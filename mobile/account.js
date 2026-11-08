/* =============================================================
   账号界面

   三块东西：
     1. 登录页       —— 账号 + 密码（账号不区分老板和员工）
     2. 员工任务页   —— 今日任务，勾选即上报
     3. 账号管理     —— 老板建员工账号、派任务

   ## 设计原则

   **没登录也能用本机的功能**。所以登录页上有一个
   「先不登录，只用本机功能」——否则老用户升级后
   会被一个用不上的登录页挡在外面，本机数据还在却打不开。

   登录状态存在本地（DB.profile），所以**离线也能进主界面**：
   没网时不能把人挡在门外。
   ============================================================= */
"use strict";

/* ---------------------------------------------------------- 登录页 */

/* 当前选的是哪一边。**只影响下面那个标签叫什么**：
     老板 → 「账号」
     员工 → 「员工号」

   登录本身不依赖它：服务端会核对这个账号名和密码（login_email），
   所以点错了也照样能登进去 —— 这个选择只是让用户看清自己该填什么。 */
let loginRole = "boss";

function renderLogin() {
  /* 身份切换按钮：**在渲染时就绑定**，不依赖 bindGlobalEvents。
     否则一旦登录页被重画、或者启动顺序变了，按钮就成了死按钮。 */
  const roleBox = $("login-role");
  if (roleBox) {
    const buttons = roleBox.querySelectorAll("[data-role]");
    buttons.forEach(button => {
      let handled = false;
      const pick = event => {
        if (event) event.preventDefault();
        handled = true;
        loginRole = button.dataset.role;
        renderLogin();
      };
      button.onpointerdown = pick;
      button.onclick = event => {
        if (handled) { handled = false; return; }
        pick(event);
      };
    });
    buttons.forEach(button => {
      button.classList.toggle("on", button.dataset.role === loginRole);
    });
  }

  /* 标签跟着身份变：老板填账号，员工填员工号 */
  const codeLabel = $("login-code-label");
  if (codeLabel) {
    codeLabel.textContent = loginRole === "boss" ? "账号" : "员工号";
  }

  const config = syncStatus();
  const box = $("login-cloud");
  if (!config.hasLibrary) {
    /* 这个必须说——云库没打包进去，谁都登不上 */
    box.innerHTML = '<div class="banner warn">云组件没加载上。'
      + '先跑 <b>node fetch-vendor.js</b> 下载，然后重新打包。</div>';
  } else if (!config.configured) {
    /* **没配好时也要说，但不再提"点下面云服务设置"**——
       那个按钮已经删掉了。所以这里直接把配置界面打开，
       而不是让用户去找一个不存在的按钮。 */
    box.innerHTML = '<div class="banner warn">'
      + '这台设备还没配好服务器，登录用不了。</div>';
    const setup = document.createElement("button");
    setup.className = "btn ghost";
    setup.style.width = "100%";
    setup.textContent = "填写服务器地址";
    setup.onclick = () => openCloudSettings();
    box.appendChild(setup);
  } else {
    box.innerHTML = "";
  }

  /* 已经登录过的话，登录页显示"继续使用"而不是重新输密码 */
  const profile = DB.profile;
  if (profile) {
    $("login-form").classList.add("hidden");
    $("login-resume").classList.remove("hidden");
    $("login-resume-name").textContent =
      `${profile.name}（${DB.identity && DB.identity.me
        ? identityRoleLabel(DB.identity.me.role_key)
        : (profile.role === "boss" ? "老板" : "员工")}）`;
  } else {
    $("login-form").classList.remove("hidden");
    $("login-resume").classList.add("hidden");
  }

  /* 已保存的账号放在最上面——它是这个页面最常用的入口。 */
  renderSavedAccounts();
}

/* ---------------------------------------------------------- 记住账号 */

/* 最多留几条。太多会把登录页撑得很长，而且真人也就一两个账号。 */
const SAVED_ACCOUNT_LIMIT = 5;

function savedAccountsList() {
  const stored = getSetting("saved_accounts", null);
  let rows = Array.isArray(stored) ? stored : null;
  /* One-time move from the legacy shared database into device settings. */
  if (!rows && DB && Array.isArray(DB.savedAccounts) && DB.savedAccounts.length) {
    rows = DB.savedAccounts.slice();
    saveSetting("saved_accounts", rows);
  }
  if (!rows) {
    try {
      const legacy = JSON.parse(localStorage.getItem(DB_KEY) || "null");
      if (legacy && Array.isArray(legacy.savedAccounts)
          && legacy.savedAccounts.length) {
        rows = legacy.savedAccounts.slice();
        saveSetting("saved_accounts", rows);
      }
    } catch (error) {}
  }
  return (rows || []).filter(item => item && item.code && item.password);
}

function saveSavedAccounts(rows) {
  saveSetting("saved_accounts", (rows || []).slice(0, SAVED_ACCOUNT_LIMIT));
}

/* 登录成功之后记住这个账号。

   **只在成功之后调**——失败时记住等于把错的密码存下来，
   下次点一下还是登不上，还会让人以为是 App 坏了。 */
function rememberAccount(code, role, name, password) {
  const key = String(code || "").trim();
  if (!key || !password) return;
  const kind = role === "employee" ? "employee" : "boss";

  /* 同一个人重复登录只留一条，并且挪到最前面 */
  const rest = savedAccountsList().filter(item =>
    !(item.code === key && item.role === kind));

  saveSavedAccounts([{
    code: key,
    role: kind,
    name: String(name || "").trim() || key,
    password: String(password),
    lastUsed: nowISO(),
  }].concat(rest));
}

/* 从登录页删掉一条。
   传了 role 就只删那一个身份，没传就把这个号的两个身份都删。 */
function forgetAccount(code, role) {
  const key = String(code || "").trim();
  saveSavedAccounts(savedAccountsList().filter(item =>
    !(item.code === key && (!role || item.role === role))));
}

/* "上次 10-19 22:33" 这种短格式。存的是完整 ISO，这里只取月日时分。 */
function savedTimeShort(value) {
  const text = String(value || "");
  const match = /^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2})/.exec(text);
  if (!match) return "";
  return match[2] + "-" + match[3] + " " + match[4] + ":" + match[5];
}

/* 画登录页顶部的"已保存账号"。

   点一下就登录 —— 这是这个功能唯一的用途，
   所以整行都是点击区，右边单独一个 ✕ 拿来删。 */
function renderSavedAccounts() {
  const box = $("login-saved");
  if (!box) return;
  const list = savedAccountsList();

  if (!list.length) {
    box.innerHTML = "";
    box.classList.add("hidden");
    return;
  }
  box.classList.remove("hidden");

  /* 只画卡片本身，不加任何标题/提示小字。
     卡片上已经有「登录 ›」和右边的 ✕，意思够清楚了。 */
  box.innerHTML = list.map((item, index) => {
      const roleLabel = item.role === "employee" ? "员工" : "老板";
      const when = savedTimeShort(item.lastUsed);
      return '<div class="saved-account">'
        + `<button class="saved-tap" data-saved-tap="${index}">`
        + `<span class="saved-avatar ${item.role === "employee" ? "staff" : ""}">`
        + roleLabel + "</span>"
        + '<span class="saved-main">'
        + `<span class="saved-name">${escapeHtml(item.name)}</span>`
        + `<span class="saved-meta">${escapeHtml(item.code)}`
        + (when ? " · " + when : "") + "</span>"
        + "</span>"
        + '<span class="saved-go">登录 ›</span>'
        + "</button>"
        + `<button class="saved-del" data-saved-del="${index}"`
        + ' aria-label="删掉这个账号">✕</button>'
        + "</div>";
    }).join("");

  box.querySelectorAll("[data-saved-tap]").forEach(button => {
    button.onclick = () => loginWithSaved(Number(button.dataset.savedTap));
  });
  box.querySelectorAll("[data-saved-del]").forEach(button => {
    button.onclick = event => {
      /* 别让点 ✕ 顺带触发整行登录 */
      if (event) event.stopPropagation();
      const item = list[Number(button.dataset.savedDel)];
      if (!item) return;
      if (!confirm(`删掉「${item.name}」这个账号？\n\n`
          + "下次要重新输员工号和密码。")) return;
      forgetAccount(item.code, item.role);
      renderSavedAccounts();
      toast("已删掉");
    };
  });
}

/* 点一下保存的账号 = 填好表单 + 立刻登录 */
function loginWithSaved(index) {
  const item = savedAccountsList()[index];
  if (!item) { toast("这个账号已经不在了"); return; }

  /* 点的这条是老板还是员工，上面的按钮也跟着切过去 ——
     不然标签写着「账号」，其实登录的是个员工，看着别扭。 */
  loginRole = item.role === "employee" ? "employee" : "boss";
  renderLogin();

  /* renderLogin 不动输入框的值，所以这里再填一次最稳妥 */
  const codeInput = $("login-code");
  const passInput = $("login-password");
  if (!codeInput || !passInput) return;
  codeInput.value = item.code;
  passInput.value = item.password;

  doLogin();
}

/* 登录。失败时把原因显示在按钮上方，不要只弹一个 toast——
   密码错和"没这个号"要让人分得清。 */
async function doLogin() {
  const code = $("login-code").value;
  const password = $("login-password").value;
  if (!String(code).trim()) { setLoginError("请填账号或员工号"); return; }
  if (!password) { setLoginError("请填密码"); return; }

  setLoginError("");
  const button = $("btn-login");
  button.disabled = true;
  button.textContent = "登录中…";
  try {
    /* **不再传身份。**

       以前要把"我是老板/我是员工"传进去决定先试哪个后缀，
       但选错了也照样能进，所以那个选择其实没用。
       现在由服务端查"这个号对应哪个邮箱"，用户不用选。 */
    const profile = await cloudLogin(code, password);
    if (!profile) throw new Error("登录成功但读不到账号资料，联系管理员");

    /* 登录成功之后才记住这个账号（用服务端返回的身份） */
    rememberAccount(profile.code || code, profile.role, profile.name, password);

    finishLogin();
  } catch (error) {
    setLoginError(error.message);
  } finally {
    button.disabled = false;
    button.textContent = "登录";
  }
}

/* 忘了密码怎么办。

   **这是"死局"的出口。** 以前忘了密码只能去 Supabase 后台，
   手机上根本没办法。

   分两种情况，按身份给不同出路：
     员工  → 找老板，老板能在 App 里重置（员工账号 → 重置密码）
     老板  → 如果还有另一台登着的设备，在那台上改；
            否则只能跑 SQL（sql/rename-boss.sql 里有重置的写法）

   为什么不在这里直接"重置"：那需要给匿名请求改任意账号密码的权限，
   等于谁都能改任何人的密码。**这条路不能开。** */
