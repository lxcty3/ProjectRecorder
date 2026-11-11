/* =============================================================
   数据层：手机是本机的数据库。

   这一版的原则变了 —— **手机是主库**，不是电脑的镜像。
   所以这里要能真的增删改，不是只读。

   存储用 localStorage：
     · 容量够（一般 5~10 MB，够存几万条工时）
     · 同步 API，不用处理 Promise，代码短、出错点少
     · Capacitor 打包成 apk 后依然是本地持久化的
   如果哪天数据量真的超过容量，再换 IndexedDB —— 接口不变，
   只要把 read()/write() 两个函数换掉。

   所有写操作都会调 _save()，它顺带更新 updated_at。
   这个时间戳是后面「和电脑同步」时判断谁新谁旧的依据。
   ============================================================= */
"use strict";

const DB_KEY = "pr_database_v1";
const DB_STORAGE_PREFIX = "pr_database_account_v2:";
const DB_BACKUP_PREFIX = "pr_database_backup_v3:";
const SETTINGS_KEY = "pr_settings_v1";

/* ---------------------------------------------------------- 空库结构 */
function emptyDatabase() {
  return {
    schema: 1,
    created_at: nowISO(),
    updated_at: nowISO(),
    projects: [],
    steps: [],
    employees: [],
    worklogs: [],
    assignments: [],
    assessments: [],
    metrics: [],
    sessions: [],
    /* 习惯。**只有老板自己用**，所以没有 owner 字段——
       要给员工派习惯的话再加，现在加等于给一个不存在的需求留坑。

       一张 habit 一条习惯，habitLogs 一条打卡记录。
       用两张表而不是"在 habit 里存一串日期"，是因为：
         · 打卡记录要能单独查（某天打了哪些）
         · 以后要加备注、数值，塞进字符串就僵住了 */
    habits: [],
    habitLogs: [],
    // 自增 id。不用随机 id，是因为要让人看得懂（P1、E3），
    // 也让导出文件比随机串短很多。
    seq: { project: 0, step: 0, employee: 0, worklog: 0,
           assignment: 0, assessment: 0, metric: 0, session: 0,
           habit: 0, habitLog: 0, sync: 0 },

    /* ---------- 以下为账号 / 云同步相关的本地结构 ---------- */

    /* 老板派下来的任务（员工端用）。
       **注意这里没有"待同步"之类的状态字段**——
       同步状态全部放在 syncQueue 里，一张表管一件事。
       如果把标记散在各个表里，漏掉一处就会出现
       "这条改了但永远不上传"这种查不出来的 bug。 */
    tasks: [],

    /* 勾选记录：哪条任务在什么时候完成的。
       服务端也有这张表，本地是缓存 + 待上传。 */
    taskLogs: [],

    /* 员工向老板提的请求（现在只有"申请延期"）。

       为什么不塞进 tasks 里当几个字段：
         一条任务可能被申请延期多次（第一次没批，改天再申请），
         历史要留着，而且老板可能想回看"这人上周申请过两次"。
         塞进 tasks 就只能存最后一次。

       服务端是 task_requests 表，本地是只读缓存（写操作走 RPC，
       见 sql/task-accept-extension.sql），所以这里不需要待上传队列。 */
    taskRequests: [],

    /* 老板端收到的员工工时（来自服务端）。

       单独放一张表，**不和本地的 worklogs 混在一起**——
       混的话就没法区分"我自己记的"和"员工报上来的"，
       删除、编辑、去重的处理方式完全不同。
       统计时用 allWorklogs() 把两边合起来。 */
    remoteWorklogs: [],

    /* 记忆源点流水（来自服务端，只读缓存）。

       一条一行：谁、多少、为什么、什么时候。

       **余额不存**，永远由流水求和得出（见 merit.js）。
       存了余额就会出现"余额和流水对不上"的鬼故事，
       而且对不上之后查不出是哪一步错的。

       服务端是 merit_ledger 表，写入只走 merit_add 函数，
       本地这张表只读 —— 所以没有待上传队列。 */
    meritLedger: [],

    /* 上下工记录（服务端 work_sessions，只读缓存）。
       有一条 ended_at 为空，就说明这个人正在干活。
       老板的看板靠它回答"现在谁在干活"。 */
    workSessions: [],

    /* 兑换商城里的商品（老板维护） */
    rewards: [],

    /* 兑换申请（员工提的，老板审批） */
    redemptions: [],

    /* 请假申请 */
    leaves: [],

    /* 老板建的员工账号（本地记录，含待创建的）。
       `pending: true` 表示还没在云端建号。

       **为什么要在本地记一份**：Supabase 客户端建账号会
       顶掉当前登录（老板会被员工账号登出）。所以先记下来，
       由老板主动点"同步账号"时批量创建。 */
    staffAccounts: [],

    /* **登录过的账号，用来"点一下就登录"。**

       每条：{ code, role, name, password, lastUsed }

       ## 为什么这里存了密码

       要做到"点一下就登录"，本地就必须留一份能直接拿来登录的凭证。
       两条路：

         · 存密码          —— 一定能用；但密码泄漏就等于永久失守
         · 存 refresh token —— 更安全，但会过期 / 改密码后失效，
                                失效时还是得手输，等于"有时能用"

       这个 App 是单人用的小工具，用户明确要的是"点一下直接进"，
       所以选存密码；同时做三件事来兜住风险：

         1. 只在**登录成功之后**才存（不会存错的密码）
         2. 登录页上每一条都能单独删掉（✕）
         3. 注销账号时一并删掉（见 forgetAccount）

       密码只存在本机 App 私有目录的 localStorage 里，
       不进云、不同步、不出现在任何提示文字里。 */
    savedAccounts: [],

    /* v2 database scope. Account databases are stored under separate keys.
       Company-scoped cloud caches are cleared when the active company changes. */
    storage_version: 2,
    account_scope_id: null,
    company_scope_id: null,

    /* 待上传的变更队列。没网时攒着，联网后按顺序补传。 */
    syncQueue: [],

    /* 云端比本机新的冲突。保留双方快照，不静默覆盖。 */
    syncConflicts: [],

    /* 工时经营标签走独立 RPC；等对应 worklogs 行上传成功后再提交。 */
    dimensionQueue: [],

    /* 本地手工工时先迁移为云端 UUID，再提交经营标签。
       数字 id 只在本机有意义，不能直接发给 uuid 列。 */
    worklogMigrationQueue: [],

    /* 各表最后一次成功拉取的时间，用来做增量拉取。
       没有它就只能每次全量拉，数据一多就慢。 */
    syncCursor: {},

    /* 当前登录的人（profile）。null = 没登录 / 单机模式。
       存一份本地副本是为了**离线也能进主界面**——
       没网时不能把人挡在登录页外面。 */
    profile: null,

    /* 最近一次从云端取到的企业身份快照。
       离线时仍能显示上次确认过的身份和权限。 */
    identity: null,
    organizationStatus: { status: "unknown", message: "", at: 0 },
    clientProtocol: { protocol_version: null, minimum_protocol_version: 2, checked_at: 0 },
    shareholderMeetings: { data: null, at: 0, error: "" },

    /* 企业积分快照。余额、季度池和流水都来自 get_point_state，
       离线时继续显示最后一次确认过的值。 */
    pointState: { balance: 0, pool: null, ledger: [], at: 0 },

    /* 经营决策中心最近一次服务端快照。没有数据时保持空数组，
       绝不在客户端伪造决策或审批。 */
    decisionCenter: { decisions: [], approvals: [], members: [], at: 0 },

    /* 管理经营摘要与员工自己的绩效依据。敏感数据只保存在本机缓存，
       仍由服务端 RPC 决定是否能读取。 */
    operations: { projects: [], capacity_gaps: [], performance: [],
                  worklog_summary: {}, capacity_demands: [], skills: [],
                  collection_alerts: [], members: [], security_audit: [],
                  access: {}, at: 0 },
    myPerformance: { items: [], at: 0 },
    execution: { acceptance: [], dependencies: [], handoffs: [],
                  changes: [], tasks: [], projects: [], members: [],
                  access: {}, at: 0 },
    intake: { myRequests: [], requests: [], forms: [], members: [],
              projects: [], tasks: [], emailAliases: [], settings: {}, access: {}, at: 0 },

    /* 简单模式默认开启；只有具备管理、财务、审计或治理权限的人
       才能切到 advanced。服务端仍会独立校验。 */
    uiMode: "simple",

    /* 上次同步的结果，界面上显示"已同步 / 待上传 N 条" */
    lastSync: { at: "", ok: true, pending: 0, message: "" },

    /* ---------- 通知 ---------- */

    /* 收到的消息（最多保留 200 条，见 addNotification）。
       每一条是**已经发生的事**，不是"待办"。

       为什么放在本地而不是服务端：
         · 已读状态是**每台设备各自的**（老板手机上看过了，
           平板不用跟着变成已读）
         · 离线也要能看到历史
       服务端只负责产生"事件"（task_events），
       这边负责"我看到了哪些、哪些还没读"。 */
    notifications: [],

    /* 处理到哪个事件为止了。键是事件来源，值是时间戳。
       用它避免重复通知：拉到的老事件不再提醒第二遍。 */
    notifyCursor: {},

    /* 服务端还没建 task_events 表时置为 true（sql/migrate-notify.sql 没跑）。
       界面上据此提示一句，而不是让用户纳闷"怎么没有通知"。 */
    notifyTableMissing: false,

    /* 上次检查到的系统通知权限结果
       { supported, granted }。放在这里而不是每次现查——
       checkPermissions 是异步的，而 renderMe 是同步渲染的。 */
    notifyPermission: null,


    /* 通知开关。默认全开——用户既然要这个功能，
       默认关掉等于没做。 */
    notifyPrefs: {
      enabled: true,
      /* 应用内：底部导航小红点 + 页面顶部提示条 */
      inApp: true,
      /* 系统通知：安卓通知栏 */
      system: true,
      /* 完成/取消完成/工时汇总/新任务/项目状态，逐项可控 */
      onTaskAssigned: true,
      onTaskDone: true,
      onTaskUndone: true,
      /* 接受 / 申请延期这一类的来回消息共用一个开关。
         分太细没人愿意一项项调——它们本来就是同一件事：
         "这条任务有人在等你回应"。 */
      onTaskReply: true,
      onWorklogSummary: true,
      onProjectStatus: true,
    },
  };
}

