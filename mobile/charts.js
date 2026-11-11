/* =============================================================
   图表：用 Canvas 手绘，对应电脑端 chart.py 的四张图。

    为什么要重画而不是从电脑端截图：
      截图是死的——切主题不跟着变，数据更新要重新传图。
      Canvas 画的是活的，和电脑端一样取色于同一套调色板。

    Canvas 和 QPainter 的差别要点：
      · 单位是 CSS 像素，但**必须按 devicePixelRatio 放大**，
        否则在高分屏（手机基本都是）上糊得看不清
      · 没有画笔对象，靠 ctx.strokeStyle / fillStyle / lineWidth 设状态
      · 文字宽度要 ctx.measureText() 自己量
   ============================================================= */
"use strict";

/* =============================================================
   配色：和电脑端 theme.py 保持一致，浅色 / 深色各一套。

   **这套值同时管界面和图表**——切换主题时
   app.js 的 applyTheme() 把它们写成 CSS 变量给界面用，
   图表则直接从这里读。
   一处定义、两处使用，不会出现「界面变深色了、图还是浅色」。
   ============================================================= */
const THEME_COLORS = {
  /* **柔和、不刺眼。**

     做法是把所有颜色的饱和度压低、亮度抬高，
     并且不用纯黑纯白：
       · 字色是墨绿灰（#3a4742），不是 #000
       · 主色是淡薄荷（#5ec7b2），不是鲜艳的蓝或绿
       · 边框是极淡的灰绿，几乎看不见，只用来分隔

     半透明的效果（毛玻璃）在 style.css 里做 ——
     canvas 画布不支持 backdrop-filter，这里只给纯色值。 */
  light: {
    bg: "#f5f1fb", panel: "#fffaff", read: "#f8f4ff",
    fg: "#372b52", fgStrong: "#251c3e", fgSoft: "#685987",
    fgDim: "#8d82a5", fgFaint: "#b7aec8",
    line: "#e8def2", lineSoft: "#f2ebf8",
    accent: "#705aa8", accentDim: "#574181", accentWash: "#efe8fa",
    accentEdge: "#d8c9ed", hover: "#f7f1fd", track: "#ede5f6",
    series: ["#705aa8", "#9b8cff", "#72b9b0", "#e7b96f", "#b98ba9", "#7f91c9"],
    levels: { "健康": "#72a88e", "关注": "#b89b72",
              "风险": "#b98b9e", "严重": "#a97088" },
  },
  /* 暗色同样压低饱和，避免"深底上刺眼的荧光色" */
  dark: {
    bg: "#0f1022", panel: "#19182d", read: "#15152a",
    fg: "#eee9fb", fgStrong: "#fffaff", fgSoft: "#c9c0e8",
    fgDim: "#9d92b8", fgFaint: "#6f6689",
    line: "#2d2946", lineSoft: "#242138",
    accent: "#9984de", accentDim: "#7761bc", accentWash: "#251f3d",
    accentEdge: "#433a65", hover: "#211d34", track: "#29243f",
    series: ["#9984de", "#b8a7ff", "#72d7c7", "#e7b96f", "#cfa0bd", "#91a7df"],
    levels: { "健康": "#7fc5a4", "关注": "#d1b27f",
              "风险": "#ca9bb0", "严重": "#be849b" },
  },
};

/* 这套值给图表用（Canvas 只认具体颜色，不认 CSS 变量） */
const CHART_COLORS = {
  light: {
    panel: THEME_COLORS.light.panel,
    fg: THEME_COLORS.light.fg,
    fgDim: THEME_COLORS.light.fgDim,
    fgSoft: THEME_COLORS.light.fgSoft,
    grid: THEME_COLORS.light.lineSoft,
    axis: THEME_COLORS.light.line,
    track: THEME_COLORS.light.track,
    series: THEME_COLORS.light.series,
    levels: THEME_COLORS.light.levels,
  },
  dark: {
    panel: THEME_COLORS.dark.panel,
    fg: THEME_COLORS.dark.fg,
    fgDim: THEME_COLORS.dark.fgDim,
    fgSoft: THEME_COLORS.dark.fgSoft,
    grid: THEME_COLORS.dark.lineSoft,
    axis: THEME_COLORS.dark.line,
    track: THEME_COLORS.dark.track,
    series: THEME_COLORS.dark.series,
    levels: THEME_COLORS.dark.levels,
  },
};

