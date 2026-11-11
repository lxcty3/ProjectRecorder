/* =============================================================
   简单模式 · 今日工位
   -------------------------------------------------------------
   普通成员默认只看到今天要做什么、自己的积分和可解锁知识。
   管理、财务、审计和治理页面必须显式切到高级模式才出现。
   ============================================================= */
"use strict";

const TODAY_POINT_REFRESH_MS = 10000;

function mobileAdvancedAllowed() {
  if (typeof identityHasAdvancedAccess === "function") {
    return identityHasAdvancedAccess();
  }
  return !!(DB.profile && DB.profile.role === "boss");
}

function mobileHomePage() {
  if (!mobileAdvancedAllowed() || DB.uiMode !== "advanced") return "today";
  const management = typeof identityHasManagementView === "function"
    ? identityHasManagementView() : true;
  return management ? "decisions" : "dash";
}

function todayTaskRows() {
  const tasks = typeof tasksOn === "function" ? tasksOn(todayISO()) : [];
  return tasks.slice().sort((a, b) => {
    const ad = typeof taskLogFor === "function" && taskLogFor(a.id) ? 1 : 0;
    const bd = typeof taskLogFor === "function" && taskLogFor(b.id) ? 1 : 0;
    return ad - bd || (Number(a.sort) || 0) - (Number(b.sort) || 0);
  });
}

function todayStreakDays() {
  const dates = new Set((Array.isArray(DB.habitLogs) ? DB.habitLogs : [])
    .map(log => String((log && log.log_date) || "").slice(0, 10))
    .filter(Boolean));
  if (!dates.size) return 0;
  const cursor = new Date();
  const pad = n => String(n).padStart(2, "0");
  let streak = 0;
  while (streak < 366) {
    const key = `${cursor.getFullYear()}-${pad(cursor.getMonth() + 1)}-${
      pad(cursor.getDate())}`;
    if (!dates.has(key)) break;
    streak += 1;
    cursor.setDate(cursor.getDate() - 1);
  }
  return streak;
}

function todayTaskCard(task, index) {
  const log = typeof taskLogFor === "function" ? taskLogFor(task.id) : null;
  const done = !!log;
  const pending = typeof taskPendingAccept === "function"
    && taskPendingAccept(task);
  const rejected = typeof taskRejected === "function" && taskRejected(task);
  const started = !!task.started_at;
  const action = done ? "已完成" : pending ? "去接受"
    : rejected ? "去处理" : started ? "继续" : "开始";
  const state = done ? "今天完成"
    : pending ? "等待你接受" : rejected ? "已拒绝，等待处理"
    : started ? "已开始" : "待开始";
  const questNo = String(index + 1).padStart(2, "0");
  const tone = done ? " is-done" : pending ? " is-pending" : "";
  return `<div class="today-task-route game-quest${tone}">
    <span class="quest-node" aria-hidden="true">${done ? "✓" : questNo}</span>
    <div class="today-task-copy">
      <span class="quest-project">${escapeHtml(task.project_name || "今日行动")}</span>
      <b>${escapeHtml(task.title || "任务")}</b>
      <span class="quest-state">${state}</span>
    </div>
    <button class="btn quest-action${done ? " ghost" : ""}" data-today-task="${
      escapeHtml(task.id)
    }" ${done ? "disabled" : ""}>${action}</button>
  </div>`;
}

function todayPendingItems(tasks) {
  const items = [];
  const accepts = tasks.filter(task =>
    !(typeof taskLogFor === "function" && taskLogFor(task.id))
    && typeof taskPendingAccept === "function" && taskPendingAccept(task));
  accepts.slice(0, 1).forEach(task => items.push({
    kind: "task", title: "任务待接受", body: task.title || "今日任务",
    page: "tasks",
  }));

  const invites = organizationState && organizationState.member_invites
    ? (organizationState.member_invites.received || [])
      .filter(item => item.status === "invited") : [];
  invites.slice(0, 1).forEach(item => items.push({
    kind: "member-invite", inviteId: item.id,
    title: "公司邀请", body: item.organization_name || "新公司",
    detail: [item.department, item.title].filter(Boolean).join(" · "),
  }));

  const unread = typeof notifications === "function"
    ? notifications().filter(item => !item.read) : [];
  unread.slice(0, 1).forEach(item => items.push({
    kind: "notice", title: item.title || "待查看通知",
    body: item.body || item.text || "进入我的查看详情", page: "me",
  }));

  return items.slice(0, 3);
}