function openForgotPassword() {
  openSheet("忘了密码", `
    <div id="forgot-error" class="login-error hidden"></div>
    <label for="fp-email">注册时填的邮箱</label>
    <input id="fp-email" inputmode="email" autocapitalize="off"
           placeholder="收验证码用">

    <button class="btn ghost" id="fp-send" style="width:100%;margin-top:10px">
      发送验证码</button>

    <label for="fp-code">邮件里的验证码</label>
    <input id="fp-code" inputmode="numeric" autocapitalize="off">

    <label for="fp-new">新密码</label>
    <input id="fp-new" type="password">
  `, [
    { label: "关闭", onClick: closeSheet },
    { label: "重设密码", kind: "", onClick: () => submitForgotPassword() },
  ]);

  /* 发码按钮单独绑：它只发码，不改任何东西 */
  const send = $("fp-send");
  if (send) {
    send.onclick = async () => {
      const box = $("forgot-error");
      box.classList.add("hidden");
      const email = $("fp-email").value;
      if (!String(email).trim()) {
        box.textContent = "先填邮箱";
        box.classList.remove("hidden");
        return;
      }
      send.disabled = true;
      send.textContent = "发送中…";
      try {
        await sendResetCode(email);
        send.textContent = "已发送，看邮箱";
        box.textContent = "验证码已经发到 " + String(email).trim()
          + "，5 分钟内有效。";
        box.classList.remove("hidden");
        box.style.background = "#e9f3ec";
        box.style.color = "#4d7a5c";
      } catch (error) {
        box.textContent = error.message;
        box.classList.remove("hidden");
        send.disabled = false;
        send.textContent = "发送验证码";
      }
    };
  }
}

async function submitForgotPassword() {
  const box = $("forgot-error");
  box.classList.add("hidden");

  const email = $("fp-email").value;
  const token = $("fp-code").value;
  const newPassword = $("fp-new").value;

  const fail = message => {
    box.style.background = "";
    box.style.color = "";
    box.textContent = message;
    box.classList.remove("hidden");
  };

  if (!String(email).trim()) return fail("请填邮箱");
  if (!String(token).trim()) return fail("请填验证码");
  if (String(newPassword).length < 6) return fail("新密码至少要 6 位");

  const buttons = $("sheet-foot").querySelectorAll(".btn");
  const submit = buttons[buttons.length - 1];
  if (submit) { submit.disabled = true; submit.textContent = "处理中…"; }
  try {
    /* 验证码换会话 —— 能收到码就证明是本人，不需要旧密码。
       这以前是死路：忘了密码还要填旧密码。 */
    await verifyResetCode(email, token);

    /* 再改密码。updateUser 只改当前登录的人。 */
    const { error } = await cloudClient.auth.updateUser({
      password: String(newPassword),
    });
    if (error) throw new Error(translateAuthError(error.message));

    closeSheet();
    finishLogin();
    toast("密码已重设，已经登录");
  } catch (error) {
    fail(error.message);
  } finally {
    if (submit) { submit.disabled = false; submit.textContent = "重设密码"; }
  }
}

function setLoginError(message) {
  const box = $("login-error");
  box.textContent = message || "";
  box.classList.toggle("hidden", !message);
}

/* 登录成功后的统一收尾 */
function finishLogin() {
  $("login-password").value = "";
  applyRoleUI();
  startSyncLoop();
  if (typeof ensureClientProtocol === "function") {
    ensureClientProtocol(true).then(ok => {
      if (!ok) toast("当前版本与云端协议不兼容，请安装最新版");
    });
  }
  /* 登录时顺手确认一次系统通知权限。
     放在这里而不是 App 启动时：那时用户还没进入任何身份，
     弹权限框最容易被拒绝。 */
  refreshNotifyPermission().then(() => renderMe());
  if (typeof ensureGetuiPushConsent === "function") {
    ensureGetuiPushConsent();
  }
  /* 立刻同步一次：员工需要马上看到今天的任务 */
  syncNow("login");
  if (typeof refreshIdentity === "function") refreshIdentity(true);
  if (typeof refreshPointState === "function") refreshPointState(true);
  if (typeof loadDecisionCenter === "function") loadDecisionCenter(false);
  if (typeof loadOperations === "function") loadOperations(false);
  if (typeof loadExecution === "function") loadExecution(false);
  showPage(typeof mobileHomePage === "function" ? mobileHomePage() : "today");
  refreshSyncBadge();
  if (typeof maybePromptLegacyDataClaim === "function") maybePromptLegacyDataClaim();
}

/* 重启后恢复上次登录 */
function resumeSession() {
  applyRoleUI();
  startSyncLoop();
  if (typeof ensureClientProtocol === "function") ensureClientProtocol(false);
  if (typeof refreshPointState === "function") refreshPointState(false);
  if (typeof loadDecisionCenter === "function") loadDecisionCenter(false);
  if (typeof loadOperations === "function") loadOperations(false);
  if (typeof loadExecution === "function") loadExecution(false);
  refreshNotifyPermission().then(() => renderMe());
  if (typeof ensureGetuiPushConsent === "function") {
    ensureGetuiPushConsent();
  }
  syncNow("resume");
  if (typeof maybePromptLegacyDataClaim === "function") {
    setTimeout(() => maybePromptLegacyDataClaim(), 800);
  }
}

function resetAccountScopedRuntimeState() {
  if (typeof resetIdentityRuntimeCache === "function") resetIdentityRuntimeCache();
  if (typeof resetMyCompaniesRuntimeCache === "function") resetMyCompaniesRuntimeCache();
  if (typeof clearOperationsCache === "function") clearOperationsCache();
  if (typeof clearExecutionCache === "function") clearExecutionCache();
  if (typeof clearShareholderMeetings === "function") clearShareholderMeetings();
  if (typeof clearIntakeCache === "function") clearIntakeCache();
  if (typeof resetTodayState === "function") resetTodayState();
}

function stopAccountRuntime() {
  stopSyncLoop();
  if (typeof unsubscribeRealtime === "function") unsubscribeRealtime();
  if (DB) saveAll();
}

function switchAccount() {
  stopAccountRuntime();
  const unregister = typeof unregisterGetuiPushDevice === "function"
    ? unregisterGetuiPushDevice() : Promise.resolve();
  return Promise.resolve(unregister)
    .then(() => cloudLogout())
    .then(() => {
      if (typeof resetTodayState === "function") resetTodayState();
      applyRoleUI();
      closeSheet();
      showPage("login");
    });
}

function logout() {
  if (!confirm("退出登录？\n\n本机项目和待上传数据会按当前账号保存，"
      + "重新登录后继续使用。")) return;
  Promise.resolve(switchAccount()).then(() => {
    toast("已退出登录");
  });
}

/* ---------------------------------------------------------- 旧数据归属 */

function maybePromptLegacyDataClaim() {
  if (!DB || !DB.profile || !DB.account_scope_id) return;
  const state = getSetting("legacy_data_claim", {});
  if (state && (state.status === "claimed" || state.status === "archived")) return;
  const legacy = typeof legacyDatabaseSnapshot === "function"
    ? legacyDatabaseSnapshot() : null;
  if (!legacy) return;
  const summary = legacyDataSummary(legacy);
  if (!summary.total) return;

  openSheet("旧数据归属确认", `
    <div class="banner warn">
      检测到旧版本留下了 ${summary.total} 条本机数据。旧数据没有可靠的账号标识，
      需要你确认归属后才能使用。
    </div>
    <div class="identity-meta-grid" style="margin-top:12px">
      <div><span>项目 / 步骤</span><b>${num(summary.projects)} / ${num(summary.steps)}</b></div>
      <div><span>员工 / 工时</span><b>${num(summary.employees)} / ${num(summary.worklogs)}</b></div>
      <div><span>任务 / 打卡</span><b>${num(summary.tasks)} / ${num(summary.habitLogs)}</b></div>
      <div><span>待上传记录</span><b>${num(summary.syncQueue)}</b></div>
    </div>
    <div class="meta" style="margin-top:10px">
      选择“归入当前账号”只会导入本机业务数据，不会自动上传旧队列。
      系统会先保留一份完整备份。
    </div>
  `, [
    { label: "稍后处理", kind: "ghost", onClick: () => {
      deferLegacyDataClaim(DB.account_scope_id);
      closeSheet();
      toast("旧数据仍保留，可稍后确认");
    } },
    { label: "保留为备份", kind: "ghost", onClick: () => {
      archiveLegacyDataClaim();
      closeSheet();
      toast("旧数据已保留为备份");
    } },
    { label: "归入当前账号", kind: "", onClick: () => {
      try {
        claimLegacyDataForCurrentAccount();
        closeSheet();
        saveAll();
        applyRoleUI();
        renderToday();
        renderMe();
        toast("旧数据已归入当前账号，并保留备份");
      } catch (error) {
        toast(String(error.message || error || "旧数据迁移失败"));
      }
    } },
  ]);
}

/* ---------------------------------------------------------- 角色 */
/* 按登录身份调整界面。

   员工**看不到**项目、看板、习惯这些东西——那是老板的视角。
   让员工看到一堆自己用不上的按钮只会让人困惑。 */
function applyRoleUI() {
  const profile = DB.profile;
  const advancedAllowed = typeof identityHasAdvancedAccess === "function"
    ? identityHasAdvancedAccess()
    : !!(profile && profile.role === "boss");
  const management = typeof identityHasManagementView === "function"
    ? identityHasManagementView()
    : !!(profile && profile.role === "boss");
  const isStaff = !!(profile && !management);
  if (!advancedAllowed) DB.uiMode = "simple";
  const advanced = !!(profile && advancedAllowed && DB.uiMode === "advanced");
  if ((!advanced || !management) && typeof clearOperationsCache === "function") {
    clearOperationsCache();
  }
  if (!profile && typeof clearExecutionCache === "function") {
    clearExecutionCache();
  }
  if ((!profile || !advanced) && typeof clearShareholderMeetings === "function") {
    clearShareholderMeetings();
  }
  if (!management && typeof clearIntakeManagementCache === "function") {
    clearIntakeManagementCache();
  }
  if (!profile && typeof clearIntakeCache === "function") {
    clearIntakeCache();
  }

  /* 简单模式只保留今天、知识星球和我的；高级模式才展开经营与治理页。 */
  if ($("nav-simple")) $("nav-simple").classList.toggle("hidden", !profile || advanced);
  if ($("nav-advanced")) $("nav-advanced").classList.toggle("hidden", !advanced);

  const toggle = $("btn-mode-toggle");
  if (toggle) toggle.classList.toggle("hidden", !advancedAllowed);
  const toggleMe = $("btn-mode-toggle-me");
  if (toggleMe) {
    toggleMe.classList.toggle("hidden", !advancedAllowed);
    toggleMe.textContent = advanced ? "回到简单模式" : "切换到高级模式";
  }

  const advancedPages = ["decisions", "operations", "dash", "project",
                         "team", "assist", "identity", "assign", "staff"];
  if (profile && !advanced && advancedPages.indexOf(currentPageName()) !== -1) {
    showPage("today");
  }
  if ($("nav-operations")) {
    $("nav-operations").classList.toggle("hidden", !advanced || !management);
  }
  if ($("nav-execution")) {
    $("nav-execution").classList.toggle("hidden", !profile);
  }
  if (profile && currentPageName() === "operations" && !management) {
    showPage(advanced ? "dash" : "today");
  }

  /* 「我要请假」只给普通员工看。 */
  if ($("btn-me-companies")) {
    $("btn-me-companies").classList.toggle("hidden", !profile);
  }
  if ($("btn-me-leave")) {
    $("btn-me-leave").classList.toggle("hidden", !isStaff);
  }

  if (typeof updateNavScrollCue === "function") updateNavScrollCue();
  refreshSyncBadge();
}

