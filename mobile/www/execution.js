"use strict";

/* execution-allowed */

/* Phase 3 mobile execution tracking: acceptance, dependencies, handoffs,
   and change control. Every write below calls a server RPC. */

let executionBusy = false;

function emptyExecutionState() {
  return {
    acceptance: [], dependencies: [], handoffs: [], changes: [],
    tasks: [], projects: [], members: [], access: {}, at: 0,
  };
}

function executionState() {
  if (!DB.execution || typeof DB.execution !== "object") {
    DB.execution = emptyExecutionState();
  }
  ["acceptance", "dependencies", "handoffs", "changes", "tasks",
   "projects", "members"].forEach(key => {
    if (!Array.isArray(DB.execution[key])) DB.execution[key] = [];
  });
  if (!DB.execution.access || typeof DB.execution.access !== "object") {
    DB.execution.access = {};
  }
  return DB.execution;
}

function executionAllowed() {
  if (!DB.profile) return false;
  return typeof identityCanExecution !== "function" || identityCanExecution();
}

function clearExecutionCache() {
  DB.execution = emptyExecutionState();
  if (typeof saveAll === "function") saveAll();
  if (typeof renderExecution === "function") renderExecution();
}

async function executionRpc(name, params) {
  if (!initCloud()) throw new Error("云组件没有加载");
  const { data, error } = await cloudClient.rpc(name, params || {});
  if (error) throw error;
  if (data && typeof data === "object" && data.ok === false) {
    throw new Error(data.error || "执行追踪操作没有权限");
  }
  return data;
}

function executionNum(value) {
  return typeof num === "function" ? num(value) : Number(value) || 0;
}

function executionMoney(value) {
  return "¥" + executionNum(value).toLocaleString("zh-CN", {
    maximumFractionDigits: 2,
    minimumFractionDigits: 0,
  });
}

function executionDate(value) {
  const text = String(value || "");
  return text ? text.slice(0, 16).replace("T", " ") : "—";
}

function executionStatus(value) {
  return {
    pending: "待处理", accepted: "已接受", rework: "返工",
    rejected: "已拒绝", approved: "已批准", returned: "已退回",
    cancelled: "已取消", not_submitted: "未提交",
  }[String(value || "")] || String(value || "—");
}

function executionActionButton(action, id, label, style) {
  return `<button class="btn ${style || "ghost"} execution-action"
    data-execution-action="${escapeHtml(action)}"
    data-id="${escapeHtml(String(id || ""))}">${escapeHtml(label)}</button>`;
}

function executionMemberOptions(selected) {
  return executionState().members.map(member => {
    const value = escapeHtml(String(member.id || ""));
    const label = escapeHtml(member.name || "成员") +
      (member.department ? ` · ${escapeHtml(member.department)}` : "");
    return `<option value="${value}"${String(member.id) === String(selected) ? " selected" : ""}>${label}</option>`;
  }).join("");
}

function executionTaskOptions(selected, acceptedOnly) {
  return executionState().tasks
    .filter(task => !acceptedOnly || task.acceptance_status !== "accepted")
    .map(task => {
      const value = escapeHtml(String(task.id || ""));
      const label = escapeHtml(task.title || "任务") +
        (task.employee_name ? ` · ${escapeHtml(task.employee_name)}` : "");
      return `<option value="${value}"${String(task.id) === String(selected) ? " selected" : ""}>${label}</option>`;
    }).join("");
}

function executionProjectOptions(selected) {
  return executionState().projects.map(project => {
    const value = escapeHtml(String(project.id || ""));
    return `<option value="${value}"${String(project.id) === String(selected) ? " selected" : ""}>${escapeHtml(project.name || "项目")}</option>`;
  }).join("");
}

function executionEmpty(text) {
  return `<div class="identity-empty"><b>暂无记录</b><span>${escapeHtml(text)}</span></div>`;
}

