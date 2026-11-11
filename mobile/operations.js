/* =============================================================
   Phase 2B mobile operations summary and personal evidence.

   The management page is loaded only through get_operations_dashboard.
   Employee evidence uses a separate own-row RPC and is revealed on demand.
   ============================================================= */
"use strict";

let operationsBusy = false;
let myPerformanceBusy = false;
let operationsStaleMessage = "";
const WORKLOG_DIMENSION_RPC = "upsert_worklog_dimensions";

function emptyOperationsState(at) {
  return {
    projects: [], capacity_gaps: [], performance: [], worklog_summary: {},
    capacity_demands: [], skills: [], collection_alerts: [],
    members: [], security_audit: [], access: {}, at: at || 0,
  };
}

function operationsState() {
  return DB.operations && typeof DB.operations === "object"
    ? DB.operations : emptyOperationsState();
}

function operationsAllowedInCurrentMode() {
  if (!DB.profile || DB.uiMode !== "advanced") return false;
  if (typeof identityHasAdvancedAccess === "function" && !identityHasAdvancedAccess()) {
    return false;
  }
  if (typeof identityHasManagementView === "function" && !identityHasManagementView()) {
    return false;
  }
  return true;
}

function clearOperationsCache() {
  DB.operations = emptyOperationsState();
  saveAll();
  if (typeof renderOperations === "function") renderOperations();
}

async function operationsRpc(name, params) {
  if (!initCloud()) throw new Error("云组件没有加载");
  const { data, error } = await cloudClient.rpc(name, params || {});
  if (error) throw error;
  if (data && typeof data === "object" && data.ok === false) {
    throw new Error(data.error || "操作没有权限");
  }
  return data;
}

function operationsNum(value) {
  return typeof num === "function" ? num(value) : Number(value) || 0;
}

function operationsMoney(value) {
  return "¥" + operationsNum(value).toLocaleString("zh-CN", {
    maximumFractionDigits: 2,
    minimumFractionDigits: 0,
  });
}

function operationsHours(value) {
  return (Math.round(operationsNum(value) * 10) / 10) + " 小时";
}

function intOrZero(value) {
  return Math.max(0, Math.trunc(operationsNum(value)));
}

function operationsDate(value) {
  const text = String(value || "");
  return text ? text.slice(0, 16).replace("T", " ") : "—";
}

function operationsEvidenceEntries(evidence) {
  if (Array.isArray(evidence)) return evidence;
  if (evidence && typeof evidence === "object") {
    if (Array.isArray(evidence.items)) return evidence.items;
    return [evidence];
  }
  return [];
}

