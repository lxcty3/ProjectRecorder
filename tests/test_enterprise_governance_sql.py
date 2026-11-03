import unittest
from pathlib import Path

import pglast


class EnterpriseGovernanceSqlTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sql = Path("mobile/sql/enterprise-governance-v2.sql").read_text(
            encoding="utf-8"
        )

    def test_sql_parses_and_is_ascii(self):
        pglast.parse_sql(self.sql)
        self.assertTrue(all(ord(ch) < 128 for ch in self.sql))

    def test_required_schema(self):
        for name in (
            "enterprise_role_templates",
            "enterprise_role_template_versions",
            "enterprise_role_template_permissions",
            "enterprise_role_assignments",
            "enterprise_single_office_idx",
            "preferred_mode",
        ):
            self.assertIn(name, self.sql)

    def test_governance_and_points_contract_markers(self):
        for name in (
            "motion_class",
            "share_snapshot",
            "enterprise_board_motions",
            "enterprise_point_pools",
            "enterprise_point_ledger",
            "unlock_knowledge_content",
            "points_are_permanent",
        ):
            self.assertIn(name, self.sql)

    def test_provisioning_and_read_functions_are_authenticated_only(self):
        for function in (
            "provision_default_role_templates(uuid)",
            "get_enterprise_role_templates()",
        ):
            self.assertIn(
                f"revoke all on function public.{function} from public;", self.sql
            )
            self.assertIn(
                f"grant execute on function public.{function} to authenticated;",
                self.sql,
            )
        self.assertGreaterEqual(self.sql.lower().count("security definer"), 2)

    def test_assignment_constraints_and_rls(self):
        for table in (
            "enterprise_role_templates",
            "enterprise_role_template_versions",
            "enterprise_role_template_permissions",
            "enterprise_role_assignments",
        ):
            self.assertIn(f"alter table public.{table} enable row level security;", self.sql)
        self.assertIn("enterprise_primary_role_idx", self.sql)
        self.assertIn("status='active' and is_primary", self.sql)


if __name__ == "__main__":
    unittest.main()
