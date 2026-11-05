"use strict";

/* =============================================================
   经营决策中心：只对高级模式中的管理身份显示。
   所有数据来自 get_decision_center；所有动作都走真实 RPC。
   ============================================================= */

let decisionBusy = false;

const DECISION_RISK_LABEL = {
  severe: "严重",
  risk: "风险",
  attention: "关注",
  healthy: "健康",
};
const DECISION_KIND_LABEL = {
  leave: "请假",
  worklog: "工时",
  expense: "费用",
  purchase: "采购",
  reward: "奖励",
  task_extension: "任务延期",
  identity_motion: "身份事项",
};
const DECISION_STATUS_LABEL = {
  open: "待处理",
  acknowledged: "已确认",
  assigned: "已分派",
  deferred: "已延期",
  resolved: "已解决",
  dismissed: "已关闭",
  pending: "待审批",
  approved: "已批准",
  rejected: "已拒绝",
  returned: "退回补充",
  cancelled: "已取消",
};

function decisionState() {
  if (!DB.decisionCenter || typeof DB.decisionCenter !== "object") {
    DB.decisionCenter = { decisions: [], approvals: [], members: [] };
  }
  if (!Array.isArray(DB.decisionCenter.decisions)) {
    DB.decisionCenter.decisions = [];
  }
  if (!Array.isArray(DB.decisionCenter.approvals)) {
    DB.decisionCenter.approvals = [];
  }
  if (!Array.isArray(DB.decisionCenter.members)) {
    DB.decisionCenter.members = [];
  }
  return DB.decisionCenter;
}

function decisionRiskLabel(value) {
  return DECISION_RISK_LABEL[String(value || "")] || "健康";
}

function decisionKindLabel(value) {
  return DECISION_KIND_LABEL[String(value || "")] || String(value || "审批");
}

function decisionStatusLabel(value) {
  return DECISION_STATUS_LABEL[String(value || "")] || String(value || "");
}

function decisionDate(value) {
  const text = String(value || "");
  if (!text) return "—";
  return text.slice(0, 16).replace("T", " ");
}

function decisionMoney(value) {
  const amount = num(value);
  return "¥" + amount.toLocaleString("zh-CN", {
    maximumFractionDigits: 2,
  });
}

function decisionEvidenceHtml(item) {
  const raw = item && item.evidence;
  const entries = Array.isArray(raw) ? raw : (raw ? [raw] : []);
  if (!entries.length) {
    return '<div class="decision-evidence is-empty">来源证据：暂无结构化证据</div>';
  }
  const rows = entries.map(entry => {
    if (!entry || typeof entry !== "object") {
      return '<span class="decision-evidence-chip">' +
        escapeHtml(String(entry)) + "</span>";
    }
    const type = entry.type || entry.source_type || "记录";
    const id = entry.id || entry.source_id || "";
    const extra = Object.keys(entry)
      .filter(key => ["type", "source_type", "id", "source_id"].indexOf(key) === -1)
      .filter(key => entry[key] !== null && entry[key] !== "" &&
        entry[key] !== undefined)
      .slice(0, 4)
      .map(key => escapeHtml(key) + "=" + escapeHtml(String(entry[key])))
      .join(" · ");
    return '<span class="decision-evidence-chip"><b>' +
      escapeHtml(String(type)) + "</b> " + escapeHtml(String(id)) +
      (extra ? " · " + extra : "") + "</span>";
  });
  return '<div class="decision-evidence"><span class="decision-evidence-title">' +
    "来源证据</span>" + rows.join("") + "</div>";
}

function decisionActionButton(action, id, label) {
  return '<button class="btn ghost decision-action" data-decision-action="' +
    escapeHtml(action) + '" data-id="' + escapeHtml(String(id || "")) + '">' +
    escapeHtml(label) + "</button>";
}

function approvalActionButton(action, id, label) {
  return '<button class="btn ghost approval-action" data-approval-action="' +
    escapeHtml(action) + '" data-id="' + escapeHtml(String(id || "")) + '">' +
    escapeHtml(label) + "</button>";
}

function renderDecisionActions(item) {
  const actions = item && item.actions ? item.actions : {};
  const id = item && item.id;
  const buttons = [];
  if (actions.acknowledge) buttons.push(decisionActionButton("acknowledged", id, "确认"));
  if (actions.assign) buttons.push(decisionActionButton("assigned", id, "分派"));
  if (actions.defer) buttons.push(decisionActionButton("deferred", id, "延期"));
  if (actions.resolve) buttons.push(decisionActionButton("resolved", id, "解决"));
  if (actions.dismiss) buttons.push(decisionActionButton("dismissed", id, "关闭"));
  return buttons.length
    ? '<div class="decision-actions">' + buttons.join("") + "</div>" : "";
}

