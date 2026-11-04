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
    const { data, error } = await cloudClient.rpc(
      "get_enterprise_identity_state"
    );
    if (error) throw error;
    if (!data || !data.enterprise) throw new Error("服务端没有返回企业资料");
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
    if ($("identity-point-state")) $("identity-point-state").innerHTML = "";
    if ($("identity-board-count")) $("identity-board-count").textContent = "";
    if ($("identity-point-count")) $("identity-point-count").textContent = "";
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
