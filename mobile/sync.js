/* =============================================================
   云同步（Supabase）

   ## 架构：本地优先，后台同步

   界面代码**一行都不用改**——它仍然同步读 `DB`（localStorage）。
   这个模块在后台跑，负责和服务器交换数据：

       界面  ──同步读写──►  DB（localStorage）
                              ↑↓
                           sync.js   ← 这个文件
                              ↑↓
                           cloudClient

   ## 为什么不把界面改成异步

   服务器调用是异步的，而现在的渲染函数全是同步的
   （`renderDash()` 直接读 `DB.projects`）。如果让界面去 await 数据：

     · 项目里 40 多处调用点都要改成 async
     · **离线时界面完全打不开**——这是不可接受的

   所以本地始终是"唯一真相"，服务器只是同步对象。

   ## 没网时怎么办

   所有改动先写本地 + 进队列，然后**尝试**上传。
   上传失败不清队列，下次网络恢复时补传。
   界面永远只依赖本地数据，所以断网照常能用。
   ============================================================= */
"use strict";

/* Supabase 客户端（从 CDN 载入的全局 UMD 对象）。

   **变量名不能直接叫 `supabase`**：那个库把自己也暴露成全局
   `supabase`，同名的顶层 `let` 会触发
   "Identifier 'supabase' has already been declared"，
   让整个文件一行都不执行（表现为启动白屏）。所以叫 cloudClient。 */
let cloudClient = null;

/*: 同步状态。-1 = 没在跑，0 = 空闲，大于 0 = 正在进行第几步 */
let syncBusy = 0;
let syncTimer = null;
let listeners = [];
let syncEventsBound = false;

/*: 同步循环的间隔。30 秒是个折中：
     太短费电费流量，太长老板看不到"即时"的工时。
     另外切回前台时会立刻同步一次，所以这个间隔只影响
     "应用一直开着"的情况。 */
/* 后台自动同步的间隔。**这是自动的，不用手点「立即同步」。**

   触发时机一共有四个：
     1. 每 SYNC_INTERVAL_MS 一次（就是这里）
     2. 收到实时推送时（服务器主动推，通常 1 秒内）
     3. App 从后台切回前台
     4. 网络从断到通

   **为什么是 15 秒**

   "一发就弹"真正靠的是实时订阅（上面第 2 条），
   轮询只是它掉线时的兜底。但兜底也不能太慢：
   实时断了的时候，15 秒能自己恢复过来，人几乎察觉不到。

   再快（比如 5 秒）会让请求数翻几倍，而这是个人小团队在用，
   没必要为一两秒的差别多耗电和配额。 */
const SYNC_INTERVAL_MS = 15000;

/*: 一次同步最多处理多少条队列项。
     防止积压太多时一次请求过大、卡住界面。剩下的下轮继续。 */
const QUEUE_BATCH = 40;

/* ---------------------------------------------------------- 配置 */

/*: uuid 的形状。用来在把 id 发给服务端之前先自己检查一遍——
   服务端对类型很严格，发个 "1" 过去会报
   "invalid input syntax for type uuid"，
   而这个报错看不出是哪个字段、哪个员工的问题。 */
const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/*: **预置的云服务配置。**

   为什么要预置：让用户手填 URL 和 anon key 太麻烦了——
   那串 key 有一百多个字符，还得先搞清楚该复制哪一个
   （后台有 Project URL / RESTful endpoint / Auth endpoint
   好几个复制按钮，我见过的是粘错了导致
   "Invalid path specified in request URL"）。

   而这两个值**本来就是要打进 apk 的**：安全不靠"藏起来"，
   靠服务端的行级权限策略（RLS）。所以直接写死，用户零配置。

   设置页仍然保留——换项目、自建服务的人可以覆盖。 */
const CLOUD_DEFAULTS = {
  url: "https://edchntmyqqjqvpngylgc.supabase.co",
  key: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImVkY2hudG15cXFqcXZwbmd5bGdjIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTE1ODY5ODksImV4cCI6MjEwNzE2Mjk4OX0.6vfi2zxvdbmdLSHoV2U0r4R8zd10UCtO5XGaToqBc7I",
};

/*: Supabase 连接信息。优先用用户自己填的，没填就用预置的。 */
function syncConfig() {
  const savedUrl = getSetting("supabase_url", "");
  const savedKey = getSetting("supabase_key", "");
  const gatewayUrl = normalizeCloudUrl(
    typeof window !== "undefined" && window.PROJECT_RECORDER_GATEWAY_URL || ""
  );
  const directUrl = normalizeCloudUrl(CLOUD_DEFAULTS.url);
  const storedUrl = normalizeCloudUrl(savedUrl);
  /* Older installs may have persisted the public Supabase URL. Treat it as
     the default, so enabling a gateway really moves those users behind it. */
  const customUrl = storedUrl && storedUrl !== directUrl;
  return {
    url: customUrl ? storedUrl : gatewayUrl || directUrl,
    key: savedKey || CLOUD_DEFAULTS.key,
    custom: !!(customUrl || (savedKey && savedKey !== CLOUD_DEFAULTS.key)),
  };
}

/* 把用户填的 Supabase 地址规整成"只有协议 + 域名"的形式。

   ## 为什么必须做这个

   Supabase 后台有**很多个**复制按钮，位置不同、内容不同：

     Project URL          https://xxx.supabase.co
     RESTful endpoint     https://xxx.supabase.co/rest/v1/
     Auth endpoint        https://xxx.supabase.co/auth/v1

   **用户很可能复制到带路径的那个。**

   而 `createClient(url)` 会自己拼 `url + "/rest/v1"`。
   如果传进去的是 `https://xxx.supabase.co/rest/v1/`，
   最终请求会变成 `https://xxx.supabase.co/rest/v1//rest/v1/...`，
   Supabase 返回 **"Invalid path specified in request URL"**。

   这个报错完全看不出是"地址多粘了一段"，所以这里直接规整掉：
   只保留协议 + 域名 + 端口。 */
