/* =============================================================
   投票中心 · v1
   待我投票 + 正式投票（按人数 / 按股份）+ 社区投票聚合
   ============================================================= */
"use strict";

let voteCenterState = {
  scope: "pending",
  votes: [],
  polls: [],
  loading: false,
  error: "",
  lastLoad: 0,
};

function voteCenterTabs() {
  return [
    ["pending", "待我投票"],
    ["all", "全部"],
    ["closed", "已结束"],
  ];
}

function voteCenterIdentity() {
  return typeof identityState === "function" ? identityState() : null;
}

function voteCenterMe() {
  const state = voteCenterIdentity();
  return state && state.me ? state.me : {};
}

function voteCenterPermissions() {
  const me = voteCenterMe();
  return Array.isArray(me.permissions) ? me.permissions : [];
}

function voteCenterCanCreate(mode) {
  const me = voteCenterMe();
  const perms = voteCenterPermissions();
  if (!me || !me.profile_id) return false;
  if (mode === "headcount") {
    return !!me.is_owner || !!me.is_ceo
      || perms.indexOf("people.manage") !== -1
      || perms.indexOf("governance.manage") !== -1;
  }
  if (mode === "shares") {
    return !!me.is_shareholder || !!me.is_board_director
      || perms.indexOf("governance.vote") !== -1
      || perms.indexOf("governance.manage") !== -1;
  }
  return false;
}

function voteCenterModeLabel(mode) {
  return mode === "shares" ? "按股份" : "按人数";
}

function voteCenterChoiceLabel(choice) {
  if (choice === "yes") return "赞成";
  if (choice === "no") return "反对";
  if (choice === "abstain") return "弃权";
  return "未投";
}

function voteCenterRemaining(value) {
  const when = new Date(value || "").getTime();
  if (!isFinite(when)) return "";
  const diff = when - Date.now();
  if (diff <= 0) return "已截止";
  const hours = Math.ceil(diff / 3600000);
  return hours < 48 ? "剩 " + hours + " 小时" : "剩 " + Math.ceil(hours / 24) + " 天";
}

function voteCenterBpsText(bps) {
  const value = Number(bps);
  if (!isFinite(value) || value <= 0) return "";
  return "出席门槛 " + Math.round(value / 100) + "%";
}

function voteCenterResultText(vote) {
  if (vote.status === "open") return "进行中";
  if (vote.result === "passed" || vote.passed) return "通过";
  if (vote.result === "rejected") return "未通过";
  return "已结束";
}

function voteCenterEmpty(title, text) {
  return '<div class="identity-empty"><b>' + escapeHtml(title)
    + '</b><span>' + escapeHtml(text) + '</span></div>';
}

function voteCenterGovernancePending() {
  if (typeof identityVoteInboxItems !== "function") return [];
  return identityVoteInboxItems();
}

function voteCenterGovernanceHtml(items) {
  return '<div class="section-head"><span>治理待投</span><span class="meta">'
    + items.length + ' 项</span></div><div class="card vote-governance">'
    + items.map(item => '<button class="vote-governance-row"'
      + ' data-vote-governance="' + escapeHtml(item.section) + '">'
      + '<span class="vote-governance-kind">' + escapeHtml(item.label) + '</span>'
      + '<span class="vote-governance-copy"><b>' + escapeHtml(item.title) + '</b>'
      + '<small>' + escapeHtml(item.meta || "待投票") + '</small></span>'
      + '<span class="vote-governance-arrow">›</span></button>').join("")
    + '</div>';
}