function renderExecution() {
  if (!$("execution-acceptance")) return;
  const state = executionState();
  const acceptance = state.acceptance;
  const handoffs = state.handoffs;
  const changes = state.changes;
  const dependencies = state.dependencies;
  const pendingAcceptance = acceptance.filter(item => item.status === "pending").length;
  const pendingHandoffs = handoffs.filter(item => item.status === "pending").length;
  const pendingChanges = changes.filter(item => item.status === "pending").length;
  const blocked = dependencies.filter(item => item.blocked).length;

  if ($("execution-summary")) {
    $("execution-summary").innerHTML = `
      <div class="decision-summary-card ${pendingAcceptance ? "is-watch" : ""}">
        <span>待验收</span><b>${pendingAcceptance}</b></div>
      <div class="decision-summary-card ${blocked ? "is-severe" : ""}">
        <span>依赖阻塞</span><b>${blocked}</b></div>
      <div class="decision-summary-card ${pendingHandoffs ? "is-watch" : ""}">
        <span>待确认交接</span><b>${pendingHandoffs}</b></div>
      <div class="decision-summary-card ${pendingChanges ? "is-watch" : ""}">
        <span>待决变更</span><b>${pendingChanges}</b></div>`;
  }
  const access = state.access || {};
  if ($("execution-tools")) {
    $("execution-tools").classList.toggle("hidden", !executionAllowed());
  }
  const toolVisibility = {
    "btn-execution-submit": !!access.can_submit_acceptance,
    "btn-execution-dependency": !!access.can_manage_dependencies,
    "btn-execution-handoff": !!access.can_create_handoff,
    "btn-execution-change": !!access.can_manage_changes,
  };
  Object.entries(toolVisibility).forEach(([id, visible]) => {
    if ($(id)) $(id).classList.toggle("hidden", !visible);
  });

  $("execution-acceptance").innerHTML = acceptance.length
    ? acceptance.map(item => {
      const actions = item.actions || {};
      const buttons = [];
      if (actions.accept) {
        buttons.push(executionActionButton(
          "acceptance-accept", item.task_id, "验收通过", ""));
      }
      if (actions.rework) {
        buttons.push(executionActionButton(
          "acceptance-rework", item.task_id, "退回返工"));
      }
      return `<article class="execution-card">
        <div class="execution-card-head">
          <div><b>${escapeHtml(item.title || "任务")}</b>
            <div class="meta">提交人 ${escapeHtml(item.submitter_name || "—")}
              · 验收人 ${escapeHtml(item.reviewer_name || "—")}</div></div>
          <span class="execution-state">${escapeHtml(executionStatus(item.status))}</span>
        </div>
        <div class="execution-field"><span>验收标准</span>
          <p>${escapeHtml(item.criteria || "—")}</p></div>
        <div class="execution-field"><span>交付证据</span>
          <p>${escapeHtml(item.evidence || "—")}</p></div>
        ${item.review_note ? `<div class="execution-note">${escapeHtml(item.review_note)}</div>` : ""}
        ${buttons.length ? `<div class="execution-actions">${buttons.join("")}</div>` : ""}
      </article>`;
    }).join("")
    : executionEmpty("验收提交后会出现在这里。");

  $("execution-dependencies").innerHTML = dependencies.length
    ? dependencies.map(item => {
      const affected = Array.isArray(item.affected_tasks) ? item.affected_tasks : [];
      const impact = affected.length
        ? affected.map(row => `${escapeHtml(row.title || "任务")} +${executionNum(row.delay_days)} 天`).join(" · ")
        : "暂无下游影响";
      const actions = item.actions || {};
      const remove = actions.remove
        ? `<button class="btn ghost execution-action"
             data-execution-action="dependency-remove"
             data-task-id="${escapeHtml(String(item.task_id || ""))}"
             data-upstream-id="${escapeHtml(String(item.depends_on_task_id || ""))}">删除依赖</button>`
        : "";
      return `<article class="execution-card ${item.blocked ? "is-blocked" : ""}">
        <div class="execution-card-head">
          <div><b>${escapeHtml(item.title || "任务")}</b>
            <div class="meta">依赖 ${escapeHtml(item.depends_on_title || "上游任务")}
              · 间隔 ${executionNum(item.lag_days)} 天
              · ${item.required ? "必须依赖" : "可选依赖"}</div></div>
          <span class="execution-state">${item.blocked ? `延迟 ${executionNum(item.delayed_days)} 天` : "正常"}</span>
        </div>
        <div class="execution-field"><span>下游影响</span><p>${impact}</p></div>
        ${remove ? `<div class="execution-actions">${remove}</div>` : ""}
      </article>`;
    }).join("")
    : executionEmpty("任务依赖会显示在这里。");

  $("execution-handoffs").innerHTML = handoffs.length
    ? handoffs.map(item => {
      const actions = item.actions || {};
      const buttons = [];
      if (actions.accept) {
        buttons.push(executionActionButton("handoff-accept", item.id, "确认接收", ""));
      }
      if (actions.reject) {
        buttons.push(executionActionButton("handoff-reject", item.id, "拒绝"));
      }
      return `<article class="execution-card">
        <div class="execution-card-head">
          <div><b>${escapeHtml(item.title || "任务")}</b>
            <div class="meta">${escapeHtml(item.from_name || "—")} →
              ${escapeHtml(item.to_name || "—")}</div></div>
          <span class="execution-state">${escapeHtml(executionStatus(item.status))}</span>
        </div>
        <div class="execution-field"><span>交接物</span>
          <p>${escapeHtml(item.artifact || "—")}</p></div>
        ${item.note ? `<div class="execution-note">${escapeHtml(item.note)}</div>` : ""}
        ${buttons.length ? `<div class="execution-actions">${buttons.join("")}</div>` : ""}
      </article>`;
    }).join("")
    : executionEmpty("跨部门交接会推送给接收方确认。");

  $("execution-changes").innerHTML = changes.length
    ? changes.map(item => {
      const actions = item.actions || {};
      const buttons = [];
      if (actions.approve) buttons.push(executionActionButton(
        "change-approve", item.id, "批准", ""));
      if (actions.reject) buttons.push(executionActionButton(
        "change-reject", item.id, "拒绝"));
      if (actions.return) buttons.push(executionActionButton(
        "change-return", item.id, "退回补充"));
      return `<article class="execution-card ${item.high_impact ? "is-blocked" : ""}">
        <div class="execution-card-head">
          <div><b>${escapeHtml(item.title || "变更")}</b>
            <div class="meta">${escapeHtml(item.project_name || "项目")}
              · 紧急度 ${escapeHtml(item.urgency || "—")}</div></div>
          <span class="execution-state">${escapeHtml(executionStatus(item.status))}</span>
        </div>
        <div class="execution-field"><span>变更范围</span>
          <p>${escapeHtml(item.scope || "—")}</p></div>
        <div class="execution-field"><span>原因</span>
          <p>${escapeHtml(item.reason || "—")}</p></div>
        <div class="execution-impact">
          <span>工期 +${executionNum(item.schedule_impact_days)} 天</span>
          <span>成本 ${executionMoney(item.cost_impact)}</span>
          <span>资源 ${escapeHtml(item.resource_impact || "—")}</span>
        </div>
        ${item.high_impact ? '<div class="execution-note">高影响变更已进入决策队列；批准前不会改动原计划。</div>' : ""}
        ${buttons.length ? `<div class="execution-actions">${buttons.join("")}</div>` : ""}
      </article>`;
    }).join("")
    : executionEmpty("变更申请会显示在这里。");
}

