"use strict";

/* Phase 4 work intake: quick capture, public forms, triage, merge, conversion. */

let intakeBusy = false;

function emptyIntakeState() {
  return {
    myRequests: [], requests: [], forms: [], members: [], projects: [],
    tasks: [], emailAliases: [], settings: {}, access: {}, at: 0,
  };
}

function intakeState() {
  if (!DB.intake || typeof DB.intake !== "object") DB.intake = emptyIntakeState();
  ["myRequests", "requests", "forms", "members", "projects", "tasks"]
    .forEach(key => { if (!Array.isArray(DB.intake[key])) DB.intake[key] = []; });
  if (!DB.intake.access || typeof DB.intake.access !== "object") DB.intake.access = {};
  if (!DB.intake.settings || typeof DB.intake.settings !== "object") DB.intake.settings = {};
  return DB.intake;
}

function clearIntakeManagementCache() {
  const state = intakeState();
  state.requests = [];
  state.forms = [];
  state.members = [];
  state.projects = [];
  state.tasks = [];
  state.access = {};
  state.at = 0;
  if (typeof saveAll === "function") saveAll();
  if (typeof renderIntake === "function") renderIntake();
}

function clearIntakeCache() {
  DB.intake = emptyIntakeState();
  if (typeof saveAll === "function") saveAll();
  if (typeof renderIntake === "function") renderIntake();
}

async function intakeRpc(name, params) {
  if (!initCloud()) throw new Error("云组件没有加载");
  const { data, error } = await cloudClient.rpc(name, params || {});
  if (error) throw error;
  if (data && typeof data === "object" && data.ok === false) {
    throw new Error(data.error || "工作入口操作没有权限");
  }
  return data;
}

function intakeTypeLabel(value) {
  return {
    customer: "客户需求", sales: "销售机会", improvement: "内部改进",
    incident: "故障", temporary: "临时事项",
  }[String(value || "")] || String(value || "—");
}

function intakeStatusLabel(value) {
  return {
    submitted: "待分诊", triage: "分诊中", in_progress: "处理中",
    resolved: "已解决", closed: "已关闭", merged: "已合并",
  }[String(value || "")] || String(value || "—");
}

function intakeDate(value) {
  const text = String(value || "");
  return text ? text.slice(0, 16).replace("T", " ") : "—";
}

function intakeEmpty(text) {
  return `<div class="identity-empty"><b>暂无记录</b><span>${escapeHtml(text)}</span></div>`;
}

function intakeActionButton(action, id, label, className) {
  return `<button class="btn ${className || "ghost"} intake-action"
    data-intake-action="${escapeHtml(action)}"
    data-id="${escapeHtml(String(id || ""))}">${escapeHtml(label)}</button>`;
}

function intakeMemberOptions(selected) {
  return intakeState().members.map(member => {
    const id = escapeHtml(String(member.id || ""));
    return `<option value="${id}"${String(member.id) === String(selected) ? " selected" : ""}>`;
  }).join("");
}

