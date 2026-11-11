/* =============================================================
   主程序：页面切换、渲染、表单、计时、导航。

   组织方式：
     · 一个 showPage() 管页面切换，每页一个 render 函数
     · 表单统一走 openSheet()，避免每个功能写一套弹层
     · 渲染函数只读 DB 和 calc，不自己算东西

   错误处理：
     手机上没法看 Console，所以任何异常都要**显示在页面上**。
     顶层的 window.onerror 兜住漏出来的错误，
     表单里的错误就近用 toast 提示。
   ============================================================ */
"use strict";

/* ---------------------------------------------------------- 启动 */
window.addEventListener("error", event => {
  showBootError("出错了", (event.error && event.error.stack)
    || event.message || String(event));
});

function queueLocalProjectsForCloud() {
  const projects = (DB.projects || []).filter(item => !item.remote_id);
  if (!projects.length) {
    toast("没有需要上传的本机项目");
    return 0;
  }
  projects.forEach(project => {
    queueProjectSync(project, "upsert");
    (DB.steps || []).filter(step => step.project_id === project.id)
      .forEach(step => queueStepSync(step, "upsert"));
  });
  saveAll();
  if (typeof syncNow === "function") syncNow("project-confirm");
  toast(`已排队上传 ${projects.length} 个本机项目`);
  return projects.length;
}

async function runSystemDiagnosis() {
  const box = $("system-health-result");
  if (!box) return;
  const local = typeof localSyncDiagnostics === "function"
    ? localSyncDiagnostics() : {};
  const pending = Number(local.pending || 0);
  const localHtml = '<div class="banner ' + (pending || local.pullError
      ? "warn" : "good") + '">'
    + (pending ? '本机还有 ' + pending + ' 条待上传数据'
      : local.pullError ? '上次拉取有异常' : '本机账号数据与队列正常')
    + '</div>'
    + '<div class="identity-meta-grid" style="margin-top:10px">'
    + '<div><span>当前账号</span><b>' + escapeHtml((DB.profile && DB.profile.code) || "未登录") + '</b></div>'
    + '<div><span>当前公司</span><b>' + escapeHtml(local.company_id || "未确定") + '</b></div>'
    + '<div><span>最近同步</span><b>' + escapeHtml((local.lastSync && local.lastSync.at) || "尚未同步") + '</b></div>'
    + '<div><span>自动备份</span><b>' + num(local.backup_count) + ' 份</b></div>'
    + '</div>'
    + (local.conflicts
      ? '<div class="banner warn" style="margin-top:8px">有 ' + num(local.conflicts)
        + ' 条同步冲突，云端和本机版本都已保留。</div>'
        + (local.conflict_items || []).map(item => '<div class="today-ledger-row">'
          + '<div><b>' + escapeHtml(item.table + ' · ' + (item.fields || []).join('、'))
          + '</b><span>记录 ' + escapeHtml(item.key) + '</span></div>'
          + '<div class="btn-row"><button class="identity-small-btn" data-conflict-local="'
          + escapeHtml(item.id) + '">用本机</button>'
          + '<button class="identity-small-btn" data-conflict-cloud="'
          + escapeHtml(item.id) + '">用云端</button></div></div>').join("")
      : "")
    + (local.pullError ? '<div class="banner bad" style="margin-top:8px">拉取失败：'
      + escapeHtml(local.pullError) + '</div>' : "")
    + (local.failures || []).map(item => '<div class="today-ledger-row">'
      + '<div><b>' + escapeHtml(item.table || "待上传") + '</b><span>'
      + escapeHtml(item.error || "") + '</span></div></div>').join("")
    + (local.legacy_available
      ? '<div class="banner warn" style="margin-top:8px">发现旧版本未归属数据 '
        + num((local.legacy_summary || {}).total || 0)
        + ' 条，可手动确认导入当前账号。</div>'
        + '<button class="btn ghost" id="btn-legacy-claim" style="width:100%;margin-top:8px">'
        + '导入旧数据到当前账号</button>' : "")
    + ((DB.projects || []).filter(item => !item.remote_id).length
      ? '<div class="banner warn" style="margin-top:8px">本机有 '
        + (DB.projects || []).filter(item => !item.remote_id).length
        + ' 个项目尚未同步到公司。确认后才会上传，不会自动改动云端。</div>'
        + '<button class="btn ghost" id="btn-local-projects" style="width:100%;margin-top:8px">'
        + '确认为当前公司上传本机项目</button>' : "")
    + '<div class="btn-row" style="margin-top:10px">'
    + '<button class="btn ghost" id="btn-local-backup">立即备份</button>'
    + '<button class="btn" id="btn-local-sync">立即同步</button></div>';

  const bindLocalButtons = () => {
    if ($("btn-local-backup")) {
      $("btn-local-backup").onclick = () => {
        try {
          const key = backupCurrentDatabase("manual-diagnostic");
          toast(key ? "本机数据已备份" : "当前没有可备份的数据");
          runSystemDiagnosis();
        } catch (error) { toast(String(error.message || error)); }
      };
    }
    if ($("btn-legacy-claim")) {
      $("btn-legacy-claim").onclick = () => {
        if (!confirm("把旧版本本机数据导入当前账号？\n\n会先自动备份，旧队列不会自动上传。")) return;
        claimLegacyDataForCurrentAccount();
        runSystemDiagnosis();
        toast("旧数据已导入当前账号");
      };
    }
    document.querySelectorAll("[data-conflict-local]").forEach(button => {
      button.onclick = async () => {
        await resolveSyncConflict(button.dataset.conflictLocal, "local");
        runSystemDiagnosis();
      };
    });
    document.querySelectorAll("[data-conflict-cloud]").forEach(button => {
      button.onclick = async () => {
        await resolveSyncConflict(button.dataset.conflictCloud, "cloud");
        runSystemDiagnosis();
      };
    });
    if ($("btn-local-projects")) {
      $("btn-local-projects").onclick = () => {
        if (!confirm("把本机尚未同步的项目和步骤上传到当前公司？")) return;
        queueLocalProjectsForCloud();
        runSystemDiagnosis();
      };
    }
    if ($("btn-local-sync")) {
      $("btn-local-sync").onclick = async () => {
        await syncNow("diagnostic");
        runSystemDiagnosis();
      };
    }
  };

  if (!DB.profile) {
    box.innerHTML = localHtml + '<div class="meta" style="margin-top:10px">登录后可继续检查云端数据库。</div>';
    bindLocalButtons();
    return;
  }
  if (!initCloud()) {
    box.innerHTML = localHtml + '<div class="banner warn" style="margin-top:10px">云组件未加载，无法检查云端。</div>';
    bindLocalButtons();
    return;
  }
  box.innerHTML = localHtml + '<div class="meta" style="margin-top:10px">正在检查云端数据库…</div>';
  bindLocalButtons();
  try {
    await ensureFreshCloudSession();
    const { data, error } = await cloudClient.rpc("get_platform_health");
    if (error) throw error;
    const checks = Array.isArray(data && data.checks) ? data.checks : [];
    const failed = checks.filter(item => !item.ok);
    const migrations = Array.isArray(data && data.migrations) ? data.migrations.length : 0;
    box.innerHTML = localHtml
      + (failed.length
        ? '<div class="banner bad">云端缺少 ' + failed.length + ' 项数据库功能。</div>'
        : '<div class="banner good">云端账号、数据库和核心功能检查通过。</div>')
      + '<div class="meta" style="margin-top:8px">已登记迁移 ' + migrations
      + ' 项 · 服务器时间 ' + escapeHtml(String(data && data.server_time || "")) + '</div>'
      + checks.map(item => '<div class="today-ledger-row"><div><b>'
        + escapeHtml(item.label || item.key) + '</b></div><strong>'
        + (item.ok ? "正常" : "缺失") + '</strong></div>').join("");
  } catch (error) {
    box.innerHTML = localHtml + '<div class="banner bad" style="margin-top:10px">云端诊断失败：'
      + escapeHtml(String(error.message || error)) + '</div>';
  }
  bindLocalButtons();
}
function showBootError(title, detail) {
  const box = document.getElementById("boot-error");
  box.innerHTML = "<b>" + escapeHtml(title) + "</b>"
    + escapeHtml(String(detail || ""));
  box.classList.remove("hidden");
}

function boot() {
  const lastAccountId = getSetting("last_account_id", "");
  DB = loadAll(lastAccountId ? accountDatabaseKey(lastAccountId) : undefined);

  /* Upgrade path: an old install has only the shared legacy database.
     Create the account-owned database without moving business data. The
     ownership prompt decides later whether old records belong to this user. */
  if (currentDatabaseKey === DB_KEY && DB.profile && DB.profile.id) {
    const legacyProfile = DB.profile;
    ensureAccountDatabase(String(legacyProfile.id));
    DB.profile = legacyProfile;
    DB.account_scope_id = String(legacyProfile.id);
    saveAll();
  }

  applyTheme(getSetting("theme", "light"));
  makeNavScrollable();
  bindGlobalEvents();
  if (typeof bindAppUpdateEvents === "function") bindAppUpdateEvents();
  if (typeof checkForAppUpdate === "function") {
    setTimeout(() => checkForAppUpdate(false), 1800);
  }

  /* 进哪个页面：

       登录了        → 员工进任务页，老板进看板
       没登录        → **一律进登录页**

     ## 为什么没配云服务也要进登录页

     我原来的逻辑是"没配云服务就直接进看板（单机模式）"，
     想的是"别拿登录页烦只想本地记事的用户"。

     但那样有个死循环：**配置云服务的入口就在登录页上**，
     不进登录页就配不了，配不了就永远不进登录页。
     结果用户装了之后完全看不到账号功能，以为没做。

     现在改成一律进登录页，那里有：
       · 身份选择（老板 / 员工）—— 这样区分一眼就能看到
       · 云服务设置入口
       · 「先不登录，只用本机功能」的出口

     **离线也要能进主界面**：DB.profile 是本地副本，
     所以没网时已经登录过的人不会被挡在门外。 */
  const status = syncStatus();
  if (status.signedIn) {
    resumeSession();
    const previewParams = new URLSearchParams(location.search); const requestedPage = previewParams.get("page"); const commentPreview = previewParams.get("v") === "comment-direct"; if (requestedPage === "community" || commentPreview) { showPage("community"); } else { showPage(typeof mobileHomePage === "function" ? mobileHomePage() : "today"); }

    /* **启动时核对一次登录会话。**

       DB.profile 是本机存的副本，**它还在不代表登录还有效**。
       会话可能早就没了（换机、重装、令牌过期又刷新失败），
       这时所有写入都会以匿名身份发出去，被服务端的 RLS 全部拒掉：

           new row violates row-level security policy for table "task_logs"

       而界面上只会显示"同步失败"，看不出是"没登录了"。

       restoreSession() 会从本机存储里恢复会话；恢复不出来
       就保持原样（离线也能继续用），但**界面会明确提示要重新登录**。 */
    if (typeof restoreSession === "function") {
      restoreSession().then(() => {
        if (typeof renderMe === "function") renderMe();
        if (typeof renderToday === "function") renderToday();
        if (typeof refreshIdentity === "function") refreshIdentity(false);
      }).catch(() => { /* 没网时失败是正常的，不影响 */ });
    }

    /* **启动时就把通知渠道建好。**

       以前只在"登录 / 恢复会话"的路径上调 refreshNotifyPermission()。
       已经登录的人装完新版本直接进主界面，那次调用会走到，
       但如果中途出任何岔子（比如权限已经是 granted，就不申请了），
       渠道可能一直没建——**没渠道就没有弹窗横幅**，
       表现是"通知进了下拉栏但不弹"。

       这里无条件调一次：建渠道是幂等的，
       权限已给的话也不会再弹框烦人。 */
    if (typeof ensureNotifyChannel === "function") {
      ensureNotifyChannel();
    }

    /* **启动时也确认一次推送设备登记。**

       这条不能只靠 resumeSession() 里那次：
         · resumeSession 前面任何一句抛异常，后面的就都不执行了
         · 换签名重装后 CID 会变，必须重新登记一次；
           而"没登记"是完全静默的——推送发到旧地址，手机永远收不到

       函数内部会自己确保云客户端就绪，失败原因也会记下来并显示，
       所以这里无条件调一次，代价很小。 */
    if (typeof ensureGetuiPushConsent === "function") {
      ensureGetuiPushConsent();
    }
    /* 不在每次冷启动发“App 已就绪”的测试通知，避免和真实任务提醒混淆。
       通知链路需要验证时，使用通知中心里的“测试弹窗”按钮。 */
    if (typeof refreshNotifyPermission === "function") {
      refreshNotifyPermission().then(() => renderMe());
    }

  } else {
    showPage("login");
  }
}

/* 切换主题：**界面和图表一起变**。

   之前只调了 setChartTheme()，那只改了 Canvas 的颜色，
   界面的 CSS 变量没动——所以看起来像「切了没反应」。
   现在两件事一起做：
     · applyThemeVariables() 把配色写成 CSS 变量给界面用
     · setChartTheme() 让图表下次重画时取新色
   两处的值来自同一个 THEME_COLORS，不会不同步。 */
function applyTheme(name) {
  const theme = name === "dark" ? "dark" : "light";
  setChartTheme(theme);
  applyThemeVariables(theme);
  saveSetting("theme", theme);
  return theme;
}

/* ---------------------------------------------------------- 小工具 */
function $(id) { return document.getElementById(id); }