async function loadExecution(showErrors) {
  if (!executionAllowed()) {
    clearExecutionCache();
    return;
  }
  if (!initCloud()) {
    if (showErrors) toast("云服务没有加载，无法读取执行追踪。");
    return;
  }
  if (executionBusy) return;
  executionBusy = true;
  try {
    const { data, error } = await cloudClient.rpc("get_execution_board");
    if (error) throw error;
    if (data && data.ok === false) throw new Error(data.error || "执行追踪权限不足");
    DB.execution = Object.assign(emptyExecutionState(), data || {});
    saveAll();
    renderExecution();
  } catch (error) {
    if (showErrors) toast(String((error && error.message) || error));
  } finally {
    executionBusy = false;
  }
}

function openAcceptanceSubmission(selectedTask) {
  const tasks = executionState().tasks.filter(task => task.acceptance_status !== "accepted");
  if (!tasks.length) { toast("没有可提交验收的任务"); return; }
  const members = executionState().members;
  if (!members.length) { toast("企业成员尚未加载"); return; }
  openSheet("提交验收", `
    <label for="execution-accept-task">任务</label>
    <select id="execution-accept-task">${executionTaskOptions(selectedTask, true)}</select>
    <label for="execution-accept-criteria">验收标准（必填）</label>
    <textarea id="execution-accept-criteria" maxlength="2000"
      placeholder="写清完成定义和可验证条件"></textarea>
    <label for="execution-accept-evidence">交付证据（必填）</label>
    <textarea id="execution-accept-evidence" maxlength="4000"
      placeholder="提交记录、测试结果、文件或链接"></textarea>
    <label for="execution-accept-reviewer">独立验收人</label>
    <select id="execution-accept-reviewer">${executionMemberOptions("")}</select>
    <div class="community-note">提交人与验收人不能相同。服务端会再次校验。</div>
  `, [
    { label: "取消", onClick: closeSheet },
    { label: "提交", kind: "", onClick: submitExecutionAcceptance },
  ]);
}

