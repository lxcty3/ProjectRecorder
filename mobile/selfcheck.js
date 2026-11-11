/* =============================================================
   手机版自检：语法 + 计算逻辑 + 洞察，每个用例独立跑。

   为什么需要它：
     check.py 只能查 Python。手机版是 JavaScript，
     它出语法错的话，在浏览器里表现为**整页空白**，
     手机上还看不到 Console——排查非常痛苦。

   为什么每个用例要新建上下文：
     第一版把所有用例放在同一个上下文里跑，结果前一个用例造的数据
     会影响后一个。比如「洞察在正常数据上不误报」明明只建了一个干净项目，
     却报出三个问题——因为前面用例的脏数据还留在 localStorage 里。
     **测试之间必须隔离**，否则失败原因看不出来。

   用法：
     node selfcheck.js
   ============================================================= */
"use strict";

const fs = require("fs");
const path = require("path");
const vm = require("vm");

const HERE = __dirname;
/* 语法检查的文件清单。
   **必须和 index.html 里 <script src> 的顺序一致**——
   漏掉一个的话，那个文件有语法错也查不出来，
   而语法错在浏览器里表现为"整页空白"，最难查。 */
const FILES = ["cloud-config.js", "store.js", "calc.js", "charts.js", "merit.js", "assist.js",
               "sync.js", "notify.js", "meeting.js", "update.js", "identity.js", "companies.js", "today.js",
               "decision.js", "operations.js", "execution.js", "intake.js", "account.js",
               "community.js",
               "app.js"];

let failed = 0;
function fail(label, detail) {
  failed += 1;
  console.log(`  [失败] ${label}`);
  if (detail) {
    console.log("         " + String(detail).split("\n").join("\n         "));
  }
}
function ok(label) { console.log(`  [OK]   ${label}`); }

/* ---------------------------------------------------------- 1. 语法 */
console.log("=".repeat(60));
console.log("[1] 语法检查");
FILES.forEach(name => {
  const full = path.join(HERE, name);
  if (!fs.existsSync(full)) { fail(`${name} 不存在`); return; }
  const source = fs.readFileSync(full, "utf8");
  try {
    new vm.Script(source, { filename: name });
    ok(name);
  } catch (error) {
    fail(name, error.message);
  }
});

/* ============================================================
   隔离的测试环境
   每次 fresh() 都造一个新的沙盒：空的 localStorage、新的 DB。
   这样用例之间不可能互相影响。
   ============================================================ */
function makeContext() {
  const storage = {};
  const sandbox = {
    console,
    localStorage: {
      getItem: key => (key in storage ? storage[key] : null),
      setItem: (key, value) => { storage[key] = String(value); },
      removeItem: key => { delete storage[key]; },
    },
    performance: { now: () => Date.now() },
    Date, Math, JSON, Object, Array, String, Number, Boolean, isFinite,
    parseFloat, parseInt, RegExp, Error, TypeError, RangeError,
    setTimeout, clearTimeout,
    /* **定时器必须 unref**，否则整个自检跑完也不退出。

       sync.js 的 startSyncLoop() 会 setInterval(30 秒) 做后台同步。
       那个定时器让 node 的事件循环永远有活干，进程就挂着不结束——
       表现出来就是"自检卡住了"，其实测试早就跑完并通过了。

       unref 的语义正是"不要因为这个定时器而保持进程活着"。 */
    setInterval: (fn, ms) => {
      const timer = setInterval(fn, ms);
      if (timer && timer.unref) timer.unref();
      return timer;
    },
    clearInterval,
    CanvasRenderingContext2D: undefined,
    /* sync.js 用到的浏览器 API，node 里都没有。
       给最小可用的桩——目的是让文件能加载、纯逻辑函数能测，
       不是模拟浏览器行为。 */
    /* **URL 必须给**：normalizeCloudUrl 用它裁掉地址里的路径
       （用户很容易粘成 .../rest/v1/）。
       沙箱里缺这个对象的话，那个函数会走兜底分支——
       表现为"规整没生效"，而测试会误判成代码有 bug。 */
    URL: URL,
    crypto: {
      randomUUID: () => "test-" + Math.random().toString(16).slice(2, 10),
    },
    navigator: { onLine: true },
    /* supabase 是从 CDN 载入的全局对象。测试里不联网，所以留 undefined——
       这正好也验证了"没配云服务时程序不会崩"。 */
    document: {
      hidden: false,
      addEventListener: () => {},
      getElementById: () => null,
      querySelectorAll: () => [],
      createElement: () => ({ style: {}, classList: { add() {}, remove() {} } }),
      /* applyThemeVariables 会往这里写 CSS 变量。
         node 里没有 DOM，给个能接受 setProperty 的桩就行，
         这样主题配色的「有没有缺项」就能测。 */
      documentElement: {
        style: { setProperty: () => {} },
        setAttribute: () => {},
      },
    },
  };
  sandbox.window = sandbox;
  sandbox.__storage = storage;
  return vm.createContext(sandbox);
}

let ctx = null;

/* 在一段文本里反复匹配，返回所有捕获组。

   **为什么要封成函数**：我原来到处写这个模式——

       let match = /re/g.exec(text);
       while (match) { ...; match = /re/g.exec(text); }

   **这是死循环**：每次循环都新建一个正则字面量，
   `lastIndex` 于是每次从 0 开始，永远匹配第一处。
   我在同一个文件里犯了这个错 6 次，症状是自检跑完所有用例后
   不退出（CPU 空转），而且**没有任何报错**——很难查。

   这个封装用**一个**正则实例、并且带"位置没前进就退出"的保护，
   从根本上避免这类错误。 */
function matchAll(text, pattern, group) {
  const results = [];
  const index = group === undefined ? 1 : group;
  let match = pattern.exec(text);
  let guard = 0;
  while (match) {
    results.push(match[index]);
    /* 保护：如果 lastIndex 没有前进（零宽匹配），立刻退出。
       没有这个保护，一个能匹配空串的正则会让整个自检挂死。 */
    if (pattern.lastIndex === match.index) pattern.lastIndex += 1;
    guard += 1;
    if (guard > 100000) {
      throw new Error("matchAll 匹配次数异常（正则可能有问题）");
    }
    match = pattern.exec(text);
  }
  return results;
}

/* **预先编译一次**，之后每个用例只是"在新环境里重新执行"。

   为什么必须这样：
     原来每个用例都用 vm.runInContext(source, ctx) 传字符串，
     V8 会对同一份源码**重新解析编译**，而且编译产物挂在那个 realm 上
     不能回收。50 多个用例 × 4 个文件，堆直接涨到 4 GB，
     最后 "JavaScript heap out of memory" 崩溃。

     改成 vm.Script 预编译后，每个用例只付"执行"的代价。
*/
const COMPILED = ["store.js", "calc.js", "assist.js", "charts.js", "merit.js",
                  "sync.js", "notify.js", "operations.js", "execution.js", "intake.js"]
  .map(name => ({
  name,
  script: new vm.Script(fs.readFileSync(path.join(HERE, name), "utf8"),
                        { filename: name }),
}));

/* 新建一个干净环境，载入模块并把 DB 初始化好。
   charts.js 也要载入——主题配色表 THEME_COLORS 在那里，
   而主题相关的用例要检查它。 */
function fresh() {
  ctx = makeContext();
  COMPILED.forEach(item => item.script.runInContext(ctx));
  vm.runInContext("DB = loadAll();", ctx);
  return ctx;
}

/* 在当前环境里执行代码。返回值会跨 realm——处理成普通对象更好用。 */
function run(code) {
  return vm.runInContext(code, ctx);
}

/* 把跨 realm 的值转成本 realm 的普通对象（数组也是），
   否则在某些情况下 instanceof / 深比较会不符合预期 */
function plain(value) {
  return JSON.parse(JSON.stringify(value));
}

console.log("\n[2] 计算逻辑（每个用例独立环境）");

/* ---------------------------------------------------------- 用例 */
const CASES = [];
function test(label, body) { CASES.push([label, body]); }

/* ---- 存储与基础 ---- */
test("空库时预测不崩", () => {
  fresh();
  if (run("projectSummary().length") !== 0) throw new Error("空库应当没有项目");
  if (run("loadRows().rows.length") !== 0) throw new Error("空库不该有员工");
  if (run("insights().length") !== 0) throw new Error("空库不该有洞察");
});

test("新建项目", () => {
  fresh();
  const project = run(`addProject({name: "智慧园区", owner: "李工",
    status: "进行中", start_date: "2026-01-01", due_date: "2026-02-01",
    budget: 100000, cost: 50000, progress: 30})`);
  if (project.name !== "智慧园区") throw new Error("项目名不对：" + project.name);
  if (run("DB.projects.length") !== 1) throw new Error("没进库");
});

test("项目名为空要报错", () => {
  fresh();
  let caught = false;
  try { run('addProject({name: "   "});'); } catch (error) { caught = true; }
  if (!caught) throw new Error("空名字没被拦住");
});

test("项目名前后空格要去掉", () => {
  fresh();
  run('addProject({name: "  带空格的项目  "});');
  const name = run("DB.projects[0].name");
  if (name !== "带空格的项目") throw new Error("没去掉空格：" + JSON.stringify(name));
});

/* ---- 员工 ---- */
test("新建员工", () => {
  fresh();
  run('addEmployee({name: "王强", role: "后端", level: "P6", weekly_hours: 40});');
  if (run("DB.employees.length") !== 1) throw new Error("没进库");
  if (run("activeEmployees().length") !== 1) throw new Error("在岗人数不对");
});

test("员工姓名为空要报错", () => {
  fresh();
  let caught = false;
  try { run('addEmployee({name: ""});'); } catch (error) { caught = true; }
  if (!caught) throw new Error("空姓名没被拦住");
});

test("周工时填 0 时按 40 处理", () => {
  fresh();
  run('addEmployee({name: "某人", weekly_hours: 0});');
  const weekly = run("DB.employees[0].weekly_hours");
  if (weekly !== 40) throw new Error("应当是 40，实际 " + weekly);
});

/* ---- 步骤 ---- */
test("新建步骤并自动排序号", () => {
  fresh();
  run(`window.__p = addProject({name: "P"});
    addStep(window.__p.id, {name: "第一步"});
    addStep(window.__p.id, {name: "第二步"});`);
  const seqs = plain(run("projectSteps(window.__p.id).map(function(s){return s.seq;})"));
  if (seqs.join(",") !== "1,2") throw new Error("序号不对：" + seqs.join(","));
});

test("步骤名为空要报错", () => {
  fresh();
  run('window.__p = addProject({name: "P"});');
  let caught = false;
  try { run('addStep(window.__p.id, {name: " "});'); } catch (error) { caught = true; }
  if (!caught) throw new Error("空步骤名没被拦住");
});

/* ---- 工时 ---- */
test("记一条工时", () => {
  fresh();
  run(`window.__p = addProject({name: "P"});
    window.__e = addEmployee({name: "王强"});
    window.__s = addStep(window.__p.id, {name: "步骤"});
    addWorklog({employee_id: window.__e.id, project_id: window.__p.id,
      step_id: window.__s.id, work_date: "2026-01-05", hours: 8,
      content: "调接口"});`);
  if (run("DB.worklogs.length") !== 1) throw new Error("没进库");
  if (run("DB.worklogs[0].step_id") !== run("window.__s.id")) {
    throw new Error("步骤没关联上");
  }
});

test("工时经营标签有兼容默认值并可在修改时更新", () => {
  fresh();
  run(`window.__e = addEmployee({name: "王强"});
    window.__w = addWorklog({employee_id: window.__e.id,
      work_date: "2026-01-05", hours: 8, content: "默认标签"});`);
  if (run("DB.worklogs[0].billable") !== true) throw new Error("默认可计费丢失");
  if (run("DB.worklogs[0].work_kind") !== "project") throw new Error("默认项目类型丢失");
  if (run("DB.worklogs[0].overtime || DB.worklogs[0].rework")) {
    throw new Error("加班/返工默认应为否");
  }
  run(`updateWorklog(window.__w.id, {billable: false, overtime: true,
    work_kind: "presales", rework: true, waiting: true, travel: true});`);
  if (run("DB.worklogs[0].work_kind") !== "presales") throw new Error("类型没更新");
  if (run("DB.worklogs[0].billable") !== false) throw new Error("可计费没更新");
  if (run("DB.worklogs[0].travel") !== true) throw new Error("出差没更新");
});

test("工时经营标签排队后只保留一条并可撤销", () => {
  fresh();
  run(`DB.profile = {id: "profile-uuid"};
    queueWorklogDimensions("11111111-1111-4111-8111-111111111111",
      {billable: true, work_kind: "project"});
    queueWorklogDimensions("11111111-1111-4111-8111-111111111111",
      {billable: false, work_kind: "internal", overtime: true});`);
  if (run("DB.dimensionQueue.length") !== 1) throw new Error("同一工时重复排队");
  if (run("DB.dimensionQueue[0].data.work_kind") !== "internal") {
    throw new Error("后一次标签没覆盖前一次");
  }
  if (run("pendingCount()") !== 1) throw new Error("待上传数量没算标签");
  run('removeQueuedWorklogDimensions("11111111-1111-4111-8111-111111111111");');
  if (run("DB.dimensionQueue.length") !== 0) throw new Error("撤销后标签仍在队列");
});

test("本地工时维度保留到拿到云 UUID 后再同步", () => {
  fresh();
  run(`DB.profile = {id: "profile-uuid"};
    queueWorklogDimensions(42, {billable: false, overtime: true,
      work_kind: "presales", rework: true, waiting: true, travel: true});`);
  if (run("DB.dimensionQueue.length") !== 1) throw new Error("本地维度没进队列");
  const reserved = run("DB.dimensionQueue[0].worklog_id");
  if (!run(`operationsUuid(${JSON.stringify(reserved)})`)) {
    throw new Error("本地数字 id 没有换成预留云 UUID");
  }
  if (run("DB.dimensionQueue[0].local_id") !== null) {
    throw new Error("维度不应继续永久等待本地 id");
  }
  if (run("DB.worklogMigrationQueue[0].local_id") !== "42") {
    throw new Error("迁移队列没保留本地工时 id");
  }
  if (run("DB.dimensionQueue[0].worklog_id") !== reserved) {
    throw new Error("预留云 UUID 后被意外改写");
  }
  if (run("DB.dimensionQueue[0].data.work_kind") !== "presales") {
    throw new Error("等待同步时维度被丢掉");
  }
});

test("本地手工工时排队迁移为云 UUID 并同步维度", () => {
  fresh();
  run(`DB.profile = {id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
      role: "boss", name: "老板"};
    window.__e = addEmployee({name: "王强"});
    window.__p = addProject({name: "本地项目"});
    window.__w = addWorklog({employee_id: window.__e.id,
      project_id: window.__p.id, work_date: "2026-01-05",
      hours: 8, content: "本地手工工时"});
    DB.employees[0].cloud_id =
      "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
    syncWorklogDimensions(window.__w);`);
  if (run("DB.worklogMigrationQueue.length") !== 1) {
    throw new Error("本地工时没有进入迁移队列");
  }
  const cloudId = run("DB.worklogMigrationQueue[0].cloud_id");
  if (!run(`operationsUuid(${JSON.stringify(cloudId)})`)) {
    throw new Error("迁移队列没有分配云 UUID");
  }
  if (run("DB.dimensionQueue.length") !== 1) {
    throw new Error("维度没有继续排队");
  }
  if (run("DB.dimensionQueue[0].worklog_id") !== cloudId) {
    throw new Error("维度没有绑定预留的云 UUID");
  }
  if (run("DB.dimensionQueue[0].local_id") !== null) {
    throw new Error("维度仍在等待非 UUID");
  }
  const built = plain(run("worklogMigrationPayload(DB.worklogMigrationQueue[0])"));
  if (!built.ready) throw new Error("可映射工时却没有迁移载荷");
  if (built.payload.employee_id
      !== "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb") {
    throw new Error("迁移载荷没有使用云端员工 UUID");
  }
  if (built.payload.project_name !== "本地项目") {
    throw new Error("迁移后丢失本地项目名称");
  }
  run("completeWorklogMigration(DB.worklogMigrationQueue[0]);");
  if (run("DB.worklogMigrationQueue.length") !== 0) {
    throw new Error("迁移成功后队列没有清掉");
  }
  if (run("DB.worklogs[0].cloud_id") !== cloudId) {
    throw new Error("本地工时没有记录云 UUID");
  }
});

test("本地工时缺员工云映射时等待而不是永久拒绝", () => {
  fresh();
  run(`DB.profile = {id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
      role: "boss", name: "老板"};
    window.__e = addEmployee({name: "待建号员工"});
    window.__w = addWorklog({employee_id: window.__e.id,
      work_date: "2026-01-05", hours: 4, content: "等待建号"});
    syncWorklogDimensions(window.__w);`);
  let built = plain(run("worklogMigrationPayload(DB.worklogMigrationQueue[0])"));
  if (built.ready) throw new Error("没有员工云映射却可以迁移");
  if (run("DB.worklogMigrationQueue.length") !== 1) {
    throw new Error("等待状态不应丢失迁移项");
  }
  run(`DB.employees[0].cloud_id =
    "cccccccc-cccc-4ccc-8ccc-cccccccccccc";`);
  built = plain(run("worklogMigrationPayload(DB.worklogMigrationQueue[0])"));
  if (!built.ready) throw new Error("员工拿到云 UUID 后仍未恢复迁移");
});

test("历史非 UUID 维度队列会补建本地工时迁移", () => {
  fresh();
  run(`DB.profile = {id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
      role: "boss", name: "老板"};
    window.__e = addEmployee({name: "王强"});
    DB.employees[0].cloud_id =
      "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
    window.__w = addWorklog({employee_id: window.__e.id,
      work_date: "2026-01-05", hours: 2, content: "历史本地工时"});
    DB.dimensionQueue = [{worklog_id: null, local_id: String(window.__w.id),
      data: {work_kind: "internal", billable: false}}];
    ensureLocalWorklogMigrationQueues();`);
  if (run("DB.worklogMigrationQueue.length") !== 1) {
    throw new Error("历史等待项没有补建迁移队列");
  }
  const cloudId = run("DB.worklogMigrationQueue[0].cloud_id");
  if (run("DB.dimensionQueue[0].worklog_id") !== cloudId) {
    throw new Error("历史维度项没有改绑云 UUID");
  }
  if (run("DB.dimensionQueue[0].local_id") !== null) {
    throw new Error("历史维度项仍在永久等待");
  }
});

test("对象形式的绩效证据也能渲染来源 ID", () => {
  fresh();
  const html = run(`(function () {
    var box = { innerHTML: "", querySelectorAll: function () { return []; } };
    document.getElementById = function (id) {
      return id === "my-performance" ? box : null;
    };
    window.$ = function (id) { return document.getElementById(id); };
    window.escapeHtml = function (value) {
      return String(value == null ? "" : value)
        .replace(/&/g, "&amp;").replace(/</g, "&lt;")
        .replace(/>/g, "&gt;").replace(/"/g, "&quot;");
    };
    DB.myPerformance = {items: [{
      id: "e1", period: "2026-11", status: "submitted", score: 81,
      evidence: {type: "worklog", source_id: "w1", label: "客户交付"},
      employee_statement: "", reviewer_note: ""
    }]};
    renderMyPerformance();
    return box.innerHTML;
  })();`);
  if (html.indexOf("worklog w1") === -1) {
    throw new Error("对象证据没有显示 source_id");
  }
});

test("简单模式和权限丢失会清掉经营缓存", () => {
  fresh();
  run(`window.$ = function (id) { return document.getElementById(id); };
    DB.profile = {id: "u1"};
    DB.uiMode = "simple";
    DB.operations = {projects: [{name: "secret"}],
      capacity_gaps: [], performance: [], worklog_summary: {}, at: 1};`);
  if (run("operationsAllowedInCurrentMode()") !== false) {
    throw new Error("简单模式被误判为允许经营数据");
  }
  run("clearOperationsCache()");
  if (run("DB.operations.projects.length") !== 0) {
    throw new Error("权限/模式变化后经营缓存没清空");
  }
});

test("工时为 0 要报错", () => {
  fresh();
  run('window.__e = addEmployee({name: "王强"});');
  let caught = false;
  try {
    run('addWorklog({employee_id: window.__e.id, work_date: "2026-01-05", hours: 0});');
  } catch (error) { caught = true; }
  if (!caught) throw new Error("0 小时没被拦住");
});

test("工时超 24 要报错", () => {
  fresh();
  run('window.__e = addEmployee({name: "王强"});');
  let caught = false;
  try {
    run('addWorklog({employee_id: window.__e.id, work_date: "2026-01-05", hours: 30});');
  } catch (error) { caught = true; }
  if (!caught) throw new Error("30 小时没被拦住");
});

test("未来日期要报错", () => {
  fresh();
  run('window.__e = addEmployee({name: "王强"});');
  let caught = false;
  try {
    run('addWorklog({employee_id: window.__e.id, work_date: "2099-01-01", hours: 8});');
  } catch (error) { caught = true; }
  if (!caught) throw new Error("未来日期没被拦住");
});

test("不选人要报错", () => {
  fresh();
  let caught = false;
  try { run('addWorklog({employee_id: 999, work_date: "2026-01-05", hours: 8});'); }
  catch (error) { caught = true; }
  if (!caught) throw new Error("不存在的人没被拦住");
});

test("步骤不属于所选项目时自动去掉关联", () => {
  fresh();
  run(`window.__a = addProject({name: "A"});
    window.__b = addProject({name: "B"});
    window.__sa = addStep(window.__a.id, {name: "A 的步骤"});
    window.__e = addEmployee({name: "某人"});
    addWorklog({employee_id: window.__e.id, project_id: window.__b.id,
      step_id: window.__sa.id, work_date: "2026-01-05", hours: 8});`);
  if (run("DB.worklogs[0].step_id") !== null) {
    throw new Error("别的项目的步骤被挂上了");
  }
});

test("重复工时要能查出来", () => {
  fresh();
  run(`window.__p = addProject({name: "P"});
    window.__e = addEmployee({name: "王强"});
    addWorklog({employee_id: window.__e.id, project_id: window.__p.id,
      work_date: "2026-01-05", hours: 8, content: "调接口"});`);
  const dup = run(`findDuplicate({employee_id: window.__e.id,
    project_id: window.__p.id, work_date: "2026-01-05", hours: 8,
    content: "调接口"}) !== null`);
  if (!dup) throw new Error("同样的工时没查出重复");
});

test("工时不同不算重复", () => {
  fresh();
  run(`window.__p = addProject({name: "P"});
    window.__e = addEmployee({name: "王强"});
    addWorklog({employee_id: window.__e.id, project_id: window.__p.id,
      work_date: "2026-01-05", hours: 8, content: "调接口"});`);
  const dup = run(`findDuplicate({employee_id: window.__e.id,
    project_id: window.__p.id, work_date: "2026-01-05", hours: 5,
    content: "调接口"}) !== null`);
  if (dup) throw new Error("工时不同却报了重复");
});

test("allowDuplicate 能强制记两条一样的", () => {
  fresh();
  run(`window.__p = addProject({name: "P"});
    window.__e = addEmployee({name: "王强"});
    addWorklog({employee_id: window.__e.id, project_id: window.__p.id,
      work_date: "2026-01-05", hours: 4, content: "修 bug"});
    addWorklog({employee_id: window.__e.id, project_id: window.__p.id,
      work_date: "2026-01-05", hours: 4, content: "修 bug"},
      {allowDuplicate: true});`);
  if (run("DB.worklogs.length") !== 2) {
    throw new Error("上午下午各 4 小时是两条真实记录，不该被去重");
  }
});

/* ---- 预测 ---- */
test("预测给出等级和依据", () => {
  fresh();
  run(`window.__p = addProject({name: "测试项目", status: "进行中",
    start_date: "2026-01-01", due_date: "2026-02-01", progress: 30,
    budget: 10000, cost: 9000});
    window.__e = addEmployee({name: "王强"});
    addStep(window.__p.id, {name: "卡住的", status: "已阻塞",
      due_date: "2026-01-10"});`);
  const result = plain(run("predict(window.__p)"));
  if (!result.level) throw new Error("没有等级");
  if (!result.reasons.length) throw new Error("没有依据");
  if (!result.headline) throw new Error("没有结论文本");
  if (["健康", "关注", "风险", "严重"].indexOf(result.level) === -1) {
    throw new Error("等级不在允许范围：" + result.level);
  }
  result.reasons.forEach(reason => {
    if (!reason.text || !reason.text.trim()) throw new Error("有依据缺 text");
  });
});

test("阻塞步骤要被算进风险", () => {
  fresh();
  run(`window.__p = addProject({name: "P", status: "进行中", progress: 50});
    addStep(window.__p.id, {name: "卡住的", status: "已阻塞"});`);
  const result = plain(run("predict(window.__p)"));
  const hit = result.reasons.some(reason => reason.text.indexOf("阻塞") !== -1);
  if (!hit) throw new Error("有阻塞步骤但预测里没提");
});

test("已交付的项目不再报风险", () => {
  fresh();
  run(`window.__p = addProject({name: "交付了的", status: "已交付",
    progress: 100, start_date: "2026-01-01", due_date: "2026-02-01",
    budget: 100000, cost: 120000});`);
  const result = plain(run("predict(window.__p)"));
  if (result.level === "风险" || result.level === "严重") {
    throw new Error("已交付的项目不该是高风险：" + result.level);
  }
  if (result.headline.indexOf("交付") === -1) {
    throw new Error("结论里该提到已交付：" + result.headline);
  }
});

test("健康项目判为健康", () => {
  fresh();
  run(`window.__p = addProject({name: "健康项目", status: "进行中",
    start_date: todayISO(),
    due_date: dateToISO(new Date(today().getTime() + 120 * 86400000)),
    progress: 50, budget: 100000, cost: 10000});
    window.__e = addEmployee({name: "正常人", weekly_hours: 40});
    addStep(window.__p.id, {name: "第一步", status: "已完成"});
    addStep(window.__p.id, {name: "第二步", status: "进行中"});
    addWorklog({employee_id: window.__e.id, project_id: window.__p.id,
      work_date: todayISO(), hours: 4, content: "干活"}, {allowDuplicate: true});`);
  const result = plain(run("predict(window.__p)"));
  if (result.level !== "健康") {
    throw new Error("干净的新项目应当是「健康」，实际「" + result.level
      + "」，依据：" + result.reasons.map(r => r.text).join("；"));
  }
});

/* ---- 预算与负荷 ---- */
test("预算占用算得对", () => {
  fresh();
  run('window.__p = addProject({name: "P", budget: 100000, cost: 50000});');
  const ratio = run("budgetOf(window.__p).ratio");
  if (Math.abs(ratio - 0.5) > 0.001) throw new Error("该是 50%，实际 " + ratio);
});

test("没设预算时不给比例", () => {
  fresh();
  run('window.__p = addProject({name: "没预算的", cost: 5000});');
  const budget = plain(run("budgetOf(window.__p)"));
  if (budget.has !== false) throw new Error("没预算却 has=true");
  if (budget.ratio !== null) throw new Error("没预算却给了比例");
});

test("超预算能判出来", () => {
  fresh();
  run('window.__p = addProject({name: "P", budget: 1000, cost: 1500});');
  const budget = plain(run("budgetOf(window.__p)"));
  if (!budget.over) throw new Error("超了却没判出来");
  if (Math.abs(budget.remaining + 500) > 0.001) {
    throw new Error("剩余金额不对：" + budget.remaining);
  }
});

test("负荷率随窗口天数变", () => {
  fresh();
  const seven = run("loadRatio(60, 40, 7)");
  const twentyEight = run("loadRatio(60, 40, 28)");
  if (Math.abs(seven - 1.5) > 0.001) throw new Error("7 天应当是 1.5：" + seven);
  if (Math.abs(twentyEight - 0.375) > 0.001) {
    throw new Error("28 天应当是 0.375：" + twentyEight);
  }
});

test("周基准为 0 不崩", () => {
  fresh();
  if (run("loadRatio(60, 0, 7)") !== 0) throw new Error("周基准 0 应当返回 0");
});

test("没工时时负荷窗口退回 7 天", () => {
  fresh();
  const days = run("worklogWindow().days");
  if (days !== 7) throw new Error("空库应当是 7 天，实际 " + days);
});

/* ---- 洞察 ---- */
test("洞察在干净数据上完全不误报", () => {
  fresh();
  /* 这个用例只造「一个健康项目 + 一个正常员工 + 几条正常工时」，
     不该报出任何问题。之前它误报了三条，原因是测试之间没隔离，
     前面用例的脏数据留在了 localStorage 里。 */
  run(`window.__p = addProject({name: "干净项目", status: "进行中",
    start_date: todayISO(),
    due_date: dateToISO(new Date(today().getTime() + 120 * 86400000)),
    budget: 100000, cost: 10000, progress: 50});
    window.__e = addEmployee({name: "正常人", weekly_hours: 40});
    addStep(window.__p.id, {name: "第一步", status: "已完成"});
    addStep(window.__p.id, {name: "第二步", status: "进行中"});
    window.__st = projectSteps(window.__p.id)[1];
    addAssignment({project_id: window.__p.id, step_id: window.__st.id,
      employee_id: window.__e.id, planned_hours: 40});
    for (var i = 0; i < 3; i += 1) {
      addWorklog({employee_id: window.__e.id, project_id: window.__p.id,
        step_id: window.__st.id,
        work_date: dateToISO(new Date(today().getTime() - i * 86400000)),
        hours: 4, content: "干活 " + i}, {allowDuplicate: true});
    }`);
  const found = plain(run("insights()"));
  if (found.length) {
    throw new Error("干净数据上报了 " + found.length + " 条："
      + found.map(item => item.title).join("；"));
  }
});

test("洞察能抓出顺序矛盾", () => {
  fresh();
  run(`window.__p = addProject({name: "P", status: "进行中"});
    addStep(window.__p.id, {name: "第一步", status: "进行中"});
    addStep(window.__p.id, {name: "第二步", status: "已完成"});`);
  const found = plain(run("insights()"));
  const hit = found.some(item => item.title.indexOf("顺序矛盾") !== -1);
  if (!hit) throw new Error("顺序矛盾没被抓出来："
    + found.map(item => item.title).join("；"));
});

test("洞察能抓出超负荷", () => {
  fresh();
  /* 不要硬编码「几天前」去凑窗口——那依赖窗口天数和今天的位置，
     改一点就对不上（我先写了 8 天、又写了 14 天，两次都算错）。
     改成**显式问窗口的范围**，把工时铺在窗口内的每一天上。 */
  run(`window.__p = addProject({name: "P", status: "进行中"});
    window.__e = addEmployee({name: "忙人", weekly_hours: 40});`);
  const window = plain(run("worklogWindow()"));
  run(`(function () {
    var from = new Date(${JSON.stringify(window.from)} + "T00:00:00");
    var to = new Date(${JSON.stringify(window.to)} + "T00:00:00");
    for (var d = new Date(from); d <= to; d.setDate(d.getDate() + 1)) {
      addWorklog({employee_id: window.__e.id, project_id: window.__p.id,
        work_date: dateToISO(d), hours: 8,
        content: "干活 " + dateToISO(d)}, {allowDuplicate: true});
    }
  })();`);

  const rows = plain(run("loadRows().rows"));
  const top = rows[0];
  /* 每天 8 小时铺满整个窗口 → 负荷必然是 8/40*7/天数... 直接用比例判断 */
  const expected = 40 * (window.days / 7);
  if (Math.abs(top.expected - expected) > 0.001) {
    throw new Error(`同期应出应当是 ${expected}，实际 ${top.expected}`
      + "——分母没跟着窗口天数走");
  }
  if (top.hours < expected + 1) {
    throw new Error(`铺满了窗口却只有 ${top.hours} 小时，同期应出 ${expected}`);
  }
  if (top.ratio <= 1) throw new Error("负荷应当超过 1，实际 " + top.ratio);

  const found = plain(run("insights()"));
  const hit = found.some(item => item.title.indexOf("超出同期") !== -1);
  if (!hit) throw new Error("负荷 " + Math.round(top.ratio * 100)
    + "% 没被抓成超负荷：" + found.map(item => item.title).join("；"));
});

test("洞察能抓出效率对比", () => {
  fresh();
  /* 效率对比需要**两个都在进行中、且都有花费**的项目，
     一个「花钱多进度低」，一个「花钱少进度高」。 */
  run(`window.__a = addProject({name: "低效项目", status: "进行中",
      cost: 900000, progress: 10});
    window.__b = addProject({name: "高效项目", status: "进行中",
      cost: 5000, progress: 80});`);
  const found = plain(run("insights()"));
  const hit = found.some(item => item.title.indexOf("投入最大") !== -1);
  if (!hit) throw new Error("明显的效率差距没被抓出来："
    + found.map(item => item.title).join("；"));
});

test("只有零花费的项目时不报效率对比", () => {
  fresh();
  /* 防误报：花费都是 0 时算不出效率，不该硬报一条 */
  run(`window.__a = addProject({name: "A", status: "进行中", cost: 0,
      progress: 10});
    window.__b = addProject({name: "B", status: "进行中", cost: 0,
      progress: 80});`);
  const found = plain(run("insights()"));
  const hit = found.some(item => item.title.indexOf("投入最大") !== -1);
  if (hit) throw new Error("零花费不该报效率对比");
});