function renderIntake() {
  if (!$("intake-summary")) return;
  const state = intakeState();
  const management = !!state.access.management;
  const pending = state.requests.filter(item => item.status === "submitted").length;
  const overdue = state.requests.filter(item => item.sla_overdue).length;
  $("intake-summary").innerHTML = `
    <div class="decision-summary-card"><span>我的需求</span><b>${state.myRequests.length}</b></div>
    <div class="decision-summary-card ${pending ? "is-watch" : ""}"><span>待分诊</span><b>${pending}</b></div>
    <div class="decision-summary-card ${overdue ? "is-severe" : ""}"><span>SLA 超时</span><b>${overdue}</b></div>`;
  if ($("intake-admin-tools")) $("intake-admin-tools").classList.toggle("hidden", !management);
  if ($("intake-management")) $("intake-management").classList.toggle("hidden", !management);
  if ($("intake-forms-wrap")) $("intake-forms-wrap").classList.toggle("hidden", !management);

  $("intake-forms").innerHTML = state.forms.length
    ? state.forms.map(form => `<article class="execution-card">
        <div class="execution-card-head"><div><b>${escapeHtml(form.name || "公开表单")}</b>
          <div class="meta">${escapeHtml(form.public_url || "尚未设置公开地址")}</div></div>
          <span class="execution-state">${form.active ? "启用" : "停用"}</span></div>
        <div class="execution-actions">
          <button class="btn ghost intake-action" data-intake-action="copy-form" data-id="${escapeHtml(String(form.id || ""))}">复制链接</button>
          <button class="btn ghost intake-action" data-intake-action="qr-form" data-id="${escapeHtml(String(form.id || ""))}">二维码</button>
        </div></article>`).join("")
    : intakeEmpty("新建公开表单后，外部客户可以通过链接或二维码提交需求。");

  if ($("intake-email-aliases")) {
    $("intake-email-aliases").textContent = state.emailAliases.length
      ? "邮件入口：" + state.emailAliases.map(row => row.email_address).filter(Boolean).join(" · ")
      : "尚未创建邮件入口。";
  }

  $("intake-requests").innerHTML = state.requests.length
    ? state.requests.map(item => {
      const links = Array.isArray(item.links) ? item.links.length : 0;
      return `<article class="execution-card ${item.sla_overdue ? "is-blocked" : ""}">
        <div class="execution-card-head"><div><b>${escapeHtml(item.title || "需求")}</b>
          <div class="meta">${escapeHtml(item.request_no || "—")} · ${escapeHtml(intakeTypeLabel(item.request_type))}
            · ${escapeHtml(item.owner_name || "未分诊")}</div></div>
          <span class="execution-state">${escapeHtml(intakeStatusLabel(item.status))}</span></div>
        <div class="execution-field"><span>优先级</span><p>${Math.round(Number(item.priority_score) || 0)}
          ${item.sla_overdue ? " · SLA 已超时" : ""}${links ? ` · 关联 ${links}` : ""}</p></div>
        <div class="execution-field"><span>提出人</span><p>${escapeHtml(item.requester_name || "—")}</p></div>
        <div class="execution-actions">
          ${intakeActionButton("triage", item.id, "分诊")}
          ${intakeActionButton("convert", item.id, "转入执行")}
          ${intakeActionButton("merge", item.id, "合并重复")}
          ${intakeActionButton("message", item.id, "回复/备注")}
        </div></article>`;
    }).join("")
    : intakeEmpty("暂无待分诊需求。");

  $("intake-mine").innerHTML = state.myRequests.length
    ? state.myRequests.map(item => `<article class="execution-card">
        <div class="execution-card-head"><div><b>${escapeHtml(item.title || "需求")}</b>
          <div class="meta">${escapeHtml(item.request_no || "—")} · ${escapeHtml(intakeTypeLabel(item.request_type))}</div></div>
          <span class="execution-state">${escapeHtml(intakeStatusLabel(item.status))}</span></div>
        ${(item.messages || []).length ? `<div class="execution-field"><span>公开进展</span><p>${escapeHtml(item.messages[item.messages.length - 1].body || "")}</p></div>` : ""}
      </article>`).join("")
    : intakeEmpty("快速记录后会出现在这里。");
}

async function loadIntake(force) {
  if (!DB.profile || !initCloud()) return;
  const state = intakeState();
  if (!force && state.at && Date.now() - state.at < 30000) {
    renderIntake();
    return;
  }
  if (intakeBusy) return;
  intakeBusy = true;
  try {
    const management = typeof identityHasManagementView === "function"
      ? identityHasManagementView() : false;
    const mine = await intakeRpc("get_my_intake_requests", {});
    let board = {};
    if (management) {
      try { board = await intakeRpc("get_intake_board", {}); } catch (error) { board = {}; }
    }
    state.myRequests = mine.requests || [];
    state.requests = board.requests || [];
    state.forms = board.forms || [];
    state.members = board.members || [];
    state.projects = board.projects || [];
    state.tasks = board.tasks || [];
    state.emailAliases = board.email_aliases || [];
    state.settings = board.settings || {};
    state.access = board.access || {};
    state.at = Date.now();
    if (typeof saveAll === "function") saveAll();
    renderIntake();
  } catch (error) {
    toast(String((error && error.message) || error));
  } finally {
    intakeBusy = false;
  }
}