let DB = null;
let currentDatabaseKey = DB_KEY;

/* ---------------------------------------------------------- 时间工具 */
function nowISO() {
  const d = new Date();
  const pad = n => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} `
        + `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
}

function todayISO() {
  const d = new Date();
  const pad = n => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

/* ---------------------------------------------------------- 存取 */
function accountDatabaseKey(accountId) {
  const id = String(accountId || "").trim();
  return id ? DB_STORAGE_PREFIX + encodeURIComponent(id) : DB_KEY;
}

function activeDatabaseKey() {
  return currentDatabaseKey || DB_KEY;
}

function readDatabaseRaw(storageKey) {
  try {
    return localStorage.getItem(storageKey || activeDatabaseKey());
  } catch (error) {
    throw new Error("浏览器不允许本地存储，数据无法保存：" + error.message);
  }
}

function loadAll(storageKey) {
  if (storageKey) currentDatabaseKey = storageKey;
  const raw = readDatabaseRaw();
  if (!raw) return emptyDatabase();
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch (error) {
    throw new Error("本地数据损坏，无法解析：" + error.message);
  }
  const data = migrate(parsed);
  if (currentDatabaseKey !== DB_KEY && !data.account_scope_id) {
    data.account_scope_id = decodeURIComponent(
      currentDatabaseKey.slice(DB_STORAGE_PREFIX.length));
  }
  return data;
}

function saveAll() {
  DB.updated_at = nowISO();
  DB.storage_version = 2;
  try {
    localStorage.setItem(activeDatabaseKey(), JSON.stringify(DB));
  } catch (error) {
    // 超容量是最可能的失败原因，提示要说清
    throw new Error(
      "保存失败（可能是存储空间满了）：" + error.message
      + "\n建议导出一次备份，然后清掉旧的工时。"
    );
  }
}

/* 让调用方读起来像「保存」这个动作，而不是写文件 */
function _save() { saveAll(); }

/* Switch to the account-owned database before any account data is rendered.
   The previous database is written first, including its pending queue. */
function activateAccountDatabase(accountId) {
  const id = String(accountId || "").trim();
  if (!id) throw new Error("无法切换数据库：账号 ID 为空");
  if (DB && currentDatabaseKey === accountDatabaseKey(id)
      && String(DB.account_scope_id || "") === id) return DB;

  if (DB) saveAll();
  const key = accountDatabaseKey(id);
  const exists = !!readDatabaseRaw(key);
  currentDatabaseKey = key;
  DB = loadAll(key);
  DB.account_scope_id = id;
  saveSetting("last_account_id", id);
  if (!exists) saveAll();
  return DB;
}

/* A fresh account database is created only after the account ID is known. */
function ensureAccountDatabase(accountId) {
  const id = String(accountId || "").trim();
  if (!id) throw new Error("无法创建数据库：账号 ID 为空");
  const key = accountDatabaseKey(id);
  const exists = !!readDatabaseRaw(key);
  if (!exists) {
    if (DB) saveAll();
    currentDatabaseKey = key;
    DB = emptyDatabase();
    DB.account_scope_id = id;
    saveSetting("last_account_id", id);
    saveAll();
  } else if (!DB || currentDatabaseKey !== key) {
    activateAccountDatabase(id);
  }
  return { created: !exists, database: DB };
}

function databaseMeaningful(data) {
  if (!data || typeof data !== "object") return false;
  return ["projects", "steps", "employees", "worklogs", "assignments",
          "assessments", "metrics", "sessions", "habits", "habitLogs",
          "tasks", "taskLogs", "remoteWorklogs", "staffAccounts",
          "syncQueue", "dimensionQueue", "worklogMigrationQueue"]
    .some(key => Array.isArray(data[key]) && data[key].length > 0);
}

function backupCurrentDatabase(reason) {
  const raw = readDatabaseRaw();
  if (!raw) return null;
  const stamp = nowISO().replace(/[-: ]/g, "");
  const account = DB && DB.account_scope_id ? DB.account_scope_id : "legacy";
  const suffix = Math.random().toString(36).slice(2, 6);
  const key = DB_BACKUP_PREFIX + stamp + ":" + suffix + ":" + encodeURIComponent(account);
  localStorage.setItem(key, raw);
  const index = getSetting("database_backup_index", []);
  const rows = Array.isArray(index) ? index : [];
  rows.unshift({
    key: key,
    at: nowISO(),
    reason: String(reason || "manual"),
    account_id: DB && DB.account_scope_id || null,
    bytes: raw.length,
  });
  saveSetting("database_backup_index", rows.slice(0, 20));
  pruneDatabaseBackups(3);
  return key;
}

function databaseBackups() {
  const rows = getSetting("database_backup_index", []);
  return Array.isArray(rows) ? rows.slice() : [];
}

function pruneDatabaseBackups(keep) {
  const max = Math.max(1, Number(keep) || 3);
  const rows = databaseBackups();
  const remove = rows.slice(max);
  const remain = rows.slice(0, max);
  remove.forEach(row => {
    try { localStorage.removeItem(row.key); } catch (error) {}
  });
  saveSetting("database_backup_index", remain);
  return remain;
}

function legacyDatabaseSnapshot() {
  const raw = readDatabaseRaw(DB_KEY);
  if (!raw) return null;
  try {
    const data = migrate(JSON.parse(raw));
    return databaseMeaningful(data) ? data : null;
  } catch (error) {
    return null;
  }
}

function legacyDataSummary(data) {
  const source = data || legacyDatabaseSnapshot();
  if (!source) return { total: 0 };
  const fields = ["projects", "steps", "employees", "worklogs", "tasks",
                  "habitLogs", "syncQueue"];
  const summary = {};
  let total = 0;
  fields.forEach(key => {
    const count = Array.isArray(source[key]) ? source[key].length : 0;
    summary[key] = count;
    total += count;
  });
  summary.total = total;
  return summary;
}

function markLegacyBackup(reason) {
  const raw = readDatabaseRaw(DB_KEY);
  if (!raw) return null;
  const stamp = nowISO().replace(/[-: ]/g, "");
  const suffix = Math.random().toString(36).slice(2, 6);
  const key = DB_BACKUP_PREFIX + stamp + ":" + suffix + ":legacy";
  localStorage.setItem(key, raw);
  const index = getSetting("database_backup_index", []);
  const rows = Array.isArray(index) ? index : [];
  rows.unshift({ key: key, at: nowISO(), reason: reason || "legacy", account_id: null, bytes: raw.length });
  saveSetting("database_backup_index", rows.slice(0, 20));
  pruneDatabaseBackups(3);
  return key;
}

/* Explicit ownership claim. Queues from the legacy database are not activated:
   old pending operations must not be attributed to a new account. */
function claimLegacyDataForCurrentAccount() {
  if (!DB || !DB.account_scope_id) throw new Error("请先登录再确认旧数据归属");
  const legacy = legacyDatabaseSnapshot();
  if (!legacy) return false;
  markLegacyBackup("legacy-claim");
  const accountId = DB.account_scope_id;
  const arrays = ["projects", "steps", "employees", "worklogs", "assignments",
                  "assessments", "metrics", "sessions", "habits", "habitLogs",
                  "tasks", "taskLogs", "remoteWorklogs", "staffAccounts",
                  "meritLedger", "workSessions", "rewards", "redemptions", "leaves"];
  arrays.forEach(key => {
    if (!Array.isArray(legacy[key])) return;
    if (!Array.isArray(DB[key])) DB[key] = [];
    const seen = new Set(DB[key].map(item => String(item && item.id)));
    legacy[key].forEach(item => {
      if (!item || !item.id || seen.has(String(item.id))) return;
      const row = Object.assign({}, item, { owner_account_id: accountId });
      DB[key].push(row);
      seen.add(String(row.id));
    });
  });
  saveSetting("legacy_data_claim", {
    status: "claimed",
    account_id: accountId,
    claimed_at: nowISO(),
  });
  saveAll();
  return true;
}

function archiveLegacyDataClaim() {
  markLegacyBackup("legacy-archive");
  saveSetting("legacy_data_claim", { status: "archived", at: nowISO() });
}

function deferLegacyDataClaim(accountId) {
  saveSetting("legacy_data_claim", {
    status: "pending",
    account_id: String(accountId || ""),
    deferred_at: nowISO(),
  });
}

function updateCompanyScope(companyId) {
  const next = String(companyId || "");
  const current = String(DB && DB.company_scope_id || "");
  if (current === next) return false;
  if (current && next) clearCompanyScopedCache();
  DB.company_scope_id = next || null;
  saveAll();
  return true;
}

/* Clear cloud snapshots when the active company changes. Pending queues stay
   in the account database and are intentionally untouched. */
function clearCompanyScopedCache() {
  if (!DB) return;
  DB.identity = null;
  DB.tasks = [];
  DB.taskLogs = [];
  DB.taskRequests = [];
  DB.remoteWorklogs = [];
  DB.meritLedger = [];
  DB.workSessions = [];
  DB.rewards = [];
  DB.redemptions = [];
  DB.leaves = [];
  DB.staffAccounts = [];
  DB.notifications = [];
  DB.pointState = { balance: 0, pool: null, ledger: [], at: 0 };
  DB.decisionCenter = { decisions: [], approvals: [], members: [], at: 0 };
  DB.operations = { projects: [], capacity_gaps: [], performance: [],
                    worklog_summary: {}, capacity_demands: [], skills: [],
                    collection_alerts: [], members: [], security_audit: [],
                    access: {}, at: 0 };
  DB.myPerformance = { items: [], at: 0 };
  DB.execution = { acceptance: [], dependencies: [], handoffs: [], changes: [],
                   tasks: [], projects: [], members: [], access: {}, at: 0 };
  DB.intake = { myRequests: [], requests: [], forms: [], members: [],
                projects: [], tasks: [], emailAliases: [], settings: {},
                access: {}, at: 0 };
  DB.company_scope_id = null;
  DB.syncCursor = {};
  DB.notifyCursor = {};
  DB.pullError = "";
  DB.identityError = "";
  DB.lastSync = { at: "", ok: true, pending: 0, message: "" };
  saveAll();
}


function localSyncDiagnostics() {
  const queue = Array.isArray(DB && DB.syncQueue) ? DB.syncQueue : [];
  const failed = queue.filter(item => item.lastError);
  const backupRows = databaseBackups();
  let bytes = 0;
  try {
    const raw = readDatabaseRaw();
    bytes = raw ? raw.length : 0;
  } catch (error) {}
  const legacy = legacyDatabaseSnapshot();
  const legacyState = getSetting("legacy_data_claim", {});
  return {
    account_id: DB && DB.account_scope_id || null,
    company_id: DB && DB.company_scope_id || null,
    database_key: activeDatabaseKey(),
    pending: typeof pendingCount === "function" ? pendingCount() : queue.length,
    failed: failed.length,
    conflicts: Array.isArray(DB && DB.syncConflicts)
      ? DB.syncConflicts.filter(item => !item.resolved).length : 0,
    conflict_items: Array.isArray(DB && DB.syncConflicts)
      ? DB.syncConflicts.filter(item => !item.resolved).slice(0, 5)
      : [],
    failures: failed.slice(0, 5).map(item => ({
      table: item.table,
      key: item.key,
      error: item.lastError,
    })),
    lastSync: DB && DB.lastSync || null,
    pullError: DB && DB.pullError || "",
    backup_count: backupRows.length,
    last_backup: backupRows[0] || null,
    bytes: bytes,
    legacy_available: !!legacy && (!legacyState || legacyState.status !== "claimed"),
    legacy_summary: legacy ? legacyDataSummary(legacy) : { total: 0 },
  };
}

/* ---------------------------------------------------------- 版本升级 */
function migrate(data) {
  // 每加一个字段都在这里补默认值，否则老数据读进来会 undefined
  const base = emptyDatabase();
  const merged = Object.assign({}, base, data || {});
  merged.seq = Object.assign({}, base.seq, (data && data.seq) || {});
  merged.pointState = Object.assign(
    { balance: 0, pool: null, ledger: [], at: 0 }, merged.pointState || {}
  );
  if (!Array.isArray(merged.pointState.ledger)) merged.pointState.ledger = [];
  merged.decisionCenter = Object.assign(
    { decisions: [], approvals: [], members: [], at: 0 },
    merged.decisionCenter || {}
  );
  merged.operations = Object.assign(
    { projects: [], capacity_gaps: [], performance: [],
      worklog_summary: {}, capacity_demands: [], skills: [],
      collection_alerts: [], members: [], security_audit: [],
      access: {}, at: 0 },
    merged.operations || {}
  );
  merged.myPerformance = Object.assign(
    { items: [], at: 0 }, merged.myPerformance || {}
  );
  merged.organizationStatus = Object.assign(
    { status: "unknown", message: "", at: 0 },
    merged.organizationStatus || {}
  );
  merged.clientProtocol = Object.assign(
    { protocol_version: null, minimum_protocol_version: 2, checked_at: 0 },
    merged.clientProtocol || {}
  );
  merged.execution = Object.assign(
    { acceptance: [], dependencies: [], handoffs: [], changes: [],
      tasks: [], projects: [], members: [], access: {}, at: 0 },
    merged.execution || {}
  );
  ["decisions", "approvals", "members"].forEach(key => {
    if (!Array.isArray(merged.decisionCenter[key])) {
      merged.decisionCenter[key] = [];
    }
  });
  if (merged.uiMode !== "advanced") merged.uiMode = "simple";
  ["projects", "steps", "employees", "worklogs", "assignments",
   "assessments", "metrics", "sessions", "habits", "habitLogs",
   "tasks", "taskLogs", "remoteWorklogs", "staffAccounts", "syncQueue",
   "syncConflicts", "dimensionQueue", "worklogMigrationQueue", "notifications", "meritLedger",
   "workSessions", "rewards", "redemptions", "leaves"]
    .forEach(key => {
      if (!Array.isArray(merged[key])) merged[key] = [];
    });

  /* **清掉历史遗留的本地流水。**

     旧版收工时先在本地插一条 id 形如 local-hours-xxx 的流水，
     而服务端也会写一条（id 是随机 uuid），于是同一次工作
     被算了两遍。服务端才是权威，本地那几条一律丢掉；
     真正没上传成功的，下次拉取会从服务端补回来。 */
  if (Array.isArray(merged.meritLedger)) {
    merged.meritLedger = merged.meritLedger.filter(row =>
      String((row && row.id) || "").indexOf("local-") !== 0);
  }
  /* 这几个是对象不是数组，单独补。
     写成数组兜底会让 syncCursor[key] 取不到值，静默失效。 */
  if (!merged.syncCursor || typeof merged.syncCursor !== "object"
      || Array.isArray(merged.syncCursor)) {
    merged.syncCursor = {};
  }
  if (!merged.notifyCursor || typeof merged.notifyCursor !== "object"
      || Array.isArray(merged.notifyCursor)) {
    merged.notifyCursor = {};
  }
  if (!merged.lastSync || typeof merged.lastSync !== "object"
      || Array.isArray(merged.lastSync)) {
    merged.lastSync = { at: "", ok: true, pending: 0, message: "" };
  }
  /* 通知开关：**逐项补默认值**，不能整个替换。
     整个替换的话，将来加一个新开关，老用户升级后
     那个开关会是 undefined（表现为"这项通知永远不发"）。 */
  if (!merged.notifyPrefs || typeof merged.notifyPrefs !== "object"
      || Array.isArray(merged.notifyPrefs)) {
    merged.notifyPrefs = {};
  }
  merged.notifyPrefs = Object.assign({}, base.notifyPrefs,
                                     merged.notifyPrefs);
  if (merged.profile === undefined) merged.profile = null;
  return merged;
}

/* ---------------------------------------------------------- 自增 id */
function nextId(kind) {
  DB.seq[kind] = (DB.seq[kind] || 0) + 1;
  return DB.seq[kind];
}

/* ---------------------------------------------------------- 设置项 */
function loadSettings() {
  try {
    return JSON.parse(localStorage.getItem(SETTINGS_KEY) || "{}");
  } catch (error) {
    return {};
  }
}

function saveSetting(key, value) {
  const all = loadSettings();
  all[key] = value;
  try {
    localStorage.setItem(SETTINGS_KEY, JSON.stringify(all));
  } catch (error) {
    /* 设置存不上不影响使用，静默即可 */
  }
}

function getSetting(key, fallback) {
  const all = loadSettings();
  return all[key] === undefined ? fallback : all[key];
}

/* ============================================================
   项目
   ============================================================ */
const PROJECT_FIELDS = [
  "name", "owner", "client", "status", "priority",
  "start_date", "due_date", "budget", "cost", "progress", "note",
];

function projectCloudPayload(project) {
  return {
    remote_id: project.remote_id || "",
    remote_version: project.remote_version || null,
    name: project.name || "",
    owner: project.owner || "",
    client: project.client || "",
    status: project.status || "进行中",
    priority: project.priority || "中",
    start_date: project.start_date || "",
    due_date: project.due_date || "",
    budget: num(project.budget),
    cost: num(project.cost),
    progress: clamp(num(project.progress), 0, 100),
    note: project.note || "",
  };
}

function stepCloudPayload(step) {
  return {
    remote_id: step.remote_id || "",
    remote_version: step.remote_version || null,
    project_id: step.project_id,
    seq: num(step.seq),
    name: step.name || "",
    owner: step.owner || "",
    status: step.status || "未开始",
    start_date: step.start_date || "",
    due_date: step.due_date || "",
    progress: clamp(num(step.progress), 0, 100),
    note: step.note || "",
  };
}

function dropQueuedSync(table, key) {
  if (!Array.isArray(DB.syncQueue)) return;
  DB.syncQueue = DB.syncQueue.filter(item =>
    item.table !== table || String(item.key) !== String(key));
}

function queueProjectSync(project, op) {
  if (!DB.profile || !project || typeof queueChange !== "function") return;
  if (op === "delete" && !project.remote_id) {
    dropQueuedSync("projects", project.id);
    return;
  }
  queueChange("projects", op || "upsert", project.id, projectCloudPayload(project));
}

function queueStepSync(step, op) {
  if (!DB.profile || !step || typeof queueChange !== "function") return;
  if (op === "delete" && !step.remote_id) {
    dropQueuedSync("project_steps", step.id);
    return;
  }
  queueChange("project_steps", op || "upsert", step.id, stepCloudPayload(step));
}

function addProject(data) {
  const project = {
    id: nextId("project"),
    name: String(data.name || "").trim(),
    owner: data.owner || "",
    client: data.client || "",
    status: data.status || "进行中",
    priority: data.priority || "中",
    start_date: data.start_date || "",
    due_date: data.due_date || "",
    budget: num(data.budget),
    cost: num(data.cost),
    progress: clamp(num(data.progress), 0, 100),
    note: data.note || "",
    created_at: nowISO(),
    updated_at: nowISO(),
  };
  if (!project.name) throw new Error("项目名称不能为空。");
  DB.projects.push(project);
  _save();
  queueProjectSync(project, "upsert");
  return project;
}

function updateProject(id, data) {
  const project = getProject(id);
  if (!project) throw new Error("这个项目已经不存在了。");
  PROJECT_FIELDS.forEach(key => {
    if (data[key] === undefined) return;
    if (key === "budget" || key === "cost") project[key] = num(data[key]);
    else if (key === "progress") project[key] = clamp(num(data[key]), 0, 100);
    else if (key === "name") {
      const name = String(data.name).trim();
      if (!name) throw new Error("项目名称不能为空。");
      project[key] = name;
    } else project[key] = data[key];
  });
  project.updated_at = nowISO();
  _save();
  queueProjectSync(project, "upsert");
  return project;
}

function getProject(id) {
  return DB.projects.find(item => item.id === Number(id)) || null;
}

function deleteProject(id) {
  const pid = Number(id);
  const project = getProject(pid);
  // 级联删掉从属于它的东西。工时也一起删
  // 留着「项目已删但工时还在」会让负荷统计出现找不到项目的记录。
  DB.steps = DB.steps.filter(item => item.project_id !== pid);
  DB.worklogs = DB.worklogs.filter(item => item.project_id !== pid);
  DB.assignments = DB.assignments.filter(item => item.project_id !== pid);
  DB.assessments = DB.assessments.filter(item => item.project_id !== pid);
  DB.metrics = DB.metrics.filter(item => item.project_id !== pid);
  DB.projects = DB.projects.filter(item => item.id !== pid);
  _save();
  queueProjectSync(project, "delete");
}

function projectSteps(projectId) {
  return DB.steps
    .filter(item => item.project_id === Number(projectId))
    .sort((a, b) => (a.seq || 0) - (b.seq || 0) || a.id - b.id);
}

/* ============================================================
   步骤
   ============================================================ */
function addStep(projectId, data) {
  const pid = Number(projectId);
  if (!getProject(pid)) throw new Error("这个项目已经不存在了。");
  const siblings = projectSteps(pid);
  const step = {
    id: nextId("step"),
    project_id: pid,
    seq: data.seq === undefined ? siblings.length + 1 : num(data.seq),
    name: String(data.name || "").trim(),
    owner: data.owner || "",
    status: data.status || "未开始",
    start_date: data.start_date || "",
    due_date: data.due_date || "",
    progress: clamp(num(data.progress), 0, 100),
    note: data.note || "",
  };
  if (!step.name) throw new Error("步骤名称不能为空。");
  DB.steps.push(step);
  _save();
  queueStepSync(step, "upsert");
  return step;
}

function updateStep(id, data) {
  const step = DB.steps.find(item => item.id === Number(id));
  if (!step) throw new Error("这个步骤已经不存在了。");
  ["seq", "name", "owner", "status", "start_date", "due_date",
   "progress", "note"].forEach(key => {
    if (data[key] === undefined) return;
    if (key === "progress" || key === "seq") step[key] = num(data[key]);
    else step[key] = data[key];
  });
  if (!String(step.name).trim()) throw new Error("步骤名称不能为空。");
  _save();
  queueStepSync(step, "upsert");
  return step;
}

function deleteStep(id) {
  const sid = Number(id);
  const step = DB.steps.find(item => item.id === sid) || null;
  // 工时不跟着删，只是把关联去掉那条工时是真干过的活，
  // 不该因为步骤被删就消失（和电脑端 ON DELETE SET NULL 一致）
  DB.worklogs.forEach(item => { if (item.step_id === sid) item.step_id = null; });
  DB.assignments.forEach(item => { if (item.step_id === sid) item.step_id = null; });
  DB.steps = DB.steps.filter(item => item.id !== sid);
  _save();
  queueStepSync(step, "delete");
}

function addEmployee(data) {
  const employee = {
    id: nextId("employee"),
    name: String(data.name || "").trim(),
    role: data.role || "",
    level: data.level || "",
    weekly_hours: num(data.weekly_hours) || 40,
    hired_date: data.hired_date || "",
    active: data.active === undefined ? 1 : num(data.active),
    note: data.note || "",
  };
  if (!employee.name) throw new Error("姓名不能为空。");
  DB.employees.push(employee);
  _save();
  return employee;
}

function updateEmployee(id, data) {
  const employee = getEmployee(id);
  if (!employee) throw new Error("这个人已经不在名单里了。");
  ["name", "role", "level", "weekly_hours", "hired_date", "active",
   "note"].forEach(key => {
    if (data[key] === undefined) return;
    if (key === "weekly_hours") employee[key] = num(data[key]) || 40;
    else if (key === "active") employee[key] = num(data[key]);
    else employee[key] = data[key];
  });
  if (!String(employee.name).trim()) throw new Error("姓名不能为空。");
  _save();
  return employee;
}

function getEmployee(id) {
  return DB.employees.find(item => item.id === Number(id)) || null;
}

/* 找一个"干活的人"：先查本机员工，再查公司成员。
   跨公司加入的老板号没有本机员工记录，只有 enterprise_members 里的 profile。 */
function resolveWorker(id) {
  const key = String(id || "").trim();
  if (!key) return null;
  const employee = DB.employees.find(item => String(item.id) === key) || null;
  if (employee) {
    return {
      source: "local",
      id: employee.id,
      profile_id: employee.profile_id || null,
      name: employee.name,
    };
  }
  const member = (DB.identity && Array.isArray(DB.identity.members)
    ? DB.identity.members : []).find(item => String(item.profile_id) === key) || null;
  if (member) {
    return {
      source: "member",
      id: member.profile_id,
      profile_id: member.profile_id,
      name: member.name || "未命名成员",
    };
  }
  return null;
}

function employeeByName(name) {
  return DB.employees.find(item => item.name === name) || null;
}

function activeEmployees() {
  return DB.employees.filter(item => item.active !== 0);
}

function deleteEmployee(id) {
  const eid = Number(id);
  // 工时和分配跟着删。一个人被删掉，他报的工时没有归属了，
  // 留着只会让统计出错。要保留历史的话应该改「离职」而不是删。
  DB.worklogs = DB.worklogs.filter(item => item.employee_id !== eid);
  DB.assignments = DB.assignments.filter(item => item.employee_id !== eid);
  DB.sessions = DB.sessions.filter(item => item.employee_id !== eid);
  DB.employees = DB.employees.filter(item => item.id !== eid);
  _save();
}

/* ============================================================
   工时
   ============================================================ */
function addWorklog(data, options) {
  const opts = options || {};
  const worker = resolveWorker(data.employee_id);
  if (!worker) throw new Error("先选一个人。");
  const hours = num(data.hours);
  if (hours <= 0) throw new Error("工时要大于 0。");
  if (hours > 24) throw new Error("一天不可能超过 24 小时。");
  const date = String(data.work_date || "").trim();
  if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) throw new Error("日期格式不对。");
  if (date > todayISO()) throw new Error("不能填未来的日期。");

  const projectId = data.project_id === undefined || data.project_id === ""
    ? null : Number(data.project_id);
  if (projectId !== null && !getProject(projectId)) {
    throw new Error("这个项目已经不存在了。");
  }

  // 手录的重复提醒：由调用方决定是否已经问过用户
  if (!opts.allowDuplicate) {
    const twin = findDuplicate(data);
    if (twin) throw new Error(
      "DUPLICATE:" + `${twin.work_date} ${employeeName(twin.employee_id)} `
      + `${projectName(twin.project_id)} ${num(twin.hours)} 小时`
    );
  }

  // 步骤必须属于所选项目，不然就是数据串了
  let stepId = data.step_id === undefined || data.step_id === "" || !data.step_id
    ? null : Number(data.step_id);
  if (stepId !== null) {
    const step = DB.steps.find(item => item.id === stepId);
    if (!step || step.project_id !== projectId) stepId = null;
  }

  const ownerProfileId = typeof currentEnterpriseOwnerId === "function"
    && currentEnterpriseOwnerId()
    ? currentEnterpriseOwnerId()
    : (DB.profile
      ? (DB.profile.role === "boss"
        ? String(DB.profile.id || "")
        : String(DB.profile.boss_id || ""))
      : "");
  const log = {
    id: nextId("worklog"),
    owner_profile_id: ownerProfileId,
    employee_id: worker.id,
    enterprise_id: typeof currentEnterpriseId === "function"
      ? currentEnterpriseId() : "",
    project_id: projectId,
    step_id: stepId,
    work_date: date,
    hours: hours,
    content: String(data.content || ""),
    // timer / manual：电脑端靠这个区分「真实计时」和「手工补录」
    source: data.source === "timer" ? "timer" : "manual",
    billable: data.billable !== false,
    overtime: !!data.overtime,
    work_kind: ["project", "presales", "internal"].indexOf(data.work_kind) !== -1
      ? data.work_kind : "project",
    rework: !!data.rework,
    waiting: !!data.waiting,
    travel: !!data.travel,
    created_at: nowISO(),
  };
  DB.worklogs.push(log);
  _save();
  return log;
}

