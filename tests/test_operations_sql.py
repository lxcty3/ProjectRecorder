import unittest
from pathlib import Path

import pglast


class OperationsSqlTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sql = Path(
            "mobile/sql/operations-economics-v1.sql"
        ).read_text(encoding="utf-8")
        cls.lowered = cls.sql.lower()

    def test_parse_ascii(self):
        pglast.parse_sql(self.sql)
        self.assertTrue(all(ord(ch) < 128 for ch in self.sql))

    def test_required_tables_and_rpcs(self):
        for name in (
            "project_economics",
            "profile_skills",
            "capacity_demands",
            "performance_evidence",
            "worklog_dimensions",
            "get_operations_dashboard",
            "upsert_project_economics",
            "upsert_profile_skill",
            "upsert_capacity_demand",
            "upsert_worklog_dimensions",
            "get_worklog_dimensions",
            "upsert_performance_evidence",
            "get_my_performance_evidence",
            "task_acceptance",
            "submit_performance_statement",
            "review_performance_evidence",
        ):
            self.assertIn(name, self.lowered)

    def test_economics_contract_columns(self):
        for fragment in (
            "contract_amount numeric",
            "invoiced_amount numeric",
            "collected_amount numeric",
            "outsourced_committed numeric",
            "outsourced_paid numeric",
            "labor_cost numeric",
            "estimated_completion_cost numeric",
            "invoice_due_date date",
            "payment_terms text",
            "updated_by uuid",
            "updated_at timestamptz",
        ):
            self.assertIn(fragment, self.lowered)

    def test_timesheet_dimensions_have_compatible_defaults(self):
        for fragment in (
            "billable boolean not null default true",
            "overtime boolean not null default false",
            "work_kind text not null default 'project'",
            "rework boolean not null default false",
            "waiting boolean not null default false",
            "travel boolean not null default false",
            "check (work_kind in ('project','presales','internal'))",
            "_operations_worklog_defaults",
            "insert into public.worklog_dimensions(worklog_id)",
            "select id from public.worklogs",
        ):
            self.assertIn(fragment, self.lowered)

    def test_skills_contract_and_capacity_window(self):
        for fragment in (
            "level integer not null default 1 check (level between 1 and 5)",
            "certified boolean not null default false",
            "certification text not null default ''",
            "available_hours numeric",
            "valid_until date",
            "p_weeks integer default 4",
            "least(greatest(coalesce(p_weeks,4),2),4)",
            "capacity_gaps",
            "gap_hours",
        ):
            self.assertIn(fragment, self.lowered)

    def test_performance_is_evidence_based_and_employee_visible(self):
        for fragment in (
            "on_time_rate numeric",
            "first_pass_rate numeric",
            "rework_rate numeric",
            "collaboration_score numeric",
            "complexity_score numeric",
            "business_contribution numeric",
            "customer_evaluation jsonb",
            "employee_statement text",
            "reviewed_by uuid",
            "reviewed_at timestamptz",
            "_operations_performance_score",
            "submit_performance_statement",
            "review_performance_evidence",
            "get_my_performance_evidence",
            "task_acceptance",
            "accepted_count",
            "rework_count",
        ):
            self.assertIn(fragment, self.lowered)
        for forbidden in (
            "wage_amount",
            "salary_amount",
            "promotion_decision",
            "compensation_amount",
        ):
            self.assertNotIn(forbidden, self.lowered)

    def test_management_only_aggregate_privacy(self):
        for fragment in (
            "management permission required",
            "'finance.manage'",
            "'projects.manage'",
            "'people.manage'",
            "'tasks.grade'",
            "_operations_has_permission",
            "_operations_can_access_project",
            "_operations_can_access_profile",
            "_operations_has_company_permission",
            "_operations_denied",
        ):
            self.assertIn(fragment, self.lowered)

    def test_permission_conditions_and_dashboard_field_filters(self):
        for fragment in (
            "v_conditions->'project_ids'",
            "v_conditions->'profile_ids'",
            "'amount_limit'",
            "'can_finance'",
            "'can_performance'",
            "'can_worklogs'",
            "case when v_can_finance then jsonb_build_object",
        ):
            self.assertIn(fragment.lower(), self.lowered)

    def test_phase2b_review_blockers_are_enforced(self):
        for fragment in (
            "foreach v_amount_key in array",
            "monetary field exceeds permission condition",
            "cross-enterprise project access denied",
            "v_can_capacity:=v_can_people",
            "'capacity_requires_people_scope'",
            "capacity_permission_message",
            "people.manage permission required",
            "people scope does not allow this profile",
            "'can_manage_skills',public._operations_has_permission",
        ):
            self.assertIn(fragment.lower(), self.lowered)

    def test_rls_least_privilege_and_audit(self):
        self.assertGreaterEqual(self.lowered.count("security definer"), 12)
        self.assertIn("set search_path=public,auth,pg_temp", self.lowered)
        for table in (
            "project_economics",
            "profile_skills",
            "capacity_demands",
            "performance_evidence",
            "worklog_dimensions",
            "operations_security_audit",
        ):
            self.assertIn(f"alter table public.{table} enable row level security",
                          self.lowered)
            self.assertIn(f"revoke all on table public.{table}", self.lowered)
        self.assertIn("grant execute on function public.get_operations_dashboard", self.lowered)
        self.assertIn("to authenticated", self.lowered)
        self.assertNotIn("grant select on table", self.lowered)
        self.assertNotIn("grant insert on table", self.lowered)
        self.assertIn("enterprise_identity_audit", self.lowered)
        self.assertIn("operations.economics.updated", self.lowered)
        self.assertIn("operations.performance.reviewed", self.lowered)
        self.assertIn("source_type='finance'", self.lowered)
        self.assertIn("w.approval_status='approved'", self.lowered)
        self.assertIn("_operations_validate_evidence", self.lowered)
        self.assertIn("_operations_evidence_details", self.lowered)
        self.assertIn("'code','permission_denied'", self.lowered)


if __name__ == "__main__":
    unittest.main()
