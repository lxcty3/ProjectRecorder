"use strict";

/* Shareholder meetings: monthly regular meetings, special meetings,
   headcount approval, attendance, and leave records. */

let shareholderMeetingBusy = false;

function shareholderMeetingState() {
  if (!DB.shareholderMeetings || typeof DB.shareholderMeetings !== "object") {
    DB.shareholderMeetings = { data: null, at: 0, error: "" };
  }
  return DB.shareholderMeetings;
}

function clearShareholderMeetings() {
  DB.shareholderMeetings = { data: null, at: 0, error: "" };
  if (typeof saveAll === "function") saveAll();
  if (typeof renderShareholderMeetings === "function") renderShareholderMeetings();
}

async function meetingRpc(name, args) {
  if (!initCloud()) throw new Error("云服务没有加载");
  const { data, error } = await cloudClient.rpc(name, args || {});
  if (error) throw error;
  if (data && data.ok === false) {
    throw new Error(data.error || "股东大会操作没有权限");
  }
  return data || {};
}

function meetingStatusLabel(value) {
  return {
    pending_approval: "等股东同意", scheduled: "待召开", approved: "已同意",
    completed: "已完成", cancelled: "已取消", rejected: "未通过",
  }[String(value || "")] || String(value || "—");
}

function meetingTypeLabel(value) {
  return value === "regular" ? "月度例行" : value === "special" ? "临时会议" : "会议";
}

function meetingDate(value) {
  const text = String(value || "");
  if (!text) return "—";
  const when = new Date(text);
  if (Number.isNaN(when.getTime())) return text.replace("T", " ").slice(0, 16);
  return when.toLocaleString("zh-CN", {
    year: "numeric", month: "2-digit", day: "2-digit",
    hour: "2-digit", minute: "2-digit", hour12: false,
  });
}

function meetingDefaultDateTime() {
  const now = new Date();
  const last = new Date(now.getFullYear(), now.getMonth() + 1, 0).getDate();
  const day = Math.min(now.getDate() + 1, last);
  const target = new Date(now.getFullYear(), now.getMonth(), day, 18, 0);
  const pad = value => String(value).padStart(2, "0");
  return `${target.getFullYear()}-${pad(target.getMonth() + 1)}-${pad(target.getDate())}T18:00`;
}

function meetingErrorText(error) {
  const text = String((error && (error.message || error.details || error.hint)) || error || "");
  if (/record_shareholder_meeting_attendance_verified|shareholder-meeting-verification-v1/i.test(text)) {
    return "出席验证服务还没安装，请运行 mobile/sql/shareholder-meeting-verification-v1.sql。";
  }
  if (/verification failed|identity verification failed|account code verification required/i.test(text)) {
    return "身份验证失败：请输入当前登录账号的员工号或老板号。";
  }
  if (/could not find the function|does not exist/i.test(text)) {
    return "股东大会服务还没安装，请运行 shareholder-meetings-v1.sql。";
  }
  if (/only shareholders/i.test(text)) return "只有持股股东可以发起或表决。";
  if (/one active special meeting/i.test(text)) return "本月已经有一场有效临时股东大会。";
  if (/leave note required/i.test(text)) return "请假必须填写原因。";
  if (/current month/i.test(text)) return "临时会议必须安排在本月。";
  if (/governance authority|permission/i.test(text)) return "当前身份没有治理权限。";
  if (/jwt expired|not signed in/i.test(text)) return "登录状态过期，请重新登录。";
  return text || "股东大会操作失败";
}

async function loadShareholderMeetings(force) {
  if (!DB.profile) {
    clearShareholderMeetings();
    return;
  }
  const state = shareholderMeetingState();
  if (!force && state.at && Date.now() - state.at < 15000) {
    renderShareholderMeetings();
    return;
  }
  if (shareholderMeetingBusy) return;
  shareholderMeetingBusy = true;
  try {
    state.data = await meetingRpc("get_shareholder_meetings", {});
    state.error = "";
    state.at = Date.now();
    if (typeof saveAll === "function") saveAll();
    renderShareholderMeetings();
  } catch (error) {
    state.error = meetingErrorText(error);
    renderShareholderMeetings();
  } finally {
    shareholderMeetingBusy = false;
  }
}

function meetingAttendanceSummary(attendance) {
  const rows = Array.isArray(attendance) ? attendance : [];
  const attending = rows.filter(row => row.status === "attending").length;
  const leave = rows.filter(row => row.status === "leave").length;
  const absent = rows.filter(row => row.status === "absent").length;
  const leaveRows = rows.filter(row => row.status === "leave" && row.note);
  return {
    attending, leave, absent,
    text: `出席 ${attending} · 请假 ${leave} · 缺席 ${absent}`,
    leaveText: leaveRows.map(row => `${row.name || "股东"}：${row.note}`).join("；"),
  };
}

