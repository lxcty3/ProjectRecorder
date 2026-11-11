"use strict";

let myCompaniesState = {
  busy: false,
  loadedAt: 0,
  error: "",
  companies: [],
  primaryId: null,
  activeId: null,
  selectedId: null,
  people: [],
  access: {},
  invites: { received: [], sent: [] },
  inviteBusy: "",
};

function resetMyCompaniesRuntimeCache() {
  myCompaniesState = {
    busy: false,
    loadedAt: 0,
    error: "",
    companies: [],
    primaryId: null,
    activeId: null,
    selectedId: null,
    people: [],
    access: {},
    invites: { received: [], sent: [] },
    inviteBusy: "",
  };
}

function myCompanyRoleLabel(value) {
  return typeof identityRoleLabel === "function"
    ? identityRoleLabel(value) : (value || "成员");
}

function myCompanyInviteIsOpen(item) {
  if (!item || item.status !== "invited") return false;
  const expiresAt = Date.parse(item.expires_at || "");
  return !Number.isFinite(expiresAt) || expiresAt > Date.now();
}

function myCompanyInvitesHtml() {
  const data = (myCompaniesState && myCompaniesState.invites) || {};
  const received = (Array.isArray(data.received) ? data.received : [])
    .filter(myCompanyInviteIsOpen);
  const sent = (Array.isArray(data.sent) ? data.sent : [])
    .filter(myCompanyInviteIsOpen);
  const busy = String(myCompaniesState.inviteBusy || "");
  const receivedHtml = received.map(item => {
    const id = String(item.id || "");
    const working = busy === id;
    const disabled = busy ? " disabled" : "";
    const inviter = [item.inviter_name, item.inviter_code].filter(Boolean).join("  ");
    return `
      <div class="identity-motion open">
        <div class="identity-motion-head"><div>
          <div class="identity-eyebrow">公司邀请${inviter ? "  " + escapeHtml(inviter) : ""}</div>
          <b>${escapeHtml(item.organization_name || "新公司")}</b>
        </div><span class="identity-status open">待接受</span></div>
        <div class="identity-vote-line">
          <span>${escapeHtml(item.department || "未填部门")}</span>
          <span>${escapeHtml(item.title || "普通成员")}</span>
        </div>
        <div class="hint" style="margin-top:8px">接受后会加入这家公司，并切换为当前公司；原公司数据不会迁移。</div>
        <div class="identity-vote-actions">
          <button class="btn ghost" data-my-company-invite-reject="${escapeHtml(id)}"${disabled}>拒绝</button>
          <button class="btn" data-my-company-invite-accept="${escapeHtml(id)}"${disabled}>${working ? "处理中" : "接受邀请"}</button>
        </div>
      </div>`;
  }).join("");
  const sentHtml = sent.map(item => `
    <div class="today-ledger-row">
      <div><b>${escapeHtml(item.invitee_name || "成员")}</b>
        <span>${escapeHtml(item.invitee_code || "无员工号")}  ${escapeHtml(item.department || "未填部门")}  ${escapeHtml(item.title || "普通成员")}</span></div>
      <strong>等待接受</strong>
    </div>`).join("");
  return (receivedHtml
    ? '<div class="section-head"><span>待处理的公司邀请</span><span class="meta">' + received.length + ' 个</span></div>' + receivedHtml
    : "")
    + (sentHtml
      ? '<div class="section-head"><span>已发出的成员邀请</span><span class="meta">' + sent.length + ' 个待接受</span></div><div class="card">' + sentHtml + '</div>'
      : "");
}