test("负荷窗口是 7 个日期而不是 8 个", () => {
  fresh();
  /* 边界容易搞错：从今天往前数 7 个日期（含今天），
     所以偏移 6 的那天在窗口里，偏移 7 的不在。 */
  run(`window.__p = addProject({name: "P", status: "进行中"});
    window.__e = addEmployee({name: "某人", weekly_hours: 40});
    addWorklog({employee_id: window.__e.id, project_id: window.__p.id,
      work_date: dateToISO(new Date(today().getTime() - 6 * 86400000)),
      hours: 8, content: "第 6 天前"}, {allowDuplicate: true});
    addWorklog({employee_id: window.__e.id, project_id: window.__p.id,
      work_date: dateToISO(new Date(today().getTime() - 7 * 86400000)),
      hours: 8, content: "第 7 天前"}, {allowDuplicate: true});`);
  const window = plain(run("worklogWindow()"));
  if (window.days !== 7) {
    throw new Error("有 7 天内的记录时就该用 7 天窗口，实际 " + window.days);
  }
  const hours = run("loadRows().rows[0].hours");
  if (Math.abs(hours - 8) > 0.001) {
    throw new Error("窗口内应当只有 8 小时（偏移 6 那天），实际 " + hours);
  }
});

test("洞察里的一天没超 24 小时就不报工时异常", () => {
  fresh();
  run(`window.__p = addProject({name: "P", status: "进行中"});
    window.__e = addEmployee({name: "正常人", weekly_hours: 40});
    addWorklog({employee_id: window.__e.id, project_id: window.__p.id,
      work_date: todayISO(), hours: 8, content: "正常一天"},
      {allowDuplicate: true});`);
  const problems = plain(run("worklogProblems()"));
  if (problems.length) {
    throw new Error("正常的 8 小时被报了异常：" + problems[0].text);
  }
});

test("洞察能抓出阻塞太久", () => {
  fresh();
  run(`window.__p = addProject({name: "P", status: "进行中"});
    addStep(window.__p.id, {name: "卡住的", status: "已阻塞",
      due_date: dateToISO(new Date(today().getTime() - 30 * 86400000))});`);
  const found = plain(run("insights()"));
  const hit = found.some(item => item.title.indexOf("已阻塞") !== -1);
  if (!hit) throw new Error("阻塞 30 天没被报出来");
});

test("每条洞察都带数字依据和建议", () => {
  fresh();
  /* 这个用例只验证「格式化」这一件事：所有洞察都必须带
     数字依据和建议，缺一不可（没有数字的「洞察」就是废话）。
     至于「能不能抓出某一类问题」，由各自专门的用例负责——
     混在一起写的话，一次失败分不清是抓取错了还是格式化错了。 */
  run(`window.__a = addProject({name: "低效项目", status: "进行中",
      cost: 900000, progress: 10});
    window.__b = addProject({name: "高效项目", status: "进行中",
      cost: 5000, progress: 80});
    window.__e = addEmployee({name: "忙人", weekly_hours: 40});
    addStep(window.__a.id, {name: "第一步", status: "进行中"});
    addStep(window.__a.id, {name: "第二步", status: "已完成"});
    addStep(window.__a.id, {name: "卡住的", status: "已阻塞",
      due_date: dateToISO(new Date(today().getTime() - 30 * 86400000))});`);
  const window = plain(run("worklogWindow()"));
  run(`(function () {
    var from = new Date(${JSON.stringify(window.from)} + "T00:00:00");
    var to = new Date(${JSON.stringify(window.to)} + "T00:00:00");
    for (var d = new Date(from); d <= to; d.setDate(d.getDate() + 1)) {
      addWorklog({employee_id: window.__e.id, project_id: window.__a.id,
        work_date: dateToISO(d), hours: 8,
        content: "干活 " + dateToISO(d)}, {allowDuplicate: true});
    }
  })();`);

  const found = plain(run("insights()"));
  if (!found.length) throw new Error("造了这么多问题却一条洞察都没报");
  found.forEach(item => {
    if (!item.detail || !String(item.detail).trim()) {
      throw new Error("缺数字依据：" + item.title);
    }
    if (!item.advice || !String(item.advice).trim()) {
      throw new Error("缺建议：" + item.title);
    }
    if (["compare", "conflict"].indexOf(item.group) === -1) {
      throw new Error("分组不对：" + item.group);
    }
    if (typeof item.severity !== "number") {
      throw new Error("缺严重度：" + item.title);
    }
  });
  /* 按严重度从高到低排——最该先看的排最前 */
  for (let i = 1; i < found.length; i += 1) {
    if (found[i].severity > found[i - 1].severity) {
      throw new Error("洞察没有按严重度排序："
        + found.map(item => item.severity).join(","));
    }
  }
});

/* ---- 小助手 ---- */
test("空库时每个问题都有回答", () => {
  fresh();
  const questions = plain(run("SUGGESTIONS")).concat([
    "现在什么情况", "哪个项目有风险", "谁最忙", "谁闲下来了",
    "预算要紧吗", "有多少人在岗", "哪些任务卡住了",
    "帮我看看有什么问题", "比一比", "找矛盾",
    "不存在的人", "不存在的项目", "", "今天天气怎么样",
  ]);
  questions.forEach(question => {
    const answer = run(`ask(${JSON.stringify(question)})`);
    if (typeof answer !== "string" || !answer.trim()) {
      throw new Error(`「${question}」没有回答`);
    }
  });
});

test("点名项目要给出等级和逐条依据", () => {
  fresh();
  run(`window.__p = addProject({name: "测试项目", status: "进行中",
    progress: 40, budget: 10000, cost: 9000});
    window.__e = addEmployee({name: "测试员工"});
    addWorklog({employee_id: window.__e.id, project_id: window.__p.id,
      work_date: todayISO(), hours: 8, content: "干活"}, {allowDuplicate: true});`);
  const answer = run('ask("测试项目怎么样")');
  if (answer.indexOf("测试项目") === -1) throw new Error("没提到项目名");
  if (answer.indexOf("·") === -1) throw new Error("没有逐条依据");
});

test("点名的人要给出负荷", () => {
  fresh();
  run(`window.__p = addProject({name: "P", status: "进行中"});
    window.__e = addEmployee({name: "测试员工", weekly_hours: 40});
    addWorklog({employee_id: window.__e.id, project_id: window.__p.id,
      work_date: todayISO(), hours: 8, content: "干活"}, {allowDuplicate: true});`);
  const answer = run('ask("测试员工")');
  if (answer.indexOf("测试员工") === -1) throw new Error("没提到这个人");
  if (answer.indexOf("负荷") === -1) throw new Error("没有负荷信息");
});

test("问不懂的要说明能问什么", () => {
  fresh();
  const answer = run('ask("今天天气怎么样")');
  if (answer.indexOf("没理解") === -1 && answer.indexOf("能回答") === -1) {
    throw new Error("兜底回答没说明能力边界：" + answer.slice(0, 40));
  }
});

test("动态建议不和固定列表重名，且都能被回答", () => {
  fresh();
  run(`window.__p = addProject({name: "有阻塞的", status: "进行中"});
    addStep(window.__p.id, {name: "卡住的", status: "已阻塞"});`);
  const urgent = plain(run("urgentSuggestions()"));
  const fixed = plain(run("SUGGESTIONS"));
  if (!urgent.length) throw new Error("有阻塞步骤却没给出动态建议");
  urgent.forEach(item => {
    if (fixed.indexOf(item) !== -1) {
      throw new Error(`「${item}」和固定列表重名，加了等于没加`);
    }
    const answer = run(`ask(${JSON.stringify(item)})`);
    if (answer.indexOf("我没理解") !== -1) {
      throw new Error(`「${item}」点下去得到兜底回答——死按钮`);
    }
  });
});

/* ---- 级联删除 ---- */
test("删项目要级联删掉步骤和工时", () => {
  fresh();
  run(`window.__p = addProject({name: "待删除"});
    window.__e = addEmployee({name: "临时工"});
    addStep(window.__p.id, {name: "某步骤"});
    addWorklog({employee_id: window.__e.id, project_id: window.__p.id,
      work_date: todayISO(), hours: 2, content: "x"}, {allowDuplicate: true});
    deleteProject(window.__p.id);`);
  if (run("projectSteps(window.__p.id).length") !== 0) {
    throw new Error("步骤没跟着删");
  }
  if (run("worklogsFor({project_id: window.__p.id}).length") !== 0) {
    throw new Error("工时没跟着删");
  }
});

test("删步骤不删工时，只解除关联", () => {
  fresh();
  run(`window.__p = addProject({name: "留工时"});
    window.__e = addEmployee({name: "某人"});
    window.__s = addStep(window.__p.id, {name: "要删的步骤"});
    addWorklog({employee_id: window.__e.id, project_id: window.__p.id,
      step_id: window.__s.id, work_date: todayISO(), hours: 2,
      content: "真干过"}, {allowDuplicate: true});
    deleteStep(window.__s.id);`);
  const logs = plain(run("worklogsFor({project_id: window.__p.id})"));
  if (logs.length !== 1) throw new Error("工时被误删了——那是真干过的活");
  if (logs[0].step_id !== null) throw new Error("步骤关联没解除");
});

test("删员工要删掉他的工时", () => {
  fresh();
  run(`window.__p = addProject({name: "P"});
    window.__e = addEmployee({name: "要走的人"});
    addWorklog({employee_id: window.__e.id, project_id: window.__p.id,
      work_date: todayISO(), hours: 2, content: "x"}, {allowDuplicate: true});
    deleteEmployee(window.__e.id);`);
  if (run("DB.worklogs.length") !== 0) throw new Error("工时没跟着删");
});

/* ---- 存储与导出 ---- */
test("存到 localStorage 再读回来一致", () => {
  fresh();
  run(`addProject({name: "A"}); addProject({name: "B"});
    addEmployee({name: "某人"});`);
  const before = run("DB.projects.length");
  run("saveAll();");
  run("DB = loadAll();");
  const after = run("DB.projects.length");
  if (before !== after) throw new Error(`存读不一致：${before} → ${after}`);
});

test("导出快照结构符合电脑端的期望", () => {
  fresh();
  run(`window.__p = addProject({name: "P", status: "进行中", budget: 1000,
      cost: 200, progress: 30, start_date: "2026-01-01",
      due_date: "2026-06-01", owner: "李工", client: "甲方",
      priority: "高", note: "备注"});
    window.__e = addEmployee({name: "王强", role: "后端", level: "P6",
      weekly_hours: 40});
    addStep(window.__p.id, {name: "步骤一", status: "进行中"});
    addAssessment(window.__p.id, {kind: "ability", name: "后端", score: 4,
      weight: 2});
    addMetric(window.__p.id, {metric_date: "2026-02-01", name: "到货率",
      value: 60, unit: "%"});
    addWorklog({employee_id: window.__e.id, project_id: window.__p.id,
      work_date: "2026-01-05", hours: 8, content: "干活"},
      {allowDuplicate: true});`);
  const payload = plain(run(`(function () {
    return {
      format: "ProjectRecorder.snapshot",
      version: 1,
      exported_at: nowISO(),
      employees: DB.employees,
      projects: DB.projects.map(function (p) {
        return Object.assign({}, p, {
          steps: projectSteps(p.id),
          assessments: projectAssessments(p.id),
          metrics: projectMetrics(p.id),
        });
      }),
      assignments: DB.assignments,
      worklogs: DB.worklogs.map(function (log) {
        return {
          employee: employeeName(log.employee_id),
          project: projectName(log.project_id),
          step: stepName(log.step_id),
          work_date: log.work_date,
          hours: num(log.hours),
          content: log.content || "",
          source: log.source || "manual",
          key: "",
        };
      }),
    };
  })()`));

  ["format", "version", "employees", "projects", "assignments", "worklogs"]
    .forEach(key => {
      if (payload[key] === undefined) throw new Error("快照缺少字段：" + key);
    });
  const project = payload.projects[0];
  ["name", "owner", "client", "status", "priority", "start_date", "due_date",
   "budget", "cost", "progress", "note", "steps", "assessments", "metrics"]
    .forEach(key => {
      if (project[key] === undefined) {
        throw new Error("快照的项目缺少 " + key + "（电脑端会读不到）");
      }
    });
  /* 数值必须是数字——电脑端拿它做算术，字符串会算错 */
  ["budget", "cost", "progress"].forEach(key => {
    if (typeof project[key] !== "number") {
      throw new Error(`快照的 ${key} 不是数字：${JSON.stringify(project[key])}`);
    }
  });
  payload.worklogs.forEach(log => {
    if (typeof log.hours !== "number") throw new Error("hours 不是数字");
    if (log.employee === undefined) throw new Error("工时缺少 employee");
    if (log.project === undefined) throw new Error("工时缺少 project");
  });
});

test("导出的员工工时文件符合电脑端的导入格式", () => {
  fresh();
  const payload = plain(run(`(function () {
    return {
      format: "ProjectRecorder.worklog",
      version: 1,
      employee: {name: "王强", role: "后端", level: "P6", weekly_hours: 40},
      range: {from: "2026-01-01", to: "2026-01-31"},
      entries: [{work_date: "2026-01-05", project: "P", step: "步骤一",
                 hours: 8, content: "干活", source: "manual", key: ""}],
    };
  })()`));
  /* 电脑端 read_file 会检查这几项，缺一个就导不进去 */
  if (payload.format !== "ProjectRecorder.worklog") throw new Error("format 不对");
  if (typeof payload.version !== "number") throw new Error("version 不是数字");
  if (!payload.entries.length) throw new Error("没有 entries");
  if (!payload.employee || !payload.employee.name) throw new Error("没说是谁");
  payload.entries.forEach(entry => {
    if (typeof entry.hours !== "number") throw new Error("hours 不是数字");
    if (!/^\d{4}-\d{2}-\d{2}$/.test(entry.work_date)) {
      throw new Error("日期格式不对：" + entry.work_date);
    }
  });
});

/* ---- 云同步 ---- */
test("队列去重：同一条记录改三次只上传一次", () => {
  fresh();
  /* 这是队列存在的意义之一——员工反复改同一条记录时，
     队列不能无限增长，也不该把中间状态也传上去。 */
  run(`queueChange("tasks", "update", "t1", {id: "t1", title: "第一版"});
    queueChange("tasks", "update", "t1", {id: "t1", title: "第二版"});
    queueChange("tasks", "update", "t1", {id: "t1", title: "第三版"});`);
  if (run("DB.syncQueue.length") !== 1) {
    throw new Error("应当只留一条，实际 " + run("DB.syncQueue.length"));
  }
  const payload = plain(run("DB.syncQueue[0].payload"));
  if (payload.title !== "第三版") {
    throw new Error("应当保留最后一次的内容，实际 " + payload.title);
  }
});

test("队列去重不会把不同操作混在一起", () => {
  fresh();
  /* insert 和 delete 是不同的 dedupe key，不能互相覆盖。
     否则"先建后删"会只剩一条，服务端就少了一次删除。 */
  run(`queueChange("tasks", "insert", "t1", {id: "t1"});
    queueChange("tasks", "delete", "t1", {});`);
  if (run("DB.syncQueue.length") !== 2) {
    throw new Error("insert 和 delete 应当各留一条，实际 "
      + run("DB.syncQueue.length"));
  }
});

test("队列去重不会把不同表混在一起", () => {
  fresh();
  run(`queueChange("tasks", "insert", "x1", {id: "x1"});
    queueChange("worklogs", "insert", "x1", {id: "x1"});`);
  if (run("DB.syncQueue.length") !== 2) {
    throw new Error("不同表应当各留一条，实际 " + run("DB.syncQueue.length"));
  }
});

test("云端项目与步骤会合并到本地，本机独有项目保留", () => {
  fresh();
  run(`mergeCloudProjects([{
    id: "cloud-project-1", version: 3, name: "云端项目",
    owner: "老板", client: "", status: "进行中", priority: "中",
    start_date: "2026-01-01", due_date: "2026-02-01",
    budget: 100, cost: 20, progress: 50, note: "",
    created_at: "2026-01-01T00:00:00Z",
    updated_at: "2026-01-02T00:00:00Z"
  }]);
  mergeCloudProjectSteps([{
    id: "cloud-step-1", version: 2, project_id: "cloud-project-1",
    seq: 1, name: "云端步骤", owner: "", status: "未开始",
    progress: 0, note: "", created_at: "2026-01-01T00:00:00Z",
    updated_at: "2026-01-02T00:00:00Z"
  }]);
  DB.projects.push({id: 999, name: "本机独有项目"});`);
  if (run("DB.projects.length") !== 2) {
    throw new Error("应当合并 1 个云端项目并保留 1 个本机项目");
  }
  if (run("DB.projects.filter(function (p) { return !!p.remote_id; }).length") !== 1) {
    throw new Error("云端项目没有写入 remote_id");
  }
  if (run("DB.steps.length") !== 1 || run("DB.steps[0].name") !== "云端步骤") {
    throw new Error("云端步骤没有合并到本地");
  }
  run(`mergeCloudProjects([{
    id: "cloud-project-1", version: 3, name: "云端项目",
    owner: "老板", client: "", status: "进行中", priority: "中",
    start_date: "2026-01-01", due_date: "2026-02-01",
    budget: 100, cost: 20, progress: 50, note: "",
    created_at: "2026-01-01T00:00:00Z",
    updated_at: "2026-01-02T00:00:00Z"
  }]);`);
  if (run("DB.projects.filter(function (p) { return p.remote_id === 'cloud-project-1'; }).length") !== 1) {
    throw new Error("重复拉取同一个云端项目时产生了重复记录");
  }
});

test("本机新建项目与步骤会进入待上传队列", () => {
  fresh();
  run(`DB.profile = {id: "profile-1", name: "老板"};
    DB.account_scope_id = "profile-1";
    DB.company_scope_id = "enterprise-1";
    var p = addProject({name: "本机新项目"});
    updateProject(p.id, {progress: 30});
    addStep(p.id, {name: "第一步"});`);
  if (run("DB.syncQueue.filter(function (x) { return x.table === 'projects'; }).length") !== 1) {
    throw new Error("项目应当只保留 1 条去重后的待上传记录");
  }
  if (run("DB.syncQueue.filter(function (x) { return x.table === 'project_steps'; }).length") !== 1) {
    throw new Error("步骤没有进入待上传队列");
  }
  if (run("DB.syncQueue.find(function (x) { return x.table === 'projects'; }).account_id") !== "profile-1") {
    throw new Error("项目队列没有绑定当前账号");
  }
});

test("云端工时会按项目 UUID 归到本地项目", () => {
  fresh();
  run(`DB.projects = [{id: 1, remote_id: "cloud-project-1", name: "云端项目"}];
    DB.worklogs = [];
    DB.remoteWorklogs = [{
      id: "cloud-worklog-1", project_id: "cloud-project-1",
      employee_id: "employee-1", work_date: "2026-01-02", hours: 2
    }];`);
  const rows = plain(run('worklogsFor({project_id: 1, includeRemote: true})'));
  if (rows.length !== 1 || Number(rows[0].hours) !== 2) {
    throw new Error("云端工时没有按 remote_id 归到本地项目");
  }
});

test("上传成功后只清掉成功的那些", () => {
  fresh();
  run(`queueChange("tasks", "insert", "a", {id: "a"});
    queueChange("tasks", "insert", "b", {id: "b"});
    queueChange("tasks", "insert", "c", {id: "c"});`);
  const ids = plain(run("DB.syncQueue.map(function (x) { return x.id; })"));
  run(`clearQueueItems([${ids[0]}, ${ids[2]}]);`);
  if (run("DB.syncQueue.length") !== 1) {
    throw new Error("应当剩 1 条，实际 " + run("DB.syncQueue.length"));
  }
  if (run("DB.syncQueue[0].key") !== "b") {
    throw new Error("剩下的应当是 b，实际 " + run("DB.syncQueue[0].key"));
  }
});

test("待上传数量算得对", () => {
  fresh();
  if (run("pendingCount()") !== 0) throw new Error("空库应当是 0");
  run('queueChange("tasks", "insert", "a", {});'
    + 'queueChange("tasks", "insert", "b", {});');
  if (run("pendingCount()") !== 2) throw new Error("应当是 2");
});

test("切换账号保留待上传队列但重置同步游标", () => {
  fresh();
  run(`queueChange("tasks", "insert", "a", {});
    DB.syncCursor = {tasks: "2026-01-01 00:00:00"};
    DB.lastSync = {at: "x", ok: true, pending: 5, message: "旧消息"};
    resetSyncState();`);
  if (run("DB.syncQueue.length") !== 1) {
    throw new Error("未上传队列被登录/退出流程清空了");
  }
  if (Object.keys(plain(run("DB.syncCursor"))).length !== 0) {
    throw new Error("游标没清空");
  }
  if (run("DB.lastSync.pending") !== 0) throw new Error("状态没重置");
});

test("账号数据库彼此隔离且切换后能恢复", () => {
  fresh();
  run('activateAccountDatabase("account-a");'
    + 'addProject({name: "A 的项目"}); saveAll();'
    + 'activateAccountDatabase("account-b");'
    + 'addProject({name: "B 的项目"}); saveAll();'
    + 'activateAccountDatabase("account-a");');
  if (run("DB.projects.length") !== 1
      || run("DB.projects[0].name") !== "A 的项目") {
    throw new Error("切回账号 A 后没有恢复 A 自己的数据");
  }
  if (run("DB.account_scope_id") !== "account-a") {
    throw new Error("数据库没有记录账号 scope");
  }
  run('activateAccountDatabase("account-b");');
  if (run("DB.projects.length") !== 1
      || run("DB.projects[0].name") !== "B 的项目") {
    throw new Error("账号 B 读到了账号 A 的数据");
  }
});

test("已保存账号属于设备设置，不随账号数据库切换消失", () => {
  fresh();
  const accountSource = fs.readFileSync(path.join(HERE, "account.js"), "utf8");
  new vm.Script(accountSource, { filename: "account.js" }).runInContext(ctx);
  run('rememberAccount("boss-a", "boss", "老板 A", "pass-a");'
    + 'activateAccountDatabase("other-account");'
    + 'rememberAccount("staff-b", "employee", "员工 B", "pass-b");');
  const rows = plain(run("savedAccountsList()"));
  if (rows.length !== 2 || rows[0].code !== "staff-b") {
    throw new Error("切换账号后已保存账号列表没有保留");
  }
});

test("多账号连续切换 20 次不串数据", () => {
  fresh();
  run('activateAccountDatabase("switch-a"); addProject({name:"A only"}); saveAll();'
    + 'activateAccountDatabase("switch-b"); addProject({name:"B only"}); saveAll();');
  for (let i = 0; i < 20; i += 1) {
    const account = i % 2 === 0 ? "switch-a" : "switch-b";
    const expected = account === "switch-a" ? "A only" : "B only";
    run('activateAccountDatabase(' + JSON.stringify(account) + ');');
    if (run("DB.projects.length") !== 1
        || run("DB.projects[0].name") !== expected) {
      throw new Error("第 " + (i + 1) + " 次切换账号发生数据串号");
    }
  }
});

test("旧数据必须显式归属，且旧队列不会自动激活", () => {
  fresh();
  run(`DB = emptyDatabase();
  DB.projects = [{id: 1, name: "旧项目"}];
  DB.syncQueue = [{id: 1, table: "tasks", op: "insert", key: "old"}];
  saveAll();
  activateAccountDatabase("account-owner");
  claimLegacyDataForCurrentAccount();`);
  if (run("DB.projects.length") !== 1
      || run("DB.projects[0].name") !== "旧项目") {
    throw new Error("确认归属后旧项目没有导入");
  }
  if (run("DB.syncQueue.length") !== 0) {
    throw new Error("旧队列不应自动归到新账号");
  }
  const backups = plain(run("databaseBackups()"));
  if (!backups.length) throw new Error("旧数据导入前没有留备份");
});

test("切换公司清缓存但不清账号队列", () => {
  fresh();
  run('activateAccountDatabase("account-company");'
    + 'queueChange("tasks", "insert", "pending", {id: "pending"});'
    + 'clearCompanyScopedCache();');
  if (run("pendingCount()") !== 1) {
    throw new Error("切换公司时待上传队列被清空");
  }
});

test("云服务配置：预置值可用，用户填的能覆盖", () => {
  /* 预置的意义：用户不用手填那串一百多字符的 anon key。
     这里验证三件事：
       1. 什么都不填时，能从预置值拿到配置（cloudReady 为 true）
       2. 用户填了就用用户的
       3. URL 会被规整（去掉 /rest/v1 之类的尾缀） */
  fresh();

  /* 1. 预置 */
  run('saveSyncConfig("", "");');
  const preset = plain(run("syncConfig()"));
  if (!preset.url || !preset.key) {
    throw new Error("预置配置为空，用户会被迫手填：" + JSON.stringify(preset));
  }
  if (preset.custom) throw new Error("没填过却标记成 custom");
  if (run("cloudReady()") !== true) {
    throw new Error("有预置值时 cloudReady 应当是 true");
  }

  /* 2. 用户覆盖 */
  run('saveSyncConfig("https://my-own.supabase.co/rest/v1/", "my-key");');
  const custom = plain(run("syncConfig()"));
  if (custom.url !== "https://my-own.supabase.co") {
    throw new Error("用户填的地址没被规整：" + custom.url);
  }
  if (custom.key !== "my-key") throw new Error("用户填的 key 没生效");
  if (custom.custom !== true) throw new Error("应当标记成 custom");

  /* 3. 清掉后回到预置 */
  run('saveSyncConfig("", "");');
  const back = plain(run("syncConfig()"));
  if (back.url !== preset.url) throw new Error("清空后没回到预置值");
});

test("云服务网关：用户只连接中转地址，不直连 Supabase", () => {
  fresh();
  run('window.PROJECT_RECORDER_GATEWAY_URL = "https://gateway.example.com/rest/v1/";'
    + 'saveSyncConfig("", "");');
  const gateway = plain(run("syncConfig()"));
  if (gateway.url !== "https://gateway.example.com") {
    throw new Error("网关地址没有规整或被忽略：" + gateway.url);
  }
  if (gateway.custom) throw new Error("预置网关不应标记成用户自定义");

  /* People who used the previous build may have the direct URL persisted.
     That must migrate to the gateway automatically, not silently keep
     calling the blocked Supabase domain. */
  run('saveSyncConfig("https://edchntmyqqjqvpngylgc.supabase.co", "");');
  if (plain(run("syncConfig()")).url !== "https://gateway.example.com") {
    throw new Error("旧版预置 Supabase 地址没有迁移到网关");
  }

  /* A genuinely custom backend still wins. */
  run('saveSyncConfig("https://custom.example.com", "custom-key");');
  const custom = plain(run("syncConfig()"));
  if (custom.url !== "https://custom.example.com" || custom.key !== "custom-key") {
    throw new Error("用户自定义后端被网关覆盖");
  }

  const html = fs.readFileSync(path.join(HERE, "index.html"), "utf8");
  const intake = fs.readFileSync(path.join(HERE, "intake.html"), "utf8");
  const sync = fs.readFileSync(path.join(HERE, "sync.js"), "utf8");
  const publicIntake = fs.readFileSync(path.join(HERE, "public-intake.js"), "utf8");
  const build = fs.readFileSync(path.join(HERE, "build-www.js"), "utf8");
  if (!html.includes("cloud-config.js") ||
      html.indexOf('<script src="cloud-config.js') > html.indexOf('<script src="sync.js')) {
    throw new Error("index.html 没有在 sync.js 前加载网关配置");
  }
  if (!intake.includes("cloud-config.js") ||
      intake.indexOf('<script src="cloud-config.js') > intake.indexOf('<script src="public-intake.js')) {
    throw new Error("公开表单没有在接口脚本前加载网关配置");
  }
  if (!sync.includes("PROJECT_RECORDER_GATEWAY_URL") ||
      !publicIntake.includes("PROJECT_RECORDER_GATEWAY_URL")) {
    throw new Error("应用没有使用网关地址");
  }
  if (!build.includes('"cloud-config.js"')) {
    throw new Error("APK 构建没有包含 cloud-config.js");
  }
});

test("URL 规整化能把各种粘错的形式修回来", () => {
  fresh();
  const cases = [
    ["https://x.supabase.co/rest/v1/", "https://x.supabase.co"],
    ["https://x.supabase.co/rest/v1", "https://x.supabase.co"],
    ["https://x.supabase.co/auth/v1", "https://x.supabase.co"],
    ["  https://x.supabase.co  ", "https://x.supabase.co"],
    ["https://x.supabase.co/", "https://x.supabase.co"],
    ["x.supabase.co", "https://x.supabase.co"],
    ["", ""],
  ];
  cases.forEach(([input, expected]) => {
    const got = run(`normalizeCloudUrl(${JSON.stringify(input)})`);
    if (got !== expected) {
      throw new Error(`「${input}」应当规整成「${expected}」，实际「${got}」`);
    }
  });
  /* 带端口的也要保留 */
  const withPort = run('normalizeCloudUrl("http://localhost:8000/rest/v1")');
  if (withPort !== "http://localhost:8000") {
    throw new Error("带端口的地址没保留端口：" + withPort);
  }
});