function normalizeCloudUrl(input) {
  let text = String(input || "").trim();
  if (!text) return "";

  /* 少了协议就补上。用户经常只粘 xxx.supabase.co */
  if (!/^https?:\/\//i.test(text)) text = "https://" + text;

  try {
    const parsed = new URL(text);
    return parsed.protocol + "//" + parsed.host;
  } catch (error) {
    /* 不是合法 URL。原样返回（去掉末尾斜杠），
       让服务端报错时至少能看到用户到底填了什么。 */
    return text.replace(/\/+$/, "");
  }
}

function saveSyncConfig(url, key) {
  saveSetting("supabase_url", normalizeCloudUrl(url));
  saveSetting("supabase_key", String(key || "").trim());
}

function cloudReady() {
  const config = syncConfig();
  return !!(config.url && config.key);
}

/* ---------------------------------------------------------- 初始化 */
function initCloud() {
  /* **已经建过就直接用，别再建第二个。**

     这一句是修一个真事故：原来这里没有判断，每次调用都
     `createClient(...)` 新建一个客户端。函数注释写着"幂等"，
     其实**根本不幂等**。

     而我在两处让它被反复调用：
       · boot() 启动时调一次
       · ensureGetuiPushConsent() 的重试循环里最多调 8 次

     后果（真机上抓到的日志）：

       Multiple GoTrueClient instances detected in the same browser  ×N
       Getui 登记失败：写库失败：new row violates row-level security policy

     多个 GoTrue 实例抢同一个 storageKey（pr_auth_v1），
     认证状态互相覆盖，写请求被打成匿名 —— 于是被 RLS 拒；
     更糟的是**同步整个挂住**：lastSync 停在某个时刻不再前进，
     界面上一直显示"同步中…"，新派的任务永远不出现。

     所以：有就直接返回。真正的重建走 resetSyncState 那条路。 */
  if (cloudClient) return true;
  if (!cloudReady()) return false;
  if (typeof window.supabase === "undefined") {
    /* CDN 没加载上（离线首启）。不是致命错误——
       下次联网再试，本地功能照常用。 */
    return false;
  }
  const config = syncConfig();
  try {
    cloudClient = window.supabase.createClient(config.url, config.key, {
      auth: {
        /* 会话持久化：关掉 App 再打开不用重新登录 */
        persistSession: true,
        autoRefreshToken: true,
        storageKey: "pr_auth_v1",
      },
    });
    return true;
  } catch (error) {
    cloudClient = null;
    return false;
  }
}

/* ---------------------------------------------------------- 订阅状态 */
/* 界面可以订阅同步状态变化，用来显示"待上传 3 条"这类提示 */
function onSyncChange(fn) {
  listeners.push(fn);
}

function emitSync(status) {
  listeners.forEach(fn => {
    try { fn(status); } catch (error) { /* 单个订阅者出错不影响别人 */ }
  });
}

function syncStatus() {
  const config = syncConfig();
  return {
    enabled: cloudReady(),
    hasLibrary: typeof window.supabase !== "undefined",
    online: typeof navigator === "undefined" ? true : navigator.onLine !== false,
    pending: pendingCount(),
    last: DB.lastSync || { at: "", ok: true, pending: 0, message: "" },
    busy: syncBusy > 0,
    role: DB.profile ? DB.profile.role : null,
    signedIn: !!DB.profile,
    /* **"有本机资料"和"登录还有效"是两件事。**

       DB.profile 是本地副本，它还在不代表会话还在——
       换机、重装、令牌过期又刷新失败都会让会话消失，
       而 DB.profile 照样留着（离线可用是我们的设计）。

       但那种状态下所有写入都是匿名的，会被 RLS 全部拒掉，
       界面上只显示"同步失败"，用户根本不知道要重新登录。

       所以单独报一个"会话还在不在"。
       判断依据：云客户端能拿到当前会话。 */
    hasSession: sessionAlive(),
    configured: !!(config.url && config.key),
    protocolCompatible: !DB.clientProtocol
      || DB.clientProtocol.protocol_version === null
      || Number(DB.clientProtocol.protocol_version)
        >= Number(DB.clientProtocol.minimum_protocol_version || 2),
  };
}

/* 云客户端里还留着登录会话吗。

   注意：这是**同步**判断，靠 initCloud() 之后 supabase 客户端
   内存里的会话状态。没初始化过、或者会话被清掉，都算没有。

   真正确认要靠 getSession()（异步），那是 restoreSession() 的事；
   这里只用来决定界面提不提示。 */
function sessionAlive() {
  if (!cloudClient || !cloudClient.auth) return false;
  try {
    /* supabase-js 把当前会话放在 auth 内部的 storage 适配器里，
       不同小版本字段名不一样。稳妥做法是看有没有 access_token，
       取不到就当"不知道"，返回 true（不误报）。 */
    const raw = typeof localStorage !== "undefined"
      ? localStorage.getItem("pr_auth_v1") : null;
    if (raw === null) return false;
    if (raw === "" || raw === "null") return false;
    return true;
  } catch (error) {
    return true;
  }
}

const APP_PROTOCOL_VERSION = 2;
const APP_CLIENT_VERSION = "2.0.9";

async function ensureClientProtocol(force) {
  if (!DB.profile || !initCloud()) return false;
  const cached = DB.clientProtocol || {};
  if (!force && cached.checked_at
      && Date.now() - Number(cached.checked_at) < 60000) {
    return Number(cached.protocol_version || 0)
      >= Number(cached.minimum_protocol_version || 2);
  }
  try {
    let result = await cloudClient.rpc("register_client_protocol", {
      p_protocol: APP_PROTOCOL_VERSION,
      p_app_version: APP_CLIENT_VERSION,
    });
    if (result.error
        && /could not find the function|does not exist|schema cache/i.test(String(result.error.message || ""))) {
      result = await cloudClient.rpc("get_client_protocol");
    }
    if (result.error) throw result.error;
    const data = result.data || {};
    DB.clientProtocol = {
      protocol_version: Number(data.protocol_version || APP_PROTOCOL_VERSION),
      minimum_protocol_version: Number(data.minimum_protocol_version || APP_PROTOCOL_VERSION),
      checked_at: Date.now(),
    };
    saveAll();
    const compatible = DB.clientProtocol.protocol_version
      >= DB.clientProtocol.minimum_protocol_version;
    if (!compatible) {
      DB.lastSync = Object.assign({}, DB.lastSync, {
        ok: false,
        message: "客户端协议过旧，请安装新版后继续同步",
      });
      saveAll();
    }
    return compatible;
  } catch (error) {
    DB.clientProtocol = Object.assign({}, cached, {
      checked_at: Date.now(),
      error: String(error.message || error || "协议检查失败"),
    });
    saveAll();
    return true;
  }
}

/* ---------------------------------------------------------- 认证 */

function profileFromUser(user, extra) {
  return {
    id: user.id,
    code: (extra && extra.code) || user.email || "",
    name: (extra && extra.name) || user.email || "",
    role: (extra && extra.role) || "boss",
    boss_id: (extra && extra.boss_id) || null,
    active_enterprise_id: (extra && extra.active_enterprise_id) || null,
    primary_enterprise_id: (extra && extra.primary_enterprise_id) || null,
    weekly_hours: num(extra && extra.weekly_hours) || 40,
    /* **真实的登录邮箱。**

       **优先用 profiles 表里的，而不是 session 里的。**

       原因：session 里的 user 是登录那一刻缓存的快照，
       邮箱在服务端被改掉之后它还是旧的，而且不会自己刷新。
       实测踩到：数据库里已经是 Gmail 了，界面上还写着"未绑定"，
       用户以为没改成，反复操作。

       profiles 那行每次 adoptSession 都重新查，所以是新的。 */
    email: (extra && extra.email) || (user && user.email) || "",
  };
}

/* 登录。

   用的是 Supabase Auth 的**邮箱密码**方式，但界面上让用户填
   "账号名"。做法是把账号名转成一个内部邮箱：
       boss  →  <账号名>@boss.pr
       staff →  <账号名>@staff.pr
   这样员工不用有真邮箱，而 Supabase 那边仍然是合法的邮箱格式。

   **这个转换必须和老板建账号时一致**，否则登录不上。 */
function loginCodeToEmail(code, isStaff) {
  const clean = String(code || "").trim().toLowerCase()
    .replace(/[^a-z0-9._-]/g, "");
  return clean + (isStaff ? "@staff.pr" : "@boss.pr");
}

/* ---------------------------------------------------------- 登录 */

/* 登录。

   ## 不再"猜身份"

   以前登录页让人选「我是老板 / 我是员工」，然后先按选的试、
   失败再试另一种。这有三个毛病：

     1. 用户被要求回答一个只有系统内部才知道的问题
     2. 选错了照样能进，所以那个选择器其实没用
     3. 一次登录最多发 4 个请求，失败后还说不清错在哪

   现在改成：**先问服务端"这个号对应哪个邮箱"，然后拿密码试。**
   老板账号可能是真实邮箱，员工是 <工号>@staff.pr，
   同一个号两种身份都存在时，服务端会按老板优先返回两个，
   客户端挨个试一遍就行 —— 用户不用选任何东西。

   ## 错误要分清楚

   号不存在   → 直接说"没有这个账号"
   密码不对   → 直接说"密码不对"
   这两个混在一起，就是用户反复注册新号的原因。 */
async function cloudLogin(codeOrEmail, password, options) {
  if (!initCloud()) throw new Error("云服务没有配置");

  const text = String(codeOrEmail || "").trim();
  if (!text) throw new Error("请填账号或员工号");
  if (!password) throw new Error("请填密码");

  /* ---- 1. 把「账号名 + 密码」交给服务端核对 ---- */

  if (text.indexOf("@") !== -1) {
    /* 直接填了邮箱：不用查表，直接试 */
    return loginWithEmail(text.toLowerCase(), password, options);
  }

  /* **为什么把密码也一起发过去。**

     以前是先用 login_emails 把账号名换成邮箱（这一步不需要密码），
     再用邮箱 + 密码登录。问题是 login_emails 必须开给匿名用户，
     等于**任何人拿着 apk 里的 anon key 就能把账号名换成真实邮箱**。
     以前邮箱都是假的 @boss.pr，无所谓；现在是真的 Gmail / QQ 地址，
     就变成真的隐私泄露了。

     login_email 在数据库里用 bcrypt 比对密码：
     密码不对就什么都不返回。泄露的只剩"这个账号名存在吗" ——
     而那句提示本来就是我们特意要给用户的。 */
  const lookup = await cloudClient.rpc("login_email", {
    p_code: text,
    p_password: password,
  });

  if (lookup.error) {
    /* 主函数调用失败 —— 可能是旧数据库，也可能只是服务端的
       接口缓存还没刷新（项目暂停后恢复常见）。

       退一步用 login_emails 试试。 */
    const fallback = await cloudClient.rpc("login_emails", { p_code: text });

    /* **两个都失败 = 服务器有问题，不能说成"没这个账号"。**

       实测踩到：项目恢复后 PostgREST 的 schema 缓存是旧的，
       login_email 报错、login_emails 又被收回了权限，
       于是两个都失败 —— 客户端却弹出「没有这个账号：19155025818」。

       用户看到这句会去重新注册，凭空多出一个重复账号。
       基础设施故障必须说成基础设施故障。 */
    if (fallback.error) {
      const detail = String(lookup.error.message || lookup.error || "");
      throw new Error("连不上服务器，暂时登录不了。\n\n"
        + "这是服务器端的问题，不是账号的问题。\n"
        + "过一会儿再试；一直不行就找管理员刷新一次数据库接口。"
        + (detail ? "\n（" + detail.slice(0, 60) + "）" : ""));
    }

    const list = Array.isArray(fallback.data) ? fallback.data.filter(Boolean) : [];
    if (!list.length) throw new Error(noSuchAccount(text));
    return loginWithEmail(list[0], password, options);
  }

  const payload = lookup.data || {};

  if (payload.status === "no_account") {
    throw new Error(noSuchAccount(text));
  }
  if (payload.status === "bad_password") {
    throw new Error("密码不对。\n\n"
      + "点下面的「忘了密码」，用注册时填的邮箱收验证码就能重设。");
  }
  if (payload.status !== "ok" || !payload.email) {
    throw new Error("登录失败，服务端返回了意料之外的结果。");
  }

  /* ---- 2. 密码已经在数据库里核对过了，这里只换会话 ---- */
  return loginWithEmail(payload.email, password, options);
}

function noSuchAccount(text) {
  /* **说清楚是"没这个号"，不是"密码错"。**
     这样打错一个数字立刻就能看出来。 */
  return "没有这个账号：" + text + "\n\n"
    + "检查一下有没有打错。还没有账号的话，"
    + "点下面「创建一个老板账号」。";
}

async function loginWithEmail(email, password, options) {
  let attempt = await signInEmail(email, password);

  /* 刚注册完的第一个请求，GoTrue 偶尔还没认到新用户。
     只在注册流程里重试一次，平时不拖慢登录。 */
  if (!attempt.ok && options && options.fresh
      && /invalid/i.test(attempt.message || "")) {
    await new Promise(resolve => setTimeout(resolve, 800));
    attempt = await signInEmail(email, password);
  }

  if (!attempt.ok) {
    if (/not confirmed|email_not_confirmed/i.test(attempt.message || "")) {
      throw new Error("这个账号还没确认邮箱。\n\n"
        + "去 Supabase 后台把「Confirm email」关掉，"
        + "或者在 Authentication → Users 里确认这个账号。");
    }
    throw new Error("密码不对。\n\n"
      + "点下面的「忘了密码」，用注册时填的邮箱收验证码就能重设。");
  }

  await adoptSession(attempt.user);
  _save();
  return DB.profile;
}

/* 用邮箱 + 密码登一次。失败返回错误对象，不抛异常。 */
async function signInEmail(email, password) {
  try {
    const result = await cloudClient.auth.signInWithPassword({
      email: email, password: password,
    });
    if (result.error) {
      return { ok: false, message: result.error.message || "" };
    }
    if (!result.data || !result.data.user) {
      return { ok: false, message: "没有返回用户信息" };
    }
    return { ok: true, user: result.data.user };
  } catch (thrown) {
    return { ok: false, message: String(thrown.message || thrown) };
  }
}


/* 绑/换找回邮箱。

   **不用 Supabase 的 updateUser({email})，直接调 set_my_email。**

   原因：那个接口要发确认信。老账号的邮箱是 <账号>@boss.pr ——
   一个不存在的地址。Supabase 开了"安全邮箱更改"后要求
   **新旧两个地址都确认**，旧地址永远收不到，于是改动永远完不成：
   用户卡在"待确认"，而且**最需要绑邮箱的那批人正好绑不了**。

   set_my_email 是服务端的 SECURITY DEFINER 函数，
   只改 auth.uid() 自己的那一行，不依赖任何邮件。

   **24 小时内只能改一次。** 不验证邮箱真伪，但也不能随便反复改：
      · 手滑写错还能改回来，而且这期间密码没变、照样能登录
      · 会话被盗也不能把账号悄悄搬到别的邮箱

   代价说清楚：这样不验证邮箱是否真实存在。
   好在界面拦了明显的拼写错误，用户也可以用「忘了密码」自证一次。 */
async function changeMyEmail(newEmail) {
  if (!initCloud()) throw new Error("云组件没加载上，检查网络");
  const clean = String(newEmail || "").trim().toLowerCase();
  const badEmail = checkEmail(clean);
  if (badEmail) throw new Error(badEmail);

  if (DB.profile && String(DB.profile.email || "").toLowerCase() === clean) {
    throw new Error("和现在绑的一样");
  }

  const result = await cloudClient.rpc("set_my_email", { p_email: clean });
  if (result.error) {
    const message = String(result.error.message || "");
    /* 服务端返回 "email change locked, N hours left" */
    const locked = /locked,?\s*(\d+)\s*hours?/i.exec(message);
    if (locked) {
      throw new Error("换邮箱 24 小时只能改一次。\n\n"
        + "还要等 " + locked[1] + " 小时。\n"
        + "这段时间密码没变，照样能登录。");
    }
    throw new Error(translateBossError(message));
  }

  /* 立刻更新本地，界面不用等下次登录 */
  if (DB.profile) {
    DB.profile.email = clean;
    DB.profile.emailChangedAt = nowISO();
    delete DB.profile.pendingEmail;
    _save();
  }
  return clean;
}

/* ---------------------------------------------------------- 找回密码 */

/* 往邮箱发一个验证码。

   走 Supabase 自带的 `signInWithOtp`：
     · 不用接第三方发信服务
     · 只对已存在的用户发（shouldCreateUser: false），
       不会莫名其妙注册新账号
     · 模板里必须有 {{ .Token }}，默认模板只有链接

   **位数不固定**：这个项目的 OTP 是 8 位，别的地方可能是 6 位。
   所以界面上的提示不能写死"6 位"，否则用户会以为自己收到了错的码。 */
async function sendResetCode(email) {
  if (!initCloud()) throw new Error("云服务没加载上，检查网络");
  const clean = String(email || "").trim().toLowerCase();
  const badEmail = checkEmail(clean);
  if (badEmail) {
    throw new Error(badEmail);
  }

  const { error } = await cloudClient.auth.signInWithOtp({
    email: clean,
    options: {
      shouldCreateUser: false,
      emailRedirectTo: undefined,
    },
  });
  if (error) throw new Error(translateResetError(error.message));
  return clean;
}

/* 验证码 → 换成一个登录会话 */
async function verifyResetCode(email, token) {
  if (!initCloud()) throw new Error("云组件没加载上，检查网络");
  const clean = String(email || "").trim().toLowerCase();
  const code = String(token || "").trim();
  if (!code) throw new Error("请填验证码");

  const { data, error } = await cloudClient.auth.verifyOtp({
    email: clean,
    token: code,
    type: "email",
  });
  if (error) throw new Error(translateResetError(error.message));
  if (!data || !data.user) throw new Error("验证码不对或者已经过期");

  await adoptSession(data.user);
  _save();
  return DB.profile;
}

function translateResetError(message) {
  const text = String(message || "");
  if (/rate limit|too many/i.test(text)) {
    return "发太多次了，等一小时再试（Supabase 免费额度有限制）。";
  }
  if (/token has expired|expired/i.test(text)) {
    return "验证码过期了，重新发一个。";
  }
  if (/invalid|incorrect/i.test(text)) {
    return "验证码不对，看清楚邮件里那串数字。";
  }
  if (/not found|no user/i.test(text)) {
    return "这个邮箱没有注册过。用注册时填的那个邮箱试试。";
  }
  if (/signups not allowed/i.test(text)) {
    return "这个邮箱没有对应账号。";
  }
  return text || "发不出去，检查网络后重试。";
}


/* ---------------------------------------------------------- 账号管理 */

/* 改自己的密码。

   **这是"忘了密码就是死局"的一半解药**：只要还记得现在的密码，
   就能自己在 App 里换成新的，不用去 Supabase 后台。

   走 Supabase 的 `updateUser`——它只改"当前登录的那个人"，
   所以不需要任何额外权限，也不会误改别人。 */
async function changeMyPassword(oldPassword, newPassword) {
  const profile = DB.profile;
  if (!profile) throw new Error("还没登录");
  if (String(newPassword || "").length < 6) {
    throw new Error("新密码至少要 6 位");
  }
  if (String(newPassword) === String(oldPassword)) {
    throw new Error("新密码和旧密码一样");
  }
  if (!initCloud()) throw new Error("云组件没加载上，检查网络");

  /* 先验旧密码：拿现在这个密码登一次。
     不验的话，谁拿到手机都能改密码——那是安全隐患。
     （Supabase 的 updateUser 不需要旧密码，所以这一步要自己做。）

     **必须用真实登录邮箱，不能拿 code 猜。**
     老板账号现在可能是 <手机号>@boss.pr，也可能是一个真实邮箱；
     猜错的后果是"密码明明对却说不对"。 */
  const email = (profile && profile.email)
    || loginCodeToEmail(profile.code, profile.role === "employee");
  const check = await signInEmail(email, oldPassword);
  if (!check.ok) {
    throw new Error("现在的密码不对");
  }

  const { error } = await cloudClient.auth.updateUser({
    password: String(newPassword),
  });
  if (error) throw new Error(translateAuthError(error.message));

  /* 本地那份明文密码（老板能看到员工初始密码那份）也要跟着更新，
     否则老板以后看到的是旧的。 */
  const account = staffAccounts().find(item =>
    String(item.employee_id) === String(profile.id));
  if (account) {
    account.password = String(newPassword);
    _save();
  }
  return true;
}

/* 换登录名（老板：手机号；员工：工号）。

   **客户端做不到**：Supabase 改邮箱要发确认信到新邮箱，
   而我们用的是假邮箱，收不到。所以走服务端函数
   （见 sql/account-management.sql 的 rename_my_login）。

   这一步很实用：老板注册时手机号打错一个数字，
   以前只能跑 SQL 改，现在自己在 App 里就能改。 */
async function changeMyLogin(newCode) {
  const profile = DB.profile;
  if (!profile) throw new Error("还没登录");
  const code = String(newCode || "").trim().toLowerCase();
  if (!/^[a-z0-9._-]{3,20}$/.test(code)) {
    throw new Error("只能用字母、数字和 . _ -，长度 3~20 位。\n\n"
      + "（中文和空格不能用——内部要拼成邮箱）");
  }
  if (code === String(profile.code).toLowerCase()) {
    throw new Error("和现在的登录名一样");
  }
  if (!initCloud()) throw new Error("云组件没加载上，检查网络");

  const result = await cloudClient.rpc("rename_my_login", {
    p_new_code: code,
  });
  if (result.error) throw new Error(translateAccountError(result.error.message));
  const payload = result.data || {};
  if (!payload.ok) throw new Error("服务端没有返回成功");

  /* 本地也要跟着改，否则下次登录用的是旧名字 */
  profile.code = payload.code || code;
  _save();
  return profile.code;
}

/* 注销账号。

   **以前只能跑 SQL 删**（我误建的 probe 账号就清不掉）。
   现在自己能在 App 里注销。

   服务端函数只做两件事：确认"你是你自己"，然后删掉那一行。
   `auth.users` 一删，profiles / tasks / logs / worklogs 靠外键级联跟着删。 */
async function deleteMyAccount(password) {
  const profile = DB.profile;
  if (!profile) throw new Error("还没登录");
  if (!password) throw new Error("请输入密码确认");

  /* 验密码：不验的话，别人拿到你手机就能把你账号删了。
     同样要用**真实登录邮箱**，不能拿 code 猜。 */
  const email = (profile && profile.email)
    || loginCodeToEmail(profile.code, profile.role === "employee");
  const check = await signInEmail(email, password);
  if (!check.ok) throw new Error("密码不对，没有注销");

  if (!initCloud()) throw new Error("云组件没加载上，检查网络");
  const result = await cloudClient.rpc("delete_my_account");
  if (result.error) throw new Error(translateAccountError(result.error.message));

  /* 本地也清干净：退登录 + 清同步状态。
     **本机的项目/工时/习惯不删**——那些是用户自己记的，
     和云端账号是两回事（提示里会说清楚）。 */
  await cloudLogout();
  return true;
}

/* 重置密码（**不需要旧密码**）。

   用途：员工忘了密码、老板也忘了自己设的初始密码。
   以前这种情况只能去 Supabase 后台改，现在 App 里能重置。

   安全性靠什么：
     · 员工：只有**他的老板**能重置（服务端检查 boss_id）
     · 老板：只能重置**自己名下**的员工，不能碰别人的
   也就是说"能重置谁"和"能看见谁"是同一个范围。 */
async function resetStaffPassword(employeeId, newPassword) {
  const profile = DB.profile;
  if (!profile || profile.role !== "boss") {
    throw new Error("只有老板能重置员工的密码");
  }
  if (String(newPassword || "").length < 6) {
    throw new Error("新密码至少要 6 位");
  }
  if (!initCloud()) throw new Error("云组件没加载上，检查网络");

  const result = await cloudClient.rpc("reset_staff_password", {
    p_employee_id: String(employeeId),
    p_new_password: String(newPassword),
  });
  if (result.error) throw new Error(translateAccountError(result.error.message));

  /* 本地的明文副本也更新，方便老板再看一次告诉员工 */
  const account = staffAccounts().find(item =>
    String(item.employee_id) === String(employeeId));
  if (account) {
    account.password = String(newPassword);
    _save();
  }
  return true;
}

/* 账号相关函数的英文报错 → 中文 */
function translateAccountError(message) {
  const text = String(message || "");
  if (/could not find the function|does not exist/i.test(text)
      && /rename_my_login|delete_my_account|reset_staff_password/i.test(text)) {
    return "云端的账号管理功能还没装。\n\n"
      + "去 Supabase 的 SQL Editor 跑一遍 sql/account-management.sql";
  }
  if (/already taken|already exists|duplicate key/i.test(text)) {
    return "这个登录名已经被用了，换一个";
  }
  if (/only a boss/i.test(text)) return "只有老板能做这件事";
  if (/not your staff|not found/i.test(text)) {
    return "这个员工不在你名下，动不了";
  }
  if (/code may only contain/i.test(text)) {
    return "登录名只能用字母、数字和 . _ -，长度 3~20 位";
  }
  if (/password must be at least/i.test(text)) {
    return "密码至少要 6 位";
  }
  if (/not signed in/i.test(text)) return "登录状态过期了，重新登录一次";
  return text;
}

/* 把登录结果落到本地。
   profiles 表里存着角色和所属老板，必须读出来才知道该显示什么界面。 */
async function adoptSession(user) {
  const previousId = DB.profile && DB.profile.id ? String(DB.profile.id) : "";
  if (!user) { DB.profile = null; DB.identity = null; _save(); return null; }

  let extra = null;
  try {
    const { data } = await cloudClient.from("profiles")
      .select("*").eq("id", user.id).single();
    extra = data;
  } catch (error) {
    /* 读不到 profile 不阻塞登录——先用基本信息进去，
       界面会提示"资料没同步上"。比直接登录失败好。 */
  }

  const accountId = String(user.id);
  if (DB && (currentDatabaseKey !== accountDatabaseKey(accountId)
      || String(DB.account_scope_id || "") !== accountId)) {
    saveAll();
    ensureAccountDatabase(accountId);
    if (typeof resetAccountScopedRuntimeState === "function") {
      resetAccountScopedRuntimeState();
    }
  }
  const switched = previousId && previousId !== accountId;
  DB.profile = profileFromUser(user, extra);
  DB.account_scope_id = accountId;
  DB.company_scope_id = (extra && extra.active_enterprise_id) || null;
  if (switched) DB.identity = null;
  resetSyncState();
  _save();
  return DB.profile;
}

async function cloudLogout() {
  if (DB) saveAll();
  try { if (cloudClient) await cloudClient.auth.signOut(); } catch (error) { /* 忽略 */ }
  DB.profile = null;
  DB.identity = null;
  resetSyncState();
  if (typeof resetAccountScopedRuntimeState === "function") {
    resetAccountScopedRuntimeState();
  }
  _save();
}

/* 启动时恢复上次的登录状态。
   **离线也要能恢复**——本地存了 profile 副本，所以没网也能进主界面。 */
async function restoreSession() {
  if (!initCloud()) return DB.profile;
  try {
    const { data } = await cloudClient.auth.getSession();
    if (data && data.session && data.session.user) {
      await adoptSession(data.session.user);
    }
  } catch (error) {
    /* 没网时这里会失败。本地 DB.profile 还在，照常用。 */
  }
  return DB.profile;
}

/* 检查邮箱，顺便拦下最常见的拼写错误。

   **为什么要拦**：注册时我们不验证邮箱是否真实存在
   （直接写 email_confirmed_at，否则新账号登不进去）。
   于是 `xxx@qq.con` 也能注册成功 —— 用户以为绑好了，
   等到忘了密码才发现信全发到了不存在的地址。

   完整的验证要"发一封确认信再让人点"，成本很高。
   但真正会发生的错误绝大多数是**域名拼错**，
   把这几种拦下来，就挡住了绝大部分事故。

   返回空字符串表示没问题，否则返回中文提示。 */
const EMAIL_DOMAIN_TYPOS = [
  ["qq.con", "qq.com"], ["qq.com1", "qq.com"], ["qq. com", "qq.com"],
  ["q q.com", "qq.com"], ["163.con", "163.com"], ["126.con", "126.com"],
  ["gmial.com", "gmail.com"], ["gmail.con", "gmail.com"],
  ["gmail.com1", "gmail.com"], ["outlok.com", "outlook.com"],
  ["outlook.con", "outlook.com"], ["hotmall.com", "hotmail.com"],
];

function checkEmail(raw) {
  const clean = String(raw || "").trim().toLowerCase();
  if (!clean) return "请填邮箱";
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(clean)) {
    return "邮箱格式不对，要像 xxx@qq.com 这样";
  }
  const domain = clean.split("@")[1] || "";
  for (let i = 0; i < EMAIL_DOMAIN_TYPOS.length; i += 1) {
    if (domain === EMAIL_DOMAIN_TYPOS[i][0]) {
      return "邮箱域名好像写错了：" + domain
        + "\n\n是不是想说 " + EMAIL_DOMAIN_TYPOS[i][1] + "？";
    }
  }
  /* 常见邮箱服务商：域名跟它们"只差一两个字母"就算打错。

     **不能用"开头几个字母相同"来判断。**
     我第一版就是这么写的，结果把两个真实域名拦了下来：

         sina.com.cn    ← 新浪真的用这个
         hotmail.co.uk  ← 微软真的用这个

     用户明明填对了，却被说"域名好像不对"，比不检查还糟。

     现在用编辑距离，而且**点数必须一致**才比较：
         sina.com.cn（2 个点）vs sina.com（1 个点）→ 结构不同，不比
         gmial.com （1 个点）vs gmail.com（1 个点）→ 距离 2，判为拼错 */
  const known = ["qq.com", "163.com", "126.com", "gmail.com",
    "outlook.com", "hotmail.com", "foxmail.com", "sina.com", "yeah.net"];

  const dotsOf = text => (text.match(/\./g) || []).length;

  /* 朴素的编辑距离，字符串都很短，够用 */
  const editDistance = (a, b) => {
    const rows = a.length + 1;
    const cols = b.length + 1;
    let prev = [];
    for (let j = 0; j < cols; j += 1) prev.push(j);
    for (let i = 1; i < rows; i += 1) {
      const cur = [i];
      for (let j = 1; j < cols; j += 1) {
        const cost = a[i - 1] === b[j - 1] ? 0 : 1;
        cur.push(Math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost));
      }
      prev = cur;
    }
    return prev[cols - 1];
  };

  const nearMiss = known.find(provider => {
    if (domain === provider) return false;
    if (dotsOf(domain) !== dotsOf(provider)) return false;
    /* **阈值只能是 1。**
       放到 2 的时候，这些真实域名都被误判了：
           foxmail.com  ↔ hotmail.com（差 2 个字母）
           me.com       ↔ qq.com     （也差 2 个）
       差一个字母才是"手滑少打/打错"，差两个多半是另一个域名。
       换位错字（gmial）交给上面的显式列表处理。 */
    return editDistance(domain, provider) <= 1;
  });
  if (nearMiss) {
    return "邮箱域名好像不对：" + domain
      + "\n\n是不是想说 " + nearMiss + "？";
  }
  return "";
}

