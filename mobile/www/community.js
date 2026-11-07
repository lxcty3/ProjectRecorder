/* =============================================================
   知识星球 · v2.1 community foundation
   Boards -> posts -> comments, with server-side permissions.
   ============================================================= */
"use strict";

const COMMUNITY_TOPICS = ["分享", "提问", "经验", "灵感", "公告"];
let communityPosts = [];
let communityBoards = [];
let communityAccess = {};
let communityCurrentBoard = "";
let communityTopic = "分享";
let communitySearch = "";
let communityBookmarkedOnly = false;
let communityLoading = false;
let communityBoardsLoading = false;
let communityLastLoad = 0;
let communityCursor = null;
let communityHasMore = false;
let communityChannel = null;
let communityUnread = 0;
let communityNotifications = [];
let communityNotificationsVisible = false;
let communityCommentCache = {};
let communityReplyParent = {};
let communitySeenNotifications = new Set();
let communityNotificationTimer = null;
let communityAdminEditing = "";
let communityAdminStats = null;
let communityAuthorCardCache = {};
let communityAuthorCardWarningShown = false;

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
  return role === "boss" ? "老板" : "成员";
}

function communityAuthorCard(profileId) {
  return communityAuthorCardCache[String(profileId || "")] || null;
}

function communityAuthorAvatarHtml(profileId, name, role) {
  const card = communityAuthorCard(profileId) || {};
  const url = String(card.avatar_url || "").trim();
  const className = role === "boss" ? "boss" : "staff";
  if (url) {
    return '<span class="community-avatar ' + className + ' has-image">'
      + '<img src="' + communityEscape(url) + '" alt=""></span>';
  }
  return '<span class="community-avatar ' + className + '">'
    + communityEscape(String(name || "成").slice(0, 1)) + '</span>';
}

function communityAuthorRoleText(profileId, fallbackRole) {
  const card = communityAuthorCard(profileId);
  const companyName = card && (card.company_name || card.primary_company_name);
  if (companyName) {
    const roleText = card.role_key && typeof identityRoleLabel === "function"
      ? identityRoleLabel(card.role_key)
      : (card.role_name || card.role_key || communityRoleLabel(fallbackRole));
    return companyName + " · " + roleText;
  }
  return communityRoleLabel(fallbackRole);
}

async function hydrateCommunityAuthors(rows) {
  const list = Array.isArray(rows) ? rows : [];
  const ids = Array.from(new Set(list.map(item => String(item.author_id || ""))
    .filter(Boolean)));
  const missing = ids.filter(id => !communityAuthorCardCache[id]);
  if (missing.length && initCloud()) {
    try {
      const result = await cloudClient.rpc("get_community_author_cards", {
        p_profiles: missing,
      });
      if (result.error) {
        console.warn("社区作者卡加载失败", result.error.message || result.error);
        const fallback = await Promise.all(missing.map(async profileId => {
          try {
            const card = await cloudClient.rpc("get_community_user_profile", {
              p_profile: profileId,
            });
            if (card.error) return null;
            return Object.assign({ profile_id: profileId }, card.data || {});
          } catch (_) {
            return null;
          }
        }));
        fallback.filter(Boolean).forEach(item => {
          communityAuthorCardCache[String(item.profile_id)] = item;
        });
        if (!communityAuthorCardWarningShown && typeof toast === "function") {
          communityAuthorCardWarningShown = true;
          toast("社区头像已恢复；主公司职业数据仍待更新 SQL");
        }
      } else {
        const authors = result.data && result.data.authors;
        (Array.isArray(authors) ? authors : []).forEach(item => {
          communityAuthorCardCache[String(item.profile_id)] = item;
        });
      }
    } catch (error) {
      console.warn("社区作者卡加载失败", error.message || error);
    }
  }
  list.forEach(item => {
    const card = communityAuthorCard(item.author_id);
    if (!card) return;
    item.author_avatar_url = card.avatar_url || "";
    item.author_primary_company_name = card.company_name || "";
    item.author_role_key = card.role_key || "";
    item.author_role_name = card.role_name || "";
  });
  return list;
}

function communityCurrentBoardRow() {
  return communityBoards.find(board => String(board.id) === String(communityCurrentBoard));
}

function communityEmpty(title, text) {
  return '<div class="community-empty"><b>' + communityEscape(title)
    + '</b><span>' + communityEscape(text) + "</span></div>";
}

function communityErrorText(error) {
  const text = String((error && (error.message || error.details || error.hint))
    || error || "社区请求失败");
  if (/community-forum-v1|list_community_posts_v2|community_boards/i.test(text)
      && /(does not exist|not found|could not find)/i.test(text)) {
    return "社区 v2.1 数据尚未安装，请管理员运行 mobile/sql/community-forum-v1.sql";
  }
  if (/jwt expired|not signed in/i.test(text)) return "登录状态过期了，请重新登录。";
  if (/permission denied|access denied|posting denied/i.test(text)) {
    return "当前身份没有这个板块的操作权限。";
  }
  if (/network|fetch|failed to fetch/i.test(text)) return "连不上社区服务器，请检查网络。";
  return text;
}

function communitySetUnread(value) {
  communityUnread = Math.max(0, Number(value) || 0);
  const badge = $("community-unread");
  if (badge) {
    badge.textContent = String(communityUnread);
    badge.classList.toggle("hidden", communityUnread < 1);
  }
}

