#!/usr/bin/env node
/* =============================================================
   打包前检查：不会做出"装上去打不开"的 apk。

   ## 为什么要专门做这个检查

   另一个 AI 接入了 FCM 推送插件，但没配 google-services.json。
   结果是**装上之后 App 直接崩在启动**：

       FATAL EXCEPTION: CapacitorPlugins
       Caused by: java.lang.IllegalStateException:
           Default FirebaseApp is not initialized in this process
           at ...FirebaseMessaging.getInstance
           at ...PushNotificationsPlugin.register

   插件的 register() 直接调 FirebaseMessaging.getInstance()，
   没有先判断 Firebase 是否可用；Capacitor 把它当致命错误，
   **界面还没出来进程就没了**。JS 的 try/catch 救不了（原生异常）。

   更麻烦的是：**这种崩不该由用户发现**。用户装完打不开，
   既看不到界面也看不到原因，只能来问人。

   所以打包前先自查这几条，任何一条不满足就直接拦住。

   用法：
     node preflight-apk.js
   ============================================================= */
"use strict";

const fs = require("fs");
const path = require("path");

const HERE = __dirname;
const ANDROID = path.join(HERE, "android");
const APP = path.join(ANDROID, "app");

let failed = 0;
let passed = 0;

function ok(label, detail) {
  passed += 1;
  console.log("  [OK]   " + label + (detail ? "  " + detail : ""));
}
function bad(label, detail) {
  failed += 1;
  console.log("  [失败] " + label);
  if (detail) console.log("         " + detail);
}

function read(file) {
  return fs.existsSync(file) ? fs.readFileSync(file, "utf8") : null;
}

console.log("=".repeat(64));
console.log("打包前检查（防止做出打不开的 apk）");
console.log("=".repeat(64));

/* ---------- 1. 推送插件 vs Firebase 配置 ---------- */
console.log("\n[1] 推送插件与 Firebase 配置的配对");
const pkg = JSON.parse(read(path.join(HERE, "package.json")) || "{}");
const hasPush = !!(pkg.dependencies
  && pkg.dependencies["@capacitor/push-notifications"]);
const hasFirebaseJson = fs.existsSync(
  path.join(APP, "google-services.json"));

if (!hasPush) {
  ok("没有装推送插件（FCM 不参与，不会崩）");
} else if (hasFirebaseJson) {
  ok("装了推送插件，而且有 google-services.json");
} else {
  /* 装了插件却没配置文件——这正是崩溃的场景。
     必须确认构建脚本里有"没配置就摘掉插件"的保护。 */
  const gradle = read(path.join(APP, "build.gradle")) || "";
  const hasStrip = gradle.indexOf("stripPushPluginIfNoFirebase") !== -1
    && gradle.indexOf("pushnotifications") !== -1;
  const main = read(path.join(APP,
    "src/main/java/com/cj/projectrecorder/MainActivity.java")) || "";
  const hasGuard = main.indexOf("FIREBASE_CONFIGURED") !== -1;

  if (hasStrip && hasGuard) {
    ok("装了推送插件，没有配置文件 —— "
      + "但构建时会自动摘掉它（有保护）");
  } else {
    bad("装了推送插件，但既没有 google-services.json "
      + "也没有构建保护",
      "这样打出来的 apk **装上就会崩在启动**，界面都出不来。\n"
      + "        要么放一个 google-services.json 到 android/app/，\n"
      + "        要么在 app/build.gradle 里加 stripPushPluginIfNoFirebase。");
  }
}

/* ---------- 2. 保护代码真的会被执行 ---------- */
console.log("\n[2] 保护代码的接线");
if (hasPush && !hasFirebaseJson) {
  const gradle = read(path.join(APP, "build.gradle")) || "";
  /* 必须赶在 assets 合并之前跑，否则清单已经被打包了 */
  if (/merge\w*Assets/.test(gradle)
      || gradle.indexOf("preBuild.dependsOn") !== -1) {
    ok("摘插件的任务挂在打包流程上（不会漏跑）");
  } else {
    bad("stripPushPluginIfNoFirebase 没有挂到打包流程",
      "任务定义了但没人调，等于没做");
  }
  /* BuildConfig 开关要打开，否则 MainActivity 编不过 */
  if (gradle.indexOf("buildConfig = true") !== -1) {
    ok("buildConfig 已启用（MainActivity 要用它）");
  } else {
    bad("buildFeatures.buildConfig 没打开",
      "MainActivity 里的 BuildConfig.FIREBASE_CONFIGURED 会编译失败");
  }
} else {
  ok("（不需要这道保护）");
}