/* 把 Supabase 的英文报错换成能看懂的中文。
   直接用原文的话，用户看到 "Invalid login credentials" 不知道该干什么。 */
function translateAuthError(message) {
  const text = String(message || "");
  if (/Invalid login credentials/i.test(text)) {
    return "账号或密码不对。\n\n老板用「账号」登录，员工用「员工号」登录。";
  }
  if (/Email not confirmed/i.test(text)) {
    return "这个账号还没确认邮箱。去 Supabase 后台把"
         + " Authentication → Sign In / Providers → Email 里的"
         + " Confirm email 关掉。";
  }
  if (/User already registered/i.test(text)) return "这个账号名已经被占用了。";
  if (/Password should be at least/i.test(text)) {
    return "密码太短了，至少 6 位。";
  }
  if (/Failed to fetch|NetworkError|Load failed/i.test(text)) {
    return "连不上服务器。检查网络，或者确认 Supabase 地址填对了。";
  }
  return text;
}

/* ---------------------------------------------------------- 上传 */

/* 把队列里的变更推上去。

   逐条处理而不是批量：任何一条失败都只影响它自己，
   其余的照常上传。批量提交的话一条脏数据会让整批回滚。

   ## 失败时的处理（这块我改过一次，因为踩了坑）

   原来失败只往 `DB.lastSync.message` 写一句，而**下一轮同步会把它
   覆盖掉**——结果"任务没传上去"这件事在界面上完全看不出来，
   看起来像"已同步"。这是最危险的失败模式：
   用户以为报上去了，老板那边什么都没有。

   现在：
     · 失败的项**留在队列里**，不删（下次还会重试）
     · 每项记下 `lastError`，界面上能看到具体原因
     · 返回失败清单，调用方可以据此提示

   **只有服务端明确说"唯一约束冲突"时才丢弃**——
   那种情况重试多少次都不会成功，留着只会永远堵住队列。 */
async function resolveSyncConflict(conflictId, choice) {
  const conflict = (DB.syncConflicts || []).find(item =>
    String(item.id) === String(conflictId) && !item.resolved);
  if (!conflict) throw new Error("这条冲突已经处理过了");
  if (choice === "cloud") {
    if (conflict.table === "tasks" && typeof mergeTasks === "function") {
      mergeTasks([conflict.cloud]);
    } else if (conflict.table === "worklogs"
        && typeof mergeRemoteWorklogs === "function") {
      mergeRemoteWorklogs([conflict.cloud]);
    }
    DB.syncQueue = (DB.syncQueue || []).filter(item =>
      Number(item.id) !== Number(conflict.queue_id));
    conflict.resolved = true;
    conflict.resolution = "cloud";
    conflict.resolved_at = nowISO();
    saveAll();
    return true;
  }
  if (choice === "local") {
    const queued = (DB.syncQueue || []).find(item =>
      Number(item.id) === Number(conflict.queue_id));
    if (!queued) throw new Error("对应的待上传操作已经不存在");
    queued.payload = Object.assign({}, conflict.local);
    queued.payload.updated_at = nowISO();
    delete queued.lastError;
    delete queued.lastErrorAt;
    conflict.resolved = true;
    conflict.resolution = "local";
    conflict.resolved_at = nowISO();
    saveAll();
    syncNow("conflict-local");
    return true;
  }
  throw new Error("未知的冲突处理方式");
}

async function detectQueueConflict(item) {
  if (!item || item.op !== "update" || !item.payload
      || !item.payload.updated_at || !item.key) return null;
  const { data, error } = await cloudClient.from(item.table)
    .select("*").eq("id", item.key).maybeSingle();
  if (error || !data || !data.updated_at) return null;
  const remoteTime = String(data.updated_at || "");
  const localTime = String(item.payload.updated_at || "");
  if (!remoteTime || !localTime || remoteTime <= localTime) return null;

  const ignore = new Set(["updated_at", "created_at", "sync_status"]);
  const fields = [];
  Object.keys(item.payload).forEach(key => {
    if (ignore.has(key)) return;
    if (String(item.payload[key] ?? "") !== String(data[key] ?? "")) fields.push(key);
  });
  if (!fields.length) return null;

  const conflict = {
    id: "conflict-" + item.id + "-" + Date.now(),
    queue_id: item.id,
    table: item.table,
    key: item.key,
    fields: fields,
    local: item.payload,
    cloud: data,
    at: nowISO(),
    resolved: false,
  };
  if (!Array.isArray(DB.syncConflicts)) DB.syncConflicts = [];
  DB.syncConflicts.push(conflict);
  saveAll();
  return conflict;
}

async function pushQueuedProject(item) {
  const payload = item.payload || {};
  if (item.op === "delete") {
    if (!payload.remote_id) return;
    const result = await cloudClient.from("projects")
      .delete().eq("id", payload.remote_id);
    if (result.error) throw new Error(result.error.message);
    return;
  }
  const result = await cloudClient.rpc("save_project", {
    p_id: payload.remote_id || null,
    p_version: payload.remote_version || null,
    p_data: payload,
  });
  if (result.error) throw new Error(result.error.message);
  if (!result.data || !result.data.id) throw new Error("项目保存后没有返回云端 ID");
  mergeCloudProjects([result.data]);
  saveAll();
}

async function pushQueuedProjectStep(item) {
  const payload = item.payload || {};
  if (item.op === "delete") {
    if (!payload.remote_id) return;
    const result = await cloudClient.from("project_steps")
      .delete().eq("id", payload.remote_id);
    if (result.error) throw new Error(result.error.message);
    return;
  }
  const project = getProject(payload.project_id);
  if (!project || !project.remote_id) {
    throw new Error("步骤所属项目还没有云端 ID，项目上传后会重试");
  }
  const result = await cloudClient.rpc("save_project_step", {
    p_id: payload.remote_id || null,
    p_project: project.remote_id,
    p_version: payload.remote_version || null,
    p_data: payload,
  });
  if (result.error) throw new Error(result.error.message);
  if (!result.data || !result.data.id) throw new Error("步骤保存后没有返回云端 ID");
  mergeCloudProjectSteps([result.data]);
  saveAll();
}

async function pushQueue() {
  if (!cloudClient || !DB.profile) return { pushed: 0, failed: [] };
  const compatible = await ensureClientProtocol(false);
  if (!compatible) {
    return { pushed: 0, failed: [{ message: "客户端协议过旧，请安装新版" }] };
  }
  const queue = DB.syncQueue || [];
  if (!queue.length) return { pushed: 0, failed: [] };

  const priority = { projects: 0, project_steps: 1 };
  const batch = queue.slice(0, QUEUE_BATCH).map((item, index) => ({ item, index }))
    .sort((a, b) => (priority[a.item.table] ?? 2) - (priority[b.item.table] ?? 2)
      || a.index - b.index)
    .map(row => row.item);
  const done = [];
  const failed = [];

  for (let i = 0; i < batch.length; i += 1) {
    const item = batch[i];

    /* A queue belongs to one account and, where relevant, one company.
       Refuse to upload it under a different scope. Keeping the item intact
       is safer than attributing work to the wrong organisation. */
    if (item.account_id && DB.account_scope_id
        && String(item.account_id) !== String(DB.account_scope_id)) {
      item.lastError = "这条待上传数据属于另一个账号，已停止上传";
      item.lastErrorAt = nowISO();
      failed.push(item);
      break;
    }
    const currentEnterprise = DB.company_scope_id
      || (DB.identity && DB.identity.enterprise && DB.identity.enterprise.id)
      || null;
    if (item.enterprise_id && currentEnterprise
        && String(item.enterprise_id) !== String(currentEnterprise)) {
      item.lastError = "这条待上传数据属于另一家公司，已停止上传";
      item.lastErrorAt = nowISO();
      failed.push(item);
      break;
    }

    try {
      const conflict = await detectQueueConflict(item);
      if (conflict) {
        item.lastError = "云端版本较新，已暂停上传，等待选择保留哪一版";
        item.lastErrorAt = nowISO();
        failed.push({ table: item.table, op: item.op, message: item.lastError });
        break;
      }
      if (item.table === "projects") {
        await pushQueuedProject(item);
        done.push(item.id);
        delete item.lastError;
        delete item.lastErrorAt;
        continue;
      }
      if (item.table === "project_steps") {
        await pushQueuedProjectStep(item);
        done.push(item.id);
        delete item.lastError;
        delete item.lastErrorAt;
        continue;
      }
      if (item.op === "delete") {
        if (!["tasks", "task_logs", "worklogs"].includes(item.table)) {
          throw new Error("不支持的删除同步表：" + item.table);
        }
        const result = await cloudClient.rpc("delete_sync_record", {
          p_table: item.table,
          p_id: item.key,
          p_enterprise: currentEnterprise,
        });
        if (result.error) throw new Error(result.error.message);
        if (result.data && result.data.ok === false) {
          throw new Error(result.data.message || "删除同步失败");
        }
      } else {
        const result = await cloudClient.from(item.table)
          .upsert(item.payload, { onConflict: "id" });
        if (result.error) throw new Error(result.error.message);
      }
      done.push(item.id);
      delete item.lastError;
      delete item.lastErrorAt;
    } catch (error) {
      const message = String(error.message || error);

      /* Another device already deleted this row. Apply the server tombstone
         locally and drop this stale queue item. */
      if (/record deleted on another device/i.test(message)) {
        applySyncTombstones([{
          table_name: item.table,
          row_id: item.key,
          deleted_at: nowISO(),
        }]);
        done.push(item.id);
        continue;
      }

      /* 唯一约束冲突：服务端已经有这条了，重试也不会成功。
         当作成功丢弃，否则队列会被这一条永远堵住。 */
      if (/duplicate key|unique constraint|violates.*unique/i.test(message)) {
        done.push(item.id);
        continue;
      }

      /* 表不存在：sql/migrate-notify.sql 没跑。

         **这种也要丢弃**，和唯一约束同理——表不会自己出现，
         留着只会把队列永远堵住，而且用户完全不知道是这个原因。
         通知功能降级（没有通知），但别的功能照常。

         记一条提示，让界面能说清楚"要跑哪段 SQL"。

         **注意：这个标记要能自己消掉。**
         原来只在这里设 true，没有任何地方设回 false——
         于是"跑完 SQL 之后提示还在"，用户会以为没生效。
         清除在 verifyNotifyTable() 里做（临同步时验一次）。 */
      if (item.table === "task_events"
          && /Could not find the table|does not exist|schema cache/i.test(message)) {
        DB.notifyTableMissing = true;
        done.push(item.id);
        continue;
      }

      /* 其他错误：留着并记下原因。
         **不静默吞掉**——上一轮就是因为吞掉了，
         "tasks 表缺 updated_at 列" 这个错误查了很久。 */
      item.lastError = message;
      item.lastErrorAt = nowISO();
      failed.push({ table: item.table, op: item.op, message: message });
      /* Later queue items may depend on this one (create -> update -> delete).
         Stop this round and retry from the same item after the cause is fixed. */
      break;
    }
  }

  if (done.length) clearQueueItems(done);
  _save();

  return { pushed: done.length, failed: failed };
}