test("pullAll 返回的是对象，且带通知需要的两样东西", () => {
  /* **这条来自一次改动风险。**

     pullAll 原来返回一个数字（"变了多少条"）。加通知之后改成
     `{ changed, events, newWorklogs }`，因为通知模块要新事件和新工时。

     如果谁改回返回数字，syncNow 里的 `pulled.changed` 会变成
     undefined，界面上只是"收到 0 条新数据"——**看不出坏了**。
     所以这里把形状钉住。

     用源码检查而不是真调函数：pullAll 是 async 且依赖网络，
     在这套同步测试沙箱里跑不出有意义的返回值。 */
  const source = fs.readFileSync(path.join(HERE, "sync.js"), "utf8");
  const start = source.indexOf("async function pullAll()");
  if (start === -1) throw new Error("找不到 pullAll");
  /* 取到下一个顶层函数定义为止 */
  const rest = source.slice(start + 10);
  const nextFn = rest.indexOf("\nasync function ");
  const body = nextFn === -1 ? rest : rest.slice(0, nextFn);

  /* 每一条 return 都必须返回对象。
     `return empty;` 也合法（empty 是对象），所以只拒绝
     明显不是对象的形状：数字、字符串、布尔。 */
  const returns = body.match(/return [^;]+;/g) || [];
  if (!returns.length) throw new Error("pullAll 里没有 return");
  returns.forEach(line => {
    const value = line.replace(/^return\s+/, "").replace(/;$/, "").trim();
    if (/^\d+$/.test(value) || /^["']/.test(value)
        || value === "true" || value === "false") {
      throw new Error("pullAll 返回了非对象（通知模块会拿到 undefined）："
        + line.trim());
    }
  });
  if (!/empty = \{ changed: 0, events: \[\], newWorklogs: \[\] \}/.test(body)) {
    throw new Error("早退值 empty 的形状不对（通知模块会拿到 undefined）");
  }
  if (!/return \{ changed: changed, events: events, newWorklogs: newWorklogs \}/.test(body)) {
    throw new Error("末尾的 return 缺字段");
  }
});

test("没登录时 syncNow 直接返回，不发请求", () => {
  fresh();
  run('saveSyncConfig("https://example.supabase.co", "fake-key");'
    + "DB.profile = null;");
  /* 没有 supabase 库、没有 profile，syncNow 应当立刻返回而不是抛错 */
  const status = plain(run("syncStatus()"));
  if (status.signedIn !== false) throw new Error("应当标记为未登录");
});

test("登录名到邮箱的转换是稳定的", () => {
  fresh();
  /* 老板建账号时和员工登录时必须算出同一个邮箱，
     否则会出现"账号明明建了但登不上"。 */
  const cases = [
    ["13800138000", false, "13800138000@boss.pr"],
    ["A001", true, "a001@staff.pr"],
    ["  A001  ", true, "a001@staff.pr"],
    ["zhang.san", true, "zhang.san@staff.pr"],
    ["wang_li-2", true, "wang_li-2@staff.pr"],
  ];
  cases.forEach(([code, isStaff, expected]) => {
    const got = run(`loginCodeToEmail(${JSON.stringify(code)}, ${isStaff})`);
    if (got !== expected) {
      throw new Error(`「${code}」应当转成 ${expected}，实际 ${got}`);
    }
  });
  /* 中文会被过滤掉——如果工号里有中文，转换后会变成空串，
     那是个"建号成功但登不上"的坑，所以必须能看出来 */
  const chinese = run('loginCodeToEmail("张三", true)');
  if (chinese !== "@staff.pr") {
    throw new Error("中文工号的处理方式变了，实际 " + chinese);
  }
});

test("英文报错会翻译成能看懂的中文", () => {
  fresh();
  const cases = [
    ["Invalid login credentials", "账号或密码不对"],
    ["Email not confirmed", "确认邮箱"],
    ["User already registered", "已经被占用"],
    ["Failed to fetch", "连不上服务器"],
  ];
  cases.forEach(([raw, expectContains]) => {
    const got = run(`translateAuthError(${JSON.stringify(raw)})`);
    if (got.indexOf(expectContains) === -1) {
      throw new Error(`「${raw}」应当译成含「${expectContains}」的说明，实际：${got}`);
    }
  });
  /* 认不出的错误要原样返回，不能吞掉——否则排查时没有线索 */
  const unknown = run('translateAuthError("Some weird thing")');
  if (unknown !== "Some weird thing") throw new Error("未知错误应当原样返回");
});

test("老板注册的网络失败必须给出可操作提示", () => {
  fresh();
  for (const raw of ["TypeError: Failed to fetch", "NetworkError", "Load failed"]) {
    const got = run(`translateBossError(${JSON.stringify(raw)})`);
    if (got.indexOf("手机连不上云服务器") === -1
        || got.indexOf("Wi-Fi") === -1
        || got.indexOf("supabase.co") === -1) {
      throw new Error(`注册网络错误没有给出可操作说明：${got}`);
    }
  }
});

test("本机 uuid 生成不重复且格式正确", () => {
  fresh();
  const ids = [];
  for (let i = 0; i < 40; i += 1) ids.push(run("uuid()"));
  const unique = ids.filter((id, index) => ids.indexOf(id) === index);
  if (unique.length !== ids.length) {
    throw new Error("生成了重复的 id，任务会互相覆盖");
  }
  /* 测试沙盒里 crypto.randomUUID 存在，所以走那条路径；
     这里只验证"是个非空字符串" */
  ids.forEach(id => {
    if (typeof id !== "string" || !id.length) {
      throw new Error("生成了空的 id：" + id);
    }
  });
});

test("老数据库升级后同步字段都在", () => {
  /* 兼容性：用户手机上已有一份不含同步字段的数据 */
  fresh();
  const result = plain(run(`(function () {
    var old = emptyDatabase();
    delete old.tasks; delete old.taskLogs; delete old.remoteWorklogs;
    delete old.staffAccounts; delete old.syncQueue;
    delete old.syncCursor; delete old.lastSync; delete old.profile;
    delete old.seq.sync;
    var moved = migrate(old);
    return {
      tasks: Array.isArray(moved.tasks),
      taskLogs: Array.isArray(moved.taskLogs),
      remote: Array.isArray(moved.remoteWorklogs),
      staff: Array.isArray(moved.staffAccounts),
      queue: Array.isArray(moved.syncQueue),
      cursorIsObject: moved.syncCursor !== null
        && typeof moved.syncCursor === "object"
        && !Array.isArray(moved.syncCursor),
      lastSyncIsObject: moved.lastSync !== null
        && typeof moved.lastSync === "object",
      profile: moved.profile,
      seqSync: typeof moved.seq.sync
    };
  })()`));
  ["tasks", "taskLogs", "remote", "staff", "queue"].forEach(key => {
    if (!result[key]) throw new Error(key + " 没补成数组");
  });
  if (!result.cursorIsObject) {
    throw new Error("syncCursor 没补成对象——补成数组的话游标会静默失效");
  }
  if (!result.lastSyncIsObject) throw new Error("lastSync 没补成对象");
  if (result.profile !== null) throw new Error("profile 应当是 null");
  if (result.seqSync !== "number") {
    throw new Error("seq.sync 没补成数字，入队会算出 NaN id");
  }
});

test("工时汇总既包含本地也包含员工报的", () => {
  fresh();
  run(`window.__p = addProject({name: "P"});
    window.__e = addEmployee({name: "我"});
    addWorklog({employee_id: window.__e.id, project_id: window.__p.id,
      work_date: todayISO(), hours: 4, content: "自己记的"},
      {allowDuplicate: true});
    DB.remoteWorklogs.push({id: "r1", employee_id: "uuid-1",
      work_date: todayISO(), hours: 6, content: "员工报的",
      project_name: "P", source: "task"});`);
  const all = plain(run("allWorklogs()"));
  if (all.length !== 2) throw new Error("应当是 2 条，实际 " + all.length);
  /* num 是沙箱里的函数，测试脚本里用不了，所以在沙箱里算 */
  const total = run(`allWorklogs().reduce(function (sum, item) {`
    + ` return sum + num(item.hours); }, 0)`);
  if (Math.abs(total - 10) > 0.001) {
    throw new Error("合计应当是 10 小时，实际 " + total);
  }
  /* 要能区分来源，否则界面上没法标注"这是员工报的" */
  const sources = all.map(item => item.__source).sort();
  if (sources.join(",") !== "cloud,local") {
    throw new Error("来源标记不对：" + sources.join(","));
  }
});

test("同步流程先迁移本地工时再上传维度", () => {
  const source = fs.readFileSync(path.join(HERE, "sync.js"), "utf8");
  const migrate = source.indexOf(
    "const migrationsPushed = await pushWorklogMigrationQueue();");
  const dimensions = source.indexOf(
    "const dimensionsPushed = await pushDimensionQueue();");
  if (migrate < 0 || dimensions < 0 || migrate > dimensions) {
    throw new Error("工时迁移必须先于维度上传");
  }
  if (source.indexOf("pendingMigrations") < 0) {
    throw new Error("等待迁移的工时不能被维度上传误判为失败");
  }
});

test("迁移后的本地工时和云端回流不会重复计数", () => {
  fresh();
  run(`window.__e = addEmployee({name: "我"});
    window.__w = addWorklog({employee_id: window.__e.id,
      work_date: "2026-01-05", hours: 3, content: "迁移工时"});
    DB.worklogs[0].cloud_id =
      "dddddddd-dddd-4ddd-8ddd-dddddddddddd";
    mergeRemoteWorklogs([{id: DB.worklogs[0].cloud_id,
      employee_id: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
      work_date: "2026-01-05", hours: 3, content: "迁移工时",
      project_name: "", source: "manual", approval_status: "pending"}]);`);
  if (run("DB.remoteWorklogs.length") !== 0) {
    throw new Error("云端回流被重复放入 remoteWorklogs");
  }
  if (run("allWorklogs().length") !== 1) {
    throw new Error("迁移工时被统计了两遍");
  }
});

test("员工报的工时会计进负荷统计", () => {
  fresh();
  /* 这条是关键：老板手机上自己没记工时，但员工报了，
     负荷图必须显示出来，否则老板以为没人干活。 */
  run(`window.__e = addEmployee({name: "员工甲", weekly_hours: 40});
    DB.remoteWorklogs.push({id: "r1", employee_id: window.__e.id,
      work_date: todayISO(), hours: 8, content: "干活",
      source: "task"});`);
  const rows = plain(run("loadRows().rows"));
  if (rows.length !== 1) throw new Error("应当有 1 个员工");
  if (Math.abs(rows[0].hours - 8) > 0.001) {
    throw new Error("员工的 8 小时没算进去，实际 " + rows[0].hours);
  }
});

test("员工报的工时会被工时异常检查看到", () => {
  fresh();
  run(`window.__e = addEmployee({name: "员工甲"});
    DB.remoteWorklogs.push({id: "r1", employee_id: window.__e.id,
      work_date: todayISO(), hours: 20, content: "A", source: "task"});
    DB.remoteWorklogs.push({id: "r2", employee_id: window.__e.id,
      work_date: todayISO(), hours: 20, content: "B", source: "task"});`);
  const problems = plain(run("worklogProblems()"));
  if (!problems.length) {
    throw new Error("一天 40 小时没被查出来——说明远程工时没进统计");
  }
});

/* ---- 习惯 ---- */
test("新建习惯并校验参数", () => {
  fresh();
  run('window.__h = addHabit({name: "每天走 8000 步", kind: "quantity", '
    + 'target: 8000, unit: "步"});');
  if (run("DB.habits.length") !== 1) throw new Error("没进库");
  if (run("window.__h.kind") !== "quantity") throw new Error("类型不对");

  let caught = false;
  try { run('addHabit({name: ""});'); } catch (error) { caught = true; }
  if (!caught) throw new Error("空名字没被拦住");

  caught = false;
  try {
    run('addHabit({name: "跑步", kind: "quantity", target: 0});');
  } catch (error) { caught = true; }
  if (!caught) throw new Error("计量型目标为 0 没被拦住");
});

test("周期判断：空 weekdays 表示每天", () => {
  fresh();
  run('window.__h = addHabit({name: "每天"});');
  for (let day = 0; day < 7; day += 1) {
    const ok = run(`habitDueOn(window.__h, dateToISO(new Date(today().getTime()`
      + ` - ${day} * 86400000)))`);
    if (!ok) throw new Error(`第 ${day} 天应当是每天都要做`);
  }
});

test("周期判断：只在指定星期", () => {
  fresh();
  /* 存 "1 3 5" = 周一三五 */
  run('window.__h = addHabit({name: "复盘", weekdays: "1 3 5"});');
  let hitAny = false;
  for (let day = 0; day < 7; day += 1) {
    const date = run(`dateToISO(new Date(today().getTime() - ${day} * 86400000))`);
    const due = run(`habitDueOn(window.__h, ${JSON.stringify(date)})`);
    const weekday = run(`weekdayOf(${JSON.stringify(date)})`);
    const should = [1, 3, 5].indexOf(weekday) !== -1;
    if (due !== should) {
      throw new Error(`${date}（周${weekday}）应当是 ${should}，实际 ${due}`);
    }
    if (due) hitAny = true;
  }
  if (!hitAny) throw new Error("7 天里一次都没轮到，说明星期判断失效了");
});

test("停用的习惯不出现在今日列表", () => {
  fresh();
  run('window.__a = addHabit({name: "在用"});'
    + 'window.__b = addHabit({name: "停用"});'
    + 'updateHabit(window.__b.id, {active: 0});');
  const names = plain(run("todayHabitRows().map(function (r) {"
    + " return r.habit.name; })"));
  if (names.indexOf("在用") === -1) throw new Error("在用的习惯没出现");
  if (names.indexOf("停用") !== -1) throw new Error("停用的习惯应当不出现");
});

test("打卡后 toggle 能取消，再点又能打上", () => {
  fresh();
  run('window.__h = addHabit({name: "晨会"});');
  if (run("toggleHabit(window.__h.id)") !== true) {
    throw new Error("第一次应当打卡成功");
  }
  if (run("DB.habitLogs.length") !== 1) throw new Error("记录没写进去");
  if (run("toggleHabit(window.__h.id)") !== false) {
    throw new Error("第二次应当取消");
  }
  if (run("DB.habitLogs.length") !== 0) throw new Error("取消后记录没删掉");
});

test("同一天重复打卡不会产生多条记录", () => {
  fresh();
  run('window.__h = addHabit({name: "读书", kind: "quantity", '
    + 'target: 30, unit: "分钟"});'
    + 'checkHabit(window.__h.id, 20);'
    + 'checkHabit(window.__h.id, 35);');
  if (run("DB.habitLogs.length") !== 1) {
    throw new Error("同一天应当只有一条记录，实际 " + run("DB.habitLogs.length"));
  }
  if (run("num(DB.habitLogs[0].value)") !== 35) {
    throw new Error("第二次打卡应当覆盖第一次的数值");
  }
});

test("计量型要够到目标才算完成", () => {
  fresh();
  run('window.__h = addHabit({name: "跑步", kind: "quantity", '
    + 'target: 30, unit: "分钟"});');
  run("checkHabit(window.__h.id, 10);");
  if (run("todayHabitRows()[0].done") !== false) {
    throw new Error("只跑了 10 分钟，目标 30，不该算完成");
  }
  run("checkHabit(window.__h.id, 30);");
  if (run("todayHabitRows()[0].done") !== true) {
    throw new Error("够了 30 分钟，应当算完成");
  }
});

test("打勾型记了就算完成", () => {
  fresh();
  run('window.__h = addHabit({name: "晨会"});'
    + "checkHabit(window.__h.id);");
  if (run("todayHabitRows()[0].done") !== true) throw new Error("应当算完成");
});

test("连续天数：连打三天算 3", () => {
  fresh();
  run(`window.__h = addHabit({name: "每天"});
    DB.habitLogs.push({id: 1, habit_id: window.__h.id, log_date: todayISO(),
      value: 1, note: "", done_at: ""});
    DB.habitLogs.push({id: 2, habit_id: window.__h.id,
      log_date: dateToISO(new Date(today().getTime() - 86400000)),
      value: 1, note: "", done_at: ""});
    DB.habitLogs.push({id: 3, habit_id: window.__h.id,
      log_date: dateToISO(new Date(today().getTime() - 2 * 86400000)),
      value: 1, note: "", done_at: ""});`);
  const streak = run("habitStreak(window.__h.id)");
  if (streak !== 3) throw new Error("应当是连续 3 天，实际 " + streak);
});

test("连续天数：断一天就归零重算", () => {
  fresh();
  run(`window.__h = addHabit({name: "每天"});
    DB.habitLogs.push({id: 1, habit_id: window.__h.id, log_date: todayISO(),
      value: 1, note: "", done_at: ""});
    DB.habitLogs.push({id: 2, habit_id: window.__h.id,
      log_date: dateToISO(new Date(today().getTime() - 2 * 86400000)),
      value: 1, note: "", done_at: ""});
    DB.habitLogs.push({id: 3, habit_id: window.__h.id,
      log_date: dateToISO(new Date(today().getTime() - 3 * 86400000)),
      value: 1, note: "", done_at: ""});`);
  const streak = run("habitStreak(window.__h.id)");
  if (streak !== 1) {
    throw new Error("昨天断了，连续天数应当只有今天 1 天，实际 " + streak);
  }
});

test("连续天数：今天还没打不算断", () => {
  fresh();
  /* 这是刻意的宽容——早上一打开就显示"连续 0 天"会让人直接放弃 */
  run(`window.__h = addHabit({name: "每天"});
    DB.habitLogs.push({id: 1, habit_id: window.__h.id,
      log_date: dateToISO(new Date(today().getTime() - 86400000)),
      value: 1, note: "", done_at: ""});
    DB.habitLogs.push({id: 2, habit_id: window.__h.id,
      log_date: dateToISO(new Date(today().getTime() - 2 * 86400000)),
      value: 1, note: "", done_at: ""});`);
  const streak = run("habitStreak(window.__h.id)");
  if (streak !== 2) {
    throw new Error("今天没打但昨天前天打了，应当连续 2 天，实际 " + streak);
  }
});

test("连续天数很久没打时返回 0（不会死循环）", () => {
  fresh();
  run('window.__h = addHabit({name: "每天"});'
    + 'DB.habitLogs.push({id: 1, habit_id: window.__h.id, '
    + 'log_date: "2000-01-01", value: 1, note: "", done_at: ""});');
  /* 上界 365 天，必须能返回 */
  const streak = run("habitStreak(window.__h.id)");
  if (streak !== 0) throw new Error("很久没打应当是 0，实际 " + streak);
});

test("完成率算得对", () => {
  fresh();
  run(`window.__h = addHabit({name: "每天"});
    DB.habitLogs.push({id: 1, habit_id: window.__h.id, log_date: todayISO(),
      value: 1, note: "", done_at: ""});`);
  const result = plain(run("habitRate(window.__h.id, 10)"));
  if (result.due !== 10) throw new Error("10 天应当都要做，实际 " + result.due);
  if (result.done !== 1) throw new Error("只打了 1 天，实际 " + result.done);
  if (Math.abs(result.rate - 0.1) > 0.001) {
    throw new Error("完成率应当是 10%，实际 " + result.rate);
  }
});

test("完成率只统计该做的日子", () => {
  fresh();
  /* 只在周一做。任意连续 14 天里，每个星期几都正好出现 2 次 */
  run('window.__h = addHabit({name: "周一复盘", weekdays: "1"});');
  const result = plain(run("habitRate(window.__h.id, 14)"));
  if (result.due !== 2) {
    throw new Error("14 天里周一应当出现 2 次，实际 " + result.due);
  }
});

test("删习惯要把打卡记录一起删掉", () => {
  fresh();
  run('window.__h = addHabit({name: "要删的"});'
    + "checkHabit(window.__h.id);"
    + "deleteHabit(window.__h.id);");
  if (run("DB.habits.length") !== 0) throw new Error("习惯没删掉");
  if (run("DB.habitLogs.length") !== 0) {
    throw new Error("打卡记录成了孤儿数据，应当一起删");
  }
});

test("老数据库能平滑升级（自动补出习惯字段）", () => {
  /* 关键兼容性测试：用户手机上已经有一份不含 habits 的数据，
     升级后不能崩。migrate() 必须补出空数组和自增计数器。 */
  fresh();
  const migrated = plain(run(`(function () {
    var old = emptyDatabase();
    delete old.habits;
    delete old.habitLogs;
    delete old.seq.habit;
    delete old.seq.habitLog;
    var moved = migrate(old);
    return {
      habitsIsArray: Array.isArray(moved.habits),
      logsIsArray: Array.isArray(moved.habitLogs),
      seqHabit: typeof moved.seq.habit,
      seqLog: typeof moved.seq.habitLog
    };
  })()`));
  if (!migrated.habitsIsArray) throw new Error("habits 没补成数组");
  if (!migrated.logsIsArray) throw new Error("habitLogs 没补成数组");
  if (migrated.seqHabit !== "number") {
    throw new Error("seq.habit 没补成数字，新建习惯会算出 NaN 的 id");
  }
  if (migrated.seqLog !== "number") {
    throw new Error("seq.habitLog 没补成数字");
  }
});

test("升级后能正常新建习惯（id 不会算出 NaN）", () => {
  /* 上面那条只检查了类型，这里真的走一遍新建流程 */
  fresh();
  run(`(function () {
    var old = emptyDatabase();
    delete old.habits; delete old.habitLogs;
    delete old.seq.habit; delete old.seq.habitLog;
    DB = migrate(old);
  })();`);
  run('window.__h = addHabit({name: "升级后新建的"});');
  const id = run("window.__h.id");
  if (!isFinite(id) || id <= 0) throw new Error("id 不合法：" + id);
  run("checkHabit(window.__h.id);");
  if (run("DB.habitLogs.length") !== 1) throw new Error("打卡记录没写进去");
});

/* ---- 通知 ---- */
test("通知：加一条能存下来，并成为未读", () => {
  fresh();
  run('addNotification({key: "k1", kind: "done", title: "有任务完成了",'
    + ' body: "把接口补上（2 小时）"});');
  if (run("notifications().length") !== 1) throw new Error("没存进去");
  if (run("unreadCount()") !== 1) throw new Error("应当是 1 条未读");
  if (run("notifications()[0].read") !== false) {
    throw new Error("新通知应当是未读");
  }
});

test("通知：同一个 key 不会重复加", () => {
  /* **这条是通知功能最容易出的 bug**：
     每次同步都会拉到同一批事件，没有去重的话
     用户会每隔 30 秒被提醒一遍同一件事。 */
  fresh();
  run('addNotification({key: "ev:abc", kind: "done", title: "完成", body: "x"});');
  run('addNotification({key: "ev:abc", kind: "done", title: "完成", body: "x"});');
  run('addNotification({key: "ev:abc", kind: "done", title: "完成", body: "x"});');
  if (run("notifications().length") !== 1) {
    throw new Error("同一个 key 重复加进去了，实际 "
      + run("notifications().length") + " 条");
  }
});

test("通知：新的排在最前面", () => {
  fresh();
  run('addNotification({key: "a", kind: "done", title: "第一条", body: ""});');
  run('addNotification({key: "b", kind: "done", title: "第二条", body: ""});');
  if (run("notifications()[0].title") !== "第二条") {
    throw new Error("最新的应当排最前，实际 " + run("notifications()[0].title"));
  }
});

test("通知：条数有上限，不会把存储撑爆", () => {
  /* localStorage 满了会导致**整个数据库存不进去**，
     所以通知必须有上限。 */
  fresh();
  run(`for (var i = 0; i < 260; i++) {
    addNotification({key: "n" + i, kind: "done", title: "第" + i, body: ""});
  }`);
  const count = run("notifications().length");
  if (count > 200) throw new Error("超过上限了：" + count);
  /* 留下的是最新的那批 */
  if (run("notifications()[0].title") !== "第259") {
    throw new Error("丢的应当是最旧的，实际最前面是 "
      + run("notifications()[0].title"));
  }
});

test("通知：标已读之后未读数归零", () => {
  fresh();
  run('addNotification({key: "a", kind: "done", title: "x", body: ""});'
    + 'addNotification({key: "b", kind: "assigned", title: "y", body: ""});');
  if (run("unreadCount()") !== 2) throw new Error("应当是 2 条未读");
  run("markNotificationsRead();");
  if (run("unreadCount()") !== 0) throw new Error("标记后应该没有未读");
  if (run("notifications().length") !== 2) {
    throw new Error("标已读不该删掉通知");
  }
});

test("通知：清空能清干净", () => {
  fresh();
  run('addNotification({key: "a", kind: "done", title: "x", body: ""});'
    + 'clearNotifications();');
  if (run("notifications().length") !== 0) throw new Error("没清干净");
  if (run("unreadCount()") !== 0) throw new Error("未读数没归零");
});

test("通知：服务端事件按身份筛选", () => {
  /* 员工只关心"老板派了新活"；老板只关心"员工干了什么"。
     不筛的话两边都会收到跟自己无关的提醒。 */
  fresh();
  const events = [
    { id: "e1", kind: "assigned", title: "写接口", task_id: "t1",
      created_at: "2026-10-10 10:00:00" },
    { id: "e2", kind: "done", title: "写接口", hours: 2,
      task_id: "t1", created_at: "2026-10-10 11:00:00" },
  ];
  run("window.__ev = " + JSON.stringify(events) + ";");

  /* 员工视角：只该收到 assigned */
  run('ingestEvents(window.__ev, "employee");');
  if (run("notifications().length") !== 1) {
    throw new Error("员工应当只收到 1 条，实际 " + run("notifications().length"));
  }
  if (run("notifications()[0].kind") !== "assigned") {
    throw new Error("员工收到的应当是 assigned，实际 "
      + run("notifications()[0].kind"));
  }

  /* 老板视角：只该收到 done */
  fresh();
  run("window.__ev = " + JSON.stringify(events) + ";");
  run('ingestEvents(window.__ev, "boss");');
  if (run("notifications().length") !== 1) {
    throw new Error("老板应当只收到 1 条，实际 " + run("notifications().length"));
  }
  if (run("notifications()[0].kind") !== "done") {
    throw new Error("老板收到的应当是 done，实际 "
      + run("notifications()[0].kind"));
  }
});

test("通知：同一批事件处理两遍只产生一批通知", () => {
  /* **模拟真实的重复同步**：网络重试、手动点立即同步、
     30 秒轮询撞在一起，同一批事件可能被处理多次。 */
  fresh();
  const events = [{ id: "e9", kind: "assigned", title: "画图",
                    task_id: "t9", created_at: "2026-10-10 09:00:00" }];
  run("window.__ev = " + JSON.stringify(events) + ";");
  run('ingestEvents(window.__ev, "employee");');
  run('ingestEvents(window.__ev, "employee");');
  run('ingestEvents(window.__ev, "employee");');
  if (run("notifications().length") !== 1) {
    throw new Error("同一批事件处理三遍产生了 "
      + run("notifications().length") + " 条通知");
  }
});

test("通知：关掉某一类开关，那类就不再产生通知", () => {
  fresh();
  run('saveNotifyPrefs({onTaskAssigned: false});');
  run('ingestEvents([{id: "e1", kind: "assigned", title: "x", task_id: "t1",'
    + ' created_at: "2026-10-10 10:00:00"}], "employee");');
  if (run("notifications().length") !== 0) {
    throw new Error("开关关掉了还是产生了通知");
  }
  run('saveNotifyPrefs({onTaskAssigned: true});');
  run('ingestEvents([{id: "e2", kind: "assigned", title: "x", task_id: "t2",'
    + ' created_at: "2026-10-10 10:01:00"}], "employee");');
  if (run("notifications().length") !== 1) {
    throw new Error("开关打开后应当产生通知");
  }
});

test("通知：总开关关掉后所有类型都不发", () => {
  fresh();
  run('saveNotifyPrefs({enabled: false});');
  run('ingestEvents([{id: "e1", kind: "assigned", title: "x", task_id: "t1",'
    + ' created_at: "2026-10-10 10:00:00"}], "employee");');
  if (run("notifications().length") !== 0) {
    throw new Error("总开关关了还发通知");
  }
  if (run("notifyEnabled(\"done\")") !== false) {
    throw new Error("总开关关了，notifyEnabled 应当返回 false");
  }
});

test("通知：工时汇总按天合并成一条，不是逐条提醒", () => {
  /* 老板一次同步可能拉到好几条工时。逐条提醒会刷屏。 */
  fresh();
  run('DB.employees.push({id: 1, name: "张三"});'
    + 'DB.employees.push({id: 2, name: "李四"});');
  const today = new Date();
  const pad = n => String(n).padStart(2, "0");
  const date = today.getFullYear() + "-" + pad(today.getMonth() + 1)
    + "-" + pad(today.getDate());
  const rows = [
    { id: "w1", employee_id: 1, work_date: date, hours: 3 },
    { id: "w2", employee_id: 1, work_date: date, hours: 2 },
    { id: "w3", employee_id: 2, work_date: date, hours: 4 },
  ];
  run("window.__rows = " + JSON.stringify(rows) + ";");
  run("ingestWorklogSummary(window.__rows);");
  if (run("notifications().length") !== 1) {
    throw new Error("三条工时应当合成一条，实际 "
      + run("notifications().length") + " 条");
  }
  const note = plain(run("notifications()[0]"));
  if (note.title.indexOf("3 条") === -1) {
    throw new Error("标题里应当有 3 条，实际：" + note.title);
  }
  if (note.body.indexOf("9") === -1) {
    throw new Error("正文里应当有合计 9 小时，实际：" + note.body);
  }
  /* 两位员工的名字都该出现 */
  if (note.body.indexOf("张三") === -1 || note.body.indexOf("李四") === -1) {
    throw new Error("应当列出员工名字，实际：" + note.body);
  }
});

test("通知：工时汇总不重复提醒同一批数字", () => {
  fresh();
  const today = new Date();
  const pad = n => String(n).padStart(2, "0");
  const date = today.getFullYear() + "-" + pad(today.getMonth() + 1)
    + "-" + pad(today.getDate());
  const rows = [{ id: "w1", employee_id: 1, work_date: date, hours: 3 }];
  run("window.__rows = " + JSON.stringify(rows) + ";");
  run("ingestWorklogSummary(window.__rows);");
  run("ingestWorklogSummary(window.__rows);");
  if (run("notifications().length") !== 1) {
    throw new Error("同一批工时提醒了两遍");
  }
});

test("通知：昨天和前天的工时不进今天的汇总", () => {
  fresh();
  run("ingestWorklogSummary([{id: \"w1\", employee_id: 1,"
    + " work_date: \"2000-01-01\", hours: 5}]);");
  if (run("notifications().length") !== 0) {
    throw new Error("旧工时不该出现在今天的汇总里");
  }
});

test("通知：事件缺字段不会崩", () => {
  /* 服务端可能返回一些奇怪的形状（字段名改了、手动插的数据）。
     通知是次要功能，**不该因为它把整个同步搞崩**。 */
  fresh();
  run('ingestEvents([{}, {kind: "unknown"}, {kind: "done"}], "boss");');
  run("ingestWorklogSummary([{}, null]);");
  run("ingestWorklogSummary(null);");
  run("ingestEvents(null, \"boss\");");
  /* 没崩就算过 */
});

test("通知：项目状态只在启动/完成时提醒", () => {
  /* **状态值必须用 app.js 项目下拉里的真实取值。**

     这条测试原来用的是 "planning"/"active"/"done"（英文），
     而真实取值是中文——**测试和代码犯的是同一个错**，
     所以它一直是"通过"的，功能却从来没生效过。

     现在用真实取值，而且顺带检查 notify.js 里的常量
     和 app.js 的下拉选项**保持一致**（不一致就是这类 bug 的根）。 */
  fresh();
  /* 先确认常量本身对得上真实取值 */
  const allowed = plain(run("PROJECT_NOTIFY_STATUS"));
  if (allowed.indexOf("进行中") === -1 || allowed.indexOf("已交付") === -1) {
    throw new Error("PROJECT_NOTIFY_STATUS 和真实状态值对不上："
      + JSON.stringify(allowed));
  }

  run('DB.projects.push({id: 1, name: "智慧园区", status: "规划中"});');
  /* 第一次跑只记快照，不提醒——否则一装 App 就把现有项目全提醒一遍 */
  run("ingestProjectStatus();");
  if (run("notifications().length") !== 0) {
    throw new Error("第一次不该提醒，实际 " + run("notifications().length"));
  }
  /* 改成进行中 → 提醒 */
  run('DB.projects[0].status = "进行中";');
  run("ingestProjectStatus();");
  if (run("notifications().length") !== 1) {
    throw new Error("改成进行中应当提醒，实际 "
      + run("notifications().length"));
  }
  /* 再跑一次不该重复提醒 */
  run("ingestProjectStatus();");
  if (run("notifications().length") !== 1) {
    throw new Error("状态没变却又提醒了");
  }
  /* 改成已交付 → 再提醒一条 */
  run('DB.projects[0].status = "已交付";');
  run("ingestProjectStatus();");
  if (run("notifications().length") !== 2) {
    throw new Error("改成已交付应当再提醒一条，实际 "
      + run("notifications().length"));
  }
  /* 暂停 / 取消不该提醒 */
  run('DB.projects[0].status = "已暂停";');
  run("ingestProjectStatus();");
  run('DB.projects[0].status = "已取消";');
  run("ingestProjectStatus();");
  if (run("notifications().length") !== 2) {
    throw new Error("暂停/取消不该提醒，现在 "
      + run("notifications().length") + " 条");
  }
});

test("通知：项目状态常量必须和 app.js 的下拉选项一致", () => {
  /* **这条防的正是我刚犯的错。**

     notify.js 里的状态值如果和 app.js 实际写入的不一致，
     条件永远不成立，通知静默失效。所以直接读 app.js 的下拉选项
     来对照，而不是各自写一份。

     （两边都写中文字面量的话，一方改了另一方不知道。） */
  const appSource = fs.readFileSync(path.join(HERE, "app.js"), "utf8");
  const match = appSource.match(
    /\[\s*"规划中"\s*,\s*"进行中"\s*,\s*"已暂停"\s*,\s*"已交付"\s*,\s*"已取消"\s*\]/);
  if (!match) {
    throw new Error("app.js 里的项目下拉选项变了，"
      + "notify.js 的 PROJECT_STATUS 要跟着更新");
  }
  const statuses = plain(run("Object.keys(PROJECT_STATUS)"
    + ".map(function (k) { return PROJECT_STATUS[k]; })"));
  const expected = ["规划中", "进行中", "已暂停", "已交付", "已取消"];
  expected.forEach(name => {
    if (statuses.indexOf(name) === -1) {
      throw new Error("PROJECT_STATUS 缺少 " + name
        + "（app.js 里有，notify.js 里没有）");
    }
  });
});

test("通知：升级老数据库后通知字段都在", () => {
  fresh();
  /* 模拟老版本的数据：完全没有通知字段 */
  run(`var old = emptyDatabase();
    delete old.notifications;
    delete old.notifyCursor;
    delete old.notifyPrefs;
    var upgraded = migrate(old);`);
  if (run("Array.isArray(upgraded.notifications)") !== true) {
    throw new Error("notifications 没补成数组");
  }
  if (run("typeof upgraded.notifyCursor") !== "object"
      || run("Array.isArray(upgraded.notifyCursor)") === true) {
    throw new Error("notifyCursor 没补成对象");
  }
  /* 通知开关要**逐项**补默认值，不能整个替换 */
  if (run("upgraded.notifyPrefs.enabled") !== true) {
    throw new Error("默认应当是开启");
  }
  if (run("upgraded.notifyPrefs.onTaskDone") !== true) {
    throw new Error("完成任务的开关默认应当是开启");
  }
});

test("通知：开关只改一项，别的项不受影响", () => {
  /* 整个替换的话，改一个开关会把其他开关全冲掉 */
  fresh();
  run('saveNotifyPrefs({onTaskDone: false});');
  if (run("notifyPrefs().onTaskDone") !== false) {
    throw new Error("改的那项没生效");
  }
  if (run("notifyPrefs().onTaskAssigned") !== true) {
    throw new Error("没改的项被冲掉了");
  }
  if (run("notifyPrefs().enabled") !== true) {
    throw new Error("总开关被冲掉了");
  }
});

test("通知：退出登录会清掉通知游标", () => {
  /* 不清的话，换账号后新账号的事件时间戳比旧游标早，
     会被当成"已经看过"而漏掉通知。 */
  fresh();
  run('DB.notifyCursor.taskEvents = "2026-10-10 10:00:00";'
    + 'resetSyncState();');
  if (run("Object.keys(DB.notifyCursor).length") !== 0) {
    throw new Error("notifyCursor 没清干净");
  }
});

test("派任务：员工没有云端账号时必须拒绝", () => {
  /* **这条来自一次真实的端到端失败。**

     createEmployeeLocal 是先建本地员工记录、再去云端建账号。
     云端那步失败时（比如工号被别的老板占了），本地记录还在，
     但 employee_id 还是本地自增数字（1、2…）。

     原来这时候**照样能派任务**，于是把 "1" 当成 uuid 发给服务端：
         invalid input syntax for type uuid: "1"
     任务没建上，员工的勾选又跟着撞外键，一次错引发一串错。

     现在：没有云端 id 的员工不能派任务，而且要给出可读的原因。 */
  fresh();
  run(`DB.profile = {id: "boss-uuid", code: "13800138000",
       name: "老板", role: "boss"};
    DB.employees.push({id: 7, name: "张三", weekly_hours: 40});
    DB.staffAccounts.push({id: "local_7", code: "A001", name: "张三",
      password: "123456", employee_id: 7, pending: true,
      lastError: "工号被占了"});`);

  /* 用本地自增 id 派任务 → 必须拒绝 */
  let message = "";
  try {
    run('assignTask({employee_id: 7, title: "写接口", est_hours: 2});');
  } catch (error) {
    message = String(error.message || error);
  }
  if (!message) {
    throw new Error("用本地数字 id 派任务竟然成功了 —— "
      + "会把 \"7\" 当 uuid 发给服务端");
  }
  if (message.indexOf("云端") === -1 && message.indexOf("账号") === -1) {
    throw new Error("报错没说明白是账号问题，实际：" + message);
  }
  if (run("(DB.tasks || []).length") !== 0) {
    throw new Error("拒绝之后不该留下任务记录");
  }

  /* 员工拿到云端 id 之后就能派了 */
  run(`DB.employees[0].id = "11111111-2222-3333-4444-555555555555";
    DB.staffAccounts[0].employee_id = "11111111-2222-3333-4444-555555555555";
    DB.staffAccounts[0].pending = false;
    delete DB.staffAccounts[0].lastError;`);
  run(`assignTask({employee_id: "11111111-2222-3333-4444-555555555555",`
    + ` title: "写接口", est_hours: 2});`);
  if (run("DB.tasks.length") !== 1) {
    throw new Error("有云端 id 之后应当能派任务，实际 "
      + run("DB.tasks.length") + " 条");
  }
});

test("派任务：员工 id 不是 uuid 时也要拒绝", () => {
  /* 兜底：万一别的路径给了一个非 uuid 的 id
     （比如手工改过本地数据），也不该把脏 id 发出去。 */
  fresh();
  run(`DB.profile = {id: "boss-uuid", code: "13800138000",
       name: "老板", role: "boss"};
    DB.employees.push({id: "abc", name: "张三", weekly_hours: 40});
    DB.staffAccounts.push({id: "local_abc", code: "A001", name: "张三",
      password: "123456", employee_id: "abc", pending: false});`);
  let rejected = false;
  try {
    run('assignTask({employee_id: "abc", title: "x", est_hours: 1});');
  } catch (error) {
    rejected = true;
  }
  if (!rejected) {
    throw new Error("非 uuid 的 employee_id 竟然发出去了");
  }
});

test("完成/取消完成都会上报事件（通知的前提）", () => {
  /* "完成"能从 task_logs 推出来，但**"取消完成"推不出来**——
     那一行是被删掉的，老板端分不清"被撤了"和"我还没拉到"。
     所以两种操作都必须往 task_events 排一条。

     这条测试防的是"以后重构时把它删掉"：
     删了的话通知会静默失效，界面上什么都看不出来。 */
  fresh();
  run(`DB.profile = {id: "22222222-3333-4444-5555-666666666666",
       code: "A001", name: "张三", role: "employee",
       boss_id: "11111111-2222-3333-4444-555555555555"};
    DB.tasks.push({id: "33333333-4444-5555-6666-777777777777",
      boss_id: "11111111-2222-3333-4444-555555555555",
      employee_id: "22222222-3333-4444-5555-666666666666",
      title: "把接口补上", plan_date: todayISO(), est_hours: 2});`);

  /* 完成 → 应当有 done 事件排队 */
  run("completeTask(taskById(\"33333333-4444-5555-6666-777777777777\"), 2);");
  const afterDone = run(
    'DB.syncQueue.filter(function (i) { return i.table === "task_events"; })'
    + '.map(function (i) { return i.payload.kind; })');
  if (String(afterDone).indexOf("done") === -1) {
    throw new Error("完成任务没有排 done 事件，实际：" + JSON.stringify(afterDone));
  }
  /* boss_id 必须是任务的老板，否则老板拉不到 */
  const doneBoss = run(
    'DB.syncQueue.filter(function (i) { return i.table === "task_events"; })[0]'
    + '.payload.boss_id');
  if (doneBoss !== "11111111-2222-3333-4444-555555555555") {
    throw new Error("done 事件的 boss_id 不对：" + doneBoss);
  }

  /* 取消完成 → 应当有 undone 事件排队 */
  run("uncompleteTask(\"33333333-4444-5555-6666-777777777777\");");
  const kinds = run(
    'DB.syncQueue.filter(function (i) { return i.table === "task_events"; })'
    + '.map(function (i) { return i.payload.kind; })');
  if (String(kinds).indexOf("undone") === -1) {
    throw new Error("取消完成没有排 undone 事件，实际：" + JSON.stringify(kinds));
  }
});

test("取消完成：不知道老板是谁时说清楚，不静默丢事件", () => {
  /* boss_id 那一列是 not null。拿不到的话事件写不进去，
     宁可报错也不要静默丢掉——丢了老板就永远不知道工时被撤了。 */
  fresh();
  run(`DB.profile = {id: "22222222-3333-4444-5555-666666666666",
       code: "A001", name: "张三", role: "employee"};
    DB.taskLogs.push({id: "44444444-5555-6666-7777-888888888888",
      task_id: "33333333-4444-5555-6666-777777777777",
      employee_id: "22222222-3333-4444-5555-666666666666",
      finish_date: todayISO()});`);
  let message = "";
  try {
    run('uncompleteTask("33333333-4444-5555-6666-777777777777");');
  } catch (error) {
    message = String(error.message || error);
  }
  if (message.indexOf("老板") === -1) {
    throw new Error("应当说明拿不到老板信息，实际：" + (message || "（没报错）"));
  }
});

test("通知：五类事件的开关各自独立生效", () => {
  /* 用户要的是"五类事件都能提示"，而且能**逐项关掉**。
     这条把五个开关挨个关一遍，确认：
       · 关掉的那类不再产生通知
       · 没关的照常产生

     为什么值得单独测：开关是逐项从 notifyPrefs 读的，
     任何一处拼错名字（onTaskDone vs onTaskdone）都会让
     那一类开关永远失效，而界面上开关看起来是好的。 */
  const kinds = [
    { kind: "assigned", pref: "onTaskAssigned" },
    { kind: "done", pref: "onTaskDone" },
    { kind: "undone", pref: "onTaskUndone" },
  ];
  const events = {
    assigned: { id: "e1", kind: "assigned", title: "写接口",
                task_id: "t1", created_at: "2026-10-10 10:00:00" },
    done: { id: "e2", kind: "done", title: "写接口", hours: 2,
            task_id: "t1", created_at: "2026-10-10 11:00:00" },
    undone: { id: "e3", kind: "undone", title: "写接口",
              task_id: "t1", created_at: "2026-10-10 12:00:00" },
  };
  /* 每种事件由对应的身份收：assigned 给员工，done/undone 给老板 */
  const roleFor = { assigned: "employee", done: "boss", undone: "boss" };

  kinds.forEach(item => {
    /* 关掉这一类 */
    fresh();
    run("saveNotifyPrefs({" + item.pref + ": false});");
    run("window.__ev = [" + JSON.stringify(events[item.kind]) + "];");
    run('ingestEvents(window.__ev, "' + roleFor[item.kind] + '");');
    if (run("notifications().length") !== 0) {
      throw new Error(item.pref + " 关掉了，但 " + item.kind
        + " 还是产生了通知");
    }

    /* 打开这一类，确认它本身是能工作的（不是被别的 bug 掩盖） */
    fresh();
    run("saveNotifyPrefs({" + item.pref + ": true});");
    run("window.__ev = [" + JSON.stringify(events[item.kind]) + "];");
    run('ingestEvents(window.__ev, "' + roleFor[item.kind] + '");');
    if (run("notifications().length") !== 1) {
      throw new Error(item.pref + " 打开了，但 " + item.kind
        + " 没产生通知（开关名可能拼错了）");
    }
  });
});

test("通知：工时汇总和项目状态的开关也能各自关掉", () => {
  fresh();
  /* 日期在测试这边算好，不依赖沙箱里的函数名 */
  const now = new Date();
  const pad = n => String(n).padStart(2, "0");
  const today = now.getFullYear() + "-" + pad(now.getMonth() + 1)
    + "-" + pad(now.getDate());
  const rows = [{ id: "w1", employee_id: 1, work_date: today, hours: 3 }];
  run("window.__rows = " + JSON.stringify(rows) + ";");

  /* 汇总 */
  run('saveNotifyPrefs({onWorklogSummary: false});');
  run("ingestWorklogSummary(window.__rows);");
  if (run("notifications().length") !== 0) {
    throw new Error("汇总开关关掉了还是产生了通知");
  }
  run('saveNotifyPrefs({onWorklogSummary: true});');
  run("ingestWorklogSummary(window.__rows);");
  if (run("notifications().length") !== 1) {
    throw new Error("汇总开关打开了却没产生通知");
  }

  /* 项目状态。

     ## 这里有个陷阱，我踩了一次

     ingestProjectStatus 在开关关掉时**是早退的**，所以它
     不会记快照。于是"先关着跑一次、再打开"的测法根本测不到东西：
     打开之后仍然是"第一次跑"，而第一次跑只记快照不提醒
     （那是有意设计——否则一装 App 就会把现有项目全提醒一遍）。

     所以要在**开关开着**的状态下测：
       项目甲 变化 -> 应当有通知
       把开关关掉，项目乙 变化 -> 不应当有通知 */
  fresh();
  /* 状态用真实取值（"规划中" / "进行中"），不要用英文——
     用错的话整个测试会因为"条件不成立"而假通过 */
  run('DB.projects.push({id: 1, name: "智慧园区", status: "规划中"});'
    + 'DB.projects.push({id: 2, name: "巡检系统", status: "规划中"});');
  run("ingestProjectStatus();");          // 第一次只记快照
  if (run("notifications().length") !== 0) {
    throw new Error("第一次不该提醒（否则一装 App 就刷屏）");
  }

  /* 开关开着：项目甲变化 → 有通知 */
  run('DB.projects[0].status = "进行中";');
  run("ingestProjectStatus();");
  if (run("notifications().length") !== 1) {
    throw new Error("开关开着，项目变成进行中却没通知（实际 "
      + run("notifications().length") + " 条）");
  }

  /* 关掉开关：项目乙变化 → 不该有通知 */
  run('saveNotifyPrefs({onProjectStatus: false});');
  run('DB.projects[1].status = "进行中";');
  run("ingestProjectStatus();");
  if (run("notifications().length") !== 1) {
    throw new Error("项目状态开关关掉了还是产生了通知（实际 "
      + run("notifications().length") + " 条）");
  }
});

test("取消完成：老板端那条工时真的被撤掉", () => {
  /* **这条是通知文案逼出来的。**

     我给老板的通知写着"工时已经撤掉了"，但一查代码：
     mergeRemoteWorklogs **只增改、从不删**，而员工的取消是
     把服务端那条 worklog 删掉——增量拉取只拉"更新的行"，
     所以老板端**永远收不到"它没了"**。

     结果：通知说撤了，看板上那 2 小时还在。**文案在撒谎。**

     修法：undone 事件里带着 task_id 和 work_date，
     老板端收到就按这两个字段把对应工时删掉
     （员工端就是用同样的字段找出来删的）。 */
  fresh();
  run(`DB.profile = {id: "11111111-2222-3333-4444-555555555555",
       code: "13800138000", name: "老板", role: "boss"};
    DB.employees.push({id: "22222222-3333-4444-5555-666666666666",
       name: "张三", weekly_hours: 40});
    DB.remoteWorklogs.push({
      id: "99999999-8888-7777-6666-555555555555",
      boss_id: "11111111-2222-3333-4444-555555555555",
      employee_id: "22222222-3333-4444-5555-666666666666",
      task_id: "33333333-4444-5555-6666-777777777777",
      work_date: todayISO(), hours: 2, content: "把接口补上"});`);
  if (run("DB.remoteWorklogs.length") !== 1) {
    throw new Error("准备数据失败");
  }

  /* 收到员工的取消事件 */
  run(`ingestEvents([{
    id: "ev-undone-1", kind: "undone", title: "把接口补上",
    task_id: "33333333-4444-5555-6666-777777777777",
    employee_id: "22222222-3333-4444-5555-666666666666",
    work_date: todayISO(), created_at: "2026-10-10 12:00:00"
  }], "boss");`);

  if (run("notifications().length") !== 1) {
    throw new Error("应当产生一条通知");
  }
  if (run("DB.remoteWorklogs.length") !== 0) {
    throw new Error("老板端那条工时没被撤掉，还剩 "
      + run("DB.remoteWorklogs.length") + " 条 —— 通知说撤了却没撤");
  }

  /* **开关关掉时也必须撤工时。**

     这里容易写错：如果把撤销放在 notifyEnabled 判断之后，
     关掉通知就变成"工时也不撤了"——那是两件事，
     界面上的开关只该管"提不提醒"，不该管数据对不对。 */
  fresh();
  run(`DB.profile = {id: "boss-1", code: "138", name: "老板", role: "boss"};
    DB.remoteWorklogs.push({
      id: "w1", employee_id: "e1", task_id: "t1",
      work_date: todayISO(), hours: 2, content: "任务一"});
    saveNotifyPrefs({onTaskUndone: false});`);
  run(`ingestEvents([{
    id: "ev-undone-9", kind: "undone", title: "任务一",
    task_id: "t1", employee_id: "e1",
    work_date: todayISO(), created_at: "2026-10-10 12:00:00"
  }], "boss");`);
  if (run("notifications().length") !== 0) {
    throw new Error("开关关掉了不该产生通知");
  }
  if (run("DB.remoteWorklogs.length") !== 0) {
    throw new Error("开关关掉之后工时没撤 —— "
      + "通知开关不该影响数据正确性");
  }
});

test("取消完成：只撤那条任务的工时，不动别人的", () => {
  fresh();
  run(`DB.profile = {id: "11111111-2222-3333-4444-555555555555",
       code: "13800138000", name: "老板", role: "boss"};
    DB.remoteWorklogs.push({
      id: "aaaaaaaa-1111-1111-1111-111111111111",
      employee_id: "e1", task_id: "t1",
      work_date: todayISO(), hours: 2, content: "任务一"});
    DB.remoteWorklogs.push({
      id: "bbbbbbbb-2222-2222-2222-222222222222",
      employee_id: "e1", task_id: "t2",
      work_date: todayISO(), hours: 3, content: "任务二"});`);
  run(`ingestEvents([{
    id: "ev-undone-2", kind: "undone", title: "任务一",
    task_id: "t1", employee_id: "e1",
    work_date: todayISO(), created_at: "2026-10-10 12:00:00"
  }], "boss");`);
  if (run("DB.remoteWorklogs.length") !== 1) {
    throw new Error("应当只剩 1 条（任务二那条），实际 "
      + run("DB.remoteWorklogs.length") + " 条");
  }
  if (run("DB.remoteWorklogs[0].task_id") !== "t2") {
    throw new Error("撤错了：剩下的是 " + run("DB.remoteWorklogs[0].task_id"));
  }
});

test("通知：同一次同步里先完成又取消，汇总不报已撤销的工时", () => {
  /* **这条修的是一处不一致。**

     pumpNotifications 原来先算工时汇总、后处理事件（事件里才撤销）。
     于是员工在同一次同步里"先完成又取消"时：
       · 工时被撤销了 → 看板 0 条
       · 汇总却把那条算进去 → 通知说"收到 1 条 2 小时"
     **通知和数据对不上。**

     现在顺序反过来：先撤销，再用剩下的算汇总。 */
  fresh();
  run(`DB.profile = {id: "boss-1", code: "138", name: "老板", role: "boss"};`);
  const now = new Date();
  const pad = n => String(n).padStart(2, "0");
  const today = now.getFullYear() + "-" + pad(now.getMonth() + 1)
    + "-" + pad(now.getDate());
  const worklog = {
    id: "w-cancel", boss_id: "boss-1", employee_id: "e1",
    task_id: "t-cancel", work_date: today, hours: 2, content: "干完了又撤了",
  };
  run("window.__wl = " + JSON.stringify([worklog]) + ";");
  run("window.__ev = " + JSON.stringify([{
    id: "ev-cancel", kind: "undone", title: "干完了又撤了",
    task_id: "t-cancel", employee_id: "e1",
    work_date: today, created_at: "2026-10-10 12:00:00",
  }]) + ";");

  /* 注意：本地要先有这条工时（模拟刚拉到） */
  run("DB.remoteWorklogs = window.__wl.slice();");
  /* pumpNotifications 是异步的，但这里只关心它调用的顺序。
     用同步的方式模拟同样的顺序：先事件、再汇总。 */
  run("ingestEvents(window.__ev, \"boss\");");
  const aliveAfter = run("(DB.remoteWorklogs || []).length");
  if (aliveAfter !== 0) {
    throw new Error("事件没有撤销工时，实际还剩 " + aliveAfter + " 条");
  }
  /* 用"撤销后还活着的"过滤输入，再算汇总 */
  run(`var alive = DB.remoteWorklogs.map(function (r) { return String(r.id); });
    var fresh = window.__wl.filter(function (r) {
      return alive.indexOf(String(r.id)) !== -1; });
    ingestWorklogSummary(fresh);`);
  /* 只该有 undone 那一条通知，不该多出一条汇总 */
  const kinds = run("notifications().map(function (n) { return n.kind; })");
  if (String(kinds).indexOf("summary") !== -1) {
    throw new Error("汇总把已经撤销的工时算进去了：" + JSON.stringify(kinds));
  }
  if (String(kinds).indexOf("undone") === -1) {
    throw new Error("应当有取消完成的通知，实际：" + JSON.stringify(kinds));
  }
});

test("通知流水线：撤销 + 汇总 + 红点，按真实顺序跑一遍", () => {
  /* **按 pumpNotifications 内部的实际顺序**同步跑一遍各个零件。

     不直接调 pumpNotifications 的原因：它是 async，而这套沙箱的
     `run` 是同步的，拿到的会是 Promise 而不是结果。
     与其写一堆异步等待，不如把它的顺序抄过来逐步验证——
     顺序本身就是要验证的东西（先撤销、再汇总）。 */
  fresh();
  run(`DB.profile = {id: "boss-1", code: "138", name: "老板", role: "boss"};
    DB.employees.push({id: "e1", name: "张三", weekly_hours: 40});`);
  const now = new Date();
  const pad = n => String(n).padStart(2, "0");
  const today = now.getFullYear() + "-" + pad(now.getMonth() + 1)
    + "-" + pad(now.getDate());

  /* 这次同步拉到两条工时：一条会被撤销，一条留着 */
  const rows = [
    { id: "w-keep", boss_id: "boss-1", employee_id: "e1",
      task_id: "t-keep", work_date: today, hours: 3, content: "留着" },
    { id: "w-drop", boss_id: "boss-1", employee_id: "e1",
      task_id: "t-drop", work_date: today, hours: 2, content: "会被撤" },
  ];
  const events = [{
    id: "ev-drop", kind: "undone", title: "会被撤",
    task_id: "t-drop", employee_id: "e1",
    work_date: today, created_at: "2026-10-10 12:00:00",
  }];
  run("window.__rows = " + JSON.stringify(rows) + ";");
  run("window.__ev = " + JSON.stringify(events) + ";");
  run("DB.remoteWorklogs = window.__rows.slice();");

  /* 步骤 1：处理事件（撤销在里面） */
  run('ingestEvents(window.__ev, "boss");');
  if (run("DB.remoteWorklogs.length") !== 1) {
    throw new Error("撤销没生效，还剩 " + run("DB.remoteWorklogs.length") + " 条");
  }
  if (run("DB.remoteWorklogs[0].task_id") !== "t-keep") {
    throw new Error("撤错了：剩的是 " + run("DB.remoteWorklogs[0].task_id"));
  }

  /* 步骤 2：用**还活着的**工时算汇总 */
  run(`var alive = DB.remoteWorklogs.map(function (r) { return String(r.id); });
    var fresh = window.__rows.filter(function (r) {
      return alive.indexOf(String(r.id)) !== -1; });
    ingestWorklogSummary(fresh);`);
  const summary = plain(run(
    'notifications().filter(function (n) { return n.kind === "summary"; })'));
  if (summary.length !== 1) {
    throw new Error("应当有 1 条汇总，实际 " + summary.length);
  }
  if (String(summary[0].body).indexOf("3") === -1) {
    throw new Error("汇总小时数应当是 3，实际：" + summary[0].body);
  }
  if (String(summary[0].body).indexOf("5") !== -1) {
    throw new Error("汇总把撤销的那 2 小时也算进去了：" + summary[0].body);
  }

  /* 步骤 3：刷新红点时要能安全执行。

     **沙箱里的 document 是桩**：querySelectorAll 永远返回空数组，
     所以这里画不出红点元素——红点是否真的出现由浏览器测试负责
     （devtools/notify-check.html 里查过）。

     这一步真正要盯的是：**renderNotifyBadges 不能有隐式的
     加载顺序依赖**。它原来调了 app.js 的 `$`，而 notify.js
     在 app.js 之前加载——单独加载 notify.js 就会
     "$ is not defined"。自检正好就是单独加载的场景。 */
  let badgeError = null;
  try {
    run("renderNotifyBadges();");
  } catch (error) {
    badgeError = String(error.message || error);
  }
  if (badgeError) {
    throw new Error("renderNotifyBadges 抛错了（可能有加载顺序依赖）："
      + badgeError);
  }
  /* 提示条同理 */
  try {
    run('renderNotifyBanner("notify-banner-dash");');
  } catch (error) {
    throw new Error("renderNotifyBanner 抛错了：" + error.message);
  }
});

test("pumpNotifications：没登录时安静返回，不抛错", () => {
  /* 早退路径。这条能同步测，因为 DB.profile 为空时它
     在第一个 await 之前就返回了。 */
  fresh();
  run("DB.profile = null;");
  const result = plain(run("pumpNotifications({})"));
  /* async 函数即使不走 await 也返回 Promise；
     这里只确认「调用它不会抛同步异常」。 */
  void result;
  if (run("DB.profile") !== null) {
    throw new Error("不该改数据");
  }
});

test("通知：「应用内提示」开关真的管用", () => {
  /* **这条查出一个死开关。**

     通知中心里有「应用内提示」这个开关，但代码里**从来没读过它**——
     关掉之后红点和提示条照样出现。**界面上躺着一个不动的开关，
     比没有这个开关更糟**（用户以为关掉了）。

     ## 为什么这里检查代码而不是跑函数

     渲染函数用 document 操作，而沙箱里的 document 是桩：
     querySelectorAll 永远返回空数组，getElementById 返回 null。
     所以"红点数为 0"跟开不开**无关**——断言会假通过。
     （我第一版就是这么写的，跑出来"通过"，其实什么都没验。）

     形状对了但没验到点子上，等于没测。所以这里直接读源码，
     确认渲染路径上**引用了 inApp**。 */
  const source = fs.readFileSync(path.join(HERE, "notify.js"), "utf8");

  /* 取 renderNotifyBadges 和 renderNotifyBanner 的函数体 */
  ["renderNotifyBadges", "renderNotifyBanner"].forEach(name => {
    const start = source.indexOf("function " + name);
    if (start === -1) throw new Error("找不到 " + name);
    const rest = source.slice(start + 10);
    const nextFn = rest.indexOf("\nfunction ");
    const body = nextFn === -1 ? rest : rest.slice(0, nextFn);
    if (body.indexOf("inApp") === -1) {
      throw new Error(name + " 没有检查 inApp 开关 —— "
        + "关掉「应用内提示」之后它照样会渲染");
    }
  });

  /* 数据层不能被这个开关影响：管的是"提不提示"，不是"记不记" */
  fresh();
  run('addNotification({key: "a", kind: "done", title: "x", body: "y"});'
    + "saveNotifyPrefs({inApp: false});");
  if (run("notifications().length") !== 1) {
    throw new Error("关掉应用内提示把通知删了");
  }
  if (run("unreadCount()") !== 1) {
    throw new Error("关掉应用内提示影响了未读数");
  }
  if (run("notifyEnabled('done')") !== true && run("notifyEnabled('done')") !== false) {
    throw new Error("notifyEnabled 返回值异常");
  }
});

test("通知：三个开关职责不混", () => {
  /* enabled 是总闸：关掉它，任何一类都不发 */
  fresh();
  run("saveNotifyPrefs({enabled: false, inApp: true, system: true,"
    + " onTaskDone: true});");
  run('ingestEvents([{id: "e1", kind: "done", title: "x", task_id: "t1",'
    + ' created_at: "2026-10-10 10:00:00"}], "boss");');
  if (run("notifications().length") !== 0) {
    throw new Error("总闸关掉了还产生通知");
  }

  /* 关掉 system 不该拦住通知的产生（只是不弹通知栏） */
  fresh();
  run("saveNotifyPrefs({enabled: true, system: false, onTaskDone: true});");
  run('ingestEvents([{id: "e1", kind: "done", title: "x", task_id: "t1",'
    + ' created_at: "2026-10-10 10:00:00"}], "boss");');
  if (run("notifications().length") !== 1) {
    throw new Error("关掉系统通知把应用内通知也拦掉了 —— 职责混了");
  }

  /* 关掉 inApp 也不该拦住通知的产生 */
  fresh();
  run("saveNotifyPrefs({enabled: true, inApp: false, onTaskDone: true});");
  run('ingestEvents([{id: "e1", kind: "done", title: "x", task_id: "t1",'
    + ' created_at: "2026-10-10 10:00:00"}], "boss");');
  if (run("notifications().length") !== 1) {
    throw new Error("关掉应用内提示把通知本身也拦掉了 —— 职责混了");
  }
});

test("派任务：下拉里的选中值失效时必须拒绝，不能静默派错人", () => {
  /* **这条来自用户的真实反馈**："给别人发任务，结果发到我自己的员工号上了"。

     查出来的原因在 renderAssign：
         var current = employeeSelect.value;
         employeeSelect.innerHTML = staff.map(...);   // 重建
         if (current) employeeSelect.value = current;
     employee_id 变化时（createCloudStaff 就会把它从本地数字换成 uuid），
     current 在新列表里匹配不到任何一项 → 浏览器把它设成"未选中"
     → select 自动回到第一项 → 提交时取到的是**第一个人**。

     于是任务静默派给了错误的人，界面还提示"已派发"。

     修法：提交前校验"选中的 id 确实在当前员工列表里"，
     不在就拒绝并要求重选。宁可让人多点一下，也不能派错人。 */
  fresh();
  /* **用真实格式的 uuid。**

     我第一版写的是 "uuid-a" / "uuid-b"（图省事），
     但它们不是合法 uuid——于是"格式不对"那条先拦住了，
     测不到"选中的值失效"这条路径。**测试数据不真实，
     测的就是假的东西。** */
  const UUID_A = "11111111-1111-4111-8111-111111111111";
  const UUID_B = "22222222-2222-4222-8222-222222222222";
  run(`DB.profile = {id: "boss-1", code: "138", name: "老板", role: "boss"};
    DB.employees.push({id: "${UUID_A}", name: "张三", weekly_hours: 40});
    DB.employees.push({id: "${UUID_B}", name: "李四", weekly_hours: 40});
    DB.staffAccounts.push({id: "sa", code: "A001", name: "张三",
      password: "123456", employee_id: "${UUID_A}", pending: false});
    DB.staffAccounts.push({id: "sb", code: "A002", name: "李四",
      password: "123456", employee_id: "${UUID_B}", pending: false});`);

  /* 选一个不存在的 id —— 模拟"选中值失效" */
  let rejected = false;
  let message = "";
  try {
    run('assignTask({employee_id: "", title: "写接口", est_hours: 2});');
  } catch (error) {
    rejected = true;
    message = String(error.message || error);
  }
  if (!rejected) throw new Error("空 employee_id 竟然能派任务");

  /* 一个**格式合法但不在名单里**的 uuid。 */
  rejected = false;
  message = "";
  try {
    run('assignTask({employee_id: "99999999-9999-4999-8999-999999999999",'
      + ' title: "写接口", est_hours: 2});');
  } catch (error) {
    rejected = true;
    message = String(error.message || error);
  }
  if (!rejected) {
    throw new Error("指向不存在员工的 id 竟然能派任务 —— 这就是派错人的路径");
  }
  if (message.indexOf("名单") === -1) {
    throw new Error("应当报【不在名单里】让人重选，实际报的是：" + message);
  }

  /* 正确的 id 仍然要能派 */
  let lastError = "";
  try {
    run(`assignTask({employee_id: "${UUID_B}", title: "写接口",`
      + " est_hours: 2});");
  } catch (error) {
    lastError = String(error.message || error);
  }
  if (lastError) {
    throw new Error("合法的员工应当能派任务，却报：" + lastError
      + "\n        名单：" + JSON.stringify(plain(run(
        "staffAccounts().map(function (a) { return a.employee_id"
        + " + ':' + a.pending; })"))));
  }
  if (run("DB.tasks.length") !== 1) {
    throw new Error("合法的员工应当能派任务，实际任务数 "
      + run("DB.tasks.length"));
  }
  if (run("DB.tasks[0].employee_id") !== UUID_B) {
    throw new Error("派给了错误的人：" + run("DB.tasks[0].employee_id"));
  }
});

test("提示里提到的 SQL 文件必须真实存在", () => {
  /* **这条来自一次真实的失误。**

     我把 sql/task-events.sql 和 sql/reclaim-orphan-codes.sql
     合并成了 sql/migrate-notify.sql，但**忘了改提示文案**——
     用户在「我的」页看到"去跑 sql/task-events.sql"，
     按它去找会找不到。

     **改动文件名时全局搜一遍引用**这件事，人很容易忘。
     所以让机器盯着：界面上出现的 sql/xxx.sql 必须真的存在。 */
  const files = ["sync.js", "notify.js", "account.js", "community.js", "app.js"];
  const missing = [];
  const seen = [];
  files.forEach(name => {
    const source = fs.readFileSync(path.join(HERE, name), "utf8");
    /* 匹配 sql/xxx.sql 这种写法 */
    matchAll(source, /sql\/([a-z-]+\.sql)/g).forEach(ref => {
      seen.push(name + " → " + ref);
      if (!fs.existsSync(path.join(HERE, "sql", ref))) {
        missing.push(name + " 里提到 " + ref);
      }
    });
  });
  /* 把扫到的都列出来，失败时能一眼看到是哪个 */
  if (missing.length) {
    throw new Error("提示文案指向了不存在的 SQL 文件：\n  "
      + missing.join("\n  ")
      + "\n\n  扫描到的全部引用：\n    " + seen.join("\n    "));
  }
  if (!seen.length) {
    throw new Error("一个 sql/xxx.sql 的引用都没扫到 —— "
      + "正则可能写错了，这条检查等于没做");
  }
});

test("不需要的 SQL 文件已清掉，避免指错路", () => {
  /* 合并之后，旧文件名不该再作为"独立步骤"存在——
     留着会让用户不知道该跑哪个。

     （create-staff-rpc.sql 保留：它是单文件、可独立跑的版本，
       migrate-notify.sql 里只是又定义了一遍。） */
  const merged = ["task-events.sql", "reclaim-orphan-codes.sql",
                  "create-boss-rpc.sql"];
  const stillThere = merged.filter(name =>
    fs.existsSync(path.join(HERE, "sql", name)));
  if (stillThere.length) {
    throw new Error("这些已经合并进 migrate-notify.sql，"
      + "不该再单独存在（会让人不知道跑哪个）："
      + stillThere.join("、"));
  }
});

test("SQL 文件必须是纯 ASCII", () => {
  /* **这条来自一次真实的踩坑。**

     SQL 文件里写了中文注释，传过去被重新编码，
     变成了 `＄`（全角美元符 U+FF04）。它看起来像 `$`，
     但 PostgreSQL 不认——于是**函数体的 `$$` 定界符被破坏**，
     报出来的却是 "syntax error at or near ^"，
     指向一行完全无关的正则表达式。**排查了很久。**

     所以 SQL 一律 ASCII：注释也写英文。
     这条检查在写 SQL 时就挡住，不用等到跑的时候才发现。 */
  const dir = path.join(HERE, "sql");
  if (!fs.existsSync(dir)) return;
  const bad = [];
  fs.readdirSync(dir).filter(f => f.endsWith(".sql")).forEach(name => {
    const raw = fs.readFileSync(path.join(dir, name), "utf8");
    const offenders = [];
    raw.split("\n").forEach((line, index) => {
      for (const ch of line) {
        if (ch.codePointAt(0) > 127) {
          offenders.push((index + 1) + ":" + ch);
          break;
        }
      }
    });
    if (offenders.length) {
      bad.push(name + "（" + offenders.length + " 行，如 "
        + offenders.slice(0, 3).join(" ") + "）");
    }
  });
  if (bad.length) {
    throw new Error("这些 SQL 文件里有非 ASCII 字符，"
      + "可能破坏 $ 定界符：\n  " + bad.join("\n  "));
  }
});

test("index.html 里的每个按钮都有 onclick 绑上", () => {
  /* **这条来自一次真实的疏忽。**

     我在登录页加了「忘了密码」按钮、也写好了处理函数，
     但**忘了在 bindGlobalEvents 里接线**——
     表现是"点了没反应"，而且不报错。

     原来的检查只查反方向（JS 里引用的 id 在 HTML 里存在），
     抓不到"HTML 里有按钮但没人绑"。所以补这一条。

     ## 跳过哪些

       · 导航按钮：用 data-page / data-back，由统一的委托处理
       · 动态生成的按钮：在 JS 模板串里，不在 index.html 里

     只检查 index.html 里**静态写死**的按钮。 */
  const html = fs.readFileSync(path.join(HERE, "index.html"), "utf8");
  const sources = ["app.js", "account.js", "community.js", "today.js",
                   "operations.js", "execution.js", "intake.js"]
    .map(name => fs.readFileSync(path.join(HERE, name), "utf8"))
    .join("\n");

  /* 取 <button ... id="xxx" ...> */
  const ids = [];
  matchAll(html, /<button[^>]*\sid="([^"]+)"/g).forEach(id => {
    if (ids.indexOf(id) === -1) ids.push(id);
  });
  if (!ids.length) throw new Error("一个静态按钮都没扫到，正则可能写错了");

  /* 先把每个按钮的**整个标签**抽出来（属性和属性值里都不含 ">"，
     所以匹配到第一个 ">" 为止是安全的）。

     **注意 matchAll 的第三个参数**：默认返回第 1 个捕获组，
     这里要的是整个匹配，所以传 0。不传的话拿到的是一个
     字符串（id），后面 .match 就会报 undefined。 */
  const tags = {};
  matchAll(html, /<button[^>]*>/g, 0).forEach(tag => {
    const idMatch = tag.match(/\sid="([^"]+)"/);
    if (idMatch) tags[idMatch[1]] = tag;
  });

  const unbound = [];
  ids.forEach(id => {
    /* 有没有 $( "id" ).onclick = ... 或者 addEventListener */
    const bound = new RegExp('\\$\\("' + id + '"\\)\\s*\\.\\s*onclick')
      .test(sources)
      || new RegExp('\\$\\("' + id + '"\\)\\s*\\.\\s*addEventListener')
        .test(sources);
    /* 导航类按钮用属性驱动，统一委托，不需要各自绑。
       **属性可能在 id 前面**（`data-page="me" id="nav-me-boss"`），
       所以看整个标签，不要写"id 后面必须紧跟属性"那种正则——
       我第一版就是这么写的，结果把两个导航按钮误判成没绑。 */
    const navDriven = /data-(page|back)=/.test(tags[id] || "");
    if (!bound && !navDriven) unbound.push(id);
  });

  if (unbound.length) {
    throw new Error("这些按钮在 index.html 里，但没有任何地方绑 onclick，"
      + "点了不会有反应：\n  " + unbound.join("\n  "));
  }
});

