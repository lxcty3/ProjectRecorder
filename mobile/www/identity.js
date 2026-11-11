/* =============================================================
   企业身份与股东投票
   -------------------------------------------------------------
   身份不是前端自己编的：服务端返回角色、权限、股份和投票状态。
   这个文件只负责展示和发起 RPC，真正的权限与计票规则在
   mobile/sql/enterprise-identity.sql。
   ============================================================= */
"use strict";

const IDENTITY_ROLE_LABELS = Object.freeze({
  chairperson: "董事长",
  director: "董事",
  supervisor: "监事",
  ceo: "首席执行官",
  vice_president: "副总裁",
  department_manager: "部门经理",
  project_manager: "项目经理",
  team_lead: "组长",
  finance: "财务",
  hr: "人力资源",
  auditor: "审计",
  employee: "员工",
});

const IDENTITY_PERMISSION_LABELS = Object.freeze({
  "identity.view": "查看企业身份",
  "identity.propose": "发起任免提案",
  "identity.vote": "按股份投票",
  "identity.manage_shares": "调整股份",
  "company.manage": "管理企业",
  "projects.view_all": "查看全部项目",
  "projects.manage": "管理项目",
  "people.view_all": "查看全部成员",
  "people.manage": "管理成员",
  "worklogs.approve": "审核工时",
  "tasks.assign": "分配任务",
  "tasks.grade": "任务评级",
  "rewards.manage": "管理奖励",
  "leave.approve": "审批请假",
  "finance.view": "查看财务",
  "finance.manage": "管理财务",
  "reports.view": "查看经营报表",
  "audit.read": "查看审计信息",
  "community.post": "发布社区消息",
  "identity.manage_templates": "管理身份模板",
  "finance.manage": "管理财务",
  "finance.approve_company": "审批公司财务",
  "governance.manage": "管理治理事项",
  "governance.vote": "参与治理表决",
  "data.export_all": "导出全部数据",
  "data.delete_all": "删除全部数据",
});

const IDENTITY_MOTION_LABELS = Object.freeze({
  open: "投票中",
  passed: "已通过",
  rejected: "未通过",
  cancelled: "已取消",
});

const IDENTITY_MAJOR_ROLES = Object.freeze([
  "chairperson", "director", "supervisor", "ceo", "finance", "identity_admin",
]);

let identityBusy = false;
let identityLastAttempt = 0;
let organizationState = null;
let organizationBusy = false;
let organizationError = "";

function identityRoleLabel(key) {
  return IDENTITY_ROLE_LABELS[String(key || "")] || String(key || "员工");
}

function identityState() {
  return DB.identity && DB.identity.enterprise ? DB.identity : null;
}

function identityMe() {
  const state = identityState();
  return state && state.me ? state.me : null;
}

function identityPermissions() {
  const me = identityMe();
  return me && Array.isArray(me.permissions) ? me.permissions : [];
}

function identityCan(permission) {
  const me = identityMe();
  if (me) return identityPermissions().indexOf(permission) !== -1;
  // 身份接口尚未加载时保持旧版行为，避免老板打开新版本后暂时失去入口。
  return !!(DB.profile && DB.profile.role === "boss");
}

function identityCanAny(permissions) {
  const list = Array.isArray(permissions) ? permissions : [];
  return list.some(permission => identityCan(permission));
}

function identityOwnerId() {
  const state = identityState();
  return state && state.enterprise
    ? state.enterprise.owner_profile_id
    : (DB.profile ? DB.profile.id : "");
}

function identityHasManagementView() {
  return identityCanAny([
    "company.manage", "projects.view_all", "projects.manage",
    "people.view_all", "people.manage", "reports.view",
    "tasks.assign", "finance.view", "audit.read",
  ]);
}

function identityHasAdvancedAccess() {
  return identityCanAny([
    "company.manage", "projects.view_all", "projects.manage",
    "people.view_all", "people.manage", "worklogs.approve",
    "tasks.assign", "tasks.grade", "finance.view", "finance.manage",
    "reports.view", "audit.read", "identity.manage_templates",
    "governance.manage", "governance.vote",
  ]);
}

function identityCanReviewAcceptance() {
  return identityCanAny([
    "tasks.grade", "tasks.assign", "projects.manage",
    "company.manage", "people.manage",
  ]);
}

function identityCanManageExecution() {
  return identityCanAny([
    "company.manage", "projects.manage", "tasks.assign",
    "tasks.grade", "people.manage",
  ]);
}

function identityCanExecution() {
  // The server scopes the board to the caller's tasks and handoffs.
  return !!DB.profile;
}

function identityPercent(value) {
  return Math.round(num(value) * 100) / 100;
}

function identityDate(value) {
  const text = String(value || "");
  if (!text) return "—";
  return text.slice(0, 16).replace("T", " ");
}

function identityErrorText(error) {
  const message = String((error && error.message) || error || "");
  const lower = message.toLowerCase();
  if (lower.indexOf("get_enterprise_identity_state") !== -1
      || (lower.indexOf("enterprise") !== -1
          && (lower.indexOf("does not exist") !== -1
              || lower.indexOf("could not find") !== -1))) {
    return "企业身份服务还没安装。请让管理员在 Supabase 运行 "
      + "mobile/sql/enterprise-identity.sql";
  }
  if (lower.indexOf("only shareholders may vote") !== -1) {
    return "只有持股股东可以投票。";
  }
  if (lower.indexOf("only shareholders may propose") !== -1) {
    return "只有持股股东可以发起任免提案。";
  }
  if (lower.indexOf("only the enterprise owner may change shares") !== -1) {
    return "只有企业所有者可以调整股份。";
  }
  if (lower.indexOf("voting is still in progress") !== -1) {
    return "投票还在进行，需等投票期结束或全部股东完成投票。";
  }
  if (lower.indexOf("cannot change shares while a role vote is open") !== -1) {
    return "有任免投票正在进行，结束前不能调整股份。";
  }
  if (lower.indexOf("motion is closed") !== -1
      || lower.indexOf("voting period has ended") !== -1) {
    return "这次投票已经结束。";
  }
  if (lower.indexOf("open role motion") !== -1) {
    return "该成员已有一项进行中的任免提案。";
  }
  return message || "企业身份请求失败。";
}

function resetIdentityRuntimeCache() {
  identityLastAttempt = 0;
  organizationState = null;
  organizationLastRefresh = 0;
  if (DB) {
    DB.identity = null;
    DB.identityError = "";
    DB.organizationStatus = { status: "unknown", message: "", at: 0 };
  }
}

async function ensureMyOrganization(force) {
  if (!DB.profile || !initCloud()) return false;
  const state = DB.organizationStatus || {};
  if (!force && state.status === "ready" && Date.now() - num(state.at) < 30000) {
    return true;
  }
  const { data, error } = await cloudClient.rpc("repair_my_organization");
  if (error) throw error;
  DB.organizationStatus = Object.assign({}, data || {}, { at: Date.now() });
  if (data && data.enterprise_id && typeof updateCompanyScope === "function") {
    updateCompanyScope(data.enterprise_id);
  }
  saveAll();
  if (DB.organizationStatus.status !== "ready") {
    DB.identity = null;
    DB.identityError = DB.organizationStatus.status === "pending"
      ? "尚未加入有效公司，请等待老板邀请或联系管理员。"
      : (DB.organizationStatus.message || "公司关系需要修复。");
    renderIdentity();
    return false;
  }
  DB.identityError = "";
  return true;
}

async function refreshIdentity(force) {
  if (!DB.profile) {
    renderIdentity();
    return;
  }
  const now = Date.now();
  if (!force && now - identityLastAttempt < 10000) return;
  if (identityBusy) return;
  if (!initCloud()) {
    DB.identityError = "云组件没有加载，暂时无法同步企业身份。";
    renderIdentity();
    return;
  }

  identityBusy = true;
  identityLastAttempt = now;
  try {
    const ready = await ensureMyOrganization(force);
    if (!ready) return;
    const { data, error } = await cloudClient.rpc(
      "get_enterprise_identity_state"
    );
    if (error) throw error;
    if (!data || !data.enterprise) throw new Error("服务端没有返回企业资料");
    if (data.enterprise.id
        && typeof updateCompanyScope === "function") {
      updateCompanyScope(data.enterprise.id);
    }
    DB.identity = data;
    DB.identityError = "";
    const preferred = data.me && data.me.preferred_mode;
    if (preferred === "simple" || preferred === "advanced") {
      DB.uiMode = preferred;
    }
    saveAll();
    if (typeof applyRoleUI === "function") applyRoleUI();
    if (typeof renderMe === "function") renderMe();
    if (typeof renderToday === "function") renderToday();
    renderIdentity();
    refreshOrganizationState(false);
    if (typeof loadShareholderMeetings === "function") {
      loadShareholderMeetings(false);
    }
    if (typeof refreshDecisionCenterIfActive === "function") {
      refreshDecisionCenterIfActive();
    }
    if (typeof refreshOperationsIfActive === "function") {
      refreshOperationsIfActive();
    }
  } catch (error) {
    DB.identityError = identityErrorText(error);
    renderIdentity();
  } finally {
    identityBusy = false;
  }
}