function voteCenterCard(vote) {
  const open = vote.status === "open";
  const my = String(vote.my_choice || "");
  const showResults = !open || !!my;
  const choices = [["yes", "赞成"], ["no", "反对"], ["abstain", "弃权"]];
  const choiceButtons = choices.map(([key, label]) =>
    '<button class="vote-choice' + (my === key ? " mine" : "") + '"'
    + ' data-vote-cast="' + escapeHtml(vote.id) + '"'
    + ' data-vote-choice="' + key + '"' + (open ? "" : " disabled") + '>'
    + label + '</button>').join("");
  const resultRows = choices.map(([key, label]) => {
    const count = vote.mode === "shares"
      ? Number(vote[key === "yes" ? "yes_shares"
        : key === "no" ? "no_shares" : "abstain_shares"]) || 0
      : Number(vote[key === "yes" ? "yes_count"
        : key === "no" ? "no_count" : "abstain_count"]) || 0;
    const total = vote.mode === "shares"
      ? Number(vote.cast_shares) || 0
      : Number(vote.cast_count) || 0;
    const percent = total > 0 ? Math.round(count * 100 / total) : 0;
    const mine = my === key;
    return '<div class="vote-result-row' + (mine ? " mine" : "") + '">'
      + '<div class="vote-result-head"><span>' + (mine ? "✓ " : "") + label
      + '</span><b>' + (vote.mode === "shares" ? num(count) + " 股" : num(count) + " 票")
      + ' · ' + percent + '%</b></div>'
      + '<div class="vote-result-track"><span style="transform:scaleX('
      + (percent / 100) + ')"></span></div></div>';
  }).join("");
  const details = (vote.mode === "shares"
    && Array.isArray(vote.details) && vote.details.length)
    ? '<details class="vote-details"><summary>投票明细（实名可审计）</summary>'
      + vote.details.map(row => '<div class="vote-detail-row"><span>'
        + escapeHtml(row.name || "成员") + '</span><span>' + num(row.shares)
        + ' 股</span><span>' + voteCenterChoiceLabel(row.choice) + '</span></div>').join("")
      + '</details>'
    : "";
  const weightText = vote.mode === "shares"
    ? "我的 " + num(vote.my_weight) + " 股" : "一人一票";
  const totalText = vote.mode === "shares"
    ? "已投 " + num(vote.cast_shares) + " / " + num(vote.eligible_shares) + " 股"
    : "已有 " + num(vote.cast_count) + " 人投票";
  const changeButtons = (showResults && open && vote.can_vote)
    ? '<div class="vote-change"><span class="meta">改投</span>'
      + choiceButtons + '</div>' : "";
  return '<article class="vote-card">'
    + '<div class="vote-card-head"><div><span class="vote-mode">'
    + voteCenterModeLabel(vote.mode) + '</span><b>'
    + escapeHtml(vote.title || "投票") + '</b></div>'
    + '<span class="vote-status ' + (open ? "open" : "closed") + '">'
    + escapeHtml(voteCenterResultText(vote)) + '</span></div>'
    + (vote.description
      ? '<div class="vote-desc">' + escapeHtml(vote.description) + '</div>' : '')
    + '<div class="vote-meta">' + escapeHtml([
      weightText,
      voteCenterBpsText(vote.quorum_bps),
      voteCenterRemaining(vote.closes_at),
    ].filter(Boolean).join(" · ")) + '</div>'
    + '<div class="vote-meta">' + escapeHtml(totalText) + '</div>'
    + (showResults ? '<div class="vote-results">' + resultRows + '</div>' : choiceButtons)
    + changeButtons
    + (my ? '<div class="vote-my">你已投「' + voteCenterChoiceLabel(my) + '」'
      + (open ? "，截止前可改票" : "") + '</div>'
      : (open ? '<div class="vote-hint">投完可看结果</div>' : ''))
    + details
    + '<div class="vote-card-foot"><span>' + escapeHtml(vote.creator_name || "成员")
    + ' 发起</span>' + (open && vote.can_close
      ? '<button class="community-link-btn" data-vote-close="'
        + escapeHtml(vote.id) + '">结束投票</button>' : '') + '</div>'
    + '</article>';
}

function renderVoteCenter() {
  const box = $("vote-center-list");
  const tabs = $("vote-center-tabs");
  const sub = $("vote-center-sub");
  const create = $("btn-vote-create");
  if (!box) return;
  const scope = voteCenterState.scope;
  const votes = Array.isArray(voteCenterState.votes) ? voteCenterState.votes : [];
  const polls = Array.isArray(voteCenterState.polls) ? voteCenterState.polls : [];
  const governance = scope === "pending" ? voteCenterGovernancePending() : [];
  if (sub) sub.textContent = scope === "pending" ? "待你投票的事项都在这里"
    : scope === "closed" ? "已结束的正式投票" : "全部正式投票";
  if (tabs) {
    tabs.innerHTML = voteCenterTabs().map(([value, label]) =>
      '<button class="chip' + (value === scope ? " on" : "") + '" data-vote-tab="'
      + value + '">' + label + '</button>').join("");
    tabs.querySelectorAll("[data-vote-tab]").forEach(button => {
      button.onclick = () => {
        voteCenterState.scope = button.dataset.voteTab;
        voteCenterState.lastLoad = 0;
        loadVoteCenter(true);
      };
    });
  }
  if (create) {
    create.classList.toggle("hidden",
      !(voteCenterCanCreate("headcount") || voteCenterCanCreate("shares")));
  }
  if (voteCenterState.loading) {
    box.innerHTML = voteCenterEmpty("正在加载投票", "正在读取待投事项…");
    return;
  }
  if (voteCenterState.error) {
    box.innerHTML = voteCenterEmpty("投票中心暂时不可用", voteCenterState.error);
    return;
  }
  if (!votes.length && !polls.length && !governance.length) {
    box.innerHTML = voteCenterEmpty(
      scope === "pending" ? "暂无待你投票的事项" : "还没有投票",
      scope === "pending" ? "有新的正式投票或社区投票时会出现在这里。"
        : "有发起权限的成员可以发起正式投票。");
    return;
  }
  box.innerHTML = (governance.length ? voteCenterGovernanceHtml(governance) : "")
    + (votes.length ? '<div class="section-head"><span>正式投票</span><span class="meta">'
      + votes.length + ' 项</span></div>' + votes.map(voteCenterCard).join("") : "")
    + (polls.length ? '<div class="section-head"><span>社区投票</span><span class="meta">'
      + polls.length + ' 项</span></div>'
      + polls.map(poll => '<div class="vote-community-poll">'
        + communityPollHtml(poll) + '</div>').join("") : "");
  bindVoteCenterActions(box);
}