function renderApprovalActions(item) {
  const actions = item && item.actions ? item.actions : {};
  const id = item && item.id;
  const identity = item && item.kind === "identity_motion";
  const buttons = [];
  if (actions.approve) {
    buttons.push(approvalActionButton("approved", id, identity ? "赞成" : "批准"));
  }
  if (actions.reject) {
    buttons.push(approvalActionButton("rejected", id, identity ? "反对" : "拒绝"));
  }
  if (actions["return"]) buttons.push(approvalActionButton("returned", id, "退回补充"));
  if (actions.cancel) buttons.push(approvalActionButton("cancelled", id, "取消"));
  return buttons.length
    ? '<div class="decision-actions">' + buttons.join("") + "</div>" : "";
}

function renderDecisionCenter() {
  if (!$("decision-list") || !$("approval-list")) return;
  const state = decisionState();
  const decisions = state.decisions;
  const approvals = state.approvals;
  const severe = decisions.filter(item => item.risk === "severe").length +
    approvals.filter(item => item.risk === "severe").length;
  const amount = decisions.reduce((sum, item) => sum + num(item.impact_amount), 0) +
    approvals.reduce((sum, item) => sum + num(item.amount), 0);
  const summary = $("decision-summary");
  if (summary) {
    summary.innerHTML = `
      <div class="decision-summary-card">
        <span class="meta">今日必须处理</span>
        <b>${decisions.length + approvals.length}</b>
      </div>
      <div class="decision-summary-card ${severe ? "is-severe" : ""}">
        <span class="meta">严重风险</span>
        <b>${severe}</b>
      </div>
      <div class="decision-summary-card">
        <span class="meta">涉及金额</span>
        <b>${decisionMoney(amount)}</b>
      </div>`;
  }

  $("decision-list").innerHTML = decisions.length ? decisions.map(item => `
    <article class="identity-motion open decision-card">
      <div class="identity-motion-head">
        <div>
          <span class="decision-risk risk-${escapeHtml(item.risk || "healthy")}">
            ${escapeHtml(decisionRiskLabel(item.risk))}</span>
          <b>${escapeHtml(item.title || "经营决策")}</b>
        </div>
        <span class="identity-status open">${escapeHtml(decisionStatusLabel(item.status))}</span>
      </div>
      <div class="identity-vote-line">
        <span>影响 ${num(item.impact_days)} 天</span>
        <span>${decisionMoney(item.impact_amount)}</span>
        <span>负责人 ${escapeHtml(item.owner_name || "未指派")}</span>
        <span>截止 ${escapeHtml(decisionDate(item.due_at))}</span>
      </div>
      ${item.detail ? `<div class="identity-motion-reason">${escapeHtml(item.detail)}</div>` : ""}
      ${decisionEvidenceHtml(item)}
      ${renderDecisionActions(item)}
    </article>`).join("") : `
    <div class="identity-empty"><b>暂无待决策事项</b>
      <span>不会用假数据填充；来源模块出现真实影响后会进入队列。</span></div>`;

  $("approval-list").innerHTML = approvals.length ? approvals.map(item => `
    <article class="identity-motion open decision-card">
      <div class="identity-motion-head">
        <div>
          <span class="decision-kind">${escapeHtml(decisionKindLabel(item.kind))}</span>
          <b>${escapeHtml(item.title || "待审批")}</b>
        </div>
        <span class="identity-status open">${escapeHtml(decisionStatusLabel(item.status))}</span>
      </div>
      <div class="identity-vote-line">
        <span>金额 ${decisionMoney(item.amount)}</span>
        <span>影响 ${num(item.impact_days)} 天</span>
        <span>申请人 ${escapeHtml(item.requester_name || "—")}</span>
        <span>截止 ${escapeHtml(decisionDate(item.due_at))}</span>
      </div>
      ${item.detail ? `<div class="identity-motion-reason">${escapeHtml(item.detail)}</div>` : ""}
      ${decisionEvidenceHtml(item)}
      ${renderApprovalActions(item)}
    </article>`).join("") : `
    <div class="identity-empty"><b>暂无待审批</b>
      <span>请假、工时、奖励、任务延期和身份事项会统一出现在这里。</span></div>`;
}