function renderIdentity() {
  const state = identityState();
  const me = state && state.me ? state.me : null;
  const errorBox = DB.identityError || "";
  const meCard = $("identity-me-card");
  if (!meCard) return;

  if (!me) {
    meCard.innerHTML = `
      <div class="identity-empty">
        <b>${DB.profile ? "还没有加载企业身份" : "登录后查看企业身份"}</b>
        <span>${escapeHtml(errorBox || "点击右上角刷新，或检查网络后重试。")}</span>
      </div>`;
    $("identity-permissions").innerHTML = "";
    $("identity-members").innerHTML = "";
    $("identity-motions").innerHTML = "";
    $("identity-sub").textContent = "股东按股份投票任免";
    $("identity-member-count").textContent = "";
    $("identity-motion-count").textContent = "";
    if ($("identity-board")) $("identity-board").innerHTML = "";
    if ($("identity-meetings")) $("identity-meetings").innerHTML = "";
    if ($("identity-meeting-count")) $("identity-meeting-count").textContent = "";
    if ($("identity-point-state")) $("identity-point-state").innerHTML = "";
    if ($("identity-board-count")) $("identity-board-count").textContent = "";
    if ($("identity-point-count")) $("identity-point-count").textContent = "";
    if ($("identity-organization")) $("identity-organization").innerHTML = "";
    if ($("organization-summary")) $("organization-summary").textContent = "";
    return;
  }

  const enterprise = state.enterprise || {};
  const canSeeShares = Object.prototype.hasOwnProperty.call(me, "shares");
  const sharePercent = canSeeShares ? identityPercent(me.share_percent) : 0;
  $("identity-sub").textContent = enterprise.name || "企业治理";
  meCard.innerHTML = `
    <div class="identity-me-head">
      <div>
        <div class="identity-eyebrow">我的企业身份</div>
        <div class="identity-role-line">
          <b>${escapeHtml(identityRoleLabel(me.role_key))}</b>
          ${me.is_owner ? '<span class="identity-owner">企业所有者</span>' : ""}
          ${me.is_shareholder ? '<span class="identity-share">股东</span>' : ""}
        </div>
      </div>
      <div class="identity-weight">
        <b>${canSeeShares ? sharePercent + "%" : "—"}</b>
        <span>${canSeeShares ? "股份权重" : "仅本人权限"}</span>
      </div>
    </div>
    <div class="identity-meta-grid">
      <div><span>成员</span><b>${escapeHtml(me.name || "—")}</b></div>
      <div><span>部门</span><b>${escapeHtml(me.department || "—")}</b></div>
      <div><span>职务</span><b>${escapeHtml(me.title || "—")}</b></div>
      ${canSeeShares
        ? `<div><span>计票门槛</span><b>${num(enterprise.quorum_bps) / 100}% 出席</b></div>`
        : ""}
    </div>
    ${errorBox ? `<div class="identity-stale">${escapeHtml(errorBox)}</div>` : ""}
  `;

  const permissions = identityPermissions();
  $("identity-permissions").innerHTML = permissions.length
    ? permissions.map(permission => `<span class="chip on">${
        escapeHtml(IDENTITY_PERMISSION_LABELS[permission] || permission)
      }</span>`).join("")
    : '<span class="meta">当前身份没有额外管理权限</span>';

  renderOrganizationSection();
  renderIdentityMembers(state);
  renderIdentityMotions(state);
  renderIdentityBoard(state);
}

function renderIdentityMembers(state) {
  const members = Array.isArray(state.members) ? state.members : [];
  const box = $("identity-members");
  $("identity-member-count").textContent = `${members.length} 人`;
  const canPropose = identityCan("identity.propose");
  const canShares = identityCan("identity.manage_shares");
  const rows = members.map(member => {
    const actions = [];
    if (canPropose && member.status === "active") {
      actions.push(`<button class="identity-small-btn" data-identity-propose="${
        escapeHtml(member.profile_id)
      }">任免</button>`);
    }
    if (canShares && member.status === "active") {
      actions.push(`<button class="identity-small-btn" data-identity-shares="${
        escapeHtml(member.profile_id)
      }">股份</button>`);
    }
    return `
      <div class="identity-member">
        <div class="identity-member-main">
          <div class="identity-member-name">
            <b>${escapeHtml(member.name || "成员")}</b>
            ${member.is_owner ? '<span class="identity-owner">所有者</span>' : ""}
            ${member.is_shareholder ? '<span class="identity-share">股东</span>' : ""}
          </div>
          <div class="identity-member-meta">
            ${escapeHtml(identityRoleLabel(member.role_key))}
            ${member.department || member.title
              ? " · " + escapeHtml([member.department, member.title]
                  .filter(Boolean).join(" / "))
              : ""}
          </div>
        </div>
        <div class="identity-member-share">
          ${member.is_shareholder
            ? identityPercent(member.share_percent) + "%"
            : "非股东"}
        </div>
        <div class="identity-member-actions">${actions.join("")}</div>
      </div>`;
  }).join("");
  box.innerHTML = (canPropose
    ? '<button class="btn ghost identity-propose-any">发起任免提案</button>'
    : "") + (rows || '<div class="identity-empty"><b>没有成员</b></div>');

  const proposeAny = box.querySelector(".identity-propose-any");
  if (proposeAny) proposeAny.onclick = () => openIdentityMotion();
  box.querySelectorAll("[data-identity-propose]").forEach(button => {
    button.onclick = () => openIdentityMotion(button.dataset.identityPropose);
  });
  box.querySelectorAll("[data-identity-shares]").forEach(button => {
    button.onclick = () => openIdentityShares(button.dataset.identityShares);
  });
}

function identityMotionCard(motion) {
  const me = identityMe() || {};
  const kind = motion.kind === "appointment" ? "任免 / 调整"
    : motion.kind === "share_change" ? "股份调整"
    : motion.kind === "template_change" ? "身份模板变更" : "免职";
  let target = motion.target_name || "企业";
  const targetRole = motion.proposed_role_key
    ? ` → ${identityRoleLabel(motion.proposed_role_key)}`
    : "";
  if (motion.kind === "share_change") {
    target += ` · 目标 ${num((motion.payload || {}).shares)} 股`;
  } else if (motion.kind === "template_change") {
    target += ` · ${(motion.payload || {}).template_key || "模板"}`;
  }
  const status = IDENTITY_MOTION_LABELS[motion.status] || motion.status || "—";
  const open = motion.status === "open";
  const canVote = open && motion.can_vote && identityCan("identity.vote");
  const canCancel = open && (me.is_owner
    || String(me.profile_id) === String(motion.proposer_profile_id));
  const voteButtons = canVote ? `
    <div class="identity-vote-actions">
      <button class="btn" data-vote-yes="${escapeHtml(motion.id)}">赞成</button>
      <button class="btn ghost" data-vote-no="${escapeHtml(motion.id)}">反对</button>
      <button class="btn ghost" data-vote-abstain="${escapeHtml(motion.id)}">弃权</button>
    </div>` : "";
  const closeButton = open
    ? `<button class="btn ghost" data-vote-close="${escapeHtml(motion.id)}">截止计票</button>`
    : "";
  const cancelButton = canCancel
    ? `<button class="btn danger" data-vote-cancel="${escapeHtml(motion.id)}">撤回</button>`
    : "";
  return `
    <div class="identity-motion ${open ? "open" : ""}">
      <div class="identity-motion-head">
        <div>
          <div class="identity-eyebrow">${kind}</div>
          <b>${escapeHtml(target)}${escapeHtml(targetRole)}</b>
        </div>
        <span class="identity-status ${escapeHtml(motion.status || "")}">${escapeHtml(status)}</span>
      </div>
      <div class="identity-motion-reason">${escapeHtml(motion.reason || "未填写原因")}</div>
      ${motion.conflict_disclosed
        ? '<div class="identity-disclosure">已披露利益冲突</div>' : ""}
      <div class="identity-vote-line">
        <span>出席 ${identityPercent(motion.turnout_percent)}%</span>
        <span>赞成 ${identityPercent(motion.yes_percent)}%</span>
        <span>${escapeHtml(motion.proposer_name || "成员")} 发起</span>
      </div>
      <div class="identity-vote-track"><span style="width:${
        Math.max(0, Math.min(100, identityPercent(motion.turnout_percent)))
      }%"></span></div>
      <div class="identity-motion-foot">
        <span>${open ? "截止 " + identityDate(motion.closes_at) : escapeHtml(motion.decision_reason || "")}</span>
        <div class="identity-motion-actions">${cancelButton}${closeButton}${voteButtons}</div>
      </div>
    </div>`;
}