function renderMyCompanies() {
  const primaryBox = $("my-company-primary");
  const listBox = $("my-company-list");
  const peopleBox = $("my-company-people");
  const peopleCount = $("my-company-people-count");
  const invitesBox = $("my-company-invites");
  const sub = $("my-companies-sub");
  if (!primaryBox || !listBox || !peopleBox || !peopleCount || !sub) return;

  if (!DB.profile) {
    sub.textContent = "登录后查看你的公司";
    primaryBox.innerHTML = '<div class="identity-empty"><b>还没有登录</b></div>';
    listBox.innerHTML = "";
    peopleBox.innerHTML = "";
    peopleCount.textContent = "";
    if (invitesBox) invitesBox.innerHTML = "";
    return;
  }

  if (!myCompaniesState.loadedAt && !myCompaniesState.busy && !myCompaniesState.error) {
    primaryBox.innerHTML = '<div class="identity-empty"><b>正在读取公司</b><span>加载主公司和其他成员关系…</span></div>';
    listBox.innerHTML = "";
    peopleBox.innerHTML = "";
    if (invitesBox) invitesBox.innerHTML = "";
    loadMyCompanies(true);
    return;
  }

  const healthSection = $("organization-health-section");
  if (healthSection) {
    healthSection.classList.toggle("hidden", !identityHasManagementView());
  }

  const companies = myCompaniesState.companies || [];
  const primary = companies.find(item => String(item.id) === String(myCompaniesState.primaryId));
  const selected = companies.find(item => String(item.id) === String(myCompaniesState.selectedId));
  sub.textContent = primary ? `主公司：${primary.name}` : "公司关系";

  if (myCompaniesState.error) {
    primaryBox.innerHTML = `<div class="identity-empty"><b>公司信息没有加载</b><span>${escapeHtml(myCompaniesState.error)}</span></div>`;
    listBox.innerHTML = "";
    peopleBox.innerHTML = "";
    peopleCount.textContent = "";
    if (invitesBox) invitesBox.innerHTML = "";
    return;
  }

  if (invitesBox) invitesBox.innerHTML = myCompanyInvitesHtml();
  primaryBox.innerHTML = primary ? `
    <div class="card identity-me-card">
      <div class="identity-me-head"><div>
        <div class="identity-eyebrow">我的主公司</div>
        <div class="identity-role-line"><b>${escapeHtml(primary.name)}</b>
          <span class="identity-owner">主公司</span>
          ${primary.is_active ? '<span class="identity-share">当前组织</span>' : ""}
        </div>
      </div><div class="identity-weight"><b>${num(primary.member_count)}</b><span>成员</span></div></div>
      <div class="identity-meta-grid">
        <div><span>我的身份</span><b>${escapeHtml(myCompanyRoleLabel(primary.role_key))}</b></div>
        <div><span>部门 / 职务</span><b>${escapeHtml([primary.department,primary.title].filter(Boolean).join(" / ") || "—")}</b></div>
      </div>
      <div class="btn-row" style="margin-top:12px">
        <button class="btn ghost" data-company-view="${escapeHtml(primary.id)}">查看成员</button>
        ${primary.is_active ? "" : `<button class="btn" data-company-active="${escapeHtml(primary.id)}">切换到这家公司</button>`}
      </div>
    </div>` : '<div class="identity-empty"><b>还没有主公司</b><span>接受公司邀请后会自动建立主公司。</span></div>';

  listBox.innerHTML = companies.length ? companies.map(item => `
    <div class="identity-member" data-company-view="${escapeHtml(item.id)}">
      <div class="identity-member-main">
        <div class="identity-member-name"><b>${escapeHtml(item.name)}</b>
          ${item.is_primary ? '<span class="identity-owner">主公司</span>' : ""}
          ${item.is_active ? '<span class="identity-share">当前</span>' : ""}
        </div>
        <div class="identity-member-meta">${escapeHtml(myCompanyRoleLabel(item.role_key))}
          ${item.department || item.title ? " · " + escapeHtml([item.department,item.title].filter(Boolean).join(" / ")) : ""}
        </div>
      </div>
      <div class="identity-member-share">${num(item.member_count)} 人</div>
      <div class="identity-member-actions">
        <button class="identity-small-btn" data-company-view="${escapeHtml(item.id)}">查看</button>
        ${item.is_active ? "" : `<button class="identity-small-btn" data-company-active="${escapeHtml(item.id)}">切换</button>`}
        ${item.is_primary ? "" : `<button class="identity-small-btn" data-company-primary="${escapeHtml(item.id)}">设为主公司</button>`}
      </div>
    </div>`).join("") : '<div class="identity-empty"><b>还没有加入公司</b></div>';

  const people = myCompaniesState.people || [];
  peopleCount.textContent = selected ? `${selected.name} · ${people.length} 人` : "";
  if (!selected) {
    peopleBox.innerHTML = '<div class="identity-empty"><b>选择一家公司</b><span>点击上面的「查看」读取你有权限看到的成员信息。</span></div>';
  } else {
    const access = myCompaniesState.access || {};
    const accessMessage = access.full
      ? "可查看成员角色、部门、账号、成员状态和持股信息"
      : "只显示成员的公开角色、部门和职务";
    peopleBox.innerHTML = `<div class="hint" style="margin-bottom:10px">${escapeHtml(accessMessage)}</div>`
      + (people.length ? people.map(person => `
        <div class="identity-member">
          <div class="identity-member-main">
            <div class="identity-member-name"><b>${escapeHtml(person.name || "成员")}</b>
              ${person.is_me ? '<span class="identity-owner">我</span>' : ""}
              ${person.is_shareholder ? '<span class="identity-share">股东</span>' : ""}
            </div>
            <div class="identity-member-meta">${escapeHtml(myCompanyRoleLabel(person.role_key))}
              ${person.department || person.title ? " · " + escapeHtml([person.department,person.title].filter(Boolean).join(" / ")) : ""}
            </div>
            ${access.full ? `<div class="meta" style="margin-top:4px">${escapeHtml(person.code || "无员工号")}
              · ${escapeHtml(person.email || "未绑定邮箱")}
              · ${escapeHtml(person.status || "active")}</div>
              <div class="meta" style="margin-top:2px">主公司：${escapeHtml(person.primary_company_name || "未设置")}</div>` : ""}
          </div>
          <div class="identity-member-share">${person.is_shareholder ? num(person.share_percent) + "%" : "非股东"}</div>
        </div>`).join("") : '<div class="identity-empty"><b>没有可显示的成员</b></div>');

    peopleBox.querySelectorAll("[data-company-switch]").forEach(button => {
      button.onclick = () => switchMyCompany(button.dataset.companySwitch);
    });
  }

  document.querySelectorAll("[data-company-view]").forEach(button => {
    button.onclick = event => {
      event.stopPropagation();
      selectMyCompany(button.dataset.companyView);
    };
  });
  document.querySelectorAll("[data-company-primary]").forEach(button => {
    button.onclick = event => {
      event.stopPropagation();
      makeMyPrimaryCompany(button.dataset.companyPrimary);
    };
  });
  document.querySelectorAll("[data-company-active]").forEach(button => {
    button.onclick = event => {
      event.stopPropagation();
      switchMyCompany(button.dataset.companyActive);
    };
  });
  if (invitesBox) {
    invitesBox.querySelectorAll("[data-my-company-invite-accept]").forEach(button => {
      button.onclick = () => respondMyCompanyInvite(button.dataset.myCompanyInviteAccept, true);
    });
    invitesBox.querySelectorAll("[data-my-company-invite-reject]").forEach(button => {
      button.onclick = () => respondMyCompanyInvite(button.dataset.myCompanyInviteReject, false);
    });
  }
}

