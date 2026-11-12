/* =============================================================
   职业等级 · v1
   L1-L5；每个等级对应一组固定岗位。
   人的职级独立，任命岗位时要求 人的职级 >= 岗位职级。
   ============================================================= */
"use strict";

let careerState = {
  data: null,
  customRoles: [],
  loading: false,
  error: "",
  lastLoad: 0,
};

const CAREER_LEVEL_NAMES = Object.freeze({
  1: "L1 初级",
  2: "L2 中级",
  3: "L3 高级",
  4: "L4 资深",
  5: "L5 专家",
});

function careerLevelLabel(level) {
  const value = Number(level) || 1;
  return CAREER_LEVEL_NAMES[value] || ("L" + value);
}

function careerLevelOf(profileId) {
  const data = careerState.data;
  if (!data || !Array.isArray(data.members)) return 0;
  const row = data.members.find(member =>
    String(member.profile_id) === String(profileId));
  return row ? Number(row.career_level) || 1 : 0;
}

function careerLevelAtLeast(level) {
  const me = careerState.data && careerState.data.me;
  return !!me && Number(me.career_level) >= Number(level);
}

function careerErrorText(error) {
  const text = String(error && error.message || error || "");
  if (/could not find|does not exist|function/i.test(text)) return "职业等级还没注入 SQL";
  if (/not allowed/i.test(text)) return "当前身份不能操作职业等级";
  if (/unchanged/i.test(text)) return "职级没有变化";
  if (/pending/i.test(text)) return "该成员已有待审批的职级变更";
  if (/not pending/i.test(text)) return "这条申请已经处理过了";
  if (/level must/i.test(text)) return "职级必须在 1–5 之间";
  if (/career role name must/i.test(text)) return "职业名称请控制在 2–40 字";
  if (/already exists/i.test(text)) return "同名职业已存在";
  if (/career role not found/i.test(text)) return "这个职业不存在";
  if (/not allowed to manage career roles/i.test(text)) return "当前身份不能创建职业";
  return text || "职业等级操作失败";
}

async function loadCareerLevels(force) {
  if (!DB.profile || !initCloud()) return;
  const now = Date.now();
  if (!force && careerState.lastLoad && now - careerState.lastLoad < 10000) {
    renderCareerLevels();
    return;
  }
  careerState.loading = true;
  careerState.error = "";
  renderCareerLevels();
  try {
    const stateResult = await cloudClient.rpc("get_career_level_state", {});
    if (stateResult.error) throw stateResult.error;
    careerState.data = stateResult.data || null;
    const rolesResult = await cloudClient.rpc("list_career_roles", {});
    careerState.customRoles = (!rolesResult.error
      && Array.isArray(rolesResult.data && rolesResult.data.roles))
      ? rolesResult.data.roles : [];
    careerState.lastLoad = Date.now();
  } catch (error) {
    careerState.error = careerErrorText(error);
  } finally {
    careerState.loading = false;
    renderCareerLevels();
    if (typeof renderIdentityMembers === "function"
        && typeof identityState === "function") {
      renderIdentityMembers(identityState());
    }
  }
}

function careerRoleChips(roles) {
  return roles.map(role =>
    '<span class="career-role-chip">' + escapeHtml(identityRoleLabel(role.role_key))
    + '</span>').join("");
}

