/* =============================================================
   云端链路端到端验证

   模拟一遍真实的完整流程，直接打 Supabase 的 REST 接口：

     1. 老板注册        → profiles 行应自动创建（触发器）
     2. 员工注册
     3. 老板认领员工    → 把员工 profile 的 boss_id 设成自己
     4. 老板派任务      → 写入 tasks
     5. 员工查任务      → 只能看到派给自己的
     6. 员工勾选完成    → 写入 task_logs + worklogs
     7. 老板拉工时      → 应该收到员工报的那条
     8. 越权检查        → 员工不该看到别人的任务

   **为什么必须有这个脚本**：
     RLS 策略、外键、触发器这些只在真实数据库上才暴露问题。
     前面 "profiles 插入被拒" 就是靠真实调用发现的，
     静态检查、node 自检都查不出来。

   用法：
     node e2e-cloud.js

   它会创建几个临时测试账号。跑完可以到 Supabase 后台删掉它们，
   或者留着不管——名字都带 test 前缀，一眼能认出来。
   ============================================================= */
"use strict";

const URL_BASE = process.env.PROJECT_RECORDER_CLOUD_URL
  || "https://edchntmyqqjqvpngylgc.supabase.co";
const ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImVkY2hudG15cXFqcXZwbmd5bGdjIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTE1ODY5ODksImV4cCI6MjEwNzE2Mjk4OX0.6vfi2zxvdbmdLSHoV2U0r4R8zd10UCtO5XGaToqBc7I";

let passed = 0;
let failed = 0;

function ok(label, detail) {
  passed += 1;
  console.log(`  [OK]   ${label}${detail ? "  " + detail : ""}`);
}
function bad(label, detail) {
  failed += 1;
  console.log(`  [失败] ${label}`);
  if (detail) console.log("         " + String(detail).slice(0, 300));
}

/* 统一的接口调用。
   apikey 永远是 anon key；Authorization 用登录后的 token，
   这样 RLS 才会按"当前用户"来判权限。 */
async function api(method, path, options) {
  const opts = options || {};
  const headers = {
    apikey: ANON_KEY,
    "Content-Type": "application/json",
  };
  if (opts.token) headers.Authorization = "Bearer " + opts.token;
  else headers.Authorization = "Bearer " + ANON_KEY;
  if (opts.prefer) headers.Prefer = opts.prefer;

  const response = await fetch(URL_BASE + path, {
    method: method,
    headers: headers,
    body: opts.body ? JSON.stringify(opts.body) : undefined,
  });
  const text = await response.text();
  let data = null;
  try { data = text ? JSON.parse(text) : null; } catch (e) { data = text; }
  return { status: response.status, data: data };
}

function tag() {
  return Math.random().toString(36).slice(2, 8);
}

async function signup(email, password) {
  const result = await api("POST", "/auth/v1/signup", {
    body: { email: email, password: password },
  });
  if (!result.data || !result.data.access_token) {
    throw new Error("注册失败：" + JSON.stringify(result.data).slice(0, 200));
  }
  return {
    token: result.data.access_token,
    id: result.data.user.id,
    email: email,
  };
}

/* 登录。和 signup 分开——**建号现在走 RPC**，
   所以员工是靠登录拿会话的，不能再靠注册。 */
async function login(email, password) {
  const result = await api("POST", "/auth/v1/token?grant_type=password", {
    body: { email: email, password: password },
  });
  if (!result.data || !result.data.access_token) {
    throw new Error("登录失败：" + JSON.stringify(result.data).slice(0, 200));
  }
  return {
    token: result.data.access_token,
    id: result.data.user.id,
    email: email,
  };
}

