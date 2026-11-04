/* =============================================================
   知识星球社区

   和任务/项目不同，社区消息必须放在云端：只有所有人读同一张表，
   “每个人都能看到并发言”才成立。这里不做本地假数据。
   ============================================================= */
"use strict";

const COMMUNITY_TOPICS = ["分享", "提问", "经验", "灵感", "公告"];
let communityPosts = [];
let communityTopic = "分享";
let communityLoading = false;
let communityLastLoad = 0;
let communityChannel = null;

function communityEscape(value) {
  return escapeHtml(String(value == null ? "" : value));
}

function communityTime(value) {
  const text = String(value || "");
  if (!text) return "";
  const when = new Date(text);
  if (Number.isNaN(when.getTime())) return text.slice(0, 16).replace("T", " ");
  const seconds = Math.max(0, Math.round((Date.now() - when.getTime()) / 1000));
  if (seconds < 60) return "刚刚";
  if (seconds < 3600) return Math.floor(seconds / 60) + " 分钟前";
  if (seconds < 86400) return Math.floor(seconds / 3600) + " 小时前";
  if (seconds < 86400 * 7) return Math.floor(seconds / 86400) + " 天前";
  return (when.getMonth() + 1) + "月" + when.getDate() + "日 "
    + String(when.getHours()).padStart(2, "0") + ":"
    + String(when.getMinutes()).padStart(2, "0");
}

function communityRoleLabel(role) {
  return role === "boss" ? "老板" : "员工";
}

function communityTopicButtons() {
  const box = $("community-topics");
  if (!box) return;
  box.innerHTML = COMMUNITY_TOPICS.map(topic =>
    '<button class="chip' + (topic === communityTopic ? " on" : "")
    + '" data-community-topic="' + communityEscape(topic) + '">'
    + communityEscape(topic) + "</button>"
  ).join("");
  box.querySelectorAll("[data-community-topic]").forEach(button => {
    button.onclick = () => {
      communityTopic = button.dataset.communityTopic;
      communityTopicButtons();
    };
  });
}

function communityEmpty(title, text) {
  return '<div class="community-empty"><b>' + communityEscape(title)
    + '</b><span>' + communityEscape(text) + "</span></div>";
}

function renderCommunityFeed() {
  const feed = $("community-feed");
  const status = $("community-status");
  if (!feed) return;

  if (!DB.profile) {
    feed.innerHTML = communityEmpty(
      "登录后进入星球广场",
      "社区消息对所有成员可见。登录你的账号后，就能看到大家发的消息，也能发布消息。"
    );
    if (status) status.textContent = "尚未登录";
    return;
  }

  if (communityLoading && !communityPosts.length) {
    feed.innerHTML = communityEmpty("正在同步", "正在从星球读取最新消息…");
    if (status) status.textContent = "加载中…";
    return;
  }

  if (!communityPosts.length) {
    feed.innerHTML = communityEmpty(
      "这里还很安静",
      "还没有人发消息。你可以成为第一个，把此刻的问题、经验或灵感发到星球上。"
    );
    if (status) status.textContent = "0 条";
    return;
  }

  const ledger = DB.pointState && Array.isArray(DB.pointState.ledger)
    ? DB.pointState.ledger : [];
  feed.innerHTML = communityPosts.map(post => {
    const mine = DB.profile && post.author_id === DB.profile.id;
    const initial = communityEscape(String(post.author_name || "成").slice(0, 1));
    const role = post.author_role === "boss" ? "boss" : "staff";
    const cost = num(post.unlock_cost);
    const unlocked = ledger.some(entry =>
      entry.entry_type === "unlock"
      && String(entry.evidence_id) === String(post.id));
    const required = !!post.is_required;
    const locked = typeof post.locked === "boolean"
      ? post.locked : (!mine && !required && !unlocked && cost > 0);
    const access = required ? '<span class="community-access required">必读</span>'
      : cost > 0 ? `<span class="community-access${unlocked || mine ? " unlocked" : ""}">${
          unlocked || mine ? "已解锁" : cost + " 积分"
        }</span>` : "";
    const body = locked
      ? '<div class="community-locked"><b>这是付费知识</b>'
        + `<span>${communityEscape(post.preview || "解锁后可永久查看全文")}</span>`
        + `<span>使用 ${cost} 积分后可永久查看。</span>`
        + `<button class="btn" data-community-unlock="${
          communityEscape(post.id)
        }">解锁全文</button></div>`
      : communityEscape(post.content || post.preview || "");
    return '<article class="community-post">'
      + '<div class="community-post-head">'
      + '<span class="community-avatar ' + role + '">' + initial + "</span>"
      + '<div class="grow"><div class="community-author-row"><b>'
      + communityEscape(post.author_name || "成员") + "</b>"
      + '<span class="community-role">' + communityRoleLabel(post.author_role)
      + "</span>" + (mine ? '<span class="community-mine">我</span>' : "")
      + access + "</div><div class=\"community-meta\">"
      + communityEscape(post.topic || "分享") + " · "
      + communityTime(post.created_at) + "</div></div>"
      + (mine ? '<button class="community-delete" data-community-delete="'
        + communityEscape(post.id) + '">删除</button>' : "")
      + "</div>"
      + '<div class="community-post-body">' + body + "</div></article>";
  }).join("");

  feed.querySelectorAll("[data-community-delete]").forEach(button => {
    button.onclick = () => deleteCommunityPost(button.dataset.communityDelete);
  });
  feed.querySelectorAll("[data-community-unlock]").forEach(button => {
    button.onclick = () => {
      button.disabled = true;
      unlockKnowledgePost(button.dataset.communityUnlock).finally(() => {
        button.disabled = false;
      });
    };
  });
  if (status) status.textContent = communityPosts.length + " 条 · 刚刚更新";
}