function renderOperations() {
  if (!$("operations-projects") || !$("operations-capacity")) return;
  const banner = $("operations-banner");
  if (banner) {
    const message = operationsStaleMessage || String(DB.pullError || "");
    banner.innerHTML = message
      ? '<div class="banner warn">数据可能不是最新：' + escapeHtml(message) + '</div>'
      : "";
  }
  const state = operationsState();
  const access = state.access && typeof state.access === "object" ? state.access : {};
  const projects = Array.isArray(state.projects) ? state.projects : [];
  const gaps = Array.isArray(state.capacity_gaps) ? state.capacity_gaps : [];
  const demands = Array.isArray(state.capacity_demands) ? state.capacity_demands : [];
  const skills = Array.isArray(state.skills) ? state.skills : [];
  const performance = Array.isArray(state.performance) ? state.performance : [];
  const alerts = Array.isArray(state.collection_alerts) ? state.collection_alerts : [];
  const summary = state.worklog_summary && typeof state.worklog_summary === "object"
    ? state.worklog_summary : {};
  const canFinance = access.can_finance === true;
  const canCapacity = access.can_capacity === true;
  const canPerformance = access.can_performance === true;
  const canWorklogs = access.can_worklogs === true;
  const capacityMessage = access.capacity_requires_people_scope === true
    ? "能力缺口需要人员查看范围；当前权限不计算缺口。"
    : String(
      access.capacity_permission_message ||
      "能力缺口需要人员查看范围；当前权限不计算缺口。"
    );
  const margin = projects.reduce((sum, item) => sum + operationsNum(item.projected_margin), 0);
  const collectionGap = projects.reduce(
    (sum, item) => sum + operationsNum(item.collection_gap), 0);
  const shortages = gaps.filter(item => operationsNum(item.gap_hours) > 0).length;

  if ($("operations-summary")) {
    $("operations-summary").innerHTML = `
      <div class="decision-summary-card"><span>项目</span><b>${projects.length}</b></div>
      ${canFinance ? `<div class="decision-summary-card"><span>预计毛利</span>
        <b>${operationsMoney(margin)}</b></div>
      <div class="decision-summary-card ${collectionGap > 0 ? "is-severe" : ""}">
        <span>回款缺口</span><b>${operationsMoney(collectionGap)}</b></div>` : ""}
      <div class="decision-summary-card ${canCapacity && shortages > 0 ? "is-severe" : ""}">
        <span>能力缺口</span><b>${canCapacity ? shortages : "—"}</b></div>
      <div class="decision-summary-card ${alerts.length > 0 ? "is-severe" : ""}">
        <span>逾期回款</span><b>${alerts.length}</b></div>`;
  }

  $("operations-projects").innerHTML = projects.length
    ? projects.map(item => `
      <div class="operations-card">
        <div class="operations-card-head">
          <div class="grow"><b>${escapeHtml(item.name || "项目")}</b>
            ${canFinance ? `<div class="meta">合同 ${operationsMoney(item.contract_amount)}
              · 已开票 ${operationsMoney(item.invoiced_amount)}
              · 已回款 ${operationsMoney(item.collected_amount)}</div>` : ""}</div>
          ${canFinance ? `<div class="operations-number ${operationsNum(item.projected_margin) < 0 ? "bad" : "good"}">
            <b>${operationsMoney(item.projected_margin)}</b>
            <span>${operationsNum(item.projected_margin_percent).toFixed(1)}%</span></div>` : ""}
        </div>
        ${canFinance ? `<div class="operations-metrics">
          <span>外包承诺 ${operationsMoney(item.outsourced_committed)}</span>
          <span>外包已付 ${operationsMoney(item.outsourced_paid)}</span>
          <span>人力成本 ${operationsMoney(item.labor_cost)}</span>
          <span>其他成本 ${operationsMoney(item.other_cost)}</span>
          <span>预计完工成本 ${operationsMoney(item.projected_completion_cost)}</span>
          <span>回款缺口 ${operationsMoney(item.collection_gap)}</span>
          <span>开票到期 ${escapeHtml(item.invoice_due_date || "—")}</span>
          <span>付款条款 ${escapeHtml(item.payment_terms || "—")}</span>
          ${operationsNum(item.overdue_amount) > 0 ? `<span class="bad">逾期 ${intOrZero(item.overdue_days)} 天 · ${operationsMoney(item.overdue_amount)}</span>` : ""}
        </div>` : `<div class="meta">当前权限只显示项目名称和交付范围，财务字段已过滤。</div>`}
      </div>`).join("")
    : '<div class="identity-empty"><b>暂无经营数据</b><span>有权限的成员录入合同与成本后会显示在这里。</span></div>';

  const gapHtml = !canCapacity
    ? `<div class="identity-empty"><b>能力缺口未展示</b><span>${escapeHtml(capacityMessage)}</span></div>`
    : gaps.length
    ? gaps.map(item => `
      <div class="operations-card">
        <div class="operations-card-head">
          <div class="grow"><b>${escapeHtml(item.skill || "未命名技能")}</b>
            <div class="meta">${escapeHtml(operationsDate(item.period_start))}
              至 ${escapeHtml(operationsDate(item.period_end))}</div></div>
          <div class="operations-number ${operationsNum(item.gap_hours) > 0 ? "bad" : "good"}">
            <b>${operationsHours(item.gap_hours)}</b>
            <span>${operationsNum(item.gap_hours) > 0 ? "缺口" : "已覆盖"}</span></div>
        </div>
        <div class="operations-metrics">
          <span>需求 ${operationsHours(item.required_hours)}</span>
          <span>可用 ${operationsHours(item.available_hours)}</span>
        </div>
      </div>`).join("")
    : '<div class="identity-empty"><b>暂无能力缺口</b><span>技能可用时间和未来需求对齐后会在这里计算。</span></div>';
  const demandHtml = canCapacity && demands.length
    ? `<div class="section-head"><span>能力需求与来源</span></div>${demands.map(item => `
      <div class="operations-card">
        <div class="operations-card-head">
          <div class="grow"><b>${escapeHtml(item.skill || "技能")}</b>
            <div class="meta">ID ${escapeHtml(item.source_id || item.id || "—")}
              · ${escapeHtml(item.project_name || "未绑定项目")}</div></div>
          <div class="operations-number"><b>${operationsHours(item.required_hours)}</b>
            <span>${escapeHtml(item.needed_from || "—")} 至 ${escapeHtml(item.needed_until || "—")}</span></div>
        </div>
        <button class="btn ghost" data-capacity-id="${escapeHtml(String(item.id || ""))}">
          编辑这条需求</button>
      </div>`).join("")}` : "";
  const skillHtml = canCapacity && skills.length
    ? `<div class="section-head"><span>技能档案</span></div>${skills.map(item => `
      <div class="operations-card">
        <div class="operations-card-head">
          <div class="grow"><b>${escapeHtml(item.name || "成员")} · ${escapeHtml(item.skill || "技能")}</b>
            <div class="meta">来源 ${escapeHtml(item.source_id || item.profile_id || "—")}</div></div>
          <div class="operations-number"><b>${intOrZero(item.level)}/5</b>
            <span>${operationsHours(item.available_hours)}/周</span></div>
        </div>
      </div>`).join("")}` : "";
  $("operations-capacity").innerHTML = gapHtml + demandHtml + skillHtml;

  $("operations-performance").innerHTML = canPerformance && performance.length
    ? performance.map(item => {
      const entries = operationsEvidenceEntries(item.evidence);
      const details = Array.isArray(item.evidence_details) ? item.evidence_details : [];
      const evidenceText = (details.length ? details : entries).map(entry => {
        if (!entry || typeof entry !== "object") return "";
        return String(entry.type || entry.source_type || "记录")
          + " " + String(entry.source_id || entry.id || "")
          + (entry.label ? " · " + String(entry.label) : "");
      }).filter(Boolean).join(" · ");
      return `
        <div class="operations-card">
          <div class="operations-card-head">
            <div class="grow"><b>${escapeHtml(item.name || "成员")}</b>
              <div class="meta">${escapeHtml(item.period || "—")} ·
                ${escapeHtml(item.status === "reviewed" ? "已复核" : "待复核")}
                · ID ${escapeHtml(item.source_id || item.id || "—")}</div></div>
            <div class="operations-number"><b>${operationsNum(item.score).toFixed(1)}</b>
              <span>证据分</span></div>
          </div>
          <div class="operations-metrics">
            <span>准时 ${Math.round(operationsNum(item.on_time_rate) * 100)}%</span>
            <span>一次通过 ${Math.round(operationsNum(item.first_pass_rate) * 100)}%</span>
            <span>返工 ${Math.round(operationsNum(item.rework_rate) * 100)}%</span>
            <span>协作 ${operationsNum(item.collaboration_score).toFixed(1)}/5</span>
            <span>复杂度 ${operationsNum(item.complexity_score).toFixed(1)}/5</span>
            <span>经营贡献 ${operationsNum(item.business_contribution).toFixed(1)}/5</span>
          </div>
          ${evidenceText ? `<div class="operations-evidence">证据：${escapeHtml(evidenceText)}</div>` : ""}
          ${item.customer_evaluation && Object.keys(item.customer_evaluation).length
            ? `<div class="operations-note">客户评价：${escapeHtml(
              String(item.customer_evaluation.score ?? "—"))}/5 · ${escapeHtml(
              item.customer_evaluation.comment || "—")}</div>` : ""}
          ${item.employee_statement ? `<div class="operations-note">员工说明：${escapeHtml(item.employee_statement)}</div>` : ""}
          ${item.reviewer_note ? `<div class="operations-note">复核说明：${escapeHtml(item.reviewer_note)}</div>` : ""}
          <div class="operations-policy">绩效依据只用于复核与说明，不直接决定工资或晋升。</div>
        </div>`;
    }).join("")
    : `<div class="identity-empty"><b>${canPerformance ? "暂无绩效证据" : "当前权限不展示绩效证据"}</b><span>有权限的管理者建立证据记录后会显示在这里。</span></div>`;

  $("operations-worklog").innerHTML = canWorklogs
    ? `<div class="operations-card">
      <div class="operations-metrics operations-worklog-grid">
        <span><b>${operationsHours(summary.total_hours)}</b>已批准总工时</span>
        <span><b>${operationsHours(summary.billable_hours)}</b>可计费</span>
        <span><b>${operationsHours(summary.overtime_hours)}</b>加班</span>
        <span><b>${operationsHours(summary.rework_hours)}</b>返工</span>
        <span><b>${operationsHours(summary.waiting_hours)}</b>等待</span>
        <span><b>${operationsHours(summary.travel_hours)}</b>出差</span>
      </div>
    </div>`
    : '<div class="identity-empty"><b>当前权限不展示工时经营汇总</b></div>';

  $("operations-capacity").querySelectorAll("[data-capacity-id]").forEach(button => {
    button.onclick = () => {
      const item = demands.find(row =>
        String(row.id) === button.dataset.capacityId);
      if (item) openCapacityDemand(item);
    };
  });
  const actions = $("operations-admin-actions");
  if (actions) {
    actions.classList.toggle("hidden", !canCapacity && !canPerformance);
    if ($("btn-ops-skill")) $("btn-ops-skill").disabled = !access.can_manage_skills;
    if ($("btn-ops-capacity")) {
      $("btn-ops-capacity").disabled = !access.can_manage_capacity;
    }
    if ($("btn-ops-evidence")) {
      $("btn-ops-evidence").disabled = !access.can_manage_performance;
    }
  }
}

