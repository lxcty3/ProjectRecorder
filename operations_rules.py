"""Pure rules for Phase 2B operations economics and performance."""

from __future__ import annotations


def _number(value):
    try:
        return float(value or 0)
    except (TypeError, ValueError):
        return 0.0


def _nonnegative(value):
    return max(_number(value), 0.0)


def _rate(value):
    return min(max(_number(value), 0.0), 1.0)


def project_margin(
    contract,
    invoiced=0,
    cost=0,
    committed=0,
    collected=0,
    labor_cost=None,
    projected_completion_cost=None,
):
    """Return the management economics view for one project.

    ``cost`` is the default labor cost for backwards compatibility with the
    Phase 2B plan. When ``labor_cost`` is supplied, ``cost`` is treated as
    other direct cost. ``projected_completion_cost`` can override the computed
    total when finance has a stronger completion estimate.
    """
    contract_amount = _nonnegative(contract)
    invoiced_amount = _nonnegative(invoiced)
    collected_amount = _nonnegative(collected)
    committed_amount = _nonnegative(committed)
    direct_cost = _nonnegative(cost)

    if labor_cost is None:
        labor = direct_cost
        other_cost = 0.0
    else:
        labor = _nonnegative(labor_cost)
        other_cost = direct_cost

    if projected_completion_cost is None:
        total_cost = labor + other_cost + committed_amount
    else:
        total_cost = _nonnegative(projected_completion_cost)

    margin = contract_amount - total_cost
    percent = (
        round(margin / contract_amount * 100, 2)
        if contract_amount > 0
        else 0.0
    )
    return {
        "contract_amount": contract_amount,
        "invoiced_amount": invoiced_amount,
        "collected_amount": collected_amount,
        "outsourced_committed": committed_amount,
        "labor_cost": labor,
        "other_cost": other_cost,
        "projected_completion_cost": total_cost,
        "projected_cost": total_cost,
        "projected_margin": margin,
        "projected_margin_percent": percent,
        "collection_gap": max(contract_amount - collected_amount, 0.0),
        "invoice_gap": max(contract_amount - invoiced_amount, 0.0),
        "unpaid_invoice": max(invoiced_amount - collected_amount, 0.0),
    }


def capacity_gap(required, available):
    """Return the aggregate positive shortfall between two hour vectors."""
    required_total = sum(max(_number(value), 0.0) for value in required or [])
    available_total = sum(max(_number(value), 0.0) for value in available or [])
    return max(required_total - available_total, 0.0)


def performance_score(
    on_time,
    first_pass,
    rework,
    collaboration,
    complexity=0,
    business_contribution=0,
):
    """Compute an evidence score only; this does not authorize compensation."""
    raw = (
        _rate(on_time) * 30
        + _rate(first_pass) * 25
        + (1 - _rate(rework)) * 15
        + min(max(_number(collaboration), 0.0), 5.0) / 5 * 10
        + min(max(_number(complexity), 0.0), 5.0) / 5 * 12
        + min(max(_number(business_contribution), 0.0), 5.0) / 5 * 8
    )
    return max(0.0, min(100.0, round(raw, 1)))