async function loadMyCompanyInvites() {
  if (!initCloud()) return;
  try {
    const { data, error } = await cloudClient.rpc("get_organization_member_invites");
    if (error) throw error;
    myCompaniesState.invites = {
      received: Array.isArray(data && data.received) ? data.received : [],
      sent: Array.isArray(data && data.sent) ? data.sent : [],
    };
  } catch (error) {
    console.warn("公司邀请加载失败", String(error.message || error || ""));
  }
}

async function respondMyCompanyInvite(inviteId, accept) {
  if (!inviteId || myCompaniesState.inviteBusy || !initCloud()) return;
  myCompaniesState.inviteBusy = String(inviteId);
  renderMyCompanies();
  try {
    const { data, error } = await cloudClient.rpc("respond_organization_member_invite", {
      p_invite: inviteId, p_accept: !!accept,
    });
    if (error) throw error;
    if (data && data.ok === false) throw new Error(data.error || "邀请处理失败");
    myCompaniesState.loadedAt = 0;
    await loadMyCompanies(true);
    if (typeof refreshOrganizationState === "function") refreshOrganizationState(true);
    if (typeof refreshIdentity === "function") refreshIdentity(true);
    toast(accept
      ? `已加入 ${(data && data.organization_name) || "新公司"}`
      : "已拒绝公司邀请");
  } catch (error) {
    toast(typeof organizationErrorText === "function"
      ? organizationErrorText(error)
      : String(error.message || error || "邀请处理失败"));
  } finally {
    myCompaniesState.inviteBusy = "";
    renderMyCompanies();
  }
}

async function loadMyCompanies(force) {
  if (!DB.profile || myCompaniesState.busy) return;
  if (!force && myCompaniesState.loadedAt && Date.now() - myCompaniesState.loadedAt < 15000) return;
  if (!initCloud()) {
    myCompaniesState.error = "云服务没有加载";
    renderMyCompanies();
    return;
  }
  myCompaniesState.busy = true;
  try {
    const { data, error } = await cloudClient.rpc("get_my_companies");
    if (error) throw error;
    myCompaniesState.companies = Array.isArray(data && data.companies) ? data.companies : [];
    myCompaniesState.primaryId = data && data.primary_enterprise_id;
    myCompaniesState.activeId = data && data.active_enterprise_id;
    const keepSelected = myCompaniesState.companies.some(item =>
      String(item.id) === String(myCompaniesState.selectedId));
    if (!keepSelected) myCompaniesState.selectedId = myCompaniesState.primaryId
      || (myCompaniesState.companies[0] && myCompaniesState.companies[0].id) || null;
    myCompaniesState.error = "";
    await loadMyCompanyPeople(myCompaniesState.selectedId);
    await loadMyCompanyInvites();
    myCompaniesState.loadedAt = Date.now();
  } catch (error) {
    const text = String(error.message || error || "");
    console.warn("我的公司加载失败", text);
    myCompaniesState.error = /could not find the function|does not exist/i.test(text)
      ? "我的公司 SQL 尚未安装，请运行 mobile/sql/phase1-my-companies-v1.sql"
      : text || "公司信息加载失败";
  } finally {
    myCompaniesState.busy = false;
    renderMyCompanies();
  }
}

