"use strict";
const APP_UPDATE_MANIFEST_URL =
  "https://raw.githubusercontent.com/lxcty3/ProjectRecorder/main/latest.json";
const APP_UPDATE_CHECK_MS = 24 * 60 * 60 * 1000;
/* raw.githubusercontent 在国内经常被 reset；这里再备一个走 Cloudflare
   网关的 GitHub Release API，两个源任意一个能用就能检查更新。 */
const APP_UPDATE_API_URL =
  "https://projectrecorder-gateway-pages2.pages.dev/github-api/repos/lxcty3/ProjectRecorder/releases/latest";
let appUpdateBusy = false;

function appUpdateState() {
  if (!DB.appUpdate || typeof DB.appUpdate !== "object") {
    DB.appUpdate = { current: null, remote: null, checkedAt: 0, error: "" };
  }
  const state = DB.appUpdate;
  if (state.progress === undefined) state.progress = null;
  if (state.dismissed === undefined) state.dismissed = "";
  if (state.lastError === undefined) state.lastError = "";
  return state;
}

/* 原生更新插件。网页预览里没有它，自动退回浏览器下载。 */
function appUpdatePlugin() {
  try {
    const plugins = window.Capacitor && window.Capacitor.Plugins;
    return plugins && plugins.AppUpdate ? plugins.AppUpdate : null;
  } catch (_) {
    return null;
  }
}

async function loadCurrentAppVersion() {
  const state = appUpdateState();
  if (state.current) return state.current;
  try {
    const response = await fetch("./version.json", { cache: "no-store" });
    if (!response.ok) throw new Error("version.json unavailable");
    state.current = await response.json();
  } catch (_) {
    state.current = { versionCode: 0, versionName: "未知" };
  }
  return state.current;
}

function versionParts(name) {
  return String(name || "").replace(/^v/i, "")
    .split(/[^0-9]+/).filter(Boolean).map(Number);
}

/* 优先用 versionCode；Release API 回退时没有 code，就逐段比版本号。 */
function versionGreater(remote, current) {
  const rc = Number(remote && remote.versionCode);
  const cc = Number(current && current.versionCode);
  if (isFinite(rc) && rc > 0 && isFinite(cc) && cc > 0) return rc > cc;
  const a = versionParts(remote && remote.versionName);
  const b = versionParts(current && current.versionName);
  for (let i = 0; i < Math.max(a.length, b.length); i += 1) {
    const x = a[i] || 0;
    const y = b[i] || 0;
    if (x !== y) return x > y;
  }
  return false;
}

function releaseManifest(data) {
  if (!data || !data.tag_name) return null;
  const assets = Array.isArray(data.assets) ? data.assets : [];
  const apk = assets.find(item =>
    String(item && item.name || "").toLowerCase().endsWith(".apk"));
  if (!apk) return null;
  const notes = String(data.body || "")
    .split(/\r?\n/).map(line => line.trim()).filter(Boolean).slice(0, 6);
  return {
    versionCode: 0,
    versionName: String(data.tag_name).replace(/^v/i, ""),
    releasedAt: String(data.published_at || "").slice(0, 10),
    notes: notes,
    downloadUrl: apk.browser_download_url || apk.url || "",
    sha256: String(apk.digest || "").replace(/^sha256:/i, ""),
    size: Number(apk.size || 0),
  };
}

async function fetchUpdateManifest() {
  const sources = [APP_UPDATE_MANIFEST_URL, APP_UPDATE_API_URL];
  for (let i = 0; i < sources.length; i += 1) {
    try {
      const response = await fetch(sources[i], { cache: "no-store" });
      if (!response.ok) continue;
      const data = await response.json();
      if (i === 0 && data && (data.versionCode || data.versionName)) {
        return data;
      }
      const manifest = releaseManifest(data);
      if (manifest) return manifest;
    } catch (_) {
      /* 换下一个源 */
    }
  }
  throw new Error("更新服务暂时不可用");
}

function updateProgressHtml(state) {
  const progress = state.progress;
  if (!progress) return "";
  if (progress.phase === "downloading") {
    const percent = Number(progress.percent);
    const known = isFinite(percent) && percent >= 0;
    return `<div class="update-progress">
      <div class="update-progress-head">
        <span>${known ? "正在下载 " + percent + "%" : "正在下载…"}</span>
        <b>${known ? percent + "%" : ""}</b>
      </div>
      <div class="update-progress-track"><span style="width:${known ? Math.max(4, percent) : 28}%"></span></div>
    </div>`;
  }
  if (progress.phase === "verifying") {
    return `<div class="update-progress"><div class="meta">正在校验安装包…</div></div>`;
  }
  return "";
}