function updateWorklog(id, data) {
  const local = DB.worklogs.find(item => String(item.id) === String(id));
  const remote = (DB.remoteWorklogs || []).find(
    item => String(item.id) === String(id));
  const log = local || remote;
  if (!log) throw new Error("这条工时已经不存在了。");
  const cloudOnly = !local;
  if (!cloudOnly && data.hours !== undefined) {
    const hours = num(data.hours);
    if (hours <= 0 || hours > 24) throw new Error("工时要大于 0 且不超过 24。");
    log.hours = hours;
  }
  if (!cloudOnly && data.work_date !== undefined) {
    const date = String(data.work_date).trim();
    if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) throw new Error("日期格式不对。");
    if (date > todayISO()) throw new Error("不能填未来的日期。");
    log.work_date = date;
  }
  if (!cloudOnly && data.project_id !== undefined) {
    log.project_id = data.project_id === "" || data.project_id === null
      ? null : Number(data.project_id);
    if (log.project_id !== null && !getProject(log.project_id)) {
      throw new Error("这个项目已经不存在了。");
    }
    // 换了项目，原来的步骤可能不属于新项目了
    if (log.step_id) {
      const step = DB.steps.find(item => item.id === log.step_id);
      if (!step || step.project_id !== log.project_id) log.step_id = null;
    }
  }
  if (!cloudOnly && data.step_id !== undefined) {
    log.step_id = data.step_id === "" || data.step_id === null
      ? null : Number(data.step_id);
  }
  if (!cloudOnly && data.employee_id !== undefined) {
    const worker = resolveWorker(data.employee_id);
    if (!worker) throw new Error("这个人已经不在名单里了。");
    log.employee_id = worker.id;
  }
  if (!cloudOnly && data.content !== undefined) log.content = String(data.content);
  if (data.billable !== undefined) log.billable = data.billable !== false;
  if (data.overtime !== undefined) log.overtime = !!data.overtime;
  if (data.work_kind !== undefined) {
    log.work_kind = ["project", "presales", "internal"].indexOf(data.work_kind) !== -1
      ? data.work_kind : "project";
  }
  if (data.rework !== undefined) log.rework = !!data.rework;
  if (data.waiting !== undefined) log.waiting = !!data.waiting;
  if (data.travel !== undefined) log.travel = !!data.travel;
  log.updated_at = nowISO();
  _save();
  return log;
}