function openIntakeQuick() {
  openSheet("快速记录", `
    <label for="intake-quick-type">类型</label>
    <select id="intake-quick-type">
      <option value="customer">客户需求</option><option value="sales">销售机会</option>
      <option value="improvement">内部改进</option><option value="incident">故障</option>
      <option value="temporary">临时事项</option>
    </select>
    <label for="intake-quick-title">标题</label>
    <input id="intake-quick-title" maxlength="120" placeholder="一句话说明要处理什么">
    <label for="intake-quick-detail">详情</label>
    <textarea id="intake-quick-detail" maxlength="4000" placeholder="背景、期望结果和截止时间"></textarea>
    <div class="row2">
      <div><label for="intake-business">业务价值</label><input id="intake-business" type="number" min="0" max="5" value="0"></div>
      <div><label for="intake-urgency">紧急度</label><input id="intake-urgency" type="number" min="0" max="5" value="0"></div>
    </div>
    <div class="row2">
      <div><label for="intake-risk">风险</label><input id="intake-risk" type="number" min="0" max="5" value="0"></div>
      <div><label for="intake-dependency">依赖影响</label><input id="intake-dependency" type="number" min="0" max="5" value="0"></div>
    </div>
    <label for="intake-effort">投入成本</label>
    <input id="intake-effort" type="number" min="0" max="5" value="0">
    <div class="community-note">优先级由服务端按五项因素计算，并在队列里展示依据。</div>
  `, [
    { label: "取消", onClick: closeSheet },
    { label: "提交", kind: "", onClick: submitIntakeQuick },
  ]);
}

async function submitIntakeQuick() {
  const title = $("intake-quick-title").value.trim();
  const detail = $("intake-quick-detail").value.trim();
  if (!title || detail.length < 5) { toast("标题和详情都要填写"); return; }
  const result = await intakeRpc("create_intake_request", { p_data: {
    title, detail, request_type: $("intake-quick-type").value, source_type: "quick",
    business_value: Number($("intake-business").value) || 0,
    urgency: Number($("intake-urgency").value) || 0,
    risk: Number($("intake-risk").value) || 0,
    dependency_impact: Number($("intake-dependency").value) || 0,
    effort: Number($("intake-effort").value) || 0,
  }});
  closeSheet();
  toast(result.duplicates && result.duplicates.length
    ? `已提交，发现 ${result.duplicates.length} 个相似需求`
    : "快速记录已提交");
  await loadIntake(true);
}

function openIntakeFormCreate() {
  openSheet("新建公开表单", `
    <label for="intake-form-name">表单名称</label>
    <input id="intake-form-name" maxlength="120" value="客户需求入口">
    <div class="community-note">公开页面只显示公司名称、表单名称和允许的需求类型，不显示内部项目或员工信息。</div>
  `, [
    { label: "取消", onClick: closeSheet },
    { label: "创建", kind: "", onClick: async () => {
      const result = await intakeRpc("create_intake_form", {
        p_data: { name: $("intake-form-name").value.trim() || "客户需求入口" },
      });
      closeSheet();
      toast("公开表单已创建");
      if (result.public_url) {
        try { await navigator.clipboard.writeText(result.public_url); } catch (error) {}
      }
      await loadIntake(true);
    } },
  ]);
}

function openIntakeEmailAlias() {
  openSheet("新建邮件入口", `
    <label for="intake-email-label">入口名称</label>
    <input id="intake-email-label" maxlength="120" value="客户邮件">
    <div class="community-note">系统会生成 intake+随机令牌@收件域名。把生成的地址配置到邮件转发网关即可。</div>
  `, [
    { label: "取消", onClick: closeSheet },
    { label: "创建", kind: "", onClick: async () => {
      await intakeRpc("create_intake_email_alias", {
        p_label: $("intake-email-label").value.trim(),
      });
      closeSheet(); toast("邮件入口已创建"); await loadIntake(true);
    } },
  ]);
}

function openIntakeSettings() {
  const settings = intakeState().settings || {};
  openSheet("入口设置", `
    <label for="intake-settings-url">公开表单站点地址</label>
    <input id="intake-settings-url" value="${escapeHtml(settings.public_form_base_url || "")}" placeholder="https://example.com/project-recorder">
    <label for="intake-settings-domain">收件域名</label>
    <input id="intake-settings-domain" value="${escapeHtml(settings.email_domain || "inbound.projectrecorder.local")}">
    <div class="community-note">公开链接会使用站点地址加 /intake.html?token=...；邮件地址会使用 intake+令牌@收件域名。</div>
  `, [
    { label: "取消", onClick: closeSheet },
    { label: "保存", kind: "", onClick: async () => {
      await intakeRpc("upsert_intake_settings", { p_data: {
        public_form_base_url: $("intake-settings-url").value.trim(),
        email_domain: $("intake-settings-domain").value.trim(),
      }});
      closeSheet(); toast("入口设置已保存"); await loadIntake(true);
    } },
  ]);
}

function intakeFormById(id) {
  return intakeState().forms.find(form => String(form.id) === String(id)) || null;
}

