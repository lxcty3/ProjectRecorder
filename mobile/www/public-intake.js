"use strict";

const PUBLIC_SUPABASE_URL = String(
  window.PROJECT_RECORDER_GATEWAY_URL
    || "https://edchntmyqqjqvpngylgc.supabase.co"
).replace(/\/+$/, "");
const PUBLIC_SUPABASE_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImVkY2hudG15cXFqcXZwbmd5bGdjIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTE1ODY5ODksImV4cCI6MjEwNzE2Mjk4OX0.6vfi2zxvdbmdLSHoV2U0r4R8zd10UCtO5XGaToqBc7I";

const $ = id => document.getElementById(id);
const token = new URL(location.href).searchParams.get("token") || "";

async function publicRpc(name, payload) {
  const response = await fetch(`${PUBLIC_SUPABASE_URL}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers: {
      apikey: PUBLIC_SUPABASE_KEY,
      Authorization: `Bearer ${PUBLIC_SUPABASE_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(payload || {}),
  });
  let data = {};
  try { data = await response.json(); } catch (error) {}
  if (!response.ok) {
    throw new Error(data.message || data.error || "提交失败，请稍后再试。");
  }
  if (data && data.ok === false) {
    throw new Error(data.error || "请求未完成。");
  }
  return data || {};
}

function typeLabel(value) {
  return {
    customer: "客户需求", sales: "销售机会", improvement: "内部改进",
    incident: "故障", temporary: "临时事项",
  }[value] || value;
}

function statusLabel(value) {
  return {
    submitted: "待分诊", triage: "分诊中", in_progress: "处理中",
    resolved: "已解决", closed: "已关闭", merged: "已合并",
  }[value] || value || "—";
}

function escapeHtml(value) {
  return String(value || "").replace(/[&<>"']/g, char => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
  }[char]));
}

async function loadPublicForm() {
  if (!token) {
    $("form-sub").textContent = "这个表单链接无效。";
    $("submit-request").disabled = true;
    return;
  }
  try {
    const data = await publicRpc("get_public_intake_form", { p_token: token });
    $("form-title").textContent = data.form_name || "提交需求";
    $("form-sub").textContent = `${data.enterprise_name || "项目组"} · 公开需求入口`;
    const select = $("request-type");
    select.innerHTML = "";
    (data.allowed_types || ["customer", "sales", "improvement", "incident", "temporary"])
      .forEach(type => {
        const option = document.createElement("option");
        option.value = type;
        option.textContent = typeLabel(type);
        select.appendChild(option);
      });
  } catch (error) {
    $("form-sub").textContent = error.message;
    $("submit-request").disabled = true;
  }
}

async function submitPublicForm(event) {
  event.preventDefault();
  $("form-error").textContent = "";
  $("submit-result").classList.add("hidden");
  const button = $("submit-request");
  button.disabled = true;
  try {
    const result = await publicRpc("submit_public_intake", {
      p_token: token,
      p_data: {
        requester_name: $("requester-name").value.trim(),
        requester_email: $("requester-email").value.trim(),
        request_type: $("request-type").value,
        title: $("request-title").value.trim(),
        detail: $("request-detail").value.trim(),
        consent: $("request-consent").checked,
      },
    });
    $("submit-result").innerHTML = `
      <div>提交成功。请保存申请编号和邮箱，用于查询进度。</div>
      <div class="code">${escapeHtml(result.tracking_code)}</div>
      <div class="meta">需求编号 ${escapeHtml(result.request_no)} · 预计响应 ${escapeHtml(String(result.sla_due_at || "").replace("T", " ").slice(0, 16))}</div>
      ${result.duplicate_count ? `<div class="note">系统发现 ${Number(result.duplicate_count)} 个相似需求，协调员会核实是否合并。</div>` : ""}`;
    $("submit-result").classList.remove("hidden");
    $("tracking-code").value = result.tracking_code || "";
    $("status-email").value = $("requester-email").value.trim();
    $("public-form").reset();
  } catch (error) {
    $("form-error").textContent = error.message;
  } finally {
    button.disabled = false;
  }
}

async function lookupStatus() {
  const code = $("tracking-code").value.trim();
  const email = $("status-email").value.trim();
  $("status-error").textContent = "";
  $("status-result").classList.add("hidden");
  if (!code || !email) {
    $("status-error").textContent = "申请编号和邮箱都要填写。";
    return;
  }
  try {
    const data = await publicRpc("get_public_intake_status", {
      p_tracking_code: code, p_email: email,
    });
    const messages = Array.isArray(data.messages) ? data.messages : [];
    $("status-result").innerHTML = `
      <div><b>${escapeHtml(data.title || "需求")}</b></div>
      <div class="meta">${escapeHtml(data.request_no || "")} · ${escapeHtml(typeLabel(data.request_type))} · ${escapeHtml(statusLabel(data.status))}</div>
      <div class="note">创建 ${escapeHtml(String(data.created_at || "").replace("T", " ").slice(0, 16))} · 预计响应 ${escapeHtml(String(data.sla_due_at || "").replace("T", " ").slice(0, 16))}</div>
      ${messages.length ? messages.map(row => `<div class="message"><div>${escapeHtml(row.body)}</div><div class="meta">${escapeHtml(String(row.created_at || "").replace("T", " ").slice(0, 16))}</div></div>`).join("") : '<div class="message meta">暂无公开进展。</div>'}`;
    $("status-result").classList.remove("hidden");
  } catch (error) {
    $("status-error").textContent = error.message;
  }
}

$("public-form").addEventListener("submit", submitPublicForm);
$("lookup-status").addEventListener("click", lookupStatus);
$("clear-form").addEventListener("click", () => {
  $("public-form").reset();
  $("form-error").textContent = "";
});
loadPublicForm();