test("「通知没装好」的标记能自己消掉", () => {
  /* **这条来自用户的真实困惑。**

     他在「我的」页看到黄字"通知功能没装好——去跑一遍
     sql/migrate-notify.sql"，**但他早就跑过了**。

     原因：`DB.notifyTableMissing` 原来是**只进不出**的。
     早先某次上传失败时被设成 true 写进本机存储，
     之后永远显示那条提示——表建好了也不会消。

     用户看到提示还在，自然以为 SQL 没生效。
     **一个只进不出的状态标记，就是会变成谎话。**

     所以检查两件事：
       1. 有地方能把它设回 false
       2. 那个地方真的被调用（不是写了没人用） */
  const sync = fs.readFileSync(path.join(HERE, "sync.js"), "utf8");

  if (sync.indexOf("DB.notifyTableMissing = false") === -1) {
    throw new Error("没有任何地方把 notifyTableMissing 设回 false —— "
      + "提示会永远留着，哪怕表已经建好了");
  }
  /* 设 true 和设 false 都要有，否则是另一头的 bug */
  if (sync.indexOf("DB.notifyTableMissing = true") === -1) {
    throw new Error("没有地方设成 true —— 表真缺的时候就不提示了");
  }
  /* 清除函数必须被调用 */
  if (!/verifyNotifyTable\s*\(\)\s*;/.test(sync)
      || sync.indexOf("await verifyNotifyTable()") === -1) {
    throw new Error("verifyNotifyTable 定义了但没被调用 —— "
      + "写了没人用等于没写");
  }
});