function renderCommunityBoards() {
  const box = $("community-boards");
  if (!box) return;
  const all = '<button class="chip' + (!communityCurrentBoard ? " on" : "")
    + '" data-community-board="">全部</button>';
  box.innerHTML = all + communityBoards.map(board =>
    '<button class="chip' + (String(board.id) === String(communityCurrentBoard) ? " on" : "")
    + '" data-community-board="' + communityEscape(board.id) + '">'
    + communityEscape(board.icon || "*") + " " + communityEscape(board.name)
    + (board.followed ? ' <span class="community-follow-dot">•</span>' : "")
    + "</button>").join("");
  box.querySelectorAll("[data-community-board]").forEach(button => {
    button.onclick = () => {
      communityCurrentBoard = button.dataset.communityBoard || "";
      renderCommunityBoards();
      renderCommunityBoardSelect();
      communityLastLoad = 0;
      communityCursor = null;
      loadCommunityPosts(true);
    };
  });
}

function renderCommunityBoardSelect() {
  const select = $("community-board-select");
  if (!select) return;
  const available = communityBoards.filter(board => board.allow_posts);
  const wanted = communityCurrentBoard
    || (available[0] && String(available[0].id)) || "";
  if (!available.some(board => String(board.id) === String(wanted)) && available.length) {
    communityCurrentBoard = String(available[0].id);
  }
  select.innerHTML = available.map(board =>
    '<option value="' + communityEscape(board.id) + '">'
    + communityEscape(board.icon || "*") + " "
    + communityEscape(board.name) + "</option>").join("");
  if (communityCurrentBoard) select.value = String(communityCurrentBoard);
  select.disabled = !DB.profile || !available.length;
}

function renderCommunityFilterRow() {
  const label = $("community-filter-label");
  if (label) {
    const board = communityCurrentBoardRow();
    label.textContent = communityBookmarkedOnly
      ? "我的收藏"
      : communitySearch ? "搜索结果：" + communitySearch
      : board ? board.name : "全部讨论";
  }
  const bookmarks = $("btn-community-bookmarks");
  if (bookmarks) bookmarks.classList.toggle("on", communityBookmarkedOnly);
  const manage = $("btn-community-manage");
  if (manage) manage.classList.toggle("hidden", !communityAccess.can_manage);
  document.querySelectorAll(".community-admin-only").forEach(node => {
    node.classList.toggle("hidden", !communityAccess.can_manage);
  });
  communitySetUnread(communityUnread);
}

function renderCommunityNotifications() {
  const panel = $("community-notifications-panel");
  if (!panel) return;
  panel.classList.toggle("hidden", !communityNotificationsVisible);
  if (!communityNotificationsVisible) return;
  const readButton = '<button class="chip" id="btn-community-read-all">全部标为已读</button>';
  panel.innerHTML = '<div class="card-head"><h3>社区通知</h3>'
    + '<span class="meta">' + communityUnread + ' 条未读</span></div>'
    + (communityNotifications.length
      ? communityNotifications.map(item =>
        '<button class="community-notification-row' + (item.read_at ? "" : " unread")
        + '" data-community-notification="' + communityEscape(item.id)
        + '" data-community-notification-post="' + communityEscape(item.post_id || "")
        + '" data-community-notification-board="' + communityEscape(item.board_id || "")
        + '"><span><b>' + communityEscape(item.title) + '</b><small>'
        + communityEscape(item.body || communityTime(item.created_at))
        + '</small></span><i>' + communityTime(item.created_at) + "</i></button>").join("")
      : '<div class="community-empty"><b>暂时没有通知</b>'
        + '<span>有人回复、提到你或关注的板块有新帖时，会显示在这里。</span></div>')
    + (communityNotifications.length ? '<div class="community-notification-actions">'
      + readButton + "</div>" : "");
  panel.querySelectorAll("[data-community-notification]").forEach(button => {
    button.onclick = () => {
      const board = button.dataset.communityNotificationBoard;
      if (board) {
        communityCurrentBoard = board;
        renderCommunityBoards();
        renderCommunityBoardSelect();
      }
      communityNotificationsVisible = false;
      renderCommunityNotifications();
      markCommunityNotificationRead(button.dataset.communityNotification);
      communityLastLoad = 0;
      loadCommunityPosts(true);
    };
  });
  const readAll = $("btn-community-read-all");
  if (readAll) readAll.onclick = () => markCommunityNotificationRead(null);
}

function communityTopicButtons() {
  const box = $("community-topics");
  if (!box) return;
  box.innerHTML = COMMUNITY_TOPICS.map(topic =>
    '<button class="chip' + (topic === communityTopic ? " on" : "")
    + '" data-community-topic="' + communityEscape(topic) + '">'
    + communityEscape(topic) + "</button>").join("");
  box.querySelectorAll("[data-community-topic]").forEach(button => {
    button.onclick = () => {
      communityTopic = button.dataset.communityTopic;
      communityTopicButtons();
    };
  });
}

function renderCommunity() {
  const sub = $("community-sub");
  const me = $("community-me");
  const input = $("community-input");
  const send = $("btn-community-send");
  const count = $("community-count");
  if (!sub || !me || !input || !send) return;
  bindCommunityToolbar();
  communityTopicButtons();
  renderCommunityBoards();
  renderCommunityBoardSelect();
  renderCommunityFilterRow();
  renderCommunityNotifications();
  if (count) count.textContent = input.value.length + " / 2000";
  if (!DB.profile) {
    sub.textContent = "登录后进入板块讨论";
    me.textContent = "尚未登录";
    input.disabled = true;
    send.disabled = true;
    renderCommunityFeed();
    return;
  }
  sub.textContent = "板块、讨论与伙伴经验都在这里";
  me.textContent = DB.profile.name + " · " + communityRoleLabel(DB.profile.role);
  input.disabled = false;
  send.disabled = communityLoading;
  ensureCommunitySubscription();
  if (!communityBoards.length || !communityLastLoad
      || Date.now() - communityLastLoad > 12000) {
    loadCommunityBoards(!communityBoards.length).then(() => loadCommunityPosts(false));
  } else {
    renderCommunityFeed();
  }
  loadCommunityNotifications(false);
  if (!communityNotificationTimer && typeof setInterval === "function") {
    communityNotificationTimer = setInterval(() => loadCommunityNotifications(false), 15000);
  }
}

