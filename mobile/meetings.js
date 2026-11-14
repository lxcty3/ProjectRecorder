/* =============================================================
   会议 · 录音 + AI 总结
   音频默认只存本机（Capacitor Filesystem）；总结前临时上传，
   由 Edge Function 处理并删除云端音频。
   ============================================================= */
"use strict";

let meetingState = {
  list: [],
  loading: false,
  error: "",
  lastLoad: 0,
  recorder: null,
  stream: null,
  chunks: [],
  recordingId: "",
  startedAt: 0,
  timer: null,
  autoStop: null,
  blobs: {},
  audioUrl: "",
};

const MEETING_DB = "project-recorder-audio";
const MEETING_STORE = "audio";

function meetingOpenDb() {
  return new Promise((resolve, reject) => {
    if (!window.indexedDB) { reject(new Error("IndexedDB unavailable")); return; }
    const req = indexedDB.open(MEETING_DB, 1);
    req.onupgradeneeded = () => {
      if (!req.result.objectStoreNames.contains(MEETING_STORE)) {
        req.result.createObjectStore(MEETING_STORE, { keyPath: "id" });
      }
    };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

function meetingLocalPath(id) {
  return "meetings/" + String(id || "") + ".webm";
}

async function meetingSaveAudio(id, blob) {
  meetingState.blobs[String(id)] = blob;
  try {
    const db = await meetingOpenDb();
    await new Promise((resolve, reject) => {
      const tx = db.transaction(MEETING_STORE, "readwrite");
      tx.objectStore(MEETING_STORE).put({
        id: String(id),
        blob: blob,
        mime: blob.type || "audio/webm",
        savedAt: Date.now(),
      });
      tx.oncomplete = resolve;
      tx.onerror = () => reject(tx.error);
    });
    db.close();
  } catch (_) {}
}

async function meetingReadAudio(id) {
  const cached = meetingState.blobs[String(id)];
  if (cached) return cached;
  try {
    const db = await meetingOpenDb();
    const row = await new Promise((resolve, reject) => {
      const tx = db.transaction(MEETING_STORE, "readonly");
      const req = tx.objectStore(MEETING_STORE).get(String(id));
      req.onsuccess = () => resolve(req.result || null);
      req.onerror = () => reject(req.error);
    });
    db.close();
    return row && row.blob ? row.blob : null;
  } catch (_) {
    return null;
  }
}

async function meetingDeleteAudio(id) {
  delete meetingState.blobs[String(id)];
  try {
    const db = await meetingOpenDb();
    await new Promise((resolve, reject) => {
      const tx = db.transaction(MEETING_STORE, "readwrite");
      tx.objectStore(MEETING_STORE).delete(String(id));
      tx.oncomplete = resolve;
      tx.onerror = () => reject(tx.error);
    });
    db.close();
  } catch (_) {}
}

const MEETING_AI_KEY = "pr_meeting_ai_config";

function meetingAiConfig() {
  try {
    return JSON.parse(localStorage.getItem(MEETING_AI_KEY) || "{}") || {};
  } catch (_) {
    return {};
  }
}

function meetingHasAiConfig() {
  const cfg = meetingAiConfig();
  if (cfg.provider === "domestic") {
    return !!(cfg.asr_url && cfg.llm_url);
  }
  return !!cfg.gemini_key;
}

function openMeetingAiSettings() {
  const cfg = meetingAiConfig();
  const provider = cfg.provider === "domestic" ? "domestic" : "gemini";
  openSheet("AI 设置", `
    <label for="ai-provider">总结服务</label>
    <select id="ai-provider">
      <option value="gemini"${provider === "gemini" ? " selected" : ""}>Gemini</option>
      <option value="domestic"${provider === "domestic" ? " selected" : ""}>国内 ASR + 大模型</option>
    </select>
    <div id="ai-gemini-fields">
      <label for="ai-gemini-key">Gemini API Key</label>
      <input id="ai-gemini-key" type="password" autocomplete="off"
        value="${escapeHtml(cfg.gemini_key || "")}" placeholder="AIza...">
    </div>
    <div id="ai-domestic-fields">
      <label for="ai-asr-url">ASR 接口地址</label>
      <input id="ai-asr-url" value="${escapeHtml(cfg.asr_url || "")}" placeholder="https://...">
      <label for="ai-asr-key">ASR Key</label>
      <input id="ai-asr-key" type="password" value="${escapeHtml(cfg.asr_key || "")}">
      <label for="ai-llm-url">大模型接口地址</label>
      <input id="ai-llm-url" value="${escapeHtml(cfg.llm_url || "")}" placeholder="https://...">
      <label for="ai-llm-key">大模型 Key</label>
      <input id="ai-llm-key" type="password" value="${escapeHtml(cfg.llm_key || "")}">
      <label for="ai-llm-model">模型名</label>
      <input id="ai-llm-model" value="${escapeHtml(cfg.llm_model || "deepseek-chat")}">
    </div>
    <div class="hint">Key 只保存在本机浏览器/App 里，不会写入数据库；生成总结时随请求发给 Edge Function。</div>
  `, [
    { label: "取消", kind: "ghost", onClick: closeSheet },
    { label: "保存", kind: "", onClick: saveMeetingAiSettings },
  ]);
  const select = $("ai-provider");
  const sync = () => {
    const domestic = select && select.value === "domestic";
    if ($("ai-gemini-fields")) $("ai-gemini-fields").classList.toggle("hidden", domestic);
    if ($("ai-domestic-fields")) $("ai-domestic-fields").classList.toggle("hidden", !domestic);
  };
  if (select) { select.onchange = sync; sync(); }
}

function saveMeetingAiSettings() {
  const cfg = {
    provider: String(($("ai-provider") || {}).value || "gemini"),
    gemini_key: String(($("ai-gemini-key") || {}).value || "").trim(),
    asr_url: String(($("ai-asr-url") || {}).value || "").trim(),
    asr_key: String(($("ai-asr-key") || {}).value || "").trim(),
    llm_url: String(($("ai-llm-url") || {}).value || "").trim(),
    llm_key: String(($("ai-llm-key") || {}).value || "").trim(),
    llm_model: String(($("ai-llm-model") || {}).value || "deepseek-chat").trim(),
  };
  try {
    localStorage.setItem(MEETING_AI_KEY, JSON.stringify(cfg));
    closeSheet();
    toast("AI 设置已保存");
    renderMeetings();
  } catch (_) {
    toast("保存失败");
  }
}

function meetingErrorText(error) {
  const text = String(error && error.message || error || "");
  if (/could not find|does not exist|function/i.test(text)) return "会议功能还没注入 SQL";
  if (/consent/i.test(text)) return "录音前必须确认已征得参会者同意";
  if (/not allowed|organizer/i.test(text)) return "只有会议发起人能操作录音和总结";
  if (/GEMINI_API_KEY|not configured/i.test(text)) return "AI 服务还没配置 API Key";
  if (/audio download failed/i.test(text)) return "音频上传失败，请重试";
  return text || "会议操作失败";
}

async function loadMeetings(force) {
  if (!DB.profile || !initCloud()) return;
  const now = Date.now();
  if (!force && meetingState.lastLoad && now - meetingState.lastLoad < 8000) {
    renderMeetings();
    return;
  }
  meetingState.loading = true;
  meetingState.error = "";
  renderMeetings();
  try {
    const result = await cloudClient.rpc("list_meetings", { p_limit: 50 });
    if (result.error) throw result.error;
    meetingState.list = Array.isArray(result.data && result.data.meetings)
      ? result.data.meetings : [];
    meetingState.lastLoad = Date.now();
  } catch (error) {
    meetingState.error = meetingErrorText(error);
    meetingState.list = [];
  } finally {
    meetingState.loading = false;
    renderMeetings();
  }
}

function meetingDate(value) {
  const d = new Date(value || "");
  if (!isFinite(d.getTime())) return "";
  const pad = n => String(n).padStart(2, "0");
  return (d.getMonth() + 1) + "月" + d.getDate() + "日 "
    + pad(d.getHours()) + ":" + pad(d.getMinutes());
}

function meetingStatusText(status) {
  if (status === "ready") return "已总结";
  if (status === "recording") return "录音中";
  if (status === "processing") return "总结中";
  if (status === "failed") return "失败";
  return "待录音";
}

function meetingParticipantText(participants) {
  const list = Array.isArray(participants) ? participants : [];
  return list.map(p => p.name || p).filter(Boolean).join("、");
}

function meetingListHtml(value) {
  const list = Array.isArray(value) ? value : [];
  return list.length ? list.map(item => '<li>' + escapeHtml(
    typeof item === "string" ? item : JSON.stringify(item)) + '</li>').join("") : "";
}

function meetingCard(meeting) {
  const organizer = !!meeting.is_organizer;
  const ready = meeting.summary || meeting.transcript;
  const actions = Array.isArray(meeting.actions) ? meeting.actions : [];
  const decisions = Array.isArray(meeting.decisions) ? meeting.decisions : [];
  const risks = Array.isArray(meeting.risks) ? meeting.risks : [];
  return '<article class="meeting-card">'
    + '<div class="meeting-card-head"><div><b>' + escapeHtml(meeting.title || "会议")
    + '</b><div class="meta">' + escapeHtml(meetingDate(meeting.meeting_date))
    + (meeting.location ? " · " + escapeHtml(meeting.location) : "") + '</div></div>'
    + '<span class="meeting-status ' + escapeHtml(meeting.status || "draft") + '">'
    + escapeHtml(meetingStatusText(meeting.status)) + '</span></div>'
    + (meeting.agenda ? '<div class="meeting-agenda">' + escapeHtml(meeting.agenda) + '</div>' : '')
    + '<div class="meeting-meta">参会：' + escapeHtml(
      meetingParticipantText(meeting.participants) || "未指定")
    + ' · 发起：' + escapeHtml(meeting.organizer_name || "成员") + '</div>'
    + (ready
      ? '<details class="meeting-summary" open><summary>会议总结</summary>'
        + (meeting.summary ? '<div class="meeting-summary-text">' + escapeHtml(meeting.summary) + '</div>' : '')
        + (decisions.length ? '<div class="meeting-block"><b>关键决议</b><ul>'
          + meetingListHtml(decisions) + '</ul></div>' : '')
        + (actions.length ? '<div class="meeting-block"><b>待办</b><ul>'
          + actions.map(item => '<li>' + escapeHtml(item.task || "")
            + (item.owner ? " · " + escapeHtml(item.owner) : "")
            + (item.due ? " · " + escapeHtml(item.due) : "") + '</li>').join("") + '</ul></div>' : '')
        + (risks.length ? '<div class="meeting-block"><b>风险 / 分歧</b><ul>'
          + meetingListHtml(risks) + '</ul></div>' : '')
        + (meeting.transcript ? '<details class="meeting-transcript"><summary>逐字稿</summary><pre>'
          + escapeHtml(meeting.transcript) + '</pre></details>' : '')
        + '</details>'
      : '')
    + (meeting.error ? '<div class="meeting-error">' + escapeHtml(meeting.error) + '</div>' : '')
    + (organizer ? '<div class="meeting-actions">'
      + (meeting.status === "recording"
        ? '<button class="btn ghost" data-meeting-stop="' + escapeHtml(meeting.id) + '">停止录音</button>'
        : '<button class="btn" data-meeting-record="' + escapeHtml(meeting.id) + '">开始录音</button>')
      + (meeting.audio_path
        ? '<button class="btn ghost" data-meeting-play="' + escapeHtml(meeting.id) + '">播放录音</button>'
        : '')
      + (meeting.audio_path
        ? '<button class="btn ghost" data-meeting-summarize="' + escapeHtml(meeting.id) + '">生成总结</button>'
        : '')
      + '<button class="btn danger" data-meeting-delete="' + escapeHtml(meeting.id) + '">删除</button>'
      + '</div>' : '')
    + '</article>';
}

function renderMeetings() {
  const box = $("meeting-list");
  if (!box) return;
  const create = $("btn-meeting-create");
  if (create) create.onclick = openMeetingCreateSheet;
  if (meetingState.loading && !meetingState.list.length) {
    box.innerHTML = '<div class="identity-empty"><b>正在加载会议</b><span>读取会议记录…</span></div>';
    return;
  }
  if (meetingState.error) {
    box.innerHTML = '<div class="identity-empty"><b>会议暂时不可用</b><span>'
      + escapeHtml(meetingState.error) + '</span></div>';
    return;
  }
  if (!meetingState.list.length) {
    box.innerHTML = '<div class="identity-empty"><b>还没有会议</b>'
      + '<span>点「发起会议」，填好信息后开始录音。</span></div>';
    return;
  }
  const aiHint = meetingHasAiConfig() ? ""
    : '<div class="community-note">还没有配置 AI Key，点右上角「AI 设置」填写后才能生成总结。</div>';
  box.innerHTML = aiHint + meetingState.list.map(meetingCard).join("");
  box.querySelectorAll("[data-meeting-record]").forEach(button => {
    button.onclick = () => startMeetingRecording(button.dataset.meetingRecord);
  });
  box.querySelectorAll("[data-meeting-stop]").forEach(button => {
    button.onclick = stopMeetingRecording;
  });
  box.querySelectorAll("[data-meeting-summarize]").forEach(button => {
    button.onclick = () => summarizeMeeting(button.dataset.meetingSummarize);
  });
  box.querySelectorAll("[data-meeting-play]").forEach(button => {
    button.onclick = () => playMeetingAudio(button.dataset.meetingPlay);
  });
  box.querySelectorAll("[data-meeting-delete]").forEach(button => {
    button.onclick = () => deleteMeeting(button.dataset.meetingDelete);
  });
}

function openMeetingCreateSheet() {
  if (!DB.profile) { toast("登录后才能发起会议"); return; }
  const members = ((identityState() || {}).members || [])
    .filter(m => m.status === "active");
  const memberOptions = members.map(m =>
    '<label class="check meeting-member"><input type="checkbox" value="'
    + escapeHtml(m.profile_id) + '" data-name="' + escapeHtml(m.name || "成员")
    + '"> ' + escapeHtml(m.name || "成员") + '</label>').join("");
  const d = new Date();
  const local = new Date(d.getTime() - d.getTimezoneOffset() * 60000)
    .toISOString().slice(0, 16);
  openSheet("发起会议", `
    <label for="meeting-title">会议标题</label>
    <input id="meeting-title" maxlength="120" placeholder="例如：周会 / 项目复盘">
    <label for="meeting-date">时间</label>
    <input id="meeting-date" type="datetime-local" value="${local}">
    <label for="meeting-location">地点（可选）</label>
    <input id="meeting-location" maxlength="200" placeholder="会议室 / 线上">
    <label for="meeting-agenda">议程（可选）</label>
    <textarea id="meeting-agenda" maxlength="2000" placeholder="这次会议要讨论什么"></textarea>
    <div class="section-head"><span>参会人</span><span class="meta">可多选</span></div>
    <div class="meeting-members">${memberOptions || '<span class="meta">暂无可选成员</span>'}</div>
    <label class="check meeting-consent"><input type="checkbox" id="meeting-consent">
      我已征得参会者同意，允许本次会议录音</label>
  `, [
    { label: "取消", kind: "ghost", onClick: closeSheet },
    { label: "创建会议", kind: "", onClick: submitMeetingCreate },
  ]);
}

async function submitMeetingCreate() {
  const title = String(($("meeting-title") || {}).value || "").trim();
  const dateRaw = String(($("meeting-date") || {}).value || "");
  const location = String(($("meeting-location") || {}).value || "");
  const agenda = String(($("meeting-agenda") || {}).value || "");
  const consent = !!($("meeting-consent") || {}).checked;
  const participants = Array.from(document.querySelectorAll(".meeting-member input:checked"))
    .map(input => ({ profile_id: input.value, name: input.dataset.name || "" }));
  if (!title) { toast("先写会议标题"); return; }
  if (!consent) { toast("录音前必须确认已征得同意"); return; }
  const date = dateRaw ? new Date(dateRaw) : new Date();
  try {
    const result = await cloudClient.rpc("create_meeting", {
      p_title: title,
      p_date: date.toISOString(),
      p_location: location,
      p_agenda: agenda,
      p_participants: participants,
      p_consent: consent,
    });
    if (result.error) throw result.error;
    closeSheet();
    toast("会议已创建，可以开始录音");
    await loadMeetings(true);
  } catch (error) {
    toast(meetingErrorText(error));
  }
}

async function startMeetingRecording(meetingId) {
  if (meetingState.recorder) { toast("已经在录音中"); return; }
  if (!navigator.mediaDevices || !window.MediaRecorder) {
    toast("这个设备不支持录音");
    return;
  }
  try {
    const stream = await navigator.mediaDevices.getUserMedia({
      audio: { echoCancellation: true, noiseSuppression: true, channelCount: 1 },
    });
    const mime = MediaRecorder.isTypeSupported("audio/webm;codecs=opus")
      ? "audio/webm;codecs=opus" : "audio/webm";
    const recorder = new MediaRecorder(stream, {
      mimeType: mime,
      audioBitsPerSecond: 24000,
    });
    meetingState.recorder = recorder;
    meetingState.stream = stream;
    meetingState.chunks = [];
    meetingState.recordingId = String(meetingId);
    meetingState.startedAt = Date.now();
    recorder.ondataavailable = event => {
      if (event.data && event.data.size) meetingState.chunks.push(event.data);
    };
    recorder.onstop = finishMeetingRecording;
    recorder.start(1000);
    await cloudClient.rpc("update_meeting_status", {
      p_meeting: meetingId, p_status: "recording", p_error: "",
    });
    meetingState.timer = setInterval(renderRecordingTimer, 1000);
    meetingState.autoStop = setTimeout(stopMeetingRecording, 2 * 60 * 60 * 1000);
    toast("开始录音");
    await loadMeetings(true);
  } catch (error) {
    toast("无法开始录音：" + (error.message || error));
  }
}

function renderRecordingTimer() {
  const el = $("meeting-recording-timer");
  if (!el) return;
  const seconds = Math.floor((Date.now() - meetingState.startedAt) / 1000);
  el.textContent = String(Math.floor(seconds / 60)).padStart(2, "0")
    + ":" + String(seconds % 60).padStart(2, "0");
}

function stopMeetingRecording() {
  const recorder = meetingState.recorder;
  if (!recorder) return;
  if (meetingState.autoStop) clearTimeout(meetingState.autoStop);
  if (meetingState.timer) clearInterval(meetingState.timer);
  meetingState.timer = null;
  meetingState.autoStop = null;
  try { recorder.stop(); } catch (_) {}
  if (meetingState.stream) {
    meetingState.stream.getTracks().forEach(track => track.stop());
  }
  meetingState.stream = null;
}

async function finishMeetingRecording() {
  const id = meetingState.recordingId;
  const chunks = meetingState.chunks;
  meetingState.recorder = null;
  meetingState.chunks = [];
  meetingState.recordingId = "";
  if (!id || !chunks.length) return;
  const blob = new Blob(chunks, { type: "audio/webm" });
  if (blob.size > 100 * 1024 * 1024) {
    toast("录音超过 100MB，请分段录音");
    return;
  }
  try {
    await meetingSaveAudio(id, blob);
    await cloudClient.rpc("update_meeting_audio", {
      p_meeting: id, p_audio_path: meetingLocalPath(id),
    });
    toast("录音已保存到本机");
    await loadMeetings(true);
  } catch (error) {
    toast(meetingErrorText(error));
  }
}

async function summarizeMeeting(meetingId) {
  if (!initCloud()) return;
  const ai = meetingAiConfig();
  if (!meetingHasAiConfig()) {
    openMeetingAiSettings();
    return;
  }
  const blob = await meetingReadAudio(meetingId);
  if (!blob) { toast("本机找不到这段录音"); return; }
  const sessionResult = await cloudClient.auth.getSession();
  const session = sessionResult.data && sessionResult.data.session;
  if (!session || !session.access_token) { toast("请先登录"); return; }
  const path = String(DB.profile.id) + "/" + String(meetingId) + ".webm";
  try {
    await cloudClient.rpc("update_meeting_status", {
      p_meeting: meetingId, p_status: "processing", p_error: "",
    });
    const upload = await cloudClient.storage.from("meeting-audio").upload(path, blob, {
      contentType: blob.type || "audio/webm", upsert: true,
    });
    if (upload.error) throw upload.error;
    const response = await fetch(
      "https://projectrecorder-gateway-pages2.pages.dev/functions/v1/meeting-summary",
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: "Bearer " + session.access_token,
        },
        body: JSON.stringify({
          meeting_id: meetingId,
          audio_path: path,
          mime_type: blob.type || "audio/webm",
          ai: ai,
        }),
      }
    );
    const data = await response.json();
    if (!response.ok) throw new Error(data.error || "summary failed");
    toast("会议总结已生成");
    await loadMeetings(true);
  } catch (error) {
    await cloudClient.rpc("update_meeting_status", {
      p_meeting: meetingId, p_status: "failed", p_error: meetingErrorText(error),
    });
    toast(meetingErrorText(error));
    await loadMeetings(true);
  }
}

async function playMeetingAudio(meetingId) {
  const blob = await meetingReadAudio(meetingId);
  if (!blob) { toast("本机找不到这段录音"); return; }
  if (meetingState.audioUrl) URL.revokeObjectURL(meetingState.audioUrl);
  meetingState.audioUrl = URL.createObjectURL(blob);
  const audio = new Audio(meetingState.audioUrl);
  audio.play().catch(() => toast("播放失败"));
}

async function deleteMeeting(meetingId) {
  if (!confirm("删除这场会议？本机录音也会删除。")) return;
  try {
    const result = await cloudClient.rpc("delete_meeting", { p_meeting: meetingId });
    if (result.error) throw result.error;
    await meetingDeleteAudio(meetingId);
    toast("会议已删除");
    await loadMeetings(true);
  } catch (error) {
    toast(meetingErrorText(error));
  }
}

function bindMeetingEvents() {
  if ($("btn-meeting-refresh")) {
    $("btn-meeting-refresh").onclick = () => loadMeetings(true);
  }
  if ($("btn-meeting-ai")) {
    $("btn-meeting-ai").onclick = openMeetingAiSettings;
  }
  if ($("btn-meeting-create")) {
    $("btn-meeting-create").onclick = openMeetingCreateSheet;
  }
}