async function loadOperations(force) {
  if (!DB.profile) return;
  if (!operationsAllowedInCurrentMode()) {
    if (DB.operations && (DB.operations.projects || []).length) {
      clearOperationsCache();
    }
    return;
  }
  if (!initCloud()) {
    toast("云组件没有加载，暂时无法读取经营摘要。");
    return;
  }
  const last = operationsNum(operationsState().at);
  if (!force && last && Date.now() - last < 10000) {
    renderOperations();
    return;
  }
  if (operationsBusy) return;
  operationsBusy = true;
  try {
    try {
      const cloudProjects = typeof pullCloudProjects === "function"
        ? await pullCloudProjects() : { changed: 0, error: null };
      if (cloudProjects && cloudProjects.error) {
        operationsStaleMessage = String(
          cloudProjects.error.message || cloudProjects.error);
      }
    } catch (projectError) {
      operationsStaleMessage = String(projectError.message || projectError);
    }
    const data = await operationsRpc("get_operations_dashboard", {
      p_weeks: 4,
    });
    if (!operationsAllowedInCurrentMode()) {
      clearOperationsCache();
      return;
    }
    DB.operations = Object.assign(
      emptyOperationsState(Date.now()),
      data && typeof data === "object" ? data : {},
      { at: Date.now() }
    );
    const serverIds = new Set((DB.operations.projects || [])
      .map(item => String(item.project_id || "")));
    const localIds = new Set((DB.projects || [])
      .filter(item => item.remote_id)
      .map(item => String(item.remote_id)));
    const missing = [...serverIds].filter(id => id && !localIds.has(id));
    operationsStaleMessage = missing.length
      ? '经营摘要有 ' + missing.length + ' 个项目尚未合并到首页，请再刷新一次。'
      : "";
    saveAll();
    renderOperations();
  } catch (error) {
    operationsStaleMessage = String(error.message || error || "经营数据加载失败");
    renderOperations();
    toast(operationsStaleMessage);
  } finally {
    operationsBusy = false;
  }
}

function refreshOperationsIfActive() {
  if (currentPageName() === "operations") loadOperations(true);
}