/* ---------------------------------------------------------- 下载 */

/* 把服务端返回的时间戳变成「能安全拼进 URL」的形式。

   ## 这个坑很隐蔽，值得记下来

   PostgreSQL 的 timestamptz 输出是 `2026-10-15T13:27:10+00:00`。
   它被 `query.gte("updated_at", cursor)` 原样拼进 query string，
   而 **URL 里的 `+` 代表空格** —— 服务端收到的是

       2026-10-15T13:27:10 00:00

   解析失败，返回：

       HTTP 400  22007
       invalid input syntax for type timestamp with time zone

   而增量拉取的写法是 `if (!error && data) { ... }` ——
   **报错被静默吞掉**，光标永远停在旧值，于是：

      · 每次同步都拿 0 条
      · 光标永远不前进
      · 新任务**永远不会出现**
      · 界面一直显示「已同步」

   属于「看起来一切正常、其实彻底不工作」的那一类。
   实测症状：光标卡在 2026-10-15T13:27:10+00:00 好几天不动。

   修法：统一换成 `Z` 结尾。`Z` 不含 `+`，不会被误解。 */
function cursorSafe(value) {
  const text = String(value || "").trim();
  if (!text) return "";
  /* 已经是 Z 结尾、或者只是日期，直接用 */
  if (/Z$/.test(text)) return text;
  if (/^\d{4}-\d{2}-\d{2}$/.test(text)) return text;
  /* +00:00 -> Z。我们这个库全是 UTC，这是最常见的一种。 */
  const utc = /^(.*?)\+00:00$/.exec(text);
  if (utc) return utc[1] + "Z";
  /* 其他偏移（理论上不会出现）：把空格补成 T，`+` 换成 %2B */
  return text.replace(" ", "T").replace(/\+/g, "%2B");
}

/* 增量拉取。

   用 syncCursor 记各表上次拉到的时间，只拉更新的。
   没有 cursor 就只能每次全量拉——数据一多就明显变慢，
   而且流量全浪费在没变的数据上。

   ## 返回值

   以前只返回"变了多少条"（一个数字）。现在还要给通知模块
   提供**新事件**和**新工时**，所以改成对象：

     { changed, events, newWorklogs }

   `events` 是这次拉到的新 task_events（老板看员工的完成/取消，
   员工看老板派的活）；`newWorklogs` 是这次新拉到的工时行，
   用来合成"今天收到 N 条工时"那条汇总。 */
function applySyncTombstones(rows) {
  const list = Array.isArray(rows) ? rows : [];
  if (!list.length) return 0;
  let changed = 0;
  const removed = new Set();
  list.forEach(row => {
    const table = String(row.table_name || "");
    const id = String(row.row_id || "");
    if (!table || !id) return;
    removed.add(table + ":" + id);
    changed += 1;
  });
  DB.tasks = (DB.tasks || []).filter(row =>
    !removed.has("tasks:" + String(row.id)));
  DB.taskLogs = (DB.taskLogs || []).filter(row =>
    !removed.has("task_logs:" + String(row.id)));
  DB.remoteWorklogs = (DB.remoteWorklogs || []).filter(row =>
    !removed.has("worklogs:" + String(row.id)));
  DB.worklogs = (DB.worklogs || []).filter(row =>
    !removed.has("worklogs:" + String(row.id)));
  DB.syncQueue = (DB.syncQueue || []).filter(item =>
    !removed.has(String(item.table) + ":" + String(item.key)));
  DB.syncConflicts = (DB.syncConflicts || []).filter(item =>
    !removed.has(String(item.table) + ":" + String(item.key)));
  saveAll();
  return changed;
}

function cloudSyncDateOnly(value) {
  const text = String(value || "");
  return text ? text.slice(0, 10) : "";
}

function cloudProjectFields(row) {
  return {
    remote_id: String(row.id || ""),
    remote_version: Number(row.version || 1),
    cloud_updated_at: String(row.updated_at || ""),
    name: String(row.name || ""),
    owner: String(row.owner || ""),
    client: String(row.client || ""),
    status: String(row.status || "进行中"),
    priority: String(row.priority || "中"),
    start_date: cloudSyncDateOnly(row.start_date),
    due_date: cloudSyncDateOnly(row.due_date),
    budget: num(row.budget),
    cost: num(row.cost),
    progress: clamp(num(row.progress), 0, 100),
    note: String(row.note || ""),
    created_at: String(row.created_at || nowISO()),
    updated_at: String(row.updated_at || nowISO()),
  };
}

function cloudStepFields(row, localProjectId) {
  return {
    remote_id: String(row.id || ""),
    remote_version: Number(row.version || 1),
    cloud_updated_at: String(row.updated_at || ""),
    project_id: Number(localProjectId),
    seq: num(row.seq),
    name: String(row.name || ""),
    owner: String(row.owner || ""),
    status: String(row.status || "未开始"),
    start_date: cloudSyncDateOnly(row.start_date),
    due_date: cloudSyncDateOnly(row.due_date),
    progress: clamp(num(row.progress), 0, 100),
    note: String(row.note || ""),
    created_at: String(row.created_at || nowISO()),
    updated_at: String(row.updated_at || nowISO()),
  };
}

function pendingSyncKeys(table) {
  return new Set((DB.syncQueue || [])
    .filter(item => item.table === table)
    .map(item => String(item.key)));
}

function pendingDeleteRemoteIds(table) {
  return new Set((DB.syncQueue || [])
    .filter(item => item.table === table && item.op === "delete")
    .map(item => String((item.payload || {}).remote_id || ""))
    .filter(Boolean));
}

function mergeCloudProjects(rows) {
  if (!Array.isArray(DB.projects)) DB.projects = [];
  if (!Array.isArray(DB.steps)) DB.steps = [];
  const activeRows = (Array.isArray(rows) ? rows : []).filter(row => !row.archived_at);
  const pending = pendingSyncKeys("projects");
  const deleting = pendingDeleteRemoteIds("projects");
  const remoteIds = new Set();
  let changed = 0;

  activeRows.forEach(row => {
    const remoteId = String(row.id || "");
    if (!remoteId || deleting.has(remoteId)) return;
    remoteIds.add(remoteId);
    const fields = cloudProjectFields(row);
    let local = DB.projects.find(item => String(item.remote_id || "") === remoteId);
    if (!local) {
      local = Object.assign({ id: nextId("project") }, fields);
      DB.projects.push(local);
      changed += 1;
      return;
    }
    if (pending.has(String(local.id))) return;
    if (local.cloud_updated_at === fields.cloud_updated_at) return;
    Object.assign(local, fields);
    changed += 1;
  });

  const before = DB.projects.length;
  DB.projects = DB.projects.filter(item =>
    !item.remote_id || remoteIds.has(String(item.remote_id))
      || pending.has(String(item.id)));
  changed += before - DB.projects.length;
  if (changed) saveAll();
  return changed;
}

function mergeCloudProjectSteps(rows) {
  if (!Array.isArray(DB.steps)) DB.steps = [];
  const pending = pendingSyncKeys("project_steps");
  const deleting = pendingDeleteRemoteIds("project_steps");
  const remoteIds = new Set();
  let changed = 0;

  (Array.isArray(rows) ? rows : []).forEach(row => {
    const remoteProjectId = String(row.project_id || "");
    const project = DB.projects.find(item =>
      String(item.remote_id || "") === remoteProjectId);
    if (!project) return;
    const remoteId = String(row.id || "");
    if (!remoteId || deleting.has(remoteId)) return;
    remoteIds.add(remoteId);
    const fields = cloudStepFields(row, project.id);
    let local = DB.steps.find(item => String(item.remote_id || "") === remoteId);
    if (!local) {
      local = Object.assign({ id: nextId("step") }, fields);
      DB.steps.push(local);
      changed += 1;
      return;
    }
    if (pending.has(String(local.id))) return;
    if (local.cloud_updated_at === fields.cloud_updated_at) return;
    Object.assign(local, fields);
    changed += 1;
  });

  const before = DB.steps.length;
  DB.steps = DB.steps.filter(item =>
    !item.remote_id || remoteIds.has(String(item.remote_id))
      || pending.has(String(item.id)));
  changed += before - DB.steps.length;
  if (changed) saveAll();
  return changed;
}

async function pullCloudProjects() {
  if (!cloudClient || !DB.profile) return { changed: 0, error: null };
  const identityData = typeof identityState === "function" ? identityState() : null;
  const ownerId = identityData && identityData.enterprise
    ? identityData.enterprise.owner_profile_id
    : (DB.profile.boss_id || (DB.profile.role === "boss" ? DB.profile.id : ""));
  if (!ownerId) return { changed: 0, error: new Error("当前账号没有有效公司") };
  const projects = await cloudClient.from("projects").select("*")
    .eq("boss_id", ownerId)
    .order("updated_at", { ascending: false })
    .limit(1000);
  if (projects.error) return { changed: 0, error: projects.error };
  let changed = mergeCloudProjects(projects.data || []);

  const steps = await cloudClient.from("project_steps").select("*")
    .eq("boss_id", ownerId)
    .order("seq", { ascending: true })
    .limit(5000);
  if (steps.error) return { changed: changed, error: steps.error };
  changed += mergeCloudProjectSteps(steps.data || []);
  DB.cloudProjectsAt = nowISO();
  saveAll();
  return { changed: changed, error: null };
}

async function pullAll() {
  const empty = { changed: 0, events: [], newWorklogs: [] };
  if (!cloudClient || !DB.profile) {
    DB.pullError = "云端客户端没就绪，拉取被跳过";
    _save();
    return empty;
  }
  const profile = DB.profile;
  /* 旧版把游标推进到手机当前时间，查询过程中到达的行可能被永久跳过。
     升级后只重置一次云端增量游标（不动本地数据）；通知按事件 ID 去重，
     因而既能补回漏掉的消息，也不会重复弹已经处理过的通知。 */
  if (!DB.syncCursor || DB.syncCursor.safeWatermarkV1 !== true) {
    DB.syncCursor = { safeWatermarkV1: true };
    _save();
  }
  const cursor = DB.syncCursor || {};
  let changed = 0;
  const newWorklogs = [];
  let events = [];

  /* **把拉取错误收集起来，不要再静默吞掉。**

     这里每一段原本都是 `if (!error && data) { ... }` ——
     只要查询报错就什么都不做，既不记日志也不改界面。
     后果是"同步显示成功、数据永远不来"，而且**查不出原因**：
     光标不前进、界面没异常、日志干净。

     游标里的 `+` 号那次事故就是被这个写法掩盖了好几天的。
     现在把错误存进 DB.pullError，界面上能看见。 */
  const pullErrors = [];
  const noteError = (label, error) => {
    if (!error) return;
    pullErrors.push(label + "：" + String(error.message || error));
  };

  /* ---- 项目与步骤 ----
     手机本地项目和云端项目原本是两套数据，经营摘要能算出项目、
     首页却显示 0。这里把公司项目与步骤先并入本地缓存，再拉任务和工时。 */
  try {
    const projectSync = await pullCloudProjects();
    if (projectSync.error) noteError("项目", projectSync.error);
    changed += projectSync.changed || 0;
  } catch (error) {
    noteError("项目", error);
  }

  /* ---- 任务 ----
     员工拉"派给我的"，老板拉"我派出去的"。

     **老板也必须拉。** 原来只有员工拉，老板手上那份 tasks 是
     派发时写进去的本地副本，之后永远不变 —— 于是员工点"接受"、
     或者延期被批准后改了日期，老板这边看到的还是旧状态。
     见 sql/task-accept-extension.sql。 */
  if (profile.role === "employee" || profile.role === "boss") {
    let query = cloudClient.from("tasks").select("*")
      .order("plan_date", { ascending: false })
      .limit(200);
    if (!identityHasManagementView()) {
      query = query.eq("employee_id", profile.id);
    } else {
      query = query.eq("boss_id", identityOwnerId());
    }
    if (cursor.tasks) query = query.gte("updated_at", cursorSafe(cursor.tasks));
    const { data, error } = await query;
    if (error) noteError("任务", error);
    if (!error && data) {
      changed += mergeTasks(data);
      const watermark = latestTimestamp(data, "updated_at");
      if (watermark) DB.syncCursor.tasks = watermark;
    }
  }

  /* ---- 延期申请 ----
     员工看到自己提的状态，老板看到等着他批的。
     RLS 已经按 boss_id / employee_id 过滤，这里不用再加条件。 */
  {
    let query = cloudClient.from("task_requests").select("*")
      .order("created_at", { ascending: false })
      .limit(300);
    if (cursor.taskRequests) query = query.gte("created_at", cursorSafe(cursor.taskRequests));
    const { data, error } = await query;
    if (error) noteError("延期申请", error);
    if (!error && data) {
      changed += mergeTaskRequests(data);
      const watermark = latestTimestamp(data, "created_at");
      if (watermark) DB.syncCursor.taskRequests = watermark;
    }
  }

  /* ---- 记忆源点流水 ----
     RLS 已经按 profile_id / boss_id 过滤：
     员工只拿到自己的，老板拿到全队的。
     这张表客户端**只读**，写入一律走 merit_add 函数。 */
  if (typeof MERIT === "object") {
    let query = cloudClient.from("merit_ledger").select("*")
      .order("created_at", { ascending: false })
      .limit(500);
    if (cursor.merit) query = query.gte("created_at", cursorSafe(cursor.merit));
    const { data, error } = await query;
    if (error) {
      /* 表还没建时不要天天报错 —— 那是部署问题，不是同步失败 */
      if (!/does not exist|Could not find/i.test(String(error.message || ""))) {
        noteError("记忆源点", error);
      }
    }
    if (!error && data) {
      changed += mergeMeritLedger(data);
      const watermark = latestTimestamp(data, "created_at");
      if (watermark) DB.syncCursor.merit = watermark;
    }
  }

  /* ---- 上下工 / 商城 / 兑换 / 请假 ----
     四张表都小（一个人的记录不会多），直接全量拉最近若干条，
     不做增量游标 —— 少一套游标就少一类查不出来的 bug。 */
  {
    const tables = [
      ["work_sessions", "workSessions", mergeWorkSessions, 200],
      ["rewards", "rewards", mergeRewards, 200],
      ["redemptions", "redemptions", mergeRedemptions, 200],
      ["leave_requests", "leaves", mergeLeaves, 200],
    ];

    for (const [table, key, merge, limit] of tables) {
      const { data, error } = await cloudClient.from(table).select("*")
        .order("created_at", { ascending: false })
        .limit(limit);

      if (error) {
        /* 表还没建时只是部署问题，不要天天在界面上报错 */
        if (!/does not exist|Could not find/i.test(String(error.message || ""))) {
          noteError(table, error);
        }
        continue;
      }
      if (data) changed += merge(data);
    }
  }

  /* ---- 工时（老板端拉员工的，员工端拉自己确认过的） ---- */
  {
    let query = cloudClient.from("worklogs").select("*")
      .order("created_at", { ascending: false })
      .limit(500);
    if (identityCanAny([
      "worklogs.approve", "people.view_all", "reports.view",
      "finance.view", "company.manage",
    ])) {
      query = query.eq("boss_id", identityOwnerId());
    } else {
      query = query.eq("employee_id", profile.id);
    }
    if (cursor.worklogs) query = query.gte("created_at", cursorSafe(cursor.worklogs));
    const { data, error } = await query;
    if (error) noteError("工时", error);
    if (!error && data) {
      changed += mergeRemoteWorklogs(data);
      const watermark = latestTimestamp(data, "created_at");
      if (watermark) DB.syncCursor.worklogs = watermark;
      /* 记下这次新拉到的行，给"今天收到 N 条工时"那条汇总用。
         只算新拉到的，不是全部——否则每次同步都会提醒一遍。 */
      data.forEach(row => newWorklogs.push(row));
    }
  }

  /* ---- 自己的勾选记录（用来显示"今天完成了几条"） ---- */
  if (profile.role === "employee") {
    let query = cloudClient.from("task_logs").select("*")
      .eq("employee_id", profile.id)
      .order("finished_at", { ascending: false })
      .limit(200);
    if (cursor.taskLogs) query = query.gte("finished_at", cursorSafe(cursor.taskLogs));
    const { data, error } = await query;
    if (error) noteError("勾选", error);
    if (!error && data) {
      changed += mergeTaskLogs(data);
      const watermark = latestTimestamp(data, "finished_at");
      if (watermark) DB.syncCursor.taskLogs = watermark;
    }
  }

  /* ---- 任务事件（通知的来源） ----
     老板拉自己任务上的事件（员工完成 / 取消完成），
     员工拉派给自己的事件（老板派了新活）。

     **拉不到不算错误**：如果服务端还没建 task_events 表
     （sql/migrate-notify.sql 没跑），这里会报 404 之类的错。
     那种情况下应用内其他功能照常，只是没有通知——
     不能因为通知拉不到就让整个同步显示失败。 */
  {
    let query = cloudClient.from("task_events").select("*")
      .order("created_at", { ascending: false })
      .limit(200);
    if (identityHasManagementView()) {
      query = query.eq("boss_id", identityOwnerId());
    } else {
      query = query.eq("employee_id", profile.id);
    }
    if (cursor.taskEvents) query = query.gte("created_at", cursorSafe(cursor.taskEvents));
    const { data, error } = await query;
    if (error) noteError("事件", error);
    if (!error && data) {
      events = data;
      const watermark = latestTimestamp(data, "created_at");
      if (watermark) DB.syncCursor.taskEvents = watermark;
    }
  }

  /* ---- deletion tombstones ---- */
  try {
    const { data, error } = await cloudClient.rpc("get_sync_tombstones", {
      p_since: cursor.tombstones ? cursorSafe(cursor.tombstones) : null,
    });
    if (error) noteError("删除标记", error);
    if (!error && data) {
      const rows = Array.isArray(data) ? data : [];
      changed += applySyncTombstones(rows);
      const watermark = latestTimestamp(rows, "deleted_at");
      if (watermark) DB.syncCursor.tombstones = watermark;
    }
  } catch (error) {
    noteError("删除标记", error);
  }

  /* 记下拉取错误，界面能看见。
     全都没错时清空，免得一条旧错误永远挂着误导人。

     **只在值变了才写盘。** _save() 是把整个 DB 序列化进
     localStorage，每 15 秒白写一次不划算。 */
  const nextError = pullErrors.length ? pullErrors.join("　") : "";
  if (DB.pullError !== nextError) {
    DB.pullError = nextError;
    _save();
  }

  return { changed: changed, events: events, newWorklogs: newWorklogs };
}