/* ---------- 3. 插件清单不能残留崩溃项 ---------- */
console.log("\n[3] 打包用的插件清单");
const manifestPath = path.join(APP, "src/main/assets/capacitor.plugins.json");
const manifestText = read(manifestPath);
if (!manifestText) {
  bad("找不到 capacitor.plugins.json");
} else {
  let list = null;
  try { list = JSON.parse(manifestText); } catch (error) {
    bad("capacitor.plugins.json 不是合法 JSON", error.message);
  }
  if (list) {
    const names = list.map(item => item.classpath || item.pkg || "?");
    const pushInList = names.some(n => String(n).indexOf("pushnotifications") >= 0);
    if (pushInList && !hasFirebaseJson) {
      bad("插件清单里还有推送插件，而 Firebase 没配置",
        "**这会在启动时抛 IllegalStateException 并杀掉进程**。\n"
        + "        跑一次 ./gradlew assembleDebug 让它自动摘掉，\n"
        + "        或者手动从 capacitor.plugins.json 里删掉那一条。");
    } else {
      ok("插件清单与配置一致", names.length + " 个插件");
    }
  }
}

/* ---------- 4. 关键文件都在 ---------- */
console.log("\n[4] 关键文件");
[
  ["android/app/build.gradle", path.join(APP, "build.gradle")],
  ["MainActivity.java", path.join(APP,
    "src/main/java/com/cj/projectrecorder/MainActivity.java")],
  ["index.html", path.join(HERE, "index.html")],
  ["vendor/supabase.js", path.join(HERE, "vendor", "supabase.js")],
].forEach(([label, file]) => {
  if (fs.existsSync(file)) ok(label + " 在");
  else bad(label + " 不见了", file);
});

/* ---------- 5. 应用内自动更新 ---------- */
console.log("\n[5] 应用内自动更新");
const updatePluginPath = path.join(APP,
  "src/main/java/com/cj/projectrecorder/AppUpdatePlugin.java");
const mainActivity = read(path.join(APP,
  "src/main/java/com/cj/projectrecorder/MainActivity.java")) || "";
const androidManifest = read(path.join(APP,
  "src/main/AndroidManifest.xml")) || "";
const filePaths = read(path.join(APP,
  "src/main/res/xml/file_paths.xml")) || "";
const updateJs = read(path.join(HERE, "update.js")) || "";

if (!fs.existsSync(updatePluginPath)) {
  bad("AppUpdatePlugin.java 不存在");
} else {
  ok("原生更新插件存在");
}
if (mainActivity.indexOf("AppUpdatePlugin.class") === -1) {
  bad("MainActivity 没有注册 AppUpdatePlugin");
} else {
  ok("AppUpdatePlugin 已注册");
}
if (androidManifest.indexOf("REQUEST_INSTALL_PACKAGES") === -1) {
  bad("AndroidManifest 缺少 REQUEST_INSTALL_PACKAGES",
    "没有这条权限，系统安装器打不开。");
} else {
  ok("安装权限已声明");
}
if (filePaths.indexOf("cache-path") === -1) {
  bad("file_paths.xml 没有 cache-path，FileProvider 分享不到下载的 APK");
} else {
  ok("FileProvider 覆盖缓存目录");
}
for (const token of [
  "appUpdatePlugin", "expectedSha256",
  "install_permission_required", "openAppUpdateInBrowser",
]) {
  if (updateJs.indexOf(token) === -1) {
    bad("update.js 缺少 " + token);
  }
}
if (updateJs.indexOf("appUpdatePlugin") !== -1
    && updateJs.indexOf("expectedSha256") !== -1
    && updateJs.indexOf("install_permission_required") !== -1
    && updateJs.indexOf("openAppUpdateInBrowser") !== -1) {
  ok("update.js 下载 / 校验 / 安装 / 兜底齐全");
}

/* ---------- 汇总 ---------- */
console.log("\n" + "=".repeat(64));
if (failed) {
  console.log("失败 " + failed + " 项，通过 " + passed + " 项");
  console.log("");
  console.log("**先修好再打包**，否则用户装上会打不开。");
  process.exit(1);
}
console.log("全部通过（" + passed + " 项），可以打包。");