function renderShareholderMeetings() {
  const box = $("identity-meetings");
  if (!box) return;
  const state = shareholderMeetingState();
  const data = state.data || {};
  const meetings = Array.isArray(data.meetings) ? data.meetings : [];
  const access = data.access || {};
  const count = $("identity-meeting-count");
  if (count) count.textContent = `${meetings.filter(row => row.status === "pending_approval").length} 项待同意`;
  if (state.error) {
    box.innerHTML = `<div class="identity-empty"><b>股东大会暂时不可用</b><span>${escapeHtml(state.error)}</span></div>`;
    return;
  }
  if (!data.ok && !meetings.length) {
    box.innerHTML = `<div class="identity-empty"><b>股东大会未加载</b><span>请刷新企业身份。</span></div>`;
    return;
  }
  const monthStatus = {
    missing: "本月例行会议尚未建立", scheduled: "本月例行会议待召开",
    approved: "本月例行会议已同意", completed: "本月例行会议已完成",
  }[data.month_status] || "本月会议状态";
  const total = Number(data.total_shareholders || 0);
  const initiate = access.can_initiate_special
    ? '<button class="btn" id="btn-shareholder-meeting-initiate">发起临时股东大会</button>'
    : "";
  const cards = meetings.length ? meetings.slice(0, 12).map(item => {
    const attendance = meetingAttendanceSummary(item.attendance);
    const actions = item.actions || {};
    const buttons = [];
    if (actions.vote) {
      buttons.push(`<button class="btn ghost" data-meeting-vote="yes" data-meeting-id="${escapeHtml(item.id)}">同意召集</button>`);
      buttons.push(`<button class="btn ghost" data-meeting-vote="no" data-meeting-id="${escapeHtml(item.id)}">反对</button>`);
      buttons.push(`<button class="btn ghost" data-meeting-vote="abstain" data-meeting-id="${escapeHtml(item.id)}">弃权</button>`);
    }
    if (actions.attend) {
      buttons.push(`<button class="btn ghost" data-meeting-attend="attending" data-meeting-id="${escapeHtml(item.id)}">出席</button>`);
      buttons.push(`<button class="btn ghost" data-meeting-attend="leave" data-meeting-id="${escapeHtml(item.id)}">请假</button>`);
      buttons.push(`<button class="btn ghost" data-meeting-attend="absent" data-meeting-id="${escapeHtml(item.id)}">缺席</button>`);
    }
    if (actions.complete) {
      buttons.push(`<button class="btn ghost" data-meeting-complete="${escapeHtml(item.id)}">结束并记录纪要</button>`);
    }
    const voteLine = item.meeting_type === "special"
      ? `${Number(item.yes_count || 0)}/${Number(item.eligible_count || total)} 人同意，需超过半数`
      : "月度例行会议，无需召集表决";
    return `<article class="identity-motion ${item.status === 'pending_approval' ? 'open' : ''}">
      <div class="identity-motion-head"><div>
        <div class="identity-eyebrow">${escapeHtml(meetingTypeLabel(item.meeting_type))} · ${escapeHtml(meetingDate(item.scheduled_at))}</div>
        <b>${escapeHtml(item.title || "股东大会")}</b>
      </div><span class="identity-status ${item.status === 'pending_approval' ? 'open' : ''}">${escapeHtml(meetingStatusLabel(item.status))}</span></div>
      <div class="identity-vote-line"><span>${escapeHtml(voteLine)}</span><span>${escapeHtml(attendance.text)}</span></div>
      ${attendance.leaveText ? `<div class="identity-empty" style="padding:8px 0"><span>请假：${escapeHtml(attendance.leaveText)}</span></div>` : ""}
      ${buttons.length ? `<div class="identity-vote-actions">${buttons.join("")}</div>` : ""}
    </article>`;
  }).join("") : '<div class="identity-empty"><b>暂无会议记录</b><span>本月例行会议会自动建立。</span></div>';
  box.innerHTML = `<div class="identity-motion open">
    <div class="identity-motion-head"><div><div class="identity-eyebrow">${escapeHtml(data.month || "")}</div><b>${escapeHtml(monthStatus)}</b></div><span class="identity-status">${total} 位股东</span></div>
    <div class="identity-vote-line"><span>每月自动建立一次例行会议</span><span>临时会议必须填写特殊原因</span></div>
    ${initiate ? `<div class="identity-vote-actions">${initiate}</div>` : ""}
  </div>${cards}`;
  if ($("btn-shareholder-meeting-initiate")) {
    $("btn-shareholder-meeting-initiate").onclick = openShareholderMeetingInitiate;
  }
  box.querySelectorAll("[data-meeting-vote]").forEach(button => {
    button.onclick = () => shareholderMeetingVote(button.dataset.meetingId, button.dataset.meetingVote);
  });
  box.querySelectorAll("[data-meeting-attend]").forEach(button => {
    button.onclick = () => shareholderMeetingAttendance(button.dataset.meetingId, button.dataset.meetingAttend);
  });
  box.querySelectorAll("[data-meeting-complete]").forEach(button => {
    button.onclick = () => openShareholderMeetingComplete(button.dataset.meetingComplete);
  });
}

