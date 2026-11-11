/* =============================================================
   计算引擎：项目统计、负荷、预测、洞察。

   **这些判据必须和电脑端的 rules.py 一致。**
   同一个项目在手机和电脑上给出不同结论会让人不知道该信哪个。

   阈值集中放在最上面，改的时候两边一起改。
   可惜两边是两套语言（Python / JavaScript），做不到共享一份，
   所以这样处理：
     · 阈值全部提到文件开头，一眼能看出有哪些
     · check.py 里有一项专门盯住 Python 那边的阈值没被改动过
     · selfcheck 里会把两边对同一个项目算出的等级比一遍
   ============================================================= */
"use strict";

/* ---------------------------------------------------------- 阈值 */
const RISK_LEVELS = ["健康", "关注", "风险", "严重"];

const DELAY_WARN_DAYS = 3;      // 预计延期超过几天算「关注」
const DELAY_RISK_DAYS = 10;     // 超过几天算「风险」
const DELAY_SEVERE_DAYS = 25;   // 超过几天算「严重」
const OVERLOAD_RATIO = 1.15;    // 计划工时超出可用产能多少算超载
const BUDGET_WARN = 0.85;       // 预算用掉多少比例开始提醒
const BUDGET_RISK = 1.0;        // 超预算
const BLOCKED_WARN = 1;         // 几个阻塞步骤开始提醒
const STALE_DAYS = 14;          // 多久没记工时算「长期无人问津」
const DAILY_LIMIT_HOURS = 24;   // 一天总工时上限（手录时校验单条不超过它）

/* ---------------------------------------------------------- 日期 */
function parseDate(value) {
  if (!value) return null;
  const text = String(value).trim();
  const match = text.match(/^(\d{4})\D(\d{1,2})\D(\d{1,2})/);
  if (!match) return null;
  const date = new Date(Number(match[1]), Number(match[2]) - 1, Number(match[3]));
  return isNaN(date.getTime()) ? null : date;
}

function daysBetween(from, to) {
  if (!from || !to) return null;
  const a = new Date(from.getFullYear(), from.getMonth(), from.getDate());
  const b = new Date(to.getFullYear(), to.getMonth(), to.getDate());
  return Math.round((b - a) / 86400000);
}

