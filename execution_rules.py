"""Pure execution-tracking rules shared by tests and client-side guards."""

from __future__ import annotations

ACCEPTANCE_STATUSES = ("pending", "accepted", "rework")
FINAL_ACCEPTANCE_STATUS = "accepted"
RISK_ALIASES = {
    "severe": "severe",
    "critical": "severe",
    "serious": "severe",
    "high": "severe",
    "高风险": "severe",
    "严重": "severe",
    "risk": "risk",
    "medium": "risk",
    "warning": "risk",
    "风险": "risk",
    "attention": "attention",
    "low": "attention",
    "关注": "attention",
    "healthy": "healthy",
    "健康": "healthy",
}
URGENCY_ALIASES = {
    "normal": "normal",
    "普通": "normal",
    "high": "high",
    "高": "high",
    "urgent": "urgent",
    "紧急": "urgent",
    "critical": "critical",
    "emergency": "critical",
    "严重": "critical",
}
HIGH_IMPACT_RISKS = ("severe", "risk")
HIGH_URGENCIES = ("high", "urgent", "critical", "emergency")


def _text(value):
    return str(value or "").strip()


def normalize_risk(value):
    text = _text(value).lower()
    return RISK_ALIASES.get(text, "healthy")


def normalize_urgency(value):
    text = _text(value).lower()
    return URGENCY_ALIASES.get(text, text)


def acceptance_result(evidence, submitter, reviewer, criteria=None):
    """Validate evidence, criteria, and the independent reviewer."""
    if criteria is not None and not _text(criteria):
        return {"valid": False, "reason": "acceptance criteria required"}
    if not _text(evidence):
        return {"valid": False, "reason": "evidence required"}
    submitter_text = _text(submitter)
    reviewer_text = _text(reviewer)
    if not submitter_text:
        return {"valid": False, "reason": "submitter required"}
    if not reviewer_text:
        return {"valid": False, "reason": "reviewer required"}
    if submitter_text == reviewer_text:
        return {"valid": False, "reason": "independent reviewer required"}
    return {"valid": True, "reason": ""}


def review_acceptance(current_status, decision):
    """Return the only legal acceptance review transition."""
    current = _text(current_status).lower()
    target = _text(decision).lower()
    if current not in ACCEPTANCE_STATUSES:
        return {"valid": False, "reason": "invalid current acceptance status"}
    if target not in ACCEPTANCE_STATUSES:
        return {
            "valid": False,
            "reason": "decision must be pending, accepted, or rework",
        }
    if current == FINAL_ACCEPTANCE_STATUS:
        if target == FINAL_ACCEPTANCE_STATUS:
            return {"valid": True, "reason": "", "status": target}
        return {"valid": False, "reason": "accepted record is final"}
    if current == "rework" and target == "rework":
        return {"valid": False, "reason": "rework requires a new submission"}
    return {"valid": True, "reason": "", "status": target}


def is_final_completion_allowed(acceptance):
    if not isinstance(acceptance, dict):
        return {"valid": False, "reason": "acceptance record required"}
    if _text(acceptance.get("status")).lower() != FINAL_ACCEPTANCE_STATUS:
        return {"valid": False, "reason": "acceptance required"}
    return acceptance_result(
        acceptance.get("evidence"),
        acceptance.get("submitter_id"),
        acceptance.get("reviewer_id"),
        criteria=acceptance.get("criteria"),
    )


def downstream_delay(upstream_days, dependency_lag=0):
    try:
        upstream = int(upstream_days or 0)
        lag = int(dependency_lag or 0)
    except (TypeError, ValueError):
        return 0
    return max(upstream + lag, 0)