test("验表失败时不能轻易撤掉提示", () => {
  /* 反过来也要防：**网络抖一下就把提示撤掉**同样是错的。

     如果验表时遇到的是网络问题（不是"表不存在"），
     说明我们**不知道**表在不在——这时候不能改标记，
     否则用户以为好了，实际通知还是不通。 */
  const sync = fs.readFileSync(path.join(HERE, "sync.js"), "utf8");
  const start = sync.indexOf("async function verifyNotifyTable");
  if (start === -1) throw new Error("找不到 verifyNotifyTable");
  const body = sync.slice(start, start + 1400);

  /* 必须区分「表不存在」和「别的错误」 */
  if (!/Could not find the table\|does not exist\|schema cache/
      .test(body.replace(/\\/g, ""))) {
    throw new Error("verifyNotifyTable 没有区分「表不存在」和别的错误 —— "
      + "网络抖动会被误判成表已经建好");
  }
  /* 要有 catch，网络异常不能抛出去 */
  if (body.indexOf("catch") === -1) {
    throw new Error("verifyNotifyTable 没有 catch —— "
      + "网络异常会冒到同步流程里，把整个同步搞失败");
  }
});

test("测试页里的 inline script 语法必须正确", () => {
  /* **这条来自一次真实的排查。**

     我在 notify-check.html 里插了一段带 `await` 的代码，
     但那个文件是 `.then` 链结构、没有 async 包裹——
     于是整段脚本语法错误。

     表现非常难查：**页面永远停在"运行中…"，不报任何错**，
     因为脚本根本没开始跑。

     浪费了好几轮才想到去检查语法。
     现在让自检来查：把每个 html 里的 inline script 抠出来
     过一遍 vm.Script，语法错立刻报出来。 */
  const pages = fs.readdirSync(HERE)
    .filter(name => name.endsWith(".html"));
  const problems = [];

  pages.forEach(name => {
    const html = fs.readFileSync(path.join(HERE, name), "utf8");
    const pattern = /<script(?![^>]*\ssrc=)[^>]*>([\s\S]*?)<\/script>/gi;
    let match = pattern.exec(html);
    let index = 0;
    while (match) {
      index += 1;
      const source = match[1];
      /* 跳过只是数据（没语句）的空 script */
      if (source.trim()) {
        try {
          new vm.Script(source, { filename: name + " #" + index });
        } catch (error) {
          problems.push(name + " 第 " + index + " 段："
            + String(error.message).slice(0, 90));
        }
      }
      match = pattern.exec(html);
    }
  });

  if (problems.length) {
    throw new Error("这些测试页的脚本有语法错（页面会卡住不报错）：\n  "
      + problems.join("\n  "));
  }
});

test("系统通知能真的弹出横幅（渠道 + 不在前台屏蔽）", () => {
  /* **这条来自用户的抱怨**："我要的是直接弹到手机上。"

     两个原因让通知弹不出来，而且都不会报错：

       1. `pushSystemNotification` 里有一句
              if (!document.hidden) return false;
          "用户正看着 App 就不弹"——可那正是用户期待弹窗的时候，
          看不到反而以为功能坏了。

       2. **没建通知渠道**（Android 8 起必需）。
          没渠道的通知照样进通知栏，但不响、不震、不弹横幅，
          只静静躺着——现象就是"开了通知却收不到"。

     两者都是静默失败，所以用静态检查盯住。 */
  const notify = fs.readFileSync(path.join(HERE, "notify.js"), "utf8");
  const code = notify.replace(/\/\*[\s\S]*?\*\//g, "");

  /* 1. 不能有"前台不弹"的提前返回 */
  if (/if\s*\(\s*!document\.hidden\s*\)\s*return\s+false/.test(code)) {
    throw new Error("pushSystemNotification 又在「前台不弹」了 —— "
      + "用户明确要求任何时候都弹到手机上");
  }

  /* 1b. **注释里也不能说"前台不弹"。**

      这一条是真踩过的坑：代码已经改成"前台也弹"了，
      但函数上方的说明、和调用处的注释还写着"只在后台时弹"。
      后来我自己 grep 到那句，以为漏改了，白查了一轮。

      **注释和行为矛盾比没有注释更糟**——它会让人怀疑代码，
      也会让下一个改代码的人按错的方向改。

      所以：代码里不能出现"只在后台"这类说法。 */
  const staleClaims = [
    "App 在前台时不弹",
    "只在后台时弹",
    "内部会判断",
    "前台就不弹",
  ];
  const hit = staleClaims.filter(text => notify.indexOf(text) !== -1);
  if (hit.length) {
    throw new Error("注释里还写着过时的行为（实际是前台也弹）："
      + hit.join("、"));
  }
  /* 2. 必须建渠道 */
  if (notify.indexOf("async function ensureNotifyChannel") === -1) {
    throw new Error("没有 ensureNotifyChannel —— 没渠道的通知不出横幅");
  }
  /* 3. importance 必须是 4（HIGH），3 及以下不出横幅 */
  const imp = code.match(/importance:\s*(\d)/);
  if (!imp) {
    throw new Error("createChannel 里没写 importance");
  }
  if (Number(imp[1]) < 4) {
    throw new Error("渠道 importance=" + imp[1]
      + "，太低了不会弹横幅（要 4）");
  }
  /* 4. 发通知时要用那个渠道（不能写死 "default"） */
  if (/channelId:\s*"default"/.test(code)) {
    throw new Error('schedule 里还写着 channelId: "default" —— '
      + "那个渠道没建过，通知不会弹横幅");
  }
  if (code.indexOf("channelId: NOTIFY_CHANNEL_ID") === -1) {
    throw new Error("schedule 没有用 NOTIFY_CHANNEL_ID");
  }
  /* 5. 建渠道要被调用，不能定义了没人用 */
  if (code.indexOf("await ensureNotifyChannel()") === -1
      && code.indexOf("ensureNotifyChannel();") === -1) {
    throw new Error("ensureNotifyChannel 定义了但没调用 —— 写了没人用");
  }
});

test("进「我的」页会清掉红点", () => {
  /* **这条来自用户的抱怨**："图上的红点消不掉而且好丑"。

     原因：只有点右上角铃铛、打开通知中心才会清除未读。
     但用户的直觉是"我点进「我的」了，红点该没了"——
     他点了没消，就觉得红点坏了。

     用户是对的：**红点是"那儿有新东西"的提示，
     进去了就该消失。** 所以 showPage 里切到 me 时要标已读。 */
  const app = fs.readFileSync(path.join(HERE, "app.js"), "utf8");
  const code = app.replace(/\/\*[\s\S]*?\*\//g, "");

  if (!/target === "me"[\s\S]{0,60}markNotificationsRead/.test(code)) {
    throw new Error("切到「我的」页没有标已读 —— "
      + "红点会一直挂着，用户以为消不掉");
  }

  /* 红点样式：两位数字不能挤成一坨，还要有描边 */
  const css = fs.readFileSync(path.join(HERE, "style.css"), "utf8");
  const badge = css.slice(css.indexOf(".nav-badge {"));
  const rule = badge.slice(0, badge.indexOf("}"));
  if (!/min-width:\s*1[5-9]px|min-width:\s*2\dpx/.test(rule)) {
    throw new Error("红点最小宽度太小，两位数会挤在一起");
  }
  if (!/font-weight:\s*[5-7]00/.test(rule)) {
    throw new Error("红点数字没有加粗，小尺寸下看不清");
  }
  if (rule.indexOf("box-shadow") === -1) {
    throw new Error("红点没有描边，贴在底图上边缘会发毛（用户说丑）");
  }
});

test("实时订阅接上了（「一发就弹」的前提）", () => {
  /* **这条来自用户的抱怨**："延迟好大，可以实现一发就弹窗不"。

     轮询最快也要等一个间隔（15 秒）。正解是让服务器主动推：
     Supabase 的 Realtime 通过 WebSocket 把变更推给手机，
     通常 1 秒内就到。

     这个功能很容易"写了但没接上"——定义了订阅函数，
     却没有任何地方调用，表现还是慢，而且不报错。
     所以检查调用链完整。 */
  const sync = fs.readFileSync(path.join(HERE, "sync.js"), "utf8");
  const code = sync.replace(/\/\*[\s\S]*?\*\//g, "");

  if (sync.indexOf("function subscribeRealtime") === -1) {
    throw new Error("没有 subscribeRealtime");
  }
  if (sync.indexOf("function unsubscribeRealtime") === -1) {
    throw new Error("没有 unsubscribeRealtime —— 退出登录后订阅还挂着");
  }
  /* 订阅必须被启动（不然等于没写） */
  if (!/subscribeRealtime\(\);/.test(code)) {
    throw new Error("subscribeRealtime 定义了但没调用 —— 还是只能靠轮询");
  }
  /* 订阅的必须是 task_events（通知的来源） */
  if (code.indexOf('table: "task_events"') === -1) {
    throw new Error("订阅的表不是 task_events，收不到通知事件");
  }
  /* 必须挂在 channel 上，而不是自己拼 WebSocket */
  if (code.indexOf(".channel(") === -1
      || code.indexOf("postgres_changes") === -1) {
    throw new Error("没有用 supabase 的 channel/postgres_changes");
  }
  /* **订阅失败不能让同步停摆**：必须有 try/catch 兜底 */
  const start = sync.indexOf("function subscribeRealtime");
  const body = sync.slice(start, start + 1600);
  if (body.indexOf("catch") === -1) {
    throw new Error("subscribeRealtime 没有 catch —— "
      + "服务端没开实时推送时会把同步循环整个搞挂");
  }
});

test("后台通知：原生个推接收器启用且不保留常驻通知", () => {
  const main = fs.readFileSync(path.join(HERE, "android", "app", "src",
    "main", "java", "com", "cj", "projectrecorder", "MainActivity.java"),
    "utf8");
  const pushPlugin = fs.readFileSync(path.join(HERE, "android", "app", "src",
    "main", "java", "com", "cj", "projectrecorder", "GetuiPushPlugin.java"),
    "utf8");
  const pushService = fs.readFileSync(path.join(HERE, "android", "app", "src",
    "main", "java", "com", "cj", "projectrecorder", "GetuiPushIntentService.java"),
    "utf8");
  const manifest = fs.readFileSync(path.join(HERE, "android", "app",
    "src", "main", "AndroidManifest.xml"), "utf8");
  if (main.indexOf("registerPlugin(GetuiPushPlugin.class)") === -1
      || !/PushManager\.getInstance\(\)\.initialize/.test(pushPlugin)) {
    throw new Error("个推插件未注册或未调用原生初始化");
  }
  if (!/onReceiveClientId/.test(pushService)
      || manifest.indexOf("GetuiPushIntentService") === -1) {
    throw new Error("个推 CID 回调服务未声明");
  }
  if (manifest.indexOf("KeepAliveService") !== -1
      || manifest.indexOf("FOREGROUND_SERVICE") !== -1) {
    throw new Error("前台保活服务仍在，会产生常驻通知");
  }
  const account = fs.readFileSync(path.join(HERE, "account.js"), "utf8");
  const app = fs.readFileSync(path.join(HERE, "app.js"), "utf8");
  if (/startKeepAlive|stopKeepAlive/.test(account + app)) {
    throw new Error("JS 仍会启动前台保活服务");
  }
});

test("PowerShell 脚本必须纯 ASCII", () => {
  /* **这条来自一次真实的报错。**

     我写了个 setup-push-params.ps1 帮用户填推送参数，
     里面用了中文提示和全角标点（、（）？）。

     用户一运行就被 PowerShell 报了一堆语法错：

         表达式或语句中包含意外的标记 "}"

     原因：**Windows PowerShell 5.1 读不带 BOM 的 UTF-8 文件时
     按 GBK 解码**。中文变成乱码（"锛堝綋鍓嶅凡璁撅紝"），
     连全角问号都被解成两半，把脚本结构搞崩。

     这个项目已经被编码坑过两次：
       1. SQL 里的全角美元符破坏了 $$ 定界符
       2. 这个 .ps1 的中文提示被 GBK 解码后语法错

     所以定规矩：**.ps1 一律纯 ASCII**，提示文字用英文。

     为什么不加 BOM 了事：BOM 能救这一台机器，
     但"必须是 ASCII"是更强的约束，也不容易忘。 */
  const files = fs.readdirSync(HERE).filter(name => name.endsWith(".ps1"));
  if (!files.length) {
    throw new Error("一个 .ps1 都没找到，检查路径对不对");
  }

  const problems = [];
  files.forEach(name => {
    const buf = fs.readFileSync(path.join(HERE, name));
    const bad = [...buf].filter(byte => byte > 127).length;
    if (bad) {
      problems.push(name + " 有 " + bad + " 个非 ASCII 字节");
    }
  });

  if (problems.length) {
    throw new Error(problems.join("\n  ")
      + "\n  → PowerShell 5.1 会按 GBK 解码而报语法错，"
      + "请把 .ps1 里的提示改成英文");
  }
});

test("一个 APK 集成主流国内厂商离线通道和 UPS", () => {
  const gradle = fs.readFileSync(path.join(HERE, "android", "app",
    "build.gradle"), "utf8");
  const required = [
    "com.getui.opt:hwp:", "com.getui.opt:xmp:", "com.assist-v3:oppo:",
    "com.assist-v3:vivo:", "com.getui.opt:honor:", "com.getui.opt:mzp:",
    "com.getui.opt:ups:",
  ];
  const missing = required.filter(artifact => gradle.indexOf(artifact) === -1);
  if (missing.length) {
    throw new Error("APK 缺少多厂商通道依赖：" + missing.join(", "));
  }

  const fn = fs.readFileSync(path.join(HERE, "supabase", "functions",
    "getui-task-event", "index.ts"), "utf8");
  if (!/strategy:\s*\{\s*default:\s*1\s*\}/.test(fn)) {
    throw new Error("个推策略必须为在线走个推、离线走厂商通道（default: 1）");
  }
  if (!/push_channel:\s*\{\s*android:\s*\{\s*ups:\s*\{\s*notification:/.test(fn)) {
    throw new Error("推送请求缺少 Android 厂商离线通知负载");
  }
});

test("推送渠道名：客户端建的和服务端请求的必须一致", () => {
  /* **这条来自一次真机实测。**

     推送全链路打通了、通知也收到了，**但不弹横幅**——
     只躺在通知栏里。

     查下来：云函数在推送负载里请求渠道 `task_messages`（级别 4），
     但客户端**从来没建过这个渠道**。厂商通道没配时个推走在线通道，
     不会去建它，于是通知落到个推默认渠道 `upush_default`——
     那个级别是 3，**不弹横幅**。

     修法：客户端主动建 `task_messages`。

     **这个 bug 的本质是"两个文件里的同一个字符串"**：
       云函数 index.ts     channel_id: "task_messages"
       客户端 notify.js    PUSH_CHANNEL_ID = "task_messages"

     差一个字符就静默退化回默认渠道，横幅消失而且不报错。
     所以这里把两个文件读出来**直接比对**，
     以后谁改了名字都会立刻被抓住。 */
  const fnPath = path.join(HERE, "supabase", "functions",
    "getui-task-event", "index.ts");
  const notifyPath = path.join(HERE, "notify.js");

  if (!fs.existsSync(fnPath) || !fs.existsSync(notifyPath)) {
    throw new Error("找不到云函数或 notify.js");
  }

  const fn = fs.readFileSync(fnPath, "utf8");
  const notify = fs.readFileSync(notifyPath, "utf8");

  /* 云函数请求的渠道。可能写成字面量，也可能引一个常量
     （`channel_id: PUSH_CHANNEL_ID`）——两种都要认。 */
  let inFunction = /channel_id:\s*"([^"]+)"/.exec(fn);
  if (!inFunction) {
    const ref = /channel_id:\s*([A-Z_][A-Z0-9_]*)/.exec(fn);
    if (ref) {
      const decl = new RegExp(ref[1] + '\\s*=\\s*"([^"]+)"').exec(fn);
      if (decl) inFunction = decl;
    }
  }
  if (!inFunction) {
    throw new Error("云函数里找不到 channel_id —— 推送会落到默认渠道");
  }

  /* **渠道要出现在两个下发布置里。**
     个推在线通道读 push_message.notification，
     厂商通道读 push_channel.android.ups。
     只写一处的话，走另一条路径时渠道设置被忽略，
     通知落到默认渠道——收到了但不弹横幅。 */
  const channelMentions = (fn.match(/(?:channel_id|PUSH_CHANNEL_ID)\s*[,:]/g) || []).length;
  if (channelMentions < 2) {
    throw new Error("云函数里渠道只配了 " + channelMentions
      + " 处 —— 在线通道和厂商通道**都要配**，"
      + "少一处就会落到默认渠道、不弹横幅");
  }

  /* 客户端建的渠道。
     它可能是字面量，也可能是**别名**（`PUSH_CHANNEL_ID = NOTIFY_CHANNEL_ID`）——
     后来改成复用本地通知那个已验证能弹横幅的渠道，就是别名形式。
     两种都要认，不然测试会误报"渠道没建"。 */
  let inClient = /PUSH_CHANNEL_ID\s*=\s*"([^"]+)"/.exec(notify);
  if (!inClient) {
    const alias = /PUSH_CHANNEL_ID\s*=\s*([A-Z_][A-Z0-9_]*)\s*;/.exec(notify);
    if (alias) {
      const target = new RegExp(alias[1] + '\\s*=\\s*"([^"]+)"').exec(notify);
      if (target) inClient = target;
    }
  }
  if (!inClient) {
    throw new Error("notify.js 里找不到 PUSH_CHANNEL_ID —— 渠道没建");
  }
  if (inFunction[1] !== inClient[1]) {
    throw new Error("渠道名对不上："
      + "云函数要 \"" + inFunction[1] + "\"，"
      + "客户端建的是 \"" + inClient[1] + "\""
      + "\n  → 名字不一致通知会落到默认渠道，**不弹横幅**");
  }

  /* 级别必须是 4，否则照样不弹。
     注意渠道的真实级别由**创建它的那段代码**决定：
     如果 PUSH_CHANNEL_ID 是别名，那要检查的是被指向的那个渠道。 */
  const owned = /const\s+([A-Z_][A-Z0-9_]*)\s*=\s*"([^"]+)"/g;
  let owner = null;
  let m;
  while ((m = owned.exec(notify)) !== null) {
    if (m[2] === inClient[1]) owner = m[1];
  }
  if (owner) {
    const at = notify.indexOf("id: " + owner);
    const block = at === -1 ? "" : notify.slice(at, at + 400);
    if (block && !/importance:\s*4/.test(block)) {
      throw new Error(owner + " 那个渠道的 importance 不是 4，不会弹横幅");
    }
  }
});

test("增量游标不能带裸 + 号（会被 URL 当成空格）", () => {
  /* **这条来自一次真实事故。**

     增量拉取写的是 `query.gte("updated_at", cursor.tasks)`。
     而 PostgreSQL 的 timestamptz 输出是

         2026-10-15T13:27:10+00:00

     拼进 query string 之后，**URL 里的 `+` 代表空格**，
     服务端收到 `2026-10-15T13:27:10 00:00`，直接 400：

         22007 invalid input syntax for type timestamp with time zone

     而拉取的写法是 `if (!error && data) { ... }` —— 报错被静默吞掉。
     结果：光标永远不前进、每次同步都拿 0 条、新任务永远不出现，
     而界面一直显示"已同步"。**卡了整整几天才被发现。**

     所以定两条规矩，都在这里检查：
       1. 每个 query.gte 的游标都必须过 cursorSafe
       2. cursorSafe 必须真的把 +00:00 换成 Z */
  const src = fs.readFileSync(path.join(HERE, "sync.js"), "utf8");

  /* 1. 所有 gte 的第二个参数都不许是裸 cursor.X */
  const offenders = [];
  src.split("\n").forEach((line, index) => {
    if (!/query\s*=\s*query\.gte\(/.test(line)) return;
    if (/cursorSafe\(/.test(line)) return;
    offenders.push((index + 1) + ": " + line.trim());
  });
  if (offenders.length) {
    throw new Error("这些 gte 直接用了游标，会被 `+` 坑：\n  "
      + offenders.join("\n  ")
      + "\n  → 改成 cursorSafe(cursor.X)");
  }

  /* 2. cursorSafe 必须存在且能处理 +00:00 */
  if (src.indexOf("function cursorSafe") === -1) {
    throw new Error("sync.js 里没有 cursorSafe");
  }
  const body = src.slice(src.indexOf("function cursorSafe"),
    src.indexOf("function cursorSafe") + 700);
  if (!/\+00:00/.test(body) || !/"Z"/.test(body)) {
    throw new Error("cursorSafe 没有把 +00:00 换成 Z");
  }
});

test("initCloud 必须幂等（否则多条 GoTrue 抢会话）", () => {
  /* **这条来自一次真事故。**

     initCloud() 原来每次调用都 createClient(...) 建新客户端，
     注释却写着「幂等」。我在两处让它被反复调用（boot 一次、
     Getui 重试循环里最多 8 次），结果真机日志刷满：

         Multiple GoTrueClient instances detected in the same browser

     多个实例抢同一个 storageKey（pr_auth_v1），认证状态互相覆盖：
     写请求被打成匿名、被 RLS 拒（push_devices 那条），
     更糟的是**同步整个挂住** —— lastSync 停在某个时刻不再前进，
     界面一直显示「同步中…」，新派的任务永远不出现。

     检查方式：函数体开头必须有「已经建过就直接返回」的短路。 */
  const src = fs.readFileSync(path.join(HERE, "sync.js"), "utf8");
  const at = src.indexOf("function initCloud()");
  if (at === -1) throw new Error("找不到 initCloud");
  const body = src.slice(at, at + 700);
  if (!/if \(cloudClient\) return true;/.test(body)) {
    throw new Error("initCloud 没有幂等保护 —— 每次调用都会新建客户端，"
      + "多条 GoTrue 实例会抢同一个会话并让同步挂住");
  }
});

test("没接受 / 已拒绝的任务不能被直接勾完成", () => {
  /* **这条来自一个真实的逻辑漏洞。**

     员工端卡片左侧那个圆圈（data-task-check）的处理函数直接调
     `completeTask(task)`，**完全不看 accept_status**。于是：

       · 刚派下来、还没接受的任务 → 点圆圈就能完成
       · 已经拒绝的任务           → 点圆圈还能完成

     接受流程就这么被绕过去了，老板收到的数据也不可信。

     修了两处：模板里不给渲染可点的圆圈 + 处理函数里兜底拦。
     这里把两处都钉住。 */
  const account = fs.readFileSync(path.join(HERE, "account.js"), "utf8");

  /* 1. 模板里对这两种状态不渲染 data-task-check */
  if (account.indexOf("aria-hidden=\"true\"") === -1) {
    throw new Error("模板里没有把「未接受/已拒绝」的勾选换成不可点的元素");
  }

  /* 2. 处理函数里必须有这两道拦截 */
  if (account.indexOf("if (taskPendingAccept(task))") === -1) {
    throw new Error("完成按钮没有拦「未接受」的任务");
  }
  if (account.indexOf("if (taskRejected(task))") === -1) {
    throw new Error("完成按钮没有拦「已拒绝」的任务");
  }
});

test("派任务页要在同步后自动刷新", () => {
  /* **这条来自真机实测。**

     老板打开「派任务」页等人回应，员工那边拒绝了任务，
     通知角标确实 +1，但**页面上的任务列表一动不动** ——
     必须退出这一页再进来才看得到。

     老板会以为员工没回应，或者以为自己派的没生效。

     修法：在渲染派任务页时挂一个同步监听，数据变了就重画。
     这里钉住"有没有挂这个监听"。 */
  const account = fs.readFileSync(path.join(HERE, "account.js"), "utf8");
  if (account.indexOf("onSyncChange(") === -1) {
    throw new Error("派任务页没有挂同步监听 —— 员工回应后老板看不到更新");
  }
  /* 挂在页面可见时才画，别在后台白费力气 */
  if (account.indexOf('page.classList.contains("hidden")') === -1) {
    throw new Error("同步监听没有判断页面是否可见");
  }
});

test("JS 里切换的选中态 class，CSS 里必须有对应样式", () => {
  /* **这条来自一个"看起来能点、其实没反应"的 bug。**

     登录页「我是老板 / 我是员工」点了没变化，两个按钮长得一样。
     查下去发现：JS 加的是 `.on`

         button.classList.toggle("on", ...)

     而 CSS 里只有 `.chip.solid`，**`.chip.on` 一条都没有**。
     `.on` 是空样式 → 选中的视觉反馈完全没有。

     同样的写法还用在通知开关那一排（含「接受/延期」），
     所以那些开关**开着关着长得一样**，用户根本不知道自己关了什么。

     这里做一条通用检查：只要 JS 里 toggle("x") 或 `" x"` 拼接
     在 chip/nav 上用到了，CSS 里就得有这个选择器。 */
  const css = fs.readFileSync(path.join(HERE, "style.css"), "utf8");

  /* 必须存在的选中态（按实际用法列举，新增时补进来） */
  const required = [
    { selector: ".chip.on", why: "登录页角色 / 通知开关 / 工作日" },
    { selector: ".chip.solid", why: "写死在模板里的实心 chip" },
    { selector: ".chip.wd.on", why: "工作日选择" },
    { selector: "nav button.on", why: "底部导航当前页" },
  ];

  const missing = required.filter(item => css.indexOf(item.selector) === -1);
  if (missing.length) {
    throw new Error("CSS 里缺这些选中态，选了也看不出来：\n  "
      + missing.map(m => m.selector + "（" + m.why + "）").join("\n  "));
  }

  /* 反向检查：chip 上用 " on" 拼接的地方，必须能被上面的规则覆盖 */
  const chipOnUsers = [];
  ["notify.js", "account.js", "community.js", "app.js"].forEach(file => {
    const src = fs.readFileSync(path.join(HERE, file), "utf8");
    if (/class="chip[^"]*\$\{[^}]*\? " on" : ""\}/.test(src)) {
      chipOnUsers.push(file);
    }
  });
  if (chipOnUsers.length && css.indexOf(".chip.on") === -1) {
    throw new Error("这些文件用了 chip 的 on 选中态，但 CSS 没有 .chip.on："
      + chipOnUsers.join(", "));
  }
});

test("实时订阅要有并发保护（否则同一通道重复订阅会报错）", () => {
  /* **这条来自一条一直挂在「我的」页上的错误。**

        订阅失败: cannot add `postgres_changes` callbacks for
        realtime:task-events-<uid> after `subscribe()`.

     不是用法写错，是**两次调用重叠**：subscribeRealtime 里有个
     `await getSession()` 的空档，第二次调用在这个空档里进来，
     前一次建的通道还没挂到 realtimeChannel 上，清理不掉；
     两者用同一个通道名，supabase-js 返回同一个 channel 对象，
     于是对已订阅的通道再 `.on()` → 抛错。

     修法是加"在飞"标记。这里钉住它还在。 */
  const src = fs.readFileSync(path.join(HERE, "sync.js"), "utf8");

  if (src.indexOf("realtimeInFlight") === -1) {
    throw new Error("subscribeRealtime 没有并发保护 —— 两次调用会撞同一个通道");
  }
  /* 真正的订阅逻辑要挪到 Once 里，否则保护是空的 */
  if (src.indexOf("async function subscribeRealtimeOnce") === -1) {
    throw new Error("没有把订阅逻辑拆到 subscribeRealtimeOnce");
  }
  /* 保护本身：有在飞就直接复用 */
  const at = src.indexOf("async function subscribeRealtime()");
  const body = src.slice(at, at + 400);
  if (!/if \(realtimeInFlight\) return realtimeInFlight;/.test(body)) {
    throw new Error("并发保护没写对：应该直接复用正在进行的那次");
  }
});

test("身份按钮只切换标签，登录不靠它", () => {
  /* **这段来自一次真实困惑。**

     老板忘了密码 → 重新注册 → 又忘 → 又注册，最后同一个
     号码下有五个账号，自己都不知道该用哪个。

     根因有三条，都在这条检查里钉住：
       1. 号不存在和密码错，报的是同一句"账号或密码不对"
       2. 注册时不拒绝重名，而是偷偷加 -2 -3 后缀建个新号
       3. 身份按钮如果参与登录判断，选错就成了"登不上"的陷阱

     关于 3：按钮**保留**（点了下面标签会在「账号 / 员工号」之间切换），
     但**不参与登录**——服务端自己查这个号对应哪个邮箱。
     所以点错了也照样能进。 */
  const sync = fs.readFileSync(path.join(HERE, "sync.js"), "utf8");
  const account = fs.readFileSync(path.join(HERE, "account.js"), "utf8");
  const html = fs.readFileSync(path.join(HERE, "index.html"), "utf8");

  /* 1. 身份按钮在，而且它在切换标签 */
  if (html.indexOf('id="login-role"') === -1) {
    throw new Error("登录页没有身份按钮了");
  }
  if (!/loginRole === "boss" \? "账号" : "员工号"/.test(account)) {
    throw new Error("点身份按钮没有切换标签（账号 / 员工号）");
  }

  /* 2. 但登录不能拿它当判断依据 */
  if (/cloudLogin\([^)]*loginRole/.test(account)) {
    throw new Error("doLogin 还在按选的身份登录 —— 选错就成了登不上的陷阱");
  }

  /* 3. 用 login_email（带密码核对）查邮箱

        **不能用 login_emails。** 那个函数不需要密码，
        必须开给匿名用户，等于谁都能把账号名换成真实邮箱。
        以前邮箱是假的 @boss.pr 无所谓，现在是真的 Gmail/QQ 地址。 */
  if (sync.indexOf('rpc("login_email",') === -1) {
    throw new Error("cloudLogin 没有用 login_email（带密码核对）查邮箱");
  }

  /* 3. 号不存在要说出来 */
  if (sync.indexOf("没有这个账号") === -1) {
    throw new Error("号不存在时没有明确提示 —— 用户会以为密码错了");
  }
  if (sync.indexOf("密码不对。") === -1) {
    throw new Error("密码错时没有明确提示");
  }

  /* 4. 重复注册要拒绝，不能偷偷改后缀 */
  if (sync.indexOf("code already registered") === -1) {
    throw new Error("没处理「这个号已经注册过」—— 会继续产生重复账号");
  }
  if (/v_suffix/.test(sync)) {
    throw new Error("客户端还留着自动加后缀的逻辑");
  }
});