function deleteWorklog(id) {
  DB.worklogs = DB.worklogs.filter(item => item.id !== Number(id));
  if (typeof removeQueuedWorklogMigration === "function") {
    removeQueuedWorklogMigration(id);
  }
  _save();
}

/* 找出「同一个人 + 同一项目 + 同一天 + 同样工时 + 同样说明」的记录。
   界面用它提醒可能重复，但**由人决定要不要继续**——
   上午下午各干 4 小时、备注写一样，是真实存在的两条。 */
function findDuplicate(data) {
  const employeeId = Number(data.employee_id);
  const projectId = data.project_id === undefined || data.project_id === ""
    ? null : Number(data.project_id);
  const hours = num(data.hours);
  const content = String(data.content || "");
  const date = String(data.work_date || "");
  return DB.worklogs.find(item =>
    item.employee_id === employeeId
    && item.project_id === projectId
    && item.work_date === date
    && Math.abs(num(item.hours) - hours) < 0.001
    && String(item.content || "") === content) || null;
}

/* 查工时。

   ## 关于 employee_id 的比较

   **不能写 `item.employee_id === Number(opts.employee_id)`。**
   员工在云端的 id 是 uuid 字符串，`Number("a1b2-...")` 得到 NaN，
   那个比较永远为 false —— 员工报的工时一条都筛不出来。

   所以统一用**字符串比较**：`String(甲) === String(乙)`。
   本地自增整数和云端 uuid 都能正确处理。

   ## includeRemote

   默认只查本机自己记的——因为改、删、导出这些操作只对本机记录有效。
   统计和展示时传 true，会一并带上 `DB.remoteWorklogs`
   （员工通过云端报上来的），并补上 `__source` 字段标明来源。 */