function renderAppUpdateCard() {
  const box = $("app-update-card");
  if (!box) return;
  const state = appUpdateState();
  const current = state.current || { versionCode: 0, versionName: "未知" };
  const remote = state.remote;
  const hasUpdate = remote && versionGreater(remote, current);
  const plugin = appUpdatePlugin();
  const status = state.error ? escapeHtml(state.error)
    : hasUpdate ? `发现新版本 ${escapeHtml(remote.versionName)}`
    : remote ? "已是最新版本" : "可以检查是否有新版本";
  box.innerHTML = `<div class="today-ledger-row">
    <div><b>当前版本 ${escapeHtml(current.versionName)}</b><span>${status}</span></div>
    <strong>${hasUpdate ? "可更新" : "已安装"}</strong>
  </div>
  ${hasUpdate ? `
    ${updateProgressHtml(state)}
    <button class="btn" id="btn-update-in-app" style="width:100%;margin-top:10px">
      ${plugin ? "应用内更新" : "打开新版下载页"}</button>
    <button class="btn ghost" id="btn-update-browser" style="width:100%;margin-top:8px">浏览器下载</button>
    ${remote.notes && remote.notes.length
      ? `<div class="update-notes">${remote.notes.map(note => `<div>· ${escapeHtml(note)}</div>`).join("")}</div>` : ""}
  ` : ""}`;
  if ($("btn-update-in-app")) $("btn-update-in-app").onclick = () => openAppUpdate(remote);
  if ($("btn-update-browser")) $("btn-update-browser").onclick = () => openAppUpdateInBrowser(remote);
}

async function checkForAppUpdate(force) {
  if (appUpdateBusy) return null;
  const state = appUpdateState();
  await loadCurrentAppVersion();
  if (!force && state.checkedAt && Date.now() - state.checkedAt < APP_UPDATE_CHECK_MS) {
    renderAppUpdateCard();
    if (state.remote && versionGreater(state.remote, state.current)) {
      showUpdatePrompt(state.remote);
    }
    return state.remote;
  }
  appUpdateBusy = true;
  try {
    const remote = await fetchUpdateManifest();
    state.remote = remote;
    state.checkedAt = Date.now();
    state.error = "";
    if (Number(remote.versionCode) > Number(state.current.versionCode)) {
      showUpdatePrompt(remote);
    } else if (force) {
      toast("已经是最新版本");
    }
  } catch (error) {
    state.error = "暂时无法检查更新";
    if (force) toast(state.error);
  } finally {
    appUpdateBusy = false;
    saveAll();
    renderAppUpdateCard();
  }
  return state.remote;
}

/* 启动时的小提示：可关闭，同一版本只提醒一次。 */
function showUpdatePrompt(remote) {
  if (!remote) return;
  const state = appUpdateState();
  if (String(state.dismissed) === String(remote.versionCode)) return;
  const box = $("update-prompt");
  if (!box) return;
  box.innerHTML = `<div class="update-prompt-inner">
    <div class="update-prompt-copy">
      <b>发现新版本 ${escapeHtml(remote.versionName)}</b>
      <span>应用内下载，安装后数据保留</span>
    </div>
    <button class="btn" id="update-prompt-go">更新</button>
    <button class="update-prompt-close" id="update-prompt-close" aria-label="关闭">×</button>
  </div>`;
  box.classList.remove("hidden");
  if ($("update-prompt-go")) {
    $("update-prompt-go").onclick = () => {
      hideUpdatePrompt();
      openAppUpdate(remote);
    };
  }
  if ($("update-prompt-close")) {
    $("update-prompt-close").onclick = () => {
      state.dismissed = String(remote.versionCode);
      saveAll();
      hideUpdatePrompt();
    };
  }
}

function hideUpdatePrompt() {
  const box = $("update-prompt");
  if (box) box.classList.add("hidden");
}

function openAppUpdateInBrowser(remote) {
  const url = remote && remote.downloadUrl;
  if (!url) { toast("更新地址还没有配置"); return; }
  window.open(url, "_blank", "noopener");
}

function openAppUpdate(remote) {
  const plugin = appUpdatePlugin();
  if (!plugin) {
    openAppUpdateInBrowser(remote);
    return;
  }
  startNativeUpdate(remote, plugin);
}

function openUpdateSheet(title, bodyHtml, buttons) {
  if (typeof openSheet === "function") {
    openSheet(title, bodyHtml,
      buttons || [{ label: "关闭", kind: "ghost", onClick: closeSheet }]);
  } else {
    toast(String(bodyHtml || "").replace(/<[^>]+>/g, ""));
  }
}

function updateDownloadBody(percent, text) {
  const known = isFinite(percent) && percent >= 0;
  return `<div class="update-sheet">
    <b id="update-sheet-title">${escapeHtml(text || "正在下载更新…")}</b>
    <div class="update-progress-track"><span id="update-sheet-bar" style="width:${known ? Math.max(4, percent) : 28}%"></span></div>
    <div class="update-progress-foot"><span id="update-sheet-percent">${known ? percent + "%" : ""}</span></div>
  </div>`;
}