function openShareholderMeetingInitiate() {
  openSheet("发起临时股东大会", `
    <label for="meeting-title">会议标题</label>
    <input id="meeting-title" maxlength="120" placeholder="例如：重大项目风险临时会议">
    <label for="meeting-agenda">会议议程</label>
    <textarea id="meeting-agenda" maxlength="2000" placeholder="需要股东审议的事项"></textarea>
    <label for="meeting-scheduled">召开时间</label>
    <input id="meeting-scheduled" type="datetime-local" value="${meetingDefaultDateTime()}">
    <label for="meeting-reason">特殊原因</label>
    <textarea id="meeting-reason" maxlength="1000" placeholder="为什么必须在本月额外增加一次会议"></textarea>
    <div class="community-note">临时会议发起后需要超过半数股东同意。本月最多一场有效临时会议。</div>
  `, [
    { label: "取消", onClick: closeSheet },
    { label: "发起", kind: "", onClick: async () => {
      const title = $("meeting-title").value.trim();
      const agenda = $("meeting-agenda").value.trim();
      const reason = $("meeting-reason").value.trim();
      if (!title || !agenda || !reason) { toast("标题、议程和特殊原因都要填写"); return; }
      try {
        await meetingRpc("initiate_shareholder_meeting", {
          p_title: title, p_agenda: agenda,
          p_scheduled_at: new Date($("meeting-scheduled").value).toISOString(),
          p_reason: reason,
        });
        closeSheet(); toast("临时股东大会已发起，等待股东同意");
        await loadShareholderMeetings(true);
      } catch (error) { toast(meetingErrorText(error)); }
    } },
  ]);
}

async function shareholderMeetingVote(id, choice) {
  try {
    await meetingRpc("vote_shareholder_meeting", {
      p_meeting: id, p_choice: choice, p_note: "",
    });
    toast(choice === "yes" ? "已同意召集" : choice === "no" ? "已反对召集" : "已弃权");
    await loadShareholderMeetings(true);
  } catch (error) { toast(meetingErrorText(error)); }
}

function shareholderMeetingAttendance(id, status) {
  const data = shareholderMeetingState().data || {};
  const meeting = (data.meetings || []).find(item => String(item.id) === String(id)) || {};
  const labels = { attending: "出席", leave: "请假", absent: "缺席" };
  const action = labels[status] || "出席登记";
  const leave = status === "leave";
  const name = (DB.profile && DB.profile.name) || "当前账号";

  openSheet(`验证并登记${action}`, `
    <div class="identity-motion open" style="margin-bottom:12px">
      <div class="identity-motion-head"><div>
        <div class="identity-eyebrow">${escapeHtml(meetingDate(meeting.scheduled_at))}</div>
        <b>${escapeHtml(meeting.title || "股东大会")}</b>
      </div><span class="identity-status open">需要身份验证</span></div>
      <div class="identity-vote-line"><span>当前登录身份</span><span>${escapeHtml(name)}</span></div>
    </div>
    ${leave ? `
      <label for="meeting-leave-note">请假原因</label>
      <textarea id="meeting-leave-note" maxlength="500" placeholder="例如：外地出差、病假"></textarea>
    ` : ""}
    <label for="meeting-attendance-code">账号验证</label>
    <input id="meeting-attendance-code" autocapitalize="off" autocomplete="off"
           placeholder="输入你的员工号或老板号">
    <div class="hint">这一步用于确认是本人登记${action}。验证码只用于本次校验，不会保存输入内容。</div>
  `, [
    { label: "取消", onClick: closeSheet },
    { label: `验证并确认${action}`, kind: "", onClick: async () => {
      const note = leave ? $("meeting-leave-note").value.trim() : "";
      const code = $("meeting-attendance-code").value.trim();
      if (leave && !note) { toast("请假必须填写原因"); return; }
      if (!code) { toast("请输入当前账号的员工号或老板号"); return; }
      try {
        await meetingRpc("record_shareholder_meeting_attendance_verified", {
          p_meeting: id, p_status: status, p_note: note,
          p_verification_code: code,
        });
        closeSheet();
        toast(`${action}已登记并通过身份验证`);
        await loadShareholderMeetings(true);
      } catch (error) { toast(meetingErrorText(error)); }
    } },
  ]);
}

function openShareholderMeetingComplete(id) {
  openSheet("结束股东大会", `
    <label for="meeting-minutes">会议纪要</label>
    <textarea id="meeting-minutes" maxlength="8000" placeholder="记录会议结论、决议和待办事项"></textarea>
  `, [
    { label: "取消", onClick: closeSheet },
    { label: "确认结束", kind: "", onClick: async () => {
      const minutes = $("meeting-minutes").value.trim();
      if (!minutes) { toast("必须填写会议纪要"); return; }
      try {
        await meetingRpc("complete_shareholder_meeting", {
          p_meeting: id, p_minutes: minutes,
        });
        closeSheet(); toast("会议已完成"); await loadShareholderMeetings(true);
      } catch (error) { toast(meetingErrorText(error)); }
    } },
  ]);
}