/* 顶部的同步状态小标签。

   **必须让用户看得见同步状态**：
     员工勾完任务如果没上传成功，他会以为报上去了，
     老板那边却没收到。这种"静默失败"最难查。 */
function refreshSyncBadge() {
  const status = syncStatus();
  const nodes = document.querySelectorAll(".sync-badge");
  let text = "";
  let kind = "";

  if (!status.configured || !status.hasLibrary) {
    text = "单机";
    kind = "off";
  } else if (!status.signedIn) {
    text = "未登录";
    kind = "off";
  } else if (status.busy) {
    text = "同步中…";
    kind = "";
  } else if (status.last && status.last.ok === false) {
    /* **同步失败要显眼**。原来这里只显示"待上传 N 条"，
       看起来像"网络慢一点"，实际可能是被服务端一直拒绝——
       用户以为报上去了，老板那边什么都没有。 */
    text = "同步失败";
    kind = "bad";
  } else if (status.pending > 0) {
    text = `待上传 ${status.pending}`;
    kind = "warn";
  } else if (!status.online) {
    text = "离线";
    kind = "off";
  } else if (status.last && status.last.at) {
    text = "已同步";
    kind = "ok";
  } else {
    text = "已登录";
    kind = "";
  }

  /* 失败时把原因也挂到 title 上，长按/悬停能看到具体错误 */
  nodes.forEach(node => {
    node.textContent = text;
    node.className = "sync-badge " + kind;
    node.title = (status.last && status.last.message) || "";
  });
}

/* ---------------------------------------------------------- 员工任务页 */

/* ---------------------------------------------------------- 开工 / 收工 */

/* 计时器句柄。离开页面或重新渲染时要清掉，否则会越积越多。 */
let workTicker = null;

/* 把"从某个时刻到现在"格式化成 时:分:秒 */
function formatElapsed(fromISO) {
  const started = new Date(fromISO).getTime();
  if (!isFinite(started)) return "00:00:00";
  const total = Math.max(0, Math.floor((Date.now() - started) / 1000));
  const pad = n => String(n).padStart(2, "0");
  return pad(Math.floor(total / 3600)) + ":" + pad(Math.floor((total % 3600) / 60))
    + ":" + pad(total % 60);
}

/* 停掉计时器。

   离开任务页时必须停 —— 不然用户切到别的页，
   那个 setInterval 还在每秒改一个看不见的元素，白耗电。 */
function stopWorkTicker() {
  if (workTicker) {
    clearInterval(workTicker);
    workTicker = null;
  }
}

function renderWorkCard() {
  const card = $("work-card");
  if (!card) return;
  if (!DB.profile) { card.classList.add("hidden"); return; }
  card.classList.remove("hidden");

  const open = typeof openWorkSession === "function" ? openWorkSession() : null;
  const line = $("work-line");
  const timer = $("work-timer");
  const button = $("btn-work");

  /* 每次重画先停掉旧计时器，避免两个一起跑 */
  stopWorkTicker();

  if (open) {
    /* 跨天了还挂着，八成是忘了收工。**必须提示**，
       否则用户等到第二天才点结束，会被截到 24 小时，
       却不知道为什么少了这么多。 */
    const stale = meritDayKey(open.started_at) < todayISO();
    line.textContent = (stale ? "⚠ 从 " : "正在记录 · ")
      + meritTime(open.started_at) + (stale ? " 开始，是不是忘了收工？" : " 开始");
    timer.textContent = formatElapsed(open.started_at);
    timer.classList.add("running");
    button.textContent = "结束工作";
    button.classList.add("working");
    workTicker = setInterval(() => {
      /* 用记录里的开始时间算，不累加 —— 切后台再回来也不会偏 */
      timer.textContent = formatElapsed(open.started_at);
    }, 1000);
  } else {
    line.textContent = "还没开始";
    timer.textContent = "00:00:00";
    timer.classList.remove("running");
    button.textContent = "开始工作";
    button.classList.remove("working");
  }

  /* 今天一共记了多久。

     **这行很重要**：没有它，用户收工后屏幕上什么都没变，
     会以为计时器根本没在记。数字来自本地的上下工记录，
     收工那一瞬间就更新，不用等同步。 */
  const total = $("work-total");
  if (total) {
    const today = todayISO();
    const hours = (DB.workSessions || [])
      .filter(row => String(row.profile_id) === String(DB.profile.id))
      .filter(row => row.ended_at
        && meritDayKey(row.created_at || row.started_at) >= today)
      .reduce((sum, row) => sum + num(row.hours), 0);
    total.textContent = hours > 0
      ? "今天已记 " + (Math.round(hours * 100) / 100) + " 小时"
      : "";
  }
}

async function toggleWork() {
  const button = $("btn-work");
  if (!button || button.disabled) return;
  button.disabled = true;
  try {
    const open = typeof openWorkSession === "function" ? openWorkSession() : null;
    if (open) {
      const result = await stopWork();
      const hours = result ? num(result.hours) : 0;
      const merit = result ? num(result.merit) : 0;
      const pending = result ? num(result.pending_merit) : 0;
      /* 三种情况都要说清楚，不能只弹一个"已结束" ——
         那样用户不知道到底记没记上。 */
      const capped = !!(result && result.capped);
      if (hours <= 0) {
        toast("已结束 · 不到 20 秒，这次没记");
      } else if (capped) {
        toast("已结束 · 这次太长了，按 24 小时算 · 待结算 " + pending + " " + MERIT.unit);
      } else if (pending > 0) {
        toast("已结束 · 记了 " + hours + " 小时 · 待评级结算 " + pending + " " + MERIT.unit);
      } else if (merit > 0) {
        toast("已结束 · 记了 " + hours + " 小时 · +" + merit + " " + MERIT.unit);
      } else {
        toast("已结束 · 记了 " + hours + " 小时 · 时间太短，没有" + MERIT.unit);
      }
    } else {
      await startWork(null);
      toast("开始计时");
    }
    renderWorkCard();
    if (typeof renderMeritCard === "function") renderMeritCard();
  } catch (error) {
    toast(error.message);
  } finally {
    button.disabled = false;
  }
}

/* ---------------------------------------------------------- 兑换 */

function openShopSheet() {
  if (!DB.profile) { toast("先登录"); return; }
  const me = DB.profile.id;
  const balance = meritAvailable(me);
  const rewards = (DB.rewards || []).filter(item => item.active !== false);

  const rows = rewards.map(item => {
    const cost = num(item.cost);
    const affordable = balance >= cost;
    return '<button class="shop-item' + (affordable ? "" : " short") + '"'
      + ' data-redeem="' + escapeHtml(String(item.id)) + '"'
      + (affordable ? "" : " disabled") + '>'
      + '<span class="shop-main"><b>' + escapeHtml(item.title) + '</b>'
      + (item.detail
        ? '<span class="meta">' + escapeHtml(item.detail) + '</span>' : "")
      + '</span>'
      + '<span class="shop-cost">' + cost + ' ' + MERIT.unit + '</span></button>';
  }).join("");

  openSheet("兑换奖励", `
    <div class="hint" style="margin-bottom:12px">
      余额 ${meritNumber(balance)} ${MERIT.unit}，兑换后由老板发放
    </div>
    <div class="shop-list">${rows
      || '<div class="empty">还没有上架的奖励。等老板加。</div>'}</div>
  `, [{ label: "关闭", onClick: closeSheet }]);

  const box = $("sheet-body");
  if (!box) return;
  box.querySelectorAll("[data-redeem]").forEach(button => {
    button.onclick = async () => {
      button.disabled = true;
      try {
        const result = await redeemReward(button.dataset.redeem);
        closeSheet();
        renderMeritCard();
        toast("已兑换，等老板给你"
          + (result && result.cost ? " · 扣 " + num(result.cost) + " " + MERIT.unit : ""));
      } catch (error) {
        button.disabled = false;
        toast(translateRedeemError(error.message));
      }
    };
  });
}

function translateRedeemError(message) {
  const text = String(message || "");
  if (/not enough points/i.test(text)) return "源点不够，再攒攒";
  if (/inactive/i.test(text)) return "这个奖励已经下架了";
  return text;
}

/* ---------------------------------------------------------- 请假 */

function openLeaveSheet() {
  const today = todayISO();
  openSheet("请假", `
    <label for="lv-from">从哪天</label>
    <input id="lv-from" type="date" value="${today}">
    <label for="lv-to">到哪天</label>
    <input id="lv-to" type="date" value="${today}">
    <label for="lv-reason">原因（可选）</label>
    <input id="lv-reason">
    <div id="lv-error" class="login-error hidden"></div>
  `, [
    { label: "取消", onClick: closeSheet },
    { label: "提交", kind: "", onClick: () => submitLeave() },
  ]);
}

async function submitLeave() {
  const box = $("lv-error");
  box.classList.add("hidden");
  const from = $("lv-from").value;
  const to = $("lv-to").value;
  if (!from || !to) {
    box.textContent = "两天日期都要填";
    box.classList.remove("hidden");
    return;
  }
  if (to < from) {
    box.textContent = "结束日期早于开始日期";
    box.classList.remove("hidden");
    return;
  }

  const buttons = $("sheet-foot").querySelectorAll(".btn");
  const submit = buttons[buttons.length - 1];
  if (submit) { submit.disabled = true; submit.textContent = "提交中…"; }
  try {
    await requestLeave(from, to, $("lv-reason").value);
    closeSheet();
    toast("已提交，等老板批");
  } catch (error) {
    let message = error.message;
    if (/already asked/i.test(String(message))) {
      message = "已经有一条申请在等老板批了";
    } else if (/end date is before/i.test(String(message))) {
      message = "结束日期早于开始日期";
    }
    box.textContent = message;
    box.classList.remove("hidden");
  } finally {
    if (submit) { submit.disabled = false; submit.textContent = "提交"; }
  }
}

/* ---------------------------------------------------------- 老板：商品管理 */

