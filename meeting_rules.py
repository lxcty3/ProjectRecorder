"""Pure shareholder-meeting rules shared by tests and client guards."""

from __future__ import annotations

from datetime import date, datetime, timezone

MEETING_TYPES = ("regular", "special")
MEETING_STATUSES = ("pending_approval", "scheduled", "completed", "cancelled", "rejected")
ATTENDANCE_STATUSES = ("pending", "attending", "absent", "leave")
ACTIVE_SCHEDULE_STATUSES = ("scheduled", "approved")


def _text(value):
    return str(value or "").strip()


def _datetime(value, fallback=None):
    if isinstance(value, datetime):
        result = value
    else:
        text = _text(value)
        if not text:
            return fallback or datetime.now(timezone.utc)
        try:
            result = datetime.fromisoformat(text.replace("Z", "+00:00"))
        except ValueError:
            return fallback or datetime.now(timezone.utc)
    if result.tzinfo is None:
        result = result.replace(tzinfo=timezone.utc)
    return result


def majority_required(total):
    try:
        total = max(int(total or 0), 0)
    except (TypeError, ValueError):
        total = 0
    return total // 2 + 1 if total else 0


def has_headcount_majority(yes_count, total):
    return majority_required(total) > 0 and int(yes_count or 0) >= majority_required(total)


def meeting_month(value=None):
    current = _datetime(value) if value is not None else datetime.now(timezone.utc)
    return date(current.year, current.month, 1)


def _month_key(value):
    if isinstance(value, date):
        return value.isoformat()[:7]
    text = _text(value)
    return text[:7]


def month_compliance(meetings, month=None):
    target = (month or meeting_month()).isoformat()[:7]
    for meeting in meetings or []:
        if not isinstance(meeting, dict):
            continue
        if _month_key(meeting.get("meeting_month")) != target:
            continue
        if _text(meeting.get("meeting_type")) != "regular":
            continue
        status = _text(meeting.get("status"))
        if status in ("scheduled", "approved"):
            return "scheduled"
        if status == "completed":
            return "completed"
        if status == "pending_approval":
            return "pending_approval"
    return "missing"


def can_initiate_special(meetings, month=None):
    target = (month or meeting_month()).isoformat()[:7]
    for meeting in meetings or []:
        if not isinstance(meeting, dict):
            continue
        if _month_key(meeting.get("meeting_month")) != target:
            continue
        if _text(meeting.get("meeting_type")) != "special":
            continue
        if _text(meeting.get("status")) in ("pending_approval", "scheduled", "approved", "completed"):
            return {"valid": False, "reason": "one active special meeting already exists this month"}
    return {"valid": True, "reason": ""}


def validate_special_meeting(data, now=None):
    data = data if isinstance(data, dict) else {}
    now = _datetime(now or datetime.now(timezone.utc))
    missing = []
    if not _text(data.get("title")):
        missing.append("title")
    if not _text(data.get("agenda")):
        missing.append("agenda")
    if not _text(data.get("reason")):
        missing.append("reason")
    scheduled = _datetime(data.get("scheduled_at"), now)
    if scheduled <= now:
        missing.append("future scheduled_at")
    if (scheduled.year, scheduled.month) != (now.year, now.month):
        missing.append("scheduled time must be in the current month")
    return {"valid": not missing, "reason": ", ".join(missing)}


def count_votes(votes):
    result = {"yes": 0, "no": 0, "abstain": 0}
    for vote in votes or []:
        choice = _text((vote or {}).get("choice") if isinstance(vote, dict) else vote).lower()
        if choice in result:
            result[choice] += 1
    return result


def validate_attendance(status, note=""):
    status = _text(status).lower()
    if status not in ATTENDANCE_STATUSES:
        return {"valid": False, "reason": "attendance status must be pending, attending, absent, or leave"}
    if status == "leave" and not _text(note):
        return {"valid": False, "reason": "leave note is required"}
    return {"valid": True, "reason": ""}


def attendance_summary(attendees):
    result = {
        "pending": 0, "attending": 0, "absent": 0, "leave": 0,
        "leave_records": [],
    }
    for row in attendees or []:
        row = row if isinstance(row, dict) else {}
        status = _text(row.get("status")).lower() or "pending"
        if status not in result:
            status = "pending"
        result[status] += 1
        if status == "leave":
            result["leave_records"].append({
                "profile_id": row.get("profile_id"),
                "name": row.get("name") or row.get("profile_name") or "",
                "note": _text(row.get("note")),
            })
    return result


def meeting_actions(meeting, is_shareholder=False, is_executive=False):
    meeting = meeting if isinstance(meeting, dict) else {}
    status = _text(meeting.get("status")).lower()
    kind = _text(meeting.get("meeting_type")).lower()
    return {
        "vote": bool(is_shareholder and kind == "special" and status == "pending_approval"),
        "attend": bool(is_shareholder and status in ACTIVE_SCHEDULE_STATUSES),
        "complete": bool(is_executive and status in ACTIVE_SCHEDULE_STATUSES),
    }