function communityPostTags(post) {
  const tags = [];
  if (post.pinned) tags.push('<span class="community-state pinned">置顶</span>');
  if (post.featured) tags.push('<span class="community-state featured">精选</span>');
  if (post.is_required) tags.push('<span class="community-access required">必读</span>');
  if (num(post.unlock_cost) > 0) {
    tags.push('<span class="community-access' + (post.locked ? "" : " unlocked") + '">'
      + (post.locked ? num(post.unlock_cost) + " 积分" : "已解锁") + "</span>");
  }
  if (post.board_name) tags.push('<span class="community-board-tag">'
    + communityEscape((post.board_icon || "*") + " " + post.board_name) + "</span>");
  return tags.join("");
}

function communityCommentHtml(postId, comment) {
  const commentCard = communityAuthorCard(comment.author_id) || {};
  const commentAvatar = String(commentCard.avatar_url || "").trim();
  return '<div class="community-comment" data-comment-id="' + communityEscape(comment.id) + '">'
    + '<span class="community-comment-avatar' + (commentAvatar ? ' has-image' : '') + '">'
    + (commentAvatar
      ? '<img src="' + communityEscape(commentAvatar) + '" alt="">'
      : communityEscape(String(comment.author_name || "成").slice(0, 1))) + "</span>"
    + '<div><div class="community-comment-head"><b>'
    + communityEscape(comment.author_name || "成员") + "</b><span>"
    + communityTime(comment.created_at) + "</span></div><p>"
    + communityEscape(comment.body || "") + "</p>"
    + '<button class="community-link-btn" data-community-reply="'
    + communityEscape(comment.id) + '" data-community-reply-post="'
    + communityEscape(postId) + '" data-community-reply-name="'
    + communityEscape(comment.author_name || "成员") + '">回复</button></div></div>';
}

function communityCommentsHtml(postId) {
  const cached = communityCommentCache[postId];
  if (!cached) return '<div class="community-comments-loading">正在加载评论…</div>';
  const comments = Array.isArray(cached.comments) ? cached.comments : [];
  const reply = communityReplyParent[postId];
  return (comments.length
      ? comments.map(item => communityCommentHtml(postId, item)).join("")
      : '<div class="community-comments-empty">还没有评论，来留下第一条回复。</div>')
    + (reply ? '<div class="community-reply-hint">正在回复 '
      + communityEscape(reply.name) + '<button data-community-cancel-reply="'
      + communityEscape(postId) + '">取消</button></div>' : "")
    + '<div class="community-comment-form"><textarea data-community-comment-input="'
    + communityEscape(postId) + '" maxlength="4000" placeholder="'
    + (reply ? "回复 " + communityEscape(reply.name) : "写下你的回复…")
    + '"></textarea><button class="btn" data-community-comment-send="'
    + communityEscape(postId) + '">发送评论</button></div>';
}

function renderCommunityPost(post) {
  const mine = DB.profile && String(post.author_id) === String(DB.profile.id);
  const initial = communityEscape(String(post.author_name || "成").slice(0, 1));
  const body = post.locked
    ? '<div class="community-locked"><b>这是积分解锁内容</b>'
      + '<span>' + communityEscape(post.preview || "解锁后可永久查看全文") + "</span>"
      + '<span>使用 ' + num(post.unlock_cost) + " 积分后可永久查看。</span>"
      + '<button class="btn" data-community-unlock="' + communityEscape(post.id)
      + '">解锁全文</button></div>'
    : '<div class="community-post-body">' + communityEscape(post.content || post.preview || "")
      + "</div>";
  const commentsOpen = Object.prototype.hasOwnProperty.call(communityCommentCache, post.id);
  const admin = communityAccess.can_manage
    ? '<button class="community-link-btn" data-community-moderate="' + communityEscape(post.id)
      + '" data-pinned="' + (post.pinned ? "1" : "0") + '" data-featured="'
      + (post.featured ? "1" : "0") + '">管理</button>'
    : "";
  return '<article class="community-post" data-post-id="' + communityEscape(post.id) + '">'
    + '<div class="community-post-head">' + communityAuthorAvatarHtml(
      post.author_id, post.author_name, post.author_role)
    + '<div class="grow"><div class="community-author-row"><b>'
    + communityEscape(post.author_name || "成员") + "</b>"
    + '<span class="community-role">' + communityEscape(
      communityAuthorRoleText(post.author_id, post.author_role))
    + "</span>" + communityPostTags(post) + (mine ? '<span class="community-mine">我</span>' : "")
    + '</div><div class="community-meta">' + communityEscape(post.topic || "分享")
    + " · " + communityTime(post.created_at) + "</div></div>"
    + (mine ? '<button class="community-delete" data-community-delete="'
      + communityEscape(post.id) + '">删除</button>' : "") + "</div>"
    + body
    + '<div class="community-post-actions">'
    + '<button class="community-action' + (post.liked ? " on" : "") + '" data-community-like="'
    + communityEscape(post.id) + '">喜欢 <b>' + num(post.like_count) + "</b></button>"
    + '<button class="community-action' + (commentsOpen ? " on" : "") + '" data-community-comments="'
    + communityEscape(post.id) + '">评论 <b>' + num(post.comment_count) + "</b></button>"
    + '<button class="community-action' + (post.bookmarked ? " on" : "") + '" data-community-bookmark="'
    + communityEscape(post.id) + '">' + (post.bookmarked ? "已收藏" : "收藏") + "</button>"
    + '<button class="community-action" data-community-report="' + communityEscape(post.id)
    + '">举报</button>' + admin + "</div>"
    + '<div class="community-comments-box' + (commentsOpen ? "" : " hidden") + '" data-community-comments-box="'
    + communityEscape(post.id) + '">' + (commentsOpen ? communityCommentsHtml(post.id) : "") + "</div>"
    + "</article>";
}