function openManageRewards() {
  const list = DB.rewards || [];
  const rows = list.map(item => {
    const off = item.active === false;
    return '<div class="list-item">'
      + '<div class="grow"><b>' + escapeHtml(item.title) + '</b>'
      + '<div class="meta">' + num(item.cost) + ' ' + MERIT.unit
      + (off ? ' · 已下架' : '') + '</div></div>'
      + '<button class="icon-btn" data-toggle-reward="'
      + escapeHtml(String(item.id)) + '">' + (off ? "上架" : "下架") + '</button>'
      + '</div>';
  }).join("");

  openSheet("兑换商品", `
    <div class="hint" style="margin-bottom:12px">
      员工用${MERIT.name}兑换。下架后不再显示，但历史兑换记录保留。
    </div>
    ${rows || '<div class="empty">还没有商品</div>'}
    <button class="btn" id="btn-add-reward"
            style="width:100%;margin-top:12px">+ 新增商品</button>
  `, [{ label: "关闭", onClick: closeSheet }]);

  const box = $("sheet-body");
  if (!box) return;

  box.querySelectorAll("[data-toggle-reward]").forEach(button => {
    button.onclick = async () => {
      const row = (DB.rewards || []).find(item =>
        String(item.id) === String(button.dataset.toggleReward));
      if (!row) return;
      button.disabled = true;
      try {
        await setRewardActive(row.id, row.active === false);
        openManageRewards();
      } catch (error) {
        button.disabled = false;
        toast(error.message);
      }
    };
  });

  const add = $("btn-add-reward");
  if (add) add.onclick = openAddRewardSheet;
}

function openAddRewardSheet() {
  openSheet("新增商品", `
    <label for="rw-title">叫什么</label>
    <input id="rw-title" placeholder="下午茶 / 迟到免责券 / 带薪假半天">
    <label for="rw-cost">多少${MERIT.unit}</label>
    <input id="rw-cost" type="number" inputmode="numeric" value="50">
    <label for="rw-detail">说明（可选）</label>
    <input id="rw-detail">
    <div id="rw-error" class="login-error hidden"></div>
  `, [
    { label: "取消", onClick: closeSheet },
    { label: "保存", kind: "", onClick: () => submitReward() },
  ]);
}

async function submitReward() {
  const box = $("rw-error");
  box.classList.add("hidden");
  const title = $("rw-title").value;
  const cost = num($("rw-cost").value);
  if (!String(title).trim()) {
    box.textContent = "先起个名字";
    box.classList.remove("hidden");
    return;
  }
  if (cost <= 0) {
    box.textContent = "价格要大于 0";
    box.classList.remove("hidden");
    return;
  }

  const buttons = $("sheet-foot").querySelectorAll(".btn");
  const submit = buttons[buttons.length - 1];
  if (submit) { submit.disabled = true; submit.textContent = "保存中…"; }
  try {
    await addReward(title, cost, $("rw-detail").value);
    toast("已上架");
    openManageRewards();
  } catch (error) {
    box.textContent = error.message;
    box.classList.remove("hidden");
  } finally {
    if (submit) { submit.disabled = false; submit.textContent = "保存"; }
  }
}

function renderTasks() {
  /* 最上面两张卡先画：工时状态和记忆源点。
     即使今天没有任务，这两个也是员工要看的。 */
  if (typeof renderWorkCard === "function") renderWorkCard();
  if (typeof renderMeritCard === "function") renderMeritCard();

  const today = todayISO();
  const tasks = tasksOn(today);
  const done = tasks.filter(task => taskLogFor(task.id)).length;

  $("tasks-sub").textContent = tasks.length
    ? `今天 ${done}/${tasks.length} 条完成`
    : "今天还没有任务";

  const row = $("tasks-list");
  if (!tasks.length) {
    row.innerHTML = '<div class="empty">今天没有任务</div>';
    renderTaskHistory();
    refreshSyncBadge();
    return;
  }

  row.innerHTML = tasks.map(task => {
    const log = taskLogFor(task.id);
    /* 实际做了多久。**这是算钱的依据**，预估只是参考。 */
    const actualHours = (log && log.started_at && log.finished_at)
      ? Math.min(24, Math.max(0,
        (new Date(String(log.finished_at).replace(" ", "T")).getTime()
          - new Date(String(log.started_at).replace(" ", "T")).getTime())
        / 3600000))
      : 0;
    const isDone = !!log;
    const started = !!task.started_at;

    /* 接受状态。老数据没有 accept_status，按 pending 算——
       它们是在这个功能之前派的，应该让员工补一次表态。 */
    const needAccept = taskPendingAccept(task) && !isDone;
    const rejected = taskRejected(task) && !isDone;
    const ext = pendingExtensionFor(task.id);

    let action = "完成";
    if (isDone) action = "已完成";
    else if (started) action = "完成";

    /* ---- 底部按钮区：按状态三选一 ---- */
    let footer = "";
    if (isDone) {
      /* 已完成就不显示操作按钮 */
    } else if (needAccept) {
      footer = `
        <div class="btn-row" style="margin-top:10px">
          <button class="btn ghost" data-task-reject="${task.id}">不接受</button>
          <button class="btn" data-task-accept="${task.id}">接受</button>
        </div>`;
    } else if (rejected) {
      footer = `
        <div class="btn-row" style="margin-top:10px">
          <button class="btn ghost" data-task-accept="${task.id}">改主意，接受</button>
        </div>`;
    } else if (ext) {
      footer = `<div class="meta" style="margin-top:8px">`
        + `已申请延期到 <b>${escapeHtml(String(ext.to_date).slice(0, 10))}</b>`
        + `，等老板批</div>`;
    } else {
      footer = `
        <div class="btn-row" style="margin-top:10px">
          <button class="btn ghost" data-task-start="${task.id}"
                  ${started ? "disabled" : ""}>
            ${started
              ? "已开始（" + escapeHtml(String(task.started_at).slice(11, 16)) + "）"
              : "开始"}
          </button>
          <button class="btn" data-task-done="${task.id}">${action}</button>
        </div>
        <div class="btn-row" style="margin-top:8px">
          <button class="btn ghost" data-task-extend="${task.id}">今天做不完，申请延期</button>
        </div>`;
    }

    return `
      <div class="card task ${isDone ? "done" : ""}">
        <div class="task-main">
          ${needAccept || rejected
            ? `<span class="task-check" aria-hidden="true"><span></span></span>`
            : `<button class="task-check ${isDone ? "on" : ""}"
                       data-task-check="${task.id}"
                       aria-label="${isDone ? "取消完成" : "标记完成"}">
                 <span>${isDone ? "✓" : ""}</span>
               </button>`}
          <div class="task-body">
            <div class="task-title">${escapeHtml(task.title)}</div>
            ${task.detail
              ? `<div class="meta">${escapeHtml(task.detail)}</div>` : ""}
            <div class="meta">
              ${task.project_name
                ? escapeHtml(task.project_name) + " · " : ""}
              ${num(task.est_hours) > 0
                ? "预估 " + num(task.est_hours) + " 小时 · " : ""}
              ${isDone
                ? "完成于 " + escapeHtml(String(log.finished_at).slice(11, 16))
                  + (actualHours > 0
                    ? " · 实际 " + (Math.round(actualHours * 100) / 100) + " 小时"
                    : "")
                : (started
                  ? "从 " + escapeHtml(String(task.started_at).slice(11, 16))
                    + " 起计时"
                  : "未开始")}
            </div>
            ${rejected
              ? `<div class="meta" style="color:var(--severe)">`
                + `已拒绝：${escapeHtml(task.accept_reason || "（没写原因）")}</div>`
              : ""}
            ${task.grade
              ? `<div class="task-grade">`
                + `老板验收：<b>${escapeHtml(String(task.grade))} 级</b>`
                + (num(task.merit_awarded) > 0
                  ? ` · +${num(task.merit_awarded)} ${MERIT.unit}` : " · 不发源点")
                + `</div>`
              : (isDone
                ? `<div class="meta" style="color:var(--fg-faint);margin-top:4px">`
                  + `等老板验收</div>`
                : "")}

          </div>
        </div>
        ${footer}
      </div>`;
  }).join("");

  /* ---- 接受 / 拒绝 ---- */
  document.querySelectorAll("[data-task-accept]").forEach(button => {
    button.onclick = async () => {
      const id = NumberOrString(button.dataset.taskAccept);
      button.disabled = true;
      try {
        await setTaskAccept(id, true, "");
        /* **接受了就开始计时。**

           用户的要求是：接到任务自动开始、做完自动停，
           而且按计时器的时间算钱。所以接受这一步就
           把 started_at 记下来，员工不用再单独点一次"开始"。
           （老版本有个单独的「开始计时」按钮，现在保留兼容。） */
        try { startTask(id); } catch (error) { /* 计时失败不影响已接受 */ }
        toast("已接受，开始计时");
        renderTasks();
      } catch (error) {
        toast(error.message);
        button.disabled = false;
      }
    };
  });

  document.querySelectorAll("[data-task-reject]").forEach(button => {
    button.onclick = () => {
      openRejectSheet(NumberOrString(button.dataset.taskReject));
    };
  });

  /* ---- 申请延期 ---- */
  document.querySelectorAll("[data-task-extend]").forEach(button => {
    button.onclick = () => {
      openExtensionSheet(NumberOrString(button.dataset.taskExtend));
    };
  });

  document.querySelectorAll("[data-task-start]").forEach(button => {
    button.onclick = () => {
      try {
        startTask(NumberOrString(button.dataset.taskStart));
        renderTasks();
        toast("已开始计时");
      } catch (error) { toast(error.message); }
    };
  });

  document.querySelectorAll("[data-task-done], [data-task-check]").forEach(button => {
    button.onclick = () => {
      const id = NumberOrString(button.dataset.taskDone
        || button.dataset.taskCheck);
      const task = taskById(id);
      if (!task) { toast("这条任务已经不存在了"); return; }

      /* **没接受就不能算完成。**

         界面已经不给点了，但这里再兜一层：
         万一旧版本渲染的卡片还留在 DOM 里、或者以后有人改模板，
         也不能让"未确认/已拒绝"的任务被直接上报完成 ——
         那会让接受流程形同虚设，老板收到的数据也不可信。 */
      if (taskPendingAccept(task)) {
        toast("先点「接受」，再开始做");
        return;
      }
      if (taskRejected(task)) {
        toast("这条你已经拒绝了，点「改主意，接受」才会进入工作状态");
        return;
      }

      try {
        if (taskLogFor(id)) {
          /* 取消完成。要问一下——员工可能只是手滑点错了 */
          if (!confirm(`取消「${task.title}」的完成状态？\n\n`
              + "报上去的工时也会一起撤掉。")) return;
          uncompleteTask(id);
          toast("已取消");
        } else {
          completeTask(task);
          if (navigator.vibrate) navigator.vibrate(16);
          toast("已上报，老板那边会自动收到");
        }
      } catch (error) {
        toast(error.message);
      }
      renderTasks();
      refreshSyncBadge();
    };
  });

  renderTaskHistory();
  refreshSyncBadge();
}

/* ============================================================
   不接受任务 / 申请延期 的输入弹窗
   ============================================================ */

/* 往后推 N 天的日期字符串。
   **不要用 toISOString()** —— 那是 UTC，东八区下午会变成前一天。 */
function shiftDate(dateText, days) {
  const base = String(dateText || todayISO()).slice(0, 10);
  const d = new Date(base + "T00:00:00");
  if (isNaN(d.getTime())) return base;
  d.setDate(d.getDate() + (days || 0));
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, "0");
  const day = String(d.getDate()).padStart(2, "0");
  return y + "-" + m + "-" + day;
}

