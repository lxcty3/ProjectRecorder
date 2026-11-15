/* =============================================================
   资金 · 申请、审批链、资金池、支付与核销（CNY）
   ============================================================= */
"use strict";

let fundingState = {
  tab: "pending",
  requests: [],
  pools: [],
  settings: null,
  loading: false,
  error: "",
  lastLoad: 0,
};

const FUNDING_TYPES = {
  reimbursement: "报销",
  advance: "预支",
  special: "专项经费",
};

const FUNDING_STATUS = {
  draft: "草稿",
  pending: "待审批",
  approved: "已批准",
  paid: "已支付",
  settled: "已核销",
  rejected: "已驳回",
  cancelled: "已取消",
};

function fundingMoney(value) {
  const n = Number(value) || 0;
  return "¥" + n.toLocaleString("zh-CN", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

function fundingErrorText(error) {
  const text = String(error && error.message || error || "");
  if (/could not find|does not exist|function/i.test(text)) return "资金功能还没注入 SQL";
  if (/not allowed/i.test(text)) return "当前身份不能操作这笔资金";
  if (/amount must/i.test(text)) return "金额必须大于 0";
  if (/request not found/i.test(text)) return "这笔申请不存在";
  return text || "资金操作失败";
}

async function loadFunding(force) {
  if (!DB.profile || !initCloud()) return;
  const now = Date.now();
  if (!force && fundingState.lastLoad && now - fundingState.lastLoad < 8000) {
    renderFunding();
    return;
  }
  fundingState.loading = true;
  fundingState.error = "";
  renderFunding();
  try {
    const scope = fundingState.tab === "mine" ? "mine" : "pending";
    const [req, pools, settings] = await Promise.all([
      cloudClient.rpc("list_funding_requests", { p_scope: scope }),
      cloudClient.rpc("list_funding_pools", {}),
      cloudClient.rpc("get_funding_settings", {}),
    ]);
    if (req.error) throw req.error;
    if (pools.error) throw pools.error;
    if (settings.error) throw settings.error;
    fundingState.requests = Array.isArray(req.data && req.data.requests) ? req.data.requests : [];
    fundingState.pools = Array.isArray(pools.data && pools.data.pools) ? pools.data.pools : [];
    fundingState.settings = settings.data || null;
    fundingState.lastLoad = Date.now();
  } catch (error) {
    fundingState.error = fundingErrorText(error);
  } finally {
    fundingState.loading = false;
    renderFunding();
  }
}

function fundingApprovalText(approvals) {
  const list = Array.isArray(approvals) ? approvals : [];
  return list.map(step => {
    const label = step.step_kind === "manager" ? "直属上级"
      : step.step_kind === "finance" ? "财务"
      : step.step_kind === "owner" ? "老板" : "董事会";
    const mark = step.status === "approved" ? "✓"
      : step.status === "rejected" ? "✕" : "…";
    return mark + " " + label;
  }).join(" → ");
}

function fundingCard(request) {
  const canManage = fundingState.settings && fundingState.settings.can_manage;
  const pending = !!request.my_pending;
  const actionButtons = [];
  if (pending) {
    actionButtons.push('<button class="btn" data-funding-approve="' + escapeHtml(request.id) + '">批准</button>');
    actionButtons.push('<button class="btn ghost" data-funding-reject="' + escapeHtml(request.id) + '">驳回</button>');
  }
  if (canManage && request.status === "approved") {
    actionButtons.push('<button class="btn" data-funding-pay="' + escapeHtml(request.id) + '">标记已支付</button>');
  }
  if (canManage && (request.status === "approved" || request.status === "paid")) {
    actionButtons.push('<button class="btn ghost" data-funding-settle="' + escapeHtml(request.id) + '">核销</button>');
  }
  return '<article class="funding-card">'
    + '<div class="funding-card-head"><div><span class="funding-type">'
    + escapeHtml(FUNDING_TYPES[request.request_type] || request.request_type)
    + '</span><b>' + fundingMoney(request.amount) + '</b></div>'
    + '<span class="funding-status ' + escapeHtml(request.status) + '">'
    + escapeHtml(FUNDING_STATUS[request.status] || request.status) + '</span></div>'
    + '<div class="funding-reason">' + escapeHtml(request.reason || "未填写事由") + '</div>'
    + '<div class="funding-meta">申请人 ' + escapeHtml(request.applicant_name || "成员")
    + (request.category ? " · " + escapeHtml(request.category) : "")
    + (request.expected_date ? " · 期望 " + escapeHtml(String(request.expected_date).slice(0, 10)) : "")
    + '</div>'
    + '<div class="funding-approval-line">' + escapeHtml(fundingApprovalText(request.approvals)) + '</div>'
    + (actionButtons.length ? '<div class="funding-actions">' + actionButtons.join("") + '</div>' : '')
    + '</article>';
}

function renderFunding() {
  const box = $("funding-list");
  if (!box) return;
  const tabs = $("funding-tabs");
  if (tabs) {
    tabs.innerHTML = [["pending", "待我审批"], ["mine", "我的申请"], ["pools", "资金池"], ["settings", "设置"]]
      .map(([value, label]) => '<button class="chip' + (fundingState.tab === value ? " on" : "")
        + '" data-funding-tab="' + value + '">' + label + '</button>').join("");
    tabs.querySelectorAll("[data-funding-tab]").forEach(button => {
      button.onclick = () => {
        fundingState.tab = button.dataset.fundingTab;
        fundingState.lastLoad = 0;
        loadFunding(true);
      };
    });
  }
  if (fundingState.loading && !fundingState.requests.length) {
    box.innerHTML = '<div class="identity-empty"><b>正在加载资金</b><span>读取申请与资金池…</span></div>';
    return;
  }
  if (fundingState.error) {
    box.innerHTML = '<div class="identity-empty"><b>资金暂时不可用</b><span>'
      + escapeHtml(fundingState.error) + '</span></div>';
    return;
  }
  if (fundingState.tab === "pools") {
    box.innerHTML = fundingState.pools.length
      ? fundingState.pools.map(pool => '<article class="funding-card">'
        + '<div class="funding-card-head"><div><span class="funding-type">资金池</span><b>'
        + escapeHtml(pool.name) + '</b></div><span class="meta">剩余 '
        + fundingMoney(pool.remaining) + '</span></div>'
        + '<div class="funding-meta">总额 ' + fundingMoney(pool.total_amount)
        + ' · 已用 ' + fundingMoney(pool.used_amount) + '</div>'
        + (pool.purpose ? '<div class="funding-reason">' + escapeHtml(pool.purpose) + '</div>' : '')
        + '</article>').join("")
      : '<div class="identity-empty"><b>还没有资金池</b><span>老板/财务可以创建专项经费池。</span></div>';
    return;
  }
  if (fundingState.tab === "settings") {
    const s = fundingState.settings || {};
    box.innerHTML = '<div class="funding-card"><div class="funding-card-head"><div><b>金额分级</b>'
      + '<div class="meta">决定审批链走几级</div></div></div>'
      + (s.can_manage ? '<label>第一档上限（元）</label><input id="funding-tier1" type="number" min="0" value="'
        + Number(s.tier1_max || 500) + '"><label>第二档上限（元）</label><input id="funding-tier2" type="number" min="0" value="'
        + Number(s.tier2_max || 5000) + '"><button class="btn" id="btn-funding-save-settings" style="width:100%;margin-top:10px">保存设置</button>'
        : '<div class="meta">只有老板/财务能修改。</div>') + '</div>';
    if ($("btn-funding-save-settings")) {
      $("btn-funding-save-settings").onclick = saveFundingSettings;
    }
    return;
  }
  box.innerHTML = fundingState.requests.length
    ? fundingState.requests.map(fundingCard).join("")
    : '<div class="identity-empty"><b>' + (fundingState.tab === "pending" ? "没有待你审批的资金" : "还没有资金申请")
      + '</b><span>点「发起资金申请」开始。</span></div>';
  box.querySelectorAll("[data-funding-approve]").forEach(button => {
    button.onclick = () => decideFunding(button.dataset.fundingApprove, true);
  });
  box.querySelectorAll("[data-funding-reject]").forEach(button => {
    button.onclick = () => decideFunding(button.dataset.fundingReject, false);
  });
  box.querySelectorAll("[data-funding-pay]").forEach(button => {
    button.onclick = () => markFundingPaid(button.dataset.fundingPay);
  });
  box.querySelectorAll("[data-funding-settle]").forEach(button => {
    button.onclick = () => settleFunding(button.dataset.fundingSettle);
  });
}

async function saveFundingSettings() {
  const t1 = Number(($("funding-tier1") || {}).value || 500);
  const t2 = Number(($("funding-tier2") || {}).value || 5000);
  try {
    const result = await cloudClient.rpc("set_funding_settings", {
      p_tier1: t1, p_tier2: t2,
    });
    if (result.error) throw result.error;
    toast("资金设置已保存");
    await loadFunding(true);
  } catch (error) { toast(fundingErrorText(error)); }
}

function openFundingRequestSheet() {
  if (!DB.profile) { toast("登录后才能申请资金"); return; }
  const projects = (DB.projects || []).map(p =>
    '<option value="' + escapeHtml(String(p.id)) + '">' + escapeHtml(p.name) + '</option>').join("");
  const pools = fundingState.pools.map(p =>
    '<option value="' + escapeHtml(String(p.id)) + '">' + escapeHtml(p.name) + '</option>').join("");
  openSheet("发起资金申请", `
    <label for="funding-type">类型</label>
    <select id="funding-type">
      <option value="reimbursement">报销</option>
      <option value="advance">预支</option>
      <option value="special">专项经费</option>
    </select>
    <label for="funding-amount">金额（元）</label>
    <input id="funding-amount" type="number" min="0.01" step="0.01" placeholder="0.00">
    <label for="funding-reason">事由</label>
    <textarea id="funding-reason" maxlength="2000" placeholder="这笔钱用来做什么"></textarea>
    <label for="funding-category">类别（可选）</label>
    <input id="funding-category" maxlength="100" placeholder="差旅 / 采购 / 招待">
    <div class="row2">
      <div><label for="funding-project">项目（可选）</label>
        <select id="funding-project"><option value="">不关联项目</option>${projects}</select></div>
      <div><label for="funding-pool">资金池（可选）</label>
        <select id="funding-pool"><option value="">不使用资金池</option>${pools}</select></div>
    </div>
    <label for="funding-subject">预算科目（可选）</label>
    <input id="funding-subject" maxlength="200">
    <label for="funding-payee">收款人</label>
    <input id="funding-payee" maxlength="200">
    <label for="funding-method">支付方式</label>
    <select id="funding-method">
      <option value="bank">银行转账</option>
      <option value="alipay">支付宝</option>
      <option value="wechat">微信</option>
      <option value="cash">现金</option>
      <option value="other">其他</option>
    </select>
    <label for="funding-date">期望到账日</label>
    <input id="funding-date" type="date" value="${todayISO()}">
    <label for="funding-file">发票 / 收据（可选）</label>
    <input id="funding-file" type="file" accept="image/*,application/pdf">
  `, [
    { label: "取消", kind: "ghost", onClick: closeSheet },
    { label: "提交申请", kind: "", onClick: submitFundingRequest },
  ]);
}

async function submitFundingRequest() {
  const amount = Number(($("funding-amount") || {}).value || 0);
  const reason = String(($("funding-reason") || {}).value || "").trim();
  const type = String(($("funding-type") || {}).value || "reimbursement");
  if (!(amount > 0)) { toast("金额必须大于 0"); return; }
  if (!reason) { toast("先写资金事由"); return; }
  const projectRaw = String(($("funding-project") || {}).value || "");
  const poolRaw = String(($("funding-pool") || {}).value || "");
  try {
    const result = await cloudClient.rpc("create_funding_request", {
      p_type: type,
      p_amount: amount,
      p_reason: reason,
      p_category: String(($("funding-category") || {}).value || ""),
      p_project: projectRaw || null,
      p_pool: poolRaw || null,
      p_budget_subject: String(($("funding-subject") || {}).value || ""),
      p_payee: String(($("funding-payee") || {}).value || ""),
      p_payment_method: String(($("funding-method") || {}).value || ""),
      p_expected_date: String(($("funding-date") || {}).value || "") || null,
    });
    if (result.error) throw result.error;
    const requestId = result.data && result.data.request_id;
    const fileInput = $("funding-file");
    if (requestId && fileInput && fileInput.files && fileInput.files[0]) {
      const file = fileInput.files[0];
      if (file.size > 10 * 1024 * 1024) throw new Error("附件不能超过 10MB");
      const path = String(DB.profile.id) + "/" + requestId + "/" + file.name;
      const upload = await cloudClient.storage.from("funding-attachments").upload(path, file, { upsert: true });
      if (upload.error) throw upload.error;
      await cloudClient.rpc("set_funding_attachment", { p_request: requestId, p_path: path });
    }
    closeSheet();
    toast("资金申请已提交");
    fundingState.tab = "mine";
    await loadFunding(true);
  } catch (error) {
    toast(fundingErrorText(error));
  }
}

async function decideFunding(requestId, approve) {
  const note = approve ? "" : (prompt("驳回原因（可选）") || "");
  try {
    const result = await cloudClient.rpc("decide_funding_approval", {
      p_request: requestId, p_approve: approve, p_note: note,
    });
    if (result.error) throw result.error;
    toast(approve ? "已批准" : "已驳回");
    await loadFunding(true);
  } catch (error) { toast(fundingErrorText(error)); }
}

async function markFundingPaid(requestId) {
  try {
    const result = await cloudClient.rpc("mark_funding_paid", { p_request: requestId });
    if (result.error) throw result.error;
    toast("已标记支付");
    await loadFunding(true);
  } catch (error) { toast(fundingErrorText(error)); }
}

async function settleFunding(requestId) {
  try {
    const result = await cloudClient.rpc("settle_funding_request", { p_request: requestId });
    if (result.error) throw result.error;
    toast("已核销");
    await loadFunding(true);
  } catch (error) { toast(fundingErrorText(error)); }
}

function openFundingPoolSheet() {
  openSheet("新建资金池", `
    <label for="funding-pool-name">名称</label>
    <input id="funding-pool-name" maxlength="100" placeholder="例如：Q4 专项经费">
    <label for="funding-pool-purpose">用途</label>
    <textarea id="funding-pool-purpose" maxlength="1000"></textarea>
    <label for="funding-pool-total">总额（元）</label>
    <input id="funding-pool-total" type="number" min="0" step="0.01">
  `, [
    { label: "取消", kind: "ghost", onClick: closeSheet },
    { label: "创建", kind: "", onClick: submitFundingPool },
  ]);
}

async function submitFundingPool() {
  try {
    const result = await cloudClient.rpc("create_funding_pool", {
      p_name: String(($("funding-pool-name") || {}).value || "").trim(),
      p_purpose: String(($("funding-pool-purpose") || {}).value || ""),
      p_total: Number(($("funding-pool-total") || {}).value || 0),
      p_project: null,
    });
    if (result.error) throw result.error;
    closeSheet();
    toast("资金池已创建");
    await loadFunding(true);
  } catch (error) { toast(fundingErrorText(error)); }
}

function bindFundingEvents() {
  if ($("btn-funding-create")) $("btn-funding-create").onclick = openFundingRequestSheet;
  if ($("btn-funding-refresh")) $("btn-funding-refresh").onclick = () => loadFunding(true);
  if ($("btn-funding-pool")) {
    $("btn-funding-pool").onclick = () => {
      if (!fundingState.settings || !fundingState.settings.can_manage) {
        toast("只有老板/财务能创建资金池");
        return;
      }
      openFundingPoolSheet();
    };
  }
}