def _normalize_edges(edges):
    """Normalize graph input to task -> [{task_id, lag_days}]."""
    normalized = {}
    if isinstance(edges, dict):
        items = edges.items()
    else:
        items = []
        for item in edges or []:
            if isinstance(item, dict):
                task = item.get("task_id") or item.get("from")
                dependency = item.get("depends_on_task_id") or item.get("to")
                items.append((task, {"task_id": dependency,
                                     "lag_days": item.get("lag_days", 0)}))
            elif isinstance(item, (tuple, list)) and len(item) >= 2:
                items.append((item[0], item[1]))
    for task, dependencies in items:
        task_id = _text(task)
        if not task_id:
            continue
        rows = []
        if isinstance(dependencies, dict):
            dependencies = [dependencies]
        for dependency in dependencies or []:
            if isinstance(dependency, dict):
                dependency_id = _text(
                    dependency.get("task_id")
                    or dependency.get("depends_on_task_id")
                )
                lag = dependency.get("lag_days", 0)
            elif isinstance(dependency, (tuple, list)) and dependency:
                dependency_id = _text(dependency[0])
                lag = dependency[1] if len(dependency) > 1 else 0
            else:
                dependency_id = _text(dependency)
                lag = 0
            if dependency_id:
                rows.append({
                    "task_id": dependency_id,
                    "lag_days": max(int(lag or 0), 0),
                })
        normalized[task_id] = rows
    return normalized


def dependency_cycle(edges, task_id, depends_on_task_id):
    """Return True when adding task -> dependency would close a cycle."""
    source = _text(task_id)
    dependency = _text(depends_on_task_id)
    if not source or not dependency:
        return False
    if source == dependency:
        return True
    graph = _normalize_edges(edges)
    pending = [dependency]
    seen = set()
    while pending:
        current = pending.pop()
        if current == source:
            return True
        if current in seen:
            continue
        seen.add(current)
        pending.extend(row["task_id"] for row in graph.get(current, []))
    return False


def downstream_impact(edges, delayed_task_id, delay_days):
    """Calculate recursive downstream delays from an upstream delay."""
    graph = _normalize_edges(edges)
    start = _text(delayed_task_id)
    try:
        base_delay = max(int(delay_days or 0), 0)
    except (TypeError, ValueError):
        base_delay = 0
    if not start or base_delay <= 0:
        return []

    reverse = {}
    for task, dependencies in graph.items():
        for dependency in dependencies:
            reverse.setdefault(dependency["task_id"], []).append(
                (task, dependency["lag_days"])
            )

    best = {}
    frontier = [(start, base_delay)]
    while frontier:
        current, current_delay = frontier.pop()
        for dependent, lag in reverse.get(current, []):
            candidate = current_delay + lag
            if candidate > best.get(dependent, -1):
                best[dependent] = candidate
                frontier.append((dependent, candidate))

    return [
        {"task_id": task, "delay_days": delay}
        for task, delay in sorted(best.items(), key=lambda row: (row[1], row[0]))
    ]


def _number(value):
    try:
        return float(value or 0)
    except (TypeError, ValueError):
        return 0.0


def change_requires_approval(
    amount,
    days,
    risk,
    urgency="normal",
    cross_department=False,
    resource_impact="",
):
    risk_text = normalize_risk(risk)
    urgency_text = normalize_urgency(urgency)
    return bool(
        _number(amount) >= 50000
        or _number(days) > 3
        or risk_text in HIGH_IMPACT_RISKS
        or urgency_text in HIGH_URGENCIES
        or cross_department
        or bool(_text(resource_impact))
    )


def validate_change_request(data):
    """Validate a change request's scope, reason, urgency, and impacts."""
    data = data if isinstance(data, dict) else {}
    missing = []
    if not _text(data.get("scope")):
        missing.append("scope")
    if not _text(data.get("reason")):
        missing.append("reason")
    if not _text(data.get("urgency")):
        missing.append("urgency")
    if not _text(data.get("resource_impact")):
        missing.append("resource impact")
    for key in ("schedule_impact_days", "cost_impact"):
        try:
            value = float(data.get(key, 0) or 0)
        except (TypeError, ValueError):
            missing.append(key)
        else:
            if value < 0:
                missing.append(key)
    if missing:
        return {
            "valid": False,
            "reason": "required fields missing or invalid: " + ", ".join(missing),
        }
    return {"valid": True, "reason": ""}