async function loadDecisionCenter(showErrors) {
  if (!DB.profile) {
    DB.decisionCenter = { decisions: [], approvals: [], members: [] };
    renderDecisionCenter();
    return;
  }
  if (typeof identityHasManagementView === "function" && !identityHasManagementView()) {
    DB.decisionCenter = { decisions: [], approvals: [], members: [] };
    renderDecisionCenter();
    return;
  }
  if (DB.uiMode !== "advanced") return;
  if (!initCloud()) {
    if (showErrors) toast("云服务没有加载，无法读取经营决策。");
    return;
  }
  try {
    const { data, error } = await cloudClient.rpc("get_decision_center");
    if (error) throw error;
    DB.decisionCenter = data && typeof data === "object"
      ? data : { decisions: [], approvals: [], members: [] };
    saveAll();
    renderDecisionCenter();
  } catch (error) {
    if (showErrors) toast(String((error && error.message) || error));
  }
}

function refreshDecisionCenterIfActive() {
  if (typeof currentPageName === "function"
      && currentPageName() === "decisions"
      && DB.uiMode === "advanced") {
    loadDecisionCenter(false);
  }
}

function decisionIdempotencyKey(prefix) {
  if (typeof crypto !== "undefined" && crypto.randomUUID) {
    return prefix + ":" + crypto.randomUUID();
  }
  return prefix + ":" + Date.now().toString(36) + ":"
    + Math.random().toString(36).slice(2);
}

async function actOnDecision(decisionId, action, note, ownerId) {
  if (decisionBusy) return null;
  decisionBusy = true;
  try {
    const { data, error } = await cloudClient.rpc("act_on_decision", {
      p_decision: String(decisionId),
      p_action: action,
      p_owner: ownerId ? String(ownerId) : null,
      p_note: note || "",
      p_idempotency_key: decisionIdempotencyKey("decision"),
    });
    if (error) throw error;
    await loadDecisionCenter(false);
    toast(data && data.duplicate ? "重复请求已安全忽略" : "决策操作已生效");
    return data;
  } catch (error) {
    toast(String((error && error.message) || error));
    throw error;
  } finally {
    decisionBusy = false;
  }
}

async function actOnApproval(approvalId, action, note) {
  if (decisionBusy) return null;
  decisionBusy = true;
  try {
    const { data, error } = await cloudClient.rpc("act_on_approval", {
      p_approval: String(approvalId),
      p_action: action,
      p_note: note || "",
      p_idempotency_key: decisionIdempotencyKey("approval"),
    });
    if (error) throw error;
    await loadDecisionCenter(false);
    toast(data && data.duplicate ? "重复请求已安全忽略" : "审批操作已生效");
    return data;
  } catch (error) {
    toast(String((error && error.message) || error));
    throw error;
  } finally {
    decisionBusy = false;
  }
}

function decisionById(decisionId) {
  return decisionState().decisions.find(item =>
    String(item.id || "") === String(decisionId || ""));
}

function approvalById(approvalId) {
  return decisionState().approvals.find(item =>
    String(item.id || "") === String(approvalId || ""));
}

function openDecisionNote(action, item) {
  const required = action === "deferred" || action === "dismissed";
  openSheet(action === "deferred" ? "延期决策"
    : action === "dismissed" ? "关闭决策" : "解决决策", `
    <div class="hint" style="margin-bottom:8px">${escapeHtml(item.title || "")}</div>
    <label for="decision-note">原因 / 处理结果${required ? "（必填）" : "（可选）"}</label>
    <textarea id="decision-note" maxlength="1000"
      placeholder="写清依据和后续动作"></textarea>
    <div id="decision-note-error" class="login-error hidden"></div>
  `, [
    { label: "取消", onClick: closeSheet },
    { label: "提交", kind: "", onClick: async () => {
      const note = $("decision-note").value.trim();
      if (required && !note) {
        $("decision-note-error").textContent = "必须填写原因。";
        $("decision-note-error").classList.remove("hidden");
        return;
      }
      closeSheet();
      try { await actOnDecision(item.id, action, note, null); }
      catch (error) { /* actOnDecision already displays the reason */ }
    } },
  ]);
}