let chartTheme = "light";
function setChartTheme(name) { chartTheme = name === "dark" ? "dark" : "light"; }
function colors() { return CHART_COLORS[chartTheme]; }

/* 把主题写成 CSS 变量，供界面使用。
   style.css 里 :root 定义的是浅色（兜底），这里覆盖成当前主题。 */
function applyThemeVariables(name) {
  const palette = THEME_COLORS[name] || THEME_COLORS.light;
  const root = document.documentElement;
  Object.keys(palette).forEach(key => {
    const value = palette[key];
    if (typeof value !== "string") return;   // series / levels 不是 CSS 值
    /* camelCase 转成 CSS 的短横线写法：fgStrong -> fg-strong */
    const cssName = "--" + key.replace(/[A-Z]/g, letter => "-" + letter.toLowerCase());
    root.style.setProperty(cssName, value);
  });
  /* 主题名也存下来，样式表里可以按它做特殊处理 */
  root.setAttribute("data-theme", name);
}

/* ---------------------------------------------------------- 兼容层 */
/* ctx.roundRect 是比较新的接口，安卓系统 WebView 版本旧的时候没有。
   打包成 apk 之后用的就是系统 WebView，用户不一定升级过，
   所以自己补一个——否则整张图画到一半直接抛异常。 */
(function polyfillRoundRect() {
  if (typeof CanvasRenderingContext2D === "undefined") return;
  if (CanvasRenderingContext2D.prototype.roundRect) return;
  CanvasRenderingContext2D.prototype.roundRect = function (x, y, w, h, r) {
    const radius = Math.min(typeof r === "number" ? r : 0,
                            Math.abs(w) / 2, Math.abs(h) / 2);
    this.moveTo(x + radius, y);
    this.lineTo(x + w - radius, y);
    this.quadraticCurveTo(x + w, y, x + w, y + radius);
    this.lineTo(x + w, y + h - radius);
    this.quadraticCurveTo(x + w, y + h, x + w - radius, y + h);
    this.lineTo(x + radius, y + h);
    this.quadraticCurveTo(x, y + h, x, y + h - radius);
    this.lineTo(x, y + radius);
    this.quadraticCurveTo(x, y, x + radius, y);
    return this;
  };
}());

/* ---------------------------------------------------------- 基础准备 */
/* 按设备像素比放大画布，否则高分屏上模糊。
   返回 ctx 和「逻辑宽高」——后续都用逻辑坐标画。 */
function prepare(canvas, logicalHeight) {
  const width = canvas.clientWidth || canvas.parentNode.clientWidth || 320;
  const height = logicalHeight || 200;
  const ratio = window.devicePixelRatio || 1;
  canvas.width = Math.round(width * ratio);
  canvas.height = Math.round(height * ratio);
  canvas.style.height = height + "px";
  const ctx = canvas.getContext("2d");
  ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
  ctx.clearRect(0, 0, width, height);
  ctx.textBaseline = "middle";
  return { ctx, width, height };
}

/* 轴上界取整到好读的数，避免出现 3721 这种刻度。
   和电脑端的 nice_max 用同一套算法。 */
function niceMax(raw) {
  if (!(raw > 0)) return 1;
  const magnitude = Math.pow(10, String(Math.floor(raw)).length - 1);
  const factors = [1, 1.5, 2, 2.5, 5, 10];
  for (let i = 0; i < factors.length; i += 1) {
    const candidate = magnitude * factors[i];
    if (candidate >= raw) return candidate;
  }
  return magnitude * 10;
}