function renderIdentityMotions(state) {
  const motions = Array.isArray(state.motions) ? state.motions : [];
  const box = $("identity-motions");
  $("identity-motion-count").textContent =
    `${motions.filter(item => item.status === "open").length} 项待表决`;
  box.innerHTML = motions.length
    ? motions.map(identityMotionCard).join("")
    : '<div class="identity-empty"><b>还没有任免提案</b>'
      + '<span>持股股东可以从成员名单发起任免。</span></div>';

  box.querySelectorAll("[data-vote-yes]").forEach(button => {
    button.onclick = () => identityVote(button.dataset.voteYes, "yes");
  });
  box.querySelectorAll("[data-vote-no]").forEach(button => {
    button.onclick = () => identityVote(button.dataset.voteNo, "no");
  });
  box.querySelectorAll("[data-vote-abstain]").forEach(button => {
    button.onclick = () => identityVote(button.dataset.voteAbstain, "abstain");
  });
  box.querySelectorAll("[data-vote-close]").forEach(button => {
    button.onclick = () => identityCloseVote(button.dataset.voteClose);
  });
  box.querySelectorAll("[data-vote-cancel]").forEach(button => {
    button.onclick = () => identityCancelVote(button.dataset.voteCancel);
  });
}

function openIdentityMotion(profileId) {
  const state = identityState();
  if (!state) {
    toast("先刷新企业身份");
    return;
  }
  const members = state.members || [];
  const roles = (state.roles || []).filter(role => role.key !== "employee");
  const memberOptions = members
    .filter(member => member.status === "active")
    .map(member => `<option value="${escapeHtml(member.profile_id)}"${
      profileId && String(profileId) === String(member.profile_id) ? " selected" : ""
    }>${escapeHtml(member.name)}（${escapeHtml(identityRoleLabel(member.role_key))}）</option>`)
    .join("");
  const roleOptions = roles.map(role =>
    `<option value="${escapeHtml(role.key)}">${escapeHtml(identityRoleLabel(role.key))}</option>`
  ).join("");

  openSheet("发起任免提案", `
    <label for="id-target">成员</label>
    <select id="id-target">${memberOptions}</select>
    <label for="id-kind">事项</label>
    <select id="id-kind">
      <option value="appointment">任命 / 调整身份</option>
      <option value="removal">免去当前身份</option>
    </select>
    <div id="id-role-fields">
      <label for="id-role">拟任身份</label>
      <select id="id-role">${roleOptions}</select>
      <div class="row2">
        <div><label for="id-department">部门</label>
          <input id="id-department" placeholder="例如：产品研发部"></div>
        <div><label for="id-title">职务名称</label>
          <input id="id-title" placeholder="例如：研发负责人"></div>
      </div>
    </div>
    <label for="id-reason">提案原因</label>
    <textarea id="id-reason" placeholder="股东投票时会看到这项说明"></textarea>
    <label for="id-days">投票期</label>
    <select id="id-days">
      <option value="1">1 天</option>
      <option value="3" selected>3 天</option>
      <option value="5">5 天</option>
      <option value="7">7 天</option>
    </select>
    <label style="display:flex;align-items:center;gap:8px;margin-top:10px">
      <input id="id-conflict-disclosed" type="checkbox"
             style="width:auto;margin:0">
      &#21033;&#30410;&#20914;&#31361;&#65306;&#24050;&#20027;&#21160;&#25259;&#38706;
    </label>
    <div class="hint" style="margin-top:10px">
      出席率达到 ${num(state.enterprise.quorum_bps) / 100}% 且赞成票超过有效投票的 50% 才通过。
    </div>
  `, [
    { label: "取消", onClick: closeSheet },
    { label: "发起投票", onClick: submitIdentityMotion },
  ]);

  const kind = $("id-kind");
  const role = $("id-role");
  const syncMotionForm = () => {
    $("id-role-fields").classList.toggle("hidden", kind.value !== "appointment");
    $("id-days").value = kind.value === "appointment"
      && IDENTITY_MAJOR_ROLES.indexOf(role.value) !== -1 ? "5" : "3";
  };
  kind.onchange = syncMotionForm;
  role.onchange = syncMotionForm;
  syncMotionForm();
}

async function submitIdentityMotion() {
  const target = $("id-target").value;
  const kind = $("id-kind").value;
  const role = $("id-role").value;
  const department = $("id-department").value.trim();
  const title = $("id-title").value.trim();
  const reason = $("id-reason").value.trim();
  const days = Number($("id-days").value || 3);
  const conflictDisclosed = $("id-conflict-disclosed").checked;
  closeSheet();
  await identityRpc("propose_enterprise_role", {
    p_target: target,
    p_kind: kind,
    p_role_key: kind === "appointment" ? role : "employee",
    p_department: kind === "appointment" ? department : "",
    p_title: kind === "appointment" ? title : "",
    p_reason: reason,
    p_days: days,
    p_conflict_disclosed: conflictDisclosed,
  }, "任免提案已发起");
}

function openIdentityShares(profileId) {
  const state = identityState();
  const member = (state && state.members || []).find(item =>
    String(item.profile_id) === String(profileId));
  if (!member) return;
  openSheet("发起股份调整提案", `
    <div class="identity-member-sheet">
      <b>${escapeHtml(member.name)}</b>
      <span>${escapeHtml(identityRoleLabel(member.role_key))}</span>
    </div>
    <label for="id-shares">拟调整后的股份权重</label>
    <input id="id-shares" type="number" min="0" step="0.0001"
           inputmode="decimal" value="${num(member.shares)}">
    <label for="id-share-reason">调整原因</label>
    <textarea id="id-share-reason"
      placeholder="股东投票时会看到这项说明"></textarea>
    <label style="display:flex;align-items:center;gap:8px;margin-top:10px">
      <input id="id-share-conflict" type="checkbox" style="width:auto;margin:0">
      利益冲突：已主动披露
    </label>
    <div class="hint" style="margin-top:8px">
      股份调整属于重大事项，默认投票 5 天，通过后才会生效。
    </div>
  `, [
    { label: "取消", onClick: closeSheet },
    { label: "提交重大表决", onClick: async () => {
      const shares = Number($("id-shares").value || 0);
      const reason = $("id-share-reason").value.trim();
      if (!reason) {
        toast("股份调整必须填写原因");
        return;
      }
      const conflict = $("id-share-conflict").checked;
      closeSheet();
      await identityRpc("propose_enterprise_share_change", {
        p_profile: profileId,
        p_shares: shares,
        p_reason: reason,
        p_days: 5,
        p_conflict_disclosed: conflict,
      }, "股份调整已提交重大股东表决");
    } },
  ]);
}

async function identityVote(motionId, choice) {
  await identityRpc("cast_enterprise_role_vote", {
    p_motion: motionId,
    p_choice: choice,
  }, choice === "yes" ? "已投赞成票"
    : choice === "no" ? "已投反对票" : "已投弃权票");
}

async function identityCloseVote(motionId) {
  if (!confirm("只有投票期结束或全部股东已投票时才能计票。现在继续吗？")) return;
  await identityRpc("close_enterprise_role_vote", {
    p_motion: motionId,
  }, "投票已计票");
}

async function identityCancelVote(motionId) {
  if (!confirm("确定撤回这项任免提案吗？")) return;
  await identityRpc("cancel_enterprise_role_vote", {
    p_motion: motionId,
  }, "提案已撤回");
}

async function identityRpc(name, args, successText) {
  if (!initCloud()) {
    toast("云服务没有配置");
    return;
  }
  try {
    const { data, error } = await cloudClient.rpc(name, args);
    if (error) throw error;
    toast(successText);
    await refreshIdentity(true);
    return data;
  } catch (error) {
    toast(identityErrorText(error));
    return null;
  }
}


function identityBoardCard(motion) {
  const me = identityMe() || {};
  const open = motion.status === "open";
  const canVote = open && motion.can_vote;
  const canFinalize = open && motion.can_finalize;
  const voteButtons = canVote ? `
    <button class="btn" data-board-vote="${escapeHtml(motion.id)}"
      data-board-choice="yes">赞成</button>
    <button class="btn ghost" data-board-vote="${escapeHtml(motion.id)}"
      data-board-choice="no">反对</button>
    <button class="btn ghost" data-board-vote="${escapeHtml(motion.id)}"
      data-board-choice="abstain">弃权</button>` : "";
  const finalizeButton = canFinalize
    ? `<button class="btn ghost" data-board-finalize="${escapeHtml(motion.id)}">截止计票</button>`
    : "";
  const pointPayload = motion.kind === "point_pool" ? `
    <div class="identity-vote-line">
      <span>新增 ${num((motion.payload || {}).total_amount)} 分</span>
      <span>单次上限 ${num((motion.payload || {}).single_award_limit)}</span>
    </div>` : "";
  return `<div class="identity-motion ${open ? "open" : ""}">
    <div class="identity-motion-head"><div>
      <div class="identity-eyebrow">董事会 · ${escapeHtml(motion.kind || "事项")}</div>
      <b>${escapeHtml(motion.title || "董事会议案")}</b>
    </div><span class="identity-status ${escapeHtml(motion.status || "")}">${
      escapeHtml(IDENTITY_MOTION_LABELS[motion.status] || motion.status || "")
    }</span></div>
    ${pointPayload}
    <div class="identity-vote-line">
      <span>赞成 ${num(motion.yes_count)} / 出席 ${num(motion.cast_count)}</span>
      <span>${motion.conflict_disclosed ? "已披露利益冲突" : "未披露冲突"}</span>
      <span>${escapeHtml(motion.proposer_name || "董事")} 发起</span>
    </div>
    <div class="identity-motion-actions">${finalizeButton}${voteButtons}</div>
  </div>`;
}