function renderMyPerformance() {
  const box = $("my-performance");
  if (!box) return;
  const state = DB.myPerformance && typeof DB.myPerformance === "object"
    ? DB.myPerformance : { items: [] };
  const items = Array.isArray(state.items) ? state.items : [];
  if (!items.length) {
    box.innerHTML = '<div class="identity-empty"><b>暂无绩效依据</b>'
      + '<span>管理者建立本周期证据后会出现在这里。</span></div>';
    return;
  }
  box.innerHTML = items.map(item => {
    const evidence = operationsEvidenceEntries(item.evidence);
    const details = Array.isArray(item.evidence_details) ? item.evidence_details : [];
    const evidenceText = (details.length ? details : evidence).map(entry => {
      if (!entry || typeof entry !== "object") return "";
      return String(entry.type || entry.source_type || "记录")
        + " " + String(entry.source_id || entry.id || "")
        + (entry.label ? " · " + String(entry.label) : "");
    }).filter(Boolean).join(" · ");
    const canExplain = item.status !== "reviewed";
    return `
      <div class="operations-card">
        <div class="operations-card-head">
          <div class="grow"><b>${escapeHtml(item.period || "本周期")}</b>
            <div class="meta">${escapeHtml(item.status === "reviewed" ? "已复核" : "可补充说明")}</div></div>
          <div class="operations-number"><b>${operationsNum(item.score).toFixed(1)}</b>
            <span>证据分</span></div>
        </div>
        <div class="operations-metrics">
          <span>准时 ${Math.round(operationsNum(item.on_time_rate) * 100)}%</span>
          <span>一次通过 ${Math.round(operationsNum(item.first_pass_rate) * 100)}%</span>
          <span>返工 ${Math.round(operationsNum(item.rework_rate) * 100)}%</span>
          <span>协作 ${operationsNum(item.collaboration_score).toFixed(1)}/5</span>
          <span>复杂度 ${operationsNum(item.complexity_score).toFixed(1)}/5</span>
          <span>经营贡献 ${operationsNum(item.business_contribution).toFixed(1)}/5</span>
        </div>
        ${evidenceText ? `<div class="operations-evidence">依据：${escapeHtml(evidenceText)}</div>` : ""}
        ${item.customer_evaluation && Object.keys(item.customer_evaluation).length
          ? `<div class="operations-note">客户评价：${escapeHtml(
            String(item.customer_evaluation.score ?? "—"))}/5 · ${escapeHtml(
            item.customer_evaluation.comment || "—")}</div>` : ""}
        ${item.employee_statement ? `<div class="operations-note">我的说明：${escapeHtml(item.employee_statement)}</div>` : ""}
        ${item.reviewer_note ? `<div class="operations-note">复核说明：${escapeHtml(item.reviewer_note)}</div>` : ""}
        <div class="operations-policy">绩效分数只依据交付和质量证据，不直接决定工资或晋升。</div>
        ${canExplain ? `<button class="btn ghost" data-performance-statement="${escapeHtml(String(item.id || ""))}">
          补充我的说明</button>` : ""}
      </div>`;
  }).join("");
  box.querySelectorAll("[data-performance-statement]").forEach(button => {
    button.onclick = () => {
      const item = items.find(row => String(row.id) === button.dataset.performanceStatement);
      if (item) openPerformanceStatement(item);
    };
  });
}

async function loadMyPerformanceEvidence(force) {
  if (!DB.profile || !initCloud()) return;
  const last = operationsNum(DB.myPerformance && DB.myPerformance.at);
  if (!force && last && Date.now() - last < 10000) {
    renderMyPerformance();
    return;
  }
  if (myPerformanceBusy) return;
  myPerformanceBusy = true;
  try {
    const data = await operationsRpc("get_my_performance_evidence");
    DB.myPerformance = Object.assign(
      { items: [] },
      data && typeof data === "object" ? data : {},
      { at: Date.now() }
    );
    saveAll();
    renderMyPerformance();
  } catch (error) {
    toast(String(error.message || error));
  } finally {
    myPerformanceBusy = false;
  }
}

function openPerformanceStatement(item) {
  openSheet("补充绩效说明", `
    <div class="hint" style="margin-bottom:8px">
      ${escapeHtml(item.period || "本周期")} · 证据分 ${operationsNum(item.score).toFixed(1)}
    </div>
    <label for="my-performance-statement">我的说明</label>
    <textarea id="my-performance-statement" maxlength="2000"
      placeholder="说明背景、约束、协作或交付证据">${escapeHtml(item.employee_statement || "")}</textarea>
    <div class="community-note">说明会提交给有权限的复核管理者，不能修改工资或晋升结果。</div>
  `, [
    { label: "取消", onClick: closeSheet },
    { label: "提交说明", kind: "", onClick: () => submitPerformanceStatement(item.id) },
  ]);
}

async function submitPerformanceStatement(evidenceId) {
  const statement = $("my-performance-statement").value.trim();
  if (!statement) { toast("先写一句说明"); return; }
  try {
    await operationsRpc("submit_performance_statement", {
      p_evidence: String(evidenceId),
      p_statement: statement,
    });
    closeSheet();
    toast("说明已提交，等待复核");
    await loadMyPerformanceEvidence(true);
  } catch (error) {
    toast(String(error.message || error));
  }
}

function worklogDimensionData(worklog) {
  const kind = String(worklog.work_kind || "project");
  return {
    billable: worklog.billable !== false,
    overtime: !!worklog.overtime,
    work_kind: ["project", "presales", "internal"].indexOf(kind) !== -1
      ? kind : "project",
    rework: !!worklog.rework,
    waiting: !!worklog.waiting,
    travel: !!worklog.travel,
  };
}

