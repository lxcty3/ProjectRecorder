import unittest
from pathlib import Path

import pglast


class DecisionSqlTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sql = Path(
            "mobile/sql/decision-approvals-v1.sql"
        ).read_text(encoding="utf-8")

    def test_parses_ascii(self):
        pglast.parse_sql(self.sql)
        self.assertTrue(all(ord(ch) < 128 for ch in self.sql))

    def test_required_objects(self):
        for name in (
            "decision_items",
            "decision_events",
            "approval_requests",
            "approval_events",
            "get_decision_center",
            "act_on_decision",
            "act_on_approval",
        ):
            self.assertIn(name, self.sql)

    def test_decision_context_contract(self):
        for fragment in (
            "source_type text not null",
            "source_id uuid",
            "evidence jsonb not null",
            "impact_days integer not null",
            "impact_amount numeric not null",
            "risk text not null",
            "owner_profile_id uuid",
            "due_at timestamptz not null",
        ):
            self.assertIn(fragment, self.sql.lower())

    def test_approval_context_contract(self):
        for fragment in (
            "kind text not null",
            "source_id uuid not null",
            "evidence jsonb not null",
            "impact_days integer not null",
            "amount numeric not null",
            "risk text not null",
            "required_level text not null",
            "required_permission text not null",
            "owner_profile_id uuid",
            "due_at timestamptz not null",
        ):
            self.assertIn(fragment, self.sql.lower())

    def test_idempotency_and_audit(self):
        for text in (
            "idempotency_key",
            "approval_events",
            "decision_events",
            "enterprise_identity_audit",
            "for update",
            "duplicate",
        ):
            self.assertIn(text, self.sql.lower())

    def test_kind_specific_authorization_and_escalation(self):
        for text in (
            "_approval_can_act",
            "leave.approve",
            "worklogs.approve",
            "finance.manage",
            "rewards.manage",
            "tasks.grade",
            "governance.vote",
            "executive approval required",
            "approval permission required",
        ):
            self.assertIn(text, self.sql)

    def test_advanced_management_access_only(self):
        for permission in (
            "projects.view_all",
            "people.view_all",
            "finance.view",
            "finance.manage",
            "reports.view",
            "audit.read",
            "governance.manage",
            "governance.vote",
        ):
            self.assertIn(permission, self.sql)
        self.assertIn("_decision_has_management", self.sql)
        self.assertIn("management permission required", self.sql)

    def test_existing_flows_are_integrated(self):
        for fragment in (
            "_decision_sync_leave",
            "_decision_sync_worklog",
            "_decision_sync_redemption",
            "_decision_sync_task_extension",
            "_decision_sync_identity_motion",
            "on public.leave_requests",
            "on public.worklogs",
            "on public.redemptions",
            "on public.task_requests",
            "on public.enterprise_role_motions",
        ):
            self.assertIn(fragment, self.sql)

    def test_security_definer_and_least_privilege(self):
        lowered = self.sql.lower()
        self.assertGreaterEqual(lowered.count("security definer"), 12)
        self.assertIn("set search_path=public,auth,pg_temp", lowered)
        for table in ("decision_items", "decision_events",
                      "approval_requests", "approval_events"):
            self.assertIn(f"revoke all on table public.{table}", lowered)
        self.assertIn(
            "grant execute on function public.get_decision_center() "
            "to authenticated",
            lowered,
        )
        self.assertNotIn("grant select on table", lowered)
        self.assertNotIn("grant insert on table", lowered)


if __name__ == "__main__":
    unittest.main()