test("忘记密码用邮箱验证码，不要旧密码", () => {
  /* 旧流程是「旧密码 + 新密码」—— 忘了密码还怎么填旧密码？
     这是把人锁在门外的死路，也是反复注册的第二个原因。 */
  const sync = fs.readFileSync(path.join(HERE, "sync.js"), "utf8");
  const account = fs.readFileSync(path.join(HERE, "account.js"), "utf8");

  if (sync.indexOf("async function sendResetCode") === -1) {
    throw new Error("没有 sendResetCode —— 发不了验证码");
  }
  if (sync.indexOf("async function verifyResetCode") === -1) {
    throw new Error("没有 verifyResetCode —— 验证码换不了会话");
  }
  if (sync.indexOf("signInWithOtp") === -1) {
    throw new Error("没有走 Supabase 的邮箱验证码");
  }
  /* 忘了密码的表单里不能还有"旧密码"这个输入框 */
  const at = account.indexOf("function openForgotPassword");
  const body = account.slice(at, at + 1600);
  if (body.indexOf("fp-old") !== -1) {
    throw new Error("忘了密码的表单里还有旧密码输入框");
  }
  if (body.indexOf("fp-email") === -1) {
    throw new Error("忘了密码的表单里没有邮箱输入框");
  }
});

test("注册必须填邮箱（找回密码的唯一出路）", () => {
  const sync = fs.readFileSync(path.join(HERE, "sync.js"), "utf8");
  const account = fs.readFileSync(path.join(HERE, "account.js"), "utf8");

  const at = sync.indexOf("async function registerBoss");
  const body = sync.slice(at, at + 1800);
  if (body.indexOf("data.email") === -1) {
    throw new Error("registerBoss 没有接收邮箱");
  }
  if (body.indexOf("p_email") === -1) {
    throw new Error("registerBoss 没有把邮箱传给服务端");
  }
  const form = account.slice(account.indexOf("function openBossRegister"),
    account.indexOf("function openBossRegister") + 1400);
  if (form.indexOf("rg-email") === -1) {
    throw new Error("注册表单里没有邮箱输入框");
  }
});

test("登录不能让匿名用户查到邮箱（隐私）", () => {
  /* **这是上一版留下的真实泄露。**

     login_emails(p_code) 不需要密码就能把账号名换成邮箱，
     为了登录能用，它必须 grant 给 anon ——
     而 anon key 是打包进 apk 的。

     以前所有邮箱都是假的 <账号>@boss.pr，泄露了也无所谓。
     这一轮开始账号绑的是**真实 Gmail / QQ 地址**，
     同一个漏洞的性质就完全变了：谁都能把手机号换成邮箱。

     现在用 login_email(p_code, p_password)，密码在数据库里
     用 bcrypt 比对，密码不对就什么都不返回。 */
  const file = path.join(HERE, "sql", "login-by-password.sql");
  if (!fs.existsSync(file)) {
    throw new Error("没有 sql/login-by-password.sql");
  }
  const sql = fs.readFileSync(file, "utf8");

  if (sql.indexOf("extensions.crypt") === -1) {
    throw new Error("login_email 没有在数据库里比对密码");
  }
  if (!/revoke all on function public\.login_email/.test(sql)) {
    throw new Error("login_email 没有先从 public 收回权限");
  }

  /* 纯 ASCII 规则同样适用 */
  const bad = [...fs.readFileSync(file)].filter(b => b > 127).length;
  if (bad > 0) {
    throw new Error("login-by-password.sql 有 " + bad + " 个非 ASCII 字节");
  }
});

test("SQL 里要有 login_emails / account_exists", () => {
  const file = path.join(HERE, "sql", "login-rework.sql");
  if (!fs.existsSync(file)) {
    throw new Error("没有 sql/login-rework.sql");
  }
  const sql = fs.readFileSync(file, "utf8");
  ["login_emails", "account_exists", "code already registered",
    "email already registered"].forEach(key => {
    if (sql.indexOf(key) === -1) {
      throw new Error("login-rework.sql 里缺：" + key);
    }
  });
  /* 纯 ASCII 规则同样适用 */
  const bytes = fs.readFileSync(file);
  const bad = [...bytes].filter(b => b > 127).length;
  if (bad > 0) {
    throw new Error("login-rework.sql 有 " + bad + " 个非 ASCII 字节");
  }
});

test("账号体系：统一叫账号、不许重名、每个账号绑邮箱", () => {
  /* **需求：把"手机号"改叫"账号"，重名一律拒绝，每个账号都要有邮箱。**

     为什么这三条要一起做：

       · 以前老板那边叫"手机号"、员工那边叫"工号"，其实是同一个东西。
         分开叫会让人以为填错了字段。
       · 老代码在服务端遇到重名会偷偷加 -2 后缀建新号，
         同一个号码能注册出五个账号，用户永远找不到该用哪个。
       · 没有真实邮箱就收不到验证码，忘了密码只能找管理员。 */
  const html = fs.readFileSync(path.join(HERE, "index.html"), "utf8");
  const account = fs.readFileSync(path.join(HERE, "account.js"), "utf8");
  const sync = fs.readFileSync(path.join(HERE, "sync.js"), "utf8");

  /* 1. 用词要分开：老板叫「账号」，员工叫「员工号」。
        不再出现「手机号」；也不再出现单独的「工号」（必须带「员」字）。 */
  const visible = html.split("\n").filter(line => {
    if (/^\s*<!--/.test(line)) return false;          /* HTML 注释 */
    if (/手机号/.test(line)) return true;
    /* 「员工号」是允许的；裸的「工号」不行 */
    return /(^|[^员])工号/.test(line);
  });
  if (visible.length) {
    throw new Error("界面上还有「手机号」或裸的「工号」：\n  "
      + visible.join("\n  "));
  }
  /* 两套叫法都得真的存在，别改着改着又合并成一个 */
  if (account.indexOf('loginRole === "boss" ? "账号" : "员工号"') === -1) {
    throw new Error("登录页没有按身份切换「账号 / 员工号」");
  }
  if (account.indexOf('isBoss ? "账号" : "员工号"') === -1) {
    throw new Error("「我的」页没有按身份切换叫法");
  }

  /* 2. 注册和建员工都必须收邮箱 */
  if (!/rg-email/.test(account)) {
    throw new Error("老板注册表单没有邮箱输入");
  }
  if (!/st-email/.test(account)) {
    throw new Error("新建员工表单没有邮箱输入");
  }
  if (sync.indexOf("请填邮箱（员工忘了密码时靠它收回验证码）") === -1) {
    throw new Error("建员工时没有强制要求邮箱");
  }

  /* 3. 重名要被拒绝，不能偷偷改号 */
  const sql = fs.readFileSync(path.join(HERE, "sql", "account-unique.sql"), "utf8");
  if (sql.indexOf("code already registered") === -1) {
    throw new Error("create_staff_account 没有拒绝重名");
  }
  /* **这条特别重要**：以前会把别人的员工直接划到自己名下 */
  if (sql.indexOf("v_owner = auth.uid()") === -1) {
    throw new Error("建员工时没有判断这个账号是不是自己的 —— 会抢别人的员工");
  }
  if (sql.indexOf("p_email") === -1) {
    throw new Error("create_staff_account 没有接邮箱参数");
  }
});

