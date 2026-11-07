"use strict";
const APP_UPDATE_MANIFEST_URL =
  "https://raw.githubusercontent.com/lxcty3/ProjectRecorder/main/latest.json";
const APP_UPDATE_CHECK_MS = 24*60*60*1000;
let appUpdateBusy = false;

function appUpdateState() {
  if (!DB.appUpdate || typeof DB.appUpdate !== "object") {
    DB.appUpdate = { current: null, remote: null, checkedAt: 0, error: "" };
  }
  return DB.appUpdate;
}

async function loadCurrentAppVersion() {
  const state=appUpdateState();
  if (state.current) return state.current;
  try {
    const response=await fetch("./version.json",{cache:"no-store"});
    if (!response.ok) throw new Error("version.json unavailable");
    state.current=await response.json();
  } catch (_) {
    state.current={versionCode:0,versionName:"未知"};
  }
  return state.current;
}

function renderAppUpdateCard() {
  const box=$("app-update-card");
  if (!box) return;
  const state=appUpdateState();
  const current=state.current||{versionCode:0,versionName:"未知"};
  const remote=state.remote;
  const hasUpdate=remote && Number(remote.versionCode)>Number(current.versionCode);
  const status=state.error ? escapeHtml(state.error)
    : hasUpdate ? `发现新版本 ${escapeHtml(remote.versionName)}`
    : remote ? "已是最新版本" : "可以检查是否有新版本";
  box.innerHTML=`<div class="today-ledger-row">
    <div><b>当前版本 ${escapeHtml(current.versionName)}</b><span>${status}</span></div>
    <strong>${hasUpdate ? "可更新" : "已安装"}</strong>
  </div>
  ${hasUpdate ? `<button class="btn" id="btn-download-update" style="width:100%;margin-top:10px">打开新版下载页</button>` : ""}`;
  if ($("btn-download-update")) {
    $("btn-download-update").onclick=()=>openAppUpdate(remote);
  }
}

async function checkForAppUpdate(force) {
  if (appUpdateBusy) return null;
  const state=appUpdateState();
  await loadCurrentAppVersion();
  if (!force && state.checkedAt && Date.now()-state.checkedAt<APP_UPDATE_CHECK_MS) {
    renderAppUpdateCard();
    return state.remote;
  }
  appUpdateBusy=true;
  try {
    const response=await fetch(APP_UPDATE_MANIFEST_URL,{cache:"no-store"});
    if (!response.ok) throw new Error("更新服务暂时不可用");
    const remote=await response.json();
    state.remote=remote;
    state.checkedAt=Date.now();
    state.error="";
    if (Number(remote.versionCode)>Number(state.current.versionCode)) {
      toast(`发现新版本 ${remote.versionName}`);
    } else if (force) {
      toast("已经是最新版本");
    }
  } catch (error) {
    state.error="暂时无法检查更新";
    if (force) toast(state.error);
  } finally {
    appUpdateBusy=false;
    saveAll();
    renderAppUpdateCard();
  }
  return state.remote;
}

function openAppUpdate(remote) {
  const url=remote && remote.downloadUrl;
  if (!url) { toast("更新地址还没有配置"); return; }
  window.open(url,"_blank","noopener");
}

function bindAppUpdateEvents() {
  if ($("btn-check-update")) {
    $("btn-check-update").onclick=()=>checkForAppUpdate(true);
  }
  renderAppUpdateCard();
}