function emptyText(canvas, text) {
  const { ctx, width, height } = prepare(canvas, canvas.dataset.h || 180);
  const palette = colors();
  ctx.fillStyle = palette.fgDim;
  ctx.font = "13px -apple-system, 'PingFang SC', sans-serif";
  ctx.textAlign = "center";
  ctx.fillText(text || "暂无数据", width / 2, height / 2);
  return false;
}

/* ---------------------------------------------------------- 折线图 */
function drawTrend(canvas, labels, series, options) {
  const opts = options || {};
  const palette = colors();
  if (!labels || !labels.length || !series || !series.length) {
    return emptyText(canvas, opts.empty || "暂无数据");
  }
  const legendRows = series.length > 1 ? 1 : 0;
  const { ctx, width, height } = prepare(canvas, opts.height || 220);
  const padLeft = 46, padRight = 12, padTop = 14 + legendRows * 20, padBottom = 34;
  const plotW = Math.max(10, width - padLeft - padRight);
  const plotH = Math.max(10, height - padTop - padBottom);

  /* **用稳健刻度，不让一条异常数据把整张图压扁。**

     实测踩到：有人误填了一条 99999 小时的工时，
     Y 轴被拉到 15 万，其他所有日子全贴在底线上，
     曲线形状完全看不出来 —— 图等于废了。

     **判据用物理上限，不是分位数。**
     一开始写的是"取 P90"，但 14 天里只有一个非零值，
     分位数也判不出谁是异常 —— 试了还是 15 万。
     "一天不可能超过 24 小时"是硬常识，用它最稳：

       · 所有值都 ≤ 24  → 按原来的最大值定刻度，什么都不变
       · 有值 > 24      → 用 ≤24 的那些值定刻度，超出的点夹到顶部

     数据本身一点没改，只是画法变了。 */
  const HOURS_PER_DAY = 24;
  let rawMax = 0;
  const sane = [];
  series.forEach(item => item.data.forEach(value => {
    const v = num(value);
    if (v > rawMax) rawMax = v;
    if (v > 0 && v <= HOURS_PER_DAY) sane.push(v);
  }));

  let scaleBase = rawMax;
  if (rawMax > HOURS_PER_DAY) {
    if (sane.length) {
      /* 有正常值：按正常值的最大值来，留 15% 余量 */
      scaleBase = Math.min(Math.max.apply(null, sane), HOURS_PER_DAY) * 1.15;
    } else {
      /* 全是离谱值：就按物理上限画，不放大 */
      scaleBase = HOURS_PER_DAY;
    }
  }
  const maxValue = niceMax(scaleBase);

  /* 图例 */
  if (legendRows) {
    ctx.font = "11px -apple-system, 'PingFang SC', sans-serif";
    ctx.textAlign = "left";
    let x = padLeft;
    series.forEach((item, index) => {
      ctx.fillStyle = palette.series[index % palette.series.length];
      ctx.beginPath();
      ctx.arc(x + 4, 12, 4, 0, Math.PI * 2);
      ctx.fill();
      ctx.fillStyle = palette.fgDim;
      ctx.fillText(item.name || "", x + 12, 12);
      x += 12 + ctx.measureText(item.name || "").width + 16;
    });
  }

  /* 网格 + 纵轴刻度 */
  ctx.font = "11px -apple-system, 'PingFang SC', sans-serif";
  const ticks = 4;
  for (let i = 0; i <= ticks; i += 1) {
    const y = padTop + plotH - (plotH * i) / ticks;
    ctx.strokeStyle = palette.grid;
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.moveTo(padLeft, y + 0.5);
    ctx.lineTo(padLeft + plotW, y + 0.5);
    ctx.stroke();
    ctx.fillStyle = palette.fgDim;
    ctx.textAlign = "right";
    /* **刻度标签不能重复。**

       上限很小的时候（比如全是 0，上限被兜底成 1），
       `Math.round(maxValue * i / ticks)` 会把 0.25 / 0.5 / 0.75 / 1
       全舍成 0 和 1，纵轴就出现 "1 1 1 0" 这种看不懂的刻度。

       上限 ≤ 4 时保留一位小数，四个刻度就能分得开。 */
    const tickValue = (maxValue * i) / ticks;
    const tickLabel = maxValue <= 4
      ? String(Math.round(tickValue * 10) / 10)
      : String(Math.round(tickValue));
    ctx.fillText(tickLabel, padLeft - 8, y);
  }

  /* 横坐标位置 */
  const count = labels.length;
  const step = count > 1 ? plotW / (count - 1) : 0;
  const xOf = index => (count > 1 ? padLeft + step * index : padLeft + plotW / 2);

  /* 折线 + 点 */
  series.forEach((item, index) => {
    const color = palette.series[index % palette.series.length];
    const points = item.data.slice(0, count).map((value, i) => ({
      x: xOf(i),
      /* 超过刻度上限的值夹到顶部，别画到图外面去 */
      y: padTop + plotH
        - (plotH * Math.min(num(value), maxValue)) / maxValue,
    }));
    if (!points.length) return;
    ctx.strokeStyle = color;
    ctx.lineWidth = 2;
    ctx.lineJoin = "round";
    ctx.beginPath();
    points.forEach((point, i) => {
      if (i === 0) ctx.moveTo(point.x, point.y);
      else ctx.lineTo(point.x, point.y);
    });
    if (points.length > 1) ctx.stroke();
    points.forEach(point => {
      ctx.fillStyle = color;
      ctx.beginPath();
      ctx.arc(point.x, point.y, 3, 0, Math.PI * 2);
      ctx.fill();
      ctx.strokeStyle = palette.panel;
      ctx.lineWidth = 1.5;
      ctx.stroke();
    });
  });

  /* 横轴标签：太密就隔几个画一个 */
  const stride = Math.max(1, Math.ceil(count / 6));
  ctx.fillStyle = palette.fgDim;
  ctx.textAlign = "center";
  labels.forEach((label, index) => {
    if (index % stride) return;
    ctx.fillText(String(label).slice(0, 8), xOf(index), padTop + plotH + 16);
  });
  return true;
}