function worklogsFor(options) {
  const opts = options || {};
  let rows = DB.worklogs.map(item => Object.assign({ __source: "local" }, item));

  if (opts.includeRemote) {
    rows = rows.concat((DB.remoteWorklogs || []).map(item =>
      Object.assign({ __source: "cloud" }, item)));
  }

  if (opts.employee_id !== undefined && opts.employee_id !== null) {
    const wanted = String(opts.employee_id);
    rows = rows.filter(item => String(item.employee_id) === wanted);
  }
  if (opts.project_id !== undefined && opts.project_id !== null) {
    const project = typeof getProject === "function" ? getProject(opts.project_id) : null;
    const wanted = new Set([String(opts.project_id)]);
    if (project && project.remote_id) wanted.add(String(project.remote_id));
    rows = rows.filter(item => wanted.has(String(item.project_id)));
  }
  if (opts.date_from) rows = rows.filter(item => item.work_date >= opts.date_from);
  if (opts.date_to) rows = rows.filter(item => item.work_date <= opts.date_to);

  /* **id 用字符串比**：uuid 相减得到 NaN，
     会让排序结果不可预测（看起来像"顺序是随机的"）。 */
  rows.sort((a, b) =>
    String(b.work_date || "").localeCompare(String(a.work_date || ""))
    || String(b.id || "").localeCompare(String(a.id || "")));
  if (opts.limit) rows = rows.slice(0, opts.limit);
  return rows;
}

