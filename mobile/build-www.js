/* =============================================================
   把手机版的网页文件复制到 www/，供 Capacitor 打包。

   为什么要多这一层：
     Capacitor 需要一个「网页目录」，而工程根目录里有
     node_modules、android/、package.json 这些东西，
     不能让它们被打进 apk。

     所以：根目录是**源码**（你自己在浏览器里打开 index.html 就能测），
     www/ 是**打包用的副本**（自动生成，不要手改）。

   用法：
     node build-www.js
   ============================================================= */
"use strict";

const fs = require("fs");
const path = require("path");

const HERE = __dirname;
const OUT = path.join(HERE, "www");

/* 打进去的文件。加新文件时记得也加到这里，
   否则 apk 里缺文件，表现为「点某个功能白屏」。 */
const FILES = [
  "index.html",
  "style.css",
  "cloud-config.js",
  "store.js",
  "calc.js",
  "charts.js",
  "merit.js",
  "assist.js",
  "sync.js",
  "notify.js",
  "meeting.js",
  "update.js",
  "version.json",
  "identity.js",
  "companies.js",
  "today.js",
  "decision.js",
  "operations.js",
  "execution.js",
  "intake.js",
  "phone-preview.html",
  "intake.html",
  "public-intake.js",
  "account.js",
  "community.js",
  "app.js",
];

/* 云库。由 fetch-vendor.js 下载，**必须打进 apk**——
   用 CDN 引用的话，App 离线时就加载不上，
   而"员工在外面报工时"正是没网的场景。
   缺这个文件不致命（本机功能照常用），所以只警告不中断。 */
const VENDOR_DIR = "vendor";
const VENDOR = ["supabase.js", "qrcode.min.js"];

/* 头像目录。由 prepare-avatars.py 生成，两种版本：
     名字.webp          脸特写（小尺寸用）
     名字@hero.webp     整身立绘（大尺寸用，边缘由 CSS 羽化）
   头像缺失不会让程序崩，但界面会缺一块——
   所以这里**检查每个表情的两种版本都在**，缺了就报出来。 */
const ICON_DIR = "icons";
const MOODS = ["01_嗯", "02_好耶", "03_睡觉", "04_疑惑", "05_哼",
               "06_惊讶", "07_抱抱", "08_嗯嗯", "09_暗中观察"];

/* 这些不进 apk：
     selfcheck.js / e2e-cloud.js       电脑上跑的验证脚本
     build-www.js / build-devtools.js  构建脚本自己
     fetch-vendor.js                   下载云库的脚本
     *.py                              图片处理工具
     devtools/                         开发用测试页（bootcheck / e2e-ui）
     node_modules / android / www      依赖或构建产物

   **devtools 必须排除**：那里面放了一份 App 文件的副本，
   不排除的话有可能被打进去，白占体积。
*/
function main() {
  if (!fs.existsSync(OUT)) fs.mkdirSync(OUT, { recursive: true });

  let copied = 0;
  const missing = [];
  FILES.forEach(name => {
    const from = path.join(HERE, name);
    if (!fs.existsSync(from)) { missing.push(name); return; }
    fs.copyFileSync(from, path.join(OUT, name));
    copied += 1;
  });

  if (missing.length) {
    console.error("缺少这些文件，apk 里会少东西：");
    missing.forEach(name => console.error("  " + name));
    process.exit(1);
  }

  /* ---- 头像 ----
     每个表情需要两个文件：脸特写和整身立绘。
     少任何一个，界面上对应的头像就是空白（不会报错，只会缺一块），
     所以这里显式检查。 */
  const iconOut = path.join(OUT, ICON_DIR);
  if (!fs.existsSync(iconOut)) fs.mkdirSync(iconOut, { recursive: true });

  const missingIcons = [];
  let iconCount = 0;
  MOODS.forEach(mood => {
    [`${mood}.webp`, `${mood}@hero.webp`].forEach(file => {
      const from = path.join(HERE, ICON_DIR, file);
      if (!fs.existsSync(from)) { missingIcons.push(file); return; }
      fs.copyFileSync(from, path.join(iconOut, file));
      iconCount += 1;
    });
  });

  if (missingIcons.length) {
    console.error("\n缺少头像文件（先跑 py prepare-avatars.py）：");
    missingIcons.forEach(name => console.error("  icons/" + name));
    process.exit(1);
  }

  /* ---- 星轨陪伴表情 ---- */
  const starSrcDir = path.join(HERE, ICON_DIR, "star");
  const starOutDir = path.join(iconOut, "star");
  let starCount = 0;
  if (fs.existsSync(starSrcDir)) {
    fs.cpSync(starSrcDir, starOutDir, { recursive: true });
    starCount = fs.readdirSync(starOutDir).filter(name => name.endsWith(".webp")).length;
  }
  if (starCount < 32) {
    console.error("\n星轨陪伴表情不足 32 个文件，请先运行：py prepare-star-stickers.py");
    process.exit(1);
  }

  /* ---- 云库 ----
     缺了不中断，只警告：没有云库时本机功能照常能用，
     只是登录用不了。硬中断的话，一个还没配云服务的用户
     会连打包都做不了，没必要。 */
  const vendorOut = path.join(OUT, VENDOR_DIR);
  if (!fs.existsSync(vendorOut)) fs.mkdirSync(vendorOut, { recursive: true });
  let vendorCount = 0;
  const missingVendor = [];
  VENDOR.forEach(file => {
    const from = path.join(HERE, VENDOR_DIR, file);
    if (!fs.existsSync(from)) { missingVendor.push(file); return; }
    fs.copyFileSync(from, path.join(vendorOut, file));
    vendorCount += 1;
  });

  /* 清理 www 里已经不在清单里的旧文件——
     否则删掉的文件会一直留在 apk 里。
     注意 icons 和 vendor 要留着，它们不在 FILES 里但必须保留。 */
  const keep = FILES.concat([ICON_DIR, VENDOR_DIR]);
  fs.readdirSync(OUT).forEach(name => {
    if (keep.indexOf(name) === -1) {
      fs.rmSync(path.join(OUT, name), { recursive: true, force: true });
      console.log("  清理掉旧文件：" + name);
    }
  });

  console.log(`已复制 ${copied} 个文件 + ${iconCount} 个头像到 www/：`);
  FILES.forEach(name => console.log("  " + name));
  console.log(`  ${ICON_DIR}/  （${iconCount} 个文件）`);
  console.log(`  ${ICON_DIR}/star/  （${starCount} 个星轨表情）`);
  if (vendorCount) {
    console.log(`  ${VENDOR_DIR}/  （${vendorCount} 个文件）`);
  } else {
    console.log();
    console.log("⚠ 没有 vendor/supabase.js —— 登录功能用不了。");
    console.log("  跑这条下载：node fetch-vendor.js");
    console.log("  （本机功能不受影响，可以先打包用着）");
  }
  console.log("\n下一步：npx cap sync android");
}

main();
