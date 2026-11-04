/* =============================================================
   Phase 2B mobile operations summary and personal evidence.

   The management page is loaded only through get_operations_dashboard.
   Employee evidence uses a separate own-row RPC and is revealed on demand.
   ============================================================= */
"use strict";

let operationsBusy = false;
let myPerformanceBusy = false;
const WORKLOG_DIMENSION_RPC = "upsert_worklog_dimensions";

function operationsState() {
  return DB.operations && typeof DB.operations === "object"
    ? DB.operations : { projects: [], capacity_gaps: [], performance: [], worklog_summary: {} };
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

function operationsDate(value) {
  const text = String(value || "");
  return text ? text.slice(0, 16).replace("T", " ") : "—";
}

function renderOperations() {
  if (!$("operations-projects") || !$("operations-capacity")) return;
  const state = operationsState();
  const projects = Array.isArray(state.projects) ? state.projects : [];
  const gaps = Array.isArray(state.capacity_gaps) ? state.capacity_gaps : [];
  const performance = Array.isArray(state.performance) ? state.performance : [];
  const summary = state.worklog_summary && typeof state.worklog_summary === "object"
    ? state.worklog_summary : {};
  const margin = projects.reduce((sum, item) => sum + operationsNum(item.projected_margin), 0);
  const collectionGap = projects.reduce(
    (sum, item) => sum + operationsNum(item.collection_gap), 0);
  const shortages = gaps.filter(item => operationsNum(item.gap_hours) > 0).length;

  if ($("operations-summary")) {
    $("operations-summary").innerHTML = `
      <div class="decision-summary-card"><span>项目</span><b>${projects.length}</b></div>
      <div class="decision-summary-card"><span>预计毛利</span><b>${operationsMoney(margin)}</b></div>
      <div class="decision-summary-card ${collectionGap > 0 ? "is-severe" : ""}">
        <span>回款缺口</span><b>${operationsMoney(collectionGap)}</b></div>
      <div class="decision-summary-card ${shortages > 0 ? "is-severe" : ""}">
        <span>能力缺口</span><b>${shortages}</b></div>`;
  }

  $("operations-projects").innerHTML = projects.length
    ? projects.map(item => `
      <div class="operations-card">
        <div class="operations-card-head">
          <div class="grow"><b>${escapeHtml(item.name || "项目")}</b>
            <div class="meta">合同 ${operationsMoney(item.contract_amount)}
              · 已开票 ${operationsMoney(item.invoiced_amount)}
              · 已回款 ${operationsMoney(item.collected_amount)}</div></div>
          <div class="operations-number ${operationsNum(item.projected_margin) < 0 ? "bad" : "good"}">
            <b>${operationsMoney(item.projected_margin)}</b>
            <span>${operationsNum(item.projected_margin_percent).toFixed(1)}%</span></div>
        </div>
        <div class="operations-metrics">
          <span>外包承诺 ${operationsMoney(item.outsourced_committed)}</span>
          <span>人力成本 ${operationsMoney(item.labor_cost)}</span>
          <span>预计完工成本 ${operationsMoney(item.projected_completion_cost)}</span>
          <span>回款缺口 ${operationsMoney(item.collection_gap)}</span>
        </div>
      </div>`).join("")
    : '<div class="identity-empty"><b>暂无经营数据</b><span>有权限的成员录入合同与成本后会显示在这里。</span></div>';

  $("operations-capacity").innerHTML = gaps.length
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

  $("operations-performance").innerHTML = performance.length
    ? performance.map(item => {
      const evidence = Array.isArray(item.evidence) ? item.evidence : [];
      const evidenceText = evidence.map(entry => {
        if (!entry || typeof entry !== "object") return "";
        return String(entry.type || entry.source_type || "记录")
          + " " + String(entry.id || entry.source_id || "");
      }).filter(Boolean).join(" · ");
      return `
        <div class="operations-card">
          <div class="operations-card-head">
            <div class="grow"><b>${escapeHtml(item.name || "成员")}</b>
              <div class="meta">${escapeHtml(item.period || "—")} ·
                ${escapeHtml(item.status === "reviewed" ? "已复核" : "待复核")}</div></div>
            <div class="operations-number"><b>${operationsNum(item.score).toFixed(1)}</b>
              <span>证据分</span></div>
          </div>
          <div class="operations-metrics">
            <span>准时 ${Math.round(operationsNum(item.on_time_rate) * 100)}%</span>
            <span>一次通过 ${Math.round(operationsNum(item.first_pass_rate) * 100)}%</span>
            <span>返工 ${Math.round(operationsNum(item.rework_rate) * 100)}%</span>
            <span>协作 ${operationsNum(item.collaboration_score).toFixed(1)}/5</span>
          </div>
          ${evidenceText ? `<div class="operations-evidence">证据：${escapeHtml(evidenceText)}</div>` : ""}
          ${item.employee_statement ? `<div class="operations-note">员工说明：${escapeHtml(item.employee_statement)}</div>` : ""}
          ${item.reviewer_note ? `<div class="operations-note">复核说明：${escapeHtml(item.reviewer_note)}</div>` : ""}
          <div class="operations-policy">绩效依据只用于复核与说明，不直接决定工资或晋升。</div>
        </div>`;
    }).join("")
    : '<div class="identity-empty"><b>暂无绩效证据</b><span>有权限的管理者建立证据记录后会显示在这里。</span></div>';

  $("operations-worklog").innerHTML = `
    <div class="operations-card">
      <div class="operations-metrics operations-worklog-grid">
        <span><b>${operationsHours(summary.total_hours)}</b>总工时</span>
        <span><b>${operationsHours(summary.billable_hours)}</b>可计费</span>
        <span><b>${operationsHours(summary.overtime_hours)}</b>加班</span>
        <span><b>${operationsHours(summary.rework_hours)}</b>返工</span>
        <span><b>${operationsHours(summary.waiting_hours)}</b>等待</span>
        <span><b>${operationsHours(summary.travel_hours)}</b>出差</span>
      </div>
    </div>`;
}

async function loadOperations(force) {
  if (!DB.profile) return;
  if (typeof identityHasManagementView === "function"
      && !identityHasManagementView()) return;
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
    const { data, error } = await cloudClient.rpc("get_operations_dashboard", {
      p_weeks: 4,
    });
    if (error) throw error;
    DB.operations = Object.assign(
      { projects: [], capacity_gaps: [], performance: [], worklog_summary: {} },
      data && typeof data === "object" ? data : {},
      { at: Date.now() }
    );
    saveAll();
    renderOperations();
  } catch (error) {
    toast(String(error.message || error));
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
    const evidence = Array.isArray(item.evidence) ? item.evidence : [];
    const evidenceText = evidence.map(entry => {
      if (!entry || typeof entry !== "object") return "";
      return String(entry.type || entry.source_type || "记录")
        + " " + String(entry.id || entry.source_id || "");
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
        </div>
        ${evidenceText ? `<div class="operations-evidence">依据：${escapeHtml(evidenceText)}</div>` : ""}
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
    const { data, error } = await cloudClient.rpc("get_my_performance_evidence");
    if (error) throw error;
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
    const { error } = await cloudClient.rpc("submit_performance_statement", {
      p_evidence: String(evidenceId),
      p_statement: statement,
    });
    if (error) throw error;
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

function queueWorklogDimensions(worklogId, worklog) {
  const id = String(worklogId || "");
  if (!DB.profile || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id)) {
    return false;
  }
  if (!Array.isArray(DB.dimensionQueue)) DB.dimensionQueue = [];
  const data = worklogDimensionData(worklog || {});
  const existing = DB.dimensionQueue.find(item => String(item.worklog_id) === id);
  if (existing) {
    existing.data = data;
    existing.updated_at = nowISO();
    delete existing.lastError;
  } else {
    DB.dimensionQueue.push({
      worklog_id: id,
      data: data,
      created_at: nowISO(),
    });
  }
  _save();
  return true;
}

function removeQueuedWorklogDimensions(worklogId) {
  if (!Array.isArray(DB.dimensionQueue)) return;
  const id = String(worklogId || "");
  DB.dimensionQueue = DB.dimensionQueue.filter(
    item => String(item.worklog_id) !== id);
  _save();
}

function syncWorklogDimensions(worklog) {
  if (!worklog || !queueWorklogDimensions(worklog.id, worklog)) return;
  if (typeof syncNow === "function") syncNow("worklog-dimensions");
}

function bindOperations() {
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
}
