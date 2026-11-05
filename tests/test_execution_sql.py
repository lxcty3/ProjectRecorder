import re
import unittest
from pathlib import Path

import pglast


class ExecutionSqlTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.path = Path("mobile/sql/execution-tracking-v1.sql")
        cls.sql = cls.path.read_text(encoding="utf-8")
        cls.lowered = cls.sql.lower()
        cls.installer = Path("mobile/sql/install-unified.sql").read_text(
            encoding="utf-8"
        )

    def test_parse_ascii_and_no_escaped_newline_artifacts(self):
        pglast.parse_sql(self.sql)
        self.assertTrue(all(ord(ch) < 128 for ch in self.sql))
        self.assertNotIn("`n", self.sql)
        self.assertEqual(len(re.findall(r"\$fn\$", self.sql)) % 2, 0)

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
            "delete_task_dependency",
            "create_task_handoff",
            "accept_task_handoff",
            "create_change_request",
            "decide_change_request",
            "get_execution_board",
        ):
            self.assertIn(name, self.lowered)

    def test_acceptance_contract_and_completion_gate(self):
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
            "assignment must be accepted before completion",
            "task completion log required before acceptance",
            "delete from public.task_logs",
            "completion_logs_removed",
            "reopened",
        ):
            self.assertIn(fragment, self.lowered)

    def test_dependencies_reject_cycles_and_honor_optional_edges(self):
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
            "coalesce(d.required,true)",
            "delete_task_dependency",
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

    def test_change_control_normalizes_alias_values(self):
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
            "_execution_urgency",
            "u&'\\4e25\\91cd'",
            "u&'\\98ce\\9669'",
            "u&'\\7d27\\6025'",
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
            "coalesce(amount,0) >= 50000",
            "coalesce(schedule_impact_days,0) > 3",
            "cross_department",
            "decision_items",
            "decision_events",
            "_execution_sync_change_from_decision",
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
            self.assertIn(f"revoke all on table public.{table}", self.lowered)
        for rpc in (
            "get_execution_board",
            "submit_task_acceptance",
            "review_task_acceptance",
            "upsert_task_dependency",
            "delete_task_dependency",
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

    def test_permissions_are_split_from_read_only_oversight(self):
        for fragment in (
            "tasks.assign",
            "tasks.grade",
            "people.manage",
            "projects.manage",
            "can_manage_dependencies",
            "can_create_handoff",
            "can_manage_changes",
            "read_only",
        ):
            self.assertIn(fragment, self.lowered)
        self.assertNotIn("'can_manage_dependencies',v_management", self.lowered)
        self.assertNotIn("'can_manage_changes',v_management", self.lowered)

    def test_board_limits_before_aggregating_every_section(self):
        for alias in (
            "acceptance", "handoffs", "changes", "dependencies",
            "tasks", "projects", "members",
        ):
            self.assertIn(f") {alias};\n", self.lowered)
        self.assertGreaterEqual(self.lowered.count("from (\n"), 7)
        self.assertNotIn("order by a.submitted_at desc\n  limit 100;", self.lowered)

    def test_function_bodies_are_exercised_by_opt_in_database_tests(self):
        integration = Path("tests/test_execution_integration.py").read_text(
            encoding="utf-8"
        )
        for rpc in (
            "submit_task_acceptance",
            "review_task_acceptance",
            "upsert_task_dependency",
            "delete_task_dependency",
            "create_task_handoff",
            "accept_task_handoff",
            "create_change_request",
            "decide_change_request",
            "get_execution_board",
            "act_on_decision",
            "grade_task",
            "get_operations_dashboard",
        ):
            self.assertIn(rpc, integration)

    def test_unified_installer_carries_remediated_bodies(self):
        self.assertTrue(all(ord(ch) < 128 for ch in self.installer))
        self.assertNotIn("`n", self.installer)
        for fragment in (
            "_execution_urgency",
            "assignment must be accepted before completion",
            "delete from public.task_logs",
            "delete_task_dependency",
            "_execution_sync_change_from_decision",
            ") acceptance;\n",
            ") handoffs;\n",
            ") changes;\n",
            ") dependencies;\n",
        ):
            self.assertIn(fragment, self.installer.lower())


if __name__ == "__main__":
    unittest.main()