async function loadMyCompanyPeople(companyId) {
  if (!companyId || !initCloud()) return;
  const { data, error } = await cloudClient.rpc("get_company_people", {
    p_enterprise: companyId,
  });
  if (error) throw error;
  myCompaniesState.selectedId = companyId;
  myCompaniesState.people = Array.isArray(data && data.people) ? data.people : [];
  myCompaniesState.access = (data && data.access) || {};
}

async function selectMyCompany(companyId) {
  if (!companyId) return;
  myCompaniesState.selectedId = companyId;
  myCompaniesState.people = [];
  myCompaniesState.access = {};
  renderMyCompanies();
  try {
    await loadMyCompanyPeople(companyId);
  } catch (error) {
    myCompaniesState.error = String(error.message || error || "成员信息加载失败");
  }
  renderMyCompanies();
}

async function loadOrganizationHealth() {
  const box = $("organization-health-result");
  if (!box || !DB.profile) return;
  if (!identityHasManagementView()) {
    box.textContent = "只有管理身份可以查看组织健康。";
    return;
  }
  if (!initCloud()) {
    box.textContent = "云服务没有加载。";
    return;
  }
  box.textContent = "正在检查成员、股份和治理状态…";
  try {
    const { data, error } = await cloudClient.rpc("get_organization_health", {
      p_enterprise: myCompaniesState.activeId || DB.company_scope_id || null,
    });
    if (error) throw error;
    if (!data || data.ok === false) {
      throw new Error(data && data.message || "组织健康检查未完成");
    }
    const checks = Array.isArray(data.checks) ? data.checks : [];
    const failed = checks.filter(item => !item.ok);
    box.innerHTML = (failed.length
      ? '<div class="banner bad">发现 ' + failed.length + ' 项需要修复。</div>'
      : '<div class="banner good">组织成员、股份和治理状态正常。</div>')
      + checks.map(item => '<div class="today-ledger-row"><div><b>'
        + escapeHtml(item.label || item.key) + '</b><span>'
        + escapeHtml(item.detail || "") + '</span></div><strong>'
        + (item.ok ? "正常" : "异常") + '</strong></div>').join("");
  } catch (error) {
    const message = String(error.message || error || "");
    box.innerHTML = '<div class="banner bad">健康检查失败：'
      + escapeHtml(message) + '</div>';
  }
}

async function repairMyOrganizationFromUI() {
  if (!DB.profile || !initCloud()) return;
  try {
    const { data, error } = await cloudClient.rpc("repair_my_organization");
    if (error) throw error;
    DB.organizationStatus = Object.assign({}, data || {}, { at: Date.now() });
    if (data && data.enterprise_id && typeof updateCompanyScope === "function") {
      updateCompanyScope(data.enterprise_id);
    }
    saveAll();
    if (data && data.status === "ready") {
      await refreshIdentity(true);
      myCompaniesState.loadedAt = 0;
      await loadMyCompanies(true);
      await loadOrganizationHealth();
      toast("公司身份已修复");
    } else {
      toast(String(data && data.message || "正在等待公司邀请"));
    }
  } catch (error) {
    toast(String(error.message || error || "公司身份修复失败"));
  }
}

async function switchMyCompany(companyId) {
  if (!companyId || !initCloud()) return;
  if (typeof pendingCount === "function" && pendingCount() > 0) {
    toast("当前公司还有待上传数据，请先同步完成再切换公司");
    return;
  }
  try {
    const { error } = await cloudClient.rpc("set_active_organization", {
      p_enterprise: companyId,
    });
    if (error) throw error;
    if (typeof unsubscribeRealtime === "function") unsubscribeRealtime();
    if (typeof clearCompanyScopedCache === "function") clearCompanyScopedCache();
    myCompaniesState.loadedAt = 0;
    await loadMyCompanies(true);
    if (typeof refreshIdentity === "function") await refreshIdentity(true);
    if (typeof refreshOrganizationState === "function") refreshOrganizationState(true);
    if (typeof syncNow === "function") syncNow("company-switch");
    toast("已切换当前公司");
  } catch (error) {
    toast(String(error.message || error || "切换公司失败"));
  }
}

async function makeMyPrimaryCompany(companyId) {
  if (!companyId || !initCloud()) return;
  try {
    const { error } = await cloudClient.rpc("set_primary_company", {
      p_enterprise: companyId,
    });
    if (error) throw error;
    myCompaniesState.loadedAt = 0;
    await loadMyCompanies(true);
    if (typeof refreshOrganizationState === "function") refreshOrganizationState(true);
    toast("已更新主公司");
  } catch (error) {
    toast(String(error.message || error || "设置主公司失败"));
  }
}