async function intakeCopyForm(id) {
  const form = intakeFormById(id);
  if (!form || !form.public_url) { toast("没有公开链接"); return; }
  try {
    await navigator.clipboard.writeText(form.public_url);
    toast("公开链接已复制");
  } catch (error) {
    toast(form.public_url);
  }
}

function intakeShowQr(id) {
  const form = intakeFormById(id);
  if (!form || !form.public_url) { toast("没有公开链接"); return; }
  openSheet("公开表单二维码", `
    <div id="intake-qr" class="qr-wrap"></div>
    <div class="community-note">${escapeHtml(form.public_url)}</div>
  `, [{ label: "关闭", onClick: closeSheet }]);
  if (typeof QRCode === "function") {
    const holder = $("intake-qr");
    holder.innerHTML = "";
    new QRCode(holder, { text: form.public_url, width: 220, height: 220 });
  } else {
    $("intake-qr").textContent = "未加载二维码组件，请复制上方链接。";
  }
}

function openIntakeTriage(item) {
  const memberOptions = intakeState().members.map(member => {
    const selected = String(member.id) === String(item.owner_profile_id) ? " selected" : "";
    return `<option value="${escapeHtml(String(member.id || ""))}"${selected}>${escapeHtml(member.name || "成员")}</option>`;
  }).join("");
  openSheet("分诊需求", `
    <label for="intake-triage-owner">负责人</label>
    <select id="intake-triage-owner"><option value="">未指定</option>${memberOptions}</select>
    <label for="intake-triage-type">类型</label>
    <select id="intake-triage-type">
      ${["customer", "sales", "improvement", "incident", "temporary"].map(type => `<option value="${type}"${item.request_type === type ? " selected" : ""}>${escapeHtml(intakeTypeLabel(type))}</option>`).join("")}
    </select>
    <label for="intake-triage-status">状态</label>
    <select id="intake-triage-status">
      <option value="triage">分诊中</option><option value="in_progress">处理中</option>
      <option value="resolved">已解决</option><option value="closed">已关闭</option>
    </select>
    <label for="intake-triage-priority">优先级覆盖</label>
    <input id="intake-triage-priority" type="number" min="0" max="100" value="${Number(item.priority_score) || 0}">
    <label for="intake-triage-reason">覆盖理由</label>
    <textarea id="intake-triage-reason" maxlength="500" placeholder="覆盖优先级时必须填写"></textarea>
  `, [
    { label: "取消", onClick: closeSheet },
    { label: "保存", kind: "", onClick: async () => {
      const priority = Number($("intake-triage-priority").value) || 0;
      const original = Number(item.priority_score) || 0;
      const reason = $("intake-triage-reason").value.trim();
      const changed = priority !== original;
      if (changed && !reason) { toast("覆盖优先级必须填写理由"); return; }
      await intakeRpc("triage_intake_request", {
        p_request: item.id,
        p_owner: $("intake-triage-owner").value || null,
        p_request_type: $("intake-triage-type").value,
        p_priority_override: changed ? priority : null,
        p_reason: reason,
        p_status: $("intake-triage-status").value,
      });
      closeSheet(); toast("分诊已保存"); await loadIntake(true);
    } },
  ]);
}

function openIntakeConvert(item) {
  const projects = intakeState().projects;
  const members = intakeState().members;
  const projectOptions = projects.map(project => `<option value="${escapeHtml(String(project.id || ""))}">${escapeHtml(project.name || "项目")}</option>`).join("");
  const memberOptions = members.map(member => `<option value="${escapeHtml(String(member.id || ""))}">${escapeHtml(member.name || "成员")}</option>`).join("");
  openSheet("转入执行", `
    <label for="intake-convert-kind">转换类型</label>
    <select id="intake-convert-kind">
      <option value="project">项目</option><option value="task">任务</option>
      <option value="presales">售前支持</option>
    </select>
    <label for="intake-convert-name">项目名称</label>
    <input id="intake-convert-name" value="${escapeHtml(item.title || "")}" maxlength="120">
    <div class="row2">
      <div><label for="intake-convert-project">项目</label><select id="intake-convert-project">${projectOptions}</select></div>
      <div><label for="intake-convert-employee">负责人</label><select id="intake-convert-employee">${memberOptions}</select></div>
    </div>
    <label for="intake-convert-date">任务计划日期</label>
    <input id="intake-convert-date" type="date" value="${new Date(Date.now() + 86400000).toISOString().slice(0, 10)}">
    <label for="intake-convert-value">售前预估金额</label>
    <input id="intake-convert-value" type="number" min="0" step="0.01" value="0">
    <div class="community-note">转换后需求会保留来源、提出人、消息和验收线索。</div>
  `, [
    { label: "取消", onClick: closeSheet },
    { label: "转换", kind: "", onClick: async () => {
      const kind = $("intake-convert-kind").value;
      let data = {};
      if (kind === "project") {
        data = { name: $("intake-convert-name").value.trim(), note: item.detail || "" };
      } else if (kind === "task") {
        data = {
          title: item.title || "需求任务", detail: item.detail || "",
          project_id: $("intake-convert-project").value,
          employee_id: $("intake-convert-employee").value,
          plan_date: $("intake-convert-date").value,
        };
      } else {
        data = {
          owner_id: $("intake-convert-employee").value,
          estimated_value: Number($("intake-convert-value").value) || 0,
        };
      }
      await intakeRpc("convert_intake_request", {
        p_request: item.id, p_kind: kind, p_data: data,
      });
      closeSheet(); toast("需求已转入执行"); await loadIntake(true);
    } },
  ]);
}