test("界面上绑定的每个处理函数都真的有定义", () => {
  /* **这条来自一次白屏事故。**

     我用脚本删「找回邮箱」那段代码时，删除范围算错，
     把紧挨着的 openChangeLogin 一起吞进了注释里。
     源码 `node --check` 照样通过（注释本身合法），
     但 App 一启动就：

         启动失败
         openChangeLogin is not defined
         at bindGlobalEvents (app.js:486)

     **整个 App 白屏**，而且语法检查一点问题都看不出来。

     所以这里做一条真正的静态检查：凡是 `onclick = 某个名字` 的，
     那个名字必须在某个文件里被定义过。 */
  const FILES = ["app.js", "account.js", "sync.js", "notify.js",
    "assist.js", "charts.js", "store.js", "identity.js", "today.js",
    "community.js", "execution.js"];

  const defined = new Set();
  FILES.forEach(file => {
    const text = fs.readFileSync(path.join(HERE, file), "utf8");
    /* 普通函数声明 */
    let m;
    const fnRe = /function\s+([A-Za-z_$][\w$]*)\s*\(/g;
    while ((m = fnRe.exec(text)) !== null) defined.add(m[1]);
    /* 箭头函数 / 函数表达式赋值 */
    const varRe = /(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*(?:async\s*)?(?:function|\(|[A-Za-z_$])/g;
    while ((m = varRe.exec(text)) !== null) defined.add(m[1]);
  });

  const missing = [];
  FILES.forEach(file => {
    const text = fs.readFileSync(path.join(HERE, file), "utf8");
    const useRe = /(?:onclick|onpointerdown)\s*=\s*([A-Za-z_$][\w$]*)\s*[;,)]/g;
    let m;
    while ((m = useRe.exec(text)) !== null) {
      const name = m[1];
      if (defined.has(name)) continue;
      if (missing.indexOf(name) === -1) missing.push(name);
    }
  });

  if (missing.length) {
    throw new Error("这些函数被绑成按钮处理器，但没有定义"
      + "（启动会直接白屏）：\n  " + missing.join("\n  "));
  }
});

test("绑了邮箱也必须能改（绑错了不能变成死路）", () => {
  /* **这条来自一个我刚引入的 bug。**

     邮箱那行原来只在"未绑定"时显示「绑定邮箱」按钮，
     一旦绑了真邮箱，按钮就永远消失。

     于是用户手滑填成 xxx@qq.con（少个 m），
     邮件全发到不存在的地址 → 忘了密码 → 再也进不来，
     而且界面上没有任何地方能改。

     跟"忘了密码要旧密码"是同一类死路，必须拦住。

     现在的规则：
       · 没绑 / 绑的是内部假地址 → 显示「绑定邮箱」大按钮
       · 已经绑了真邮箱         → 显示地址 + 一个「改邮箱」 */
  const app = fs.readFileSync(path.join(HERE, "app.js"), "utf8");

  if (app.indexOf("btn-me-bind-email") === -1) {
    throw new Error("没有「绑定邮箱」入口");
  }
  if (app.indexOf("btn-me-change-email") === -1) {
    throw new Error("绑了邮箱之后没有「改邮箱」入口 —— 绑错了就再也改不了");
  }
  /* 两个入口都要真的接上同一个处理函数 */
  const bindCount = (app.match(/= openChangeEmail/g) || []).length;
  if (bindCount < 2) {
    throw new Error("「绑定」和「改」没有都接到 openChangeEmail");
  }
});

test("图表不能被一条异常数据压扁", () => {
  /* 实测踩到：一条误填的 99999 小时工时把 Y 轴拉到 15 万，
     其他日子全贴在底线上，折线图形同虚设。

     修法是"稳健刻度"：用 P90 而不是最大值定上限，
     超出的点画的时候夹到顶部。 */
  const charts = fs.readFileSync(path.join(HERE, "charts.js"), "utf8");

  /* 判据必须是**物理上限**（一天 24 小时），不是分位数。
     我第一版用的是 P90，结果 14 天里只有一个非零值时，
     分位数也判不出谁是异常 —— 试了还是 15 万。 */
  if (charts.indexOf("HOURS_PER_DAY") === -1) {
    throw new Error("图表没有用「一天最多 24 小时」来定刻度");
  }
  if (!/rawMax > HOURS_PER_DAY/.test(charts)) {
    throw new Error("没有任何值超过 24 小时时也该走原逻辑，但代码里没有这个判断");
  }
  /* 超出上限的点必须夹住，否则会画到画布外面 */
  if (!/Math\.min\(num\(value\), maxValue\)/.test(charts)) {
    throw new Error("超上限的点没有夹到顶部，会画到图外面");
  }
  /* 摘要那行要说明有几天的数据离谱，不然被压平的峰看着像正常值。
     文案特意写短（"3 天超 24h"），长句会把标题挤成两行。 */
  const app = fs.readFileSync(path.join(HERE, "app.js"), "utf8");
  if (app.indexOf("天超 24h") === -1) {
    throw new Error("图表摘要没有提示「有几天超 24h」");
  }
});

test("邮箱要拦住明显的域名拼写错误", () => {
  /* 注册时不验证邮箱真实性（不然新账号登不进去），
     所以 xxx@qq.con 也能注册成功 —— 之后收不到任何信。

     完整的"发确认信再点链接"成本高，但域名拼错是绝大多数情况，
     拦下这几种就挡住了大部分事故。 */
  const sync = fs.readFileSync(path.join(HERE, "sync.js"), "utf8");

  if (sync.indexOf("function checkEmail") === -1) {
    throw new Error("没有 checkEmail —— 邮箱拼错也能注册");
  }
  ["qq.con", "gmial.com", "163.con"].forEach(typo => {
    if (sync.indexOf(typo) === -1) {
      throw new Error("没有拦截这个常见拼写错误：" + typo);
    }
  });
  /* 注册和绑邮箱都要走它 */
  const uses = (sync.match(/checkEmail\(/g) || []).length;
  if (uses < 4) {
    throw new Error("checkEmail 只接了 " + uses + " 处，注册/建员工/绑邮箱都要走");
  }
});

test("改邮箱不能依赖邮件确认（老账号的旧地址是死的）", () => {
  /* **这是一条真实的死路，比"绑错了改不了"更狠。**

     老账号的邮箱是 <账号>@boss.pr，那个域名不存在。
     Supabase 的 updateUser({email}) 在"安全邮箱更改"开启时要
     **新旧两个地址都点确认** —— 旧地址永远收不到。

     结果：改动永远卡在"待确认"，而且**最需要绑邮箱的那批人
     （全是老账号）正好绑不了**。

     现在改走服务端的 set_my_email，不涉及任何邮件。
     代价是不验证邮箱是否真实存在 —— 界面拦拼写 + 用户可以用
     「忘了密码」自证一次。 */
  const sync = fs.readFileSync(path.join(HERE, "sync.js"), "utf8");

  if (sync.indexOf('rpc("set_my_email"') === -1) {
    throw new Error("改邮箱还在走 updateUser —— 老账号会卡死在待确认");
  }
  if (/auth\.updateUser\(\s*\{\s*email/.test(sync)) {
    throw new Error("代码里还在用 updateUser 改邮箱");
  }

  const sql = fs.readFileSync(path.join(HERE, "sql", "set-my-email.sql"), "utf8");
  if (sql.indexOf("security definer") === -1) {
    throw new Error("set_my_email 不是 security definer，写不了 auth.users");
  }
  /* 只能改自己的 —— 身份必须来自 JWT，不能来自参数 */
  if (sql.indexOf("auth.uid()") === -1) {
    throw new Error("set_my_email 没有校验调用者身份");
  }
  if (!/where id = v_uid/.test(sql)) {
    throw new Error("set_my_email 没限定只改自己那一行");
  }
});

test("换邮箱 24 小时只能改一次（不用验证，但要防滥用）", () => {
  /* 不用邮件验证，是因为老账号的旧地址是死的（见上一条）。
     但"完全不管"也不行：
       · 会话被盗后可以反复把账号搬到别的邮箱
       · 手滑改错之后来回改，越改越乱

     24 小时冷却是个折中：手滑还能救（密码没变、照样登录），
     盗号也没法反复操作。 */
  const sql = fs.readFileSync(
    path.join(HERE, "sql", "email-change-cooldown.sql"), "utf8");

  if (sql.indexOf("email_changed_at") === -1) {
    throw new Error("没有记录改邮箱的时间，无法做冷却");
  }
  if (!/interval '24 hours'/.test(sql)) {
    throw new Error("set_my_email 里没有 24 小时冷却");
  }
  /* 必须真的拦住，而不是只记时间 */
  if (sql.indexOf("email change locked") === -1) {
    throw new Error("冷却时间没到也允许改 —— 等于没做限制");
  }
  /* 第一次绑定必须放行：老账号 email_changed_at 是 null */
  if (!/v_last is not null/.test(sql)) {
    throw new Error("冷却判断没排除「从没改过」的情况，老账号会绑不上");
  }

  /* 客户端要能把"还要等几小时"翻译成人话 */
  const sync = fs.readFileSync(path.join(HERE, "sync.js"), "utf8");
  if (sync.indexOf("24 小时只能改一次") === -1) {
    throw new Error("客户端没有把冷却提示翻成中文");
  }
});

test("邮箱以服务端资料为准，不用过期的 session 快照", () => {
  /* 实测踩到：邮箱在服务端已经改成 Gmail 了，
     「我的」页还原地写着"未绑定" —— 因为 profileFromUser 里
     `user.email`（登录那一刻的快照）排在前面，盖住了刚查回来的
     profiles 行。

     用户以为没改成功，会反复操作。 */
  const sync = fs.readFileSync(path.join(HERE, "sync.js"), "utf8");

  if (/email:\s*\(user && user\.email\)\s*\|\|/.test(sync)) {
    throw new Error("email 还在优先用 session 快照 —— 改完邮箱界面不会更新");
  }
  if (!/email:\s*\(extra && extra\.email\)\s*\|\|\s*\(user && user\.email\)/.test(sync)) {
    throw new Error("email 没有优先取 profiles 表里的值");
  }
});

test("建员工时的唯一性检查，变量不能接反", () => {
  /* **这里曾经接反过，后果很隐蔽。**

     SQL 写的是：
         select id, boss_id into v_owner, v_uid
     变量和内联的顺序错位，于是 v_owner 拿到账号 id、
     v_uid 拿到 boss_id。

     老板账号的 boss_id 是 null，所以 `if v_uid is not null`
     直接跳过整段唯一性检查 —— **一个老板账号能被同名的员工账号撞上**，
     两个账号共用同一个登录名。

     正确写法是 select boss_id, id into v_owner, v_uid。
     这种错编译期发现不了，跑起来也不报错，只能靠测试。 */
  const sql = fs.readFileSync(path.join(HERE, "sql", "account-unique.sql"), "utf8");

  if (!/select boss_id, id into v_owner, v_uid/.test(sql)) {
    throw new Error("唯一性检查的变量顺序不对（会漏掉老板账号）");
  }
  if (/select id, boss_id into v_owner, v_uid/.test(sql)) {
    throw new Error("唯一性检查的变量还是接反的");
  }
  /* 老板账号（boss_id 为 null）必须走到拒绝分支，不能被当成"自己的" */
  if (!/v_owner is not null and v_owner = auth\.uid\(\)/.test(sql)) {
    throw new Error("没有排除 boss_id 为空的老板账号，会误判成自己的员工");
  }
});

test("邮箱拼写检查不能误伤真实域名", () => {
  /* **这条来自一次真实的误伤。**

     第一版用"域名开头几个字母和常见服务商相同"来判断拼错，
     结果把两个真实域名拦掉了：

         sina.com.cn     ← 新浪真的用这个
         hotmail.co.uk   ← 微软真的用这个

     用户明明填对了，却被说"域名好像不对"，比不检查还糟。

     现在改成编辑距离，而且点数必须一致；阈值只能是 1，
     放到 2 时 foxmail.com（↔hotmail.com）和 me.com（↔qq.com）
     都会被误判。 */
  const sync = fs.readFileSync(path.join(HERE, "sync.js"), "utf8");

  if (!/function editDistance/.test(sync) && !/const editDistance =/.test(sync)) {
    throw new Error("没有用编辑距离，还在用「开头字母」这种粗糙判断");
  }
  if (/indexOf\(bare\) === 0/.test(sync)) {
    throw new Error("还在用「前缀相同就算拼错」，会误伤 sina.com.cn");
  }
  if (!/editDistance\(domain, provider\) <= 1/.test(sync)) {
    throw new Error("编辑距离阈值不是 1 —— 放到 2 会误伤 foxmail.com / me.com");
  }
  if (!/dotsOf\(domain\) !== dotsOf\(provider\)/.test(sync)) {
    throw new Error("没有比较点数，sina.com.cn 这类多级域名会被误伤");
  }
});

test("记忆源点：余额是流水求和，不是单独存的数", () => {
  /* 这是整个系统的算术地基。
     余额一旦单独存一份，就会和流水对不上，而且**查不出哪一步错的**。
     所以这里直接跑真代码，不是看文本。 */
  fresh();
  run(`
    DB.meritLedger = [
      { id: "a", profile_id: "p1", amount: 120, kind: "grade",
        reason: "任务「官网」S 级", created_at: "2026-11-01T10:00:00Z" },
      { id: "b", profile_id: "p1", amount: -50, kind: "redeem",
        reason: "兑换 下午茶", created_at: "2026-11-01T11:00:00Z" },
      { id: "c", profile_id: "p2", amount: 999, kind: "adjust",
        reason: "别人的", created_at: "2026-11-01T12:00:00Z" }
    ];
  `);

  const p1 = run('meritBalance("p1")');
  if (p1 !== 70) throw new Error("p1 余额应为 70（120-50），实际 " + p1);

  const p2 = run('meritBalance("p2")');
  if (p2 !== 999) throw new Error("p2 的流水不该串到 p1，实际 " + p2);

  /* 没有流水的人必须是 0，不能是 NaN */
  const nobody = run('meritBalance("p3")');
  if (nobody !== 0) throw new Error("没记录的人应该是 0，实际 " + nobody);

  /* 最新的排在前面 */
  const first = run('meritEntries("p1")[0].id');
  if (first !== "b") throw new Error("流水应按时间倒序，第一条应是 b，实际 " + first);

  /* 显示格式：千分位 + 正负号 */
  const big = run('meritNumber(1280)');
  if (big !== "1,280") throw new Error("千分位不对：" + big);
  if (run('meritSigned(120)') !== "+120") throw new Error("正数要带 +");
  if (run('meritSigned(-50)') !== "-50") throw new Error("负数要带 -");
});

test("记忆源点：名字只有一个来源，余额由流水算出来", () => {
  /* 第 1 步先钉三条规矩：

     1. 名字只能是常量。这个名字已经改过一次
        （功绩点 → 记忆源点），硬编码在界面里的字会残留，
        变成"一半新名一半旧名"。

     2. **余额不能存。** 只存流水，余额永远求和。
        两个都存就会出现余额和流水对不上，而且查不出哪一步错了。

     3. 汇率和评级倍率必须写在代码里，不能散落各处。 */
  const merit = fs.readFileSync(path.join(HERE, "merit.js"), "utf8");

  if (merit.indexOf('name: "记忆源点"') === -1) {
    throw new Error("merit.js 里的名字不是「记忆源点」");
  }
  if (merit.indexOf("hourRate: 10") === -1) {
    throw new Error("汇率（1 小时 = 10 源点）没写进常量");
  }
  ["S: 1.2", "A: 1.0", "B: 0.8", "C: 0"].forEach(pair => {
    if (merit.indexOf(pair) === -1) {
      throw new Error("评级倍率缺：" + pair);
    }
  });
  /* 余额必须是算出来的 */
  if (!/function meritBalance[\s\S]{0,200}reduce/.test(merit)) {
    throw new Error("meritBalance 不是用流水求和 —— 余额不许单独存");
  }

  /* 界面上不许出现旧名字 */
  const html = fs.readFileSync(path.join(HERE, "index.html"), "utf8");
  if (/功绩点/.test(html)) {
    throw new Error("index.html 里还有旧名字「功绩点」");
  }

  /* 建表脚本必须是纯 ASCII，这是这个项目的硬规矩 */
  const sql = fs.readFileSync(path.join(HERE, "sql", "merit-ledger.sql"));
  const bad = [...sql].filter(b => b > 127).length;
  if (bad > 0) {
    throw new Error("merit-ledger.sql 有 " + bad + " 个非 ASCII 字节");
  }
});

test("等级用累计赚到的算，花掉的不会降级", () => {
  /* 如果用余额算，员工一兑换就掉段 —— 越兑换越不想干，
     正好把激励做反了。所以等级看的是"总共赚过多少"。 */
  fresh();
  run(`
    DB.meritLedger = [
      { id: "a", profile_id: "p", amount: 120, created_at: "2026-11-01T10:00:00Z" },
      { id: "b", profile_id: "p", amount: -100, created_at: "2026-11-01T11:00:00Z" }
    ];
  `);

  const balance = run('meritBalance("p")');
  if (balance !== 20) throw new Error("余额应为 20，实际 " + balance);

  const lifetime = run('meritLifetime("p")');
  if (lifetime !== 120) throw new Error("累计应为 120（只算正数），实际 " + lifetime);

  const level = run('meritLevel("p")');
  if (level.current.name !== "白银") {
    throw new Error("累计 120 应该是白银，实际 " + level.current.name);
  }
  if (level.next.name !== "黄金" || level.toNext !== 180) {
    throw new Error("离黄金还差 180，实际 " + level.toNext);
  }

  /* 最高级之后没有下一级，不能算出负数 */
  run('DB.meritLedger = [{ id: "c", profile_id: "q", amount: 5000, created_at: "2026-11-01T10:00:00Z" }];');
  const top = run('meritLevel("q")');
  if (top.current.name !== "钻石" || top.next !== null || top.toNext !== 0) {
    throw new Error("5000 分应该是钻石且没有下一级");
  }
});

test("新功能：上工、商城、请假、看板都接好了", () => {
  /* 这几块是照着需求文档新加的，任何一处断开都会变成
     "按钮点了没反应"——那种问题在真机上很难查。 */
  const html = fs.readFileSync(path.join(HERE, "index.html"), "utf8");
  const app = fs.readFileSync(path.join(HERE, "app.js"), "utf8");
  const account = fs.readFileSync(path.join(HERE, "account.js"), "utf8");
  const css = fs.readFileSync(path.join(HERE, "style.css"), "utf8");

  /* 1. 元素都在 */
  ["work-card", "btn-work", "merit-level", "btn-shop",
    "team-card", "team-summary", "team-todo", "team-board",
    "btn-me-leave", "btn-me-rewards"].forEach(id => {
    if (html.indexOf('id="' + id + '"') === -1) {
      throw new Error("index.html 里缺元素 #" + id);
    }
  });

  /* 2. 按钮都绑了处理函数 */
  const useless = [];
  [
    ["btn-work", "toggleWork", app],
    ["btn-shop", "openShopSheet", app],
    ["btn-me-leave", "openLeaveSheet", app],
    ["btn-me-rewards", "openManageRewards", app],
  ].forEach(([id, fn, source]) => {
    if (source.indexOf('$("' + id + '").onclick = ' + fn) === -1) {
      useless.push(id + " → " + fn);
    }
  });
  if (useless.length) {
    throw new Error("这些按钮没绑定：" + useless.join("、"));
  }

  /* 3. 四个新函数真的定义了 */
  ["toggleWork", "openShopSheet", "openLeaveSheet",
    "openManageRewards", "renderWorkCard", "stopWorkTicker"].forEach(fn => {
    if (account.indexOf("function " + fn) === -1) {
      throw new Error("account.js 里没有 " + fn);
    }
  });
  if (app.indexOf("function renderTeamCard") === -1) {
    throw new Error("app.js 里没有 renderTeamCard");
  }

  /* 4. 计时器必须在离开页面时停掉，否则白耗电 */
  if (!/target !== "tasks"[\s\S]{0,120}stopWorkTicker/.test(app)) {
    throw new Error("离开任务页没有停掉走秒定时器");
  }

  /* 5. 汇率只有一个来源：merit.js 的 10，SQL 里也必须是 10 */
  const sql = fs.readFileSync(
    path.join(HERE, "sql", "work-session.sql"), "utf8");
  if (sql.indexOf("round(v_hours * 10)") === -1) {
    throw new Error("work-session.sql 里的汇率不是 10 — 和 merit.js 对不上");
  }

  /* 6. 新组件的样式得有 */
  ["work-timer", "shop-item", "grade-option", "todo-row"].forEach(name => {
    if (css.indexOf("." + name) === -1) {
      throw new Error("style.css 缺 ." + name);
    }
  });
});

test("样式表不能漏掉表单控件（下拉框曾经完全没样式）", () => {
  /* **重写样式表时漏了 <select>。**

     结果派任务页、记工时、习惯、项目编辑里的下拉框全是浏览器
     原生样式：又小又窄、带一圈灰硬边，和旁边的输入框完全不像
     一套东西。截图一眼就能看出来。

     这里把"必须被样式化的控件"列出来，漏一个就报错。 */
  const css = fs.readFileSync(path.join(HERE, "style.css"), "utf8");

  const mustStyle = [
    ["select", "下拉框"],
    ["input", "输入框"],
    ["textarea", "多行输入"],
    [".btn", "按钮"],
    [".chip", "小选项"],
  ];
  const missing = mustStyle
    .filter(([selector]) => css.indexOf("\n" + selector + " {") === -1
      && css.indexOf("\n" + selector + ",") === -1)
    .map(([, label]) => label);
  if (missing.length) {
    throw new Error("这些控件没有样式：" + missing.join("、"));
  }

  /* 下拉框必须去掉系统箭头，否则和自定义样式打架 */
  if (css.indexOf("appearance: none") === -1) {
    throw new Error("select 没有去掉系统默认外观");
  }

  /* 派任务页的员工下拉必须有"请选择"占位 ——
     否则 value 清空时 selectedIndex 变成 -1，看上去是空白的。 */
  const account = fs.readFileSync(path.join(HERE, "account.js"), "utf8");
  if (account.indexOf("请选择员工") === -1) {
    throw new Error("派任务页的员工下拉没有占位项，清空后是空白");
  }
});

test("底部导航不能压住页面内容", () => {
  /* 导航是 position:fixed 的，浮在所有页面上面。
     每个页面的 .body 都必须留出导航的高度，否则列表最后几条
     会被挡住 —— 助手页的输入框就是这么"消失"的。 */
  const css = fs.readFileSync(path.join(HERE, "style.css"), "utf8");

  /* 通用的底部留白必须作用于所有页面，而不是只有 .has-nav 的 */
  if (css.indexOf(".page .body {") === -1) {
    throw new Error("没有给所有页面统一留底部空间");
  }
  if (!/\.page \.body \{[\s\S]{0,120}var\(--nav-h\)/.test(css)) {
    throw new Error("底部留白没有用 --nav-h");
  }
  /* 助手页是 flex 三段式，自己也要留 */
  if (!/#page-assist \.body \{[\s\S]{0,200}var\(--nav-h\)/.test(css)) {
    throw new Error("助手页的 body 没留导航高度 —— 输入框会被盖住");
  }
});

test("源点流水不能重复记账，时间要按本地时区", () => {
  /* **这条是拿真机数据查出来的。**

     收工时客户端先在本地插一条 cash 流水（id 是 local-hours-xxx），
     服务端也写一条（id 是随机 uuid）。两边 id 不同 → 下一轮同步
     两条并存 → **同一次工作算了两遍钱**，余额直接翻倍。

     浏览器里看到的是：同一笔 +20 出现两次，时间一个 14:53
     一个 06:53（UTC 没转本地）。

     现在：客户端不插流水，服务端写完立刻拉一次。 */
  const sync = fs.readFileSync(path.join(HERE, "sync.js"), "utf8");

  if (/id:\s*"local-hours-/.test(sync)) {
    throw new Error("stopWork 还在本地插流水 —— 会和服务端那条重复");
  }
  if (/id:\s*"local-grade-/.test(sync)) {
    throw new Error("gradeTask 还在本地插流水 —— 会重复记账");
  }
  /* 两个 RPC 之后都要拉一次，否则界面要等 30 秒才更新 */
  const pulls = (sync.match(/await pullAll\(\)/g) || []).length;
  if (pulls < 2) {
    throw new Error("打完分 / 收完工没有立刻拉取，界面会滞后");
  }

  /* 时间必须走 Date 转本地，不能直接 slice */
  const merit = fs.readFileSync(path.join(HERE, "merit.js"), "utf8");
  if (!/function meritDayKey/.test(merit)) {
    throw new Error("没有 meritDayKey —— 日期比较会把 UTC 当本地");
  }
  if (/return text\.slice\(5, 10\)/.test(merit)) {
    throw new Error("meritTime 还在直接 slice 字符串，显示的是 UTC");
  }

  /* 历史遗留的本地流水要被清掉 */
  const store = fs.readFileSync(path.join(HERE, "store.js"), "utf8");
  if (store.indexOf('indexOf("local-") !== 0') === -1) {
    throw new Error("没有清理历史遗留的 local- 流水，余额会一直是错的");
  }
});

test("工时必须有上限（一次收工最多算一天）", () => {
  /* **这条也是"钱"的问题。**

     原来 end_work 算的是 (now - started_at)，**没有上限**。
     忘了收工、或者断网收不了工，隔三天再点结束：

         72 小时 → 720 源点

     一次就能刷出几百点，整个经济系统就废了。

     现在：单次封顶 24 小时；而且 start_work 遇到超过 24 小时的
     陈旧会话会把它关掉再开新的 —— 否则用户点开工永远是
     "already working"，人被锁死在门外。 */
  const sql = fs.readFileSync(
    path.join(HERE, "sql", "work-session-cap.sql"), "utf8");

  if (!/if v_hours > 24 then/.test(sql)) {
    throw new Error("end_work 没有把时长封顶到 24 小时");
  }
  if (sql.indexOf("'capped'") === -1) {
    throw new Error("end_work 没告诉客户端被截断了，用户会莫名其妙少算");
  }
  /* 陈旧会话要能自救 */
  if (!/v_hours <= 24 then[\s\S]{0,120}already working/.test(sql)) {
    throw new Error("start_work 没区分陈旧会话和正在工作中");
  }
  if (sql.indexOf("'closed_stale'") === -1) {
    throw new Error("start_work 没有自动关闭陈旧会话");
  }

  /* 客户端要把这件事说出来 */
  const account = fs.readFileSync(path.join(HERE, "account.js"), "utf8");
  if (account.indexOf("是不是忘了收工") === -1) {
    throw new Error("跨天未收工没有提示");
  }
  if (account.indexOf("按 24 小时算") === -1) {
    throw new Error("被截断时没有告诉用户");
  }

  /* 纯 ASCII 规矩 */
  const bad = [...fs.readFileSync(
    path.join(HERE, "sql", "work-session-cap.sql"))].filter(b => b > 127).length;
  if (bad > 0) {
    throw new Error("work-session-cap.sql 有 " + bad + " 个非 ASCII 字节");
  }
});

test("推送设备登记：换过账号的机器不能卡在 RLS 上", () => {
  /* **真机上踩到的：**

     「后台推送没登记上：写库失败：new row violates row-level security
       policy (USING expression) for table "push_devices"」

     原因：客户端直接 upsert + onConflict "cid"。cid 是唯一键，而
     这台手机换过账号 —— 那一行还挂在**上一个账号**名下。upsert 于是
     走 UPDATE 分支，可 RLS 只允许改自己的行，必然报错。

     结果：这台机器永远登记不上，推送发到旧地址，手机一声不响。

     现在改成调 register_push_device：它会把这条 CID 收回来
     （删旧插新），一台设备同时只属于一个人。 */
  const sqlPath = path.join(HERE, "sql", "push-device-rpc.sql");
  if (!fs.existsSync(sqlPath)) {
    throw new Error("没有 sql/push-device-rpc.sql");
  }
  const sql = fs.readFileSync(sqlPath, "utf8");

  if (!/create or replace function public\.register_push_device/.test(sql)) {
    throw new Error("没有 register_push_device 函数");
  }
  if (!/delete from public\.push_devices where cid = v_cid/.test(sql)) {
    throw new Error("函数没有先删掉旧记录 —— 换账号还是会撞 RLS");
  }

  const notify = fs.readFileSync(path.join(HERE, "notify.js"), "utf8");
  /* 先把注释剥掉再查 —— 注释里会提到旧写法
     （"原来这里是 upsert(..., onConflict: cid)"），
     不剥的话自检会误判成"还在用旧写法"。 */
  const code = notify
    .replace(/\/\*[\s\S]*?\*\//g, "")
    .replace(/^\s*\/\/.*$/gm, "");

  if (/onConflict:\s*"cid"/.test(code)) {
    throw new Error("还在直接 upsert push_devices —— 换过账号的机器会登记失败");
  }
  if (code.indexOf('rpc("register_push_device"') === -1) {
    throw new Error("没有走 register_push_device");
  }
});

test("验收按计时器量出来的实际时长算钱，预估只作参考", () => {
  /* 用户要求："以计时器的时间为准，老板设置的只作为参考。"

     原来 grade_task 用的是 est_hours —— 老板填的预估。
     实际做了 4 小时、预估写了 2 小时，就只发 20 分，
     干得多拿得少，激励整个是反的。

     现在：从 task_logs 的 started_at → finished_at 算实际时长。
     没有计时记录（老任务）才回退到预估。 */
  const sql = fs.readFileSync(
    path.join(HERE, "sql", "task-grade-actual.sql"), "utf8");

  if (sql.indexOf("from public.task_logs") === -1) {
    throw new Error("grade_task 没有读任务的实际计时记录");
  }
  if (!/'source'/.test(sql)) {
    throw new Error("没有返回 source —— 界面分不清是按实际还是按预估算的");
  }
  /* 封顶仍然要在 */
  if (!/least\(greatest\(v_hours, 0\), 24\)/.test(sql)) {
    throw new Error("实际时长没有夹到 0~24 小时");
  }

  /* 客户端预览要和服务端口径一致，否则老板看到的数字和实际发的不一样 */
  const merit = fs.readFileSync(path.join(HERE, "merit.js"), "utf8");
  if (merit.indexOf("function taskActualHours") === -1) {
    throw new Error("客户端没有 taskActualHours —— 预览会用预估算");
  }
  if (!/function taskBaseMerit[\s\S]{0,320}taskActualHours/.test(merit)) {
    throw new Error("taskBaseMerit 没有优先用实际时长");
  }

  /* 接受了就自动开始计时 */
  const account = fs.readFileSync(path.join(HERE, "account.js"), "utf8");
  if (!/setTaskAccept\(id, true[\s\S]{0,260}startTask\(id\)/.test(account)) {
    throw new Error("接受任务后没有自动开始计时");
  }
});

test("记住账号：登录成功才存、能删、注销时清掉", () => {
  /* 需求：登录过的账号，在登录页点一下就进去。

     这个功能会**在本机存密码**（"点一下直接登录"必须有凭证），
     所以几条底线必须钉死，不然就是个安全隐患：
       1. 只在登录成功之后才存 —— 存错了密码等于永远登不上
       2. 每条都能单独删掉 —— 换手机 / 借人用时要能清
       3. 注销账号时一并清掉 —— 账号都没了还留着密码
       4. 有上限，别把登录页撑成一长串 */
  const account = fs.readFileSync(path.join(HERE, "account.js"), "utf8");
  const store = fs.readFileSync(path.join(HERE, "store.js"), "utf8");

  if (store.indexOf("savedAccounts: []") === -1) {
    throw new Error("store.js 里没有 savedAccounts 这个本地结构");
  }
  if (account.indexOf("function rememberAccount(") === -1) {
    throw new Error("没有 rememberAccount");
  }
  if (account.indexOf("function forgetAccount(") === -1) {
    throw new Error("没有 forgetAccount —— 保存的账号删不掉");
  }

  /* 1. 记住必须发生在登录成功之后 */
  const loginAt = account.indexOf("async function doLogin()");
  const body = account.slice(loginAt, loginAt + 2000);
  const rememberAt = body.indexOf("rememberAccount(");
  const finishAt = body.indexOf("finishLogin()");
  if (rememberAt === -1) {
    throw new Error("doLogin 里没有记住账号");
  }
  if (finishAt !== -1 && rememberAt > finishAt) {
    throw new Error("rememberAccount 写在 finishLogin 之后了，位置不对");
  }
  /* 记住要用服务端返回的身份，不能用按钮选的那个 */
  if (body.indexOf("profile.role") === -1) {
    throw new Error("记住账号时没用 profile.role（选错身份会把错的存下来）");
  }

  /* 2. 注销时必须清掉 */
  const delAt = account.indexOf("async function submitDeleteAccount()");
  const delBody = account.slice(delAt, delAt + 1400);
  if (delBody.indexOf("forgetAccount(") === -1) {
    throw new Error("注销账号时没有清掉保存的密码");
  }

  /* 3. 有上限 */
  if (!/SAVED_ACCOUNT_LIMIT\s*=\s*\d+/.test(account)) {
    throw new Error("保存的账号数量没有上限");
  }

  /* 4. 登录页要有那块容器 */
  const html = fs.readFileSync(path.join(HERE, "index.html"), "utf8");
  if (html.indexOf('id="login-saved"') === -1) {
    throw new Error("index.html 里没有 #login-saved 容器");
  }
});

/* ---- 任务接受 / 申请延期 ---- */

test("接受/延期：客户端调的 RPC 在 SQL 里都有", () => {
  /* **这一类和"推送渠道名"是同一个坑。**

     客户端 `callTaskRpc("accept_task", ...)`，服务端要是有
     `create function accept_task` —— 名字差一个字母，运行时就是
     "Could not find the function"，而不是编译错误。

     所以把两边读出来直接比对，写代码时就挡住。 */
  /* 每新增一个带 task RPC 的 sql 文件，都要登记到这里。 */
  const sqlFiles = [
    "task-accept-extension.sql",
    "task-grade.sql",
    "work-session.sql",
    "rewards-leave.sql",
  ];
  sqlFiles.forEach(name => {
    if (!fs.existsSync(path.join(HERE, "sql", name))) {
      throw new Error("sql/" + name + " 不见了");
    }
  });

  const sql = sqlFiles
    .map(name => fs.readFileSync(path.join(HERE, "sql", name), "utf8"))
    .join("\n");
  const sync = fs.readFileSync(path.join(HERE, "sync.js"), "utf8");

  const called = [...sync.matchAll(/callTaskRpc\("([a-z_]+)"/g)]
    .map(m => m[1]);
  if (!called.length) {
    throw new Error("sync.js 里没有 callTaskRpc 调用 —— 功能没接上");
  }

  const defined = [...sql.matchAll(
    /create or replace function public\.([a-z_]+)\(/g)].map(m => m[1]);

  const missing = called.filter(name => defined.indexOf(name) === -1);
  if (missing.length) {
    throw new Error("这些 RPC 客户端在调、SQL 里却没有："
      + missing.join("、")
      + "\n  → 运行时会报 Could not find the function");
  }
});

test("接受/延期：SQL 写的事件类型客户端都认得", () => {
  /* SQL 里 insert into task_events 的 kind，必须能被
     notify.js 的 describeEvent 认出来。

     **不认的 kind 会被静默丢掉**：老板永远收不到"员工不接受"
     这条通知，而且没有任何报错。 */
  const sql = fs.readFileSync(
    path.join(HERE, "sql", "task-accept-extension.sql"), "utf8");
  const notify = fs.readFileSync(path.join(HERE, "notify.js"), "utf8");

  const kinds = [...new Set(
    [...sql.matchAll(/'(rejected|extend|extend_ok|extend_no)'/g)]
      .map(m => m[1]))];

  if (!kinds.length) {
    throw new Error("SQL 里没找到事件类型 —— 检查是不是漏了 insert");
  }

  kinds.forEach(kind => {
    if (notify.indexOf('kind === "' + kind + '"') === -1) {
      throw new Error("describeEvent 里没有处理 " + kind
        + " —— 这类通知会被静默丢掉");
    }
  });
});

test("接受/延期：界面上每个按钮都绑了处理函数", () => {
  /* 画了按钮但没绑 onclick —— 点了没反应，
     是这类功能最常见也最难发现的漏。 */
  const account = fs.readFileSync(path.join(HERE, "account.js"), "utf8");
  const pairs = [
    ["data-task-accept", "dataset.taskAccept"],
    ["data-task-reject", "dataset.taskReject"],
    ["data-task-extend", "dataset.taskExtend"],
    ["data-ext-yes", "dataset.extYes"],
    ["data-ext-no", "dataset.extNo"],
  ];
  pairs.forEach(([attr, handler]) => {
    if (account.indexOf(attr) === -1) {
      throw new Error("界面上没有 " + attr + " 按钮");
    }
    if (account.indexOf(handler) === -1) {
      throw new Error(attr + " 按钮没有绑处理函数（点了没反应）");
    }
  });
});

/* ---- 图表 ---- */
test("charts.js 里的每个绘图函数都被 app.js 用上了", () => {
  /* 这就是这次出问题的原因：drawTrend / drawBars / drawTimeline
     都写好了，但 app.js 里**一次都没调用**，界面上就只剩下
     一张负荷图。用户问"折线柱状图去哪了"才发现。

     静态检查：charts.js 里定义的每个 drawXxx，app.js 里必须出现。 */
  const charts = fs.readFileSync(path.join(HERE, "charts.js"), "utf8");
  const app = fs.readFileSync(path.join(HERE, "app.js"), "utf8");

  const defined = matchAll(charts, /^function (draw\w+)/gm);
  if (defined.length < 3) {
    throw new Error("charts.js 里只解析出 " + defined.length + " 个绘图函数，"
      + "正则可能失效了");
  }

  const unused = defined.filter(name =>
    !new RegExp("\\b" + name + "\\s*\\(").test(app));
  if (unused.length) {
    throw new Error("这些绘图函数定义了但没被调用："
      + unused.join("、") + "（界面上看不到对应的图）");
  }
});

test("每个 drawXxx 调用都能对上 canvas 元素", () => {
  /* 调用绘图函数前必须先拿到 canvas。canvas 是写在 index.html 里的
     （静态的）或渲染时生成的（动态的）。
     静态的那些：检查 id 在 index.html 里存在；
     动态的：检查 app.js 里确实生成了对应的 <canvas>。 */
  const app = fs.readFileSync(path.join(HERE, "app.js"), "utf8");
  const html = fs.readFileSync(path.join(HERE, "index.html"), "utf8");

  /* 找 $("xxx") 这种 canvas 引用的写法，去重 */
  const found = matchAll(app, /\$\("([a-z-]*chart[a-z-]*)"\)/g);
  const canvasIds = found.filter((id, index) => found.indexOf(id) === index);
  if (!canvasIds.length) throw new Error("app.js 里没找到任何 canvas 引用");

  canvasIds.forEach(id => {
    const inHtml = html.indexOf(`id="${id}"`) !== -1;
    /* 动态生成的：app.js 里得有 id="..." 的 canvas 标签 */
    const inJs = app.indexOf(`id="${id}"`) !== -1;
    if (!inHtml && !inJs) {
      throw new Error(`canvas "${id}" 在 index.html 和 app.js 里都找不到，`
        + "绘图时会拿到 null 然后报错");
    }
  });
});

/* ---- 界面接线：JS 绑定的元素必须在 HTML 里存在 ---- */
test("app.js 和 account.js 绑定的元素 id 都在 index.html 里", () => {
  /* **这是最容易崩的一类错误**：bindGlobalEvents() 在启动时就跑，
     里面写 `$("btn-xxx").onclick = ...`。如果那个 id 在 HTML 里
     不存在，`$()` 返回 null，取 .onclick 直接抛 TypeError——
     **整个 App 打不开**，而手机上只能看到白屏。

     这个检查把"JS 里出现的 id"和"HTML 里定义的 id"对一遍。
     动态生成的元素（在 JS 里用 id="..." 写的）也算数。 */
  const html = fs.readFileSync(path.join(HERE, "index.html"), "utf8");
  const app = fs.readFileSync(path.join(HERE, "app.js"), "utf8");
  const account = fs.readFileSync(path.join(HERE, "account.js"), "utf8");
  const community = fs.readFileSync(path.join(HERE, "community.js"), "utf8");

  /* HTML 里定义的 id */
  const inHtml = matchAll(html, /id="([^"]+)"/g);
  /* JS 里动态生成的 id（模板字符串里写的） */
  const inJs = matchAll(app, /id="([^"]+)"/g)
    .concat(matchAll(account, /id="([^"]+)"/g))
    .concat(matchAll(community, /id="([^"]+)"/g));
  /* JS 里查的 id。只认 $("...") —— 这是本项目的取元素约定。 */
  const today = fs.readFileSync(path.join(HERE, "today.js"), "utf8");
  const queried = matchAll(app, /\$\("([^"]+)"\)/g)
    .concat(matchAll(account, /\$\("([^"]+)"\)/g))
    .concat(matchAll(community, /\$\("([^"]+)"\)/g))
    .concat(matchAll(today, /\$\("([^"]+)"\)/g));

  const known = inHtml.concat(inJs);
  const missing = queried.filter(id => known.indexOf(id) === -1);
  const unique = missing.filter((id, index) => missing.indexOf(id) === index);

  if (unique.length) {
    throw new Error("这些元素在 JS 里被取用，但 HTML 里没有——"
      + "启动时会抛 TypeError，App 直接打不开：\n  "
      + unique.join("\n  "));
  }
  if (queried.length < 30) {
    throw new Error("只解析出 " + queried.length + " 个 $() 调用，"
      + "数量太少，正则可能失效了（这会漏掉真正的错误）");
  }
});

test("每个页面都有渲染入口", () => {
  /* 加了新页面却忘了在 PAGES 里登记、或者忘了写 render 调用，
     表现是"点了导航没反应"或"页面一片空白"。 */
  const app = fs.readFileSync(path.join(HERE, "app.js"), "utf8");
  const html = fs.readFileSync(path.join(HERE, "index.html"), "utf8");

  const pages = matchAll(app, /const PAGES = \[([\s\S]*?)\];/g);
  if (!pages.length) throw new Error("找不到 PAGES 定义");
  const names = matchAll("[" + pages[0] + "]", /"([^"]+)"/g);
  if (names.length < 5) throw new Error("PAGES 只解析出 " + names.length + " 项");

  /* 每个名字都要有对应的 section */
  const sectionIds = matchAll(html, /id="page-([^"]+)"/g);
  const noSection = names.filter(name => sectionIds.indexOf(name) === -1);
  if (noSection.length) {
    throw new Error("PAGES 里有这些页面，但 index.html 里没有对应的 "
      + "section：\n  " + noSection.join("\n  "));
  }
});

/* ---- 全局名撞车（最阴的一类错误） ---- */
test("没有重名声明会撞掉库暴露的全局量", () => {
  /* **这个检查来自一次真实事故**：

     vendor/supabase.js 这个库把自己暴露成全局 `supabase`。
     而 sync.js 里我写了 `let supabase = null;` 想存客户端实例。

     结果：`SyntaxError: Identifier 'supabase' has already been declared`
     ——**整个 sync.js 一行都不执行**，所有函数变成 undefined，
     启动时报 "syncStatus is not defined"，App 直接白屏。

     这种错 commit 前看不出来：单独看 sync.js 语法完全正确，
     只有把它和库放一起加载才会炸。

     做法：扫描每个源文件，找"顶层声明了某个库全局名"的情况。
     在 node 里模拟不出来（没有真库），所以只能静态查。 */
  const LIB_GLOBALS = [
    "supabase",     // @supabase/supabase-js
    "Capacitor",    // Capacitor 原生桥
    "cordova",      // Cordova
  ];
  const files = ["store.js", "calc.js", "charts.js", "merit.js", "assist.js",
                 "sync.js", "notify.js", "identity.js", "today.js",
                 "execution.js", "account.js", "community.js", "app.js"];
  const problems = [];

  files.forEach(name => {
    const source = fs.readFileSync(path.join(HERE, name), "utf8");
    /* 只查顶层声明（行首不缩进），函数体内的局部变量不冲突 */
    LIB_GLOBALS.forEach(global_ => {
      const pattern = new RegExp(
        "^\\s*(?:let|const|var|class|function)\\s+" + global_ + "\\b", "m");
      if (pattern.test(source)) {
        problems.push(`${name} 顶层声明了 ${global_}，会和库的全局量撞车`);
      }
    });
  });

  if (problems.length) {
    throw new Error(problems.join("\n")
      + "\n（撞车会让那个文件整个不执行，表现为启动白屏）");
  }
});

test("每个源文件都能单独执行且不重复声明", () => {
  /* 上面那条查的是"和库撞车"。这条查"文件之间互相撞车"——
     两个文件都 `let x` 也会让后一个整个不执行。

     做法：把 7 个文件依次在**同一个**上下文里执行一遍。
     有重复声明的话这里会抛 SyntaxError。 */
  const context = makeContext();
  const files = ["store.js", "calc.js", "charts.js", "merit.js", "assist.js",
                 "sync.js", "notify.js", "identity.js", "today.js",
                 "execution.js", "account.js", "community.js"];
  files.forEach(name => {
    const source = fs.readFileSync(path.join(HERE, name), "utf8");
    try {
      vm.runInContext(source, context, { filename: name });
    } catch (error) {
      throw new Error(`${name} 加载失败：${error.message}`);
    }
  });

  /* 关键函数真的存在吗 */
  const expect = {
    "store.js": ["loadAll", "allWorklogs", "queueChange", "todayHabitRows"],
    "calc.js": ["fetchWorklogs", "loadRows", "predict", "insights"],
    "charts.js": ["drawTrend", "drawBars", "drawTimeline", "drawLoad"],
    "assist.js": ["ask", "urgentSuggestions"],
    "sync.js": ["syncStatus", "cloudLogin", "completeTask", "assignTask",
                "startSyncLoop"],
    /* renderMe 在 app.js 里（它属于页面路由），不在这里 */
    "identity.js": ["identityCan", "identityHasAdvancedAccess"],
    "today.js": ["renderToday", "refreshPointState", "setMobileUiMode",
                 "unlockKnowledgePost"],
    "account.js": ["renderLogin", "renderTasks", "renderStaff",
                   "openStaffMenu", "syncStaffAccounts", "applyRoleUI"],
    "community.js": ["renderCommunity", "loadCommunityPosts",
                     "submitCommunityPost", "deleteCommunityPost"],
    "execution.js": ["renderExecution", "loadExecution", "bindExecution",
                     "executionRpc"],
  };
  Object.keys(expect).forEach(file => {
    expect[file].forEach(fn => {
      const type = vm.runInContext("typeof " + fn, context);
      if (type !== "function") {
        throw new Error(`${file} 里的 ${fn} 没有定义（typeof = ${type}）`
          + "——这个文件可能一行都没执行");
      }
    });
  });
});

/* ---- 不该引用测试专用函数 ---- */
test("源码里没有引用只在自检中存在的函数", () => {
  /* **这条来自一次真实事故**：`plain()` 是我写在 selfcheck.js 里的
     辅助函数（把跨 realm 的对象转成本 realm 的普通对象），
     结果在 account.js 里也用了它。

     node 里看不出问题（自检自己有 plain），但浏览器里没有这个函数
     —— 启动时 "plain is not defined"，App 白屏。

     静态检查：源码里出现这些名字就是错。 */
  /* **test 不在列表里**：它太常见了——`/re/.test(x)` 是标准用法，
     放进来会误报一堆。 */
  const TEST_ONLY = ["plain", "matchAll", "fresh", "makeContext",
                     "COMPILED", "CASES"];
  const files = ["store.js", "calc.js", "charts.js", "merit.js", "assist.js",
                 "sync.js", "account.js", "community.js", "app.js"];
  const problems = [];

  files.forEach(name => {
    const source = fs.readFileSync(path.join(HERE, name), "utf8");
    /* 先剥掉注释，否则注释里提到这些名字会误报 */
    const code = source.replace(/\/\*[\s\S]*?\*\//g, "")
                       .replace(/\/\/[^\n]*/g, "");
    TEST_ONLY.forEach(fn => {
      const pattern = new RegExp("\\b" + fn + "\\s*\\(");
      if (pattern.test(code)) {
        problems.push(`${name} 里调用了 ${fn}()，但它只在 selfcheck.js 里定义`);
      }
    });
  });

  if (problems.length) {
    throw new Error(problems.join("\n")
      + "\n（浏览器里没有这些函数，启动就会白屏）");
  }
});

test("每个页面都有入口（不能只能靠代码跳）", () => {
  /* **这条来自一次真实事故**：page-staff（员工账号）和
     page-assign（派任务）两个页面都写好了、按钮也绑了，
     但**没有任何地方能跳过去** —— 老板打开 App 根本找不到建号功能，
     反馈是"老板没有创号功能"。

     页面和入口必须一起加。这里检查每个 PAGES 里的页面
     至少能被某种方式到达：

       · 底部导航按钮（data-page="xxx"）
       · 某个按钮的 data-back="xxx"（返回按钮）
       · 代码里有 showPage("xxx") 调用
       · 「更多」面板里的入口数组（["xxx", "名称"]）
       · 登录页是特例（启动时直接进） */
  const app = fs.readFileSync(path.join(HERE, "app.js"), "utf8");
  const account = fs.readFileSync(path.join(HERE, "account.js"), "utf8");
  const html = fs.readFileSync(path.join(HERE, "index.html"), "utf8");
  const allCode = app + account;

  const pagesBlock = app.match(/const PAGES = \[([\s\S]*?)\];/);
  if (!pagesBlock) throw new Error("找不到 PAGES 定义");
  const pages = matchAll("[" + pagesBlock[1] + "]", /"([^"]+)"/g)
    .filter(name => name !== "login");   // 登录页由 boot() 直接进入

  const unreachable = [];
  pages.forEach(name => {
    const viaNav = html.indexOf(`data-page="${name}"`) !== -1;
    const viaBack = html.indexOf(`data-back="${name}"`) !== -1;
    /* showPage("name") 或 showPage('name') 的调用 */
    const viaCode = new RegExp(
      "showPage\\(\\s*[\"']" + name + "[\"']").test(allCode);
    const viaMore = new RegExp(
      "\\[\"" + name + "\",\\s*\"").test(allCode);
    if (!viaNav && !viaBack && !viaCode && !viaMore) {
      unreachable.push(name);
    }
  });

  if (unreachable.length) {
    throw new Error("这些页面没有入口，用户点不进去："
      + unreachable.join("、")
      + "\n（要加底部导航按钮、data-back 返回按钮，"
      + "或者代码里的 showPage 跳转）");
  }
});

/* ---- 头像 ---- */
test("app.js 里引用的每个头像文件都存在", () => {
  /* 头像文件名写错的话**不会报错**，只是那个位置空一块——
     手机上表现为"某个表情显示不出来"，很难定位。
     所以这里把 app.js 里 AVATARS 的值抠出来，逐个查文件。 */
  const source = fs.readFileSync(path.join(HERE, "app.js"), "utf8");
  const block = source.match(/const AVATARS = \{[\s\S]*?\};/);
  if (!block) throw new Error("app.js 里找不到 AVATARS 定义");

  const names = matchAll(block[0], /:\s*"([^"]+)"/g);
  if (names.length < 5) {
    throw new Error("AVATARS 只解析出 " + names.length + " 项，正则可能失效了");
  }

  const missing = [];
  names.forEach(name => {
    [`${name}.webp`, `${name}@hero.webp`].forEach(file => {
      if (!fs.existsSync(path.join(HERE, "icons", file))) {
        missing.push("icons/" + file);
      }
    });
  });
  if (missing.length) {
    throw new Error("缺这些头像文件（先跑 py prepare-avatars.py）：\n"
      + missing.join("\n"));
  }
});

test("build-www.js 的头像清单和实际文件对得上", () => {
  /* build-www.js 里另有一份表情名字清单（用来检查文件是否齐全）。
     两份清单如果不同步，打包时就会漏文件或者报假错。 */
  const build = fs.readFileSync(path.join(HERE, "build-www.js"), "utf8");
  const app = fs.readFileSync(path.join(HERE, "app.js"), "utf8");

  const appBlock = app.match(/const AVATARS = \{[\s\S]*?\};/)[0];
  const appNames = matchAll(appBlock, /:\s*"([^"]+)"/g);

  const buildBlock = build.match(/const MOODS = \[[\s\S]*?\];/);
  if (!buildBlock) throw new Error("build-www.js 里找不到 MOODS 定义");
  const buildNames = matchAll(buildBlock[0], /"([^"]+)"/g);

  const onlyApp = appNames.filter(name => buildNames.indexOf(name) === -1);
  const onlyBuild = buildNames.filter(name => appNames.indexOf(name) === -1);
  if (onlyApp.length || onlyBuild.length) {
    throw new Error("两份清单不一致——"
      + (onlyApp.length ? "app.js 多：" + onlyApp.join("、") + " " : "")
      + (onlyBuild.length ? "build-www.js 多：" + onlyBuild.join("、") : ""));
  }
});

test("星轨陪伴：16 张表情和星空界面完整接入", () => {
  const app = fs.readFileSync(path.join(HERE, "app.js"), "utf8");
  const block = app.match(/const STAR_STICKERS = \[[\s\S]*?\];/);
  if (!block) throw new Error("app.js 缺少 STAR_STICKERS");
  const files = matchAll(block[0], /file:\s*"([^"]+)"/g);
  if (files.length !== 16) throw new Error("星轨表情应当正好 16 张，实际 " + files.length);
  files.forEach(file => {
    [`${file}.webp`, `${file}@face.webp`].forEach(name => {
      if (!fs.existsSync(path.join(HERE, "icons", "star", name))) {
        throw new Error("缺少星轨表情 " + name);
      }
    });
  });
  const html = fs.readFileSync(path.join(HERE, "index.html"), "utf8");
  for (const text of ['class="star-sky"', 'id="star-companion"']) {
    if (!html.includes(text)) throw new Error("index.html 缺少 " + text);
  }
  if (!app.includes("renderStarCompanion")) throw new Error("缺少星轨渲染入口");
  const build = fs.readFileSync(path.join(HERE, "build-www.js"), "utf8");
  if (!build.includes("prepare-star-stickers.py")) {
    throw new Error("打包脚本没有检查星轨表情");
  }
});

test("小助手按回答内容挑表情", () => {
  fresh();
  /* moodForAnswer 在 app.js 里（要用到 faceSrc），而 app.js 依赖 DOM，
     所以这里只测关键词规则本身——把函数体抠出来在沙盒里跑。 */
  const source = fs.readFileSync(path.join(HERE, "app.js"), "utf8");
  const body = source.match(/function moodForAnswer[\s\S]*?\n\}/);
  if (!body) throw new Error("找不到 moodForAnswer 函数");
  vm.runInContext(body[0], ctx, { filename: "moodForAnswer" });

  const cases = [
    ["这个项目已经严重超期了", "alarm"],
    ["预算超支，风险很大", "warn"],
    ["我没理解这个问题，换个问法", "puzzled"],
    ["所有项目都健康正常", "happy"],
    ["建议先把这个步骤拆开", "warm"],
    ["一共 3 个人", "ok"],
  ];
  cases.forEach(([answer, expected]) => {
    const got = run(`moodForAnswer(${JSON.stringify(answer)})`);
    if (got !== expected) {
      throw new Error(`「${answer}」应当是 ${expected}，实际 ${got}`);
    }
  });
});

test("每种情绪都有对应的头像", () => {
  fresh();
  /* dashboardMood 和 moodForAnswer 返回的情绪名，
     必须在 AVATARS 里都有——少一个就是空白头像。 */
  const source = fs.readFileSync(path.join(HERE, "app.js"), "utf8");
  const block = source.match(/const AVATARS = \{[\s\S]*?\};/)[0];
  const keys = matchAll(block, /(\w+)\s*:\s*"[^"]+"/g);

  /* 代码里会用到的情绪（来自 dashboardMood 和 moodForAnswer） */
  const used = ["sleepy", "alarm", "warn", "happy", "puzzled", "warm", "ok",
                "neutral", "watch"];
  const missing = used.filter(key => keys.indexOf(key) === -1);
  if (missing.length) {
    throw new Error("AVATARS 里缺少这些情绪：" + missing.join("、"));
  }
});

/* ---- 界面不得残留已删功能的引用 ---- */
test("源码里不再引用已删除的计时函数", () => {
  /* 计时功能整块去掉了。如果哪里还留着 getSession / renderTimer
     之类的调用，运行到那一行就会 ReferenceError——
     而这种错在手机上只表现为「点某个按钮没反应」。
     所以在这里静态扫一遍：这些名字**不该再出现在代码里**。

     注意要**先剥掉注释再扫**：注释里会提到这些名字
     （比如说明「这些函数已经删了」），不剥的话会误报。
     按「跳过 * 开头的行」是不行的——块注释的中间行不以 * 开头。 */
  const banned = ["nowMono", "sessionElapsed", "setSession",
                  "getSession", "clearSession", "renderTimer",
                  "timerStart", "timerPause", "timerFinish",
                  "timerDrop", "tickTimer", "showTimerHistory"];
  ["store.js", "calc.js", "assist.js"].forEach(name => {
    const raw = fs.readFileSync(path.join(HERE, name), "utf8");
    const code = raw.replace(/\/\*[\s\S]*?\*\//g, "")
                    .replace(/\/\/[^\n]*/g, "");
    banned.forEach(word => {
      const pattern = new RegExp("\\b" + word + "\\b");
      if (pattern.test(code)) {
        throw new Error(`${name} 的代码里还在用已删除的 ${word}`);
      }
    });
  });
});

/* ---- 主题 ---- */
test("两套主题的配色都齐全", () => {
  fresh();
  const keys = ["bg", "panel", "read", "fg", "fgStrong", "fgSoft", "fgDim",
                "fgFaint", "line", "lineSoft", "accent", "accentDim",
                "accentWash", "accentEdge", "hover", "track"];
  ["light", "dark"].forEach(name => {
    const palette = run(`THEME_COLORS[${JSON.stringify(name)}]`);
    if (!palette) throw new Error("缺少 " + name + " 主题");
    keys.forEach(key => {
      const value = palette[key];
      if (typeof value !== "string" || !/^#[0-9a-fA-F]{6}$/.test(value)) {
        throw new Error(`${name} 主题的 ${key} 不是合法颜色：${value}`);
      }
    });
    if (!Array.isArray(palette.series) || palette.series.length < 4) {
      throw new Error(name + " 主题的序列色不够用");
    }
    ["健康", "关注", "风险", "严重"].forEach(level => {
      if (!palette.levels[level]) {
        throw new Error(`${name} 主题缺少风险等级配色：${level}`);
      }
    });
  });
});

test("两套主题的颜色值不相同", () => {
  fresh();
  /* 防呆：如果深色主题是浅色的复制粘贴，那切主题看起来「没反应」 */
  const light = plain(run("THEME_COLORS.light"));
  const dark = plain(run("THEME_COLORS.dark"));
  ["bg", "panel", "fg", "fgStrong"].forEach(key => {
    if (light[key] === dark[key]) {
      throw new Error(`${key} 在浅色和深色里是同一个值（${light[key]}），`
        + "切主题会看不出变化");
    }
  });
});

test("深色主题的背景确实比文字深", () => {
  fresh();
  /* 用亮度粗判：背景必须比正文暗，否则是「浅色主题」不是深色 */
  const brightness = hex => {
    const value = hex.replace("#", "");
    const r = parseInt(value.slice(0, 2), 16);
    const g = parseInt(value.slice(2, 4), 16);
    const b = parseInt(value.slice(4, 6), 16);
    return 0.299 * r + 0.587 * g + 0.114 * b;
  };
  const dark = plain(run("THEME_COLORS.dark"));
  if (brightness(dark.bg) >= brightness(dark.fg)) {
    throw new Error("深色主题里背景不比文字暗，看起来会是反的");
  }
  const light = plain(run("THEME_COLORS.light"));
  if (brightness(light.bg) <= brightness(light.fg)) {
    throw new Error("浅色主题里背景不比文字亮，看起来会是反的");
  }
});


test("企业治理：今日工位存在", () => {
  const html = fs.readFileSync(path.join(HERE, "index.html"), "utf8");
  for (const id of [
    "page-today", "today-task-list", "btn-mode-toggle",
    "identity-board", "identity-point-state",
    "community-unlock-cost", "community-required",
  ]) {
    if (html.indexOf(`id="${id}"`) === -1) throw new Error(`缺少 ${id}`);
  }
  for (const script of ["today.js", "identity.js"]) {
    const loaded = new RegExp(`src="${script.replace(".", "\\.")}(?:\\?[^"]*)?"`).test(html);
    if (!loaded) {
      throw new Error(`index.html 没有加载 ${script}`);
    }
  }

  const app = fs.readFileSync(path.join(HERE, "app.js"), "utf8");
  if (!/const PAGES = \[[\s\S]*?"today"/.test(app)) {
    throw new Error("PAGES 没有登记 today");
  }
  if (app.indexOf('target === "today"') === -1
      || app.indexOf("renderToday();") === -1) {
    throw new Error("showPage() 没有 renderToday 入口");
  }

  const build = fs.readFileSync(path.join(HERE, "build-www.js"), "utf8");
  if (!/"today\.js"/.test(build)) throw new Error("build-www.js 没有打包 today.js");

  const today = fs.readFileSync(path.join(HERE, "today.js"), "utf8");
  for (const fn of ["renderToday", "refreshPointState", "setMobileUiMode",
                    "unlockKnowledgePost"]) {
    if (today.indexOf(`function ${fn}`) === -1) {
      throw new Error(`today.js 缺少 ${fn}`);
    }
  }

  const identity = fs.readFileSync(path.join(HERE, "identity.js"), "utf8");
  for (const fn of [
    "renderIdentityBoard", "openBoardPointMotion", "openChairAward",
    "identityBoardVote", "identityBoardFinalize",
  ]) {
    if (identity.indexOf(`function ${fn}`) === -1) {
      throw new Error(`identity.js 缺少 ${fn}`);
    }
  }
  if (identity.indexOf("propose_enterprise_share_change") === -1
      || identity.indexOf("set_enterprise_shareholder") !== -1) {
    throw new Error("股份调整必须走股东表决，不能直接改股份");
  }
  if (identity.indexOf("已披露利益冲突") === -1) {
    throw new Error("治理提案没有展示利益冲突披露");
  }

  const community = fs.readFileSync(path.join(HERE, "community.js"), "utf8");
  if (community.indexOf("unlock_cost") === -1
      || community.indexOf("data-community-unlock") === -1
      || community.indexOf("list_knowledge_posts") === -1
      || community.indexOf("p_unlock_cost") === -1) {
    throw new Error("知识星球没有完成付费知识发现、发布和解锁");
  }
});

test("社区 v2.1：板块、评论、通知和审核完整接线", () => {
  const community = fs.readFileSync(path.join(HERE, "community.js"), "utf8");
  const markup = fs.readFileSync(path.join(HERE, "index.html"), "utf8");
  for (const marker of [
    "get_community_boards", "list_community_posts_v2",
    "get_community_author_cards", "get_community_post", "add_community_comment",
    "toggle_community_like", "toggle_community_bookmark",
    "report_community_content", "get_community_notifications",
    "create_community_board", "moderate_community_post",
    "community-board-select", "community-notifications-panel",
  ]) {
    if (!community.includes(marker) && !markup.includes(marker)) {
      throw new Error("社区 v2.1 缺少接线：" + marker);
    }
  }
});

test("组织股权：创始人、1.1 权重和解散规则完整接线", () => {
  const identity = fs.readFileSync(path.join(HERE, "identity.js"), "utf8");
  const markup = fs.readFileSync(path.join(HERE, "index.html"), "utf8");
  for (const marker of [
    "get_organization_state", "create_organization",
    "propose_initial_split", "cast_equity_vote",
    "share_transfer", "employee_pool", "dissolution",
    "identity-organization",
  ]) {
    if (!identity.includes(marker) && !markup.includes(marker)) {
      throw new Error("组织股权缺少接线：" + marker);
    }
  }
});

test("组织管理：改名、添加成员和股份板块完整接线", () => {
  const identity = fs.readFileSync(path.join(HERE, "identity.js"), "utf8");
  const app = fs.readFileSync(path.join(HERE, "app.js"), "utf8");
  const sql = fs.readFileSync(path.join(HERE, "sql", "organization-management-v1.sql"), "utf8");
  for (const marker of [
    "rename_organization", "add_organization_member",
    "btn-org-rename", "btn-org-invite-member", "老板号", "openShareDashboard",
  ]) {
    if (!identity.includes(marker) && !app.includes(marker)) {
      throw new Error("组织管理缺少接线：" + marker);
    }
  }
  for (const marker of [
    "rename_organization", "add_organization_member",
    "security definer", "organization.renamed", "organization.member_added",
  ]) {
    if (!sql.toLowerCase().includes(marker)) {
      throw new Error("组织管理 SQL 缺少：" + marker);
    }
  }
  if (!app.includes('["shares", "股份"]')) throw new Error("更多菜单缺少股份板块");
});

test("阶段一：主公司、公司邀请、今日四块和版本检查完整接线", () => {
  const html = fs.readFileSync(path.join(HERE, "index.html"), "utf8");
  for (const id of [
    "today-task-list", "today-pending-list", "today-working", "today-company-feed",
    "app-update-card", "btn-check-update",
  ]) {
    if (html.indexOf(`id="${id}"`) === -1) throw new Error(`缺少 ${id}`);
  }
  for (const id of ["page-companies", "my-company-invites", "my-company-primary", "my-company-list", "my-company-people"]) {
    if (html.indexOf(`id="${id}"`) === -1) throw new Error(`缺少 ${id}`);
  }
  const identity = fs.readFileSync(path.join(HERE, "identity.js"), "utf8");
  for (const marker of [
    "get_primary_company", "set_primary_company",
    "invite_organization_member", "respond_organization_member_invite",
    "btn-org-primary", "btn-org-invite-member",
  ]) {
    if (identity.indexOf(marker) === -1) throw new Error(`主公司/邀请缺少 ${marker}`);
  }
  const update = fs.readFileSync(path.join(HERE, "update.js"), "utf8");
  if (update.indexOf("latest.json") === -1 || update.indexOf("versionCode") === -1) {
    throw new Error("版本检查没有接上 latest.json");
  }
  const companies = fs.readFileSync(path.join(HERE, "companies.js"), "utf8");
  for (const marker of ["get_my_companies", "get_company_people", "get_organization_member_invites", "respond_organization_member_invite", "myCompanyInvitesHtml", "data-company-primary", "data-my-company-invite-accept"]) {
    if (companies.indexOf(marker) === -1) throw new Error(`我的公司缺少 ${marker}`);
  }
  const companiesSql = fs.readFileSync(
    path.join(HERE, "sql", "phase1-my-companies-v1.sql"), "utf8");
  for (const marker of ["get_my_companies", "get_company_people", "can_view_sensitive"]) {
    if (companiesSql.indexOf(marker) === -1) throw new Error(`我的公司 SQL 缺少 ${marker}`);
  }
  const sql = fs.readFileSync(
    path.join(HERE, "sql", "phase1-primary-company-member-invites-v1.sql"), "utf8");
  for (const marker of [
    "primary_enterprise_id", "organization_member_invites",
    "invite_organization_member", "respond_organization_member_invite",
  ]) {
    if (sql.indexOf(marker) === -1) throw new Error(`阶段一 SQL 缺少 ${marker}`);
  }
  const pkg = JSON.parse(fs.readFileSync(path.join(HERE, "package.json"), "utf8"));
  if (!/node bump-version\.js/.test(pkg.scripts.apk || "")) {
    throw new Error("APK 构建没有自动递增版本");
  }
});

test("企业治理：积分与模式有本地缓存", () => {
  fresh();
  if (run("DB.uiMode") !== "simple") throw new Error("uiMode 默认应为 simple");
  if (run("DB.pointState.balance") !== 0) throw new Error("积分默认应为 0");
  if (run("Array.isArray(DB.pointState.ledger)") !== true) {
    throw new Error("pointState.ledger 默认应为数组");
  }
});

test("股东大会：月度会议、临时会议和请假完整接线", () => {
  const html = fs.readFileSync(path.join(HERE, "index.html"), "utf8");
  for (const id of ["identity-meetings", "identity-meeting-count"]) {
    if (html.indexOf(`id="${id}"`) === -1) throw new Error(`缺少 ${id}`);
  }
  if (!/src="meeting\.js(?:\?[^"]*)?"/.test(html)) throw new Error("没有加载 meeting.js");
  const app = fs.readFileSync(path.join(HERE, "app.js"), "utf8");
  if (app.indexOf("loadShareholderMeetings") === -1) throw new Error("app.js 没有加载股东大会");
  const identity = fs.readFileSync(path.join(HERE, "identity.js"), "utf8");
  if (identity.indexOf("loadShareholderMeetings") === -1) throw new Error("identity.js 没有刷新股东大会");
  const meeting = fs.readFileSync(path.join(HERE, "meeting.js"), "utf8");
  for (const text of [
    "get_shareholder_meetings", "initiate_shareholder_meeting",
    "vote_shareholder_meeting", "record_shareholder_meeting_attendance_verified",
    "complete_shareholder_meeting", "请假必须填写原因", "账号验证",
    "data-meeting-vote", "data-meeting-attend", "identity-meetings",
  ]) {
    if (meeting.indexOf(text) === -1) throw new Error(`meeting.js 缺少 ${text}`);
  }
  const verifySql = fs.readFileSync(
    path.join(HERE, "sql", "shareholder-meeting-verification-v1.sql"), "utf8");
  for (const text of [
    "record_shareholder_meeting_attendance_verified",
    "p_verification_code", "identity verification failed",
    "revoke execute on function public.record_shareholder_meeting_attendance",
  ]) {
    if (verifySql.indexOf(text) === -1) throw new Error(`出席验证 SQL 缺少 ${text}`);
  }
  const build = fs.readFileSync(path.join(HERE, "build-www.js"), "utf8");
  if (!/"meeting\.js"/.test(build)) throw new Error("build-www.js 没有打包 meeting.js");
});

test("决策中心：手机管理审批页完整接线", () => {
  const html = fs.readFileSync(path.join(HERE, "index.html"), "utf8");
  for (const id of [
    "page-decisions", "decision-list", "approval-list",
    "decision-summary", "btn-decisions-refresh",
  ]) {
    if (html.indexOf(`id="${id}"`) === -1) throw new Error(`缺少 ${id}`);
  }
  if (html.indexOf('data-page="decisions"') === -1) {
    throw new Error("高级导航缺少经营决策入口");
  }
  if (html.indexOf('src="decision.js"') === -1) {
    throw new Error("index.html 没有加载 decision.js");
  }

  const app = fs.readFileSync(path.join(HERE, "app.js"), "utf8");
  if (!/const PAGES = \[[\s\S]*?"decisions"/.test(app)) {
    throw new Error("PAGES 没有登记 decisions");
  }
  if (app.indexOf('target === "decisions"') === -1
      || app.indexOf("loadDecisionCenter(true);") === -1) {
    throw new Error("showPage() 没有加载决策中心");
  }
  if (app.indexOf("bindDecisionCenter()") === -1) {
    throw new Error("app.js 没有绑定决策中心事件");
  }

  const today = fs.readFileSync(path.join(HERE, "today.js"), "utf8");
  if (today.indexOf('return management ? "decisions" : "dash";') === -1) {
    throw new Error("高级管理模式没有默认进入决策中心");
  }

  const account = fs.readFileSync(path.join(HERE, "account.js"), "utf8");
  if (account.indexOf('"decisions"') === -1
      || account.indexOf("loadDecisionCenter") === -1) {
    throw new Error("账号登录/同步没有刷新决策中心");
  }

  const build = fs.readFileSync(path.join(HERE, "build-www.js"), "utf8");
  if (!/"decision\.js"/.test(build)) {
    throw new Error("build-www.js 没有打包 decision.js");
  }

  const decision = fs.readFileSync(path.join(HERE, "decision.js"), "utf8");
  for (const text of [
    "renderDecisionCenter", "loadDecisionCenter", "bindDecisionCenter",
    "act_on_decision", "act_on_approval", "data-decision-action",
    "data-approval-action", "evidence", "impact_days", "impact_amount",
    "owner_name", "due_at", "actions", "idempotency",
  ]) {
    if (decision.indexOf(text) === -1) {
      throw new Error(`decision.js 缺少 ${text}`);
    }
  }
});
test("经营摘要：管理页、能力缺口和个人绩效依据完整接线", () => {
  const html = fs.readFileSync(path.join(HERE, "index.html"), "utf8");
  for (const id of [
    "page-operations", "operations-projects", "operations-capacity",
    "operations-performance", "operations-worklog", "btn-operations-refresh",
    "nav-operations", "btn-my-performance", "my-performance",
  ]) {
    if (html.indexOf(`id="${id}"`) === -1) throw new Error(`缺少 ${id}`);
  }
  if (html.indexOf('data-page="operations"') === -1) {
    throw new Error("高级导航缺少经营摘要入口");
  }
  if (!/src="operations\.js(?:\?[^"]*)?"/.test(html)) {
    throw new Error("index.html 没有加载 operations.js");
  }

  const app = fs.readFileSync(path.join(HERE, "app.js"), "utf8");
  if (!/const PAGES = \[[\s\S]*?"operations"/.test(app)) {
    throw new Error("PAGES 没有登记 operations");
  }
  for (const text of [
    'target === "operations"', "renderOperations()", "loadOperations(true)",
    "w-billable", "w-overtime", "w-kind", "w-rework", "w-waiting",
    "w-travel", "syncWorklogDimensions",
  ]) {
    if (app.indexOf(text) === -1) throw new Error(`app.js 缺少 ${text}`);
  }

  const account = fs.readFileSync(path.join(HERE, "account.js"), "utf8");
  for (const text of ["operations", "nav-operations", "loadOperations"]) {
    if (account.indexOf(text) === -1) {
      throw new Error(`account.js 缺少 ${text}`);
    }
  }

  const build = fs.readFileSync(path.join(HERE, "build-www.js"), "utf8");
  if (!/"operations\.js"/.test(build)) {
    throw new Error("build-www.js 没有打包 operations.js");
  }

  const operations = fs.readFileSync(
    path.join(HERE, "operations.js"), "utf8");
  for (const text of [
    "renderOperations", "loadOperations", "bindOperations",
    "get_operations_dashboard", "capacity_gaps", "projected_margin",
    "collection_gap", "worklog_summary", "performance",
    "renderMyPerformance", "loadMyPerformanceEvidence",
    "get_my_performance_evidence", "submit_performance_statement",
    "upsert_worklog_dimensions", "queueWorklogDimensions",
    "resolveQueuedWorklogDimensions", "operationsAllowedInCurrentMode",
    "queueLocalWorklogMigration", "ensureLocalWorklogMigrationQueues",
    "worklogMigrationPayload", "completeWorklogMigration",
    "clearOperationsCache", "get_worklog_dimensions",
    "upsert_profile_skill", "upsert_capacity_demand",
    "upsert_performance_evidence", "operationsRpc",
  ]) {
    if (operations.indexOf(text) === -1) {
      throw new Error(`operations.js 缺少 ${text}`);
    }
  }
});
test("执行追踪：手机验收、交接、变更完整接线", () => {
  const html = fs.readFileSync(path.join(HERE, "index.html"), "utf8");
  for (const id of [
    "page-execution", "execution-acceptance", "execution-dependencies",
    "execution-handoffs", "execution-changes", "btn-execution-refresh",
    "btn-execution-dependency", "nav-execution",
  ]) {
    if (html.indexOf(`id="${id}"`) === -1) throw new Error(`缺少 ${id}`);
  }
  if (html.indexOf('data-page="execution"') === -1) {
    throw new Error("导航缺少执行追踪入口");
  }
  if (html.indexOf('src="execution.js"') === -1) {
    throw new Error("index.html 没有加载 execution.js");
  }
  const app = fs.readFileSync(path.join(HERE, "app.js"), "utf8");
  for (const text of [
    '"execution"', 'target === "execution"', "renderExecution()",
    "loadExecution(true)", "bindExecution()",
  ]) {
    if (app.indexOf(text) === -1) throw new Error(`app.js 缺少 ${text}`);
  }
  const account = fs.readFileSync(path.join(HERE, "account.js"), "utf8");
  for (const text of ["execution", "nav-execution", "loadExecution"]) {
    if (account.indexOf(text) === -1) throw new Error(`account.js 缺少 ${text}`);
  }
  const build = fs.readFileSync(path.join(HERE, "build-www.js"), "utf8");
  if (!/"execution\.js"/.test(build)) {
    throw new Error("build-www.js 没有打包 execution.js");
  }
  const executionPath = path.join(HERE, "execution.js");
  if (!fs.existsSync(executionPath)) {
    throw new Error("缺少 execution.js");
  }
  const execution = fs.readFileSync(executionPath, "utf8");
  for (const text of [
    "renderExecution", "loadExecution", "bindExecution", "executionRpc",
    "get_execution_board", "review_task_acceptance",
    "accept_task_handoff", "decide_change_request",
    "create_change_request", "submit_task_acceptance",
    "upsert_task_dependency", "delete_task_dependency",
    "openDependencyCreate", "data-execution-action", "execution-allowed",
  ]) {
    if (execution.indexOf(text) === -1) {
      throw new Error(`execution.js 缺少 ${text}`);
    }
  }
  const store = fs.readFileSync(path.join(HERE, "store.js"), "utf8");
  if (store.indexOf("execution:") === -1) {
    throw new Error("store.js 缺少 execution 缓存");
  }
});

test("工作入口：手机快速记录、公开表单和分诊完整接线", () => {
  const html = fs.readFileSync(path.join(HERE, "index.html"), "utf8");
  for (const id of [
    "page-intake", "intake-summary", "intake-requests", "intake-mine",
    "intake-forms", "btn-intake-quick", "btn-intake-form", "btn-intake-refresh",
    "btn-intake-settings", "btn-intake-email", "intake-email-aliases",
  ]) {
    if (html.indexOf(`id="${id}"`) === -1) throw new Error(`缺少 ${id}`);
  }
  if (html.indexOf('data-page="intake"') === -1) {
    throw new Error("导航缺少工作入口");
  }
  if (html.indexOf('src="intake.js"') === -1) {
    throw new Error("index.html 没有加载 intake.js");
  }
  if (html.indexOf('src="vendor/qrcode.min.js"') === -1) {
    throw new Error("index.html 没有加载二维码组件");
  }
  const app = fs.readFileSync(path.join(HERE, "app.js"), "utf8");
  for (const text of [
    '"intake"', 'target === "intake"', "renderIntake()",
    "loadIntake(true)", "bindIntake()",
  ]) {
    if (app.indexOf(text) === -1) throw new Error(`app.js 缺少 ${text}`);
  }
  const build = fs.readFileSync(path.join(HERE, "build-www.js"), "utf8");
  for (const text of ['"intake.js"', '"intake.html"', '"public-intake.js"', '"qrcode.min.js"']) {
    if (build.indexOf(text) === -1) throw new Error(`build-www.js 缺少 ${text}`);
  }
  const intake = fs.readFileSync(path.join(HERE, "intake.js"), "utf8");
  for (const text of [
    "renderIntake", "loadIntake", "bindIntake", "intakeRpc",
    "get_my_intake_requests", "get_intake_board", "create_intake_request",
    "create_intake_form", "triage_intake_request", "convert_intake_request",
    "merge_intake_request", "add_intake_message", "intakeShowQr", "openIntakeSettings",
    "create_intake_email_alias", "openIntakeEmailAlias",
    "data-intake-action",
  ]) {
    if (intake.indexOf(text) === -1) throw new Error(`intake.js 缺少 ${text}`);
  }
  const publicForm = fs.readFileSync(path.join(HERE, "public-intake.js"), "utf8");
  new vm.Script(publicForm, { filename: "public-intake.js" });
  new vm.Script(
    fs.readFileSync(path.join(HERE, "vendor", "qrcode.min.js"), "utf8"),
    { filename: "vendor/qrcode.min.js" },
  );
  for (const text of [
    "get_public_intake_form", "submit_public_intake",
    "get_public_intake_status", "PUBLIC_SUPABASE_URL",
  ]) {
    if (publicForm.indexOf(text) === -1) throw new Error(`public-intake.js 缺少 ${text}`);
  }
  const store = fs.readFileSync(path.join(HERE, "store.js"), "utf8");
  if (store.indexOf("intake:") === -1) {
    throw new Error("store.js 缺少 intake 缓存");
  }
});

test("高级模式：多公司升级后的 ON CONFLICT 已修复", () => {
  const today = fs.readFileSync(path.join(HERE, "today.js"), "utf8");
  if (!today.includes("42P10") ||
      !today.includes("fix-advanced-mode-on-conflict.sql")) {
    throw new Error("高级模式遇到 42P10 时没有给出修复指引");
  }

  const sqlPath = path.join(HERE, "sql", "fix-advanced-mode-on-conflict.sql");
  if (!fs.existsSync(sqlPath)) {
    throw new Error("缺少高级模式兼容修复 SQL");
  }
  const sql = fs.readFileSync(sqlPath, "utf8");
  if (!/^[\x00-\x7F]*$/.test(sql)) {
    throw new Error("高级模式修复 SQL 必须保持 ASCII");
  }
  const legacy = /on\s+conflict\s*\(\s*owner_profile_id\s*\)/i;
  if (legacy.test(sql)) {
    throw new Error("多公司模式下不能再对 owner_profile_id 使用 ON CONFLICT");
  }
  for (const text of [
    "pg_advisory_xact_lock", "active_enterprise_id",
    "enterprise_members_enterprise_profile_uidx",
    "grant execute on function public.set_enterprise_ui_mode(text)",
  ]) {
    if (!sql.includes(text)) throw new Error("高级模式修复 SQL 缺少 " + text);
  }
});

test("多账号同步修复：隔离、队列、协议和组织健康完整接线", () => {
  fresh();
  run('activateAccountDatabase("scope-account");'
    + 'DB.company_scope_id="scope-company";'
    + 'queueChange("tasks","update","scope-key",{id:"scope-key"});');
  if (run("DB.syncQueue[0].account_id") !== "scope-account"
      || run("DB.syncQueue[0].enterprise_id") !== "scope-company") {
    throw new Error("待上传记录没有绑定账号和公司 scope");
  }

  const account = fs.readFileSync(path.join(HERE, "account.js"), "utf8");
  for (const text of [
    "saved_accounts", "switchAccount", "resetAccountScopedRuntimeState",
    "maybePromptLegacyDataClaim", "claimLegacyDataForCurrentAccount",
  ]) {
    if (!account.includes(text)) throw new Error("account.js 缺少 " + text);
  }
  const sync = fs.readFileSync(path.join(HERE, "sync.js"), "utf8");
  for (const text of [
    "ensureClientProtocol", "detectQueueConflict", "resolveSyncConflict",
    "delete_sync_record", "get_sync_tombstones", "applySyncTombstones",
    "这条待上传数据属于另一个账号", "break;",
  ]) {
    if (!sync.includes(text)) throw new Error("sync.js 缺少 " + text);
  }
  const app = fs.readFileSync(path.join(HERE, "app.js"), "utf8");
  for (const text of [
    "accountDatabaseKey(lastAccountId)", "localSyncDiagnostics",
    "btn-local-backup", "data-conflict-local",
  ]) {
    if (!app.includes(text)) throw new Error("app.js 缺少 " + text);
  }

  const sqlPath = path.join(HERE, "sql", "multi-account-sync-health-v1.sql");
  if (!fs.existsSync(sqlPath)) throw new Error("缺少多账号修复 SQL");
  const sql = fs.readFileSync(sqlPath, "utf8");
  for (const text of [
    "repair_my_organization", "get_organization_health",
    "register_client_protocol", "client_protocol_versions",
    "sync_tombstones", "delete_sync_record", "get_sync_tombstones",
  ]) {
    if (!sql.includes(text)) throw new Error("多账号 SQL 缺少 " + text);
  }
});

test("数据一致性：项目同步、经营摘要和首页使用同一份项目缓存", () => {
  const sync = fs.readFileSync(path.join(HERE, "sync.js"), "utf8");
  for (const text of [
    "pullCloudProjects", "mergeCloudProjects", "mergeCloudProjectSteps",
    "pushQueuedProject", "pushQueuedProjectStep", "save_project",
    "save_project_step",
  ]) {
    if (!sync.includes(text)) throw new Error("sync.js 缺少 " + text);
  }
  const operations = fs.readFileSync(path.join(HERE, "operations.js"), "utf8");
  for (const text of ["pullCloudProjects", "operationsStaleMessage", "operations-banner"]) {
    if (!operations.includes(text)) throw new Error("operations.js 缺少 " + text);
  }
  const html = fs.readFileSync(path.join(HERE, "index.html"), "utf8");
  if (!html.includes('id="operations-banner"')) {
    throw new Error("经营摘要缺少旧数据提示区域");
  }
  const store = fs.readFileSync(path.join(HERE, "store.js"), "utf8");
  for (const text of ["queueProjectSync", "queueStepSync", "projectCloudPayload"]) {
    if (!store.includes(text)) throw new Error("store.js 缺少 " + text);
  }
});

test("淡紫星图视觉：场景卡、紫色主题和预览框架完整接线", () => {
  const html = fs.readFileSync(path.join(HERE, "index.html"), "utf8");
  for (const text of [
    "scene-login", "scene-company", "planet-signal-art",
    'id="today-scene"', "purple-starry-1", "charts.js?v=20261111-purple-starry-1",
  ]) {
    if (!html.includes(text)) throw new Error("index.html 缺少 " + text);
  }
  const today = fs.readFileSync(path.join(HERE, "today.js"), "utf8");
  for (const text of [
    "todaySceneData", "renderTodayScene", "star_04_work",
    "star_03_tea", "star_08_great", "star_15_tired", "star_02_roger",
  ]) {
    if (!today.includes(text)) throw new Error("today.js 缺少 " + text);
  }
  const css = fs.readFileSync(path.join(HERE, "style.css"), "utf8");
  for (const file of ["starfield.svg", "star-cluster.svg"]) {
    if (!fs.existsSync(path.join(HERE, "icons", "star", file))) {
      throw new Error("缺少不规则星空素材 " + file);
    }
  }
  for (const text of [
    "--accent: #705aa8", ".scene-card {", "#nav-simple button {",
    ".planet-signal-art {", "starfield.svg", "star-cluster.svg", "prefers-reduced-motion",
  ]) {
    if (!css.includes(text)) throw new Error("style.css 缺少 " + text);
  }
  const charts = fs.readFileSync(path.join(HERE, "charts.js"), "utf8");
  if (!charts.includes('accent: "#705aa8"')) {
    throw new Error("图表主题没有同步淡紫色");
  }
  const preview = fs.readFileSync(path.join(HERE, "phone-preview.html"), "utf8");
  if (!preview.includes("#0f1022") || !preview.includes("purple-starry-1")) {
    throw new Error("手机预览框架没有同步紫色主题");
  }
});

test("跨公司老板作为员工记录工时：完整接线", () => {
  const sync = fs.readFileSync(path.join(HERE, "sync.js"), "utf8");
  for (const text of [
    "currentEnterpriseId", "currentEnterpriseOwnerId",
    "p_enterprise: enterpriseId", "p_enterprise: currentEnterpriseId()",
    "enterprise_id: task.enterprise_id || currentEnterpriseId()",
  ]) {
    if (!sync.includes(text)) throw new Error("sync.js 缺少 " + text);
  }
  const app = fs.readFileSync(path.join(HERE, "app.js"), "utf8");
  for (const text of [
    "enterpriseMemberRows", "teamMemberRows", "identityHasManagementView()",
    "profile_id) === id", "openInviteOrganizationMember",
    "memberRows = enterpriseMemberRows()", "employeeNameOf(draft.employee_id)",
  ]) {
    if (!app.includes(text)) throw new Error("app.js 缺少 " + text);
  }
  const store = fs.readFileSync(path.join(HERE, "store.js"), "utf8");
  for (const text of [
    "function resolveWorker", "currentEnterpriseOwnerId()",
    "enterprise_id: typeof currentEnterpriseId",
    "typeof employeeNameOf",
  ]) {
    if (!store.includes(text)) throw new Error("store.js 缺少 " + text);
  }
  const ops = fs.readFileSync(path.join(HERE, "operations.js"), "utf8");
  for (const text of [
    "worklogMigrationEnterpriseId", "enterprise_id: enterpriseId || null",
  ]) {
    if (!ops.includes(text)) throw new Error("operations.js 缺少 " + text);
  }
  const sqlPath = path.join(HERE, "sql", "cross-company-worklogs-v1.sql");
  if (!fs.existsSync(sqlPath)) throw new Error("缺少跨公司工时 SQL");
  const sql = fs.readFileSync(sqlPath, "utf8");
  for (const text of [
    "enterprise_id uuid", "_worklog_scope", "start_work(", "p_enterprise uuid default null",
    "end_work(", "p_enterprise uuid default null", "not an enterprise member",
  ]) {
    if (!sql.includes(text)) throw new Error("跨公司 SQL 缺少 " + text);
  }
  if (!/^[\x00-\x7F]*$/.test(sql)) throw new Error("跨公司 SQL 必须保持 ASCII");
});

test("应用内自动更新：下载、校验、安装和兜底完整接线", () => {
  const update = fs.readFileSync(path.join(HERE, "update.js"), "utf8");
  for (const text of [
    "appUpdatePlugin", "expectedSha256", "updateProgress",
    "install_permission_required", "openInstallSettings",
    "openAppUpdateInBrowser", "showUpdatePrompt",
    "APP_UPDATE_API_URL", "fetchUpdateManifest", "releaseManifest",
  ]) {
    if (!update.includes(text)) throw new Error("update.js 缺少 " + text);
  }
  const pluginPath = path.join(HERE, "android", "app", "src", "main",
    "java", "com", "cj", "projectrecorder", "AppUpdatePlugin.java");
  if (!fs.existsSync(pluginPath)) throw new Error("缺少 AppUpdatePlugin.java");
  const plugin = fs.readFileSync(pluginPath, "utf8");
  for (const text of [
    '@CapacitorPlugin(name = "AppUpdate")',
    "canRequestPackageInstalls", "FileProvider.getUriForFile",
    "MessageDigest.getInstance(\"SHA-256\")", "notifyListeners",
  ]) {
    if (!plugin.includes(text)) throw new Error("AppUpdatePlugin 缺少 " + text);
  }
  const main = fs.readFileSync(path.join(HERE, "android", "app", "src", "main",
    "java", "com", "cj", "projectrecorder", "MainActivity.java"), "utf8");
  if (!main.includes("registerPlugin(AppUpdatePlugin.class)")) {
    throw new Error("MainActivity 没有注册 AppUpdatePlugin");
  }
  const manifest = fs.readFileSync(path.join(HERE, "android", "app", "src",
    "main", "AndroidManifest.xml"), "utf8");
  if (!manifest.includes("REQUEST_INSTALL_PACKAGES")) {
    throw new Error("AndroidManifest 缺少 REQUEST_INSTALL_PACKAGES");
  }
  if (!fs.existsSync(path.join(HERE, "seal-release.js"))) {
    throw new Error("缺少 seal-release.js");
  }
});

/* ---------------------------------------------------------- 执行 */
CASES.forEach(([label, body]) => {
  try { body(); ok(label); } catch (error) { fail(label, error.message); }
});

/* ---------------------------------------------------------- 汇总 */
console.log("\n" + "=".repeat(60));
const total = FILES.length + CASES.length;
if (failed) {
  console.log(`${total} 项检查，失败 ${failed} 项`);
  process.exit(1);
}
console.log(`全部通过（${FILES.length} 个文件语法 + ${CASES.length} 项逻辑）。`);
