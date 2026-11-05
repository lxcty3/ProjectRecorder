"""Pure work-intake rules shared by the desktop, mobile, and tests."""

from __future__ import annotations

import re
from datetime import datetime, timedelta, timezone
from math import isfinite


REQUEST_TYPES = ("customer", "sales", "improvement", "incident", "temporary")
OPEN_STATUSES = ("submitted", "triage", "in_progress")
PUBLIC_STATUSES = ("submitted", "triage", "in_progress", "resolved", "closed", "merged")
SLA_HOURS = {
    "incident": 2,
    "customer": 24,
    "sales": 24,
    "improvement": 72,
    "temporary": 24,
}
TYPE_ALIASES = {
    "customer": "customer", "客户": "customer", "客户需求": "customer",
    "sales": "sales", "销售": "sales", "销售机会": "sales",
    "improvement": "improvement", "内部改进": "improvement",
    "incident": "incident", "fault": "incident", "故障": "incident",
    "temporary": "temporary", "临时事项": "temporary", "临时": "temporary",
}
PRIORITY_FIELDS = (
    ("business_value", "业务价值", 5),
    ("urgency", "紧急程度", 4),
    ("risk", "风险", 3),
    ("dependency_impact", "依赖影响", 2),
    ("effort", "投入成本", -2),
)
PUBLIC_FIELDS = (
    "tracking_code", "status", "request_type", "title", "created_at",
    "sla_due_at", "resolved_at", "last_message_at",
)
EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")


def _text(value):
    return str(value or "").strip()


def normalize_request_type(value):
    text = _text(value).lower()
    return TYPE_ALIASES.get(text, "temporary")


def normalize_status(value):
    text = _text(value).lower()
    return text if text in PUBLIC_STATUSES else "submitted"


def _as_datetime(value):
    if isinstance(value, datetime):
        return value
    if isinstance(value, str) and value:
        try:
            return datetime.fromisoformat(value.replace("Z", "+00:00"))
        except ValueError:
            pass
    return datetime.now(timezone.utc)


def sla_due_at(request_type, created_at=None):
    start = _as_datetime(created_at or datetime.now(timezone.utc))
    hours = SLA_HOURS.get(normalize_request_type(request_type), 24)
    return start + timedelta(hours=hours)


def _bounded_number(value, low=0, high=5):
    try:
        number = float(value)
    except (TypeError, ValueError):
        return 0
    if not isfinite(number):
        return 0
    return min(max(number, low), high)


def priority_score(data):
    data = data if isinstance(data, dict) else {}
    factors = []
    score = 0.0
    for key, label, weight in PRIORITY_FIELDS:
        value = _bounded_number(data.get(key), 0, 5)
        points = value * weight
        score += points
        sign = "+" if points >= 0 else ""
        factors.append({
            "key": key,
            "label": label,
            "value": int(value) if value.is_integer() else value,
            "weight": weight,
            "points": int(points) if points.is_integer() else round(points, 2),
            "reason": f"{label} {value:g} × {weight:+d} = {sign}{points:g}",
        })
    total = round(score, 2)
    if total.is_integer():
        total = int(total)
    return {
        "score": total,
        "factors": factors,
        "explanation": "；".join(item["reason"] for item in factors) + f"；总分 {total}",
    }


def priority_override(score, reason):
    reason = _text(reason)
    if not reason:
        return {"valid": False, "reason": "priority override reason required"}
    value = _bounded_number(score, 0, 100)
    return {"valid": True, "score": value, "reason": reason}


def validate_submission(data, external=False):
    data = data if isinstance(data, dict) else {}
    missing = []
    if not _text(data.get("title")):
        missing.append("title")
    if len(_text(data.get("detail"))) < 5:
        missing.append("detail")
    if not _text(data.get("request_type")):
        missing.append("request_type")
    if external:
        email = _text(data.get("requester_email"))
        if not EMAIL_RE.match(email):
            missing.append("email")
        if not _text(data.get("requester_name")):
            missing.append("requester_name")
        if not bool(data.get("consent")):
            missing.append("consent")
    return {"valid": not missing, "reason": ", ".join(missing)}


def _tokens(value):
    text = _text(value).lower()
    words = re.findall(r"[a-z0-9]+", text)
    cjk = "".join(re.findall(r"[\u4e00-\u9fff]", text))
    grams = [cjk[index:index + 2] for index in range(max(len(cjk) - 1, 0))]
    if len(cjk) == 1:
        grams = [cjk]
    return set(words + grams)


def similarity_score(left, right):
    left_tokens = _tokens(left)
    right_tokens = _tokens(right)
    if not left_tokens or not right_tokens:
        return 0.0
    return 2 * len(left_tokens & right_tokens) / (len(left_tokens) + len(right_tokens))


def rank_duplicates(title, detail, candidates, limit=5):
    query = f"{_text(title)} {_text(detail)}"
    ranked = []
    for row in candidates or []:
        row = row if isinstance(row, dict) else {}
        score = max(
            similarity_score(query, f"{_text(row.get('title'))} {_text(row.get('detail'))}"),
            similarity_score(_text(title), _text(row.get("title"))),
        )
        if score >= 0.2:
            ranked.append({**row, "similarity": round(score, 4)})
    ranked.sort(key=lambda item: (-item["similarity"], str(item.get("id", ""))))
    try:
        limit = max(int(limit), 0)
    except (TypeError, ValueError):
        limit = 5
    return ranked[:limit]


def public_messages(messages):
    rows = []
    for row in messages or []:
        row = row if isinstance(row, dict) else {}
        if _text(row.get("visibility")).lower() != "public":
            continue
        if row.get("internal_note"):
            continue
        rows.append({
            "body": _text(row.get("body")),
            "created_at": row.get("created_at"),
            "author_label": _text(row.get("author_label")) or "项目组",
        })
    return rows


def public_status_payload(data):
    data = data if isinstance(data, dict) else {}
    result = {key: data.get(key) for key in PUBLIC_FIELDS if key in data}
    result["status"] = normalize_status(result.get("status"))
    result["messages"] = public_messages(data.get("messages"))
    return result


def should_escalate(request, now=None):
    request = request if isinstance(request, dict) else {}
    if _text(request.get("status")).lower() != "submitted":
        return False
    due = request.get("sla_due_at")
    if not due:
        return False
    return _as_datetime(now or datetime.now(timezone.utc)) >= _as_datetime(due)


def validate_conversion(kind, data):
    kind = _text(kind).lower()
    data = data if isinstance(data, dict) else {}
    if kind not in ("project", "task", "presales"):
        return {"valid": False, "reason": "conversion kind must be project, task, or presales"}
    required = {
        "project": ("name",),
        "task": ("title", "project_id", "employee_id", "plan_date"),
        "presales": ("owner_id",),
    }[kind]
    missing = [key for key in required if not _text(data.get(key))]
    return {"valid": not missing, "reason": ", ".join(missing)}


def validate_message(body, public=False):
    text = _text(body)
    if not text:
        return {"valid": False, "reason": "message is empty"}
    limit = 4000 if public else 8000
    if len(text) > limit:
        return {"valid": False, "reason": "message is too long"}
    return {"valid": True, "reason": ""}