/* ---------------------------------------------------------- 柱状图 */
/* bars: [{label, values:[v] | [plan, actual]}] */
function drawBars(canvas, bars, options) {
  const opts = options || {};
  const palette = colors();
  if (!bars || !bars.length) {
    return emptyText(canvas, opts.empty || "暂无数据");
  }
  const groups = bars.reduce((max, bar) => Math.max(max, bar.values.length), 1);
  const legendRows = groups > 1 ? 1 : 0;
  const { ctx, width, height } = prepare(canvas, opts.height || 220);
  const padLeft = 46, padRight = 12, padTop = 14 + legendRows * 20, padBottom = 44;
  const plotW = Math.max(10, width - padLeft - padRight);
  const plotH = Math.max(10, height - padTop - padBottom);

  let maxValue = 0;
  bars.forEach(bar => bar.values.forEach(value => {
    if (num(value) > maxValue) maxValue = num(value);
  }));
  maxValue = niceMax(maxValue);

  /* 图例 */
  if (legendRows && opts.groupNames) {
    ctx.font = "11px -apple-system, 'PingFang SC', sans-serif";
    ctx.textAlign = "left";
    let x = padLeft;
    opts.groupNames.slice(0, groups).forEach((name, index) => {
      ctx.fillStyle = palette.series[index % palette.series.length];
      ctx.fillRect(x, 8, 10, 10);
      ctx.fillStyle = palette.fgDim;
      ctx.fillText(name, x + 14, 13);
      x += 14 + ctx.measureText(name).width + 16;
    });
  }

  /* 网格 */
  ctx.font = "11px -apple-system, 'PingFang SC', sans-serif";
  const ticks = 4;
  for (let i = 0; i <= ticks; i += 1) {
    const y = padTop + plotH - (plotH * i) / ticks;
    ctx.strokeStyle = palette.grid;
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.moveTo(padLeft, y + 0.5);
    ctx.lineTo(padLeft + plotW, y + 0.5);
    ctx.stroke();
    ctx.fillStyle = palette.fgDim;
    ctx.textAlign = "right";
    /* **刻度标签不能重复。**

       上限很小的时候（比如全是 0，上限被兜底成 1），
       `Math.round(maxValue * i / ticks)` 会把 0.25 / 0.5 / 0.75 / 1
       全舍成 0 和 1，纵轴就出现 "1 1 1 0" 这种看不懂的刻度。

       上限 ≤ 4 时保留一位小数，四个刻度就能分得开。 */
    const tickValue = (maxValue * i) / ticks;
    const tickLabel = maxValue <= 4
      ? String(Math.round(tickValue * 10) / 10)
      : String(Math.round(tickValue));
    ctx.fillText(tickLabel, padLeft - 8, y);
  }

  const slot = plotW / bars.length;
  const barW = Math.max(4, Math.min(slot * (groups === 1 ? 0.5 : 0.34), 46));
  const groupW = barW * groups + (groups - 1) * 2;
  const showValue = bars.length <= 8;

  bars.forEach((bar, index) => {
    const center = padLeft + slot * index + slot / 2;
    const startX = center - groupW / 2;
    bar.values.forEach((value, group) => {
      const barH = (plotH * num(value)) / maxValue;
      const x = startX + group * (barW + 2);
      const y = padTop + plotH - barH;
      const color = palette.series[(groups > 1 ? group : index)
                                   % palette.series.length];
      ctx.fillStyle = color;
      ctx.beginPath();
      const r = Math.min(3, barW / 2);
      ctx.moveTo(x, padTop + plotH);
      ctx.lineTo(x, y + r);
      ctx.quadraticCurveTo(x, y, x + r, y);
      ctx.lineTo(x + barW - r, y);
      ctx.quadraticCurveTo(x + barW, y, x + barW, y + r);
      ctx.lineTo(x + barW, padTop + plotH);
      ctx.closePath();
      ctx.fill();
      if (showValue && num(value) > 0) {
        ctx.fillStyle = palette.fgSoft;
        ctx.textAlign = "center";
        ctx.fillText(String(Math.round(num(value))), x + barW / 2, y - 8);
      }
    });
    /* 标签：太长就截断，两行放不下 */
    ctx.fillStyle = palette.fgDim;
    ctx.textAlign = "center";
    const label = String(bar.label || "");
    const short = label.length > 5 ? label.slice(0, 5) + "…" : label;
    ctx.save();
    ctx.translate(center, padTop + plotH + 10);
    if (bars.length > 5) {
      ctx.rotate(-Math.PI / 6);
      ctx.textAlign = "right";
      ctx.fillText(short, 0, 0);
    } else {
      ctx.fillText(short, 0, 0);
    }
    ctx.restore();
  });
  return true;
}