function renderIdentityBoard(state) {
  const box = $("identity-board");
  const count = $("identity-board-count");
  const pointBox = $("identity-point-state");
  const pointCount = $("identity-point-count");
  if (!box || !count || !pointBox || !pointCount) return;
  const me = state.me || {};
  const motions = Array.isArray(state.board_motions) ? state.board_motions : [];
  count.textContent = `${motions.filter(item => item.status === "open").length} 项待表决`;
  const actions = [
    me.is_board_director
      ? '<button class="btn" id="btn-board-point-motion">发起积分池议案</button>'
      : "",
    me.is_chairperson
      ? '<button class="btn ghost" id="btn-chair-award">董事长发放积分</button>'
      : "",
  ].join("");
  box.innerHTML = actions + (motions.length
    ? motions.map(identityBoardCard).join("")
    : '<div class="identity-empty"><b>暂无董事会事项</b>'
      + '<span>董事可发起积分池等经营议案。</span></div>');
  const pointState = state.point_state || {};
  const pool = pointState.pool || {};
  pointCount.textContent = `${num(pointState.balance)} 积分`;
  const ledger = Array.isArray(pointState.ledger) ? pointState.ledger : [];
  const ledgerRows = ledger.map(entry => `
    <div class="identity-vote-line">
      <span>${escapeHtml(entry.profile_name || "成员")}</span>
      <span>${num(entry.amount) > 0 ? "+" : ""}${num(entry.amount)}</span>
      <span>${escapeHtml(entry.reason || entry.entry_type || "积分变动")}</span>
      <span>${identityDate(entry.created_at)}</span>
    </div>`).join("");
  const ledgerScope = pointState.can_read_full_ledger ? "完整企业台账" : "本人台账";
  pointBox.innerHTML = `<div class="identity-motion open">
    <div class="identity-motion-head"><div>
      <div class="identity-eyebrow">当前积分池</div>
      <b>${escapeHtml(pool.quarter || "暂无积分池")}</b>
    </div><span class="identity-status open">永久有效</span></div>
    <div class="identity-vote-line">
      <span>余额 ${num(pointState.balance)}</span>
      <span>剩余 ${num(pool.remaining)} / ${num(pool.total)}</span>
      <span>单次上限 ${num(pool.single_award_limit)}</span>
    </div></div>
    <div class="identity-motion open">
      <div class="identity-eyebrow">${ledgerScope}</div>
      ${ledgerRows || '<div class="identity-empty"><span>暂无积分记录</span></div>'}
    </div>`;  const newButton = $("btn-board-point-motion");
  if (newButton) newButton.onclick = openBoardPointMotion;
  const awardButton = $("btn-chair-award");
  if (awardButton) awardButton.onclick = openChairAward;
  box.querySelectorAll("[data-board-vote]").forEach(button => {
    button.onclick = () => identityBoardVote(
      button.dataset.boardVote, button.dataset.boardChoice
    );
  });
  box.querySelectorAll("[data-board-finalize]").forEach(button => {
    button.onclick = () => identityBoardFinalize(button.dataset.boardFinalize);
  });
}

function openBoardPointMotion() {
  const now = new Date();
  const quarter = `${now.getUTCFullYear()}-Q${Math.floor(now.getUTCMonth() / 3) + 1}`;
  const pointState = (identityState() || {}).point_state || {};
  const pool = pointState.pool || {};
  openSheet("发起积分池议案", `
    <label for="board-title">议案标题</label>
    <input id="board-title" value="${escapeHtml(quarter + " 积分池")}">
    <label for="board-quarter">季度</label>
    <input id="board-quarter" value="${escapeHtml(quarter)}">
    <div class="row2">
      <div><label for="board-total">新增额度</label>
        <input id="board-total" type="number" min="1" value="1000"></div>
      <div><label for="board-limit">单次上限</label>
        <input id="board-limit" type="number" min="1" value="100"></div>
    </div>
    <label for="board-carry">结转来源（可选）</label>
    <input id="board-carry" placeholder="${escapeHtml(pool.id || "上一积分池 UUID")}">
    <label style="display:flex;align-items:center;gap:8px;margin-top:10px">
      <input id="board-conflict" type="checkbox" style="width:auto;margin:0">
      利益冲突：已主动披露
    </label>
  `, [
    { label: "取消", onClick: closeSheet },
    { label: "提交董事会", onClick: async () => {
      const payload = {
        quarter: $("board-quarter").value.trim().toUpperCase(),
        total_amount: Number($("board-total").value || 0),
        single_award_limit: Number($("board-limit").value || 0),
      };
      const carry = $("board-carry").value.trim();
      if (carry) payload.carry_from = carry;
      const title = $("board-title").value.trim();
      const conflict = $("board-conflict").checked;
      closeSheet();
      await identityRpc("create_board_motion", {
        p_title: title,
        p_kind: "point_pool",
        p_payload: payload,
        p_conflict_disclosed: conflict,
      }, "积分池议案已提交董事会");
    } },
  ]);
}

async function identityBoardVote(motionId, choice) {
  await identityRpc("cast_board_vote", {
    p_motion: motionId,
    p_choice: choice,
  }, choice === "yes" ? "已投赞成票"
    : choice === "no" ? "已投反对票" : "已投弃权票");
}

async function identityBoardFinalize(motionId) {
  if (!confirm("确认截止并计票？董事会出席过半且出席董事过半赞成才通过。")) return;
  await identityRpc("finalize_board_motion", {
    p_motion: motionId,
  }, "董事会表决已计票");
}

function openChairAward() {
  const state = identityState() || {};
  const me = state.me || {};
  const members = (state.members || []).filter(member =>
    member.status === "active"
    && String(member.profile_id) !== String(me.profile_id));
  const options = members.map(member =>
    `<option value="${escapeHtml(member.profile_id)}">${escapeHtml(member.name)}</option>`
  ).join("");
  openSheet("董事长发放积分", `
    <label for="award-member">成员</label>
    <select id="award-member">${options}</select>
    <label for="award-amount">积分</label>
    <input id="award-amount" type="number" min="1" value="10">
    <label for="award-evidence-type">证据类型</label>
    <select id="award-evidence-type">
      <option value="acceptance">验收</option>
      <option value="collaboration">协作</option>
      <option value="knowledge">知识贡献</option>
    </select>
    <label for="award-evidence">证据 UUID</label>
    <input id="award-evidence">
    <label for="award-reason">发放原因</label>
    <textarea id="award-reason"></textarea>
    <div class="hint">发放后积分永久有效，且不能超过积分池和单次上限。</div>
  `, [
    { label: "取消", onClick: closeSheet },
    { label: "确认发放", onClick: async () => {
      const evidence = $("award-evidence").value.trim();
      const reason = $("award-reason").value.trim();
      if (!evidence || !reason) {
        toast("证据和原因都必须填写");
        return;
      }
      const args = {
        p_profile: $("award-member").value,
        p_amount: Number($("award-amount").value || 0),
        p_evidence_type: $("award-evidence-type").value,
        p_evidence_id: evidence,
        p_reason: reason,
      };
      closeSheet();
      await identityRpc("award_points", args, "积分已发放");
    } },
  ]);
}

/* ============================================================
   组织、创始人与股权
   ============================================================ */
let organizationLastRefresh = 0;

function organizationMemberName(profileId) {
  const members = (organizationState && organizationState.members) || [];
  const found = members.find(item => String(item.profile_id) === String(profileId));
  return found ? found.name : String(profileId || "—");
}

function organizationClassLabel(value) {
  return ({
    original: "原始股份", ordinary: "普通股份",
    employee_pool: "员工持股池", employee_incentive: "员工激励份额",
  })[value] || value || "股份";
}

function organizationMotionLabel(value) {
  return ({
    initial_split: "首次分股", share_change: "股份调整",
    founder_add: "新增创始人", share_transfer: "股份转让",
    employee_pool: "员工持股池", dissolution: "公司解散",
  })[value] || value;
}

async function refreshOrganizationState(force) {
  if (!DB.profile || organizationBusy) return;
  const now = Date.now();
  if (!force && now - organizationLastRefresh < 10000) return;
  if (!initCloud()) return;
  organizationBusy = true;
  try {
    const { data, error } = await cloudClient.rpc("get_organization_state");
    if (error) throw error;
    organizationState = data || {};
    try {
      const primary = await cloudClient.rpc("get_primary_company");
      if (!primary.error && primary.data) organizationState.primary_company = primary.data;
    } catch (_) {}
    try {
      const invites = await cloudClient.rpc("get_organization_member_invites");
      if (!invites.error && invites.data) organizationState.member_invites = invites.data;
    } catch (_) {}
    organizationError = "";
  } catch (error) {
    organizationError = String(error.message || error || "组织数据加载失败");
  } finally {
    organizationLastRefresh = Date.now();
    organizationBusy = false;
    renderOrganizationSection();
    if (typeof renderToday === "function") renderToday();
  }
}