function renderCommunityFeed() {
  const feed = $("community-feed");
  const status = $("community-status");
  const more = $("community-load-more-wrap");
  if (!feed) return;
  renderCommunityFilterRow();
  if (more) more.classList.toggle("hidden", !communityHasMore || communityLoading);
  if (!DB.profile) {
    feed.innerHTML = communityEmpty("登录后进入星球",
      "登录你的账号后，可以查看板块、参与讨论并收到回复通知。");
    if (status) status.textContent = "尚未登录";
    return;
  }
  if (communityLoading && !communityPosts.length) {
    feed.innerHTML = communityEmpty("正在同步", "正在读取最新讨论…");
    if (status) status.textContent = "加载中…";
    return;
  }
  if (!communityPosts.length) {
    feed.innerHTML = communityEmpty("这个板块还没有内容",
      communityBookmarkedOnly ? "你还没有收藏帖子。" : "成为第一个发帖的人吧。");
    if (status) status.textContent = "0 条";
    return;
  }
  feed.innerHTML = communityPosts.map(renderCommunityPost).join("");
  if (status) status.textContent = communityPosts.length + " 条 · 刚刚更新";
  bindCommunityPostActions(feed);
}

function bindCommunityPostActions(feed) {
  feed.querySelectorAll("[data-community-unlock]").forEach(button => {
    button.onclick = () => unlockKnowledgePost(button.dataset.communityUnlock);
  });
  feed.querySelectorAll("[data-community-delete]").forEach(button => {
    button.onclick = () => deleteCommunityPost(button.dataset.communityDelete);
  });
  feed.querySelectorAll("[data-community-like]").forEach(button => {
    button.onclick = () => toggleCommunityLike(button.dataset.communityLike);
  });
  feed.querySelectorAll("[data-community-bookmark]").forEach(button => {
    button.onclick = () => toggleCommunityBookmark(button.dataset.communityBookmark);
  });
  feed.querySelectorAll("[data-community-report]").forEach(button => {
    button.onclick = () => reportCommunityPost(button.dataset.communityReport);
  });
  feed.querySelectorAll("[data-community-comments]").forEach(button => {
    button.onclick = () => openCommunityComments(button.dataset.communityComments);
  });
  feed.querySelectorAll("[data-community-comment-send]").forEach(button => {
    button.onclick = () => submitCommunityComment(button.dataset.communityCommentSend);
  });
  feed.querySelectorAll("[data-community-reply]").forEach(button => {
    button.onclick = () => {
      const postId = button.dataset.communityReplyPost;
      communityReplyParent[postId] = {
        id: button.dataset.communityReply,
        name: button.dataset.communityReplyName,
      };
      renderCommunityCommentBox(postId);
    };
  });
  feed.querySelectorAll("[data-community-cancel-reply]").forEach(button => {
    button.onclick = () => {
      delete communityReplyParent[button.dataset.communityCancelReply];
      renderCommunityCommentBox(button.dataset.communityCancelReply);
    };
  });
  feed.querySelectorAll("[data-community-moderate]").forEach(button => {
    button.onclick = () => openCommunityModeration(button);
  });
}