/* ============================================================
   分配 / 评估 / 指标
   ============================================================ */
function addAssignment(data) {
  const project = getProject(data.project_id);
  if (!project) throw new Error("先选项目。");
  const employee = getEmployee(data.employee_id);
  if (!employee) throw new Error("先选人。");
  let stepId = data.step_id ? Number(data.step_id) : null;
  if (stepId !== null) {
    const step = DB.steps.find(item => item.id === stepId);
    if (!step || step.project_id !== project.id) stepId = null;
  }
  const row = {
    id: nextId("assignment"),
    project_id: project.id,
    step_id: stepId,
    employee_id: employee.id,
    role_in_task: data.role_in_task || "",
    planned_hours: num(data.planned_hours),
    start_date: data.start_date || "",
    due_date: data.due_date || "",
    status: data.status || "待开始",
  };
  DB.assignments.push(row);
  _save();
  return row;
}

function deleteAssignment(id) {
  DB.assignments = DB.assignments.filter(item => item.id !== Number(id));
  _save();
}

function projectAssignments(projectId) {
  return DB.assignments.filter(item => item.project_id === Number(projectId));
}

function addAssessment(projectId, data) {
  const project = getProject(projectId);
  if (!project) throw new Error("这个项目已经不存在了。");
  const row = {
    id: nextId("assessment"),
    project_id: project.id,
    kind: data.kind === "resource" ? "resource" : "ability",
    name: String(data.name || "").trim(),
    score: clamp(num(data.score) || 3, 1, 5),
    weight: num(data.weight),
    note: data.note || "",
  };
  if (!row.name) throw new Error("名称不能为空。");
  if (row.weight <= 0) row.weight = 1;
  DB.assessments.push(row);
  _save();
  return row;
}

function deleteAssessment(id) {
  DB.assessments = DB.assessments.filter(item => item.id !== Number(id));
  _save();
}

function projectAssessments(projectId, kind) {
  return DB.assessments.filter(item =>
    item.project_id === Number(projectId)
    && (kind === undefined || item.kind === kind));
}

function addMetric(projectId, data) {
  const project = getProject(projectId);
  if (!project) throw new Error("这个项目已经不存在了。");
  const name = String(data.name || "").trim();
  if (!name) throw new Error("指标名不能为空。");
  const date = String(data.metric_date || "").trim();
  if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) throw new Error("日期格式不对。");
  const row = {
    id: nextId("metric"),
    project_id: project.id,
    metric_date: date,
    name: name,
    value: num(data.value),
    unit: data.unit || "",
    note: data.note || "",
  };
  DB.metrics.push(row);
  _save();
  return row;
}

function deleteMetric(id) {
  DB.metrics = DB.metrics.filter(item => item.id !== Number(id));
  _save();
}

function projectMetrics(projectId, name) {
  let rows = DB.metrics.filter(item => item.project_id === Number(projectId));
  if (name) rows = rows.filter(item => item.name === name);
  rows.sort((a, b) => (a.metric_date || "").localeCompare(b.metric_date || ""));
  return rows;
}

function metricNames(projectId) {
  const seen = [];
  projectMetrics(projectId).forEach(item => {
    if (seen.indexOf(item.name) === -1) seen.push(item.name);
  });
  return seen;
}

/* ============================================================
   同步队列
   ============================================================

   为什么要有队列，而不是"改完直接上传"：

     1. **没网也能用**。员工在外面勾任务，写不上去不能丢，
        先排队，联网自动补传。
     2. **不阻塞界面**。上传是异步的，界面按本地数据先画出来，
        不能等网络——否则点一下要卡一秒。

   队列项结构：{ id, dedupe, table, op, key, payload, at }

       table    目标表名（tasks / task_logs / worklogs）
       op       "insert" | "update" | "delete"
       dedupe   **去重键**。同一个键的变更只保留最后一次——
                改了三次只需要上传最终状态，中间那次没人关心。
                没有去重的话，员工反复改一条记录会让队列无限增长。

   同步状态**只放在这一张表里**，不散到各个业务表。
   散出去的话，漏掉一处就会出现"这条改了但永远不上传"
   这种查不出来的 bug。
   ============================================================ */