function todayPendingHtml(items) {
  return items.length ? items.map(item => `
    <div class="today-ledger-row">
      <div><b>${escapeHtml(item.title || "待处理")}</b>
        <span>${escapeHtml(item.body || "")}${item.detail ? " · " + escapeHtml(item.detail) : ""}</span></div>
      ${item.kind === "member-invite"
        ? `<div class="identity-vote-actions">
             <button class="identity-small-btn" data-today-member-invite="${escapeHtml(item.inviteId)}" data-accept="0">拒绝</button>
             <button class="identity-small-btn" data-today-member-invite="${escapeHtml(item.inviteId)}" data-accept="1">接受</button>
           </div>`
        : `<button class="identity-small-btn" data-today-go="${escapeHtml(item.page || "today")}">去处理</button>`}
    </div>`).join("")
    : '<div class="identity-empty game-empty"><b>没有待处理事项</b><span>可以专心完成今天的行动。</span></div>';
}

function todayWorkingHtml() {
  const open = typeof openWorkSession === "function" ? openWorkSession() : null;
  if (!open) {
    return '<div class="identity-empty game-empty"><b>当前没有进行中的工作</b>'
      + '<span>进入任务页开始一项工作，这里会显示实时状态。</span></div>'
      + '<button class="btn ghost" id="btn-today-start-work" style="width:100%;margin-top:8px">去任务页开始</button>';
  }
  const task = typeof taskById === "function" ? taskById(open.task_id) : null;
  const started = String(open.started_at || "").slice(11, 16) || "刚刚";
  return `<div class="identity-motion open">
    <div class="identity-motion-head"><div>
      <div class="identity-eyebrow">从 ${escapeHtml(started)} 开始</div>
      <b>${escapeHtml(task && task.title ? task.title : "当前工作")}</b>
    </div><span class="identity-status open">进行中</span></div>
    <div class="identity-vote-line"><span>${escapeHtml(task && task.project_name ? task.project_name : "未关联项目")}</span>
      <span>收工后自动记录工时</span></div>
    <button class="btn" id="btn-today-open-work" style="width:100%;margin-top:10px">回到工作台收工</button>
  </div>`;
}

function todayCompanyUpdatesHtml() {
  const rows = typeof notifications === "function" ? notifications().slice(0, 3) : [];
  return rows.length ? rows.map(item => `
    <div class="today-ledger-row">
      <div><b>${escapeHtml(item.title || "公司动态")}</b>
        <span>${escapeHtml(item.body || item.text || "")}</span></div>
      <strong>${item.read ? "已读" : "新"}</strong>
    </div>`).join("")
    : '<div class="identity-empty game-empty"><b>今天还没有新动态</b><span>公司消息和社区提醒会显示在这里。</span></div>';
}

function todaySceneData(tasks, pending, open) {
  if (open) {
    return {
      file: "star_04_work",
      kicker: "专注轨道",
      title: "今天的任务正在推进",
      body: "计时器已经启动，先把眼前这一步做完。",
    };
  }
  if (!tasks.length) {
    return {
      file: "star_03_tea",
      kicker: "空白星图",
      title: "今天暂时没有任务",
      body: "可以整理计划、补充知识，或者给自己留一点缓冲。",
    };
  }
  if (!pending.length) {
    return {
      file: "star_08_great",
      kicker: "今日完成",
      title: "所有行动都已完成",
      body: "收好今天的成果，剩下的时间可以留给复盘。",
    };
  }
  if (pending.length > 3) {
    return {
      file: "star_15_tired",
      kicker: "任务偏多",
      title: "先挑最重要的一件事",
      body: "不用同时启动所有任务，完成一件就能让星图重新清晰。",
    };
  }
  return {
    file: "star_02_roger",
    kicker: "今日航线",
    title: "从最近的一步开始",
    body: "任务已经排好顺序，完成第一项就会看到新的进度。",
  };
}

function renderTodayScene(tasks, pending, open) {
  const box = $("today-scene");
  if (!box) return;
  const scene = todaySceneData(tasks, pending, open);
  box.innerHTML = `<div class="scene-card scene-today">
    <div class="scene-card-copy">
      <span class="scene-kicker">${escapeHtml(scene.kicker)}</span>
      <h2>${escapeHtml(scene.title)}</h2>
      <p>${escapeHtml(scene.body)}</p>
    </div>
    <img class="scene-card-art" src="icons/star/${scene.file}.webp" alt="">
  </div>`;
}