/* 员工：说明为什么接不了这条任务。

   拒绝必须写原因 —— 服务端也会校验（空原因直接报错），
   这里先挡一道，省得白跑一次网络请求。 */
function openRejectSheet(taskId) {
  const task = taskById(taskId);
  if (!task) { toast("这条任务已经不存在了"); return; }

  openSheet("不接受这条任务", `
    <div class="meta" style="padding-bottom:10px">
      ${escapeHtml(task.title)}
    </div>
    <label class="meta">原因（必填）</label>
    <textarea id="reject-reason" rows="4" placeholder=""
              style="width:100%;margin-top:6px"></textarea>
  `, [
    { label: "取消", onClick: closeSheet },
    { label: "确定不接受", kind: "danger", onClick: async () => {
      const box = document.getElementById("reject-reason");
      const reason = box ? String(box.value || "").trim() : "";
      if (!reason) { toast("要写原因，不能空着"); return; }
      closeSheet();
      try {
        await setTaskAccept(taskId, false, reason);
        toast("已告诉老板");
        renderTasks();
      } catch (error) { toast(error.message); }
    } },
  ]);
}

/* 员工：申请把任务挪到新日期。

   默认填"往后一天"，员工只需要改日期 + 写原因。
   日期用 <input type="date">，WebView 会调出系统日期选择器。 */
function openExtensionSheet(taskId) {
  const task = taskById(taskId);
  if (!task) { toast("这条任务已经不存在了"); return; }

  const original = String(task.plan_date || todayISO()).slice(0, 10);
  const suggested = shiftDate(original, 1);

  openSheet("申请延期", `
    <div class="meta" style="padding-bottom:10px">
      ${escapeHtml(task.title)}　·　原计划 ${escapeHtml(original)}
    </div>
    <label class="meta">挪到哪天</label>
    <input type="date" id="ext-date" value="${escapeHtml(suggested)}"
           min="${escapeHtml(shiftDate(original, 1))}"
           style="width:100%;margin-top:6px">
    <label class="meta" style="display:block;padding-top:10px">原因（必填）</label>
    <textarea id="ext-reason" rows="3"
              placeholder=""
              style="width:100%;margin-top:6px"></textarea>
  `, [
    { label: "取消", onClick: closeSheet },
    { label: "提交申请", onClick: async () => {
      const dateBox = document.getElementById("ext-date");
      const reasonBox = document.getElementById("ext-reason");
      const toDate = dateBox ? String(dateBox.value || "").trim() : "";
      const reason = reasonBox ? String(reasonBox.value || "").trim() : "";
      if (!reason) { toast("要写申请延期的原因"); return; }
      if (!toDate) { toast("要选一个新日期"); return; }
      if (toDate <= original) {
        toast("新日期要晚于原计划的 " + original);
        return;
      }
      closeSheet();
      try {
        await requestTaskExtension(taskId, toDate, reason);
        toast("已提交，等老板批");
        renderTasks();
      } catch (error) { toast(error.message); }
    } },
  ]);
}

/* 最近几天完成的任务。给员工一个"我报过什么"的回看入口——
   没有这个的话，员工会怀疑自己的记录到底有没有上去。 */
function renderTaskHistory() {
  const today = todayISO();
  const logs = (DB.taskLogs || []).filter(log => log.finish_date !== today)
    .sort((a, b) => String(b.finish_date).localeCompare(String(a.finish_date)))
    .slice(0, 15);
  const box = $("tasks-history");
  if (!logs.length) { box.innerHTML = ""; return; }

  box.innerHTML = `
    <div class="section-head"><span>之前报过的</span></div>
    <div class="card">
      ${logs.map(log => {
        const task = taskById(log.task_id);
        return `<div class="row" style="margin-top:6px">
          <div class="grow meta">${escapeHtml(log.finish_date)} ·
            ${escapeHtml(task ? task.title : "（任务已删除）")}</div>
          <span class="meta">已上报</span>
        </div>`;
      }).join("")}
    </div>`;
}

/* 任务的 id 是 uuid 字符串，但员工端可能拿到本地生成的 id。
   两种都要能用，不能强转成 Number——uuid 转数字会变 NaN。 */
function NumberOrString(value) {
  const text = String(value);
  return /^\d+$/.test(text) ? Number(text) : text;
}

/* ---------------------------------------------------------- 老板自助注册 */

/* 注册表单。

   **重名不再改名了。** 以前服务端遇到"这个手机号已经注册过"
   会自动加 -2 -3 后缀建个新号，用户完全不知道，于是同一个号
   能注册出五六个账号。现在直接报"已经注册过了"。

   **邮箱是必填的** —— 忘了密码时唯一能自救的路。 */
function openBossRegister() {
  openSheet("创建老板账号", `
    <label for="rg-name">怎么称呼你 *</label>
    <input id="rg-name">

    <label for="rg-phone">账号 *</label>
    <input id="rg-phone" inputmode="numeric" autocapitalize="off">

    <label for="rg-email">邮箱 *</label>
    <input id="rg-email" inputmode="email" autocapitalize="off"
           placeholder="忘了密码时收验证码用">

    <label for="rg-password">密码 *</label>
    <input id="rg-password" type="password">

    <div id="rg-error" class="login-error hidden"></div>
  `, [
    { label: "取消", onClick: closeSheet },
    { label: "创建并登录", kind: "", onClick: () => submitBossRegister() },
  ]);
}

async function submitBossRegister() {
  const box = $("rg-error");
  box.classList.add("hidden");

  const buttons = $("sheet-foot").querySelectorAll(".btn");
  const submit = buttons[buttons.length - 1];
  if (submit) { submit.disabled = true; submit.textContent = "创建中…"; }

  try {
    const result = await registerBoss({
      name: $("rg-name").value,
      phone: $("rg-phone").value,
      email: $("rg-email").value,
      password: $("rg-password").value,
    });
    closeSheet();
    finishLogin();
    toast("账号建好了，已登录："
      + (result.profile ? result.profile.name : ""));
  } catch (error) {
    /* **错误要显示在表单里，不能只弹气泡**。
       注册失败的原因（账号格式不对、密码太短）
       用户要能停下来看清楚再改。 */
    box.textContent = error.message;
    box.classList.remove("hidden");
  } finally {
    if (submit) { submit.disabled = false; submit.textContent = "创建并登录"; }
  }
}

/* ---------------------------------------------------------- 账号管理 */

/* 改密码。

   验旧密码是**必做的**：Supabase 的 updateUser 不需要旧密码，
   不自己验的话，谁拿到这台手机就能改密码。 */
function openChangePassword() {
  openSheet("修改密码", `
    <label for="cp-old">现在的密码</label>
    <input id="cp-old" type="password">

    <label for="cp-new">新密码</label>
    <input id="cp-new" type="password">

    <label for="cp-new2">再输一次新密码</label>
    <input id="cp-new2" type="password">

    <div id="cp-error" class="login-error hidden"></div>
  `, [
    { label: "取消", onClick: closeSheet },
    { label: "改密码", kind: "", onClick: () => submitChangePassword() },
  ]);
}

async function submitChangePassword() {
  const box = $("cp-error");
  box.classList.add("hidden");
  const oldPassword = $("cp-old").value;
  const newPassword = $("cp-new").value;
  const again = $("cp-new2").value;

  const fail = message => {
    box.textContent = message;
    box.classList.remove("hidden");
  };

  if (!oldPassword) return fail("请填现在的密码");
  if (String(newPassword).length < 6) return fail("新密码至少要 6 位");
  if (newPassword !== again) return fail("两次输入的新密码不一样");

  const buttons = $("sheet-foot").querySelectorAll(".btn");
  const submit = buttons[buttons.length - 1];
  if (submit) { submit.disabled = true; submit.textContent = "修改中…"; }
  try {
    await changeMyPassword(oldPassword, newPassword);
    closeSheet();
    toast("密码已改，下次登录用新密码");
  } catch (error) {
    fail(error.message);
  } finally {
    if (submit) { submit.disabled = false; submit.textContent = "改密码"; }
  }
}

/* 绑邮箱。

   **只在没绑真邮箱时出现**（老账号）。新注册的账号注册时就填了，
   看不到这个按钮。

   为什么非要有：老账号的邮箱是 <账号>@boss.pr 这种内部假地址，
   验证码发过去直接退信 —— 忘了密码就彻底进不来。

   走服务端的 set_my_email：**不发确认信，改完立刻生效**。
   因为老账号的旧地址是 <账号>@boss.pr（不存在的域名），
   要求"旧地址也确认"的流程会让它们永远绑不上。

   代价是 24 小时内只能改一次 —— 足够防手滑和防盗号，
   又不至于让人卡住。 */
function openChangeEmail() {
  openSheet("绑定邮箱", `
    <div id="ce-error" class="login-error hidden"></div>
    <label for="ce-new">邮箱</label>
    <input id="ce-new" inputmode="email" autocapitalize="off"
           placeholder="忘了密码时收验证码用">
    <div class="hint" style="margin-top:6px">
      改完立刻生效。24 小时内只能改一次。
    </div>
  `, [
    { label: "取消", onClick: closeSheet },
    { label: "保存", kind: "", onClick: () => submitChangeEmail() },
  ]);
}

async function submitChangeEmail() {
  const box = $("ce-error");
  box.classList.add("hidden");
  const email = $("ce-new").value;
  if (!String(email).trim()) {
    box.textContent = "请填邮箱";
    box.classList.remove("hidden");
    return;
  }

  const buttons = $("sheet-foot").querySelectorAll(".btn");
  const submit = buttons[buttons.length - 1];
  if (submit) { submit.disabled = true; submit.textContent = "保存中…"; }
  try {
    await changeMyEmail(email);
    closeSheet();
    renderMe();
    toast("邮箱已绑定");
  } catch (error) {
    box.textContent = error.message;
    box.classList.remove("hidden");
  } finally {
    if (submit) { submit.disabled = false; submit.textContent = "保存"; }
  }
}

/* 改登录名（就是账号本身）。 */
function openChangeLogin() {
  const profile = DB.profile;
  const isBoss = !!(profile && profile.role === "boss");
  const label = isBoss ? "账号" : "员工号";

  openSheet("改" + label, `
    <label for="cl-new">新的${label}</label>
    <input id="cl-new" autocapitalize="off"
           value="${escapeHtml(profile ? profile.code : "")}">
    <div class="hint" style="margin-top:4px">
      字母、数字和 <code>. _ -</code>，3~20 位，不要中文或空格。
      改完下次登录用新${label}，密码不变。
    </div>
    <div id="cl-error" class="login-error hidden"></div>
  `, [
    { label: "取消", onClick: closeSheet },
    { label: "保存", kind: "", onClick: () => submitChangeLogin() },
  ]);
}