/* 游标只推进到这次确实读到的最后一行，不能用手机当前时间。
   否则查询期间新插入的行会落在“查询结束时间”之前，永远被跳过。
   使用 gte + 各表自身的幂等合并/通知键，安全覆盖相同时间戳。 */
function latestTimestamp(rows, field) {
  let latest = "";
  (rows || []).forEach(row => {
    const value = row && row[field] ? String(row[field]) : "";
    if (value && (!latest || value > latest)) latest = value;
  });
  /* 存进去之前就归一化，见 cursorSafe */
  return latest ? cursorSafe(latest) : latest;
}


/* 把服务端的任务并入本地缓存。

   匹配用**服务端 id**（uuid），不是本地自增 id——
   自增 id 每台机器各自算，两台手机的同一条任务会撞到不同数字上。 */
function mergeTasks(rows) {
  let changed = 0;
  rows.forEach(row => {
    const existing = (DB.tasks || []).find(item => item.id === row.id);
    if (existing) {
      /* 任务内容可能被老板改过，直接覆盖 */
      Object.assign(existing, row);
    } else {
      DB.tasks.push(row);
      changed += 1;
    }
  });
  if (changed || rows.length) _save();
  return changed;
}

/* 合并服务端拉回来的延期申请。

   和 tasks 不同，这里的记录**不会被客户端改**（写操作都在服务端
   函数里做），所以直接覆盖是安全的——老板批了之后，员工下次同步
   拉到的就是 approved 了。 */
function mergeMeritLedger(rows) {
  if (!Array.isArray(DB.meritLedger)) DB.meritLedger = [];
  let changed = 0;
  rows.forEach(row => {
    const existing = DB.meritLedger.find(item => item.id === row.id);
    if (existing) Object.assign(existing, row);
    else { DB.meritLedger.push(row); changed += 1; }
  });
  if (changed || rows.length) _save();
  return changed;
}

/* ---------------------------------------------------------------
 *  四张小表的合并。
 *
 *  写法完全一样，所以用一个工厂生成 —— 复制四遍只会多四个
 *  改漏的地方。
 * --------------------------------------------------------------- */
function makeMerger(key) {
  return function merge(rows) {
    if (!Array.isArray(DB[key])) DB[key] = [];
    let changed = 0;
    rows.forEach(row => {
      const existing = DB[key].find(item => item.id === row.id);
      if (existing) Object.assign(existing, row);
      else { DB[key].push(row); changed += 1; }
    });
    /* 本地按时间倒序，界面直接用，不用各自排序 */
    DB[key].sort((a, b) =>
      String(b.created_at || b.started_at || "")
        .localeCompare(String(a.created_at || a.started_at || "")));
    if (changed || rows.length) _save();
    return changed;
  };
}

const mergeWorkSessions = makeMerger("workSessions");
const mergeRewards = makeMerger("rewards");
const mergeRedemptions = makeMerger("redemptions");
const mergeLeaves = makeMerger("leaves");

function mergeTaskRequests(rows) {
  if (!Array.isArray(DB.taskRequests)) DB.taskRequests = [];
  let changed = 0;
  rows.forEach(row => {
    const existing = DB.taskRequests.find(item => item.id === row.id);
    if (existing) Object.assign(existing, row);
    else { DB.taskRequests.push(row); changed += 1; }
  });
  if (changed || rows.length) _save();
  return changed;
}

function mergeTaskLogs(rows) {
  let changed = 0;
  if (!Array.isArray(DB.taskLogs)) DB.taskLogs = [];
  rows.forEach(row => {
    const existing = DB.taskLogs.find(item => item.id === row.id);
    if (existing) Object.assign(existing, row);
    else { DB.taskLogs.push(row); changed += 1; }
  });
  if (changed || rows.length) _save();
  return changed;
}

/* 老板端收到的员工工时。

   **放进独立的 remoteWorklogs，不混进 worklogs**：
     混在一起的话就没法区分"我自己记的"和"员工报上来的"，
     而这两者的编辑、删除、去重规则完全不同。
     统计的时候两边都算上，展示的时候分开。 */
function mergeRemoteWorklogs(rows) {
  let changed = 0;
  if (!Array.isArray(DB.remoteWorklogs)) DB.remoteWorklogs = [];
  rows.forEach(row => {
    let local = DB.worklogs.find(
      item => String(item.cloud_id || "") === String(row.id || "")
    );
    if (!local) {
      local = DB.worklogs.find(item =>
        !item.cloud_id
        && item.work_date === row.work_date
        && String(item.content || "") === String(row.content || "")
        && Math.abs(num(item.hours) - num(row.hours)) < 0.001
      );
    }
    if (local) {
      /* A migrated local row and its cloud copy are one worklog. Keep the
         local numeric key for edits, but bind it to the authoritative UUID
         so the combined list does not count it twice. */
      local.cloud_id = row.id;
      local.approval_status = row.approval_status || local.approval_status;
      local.updated_at = row.updated_at || local.updated_at;
      if (typeof resolveQueuedWorklogDimensions === "function") {
        resolveQueuedWorklogDimensions(local.id, row.id);
      }
      const duplicateIndex = DB.remoteWorklogs.findIndex(
        item => String(item.id || "") === String(row.id || "")
      );
      if (duplicateIndex >= 0) DB.remoteWorklogs.splice(duplicateIndex, 1);
      return;
    }
    const existing = DB.remoteWorklogs.find(item => item.id === row.id);
    if (existing) Object.assign(existing, row);
    else { DB.remoteWorklogs.push(row); changed += 1; }
  });
  if (changed || rows.length) _save();
  return changed;
}

/* ---------------------------------------------------------- 同步主流程 */

/*: 正在进行的同步。用来让并发调用「等同一个结果」。 */
let syncInFlight = null;
let syncAgain = false;
let syncAgainReason = "";

/* 同步一次。

   ## 并发调用必须等同一个 Promise（这是个真 bug 的修法）

   原来是：
       if (syncBusy > 0) return syncStatus();   // 直接返回"同步中"的快照

   问题：`assignTask()`、`completeTask()` 内部都会自动调一次 syncNow，
   调用方（比如界面、测试）可能紧接着又调一次。第二次进来时
   看到 syncBusy > 0，**直接返回旧状态**——
   调用方拿到的是"还没传完"的快照，以为失败了，
   界面上就会显示"待上传 N 条"，看起来像没传上去。

   现在改成**复用在飞的那个 Promise**：并发调用会等到真正结束，
   拿到的是最终状态。 */
/* 验一下服务端的 task_events 表到底在不在，并据此更新提示。

   只在 `DB.notifyTableMissing` 是 true 的时候调用——
   正常情况一次网络请求都不多发。

   为什么需要它：那个标记原来是**只进不出**的。
   用户看到"通知功能没装好"，把 SQL 跑了，提示还在，
   于是以为 SQL 没生效。**其实只是本机记着一个旧结论。**

   判断依据：
     · 读成功（哪怕 0 行）→ 表在，清掉标记
     · 报"找不到表" → 表真不在，保持标记
     · 其他错误（网络断了、权限问题）→ **不动标记**，
       不能因为一次网络抖动就把提示撤掉 */
async function verifyNotifyTable() {
  try {
    const result = await cloudClient.from("task_events")
      .select("id").limit(1);
    if (!result.error) {
      if (DB.notifyTableMissing) {
        DB.notifyTableMissing = false;
        _save();
      }
      return true;
    }
    const message = String(result.error.message || "");
    if (!/Could not find the table|does not exist|schema cache/i.test(message)) {
      /* 不是"表不存在"，是别的毛病（网络、权限）——不轻易下结论 */
      return false;
    }
    return false;
  } catch (error) {
    /* 网络异常：保持现状 */
    return false;
  }
}

async function pushWorklogMigrationQueue() {
  if (!cloudClient || !DB.profile) return {migrated: 0, failed: [], waiting: 0};
  if (typeof ensureLocalWorklogMigrationQueues === "function") {
    ensureLocalWorklogMigrationQueues();
  }
  if (!Array.isArray(DB.worklogMigrationQueue)) DB.worklogMigrationQueue = [];
  if (!DB.worklogMigrationQueue.length) {
    return {migrated: 0, failed: [], waiting: 0};
  }
  const batch = DB.worklogMigrationQueue.slice(0, QUEUE_BATCH);
  const failed = [];
  let migrated = 0;
  let waiting = 0;
  for (let i = 0; i < batch.length; i += 1) {
    const item = batch[i];
    const built = typeof worklogMigrationPayload === "function"
      ? worklogMigrationPayload(item) : {ready: false, reason: "Migration helper missing."};
    if (!built.ready) {
      item.lastError = String(built.reason || "Migration is not ready.");
      item.lastErrorAt = nowISO();
      waiting += 1;
      continue;
    }
    try {
      /* Insert instead of upsert: worklogs only grant INSERT to the
         employee/boss path, and an upsert retry would also require UPDATE.
         A duplicate id means the previous attempt committed server-side,
         so it is safe to finish the local migration. */
      const result = await cloudClient.from("worklogs").insert(built.payload);
      if (result.error) throw new Error(result.error.message || result.error);
      if (typeof completeWorklogMigration === "function") {
        completeWorklogMigration(item);
      }
      migrated += 1;
    } catch (error) {
      const message = String(error.message || error);
      if (/duplicate key|unique constraint|violates.*unique/i.test(message)
          && typeof completeWorklogMigration === "function") {
        completeWorklogMigration(item);
        migrated += 1;
        continue;
      }
      item.lastError = message;
      item.lastErrorAt = nowISO();
      failed.push({
        table: "worklogs", op: "migration", message: message,
      });
    }
  }
  _save();
  return {migrated: migrated, failed: failed, waiting: waiting};
}

async function pushDimensionQueue() {
  if (!cloudClient || !DB.profile) return { pushed: 0, failed: [] };
  if (typeof ensureLocalWorklogMigrationQueues === "function") {
    ensureLocalWorklogMigrationQueues();
  }
  if (!Array.isArray(DB.dimensionQueue)) DB.dimensionQueue = [];
  if (!DB.dimensionQueue.length) return { pushed: 0, failed: [] };
  const pendingMigrations = new Set((DB.worklogMigrationQueue || []).map(
    item => String(item.cloud_id || "")));
  const batch = DB.dimensionQueue.filter(item =>
    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
      .test(String(item.worklog_id || ""))
    && !pendingMigrations.has(String(item.worklog_id || ""))
  ).slice(0, QUEUE_BATCH);
  if (!batch.length) return { pushed: 0, failed: [] };
  const done = [];
  const failed = [];
  for (let i = 0; i < batch.length; i += 1) {
    const item = batch[i];
    try {
      const { data, error } = await cloudClient.rpc("upsert_worklog_dimensions", {
        p_worklog: String(item.worklog_id),
        p_data: item.data || {},
      });
      if (error) throw new Error(error.message || String(error));
      if (data && typeof data === "object" && data.ok === false) {
        throw new Error(data.error || "worklog dimension permission denied");
      }
      done.push(item.worklog_id);
      delete item.lastError;
      delete item.lastErrorAt;
    } catch (error) {
      item.lastError = String(error.message || error);
      item.lastErrorAt = nowISO();
      failed.push({
        table: "worklog_dimensions", op: "rpc",
        message: item.lastError,
      });
    }
  }
  if (done.length) clearDimensionQueue(done);
  _save();
  return { pushed: done.length, failed: failed };
}

