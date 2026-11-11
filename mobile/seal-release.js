#!/usr/bin/env node
/* =============================================================
   发布封包：给 latest.json 写入这次 APK 的 SHA-256 和大小。

   为什么单独一步：
     bump-version.js 只负责改版本号，那时 APK 还没构建出来，
     算不出真实的 SHA。等 gradlew assembleDebug 结束后再跑这个，
     应用内更新下载完才有东西可以校验。

   用法：
     node seal-release.js
   ============================================================= */
"use strict";

const fs = require("fs");
const path = require("path");
const crypto = require("crypto");

const HERE = __dirname;
const ROOT = path.resolve(HERE, "..");
const APK = path.join(
  HERE, "android", "app", "build", "outputs", "apk", "debug", "app-debug.apk"
);
const MANIFEST = path.join(ROOT, "latest.json");

if (!fs.existsSync(APK)) {
  console.error("找不到 APK：" + APK);
  console.error("先执行 gradlew.bat assembleDebug，再运行 node seal-release.js");
  process.exit(1);
}

const version = JSON.parse(
  fs.readFileSync(path.join(HERE, "version.json"), "utf8")
);
const buffer = fs.readFileSync(APK);
const sha256 = crypto.createHash("sha256").update(buffer).digest("hex");
const size = buffer.length;

const manifest = fs.existsSync(MANIFEST)
  ? JSON.parse(fs.readFileSync(MANIFEST, "utf8"))
  : {};

manifest.versionCode = version.versionCode;
manifest.versionName = version.versionName;
manifest.releasedAt = version.releasedAt;
manifest.notes = version.notes;
manifest.downloadUrl = version.downloadUrl;
manifest.sha256 = sha256;
manifest.size = size;

fs.writeFileSync(MANIFEST, JSON.stringify(manifest, null, 2) + "\n", "utf8");
console.log("已封包 " + manifest.versionName + " (" + size + " bytes)");
console.log("sha256 = " + sha256);