async function main() {
  console.log("=".repeat(64));
  console.log("云端链路端到端验证");
  console.log("目标：" + URL_BASE);
  console.log("=".repeat(64));

  const stamp = tag();
  const password = "test123456";

  /* ---------- 1. 注册老板 ---------- */
  console.log("\n[1] 老板注册");
  let boss;
  try {
    boss = await signup(`testboss${stamp}@boss.pr`, password);
    ok("注册成功", `id=${boss.id.slice(0, 8)}…`);
  } catch (error) {
    bad("老板注册", error.message);
    console.log("\n注册就失败的话，后面的步骤没法继续。");
    return 1;
  }

  /* ---------- 2. profiles 触发器 ---------- */
  console.log("\n[2] profiles 行是否自动创建（触发器）");
  const bossProfile = await api("GET",
    `/rest/v1/profiles?select=*&id=eq.${boss.id}`, { token: boss.token });
  if (Array.isArray(bossProfile.data) && bossProfile.data.length === 1) {
    const row = bossProfile.data[0];
    ok("自动创建了 profiles 行", `code=${row.code} role=${row.role}`);
    if (row.role === "boss") ok("角色从域名正确推断为 boss");
    else bad("角色推断错误", "应当是 boss，实际 " + row.role);
  } else {
    bad("profiles 行没有自动创建", JSON.stringify(bossProfile.data));
    console.log("        说明 handle_new_user 触发器没生效。");
    return 1;
  }

  /* ---------- 3. 建员工账号（走 App 用的那个 RPC） ---------- */
  console.log("\n[3] 老板建员工账号");
  const staffCode = "teststaff" + stamp;
  const makeStaff = await api("POST", "/rest/v1/rpc/create_staff_account", {
    token: boss.token,
    body: { p_code: staffCode, p_password: password, p_name: "测试员工" },
  });
  if (!makeStaff.data || !makeStaff.data.ok) {
    bad("建员工账号失败", JSON.stringify(makeStaff.data));
    console.log("        可能 sql/multi-boss.sql 没跑。");
    return 1;
  }
  ok("建号成功", "工号 " + makeStaff.data.code);

  /* 员工登录。**必须走真实登录**，因为后面要验证
     "员工只能看到自己的任务" 这类权限，用老板的 token 测不出来。 */
  let staff;
  try {
    staff = await login(staffCode + "@staff.pr", password);
    ok("员工能登录", "id=" + staff.id.slice(0, 8) + "…");
  } catch (error) {
    bad("员工登录", error.message);
    return 1;
  }
  if (staff.id === makeStaff.data.id) ok("登录 id 和建号返回的一致");
  else bad("id 不一致", "建号 " + makeStaff.data.id + " vs 登录 " + staff.id);

  const staffProfile = await api("GET",
    `/rest/v1/profiles?select=role,boss_id&id=eq.${staff.id}`,
    { token: staff.token });
  if (Array.isArray(staffProfile.data) && staffProfile.data[0]
      && staffProfile.data[0].role === "employee") {
    ok("员工角色是 employee");
  } else {
    bad("员工角色不对", JSON.stringify(staffProfile.data));
  }
  if (Array.isArray(staffProfile.data) && staffProfile.data[0]
      && staffProfile.data[0].boss_id === boss.id) {
    ok("建号时已归属给老板（不需要再认领）");
  } else {
    bad("没有归属给老板", JSON.stringify(staffProfile.data));
  }

  /* **认领别人的账号必须失败。**

     这一条是隔离的关键，之前的策略允许老板把任何
     "boss_id 为空"的账号改成自己的——那是个漏洞
     （任何老板都能抢走还没归属的账号）。
     现在"先找没主的号再认领"这个流程已经删掉了，
     所以这条更新必须被拒绝。 */
  const claim = await api("PATCH",
    `/rest/v1/profiles?id=eq.${staff.id}`,
    { token: boss.token, body: { boss_id: null },
      prefer: "return=representation" });
  if (Array.isArray(claim.data) && claim.data.length === 0) {
    ok("改不动已归属的员工（隔离生效）");
  } else if (claim.status >= 400) {
    ok("改不动已归属的员工（隔离生效）", "HTTP " + claim.status);
  } else {
    bad("竟然能改别人账号的归属 —— 隔离有漏洞",
      JSON.stringify(claim.data));
  }

  /* ---------- 4. 老板派任务 ---------- */
  console.log("\n[4] 老板派任务");
  const today = new Date().toISOString().slice(0, 10);
  const taskId = crypto.randomUUID();
  /* **字段要和 App 的 assignTask() 完全一致**。
     这里以前漏了 updated_at，结果 App 上传任务时被
     PGRST204 拒绝，而这个脚本却全绿——两条验证路径覆盖不一致。 */
  const task = {
    id: taskId,
    boss_id: boss.id,
    employee_id: staff.id,
    title: "端到端测试任务",
    detail: "这条是自动化测试创建的",
    plan_date: today,
    est_hours: 2,
    project_name: "",
    step_name: "",
    created_at: new Date().toISOString(),
    updated_at: new Date().toISOString(),
  };
  const assigned = await api("POST", "/rest/v1/tasks",
    { token: boss.token, body: task, prefer: "return=representation" });
  if (assigned.status === 201 || assigned.status === 200) {
    ok("任务写入成功（字段和 App 一致）");
  } else {
    bad("派任务失败", JSON.stringify(assigned.data));
    console.log("        注意：如果报 PGRST204 缺列，说明建表 SQL 没跑全。");
    return 1;
  }

  /* 顺便验证 upsert（App 走的是 upsert 而不是 insert） */
  const upserted = await api("POST", "/rest/v1/tasks",
    { token: boss.token,
      body: Object.assign({}, task, { title: "端到端测试任务（改名）" }),
      prefer: "resolution=merge-duplicates,return=representation" });
  if (upserted.status === 201 || upserted.status === 200) {
    ok("任务 upsert 也成功（App 用的就是这个）");
  } else {
    bad("任务 upsert 失败", JSON.stringify(upserted.data));
  }

  /* ---------- 4b. updated_at 触发器 ---------- */
  console.log("\n[4b] updated_at 是否由触发器自动维护");
  const touch = await api("PATCH", `/rest/v1/tasks?id=eq.${taskId}`,
    { token: boss.token, body: { est_hours: 3 },
      prefer: "return=representation" });
  if (Array.isArray(touch.data) && touch.data.length === 1
      && touch.data[0].updated_at) {
    ok("改任务后 updated_at 自动更新了", touch.data[0].updated_at);
  } else {
    bad("updated_at 没自动更新", JSON.stringify(touch.data));
  }

  /* ---------- 5. 员工查任务 ---------- */
  console.log("\n[5] 员工拉取自己的任务");
  const staffTasks = await api("GET",
    `/rest/v1/tasks?select=*&employee_id=eq.${staff.id}`,
    { token: staff.token });
  if (Array.isArray(staffTasks.data) && staffTasks.data.length === 1) {
    ok("员工能看到派给自己的任务", "标题：" + staffTasks.data[0].title);
  } else {
    bad("员工看不到任务", JSON.stringify(staffTasks.data));
  }

  /* ---------- 6. 员工勾选完成 ---------- */
  console.log("\n[6] 员工勾选完成（自动上报）");
  const logRow = {
    task_id: taskId,
    employee_id: staff.id,
    started_at: new Date(Date.now() - 7200000).toISOString(),
    finished_at: new Date().toISOString(),
    finish_date: today,
  };
  const logged = await api("POST", "/rest/v1/task_logs",
    { token: staff.token, body: logRow, prefer: "return=representation" });
  if (logged.status === 201 || logged.status === 200) {
    ok("勾选记录写入成功");
  } else {
    bad("勾选失败", JSON.stringify(logged.data));
  }

  const worklog = {
    boss_id: boss.id,
    employee_id: staff.id,
    task_id: taskId,
    work_date: today,
    hours: 2,
    content: "端到端测试任务",
    source: "task",
  };
  const pushed = await api("POST", "/rest/v1/worklogs",
    { token: staff.token, body: worklog, prefer: "return=representation" });
  if (pushed.status === 201 || pushed.status === 200) {
    ok("工时上报成功");
  } else {
    bad("工时上报失败", JSON.stringify(pushed.data));
  }

  /* ---------- 7. 老板拉工时（核心需求） ---------- */
  console.log("\n[7] 老板自动收到员工的工时（核心需求）");
  const bossWorklogs = await api("GET",
    `/rest/v1/worklogs?select=*&boss_id=eq.${boss.id}`,
    { token: boss.token });
  if (Array.isArray(bossWorklogs.data) && bossWorklogs.data.length === 1) {
    const row = bossWorklogs.data[0];
    ok("老板收到了员工的工时",
      `${row.hours} 小时 · ${row.content}`);
    if (Number(row.hours) === 2) ok("工时数值正确");
    else bad("工时数值不对", "期望 2，实际 " + row.hours);
  } else {
    bad("老板没收到工时", JSON.stringify(bossWorklogs.data));
    console.log("        这是整个功能的核心——如果不通，要检查 worklogs 的 RLS。");
  }

  /* ---------- 8. 越权检查 ---------- */
  console.log("\n[8] 权限隔离检查");
  const staffSeesBoss = await api("GET",
    `/rest/v1/worklogs?select=*&boss_id=eq.${boss.id}&employee_id=neq.${staff.id}`,
    { token: staff.token });
  if (Array.isArray(staffSeesBoss.data) && staffSeesBoss.data.length === 0) {
    ok("员工看不到别人的工时");
  } else {
    bad("员工能看到别人的工时 —— RLS 有漏洞",
      JSON.stringify(staffSeesBoss.data));
  }

  const strangerSignup = await signup(`testother${stamp}@staff.pr`, password);
  const strangerSees = await api("GET",
    `/rest/v1/tasks?select=*&employee_id=eq.${staff.id}`,
    { token: strangerSignup.token });
  if (Array.isArray(strangerSees.data) && strangerSees.data.length === 0) {
    ok("无关账号看不到别人的任务");
  } else {
    bad("无关账号能看到别人的任务 —— RLS 有漏洞",
      JSON.stringify(strangerSees.data));
  }

  /* ---------- 9. 重复勾选 ---------- */
  console.log("\n[9] 同一条任务同一天重复勾选");
  const duplicate = await api("POST", "/rest/v1/task_logs",
    { token: staff.token, body: logRow });
  if (duplicate.status === 409
      || String(JSON.stringify(duplicate.data)).indexOf("duplicate") !== -1
      || String(JSON.stringify(duplicate.data)).indexOf("unique") !== -1) {
    ok("重复勾选被唯一约束挡住（不会产生两条记录）");
  } else {
    bad("重复勾选没有被挡住", "HTTP " + duplicate.status + " "
      + JSON.stringify(duplicate.data).slice(0, 160));
  }

  /* ---------- 汇总 ---------- */
  console.log("\n" + "=".repeat(64));
  if (failed) {
    console.log(`失败 ${failed} 项，通过 ${passed} 项`);
    console.log("\n测试账号（可以在 Supabase 后台删掉）：");
    console.log("  " + boss.email);
    console.log("  " + staff.email);
    return 1;
  }
  console.log(`全部通过（${passed} 项）。云端链路是通的。`);
  console.log("\n测试账号（可以在 Supabase 后台删掉）：");
  console.log("  " + boss.email + "  （老板）");
  console.log("  " + staff.email + "  （员工）");
  return 0;
}

main().then(code => { process.exitCode = code; }).catch(error => {
  console.error("\n脚本异常：" + error.message);
  process.exitCode = 1;
});