/* ---------------------------------------------------------- 进度时间轴 */
/* steps: [{name, start, due, progress, status}] */
function drawTimeline(canvas, steps, options) {
  const opts = options || {};
  const palette = colors();
  const dated = (steps || []).filter(step =>
    parseDate(step.start) || parseDate(step.due));
  if (!dated.length) {
    return emptyText(canvas, opts.empty || "步骤填上日期后这里显示时间轴");
  }
  const rowH = 26;
  const labelW = 78;
  const { ctx, width, height } = prepare(canvas, opts.height || (44 + dated.length * rowH));

  const now = today();
  let first = now, last = now;
  dated.forEach(step => {
    const start = parseDate(step.start);
    const due = parseDate(step.due);
    if (start && start < first) first = start;
    if (due && due < first) first = due;
    if (start && start > last) last = start;
    if (due && due > last) last = due;
  });
  if (first > now) first = now;
  if (last < now) last = now;
  const span = Math.max(1, daysBetween(first, last));

  const padLeft = labelW + 8;
  const padRight = 42;
  const plotW = Math.max(20, width - padLeft - padRight);
  const padTop = 18;
  const xOf = date => (date === null ? null
    : padLeft + (plotW * daysBetween(first, date)) / span);

  /* 月份刻度 */
  ctx.font = "10px -apple-system, 'PingFang SC', sans-serif";
  const cursor = new Date(first.getFullYear(), first.getMonth(), 1);
  while (cursor <= last) {
    const x = xOf(cursor);
    if (x !== null && x >= padLeft && x <= padLeft + plotW) {
      ctx.strokeStyle = palette.grid;
      ctx.lineWidth = 1;
      ctx.beginPath();
      ctx.moveTo(x + 0.5, padTop - 4);
      ctx.lineTo(x + 0.5, padTop + dated.length * rowH + 2);
      ctx.stroke();
      ctx.fillStyle = palette.fgDim;
      ctx.textAlign = "center";
      ctx.fillText(`${cursor.getFullYear() % 100}/${cursor.getMonth() + 1}`,
                   x, 8);
    }
    cursor.setMonth(cursor.getMonth() + 1);
  }

  const barH = 11;
  dated.forEach((step, index) => {
    const y = padTop + index * rowH + (rowH - barH) / 2;
    /* 步骤名 */
    ctx.fillStyle = palette.fg;
    ctx.font = "11px -apple-system, 'PingFang SC', sans-serif";
    ctx.textAlign = "right";
    let name = String(step.name || "");
    while (name.length > 1 && ctx.measureText(name).width > labelW - 4) {
      name = name.slice(0, -2) + "…";
    }
    ctx.fillText(name, labelW, y + barH / 2);

    let startX = xOf(parseDate(step.start));
    let endX = xOf(parseDate(step.due));
    if (startX === null) startX = xOf(now);
    if (endX === null) endX = xOf(now);
    if (endX < startX) { const swap = startX; startX = endX; endX = swap; }
    if (endX - startX < 3) endX = startX + 3;

    /* 计划区间底色 */
    ctx.fillStyle = palette.track;
    ctx.beginPath();
    ctx.roundRect
      ? ctx.roundRect(startX, y, endX - startX, barH, 3)
      : ctx.rect(startX, y, endX - startX, barH);
    ctx.fill();

    /* 已完成的部分 */
    const progress = clamp(num(step.progress), 0, 100);
    if (progress > 0) {
      let fill = palette.series[0];
      if (step.status === "已完成") fill = palette.levels["健康"];
      else if (step.status === "已阻塞") fill = palette.levels["严重"];
      ctx.globalAlpha = 0.82;
      ctx.fillStyle = fill;
      const doneW = Math.max(2, ((endX - startX) * progress) / 100);
      ctx.beginPath();
      ctx.roundRect
        ? ctx.roundRect(startX, y, doneW, barH, 3)
        : ctx.rect(startX, y, doneW, barH);
      ctx.fill();
      ctx.globalAlpha = 1;
    }

    /* 过期未完成：在截止处画一道警示竖线 */
    const due = parseDate(step.due);
    if (due && due < now && step.status !== "已完成") {
      const overX = xOf(due);
      ctx.strokeStyle = palette.levels["风险"];
      ctx.lineWidth = 2;
      ctx.beginPath();
      ctx.moveTo(overX, y - 3);
      ctx.lineTo(overX, y + barH + 3);
      ctx.stroke();
    }

    /* 进度数字 */
    ctx.fillStyle = palette.fgDim;
    ctx.textAlign = "left";
    ctx.fillText(progress + "%", padLeft + plotW + 6, y + barH / 2);
  });

  /* 今天：贯穿全图的虚线 */
  const todayX = xOf(now);
  if (todayX !== null && todayX >= padLeft && todayX <= padLeft + plotW) {
    ctx.strokeStyle = palette.fgDim;
    ctx.setLineDash([4, 3]);
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.moveTo(todayX + 0.5, padTop - 4);
    ctx.lineTo(todayX + 0.5, padTop + dated.length * rowH + 2);
    ctx.stroke();
    ctx.setLineDash([]);
    ctx.fillStyle = palette.fgDim;
    ctx.textAlign = "center";
    ctx.fillText("今天", todayX, padTop + dated.length * rowH + 12);
  }
  return true;
}