async function submitChangeLogin() {
  const box = $("cl-error");
  box.classList.add("hidden");
  const buttons = $("sheet-foot").querySelectorAll(".btn");
  const submit = buttons[buttons.length - 1];
  if (submit) { submit.disabled = true; submit.textContent = "保存中…"; }
  try {
    const code = await changeMyLogin($("cl-new").value);
    closeSheet();
    renderMe();
    toast("登录名已改成 " + code);
  } catch (error) {
    box.textContent = error.message;
    box.classList.remove("hidden");
  } finally {
    if (submit) { submit.disabled = false; submit.textContent = "保存"; }
  }
}

/* 注销账号。**两段确认 + 验密码**——这是不可恢复的操作。 */
function openDeleteAccount() {
  const profile = DB.profile;
  const isBoss = !!(profile && profile.role === "boss");
  openSheet("注销账号", `
    <div class="banner bad">
      不能撤销。云端这个账号${isBoss ? "和你名下所有员工" : ""}
      的任务、工时都会被永久删除。
    </div>
    ${isBoss
      ? '<div class="hint" style="margin-top:0">你的员工还在用的话，'
        + "他们会一起被删掉。</div>"
      : ""}

    <label for="da-password">输入密码确认</label>
    <input id="da-password" type="password">

    <label for="da-confirm">再输入一遍这个字：<b>注销</b></label>
    <input id="da-confirm" autocapitalize="off">

    <div id="da-error" class="login-error hidden"></div>
  `, [
    { label: "取消", onClick: closeSheet },
    { label: "永久注销", kind: "danger", onClick: () => submitDeleteAccount() },
  ]);
}

async function submitDeleteAccount() {
  const box = $("da-error");
  box.classList.add("hidden");
  const fail = message => {
    box.textContent = message;
    box.classList.remove("hidden");
  };

  if ($("da-confirm").value.trim() !== "注销") {
    return fail("请把「注销」两个字照着输一遍");
  }
  const password = $("da-password").value;
  if (!password) return fail("请输入密码");

  const buttons = $("sheet-foot").querySelectorAll(".btn");
  const submit = buttons[buttons.length - 1];
  if (submit) { submit.disabled = true; submit.textContent = "注销中…"; }
  /* 先记下来：deleteMyAccount 会把 DB.profile 清空，之后再读就没了 */
  const gone = DB.profile;
  try {
    await deleteMyAccount(password);
    /* **注销了就把保存的密码一起删掉。**

       账号都没了，本机还留着它的密码既没用又危险。 */
    if (gone) forgetAccount(gone.code, gone.role);
    closeSheet();
    renderLogin();
    showPage("login");
    toast("账号已注销");
  } catch (error) {
    fail(error.message);
  } finally {
    if (submit) { submit.disabled = false; submit.textContent = "永久注销"; }
  }
}

/* 老板重置员工的密码。
   员工忘了密码时唯一的出路——以前只能去 Supabase 后台。 */
function openResetStaffPassword(account) {
  openSheet("重置 " + account.name + " 的密码", `
    <label for="rp-new">新的初始密码</label>
    <input id="rp-new" value="${escapeHtml(account.password || "")}">
    <div class="hint" style="margin-top:4px">
      不需要旧密码。
    </div>

    <div id="rp-error" class="login-error hidden"></div>
  `, [
    { label: "取消", onClick: closeSheet },
    { label: "重置", kind: "", onClick: () => submitResetStaffPassword(account) },
  ]);
}

async function submitResetStaffPassword(account) {
  const box = $("rp-error");
  box.classList.add("hidden");
  const newPassword = $("rp-new").value;
  if (String(newPassword).length < 6) {
    box.textContent = "密码至少要 6 位";
    box.classList.remove("hidden");
    return;
  }

  const buttons = $("sheet-foot").querySelectorAll(".btn");
  const submit = buttons[buttons.length - 1];
  if (submit) { submit.disabled = true; submit.textContent = "重置中…"; }
  try {
    await resetStaffPassword(account.employee_id, newPassword);
    closeSheet();
    renderStaff();
    toast("已重置。" + account.name + " 现在用 "
      + newPassword + " 登录");
  } catch (error) {
    box.textContent = error.message;
    box.classList.remove("hidden");
  } finally {
    if (submit) { submit.disabled = false; submit.textContent = "重置"; }
  }
}

/* ---------------------------------------------------------- 老板：员工账号 */

function renderStaff() {
  const list = staffAccounts();
  const box = $("staff-list");
  if (!list.length) {
    box.innerHTML = '<div class="empty">还没有员工账号。</div>';
    updateStaffRetryButton();
    return;
  }
  const employeesById = {};
  (DB.employees || []).forEach(item => {
    employeesById[String(item.id)] = item;
  });

  box.innerHTML = list.map(account => {
    /* 两种状态要说清楚，别让老板猜：
         pending  → 云端没建成（附原因）
         否则      → 已生效，员工可以登录 */
    const statusLine = account.pending
      ? '<div class="meta" style="color:var(--watch)">云端没建成'
        + (account.lastError ? "：" + escapeHtml(account.lastError) : "")
        + "</div>"
      : '<div class="meta" style="color:var(--ok)">可登录'
        + (account.lastNote ? "（" + escapeHtml(account.lastNote) + "）" : "")
        + "</div>";
    /* **这个人的源点和工时。**

       这是"记忆源点"系统，老板进员工账号页八成是想看
       "这个人干得怎么样"，只给姓名和工号等于白来一趟。
       数字直接从本地流水和上下工记录算，不用额外请求。 */
    const uid = String(account.employee_id || "");
    const points = uid ? meritBalance(uid) : 0;
    const weekStart = weekAgoKey();
    const weekHours = (DB.workSessions || [])
      .filter(row => String(row.profile_id) === uid && row.ended_at)
      .filter(row => meritDayKey(row.created_at || row.started_at) >= weekStart)
      .reduce((sum, row) => sum + num(row.hours), 0);
    const statLine = uid
      ? '<div class="staff-stat">'
        + '<span class="staff-points">' + meritNumber(points) + " " + MERIT.unit
        + '</span>'
        + '<span class="staff-hours">本周 ' + (Math.round(weekHours * 10) / 10)
        + ' 小时</span></div>'
      : "";

    return `
      <div class="card">
        <div class="row">
          <div class="grow">
            <b>${escapeHtml(account.name)}</b>
            <div class="meta">${escapeHtml(account.code)}</div>
            ${statusLine}
            ${statLine}
          </div>
          <button class="icon-btn" data-staff-edit="${account.id}">查看</button>
        </div>
      </div>`;
  }).join("");

  box.querySelectorAll("[data-staff-edit]").forEach(button => {
    button.onclick = () => {
      const account = staffAccounts().find(item =>
        item.id === button.dataset.staffEdit);
      if (account) editStaff(account);
    };
  });

  updateStaffRetryButton();
}

/* 还有账号没建成功时，把"重试创建"按钮点亮并显示数量。
   都建好了就禁用——点了没反应比按钮变灰更让人困惑。 */
function updateStaffRetryButton() {
  const box = $("staff-retry-box");
  const pending = staffAccounts().filter(item => item.pending).length;

  /* **没有待创建的账号时，整块卡片都不出现。**

     原来这里常驻一个灰色按钮写着「全部已在云端生效」——
     在一个账号都没有的时候，这句话既没用又占地方
     （还会留下一张空白卡片）。
     只有真有账号没建成，才需要这块东西去补。 */
  if (box) box.classList.toggle("hidden", pending === 0);

  const button = $("btn-sync-staff");
  if (button) {
    button.disabled = pending === 0;
    button.textContent = pending
      ? `重试创建（还有 ${pending} 个没建成功）`
      : "重试创建";
  }

  /* **说明只在需要时出现。**

     原来页面上常驻三段解释（"建号是一次完成的""这个按钮只在没网时
     有用""密码明文存在本机"）——正常使用时一个都不需要。
     现在只有真有账号没建成时才写一句，而且就说"怎么办"。 */
  const hint = $("staff-retry-hint");
  if (hint) {
    hint.innerHTML = pending
      ? "这几个账号是在<b>没网的时候</b>建的，云端还没有。"
        + "连上网点上面这个按钮补齐。"
      : "";
  }
}

function editStaff(account) {
  const employee = (DB.employees || []).find(item =>
    String(item.id) === String(account.employee_id));
  openSheet("员工账号", `
    <label>姓名</label>
    <div class="meta" style="padding:6px 0">${escapeHtml(account.name)}</div>
    <label>员工号</label>
    <div class="meta" style="padding:6px 0">${escapeHtml(account.code)}</div>
    <label>密码</label>
    <div class="meta" style="padding:6px 0">${escapeHtml(account.password)}</div>
    <label>云端状态</label>
    <div class="meta" style="padding:6px 0">
      ${account.pending
        ? "没建成" + (account.lastError
            ? "：" + escapeHtml(account.lastError) : "")
        : "已生效（" + escapeHtml(String(account.cloud_id || "").slice(0, 8))
          + "…）"}
    </div>
  `, [
    { label: "关闭", onClick: closeSheet },
    /* **重置密码**：员工忘了密码时唯一的出路。
       以前只能去 Supabase 后台，手机上办不到。 */
    ...(!account.pending ? [{ label: "重置密码", kind: "", onClick: () => {
      closeSheet();
      openResetStaffPassword(account);
    } }] : []),
    ...(account.pending ? [{ label: "重试创建", kind: "", onClick: async () => {
      const ok = await createCloudStaff(account);
      closeSheet();
      renderStaff();
      toast(ok ? "创建成功，员工现在可以登录了"
               : "还是失败：" + (account.lastError || ""));
    } }] : []),
    ...(employee ? [{ label: "删除员工", kind: "danger", onClick: () => {
      if (!confirm(`删除 ${account.name}？\n\n`
          + "本机的员工记录和工时会一起删掉。\n"
          + "云端的账号要用「注销账号」或者去 Supabase 后台删。")) return;
      DB.staffAccounts = staffAccounts().filter(item => item.id !== account.id);
      deleteEmployee(employee.id);
      closeSheet();
      renderStaff();
      toast("已删除");
    } }] : []),
  ]);
}

/* ---------------------------------------------------------- 老板：派任务 */