function openIntakeMerge(item) {
  const candidates = intakeState().requests.filter(row => String(row.id) !== String(item.id) && row.status !== "merged");
  if (!candidates.length) { toast("没有可合并的目标需求"); return; }
  openSheet("合并重复", `
    <label for="intake-merge-target">目标需求</label>
    <select id="intake-merge-target">${candidates.map(row => `<option value="${escapeHtml(String(row.id || ""))}">${escapeHtml(row.request_no || "需求")} · ${escapeHtml(row.title || "")}</option>`).join("")}</select>
    <label for="intake-merge-note">合并说明</label>
    <textarea id="intake-merge-note" maxlength="1000"></textarea>
    <div class="community-note">合并会保留来源、提出人和双方沟通记录，不会删除原需求。</div>
  `, [
    { label: "取消", onClick: closeSheet },
    { label: "合并", kind: "", onClick: async () => {
      await intakeRpc("merge_intake_request", {
        p_source: item.id, p_target: $("intake-merge-target").value,
        p_note: $("intake-merge-note").value.trim(),
      });
      closeSheet(); toast("重复需求已合并"); await loadIntake(true);
    } },
  ]);
}

function openIntakeMessage(item) {
  openSheet("回复或备注", `
    <label for="intake-message-body">内容</label>
    <textarea id="intake-message-body" maxlength="4000"></textarea>
    <label class="check"><input id="intake-message-public" type="checkbox" checked> 公开回复给提出人</label>
    <div class="community-note">取消勾选后内容只对内部管理者可见，外部状态页不会返回。</div>
  `, [
    { label: "取消", onClick: closeSheet },
    { label: "发送", kind: "", onClick: async () => {
      const body = $("intake-message-body").value.trim();
      if (!body) { toast("先写点内容"); return; }
      await intakeRpc("add_intake_message", {
        p_request: item.id, p_body: body,
        p_public: $("intake-message-public").checked,
      });
      closeSheet(); toast("消息已发送"); await loadIntake(true);
    } },
  ]);
}

function intakeItemById(id) {
  return intakeState().requests.find(item => String(item.id) === String(id)) || null;
}

function bindIntake() {
  if ($("btn-intake-refresh")) $("btn-intake-refresh").onclick = () => loadIntake(true);
  if ($("btn-intake-quick")) $("btn-intake-quick").onclick = openIntakeQuick;
  if ($("btn-intake-form")) $("btn-intake-form").onclick = openIntakeFormCreate;
  if ($("btn-intake-settings")) $("btn-intake-settings").onclick = openIntakeSettings;
  if ($("btn-intake-email")) $("btn-intake-email").onclick = openIntakeEmailAlias;
  ["intake-requests", "intake-mine", "intake-forms"].forEach(id => {
    const root = $(id);
    if (!root) return;
    root.onclick = event => {
      const button = event.target.closest("[data-intake-action]");
      if (!button) return;
      const action = button.dataset.intakeAction;
      const id = button.dataset.id;
      if (action === "copy-form") { intakeCopyForm(id); return; }
      if (action === "qr-form") { intakeShowQr(id); return; }
      const item = intakeItemById(id);
      if (!item) return;
      if (action === "triage") openIntakeTriage(item);
      if (action === "convert") openIntakeConvert(item);
      if (action === "merge") openIntakeMerge(item);
      if (action === "message") openIntakeMessage(item);
    };
  });
}
