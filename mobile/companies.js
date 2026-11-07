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
};

function myCompanyRoleLabel(value) {
  return typeof identityRoleLabel === "function"
    ? identityRoleLabel(value) : (value || "成员");
}

function renderMyCompanies() {
  const primaryBox = $("my-company-primary");
  const listBox = $("my-company-list");
  const peopleBox = $("my-company-people");
  const peopleCount = $("my-company-people-count");
  const sub = $("my-companies-sub");
  if (!primaryBox || !listBox || !peopleBox || !peopleCount || !sub) return;

  if (!DB.profile) {
    sub.textContent = "登录后查看你的公司";
    primaryBox.innerHTML = '<div class="identity-empty"><b>还没有登录</b></div>';
    listBox.innerHTML = "";
    peopleBox.innerHTML = "";
    peopleCount.textContent = "";
    return;
  }

  if (!myCompaniesState.loadedAt && !myCompaniesState.busy && !myCompaniesState.error) {
    primaryBox.innerHTML = '<div class="identity-empty"><b>正在读取公司</b><span>加载主公司和其他成员关系…</span></div>';
    listBox.innerHTML = "";
    peopleBox.innerHTML = "";
    loadMyCompanies(true);
    return;
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
    return;
  }

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
    peopleBox.innerHTML = `<div class="hint" style="margin-bottom:10px">${escapeHtml(access.message || "成员信息按权限显示")}</div>`
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
              · ${escapeHtml(person.status || "active")}</div>` : ""}
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
    myCompaniesState.loadedAt = Date.now();
    await loadMyCompanyPeople(myCompaniesState.selectedId);
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

async function switchMyCompany(companyId) {
  if (!companyId || !initCloud()) return;
  try {
    const { error } = await cloudClient.rpc("set_active_organization", {
      p_enterprise: companyId,
    });
    if (error) throw error;
    myCompaniesState.loadedAt = 0;
    await loadMyCompanies(true);
    if (typeof refreshOrganizationState === "function") refreshOrganizationState(true);
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