function renderToday() {
  const sub = $("today-sub");
  const summary = $("today-summary");
  const count = $("today-count");
  const taskList = $("today-task-list");
  const pendingCount = $("today-pending-count");
  const pendingList = $("today-pending-list");
  const workingState = $("today-working-state");
  const workingBox = $("today-working");
  const companyCount = $("today-company-count");
  const companyFeed = $("today-company-feed");
  if (!sub || !summary || !count || !taskList || !pendingCount || !pendingList
      || !workingState || !workingBox || !companyCount || !companyFeed) return;

  const tasks = todayTaskRows();
  const pending = tasks.filter(task =>
    !(typeof taskLogFor === "function" && taskLogFor(task.id)));
  const points = DB.pointState || {};
  const me = typeof identityMe === "function" ? identityMe() : null;
  const pendingItems = todayPendingItems(tasks);
  const open = typeof openWorkSession === "function" ? openWorkSession() : null;
  const updates = typeof notifications === "function" ? notifications() : [];

  renderTodayScene(tasks, pending, open);

  sub.textContent = DB.profile
    ? `${DB.profile.name}，先看清今天最重要的三件事`
    : "登录后查看今天的工作";
  const completed = Math.max(0, tasks.length - pending.length);
  const completion = tasks.length ? Math.round(completed * 100 / tasks.length) : 0;
  const streak = todayStreakDays();
  const displayName = String((DB.profile && DB.profile.name) || "行动者");
  const initial = displayName.trim().slice(0, 1) || "我";
  const roleKey = me && me.role_key ? me.role_key : (DB.profile && DB.profile.role);
  const roleLabel = roleKey && typeof identityRoleLabel === "function"
    ? identityRoleLabel(roleKey) : "企业成员";
  const shares = me ? num(me.shares) : 0;
  const primaryName = organizationState && organizationState.primary_company
    && organizationState.primary_company.name
    ? organizationState.primary_company.name
    : (DB.identity && DB.identity.enterprise && DB.identity.enterprise.name) || "当前公司";

  summary.innerHTML = `<div class="game-hud">
    <div class="game-avatar" aria-hidden="true"><span>${escapeHtml(initial)}</span><i>${completion}%</i></div>
    <div class="game-hud-main">
      <span class="game-kicker">${escapeHtml(primaryName)} · 今日行动档案</span>
      <div class="game-name-row"><b>${escapeHtml(displayName)}</b><span class="game-role">${escapeHtml(roleLabel)}</span></div>
      <div class="game-status-line"><span class="game-live-dot${pending.length ? " is-live" : ""}"></span>
        ${pending.length ? `还有 ${pending.length} 个行动等你处理` : "今日行动已经全部完成"}</div>
    </div>
    <div class="game-points"><span aria-hidden="true">◆</span><b>${num(points.balance)}</b><small>可用积分</small></div>
  </div>
  <div class="game-progress">
    <div class="game-progress-head"><span>今日完成度</span><b>${completed} / ${tasks.length}</b></div>
    <div class="game-progress-track" role="progressbar" aria-valuemin="0" aria-valuemax="100" aria-valuenow="${completion}"><span style="width:${completion}%"></span></div>
  </div>
  <div class="game-quick-stats">
    <div><b>${pending.length}</b><span>待处理</span></div>
    <div><b>${completed}</b><span>已完成</span></div>
    <div><b>${streak}</b><span>连续打卡</span></div>
    ${shares ? `<div><b>${num(shares)}</b><span>持股</span></div>` : ""}
  </div>`;

  const focus = tasks.slice(0, 3);
  count.textContent = `${pending.length} 项待处理`;
  taskList.innerHTML = focus.length
    ? focus.map(todayTaskCard).join("")
    : '<div class="identity-empty game-empty"><b>今日没有待办</b><span>去星球补充情报，或者为明天留一点余地。</span></div>';

  pendingCount.textContent = `${pendingItems.length} 项`;
  pendingList.innerHTML = todayPendingHtml(pendingItems);
  workingState.textContent = open ? "进行中" : "空闲";
  workingBox.innerHTML = todayWorkingHtml();
  companyCount.textContent = updates.length ? `${updates.filter(item => !item.read).length} 条未读` : "暂无";
  companyFeed.innerHTML = todayCompanyUpdatesHtml();

  taskList.querySelectorAll("[data-today-task]").forEach(button => {
    button.onclick = () => showPage("tasks");
  });
  pendingList.querySelectorAll("[data-today-go]").forEach(button => {
    button.onclick = () => showPage(button.dataset.todayGo);
  });
  pendingList.querySelectorAll("[data-today-member-invite]").forEach(button => {
    button.onclick = () => {
      if (typeof respondOrganizationMemberInvite === "function") {
        respondOrganizationMemberInvite(button.dataset.todayMemberInvite,
          button.dataset.accept === "1");
      }
    };
  });
  const startWorkButton = document.getElementById("btn-today-start-work");
  if (startWorkButton) {
    startWorkButton.onclick = () => showPage("tasks");
  }
  const openWorkButton = document.getElementById("btn-today-open-work");
  if (openWorkButton) {
    openWorkButton.onclick = () => showPage("tasks");
  }
}