function bindVoteCenterActions(box) {
  box.querySelectorAll("[data-vote-cast]").forEach(button => {
    button.onclick = () => castEnterpriseVote(button.dataset.voteCast, button.dataset.voteChoice);
  });
  box.querySelectorAll("[data-vote-close]").forEach(button => {
    button.onclick = () => closeEnterpriseVote(button.dataset.voteClose);
  });
  box.querySelectorAll("[data-vote-governance]").forEach(button => {
    button.onclick = () => {
      showPage("identity");
      setTimeout(() => {
        const target = document.getElementById(button.dataset.voteGovernance);
        if (target) target.scrollIntoView({ behavior: "smooth", block: "start" });
      }, 120);
    };
  });
  box.querySelectorAll("[data-poll-vote]").forEach(button => {
    button.onclick = () => voteCommunityPoll(button.dataset.pollVote, button.dataset.pollOption);
  });
  box.querySelectorAll("[data-poll-close]").forEach(button => {
    button.onclick = () => closeCommunityPoll(button.dataset.pollClose);
  });
}

async function loadVoteCenter(force) {
  if (!DB.profile || !initCloud()) return;
  const now = Date.now();
  if (!force && voteCenterState.lastLoad && now - voteCenterState.lastLoad < 5000) {
    renderVoteCenter();
    return;
  }
  voteCenterState.loading = true;
  voteCenterState.error = "";
  renderVoteCenter();
  try {
    const scope = voteCenterState.scope;
    if (scope === "pending") {
      const [votesResult, pollsResult] = await Promise.all([
        cloudClient.rpc("list_enterprise_votes", { p_scope: "pending", p_limit: 100 }),
        cloudClient.rpc("list_pending_community_polls", {}),
      ]);
      if (votesResult.error) throw votesResult.error;
      if (pollsResult.error) throw pollsResult.error;
      voteCenterState.votes = Array.isArray(votesResult.data && votesResult.data.votes)
        ? votesResult.data.votes : [];
      voteCenterState.polls = Array.isArray(pollsResult.data && pollsResult.data.polls)
        ? pollsResult.data.polls : [];
      if (typeof refreshIdentity === "function") refreshIdentity(false);
      if (typeof loadShareholderMeetings === "function") loadShareholderMeetings(false);
    } else {
      const result = await cloudClient.rpc("list_enterprise_votes", {
        p_scope: scope, p_limit: 100,
      });
      if (result.error) throw result.error;
      voteCenterState.votes = Array.isArray(result.data && result.data.votes)
        ? result.data.votes : [];
      voteCenterState.polls = [];
    }
    voteCenterState.lastLoad = Date.now();
  } catch (error) {
    voteCenterState.error = voteCenterErrorText(error);
    voteCenterState.votes = [];
    voteCenterState.polls = [];
  } finally {
    voteCenterState.loading = false;
    renderVoteCenter();
  }
}

function voteCenterErrorText(error) {
  const text = String(error && error.message || error || "");
  if (/could not find|does not exist|function/i.test(text)) return "投票中心还没注入 SQL";
  if (/not allowed to create/i.test(text)) return "当前身份不能发起这种投票";
  if (/only shareholders/i.test(text)) return "只有股东能参与按股份投票";
  if (/vote closed/i.test(text)) return "投票已经截止";
  if (/not an enterprise member/i.test(text)) return "只有本公司成员能参与投票";
  if (/close time/i.test(text)) return "截止时间需在未来 30 天内";
  if (/title must/i.test(text)) return "标题请控制在 1–120 字";
  if (/not allowed/i.test(text)) return "只有发起人或老板能结束投票";
  return text || "投票操作失败";
}