function renderAssign() {
  const date = $("assign-date").value || todayISO();
  $("assign-date").value = date;
  /* 上一次的选中值失效了吗（员工被重建、uuid 变了）。
     用来在下面提示"请重新选一次"。 */
  let staleSelection = false;

  /* 人员下拉。

     **只列有云端账号的员工。**

     没有云端账号的员工（建号那步失败，employee_id 还是本地自增数字）
     派任务会被 assignTask 拒绝，因为那个数字不是 uuid。
     与其让人选完再报错，不如**根本不列出来**——
     并告诉老板去哪儿把号建好。 */
  const employeeSelect = $("assign-employee");
  const all = staffAccounts();
  const staff = all.filter(account =>
    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
      .test(String(account.employee_id)));
  const notReady = all.length - staff.length;

  if (!all.length) {
    employeeSelect.innerHTML = '<option value="">先建员工账号</option>';
  } else if (!staff.length) {
    employeeSelect.innerHTML =
      '<option value="">员工还没在云端建号</option>';
  } else {
    /* **按工号排序，而且重建后要确认选中值还在。**

       ## 为什么必须检查

       `employeeSelect.value = current` 只在 current **确实存在于
       新列表里**时才生效。employee_id 变化时（createCloudStaff
       就会把它从本地数字换成 uuid）current 匹配不到任何一项，
       浏览器把它设成"未选中" → **select 自动回到第一项**。

       用户反馈过："给别人发任务，结果发到我自己的员工号上了"——
       就是这么来的。任务静默派给了列表里的第一个人。

       assignTask 里已经加了兜底校验（不在名单里就拒绝），
       这里再做一层：**检测到选中值失效就清空选择**，
       让用户必须重新选一次，而不是默默换成别人。 */
    const current = employeeSelect.value;
    const sorted = staff.slice().sort((a, b) =>
      String(a.code).localeCompare(String(b.code)));
    /* **第一项必须是"请选择"占位。**

       下面那句 `value = ""` 是为了不把任务默认派给列表第一个人
       （那会造成"派错人"），但列表里没有 value="" 的项时，
       浏览器会把 selectedIndex 设成 -1 —— 下拉框看上去是**空的**，
       用户以为坏了。加一个占位项，清空时就有字显示。 */
    employeeSelect.innerHTML = '<option value="">请选择员工</option>'
      + sorted.map(account =>
        `<option value="${escapeHtml(String(account.employee_id))}">`
        + `${escapeHtml(account.name)}（${escapeHtml(account.code)}）</option>`
      ).join("");

    if (current && sorted.some(item =>
        String(item.employee_id) === String(current))) {
      employeeSelect.value = current;
    } else {
      /* 选中值失效（或者本来就没选）→ 明确清空，
         并在下面提示一句。**不要让它悄悄变成第一个人。** */
      employeeSelect.value = "";
      staleSelection = !!current;
    }
  }

  /* 提示条：把"名单有变化"和"有员工没建号"都说清楚。

     **选中失效必须明确提示。** 不提示的话，下拉会停在第一项，
     用户以为是刚才选的那个人——**这就是"派错人"的发生方式**。 */
  const warnBox = $("assign-warn");
  if (warnBox) {
    const lines = [];
    if (staleSelection) {
      lines.push("员工名单刚更新过，<b>请重新选一次「派给谁」</b>。");
    }
    if (notReady) {
      lines.push("有 " + notReady + " 个员工还没在云端建号，派不了任务。"
        + "去「团队 → 员工账号」点「重试创建」。");
    }
    warnBox.innerHTML = lines.length
      ? '<div class="banner warn">' + lines.join("<br>") + "</div>"
      : "";
  }

  /* 项目下拉（可选，用来把工时归到项目上） */
  const projectSelect = $("assign-project");
  projectSelect.innerHTML = '<option value="">不关联项目</option>'
    + (DB.projects || []).map(project =>
        `<option value="${escapeHtml(project.name)}">`
        + `${escapeHtml(project.name)}</option>`).join("");

  renderAssignList(date);

  /* **同步完成后要重新渲染这一页。**

     实测踩到：老板打开「派任务」页等着，员工那边拒绝了任务，
     通知确实到了（角标 +1），**但页面上的任务列表一动不动** ——
     必须退出这一页再进来才看得到。

     后果：老板会以为员工没回应，或者以为自己派的没生效。

     所以挂一个同步监听：数据变了就重画。
     只在**这一页正显示着**的时候画，别在后台白费力气。 */
  if (typeof onSyncChange === "function" && !assignSyncBound) {
    assignSyncBound = true;
    onSyncChange(() => {
      const page = $("page-assign");
      if (!page || page.classList.contains("hidden")) return;
      const current = $("assign-date") ? $("assign-date").value : "";
      renderAssignList(current || todayISO());
    });
  }
}

/* 同步监听只绑一次，避免重复注册 */
let assignSyncBound = false;

function renderAssignList(date) {
  const tasks = (DB.tasks || []).filter(item => item.plan_date === date)
    .sort((a, b) => String(a.created_at).localeCompare(String(b.created_at)));
  const box = $("assign-list");
  if (!tasks.length) {
    box.innerHTML = '<div class="meta">还没有任务</div>';
    return;
  }
  const nameById = {};
  staffAccounts().forEach(account => { nameById[account.employee_id] = account.name; });
  (DB.employees || []).forEach(item => {
    if (!nameById[item.id]) nameById[item.id] = item.name;
  });

  box.innerHTML = tasks.map(task => {
    /* 接受状态：老板要能一眼看出"这条员工接了没有"，
       以及"不接的理由是什么"——那通常比任务本身更值得知道。 */
    const status = task.accept_status || "pending";
    let statusLine = "";
    if (status === "pending") {
      statusLine = '<div class="meta">等员工确认</div>';
    } else if (status === "accepted") {
      statusLine = '<div class="meta" style="color:var(--ok)">员工已接受</div>';
    } else if (status === "rejected") {
      statusLine = `<div class="meta" style="color:var(--severe)">`
        + `员工不接受：${escapeHtml(task.accept_reason || "（没写原因）")}</div>`;
    }

    /* 等着批的延期申请 */
    const ext = pendingExtensionFor(task.id);
    const extLine = ext
      ? `<div class="meta" style="color:var(--watch);margin-top:4px">`
        + `申请延期到 ${escapeHtml(String(ext.to_date).slice(0, 10))}`
        + `：${escapeHtml(ext.reason || "")}</div>`
        + `<div class="btn-row" style="margin-top:8px">`
        + `<button class="btn ghost" data-ext-no="${ext.id}">不同意</button>`
        + `<button class="btn" data-ext-yes="${ext.id}">同意延期</button>`
        + `</div>`
      : "";

    /* **完成 / 验收 / 已发分。**

       三段状态，老板一眼要能分清：
         还没干完   → 只写一句灰字
         干完了没验 → 出一个"验收"按钮（这是老板每天要做的动作）
         已经验过   → 显示等级和发出去多少源点 */
    const log = taskLogFor(task.id);
    let gradeLine = "";
    if (task.grade) {
      gradeLine = '<div class="meta" style="margin-top:6px;color:var(--ok)">'
        + '已验收：' + escapeHtml(String(task.grade)) + ' 级 · +'
        + num(task.merit_awarded) + ' ' + MERIT.unit + '</div>';
    } else if (log) {
      gradeLine = '<button class="btn" data-grade-task="'
        + escapeHtml(String(task.id)) + '" '
        + 'style="min-height:42px;padding:0 18px;font-size:14px;margin-top:10px">'
        + '验收 · 发' + MERIT.unit + '</button>';
    } else if (status === "accepted") {
      gradeLine = '<div class="meta" style="margin-top:4px;color:var(--fg-faint)">'
        + '员工还没点完成</div>';
    }

    return `
    <div class="list-item">
      <div class="row">
        <div class="grow">
          <b>${escapeHtml(task.title)}</b>
          <div class="meta">
            ${escapeHtml(nameById[task.employee_id]
              /* **不知道名字时别写"未知"。**

                 实测踩到：员工账号如果是通过接口建的（或者老板换了
                 台手机登录、本地员工缓存还是空的），这里就显示"未知"，
                 老板根本不知道这条任务派给了谁。

                 退而求其次显示 id 前 6 位 —— 不完美，但至少能和
                 别的人区分开，也和数据库里那行对得上。 */
              || "员工 " + String(task.employee_id || "").slice(0, 6))}
            ${num(task.est_hours) > 0 ? " · 预估 " + num(task.est_hours) + " 小时" : ""}
            ${task.project_name ? " · " + escapeHtml(task.project_name) : ""}
            ${(() => {
              /* 员工计时器量出来的实际时长。验收算钱用的是它，
                 预估只作参考，所以两个并排显示。 */
              const log = taskLogFor(task.id);
              if (!log || !log.started_at || !log.finished_at) return "";
              const h = Math.min(24, Math.max(0,
                (new Date(String(log.finished_at).replace(" ", "T")).getTime()
                  - new Date(String(log.started_at).replace(" ", "T")).getTime())
                / 3600000));
              return " · 实际 " + (Math.round(h * 100) / 100) + " 小时";
            })()}
          </div>
          ${statusLine}
          ${extLine}
          ${gradeLine}
        </div>
        <button class="icon-btn" data-assign-del="${escapeHtml(String(task.id))}">删</button>
      </div>
    </div>`;
  }).join("");

  /* 验收：点开四选一，点完立刻发源点 */
  box.querySelectorAll("[data-grade-task]").forEach(button => {
    button.onclick = () => openGradeSheet(button.dataset.gradeTask, date);
  });

  /* 同意延期：直接生效（老板点"同意"通常不想再填什么） */
  box.querySelectorAll("[data-ext-yes]").forEach(button => {
    button.onclick = async () => {
      button.disabled = true;
      try {
        await decideTaskExtension(button.dataset.extYes, true, "");
        toast("已同意，任务挪到新日期");
        renderAssignList(date);
      } catch (error) {
        toast(error.message);
        button.disabled = false;
      }
    };
  });

  /* 不同意：给个机会写一句说明，员工那边能看到 */
  box.querySelectorAll("[data-ext-no]").forEach(button => {
    button.onclick = () => {
      openExtensionDecisionSheet(button.dataset.extNo, date);
    };
  });

  box.querySelectorAll("[data-assign-del]").forEach(button => {
    button.onclick = () => {
      if (!confirm("删掉这条任务？员工那边也会消失。")) return;
      deleteTask(button.dataset.assignDel);
      renderAssignList(date);
      toast("已删除");
    };
  });
}

/* 老板：验收一条已完成的任务。

   四个选项一次点定，不再问第二遍 —— 老板要的是快。
   每个选项后面直接写着"点下去发多少源点"，不用心算。 */