function openDecisionAssignment(item) {
  const members = decisionState().members;
  if (!members.length) {
    toast("没有可分派的在职成员。");
    return;
  }
  openSheet("分派决策", `
    <div class="hint" style="margin-bottom:8px">${escapeHtml(item.title || "")}</div>
    <label for="decision-owner">负责人</label>
    <select id="decision-owner">${members.map(member => `
      <option value="${escapeHtml(String(member.id || ""))}">
        ${escapeHtml(member.name || "成员")} · ${escapeHtml(member.role_key || "")}
      </option>`).join("")}</select>
  `, [
    { label: "取消", onClick: closeSheet },
    { label: "确认分派", kind: "", onClick: async () => {
      const ownerId = $("decision-owner").value;
      closeSheet();
      try { await actOnDecision(item.id, "assigned", "分派处理", ownerId); }
      catch (error) { /* already displayed */ }
    } },
  ]);
}

async function requestDecisionAction(action, decisionId) {
  const item = decisionById(decisionId);
  if (!item) {
    toast("这条决策已经更新，请刷新后再试。");
    return;
  }
  if (action === "assigned") {
    openDecisionAssignment(item);
    return;
  }
  if (action === "acknowledged") {
    try { await actOnDecision(item.id, action, "", null); }
    catch (error) { /* already displayed */ }
    return;
  }
  if (action === "deferred" || action === "resolved" || action === "dismissed") {
    openDecisionNote(action, item);
  }
}

function openApprovalNote(action, item) {
  const required = action === "rejected" || action === "returned";
  const identity = item.kind === "identity_motion";
  const title = identity
    ? (action === "approved" ? "投赞成票" : "投反对票")
    : action === "approved" ? "批准"
      : action === "rejected" ? "拒绝" : "退回补充";
  openSheet(title, `
    <div class="hint" style="margin-bottom:8px">${escapeHtml(item.title || "")}</div>
    ${identity ? '<div class="community-note">身份事项按股东持股权重表决，最终结果由治理规则计算。</div>' : ""}
    <label for="approval-note">审批说明${required ? "（必填）" : "（可选）"}</label>
    <textarea id="approval-note" maxlength="1000"
      placeholder="写清审批依据"></textarea>
    <div id="approval-note-error" class="login-error hidden"></div>
  `, [
    { label: "取消", onClick: closeSheet },
    { label: identity ? "确认投票" : "提交", kind: "", onClick: async () => {
      const note = $("approval-note").value.trim();
      if (required && !note) {
        $("approval-note-error").textContent = "必须填写说明。";
        $("approval-note-error").classList.remove("hidden");
        return;
      }
      closeSheet();
      try { await actOnApproval(item.id, action, note); }
      catch (error) { /* already displayed */ }
    } },
  ]);
}

async function requestApprovalAction(action, approvalId) {
  const item = approvalById(approvalId);
  if (!item) {
    toast("这条审批已经更新，请刷新后再试。");
    return;
  }
  if (action === "cancelled") {
    if (!confirm("确定取消这条待审批事项吗？")) return;
    try { await actOnApproval(item.id, action, ""); }
    catch (error) { /* already displayed */ }
    return;
  }
  if (item.kind === "identity_motion"
      && (action === "approved" || action === "rejected")
      && !confirm("身份事项按股份权重表决。确认记录你的投票吗？")) {
    return;
  }
  if ((item.risk === "severe" || item.risk === "risk"
      || num(item.amount) >= 50000)
      && !confirm("这是高风险或高金额审批，服务端会校验高管权限。继续吗？")) {
    return;
  }
  if (action === "approved") {
    openApprovalNote(action, item);
    return;
  }
  openApprovalNote(action, item);
}

function bindDecisionCenter() {
  const refresh = $("btn-decisions-refresh");
  if (refresh) refresh.onclick = () => loadDecisionCenter(true);
  const decisions = $("decision-list");
  if (decisions) {
    decisions.onclick = event => {
      const button = event.target.closest("[data-decision-action]");
      if (!button || button.disabled) return;
      button.disabled = true;
      requestDecisionAction(button.dataset.decisionAction, button.dataset.id)
        .finally(() => { button.disabled = false; });
    };
  }
  const approvals = $("approval-list");
  if (approvals) {
    approvals.onclick = event => {
      const button = event.target.closest("[data-approval-action]");
      if (!button || button.disabled) return;
      button.disabled = true;
      requestApprovalAction(button.dataset.approvalAction, button.dataset.id)
        .finally(() => { button.disabled = false; });
    };
  }
}