async function submitExecutionAcceptance() {
  const task = $("execution-accept-task").value;
  const criteria = $("execution-accept-criteria").value.trim();
  const evidence = $("execution-accept-evidence").value.trim();
  const reviewer = $("execution-accept-reviewer").value;
  if (!task || !criteria || !evidence || !reviewer) {
    toast("任务、标准、证据和验收人都要填写");
    return;
  }
  await executeExecutionMutation("submit_task_acceptance", {
    p_task: task, p_criteria: criteria, p_evidence: evidence,
    p_reviewer: reviewer, p_note: "mobile submission",
  }, "验收已提交");
}

function openDependencyCreate(selectedTask) {
  const tasks = executionState().tasks;
  if (tasks.length < 2) { toast("至少需要两个任务才能建立依赖"); return; }
  const first = selectedTask || tasks[0].id;
  const second = tasks.find(task => String(task.id) !== String(first)).id;
  const taskOptions = executionTaskOptions(first, false);
  const upstreamOptions = tasks.map(task => {
    const value = escapeHtml(String(task.id || ""));
    return `<option value="${value}"${String(task.id) === String(second) ? " selected" : ""}>${escapeHtml(task.title || "任务")}</option>`;
  }).join("");
  openSheet("新增任务依赖", `
    <label for="execution-dependency-task">任务</label>
    <select id="execution-dependency-task">${taskOptions}</select>
    <label for="execution-dependency-upstream">依赖上游</label>
    <select id="execution-dependency-upstream">${upstreamOptions}</select>
    <label for="execution-dependency-lag">间隔天数</label>
    <input id="execution-dependency-lag" type="number" min="0" value="0">
    <label class="check">
      <input id="execution-dependency-required" type="checkbox" checked>
      必须依赖（取消后为可选依赖，不阻塞任务）
    </label>
  `, [
    { label: "取消", onClick: closeSheet },
    { label: "保存", kind: "", onClick: submitExecutionDependency },
  ]);
}

async function submitExecutionDependency() {
  const task = $("execution-dependency-task").value;
  const upstream = $("execution-dependency-upstream").value;
  const lag = Math.max(0, Number($("execution-dependency-lag").value) || 0);
  const required = $("execution-dependency-required").checked;
  if (!task || !upstream || task === upstream) {
    toast("请选择两个不同任务");
    return;
  }
  await executeExecutionMutation("upsert_task_dependency", {
    p_task: task, p_depends_on: upstream,
    p_lag_days: lag, p_required: required,
  }, "任务依赖已保存");
}