function operationsUuid(value) {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
    .test(String(value || ""));
}

function localWorklog(localId) {
  return (DB.worklogs || []).find(
    item => String(item.id) === String(localId)
  ) || null;
}

function worklogMigrationEmployeeId(worklog) {
  const raw = String((worklog && worklog.employee_id) || "");
  if (operationsUuid(raw)) return raw;
  const employee = (DB.employees || []).find(item =>
    String(item.id) === raw
    || String(item.cloud_id || "") === raw
    || String(item.cloud_profile_id || "") === raw
  );
  if (employee) {
    const candidates = [
      employee.cloud_id, employee.cloud_profile_id, employee.profile_id,
    ];
    for (let i = 0; i < candidates.length; i += 1) {
      if (operationsUuid(candidates[i])) return String(candidates[i]);
    }
  }
  const accounts = typeof staffAccounts === "function" ? staffAccounts() : [];
  let account = accounts.find(
    item => String(item.employee_id || "") === raw
  );
  if (!account && employee) {
    const sameName = accounts.filter(
      item => String(item.name || "") === String(employee.name || "")
    );
    if (sameName.length === 1) account = sameName[0];
  }
  if (account && operationsUuid(account.employee_id)) {
    return String(account.employee_id);
  }
  if (DB.profile && employee
      && String(employee.name || "") === String(DB.profile.name || "")
      && operationsUuid(DB.profile.id)) {
    return String(DB.profile.id);
  }
  return "";
}

function currentWorklogOwnerId() {
  const profile = DB.profile || {};
  if (profile.role === "boss" && operationsUuid(profile.id)) {
    return String(profile.id);
  }
  if (operationsUuid(profile.boss_id)) return String(profile.boss_id);
  if (typeof identityOwnerId === "function") {
    const ownerId = identityOwnerId();
    if (operationsUuid(ownerId)) return String(ownerId);
  }
  return "";
}

function worklogMigrationBossId(worklog) {
  const owned = String((worklog && worklog.owner_profile_id) || "");
  if (operationsUuid(owned)) return owned;
  const raw = String((worklog && worklog.boss_id) || "");
  if (operationsUuid(raw)) return raw;
  return currentWorklogOwnerId();
}

function worklogMigrationProjectId(worklog) {
  const raw = String((worklog && worklog.cloud_project_id) || "");
  if (operationsUuid(raw)) return raw;
  const project = (DB.projects || []).find(
    item => String(item.id) === String(worklog && worklog.project_id)
  );
  if (!project) return "";
  return operationsUuid(project.cloud_id) ? String(project.cloud_id)
    : operationsUuid(project.cloud_project_id)
      ? String(project.cloud_project_id) : "";
}

function worklogMigrationStepId(worklog) {
  const raw = String((worklog && worklog.cloud_step_id) || "");
  if (operationsUuid(raw)) return raw;
  const step = (DB.steps || []).find(
    item => String(item.id) === String(worklog && worklog.step_id)
  );
  if (!step) return "";
  return operationsUuid(step.cloud_id) ? String(step.cloud_id) : "";
}

/* 手工补录 / 完成任务时要带公司归属。跨公司加入的老板号，
   工时属于当前活跃公司，而不是他自己那家公司。 */
function worklogMigrationEnterpriseId(worklog) {
  const raw = String((worklog && worklog.enterprise_id) || "");
  if (operationsUuid(raw)) return raw;
  if (typeof currentEnterpriseId === "function") {
    const eid = currentEnterpriseId();
    if (operationsUuid(eid)) return String(eid);
  }
  return "";
}

function queueLocalWorklogMigration(worklogId, worklog) {
  const localId = String(worklogId || "");
  if (!localId || operationsUuid(localId)) return null;
  if (!Array.isArray(DB.worklogMigrationQueue)) {
    DB.worklogMigrationQueue = [];
  }
  const current = worklog || localWorklog(localId) || {};
  let item = DB.worklogMigrationQueue.find(
    row => String(row.local_id || "") === localId
  );
  let cloudId = item && operationsUuid(item.cloud_id) ? item.cloud_id : "";
  if (!cloudId && operationsUuid(current.cloud_id)) {
    cloudId = String(current.cloud_id);
  }
  if (!cloudId) cloudId = uuid();
  if (item) {
    item.cloud_id = String(cloudId);
    item.snapshot = Object.assign({}, current);
    item.updated_at = nowISO();
    delete item.lastError;
    delete item.lastErrorAt;
  } else {
    item = {
      local_id: localId,
      cloud_id: String(cloudId),
      snapshot: Object.assign({}, current),
      created_at: nowISO(),
      updated_at: nowISO(),
    };
    DB.worklogMigrationQueue.push(item);
  }
  if (!Array.isArray(DB.dimensionQueue)) DB.dimensionQueue = [];
  DB.dimensionQueue.forEach(row => {
    if (String(row.local_id || "") === localId) {
      row.worklog_id = String(cloudId);
      row.local_id = null;
      row.updated_at = nowISO();
    }
  });
  _save();
  return item;
}

function ensureLocalWorklogMigrationQueues() {
  const ownerId = currentWorklogOwnerId();
  (DB.worklogs || []).forEach(item => {
    if (operationsUuid(item.cloud_id)) return;
    if (ownerId && operationsUuid(item.owner_profile_id)
        && String(item.owner_profile_id) !== ownerId) {
      return;
    }
    queueLocalWorklogMigration(item.id, item);
  });
  (DB.dimensionQueue || []).forEach(item => {
    if (!item.local_id) return;
    const worklog = localWorklog(item.local_id);
    if (worklog) queueLocalWorklogMigration(item.local_id, worklog);
  });
}