async function startNativeUpdate(remote, plugin) {
  const state = appUpdateState();
  if (state.progress && state.progress.phase === "downloading") {
    toast("正在下载中，请稍候");
    return;
  }
  const safeVersion = String(remote.versionName || "latest")
    .replace(/[^0-9A-Za-z._-]/g, "_");
  const fileName = "ProjectRecorder-" + safeVersion + ".apk";
  state.progress = { phase: "downloading", percent: 0 };
  state.error = "";
  renderAppUpdateCard();

  openUpdateSheet("应用更新", updateDownloadBody(0, "正在下载 " + remote.versionName + "…"), [
    { label: "取消", kind: "ghost", onClick: () => {
      try { if (plugin.cancel) plugin.cancel(); } catch (_) {}
      state.progress = null;
      closeSheet();
      renderAppUpdateCard();
    } },
  ]);

  let listener = null;
  const applyPercent = percent => {
    const known = isFinite(percent) && percent >= 0;
    const bar = document.getElementById("update-sheet-bar");
    if (bar) bar.style.width = (known ? Math.max(4, percent) : 28) + "%";
    const label = document.getElementById("update-sheet-percent");
    if (label) label.textContent = known ? percent + "%" : "";
    state.progress = { phase: "downloading", percent: known ? percent : -1 };
  };

  try {
    if (plugin.addListener) {
      listener = await plugin.addListener("updateProgress", data => {
        const raw = Number(data && data.percent);
        applyPercent(isFinite(raw) ? raw : -1);
      });
    }
    const result = await plugin.download({
      url: remote.downloadUrl,
      fileName: fileName,
      expectedSha256: remote.sha256 || "",
    });
    if (listener && listener.remove) { try { listener.remove(); } catch (_) {} }
    state.progress = { phase: "verifying", percent: 100 };
    renderAppUpdateCard();
    const savedName = result && result.fileName ? result.fileName : fileName;
    showInstallReady(remote, savedName);
  } catch (error) {
    if (listener && listener.remove) { try { listener.remove(); } catch (_) {} }
    state.progress = null;
    const code = String(error && error.code || "");
    const message = appUpdateErrorMessage(code, error);
    state.error = message;
    saveAll();
    renderAppUpdateCard();
    showUpdateError(message, remote);
  }
}

function appUpdateErrorMessage(code, error) {
  if (code === "sha_mismatch") return "安装包校验失败，已停止安装";
  if (code === "cancelled") return "下载已取消";
  if (code === "download_failed") return "下载失败，请检查网络后重试";
  if (code === "install_permission_required") return "需要允许安装未知应用";
  if (code === "apk_missing") return "安装包不存在，请重新下载";
  if (code === "installer_failed") return "无法启动系统安装器";
  return String(error && error.message || error || "更新失败");
}

function showInstallReady(remote, fileName) {
  openUpdateSheet("应用更新", `<div class="update-sheet">
    <b>${escapeHtml(remote.versionName)} 下载完成</b>
    <p class="meta">安装会覆盖旧版本，本地数据会保留。首次安装需要允许“安装未知应用”。</p>
  </div>`, [
    { label: "稍后", kind: "ghost", onClick: closeSheet },
    { label: "立即安装", kind: "", onClick: () => attemptInstall(fileName, remote) },
  ]);
}

async function attemptInstall(fileName, remote) {
  const plugin = appUpdatePlugin();
  if (!plugin) { openAppUpdateInBrowser(remote); return; }
  try {
    await plugin.install({ fileName: fileName });
    closeSheet();
    toast("已打开系统安装器");
  } catch (error) {
    const code = String(error && error.code || "");
    if (code === "install_permission_required") {
      showInstallPermission(fileName, remote);
      return;
    }
    const message = appUpdateErrorMessage(code, error);
    toast(message);
    showUpdateError(message, remote);
  }
}

function showInstallPermission(fileName, remote) {
  openUpdateSheet("需要安装权限", `<div class="update-sheet">
    <b>允许安装未知应用</b>
    <p class="meta">Android 需要你在系统设置里允许“项目记录器”安装应用。开启后返回这里，再点“立即安装”。</p>
  </div>`, [
    { label: "取消", kind: "ghost", onClick: closeSheet },
    { label: "去设置", kind: "", onClick: () => {
      const plugin = appUpdatePlugin();
      try { if (plugin && plugin.openInstallSettings) plugin.openInstallSettings(); } catch (_) {}
    } },
    { label: "已开启，重试", kind: "", onClick: () => attemptInstall(fileName, remote) },
  ]);
}

function showUpdateError(message, remote) {
  openUpdateSheet("更新失败", `<div class="update-sheet">
    <b>${escapeHtml(message)}</b>
    <p class="meta">可以重试，或改用浏览器下载安装包。</p>
  </div>`, [
    { label: "关闭", kind: "ghost", onClick: closeSheet },
    { label: "浏览器下载", kind: "", onClick: () => openAppUpdateInBrowser(remote) },
  ]);
}

function bindAppUpdateEvents() {
  if ($("btn-check-update")) {
    $("btn-check-update").onclick = () => checkForAppUpdate(true);
  }
  renderAppUpdateCard();
}