function openHandoffCreate(selectedTask) {
  const tasks = executionState().tasks;
  if (!tasks.length) { toast("没有可交接的任务"); return; }
  openSheet("发起交接", `
    <label for="execution-handoff-task">任务</label>
    <select id="execution-handoff-task">${executionTaskOptions(selectedTask, false)}</select>
    <label for="execution-handoff-to">接收人</label>
    <select id="execution-handoff-to">${executionMemberOptions("")}</select>
    <label for="execution-handoff-artifact">交接物（必填）</label>
    <textarea id="execution-handoff-artifact" maxlength="2000"
      placeholder="文件、构建、客户确认或后续动作"></textarea>
    <label for="execution-handoff-note">说明</label>
    <textarea id="execution-handoff-note" maxlength="1000"></textarea>
    <div class="community-note">交接在接收人确认前保持待处理。</div>
  `, [
    { label: "取消", onClick: closeSheet },
    { label: "发起", kind: "", onClick: submitExecutionHandoff },
  ]);
}

async function submitExecutionHandoff() {
  const task = $("execution-handoff-task").value;
  const to = $("execution-handoff-to").value;
  const artifact = $("execution-handoff-artifact").value.trim();
  const note = $("execution-handoff-note").value.trim();
  if (!task || !to || !artifact) {
    toast("任务、接收人和交接物都要填写");
    return;
  }
  await executeExecutionMutation("create_task_handoff", {
    p_task: task, p_to: to, p_artifact: artifact, p_note: note,
  }, "交接已发起，等待接收方确认");
}

function openChangeCreate(selectedProject) {
  const projects = executionState().projects;
  if (!projects.length) { toast("没有可提交变更的项目"); return; }
  openSheet("发起变更", `
    <label for="execution-change-project">项目</label>
    <select id="execution-change-project">${executionProjectOptions(selectedProject)}</select>
    <label for="execution-change-title">变更标题</label>
    <input id="execution-change-title" maxlength="120">
    <label for="execution-change-scope">变更范围（必填）</label>
    <textarea id="execution-change-scope" maxlength="2000"></textarea>
    <label for="execution-change-reason">变更原因（必填）</label>
    <textarea id="execution-change-reason" maxlength="1000"></textarea>
    <div class="row2">
      <div><label for="execution-change-urgency">紧急程度</label>
        <select id="execution-change-urgency">
          <option value="normal">普通</option><option value="high">高</option>
          <option value="urgent">紧急</option>
        </select></div>
      <div><label for="execution-change-risk">风险</label>
        <select id="execution-change-risk">
          <option value="healthy">健康</option><option value="attention">关注</option>
          <option value="risk">风险</option><option value="severe">严重</option>
        </select></div>
    </div>
    <div class="row2">
      <div><label for="execution-change-days">工期影响（天）</label>
        <input id="execution-change-days" type="number" min="0" value="0"></div>
      <div><label for="execution-change-cost">成本影响</label>
        <input id="execution-change-cost" type="number" min="0" step="0.01" value="0"></div>
    </div>
    <label for="execution-change-resource">关键资源影响（必填）</label>
    <input id="execution-change-resource" placeholder="例如两名工程师两周">
    <label class="community-required">
      <input id="execution-change-cross" type="checkbox"> 跨部门变更
    </label>
    <div class="community-note">高影响变更会进入经营决策队列；批准前原计划不会被覆盖。</div>
  `, [
    { label: "取消", onClick: closeSheet },
    { label: "提交", kind: "", onClick: submitExecutionChange },
  ]);
}

async function submitExecutionChange() {
  const project = $("execution-change-project").value;
  const title = $("execution-change-title").value.trim();
  const scope = $("execution-change-scope").value.trim();
  const reason = $("execution-change-reason").value.trim();
  const urgency = $("execution-change-urgency").value;
  const risk = $("execution-change-risk").value;
  const schedule = Number($("execution-change-days").value) || 0;
  const cost = Number($("execution-change-cost").value) || 0;
  const resource = $("execution-change-resource").value.trim();
  const cross = $("execution-change-cross").checked;
  if (!project || !scope || !reason || !resource) {
    toast("项目、范围、原因和资源影响都要填写");
    return;
  }
  await executeExecutionMutation("create_change_request", {
    p_project: project,
    p_data: {
      title: title || scope.slice(0, 120), scope, reason, urgency,
      schedule_impact_days: schedule, cost_impact: cost,
      resource_impact: resource, risk, cross_department: cross,
    },
  }, "变更申请已提交");
}