function openGradeSheet(taskId, date) {
  const task = taskById(taskId);
  if (!task) { toast("任务不见了"); return; }

  const base = taskBaseMerit(task);
  const from = taskMeritSource(task);
  const hours = from.hours;

  const options = ["S", "A", "B", "C"].map(grade => {
    const amount = taskGradeAmount(task, grade);
    const percent = Math.round((MERIT.grade[grade] || 0) * 100);
    return '<button class="grade-option" data-grade="' + grade + '">'
      + '<span class="grade-letter">' + grade + '</span>'
      + '<span class="grade-main">'
      + '<span class="grade-label">' + MERIT.gradeText[grade]
      + (percent !== 100 ? '（' + percent + '%）' : '') + '</span>'
      + '<span class="grade-amount">'
      + (amount > 0 ? "+" + amount + " " + MERIT.unit : "不发")
      + '</span></span></button>';
  }).join("");

  openSheet("验收：" + task.title, `
    <div class="hint" style="margin-bottom:12px">
      ${from.kind === "actual"
        ? "实际做了 " + hours + " 小时"
          + (num(task.est_hours) > 0
            ? "（预估 " + num(task.est_hours) + " 小时，仅参考）" : "")
        : (hours > 0 ? "没有计时记录，按预估 " + hours + " 小时" : "没有工时")}
      ，满额 ${base} ${MERIT.unit}
    </div>
    <div class="grade-list">${options}</div>
  `, [
    { label: "以后再说", onClick: closeSheet },
  ]);

  const box = $("sheet-body");
  if (!box) return;
  box.querySelectorAll("[data-grade]").forEach(button => {
    button.onclick = async () => {
      const grade = button.dataset.grade;
      box.querySelectorAll(".grade-option").forEach(item => {
        item.disabled = true;
      });
      button.classList.add("picked");
      try {
        const result = await gradeTask(taskId, grade);
        closeSheet();
        renderAssignList(date);
        const amount = result && result.amount !== undefined
          ? num(result.amount) : taskGradeAmount(task, grade);
        toast(grade + " 级已验收"
          + (amount > 0 ? "，" + amount + " " + MERIT.unit + " 已到账" : "，不发源点"));
      } catch (error) {
        toast(error.message);
        box.querySelectorAll(".grade-option").forEach(item => {
          item.disabled = false;
        });
        button.classList.remove("picked");
      }
    };
  });
}

/* 老板：不同意延期时写一句说明。说明是可选的——
   有时候就是"明天也不行"，没必要逼他写。 */
function openExtensionDecisionSheet(requestId, date) {
  const req = (DB.taskRequests || []).find(item =>
    String(item.id) === String(requestId));
  if (!req) { toast("这条申请已经不存在了"); return; }
  const task = taskById(req.task_id);

  openSheet("不同意延期", `
    <div class="meta" style="padding-bottom:10px">
      ${escapeHtml(task ? task.title : "（任务已删除）")}
    </div>
    <div class="meta">
      员工想把任务挪到
      <b>${escapeHtml(String(req.to_date).slice(0, 10))}</b>，
      理由是：${escapeHtml(req.reason || "")}
    </div>
    <label class="meta" style="display:block;padding-top:10px">
      给员工的说明（可以不填）
    </label>
    <textarea id="ext-note" rows="3" style="width:100%;margin-top:6px"></textarea>
  `, [
    { label: "取消", onClick: closeSheet },
    { label: "确定不同意", kind: "danger", onClick: async () => {
      const box = document.getElementById("ext-note");
      const note = box ? String(box.value || "").trim() : "";
      closeSheet();
      try {
        await decideTaskExtension(requestId, false, note);
        toast("已驳回");
        renderAssignList(date);
      } catch (error) { toast(error.message); }
    } },
  ]);
}

function submitAssign() {
  try {
    /* 记住派给谁了——**成功提示里要说出来**。

       原来只提示"已派发，员工登录后会看到"，
       万一选错了人，用户完全看不出来。现在把名字报出来，
       选错的话自己就发现了。 */
    const employeeId = $("assign-employee").value;
    const account = staffAccounts().find(item =>
      String(item.employee_id) === String(employeeId));

    assignTask({
      title: $("assign-title").value,
      detail: $("assign-detail").value,
      employee_id: employeeId,
      plan_date: $("assign-date").value || todayISO(),
      est_hours: $("assign-hours").value,
      project_name: $("assign-project").value,
    });
    $("assign-title").value = "";
    $("assign-detail").value = "";
    renderAssignList($("assign-date").value || todayISO());
    toast(account
      ? "已派给 " + account.name + "（" + account.code + "）"
      : "已派发，员工登录后会看到");
  } catch (error) {
    toast(error.message);
  }
}

/* ---------------------------------------------------------- 老板：建员工账号 */

/* 新建员工账号。

   现在**一次就建好了**：走数据库函数 `create_staff_account`，
   它建号 + 认领 + 同步 id 全部在服务端完成。

   （以前要在 Supabase 后台手动建一遍再来认领，因为客户端的
     signUp 会把老板自己顶下线。用 SECURITY DEFINER 函数绕过了
     那个限制，同时不用把管理密钥打进 apk。） */
function editNewStaff() {
  openSheet("新建员工账号", `
    <label for="st-name">员工姓名 *</label>
    <input id="st-name">

    <label for="st-code">员工号 *</label>
    <input id="st-code" autocapitalize="off" placeholder="字母或数字，3~20 位">

    <label for="st-email">邮箱 *</label>
    <input id="st-email" inputmode="email" autocapitalize="off"
           placeholder="员工忘了密码时收验证码用">

    <label for="st-password">初始密码 *</label>
    <input id="st-password">

    <div class="row2">
      <div><label for="st-role">岗位</label>
        <input id="st-role"></div>
      <div><label for="st-weekly">周工时</label>
        <input id="st-weekly" type="number" value="40"></div>
    </div>

    <div class="hint">
      员工号不能和别人重复。建好把<b>员工号</b>和<b>密码</b>告诉员工。
    </div>
  `, [
    { label: "取消", onClick: closeSheet },
    { label: "创建", kind: "", onClick: () => submitNewStaff() },
  ]);
}

async function submitNewStaff() {
  const button = $("sheet-foot").querySelector(".btn:not(.ghost)");
  const name = $("st-name").value;
  const code = $("st-code").value;
  if (button) { button.disabled = true; button.textContent = "创建中…"; }
  try {
    const account = await createEmployeeLocal({
      name: name,
      code: code,
      email: $("st-email").value,
      password: $("st-password").value,
      role: $("st-role").value,
      weekly_hours: $("st-weekly").value,
    });
    closeSheet();
    renderStaff();

    if (account.pending) {
      /* 本地建好了但云端没建成。**必须说清楚是哪一种失败**，
         否则老板以为建成功了，员工却登不上。 */
      toast("已存到本机，但云端没建成功：" + (account.lastError || ""));
    } else {
      toast(`已创建：${account.name}（员工号 ${account.code}）`);
      if (navigator.vibrate) navigator.vibrate(16);
    }
  } catch (error) {
    toast(error.message);
    if (button) { button.disabled = false; button.textContent = "创建"; }
  }
}

/* 同步账号：把云端已经建好的员工账号认领成自己的员工。

   做法：拉取 profiles 表，找出 role=employee 且还没绑老板的记录，
   和本地 staffAccounts 按工号对上，然后把 boss_id 写成自己。

   这一步需要 profiles 表有对应的 RLS 策略允许老板更新自己的员工
   （建表 SQL 里的 "boss updates staff"）。 */
/* 重试创建还没建成功的员工账号。

   现在建号是**一次调用就完成**的（走数据库函数 create_staff_account），
   所以不再需要「先记本地、再去后台建号、最后回来认领」那一套。
   这个按钮只处理一种情况：**当时没网**，账号只存了本地，
   联网后点一下补齐。 */
async function retryStaffFromUI() {
  const pending = staffAccounts().filter(item => item.pending);
  if (!pending.length) { toast("没有需要重试的账号"); return; }
  if (!initCloud()) { toast("云服务连不上，检查一下网络"); return; }

  const button = $("btn-sync-staff");
  if (button) { button.disabled = true; button.textContent = "创建中…"; }
  try {
    const result = await retryPendingStaff();
    renderStaff();
    if (result.failures.length) {
      toast(result.done + " 个建好了，" + result.failures.length
        + " 个还是失败：" + result.failures[0]);
    } else {
      toast("全部创建成功，" + result.done + " 个员工现在可以登录了");
    }
  } catch (error) {
    toast(error.message);
  } finally {
    updateStaffRetryButton();
  }
}

/* 旧名字保留成别名——免得别处还引用它时直接报未定义。 */
const syncStaffAccounts = retryStaffFromUI;

/* 员工端的「更多」菜单。员工只有这几件事可做。 */
function openStaffMenu() {
  const status = syncStatus();
  openSheet("更多", `
    <div class="meta" style="padding:4px 0 10px">
      ${DB.profile ? escapeHtml(DB.profile.name + "（" + DB.profile.code + "）") : "未登录"}
      <br>${status.pending > 0
        ? `<span style="color:var(--watch)">${status.pending} 条还没上传</span>`
        : "所有记录都已上传"}
      ${status.last && status.last.at
        ? `<br>上次同步 ${escapeHtml(String(status.last.at).slice(11, 16))}` : ""}
    </div>
    <button class="btn ghost" id="sm-sync" style="width:100%">立即同步</button>
    <div style="height:10px"></div>
    <button class="btn ghost" id="sm-theme" style="width:100%">
      切换主题（当前：${escapeHtml(chartTheme === "dark" ? "深色" : "浅色")}）</button>
    <div style="height:10px"></div>
    <button class="btn danger" id="sm-logout" style="width:100%">退出登录</button>
  `, [{ label: "关闭", onClick: closeSheet }]);

  $("sm-sync").onclick = () => {
    closeSheet();
    syncNow("manual").then(result => {
      /* 这个菜单在任务页和「我的」页都可能打开，
         两个都刷新一下，避免显示的待上传数量是旧的。 */
      renderTasks();
      renderMe();
      toast(result && result.pending
        ? `还有 ${result.pending} 条待上传` : "已同步");
    });
  };
  $("sm-theme").onclick = () => {
    const next = chartTheme === "dark" ? "light" : "dark";
    applyTheme(next);
    closeSheet();
    showPage(currentPageName());
    toast("已切到" + (next === "dark" ? "深色" : "浅色"));
  };
  $("sm-logout").onclick = () => { closeSheet(); logout(); };
}


function openCloudSettings() {
  const config = syncConfig();
  openSheet("云服务设置", `
    <label for="cloud-url">Supabase Project URL</label>
    <input id="cloud-url" value="${escapeHtml(config.url)}" autocapitalize="off">
    <div class="hint" style="margin-top:6px">
      <b>只填到 .supabase.co 为止，后面不要带 /rest/v1/</b>。<br>
      后台那一排复制按钮里，请点 <b>Project URL</b> 那个；
      复制到 <code>RESTful endpoint</code> 或 <code>Auth endpoint</code>
      的话会多出路径，登录时报
      "Invalid path specified in request URL"。<br>
      多粘了也没关系——保存时会自动裁掉。
    </div>

    <label for="cloud-key">anon public key</label>
    <textarea id="cloud-key" rows="3" autocapitalize="off">${escapeHtml(config.key)}</textarea>
    <div class="hint">
      在 <b>Project Settings → API</b> 里找 <b>Project API keys</b>，
      复制 <b>anon</b> <b>public</b> 那一个。
      <br><br>
      anon key 打进 apk 是安全的——数据安全靠服务端的
      行级权限策略保证。**不要填 service_role key**，
      那个是管理密钥，泄露等于数据库裸奔。
    </div>
  `, [
    { label: "取消", onClick: closeSheet },
    { label: "保存", kind: "", onClick: () => {
      saveSyncConfig($("cloud-url").value, $("cloud-key").value);
      initCloud();
      closeSheet();
      renderLogin();
      applyRoleUI();
      toast("已保存");
    } },
  ]);
}
