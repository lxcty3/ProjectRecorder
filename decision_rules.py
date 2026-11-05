"""Pure rules for the Phase 2A decision center and unified approvals."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Iterable

from identity_rules import ADVANCED_MODE_PERMISSIONS


RISK_WEIGHT = {"严重": 50, "风险": 35, "关注": 20, "健康": 0}
_RISK_ALIASES = {
    "严重": "严重",
    "severe": "严重",
    "critical": "严重",
    "风险": "风险",
    "risk": "风险",
    "high": "风险",
    "关注": "关注",
    "attention": "关注",
    "medium": "关注",
    "健康": "健康",
    "healthy": "健康",
    "low": "健康",
}
_DECISION_STATUSES = {
    "open", "acknowledged", "assigned", "deferred", "resolved", "dismissed",
}
_APPROVAL_ACTIONS = {
    "approve": "approved",
    "approved": "approved",
    "reject": "rejected",
    "rejected": "rejected",
    "return": "returned",
    "returned": "returned",
    "cancel": "cancelled",
    "cancelled": "cancelled",
}
_APPROVAL_PERMISSIONS = {
    "leave": ("leave.approve",),
    "worklog": ("worklogs.approve",),
    "expense": ("finance.manage",),
    "purchase": ("finance.manage",),
    "reward": ("rewards.manage",),
    "task_extension": ("tasks.grade", "tasks.assign"),
    "identity_motion": ("governance.vote", "governance.manage"),
}


@dataclass(frozen=True)
class DecisionSignals:
    delivery_days: int = 0
    amount: float = 0
    risk: str = "健康"
    waiting_days: int = 0


def _number(value):
    try:
        return float(value or 0)
    except (TypeError, ValueError):
        return 0.0


def normalize_risk(risk):
    text = str(risk or "").strip().lower()
    if not text:
        return "健康"
    return _RISK_ALIASES.get(text) or _RISK_ALIASES.get(
        str(risk).strip(), "关注"
    )


def score_decision(signals):
    """Return a stable priority score; negative inputs never lower it."""
    return (
        max(_number(signals.delivery_days), 0.0) * 4
        + max(_number(signals.waiting_days), 0.0) * 3
        + max(_number(signals.amount), 0.0) / 10000
        + RISK_WEIGHT[normalize_risk(signals.risk)]
    )


def approval_required_level(amount, risk):
    if normalize_risk(risk) in ("严重", "风险") or _number(amount) >= 50000:
        return "executive"
    return "manager"


def normalize_decision_status(status):
    value = str(status or "").strip().lower()
    return value if value in _DECISION_STATUSES else "open"


def normalize_approval_action(action):
    return _APPROVAL_ACTIONS.get(str(action or "").strip().lower(), "")


def approval_permissions(kind):
    return _APPROVAL_PERMISSIONS.get(str(kind or "").strip().lower(), ())


def can_act_on_approval(permissions, kind, action, *, is_requester=False,
                        is_owner=False):
    """Pure authorization mirror used by UI and contract tests.

    PostgreSQL remains authoritative and additionally verifies enterprise
    membership, source ownership, and share-weighted governance eligibility.
    """
    action = normalize_approval_action(action)
    if not action:
        return False
    granted = set(permissions or ())
    kind = str(kind or "").strip().lower()
    if kind == "identity_motion":
        if action == "cancelled":
            return bool(is_requester or is_owner)
        return bool(granted.intersection(approval_permissions(kind)))
    if action == "cancelled" and (is_requester or is_owner):
        return True
    required = approval_permissions(kind)
    return bool(required and granted.intersection(required))


def can_open_decision_center(permissions: Iterable[str]):
    return any(permission in ADVANCED_MODE_PERMISSIONS for permission in permissions)