function organizationOptions(activeId) {
  const rows = (organizationState && organizationState.organizations) || [];
  const primaryId = organizationState && organizationState.primary_company
    ? organizationState.primary_company.primary_enterprise_id : null;
  return rows.map(row => '<button class="btn ghost" style="width:100%;margin-top:6px" '
    + 'data-org-switch="' + escapeHtml(row.id) + '">' + escapeHtml(row.name)
    + (String(row.id) === String(primaryId) ? " · 主公司" : "")
    + (String(row.id) === String(activeId) ? " · 当前" : "") + "</button>").join("");
}

function openCreateOrganization() {
  openSheet("创建组织", `
    <label for="org-name">公司名称</label>
    <input id="org-name" maxlength="120" placeholder="例如：远航工作室">
    <label for="org-founders">共同创始人员工号</label>
    <textarea id="org-founders" placeholder="每行一个员工号；留空就是单人公司"></textarea>
    <div class="hint">单人创建会立即成为临时董事长。多人创建需要全部创始人接受邀请并完成首次分股。</div>
  `, [
    { label: "取消", onClick: closeSheet },
    { label: "创建组织", onClick: async () => {
      const name = ($("org-name") || {}).value || "";
      const codes = String(($("org-founders") || {}).value || "")
        .split(/[\n,，]+/).map(value => value.trim()).filter(Boolean);
      if (!name.trim()) { toast("先填写公司名称"); return; }
      try {
        const { data, error } = await cloudClient.rpc("create_organization", {
          p_name: name.trim(), p_founder_codes: codes,
        });
        if (error) throw error;
        closeSheet();
        await refreshOrganizationState(true);
        await refreshIdentity(true);
        toast(data && data.status === "active" ? "公司已创建" : "组织已创建，等待创始人接受邀请");
      } catch (error) { toast(organizationErrorText(error)); }
    }},
  ]);
}

function openRenameOrganization() {
  const org = organizationState && organizationState.organization;
  if (!org) { toast("当前没有可修改的公司"); return; }
  openSheet("修改公司名称", `
    <label for="org-rename-input">公司名称</label>
    <input id="org-rename-input" maxlength="120" value="${escapeHtml(org.name || "")}">
    <div class="hint">名称会同步给公司内所有成员。1～120 个字符。</div>
  `, [
    { label: "取消", onClick: closeSheet },
    { label: "保存名称", onClick: async () => {
      const name = String(($("org-rename-input") || {}).value || "").trim();
      if (!name) { toast("公司名称不能为空"); return; }
      try {
        const { data, error } = await cloudClient.rpc("rename_organization", {
          p_enterprise: org.id, p_name: name,
        });
        if (error) throw error;
        closeSheet();
        await refreshOrganizationState(true);
        await refreshIdentity(true);
        toast(data && data.changed ? "公司名称已更新" : "公司名称没有变化");
      } catch (error) { toast(organizationErrorText(error)); }
    }},
  ]);
}

function openInviteOrganizationMember() {
  const org = organizationState && organizationState.organization;
  if (!org) { toast("当前没有可管理的公司"); return; }
  if (!initCloud()) { toast("云服务连不上，检查网络后重试"); return; }
  openSheet("邀请公司成员", `
    <label for="org-member-lookup">员工号 / 老板号 / 姓名</label>
    <input id="org-member-lookup" autocapitalize="off" placeholder="填员工号或老板号最准确；重名时必须填号码">
    <div class="row2">
      <div><label for="org-member-department">部门</label>
        <input id="org-member-department" placeholder="例如：产品部"></div>
      <div><label for="org-member-title">职务</label>
        <input id="org-member-title" placeholder="例如：产品经理"></div>
    </div>
    <div class="hint">对方接受后才会加入。加入新公司不会退出原公司，也不会迁移原公司的任务和工时。</div>
  `, [
    { label: "取消", onClick: closeSheet },
    { label: "发出邀请", onClick: async () => {
      const lookup = String(($("org-member-lookup") || {}).value || "").trim();
      if (!lookup) { toast("先填写员工号、老板号或姓名"); return; }
      try {
        const { data, error } = await cloudClient.rpc("invite_organization_member", {
          p_enterprise: org.id, p_lookup: lookup,
          p_department: String(($("org-member-department") || {}).value || "").trim(),
          p_title: String(($("org-member-title") || {}).value || "").trim(),
        });
        if (error) throw error;
        closeSheet();
        await refreshOrganizationState(true);
        await refreshIdentity(true);
        toast(data && data.already_member
          ? `${data.name || lookup} 已经是公司成员`
          : `已向 ${(data && data.name) || lookup} 发出邀请`);
      } catch (error) { toast(organizationErrorText(error)); }
    }},
  ]);
}

async function setPrimaryOrganization() {
  const org = organizationState && organizationState.organization;
  if (!org || !initCloud()) return;
  try {
    const { error } = await cloudClient.rpc("set_primary_company", { p_enterprise: org.id });
    if (error) throw error;
    await refreshOrganizationState(true);
    await refreshIdentity(true);
    toast("已设为你的主公司");
  } catch (error) { toast(organizationErrorText(error)); }
}

async function respondOrganizationMemberInvite(inviteId, accept) {
  if (!inviteId || !initCloud()) return;
  try {
    const { data, error } = await cloudClient.rpc("respond_organization_member_invite", {
      p_invite: inviteId, p_accept: !!accept,
    });
    if (error) throw error;
    if (data && data.ok === false) throw new Error(data.error || "邀请处理失败");
    await refreshOrganizationState(true);
    await refreshIdentity(true);
    toast(accept ? `已加入 ${(data && data.organization_name) || "新公司"}` : "已拒绝公司邀请");
  } catch (error) { toast(organizationErrorText(error)); }
}

async function switchOrganization(enterpriseId) {
  if (!enterpriseId || !initCloud()) return;
  if (typeof pendingCount === "function" && pendingCount() > 0) {
    toast("当前公司还有待上传数据，请先同步完成再切换公司");
    return;
  }
  try {
    const { error } = await cloudClient.rpc("set_active_organization", {
      p_enterprise: enterpriseId,
    });
    if (error) throw error;
    if (typeof unsubscribeRealtime === "function") unsubscribeRealtime();
    if (typeof clearCompanyScopedCache === "function") clearCompanyScopedCache();
    organizationLastRefresh = 0;
    await refreshIdentity(true);
    if (typeof syncNow === "function") syncNow("company-switch");
    toast("已切换组织");
  } catch (error) { toast(organizationErrorText(error)); }
}

function organizationErrorText(error) {
  const message = String((error && (error.message || error.details)) || error || "");
  const lower = message.toLowerCase();
  if (lower.includes("not signed in") || lower.includes("jwt")) return "登录状态过期，请重新登录。";
  if (lower.includes("permission") || lower.includes("founder approval")) return "当前身份没有这项组织权限。";
  if (lower.includes("get_primary_company") || lower.includes("set_primary_company")
      || lower.includes("invite_organization_member")
      || lower.includes("respond_organization_member_invite")
      || lower.includes("organization_member_invites")) {
    return "主公司与成员邀请 SQL 尚未安装，请运行 mobile/sql/phase1-primary-company-member-invites-v1.sql";
  }
  if (lower.includes("rename_organization") || lower.includes("add_organization_member")
      || lower.includes("organization-management-v1")) {
    return "公司管理 SQL 尚未安装，请运行 mobile/sql/organization-management-v1.sql";
  }
  if (lower.includes("repair_my_organization")
      || lower.includes("get_organization_health")) {
    return "多账号修复 SQL 尚未安装，请运行 mobile/sql/multi-account-sync-health-v1.sql";
  }
  if (lower.includes("organization-founders-v1") || lower.includes("function") && lower.includes("not found")) {
    return "组织股权 SQL 尚未安装，请运行 mobile/sql/organization-founders-v1.sql";
  }
  return message || "组织操作失败";
}

function organizationFoundersHtml() {
  const founders = (organizationState && organizationState.founders) || [];
  return founders.length ? founders.map(item =>
    '<div class="today-ledger-row"><div><b>' + escapeHtml(item.name)
    + (item.is_original ? " · 创始人" : "") + '</b><span>'
    + escapeHtml(identityRoleLabel(item.role_key)) + ' · '
    + escapeHtml(item.title || "成员") + '</span></div><strong>原始</strong></div>'
  ).join("") : '<div class="identity-empty"><b>还没有创始人</b></div>';
}

function organizationLotsHtml() {
  const lots = (organizationState && organizationState.share_lots) || [];
  return lots.length ? lots.map(item =>
    '<div class="today-ledger-row"><div><b>' + escapeHtml(item.owner_name || "员工持股池")
    + '</b><span>' + escapeHtml(organizationClassLabel(item.share_class))
    + ' · 投票 ×' + num(item.voting_weight) + '</span></div><strong>'
    + num(item.units) + " 单位</strong></div>"
  ).join("") : '<div class="identity-empty"><b>尚未分股</b><span>邀请完成后发起首次分股。</span></div>';
}

