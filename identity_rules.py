from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Iterable

BPS = 10000
HIGH_RISK_PERMISSIONS = {
    "identity.manage_templates", "identity.manage_shares", "governance.vote",
    "governance.manage", "finance.manage", "finance.approve_company",
    "data.export_all", "data.delete_all", "company.delete",
}
ADVANCED_MODE_PERMISSIONS = {
    "company.manage", "projects.view_all", "projects.manage", "people.view_all",
    "people.manage", "worklogs.approve", "tasks.assign", "tasks.grade",
    "finance.view", "finance.manage", "reports.view", "audit.read",
    "identity.manage_templates", "governance.manage", "governance.vote",
}
MANAGEMENT_PERMISSIONS = ADVANCED_MODE_PERMISSIONS


@dataclass(frozen=True)
class PermissionGrant:
    key: str
    scope: str = "self"
    conditions: dict = field(default_factory=dict)
    expires_at: datetime | None = None
    high_risk: bool = False


@dataclass(frozen=True)
class VoteResult:
    passed: bool
    turnout_bps: int
    approval_bps: int
    reason: str


def _active(grant, now):
    if not grant.expires_at:
        return True
    expires = grant.expires_at
    if expires.tzinfo is None:
        expires = expires.replace(tzinfo=timezone.utc)
    return expires > now


def merge_permissions(grants: Iterable[PermissionGrant], now=None):
    current = now or datetime.now(timezone.utc)
    if current.tzinfo is None:
        current = current.replace(tzinfo=timezone.utc)
    merged = {}
    for grant in grants:
        if grant.key and _active(grant, current):
            merged.setdefault(grant.key, []).append(grant)
    return merged


def has_permission(grants, key, now=None):
    return bool(merge_permissions(grants, now).get(key))


def motion_class(permission_keys):
    return "major" if any(key in HIGH_RISK_PERMISSIONS for key in permission_keys) else "ordinary"


def required_threshold_bps(kind):
    if kind == "major":
        return 6667
    if kind == "ordinary":
        return 5001
    raise ValueError(f"unknown motion class: {kind}")


def evaluate_vote(total_shares, yes_shares, no_shares, abstain_shares,
                  quorum_bps, approval_bps, approval_basis="decisive"):
    total = max(float(total_shares), 0.0)
    yes = max(float(yes_shares), 0.0)
    no = max(float(no_shares), 0.0)
    cast = yes + no + max(float(abstain_shares), 0.0)
    turnout = int(cast / total * BPS) if total else 0
    if approval_basis == "decisive":
        basis = yes + no
    elif approval_basis == "total":
        basis = total
    else:
        raise ValueError(f"unknown approval basis: {approval_basis}")
    approval = int(yes / basis * BPS) if basis else 0
    if total <= 0:
        return VoteResult(False, 0, 0, "no_voting_shares")
    if turnout < quorum_bps:
        return VoteResult(False, turnout, approval, "quorum_not_reached")
    if approval < approval_bps:
        return VoteResult(False, turnout, approval, "approval_not_reached")
    return VoteResult(True, turnout, approval, "passed")


def can_manage_template(actor_id, target_id, grants, requested, allow_high_risk=False):
    if str(actor_id) == str(target_id):
        return False
    granted = merge_permissions(grants)
    if not granted.get("identity.manage_templates"):
        return False
    for key in requested:
        if key not in granted:
            return False
        if key in HIGH_RISK_PERMISSIONS and not allow_high_risk:
            return False
    return True


def can_use_advanced_mode(grants):
    """Advanced mode is never granted by ordinary identity visibility alone."""
    return any(has_permission(grants, key) for key in ADVANCED_MODE_PERMISSIONS)


def point_balance(entries):
    return sum(int(entry.get("amount") or 0) for entry in entries)