function renderCommunity() {
  const profile = DB.profile;
  const sub = $("community-sub");
  const me = $("community-me");
  const input = $("community-input");
  const send = $("btn-community-send");
  if (!sub || !input || !send) return;

  if (!profile) {
    sub.textContent = "登录后加入全员社区";
    me.textContent = "尚未登录";
  } else {
    sub.textContent = profile.name + " · " + communityRoleLabel(profile.role)
      + " · 所有成员共享同一条消息流";
    me.textContent = profile.name;
  }

  communityTopicButtons();
  input.value = input.value || "";
  input.disabled = !profile;
  send.disabled = !profile || communityLoading;
  send.textContent = communityLoading ? "处理中…" : "发布";

  const count = $("community-count");
  if (count) count.textContent = String(input.value.length) + " / 2000";
  input.oninput = () => {
    if (count) count.textContent = String(input.value.length) + " / 2000";
    if (input.value.length > 2000 && count) count.style.color = "var(--severe)";
    else if (count) count.style.color = "";
  };

  if (!profile) {
    renderCommunityFeed();
    return;
  }

  ensureCommunitySubscription();
  if (!communityPosts.length
      || Date.now() - communityLastLoad > 12000) {
    loadCommunityPosts(false);
  } else {
    renderCommunityFeed();
  }
}

function communityErrorText(error) {
  const text = String((error && (error.message || error.details || error.hint))
    || error || "社区请求失败");
  if (/community_posts/i.test(text)
      && /(does not exist|not found|could not find)/i.test(text)) {
    return "社区数据表还没创建。请管理员在 Supabase SQL Editor 运行 mobile/sql/community.sql";
  }
  if (/could not find the function|function .* does not exist/i.test(text)) {
    return "社区服务还没安装。请管理员运行 mobile/sql/community.sql";
  }
  if (/jwt expired|not signed in/i.test(text)) return "登录状态过期了，请重新登录。";
  if (/network|fetch|failed to fetch/i.test(text)) return "连不上社区服务器，请检查网络。";
  return text;
}

async function loadCommunityPosts(force) {
  if (!DB.profile || communityLoading) return;
  const now = Date.now();
  if (!force && communityLastLoad && now - communityLastLoad < 6000) return;
  if (!initCloud()) {
    communityPosts = [];
    communityLoading = false;
    renderCommunityFeed();
    const status = $("community-status");
    if (status) status.textContent = "云服务未连接";
    return;
  }

  communityLoading = true;
  const send = $("btn-community-send");
  if (send) {
    send.disabled = true;
    send.textContent = "同步中…";
  }
  const status = $("community-status");
  if (status) status.textContent = "同步中…";
  try {
    const result = await cloudClient.rpc("list_knowledge_posts", {
      p_limit: 80,
    });
    if (result.error) throw result.error;
    communityPosts = Array.isArray(result.data) ? result.data : [];
    communityLastLoad = Date.now();
  } catch (error) {
    communityPosts = [];
    communityLastLoad = Date.now();
    const feed = $("community-feed");
    if (feed) {
      feed.innerHTML = communityEmpty("社区暂时没有加载出来",
        communityErrorText(error));
    }
    if (status) status.textContent = "加载失败";
    return;
  } finally {
    communityLoading = false;
    const button = $("btn-community-send");
    if (button) {
      button.disabled = !DB.profile;
      button.textContent = "发布";
    }
  }
  renderCommunityFeed();
}

async function submitCommunityPost() {
  if (!DB.profile || communityLoading) return;
  const input = $("community-input");
  if (!input) return;
  const content = input.value.trim();
  if (!content) {
    toast("先写点内容再发送");
    input.focus();
    return;
  }
  if (content.length > 2000) {
    toast("消息请控制在 2000 字以内");
    return;
  }
  if (!initCloud()) {
    toast("云服务没有连接上");
    return;
  }

  communityLoading = true;
  const send = $("btn-community-send");
  if (send) {
    send.disabled = true;
    send.textContent = "发送中…";
  }
  try {
    const result = await cloudClient.rpc("post_community_message", {
      p_content: content,
      p_topic: communityTopic,
      p_unlock_cost: Number(($("community-unlock-cost") || {}).value || 0),
      p_is_required: !!($("community-required") || {}).checked,
    });
    if (result.error) throw result.error;
    input.value = "";
    toast("已发布，所有成员都能看到");
    communityLastLoad = 0;
  } catch (error) {
    toast(communityErrorText(error));
  } finally {
    communityLoading = false;
    renderCommunity();
    await loadCommunityPosts(true);
  }
}

async function deleteCommunityPost(postId) {
  if (!DB.profile || !postId || !initCloud()) return;
  if (!confirm("确定从社区删除这条消息吗？所有成员都将看不到它。")) return;
  try {
    const result = await cloudClient.rpc("delete_my_community_message", {
      p_post_id: String(postId),
    });
    if (result.error) throw result.error;
    communityLastLoad = 0;
    await loadCommunityPosts(true);
    toast("消息已删除");
  } catch (error) {
    toast(communityErrorText(error));
  }
}

function ensureCommunitySubscription() {
  if (!DB.profile || !initCloud() || communityChannel) return;
  try {
    communityChannel = cloudClient.channel("knowledge-planet-community")
      .on("postgres_changes", {
        event: "*", schema: "public", table: "community_posts",
      }, () => {
        communityLastLoad = 0;
        loadCommunityPosts(true);
      })
      .subscribe();
  } catch (error) {
    communityChannel = null;
  }
}