function escapeHtml(value) {
  return String(value === null || value === undefined ? "" : value)
    .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function toast(text) {
  const box = $("toast");
  box.textContent = text;
  box.classList.remove("hidden");
  clearTimeout(toast._timer);
  toast._timer = setTimeout(() => box.classList.add("hidden"), 2800);
}

function setBanner(element, text, kind) {
  element.innerHTML = text
    ? `<div class="banner ${kind || "info"}">${escapeHtml(text)}</div>` : "";
}

/* 底部导航要占位置，所以这些页面的 body 要留出底部空间。
   登录页和派任务页没有导航，不用留。 */
function updateNavScrollCue() {
  const nav = $("nav");
  const cue = $("nav-scroll-cue");
  if (!nav || !cue) return;
  const maxScroll = Math.max(0, nav.scrollWidth - nav.clientWidth);
  const canScroll = maxScroll > 2;
  nav.classList.toggle("scrollable", canScroll);
  cue.classList.toggle("hidden", !canScroll);
  if (!canScroll) return;

  const atStart = nav.scrollLeft <= 2;
  const atEnd = nav.scrollLeft >= maxScroll - 2;
  cue.textContent = atStart ? "›" : atEnd ? "‹" : "↔";
  cue.title = atStart ? "向右拖动查看更多入口"
            : atEnd ? "向左拖动返回前面的入口"
            : "左右拖动查看更多入口";
}

/* 电脑预览没有手机触屏，补一套鼠标拖动和滚轮横滑。
   触摸设备继续走浏览器原生横滑，不抢它的手势。 */
function enableNavDrag() {
  const nav = $("nav");
  if (!nav || nav.dataset.dragReady === "1") return;
  nav.dataset.dragReady = "1";

  let pointerId = null;
  let startX = 0;
  let startScroll = 0;
  let dragged = false;
  let suppressClick = false;

  const finishPointer = event => {
    if (pointerId === null || (event && event.pointerId !== pointerId)) return;
    if (nav.hasPointerCapture && nav.hasPointerCapture(pointerId)) {
      nav.releasePointerCapture(pointerId);
    }
    pointerId = null;
    nav.classList.remove("nav-dragging");
    if (dragged) {
      suppressClick = true;
      window.setTimeout(() => { suppressClick = false; }, 0);
    }
    updateNavScrollCue();
  };

  nav.addEventListener("pointerdown", event => {
    if (event.pointerType === "touch" || event.button !== 0) return;
    if (nav.scrollWidth <= nav.clientWidth + 1) return;
    pointerId = event.pointerId;
    startX = event.clientX;
    startScroll = nav.scrollLeft;
    dragged = false;
  });

  nav.addEventListener("pointermove", event => {
    if (pointerId === null || event.pointerId !== pointerId) return;
    const distance = event.clientX - startX;
    if (!dragged && Math.abs(distance) > 5) {
      dragged = true;
      nav.classList.add("nav-dragging");
      try { nav.setPointerCapture(pointerId); } catch (_) {}
    }
    if (!dragged) return;
    event.preventDefault();
    nav.scrollLeft = startScroll - distance;
    updateNavScrollCue();
  });

  nav.addEventListener("pointerup", finishPointer);
  nav.addEventListener("pointercancel", finishPointer);
  nav.addEventListener("lostpointercapture", finishPointer);
  nav.addEventListener("dragstart", event => event.preventDefault());

  nav.addEventListener("click", event => {
    if (!suppressClick) return;
    event.preventDefault();
    event.stopImmediatePropagation();
  }, true);

  nav.addEventListener("wheel", event => {
    const maxScroll = Math.max(0, nav.scrollWidth - nav.clientWidth);
    if (maxScroll <= 2) return;
    const raw = Math.abs(event.deltaX) > Math.abs(event.deltaY)
      ? event.deltaX : event.deltaY;
    const unit = event.deltaMode === 1 ? 16 : event.deltaMode === 2 ? nav.clientWidth : 1;
    const before = nav.scrollLeft;
    nav.scrollLeft += raw * unit;
    if (nav.scrollLeft !== before) {
      event.preventDefault();
      updateNavScrollCue();
    }
  }, { passive: false });

  nav.addEventListener("scroll", updateNavScrollCue, { passive: true });
  window.addEventListener("resize", updateNavScrollCue);
  if (typeof ResizeObserver === "function") {
    new ResizeObserver(updateNavScrollCue).observe(nav);
  }
  updateNavScrollCue();
}

function makeNavScrollable() {
  ["page-today", "page-decisions", "page-operations", "page-execution", "page-intake",
   "page-dash", "page-team",
   "page-assist", "page-identity", "page-companies", "page-tasks", "page-community",
   "page-me"].forEach(id => {
    $(id).classList.add("has-nav");
  });
  enableNavDrag();
}

/*: 所有页面。加新页面必须登记在这里——
     漏了的话页面永远显示不出来，而且不报错，很难查。 */
const PAGES = ["login", "today", "decisions", "operations", "execution", "intake", "dash",
               "project", "tasks", "team", "assist", "identity", "companies",
               "community", "assign", "staff", "me"];

function showPage(name) {
  const target = PAGES.indexOf(name) === -1 ? "dash" : name;
  PAGES.forEach(key => {
    $("page-" + key).classList.toggle("hidden", key !== target);
  });
  const morePages = ["dash", "team", "assist", "identity", "companies", "community", "today", "me"];
  document.querySelectorAll("#nav button").forEach(button => {
    const isMore = button.dataset.page === "more" && morePages.indexOf(target) !== -1;
    button.classList.toggle("on", button.dataset.page === target || isMore);
  });

  /* 登录页不显示底部导航——还没登录，那些页面一个都进不去。
     显示出来只会让人以为能点。（样式见 style.css 的 .no-nav） */
  document.body.classList.toggle("no-nav", target === "login");

  /* 离开任务页就把走秒的定时器停掉。
     不停的话切到别的页它还在每秒跑，白耗电。 */
  if (target !== "tasks" && typeof stopWorkTicker === "function") {
    stopWorkTicker();
  }

  /* 每个页面自己负责渲染。这里是唯一的入口，
     所以不会出现"某个页面没刷新"的问题。 */
  if (target === "today") {
    renderToday();
    if (typeof refreshPointState === "function") refreshPointState(false);
  }
  if (target === "decisions") {
    renderDecisionCenter();
    loadDecisionCenter(true);
  }
  if (target === "operations") {
    renderOperations();
    loadOperations(true);
  }
  if (target === "execution") {
    renderExecution();
    loadExecution(true);
  }
  if (target === "intake") {
    renderIntake();
    loadIntake(true);
  }
  if (target === "dash" || target === "today") {
    if (typeof pullCloudProjects === "function") {
      pullCloudProjects().then(result => {
        if (!result || result.error || currentPageName() !== target) return;
        if (target === "dash") renderDash();
        else renderToday();
      }).catch(() => {});
    }
  }
  if (target === "dash") renderDash();
  if (target === "team") renderTeam();
  if (target === "assist") renderAssist();
  if (target === "tasks") renderTasks();
  if (target === "assign") renderAssign();
  if (target === "staff") renderStaff();
  if (target === "identity") {
    renderIdentity();
    if (typeof refreshIdentity === "function") refreshIdentity(false);
    if (typeof loadShareholderMeetings === "function") loadShareholderMeetings(false);
  }
  if (target === "companies") {
    renderMyCompanies();
    loadMyCompanies(true);
  }
  if (target === "community") renderCommunity();
  if (target === "me") renderMe();
  if (target === "login") renderLogin();
  refreshSyncBadge();

  /* **进「我的」页就算看过了，红点当场清掉。**

     原来只有点右上角铃铛、打开通知中心才会清除未读。
     但用户的直觉是"我点进「我的」了，红点该没了"——
     他点了没消，就觉得"红点消不掉"。

     用户说的对：**红点是"那儿有新东西"的提示，进去了就该消失。**
     （通知本身不会被删，只是标记为已读；通知中心里还能翻。） */
  if (target === "me" && typeof markNotificationsRead === "function") {
    markNotificationsRead();
  }

  /* 通知：切页时刷新红点和提示条。
     两处都调，因为这个函数只在切页时跑，
     而且"切到看板/任务页就该看到最新提示"正是想要的行为。 */
  renderNotifyBadges();
  renderNotifyBanner("notify-banner-dash");
  renderNotifyBanner("notify-banner-tasks");

  window.scrollTo(0, 0);
}

/* 「我的」页。**老板和员工共用**——两边的退出登录都在这里。

   老板多显示几个区块（云服务设置、切主题、管员工），
   员工只关心"我报上去没有"。用 me-boss-extras 控制显示。 */
function renderMe() {
  const profile = DB.profile;
  const isBoss = !!(profile && profile.role === "boss");

  $("me-sub").textContent = profile ? profile.name : "没有登录";
  $("me-name").textContent = profile ? profile.name : "—";
  $("me-code").textContent = profile ? profile.code : "—";
  /* **两个名字分开叫。**
     老板的登录名是「账号」，员工的是「员工号」。
     都叫「账号」会让人分不清"我要建的这个人"和"我自己"是同一个东西。 */
  $("me-code-label").textContent = isBoss ? "账号" : "员工号";
  $("me-role").textContent = !profile ? "未登录"
    : isBoss ? "老板" : "员工";

  /* **邮箱：忘了密码时唯一的救命通道，所以要能看见、能改。**

     老账号的邮箱是内部假地址（<账号>@boss.pr），那个地址不存在 ——
     看着像"已绑定"，实际收不到任何信。

     **绑定了也必须能改。** 之前只在"未绑定"时显示按钮，
     于是一个手滑填错（xxx@qq.con）就永远改不了：
     收不到验证码 → 忘了密码 → 再也进不来。
     这跟"忘了密码要旧密码"是同一类死路。 */
  const email = (profile && profile.email) || "";
  const isFake = !email || /@(boss|staff)\.pr$/i.test(email);
  const emailBox = $("me-email");
  if (emailBox) {
    emailBox.textContent = isFake ? "未绑定" : email;
    emailBox.style.color = isFake ? "var(--severe)" : "";
    emailBox.style.wordBreak = "break-all";
  }
  const emailTip = $("me-email-tip");
  if (emailTip) {
    if (!profile) {
      emailTip.innerHTML = "";
    } else if (isFake) {
      emailTip.innerHTML = '<button class="btn ghost" '
        + 'style="width:100%;margin-top:8px" id="btn-me-bind-email">'
        + '绑定邮箱</button>';
      const bind = $("btn-me-bind-email");
      if (bind) bind.onclick = openChangeEmail;
    } else {
      /* 已经绑了：给一个"改"，写错的时候有救 */
      emailTip.innerHTML =
        '<div style="text-align:right;margin-top:4px">'
        + '<button class="chip" id="btn-me-change-email" '
        + 'style="font-size:12px">改邮箱</button></div>';
      const change = $("btn-me-change-email");
      if (change) change.onclick = openChangeEmail;
    }
  }

  const status = syncStatus();
  $("me-sync").textContent = !status.configured ? "单机模式"
    : !status.signedIn ? "未登录"
    : status.last && status.last.at
      ? (status.last.ok ? "已同步 " + String(status.last.at).slice(11, 16)
                        : "同步失败")
      : "还没同步过";
  /* 同步失败时把原因摆出来，不要让人只看到一个"失败" */
  const syncNode = $("me-sync");
  syncNode.title = (status.last && status.last.message) || "";
  if (status.last && status.last.ok === false) {
    syncNode.style.color = "var(--watch)";
  } else {
    syncNode.style.color = "";
  }
  $("me-pending").textContent = status.pending + " 条";
  /* 没有待上传的就整行藏掉 —— 天天摆一行"待上传 0 条"是纯噪音 */
  if ($("me-pending-row")) {
    $("me-pending-row").classList.toggle("hidden", !(status.pending > 0));
  }

  /* **同步状态只在出问题时显示。**

     一切正常时右上角那个「已同步」徽标已经说明了，
     卡片里再来一行一模一样的是重复。失败/单机/未登录才值得占位。 */
  if ($("me-sync-row")) {
    const normal = status.configured && status.signedIn
      && status.last && status.last.ok;
    $("me-sync-row").classList.toggle("hidden", !!normal);
  }

  $("me-boss-extras").classList.toggle("hidden", !isBoss);
  if (typeof renderMyPerformance === "function") renderMyPerformance();

  /* 通知相关的提示。
     两种情况要说清楚，不然用户只会觉得"怎么没通知"：
       1. 服务端的 task_events 表还没建（SQL 没跑）
       2. 系统通知开关开着，但权限没给 */
  const hintBox = $("me-notify-hint");
  const hints = [];

  /* **实时推送的状态要看得见。**

     这一条是排查"通知不弹"时加的：实时订阅失败是**静默**的——
     订阅回调会说 SUBSCRIBED，但如果连接没带认证令牌、
     或者服务端没开实时发布，事件会被**悄悄过滤掉**，
     客户端一个错都不报。用户只觉得"还是慢"，无从查起。

     所以把状态摆出来。正常时它写着"订阅：SUBSCRIBED"，
     不正常时一眼能看到卡在哪一步（令牌？订阅？）。

     只在系统通知开着时才显示——关掉通知的人不关心这个。 */
  const notifyPrefsForHint = notifyPrefs();
  if (notifyPrefsForHint.enabled && notifyPrefsForHint.system
      && typeof realtimeState !== "undefined" && realtimeState) {
    const good = String(realtimeState).indexOf("SUBSCRIBED") !== -1
      || String(realtimeState).indexOf("收到推送") !== -1;
    /* **正常时不显示。**

       "实时推送：SUBSCRIBED 13:18:34" 是给排查问题的人看的，
       普通用户看到只会觉得是一堆天书。只有真出问题时才提示。 */
    if (!good) {
      hints.push("实时推送异常："
        + "<code>" + escapeHtml(realtimeState) + "</code>");
    }
  }
  /* **登录失效要明说。**

     用户的设备上出现过这种情况：本机资料还在（所以进得了主界面），
     但登录会话已经没了——于是每次上传都是匿名请求，
     被服务端的 RLS 全部拒掉，报的是
     `new row violates row-level security policy`。

     界面上只显示"同步失败"，用户只会觉得"这 App 坏了"，
     **根本想不到是"要重新登录"**。

     所以单独显示一条，并且说清楚怎么办。 */
  if (status.signedIn && status.configured && !status.hasSession) {
    /* 用 <b> 而不是 ** —— 这段是 innerHTML，
       `**粗体**` 那种写法不会被渲染，会原样显示出来。 */
    hints.push("<b>登录已失效</b>：数据传不上去。"
      + "点下面的「退出登录」，再重新登录一次即可。");
  }

  if (DB.notifyTableMissing) {
    /* **文件名要和实际存在的对上。**

       这里原来指向 sql/migrate-notify.sql，但我后来把那个文件
       和"工号解封"合并成了 sql/migrate-notify.sql——
       提示就指错了，用户按它去找会找不到。

       改动 SQL 文件名时，**记得全局搜一遍引用**。 */
    hints.push("通知功能没装好——去电脑上的 Supabase SQL Editor "
      + "跑一遍 <code>sql/migrate-notify.sql</code>");
  }
  const prefs = notifyPrefs();
  if (prefs.enabled && prefs.system) {
    const permission = DB.notifyPermission;
    if (permission && permission.supported && !permission.granted) {
      hints.push("系统通知没打开：在手机设置里允许本 App 发通知，"
        + "否则 App 退到后台时收不到提醒");
    }
  }

  /* **拉取失败必须显示出来。**

     增量拉取原来是 `if (!error && data) { ... }` —— 查询报错
     就什么都不做：不记日志、不改界面。于是出现最难查的一种状态：

        · 界面显示"已同步"
        · 新数据永远不来
        · 光标不前进
        · 日志干净，什么都没报

     游标里那个 `+` 号（被 URL 当成空格 → 400）就是这样被掩盖的。
     现在把错误原文摆出来，一眼能看到是哪张表、什么原因。 */
  if (DB.pullError) {
    hints.push("<b>云端数据拉不下来</b>："
      + escapeHtml(String(DB.pullError).slice(0, 160)));
  }

  /* **系统通知的体检结果。**

     "没弹窗"有好几种原因（权限 / 通道 / 插件 / 图标资源），
     而每一种在界面上都长得一模一样。把最后一次尝试的结果摆出来，
     出问题时一眼看到卡在哪一步，不用来回猜——
     之前就是这样猜了好几轮。 */
  if (typeof lastNotifyAttempt !== "undefined" && lastNotifyAttempt) {
    hints.push("上次发系统通知：<code>"
      + escapeHtml(String(lastNotifyAttempt.reason)) + "</code>");
  }

  /* **设备推送登记状态。**

     "推送发了但手机没收到"最常见的原因，就是这台设备没登记成功
     （`push_devices` 里没有记录）。而它失败时**完全静默**：
     界面看着一切正常，消息发到一个旧地址。

     实测踩过：换签名重装后 CID 变了，新 CID 没登记成功，
     旧记录还留在库里 —— 于是"推送发出去了但收不到"。

     所以只要不是「已登记」就明确说出来，并告诉用户点哪个按钮。 */
  if (typeof lastGetuiRegistration !== "undefined" && lastGetuiRegistration
      && !lastGetuiRegistration.ok) {
    hints.push("<b>后台推送没登记上</b>："
      + escapeHtml(String(lastGetuiRegistration.reason))
      + "。点右上角铃铛 →「启用后台推送」重试。");
  }
  if (status.pending > 0) {
    /* **队列里每一条都摊开说。**

       "还有 N 条没上传成功"这种话查不出问题——用户只能告诉我"传不上去"，
       我还得猜是哪张表、哪条记录、什么错。

       现在直接把每条的 表/操作/关键 id/报错 全列出来，
       一眼就能看出是哪一条被服务端拒了、因为什么。
       （第一次这么显示就抓到了 task_logs 的 RLS 报错。） */
    const lines = (DB.syncQueue || []).slice(0, 6).map(item => {
      const p = item.payload || {};
      const who = p.employee_id
        ? " employee=" + String(p.employee_id).slice(0, 8) + "…" : "";
      const err = item.lastError
        ? "<br>　　<b>" + escapeHtml(String(item.lastError).slice(0, 90))
          + "</b>" : "";
      return escapeHtml(String(item.table) + " " + item.op) + who + err;
    });
    hints.push("还有 " + status.pending + " 条没传上去：<br>"
      + lines.join("<br>")
      + (status.pending > 6 ? "<br>…还有 " + (status.pending - 6) + " 条" : ""));
  }
  hintBox.innerHTML = hints.length
    ? '<div class="banner warn">' + hints.join("<br>") + "</div>"
    : "";
}

/* ============================================================
   弹层表单
   ============================================================ */
let sheetSubmit = null;

function openSheet(title, bodyHtml, buttons) {
  $("sheet-title").textContent = title;
  $("sheet-body").innerHTML = bodyHtml;
  const foot = $("sheet-foot");
  foot.innerHTML = "";
  (buttons || []).forEach(spec => {
    const button = document.createElement("button");
    button.className = "btn " + (spec.kind || "ghost");
    button.textContent = spec.label;
    button.onclick = () => spec.onClick();
    foot.appendChild(button);
  });
  $("sheet").classList.remove("hidden");
}

function closeSheet() {
  $("sheet").classList.add("hidden");
  sheetSubmit = null;
}

function openNavMore() {
  const items = [
    ["shares", "股份"], ["companies", "我的公司"], ["dash", "看板"], ["team", "团队"], ["assist", "助手"],
    ["identity", "治理"], ["community", "星球"],
    ["today", "今天"], ["me", "我的"],
  ];
  openSheet("更多功能", `
    <div id="nav-more-grid" class="nav-more-grid">
      ${items.map(([page, label]) => `
        <button class="btn ghost nav-more-item" data-more-page="${page}">${label}</button>
      `).join("")}
    </div>
  `, [{ label: "关闭", onClick: closeSheet }]);
  $("nav-more-grid").onclick = event => {
    const button = event.target.closest("[data-more-page]");
    if (!button) return;
    const page = button.dataset.morePage;
    closeSheet();
    if (page === "shares") {
      if (typeof openShareDashboard === "function") openShareDashboard();
      return;
    }
    showPage(page);
  };
}

function bindGlobalEvents() {
  if ($("btn-my-companies-refresh")) {
    $("btn-my-companies-refresh").onclick = () => loadMyCompanies(true);
  }
  if ($("btn-org-health")) {
    $("btn-org-health").onclick = () => loadOrganizationHealth();
  }
  if ($("btn-org-repair")) {
    $("btn-org-repair").onclick = () => repairMyOrganizationFromUI();
  }

  if ($("btn-check-update")) {
    $("btn-check-update").onclick = () => checkForAppUpdate(true);
  }

  $("sheet").addEventListener("click", event => {
    if (event.target.dataset.close) closeSheet();
  });

  document.querySelectorAll("#nav button").forEach(button => {
    button.onclick = () => {
      if (button.dataset.page === "more") {
        openNavMore();
        return;
      }
      showPage(button.dataset.page);
    };
  });

  /* 社区的两个固定按钮在这里统一接线。 */
  $("btn-community-refresh").onclick = async () => {
    await loadCommunityBoards(true);
    await loadCommunityPosts(true);
    loadCommunityNotifications(true);
  };
  $("btn-identity-refresh").onclick = () => refreshIdentity(true);
  $("btn-decisions-refresh").onclick = () => loadDecisionCenter(true);
  if (typeof bindDecisionCenter === "function") bindDecisionCenter();
  if (typeof bindExecution === "function") bindExecution();
  if (typeof bindIntake === "function") bindIntake();
  if ($("btn-operations-refresh")) {
    $("btn-operations-refresh").onclick = () => loadOperations(true);
  }
  if ($("btn-my-performance")) {
    $("btn-my-performance").onclick = async () => {
      const box = $("my-performance");
      if (!box) return;
      const opening = box.classList.contains("hidden");
      box.classList.toggle("hidden", !opening);
      if (opening) {
        box.innerHTML = '<div class="meta">正在读取绩效依据…</div>';
        await loadMyPerformanceEvidence(true);
      }
    };
  }
  if (typeof bindOperations === "function") bindOperations();
  $("btn-community-send").onclick = () => submitCommunityPost();

  /* **按下任何按钮都轻震一下。**

     视觉上的缩放进 CSS（.btn:active 等），触感在这里——
     两者加起来才叫"跟手"：眼看按钮陷下去 + 手感到一下轻震。

     用 pointerdown 而不是 click，因为触感要**在手指按下时**发生，
     等 click 就已经晚了（click 要等抬手）。

     只在支持震动的设备上做（Android 支持，桌面浏览器没有就跳过）。
     15 毫秒很短，不会有"嗡嗡"的噪音感。 */
  bindPressFeedback();

  /* ---- 登录页 ----
     身份切换按钮的绑定**在 renderLogin() 里做**，不在这里。
     原因：绑定写在这里的话只有启动时执行一次，
     以后任何重新渲染登录页的路径都会让按钮变成死按钮
     （点了没反应而且不报错）。放在渲染函数里才是"画出来就能点"。 */
  $("btn-login").onclick = doLogin;
  $("login-password").addEventListener("keydown", event => {
    if (event.key === "Enter") doLogin();
  });
  /* 老板自助注册。**只有第一个能成功**，之后服务端会拒绝。
     员工不走这个入口——他们的账号由老板建。 */
  $("btn-register-boss").onclick = openBossRegister;
  /* 忘了密码的出口。
     **忘了绑这个按钮**——加按钮的时候只改了 HTML 和 account.js，
     忘了在这里接线，表现是"点了没反应"。
     （浏览器测试里的"「忘了密码」有 onclick"抓到了它。） */
  $("btn-forgot").onclick = openForgotPassword;
  /* 注意：登录页上的「云服务设置」和「先不登录，只用本机功能」
     两个按钮**已经删掉了**（用户要求去掉）。

     云服务地址有预置值，手机上根本不用填；真要改，
     「我的 → 云服务设置」还在（登录后）。
     本机模式也保留：不登录照样能用，只是不用摆个按钮强调。 */
  $("btn-resume").onclick = () => {
    resumeSession();
    showPage(DB.profile && DB.profile.role === "employee" ? "tasks" : "dash");
  };
  $("btn-switch-account").onclick = () => {
    switchAccount().then(() => { renderLogin(); toast("请输入新账号"); });
  };

  /* ---- 员工任务页 ---- */
  $("btn-task-menu").onclick = openStaffMenu;

  /* ---- 通知 ---- */
  /* 看板右上和任务页右上各有一个铃铛，加上底部导航的「我的」红点，
     三个入口都通向同一个通知中心。 */
  $("btn-notify").onclick = () => openNotifyCenter();
  $("btn-task-notify").onclick = () => openNotifyCenter();

  /* ---- 简单/高级模式与今日工位 ---- */
  if ($("btn-mode-toggle")) $("btn-mode-toggle").onclick = toggleMobileUiMode;
  if ($("btn-mode-toggle-me")) {
    $("btn-mode-toggle-me").onclick = toggleMobileUiMode;
  }
  if ($("btn-today-all-tasks")) {
    $("btn-today-all-tasks").onclick = () => showPage("tasks");
  }
  if ($("btn-today-community")) {
    $("btn-today-community").onclick = () => showPage("community");
  }

  /* ---- 「我的」页（两种身份都用） ---- */
  $("btn-sync-now").onclick = () => {
    syncNow("manual").then(status => {
      renderMe();
      renderNotifyBadges();
      toast(status && status.last && status.last.message
        ? status.last.message
        : (status.pending ? `还有 ${status.pending} 条待上传` : "已同步"));
    });
  };
  $("btn-system-diagnose").onclick = runSystemDiagnosis;
  $("btn-me-logout").onclick = logout;
  /* 账号管理。两种身份都要用，所以放在 me-boss-extras 外面。 */
  $("btn-me-password").onclick = openChangePassword;
  $("btn-me-login").onclick = openChangeLogin;
  $("btn-me-delete").onclick = openDeleteAccount;

  /* 老板专有的两项。员工那边这块是隐藏的，
     绑定照做——隐藏的按钮点了也没事，
     而"按身份决定要不要绑定"反而容易漏掉一处。 */
  $("btn-me-theme").onclick = () => {
    const next = chartTheme === "dark" ? "light" : "dark";
    applyTheme(next);
    showPage("me");
    toast("已切到" + (next === "dark" ? "深色" : "浅色"));
  };
  $("btn-me-companies").onclick = () => showPage("companies");
  $("btn-me-accounts").onclick = () => showPage("staff");

  /* 新加的四项：开工、兑换、请假、商品管理。
     都是"隐藏了也能点"的做法 —— 按身份判断要不要绑定
     反而容易漏掉一处，绑了不会出错。 */
  if ($("btn-work")) $("btn-work").onclick = toggleWork;
  if ($("btn-shop")) $("btn-shop").onclick = openShopSheet;
  if ($("btn-me-rewards")) $("btn-me-rewards").onclick = openManageRewards;
  if ($("btn-me-leave")) $("btn-me-leave").onclick = openLeaveSheet;

  /* **「云服务设置」的隐藏入口：长按资料卡片。**

     服务器是预置的，界面上不该摆这个按钮（别人看不懂"云服务"）。
     但万一预置的失效、或者要换项目，必须还有路可走，
     所以留一个**只有知道的人才会用**的手势。

     也接受双击——手机上长按有时会被系统的文本选择干扰。 */
  const meCard = $("me-card");
  if (meCard) {
    let pressTimer = null;
    const openIt = () => {
      openCloudSettings();
    };
    meCard.addEventListener("pointerdown", () => {
      pressTimer = setTimeout(openIt, 900);
    });
    ["pointerup", "pointercancel", "pointerleave"].forEach(type => {
      meCard.addEventListener(type, () => {
        if (pressTimer) { clearTimeout(pressTimer); pressTimer = null; }
      });
    });
    meCard.addEventListener("dblclick", openIt);
  }

  /* ---- 老板：员工账号 ---- */
  $("btn-new-staff").onclick = () => editNewStaff();
  /* 这个按钮现在是"重试创建"——建号在新建时一次就完成了，
     只有当时没网才会留下待建的账号。 */
  $("btn-sync-staff").onclick = () => retryStaffFromUI();

  /* ---- 团队页的两个管理入口 ----
     **之前漏了**：page-staff 和 page-assign 两个页面写好了，
     但没有任何地方能跳过去，老板根本找不到建号功能。
     页面和入口要一起加，否则等于没做。 */
  $("btn-goto-staff").onclick = () => showPage("staff");
  $("btn-goto-assign").onclick = () => { showPage("assign"); renderAssign(); };

  /* ---- 老板：派任务 ---- */
  $("btn-assign-submit").onclick = submitAssign;
  $("assign-date").onchange = renderAssign;

  /* 看板 */
  $("btn-new-project").onclick = () => editProject(null);
  $("btn-new-habit").onclick = () => editHabit(null);
  $("btn-menu").onclick = openMenu;

  /* 项目详情 */
  document.querySelectorAll("[data-back]").forEach(button => {
    button.onclick = () => showPage(button.dataset.back);
  });
  $("btn-edit-project").onclick = () => {
    if (currentProjectId) editProject(currentProjectId);
  };

  /* 团队 */
  $("btn-new-employee").onclick = () => {
    if (typeof openInviteOrganizationMember === "function") {
      openInviteOrganizationMember();
    } else {
      editEmployee(null);
    }
  };
  $("btn-new-worklog").onclick = () => editWorklog(null);

  /* 小助手 */
  $("btn-ask").onclick = () => sendAsk($("ask").value);
  $("ask").addEventListener("keydown", event => {
    if (event.key === "Enter") { sendAsk($("ask").value); }
  });
  $("btn-clear-chat").onclick = () => {
    chat = [];
    saveSetting("chat", chat);
    renderAssist();
    toast("对话已清空");
  };
}

/* ---------------------------------------------------------- 菜单 */
function openMenu() {
  const status = syncStatus();
  /* 云服务状态一行说清楚，否则用户不知道自己配没配 */
  const cloudLine = !status.configured
    ? '<span style="color:var(--watch)">还没配云服务，登录和自动同步用不了</span>'
    : !status.signedIn
      ? '<span style="color:var(--watch)">已配好，但还没登录</span>'
      : '<span style="color:var(--ok)">已连接 · '
        + escapeHtml(DB.profile.name) + '（'
        + (DB.profile.role === "boss" ? "老板" : "员工") + '）</span>';

  /* **「云服务设置」不摆在界面上。**

     服务器（地址 + 密钥）是预置的，正常用一辈子都不用碰。
     摆一个"云服务设置"按钮出来，别人只会问"云服务是什么"。

     但如果真需要改（换了 Supabase 项目、或者预置的失效了），
     必须还有路可走——所以：
       · 状态行本身就是入口（下面挂 id，长按进设置）
       · 没配好时**直接展开那个按钮**，因为那时候你必须能进 */
  openSheet("更多", `
    <div class="meta" style="padding:2px 0 12px" id="m-cloud-line">
      云服务：${cloudLine}</div>
    ${status.configured
      ? ""
      : '<button class="btn ghost" id="m-cloud" style="width:100%">'
        + '配置云服务</button><div style="height:10px"></div>'}
    <button class="btn ghost" id="m-account" style="width:100%">
      ${status.signedIn ? "账号与同步状态" : "去登录"}</button>
    <div style="height:10px"></div>
    <button class="btn ghost" id="m-export-db" style="width:100%">
      导出数据库（备份 / 交给电脑）</button>
    <div style="height:10px"></div>
    <button class="btn ghost" id="m-import-db" style="width:100%">导入数据库</button>
    <div style="height:10px"></div>
    <button class="btn ghost" id="m-import-worklog" style="width:100%">
      导入电脑导出的快照</button>
    <div style="height:10px"></div>
    <button class="btn ghost" id="m-theme" style="width:100%">
      切换主题（当前：${escapeHtml(chartTheme === "dark" ? "深色" : "浅色")}）</button>
  `, [{ label: "关闭", onClick: closeSheet }]);

  if ($("m-cloud")) {
    $("m-cloud").onclick = () => { closeSheet(); openCloudSettings(); };
  }
  $("m-account").onclick = () => {
    closeSheet();
    /* 已经登录就去看同步状态，没登录就回登录页 */
    showPage(syncStatus().signedIn ? "me" : "login");
  };
  $("m-export-db").onclick = exportDatabase;
  $("m-import-db").onclick = () => pickFile(importDatabase);
  $("m-import-worklog").onclick = () => pickFile(importSnapshot);
  $("m-theme").onclick = () => {
    const next = chartTheme === "dark" ? "light" : "dark";
    applyTheme(next);
    closeSheet();
    /* 重画当前页面：图表颜色是 Canvas 画的，不重画就还是旧的 */
    showPage(currentPageName());
    toast("已切到" + (next === "dark" ? "深色" : "浅色"));
  };
}

function currentPageName() {
  for (let i = 0; i < PAGES.length; i += 1) {
    const name = PAGES[i];
    if (name === "login") continue;
    const page = $("page-" + name);
    if (page && !page.classList.contains("hidden")) return name;
  }
  return "today";
}

/* ---------------------------------------------------------- 按下反馈 */

/* 按下去轻震一下。

 ## 为什么用 pointerdown 而不是绑每个按钮的 click

   · click 要等**抬手**才触发，那时候手指已经离开，
     震动的时机就不对了（感觉像"延迟了一下才震"）
   · 用事件委托绑在 document 上，**之后动态加进来的按钮也自动生效**
     （弹层里的按钮是每次重画的，一个个绑会漏）

 ## 为什么只震 12 毫秒

   长震动会让人觉得手机在"嗡"，短震动才像"嗒"一下。
   Android 上 10~15ms 是常见的轻触反馈时长。

 ## 兼容

   · 不支持 vibrate 的设备（桌面浏览器）直接跳过
   · 用户关掉系统的"触摸震动"时，vibrate 会被系统忽略，不用自己判断 */
function bindPressFeedback() {
  if (typeof navigator === "undefined"
      || typeof navigator.vibrate !== "function") {
    return;
  }

  /* 防抖：手指按住不放会连续触发 pointerdown，
     连震一串反而变成噪音。300 毫秒内只震一次。 */
  let lastBuzz = 0;

  document.addEventListener("pointerdown", event => {
    const target = event.target;
    if (!target || typeof target.closest !== "function") return;
    const hit = target.closest(".btn, .chip, .icon-btn, nav button");
    if (!hit) return;
    /* 禁用的按钮不该给反馈——它本来就点不动 */
    if (hit.disabled) return;

    const now = Date.now();
    if (now - lastBuzz < 300) return;
    lastBuzz = now;
    try {
      navigator.vibrate(12);
    } catch (error) {
      /* 震动失败不影响任何功能，静默跳过 */
    }
  }, { passive: true });
}

/* ---------------------------------------------------------- 角色形象 */
/* 头像放在 icons/ 目录，由 prepare-avatars.py 生成。
   两套尺寸各有用处：
     · 脸特写（192px）  小尺寸用，聊天气泡、空状态
     · 整身立绘（320px）大尺寸用，首屏和空状态的"主形象"，
                        边缘由 CSS 羽化，所以是整张图不是裁圆的
   全部预加载：9 张总共约 300 KB，一次读进内存，
   之后切换表情不会出现"闪一下才出来"。 */
const AVATARS = {
  neutral: "01_嗯",        // 默认
  happy:   "02_好耶",      // 一切正常、操作成功
  sleepy:  "03_睡觉",      // 没有数据
  puzzled: "04_疑惑",      // 听不懂
  warn:    "05_哼",        // 有风险、超预算
  alarm:   "06_惊讶",      // 严重风险、超期
  warm:    "07_抱抱",      // 鼓励、建议
  ok:      "08_嗯嗯",      // 确认、认可
  watch:   "09_暗中观察",  // 等待输入
};

const STAR_STICKERS = [
  { id: "hug", file: "star_01_hug", label: "抱抱", message: "先接住自己，再处理事情。" },
  { id: "roger", file: "star_02_roger", label: "收到", message: "收到，我来把这件事落到下一步。" },
  { id: "tea", file: "star_03_tea", label: "喝茶", message: "缓一口气，节奏比速度重要。" },
  { id: "work", file: "star_04_work", label: "工作中", message: "进入专注轨道，先完成最小的一步。" },
  { id: "wow", file: "star_05_wow", label: "惊讶", message: "有变化就先核对，不急着下结论。" },
  { id: "hmph", file: "star_06_hmph", label: "哼", message: "可以不同意，但把理由写清楚。" },
  { id: "sleep", file: "star_07_sleep", label: "睡觉", message: "今天到这里，休息也是进度。" },
  { id: "great", file: "star_08_great", label: "太好了", message: "一切在变好，继续保持现在的节奏。" },
  { id: "music", file: "star_09_music", label: "听歌", message: "给自己一段不被打断的时间。" },
  { id: "read", file: "star_10_read", label: "看书", message: "先找依据，再决定下一步。" },
  { id: "yum", file: "star_11_yum", label: "好吃", message: "补充能量，才有力气继续。" },
  { id: "meow", file: "star_12_meow", label: "喵", message: "允许自己可爱一点，也允许事情慢一点。" },
  { id: "out", file: "star_13_out", label: "想出去", message: "想离开一下没关系，回来再继续。" },
  { id: "what", file: "star_14_what", label: "疑惑", message: "没想清楚就先标记问题，不用硬猜。" },
  { id: "tired", file: "star_15_tired", label: "好累", message: "累不是失败，今天只做必要的事。" },
  { id: "bye", file: "star_16_bye", label: "下次见", message: "收好今天的进度，下次接着来。" },
];

const STAR_MOOD_FILES = {
  neutral: "star_03_tea",
  happy: "star_08_great",
  sleepy: "star_07_sleep",
  puzzled: "star_14_what",
  warn: "star_06_hmph",
  alarm: "star_05_wow",
  warm: "star_01_hug",
  ok: "star_02_roger",
  watch: "star_10_read",
};

const STAR_MOOD_IDS = {
  neutral: "tea", happy: "great", sleepy: "sleep", puzzled: "what",
  warn: "hmph", alarm: "wow", warm: "hug", ok: "roger", watch: "read",
};

function starStickerById(id) {
  return STAR_STICKERS.find(item => item.id === id) || null;
}

function starForMood(mood) {
  return starStickerById(STAR_MOOD_IDS[mood] || "hug") || STAR_STICKERS[0];
}

function starStickerSrc(star) {
  const item = typeof star === "string" ? starStickerById(star) : star;
  return item ? `icons/star/${item.file}.webp` : "icons/star/star_01_hug.webp";
}

function starFaceSrc(star) {
  const item = typeof star === "string" ? starStickerById(star) : star;
  return item ? `icons/star/${item.file}@face.webp` : "icons/star/star_01_hug@face.webp";
}

function starStickerSettingKey() {
  return "star_sticker_" + String(DB.account_scope_id
    || (DB.profile && DB.profile.id) || "device");
}

function selectedStarSticker() {
  const id = getSetting(starStickerSettingKey(), "");
  return starStickerById(String(id || ""));
}

function renderStarCompanion(mood) {
  const box = $("star-companion");
  if (!box) return;
  const manual = selectedStarSticker();
  const active = manual || starForMood(mood);
  box.innerHTML = `
    <div class="star-companion-head">
      <div>
        <div class="star-kicker"> 星轨陪伴</div>
        <h3>今天想以什么状态出现？</h3>
      </div>
      ${manual ? '<button class="star-auto" data-star-auto="1">跟随状态</button>' : ""}
    </div>
    <div class="star-strip" role="list">
      ${STAR_STICKERS.map(item => `
        <button class="star-chip${item.id === active.id ? " active" : ""}"
          data-star-id="${escapeHtml(item.id)}" role="listitem"
          aria-pressed="${item.id === active.id ? "true" : "false"}"
          title="${escapeHtml(item.message)}">
          <img src="${starFaceSrc(item)}" alt="${escapeHtml(item.label)}" loading="lazy">
          <span>${escapeHtml(item.label)}</span>
        </button>`).join("")}
    </div>
    <div class="star-message">
      <img src="${starFaceSrc(active)}" alt="">
      <div><b>${escapeHtml(active.label)}</b><span>${escapeHtml(active.message)}</span></div>
    </div>`;
  box.querySelectorAll("[data-star-id]").forEach(button => {
    button.onclick = () => {
      saveSetting(starStickerSettingKey(), button.dataset.starId);
      renderDash();
    };
  });
  if (box.querySelector("[data-star-auto]")) {
    box.querySelector("[data-star-auto]").onclick = () => {
      saveSetting(starStickerSettingKey(), "");
      renderDash();
    };
  }
}

function faceSrc(key) {
  if (STAR_MOOD_FILES[key]) return `icons/star/${STAR_MOOD_FILES[key]}@face.webp`;
  return "icons/" + (AVATARS[key] || AVATARS.neutral) + ".webp";
}

function heroSrc(key) {
  if (STAR_MOOD_FILES[key]) return `icons/star/${STAR_MOOD_FILES[key]}.webp`;
  return "icons/" + (AVATARS[key] || AVATARS.neutral) + "@hero.webp";
}

/* 根据当前数据挑一个表情。**表情是有信息量的**，不是装饰：
   有严重问题就"惊讶"，一切正常就"好耶"，没数据就"睡觉"。 */
function dashboardMood(rows, bad) {
  if (!rows.length) return "sleepy";
  if (bad.some(item => item.result.level === "严重")) return "alarm";
  if (bad.length) return "warn";
  return "happy";
}

/* 头像旁边那句话。写的是**判断**，不是客套——
   第一眼就该知道今天要不要操心。 */
function heroLine(mood, rows, bad, weekHours, range) {
  if (mood === "sleepy") {
    return "";
  }
  if (mood === "alarm") {
    const worst = bad.find(item => item.result.level === "严重");
    return `《${worst.project.name}》情况比较紧，建议今天就看一眼。`;
  }
  if (mood === "warn") {
    const names = bad.map(item => `《${item.project.name}》`).join("、");
    return `${names} 需要处理，其余正常。`;
  }
  if (weekHours <= 0) {
    return `${rows.length} 个项目都在正常范围内。不过这 ${range.days} 天还没人报工时。`;
  }
  return `${rows.length} 个项目都在正常范围内，${range.days} 天里投了 ${weekHours.toFixed(0)} 小时。`;
}

/* 按日期聚合每日工时，返回 {labels, data}。
   窗口是最近 N 天（含今天），**每一天都要有位置**——
   没记工时的日子是 0，不能跳过，否则折线会把空档连起来，
   看起来像"一直在干活"。

   **用 fetchWorklogs() 而不是 DB.worklogs**：
   老板自己记的在 DB.worklogs，员工通过云端报上来的在
   DB.remoteWorklogs。只读前者的话，员工报的工时会从趋势图上消失。 */
function dailyHours(days) {
  const today = new Date();
  today.setHours(0, 0, 0, 0);
  const labels = [];
  const data = [];
  const sums = {};

  fetchWorklogs().forEach(log => {
    const key = log.work_date || "";
    sums[key] = (sums[key] || 0) + num(log.hours);
  });

  for (let i = days - 1; i >= 0; i -= 1) {
    const date = new Date(today.getTime() - i * 86400000);
    const key = dateToISO(date);
    labels.push(key.slice(5));          // "01-05"
    data.push(Math.round((sums[key] || 0) * 10) / 10);
  }
  return { labels, data };
}

/* ---------------------------------------------------------- 习惯打卡 */
/* 首屏顶部那一排圆圈。

   交互设计：**点一下直接打卡，不弹任何窗口**。
   习惯打卡最大的敌人是"打卡本身太麻烦"——
   每点一次都弹表单，三天就不想用了。
   所以只有"计量型要填数值"和"长按填备注"才弹层。 */

function renderHabits() {
  const rows = todayHabitRows();
  const row = $("habit-row");
  const title = $("habit-title");

  if (!rows.length) {
    title.textContent = "今日打卡";
    row.innerHTML = DB.habits.length
      ? '<div class="meta" style="padding:4px 0">没有习惯</div>'
      : '<div class="meta" style="padding:4px 0">没有习惯</div>';
    return;
  }

  const doneCount = rows.filter(item => item.done).length;
  const today = todayISO();
  title.textContent = `今日打卡 ${doneCount}/${rows.length}`
    + `　周${WEEKDAY_NAMES[weekdayOf(today) - 1]}`;

  row.innerHTML = rows.map(item => {
    const habit = item.habit;
    const quantity = habit.kind === "quantity";
    /* 计量型的圆圈里用 conic-gradient 画进度环，
       比例通过 CSS 变量 --p 传进去 */
    let ring = "";
    if (quantity) {
      const ratio = num(habit.target) > 0
        ? Math.min(1, num(item.value) / num(habit.target)) : 0;
      ring = ` style="--p:${Math.round(ratio * 100)}%"`;
    }
    const streak = item.streak > 1
      ? `<span class="habit-streak">${item.streak}</span>` : "";
    const valueText = quantity
      ? (item.done ? `${num(item.value)}` : "")
      : (item.done ? "✓" : "");
    return `
      <button class="habit ${item.done ? "done" : ""} ${quantity ? "qty" : ""}"
              data-habit="${habit.id}"${ring}>
        <span class="habit-dot">${escapeHtml(valueText)}</span>
        <span class="habit-name">${escapeHtml(habit.name)}</span>
        ${streak}
      </button>`;
  }).join("");

  row.querySelectorAll("[data-habit]").forEach(node => {
    const habitId = Number(node.dataset.habit);
    const habit = habitById(habitId);
    if (!habit) return;

    /* 长按 550ms 打开详情（改数值、写备注）。
       同时监听 touch 和 mouse：手机上走 touch，桌面浏览器调试走 mouse。
       用一个标志位区分"长按"和"单击"——长按后手指抬起时
       还会触发 click，不拦住就会立刻把刚打的卡又取消掉。 */
    let longPressed = false;
    let pressTimer = null;
    let startX = 0;
    let startY = 0;

    const startPress = event => {
      longPressed = false;
      /* 只有触摸才记录起点。鼠标的 mousemove 即使不按键也在触发，
         拿它做滑动检测会把正常的长按判成滑动——桌面上就没法长按了。 */
      if (event.touches) {
        startX = event.touches[0].clientX;
        startY = event.touches[0].clientY;
      }
      pressTimer = setTimeout(() => {
        longPressed = true;
        openHabitCheckin(habit);
      }, 550);
    };
    const cancelPress = () => {
      if (pressTimer) { clearTimeout(pressTimer); pressTimer = null; }
    };
    /* 滑动就取消长按。

       **这是个真问题，不是优化**：没有这段的话，
       手指按在圆圈上往左滑去翻看后面的习惯，滑到 550ms
       定时器照样触发，弹层就跳出来了——用户根本没想打开详情。

       横向位移超过 8px 就算滑动。阈值不能太小，否则手指
       轻微抖动也会把正常点按判成滑动。 */
    const maybeScrolled = event => {
      if (!pressTimer || !event.touches) return;
      const point = event.touches[0];
      if (Math.abs(point.clientX - startX) > 8
          || Math.abs(point.clientY - startY) > 8) {
        cancelPress();
        /* 标记一下：手指抬起时还会触发 click，
           不拦住就会顺手把卡打上或取消 */
        longPressed = true;
      }
    };

    node.addEventListener("touchstart", startPress, { passive: true });
    node.addEventListener("touchmove", maybeScrolled, { passive: true });
    node.addEventListener("touchend", cancelPress);
    node.addEventListener("touchcancel", cancelPress);
    node.addEventListener("mousedown", startPress);
    node.addEventListener("mouseup", cancelPress);
    node.addEventListener("mouseleave", cancelPress);

    node.onclick = () => {
      cancelPress();
      if (longPressed) { longPressed = false; return; }
      /* 计量型第一次点要先问数值——不知道记了多少就没法打卡 */
      if (habit.kind === "quantity" && !habitLogOn(habit.id, todayISO())) {
        openHabitCheckin(habit);
        return;
      }
      try {
        const nowDone = toggleHabit(habit.id);
        /* 触感反馈。打卡这种高频操作，震动是最直接的"确认感"。
           桌面浏览器没有这个 API，所以先判断存在。 */
        if (navigator.vibrate) navigator.vibrate(nowDone ? 14 : 8);
        toast(nowDone ? `已打卡：${habit.name}` : `已取消：${habit.name}`);

        /* **顺序很重要**：先重画，再从新画出来的 DOM 上找那个圆圈做动画。
           反过来做的话，renderHabits() 会把刚加动画的元素销毁，
           动画一帧都播不出来。 */
        renderHabits();
        renderDash();
        const fresh = $("habit-row").querySelector(`[data-habit="${habit.id}"]`);
        if (fresh) animateHabit(fresh, nowDone);
      } catch (error) {
        toast(error.message);
      }
    };
  });
}

/* 打卡时给那个圆圈一个弹性反馈。

   做法：加 .pop 类触发 keyframes，动画结束再移除。
   这里**不重画整个列表**——重画会让所有圆圈一起闪，
   看起来像"整页刷新"而不是"我点的那一个响应了"。 */
function animateHabit(node, done) {
  const dot = node.querySelector(".habit-dot");
  if (!dot) return;
  dot.classList.remove("pop");
  /* 强制回流，否则连续点同一个圆圈时动画不会重新触发
     （浏览器会把两次 class 变化合并成一次，看起来像没反应） */
  void dot.offsetWidth;
  dot.classList.add("pop");
  setTimeout(() => dot.classList.remove("pop"), 340);
  if (done) {
    node.classList.add("just-done");
    setTimeout(() => node.classList.remove("just-done"), 620);
  }
}

/* 计量型打卡 / 长按改备注，都用这一个弹层 */
function openHabitCheckin(habit) {
  const log = habitLogOn(habit.id, todayISO());
  const quantity = habit.kind === "quantity";
  const done = habitDone(log, habit);

  openSheet(habit.name, `
    ${quantity ? `
      <label for="h-value">今天做了多少（目标 ${num(habit.target)}${escapeHtml(habit.unit)}）</label>
      <input id="h-value" type="number" step="any" inputmode="decimal"
             value="${log ? num(log.value) : num(habit.target)}">`
      : `<div class="meta">${done ? "今天已经打卡。" : "今天还没打卡。"}</div>`}
    <label for="h-note">备注（可选）</label>
    <input id="h-note" value="${escapeHtml(log ? log.note : "")}">
    <label>坚持情况</label>
    <div class="meta">连续 ${habitStreak(habit.id)} 天　·　
      近 30 天完成率 ${Math.round(habitRate(habit.id, 30).rate * 100)}%</div>
  `, [
    { label: "取消", onClick: closeSheet },
    ...(log ? [{ label: "取消打卡", kind: "danger", onClick: () => {
      uncheckHabit(habit.id);
      closeSheet(); renderHabits(); renderDash(); toast("已取消");
    } }] : []),
    { label: "编辑", onClick: () => { closeSheet(); editHabit(habit.id); } },
    { label: "打卡", kind: "", onClick: () => {
      try {
        const value = quantity ? $("h-value").value : 1;
        checkHabit(habit.id, value, $("h-note").value);
        closeSheet(); renderHabits(); renderDash();
        toast("已打卡：" + habit.name);
      } catch (error) { toast(error.message); }
    } },
  ]);
}

/* 习惯的新增 / 编辑表单 */
function editHabit(id) {
  const habit = id ? habitById(id) : null;
  if (id && !habit) { toast("这条习惯已经不存在了"); return; }
  const isNew = !habit;
  const draft = habit || { kind: "daily", target: 1, weekdays: "" };
  const picked = String(draft.weekdays || "").split(/[\s,]+/);

  /* 周期用快捷按钮，不用输入框——
     手机上打 "1 3 5" 这种事没人愿意干 */
  const weekdayChips = [1, 2, 3, 4, 5, 6, 7].map(day =>
    `<button class="chip wd${picked.indexOf(String(day)) !== -1 ? " on" : ""}"`
    + ` data-day="${day}">周${WEEKDAY_NAMES[day - 1]}</button>`).join("");

  openSheet(isNew ? "新增习惯" : "编辑习惯", `
    <label for="hb-name">习惯名称 *</label>
    <input id="hb-name" value="${escapeHtml(draft.name || "")}">

    <label for="hb-kind">类型</label>
    <select id="hb-kind">
      <option value="daily"${draft.kind !== "quantity" ? " selected" : ""}>
        打勾型 —— 今天做没做</option>
      <option value="quantity"${draft.kind === "quantity" ? " selected" : ""}>
        计量型 —— 要达到某个数</option>
    </select>

    <div id="hb-quantity" class="${draft.kind === "quantity" ? "" : "hidden"}">
      <div class="row2">
        <div><label for="hb-target">目标值</label>
          <input id="hb-target" type="number" step="any" inputmode="decimal"
                 value="${num(draft.target) || ""}"></div>
        <div><label for="hb-unit">单位</label>
          <input id="hb-unit" value="${escapeHtml(draft.unit || "")}"></div>
      </div>
    </div>

    <label>什么时候做（都不选 = 每天）</label>
    <div class="chips" id="hb-weekdays">${weekdayChips}</div>

    <label for="hb-note">备注</label>
    <input id="hb-note" value="${escapeHtml(draft.note || "")}">
  `, [
    { label: "取消", onClick: closeSheet },
    ...(isNew ? [] : [{ label: "删除", kind: "danger", onClick: () => {
      if (!confirm(`确定删除「${habit.name}」？\n\n打卡记录会一起删掉。`)) return;
      deleteHabit(habit.id);
      closeSheet(); renderHabits(); renderDash(); toast("已删除");
    } }]),
    { label: "保存", kind: "", onClick: () => saveHabitForm(id) },
  ]);

  $("hb-kind").onchange = () => {
    $("hb-quantity").classList.toggle("hidden",
      $("hb-kind").value !== "quantity");
  };
  document.querySelectorAll("#hb-weekdays .wd").forEach(button => {
    button.onclick = () => button.classList.toggle("on");
  });
}

function saveHabitForm(id) {
  const picked = [];
  document.querySelectorAll("#hb-weekdays .wd").forEach(button => {
    if (button.classList.contains("on")) picked.push(button.dataset.day);
  });
  const kind = $("hb-kind").value;
  const targetInput = $("hb-target");
  const data = {
    name: $("hb-name").value,
    kind: kind,
    target: kind === "quantity" && targetInput ? targetInput.value : 0,
    unit: $("hb-unit") ? $("hb-unit").value : "",
    weekdays: picked.join(" "),
    note: $("hb-note").value,
  };
  try {
    if (id) updateHabit(id, data); else addHabit(data);
    closeSheet(); renderHabits(); renderDash();
    toast(id ? "已保存" : "已创建");
  } catch (error) {
    toast(error.message);
  }
}

/* ---------------------------------------------------------- 看板 */
/* 看板顶部那张「现在」卡：谁在干活、今日产出、待审批。

   三块内容从上到下：数字 → 在干活的人 → 等我处理的事。
   老板扫一眼就知道"要不要现在管点什么"。 */
function renderTeamCard() {
  const card = $("team-card");
  if (!card) return;
  const profile = DB.profile;
  if (!profile || !identityHasManagementView()) {
    card.classList.add("hidden");
    return;
  }
  card.classList.remove("hidden");

  const timeBox = $("team-card-time");
  if (timeBox) {
    timeBox.textContent = new Date().toTimeString().slice(0, 5);
  }

  /* ---- 谁在干活：有一条没结束的上工记录就是在干活 ---- */
  const sessions = (DB.workSessions || []).filter(row => !row.ended_at);
  const workingIds = sessions.map(row => String(row.profile_id));

  /* ---- 今日产出：今天赚到的源点 ---- */
  const todayStart = todayISO();
  const todayEarned = (DB.meritLedger || [])
    .filter(row => num(row.amount) > 0
      && meritDayKey(row.created_at) >= todayStart)
    .reduce((sum, row) => sum + num(row.amount), 0);

  /* ---- 待审批：兑换申请 + 请假 ---- */
  const pendingRedeem = (DB.redemptions || []).filter(row => row.status === "pending");
  const pendingLeave = (DB.leaves || []).filter(row => row.status === "pending");

  const summary = $("team-summary");
  if (summary) {
    summary.innerHTML =
      '<span><b>' + workingIds.length + '</b>人在干活</span>'
      + '<span><b>' + meritNumber(todayEarned) + '</b>' + MERIT.unit + ' 今日产出</span>'
      + '<span><b>' + (pendingRedeem.length + pendingLeave.length) + '</b>条待审批</span>';
  }

  /* 在干活的人：头像没有，就直接用名字，别做假头像 */
  const working = $("team-working");
  if (working) {
    if (!workingIds.length) {
      working.innerHTML = "";
    } else {
      const names = workingIds.map(id => {
        const account = (DB.staffAccounts || []).find(item =>
          String(item.employee_id) === id);
        const employee = (DB.employees || []).find(item => String(item.id) === id);
        return (account && account.name) || (employee && employee.name)
          || "员工 " + id.slice(0, 6);
      });
      working.innerHTML = '<div class="working-list">'
        + names.map(name => '<span class="working-chip">● '
          + escapeHtml(name) + '</span>').join("")
        + '</div>';
    }
  }

  /* 待审批：一条一行，两个按钮直接处理 */
  const todo = $("team-todo");
  if (!todo) return;

  const rows = [];
  pendingLeave.forEach(row => {
    const who = employeeNameOf(row.profile_id);
    rows.push('<div class="todo-row"><div class="grow">'
      + '<b>请假</b> · ' + escapeHtml(who)
      + '<div class="meta">' + escapeHtml(String(row.from_date).slice(0, 10))
      + ' → ' + escapeHtml(String(row.to_date).slice(0, 10))
      + (row.reason ? ' · ' + escapeHtml(row.reason) : '') + '</div></div>'
      + '<button class="chip" data-leave-no="' + escapeHtml(String(row.id)) + '">不准</button>'
      + '<button class="chip on" data-leave-yes="' + escapeHtml(String(row.id)) + '">准假</button>'
      + '</div>');
  });
  pendingRedeem.forEach(row => {
    const who = employeeNameOf(row.profile_id);
    rows.push('<div class="todo-row"><div class="grow">'
      + '<b>兑换</b> · ' + escapeHtml(who)
      + '<div class="meta">' + escapeHtml(row.title) + ' · '
      + num(row.cost) + ' ' + MERIT.unit + '</div></div>'
      + '<button class="chip" data-redeem-no="' + escapeHtml(String(row.id)) + '">拒</button>'
      + '<button class="chip on" data-redeem-yes="' + escapeHtml(String(row.id)) + '">给</button>'
      + '</div>');
  });

  todo.innerHTML = rows.length
    ? '<div class="todo-list">' + rows.join("") + '</div>'
    : '';

  /* ---- 本周榜 ----
     只排前三。全排出来在手机上太长，而且后几名看着不舒服 ——
     激励的目的是让人往上冲，不是让人难堪。 */
  const board = $("team-board");
  if (board) {
    const weekAgo = new Date(Date.now() - 7 * 86400000).toISOString();
    const earned = {};
    (DB.meritLedger || []).forEach(row => {
      if (num(row.amount) <= 0) return;
      if (String(row.created_at || "") < weekAgo) return;
      const id = String(row.profile_id || "");
      if (!id) return;
      earned[id] = (earned[id] || 0) + num(row.amount);
    });
    const top = Object.keys(earned)
      .map(id => ({ id: id, amount: earned[id] }))
      .sort((a, b) => b.amount - a.amount)
      .slice(0, 3);

    board.innerHTML = top.length
      ? '<div class="section-head" style="margin:16px 2px 6px">本周榜</div>'
        + top.map((item, index) =>
          '<div class="board-row"><span class="board-rank">'
          + (index + 1) + '</span>'
          + '<span class="grow">' + escapeHtml(employeeNameOf(item.id)) + '</span>'
          + '<span class="board-amount">+' + meritNumber(item.amount)
          + ' ' + MERIT.unit + '</span></div>').join("")
      : "";
  }

  /* 四条待审批按钮。原来写成一串三元表达式去猜 dataset 的键名，
     读起来费劲还容易写错，改成显式传属性名。 */
  const bind = (attr, fn) => {
    todo.querySelectorAll("[data-" + attr + "]").forEach(button => {
      button.onclick = async () => {
        button.disabled = true;
        try {
          await fn(button.getAttribute("data-" + attr));
          renderTeamCard();
        } catch (error) {
          button.disabled = false;
          toast(error.message);
        }
      };
    });
  };

  bind("leave-yes", id => decideLeave(id, true, ""));
  bind("leave-no", id => decideLeave(id, false, ""));
  bind("redeem-yes", id => decideRedemption(id, true));
  bind("redeem-no", id => decideRedemption(id, false));
}

/* 从 id 找名字。老板看板上到处要用，抽出来。 */
function employeeNameOf(profileId) {
  const id = String(profileId || "");
  const account = (DB.staffAccounts || []).find(item =>
    String(item.employee_id) === id);
  if (account && account.name) return account.name;
  const member = (DB.identity && Array.isArray(DB.identity.members)
    ? DB.identity.members : [])
    .find(item => String(item.profile_id) === id);
  if (member && member.name) return member.name;
  const employee = (DB.employees || []).find(item => String(item.id) === id);
  if (employee && employee.name) return employee.name;
  return "员工 " + id.slice(0, 6);
}

function renderDataFreshnessBanner() {
  const box = $("dash-banner");
  if (!box) return false;
  const error = String(DB.pullError || "").trim();
  const localOnly = (DB.projects || []).filter(item => !item.remote_id).length;
  if (!error && !localOnly) return false;
  const text = error
    ? "数据可能不是最新：" + error
    : `本机有 ${localOnly} 个项目尚未同步到公司，请到系统诊断确认上传。`;
  setBanner(box, text, "warn");
  return true;
}

function renderDash() {
  /* 「现在」这张卡先画 —— 老板打开 App 最想知道
     人有没有到位、今天产出了多少、有没有卡着等他的事。 */
  renderTeamCard();

  const rows = projectSummary();
  const bad = rows.filter(item => item.result.level === "风险"
                               || item.result.level === "严重");
  const people = activeEmployees();
  /* 变量名不叫 window——那会遮蔽全局的 window 对象，
     以后在这个函数里用 window.scrollTo 就会报错。 */
  const { rows: loads, window: range } = loadRows();
  const weekHours = loads.reduce((sum, row) => sum + row.hours, 0);

  /* 没有项目时**不写任何字**。
     页面上已经有「0 个项目」和头像旁边那句，再来一行同样的
     「还没有项目」纯属占地方。 */
  $("dash-sub").textContent = DB.projects.length
    ? `${DB.projects.length} 个项目 · ${people.length} 人在岗`
    : "";

  /* 一行摘要，取代原来的四张指标卡。
     卡片要占屏幕三分之一，而里面的数字和下面的列表是同一份信息——
     首屏该留给真正要看的东西。 */
  const parts = [`<b>${DB.projects.length}</b> 个项目`];
  if (bad.length) {
    parts.push(`<b class="hot">${bad.length}</b> 个需要处理`);
  } else if (DB.projects.length) {
    parts.push("没有需要处理的");
  }
  if (weekHours > 0) {
    parts.push(`近 ${range.days} 天 <b>${weekHours.toFixed(0)}</b> 小时`);
  }
  $("dash-stats").innerHTML = parts.join('<i>·</i>');

  /* 角色形象：挑表情 + 配一句话。
     这句话是**对当前状态的判断**，不是欢迎语——
     看一眼就知道今天要不要操心。 */
  const mood = dashboardMood(rows, bad);
  const chosenStar = selectedStarSticker();
  $("dash-hero-art").src = chosenStar ? starStickerSrc(chosenStar) : heroSrc(mood);
  $("dash-hero-line").textContent = chosenStar
    ? chosenStar.message
    : heroLine(mood, rows, bad, weekHours, range);
  renderStarCompanion(mood);

  /* 近两周工时折线。**画的是"每天多少小时"而不是累计**——
     累计曲线永远是往上的，看不出节奏；
     每日曲线能看出"周末还在干""连着几天没记"这类情况。 */
  const trend = dailyHours(14);
  const trendTotal = trend.data.reduce((sum, value) => sum + value, 0);
  /* 有超过 24 小时的日子要说出来 ——
     图会把它们压到顶上，不解释的话看着像"正常的高峰"。
     文案要短，太长会把标题挤成两行。 */
  const overDays = trend.data.filter(value => value > 24).length;
  $("dash-trend-range").textContent = trendTotal > 0
    ? `合计 ${trendTotal.toFixed(1)}h`
      + (overDays ? ` · ${overDays} 天超 24h` : "")
    : "";
  drawTrend($("trend-chart"), trend.labels,
    [{ name: "小时", data: trend.data }],
    { height: 150, empty: "还没有工时记录" });

  /* 习惯打卡排在最前——习惯的特点就是"容易忘"，
     而这一排是唯一"看完就知道今天有没有漏"的地方。 */
  renderHabits();

  const problems = worklogProblems();
  const list = $("dash-list");
  if (!rows.length) {
    /* 空列表不写字：上面已经有「0 个项目」和头像旁边那句，
       再来一遍「还没有项目，点上面 + 新建」是第三次重复。 */
    list.innerHTML = "";
    if (problems.length) {
      setBanner($("dash-banner"), problems[0].text, "warn");
    }
    renderDataFreshnessBanner();
    return;
  }

  /* 卡片瘦身：只留「名字 + 等级 + 进度 + 负责人 + 一句话结论」。
     步骤数、预算占用、阻塞数量都挪进详情页——
     它们在那里已经有更完整的呈现，列表里重复显示只会让每张卡变高。
     结果：一屏能看的项目从 3 个变成 5~6 个。 */
  list.innerHTML = rows.map(item => {
    const project = item.project;
    const result = item.result;
    const stats = result.metrics;
    const barClass = result.level === "健康" ? "ok"
      : result.level === "风险" ? "risk"
      : result.level === "严重" ? "severe" : "";
    let left = "";
    if (project.status === "已交付") left = "已交付";
    else if (stats.leftDays !== null) {
      left = stats.leftDays < 0 ? `超期 ${Math.abs(stats.leftDays)} 天`
                                : `剩 ${stats.leftDays} 天`;
    }
    const ownerLine = [project.owner || "未指定负责人", left]
      .filter(Boolean).join(" · ");
    return `
      <div class="card tap pj" data-project="${project.id}">
        <div class="pj-top">
          <span class="pj-name">${escapeHtml(project.name)}</span>
          <span class="pill pill-${escapeHtml(result.level)}">${escapeHtml(result.level)}</span>
        </div>
        <div class="pj-line">
          <div class="bar ${barClass}">
            <i style="width:${Math.min(100, stats.progress)}%"></i></div>
          <span class="pj-pct">${stats.progress}%</span>
        </div>
        <div class="pj-meta">${escapeHtml(ownerLine)}</div>
        <div class="pj-note">${escapeHtml(result.headline)}</div>
      </div>`;
  }).join("");

  document.querySelectorAll("#dash-list [data-project]").forEach(card => {
    card.onclick = () => openProject(Number(card.dataset.project));
  });

  if (problems.length) {
    setBanner($("dash-banner"),
      `${problems.length} 处工时异常：${problems[0].text}`, "warn");
  }
  renderDataFreshnessBanner();
}

/* ============================================================
   项目详情
   ============================================================ */
let currentProjectId = null;

function openProject(id) {
  currentProjectId = Number(id);
  renderProject();
  showPage("project");
}

function renderProject() {
  const project = getProject(currentProjectId);
  if (!project) {
    toast("这个项目已经不存在了");
    showPage("dash");
    return;
  }
  const result = predict(project);
  const stats = result.metrics;
  const budget = budgetOf(project);

  $("pj-title").textContent = project.name;
  $("pj-sub").textContent = `${project.owner || "未指定负责人"} · `
    + `${project.status} · 优先级 ${project.priority || "中"}`;

  const reasons = result.reasons.length
    ? result.reasons.map(reason => `<div class="r">· ${escapeHtml(reason.text)}`
        + (reason.detail
            ? `　<span style="color:var(--fg-dim)">（${escapeHtml(reason.detail)}）</span>`
            : "") + "</div>").join("")
    : '<div class="r">没有发现异常。</div>';
  const actions = result.actions.length
    ? '<div class="a">建议：<br>'
      + result.actions.map(item => "· " + escapeHtml(item)).join("<br>")
      + "</div>"
    : "";

  const steps = projectSteps(project.id);
  const stepHtml = steps.length ? steps.map(step => `
    <div class="list-item tap" data-step="${step.id}">
      <div class="row">
        <div class="grow"><span class="title">${escapeHtml(step.name)}</span>
          <div class="meta">${escapeHtml(step.owner || "未指定")} · 截止 `
          + `${escapeHtml(step.due_date || "—")}</div></div>
        <span class="pill pill-${escapeHtml(step.status)}">${escapeHtml(step.status)}</span>
      </div>
      <div style="margin-top:7px" class="bar">
        <i style="width:${clamp(num(step.progress), 0, 100)}%"></i></div>
      <div class="meta" style="margin-top:2px">${num(step.progress)}%</div>
    </div>`).join("") : '<div class="meta">还没有步骤。</div>';

  const abilities = projectAssessments(project.id, "ability");
  const resources = projectAssessments(project.id, "resource");
  const assessHtml = (label, list) => {
    if (!list.length) return "";
    const score = weighted(list);
    return `<div class="row" style="margin-top:8px">
        <div class="grow">${escapeHtml(label)}</div>
        <b>${score === null ? "—" : score.toFixed(2)} / 5</b></div>
      <div class="meta">${list.map(item =>
        `${escapeHtml(item.name)} ${item.score}`).join("　")}</div>`;
  };
  /* 两类都可能为空，所以先各自算好再拼，别在模板里反复调用 */
  const assessBlock = assessHtml("技术能力", abilities)
                    + assessHtml("有利资源", resources);
  const assessSection = assessBlock
    || '<div class="meta">还没有评估。</div>';

  const names = metricNames(project.id);
  const metricsHtml = names.length
    ? names.map(name => {
        const rows = projectMetrics(project.id, name);
        const last = rows[rows.length - 1];
        return `<div class="row" style="margin-top:6px">
          <div class="grow">${escapeHtml(name)}</div>
          <b>${num(last.value)}${escapeHtml(last.unit || "")}</b>
          <span class="meta">${rows.length} 个点</span></div>`;
      }).join("")
    : '<div class="meta">还没有指标。</div>';

  const logs = worklogsFor({ project_id: project.id, limit: 3 });
  const logHtml = logs.length ? logs.map(log => `
    <div class="row" style="margin-top:6px">
      <div class="grow meta">${escapeHtml(log.work_date)} ·
        ${escapeHtml(employeeName(log.employee_id))}</div>
      <b>${num(log.hours).toFixed(1)}h</b></div>`).join("")
    : '<div class="meta">还没有工时。</div>';

  $("pj-body").innerHTML = `
    <div class="card">
      <div class="row">
        <div class="grow meta">${escapeHtml(project.start_date || "—")} → `
        + `${escapeHtml(project.due_date || "—")}</div>
        <span class="pill pill-${escapeHtml(project.priority || "中")}">`
        + `${escapeHtml(project.priority || "中")}</span>
      </div>
      ${project.client ? `<div class="meta">客户：${escapeHtml(project.client)}</div>` : ""}
      <div style="margin:12px 0 6px">
        <div class="bar"><i style="width:${clamp(stats.progress, 0, 100)}%"></i></div>
      </div>
      <div class="meta">进度 ${stats.progress}% · 步骤 ${stats.done}/${stats.total}
        ${stats.blocked.length ? ` · 阻塞 ${stats.blocked.length}` : ""}
        · 投入 ${stats.hours.toFixed(1)} 小时 · ${stats.peopleCount} 人</div>
      <div class="btn-row">
        <button class="btn ghost" id="pj-add-step">+ 步骤</button>
        <button class="btn ghost" id="pj-add-metric">+ 指标</button>
        <button class="btn ghost" id="pj-add-assess">+ 能力</button>
      </div>
    </div>

    <div class="advice">
      <div class="head lv-${escapeHtml(result.level)}">
        【${escapeHtml(result.level)}】${escapeHtml(result.headline)}</div>
      ${reasons}${actions}
    </div>

    <div class="card">
      <div class="card-head"><h3>财务</h3></div>
      ${budget.has
        ? `<div class="row"><div class="grow">预算占用</div>
             <b class="${budget.over ? "lv-风险" : ""}">`
          + `${Math.round(budget.ratio * 100)}%</b></div>
           <div class="bar" style="margin-top:8px">
             <i style="width:${Math.min(100, budget.ratio * 100)}%"></i></div>
           <div class="meta" style="margin-top:5px">
             预算 ${money(budget.budget)}，已花 ${money(budget.cost)}，
             剩余 ${money(budget.remaining)}</div>`
        : '<div class="meta">还没设预算。</div>'}
    </div>

    <div class="card">
      <div class="card-head"><h3>步骤</h3>
        </div>
      ${steps.length ? '<canvas id="step-timeline" class="chart"></canvas>' : ""}
      ${stepHtml}
    </div>

    <div class="card">
      <div class="card-head"><h3>能力与资源</h3></div>
      ${assessSection}
    </div>

    <div class="card">
      <div class="card-head"><h3>指标</h3></div>
      ${metricsHtml}
    </div>

    <div class="card">
      <div class="card-head"><h3>工时对比</h3>
        <span class="meta">计划 / 实际</span></div>
      <canvas id="project-bars" class="chart"></canvas>
    </div>

    <div class="card">
      <div class="card-head"><h3>最近工时</h3>
        <span class="meta">共 ${stats.hours.toFixed(1)} 小时</span></div>
      ${logHtml}
    </div>

    ${project.note
      ? `<div class="card"><div class="card-head"><h3>备注</h3></div>
         <div class="meta">${escapeHtml(project.note)}</div></div>` : ""}

    <div class="card">
      <button class="btn danger" id="pj-delete">删除这个项目</button>
    </div>
  `;

  $("pj-add-step").onclick = () => editStep(project.id, null);
  $("pj-add-metric").onclick = () => editMetric(project.id, null);
  $("pj-add-assess").onclick = () => editAssessment(project.id, null);
  $("pj-delete").onclick = () => {
    if (!confirm(`确定删除《${project.name}》？\n\n`
        + "它的步骤、工时、分配、评估、指标都会一起删掉，不能撤销。")) return;
    deleteProject(project.id);
    toast("已删除");
    showPage("dash");
  };
  document.querySelectorAll("#pj-body [data-step]").forEach(node => {
    node.onclick = () => editStep(project.id, Number(node.dataset.step));
  });

  /* ---- 步骤时间轴（甘特图）----
     把每个步骤的开始/截止画成横条，today 那天画一条竖线。
     一眼就能看出哪些步骤是串行的、哪些已经过期还在跑。 */
  if (steps.length) {
    const canvas = $("step-timeline");
    const dated = steps.filter(step => step.start_date || step.due_date).length;
    canvas.dataset.h = String(Math.max(70, 44 + dated * 26));
    drawTimeline(canvas, steps.map(step => ({
      name: step.name,
      start: step.start_date,
      due: step.due_date,
      progress: num(step.progress),
      status: step.status,
    })), {
      height: Number(canvas.dataset.h),
      empty: "步骤填上日期后这里显示时间轴",
    });
  }

  /* ---- 计划 vs 实际工时（分组柱状图）----
     「计划」来自分配（assignment 的 planned_hours），
     「实际」来自工时记录。两者差得多的步骤就是估算失准的地方，
     比单看总进度有用得多。 */
  const assignments = projectAssignments(project.id);
  const actualByStep = {};
  /* 不传 limit：worklogsFor 里是 `if (opts.limit)`，
     传 0 虽然也返回全部，但读起来容易误解成"一条都不要"。 */
  worklogsFor({ project_id: project.id }).forEach(log => {
    if (!log.step_id) return;
    actualByStep[log.step_id] = (actualByStep[log.step_id] || 0)
                              + num(log.hours);
  });
  const plannedByStep = {};
  assignments.forEach(item => {
    if (!item.step_id) return;
    plannedByStep[item.step_id] = (plannedByStep[item.step_id] || 0)
                                + num(item.planned_hours);
  });

  /* 只画有计划或有实际的步骤；两组数据都没有就画空状态 */
  const barRows = steps.filter(step =>
    plannedByStep[step.id] || actualByStep[step.id]).map(step => ({
      label: step.name,
      values: [
        Math.round((plannedByStep[step.id] || 0) * 10) / 10,
        Math.round((actualByStep[step.id] || 0) * 10) / 10,
      ],
    }));

  const barsCanvas = $("project-bars");
  barsCanvas.dataset.h = "200";
  drawBars(barsCanvas, barRows, {
    height: 200,
    groupNames: ["计划", "实际"],
    empty: "给步骤分配人力并记工时后，这里显示对比",
  });
}

/* ============================================================
   项目表单
   ============================================================ */
function editProject(id) {
  const project = id ? getProject(id) : {
    status: "进行中", priority: "中", progress: 0, budget: 0, cost: 0,
  };
  if (!project) { toast("这个项目已经不存在了"); return; }
  openSheet(id ? "编辑项目" : "新建项目", `
    <label for="f-name">项目名称 *</label>
    <input id="f-name" value="${escapeHtml(project.name || "")}">
    <label for="f-owner">负责人</label>
    <input id="f-owner" value="${escapeHtml(project.owner || "")}">
    <label for="f-client">客户 / 需求方</label>
    <input id="f-client" value="${escapeHtml(project.client || "")}">
    <div class="row2">
      <div><label for="f-status">状态</label>
        <select id="f-status">${optionsHtml(
          ["规划中", "进行中", "已暂停", "已交付", "已取消"],
          project.status || "进行中")}</select></div>
      <div><label for="f-priority">优先级</label>
        <select id="f-priority">${optionsHtml(
          ["高", "中", "低"], project.priority || "中")}</select></div>
    </div>
    <div class="row2">
      <div><label for="f-start">开始日期</label>
        <input id="f-start" type="date" value="${escapeHtml(project.start_date || "")}"></div>
      <div><label for="f-due">计划截止</label>
        <input id="f-due" type="date" value="${escapeHtml(project.due_date || "")}"></div>
    </div>
    <div class="row2">
      <div><label for="f-budget">预算</label>
        <input id="f-budget" type="number" inputmode="decimal"
               value="${num(project.budget) || ""}"></div>
      <div><label for="f-cost">已花费</label>
        <input id="f-cost" type="number" inputmode="decimal"
               value="${num(project.cost) || ""}"></div>
    </div>
    <label for="f-progress">当前进度：<b id="f-progress-label">${num(project.progress)}%</b></label>
    <input id="f-progress" type="range" min="0" max="100" step="5"
           value="${num(project.progress)}">
    <label for="f-note">备注</label>
    <textarea id="f-note">${escapeHtml(project.note || "")}</textarea>
  `, [
    { label: "取消", onClick: closeSheet },
    { label: id ? "保存" : "创建", kind: "", onClick: () => {
      const data = {
        name: $("f-name").value,
        owner: $("f-owner").value,
        client: $("f-client").value,
        status: $("f-status").value,
        priority: $("f-priority").value,
        start_date: $("f-start").value,
        due_date: $("f-due").value,
        budget: $("f-budget").value,
        cost: $("f-cost").value,
        progress: $("f-progress").value,
        note: $("f-note").value,
      };
      try {
        if (id) { updateProject(id, data); toast("已保存"); }
        else { const created = addProject(data); currentProjectId = created.id;
               toast("已创建"); }
        closeSheet();
        if (id) renderProject(); else showPage("dash");
      } catch (error) { toast(error.message); }
    } },
  ]);
  const range = $("f-progress");
  range.oninput = () => { $("f-progress-label").textContent = range.value + "%"; };
}

function optionsHtml(values, selected) {
  return values.map(value =>
    `<option value="${escapeHtml(value)}"`
    + (value === selected ? " selected" : "") + `>${escapeHtml(value)}</option>`
  ).join("");
}

/* ============================================================
   步骤表单
   ============================================================ */
function editStep(projectId, stepId) {
  const step = stepId ? DB.steps.find(item => item.id === Number(stepId))
                      : { status: "未开始", progress: 0 };
  if (!step) { toast("这个步骤已经不存在了"); return; }
  const isNew = !stepId;
  openSheet(isNew ? "新增步骤" : "编辑步骤", `
    <label for="s-name">步骤名称 *</label>
    <input id="s-name" value="${escapeHtml(step.name || "")}">
    <label for="s-owner">负责人</label>
    <input id="s-owner" value="${escapeHtml(step.owner || "")}">
    <div class="row2">
      <div><label for="s-status">状态</label>
        <select id="s-status">${optionsHtml(
          ["未开始", "进行中", "已完成", "已阻塞"], step.status || "未开始")}</select></div>
      <div><label for="s-progress">进度</label>
        <input id="s-progress" type="number" min="0" max="100"
               value="${num(step.progress)}"></div>
    </div>
    <div class="row2">
      <div><label for="s-start">开始日期</label>
        <input id="s-start" type="date" value="${escapeHtml(step.start_date || "")}"></div>
      <div><label for="s-due">计划截止</label>
        <input id="s-due" type="date" value="${escapeHtml(step.due_date || "")}"></div>
    </div>
    <label for="s-note">备注</label>
    <input id="s-note" value="${escapeHtml(step.note || "")}">
  `, [
    { label: "取消", onClick: closeSheet },
    ...(isNew ? [] : [{ label: "删除", kind: "danger", onClick: () => {
      if (!confirm("确定删除这个步骤？\n\n它上面的工时不会删，只是不再关联到步骤。")) return;
      deleteStep(stepId); closeSheet(); renderProject(); toast("已删除");
    } }]),
    { label: "保存", kind: "", onClick: () => {
      const data = {
        name: $("s-name").value,
        owner: $("s-owner").value,
        status: $("s-status").value,
        progress: $("s-progress").value,
        start_date: $("s-start").value,
        due_date: $("s-due").value,
        note: $("s-note").value,
      };
      try {
        if (isNew) addStep(projectId, data); else updateStep(stepId, data);
        closeSheet(); renderProject(); toast("已保存");
      } catch (error) { toast(error.message); }
    } },
  ]);
}

/* ============================================================
   能力 / 资源 / 指标
   ============================================================ */
function editAssessment(projectId, assessmentId) {
  const item = assessmentId
    ? DB.assessments.find(row => row.id === Number(assessmentId)) : null;
  const isNew = !item;
  openSheet(isNew ? "新增评估" : "编辑评估", `
    <label for="a-kind">类型</label>
    <select id="a-kind">
      <option value="ability"${item && item.kind === "ability" ? " selected" : ""}>
        技术能力（这项本事够不够用）</option>
      <option value="resource"${item && item.kind === "resource" ? " selected" : ""}>
        有利资源（手上有什么有利条件）</option>
    </select>
    <label for="a-name">名称 *</label>
    <input id="a-name" value="${escapeHtml(item ? item.name : "")}">
    <div class="row2">
      <div><label for="a-score">评分（1~5）</label>
        <input id="a-score" type="number" min="1" max="5"
               value="${item ? item.score : 3}"></div>
      <div><label for="a-weight">权重</label>
        <input id="a-weight" type="number" step="0.5" min="0"
               value="${item ? item.weight : 1}"></div>
    </div>
    <label for="a-note">备注</label>
    <input id="a-note" value="${escapeHtml(item ? item.note : "")}">
  `, [
    { label: "取消", onClick: closeSheet },
    ...(isNew ? [] : [{ label: "删除", kind: "danger", onClick: () => {
      deleteAssessment(assessmentId); closeSheet(); renderProject(); toast("已删除");
    } }]),
    { label: "保存", kind: "", onClick: () => {
      try {
        addAssessment(projectId, {
          kind: $("a-kind").value, name: $("a-name").value,
          score: $("a-score").value, weight: $("a-weight").value,
          note: $("a-note").value,
        });
        closeSheet(); renderProject(); toast("已保存");
      } catch (error) { toast(error.message); }
    } },
  ]);
}

function editMetric(projectId, metricId) {
  const item = metricId
    ? DB.metrics.find(row => row.id === Number(metricId)) : null;
  const names = metricNames(projectId);
  openSheet(item ? "编辑指标" : "录入指标", `
    <label for="m-date">日期</label>
    <input id="m-date" type="date"
           value="${escapeHtml(item ? item.metric_date : todayISO())}">
    <label for="m-name">指标名</label>
    <input id="m-name" list="m-names" value="${escapeHtml(item ? item.name : "")}">
    <datalist id="m-names">${names.map(name =>
      `<option value="${escapeHtml(name)}"></option>`).join("")}</datalist>
    <div class="row2">
      <div><label for="m-value">数值</label>
        <input id="m-value" type="number" step="0.01" inputmode="decimal"
               value="${item ? item.value : ""}"></div>
      <div><label for="m-unit">单位</label>
        <input id="m-unit" value="${escapeHtml(item ? item.unit : "")}"></div>
    </div>
    <label for="m-note">备注</label>
    <input id="m-note" value="${escapeHtml(item ? item.note : "")}">
  `, [
    { label: "取消", onClick: closeSheet },
    { label: "保存", kind: "", onClick: () => {
      try {
        addMetric(projectId, {
          metric_date: $("m-date").value, name: $("m-name").value,
          value: $("m-value").value, unit: $("m-unit").value,
          note: $("m-note").value,
        });
        closeSheet(); renderProject(); toast("已记录");
      } catch (error) { toast(error.message); }
    } },
  ]);
}

/* ============================================================
   团队
   ============================================================ */
function enterpriseMemberRows() {
  const members = (DB.identity && Array.isArray(DB.identity.members)
    ? DB.identity.members : [])
    .filter(item => item && String(item.status || "active") !== "inactive");
  const byId = new Map();
  (DB.employees || []).forEach(item => {
    byId.set(String(item.id), { source: "local", item });
  });
  members.forEach(item => {
    byId.set(String(item.profile_id), { source: "member", item });
  });
  return Array.from(byId.values()).map(entry => {
    const m = entry.item;
    if (entry.source === "local") {
      return {
        id: m.id,
        profile_id: null,
        name: m.name,
        role: m.role || "",
        level: m.level || "",
        weekly_hours: num(m.weekly_hours) || 40,
      };
    }
    return {
      id: m.profile_id,
      profile_id: m.profile_id,
      name: m.name || "未命名成员",
      role: m.role_name
        || (typeof identityRoleLabel === "function" ? identityRoleLabel(m.role_key) : m.role_key),
      level: [m.department, m.title].filter(Boolean).join(" / "),
      weekly_hours: 40,
      active: true,
    };
  });
}

function teamMemberRows(range) {
  const hoursByMember = {};
  worklogsFor({ date_from: range.from, date_to: range.to, includeRemote: true })
    .forEach(log => {
      const key = String(log.employee_id || "");
      if (!key) return;
      hoursByMember[key] = (hoursByMember[key] || 0) + num(log.hours);
    });
  const rows = enterpriseMemberRows().map(item => {
    const hours = hoursByMember[String(item.id)] || 0;
    const expected = Math.max(1, num(item.weekly_hours) / 7 * range.days);
    return Object.assign({}, item, {
      hours,
      expected,
      ratio: hours / expected,
    });
  }).sort((a, b) => b.hours - a.hours);
  if (rows.length) return rows;
  return loadRows().rows.map(row => Object.assign({}, row, {
    id: row.id, profile_id: null, active: true,
  }));
}

function renderTeam() {
  const windowRange = loadRows().window;
  const rows = teamMemberRows(windowRange);
  const range = windowRange;
  /* 条数要把云端的一起算——否则员工报了一堆工时，
     这里还显示"0 条工时"，看起来像没收到。 */
  $("team-sub").textContent = `${rows.length} 人在岗 · `
    + `${fetchWorklogs().length} 条工时`;
  $("load-range").textContent = `最近 ${range.days} 天`;

  const canvas = $("load-chart");
  /* 不要留多余的空白。
     原来最少给 120px，而一行内容只画 62px，
     下面几十像素全是空的，看起来像"图表没加载出来"。 */
  canvas.dataset.h = Math.max(40, 34 + rows.length * 28);
  drawLoad(canvas, rows.map(row => ({
    name: row.name, hours: row.hours, ratio: row.ratio,
  })), { height: Number(canvas.dataset.h), empty: "还没有员工" });

  /* 各项目工时投入（柱状）。
     和上面的「按人负荷」是两个角度看同一批工时：
     上面看"谁忙"，这里看"忙在哪个项目上"。
     只算窗口内的工时，口径和人负荷保持一致。 */
  const byProject = {};
  worklogsFor({ date_from: range.from, date_to: range.to })
    .forEach(log => {
      const key = log.project_id === null
        ? "__none__" : String(log.project_id);
      byProject[key] = (byProject[key] || 0) + num(log.hours);
    });
  const projectBars = Object.keys(byProject).map(key => ({
    label: key === "__none__" ? "非项目"
      : (projectName(Number(key)) || "已删除"),
    values: [Math.round(byProject[key] * 10) / 10],
  })).sort((a, b) => b.values[0] - a.values[0]);

  const projectCanvas = $("project-chart");
  /* 没有数据时不要摆一个 200px 高的空盒子 ——
     里面只有一行"还没有记录"，下面全是空白，
     看起来像图表加载失败。有数据才给足高度。 */
  const projectH = projectBars.length ? 200 : 92;
  projectCanvas.dataset.h = String(projectH);
  $("project-range").textContent = `近 ${range.days} 天`;
  drawBars(projectCanvas, projectBars, {
    height: projectH,
    empty: "这段时间还没有工时记录",
  });

  /* 员工列表 + 工时列表合并在一页，手机上滚动比切页方便 */
  const employeeHtml = rows.length ? rows.map(row => `
    <div class="list-item tap" data-employee="${escapeHtml(String(row.id))}">
      <div class="row">
        <div class="grow"><span class="title">${escapeHtml(row.name)}</span>
          <div class="meta">${escapeHtml(row.role || "普通员工")}
            ${row.level ? " · " + escapeHtml(row.level) : ""}</div></div>
        <b class="${row.ratio > 1 ? "lv-风险" : ""}">
          ${Math.round(row.ratio * 100)}%</b>
      </div>
      <div class="meta">${Number(row.hours || 0).toFixed(1)} 小时 / 应出 `
        + `${Number(row.expected || 0).toFixed(0)} 小时</div>
    </div>`).join("") : '<div class="meta">还没有成员，先邀请同事加入公司。</div>';

  /* 团队页的工时列表要带上云端——员工报的必须出现在这里，
     否则老板看到的是"没人干活"。云端记录用只读方式展示。 */
  const logs = worklogsFor({ limit: 40, includeRemote: true });
  const logHtml = logs.length ? logs.map(log => `
    <div class="list-item tap" data-worklog="${log.id}">
      <div class="row">
        <div class="grow">
          <b>${escapeHtml(employeeName(log.employee_id))}</b>
          <span class="meta"> · ${escapeHtml(log.work_date)} · `
          + `${escapeHtml(projectName(log.project_id) || "非项目")}</span>
          ${log.source === "timer" ? '<span class="meta"> · 计时</span>' : ""}
        </div>
        <b>${num(log.hours).toFixed(1)}h</b>
      </div>
      ${log.content
        ? `<div class="meta" style="margin-top:2px">${escapeHtml(log.content)}</div>`
        : ""}
    </div>`).join("") : '<div class="meta">还没有工时记录。</div>';

  /* 员工列表塞进详情页太挤，直接渲染在同一个 body 里 */
  const body = $("page-team").querySelector(".body");
  const old = body.querySelector("#team-block");
  if (old) old.remove();
  const block = document.createElement("div");
  block.id = "team-block";
  block.innerHTML = `
    <div class="card"><div class="card-head"><h3>成员</h3>
      </div>${employeeHtml}</div>
    <div class="section-head"><span>工时记录</span></div>
    <div class="card">${logHtml}</div>`;
  body.appendChild(block);

  block.querySelectorAll("[data-employee]").forEach(node => {
    const id = String(node.dataset.employee);
    const member = enterpriseMemberRows().find(item => String(item.id) === id);
    if (member && member.profile_id && !getEmployee(id)) {
      toast("这位是公司成员，岗位调整请在治理页面进行");
      return;
    }
    editEmployee(Number(id));
  });
  block.querySelectorAll("[data-worklog]").forEach(node => {
    node.onclick = () => editWorklog(String(node.dataset.worklog));
  });
}

function editEmployee(id) {
  const employee = id ? getEmployee(id) : { active: 1, weekly_hours: 40 };
  if (!employee) { toast("这个人已经不在名单里了"); return; }
  const isNew = !id;
  openSheet(isNew ? "新增员工" : "编辑员工", `
    <label for="e-name">姓名 *</label>
    <input id="e-name" value="${escapeHtml(employee.name || "")}">
    <div class="row2">
      <div><label for="e-role">岗位</label>
        <input id="e-role" value="${escapeHtml(employee.role || "")}"></div>
      <div><label for="e-level">职级</label>
        <input id="e-level" value="${escapeHtml(employee.level || "")}"></div>
    </div>
    <label for="e-weekly">周工时基准</label>
    <input id="e-weekly" type="number" step="1" min="0"
           value="${num(employee.weekly_hours) || 40}">
    <div class="row2">
      <div><label for="e-hired">入职日期</label>
        <input id="e-hired" type="date"
               value="${escapeHtml(employee.hired_date || "")}"></div>
      <div><label for="e-active">状态</label>
        <select id="e-active">
          <option value="1"${employee.active !== 0 ? " selected" : ""}>在职</option>
          <option value="0"${employee.active === 0 ? " selected" : ""}>离职</option>
        </select></div>
    </div>
    <label for="e-note">备注</label>
    <input id="e-note" value="${escapeHtml(employee.note || "")}">
  `, [
    { label: "取消", onClick: closeSheet },
    ...(isNew ? [] : [{ label: "删除", kind: "danger", onClick: () => {
      if (!confirm(`确定删除 ${employee.name}？\n\n`
          + "他报的工时和分配会一起删掉。\n"
          + "如果只是想让他不出现在名单里，改成「离职」更好——"
          + "历史工时会保留。")) return;
      deleteEmployee(id); closeSheet(); renderTeam(); toast("已删除");
    } }]),
    { label: "保存", kind: "", onClick: () => {
      const data = {
        name: $("e-name").value, role: $("e-role").value,
        level: $("e-level").value, weekly_hours: $("e-weekly").value,
        hired_date: $("e-hired").value, active: $("e-active").value,
        note: $("e-note").value,
      };
      try {
        if (isNew) addEmployee(data); else updateEmployee(id, data);
        closeSheet(); renderTeam(); toast("已保存");
      } catch (error) { toast(error.message); }
    } },
  ]);
}

/* ============================================================
   工时表单
   ============================================================ */
async function editWorklog(id) {
  if (!id && !enterpriseMemberRows().length) {
    toast("先加一个员工");
    editEmployee(null);
    return;
  }
  const localLog = id ? DB.worklogs.find(
    row => String(row.id) === String(id)) : null;
  const cloudLog = id ? (DB.remoteWorklogs || []).find(
    row => String(row.id) === String(id)) : null;
  const log = localLog || cloudLog || null;
  if (id && !log) { toast("这条工时已经不存在了"); return; }
  const isNew = !log;
  const cloudOnly = !!cloudLog && !localLog;
  const draft = Object.assign(
    { work_date: todayISO(), hours: 8, source: "manual" },
    log || {}
  );
  if (cloudOnly && typeof loadWorklogDimensions === "function") {
    Object.assign(draft, await loadWorklogDimensions(cloudLog));
  }
  const locked = cloudOnly ? " disabled" : "";
  const memberRows = enterpriseMemberRows();
  let employeeOptions = memberRows.map(row =>
    `<option value="${escapeHtml(String(row.id))}"`
      + (String(draft.employee_id) === String(row.id) ? " selected" : "")
      + `>${escapeHtml(row.name)}</option>`).join("");
  /* 正在改一条云端来源的工时，其 employee_id 可能已不在当前名单里，
     这里补一个只读占位，否则下拉框会变空。 */
  if (draft.employee_id
      && !memberRows.some(row => String(row.id) === String(draft.employee_id))) {
    employeeOptions = `<option value="${escapeHtml(String(draft.employee_id))}" selected>`
      + `${escapeHtml(employeeNameOf(draft.employee_id))}</option>` + employeeOptions;
  }
  const projectOptions = DB.projects.map(project =>
    `<option value="${project.id}"`
      + (String(draft.project_id) === String(project.id) ? " selected" : "")
      + `>${escapeHtml(project.name)}</option>`).join("");

  openSheet(isNew ? "记一笔工时" : "修改工时", `
    ${cloudOnly ? '<div class="hint">这条是云端来源工时。基础字段保持只读；经营标签会通过权限校验后单独保存。</div>' : ""}
    <label for="w-employee">谁</label>
    <select id="w-employee"${locked}>${employeeOptions}</select>
    <label for="w-project">项目</label>
    <select id="w-project"${locked}><option value="">（非项目事务）</option>
      ${projectOptions}</select>
    <label for="w-step">步骤（可选）</label>
    <select id="w-step"${locked}></select>
    <div class="row2">
      <div><label for="w-date">日期</label>
        <input id="w-date" type="date" value="${escapeHtml(draft.work_date || todayISO())}"${locked}></div>
      <div><label for="w-hours">工时</label>
        <input id="w-hours" type="number" step="0.5" min="0.5" max="24"
               value="${num(draft.hours) || 8}"${locked}></div>
    </div>
    <label for="w-content">做了什么</label>
    <textarea id="w-content"${locked}>${escapeHtml(draft.content || "")}</textarea>
    <div class="section-head" style="margin-top:14px"><span>经营标签</span>
      <span class="meta">默认已选好，按实际情况调整</span></div>
    <div class="check-grid">
      <label class="check"><input type="checkbox" id="w-billable"
        ${draft.billable === false ? "" : "checked"}>可计费</label>
      <label class="check"><input type="checkbox" id="w-overtime"
        ${draft.overtime ? "checked" : ""}>加班</label>
      <label class="check"><input type="checkbox" id="w-rework"
        ${draft.rework ? "checked" : ""}>返工</label>
      <label class="check"><input type="checkbox" id="w-waiting"
        ${draft.waiting ? "checked" : ""}>等待</label>
      <label class="check"><input type="checkbox" id="w-travel"
        ${draft.travel ? "checked" : ""}>出差</label>
    </div>
    <label for="w-kind">工作类型</label>
    <select id="w-kind">
      <option value="project"${draft.work_kind === "project" || !draft.work_kind ? " selected" : ""}>项目</option>
      <option value="presales"${draft.work_kind === "presales" ? " selected" : ""}>售前</option>
      <option value="internal"${draft.work_kind === "internal" ? " selected" : ""}>内部</option>
    </select>
    ${log && log.source === "timer"
      ? '<div class="hint">这条是计时器记的。改小时数等于推翻了计时结论，'
        + "改之前先想一下是不是该重新解释。</div>" : ""}
  `, [
    { label: "取消", onClick: closeSheet },
    ...(isNew || cloudOnly ? [] : [{ label: "删除", kind: "danger", onClick: () => {
      if (!confirm("确定删除这条工时？")) return;
      deleteWorklog(id); closeSheet(); renderTeam(); toast("已删除");
    } }]),
    { label: "保存", kind: "", onClick: () => saveWorklog(id || null) },
  ]);

  $("w-project").onchange = () =>
    fillStepSelect($("w-step"), $("w-project").value, draft.step_id);
  fillStepSelect($("w-step"), draft.project_id, draft.step_id);
}

function fillStepSelect(select, projectId, selectedId) {
  const steps = projectId ? projectSteps(Number(projectId)) : [];
  select.innerHTML = '<option value="">不指定步骤</option>'
    + steps.map(step => `<option value="${step.id}"`
        + (Number(selectedId) === step.id ? " selected" : "")
        + `>${escapeHtml(step.name)}</option>`).join("");
}

function saveWorklog(id) {
  const data = {
    employee_id: $("w-employee").value,
    project_id: $("w-project").value,
    step_id: $("w-step").value,
    work_date: $("w-date").value,
    hours: $("w-hours").value,
    content: $("w-content").value,
    billable: $("w-billable").checked,
    overtime: $("w-overtime").checked,
    work_kind: $("w-kind").value,
    rework: $("w-rework").checked,
    waiting: $("w-waiting").checked,
    travel: $("w-travel").checked,
  };
  try {
    if (id) {
      const saved = updateWorklog(id, data);
      syncWorklogDimensions(saved);
      closeSheet(); renderTeam(); toast("已保存");
      return;
    }
    const saved = addWorklog(data, { allowDuplicate: false });
    syncWorklogDimensions(saved);
    closeSheet(); renderTeam(); toast("已记录");
  } catch (error) {
    /* 重复的提示带前缀，单独处理——要问用户是否继续 */
    if (String(error.message).indexOf("DUPLICATE:") === 0) {
      const detail = String(error.message).slice("DUPLICATE:".length);
      if (confirm(`已经有一样的记录了：\n${detail}\n\n`
          + "如果确实是两段分开的工作，就继续记。")) {
        try {
          const saved = addWorklog(data, { allowDuplicate: true });
          syncWorklogDimensions(saved);
          closeSheet(); renderTeam(); toast("已记录");
        } catch (second) { toast(second.message); }
      }
      return;
    }
    toast(error.message);
  }
}

/* ============================================================
   小助手
   ============================================================ */
let chat = [];

/* 按回答内容挑表情。
   **这是表情真正有用的地方**：不用读完整段话，
   看头像就知道这条回答是"好消息"还是"要出事了"。
   关键词匹配不精确，但这里只需要情绪方向，不需要语义理解。 */
function moodForAnswer(answer) {
  const text = String(answer || "");
  if (/严重|超期|逾期|已经超|失控/.test(text)) return "alarm";
  if (/风险|超预算|超支|阻塞|卡住|异常|需要处理|注意/.test(text)) return "warn";
  if (/没理解|没找到|不清楚|换个问法|不认识/.test(text)) return "puzzled";
  if (/健康|正常|没问题|都在范围|没有发现/.test(text)) return "happy";
  if (/建议|可以|不妨|最好/.test(text)) return "warm";
  return "ok";
}

function bubbleHtml(item) {
  const mine = item.me;
  const mood = item.mood || (mine ? "neutral" : "ok");
  /* 机器人的回答带圆形头像；自己的消息不带——
     两边都放头像会让对话显得很乱。 */
  const avatar = mine ? ""
    : `<img class="avatar-round sticker" src="${faceSrc(mood)}" alt="">`;
  return `<div class="bubble-row ${mine ? "me" : "bot"}">`
       + avatar
       + `<div class="bubble ${mine ? "me" : "bot"}">`
       + escapeHtml(item.text) + "</div></div>";
}

function renderAssist() {
  /* **去重。** 固定推荐和"按当前数据补的"是两组来源，
     撞车过：没有项目时两边都出「现在什么情况」，
     页面上就并排两个一模一样的按钮。源头已经改了，
     这里再兜一道，免得以后再加推荐时又撞。 */
  const chips = [];
  SUGGESTIONS.concat(urgentSuggestions()).forEach(item => {
    if (chips.indexOf(item) === -1) chips.push(item);
  });
  $("assist-chips").innerHTML = chips.map(item =>
    `<button class="chip" data-ask="${escapeHtml(item)}">${escapeHtml(item)}</button>`
  ).join("");
  document.querySelectorAll("#assist-chips .chip").forEach(button => {
    button.onclick = () => sendAsk(button.dataset.ask);
  });

  const box = $("chat");
  if (chat.length) {
    box.innerHTML = chat.map(bubbleHtml).join("");
  } else {
    /* 空状态：用整身立绘 + 羽化，比一个圆头像更有形象感 */
    box.innerHTML = `
      <div class="assist-empty">
        <img class="hero-art sticker" src="${heroSrc("watch")}" alt="">
        <div class="bubble bot">数据都在本机，不联网，也不猜。</div>
      </div>`;
  }
  const last = box.lastElementChild;
  if (last) last.scrollIntoView({ block: "nearest" });
}

function sendAsk(text) {
  const question = String(text || "").trim();
  if (!question) return;
  $("ask").value = "";
  chat.push({ me: true, text: question });
  let answer;
  let mood = "ok";
  try {
    answer = ask(question);
    mood = moodForAnswer(answer);
  } catch (error) {
    answer = "算的时候出错了：" + error.message;
    mood = "puzzled";
  }
  chat.push({ me: false, text: answer, mood: mood });
  if (chat.length > 60) chat = chat.slice(-60);
  saveSetting("chat", chat);
  renderAssist();
}

/* ============================================================
   导入 / 导出
   ============================================================ */
function pickFile(onPick) {
  const input = document.createElement("input");
  input.type = "file";
  input.accept = ".json,application/json";
  input.onchange = () => {
    if (input.files && input.files[0]) onPick(input.files[0]);
  };
  input.click();
}

function download(filename, data) {
  const blob = new Blob([data], { type: "application/json;charset=utf-8" });
  const url = URL.createObjectURL(blob);
  const link = document.createElement("a");
  link.href = url;
  link.download = filename;
  document.body.appendChild(link);
  link.click();
  document.body.removeChild(link);
  setTimeout(() => URL.revokeObjectURL(url), 2000);
}

function stamp() {
  const now = new Date();
  const pad = n => String(n).padStart(2, "0");
  return `${now.getFullYear()}${pad(now.getMonth() + 1)}${pad(now.getDate())}`
       + `_${pad(now.getHours())}${pad(now.getMinutes())}`;
}

/* 导出整库。这个格式和电脑版的「手机快照」是一样的，
   所以电脑那边可以原样读；手机也能读电脑导出的快照。 */
function exportDatabase() {
  const payload = {
    format: "ProjectRecorder.snapshot",
    version: 1,
    exported_at: nowISO(),
    source: "mobile",
    range: { from: "", to: "" },
    note: "从手机版导出",
    employees: DB.employees,
    projects: DB.projects.map(project => Object.assign({}, project, {
      steps: projectSteps(project.id),
      assessments: projectAssessments(project.id),
      metrics: projectMetrics(project.id),
    })),
    assignments: DB.assignments,
    /* 习惯也导出。电脑端暂时不认这两个字段（会忽略掉），
       但**手机自己导入时要用**，所以必须带——
       否则换手机或者重装，打卡记录就全没了。

       打卡记录里**存习惯名字而不只是 id**：id 是每台机器各自
       自增的，换一台机器就对不上了。名字才是稳定标识。 */
    habits: DB.habits,
    habitLogs: DB.habitLogs.map(log => {
      const habit = habitById(log.habit_id);
      return {
        habit_name: habit ? habit.name : "",
        habit_id: log.habit_id,
        log_date: log.log_date,
        value: num(log.value),
        note: log.note || "",
        done_at: log.done_at || "",
      };
    }),
    worklogs: DB.worklogs.map(log => ({
      employee: employeeName(log.employee_id),
      project: projectName(log.project_id),
      step: stepName(log.step_id),
      work_date: log.work_date,
      hours: num(log.hours),
      content: log.content || "",
      source: log.source || "manual",
      key: "",
    })),
  };
  download(`项目快照_${stamp()}.json`, JSON.stringify(payload, null, 1));
  closeSheet();
  toast("已导出，把文件发给电脑即可");
}

/* 导入整库：**合并**而不是覆盖，否则会丢掉本地记的东西。
   合并规则按 id 判断，两边都有的取 updated_at 新的那个。 */
function importDatabase(file) {
  const reader = new FileReader();
  reader.onload = () => {
    let data;
    try {
      data = JSON.parse(reader.result);
    } catch (error) {
      toast("这个文件解析不了：" + error.message);
      return;
    }
    const format = data && data.format;
    if (format === "ProjectRecorder.snapshot") {
      mergeSnapshot(data);
    } else if (format === "ProjectRecorder.worklog") {
      /* 电脑版导出的「员工工时文件」：只有一个人的一段工时。
         按名字找人和项目，找不到就跳过并报告——和电脑端的规则一致。 */
      mergeWorklogFile(data);
    } else {
      toast("这不是本程序导出的文件");
      return;
    }
    closeSheet();
    showPage("dash");
  };
  reader.onerror = () => toast("读不了这个文件");
  reader.readAsText(file, "utf-8");
}

/* 兼容旧名字：主菜单里那条「导入电脑导出的快照」 */
function importSnapshot(file) { importDatabase(file); }

function mergeSnapshot(data) {
  let added = { project: 0, employee: 0, worklog: 0, step: 0,
                habit: 0, habitLog: 0 };
  const nameToEmployee = {};
  const nameToProject = {};

  /* 员工：按名字认，没有就新建 */
  (data.employees || []).forEach(incoming => {
    let existing = employeeByName(incoming.name);
    if (!existing) {
      try {
        existing = addEmployee(incoming);
        added.employee += 1;
      } catch (error) { existing = null; }
    }
    if (existing) nameToEmployee[incoming.name] = existing.id;
  });
  DB.employees.forEach(employee => { nameToEmployee[employee.name] = employee.id; });

  /* 项目：按名字认。两边都有就取 updated_at 新的那个覆盖本地。 */
  (data.projects || []).forEach(incoming => {
    const existing = DB.projects.find(item => item.name === incoming.name);
    if (!existing) {
      try {
        const created = addProject(incoming);
        nameToProject[incoming.name] = created.id;
        added.project += 1;
        (incoming.steps || []).forEach(step => {
          try { addStep(created.id, step); added.step += 1; } catch (error) { /* 跳过 */ }
        });
        (incoming.assessments || []).forEach(item => {
          try { addAssessment(created.id, item); } catch (error) { /* 跳过 */ }
        });
        (incoming.metrics || []).forEach(item => {
          try { addMetric(created.id, item); } catch (error) { /* 跳过 */ }
        });
      } catch (error) { /* 名字为空之类，跳过 */ }
      return;
    }
    nameToProject[incoming.name] = existing.id;
    const mine = existing.updated_at || "";
    const theirs = incoming.updated_at || "";
    if (theirs && theirs > mine) {
      try { updateProject(existing.id, incoming); } catch (error) { /* 跳过 */ }
    }
    /* 步骤按名字合并 */
    const seen = {};
    projectSteps(existing.id).forEach(step => { seen[step.name] = true; });
    (incoming.steps || []).forEach(step => {
      if (seen[step.name]) return;
      try { addStep(existing.id, step); added.step += 1; } catch (error) { /* 跳过 */ }
    });
  });
  DB.projects.forEach(project => { nameToProject[project.name] = project.id; });

  /* 工时：按「人 + 项目 + 日期 + 工时 + 说明」去重后并入。
     这条规则和电脑端的导入完全一致，所以两边反复互导也不会重复。 */
  (data.worklogs || []).forEach(incoming => {
    const employeeId = nameToEmployee[incoming.employee];
    if (!employeeId) return;
    const projectId = incoming.project
      ? nameToProject[incoming.project] : null;
    if (incoming.project && !projectId) return;   // 未知项目跳过
    const probe = {
      employee_id: employeeId, project_id: projectId,
      work_date: incoming.work_date, hours: num(incoming.hours),
      content: incoming.content || "",
    };
    const twin = DB.worklogs.find(row =>
      row.employee_id === probe.employee_id
      && row.project_id === probe.project_id
      && row.work_date === probe.work_date
      && Math.abs(num(row.hours) - probe.hours) < 0.001
      && String(row.content || "") === probe.content);
    if (twin) return;
    try {
      addWorklog(Object.assign({}, probe, {
        source: incoming.source === "timer" ? "timer" : "manual",
      }), { allowDuplicate: true });
      added.worklog += 1;
    } catch (error) { /* 脏数据跳过 */ }
  });

  /* 习惯：按名字认，已有的保留本地（不覆盖打卡记录），
     新的加进来。打卡记录按「习惯 + 日期」去重后并入。 */
  const habitByName = {};
  DB.habits.forEach(habit => { habitByName[habit.name] = habit.id; });
  (data.habits || []).forEach(incoming => {
    if (!incoming || !incoming.name) return;
    if (habitByName[incoming.name]) return;      // 已存在，跳过
    try {
      const created = addHabit(incoming);
      habitByName[incoming.name] = created.id;
      added.habit += 1;
    } catch (error) { /* 数据不完整就跳过 */ }
  });

  (data.habitLogs || []).forEach(incoming => {
    const habitId = habitByName[incoming.habit_name]
      || (incoming.habit_id && habitById(incoming.habit_id)
          ? Number(incoming.habit_id) : null);
    if (!habitId || !incoming.log_date) return;
    if (habitLogOn(habitId, incoming.log_date)) return;   // 那天已有记录
    DB.habitLogs.push({
      id: nextId("habitLog"),
      habit_id: habitId,
      log_date: String(incoming.log_date),
      value: num(incoming.value) || 1,
      note: String(incoming.note || ""),
      done_at: incoming.done_at || nowISO(),
    });
    added.habitLog += 1;
  });
  if (added.habitLog) _save();

  renderDash();
  const habitNote = (added.habit || added.habitLog)
    ? `、${added.habit} 条习惯、${added.habitLog} 次打卡` : "";
  toast(`已合并：新增 ${added.project} 个项目、`
    + `${added.employee} 人、${added.worklog} 条工时${habitNote}`);
}

/* 电脑版的员工工时文件：一个人、一段时间的工时 */
function mergeWorklogFile(data) {
  const employeeNameValue = data.employee && data.employee.name;
  if (!employeeNameValue) { toast("文件里没说是谁提交的"); return; }
  let employee = employeeByName(employeeNameValue);
  let createdEmployee = false;
  if (!employee) {
    try {
      employee = addEmployee(data.employee);
      createdEmployee = true;
    } catch (error) { toast("建不了这个员工：" + error.message); return; }
  }
  let added = 0;
  let duplicated = 0;
  const unknown = [];
  (data.entries || []).forEach(entry => {
    const project = entry.project
      ? DB.projects.find(item => item.name === entry.project) : null;
    if (entry.project && !project) {
      if (unknown.indexOf(entry.project) === -1) unknown.push(entry.project);
      return;
    }
    const projectId = project ? project.id : null;
    let stepId = null;
    if (entry.step && project) {
      const step = projectSteps(project.id).find(item => item.name === entry.step);
      if (step) stepId = step.id;
    }
    const twin = DB.worklogs.find(row =>
      row.employee_id === employee.id
      && row.project_id === projectId
      && row.work_date === entry.work_date
      && Math.abs(num(row.hours) - num(entry.hours)) < 0.001
      && String(row.content || "") === String(entry.content || ""));
    if (twin) { duplicated += 1; return; }
    try {
      addWorklog({
        employee_id: employee.id, project_id: projectId, step_id: stepId,
        work_date: entry.work_date, hours: entry.hours,
        content: entry.content, source: entry.source,
      }, { allowDuplicate: true });
      added += 1;
    } catch (error) { /* 跳过脏数据 */ }
  });

  let message = `新增 ${added} 条工时`;
  if (duplicated) message += `，已存在跳过 ${duplicated} 条`;
  if (createdEmployee) message = `（新建员工 ${employeeNameValue}）` + message;
  if (unknown.length) message += `；${unknown.join("、")} 不在项目列表里，已跳过`;
  renderDash();
  toast(message);
}

/* ---------------------------------------------------------- 启动 */
document.addEventListener("DOMContentLoaded", () => {
  try {
    chat = getSetting("chat", []);
    if (!Array.isArray(chat)) chat = [];
    boot();
  } catch (error) {
    showBootError("启动失败", error.message + "\n\n" + (error.stack || ""));
  }
});