async function ensureFreshCloudSession() {
  if (!cloudClient || !DB.profile) return false;
  try {
    const current = await cloudClient.auth.getSession();
    if (current.error) return false;
    const session = current.data && current.data.session;
    if (!session) return false;
    const expiresAt = Number(session.expires_at || 0);
    if (expiresAt && expiresAt - Math.floor(Date.now() / 1000) < 300) {
      const refreshed = await cloudClient.auth.refreshSession();
      return !refreshed.error && !!(refreshed.data && refreshed.data.session);
    }
    return true;
  } catch (error) {
    return false;
  }
}

async function syncNow(reason) {
  /* 已经有同步在跑：等它，而不是返回中间状态 */
  if (syncInFlight) {
    /* 实时事件可能恰好在 pullAll 已查完后到达；若只复用当前 Promise，
       该事件要等下一轮轮询才会出现。保留一次补同步，避免漏掉唤醒。 */
    if (["realtime", "realtime-connected", "visible", "online", "manual",
         "staff-account"].indexOf(String(reason || "")) !== -1) {
      syncAgain = true;
      syncAgainReason = reason;
    }
    return syncInFlight;
  }

  if (!cloudReady() || !DB.profile) return syncStatus();
  if (!initCloud()) {
    DB.lastSync = {
      at: nowISO(), ok: false, pending: pendingCount(),
      message: "云组件没加载上，先跑 node fetch-vendor.js 再打包",
    };
    _save();
    return syncStatus();
  }

  syncInFlight = (async () => {
    syncBusy = 1;
    const sessionFresh = await ensureFreshCloudSession();
    if (!sessionFresh) {
      DB.lastSync = {
        at: nowISO(), ok: false, pending: pendingCount(),
        message: "登录已过期，请重新登录后同步",
      };
      _save();
      emitSync(syncStatus());
      return syncStatus();
    }
    emitSync(syncStatus());
    try {
      syncBusy = 2;
      const pushed = await pushQueue();
      const migrationsPushed = await pushWorklogMigrationQueue();
      const dimensionsPushed = await pushDimensionQueue();

      /* **表建好了就把"没装好"的提示撤掉。**

         `DB.notifyTableMissing` 原来只进不出：某次上传失败设成 true，
         之后永远显示"通知功能没装好"，**哪怕用户早就把 SQL 跑了**。
         用户看到提示还在，会以为没生效——这是真发生过的困惑。

         所以每次同步都顺手验一下：能读到表就说明已经装好了。
         只在标记为 true 时才查，正常情况零开销。 */
      if (DB.notifyTableMissing) await verifyNotifyTable();

      /* **订阅挂了就补上。**

         订阅失败是静默的：状态写成一条异常文字，用户只看到
         "实时推送异常"，而推送永远不恢复——除非重启 App。

         所以每次同步时检查一下：没订阅上就再试一次。
         失败时 subscribeRealtime 自己会 catch，不会影响同步。 */
      if (!realtimeChannel && DB.profile) {
        subscribeRealtime().catch(() => { /* 下次同步再试 */ });
      }

      syncBusy = 3;
      const pulled = await pullAll();
      const changed = typeof pulled === "number" ? pulled : (pulled.changed || 0);

      /* **通知在同步成功之后才处理。**

         失败时处理会把"没拉到数据"误判成"没有新事件"，
         而且下次同步又会重复提醒同一批。 */
      if (typeof pumpNotifications === "function") {
        await pumpNotifications({
          events: pulled && pulled.events ? pulled.events : null,
          worklogs: pulled && pulled.newWorklogs ? pulled.newWorklogs : null,
        });
      }

      /* **上传失败必须如实显示**，不能被"收到几条新数据"盖过去。

         之前有个 bug 就是这样漏掉的：tasks 表缺一列，
         upsert 一直被拒，而界面显示"已同步"——
         用户以为报上去了，老板那边什么都没有。 */
      const uploadFailures = (pushed && pushed.failed ? pushed.failed : [])
        .concat(migrationsPushed && migrationsPushed.failed
          ? migrationsPushed.failed : [])
        .concat(dimensionsPushed && dimensionsPushed.failed
          ? dimensionsPushed.failed : []);
      if (uploadFailures.length) {
        DB.lastSync = {
          at: nowISO(),
          ok: false,
          pending: pendingCount(),
          message: `${uploadFailures.length} 条没传上去：`
            + uploadFailures[0].message,
        };
      } else {
        DB.lastSync = {
          at: nowISO(),
          ok: true,
          pending: pendingCount(),
          message: changed ? `收到 ${changed} 条新数据` : "",
        };
      }
      _save();
    } catch (error) {
      DB.lastSync = {
        at: nowISO(),
        ok: false,
        pending: pendingCount(),
        message: String(error.message || error),
      };
      _save();
    } finally {
      syncBusy = 0;
      syncInFlight = null;
      emitSync(syncStatus());
      if (typeof refreshDecisionCenterIfActive === "function") {
        refreshDecisionCenterIfActive();
      }
      if (syncAgain && DB.profile) {
        const nextReason = syncAgainReason || "queued";
        syncAgain = false;
        syncAgainReason = "";
        setTimeout(() => syncNow(nextReason), 0);
      }
    }
    return syncStatus();
  })();

  return syncInFlight;
}

/* 启动定时同步 + 网络/前后台事件。

   **切回前台立刻同步一次**——手机上 App 长期挂后台时
   定时器会被系统冻结，只靠 30 秒轮询的话，
   用户切回来看到的还是旧数据。 */
function startSyncLoop() {
  stopSyncLoop();
  syncTimer = setInterval(() => syncNow("timer"), SYNC_INTERVAL_MS);

  if (!syncEventsBound && typeof document !== "undefined"
      && document.addEventListener && typeof window !== "undefined"
      && window.addEventListener) {
    document.addEventListener("visibilitychange", () => {
      if (!document.hidden) syncNow("visible");
    });
    window.addEventListener("online", () => syncNow("online"));
    syncEventsBound = true;
  }

  /* **实时订阅：事件一到就立刻同步，不用等轮询。**

     这是"一发就弹窗"的关键。轮询最快也要等 15 秒；
     实时订阅是服务器**主动推**过来，通常 1 秒内就到。

     订阅的是 task_events 表的变更（老板派任务 → assigned，
     员工勾选 → done）。收到推送后调 syncNow 走原来的流程，
     所以通知、红点、提示条全都自动跟上，不用另外写一套。 */
  /* **要 catch**：subscribeRealtime 是 async 的，
     它内部虽然有 try/catch，但 await getSession() 那一步万一
     抛出未预期的错误，没有这个 catch 会变成"未处理的 Promise 拒绝"，
     在某些 WebView 里会直接打断整个同步循环。 */
  subscribeRealtime().catch(error => {
    realtimeState = "订阅异常：" + error.message;
  });
}

function stopSyncLoop() {
  if (syncTimer) { clearInterval(syncTimer); syncTimer = null; }
  unsubscribeRealtime();
}

/* ---------------------------------------------------------- 实时订阅 */

let realtimeChannel = null;
let realtimeRetryTimer = null;

/* 实时连接的状态。**要能看见。**

   为什么必须做成可见的：实时订阅失败是**静默**的——
   订阅回调会说 SUBSCRIBED，但如果不满足条件（比如没带认证令牌、
   服务端没开实时发布），事件会被服务端悄悄过滤掉，
   客户端什么都不报。用户只觉得"还是慢"，根本无从查起。

   所以我记一个状态字符串，界面（「我的」页）能显示出来，
   出问题时一眼看到卡在哪一步。 */
let realtimeState = "未连接";

/* 订阅 task_events 的变更。

   ## 为什么能只收到"和我有关"的行

   Supabase 的实时推送会**应用 RLS 策略**：
   task_events 的读策略是 `boss_id = auth.uid() or employee_id = auth.uid()`，
   所以员工只会收到派给自己的事件，老板只收到自己名下的。

   ## 关键：必须显式带上登录令牌

   服务端判断 `auth.uid()` 靠的是连接上带的 JWT。
   supabase-js 通常会在登录时把令牌同步给 realtime 客户端，
   但那只在"用户对象发生变化"的事件里做——
   **从本机存储恢复会话时不一定触发**。

   结果就是：连接建立了、订阅回调说 SUBSCRIBED、
   但服务端不知道你是谁，RLS 把每一行都过滤掉，
   **一条推送都收不到，而且完全不报错。**

   所以这里显式取一次 access_token 并 setAuth。 */
/* **订阅只能有一个在跑。**

   真机日志里一直在报：

       䅃 订阅失败: cannot add `postgres_changes` callbacks for
          realtime:task-events-<uid> after `subscribe()`.

   原因不是"用法写错"，而是**两次调用重叠了**：

     调用 A：unsubscribeRealtime() → 卡在 await getSession() 上
     调用 B：进来 → unsubscribe（此时 realtimeChannel 还是 null，
             清不掉 A 那个半成品）→ 也走到建通道那一步

   两个调用用**同一个通道名** `task-events-<uid>`，
   supabase-js 按名字返回同一个 channel 对象，
   于是第二个人对**已经订阅过**的通道再 `.on()` → 直接抛错。

   谁会产生两次调用？启动时一次、同步循环里发现没订阅上又补一次，
   两者很容易撞在一起。

   修法：加一个在飞标记，A 没跑完之前 B 直接复用它的 Promise。
   和 syncNow 里的 syncInFlight 是同一套写法。 */
let realtimeInFlight = null;

async function subscribeRealtime() {
  if (realtimeInFlight) return realtimeInFlight;
  realtimeInFlight = subscribeRealtimeOnce();
  try {
    return await realtimeInFlight;
  } finally {
    realtimeInFlight = null;
  }
}

async function subscribeRealtimeOnce() {
  unsubscribeRealtime();

  /* **先把云客户端建起来。**

     原来这里直接检查 `cloudClient`，但它初始是 null，
     只有登录 / sync / 账号操作会调 initCloud() 去建。

     而 subscribeRealtime 是在 startSyncLoop() 里调的——
     时机比那些都早，于是检查失败、状态写成"库不支持"，
     **之后再也没重试**，界面就一直挂着这条异常，
     实时推送等于没开。

     initCloud() 是幂等的，重复调用没有副作用。 */
  if (!initCloud()) {
    realtimeState = "云客户端建不起来";
    return false;
  }

  if (typeof cloudClient === "undefined" || !cloudClient
      || typeof cloudClient.channel !== "function") {
    realtimeState = "库不支持（channel 不可用）";
    return false;
  }
  if (!DB.profile) {
    realtimeState = "未登录";
    return false;
  }

  try {
    /* **① 先把登录令牌交给实时连接。**
       不做这一步的话，服务端不知道你是谁，推什么都过不了 RLS。 */
    try {
      const session = await cloudClient.auth.getSession();
      const token = session && session.data && session.data.session
        ? session.data.session.access_token : null;
      if (token && cloudClient.realtime
          && typeof cloudClient.realtime.setAuth === "function") {
        cloudClient.realtime.setAuth(token);
        realtimeState = "令牌已设置";
      } else {
        realtimeState = "拿不到令牌";
      }
    } catch (error) {
      realtimeState = "取令牌失败：" + error.message;
    }

    const me = DB.profile.id;
    realtimeChannel = cloudClient
      .channel("task-events-" + me)
      .on("postgres_changes",
        { event: "*", schema: "public", table: "task_events" },
        () => {
          /* 收到推送就同步一次。

             **不直接拿推送里的数据**——推送只带这一行，
             而同步要处理"取消完成时撤销工时"这类跨表逻辑。
             重新拉一遍最省心，而且 syncNow 自己有去重，
             连续几条推送不会打出几次重复请求。 */
          realtimeState = "收到推送 " + timeShort();
          syncNow("realtime");
        })
      .subscribe(status => {
        /* 订阅状态回调。SUBSCRIBED 才算真的连上。
           CHANNEL_ERROR / TIMED_OUT 要能看出来。 */
        realtimeState = "订阅：" + status + " " + timeShort();
        if (status === "SUBSCRIBED") {
          if (realtimeRetryTimer) {
            clearTimeout(realtimeRetryTimer);
            realtimeRetryTimer = null;
          }
          /* 初次连接和断线重连后都补拉一次，弥补 WebSocket 离线期间的事件。 */
          syncNow("realtime-connected");
        } else if (status === "CHANNEL_ERROR" || status === "TIMED_OUT"
            || status === "CLOSED") {
          /* channel 对象存在不代表连接还活着；原逻辑只在 null 时重试，
             因此断线后会永久退化成慢轮询，直到用户重启 App。 */
          if (realtimeRetryTimer) clearTimeout(realtimeRetryTimer);
          realtimeRetryTimer = setTimeout(() => {
            realtimeRetryTimer = null;
            if (DB.profile) {
              subscribeRealtime().catch(() => { /* 下一次心跳再试 */ });
            }
          }, 3000);
        }
      });

    if (!realtimeState || realtimeState === "令牌已设置") {
      realtimeState = "正在连接 " + timeShort();
    }
    return true;
  } catch (error) {
    /* 订阅不上就靠轮询，功能不受影响——但要让界面能说出来 */
    realtimeChannel = null;
    realtimeState = "订阅失败：" + error.message;
    return false;
  }
}

function timeShort() {
  const now = new Date();
  const pad = value => (value < 10 ? "0" : "") + value;
  return pad(now.getHours()) + ":" + pad(now.getMinutes())
    + ":" + pad(now.getSeconds());
}

function unsubscribeRealtime() {
  if (realtimeRetryTimer) {
    clearTimeout(realtimeRetryTimer);
    realtimeRetryTimer = null;
  }
  if (!realtimeChannel) return;
  try {
    cloudClient.removeChannel(realtimeChannel);
  } catch (error) {
    /* 关不掉也无所谓，下次订阅会覆盖 */
  }
  realtimeChannel = null;
}

/* =============================================================
   任务与工时：员工的勾选流程
   ============================================================= */

/* 员工勾选"完成"。

   本地立刻写 + 进队列（界面马上响应），然后**尝试**上传。
   上传失败不影响本地——记录已经在队列里，联网自动补传。

   ## 一个踩过的坑：id 必须是合法的 uuid

   我原来用 `task.id + "_" + date` 当 id，想表达"同一条任务同一天
   只有一条记录"。**但服务端的 id 列是 uuid 类型**，
   "0f8a…-…_2026-10-09" 这种 47 个字符的串直接被拒绝，
   表现是队列卡住两条永远传不上去，老板收不到工时。

   **"同一天只有一条"这件事应该由服务端的唯一约束保证**
   （建表时的 `unique (task_id, finish_date)`），
   而不是靠拼 id。本地要去重就单独查，别把它编进 id 里。 */