async function castEnterpriseVote(voteId, choice) {
  if (!DB.profile || !initCloud()) return;
  try {
    const result = await cloudClient.rpc("cast_enterprise_vote", {
      p_vote: voteId, p_choice: choice, p_note: "",
    });
    if (result.error) throw result.error;
    toast("已投票");
    await loadVoteCenter(true);
  } catch (error) {
    toast(voteCenterErrorText(error));
  }
}

async function closeEnterpriseVote(voteId) {
  if (!DB.profile || !initCloud()) return;
  if (!confirm("结束这个投票？结束后不能再改票。")) return;
  try {
    const result = await cloudClient.rpc("close_enterprise_vote", { p_vote: voteId });
    if (result.error) throw result.error;
    toast("投票已结束");
    await loadVoteCenter(true);
  } catch (error) {
    toast(voteCenterErrorText(error));
  }
}

function openVoteCreateSheet() {
  if (!DB.profile) { toast("登录后才能发起投票"); return; }
  const modes = [];
  if (voteCenterCanCreate("headcount")) modes.push(["headcount", "按人数投票（一人一票）"]);
  if (voteCenterCanCreate("shares")) modes.push(["shares", "按股份投票（一股一票）"]);
  if (!modes.length) { toast("当前身份不能发起正式投票"); return; }
  const d = new Date(Date.now() + 3 * 24 * 3600 * 1000);
  const local = new Date(d.getTime() - d.getTimezoneOffset() * 60000)
    .toISOString().slice(0, 16);
  openSheet("发起投票", `
    <label for="vote-title">标题</label>
    <input id="vote-title" maxlength="120" placeholder="要大家决定什么？">
    <label for="vote-desc">说明（可选）</label>
    <textarea id="vote-desc" maxlength="2000" placeholder="背景、影响和投票依据"></textarea>
    <label for="vote-mode">计票方式</label>
    <select id="vote-mode">${modes.map(([value, label]) =>
      `<option value="${value}">${escapeHtml(label)}</option>`).join("")}</select>
    <label for="vote-closes">截止时间</label>
    <input id="vote-closes" type="datetime-local" value="${local}">
    <label for="vote-quorum">出席门槛（%）</label>
    <input id="vote-quorum" type="number" min="0" max="100" value="50">
  `, [
    { label: "取消", kind: "ghost", onClick: closeSheet },
    { label: "发起投票", kind: "", onClick: submitEnterpriseVote },
  ]);
}

async function submitEnterpriseVote() {
  if (!DB.profile || !initCloud()) return;
  const title = String(($("vote-title") || {}).value || "").trim();
  const desc = String(($("vote-desc") || {}).value || "").trim();
  const mode = String(($("vote-mode") || {}).value || "headcount");
  const closesRaw = String(($("vote-closes") || {}).value || "");
  const quorum = Number(($("vote-quorum") || {}).value || 50);
  const closes = new Date(closesRaw);
  if (!title) { toast("先写投票标题"); return; }
  if (!closesRaw || !isFinite(closes.getTime())) { toast("请选择截止时间"); return; }
  if (closes.getTime() <= Date.now()) { toast("截止时间要晚于现在"); return; }
  if (!voteCenterCanCreate(mode)) { toast("当前身份不能发起这种投票"); return; }
  try {
    const result = await cloudClient.rpc("create_enterprise_vote", {
      p_title: title,
      p_description: desc,
      p_mode: mode,
      p_closes_at: closes.toISOString(),
      p_quorum_bps: Math.round(Math.max(0, Math.min(100, quorum)) * 100),
    });
    if (result.error) throw result.error;
    closeSheet();
    toast("投票已发起");
    voteCenterState.scope = "pending";
    await loadVoteCenter(true);
  } catch (error) {
    toast(voteCenterErrorText(error));
  }
}

function bindVoteCenterEvents() {
  if ($("btn-vote-create")) $("btn-vote-create").onclick = openVoteCreateSheet;
  if ($("btn-vote-refresh")) {
    $("btn-vote-refresh").onclick = () => {
      voteCenterState.lastLoad = 0;
      loadVoteCenter(true);
      if (typeof refreshIdentity === "function") refreshIdentity(true);
      if (typeof loadShareholderMeetings === "function") loadShareholderMeetings(true);
    };
  }
}