function queueChange(table, op, key, payload) {
  if (!Array.isArray(DB.syncQueue)) DB.syncQueue = [];
  const dedupeKey = `${table}:${op}:${key}`;
  DB.syncQueue = DB.syncQueue.filter(item => item.dedupe !== dedupeKey);
  DB.syncQueue.push({
    id: nextId("sync"),
    dedupe: dedupeKey,
    table: table,
    op: op,
    key: String(key),
    payload: payload || {},
    account_id: DB.account_scope_id || null,
    enterprise_id: DB.company_scope_id
      || (DB.identity && DB.identity.enterprise && DB.identity.enterprise.id)
      || null,
    at: nowISO(),
  });
  _save();
  return DB.syncQueue.length;
}

/* 队列里还有多少条待上传 */
function pendingCount() {
  return (Array.isArray(DB.syncQueue) ? DB.syncQueue.length : 0)
    + (Array.isArray(DB.dimensionQueue) ? DB.dimensionQueue.length : 0)
    + (Array.isArray(DB.worklogMigrationQueue)
      ? DB.worklogMigrationQueue.length : 0);
}

/* 上传成功后清掉那些项。只删成功的，失败的留着下次重试。 */
function clearQueueItems(ids) {
  if (!Array.isArray(DB.syncQueue)) return;
  const remove = ids.map(Number);
  DB.syncQueue = DB.syncQueue.filter(item => remove.indexOf(item.id) === -1);
  _save();
}

function clearDimensionQueue(ids) {
  if (!Array.isArray(DB.dimensionQueue)) return;
  const remove = ids.map(String);
  DB.dimensionQueue = DB.dimensionQueue.filter(
    item => remove.indexOf(String(item.worklog_id)) === -1);
  _save();
}

/* 登录 / 退出时重置同步状态。

   为什么必须重置：
     profile.id 是服务端分配的 uuid，而本地很多表用自增整数 id。
     切换账号后如果不清 cursor，增量拉取会从"上一个人的时间点"
     继续，于是漏掉新账号这段时间的数据。

   **notifyCursor 也一起清**：否则换了账号之后，
   新账号的事件时间戳比旧 cursor 早的会被当成"已经看过"而漏掉通知。 */
function resetSyncState() {
  /* Pending uploads belong to this account database. Never erase them on
     login, logout, restart or account switching. */
  DB.operations = { projects: [], capacity_gaps: [], performance: [],
                    worklog_summary: {}, capacity_demands: [], skills: [],
                    collection_alerts: [], members: [], security_audit: [],
                    access: {}, at: 0 };
  DB.myPerformance = { items: [], at: 0 };
  DB.execution = { acceptance: [], dependencies: [], handoffs: [],
                   changes: [], tasks: [], projects: [], members: [],
                   access: {}, at: 0 };
  DB.syncCursor = {};
  DB.notifyCursor = {};
  DB.lastSync = { at: "", ok: true, pending: 0, message: "" };
  _save();
}

/* ============================================================
   任务（员工端）
   ============================================================
   任务由老板派发，员工这边**只读**——本地的 tasks 只是服务端
   数据的缓存。员工改了也没用，因为不会写回服务端。
   ============================================================ */

function tasksOn(dateText) {
  const date = dateText || todayISO();
  return DB.tasks
    .filter(item => item.plan_date === date)
    .sort((a, b) => (a.sort || 0) - (b.sort || 0)
                    || String(a.id).localeCompare(String(b.id)));
}

function taskById(id) {
  return DB.tasks.find(item => String(item.id) === String(id)) || null;
}

/* 这条任务今天完成了吗 */
function taskLogFor(taskId) {
  if (!Array.isArray(DB.taskLogs)) return null;
  return DB.taskLogs.find(log =>
    String(log.task_id) === String(taskId)) || null;
}

/* ============================================================
   任务接受 / 申请延期
   ============================================================ */

/* 这条任务还没表态吗。
   accept_status 缺失时按 pending 算 —— 老数据没有这个字段，
   它们是在"接受"功能之前派的，应该让员工补表态一次，
   而不是当成已经接受。 */
function taskPendingAccept(task) {
  if (!task) return false;
  return (task.accept_status || "pending") === "pending";
}

/* 员工拒了这条任务吗 */
function taskRejected(task) {
  return !!task && task.accept_status === "rejected";
}

/* 这条任务上"待处理"的延期申请。
   同一条任务同时只会有一条 pending（服务端函数保证的），
   这里再兜一层，避免本地缓存有脏数据时界面出现两个按钮。 */
function pendingExtensionFor(taskId) {
  if (!Array.isArray(DB.taskRequests)) return null;
  const rows = DB.taskRequests.filter(item =>
    String(item.task_id) === String(taskId) && item.status === "pending");
  if (!rows.length) return null;
  rows.sort((a, b) => String(b.created_at || "").localeCompare(
    String(a.created_at || "")));
  return rows[0];
}

/* 某条任务的全部申请，新的在前 */
function taskRequestsFor(taskId) {
  if (!Array.isArray(DB.taskRequests)) return [];
  return DB.taskRequests
    .filter(item => String(item.task_id) === String(taskId))
    .sort((a, b) => String(b.created_at || "").localeCompare(
      String(a.created_at || "")));
}

/* 老板端：所有等着他批的申请 */
function pendingRequestsForBoss() {
  if (!Array.isArray(DB.taskRequests)) return [];
  return DB.taskRequests
    .filter(item => item.status === "pending")
    .sort((a, b) => String(a.created_at || "").localeCompare(
      String(b.created_at || "")));
}

/* ============================================================
   习惯
   ============================================================

   两种类型：
     daily     打勾型——"今天做没做"
     quantity  计量型——"今天做了多少"，要够到 target 才算完成

   周期用 weekdays 表达：存 "1 3 5"（周一到周日是 1~7）。
     空字符串 = 每天。
   这样一条习惯就能表达"每周一三五"、"只在周末"这些情况，
   不用为每种周期建一条。
   ============================================================ */

const WEEKDAY_NAMES = ["一", "二", "三", "四", "五", "六", "日"];

/* 日期是周几，1~7（周一=1，周日=7）。
   JS 的 getDay() 是 0=周日，所以要转换。 */
function weekdayOf(dateText) {
  const date = parseDate(dateText) || new Date();
  const day = date.getDay();
  return day === 0 ? 7 : day;
}

/* 这条习惯今天该不该做 */
function habitDueOn(habit, dateText) {
  if (habit.active === 0) return false;
  const weekdays = String(habit.weekdays || "").trim();
  if (!weekdays) return true;                    // 每天
  const day = weekdayOf(dateText);
  return weekdays.split(/[\s,]+/).indexOf(String(day)) !== -1;
}

function habitById(id) {
  return DB.habits.find(item => item.id === Number(id)) || null;
}

function activeHabits() {
  return DB.habits.slice()
    .filter(item => item.active !== 0)
    .sort((a, b) => (a.sort || 0) - (b.sort || 0) || a.id - b.id);
}

/* 今天（或指定日期）要做的习惯 */
function habitsDueOn(dateText) {
  const date = dateText || todayISO();
  return activeHabits().filter(habit => habitDueOn(habit, date));
}