function completeTask(task, hours) {
  const profile = DB.profile;
  if (!profile) throw new Error("还没登录");
  if (!task) throw new Error("这条任务已经不存在了");

  const now = nowISO();
  const date = todayISO();

  /* 本地去重：同一条任务同一天只留一条 */
  if (!Array.isArray(DB.taskLogs)) DB.taskLogs = [];
  const existing = DB.taskLogs.find(item =>
    String(item.task_id) === String(task.id) && item.finish_date === date);
  if (existing) {
    /* 已经勾过了。重复勾选不产生新记录——服务端也有唯一约束兜着。 */
    return existing;
  }

  const log = {
    id: uuid(),
    task_id: task.id,
    employee_id: profile.id,
    started_at: task.started_at || null,
    finished_at: now,
    finish_date: date,
  };
  DB.taskLogs.push(log);

  /* 工时：优先用实际耗时，其次用任务的预估工时 */
  let worked = num(hours);
  if (!worked && task.started_at) {
    const started = parseDate(task.started_at);
    if (started) worked = Math.max(0.1, (Date.now() - started.getTime()) / 3600000);
  }
  if (!worked) worked = num(task.est_hours);
  if (!worked) worked = 1;                  // 最后的兜底：算 1 小时
  worked = Math.round(worked * 100) / 100;

  const worklog = {
    id: uuid(),
    boss_id: task.boss_id,
    employee_id: profile.id,
    enterprise_id: task.enterprise_id || currentEnterpriseId(),
    task_id: task.id,
    work_date: date,
    hours: worked,
    content: task.title,
    project_name: task.project_name || "",
    source: "task",
    billable: true,
    overtime: false,
    work_kind: "project",
    rework: false,
    waiting: false,
    travel: false,
  };

  queueChange("task_logs", "insert", log.id, log);
  queueChange("worklogs", "insert", worklog.id, worklog);
  if (typeof queueWorklogDimensions === "function") {
    queueWorklogDimensions(worklog.id, worklog);
  }

  /* 记一条"完成"事件。

     **为什么单独记事件，不靠服务端 diff task_logs**：
     "完成了"能从 task_logs 推出来，但"取消完成"推不出来——
     那一行是被删掉的，客户端分不清"被删了"和"我还没拉到"。
     所以完成和取消都写成显式事件，老板端才有得拉。 */
  queueChange("task_events", "insert", uuid(), {
    boss_id: task.boss_id,
    employee_id: profile.id,
    task_id: task.id,
    kind: "done",
    title: task.title,
    hours: worked,
    work_date: date,
  });

  _save();

  /* 不等结果——界面已经更新了，上传在后台进行 */
  syncNow("task-complete");
  return log;
}

/* 取消勾选。本地删掉，同时排一个删除任务。

   删除要用**真实的 id**（uuid），不能用"任务+日期"拼出来——
   拼出来的 id 服务端根本没有，删不掉。所以先按 task_id + 日期
   把记录找出来，拿到它的 id 再删。 */
function uncompleteTask(taskId) {
  const date = todayISO();
  if (!Array.isArray(DB.taskLogs)) return false;
  const log = DB.taskLogs.find(item =>
    String(item.task_id) === String(taskId) && item.finish_date === date);
  if (!log) return false;

  DB.taskLogs = DB.taskLogs.filter(item => item.id !== log.id);

  /* 对应的工时记录也找出来一起删。
     按 task_id 匹配（本地和云端都用这个字段关联）。 */
  const worklog = (DB.remoteWorklogs || []).find(item =>
    String(item.task_id) === String(taskId) && item.work_date === date)
    || (DB.cloudWorklogIndex || {})[taskId];

  queueChange("task_logs", "delete", log.id, {});
  if (worklog && worklog.id) {
    queueChange("worklogs", "delete", worklog.id, {});
    if (typeof removeQueuedWorklogDimensions === "function") {
      removeQueuedWorklogDimensions(worklog.id);
    }
  }

  /* 记一条"取消完成"事件。

     **这条是通知功能里唯一必须显式记录的东西**：
     取消完成之后 task_logs 和 worklogs 里那一行就没了，
     老板端只靠拉数据**看不出"曾经有、现在被撤了"**——
     它分不清"被删了"和"我还没拉到"。

     所以取消也要写成事件。老板端拉到 kind='undone'
     就知道该把工时撤掉并提醒老板。

     boss_id 必须是**任务的老板**。而员工端 DB.profile 是员工自己，
     所以要读 profile.boss_id（建号时服务端设的归属）。 */
  const task = taskById(taskId)
    || (DB.tasks || []).find(item => String(item.id) === String(taskId));
  const profile = DB.profile;
  const bossId = (task && task.boss_id)
    || (profile && profile.boss_id) || null;
  if (!bossId) {
    /* 没有 boss_id 的话事件写不进（那一列是 not null）。
       宁可在这里说清楚，也不要静默丢一条事件。 */
    throw new Error("不知道这条任务属于哪个老板，取消完成没法上报");
  }
  queueChange("task_events", "insert", uuid(), {
    boss_id: bossId,
    employee_id: profile ? profile.id : null,
    task_id: taskId,
    kind: "undone",
    title: (task && task.title) || "",
    work_date: date,
  });

  _save();
  syncNow("task-uncomplete");
  return true;
}

/* 员工点"开始"。只记时间，不产生工时记录。 */
function startTask(taskId) {
  const task = taskById(taskId);
  if (!task) throw new Error("这条任务已经不存在了");
  task.started_at = nowISO();
  _save();
  return task.started_at;
}

/* ---------------------------------------------------------- 接受 / 延期

   ## 为什么这几个动作走 RPC 而不走 syncQueue

   其余的写入（工时、勾选）都是"我自己的数据"，可以离线攒着，
   联网再按队列补传。

   但"接受任务"和"申请延期"是**给对方看的动作**：
   攒在本地队列里没意义——对方看不到就等于没做。所以直接调
   服务端函数，成功才算数，失败立刻告诉用户。

   服务端函数负责三件客户端做不了的事：
     1. 校验"你确实是这条任务的负责人"（tasks 表员工只有读权限）
     2. 精确只改允许改的那几列
     3. 顺手记一条 task_events 让对方收到通知

   见 sql/task-accept-extension.sql。 */

/* 调 RPC 的公共壳子：统一把英文错误翻成中文 */
async function callTaskRpc(name, args) {
  if (!initCloud()) {
    throw new Error("没连上云端，检查一下网络再试");
  }
  const { data, error } = await cloudClient.rpc(name, args);
  if (error) {
    const text = String(error.message || "");
    if (/not signed in/i.test(text)) {
      throw new Error("登录状态过期了，重新登录一次");
    }
    if (/task not found/i.test(text)) {
      throw new Error("这条任务已经不存在了（可能被老板删了）");
    }
    if (/only the assignee/i.test(text)) {
      throw new Error("这条任务不是派给你的，操作不了");
    }
    if (/only the boss/i.test(text)) {
      throw new Error("只有派这条任务的老板能审批");
    }
    if (/reason required/i.test(text)) {
      throw new Error("必须写原因");
    }
    if (/new date must be later/i.test(text)) {
      throw new Error("新日期必须晚于原计划日期");
    }
    if (/already decided/i.test(text)) {
      throw new Error("这条申请已经处理过了");
    }
    if (/Could not find the function|does not exist/i.test(text)) {
      throw new Error("云端还没装这个功能。\n\n"
        + "去 Supabase SQL Editor 跑一遍 sql/task-accept-extension.sql");
    }
    throw new Error(text || "操作失败");
  }
  return data || {};
}

/* 员工：接受或拒绝一条任务。拒绝必须带原因。 */
async function setTaskAccept(taskId, accepted, reason) {
  const task = taskById(taskId);
  if (!task) throw new Error("这条任务已经不存在了");
  if (!accepted && !String(reason || "").trim()) {
    throw new Error("不接受任务要写原因");
  }

  const result = await callTaskRpc("accept_task", {
    p_task_id: taskId,
    p_accept: !!accepted,
    p_reason: String(reason || "").trim(),
  });

  /* 服务端已经改了，本地立刻跟上——不用等下一次同步。
     万一本地写失败，下次同步也会从服务端拉回来，不会不一致。 */
  task.accept_status = accepted ? "accepted" : "rejected";
  task.accept_reason = accepted ? "" : String(reason || "").trim();
  task.accept_at = nowISO();
  _save();
  return result;
}

/* 员工：申请把任务挪到新日期 */
async function requestTaskExtension(taskId, toDate, reason) {
  const task = taskById(taskId);
  if (!task) throw new Error("这条任务已经不存在了");
  if (!String(reason || "").trim()) throw new Error("要写申请延期的原因");
  if (!toDate) throw new Error("要选一个新日期");
  if (String(toDate) <= String(task.plan_date)) {
    throw new Error("新日期必须晚于原计划日期（" + task.plan_date + "）");
  }

  const result = await callTaskRpc("request_task_extension", {
    p_task_id: taskId,
    p_to_date: toDate,
    p_reason: String(reason || "").trim(),
  });

  /* 本地先插一条 pending，让界面立刻显示"等老板批"。
     服务端返回的 request_id 用它当 id，下次同步会覆盖成真实行。 */
  if (!Array.isArray(DB.taskRequests)) DB.taskRequests = [];
  const id = result.request_id || ("local-" + Date.now());
  const existing = DB.taskRequests.find(item => item.id === id);
  const row = {
    id: id,
    boss_id: task.boss_id,
    employee_id: task.employee_id,
    task_id: taskId,
    kind: "extension",
    reason: String(reason || "").trim(),
    to_date: toDate,
    status: "pending",
    created_at: nowISO(),
  };
  if (existing) Object.assign(existing, row);
  else DB.taskRequests.push(row);
  _save();
  return result;
}

/* 老板：批准或驳回一条延期申请 */
async function decideTaskExtension(requestId, approved, note) {
  const result = await callTaskRpc("decide_task_extension", {
    p_request_id: requestId,
    p_approved: !!approved,
    p_note: String(note || "").trim(),
  });

  /* 本地同步状态。批准时任务日期也一起改，不然老板这边
     要等下一次同步才看到任务挪走。 */
  const req = (DB.taskRequests || []).find(item =>
    String(item.id) === String(requestId));
  if (req) {
    req.status = approved ? "approved" : "rejected";
    req.decision_note = String(note || "").trim();
    req.decided_at = nowISO();
  }
  if (approved && req) {
    const task = taskById(req.task_id);
    if (task && req.to_date) {
      task.plan_date = String(req.to_date).slice(0, 10);
      task.updated_at = nowISO();
    }
  }
  _save();
  return result;
}

/* 老板：给一条已完成的任务打分，自动发源点。

   走数据库函数 grade_task（见 sql/task-grade.sql）：
     · 只有任务的老板本人能打
     · 任务必须有完成记录（task_logs），不能给没干的活发分
     · 只能打一次 —— 想改就手动加减，避免重复发钱

   分数怎么算（倍率在 merit.js 的 MERIT.grade）：
     S 超预期 ×1.2 / A 符合预期 ×1.0 / B 有瑕疵 ×0.8 / C 不合格 ×0
     基数 = 预估小时 × 汇率，小时数在服务端被夹到 0~24
     （库里有 500 小时的脏数据，不夹的话一个手滑就能发出去几千分）。 */
async function gradeTask(taskId, grade) {
  let result;
  try {
    result = await callTaskRpc("grade_task", {
      p_task: taskId,
      p_grade: String(grade || "").toUpperCase(),
    });
  } catch (error) {
    /* callTaskRpc 只认识延期/接受那几类报错，验收的几种要在这里翻。
       不翻的话用户会看到英文 already graded。 */
    throw new Error(translateGradeError(error.message));
  }

  /* 本地立刻更新任务上的评级，不用等下一轮同步 */
  const task = taskById(taskId);
  if (task) {
    task.grade = String(grade || "").toUpperCase();
    task.merit_awarded = result && result.amount !== undefined
      ? num(result.amount) : task.merit_awarded;
    task.graded_at = nowISO();
  }

  /* 同样不本地插流水（会和服务端那条重复），改为立刻拉一次 */
  _save();

  try {
    if (typeof pullAll === "function") await pullAll();
  } catch (error) {
    /* 拉不到不影响任务已经打完分，下次同步会补 */
  }

  return result;
}

/* 打分失败的提示要说清楚卡在哪一步 */
function translateGradeError(message) {
  const text = String(message || "");
  if (/already graded/i.test(text)) {
    return "这条任务已经验收过了。\n\n要调整源点，去「我的」手动加减。";
  }
  if (/not finished yet/i.test(text)) {
    return "员工还没点「完成」，暂时不能验收。";
  }
  if (/not your task/i.test(text)) {
    return "这条任务不是你派的。";
  }
  if (/no such task/i.test(text)) {
    return "这条任务已经不存在了。";
  }
  return text;
}

/* ---------------------------------------------------------- 上下工 */

/* 现在有没有在干活。有就返回那条记录。 */
function openWorkSession() {
  const list = Array.isArray(DB.workSessions) ? DB.workSessions : [];
  return list.find(row =>
    String(row.profile_id) === String(DB.profile && DB.profile.id)
    && !row.ended_at) || null;
}

function currentEnterpriseId() {
  return String(
    DB.company_scope_id
    || (DB.identity && DB.identity.enterprise && DB.identity.enterprise.id)
    || (DB.profile && DB.profile.active_enterprise_id)
    || ""
  );
}

function currentEnterpriseOwnerId() {
  const state = DB.identity && DB.identity.enterprise;
  if (state && state.owner_profile_id) return String(state.owner_profile_id);
  if (typeof identityOwnerId === "function") {
    const owner = identityOwnerId();
    if (owner) return String(owner);
  }
  return DB.profile ? String(DB.profile.id || "") : "";
}

async function startWork(taskId) {
  const enterpriseId = currentEnterpriseId();
  const result = await callTaskRpc("start_work", {
    p_task: taskId || null,
    p_enterprise: enterpriseId,
  });
  if (!Array.isArray(DB.workSessions)) DB.workSessions = [];
  const now = nowISO();
  DB.workSessions.unshift({
    id: result && result.id ? result.id : "local-" + now,
    boss_id: currentEnterpriseOwnerId(),
    profile_id: DB.profile ? DB.profile.id : null,
    enterprise_id: enterpriseId,
    task_id: taskId || null,
    started_at: (result && result.started_at) || now,
    ended_at: null,
    hours: null,
    created_at: now,
  });
  _save();
  return result;
}

async function stopWork() {
  const open = openWorkSession();
  const result = await callTaskRpc("end_work", {
    p_enterprise: currentEnterpriseId(),
  });
  if (open) {
    open.ended_at = nowISO();
    open.hours = result && result.hours !== undefined
      ? num(result.hours) : open.hours;
  }

  /* **不要在这里本地插一条流水。**

     试过：收工时先在本地记一笔 +20，界面立刻好看。
     但服务端也会写一笔，两边的 id 不一样（本地是
     local-hours-xxx，服务端是随机 uuid），下一轮同步拉回来
     **两条并存 → 同一次工作算了两遍钱**。

     正确做法：让服务端写，然后立刻拉一次（下面）。 */
  _save();

  /* **再拉一次云端。**

     服务端收工时会写一条工时记录，但工时的 id 是它生成的，
     本地拼不出来。不拉的话，"工时"列表要等下一轮同步（最长
     30 秒）才出现这一条 —— 用户刚收工就看，会以为没记上。 */
  try {
    if (typeof pullAll === "function") await pullAll();
  } catch (error) {
    /* 拉不到不影响本地已经记下的会话和源点，下次同步会补 */
  }

  return result;
}

/* ---------------------------------------------------------- 商城 */

async function addReward(title, cost, detail) {
  const result = await callTaskRpc("add_reward", {
    p_title: String(title || "").trim(),
    p_cost: Math.round(num(cost)),
    p_detail: String(detail || "").trim(),
  });
  await pullAll();
  return result;
}

async function setRewardActive(rewardId, active) {
  const result = await callTaskRpc("set_reward_active", {
    p_reward: rewardId, p_active: !!active,
  });
  const row = (DB.rewards || []).find(item => String(item.id) === String(rewardId));
  if (row) row.active = !!active;
  _save();
  return result;
}

async function redeemReward(rewardId) {
  const result = await callTaskRpc("redeem_reward", { p_reward: rewardId });
  await pullAll();
  return result;
}

async function decideRedemption(redemptionId, given) {
  const result = await callTaskRpc("decide_redemption", {
    p_redemption: redemptionId, p_given: !!given,
  });
  const row = (DB.redemptions || []).find(item =>
    String(item.id) === String(redemptionId));
  if (row) {
    row.status = given ? "given" : "rejected";
    row.decided_at = nowISO();
  }
  _save();
  return result;
}