async function refreshPointState(force) {
  if (!DB.profile || !initCloud()) return null;
  if (!force && DB.pointState
      && Date.now() - Number(DB.pointState.at || 0) < TODAY_POINT_REFRESH_MS) {
    renderToday();
    return DB.pointState;
  }
  try {
    const { data, error } = await cloudClient.rpc("get_point_state");
    if (error) throw error;
    DB.pointState = Object.assign({}, data || {}, { at: Date.now() });
    saveAll();
    renderToday();
    return DB.pointState;
  } catch (error) {
    if (force) toast("积分暂时没有加载出来，请稍后重试");
    renderToday();
    return null;
  }
}

function mobileUiModeError(error) {
  const message = String(error && error.message || error || "");
  if (error && error.code === "42P10"
      || /no unique or exclusion constraint matching the ON CONFLICT/i.test(message)) {
    return "数据库还缺少多公司兼容修复。\n\n"
      + "请在 Supabase SQL Editor 运行 sql/fix-advanced-mode-on-conflict.sql，"
      + "然后重新点击高级模式。";
  }
  if (/advanced mode requires/i.test(message)) {
    return "当前岗位没有高级模式权限。高级模式只对管理、财务、审计或治理岗位开放。";
  }
  if (/not an enterprise member/i.test(message)) {
    return "你还没有加入当前公司，先接受公司邀请或建立公司。";
  }
  if (/not signed in/i.test(message)) {
    return "登录状态已失效，请重新登录。";
  }
  return message || "切换模式失败";
}

async function setMobileUiMode(mode) {
  if (mode !== "simple" && mode !== "advanced") {
    toast("模式只能是简单或高级");
    return false;
  }
  if (mode === "advanced" && !mobileAdvancedAllowed()) {
    toast("当前身份没有高级模式权限");
    return false;
  }
  if (!DB.profile || !initCloud()) {
    toast("登录后才能切换模式");
    return false;
  }
  try {
    const { data, error } = await cloudClient.rpc(
      "set_enterprise_ui_mode", { p_mode: mode }
    );
    if (error) throw error;
    DB.uiMode = String(data && data.mode || mode);
  } catch (error) {
    toast(String(error.message || error || "切换模式失败"));
    return false;
  }
  if (DB.identity && DB.identity.me) DB.identity.me.preferred_mode = DB.uiMode;
  saveAll();
  applyRoleUI();
  showPage(DB.uiMode === "advanced" ? "dash" : "today");
  renderMe();
  toast(DB.uiMode === "advanced" ? "已切换到高级模式" : "已回到简单模式");
  return true;
}

function toggleMobileUiMode() {
  return setMobileUiMode(DB.uiMode === "advanced" ? "simple" : "advanced");
}

async function unlockKnowledgePost(postId) {
  if (!DB.profile || !postId || !initCloud()) {
    toast("登录后才能解锁知识");
    return null;
  }
  const post = (typeof communityPosts !== "undefined" ? communityPosts : [])
    .find(item => String(item.id) === String(postId));
  const cost = num(post && post.unlock_cost);
  if (cost > 0 && !confirm(`使用 ${cost} 积分解锁这篇知识？解锁后永久可看。`)) {
    return null;
  }
  try {
    const { data, error } = await cloudClient.rpc(
      "unlock_knowledge_content", { p_post: String(postId) }
    );
    if (error) throw error;
    if (post && data && data.content !== undefined) post.content = data.content;
    if (data && data.balance !== undefined) {
      DB.pointState.balance = num(data.balance);
      DB.pointState.at = Date.now();
      saveAll();
    }
    toast(data && data.already_unlocked ? "这篇知识已经解锁" : "已永久解锁");
    await refreshPointState(true);
    if (typeof renderCommunityFeed === "function") renderCommunityFeed();
    return data;
  } catch (error) {
    const message = String(error.message || error || "");
    toast(/insufficient points/i.test(message)
      ? "积分不足，先完成经过验收的成果"
      : message || "解锁失败，请稍后重试");
    return null;
  }
}

function resetTodayState() {
  DB.pointState = { balance: 0, pool: null, ledger: [], at: 0 };
  DB.uiMode = "simple";
  saveAll();
}