function addHabit(data) {
  const name = String(data.name || "").trim();
  if (!name) throw new Error("习惯名称不能为空");

  const kind = data.kind === "quantity" ? "quantity" : "daily";
  const target = num(data.target);
  if (kind === "quantity" && target <= 0) {
    throw new Error("计量型习惯要填一个大于 0 的目标值");
  }

  const habit = {
    id: nextId("habit"),
    name: name,
    kind: kind,
    target: kind === "quantity" ? target : 0,
    unit: String(data.unit || "").trim(),
    weekdays: String(data.weekdays || "").trim(),
    note: String(data.note || "").trim(),
    /* sort 用手动序号：习惯的顺序是人为的（重要的排前面），
       不像工时那样有自然顺序。新建的排到最后。 */
    sort: (DB.habits.reduce((max, item) => Math.max(max, item.sort || 0), 0)) + 1,
    active: data.active === 0 ? 0 : 1,
    created_at: nowISO(),
  };
  DB.habits.push(habit);
  _save();
  return habit;
}

function updateHabit(id, data) {
  const habit = habitById(id);
  if (!habit) throw new Error("这条习惯已经不存在了");

  if (data.name !== undefined) {
    const name = String(data.name).trim();
    if (!name) throw new Error("习惯名称不能为空");
    habit.name = name;
  }
  if (data.kind !== undefined) {
    habit.kind = data.kind === "quantity" ? "quantity" : "daily";
  }
  if (data.target !== undefined) habit.target = num(data.target);
  if (data.unit !== undefined) habit.unit = String(data.unit).trim();
  if (data.weekdays !== undefined) {
    habit.weekdays = String(data.weekdays).trim();
  }
  if (data.note !== undefined) habit.note = String(data.note).trim();
  if (data.active !== undefined) habit.active = data.active === 0 ? 0 : 1;
  if (data.sort !== undefined) habit.sort = num(data.sort);

  if (habit.kind === "quantity" && habit.target <= 0) {
    throw new Error("计量型习惯要填一个大于 0 的目标值");
  }
  _save();
  return habit;
}

/* 删习惯连它的打卡记录一起删——留着就是孤儿数据 */
function deleteHabit(id) {
  const hid = Number(id);
  DB.habits = DB.habits.filter(item => item.id !== hid);
  DB.habitLogs = DB.habitLogs.filter(item => item.habit_id !== hid);
  _save();
}

/* ---------------------------------------------------------- 打卡 */

function habitLogOn(habitId, dateText) {
  const hid = Number(habitId);
  const date = dateText || todayISO();
  return DB.habitLogs.find(item =>
    item.habit_id === hid && item.log_date === date) || null;
}

/* 某天的所有打卡记录 */
function habitLogsOn(dateText) {
  const date = dateText || todayISO();
  return DB.habitLogs.filter(item => item.log_date === date);
}

/* 打卡。**同一天同一条习惯只保留一条记录**——
   重复调用是"覆盖"而不是"追加"，所以可以放心连点。 */
function checkHabit(habitId, value, note) {
  const habit = habitById(habitId);
  if (!habit) throw new Error("这条习惯已经不存在了");

  const date = todayISO();
  const amount = value === undefined || value === null
    ? (habit.kind === "quantity" ? num(habit.target) : 1)
    : num(value);
  if (habit.kind === "quantity" && amount <= 0) {
    throw new Error("填的数值要大于 0，否则取消打卡就好");
  }

  const existing = habitLogOn(habit.id, date);
  if (existing) {
    existing.value = amount;
    if (note !== undefined) existing.note = String(note);
    existing.done_at = nowISO();
  } else {
    DB.habitLogs.push({
      id: nextId("habitLog"),
      habit_id: habit.id,
      log_date: date,
      value: amount,
      note: note === undefined ? "" : String(note),
      done_at: nowISO(),
    });
  }
  _save();
  return habitLogOn(habit.id, date);
}

/* 取消打卡 */
function uncheckHabit(habitId, dateText) {
  const hid = Number(habitId);
  const date = dateText || todayISO();
  const before = DB.habitLogs.length;
  DB.habitLogs = DB.habitLogs.filter(item =>
    !(item.habit_id === hid && item.log_date === date));
  if (DB.habitLogs.length !== before) _save();
  return DB.habitLogs.length !== before;
}

/* 点一下圆圈：打过卡就取消，没打卡就打上。
   界面上只需要调这一个函数。 */
function toggleHabit(habitId) {
  const log = habitLogOn(habitId, todayISO());
  if (log) { uncheckHabit(habitId); return false; }
  checkHabit(habitId);
  return true;
}

/* 这条打卡算不算"完成"。
   打勾型：有记录就算完成。
   计量型：值要达到目标才算——记了 10 分钟但目标是 30 分钟，不算完成。 */
function habitDone(log, habit) {
  if (!log) return false;
  if (habit.kind !== "quantity") return true;
  return num(log.value) >= num(habit.target);
}

/* 连续完成天数（从今天往回数）。
   今天还没打卡不算断——可能还没到做的时候，所以从昨天继续数。
   这个"宽容"很重要：否则早上一打开就显示"连续 0 天"，
   会让人直接放弃。 */
function habitStreak(habitId, upToDate) {
  const habit = habitById(habitId);
  if (!habit) return 0;

  const logs = {};
  DB.habitLogs.forEach(item => {
    if (item.habit_id === Number(habitId)) logs[item.log_date] = item;
  });

  const end = parseDate(upToDate || todayISO()) || new Date();
  let streak = 0;
  let cursor = new Date(end.getTime());
  let first = true;

  /* 最多往前看 365 天，防止数据异常时死循环 */
  for (let step = 0; step < 365; step += 1) {
    const key = dateToISO(cursor);
    if (habitDueOn(habit, key)) {
      if (habitDone(logs[key], habit)) {
        streak += 1;
      } else if (first) {
        /* 今天（或起点那天）还没打——跳过，不断连 */
      } else {
        break;
      }
    }
    first = false;
    cursor = new Date(cursor.getTime() - 86400000);
  }
  return streak;
}

/* 一段时间内的完成率，返回 {due, done, rate} */
function habitRate(habitId, days) {
  const habit = habitById(habitId);
  if (!habit) return { due: 0, done: 0, rate: 0 };

  const logs = {};
  DB.habitLogs.forEach(item => {
    if (item.habit_id === Number(habitId)) logs[item.log_date] = item;
  });

  const today = parseDate(todayISO());
  let due = 0;
  let done = 0;
  for (let i = 0; i < days; i += 1) {
    const key = dateToISO(new Date(today.getTime() - i * 86400000));
    if (!habitDueOn(habit, key)) continue;
    due += 1;
    if (habitDone(logs[key], habit)) done += 1;
  }
  return { due: due, done: done, rate: due ? done / due : 0 };
}

/* 今天的完成情况，界面直接用 */
function todayHabitRows() {
  const today = todayISO();
  return habitsDueOn(today).map(habit => {
    const log = habitLogOn(habit.id, today);
    return {
      habit: habit,
      log: log,
      done: habitDone(log, habit),
      value: log ? num(log.value) : 0,
      streak: habitStreak(habit.id, today),
    };
  });
}

/* ============================================================
   通用小工具（别处也用到，放这里一起）

   计时相关的函数（nowMono / sessionElapsed / formatDuration /
   setSession / getSession / clearSession）已经全部删除——
   手机版的计时器整个去掉了，工时改成纯手工记。

   数据库结构里仍保留 `sessions` 数组：删掉的话，
   万一有历史计时数据会读不出来。已有的计时工时照样算进统计，
   只是不能再新增了。
   ============================================================ */
function num(value) {
  if (value === null || value === undefined || value === "") return 0;
  const parsed = parseFloat(value);
  return isFinite(parsed) ? parsed : 0;
}

function clamp(value, low, high) {
  return Math.min(high, Math.max(low, value));
}

function projectName(id) {
  const project = getProject(id);
  return project ? project.name : "";
}

function employeeName(id) {
  const employee = getEmployee(id);
  if (employee) return employee.name;
  if (typeof employeeNameOf === "function") return employeeNameOf(id);
  return "";
}

function stepName(id) {
  const step = DB.steps.find(item => item.id === Number(id));
  return step ? step.name : "";
}

function stepById(id) {
  return DB.steps.find(item => item.id === Number(id)) || null;
}