function organizationInvitesHtml() {
  const invites = ((organizationState && organizationState.invites) || []).filter(item =>
    item.status === "invited" && String(item.invitee_profile_id) === String(DB.profile.id));
  return invites.map(item => '<div class="identity-motion open">'
    + '<div class="identity-motion-head"><div><div class="identity-eyebrow">创始人邀请</div>'
    + '<b>' + escapeHtml(organizationState.organization.name) + '</b></div></div>'
    + '<div class="identity-motion-foot"><span>有效期至 '
    + escapeHtml(identityDate(item.expires_at)) + '</span>'
    + '<div class="identity-vote-actions"><button class="btn ghost" data-org-invite-reject="'
    + escapeHtml(item.id) + '">拒绝</button><button class="btn" data-org-invite-accept="'
    + escapeHtml(item.id) + '">接受</button></div></div></div>').join("");
}

function organizationMotionsHtml() {
  const motions = (organizationState && organizationState.motions) || [];
  const me = (organizationState && organizationState.me) || {};
  return motions.length ? motions.map(item => {
    const open = item.status === "open";
    const canVote = open && (item.required_rule !== "founder_unanimous" || me.is_founder);
    return '<div class="identity-motion ' + (open ? "open" : "") + '">'
      + '<div class="identity-motion-head"><div><div class="identity-eyebrow">'
      + escapeHtml(item.required_rule === "founder_unanimous" ? "全体创始人一致同意"
        : item.required_rule === "weighted_4_5" ? "股东 4/5 加权通过" : "股东 2/3 加权通过")
      + '</div><b>' + escapeHtml(organizationMotionLabel(item.kind)) + '</b></div>'
      + '<span class="identity-status ' + (item.status === "passed" ? "passed"
        : item.status === "rejected" ? "rejected" : "open") + '">'
      + escapeHtml(item.status) + "</span></div>"
      + '<div class="identity-motion-reason">' + escapeHtml(item.reason || "—") + "</div>"
      + '<div class="identity-vote-line"><span>赞成 ' + num(item.yes_units)
      + '</span><span>反对 ' + num(item.no_units) + '</span><span>票数 '
      + num(item.vote_count) + "</span></div>"
      + (open ? '<div class="identity-motion-foot"><span>截止 '
        + escapeHtml(identityDate(item.closes_at)) + '</span><div class="identity-vote-actions">'
        + (canVote ? '<button class="btn ghost" data-org-vote="' + escapeHtml(item.id)
          + '" data-choice="no">反对</button><button class="btn ghost" data-org-vote="'
          + escapeHtml(item.id) + '" data-choice="abstain">弃权</button><button class="btn" data-org-vote="'
          + escapeHtml(item.id) + '" data-choice="yes">赞成</button>' : "")
        + '</div></div>' : "") + "</div>";
  }).join("") : '<div class="identity-empty"><b>暂无股权表决</b><span>重大调整会显示在这里。</span></div>';
}

function organizationEmployeeHtml(canManage) {
  const pool = organizationState && organizationState.employee_pool;
  if (!pool) return "";
  const grants = (organizationState.employee_grants || []).map(item =>
    '<div class="today-ledger-row"><div><b>' + escapeHtml(item.name)
    + '</b><span>已归属 ' + num(item.vested_units) + ' / ' + num(item.units)
    + ' 单位</span></div><strong>' + escapeHtml(item.status) + '</strong></div>').join("");
  return '<div class="section-head"><span>员工激励</span><span class="meta">剩余 '
    + num(pool.remaining_units) + ' 单位</span></div><div class="card">'
    + (grants || '<div class="identity-empty"><b>还没有员工激励</b></div>')
    + (canManage ? '<button class="btn ghost" id="btn-org-grant" style="width:100%;margin-top:8px">授予员工激励</button>' : "")
    + '</div>';
}

function organizationMemberInvitesHtml() {
  const data = (organizationState && organizationState.member_invites) || {};
  const received = (data.received || []).filter(item => item.status === "invited");
  const sent = (data.sent || []).filter(item => item.status === "invited");
  const receivedHtml = received.map(item => `
    <div class="identity-motion open">
      <div class="identity-motion-head"><div>
        <div class="identity-eyebrow">公司成员邀请</div>
        <b>${escapeHtml(item.organization_name || "新公司")}</b>
      </div><span class="identity-status open">待接受</span></div>
      <div class="identity-vote-line">
        <span>${escapeHtml(item.department || "未填部门")}</span>
        <span>${escapeHtml(item.title || "普通成员")}</span>
      </div>
      <div class="identity-vote-actions">
        <button class="btn ghost" data-member-invite-reject="${escapeHtml(item.id)}">拒绝</button>
        <button class="btn" data-member-invite-accept="${escapeHtml(item.id)}">接受邀请</button>
      </div>
    </div>`).join("");
  const sentHtml = sent.map(item => `
    <div class="today-ledger-row">
      <div><b>${escapeHtml(item.invitee_name || "成员")}</b>
        <span>${escapeHtml(item.department || "未填部门")} · ${escapeHtml(item.title || "普通成员")}</span></div>
      <strong>等待接受</strong>
    </div>`).join("");
  return (receivedHtml
    ? '<div class="section-head"><span>待我处理</span><span class="meta">' + received.length + ' 个公司邀请</span></div>' + receivedHtml
    : "")
    + (sentHtml
      ? '<div class="section-head"><span>已发出的成员邀请</span><span class="meta">' + sent.length + ' 个待接受</span></div><div class="card">' + sentHtml + '</div>'
      : "");
}

async function openShareDashboard() {
  if (!DB.profile) { toast("登录后查看股份"); return; }
  if (!organizationState || !organizationState.organization) {
    await refreshOrganizationState(true);
  }
  if (!organizationState || !organizationState.organization) {
    toast(organizationError || "当前没有可查看的公司股份");
    return;
  }

  const lots = (organizationState.share_lots || []).filter(item =>
    item.status === "active" && item.owner_profile_id);
  const total = num(organizationState.total_units);
  const originalUnits = lots.filter(item => item.share_class === "original")
    .reduce((sum, item) => sum + num(item.units), 0);
  const ordinaryUnits = lots.filter(item => item.share_class === "ordinary")
    .reduce((sum, item) => sum + num(item.units), 0);
  const holders = {};
  lots.forEach(item => {
    const key = String(item.owner_profile_id);
    if (!holders[key]) holders[key] = {
      name: item.owner_name || organizationMemberName(item.owner_profile_id),
      original: 0, ordinary: 0, units: 0, voting: 0,
    };
    const units = num(item.units);
    holders[key].units += units;
    holders[key].voting += units * num(item.voting_weight || 1);
    if (item.share_class === "original") holders[key].original += units;
    else holders[key].ordinary += units;
  });
  const holderRows = Object.values(holders).sort((a, b) => b.units - a.units);
  const pool = organizationState.employee_pool;
  const canManage = !!(organizationState.me && organizationState.me.can_manage);

  openSheet("股份", `
    <div class="card identity-me-card">
      <div class="identity-meta-grid" style="margin-top:0;padding-top:0;border-top:0">
        <div><span>总股份单位</span><b>${num(total)}</b></div>
        <div><span>加权投票权</span><b>${num(organizationState.voting_units)}</b></div>
        <div><span>原始股份</span><b>${num(originalUnits)} 单位</b></div>
        <div><span>普通股份</span><b>${num(ordinaryUnits)} 单位</b></div>
      </div>
    </div>
    <div class="section-head"><span>持股人</span><span class="meta">${holderRows.length} 人</span></div>
    <div class="card">${holderRows.length ? holderRows.map(item => `
      <div class="today-ledger-row">
        <div><b>${escapeHtml(item.name)}</b><span>原始 ${num(item.original)} · 普通 ${num(item.ordinary)}</span></div>
        <strong>${num(item.units)} 单位</strong>
      </div>`).join("") : '<div class="identity-empty"><b>尚未分股</b><span>完成首次分股后会显示持股人。</span></div>'}</div>
    <div class="section-head"><span>员工持股池</span><span class="meta">${pool ? "已建立" : "未建立"}</span></div>
    <div class="card">${pool
      ? `<div class="today-ledger-row"><div><b>${num(pool.total_units)} 总单位</b><span>已授予 ${num(pool.allocated_units)} · 剩余 ${num(pool.remaining_units)}</span></div><strong>无投票权</strong></div>`
      : '<div class="identity-empty"><b>还没有员工持股池</b><span>持股池最多占总股本 10%。</span></div>'}</div>
    <div class="hint">原始股份投票权重 ×1.1；普通股份和员工激励权重 ×1.0。</div>
  `, [
    { label: "关闭", onClick: closeSheet },
    ...(canManage ? [{ label: "重新分配", onClick: () => {
      closeSheet(); openShareChange();
    }}] : []),
  ]);
}

