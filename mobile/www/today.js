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

function renderToday() {
  const sub = $("today-sub");
  const summary = $("today-summary");
  const count = $("today-count");
  const taskList = $("today-task-list");
  const pointsLabel = $("today-points");
  const rewards = $("today-rewards");
  const ledgerBox = $("today-ledger");
  if (!sub || !summary || !count || !taskList || !pointsLabel || !rewards) return;

  const tasks = todayTaskRows();
  const pending = tasks.filter(task =>
    !(typeof taskLogFor === "function" && taskLogFor(task.id)));
  const points = DB.pointState || {};
  const ledger = Array.isArray(points.ledger) ? points.ledger : [];
  const me = typeof identityMe === "function" ? identityMe() : null;

  sub.textContent = DB.profile
    ? `${DB.profile.name}，今天先完成 ${pending.length} 项`
    : "登录后查看今天的工作";
  const completed = Math.max(0, tasks.length - pending.length);
  const completion = tasks.length
    ? Math.round(completed * 100 / tasks.length) : 0;
  const streak = todayStreakDays();
  const displayName = String((DB.profile && DB.profile.name) || "行动者");
  const initial = displayName.trim().slice(0, 1) || "我";
  const roleKey = me && me.role_key
    ? me.role_key : (DB.profile && DB.profile.role);
  const roleLabel = roleKey && typeof identityRoleLabel === "function"
    ? identityRoleLabel(roleKey) : "企业成员";
  const shares = me ? num(me.shares) : 0;
  summary.innerHTML = `<div class="game-hud">
    <div class="game-avatar" aria-hidden="true">
      <span>${escapeHtml(initial)}</span>
      <i>${completion}%</i>
    </div>
    <div class="game-hud-main">
      <span class="game-kicker">今日行动档案</span>
      <div class="game-name-row">
        <b>${escapeHtml(displayName)}</b>
        <span class="game-role">${escapeHtml(roleLabel)}</span>
      </div>
      <div class="game-status-line">
        <span class="game-live-dot${pending.length ? " is-live" : ""}"></span>
        ${pending.length
          ? `还有 ${pending.length} 个行动等你处理`
          : "今日行动已经全部完成"}
      </div>
    </div>
    <div class="game-points">
      <span aria-hidden="true">◆</span>
      <b>${num(points.balance)}</b>
      <small>可用积分</small>
    </div>
  </div>
  <div class="game-progress">
    <div class="game-progress-head">
      <span>今日完成度</span><b>${completed} / ${tasks.length}</b>
    </div>
    <div class="game-progress-track"
         role="progressbar" aria-valuemin="0" aria-valuemax="100"
         aria-valuenow="${completion}">
      <span style="width:${completion}%"></span>
    </div>
  </div>
  <div class="game-quick-stats">
    <div><b>${pending.length}</b><span>待处理</span></div>
    <div><b>${completed}</b><span>已完成</span></div>
    <div><b>${streak}</b><span>连续打卡</span></div>
    ${shares ? `<div><b>${num(shares)}</b><span>持股</span></div>` : ""}
  </div>`;
  count.textContent = `${pending.length} 项待处理`;
  taskList.innerHTML = tasks.length
    ? tasks.slice(0, 5).map(todayTaskCard).join("")
    : '<div class="identity-empty game-empty"><b>今日没有待办</b>'
      + '<span>去星球补充情报，或者为明天留一点余地。</span></div>';
  pointsLabel.textContent = `${num(points.balance)} 积分 · 永久有效`;

  const pool = points.pool || null;
  rewards.innerHTML = pool
    ? `<div class="identity-motion open">
        <div class="identity-motion-head"><div>
          <div class="identity-eyebrow">本期积分池</div>
          <b>${escapeHtml(pool.quarter || "当前季度")}</b>
        </div><span class="identity-status open">可用</span></div>
        <div class="identity-vote-line">
          <span>剩余 ${num(pool.remaining)} / ${num(pool.total)} 分</span>
          <span>单次上限 ${num(pool.single_award_limit || 0)}</span>
        </div>
      </div>`
    : '<div class="identity-empty"><b>暂无积分池</b>'
      + '<span>董事会批准后会显示本期可发放额度。</span></div>';

  if (ledgerBox) {
    const recent = ledger.slice(0, 4);
    ledgerBox.innerHTML = recent.length
      ? recent.map(item => `<div class="today-ledger-row">
          <div><b>${escapeHtml(item.reason || "积分变动")}</b>
          <span>${escapeHtml(String(item.created_at || "").slice(0, 16).replace("T", " "))}</span></div>
          <strong class="${num(item.amount) < 0 ? "negative" : ""}">${
            num(item.amount) > 0 ? "+" : ""
          }${num(item.amount)}</strong>
        </div>`).join("")
      : '<div class="today-ledger-empty">暂无积分明细。完成验收成果后，积分会记录在这里。</div>';
  }

  taskList.querySelectorAll("[data-today-task]").forEach(button => {
    button.onclick = () => showPage("tasks");
  });
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