function renderCommunityCommentBox(postId) {
  const selector = '[data-community-comments-box="' + String(postId).replace(/"/g, '\\"') + '"]';
  const box = document.querySelector(selector);
  if (!box) return;
  box.classList.remove("hidden");
  box.innerHTML = communityCommentsHtml(postId);
  box.querySelectorAll("[data-community-comment-send]").forEach(button => {
    button.onclick = () => submitCommunityComment(button.dataset.communityCommentSend);
  });
  box.querySelectorAll("[data-community-reply]").forEach(button => {
    button.onclick = () => {
      communityReplyParent[postId] = {
        id: button.dataset.communityReply,
        name: button.dataset.communityReplyName,
      };
      renderCommunityCommentBox(postId);
    };
  });
  box.querySelectorAll("[data-community-cancel-reply]").forEach(button => {
    button.onclick = () => {
      delete communityReplyParent[postId];
      renderCommunityCommentBox(postId);
    };
  });
}

function bindCommunityToolbar() {
  const search = $("community-search");
  const searchButton = $("btn-community-search");
  const bookmarks = $("btn-community-bookmarks");
  const notify = $("btn-community-notifications");
  const manage = $("btn-community-manage");
  const loadMore = $("btn-community-load-more");
  if (searchButton && searchButton.dataset.bound !== "1") {
    searchButton.dataset.bound = "1";
    $("btn-community-search").onclick = () => {
      communitySearch = search ? search.value.trim() : "";
      communityCursor = null;
      loadCommunityPosts(true);
    };
  }
  if (search && search.dataset.bound !== "1") {
    search.dataset.bound = "1";
    search.onkeydown = event => {
      if (event.key === "Enter") searchButton.click();
    };
  }
  if (bookmarks && bookmarks.dataset.bound !== "1") {
    bookmarks.dataset.bound = "1";
    $("btn-community-bookmarks").onclick = () => {
      communityBookmarkedOnly = !communityBookmarkedOnly;
      communityCursor = null;
      loadCommunityPosts(true);
    };
  }
  if (notify && notify.dataset.bound !== "1") {
    notify.dataset.bound = "1";
    $("btn-community-notifications").onclick = async () => {
      communityNotificationsVisible = !communityNotificationsVisible;
      renderCommunityNotifications();
      if (communityNotificationsVisible) await loadCommunityNotifications(true);
    };
  }
  if (manage && manage.dataset.bound !== "1") {
    manage.dataset.bound = "1";
    $("btn-community-manage").onclick = openCommunityAdmin;
  }
  if (loadMore && loadMore.dataset.bound !== "1") {
    loadMore.dataset.bound = "1";
    $("btn-community-load-more").onclick = () => loadCommunityPosts(false, true);
  }
  const profileButton = $("btn-community-profile");
  if (profileButton && profileButton.dataset.bound !== "1") {
    profileButton.dataset.bound = "1";
    $("btn-community-profile").onclick = openCommunityProfileEditor;
  }
  const boardSelect = $("community-board-select");
  if (boardSelect && boardSelect.dataset.bound !== "1") {
    boardSelect.dataset.bound = "1";
    boardSelect.onchange = () => {
      communityCurrentBoard = boardSelect.value;
      renderCommunityBoards();
      communityCursor = null;
      loadCommunityPosts(true);
    };
  }
}

async function loadCommunityBoards(force) {
  if (!DB.profile || communityBoardsLoading || !initCloud()) return;
  if (!force && communityBoards.length) return;
  communityBoardsLoading = true;
  try {
    const result = await cloudClient.rpc("get_community_boards", {});
    if (result.error) throw result.error;
    const data = result.data || {};
    communityBoards = Array.isArray(data.boards) ? data.boards : [];
    communityAccess = data.access || {};
    communitySetUnread(data.unread_count || 0);
    renderCommunityBoards();
    renderCommunityBoardSelect();
    renderCommunityFilterRow();
  } catch (error) {
    toast(communityErrorText(error));
  } finally {
    communityBoardsLoading = false;
  }
}

async function loadCommunityPosts(force, append) {
  if (!DB.profile || communityLoading || !initCloud()) return;
  const now = Date.now();
  if (!force && !append && communityLastLoad && now - communityLastLoad < 6000) {
    renderCommunityFeed();
    return;
  }
  if (!append) {
    communityCursor = null;
    communityPosts = [];
  }
  communityLoading = true;
  renderCommunityFeed();
  try {
    let result = await cloudClient.rpc("list_community_posts_v2", {
      p_board: communityCurrentBoard || null,
      p_search: communitySearch,
      p_before: append ? communityCursor : null,
      p_limit: 20,
      p_bookmarked: communityBookmarkedOnly,
    });
    if (result.error && /function|does not exist|could not find/i.test(
      String(result.error.message || result.error))) {
      // Legacy rollback path before community-forum-v1.sql is installed.
      result = await cloudClient.rpc("list_knowledge_posts", { p_limit: 80 });
      if (result.error) throw result.error;
      communityPosts = (Array.isArray(result.data) ? result.data : []).map(post =>
        Object.assign({}, post, {
          board_id: post.board_id || "10000000-0000-4000-8000-000000000001",
          board_name: post.board_name || "综合讨论",
          board_icon: post.board_icon || "*",
          liked: false,
          bookmarked: false,
          like_count: post.like_count || 0,
          comment_count: post.comment_count || 0,
        }));
      communityCursor = null;
      communityHasMore = false;
      communityLastLoad = Date.now();
      return;
    }
    if (result.error) throw result.error;
    const data = result.data || {};
    const rows = Array.isArray(data.posts) ? data.posts : [];
    await hydrateCommunityAuthors(rows);
    communityPosts = append ? communityPosts.concat(rows) : rows;
    communityCursor = data.next_cursor || null;
    communityHasMore = !!data.has_more;
    communityLastLoad = Date.now();
  } catch (error) {
    if (!append) communityPosts = [];
    const feed = $("community-feed");
    if (feed) feed.innerHTML = communityEmpty("社区暂时没有加载出来", communityErrorText(error));
    const status = $("community-status");
    if (status) status.textContent = "加载失败";
    return;
  } finally {
    communityLoading = false;
  }
  renderCommunityFeed();
}

async function submitCommunityPost() {
  if (!DB.profile || communityLoading) return;
  const input = $("community-input");
  if (!input) return;
  const content = input.value.trim();
  if (!content) {
    toast("先写点内容再发布");
    input.focus();
    return;
  }
  if (content.length > 2000) {
    toast("内容请控制在 2000 字以内");
    return;
  }
  if (!initCloud()) {
    toast("云服务没有连接上");
    return;
  }
  const select = $("community-board-select");
  const boardId = select && select.value ? select.value : communityCurrentBoard;
  if (!boardId) {
    toast("请先选择板块");
    return;
  }
  communityLoading = true;
  const send = $("btn-community-send");
  if (send) {
    send.disabled = true;
    send.textContent = "发布中…";
  }
  try {
    const result = await cloudClient.rpc("post_community_message_v2", {
      p_content: content,
      p_topic: communityTopic,
      p_unlock_cost: Number(($("community-unlock-cost") || {}).value || 0),
      p_is_required: !!($("community-required") || {}).checked,
      p_board: boardId,
    });
    if (result.error) throw result.error;
    const postId = result.data && result.data.id;
    if (postId && communityAccess.can_manage
        && (($("community-pinned") || {}).checked || ($("community-featured") || {}).checked)) {
      await cloudClient.rpc("moderate_community_post", {
        p_post: postId,
        p_pinned: !!($("community-pinned") || {}).checked,
        p_featured: !!($("community-featured") || {}).checked,
        p_deleted: false,
      });
    }
    input.value = "";
    communityLastLoad = 0;
    toast("已发布到板块");
  } catch (error) {
    toast(communityErrorText(error));
  } finally {
    communityLoading = false;
    if (send) {
      send.disabled = !DB.profile;
      send.textContent = "发布";
    }
    renderCommunity();
    await loadCommunityBoards(true);
    await loadCommunityPosts(true);
  }
}

async function toggleCommunityLike(postId) {
  if (!DB.profile || !initCloud()) return;
  try {
    const result = await cloudClient.rpc("toggle_community_like", { p_post: postId });
    if (result.error) throw result.error;
    const data = result.data || {};
    const post = communityPosts.find(item => String(item.id) === String(postId));
    if (post) {
      post.liked = !!data.liked;
      post.like_count = num(data.like_count);
    }
    renderCommunityFeed();
  } catch (error) {
    toast(communityErrorText(error));
  }
}

async function toggleCommunityBookmark(postId) {
  if (!DB.profile || !initCloud()) return;
  try {
    const result = await cloudClient.rpc("toggle_community_bookmark", { p_post: postId });
    if (result.error) throw result.error;
    const data = result.data || {};
    const post = communityPosts.find(item => String(item.id) === String(postId));
    if (post) post.bookmarked = !!data.bookmarked;
    renderCommunityFeed();
    if (communityBookmarkedOnly) await loadCommunityPosts(true);
  } catch (error) {
    toast(communityErrorText(error));
  }
}

async function openCommunityComments(postId) {
  if (!DB.profile || !initCloud()) return;
  const box = document.querySelector('[data-community-comments-box="' + String(postId).replace(/"/g, '\\"') + '"]');
  if (!box) return;
  if (communityCommentCache[postId] && !box.classList.contains("hidden")) {
    delete communityCommentCache[postId];
    delete communityReplyParent[postId];
    renderCommunityFeed();
    return;
  }
  box.classList.remove("hidden");
  box.innerHTML = '<div class="community-comments-loading">正在加载评论…</div>';
  try {
    const result = await cloudClient.rpc("get_community_post", { p_post: postId });
    if (result.error) throw result.error;
    const detail = result.data || {};
    await hydrateCommunityAuthors([detail].concat(
      Array.isArray(detail.comments) ? detail.comments : []));
    communityCommentCache[postId] = detail;
    renderCommunityCommentBox(postId);
  } catch (error) {
    box.innerHTML = communityEmpty("评论没有加载出来", communityErrorText(error));
  }
}

async function submitCommunityComment(postId) {
  if (!DB.profile || !initCloud()) return;
  const box = document.querySelector('[data-community-comments-box="' + String(postId).replace(/"/g, '\\"') + '"]');
  if (!box) return;
  const input = box.querySelector('[data-community-comment-input]');
  const body = input ? input.value.trim() : "";
  if (!body) {
    toast("先写评论再发送");
    return;
  }
  const parent = communityReplyParent[postId];
  try {
    const result = await cloudClient.rpc("add_community_comment", {
      p_post: postId,
      p_body: body,
      p_parent: parent ? parent.id : null,
    });
    if (result.error) throw result.error;
    delete communityReplyParent[postId];
    const detail = await cloudClient.rpc("get_community_post", { p_post: postId });
    if (!detail.error) {
      const payload = detail.data || {};
      await hydrateCommunityAuthors([payload].concat(
        Array.isArray(payload.comments) ? payload.comments : []));
      communityCommentCache[postId] = payload;
    }
    renderCommunityCommentBox(postId);
    communityLastLoad = 0;
    await loadCommunityPosts(true);
    toast("评论已发布");
  } catch (error) {
    toast(communityErrorText(error));
  }
}

async function deleteCommunityPost(postId) {
  if (!DB.profile || !initCloud()) return;
  if (!confirm("确定删除这条消息吗？所有成员都将看不到它。")) return;
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

async function reportCommunityPost(postId) {
  if (!DB.profile || !initCloud()) return;
  const reason = prompt("举报原因：垃圾内容、攻击他人、泄露隐私或其他");
  if (!reason) return;
  try {
    const result = await cloudClient.rpc("report_community_content", {
      p_post: postId,
      p_comment: null,
      p_reason: reason.trim(),
      p_detail: "",
    });
    if (result.error) throw result.error;
    toast("举报已提交，管理员会处理");
  } catch (error) {
    toast(communityErrorText(error));
  }
}

async function openCommunityModeration(button) {
  if (!communityAccess.can_manage || !initCloud()) return;
  const postId = button.dataset.communityModerate;
  const pinned = button.dataset.pinned === "1";
  const featured = button.dataset.featured === "1";
  openSheet("管理这条内容", `
    <div class="community-admin-form">
      <label><input type="checkbox" id="moderate-pinned" ${pinned ? "checked" : ""}> 置顶</label>
      <label><input type="checkbox" id="moderate-featured" ${featured ? "checked" : ""}> 设为精选</label>
      <p class="hint">置顶内容会排在板块前面；精选内容会带精选标记。</p>
    </div>
  `, [
    { label: "取消", onClick: closeSheet },
    { label: "保存", kind: "", onClick: async () => {
      try {
        const result = await cloudClient.rpc("moderate_community_post", {
          p_post: postId,
          p_pinned: !!($("moderate-pinned") || {}).checked,
          p_featured: !!($("moderate-featured") || {}).checked,
          p_deleted: false,
        });
        if (result.error) throw result.error;
        closeSheet();
        communityLastLoad = 0;
        await loadCommunityPosts(true);
        toast("内容状态已更新");
      } catch (error) {
        toast(communityErrorText(error));
      }
    }},
  ]);
}

async function loadCommunityNotifications(force) {
  if (!DB.profile || !initCloud()) return;
  if (!force && !communityNotificationsVisible && Date.now() - (loadCommunityNotifications.last || 0) < 12000) return;
  loadCommunityNotifications.last = Date.now();
  try {
    const result = await cloudClient.rpc("get_community_notifications", { p_limit: 30 });
    if (result.error) throw result.error;
    const data = result.data || {};
    communityNotifications = Array.isArray(data.notifications) ? data.notifications : [];
    communitySetUnread(data.unread_count || 0);
    for (const item of communityNotifications) {
      if (item.read_at || communitySeenNotifications.has(String(item.id))) continue;
      communitySeenNotifications.add(String(item.id));
      if (typeof pushSystemNotification === "function") {
        pushSystemNotification({ title: item.title, body: item.body || "有新的社区消息" });
      }
    }
    renderCommunityNotifications();
  } catch (error) {
    if (force) toast(communityErrorText(error));
  }
}

async function markCommunityNotificationRead(notificationId) {
  if (!DB.profile || !initCloud()) return;
  try {
    const result = await cloudClient.rpc("mark_community_notifications_read", {
      p_notification: notificationId || null,
    });
    if (result.error) throw result.error;
    communitySetUnread(notificationId ? Math.max(0, communityUnread - 1) : 0);
    communityNotifications = communityNotifications.map(item =>
      notificationId && String(item.id) !== String(notificationId)
        ? item : Object.assign({}, item, { read_at: item.read_at || nowISO() }));
    renderCommunityNotifications();
  } catch (error) {
    toast(communityErrorText(error));
  }
}

function communityAdminBoardList() {
  return communityBoards.filter(board => board.can_edit);
}

function renderCommunityAdminSheet() {
  const boards = communityAdminBoardList();
  const editing = boards.find(board => String(board.id) === String(communityAdminEditing));
  return '<div class="community-admin-panel">'
    + '<p class="hint">系统默认板块由产品维护，企业可以创建自己的公开或受限板块。</p>'
    + '<div class="community-admin-board-list">' + boards.map(board =>
      '<button class="chip' + (editing && String(editing.id) === String(board.id) ? " on" : "")
      + '" data-admin-edit-board="' + communityEscape(board.id) + '">'
      + communityEscape(board.name) + "</button>").join("") + "</div>"
    + '<div class="community-admin-form">'
    + '<label>板块名称<input id="admin-board-name" maxlength="60" value="'
    + communityEscape(editing ? editing.name : "") + '"></label>'
    + '<label>板块短名<input id="admin-board-slug" maxlength="40" value="'
    + communityEscape(editing ? editing.slug : "") + '"'
    + (editing ? " disabled" : "") + ' placeholder="例如 product-notes"></label>'
    + '<label>说明<textarea id="admin-board-desc" maxlength="300">'
    + communityEscape(editing ? editing.description : "") + "</textarea></label>"
    + '<label>可见范围<select id="admin-board-visibility"><option value="public"'
    + (editing && editing.visibility === "restricted" ? "" : " selected")
    + '>公开</option><option value="restricted"'
    + (editing && editing.visibility === "restricted" ? " selected" : "")
    + '>按权限</option></select></label>'
    + '<label>所需权限（逗号分隔）<input id="admin-board-permissions" value="'
    + communityEscape(editing && Array.isArray(editing.required_permissions)
      ? editing.required_permissions.join(",") : "")
    + '" placeholder="finance.view,audit.read"></label>'
    + "</div>"
    + '<div class="community-admin-stats" id="community-admin-stats">'
    + (communityAdminStats ? '<pre>' + communityEscape(JSON.stringify(communityAdminStats, null, 2)) + '</pre>'
      : '<span class="meta">管理员可以查看最近 7 天有效参与数据。</span>')
    + "</div></div>";
}

function bindCommunityAdminSheet() {
  document.querySelectorAll("[data-admin-edit-board]").forEach(button => {
    button.onclick = () => {
      communityAdminEditing = button.dataset.adminEditBoard;
      openCommunityAdmin();
    };
  });
}

async function saveCommunityBoardAdmin() {
  const name = ($("admin-board-name") || {}).value || "";
  const slug = ($("admin-board-slug") || {}).value || "";
  const description = ($("admin-board-desc") || {}).value || "";
  const visibility = ($("admin-board-visibility") || {}).value || "public";
  const permissions = String(($("admin-board-permissions") || {}).value || "")
    .split(",").map(value => value.trim()).filter(Boolean);
  try {
    const result = communityAdminEditing
      ? await cloudClient.rpc("update_community_board", {
        p_board: communityAdminEditing,
        p_name: name,
        p_description: description,
        p_visibility: visibility,
        p_required_permissions: permissions,
        p_icon: "*",
        p_archived: false,
      })
      : await cloudClient.rpc("create_community_board", {
        p_name: name,
        p_slug: slug,
        p_description: description,
        p_visibility: visibility,
        p_required_permissions: permissions,
        p_icon: "*",
      });
    if (result.error) throw result.error;
    communityAdminEditing = "";
    communityAdminStats = null;
    closeSheet();
    await loadCommunityBoards(true);
    toast("板块已保存");
  } catch (error) {
    toast(communityErrorText(error));
  }
}

async function showCommunityAdminStats() {
  try {
    const result = await cloudClient.rpc("get_community_admin_stats", {});
    if (result.error) throw result.error;
    communityAdminStats = result.data || {};
    openCommunityAdmin();
  } catch (error) {
    toast(communityErrorText(error));
  }
}

function openCommunityAdmin() {
  if (!communityAccess.can_manage) return;
  openSheet("管理社区板块", renderCommunityAdminSheet(), [
    { label: "关闭", onClick: closeSheet },
    { label: "社区数据", onClick: showCommunityAdminStats },
    { label: communityAdminEditing ? "保存板块" : "创建板块",
      kind: "", onClick: saveCommunityBoardAdmin },
  ]);
  bindCommunityAdminSheet();
}

function ensureCommunitySubscription() {
  if (!DB.profile || !initCloud() || communityChannel) return;
  try {
    communityChannel = cloudClient.channel("knowledge-planet-community-v2")
      .on("postgres_changes", { event: "*", schema: "public", table: "community_posts" }, () => {
        communityLastLoad = 0;
        loadCommunityPosts(true);
        loadCommunityBoards(true);
      })
      .on("postgres_changes", { event: "*", schema: "public", table: "community_comments" }, () => {
        communityLastLoad = 0;
        loadCommunityPosts(true);
      })
      .on("postgres_changes", { event: "*", schema: "public", table: "community_notifications" }, () => {
        loadCommunityNotifications(true);
      })
      .subscribe();
  } catch (error) {
    communityChannel = null;
  }
}


function communityProfileAvatarMarkup(url, name) {
  const safeUrl = String(url || "").trim();
  if (safeUrl) {
    return `<img src="${communityEscape(safeUrl)}" alt="">`;
  }
  return `<span>${communityEscape(String(name || "社").slice(0, 1))}</span>`;
}

function refreshCommunityProfilePreview() {
  const alias = String(($("community-alias") || {}).value || "社区成员");
  const signature = String(($("community-signature") || {}).value || "");
  const avatar = String(($("community-avatar") || {}).value || "");
  const preview = $("community-profile-avatar-preview");
  const name = $("community-profile-name-preview");
  const sign = $("community-profile-sign-preview");
  if (preview) preview.innerHTML = communityProfileAvatarMarkup(avatar, alias);
  if (name) name.textContent = alias || "社区成员";
  if (sign) sign.textContent = signature || "还没有个性签名";
}

function communityProfileImageData(file) {
  return new Promise((resolve, reject) => {
    if (!file || !/^image\//.test(file.type || "")) {
      reject(new Error("请选择图片文件"));
      return;
    }
    const reader = new FileReader();
    reader.onerror = () => reject(new Error("图片读取失败"));
    reader.onload = () => {
      const image = new Image();
      image.onerror = () => reject(new Error("图片格式无法识别"));
      image.onload = () => {
        const size = 320;
        const canvas = document.createElement("canvas");
        canvas.width = size;
        canvas.height = size;
        const ctx = canvas.getContext("2d");
        const scale = Math.max(size / image.width, size / image.height);
        const width = image.width * scale;
        const height = image.height * scale;
        ctx.drawImage(image, (size - width) / 2, (size - height) / 2, width, height);
        resolve(canvas.toDataURL("image/jpeg", .84));
      };
      image.src = String(reader.result || "");
    };
    reader.readAsDataURL(file);
  });
}

async function openCommunityProfileEditor() {
  if (!DB.profile || !initCloud()) return;
  try {
    const { data, error } = await cloudClient.rpc("get_my_community_profile");
    if (error) throw error;
    const profile = data || {};
    const alias = profile.alias_name || (DB.profile && DB.profile.name) || "社区成员";
    const signature = profile.signature || "";
    const avatar = profile.avatar_url || "";
    const shortId = String((DB.profile && DB.profile.id) || "").replace(/-/g, "").slice(0, 8).toUpperCase() || "—";

    openSheet("账号资料", `
      <div class="community-profile-editor">
        <div class="community-profile-hero">
          <div class="community-profile-avatar-preview" id="community-profile-avatar-preview">
            ${communityProfileAvatarMarkup(avatar, alias)}
          </div>
          <div class="community-profile-hero-copy">
            <b id="community-profile-name-preview">${communityEscape(alias)}</b>
            <span id="community-profile-sign-preview">${communityEscape(signature || "还没有个性签名")}</span>
            <small>社区 ID · ${communityEscape(shortId)}</small>
          </div>
        </div>

        <div class="community-account-list">
          <label class="community-account-row community-account-avatar-row">
            <span>头像</span>
            <div class="community-account-row-value">
              <span>从相册选择</span><i>›</i>
            </div>
            <input type="file" id="community-avatar-file" accept="image/*" hidden>
          </label>

          <label class="community-account-row">
            <span>社区昵称</span>
            <input id="community-alias" maxlength="20" value="${communityEscape(profile.alias_name || alias)}" placeholder="设置社区昵称">
            <i>›</i>
          </label>

          <div class="community-account-row">
            <span>社区 ID</span>
            <strong>${communityEscape(shortId)}</strong>
          </div>

          <label class="community-account-row">
            <span>头像地址</span>
            <input id="community-avatar" value="${communityEscape(profile.avatar_url || "")}" placeholder="https://...">
            <i>›</i>
          </label>

          <label class="community-account-row">
            <span>个性签名</span>
            <input id="community-signature" maxlength="120" value="${communityEscape(profile.signature || "")}" placeholder="写一句状态或原则">
            <i>›</i>
          </label>

          <label class="community-account-row community-account-bio-row">
            <span>个人简介</span>
            <textarea id="community-bio" maxlength="300" placeholder="介绍一下你的经验、关注方向或当前目标">${communityEscape(profile.bio || "")}</textarea>
          </label>
        </div>

        <div class="community-profile-note">
          公开区域只显示社区昵称和头像，真实姓名不会展示。昵称每 30 天最多修改一次。
        </div>
      </div>
    `, [
      { label: "取消", onClick: closeSheet },
      { label: "保存资料", onClick: async () => {
        try {
          const result = await cloudClient.rpc("update_community_profile", {
            p_alias: ($("community-alias") || {}).value || "",
            p_avatar_url: ($("community-avatar") || {}).value || "",
            p_bio: ($("community-bio") || {}).value || "",
            p_signature: ($("community-signature") || {}).value || "",
          });
          if (result.error) throw result.error;
          closeSheet();
          communityLastLoad = 0;
          await loadCommunityPosts(true);
          toast("社区资料已更新");
        } catch (error) { toast(communityErrorText(error)); }
      }},
    ]);

    ["community-alias", "community-signature", "community-avatar"].forEach(id => {
      const input = $(id);
      if (input) input.addEventListener("input", refreshCommunityProfilePreview);
    });
    const pick = $("community-avatar-file");
    if (pick) {
      pick.onchange = async () => {
        const file = pick.files && pick.files[0];
        if (!file) return;
        try {
          const dataUrl = await communityProfileImageData(file);
          if ($("community-avatar")) $("community-avatar").value = dataUrl;
          refreshCommunityProfilePreview();
          toast("头像已准备好，保存资料后生效");
        } catch (error) {
          toast(error.message || "头像处理失败");
        }
      };
    }
  } catch (error) { toast(communityErrorText(error)); }
}