function renderCareerLevels() {
  const box = $("career-level-panel");
  if (!box) return;
  const data = careerState.data;
  if (careerState.loading && !data) {
    box.innerHTML = '<div class="meta">正在加载职业等级…</div>';
    return;
  }
  if (careerState.error && !data) {
    box.innerHTML = '<div class="meta">' + escapeHtml(careerState.error) + '</div>';
    return;
  }
  if (!data) {
    box.innerHTML = '<div class="meta">登录后查看职业等级。</div>';
    return;
  }
  const me = data.me || {};
  const levels = Array.isArray(data.levels) ? data.levels : [];
  const roles = Array.isArray(data.roles) ? data.roles : [];
  const members = Array.isArray(data.members) ? data.members : [];
  const requests = Array.isArray(data.requests) ? data.requests : [];
  const customRoles = Array.isArray(careerState.customRoles) ? careerState.customRoles : [];
  const byLevel = {};
  roles.forEach(role => {
    const level = Number(role.level) || 1;
    (byLevel[level] = byLevel[level] || []).push(role);
  });
  const customByLevel = {};
  const customByMember = {};
  customRoles.forEach(role => {
    const level = Number(role.level) || 1;
    (customByLevel[level] = customByLevel[level] || []).push(role);
    (role.assigned_members || []).forEach(member => {
      customByMember[String(member.profile_id)] = role;
    });
  });
  const ladder = levels.map(level => {
    const current = Number(me.career_level) === Number(level.level);
    const fixedChips = careerRoleChips(byLevel[level.level] || []);
    const customChips = (customByLevel[level.level] || []).map(role =>
      '<span class="career-role-chip custom">' + escapeHtml(role.name)
      + '</span>').join("");
    return '<div class="career-level' + (current ? " current" : "") + '">'
      + '<div class="career-level-head"><b>' + escapeHtml(level.name) + '</b>'
      + '<span>' + (current ? "我的职级" : "") + '</span></div>'
      + '<div class="career-level-roles">' + fixedChips + customChips + '</div></div>';
  }).join("");
  const memberRows = members.map(member => {
    const custom = customByMember[String(member.profile_id)];
    return '<div class="career-member-row">'
      + '<span class="career-member-name">' + escapeHtml(member.name || "成员") + '</span>'
      + '<span class="career-badge">' + careerLevelLabel(member.career_level)
      + (custom ? ' · ' + escapeHtml(custom.name) : '') + '</span>'
      + '<span class="meta">' + escapeHtml(identityRoleLabel(member.role_key)) + '</span>'
      + (me.can_manage && Number(member.career_level) < 5
        ? '<button class="community-link-btn" data-career-request="'
          + escapeHtml(member.profile_id) + '" data-career-current="'
          + Number(member.career_level) + '">调整职级</button>'
        : '')
      + (me.can_manage && customRoles.length
        ? '<button class="community-link-btn" data-career-assign="'
          + escapeHtml(member.profile_id) + '">分配职业</button>'
        : '')
      + '</div>';
  }).join("");
  const requestRows = requests.map(request => '<div class="career-request-row">'
    + '<div class="career-request-copy"><b>' + escapeHtml(request.name || "成员") + '</b>'
    + '<span class="meta">' + careerLevelLabel(request.current_level) + ' → '
    + careerLevelLabel(request.requested_level) + '</span>'
    + (request.reason ? '<small>' + escapeHtml(request.reason) + '</small>' : '')
    + '</div>'
    + (me.can_approve
      ? '<div class="career-request-actions">'
        + '<button class="btn ghost" data-career-decide="' + escapeHtml(request.id)
        + '" data-career-approve="0">驳回</button>'
        + '<button class="btn" data-career-decide="' + escapeHtml(request.id)
        + '" data-career-approve="1">批准</button></div>'
      : '<span class="meta">待审批</span>')
    + '</div>').join("");
  box.innerHTML = '<div class="career-me">'
    + '<div><span class="meta">我的职级</span>'
    + '<b class="career-big">' + careerLevelLabel(me.career_level) + '</b>'
    + '<span class="meta">岗位职级 ' + careerLevelLabel(me.role_level)
    + ' · ' + escapeHtml(identityRoleLabel(me.role_key)) + '</span></div>'
    + (me.can_manage
      ? '<button class="btn ghost" id="btn-create-career-role">创建职业</button>'
      : '')
    + '</div>'
    + '<div class="career-ladder">' + ladder + '</div>'
    + (me.can_manage || me.can_approve
      ? '<div class="section-head"><span>成员职级</span><span class="meta">'
        + members.length + ' 人</span></div><div class="career-members">'
        + memberRows + '</div>'
      : '')
    + (requests.length
      ? '<div class="section-head"><span>待审批晋升</span><span class="meta">'
        + requests.length + ' 项</span></div><div class="career-requests">'
        + requestRows + '</div>'
      : '');
  const create = $("btn-create-career-role");
  if (create) create.onclick = openCreateCareerRoleSheet;
  box.querySelectorAll("[data-career-request]").forEach(button => {
    button.onclick = () => openCareerRequestSheet(
      button.dataset.careerRequest, Number(button.dataset.careerCurrent || 1));
  });
  box.querySelectorAll("[data-career-assign]").forEach(button => {
    button.onclick = () => openAssignCareerRoleSheet(button.dataset.careerAssign);
  });
  box.querySelectorAll("[data-career-decide]").forEach(button => {
    button.onclick = () => decideCareerRequest(
      button.dataset.careerDecide, button.dataset.careerApprove === "1");
  });
}

