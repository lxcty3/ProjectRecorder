import unittest
from pathlib import Path

import pglast


class ExecutionSqlTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.path = Path("mobile/sql/execution-tracking-v1.sql")
        cls.sql = cls.path.read_text(encoding="utf-8")
        cls.lowered = cls.sql.lower()

    def test_parse_ascii(self):
        pglast.parse_sql(self.sql)
        self.assertTrue(all(ord(ch) < 128 for ch in self.sql))

    def test_required_tables_and_rpcs(self):
        for name in (
            "task_acceptance",
            "task_dependencies",
            "task_handoffs",
            "change_requests",
            "execution_audit",
            "submit_task_acceptance",
            "review_task_acceptance",
            "upsert_task_dependency",
            "create_task_handoff",
            "accept_task_handoff",
            "create_change_request",
            "decide_change_request",
            "get_execution_board",
        ):
            self.assertIn(name, self.lowered)

    def test_acceptance_contract_and_final_completion_gate(self):
        for fragment in (
            "criteria text not null",
            "evidence text not null",
            "submitter_id uuid not null",
            "reviewer_id uuid",
            "status text not null default 'pending'",
            "check (status in ('pending','accepted','rework','cancelled'))",
            "independent reviewer required",
            "acceptance criteria required",
            "evidence required",
            "task is not pending acceptance",
            "accepted record is final",
        ):
            self.assertIn(fragment, self.lowered)
        self.assertIn("review_task_acceptance", self.lowered)

    def test_dependencies_reject_cycles_and_calculate_impact(self):
        for fragment in (
            "task_dependencies",
            "depends_on_task_id",
            "lag_days integer not null default 0",
            "check (task_id<>depends_on_task_id)",
            "with recursive",
            "dependency cycle detected",
            "downstream",
            "affected_tasks",
            "projected_date",
            "delay_days",
        ):
            self.assertIn(fragment, self.lowered)

    def test_handoffs_require_recipient_decision(self):
        for fragment in (
            "from_profile_id",
            "to_profile_id",
            "artifact text not null",
            "status in ('pending','accepted','rejected')",
            "only the handoff recipient can decide",
            "decision must be accepted or rejected",
            "accepted_at",
        ):
            self.assertIn(fragment, self.lowered)

    def test_change_control_captures_scope_reason_urgency_and_impacts(self):
        for fragment in (
            "scope text not null",
            "reason text not null",
            "urgency text not null",
            "schedule_impact_days integer not null",
            "cost_impact numeric not null",
            "resource_impact text not null",
            "cross_department boolean not null default false",
            "risk text not null default 'healthy'",
            "status in ('pending','approved','rejected','returned')",
            "scope, reason, urgency, schedule, cost, and resource impact are required",
        ):
            self.assertIn(fragment, self.lowered)
        self.assertNotIn("update public.projects", self.lowered)
        self.assertNotIn("update public.tasks set plan_date", self.lowered)

    def test_high_impact_change_enters_phase2a_decision_queue(self):
        for fragment in (
            "insert into public.decision_items",
            "source_type",
            "'change'",
            "change_requires_approval",
            "amount >= 50000",
            "schedule_impact_days > 3",
            "risk in ('severe','risk')",
            "cross_department",
            "decision_items",
            "decision_events",
        ):
            self.assertIn(fragment, self.lowered)

    def test_security_definer_rls_least_privilege_and_audit(self):
        self.assertGreaterEqual(self.lowered.count("security definer"), 12)
        self.assertIn("set search_path=public,auth,pg_temp", self.lowered)
        for table in (
            "task_acceptance",
            "task_dependencies",
            "task_handoffs",
            "change_requests",
            "execution_audit",
        ):
            self.assertIn(
                f"alter table public.{table} enable row level security",
                self.lowered,
            )
            self.assertIn(
                f"revoke all on table public.{table}", self.lowered
            )
        for rpc in (
            "get_execution_board",
            "submit_task_acceptance",
            "review_task_acceptance",
            "upsert_task_dependency",
            "create_task_handoff",
            "accept_task_handoff",
            "create_change_request",
            "decide_change_request",
        ):
            self.assertIn(f"grant execute on function public.{rpc}", self.lowered)
        self.assertIn("to authenticated", self.lowered)
        self.assertNotIn("grant insert on table", self.lowered)
        self.assertNotIn("grant update on table", self.lowered)
        self.assertIn("insert into public.execution_audit", self.lowered)
        self.assertIn("insert into public.enterprise_identity_audit", self.lowered)
        self.assertIn("'code','permission_denied'", self.lowered)


    def test_board_exposes_scoped_task_project_and_member_sources(self):
        for fragment in (
            "'tasks',v_tasks",
            "'projects',v_projects",
            "'members',v_members",
            "public._execution_task_enterprise(t.id)=v_eid",
            "m.enterprise_id=v_eid and m.status='active'",
        ):
            self.assertIn(fragment, self.lowered)


if __name__ == "__main__":
    unittest.main()