function worklogMigrationPayload(item) {
  const worklog = localWorklog(item && item.local_id)
    || (item && item.snapshot) || null;
  const cloudId = String((item && item.cloud_id) || "");
  if (!worklog) {
    return {ready: false, reason: "Worklog is no longer available locally."};
  }
  if (!operationsUuid(cloudId)) {
    return {ready: false, reason: "Cloud UUID has not been assigned yet."};
  }
  const bossId = worklogMigrationBossId(worklog);
  const employeeId = worklogMigrationEmployeeId(worklog);
  if (!bossId) {
    return {ready: false, reason: "Enterprise owner identity is not available yet."};
  }
  const currentOwner = currentWorklogOwnerId();
  if (currentOwner && bossId !== currentOwner) {
    return {ready: false, reason: "Worklog belongs to a different enterprise."};
  }
  if (!employeeId) {
    return {
      ready: false,
      reason: "Employee cloud account is not available yet.",
    };
  }
  const projectId = worklogMigrationProjectId(worklog);
  const stepId = worklogMigrationStepId(worklog);
  const project = (DB.projects || []).find(
    row => String(row.id) === String(worklog.project_id)
  );
  const taskId = operationsUuid(worklog.task_id) ? String(worklog.task_id) : null;
  const enterpriseId = worklogMigrationEnterpriseId(worklog);
  return {
    ready: true,
    payload: {
      id: cloudId,
      boss_id: bossId,
      employee_id: employeeId,
      enterprise_id: enterpriseId || null,
      task_id: taskId,
      project_id: projectId || null,
      step_id: stepId || null,
      work_date: String(worklog.work_date || ""),
      hours: operationsNum(worklog.hours),
      content: String(worklog.content || ""),
      project_name: String(worklog.project_name || (project && project.name) || ""),
      source: String(worklog.source || "manual"),
      version: 1,
      approval_status: String(worklog.approval_status || "pending"),
      idempotency_key: "local-worklog:" + cloudId,
    },
  };
}

function completeWorklogMigration(item) {
  if (!item) return null;
  const built = worklogMigrationPayload(item);
  if (!built.ready) return null;
  const local = localWorklog(item.local_id);
  if (local) {
    local.cloud_id = item.cloud_id;
    local.cloud_project_id = built.payload.project_id || "";
    local.cloud_step_id = built.payload.step_id || "";
    local.updated_at = nowISO();
  }
  DB.worklogMigrationQueue = (DB.worklogMigrationQueue || []).filter(
    row => row !== item && String(row.cloud_id || "") !== String(item.cloud_id || "")
  );
  resolveQueuedWorklogDimensions(item.local_id, item.cloud_id);
  _save();
  return local;
}

function removeQueuedWorklogMigration(worklogId) {
  const id = String(worklogId || "");
  if (!id) return;
  DB.worklogMigrationQueue = (DB.worklogMigrationQueue || []).filter(item =>
    String(item.local_id || "") !== id
    && String(item.cloud_id || "") !== id
  );
  removeQueuedWorklogDimensions(id);
  _save();
}

function queueWorklogDimensions(worklogId, worklog) {
  const id = String(worklogId || "");
  if (!id) return false;
  if (!Array.isArray(DB.dimensionQueue)) DB.dimensionQueue = [];
  let cloudId = operationsUuid(id) ? id : null;
  let localId = cloudId ? null : id;
  if (!cloudId) {
    const migration = queueLocalWorklogMigration(id, worklog);
    if (migration) {
      cloudId = migration.cloud_id;
      localId = null;
    }
  }
  const data = worklogDimensionData(worklog || {});
  const existing = DB.dimensionQueue.find(item =>
    (cloudId && String(item.worklog_id || "") === cloudId)
    || (localId && String(item.local_id || "") === localId));
  if (existing) {
    existing.worklog_id = cloudId;
    existing.local_id = localId;
    existing.data = data;
    existing.updated_at = nowISO();
    delete existing.lastError;
  } else {
    DB.dimensionQueue.push({
      worklog_id: cloudId,
      local_id: localId,
      data: data,
      created_at: nowISO(),
    });
  }
  _save();
  return true;
}

function resolveQueuedWorklogDimensions(localId, worklogId) {
  const localKey = String(localId || "");
  const cloudId = String(worklogId || "");
  if (!localKey || !operationsUuid(cloudId) || !Array.isArray(DB.dimensionQueue)) {
    return false;
  }
  let resolved = false;
  DB.dimensionQueue.forEach(item => {
    if (String(item.local_id || "") === localKey) {
      item.worklog_id = cloudId;
      item.local_id = null;
      item.updated_at = nowISO();
      resolved = true;
    }
  });
  if (resolved) {
    _save();
    if (typeof syncNow === "function") syncNow("worklog-dimensions-resolved");
  }
  return resolved;
}

function removeQueuedWorklogDimensions(worklogId) {
  if (!Array.isArray(DB.dimensionQueue)) return;
  const id = String(worklogId || "");
  DB.dimensionQueue = DB.dimensionQueue.filter(
    item => String(item.worklog_id || "") !== id
      && String(item.local_id || "") !== id);
  _save();
}

function syncWorklogDimensions(worklog) {
  if (!worklog) return;
  const id = worklog.cloud_id || worklog.id;
  if (!queueWorklogDimensions(id, worklog)) return;
  if (typeof syncNow === "function") syncNow("worklog-dimensions");
}