function openCareerRequestSheet(profileId, currentLevel) {
  const data = careerState.data || {};
  const member = (data.members || []).find(row =>
    String(row.profile_id) === String(profileId));
  if (!member) return;
  const options = [1, 2, 3, 4, 5].map(level =>
    '<option value="' + level + '"' + (level === currentLevel ? " selected" : "")
    + '>' + careerLevelLabel(level) + '</option>').join("");
  openSheet("调整职级", `
    <div class="hint">${escapeHtml(member.name || "成员")} · 当前 ${careerLevelLabel(currentLevel)}</div>
    <label for="career-target">目标职级</label>
    <select id="career-target">${options}</select>
    <label for="career-reason">原因</label>
    <textarea id="career-reason" maxlength="1000" placeholder="为什么调整"></textarea>
  `, [
    { label: "取消", kind: "ghost", onClick: closeSheet },
    { label: "提交审批", kind: "", onClick: () => submitCareerRequest(profileId) },
  ]);
}

async function submitCareerRequest(profileId) {
  const level = Number(($("career-target") || {}).value || 1);
  const reason = String(($("career-reason") || {}).value || "");
  try {
    const result = await cloudClient.rpc("request_career_level_change", {
      p_profile: profileId, p_level: level, p_reason: reason,
    });
    if (result.error) throw result.error;
    closeSheet();
    toast("已提交职级变更，等待审批");
    await loadCareerLevels(true);
  } catch (error) {
    toast(careerErrorText(error));
  }
}

async function decideCareerRequest(requestId, approve) {
  const reason = approve ? "" : (prompt("驳回原因（可选）") || "");
  try {
    const result = await cloudClient.rpc("decide_career_level_request", {
      p_request: requestId, p_approve: approve, p_reason: reason,
    });
    if (result.error) throw result.error;
    toast(approve ? "已批准晋升" : "已驳回");
    await loadCareerLevels(true);
  } catch (error) {
    toast(careerErrorText(error));
  }
}

function openCreateCareerRoleSheet() {
  const options = [1, 2, 3, 4, 5].map(level =>
    '<option value="' + level + '">' + careerLevelLabel(level) + '</option>').join("");
  openSheet("创建职业", `
    <label for="career-role-name">职业名称</label>
    <input id="career-role-name" maxlength="40" placeholder="例如：UI 设计师">
    <label for="career-role-level">对应职级</label>
    <select id="career-role-level">${options}</select>
    <label for="career-role-desc">说明（可选）</label>
    <textarea id="career-role-desc" maxlength="500" placeholder="这个职业负责什么"></textarea>
  `, [
    { label: "取消", kind: "ghost", onClick: closeSheet },
    { label: "创建", kind: "", onClick: submitCreateCareerRole },
  ]);
}

async function submitCreateCareerRole() {
  const name = String(($("career-role-name") || {}).value || "").trim();
  const level = Number(($("career-role-level") || {}).value || 1);
  const desc = String(($("career-role-desc") || {}).value || "");
  if (!name) { toast("先写职业名称"); return; }
  try {
    const result = await cloudClient.rpc("create_career_role", {
      p_name: name, p_level: level, p_description: desc,
    });
    if (result.error) throw result.error;
    closeSheet();
    toast("职业已创建");
    await loadCareerLevels(true);
  } catch (error) {
    toast(careerErrorText(error));
  }
}

function openAssignCareerRoleSheet(profileId) {
  const roles = Array.isArray(careerState.customRoles) ? careerState.customRoles : [];
  const member = ((careerState.data && careerState.data.members) || [])
    .find(row => String(row.profile_id) === String(profileId));
  if (!roles.length) { toast("先创建一个职业"); return; }
  const options = roles.map(role =>
    '<option value="' + escapeHtml(role.id) + '">' + escapeHtml(role.name)
    + ' · ' + careerLevelLabel(role.level) + '</option>').join("");
  openSheet("分配职业", `
    <div class="hint">${escapeHtml(member ? member.name : "成员")}</div>
    <label for="career-assign-role">选择职业</label>
    <select id="career-assign-role">${options}</select>
  `, [
    { label: "取消", kind: "ghost", onClick: closeSheet },
    { label: "分配", kind: "", onClick: () => assignCareerRole(profileId) },
  ]);
}

async function assignCareerRole(profileId) {
  const roleId = String(($("career-assign-role") || {}).value || "");
  if (!roleId) return;
  try {
    const result = await cloudClient.rpc("assign_career_role", {
      p_profile: profileId, p_role: roleId,
    });
    if (result.error) throw result.error;
    closeSheet();
    toast("职业已分配");
    await loadCareerLevels(true);
  } catch (error) {
    toast(careerErrorText(error));
  }
}

function bindCareerEvents() {

  if (typeof renderCareerLevels === "function") renderCareerLevels();
}