function dateToISO(date) {
  const pad = n => String(n).padStart(2, "0");
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`;
}

function today() {
  const now = new Date();
  return new Date(now.getFullYear(), now.getMonth(), now.getDate());
}

function fmtDate(value) {
  const date = parseDate(value);
  if (!date) return "（未定）";
  const pad = n => String(n).padStart(2, "0");
  return `${date.getFullYear()}年${pad(date.getMonth() + 1)}月${pad(date.getDate())}日`;
}

/* ---------------------------------------------------------- 负荷窗口 */
/* 和 Python 版一样：优先最近 7 天，没数据就放宽到 28 天。
   返回的天数必须一路传到 loadRatio 里，否则分母不对。 */
function worklogWindow() {
  const now = today();
  const candidates = [7, 28];
  for (let i = 0; i < candidates.length; i += 1) {
    const days = candidates[i];
    const from = dateToISO(new Date(now.getTime() - (days - 1) * 86400000));
    const to = dateToISO(now);
    const count = fetchWorklogs().filter(item =>
      item.work_date >= from && item.work_date <= to).length;
    if (count > 0) return { from, to, days };
  }
  const from = dateToISO(new Date(now.getTime() - 6 * 86400000));
  return { from, to: dateToISO(now), days: 7 };
}

/* 负荷率 = 这段时间的工时 ÷ 同期应出工时（周基准 × 周数）。
   不能直接拿总工时比周基准——窗口是 28 天时那会把所有人算成超负荷。 */
function expectedHours(weeklyHours, days) {
  return num(weeklyHours) * num(days) / 7;
}

function loadRatio(hours, weeklyHours, days) {
  const expected = expectedHours(weeklyHours, days);
  if (expected <= 0) return 0;
  return num(hours) / expected;
}

/* 所有工时：本地自己记的 + 员工通过云端报上来的。

   **为什么必须有这个函数而不是直接读 DB.worklogs**：
     老板在手机上自己记的工时存在 DB.worklogs，
     员工勾任务后报上来的存在 DB.remoteWorklogs。
     统计的时候两边都要算，否则老板看到的负荷是缺的。

   两边能不能对上，取决于 **employee_id 用的是同一套标识**：
     员工在服务端的 id 是 uuid，所以老板建员工账号时
     要把本地 employee.id 也设成那个 uuid。
     见 sync.js 的 reconcileStaff()。 */
function fetchWorklogs() {
  if (typeof allWorklogs === "function") return allWorklogs();
  return DB.worklogs || [];
}

function fetchEmployees() {
  return DB.employees || [];
}

/* 每人在这段窗口里的工时和负荷，按负荷从高到低 */
function loadRows() {
  const window = worklogWindow();
  const hours = {};
  fetchWorklogs().forEach(item => {
    if (!item.work_date) return;
    if (item.work_date < window.from || item.work_date > window.to) return;
    hours[item.employee_id] = (hours[item.employee_id] || 0) + num(item.hours);
  });
  const rows = activeEmployees().map(employee => {
    const total = hours[employee.id] || 0;
    const weekly = num(employee.weekly_hours) || 40;
    return {
      id: employee.id,
      name: employee.name,
      role: employee.role || "",
      level: employee.level || "",
      hours: total,
      weekly: weekly,
      expected: expectedHours(weekly, window.days),
      ratio: loadRatio(total, weekly, window.days),
    };
  });
  rows.sort((a, b) => b.ratio - a.ratio);
  return { rows, window };
}

/* ---------------------------------------------------------- 预算 */
function budgetOf(project) {
  const budget = num(project.budget);
  const cost = num(project.cost);
  if (budget <= 0) {
    return { has: false, ratio: null, budget: 0, cost: cost,
             remaining: 0, over: false, used: 0 };
  }
  const ratio = cost / budget;
  return {
    has: true, ratio: ratio, budget: budget, cost: cost,
    remaining: budget - cost, over: ratio >= BUDGET_RISK,
    used: cost,
  };
}

function money(value) {
  const n = num(value);
  if (Math.abs(n) >= 10000) return (n / 10000).toFixed(1) + " 万";
  return n.toFixed(0);
}

/* ---------------------------------------------------------- 项目统计 */
function projectStats(project) {
  const steps = projectSteps(project.id);
  const done = steps.filter(item => item.status === "已完成").length;
  const blocked = steps.filter(item => item.status === "已阻塞");
  const logs = worklogsFor({ project_id: project.id, includeRemote: true });
  const hours = logs.reduce((sum, item) => sum + num(item.hours), 0);
  const assignments = projectAssignments(project.id);
  const planned = assignments.reduce((sum, item) => sum + num(item.planned_hours), 0);
  const people = {};
  logs.forEach(item => { people[item.employee_id] = true; });
  const peopleCount = Object.keys(people).length;

  const start = parseDate(project.start_date);
  const due = parseDate(project.due_date);
  const now = today();
  return {
    steps, done, total: steps.length, blocked, hours, planned,
    peopleCount,
    progress: num(project.progress),
    leftDays: due ? daysBetween(now, due) : null,
    usedDays: start ? Math.max(0, daysBetween(start, now)) : null,
    totalDays: (start && due) ? Math.max(1, daysBetween(start, due)) : null,
  };
}

/* 加权总分（权重为 0 的忽略） */
function weighted(items) {
  let score = 0;
  let weight = 0;
  (items || []).forEach(item => {
    const w = num(item.weight);
    if (w > 0) { score += num(item.score) * w; weight += w; }
  });
  if (weight <= 0) return null;
  return score / weight;
}

/* ============================================================
   预测：返回 {level, headline, reasons[{text,detail}], actions[], metrics}
   ============================================================ */
function predict(project) {
  const stats = projectStats(project);
  const reasons = [];
  const actions = [];
  let score = 0;
  const notes = {};

  const isDelivered = project.status === "已交付" || project.status === "已取消";

  /* ---- 1. 时间与进度错位 ---- */
  if (!isDelivered && stats.totalDays && stats.usedDays !== null
      && stats.progress > 0 && stats.progress < 100) {
    const timeRatio = stats.usedDays / stats.totalDays;
    const gap = timeRatio - stats.progress / 100;
    if (gap > 0.15) {
      score += gap > 0.35 ? 2 : 1;
      reasons.push({
        text: `时间用掉 ${Math.round(timeRatio * 100)}%，进度只有 ${stats.progress}%`,
        detail: `落后 ${Math.round(gap * 100)} 个百分点`,
      });
      if (gap > 0.3) actions.push("要么砍范围，要么加人，否则只能靠加班顶");
    }
    notes.timeRatio = timeRatio;
  }

  /* ---- 2. 按当前速度外推完成时间 ---- */
  let etaLine = "";
  if (!isDelivered && stats.progress > 0 && stats.progress < 100
      && stats.usedDays !== null && stats.leftDays !== null
      && stats.usedDays > 0) {
    const totalNeed = stats.usedDays / (stats.progress / 100);
    const remainNeed = totalNeed - stats.usedDays;
    const delay = Math.round(remainNeed - stats.leftDays);
    if (delay >= DELAY_SEVERE_DAYS) score += 3;
    else if (delay >= DELAY_RISK_DAYS) score += 2;
    else if (delay >= DELAY_WARN_DAYS) score += 1;
    if (delay >= DELAY_WARN_DAYS) {
      const eta = new Date(today().getTime() + remainNeed * 86400000);
      etaLine = `按当前速度，预计 ${fmtDate(dateToISO(eta))} 才能收尾，`
              + `比计划晚 ${delay} 天`;
      reasons.push({
        text: `预计延期 ${delay} 天`,
        detail: `已过 ${stats.usedDays} 天完成 ${stats.progress}%，`
              + `按此速度还需约 ${Math.round(remainNeed)} 天，`
              + `而计划只剩 ${stats.leftDays} 天`,
      });
      notes.delay = delay;
    }
  }

  /* ---- 3. 已超期 ---- */
  if (!isDelivered && stats.leftDays !== null && stats.leftDays < 0
      && stats.progress < 100) {
    score += 2;
    reasons.push({
      text: `已经超过计划截止 ${Math.abs(stats.leftDays)} 天`,
      detail: `计划 ${project.due_date}，当前进度 ${stats.progress}%`,
    });
  }

  /* ---- 4. 阻塞步骤 ---- */
  if (stats.blocked.length >= BLOCKED_WARN) {
    score += stats.blocked.length > 1 ? 2 : 1;
    reasons.push({
      text: `${stats.blocked.length} 个步骤处于「已阻塞」`,
      detail: stats.blocked.map(item => item.name).slice(0, 4).join("、"),
    });
    actions.push("先解开阻塞——阻塞不解决，加人也没用");
  }

  /* ---- 5. 人力负荷 ---- */
  if (stats.planned > 0 && !isDelivered) {
    const available = availableHours(project);
    if (available > 0) {
      const load = stats.planned / available;
      if (load > OVERLOAD_RATIO) {
        score += load > 1.5 ? 2 : 1;
        reasons.push({
          text: `计划工时超出可用产能 ${Math.round(load * 100 - 100)}%`,
          detail: `计划 ${stats.planned.toFixed(0)} 小时，`
                + `${stats.peopleCount} 人剩余产能约 ${available.toFixed(0)} 小时`,
        });
        actions.push("把部分任务分出去，或者往后排");
      }
    }
  }

  /* ---- 6. 预算 ---- */
  const budget = budgetOf(project);
  if (budget.has) {
    if (budget.ratio >= BUDGET_RISK) {
      score += 2;
      reasons.push({
        text: `已超预算 ${Math.round(budget.ratio * 100 - 100)}%`,
        detail: `预算 ${money(budget.budget)}，已花 ${money(budget.cost)}`,
      });
      actions.push("核对超支科目，必要时追加预算或砍掉低价值范围");
    } else if (budget.ratio >= BUDGET_WARN) {
      score += 1;
      reasons.push({
        text: `预算已用掉 ${Math.round(budget.ratio * 100)}%`,
        detail: `预算 ${money(budget.budget)}，已花 ${money(budget.cost)}，`
              + `剩余 ${money(budget.remaining)}`,
      });
    }
  }

  /* ---- 7. 能力 / 资源评分 ---- */
  const abilities = projectAssessments(project.id, "ability");
  const abilityScore = weighted(abilities);
  if (abilities.length && abilityScore !== null && abilityScore < 3.0) {
    score += 2;
    reasons.push({
      text: `技术能力评分偏低（加权 ${abilityScore.toFixed(2)} / 5）`,
      detail: abilities.filter(item => num(item.score) <= 2)
                .map(item => item.name).slice(0, 3).join("、"),
    });
    actions.push("缺的能力要么补人，要么外部支援");
  }
  const resources = projectAssessments(project.id, "resource");
  const resourceScore = weighted(resources);
  if (resources.length && resourceScore !== null && resourceScore < 3.0) {
    score += 1;
    reasons.push({
      text: `有利资源把握不足（加权 ${resourceScore.toFixed(2)} / 5）`,
      detail: resources.filter(item => num(item.score) <= 2)
                 .map(item => item.name).slice(0, 3).join("、"),
    });
  }

  /* ---- 8. 没人管 / 长时间没有工时 ---- */
  if (!isDelivered) {
    if (stats.peopleCount === 0 && stats.planned > 0) {
      score += 1;
      reasons.push({
        text: "有分配任务，但没有实际的工时记录",
        detail: `已分配 ${stats.planned.toFixed(0)} 小时，还没人报过`,
      });
      actions.push("确认这些任务是不是还没开工");
    } else if (stats.peopleCount === 0 && stats.total > 0) {
      score += 1;
      reasons.push({ text: "还没有分配任何人", detail: "没有人的项目不会自己推进" });
      actions.push("先把任务分配到人");
    } else if (stats.hours > 0) {
      const last = worklogsFor({ project_id: project.id, limit: 1 })[0];
      const lastDate = last ? parseDate(last.work_date) : null;
      const stale = lastDate ? daysBetween(lastDate, today()) : null;
      if (stale !== null && stale >= STALE_DAYS && stats.progress < 100) {
        score += 1;
        reasons.push({
          text: `${stale} 天没有新的工时记录`,
          detail: `最后一次是 ${last.work_date}`,
        });
        actions.push("确认这个项目是不是停下来了");
      }
    }
  }

  let level = "健康";
  if (score >= 6) level = "严重";
  else if (score >= 4) level = "风险";
  else if (score >= 2) level = "关注";

  return {
    level, score, reasons, actions, metrics: stats,
    headline: buildHeadline(level, etaLine, reasons, project, isDelivered),
  };
}

/* 可用产能：参与的人在这个项目上还能出多少小时。
   粗算：人数 × 每周 40 × 剩余周数，再扣掉已经投进去的。
   精确不起来——人和人不一样，而且一个人可能同时挂几个项目。
   够用来判断「计划量是不是明显超出人头」就行了。 */
function availableHours(project) {
  const stats = projectStats(project);
  const left = stats.leftDays === null ? 30 : Math.max(0, stats.leftDays);
  if (left <= 0) return 0;
  const people = Math.max(1, stats.peopleCount);
  const capacity = people * 40 * (left / 7);
  return Math.max(0, capacity - stats.hours);
}

function buildHeadline(level, etaLine, reasons, project, isDelivered) {
  if (isDelivered) return `${project.status}，没有遗留问题`;
  if (etaLine) return etaLine;
  if (reasons.length) return reasons[0].text;
  if (level === "健康") return "各项指标正常";
  return "有几处需要留意，见下面几条";
}

/* 所有项目 + 各自的预测等级，按严重程度排 */
function projectSummary() {
  const rows = DB.projects.map(project => ({
    project, result: predict(project),
  }));
  rows.sort((a, b) =>
    RISK_LEVELS.indexOf(b.result.level) - RISK_LEVELS.indexOf(a.result.level)
    || b.result.score - a.result.score);
  return rows;
}

/* ============================================================
   主动发现：横向比较 + 逻辑矛盾（对应电脑端的 insights）
   ============================================================ */
function insights() {
  const found = [];
  found.push(...insightInefficient());
  found.push(...insightOverloaded());
  found.push(...insightScattered());
  found.push(...insightBlockedAging());
  found.push(...insightOrderConflict());
  found.push(...insightOrphanHours());
  found.sort((a, b) => b.severity - a.severity);
  return found;
}

function makeInsight(title, detail, advice, group, severity) {
  return { title, detail, advice, group: group || "compare",
           severity: severity || 0 };
}

/* 花钱多、进度低 —— 单看成本或单看进度都发现不了 */
function insightInefficient() {
  const rows = DB.projects.filter(project =>
    num(project.cost) > 0
    && (project.status === "进行中" || project.status === "已暂停"));
  if (rows.length < 2) return [];
  const byCost = rows.slice().sort((a, b) => num(b.cost) - num(a.cost));
  const byProgress = rows.slice().sort((a, b) => num(a.progress) - num(b.progress));
  const worst = byCost[0];
  const best = byProgress[byProgress.length - 1];
  const worstRatio = num(worst.progress) / Math.max(1, num(worst.cost));
  const bestRatio = num(best.progress) / Math.max(1, num(best.cost));
  if (bestRatio < worstRatio * 3 || worst.id === best.id) return [];
  return [makeInsight(
    `《${worst.name}》投入最大、推进最慢`,
    `已花 ${money(worst.cost)}、进度 ${num(worst.progress)}%；`
    + `对比《${best.name}》花了 ${money(best.cost)}、进度 ${num(best.progress)}%`,
    "同样的人力在另一个项目上推进得更快。先弄清是范围失控还是执行受阻——"
    + "这两种情况处理方式完全相反。",
    "compare", 3)];
}

/* 谁超出同期应出工时 */
function insightOverloaded() {
  const { rows, window } = loadRows();
  const over = rows.filter(row => row.ratio > 1);
  if (!over.length) return [];
  const top = over[0];
  const others = over.slice(1, 4).map(row => row.name).join("、");
  let detail = `最近 ${window.days} 天：${top.name} ${top.hours.toFixed(1)} 小时，`
             + `是同期应出 ${top.expected.toFixed(0)} 小时的 `
             + `${Math.round(top.ratio * 100)}%`;
  if (others) detail += `；另有 ${others} 也超标`;
  return [makeInsight(
    `${over.length} 个人超出同期应出工时`, detail,
    "超负荷不会立刻出事，但会以质量下降、延期、离职的形式在后面还回来。"
    + "要么把事分出去，要么明确砍范围。",
    "compare", 3)];
}

/* 一个人挂在 3 个以上进行中的项目 */
function insightScattered() {
  const counts = {};
  DB.assignments.forEach(item => {
    const project = getProject(item.project_id);
    if (!project || project.status !== "进行中") return;
    counts[item.employee_id] = counts[item.employee_id] || {};
    counts[item.employee_id][item.project_id] = project.name;
  });
  let worst = null;
  Object.keys(counts).forEach(key => {
    const names = Object.keys(counts[key]);
    if (names.length >= 3 && (!worst || names.length > worst.count)) {
      worst = { employeeId: Number(key), count: names.length,
                names: names.map(id => counts[key][id]) };
    }
  });
  if (!worst) return [];
  return [makeInsight(
    `${employeeName(worst.employeeId)} 同时挂在 ${worst.count} 个项目上`,
    `进行中的项目：${worst.names.join("、")}`,
    "人在多个项目之间切换，光是切换本身就要花掉不少时间，"
    + "实际产出通常低于把工时简单相加的预期。考虑让他专注在其中一两个。",
    "compare", 2)];
}

/* 阻塞越久越危险 */
function insightBlockedAging() {
  let worst = null;
  DB.projects.forEach(project => {
    projectSteps(project.id).forEach(step => {
      if (step.status !== "已阻塞") return;
      const due = parseDate(step.due_date);
      const overdue = due ? daysBetween(due, today()) : null;
      if (worst === null || (overdue || 0) > (worst.overdue || 0)) {
        worst = { project: project.name, step: step, overdue: overdue };
      }
    });
  });
  if (!worst || worst.overdue === null || worst.overdue < 3) return [];
  return [makeInsight(
    `《${worst.project}》的「${worst.step.name}」已阻塞 ${worst.overdue} 天`,
    `计划截止 ${worst.step.due_date}，负责人 ${worst.step.owner || "未指定"}`,
    "阻塞放久了会变成习惯，后面就没人再提。"
    + "这周内必须有人明确回答：卡在谁那里、什么时候能解开。",
    "compare", 3)];
}

/* 标记为已完成，但前面还有没做完的步骤 —— 逻辑矛盾 */
function insightOrderConflict() {
  const hits = [];
  DB.projects.forEach(project => {
    let open = null;
    projectSteps(project.id).forEach(step => {
      if (step.status === "已完成") {
        if (open) hits.push({ project: project.name, step: step.name, before: open.name });
      } else {
        if (!open) open = step;
      }
    });
  });
  if (!hits.length) return [];
  const shown = hits.slice(0, 2)
    .map(item => `${item.project}：「${item.step}」完成了但「${item.before}」还没`)
    .join("；");
  return [makeInsight(
    `${hits.length} 处步骤顺序矛盾`,
    shown + (hits.length > 2 ? "…" : ""),
    "要么状态填错了，要么顺序乱了——两者都会让进度百分比失真。"
    + "花五分钟核对一下，比后面按错的进度做决策便宜得多。",
    "conflict", 2)];
}

/* 记了工时，但这个人没被分配到那个项目 */
function insightOrphanHours() {
  const byProject = {};
  fetchWorklogs().forEach(log => {
    /* 跳过非项目工时。这里要判断 null 和 undefined 两种——
       员工报上来的记录没有 project_id（只有 project_name），
       只判 null 的话会把它们当成"属于项目 0"算进去。 */
    if (log.project_id === null || log.project_id === undefined) return;
    const assigned = DB.assignments.some(item =>
      item.project_id === log.project_id && item.employee_id === log.employee_id);
    if (assigned) return;
    byProject[log.project_id] = byProject[log.project_id]
      || { hours: 0, count: 0 };
    byProject[log.project_id].hours += num(log.hours);
    byProject[log.project_id].count += 1;
  });
  const keys = Object.keys(byProject);
  if (!keys.length) return [];
  const total = keys.reduce((sum, key) => sum + byProject[key].hours, 0);
  const topKey = keys.sort((a, b) => byProject[b].hours - byProject[a].hours)[0];
  return [makeInsight(
    `${keys.length} 个项目有「没分配到人」的工时`,
    `合计 ${total.toFixed(1)} 小时；最多的是《${projectName(topKey)}》，`
    + `${byProject[topKey].hours.toFixed(1)} 小时、`
    + `${byProject[topKey].count} 条记录`,
    "这些工时不知道该算在哪个任务上，也就没法判断哪一步超支。"
    + "要么补上分配，要么确认这些是计划外的工作。",
    "conflict", 2)];
}

/* 一天合计超过 24 小时 —— 光看单条发现不了。
   注意：手录的工时**没有起止时间**，所以做不了真正的「时间段重叠」判断
   （电脑端有计时会话的起止时间才能查那个）。
   这里只查总量，不硬凑一个像模像样的重叠检查。 */
function worklogProblems() {
  const problems = [];
  const byEmployeeDay = {};
  fetchWorklogs().forEach(log => {
    if (!log.work_date) return;
    const key = `${log.employee_id}|${log.work_date}`;
    byEmployeeDay[key] = byEmployeeDay[key] || { employee: log.employee_id,
                                                 day: log.work_date, hours: 0,
                                                 count: 0 };
    byEmployeeDay[key].hours += num(log.hours);
    byEmployeeDay[key].count += 1;
  });
  Object.keys(byEmployeeDay).forEach(key => {
    const row = byEmployeeDay[key];
    if (row.hours > DAILY_LIMIT_HOURS) {
      problems.push({
        day: row.day,
        text: `${employeeName(row.employee)} 这天报了 ${row.hours.toFixed(1)} 小时`
            + `（${row.count} 条），超过 24 小时`,
      });
    }
  });
  problems.sort((a, b) => a.day.localeCompare(b.day));
  return problems;
}