async function loadWorklogDimensions(worklog) {
  if (!worklog || !worklog.id || !operationsUuid(worklog.id)) return {};
  try {
    return await operationsRpc("get_worklog_dimensions", {
      p_worklog: String(worklog.id),
    }) || {};
  } catch (error) {
    return {};
  }
}

function operationsMembers() {
  const state = operationsState();
  return Array.isArray(state.members) ? state.members : [];
}

function operationsMemberOptions(selected) {
  return operationsMembers().map(item => `<option value="${
    escapeHtml(String(item.profile_id || ""))}"${
    String(item.profile_id || "") === String(selected || "") ? " selected" : ""
  }>${escapeHtml(item.name || "成员")}</option>`).join("");
}

function openSkillEditor(existing) {
  const item = existing || {};
  openSheet("维护技能", `
    <label for="ops-skill-member">成员</label>
    <select id="ops-skill-member">${operationsMemberOptions(item.profile_id)}</select>
    <label for="ops-skill-name">技能</label>
    <input id="ops-skill-name" value="${escapeHtml(item.skill || "")}">
    <div class="row2">
      <div><label for="ops-skill-level">等级 1-5</label>
        <input id="ops-skill-level" type="number" min="1" max="5" value="${
          intOrZero(item.level) || 1}"></div>
      <div><label for="ops-skill-hours">每周可用工时</label>
        <input id="ops-skill-hours" type="number" min="0" step="0.5" value="${
          operationsNum(item.available_hours)}"></div>
    </div>
    <label class="check"><input type="checkbox" id="ops-skill-certified"${
      item.certified ? " checked" : ""}>已认证</label>
    <label for="ops-skill-cert">证书</label>
    <input id="ops-skill-cert" value="${escapeHtml(item.certification || "")}">
    <label for="ops-skill-valid">有效期至</label>
    <input id="ops-skill-valid" type="date" value="${escapeHtml(item.valid_until || "")}">
  `, [
    { label: "取消", onClick: closeSheet },
    { label: "保存", kind: "", onClick: submitSkill },
  ]);
}

async function submitSkill() {
  const profileId = $("ops-skill-member").value;
  const skill = $("ops-skill-name").value.trim();
  if (!profileId || !skill) { toast("先选成员并填写技能"); return; }
  try {
    await operationsRpc("upsert_profile_skill", {
      p_profile: profileId,
      p_skill: skill,
      p_data: {
        level: parseInt($("ops-skill-level").value, 10) || 1,
        available_hours: parseFloat($("ops-skill-hours").value) || 0,
        certified: $("ops-skill-certified").checked,
        certification: $("ops-skill-cert").value.trim(),
        valid_until: $("ops-skill-valid").value,
      },
    });
    closeSheet();
    toast("技能已保存");
    await loadOperations(true);
  } catch (error) {
    toast(String(error.message || error));
  }
}

function openCapacityDemand(existing) {
  const item = existing || {};
  const state = operationsState();
  const projects = Array.isArray(state.projects) ? state.projects : [];
  const today = todayISO();
  const end = new Date(Date.now() + 27 * 86400000).toISOString().slice(0, 10);
  openSheet(existing ? "编辑能力需求" : "新增能力需求", `
    <label for="ops-demand-skill">技能</label>
    <input id="ops-demand-skill" value="${escapeHtml(item.skill || "")}">
    <div class="row2">
      <div><label for="ops-demand-hours">需求工时</label>
        <input id="ops-demand-hours" type="number" min="0.5" step="0.5" value="${
          operationsNum(item.required_hours) || 40}"></div>
      <div><label for="ops-demand-project">项目</label>
        <select id="ops-demand-project"><option value="">（不绑定）</option>${
          projects.map(project => `<option value="${escapeHtml(project.project_id)}"${
            String(project.project_id) === String(item.project_id || "") ? " selected" : ""
          }>${escapeHtml(project.name || "项目")}</option>`).join("")}</select></div>
    </div>
    <div class="row2">
      <div><label for="ops-demand-from">开始</label>
        <input id="ops-demand-from" type="date" value="${escapeHtml(item.needed_from || today)}"></div>
      <div><label for="ops-demand-until">结束</label>
        <input id="ops-demand-until" type="date" value="${escapeHtml(item.needed_until || end)}"></div>
    </div>
    <label for="ops-demand-owner">责任人</label>
    <select id="ops-demand-owner"><option value="">（未指派）</option>${
      operationsMemberOptions(item.owner_profile_id)}</select>
    <label for="ops-demand-note">说明</label>
    <input id="ops-demand-note" value="${escapeHtml(item.note || "")}">
  `, [
    { label: "取消", onClick: closeSheet },
    { label: "保存", kind: "", onClick: () => submitCapacityDemand(item.id) },
  ]);
}

async function submitCapacityDemand(demandId) {
  const skill = $("ops-demand-skill").value.trim();
  if (!skill) { toast("填写技能"); return; }
  try {
    await operationsRpc("upsert_capacity_demand", {
      p_demand: demandId ? String(demandId) : null,
      p_data: {
        skill: skill,
        required_hours: parseFloat($("ops-demand-hours").value) || 0,
        needed_from: $("ops-demand-from").value,
        needed_until: $("ops-demand-until").value,
        project_id: $("ops-demand-project").value || null,
        owner_profile_id: $("ops-demand-owner").value || null,
        note: $("ops-demand-note").value.trim(),
      },
    });
    closeSheet();
    toast("能力需求已保存");
    await loadOperations(true);
  } catch (error) {
    toast(String(error.message || error));
  }
}