/* ---------------------------------------------------------- 负荷条形图 */
/* rows: [{name, hours, ratio}]，ratio 是负荷率（1.0 = 满） */
function drawLoad(canvas, rows, options) {
  const opts = options || {};
  const palette = colors();
  if (!rows || !rows.length) {
    return emptyText(canvas, opts.empty || "还没有员工");
  }
  const rowH = 28;
  const labelW = 62;
  const { ctx, width, height } = prepare(canvas, opts.height || (34 + rows.length * rowH));
  const padLeft = labelW + 8;
  const padRight = 46;
  const plotW = Math.max(20, width - padLeft - padRight);
  const padTop = 8;
  const barH = 12;

  let topRatio = 1;
  rows.forEach(row => { if (row.ratio > topRatio) topRatio = row.ratio; });
  const ticks = 4;
  let axisMax = Math.ceil(topRatio * ticks) / ticks;
  if (axisMax <= topRatio) axisMax = topRatio * 1.05;

  /* 纵向网格 + 刻度 */
  ctx.font = "10px -apple-system, 'PingFang SC', sans-serif";
  for (let i = 0; i <= ticks; i += 1) {
    const x = padLeft + (plotW * i) / ticks;
    ctx.strokeStyle = palette.grid;
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.moveTo(x + 0.5, padTop);
    ctx.lineTo(x + 0.5, padTop + rows.length * rowH);
    ctx.stroke();
    ctx.fillStyle = palette.fgDim;
    ctx.textAlign = "center";
    ctx.fillText(Math.round((axisMax * i * 100) / ticks) + "%",
                 x, padTop + rows.length * rowH + 10);
  }

  /* 100% 基准线：超没超负荷就看它 */
  const baseX = padLeft + plotW * (1 / axisMax);
  if (baseX <= padLeft + plotW) {
    ctx.strokeStyle = palette.axis;
    ctx.setLineDash([4, 3]);
    ctx.beginPath();
    ctx.moveTo(baseX + 0.5, padTop);
    ctx.lineTo(baseX + 0.5, padTop + rows.length * rowH);
    ctx.stroke();
    ctx.setLineDash([]);
  }

  rows.forEach((row, index) => {
    const y = padTop + index * rowH + (rowH - barH) / 2;
    ctx.fillStyle = palette.fg;
    ctx.font = "11px -apple-system, 'PingFang SC', sans-serif";
    ctx.textAlign = "right";
    let name = String(row.name || "");
    while (name.length > 1 && ctx.measureText(name).width > labelW - 4) {
      name = name.slice(0, -2) + "…";
    }
    ctx.fillText(name, labelW, y + barH / 2);

    let fill = palette.series[0];
    if (row.ratio > 1) fill = palette.levels["风险"];
    else if (row.ratio >= 0.85) fill = palette.levels["关注"];
    ctx.fillStyle = fill;
    const barW = Math.max(2, plotW * Math.min(row.ratio / axisMax, 1));
    ctx.beginPath();
    ctx.roundRect
      ? ctx.roundRect(padLeft, y, barW, barH, 3)
      : ctx.rect(padLeft, y, barW, barH);
    ctx.fill();

    ctx.fillStyle = row.ratio > 1 ? palette.levels["风险"] : palette.fgDim;
    ctx.textAlign = "left";
    ctx.fillText(Math.round(row.ratio * 100) + "%",
                 padLeft + barW + 6, y + barH / 2);
  });
  return true;
}

/* 把四张图都包一层：画之前先按逻辑高度设置，画完不用管 */
function chartHeight(rows, base, rowH) {
  return Math.max(base, (rows || 0) * rowH + 34);
}
