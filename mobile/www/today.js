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
  return mobileAdvancedAllowed() && DB.uiMode === "advanced" ? "dash" : "today";
}

function todayTaskRows() {
  const tasks = typeof tasksOn === "function" ? tasksOn(todayISO()) : [];
  return tasks.slice().sort((a, b) => {
    const ad = typeof taskLogFor === "function" && taskLogFor(a.id) ? 1 : 0;
    const bd = typeof taskLogFor === "function" && taskLogFor(b.id) ? 1 : 0;
    return ad - bd || (Number(a.sort) || 0) - (Number(b.sort) || 0);
  });
}

function todayTaskCard(task) {
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
  return `<div class="today-task-route">
    <div class="today-task-copy">
      <b>${escapeHtml(task.title || "任务")}</b>
      <span>${escapeHtml(task.project_name || "今日任务")} · ${state}</span>
    </div>
    <button class="btn ${done ? "ghost" : ""}" data-today-task="${
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
  summary.innerHTML = `<div class="identity-me-head">
    <div>
      <div class="identity-eyebrow">我的今日进度</div>
      <div class="identity-role-line"><b>${
        pending.length ? "继续推进" : "今天已完成"
      }</b>${me && me.role_key
        ? `<span class="identity-owner">${escapeHtml(identityRoleLabel(me.role_key))}</span>`
        : ""}</div>
    </div>
    <div class="identity-weight"><b>${num(points.balance)}</b><span>可用积分</span></div>
  </div>`;
  count.textContent = `${pending.length} 项待处理`;
  taskList.innerHTML = tasks.length
    ? tasks.slice(0, 5).map(todayTaskCard).join("")
    : '<div class="identity-empty"><b>今天没有待办</b>'
      + '<span>可以查看知识星球，或为明天留一点余地。</span></div>';
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