function parseEvidenceLines(text) {
  return String(text || "").split(/\n+/).map(line => {
    const separator = line.indexOf(":");
    if (separator < 1) return null;
    return {
      type: line.slice(0, separator).trim(),
      id: line.slice(separator + 1).trim(),
    };
  }).filter(item => item && item.type && item.id);
}

function openPerformanceEvidence(existing) {
  const item = existing || {};
  const month = todayISO().slice(0, 7);
  const customer = item.customer_evaluation || {};
  const entries = operationsEvidenceEntries(item.evidence).map(entry =>
    `${entry.type || entry.source_type || ""}:${entry.id || entry.source_id || ""}`
  ).join("\n");
  openSheet("新建绩效证据", `
    <label for="ops-evidence-member">成员</label>
    <select id="ops-evidence-member">${operationsMemberOptions(item.profile_id)}</select>
    <label for="ops-evidence-period">周期</label>
    <input id="ops-evidence-period" value="${escapeHtml(item.period || month)}">
    <div class="row2">
      <div><label for="ops-evidence-ontime">准时率 0-1</label>
        <input id="ops-evidence-ontime" type="number" min="0" max="1" step="0.01" value="${
          operationsNum(item.on_time_rate)}"></div>
      <div><label for="ops-evidence-first">一次通过率 0-1</label>
        <input id="ops-evidence-first" type="number" min="0" max="1" step="0.01" value="${
          operationsNum(item.first_pass_rate)}"></div>
    </div>
    <div class="row2">
      <div><label for="ops-evidence-rework">返工率 0-1</label>
        <input id="ops-evidence-rework" type="number" min="0" max="1" step="0.01" value="${
          operationsNum(item.rework_rate)}"></div>
      <div><label for="ops-evidence-collab">协作 0-5</label>
        <input id="ops-evidence-collab" type="number" min="0" max="5" step="0.1" value="${
          operationsNum(item.collaboration_score)}"></div>
    </div>
    <div class="row2">
      <div><label for="ops-evidence-complexity">复杂度 0-5</label>
        <input id="ops-evidence-complexity" type="number" min="0" max="5" step="0.1" value="${
          operationsNum(item.complexity_score)}"></div>
      <div><label for="ops-evidence-contribution">经营贡献 0-5</label>
        <input id="ops-evidence-contribution" type="number" min="0" max="5" step="0.1" value="${
          operationsNum(item.business_contribution)}"></div>
    </div>
    <div class="row2">
      <div><label for="ops-evidence-customer-score">客户评分 0-5</label>
        <input id="ops-evidence-customer-score" type="number" min="0" max="5" step="0.1" value="${
          operationsNum(customer.score)}"></div>
      <div><label for="ops-evidence-customer-name">客户</label>
        <input id="ops-evidence-customer-name" value="${escapeHtml(customer.evaluator || "")}"></div>
    </div>
    <label for="ops-evidence-customer-comment">客户评价</label>
    <input id="ops-evidence-customer-comment" value="${escapeHtml(customer.comment || "")}">
    <label for="ops-evidence-lines">来源证据（task:UUID / worklog:UUID / approval:UUID）</label>
    <textarea id="ops-evidence-lines" placeholder="task:xxxxxxxx-...">${escapeHtml(entries)}</textarea>
    <div class="community-note">服务端会校验来源记录是否属于该员工。</div>
  `, [
    { label: "取消", onClick: closeSheet },
    { label: "保存", kind: "", onClick: submitPerformanceEvidence },
  ]);
}

async function submitPerformanceEvidence() {
  const profile = $("ops-evidence-member").value;
  const period = $("ops-evidence-period").value.trim();
  if (!profile || !period) { toast("先选成员并填写周期"); return; }
  try {
    await operationsRpc("upsert_performance_evidence", {
      p_profile: profile,
      p_period: period,
      p_data: {
        on_time_rate: parseFloat($("ops-evidence-ontime").value) || 0,
        first_pass_rate: parseFloat($("ops-evidence-first").value) || 0,
        rework_rate: parseFloat($("ops-evidence-rework").value) || 0,
        collaboration_score: parseFloat($("ops-evidence-collab").value) || 0,
        complexity_score: parseFloat($("ops-evidence-complexity").value) || 0,
        business_contribution: parseFloat($("ops-evidence-contribution").value) || 0,
        customer_evaluation: {
          score: parseFloat($("ops-evidence-customer-score").value) || 0,
          evaluator: $("ops-evidence-customer-name").value.trim(),
          comment: $("ops-evidence-customer-comment").value.trim(),
        },
        evidence: parseEvidenceLines($("ops-evidence-lines").value),
      },
    });
    closeSheet();
    toast("绩效证据已保存");
    await loadOperations(true);
  } catch (error) {
    toast(String(error.message || error));
  }
}

function bindOperations() {
  if ($("btn-operations-refresh")) {
    $("btn-operations-refresh").onclick = () => loadOperations(true);
  }
  if ($("btn-ops-skill")) {
    $("btn-ops-skill").onclick = () => openSkillEditor(null);
  }
  if ($("btn-ops-capacity")) {
    $("btn-ops-capacity").onclick = () => openCapacityDemand(null);
  }
  if ($("btn-ops-evidence")) {
    $("btn-ops-evidence").onclick = () => openPerformanceEvidence(null);
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
}