/* ---------------------------------------------------------- 请假 */

async function requestLeave(fromDate, toDate, reason) {
  const result = await callTaskRpc("request_leave", {
    p_from: fromDate,
    p_to: toDate,
    p_reason: String(reason || "").trim(),
  });
  await pullAll();
  return result;
}

async function decideLeave(leaveId, approved, note) {
  const result = await callTaskRpc("decide_leave", {
    p_leave: leaveId,
    p_approved: !!approved,
    p_note: String(note || "").trim(),
  });
  const row = (DB.leaves || []).find(item => String(item.id) === String(leaveId));
  if (row) {
    row.status = approved ? "approved" : "rejected";
    row.decided_at = nowISO();
    row.decision_note = String(note || "").trim();
  }
  _save();
  return result;
}

/* ---------------------------------------------------------- 老板端 */

/* 老板创建员工账号。

   ## 一次调用搞定

   走数据库函数 `create_staff_account`（见 sql/create-staff-rpc.sql）。
   那个函数是 SECURITY DEFINER，以数据库属主身份运行，
   所以能写 auth.users —— 而 service_role key 始终留在数据库里，
   客户端看不到。

   **不再需要去 Supabase 后台建号、也不需要"同步账号"那一步**：
   函数建完号直接把 boss_id 设成当前老板，员工立刻就能登录、
   立刻能看到派给自己的任务。

   ## 为什么不用 signUp

   Supabase 的 `auth.signUp()` 会把当前会话换成新注册那个账号，
   老板建完一个员工就被登出了。 */
async function createEmployeeLocal(data) {
  const name = String(data.name || "").trim();
  const code = String(data.code || "").trim();
  const email = String(data.email || "").trim().toLowerCase();

  if (!name) throw new Error("员工姓名不能为空");
  if (!code) throw new Error("员工号不能为空");
  if (!/^[a-zA-Z0-9._-]{3,20}$/.test(code)) {
    throw new Error("员工号只能用字母数字和 . _ -，长度 3~20 位");
  }
  if (!email) throw new Error("请填邮箱（员工忘了密码时靠它收回验证码）");
  {
    const badEmail = checkEmail(email);
    if (badEmail) throw new Error(badEmail);
  }
  if (String(data.password || "").length < 6) {
    throw new Error("密码至少要 6 位");
  }

  const profile = DB.profile;
  if (!profile || profile.role !== "boss") {
    throw new Error("只有老板能创建员工账号");
  }
  /* 本地也查一遍重名，省得等一个网络往返才报错 */
  if (staffAccounts().some(item =>
      String(item.code).toLowerCase() === code.toLowerCase())) {
    throw new Error("员工号 " + code + " 已经被用了");
  }

  /* 先把员工记录建在本地。
     这样即使网络断了，人员名单也是完整的，任务可以先派好，
     等联网再建云端账号。 */
  const employee = addEmployee({
    name: name,
    role: data.role || "",
    level: data.level || "",
    weekly_hours: data.weekly_hours || 40,
  });

  const account = {
    id: "local_" + employee.id,
    code: code,
    name: name,
    email: email,
    password: String(data.password),
    employee_id: employee.id,
    pending: true,
    created_at: nowISO(),
  };
  DB.staffAccounts.push(account);
  _save();

  /* 然后就建云端账号。 */
  await createCloudStaff(account);
  return account;
}

/* 在云端真正创建账号。

   失败不抛异常——本地记录已经建好了，标记 pending 就行，
   界面上显示"待创建"，联网后再点一次。
   **不抛的原因是**：老板在没网的时候也需要能把人员名单录进去。 */
async function createCloudStaff(account) {
  if (!cloudReady() || !DB.profile) {
    account.lastError = "还没登录云服务，账号只在本地";
    _save();
    return false;
  }
  if (!initCloud()) {
    account.lastError = "云组件没加载上";
    _save();
    return false;
  }

  try {
    const result = await cloudClient.rpc("create_staff_account", {
      p_code: account.code,
      p_password: account.password,
      p_name: account.name,
      p_email: account.email || null,
    });
    if (result.error) throw new Error(translateBossError(result.error.message));

    const payload = result.data || {};
    if (!payload.ok || !payload.id) {
      throw new Error("服务端没有返回账号 id");
    }

    /* 关键：把本地员工的 id 换成云端 uuid。

       员工报上来的工时里 employee_id 是云端 uuid，
       本地员工用的是自增整数。两边不统一的话，
       负荷统计找不到对应员工，员工报的工时会"消失"。 */
    const oldId = account.employee_id;
    const employee = (DB.employees || []).find(item =>
      String(item.id) === String(oldId));
    if (employee) {
      employee.id = payload.id;
      employee.cloud_id = payload.id;
      /* 本地所有引用这个旧 id 的地方都改过来 */
      (DB.worklogs || []).forEach(log => {
        if (String(log.employee_id) === String(oldId)) log.employee_id = payload.id;
      });
      (DB.assignments || []).forEach(item => {
        if (String(item.employee_id) === String(oldId)) item.employee_id = payload.id;
      });
      (DB.habits || []).forEach(item => {
        if (String(item.employee_id) === String(oldId)) item.employee_id = payload.id;
      });
    }
    account.employee_id = payload.id;
    account.cloud_id = payload.id;
    account.pending = false;
    delete account.lastError;
    if (payload.already_existed) {
      account.lastNote = "云端已经有这个员工号了";
    }
    if (typeof ensureLocalWorklogMigrationQueues === "function") {
      ensureLocalWorklogMigrationQueues();
    }
    _save();
    syncNow("staff-account");
    return true;
  } catch (error) {
    /* 把数据库的英文报错转成能看懂的说明 */
    account.lastError = translateStaffError(error.message);
    account.pending = true;
    _save();
    return false;
  }
}

/* 数据库函数抛的英文错误 → 中文提示。
   直接用原文的话，老板看到 "code may only contain letters..."
   不知道该怎么办。 */
function translateStaffError(message) {
  const text = String(message || "");
  if (/code may only contain/i.test(text)) {
    return "员工号只能用字母、数字和 . _ -，长度 3~20 位";
  }
  if (/password must be at least/i.test(text)) {
    return "密码至少要 6 位";
  }
  if (/only a boss/i.test(text)) {
    return "只有老板能创建员工账号";
  }
  if (/not signed in/i.test(text)) {
    return "登录状态过期了，重新登录一次";
  }
  if (/Could not find the function|does not exist/i.test(text)) {
    /* 指向整合后的那个文件。原来写的是 create-staff-rpc.sql，
       但那个函数现在也在 migrate-notify.sql 里重新定义了一遍
       （带去重和孤儿接管），所以让用户跑后者更准。 */
    return "云端的建号功能还没装。"
      + "去 Supabase SQL Editor 跑一遍 sql/migrate-notify.sql";
  }
  return text;
}

/* 重试所有还没建成功的账号。老板在账号页点一下就行。 */
async function retryPendingStaff() {
  const list = staffAccounts().filter(item => item.pending);
  let done = 0;
  const failures = [];
  for (let i = 0; i < list.length; i += 1) {
    const ok = await createCloudStaff(list[i]);
    if (ok) done += 1;
    else failures.push(list[i].code + "：" + (list[i].lastError || "未知原因"));
  }
  return { done: done, total: list.length, failures: failures };
}

function staffAccounts() {
  return Array.isArray(DB.staffAccounts) ? DB.staffAccounts : [];
}

/* 老板派发任务 */
function assignTask(data) {
  const profile = DB.profile;
  if (!profile || profile.role !== "boss") {
    throw new Error("只有老板能派任务");
  }
  const title = String(data.title || "").trim();
  if (!title) throw new Error("任务内容不能为空");
  if (!data.employee_id) throw new Error("要选一个员工");

  /* **先查格式，再查名单。**

     顺序不能反：
       · 格式不对（本地自增数字 "7"）→ 说"还没建云端账号"最准确
       · 格式对但不在名单里 → 说明选中的值失效了，让重选
     反过来的话，那种"还没建号的员工"会被报成"不在名单里"，
     用户按提示去重选，但问题其实是号没建好——**指错了方向**。 */
  const employeeId = String(data.employee_id);
  const account = staffAccounts().find(item =>
    String(item.employee_id) === employeeId);

  if (!UUID_PATTERN.test(employeeId)) {
    const reason = account && account.lastError
      ? "：" + account.lastError
      : "（还没有在云端建号）";
    throw new Error("这个员工还没有云端账号，派不了任务" + reason
      + "\n\n去「团队 → 员工账号」点「重试创建」，建好再派。");
  }
  if (!account) {
    throw new Error("选中的这个员工不在名单里，可能名单刚刷新过。\n\n"
      + "请重新选一次「派给谁」。");
  }

  const task = {
    /* 用 uuid 而不是本地自增 id：两台手机会算出相同的自增数字，
       撞在一起就会把别人的任务覆盖掉。 */
    id: uuid(),
    boss_id: profile.id,
    employee_id: employeeId,
    title: title,
    detail: String(data.detail || ""),
    plan_date: data.plan_date || todayISO(),
    est_hours: num(data.est_hours),
    project_name: String(data.project_name || ""),
    step_name: String(data.step_name || ""),
    created_at: nowISO(),
    updated_at: nowISO(),
  };
  if (!Array.isArray(DB.tasks)) DB.tasks = [];
  DB.tasks.push(task);
  queueChange("tasks", "insert", task.id, task);
  /* **"派了新任务"这条事件不在这里写。**

     服务端 tasks 表上有个 after insert 触发器
     （见 sql/migrate-notify.sql 的 trg_task_assigned），
     插入任务时自动记一条 kind='assigned' 的事件。

     为什么放服务端：那样**任何建任务的路径都会产生事件**——
     App、脚本、直接在后台手写 insert。放在客户端就多一处会忘。 */
  _save();
  syncNow("assign");
  return task;
}

function deleteTask(taskId) {
  const before = (DB.tasks || []).length;
  DB.tasks = (DB.tasks || []).filter(item => String(item.id) !== String(taskId));
  if (DB.tasks.length === before) return false;
  queueChange("tasks", "delete", taskId, {});
  _save();
  syncNow("task-delete");
  return true;
}

/* 本机生成 uuid。优先用 crypto.randomUUID（安卓 WebView 支持），
   没有就退回手写版本——不能因为缺一个 API 就崩掉。 */
function uuid() {
  if (typeof crypto !== "undefined" && crypto.randomUUID) {
    const generated = String(crypto.randomUUID() || "");
    if (UUID_PATTERN.test(generated)) return generated;
  }
  return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, ch => {
    const rand = Math.random() * 16 | 0;
    const value = ch === "x" ? rand : ((rand & 0x3) | 0x8);
    return value.toString(16);
  });
}

/* ---------------------------------------------------------- 汇总 */
/* 本地自己记的 + 员工报上来的 = 全部工时。

   **委托给 worklogsFor({includeRemote: true})**，不在这里自己拼一遍。
   两处各写一套的话，将来改字段名或来源标记时很容易漏掉一处，
   表现就是"同一个数字在两个页面显示得不一样"。 */
function allWorklogs() {
  return worklogsFor({ includeRemote: true });
}

/* =============================================================
   老板自助注册
   ============================================================= */

/* 创建一个老板账号。

   ## 每个老板都能建，各自独立

   之前是"只能有一个老板，先到先得"——那个设计是错的：
   你要的是**每个老板都能自己建账号，互相看不到对方的人和数据**。

   数据隔离靠的是 RLS：tasks / task_logs / worklogs 全都按
   `boss_id = auth.uid()` 判断，所以两个老板天然互不可见。
   每个老板建的员工，boss_id 都指向他自己。

   ## 重名怎么办

   两个老板可能都想用同一个手机号当登录名。这时**不拒绝**，
   而是在后面加个数字（`19155025818-2`），并把**最终的名字返回**，
   让界面告诉用户"你的登录名是这个"。

   这一点很重要：如果只是静默改名，用户下次登录会发现自己
   记的名字登不上。 */
async function registerBoss(data) {
  const name = String(data.name || "").trim();
  const code = String(data.phone || "").trim();
  const email = String(data.email || "").trim().toLowerCase();

  if (!name) throw new Error("请填姓名（或者一个称呼）");
  if (!code) throw new Error("请填账号");
  if (!/^[a-zA-Z0-9._-]{3,20}$/.test(code)) {
    throw new Error("账号只能用字母数字和 . _ -，长度 3~20 位");
  }
  if (String(data.password || "").length < 6) {
    throw new Error("密码至少要 6 位");
  }
  if (!email) throw new Error("请填邮箱（忘了密码时靠它收回验证码）");
  {
    const badEmail = checkEmail(email);
    if (badEmail) throw new Error(badEmail);
  }
  if (!initCloud()) throw new Error("云组件没加载上，检查一下网络");

  let result = await cloudClient.rpc("create_boss_account", {
    p_code: code,
    p_password: String(data.password),
    p_name: name,
    p_email: email,
  });
  const firstMessage = String(result.error && result.error.message || result.error || "");
  if (result.error && /failed to fetch|networkerror|load failed|network request failed|fetch failed/i.test(firstMessage)) {
    await new Promise(resolve => setTimeout(resolve, 900));
    result = await cloudClient.rpc("create_boss_account", {
      p_code: code,
      p_password: String(data.password),
      p_name: name,
      p_email: email,
    });
  }
  if (result.error) throw new Error(translateBossError(result.error.message));

  const payload = result.data || {};

  /* 注册完直接登录。**fresh: true** —— 刚建好的账号
     GoTrue 偶尔还没认到，允许它多试一次。 */
  const profile = await cloudLogin(email, data.password, { fresh: true });

  return {
    profile: profile,
    code: payload.code || code,
    email: email,
    /* 现在不会改名了，这个字段留着是为了兼容旧调用方 */
    renamed: false,
  };
}

/* 注册相关的英文报错 → 中文说明 */
function translateBossError(message) {
  const text = String(message || "");
  if (/code may only contain/i.test(text)) {
    return "账号只能用字母、数字和 . _ -，长度 3~20 位";
  }
  if (/password must be at least/i.test(text)) {
    return "密码至少要 6 位";
  }
  /* **这个号已经注册过了。**

     以前服务端会自动加 -2 -3 后缀再建一个新号，
     于是同一个号码能注册出五六个账号，用户完全不知道
     该用哪个登录。现在直接拒绝，并告诉下一步该干嘛。 */
  if (/code already registered/i.test(text)) {
    return "这个账号已经被注册过了。\n\n"
      + "直接登录就行；忘了密码就点「忘了密码」用邮箱收验证码。";
  }
  if (/email already registered/i.test(text)) {
    return "这个邮箱已经绑定过别的账号了，换一个邮箱。";
  }
  if (/email looks invalid/i.test(text)) {
    return "邮箱格式不对";
  }
  if (/too many accounts/i.test(text)) {
    return "这个账号被太多次用过了，换一个吧";
  }
  if (/failed to fetch|networkerror|load failed|network request failed|fetch failed/i.test(text)) {
    return "手机连不上云服务器。\n\n"
      + "请先切换 Wi-Fi / 手机流量后重试；如果仍然失败，用手机浏览器打开 "
      + "https://edchntmyqqjqvpngylgc.supabase.co/rest/v1/ 。"
      + "打不开说明当前网络屏蔽了 Supabase，需要换网络或使用网络加速服务。";
  }
  if (/Could not find the function|does not exist/i.test(text)) {
    return "云端的注册功能还没装。\n\n"
      + "去 Supabase 的 SQL Editor 跑一遍 sql/login-rework.sql";
  }
  return text;
}