function renderOrganizationSection() {
  const box = $("identity-organization");
  if (!box) return;
  const summary = $("organization-summary");
  if (summary) {
    summary.textContent = organizationState && organizationState.organization
      ? (organizationState.organization.foundation_status === "founding" ? "筹备中" : "已成立")
      : (DB.profile ? "创建或加入公司" : "");
  }
  if (!DB.profile) {
    box.innerHTML = '<div class="identity-empty"><b>登录后管理组织</b>'
      + '<span>创建公司、邀请创始人并确认首次分股。</span></div>';
    return;
  }
  if (organizationError) {
    box.innerHTML = '<div class="identity-empty"><b>组织数据还没有加载</b><span>'
      + escapeHtml(organizationError) + '</span></div>';
    return;
  }
  if (!organizationState) {
    box.innerHTML = '<div class="identity-empty"><b>正在加载组织</b>'
      + '<span>正在读取创始人与股份资料…</span></div>';
    return;
  }
  const org = organizationState.organization;
  if (!org) {
    const options = organizationOptions("");
    box.innerHTML = '<div class="card identity-motion open">'
      + '<div class="identity-motion-head"><div><div class="identity-eyebrow">新组织</div>'
      + '<b>创建自己的公司</b></div><span class="identity-status open">可创建</span></div>'
      + '<div class="identity-vote-line">自己创建后自动成为创始人；单人公司自动成为临时董事长。</div>'
      + '<button class="btn" id="btn-org-create" style="width:100%;margin-top:10px">创建组织</button>'
      + (options ? '<div class="identity-eyebrow" style="margin-top:14px">已加入的组织</div>' + options : "")
      + '</div>';
    $("btn-org-create").onclick = openCreateOrganization;
    box.querySelectorAll("[data-org-switch]").forEach(button => {
      button.onclick = () => switchOrganization(button.dataset.orgSwitch);
    });
    return;
  }
  const me = organizationState.me || {};
  const founders = organizationState.founders || [];
  const canManage = !!me.can_manage;
  const primaryId = organizationState.primary_company
    ? organizationState.primary_company.primary_enterprise_id : null;
  const isPrimary = String(org.id) === String(primaryId);
  const founding = org.foundation_status === "founding";
  const pool = organizationState.employee_pool;
  box.innerHTML = '<div class="card identity-me-card">'
    + '<div class="identity-me-head"><div><div class="identity-eyebrow">当前组织</div>'
    + '<div class="identity-role-line"><b>' + escapeHtml(org.name) + '</b>'
    + (me.is_founder ? '<span class="identity-owner">创始人</span>' : "")
    + '<span class="identity-share">' + escapeHtml(org.foundation_status) + '</span>'
    + (isPrimary ? '<span class="identity-owner">主公司</span>' : "")
    + (!isPrimary ? '<button class="identity-small-btn" id="btn-org-primary">设为主公司</button>' : "")
    + (canManage ? '<button class="identity-small-btn" id="btn-org-rename">改名</button>' : "")
    + '</div></div>'
    + '<div class="identity-weight"><b>' + num(organizationState.total_units)
    + '</b><span>总股份单位</span></div></div>'
    + '<div class="identity-meta-grid"><div><span>加权投票权</span><b>'
    + num(organizationState.voting_units) + '</b></div><div><span>创始人</span><b>'
    + founders.filter(item => item.status === "active").length + ' 人</b></div>'
    + '<div><span>员工持股池</span><b>' + (pool ? num(pool.total_units) : "未建立")
    + '</b></div><div><span>我的身份</span><b>' + escapeHtml(identityRoleLabel(me.role_key))
    + '</b></div></div>'
    + (founding && canManage
      ? '<div class="btn-row" style="margin-top:12px"><button class="btn ghost" id="btn-org-invite">邀请创始人</button>'
        + '<button class="btn" id="btn-org-initial-split">发起首次分股</button></div>'
        + '<button class="btn ghost" id="btn-org-invite-member" style="width:100%;margin-top:8px">邀请公司成员</button>'
      : canManage
        ? '<div class="btn-row" style="margin-top:12px"><button class="btn ghost" id="btn-org-invite-member">邀请公司成员</button>'
          + '<button class="btn ghost" id="btn-org-transfer">股份转让</button></div>'
          + '<button class="btn ghost" id="btn-org-more" style="width:100%;margin-top:8px">更多股权操作</button>'
        : '<div class="btn-row" style="margin-top:12px"><button class="btn ghost" id="btn-org-transfer">股份转让</button></div>')
    + (organizationOptions(org.id)
      ? '<div class="identity-eyebrow" style="margin-top:14px">切换组织</div>'
        + organizationOptions(org.id) : "")
    + '</div>'
    + organizationMemberInvitesHtml()
    + organizationInvitesHtml()
    + '<div class="section-head"><span>创始人</span><span class="meta">'
    + founders.length + ' 人</span></div><div class="card">' + organizationFoundersHtml() + '</div>'
    + '<div class="section-head"><span>股本结构</span><span class="meta">原始 ×1.1 / 普通 ×1.0</span></div>'
    + '<div class="card">' + organizationLotsHtml() + '</div>'
    + '<div class="section-head"><span>股权表决</span><span class="meta">'
    + (organizationState.motions || []).filter(item => item.status === "open").length
    + ' 项进行中</span></div><div>' + organizationMotionsHtml() + '</div>'
    + organizationEmployeeHtml(canManage);
  if ($("btn-org-create")) $("btn-org-create").onclick = openCreateOrganization;
  if ($("btn-org-primary")) $("btn-org-primary").onclick = setPrimaryOrganization;
  if ($("btn-org-rename")) $("btn-org-rename").onclick = openRenameOrganization;
  if ($("btn-org-invite-member")) $("btn-org-invite-member").onclick = openInviteOrganizationMember;
  if ($("btn-org-invite")) $("btn-org-invite").onclick = inviteOrganizationFounder;
  if ($("btn-org-initial-split")) $("btn-org-initial-split").onclick = openInitialSplit;
  if ($("btn-org-transfer")) $("btn-org-transfer").onclick = openShareTransfer;
  if ($("btn-org-more")) $("btn-org-more").onclick = openOrganizationMore;
  if ($("btn-org-grant")) $("btn-org-grant").onclick = openEmployeeGrant;
  box.querySelectorAll("[data-org-switch]").forEach(button => {
    button.onclick = () => switchOrganization(button.dataset.orgSwitch);
  });
  box.querySelectorAll("[data-org-invite-accept]").forEach(button => {
    button.onclick = () => respondOrganizationInvite(button.dataset.orgInviteAccept, true);
  });
  box.querySelectorAll("[data-org-invite-reject]").forEach(button => {
    button.onclick = () => respondOrganizationInvite(button.dataset.orgInviteReject, false);
  });
  box.querySelectorAll("[data-org-vote]").forEach(button => {
    button.onclick = () => castOrganizationVote(button.dataset.orgVote, button.dataset.choice);
  });
  box.querySelectorAll("[data-member-invite-accept]").forEach(button => {
    button.onclick = () => respondOrganizationMemberInvite(button.dataset.memberInviteAccept, true);
  });
  box.querySelectorAll("[data-member-invite-reject]").forEach(button => {
    button.onclick = () => respondOrganizationMemberInvite(button.dataset.memberInviteReject, false);
  });
}

async function inviteOrganizationFounder() {
  const org = organizationState && organizationState.organization;
  if (!org) return;
  const code = prompt("输入共同创始人员工号或姓名");
  if (!code) return;
  try {
    const { error } = await cloudClient.rpc("invite_organization_founder", {
      p_enterprise: org.id, p_code: code.trim(),
    });
    if (error) throw error;
    await refreshOrganizationState(true);
    toast("创始人邀请已发出");
  } catch (error) { toast(organizationErrorText(error)); }
}

async function respondOrganizationInvite(inviteId, accept) {
  try {
    const { error } = await cloudClient.rpc("respond_organization_founder_invite", {
      p_invite: inviteId, p_accept: !!accept,
    });
    if (error) throw error;
    await refreshOrganizationState(true);
    await refreshIdentity(true);
    toast(accept ? "已接受创始人邀请" : "已拒绝创始人邀请");
  } catch (error) { toast(organizationErrorText(error)); }
}

function openInitialSplit() {
  const founders = (organizationState.founders || []).filter(item => item.status === "active");
  if (!founders.length) { toast("没有可分配的创始人"); return; }
  const equal = Math.round(10000 / founders.length) / 100;
  openSheet("首次分股", founders.map(item =>
    '<label>' + escapeHtml(item.name) + '（' + escapeHtml(item.code || "") + '）'
    + '<input type="number" min="0.0001" step="0.0001" value="' + equal
    + '" data-org-split-profile="' + escapeHtml(item.profile_id) + '"></label>'
  ).join("") + '<div class="hint">总单位必须等于 100。原始股份按 1.1 计算投票权重。</div>', [
    { label: "取消", onClick: closeSheet },
    { label: "发起全体创始人表决", onClick: async () => {
      const allocations = Array.from(document.querySelectorAll("[data-org-split-profile]"))
        .map(input => ({ profile_id: input.dataset.orgSplitProfile, units: num(input.value) }));
      const total = allocations.reduce((sum, item) => sum + item.units, 0);
      if (Math.abs(total - 100) > 0.001) { toast("总股份必须等于 100"); return; }
      try {
        const closes = new Date(Date.now() + 3 * 86400000).toISOString();
        const { error } = await cloudClient.rpc("propose_initial_split", {
          p_allocations: allocations, p_reason: "首次分股确认", p_closes_at: closes,
        });
        if (error) throw error;
        closeSheet();
        await refreshOrganizationState(true);
        toast("首次分股提案已发起，等待全部创始人同意");
      } catch (error) { toast(organizationErrorText(error)); }
    }},
  ]);
}