function openExecutionNote(action, id, decision) {
  const labels = {
    "acceptance-accept": "确认验收", "acceptance-rework": "退回返工",
    "handoff-accept": "确认接收", "handoff-reject": "拒绝交接",
    "change-approve": "批准变更", "change-reject": "拒绝变更",
    "change-return": "退回补充",
  };
  const required = ["acceptance-rework", "handoff-reject",
    "change-reject", "change-return"].indexOf(action) !== -1;
  openSheet(labels[action] || "执行操作", `
    <label for="execution-action-note">说明${required ? "（必填）" : "（可选）"}</label>
    <textarea id="execution-action-note" maxlength="1000"
      placeholder="写清依据，内容会写入审计"></textarea>
  `, [
    { label: "取消", onClick: closeSheet },
    { label: "确认", kind: "", onClick: () => {
      const note = $("execution-action-note").value.trim();
      if (required && !note) { toast("必须填写说明"); return; }
      executionSubmitAction(action, id, decision, note);
    } },
  ]);
}

async function executionSubmitAction(action, id, decision, note) {
  const map = {
    "acceptance-accept": ["review_task_acceptance", "p_task", "accepted"],
    "acceptance-rework": ["review_task_acceptance", "p_task", "rework"],
    "handoff-accept": ["accept_task_handoff", "p_handoff", "accepted"],
    "handoff-reject": ["accept_task_handoff", "p_handoff", "rejected"],
    "change-approve": ["decide_change_request", "p_change", "approved"],
    "change-reject": ["decide_change_request", "p_change", "rejected"],
    "change-return": ["decide_change_request", "p_change", "returned"],
  };
  const entry = map[action];
  if (!entry) { toast("不支持的操作"); return; }
  const params = { [entry[1]]: id, p_note: note };
  if (entry[0] === "review_task_acceptance" || entry[0] === "accept_task_handoff") {
    params.p_decision = decision;
  } else {
    params.p_decision = decision;
    params.p_idempotency_key = "change:" + id + ":" + Date.now().toString(36);
  }
  await executeExecutionMutation(entry[0], params, "执行操作已生效");
}

async function executeExecutionMutation(name, params, successText) {
  try {
    await executionRpc(name, params);
    closeSheet();
    toast(successText);
    await loadExecution(false);
  } catch (error) {
    toast(String((error && error.message) || error));
  }
}

function bindExecution() {
  if ($("btn-execution-refresh")) {
    $("btn-execution-refresh").onclick = () => loadExecution(true);
  }
  if ($("btn-execution-submit")) {
    $("btn-execution-submit").onclick = () => openAcceptanceSubmission("");
  }
  if ($("btn-execution-dependency")) {
    $("btn-execution-dependency").onclick = () => openDependencyCreate("");
  }
  if ($("btn-execution-handoff")) {
    $("btn-execution-handoff").onclick = () => openHandoffCreate("");
  }
  if ($("btn-execution-change")) {
    $("btn-execution-change").onclick = () => openChangeCreate("");
  }
  const containers = ["execution-acceptance", "execution-dependencies",
    "execution-handoffs", "execution-changes"];
  containers.forEach(id => {
    const root = $(id);
    if (!root) return;
    root.onclick = event => {
      const button = event.target.closest("[data-execution-action]");
      if (!button || button.disabled) return;
      const action = button.dataset.executionAction;
      if (action === "dependency-remove") {
        executeExecutionMutation("delete_task_dependency", {
          p_task: button.dataset.taskId,
          p_depends_on: button.dataset.upstreamId,
        }, "任务依赖已删除");
        return;
      }
      const decisions = {
        "acceptance-accept": "accepted", "acceptance-rework": "rework",
        "handoff-accept": "accepted", "handoff-reject": "rejected",
        "change-approve": "approved", "change-reject": "rejected",
        "change-return": "returned",
      };
      openExecutionNote(action, button.dataset.id, decisions[action] || "");
    };
  });
}