async function castOrganizationVote(motionId, choice) {
  try {
    const { error } = await cloudClient.rpc("cast_equity_vote", {
      p_motion: motionId, p_choice: choice,
    });
    if (error) throw error;
    await refreshOrganizationState(true);
    await refreshIdentity(true);
    toast("股权表决已记录");
  } catch (error) { toast(organizationErrorText(error)); }
}

function openShareTransfer() {
  const me = organizationState.me || {};
  const ownLots = (organizationState.share_lots || []).filter(item =>
    String(item.owner_profile_id) === String(DB.profile.id));
  if (!ownLots.length) { toast("你当前没有可转让股份"); return; }
  const buyers = (organizationState.members || []).filter(item =>
    String(item.profile_id) !== String(DB.profile.id) && item.status === "active");
  openSheet("股份转让", `
    <label>卖出股份批次<select id="org-transfer-lot">${ownLots.map(item =>
      `<option value="${escapeHtml(item.id)}">${escapeHtml(organizationClassLabel(item.share_class))} · ${num(item.units)} 单位</option>`
    ).join("")}</select></label>
    <label>受让人<select id="org-transfer-buyer">${buyers.map(item =>
      `<option value="${escapeHtml(item.profile_id)}">${escapeHtml(item.name)}（${escapeHtml(item.code || "")}）</option>`
    ).join("")}</select></label>
    <label>转让单位<input id="org-transfer-units" type="number" min="0.0001" step="0.0001"></label>
    <label>转让价格<input id="org-transfer-price" type="number" min="0" step="0.01" value="0"></label>
    <div class="hint">原始股份转让后，转出部分永久变成普通 1.0 股份。</div>
  `, [
    { label: "取消", onClick: closeSheet },
    { label: "发起创始人表决", onClick: async () => {
      try {
        const closes = new Date(Date.now() + 3 * 86400000).toISOString();
        const { error } = await cloudClient.rpc("create_equity_motion", {
          p_kind: "share_transfer",
          p_payload: {
            lot_id: $("org-transfer-lot").value,
            buyer_profile_id: $("org-transfer-buyer").value,
            units: num($("org-transfer-units").value),
            price: num($("org-transfer-price").value),
          },
          p_reason: "股份转让申请", p_closes_at: closes,
        });
        if (error) throw error;
        closeSheet(); await refreshOrganizationState(true);
        toast("股份转让提案已发起");
      } catch (error) { toast(organizationErrorText(error)); }
    }},
  ]);
}

function openOrganizationMore() {
  openSheet("更多股权操作", `
    <button class="btn ghost" style="width:100%;margin-bottom:8px" id="org-action-share-change">重新分配股份</button>
    <button class="btn ghost" style="width:100%;margin-bottom:8px" id="org-action-founder-add">新增创始人</button>
    <button class="btn ghost" style="width:100%;margin-bottom:8px" id="org-action-pool">设立员工持股池</button>
    <button class="btn ghost" style="width:100%" id="org-action-dissolve">发起公司解散</button>
  `, [{ label: "关闭", onClick: closeSheet }]);
  $("org-action-share-change").onclick = openShareChange;
  $("org-action-founder-add").onclick = openFounderAddition;
  $("org-action-pool").onclick = openEmployeePool;
  $("org-action-dissolve").onclick = openDissolution;
}

function openShareChange() {
  const members = (organizationState.members || []).filter(item => item.status === "active");
  const unitsByProfile = {};
  (organizationState.share_lots || []).forEach(item => {
    if (item.owner_profile_id) {
      unitsByProfile[item.owner_profile_id] = (unitsByProfile[item.owner_profile_id] || 0) + num(item.units);
    }
  });
  openSheet("重新分配股份", members.map(item =>
    `<label>${escapeHtml(item.name)}<input type="number" min="0" step="0.0001" value="${num(unitsByProfile[item.profile_id])}" data-org-change-profile="${escapeHtml(item.profile_id)}"></label>`
  ).join("") + '<div class="hint">全体创始人必须同意；总单位必须为 100。</div>', [
    { label: "取消", onClick: closeSheet },
    { label: "发起表决", onClick: async () => {
      const allocations = Array.from(document.querySelectorAll("[data-org-change-profile]"))
        .map(input => ({ profile_id: input.dataset.orgChangeProfile, units: num(input.value) }))
        .filter(item => item.units > 0);
      if (Math.abs(allocations.reduce((sum, item) => sum + item.units, 0) - 100) > 0.001) {
        toast("总股份必须等于 100"); return;
      }
      try {
        const { error } = await cloudClient.rpc("create_equity_motion", {
          p_kind: "share_change", p_payload: { allocations },
          p_reason: "股份重新分配", p_closes_at: new Date(Date.now() + 3 * 86400000).toISOString(),
        });
        if (error) throw error;
        closeSheet(); await refreshOrganizationState(true); toast("股份调整提案已发起");
      } catch (error) { toast(organizationErrorText(error)); }
    }},
  ]);
}

function openFounderAddition() {
  const founderIds = new Set((organizationState.founders || []).map(item => String(item.profile_id)));
  const members = (organizationState.members || []).filter(item =>
    item.status === "active" && !founderIds.has(String(item.profile_id)));
  if (!members.length) { toast("没有可新增的成员"); return; }
  openSheet("新增创始人", `
    <label>成员<select id="org-founder-profile">${members.map(item =>
      `<option value="${escapeHtml(item.profile_id)}">${escapeHtml(item.name)}（${escapeHtml(item.code || "")}）</option>`
    ).join("")}</select></label>
    <label>授予原始股份单位<input id="org-founder-units" type="number" min="0.0001" step="0.0001"></label>
    <div class="hint">需要全部现有创始人一致同意。</div>
  `, [
    { label: "取消", onClick: closeSheet },
    { label: "发起表决", onClick: async () => {
      try {
        const { error } = await cloudClient.rpc("create_equity_motion", {
          p_kind: "founder_add",
          p_payload: {
            profile_id: $("org-founder-profile").value,
            units: num($("org-founder-units").value),
          },
          p_reason: "新增创始人", p_closes_at: new Date(Date.now() + 3 * 86400000).toISOString(),
        });
        if (error) throw error;
        closeSheet(); await refreshOrganizationState(true); toast("新增创始人提案已发起");
      } catch (error) { toast(organizationErrorText(error)); }
    }},
  ]);
}

function openEmployeePool() {
  const total = num(organizationState.total_units || 100);
  openSheet("设立员工持股池", `
    <label>持股池总单位<input id="org-pool-units" type="number" min="0.0001" step="0.0001" max="${total * 0.1}"></label>
    <div class="hint">员工持股池最多占总股本 10%，无投票权，需要全部创始人同意。</div>
  `, [
    { label: "取消", onClick: closeSheet },
    { label: "发起表决", onClick: async () => {
      try {
        const { error } = await cloudClient.rpc("create_equity_motion", {
          p_kind: "employee_pool", p_payload: { units: num($("org-pool-units").value) },
          p_reason: "设立员工持股池", p_closes_at: new Date(Date.now() + 3 * 86400000).toISOString(),
        });
        if (error) throw error;
        closeSheet(); await refreshOrganizationState(true); toast("员工持股池提案已发起");
      } catch (error) { toast(organizationErrorText(error)); }
    }},
  ]);
}

function openDissolution() {
  if (!confirm("发起公司解散？通过后公司进入冻结和清算状态，不会立即删除数据。")) return;
  const reason = prompt("填写解散原因");
  if (!reason) return;
  cloudClient.rpc("create_equity_motion", {
    p_kind: "dissolution", p_payload: { reason },
    p_reason: reason.trim(), p_closes_at: new Date(Date.now() + 7 * 86400000).toISOString(),
  }).then(({ error }) => {
    if (error) throw error;
    return refreshOrganizationState(true);
  }).then(() => toast("解散提案已发起，需要超过 4/5 加权投票权同意"))
    .catch(error => toast(organizationErrorText(error)));
}

function openEmployeeGrant() {
  const pool = organizationState.employee_pool;
  if (!pool) { toast("先建立员工持股池"); return; }
  const members = (organizationState.members || []).filter(item => item.status === "active");
  openSheet("授予员工激励", `
    <label>员工<select id="org-grant-profile">${members.map(item =>
      `<option value="${escapeHtml(item.profile_id)}">${escapeHtml(item.name)}（${escapeHtml(item.code || "")}）</option>`
    ).join("")}</select></label>
    <label>授予单位<input id="org-grant-units" type="number" min="0.0001" step="0.0001" max="${num(pool.remaining_units)}"></label>
    <div class="hint">默认 4 年归属、满 1 年归属 25%，无投票权。</div>
  `, [
    { label: "取消", onClick: closeSheet },
    { label: "授予", onClick: async () => {
      try {
        const { error } = await cloudClient.rpc("grant_employee_equity", {
          p_profile: $("org-grant-profile").value,
          p_units: num($("org-grant-units").value),
          p_vesting_start: new Date().toISOString(),
        });
        if (error) throw error;
        closeSheet(); await refreshOrganizationState(true); toast("员工激励已授予");
      } catch (error) { toast(organizationErrorText(error)); }
    }},
  ]);
}
