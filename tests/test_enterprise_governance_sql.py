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

    def test_identity_admin_catalog_entry_is_provisionable(self):
        self.assertIn("insert into public.enterprise_role_catalog", self.sql)
        self.assertIn("('identity_admin','Identity Administrator'", self.sql)
        self.assertIn(
            '["identity.manage_templates","identity.view","people.view_all"]',
            self.sql,
        )
        self.assertIn("'chairperson','director','supervisor','ceo','finance','identity_admin'", self.sql)

    def test_assignments_require_primary_or_an_end(self):
        self.assertIn("enterprise_assignment_primary_or_ends_check", self.sql)
        compact = " ".join(self.sql.lower().split())
        self.assertIn("check ( is_primary or ends_at is not null )", compact)

    def test_assignments_reject_cross_enterprise_template_versions(self):
        self.assertIn("enterprise_role_assignment_same_tenant", self.sql)
        self.assertIn("template must belong to the same enterprise", self.sql)
        compact = " ".join(self.sql.lower().split())
        self.assertIn("before insert or update of enterprise_id, template_version_id", compact)

    def test_only_read_function_is_exposed(self):
        provision = "provision_default_role_templates(uuid)"
        read = "get_enterprise_role_templates()"
        self.assertIn(f"revoke all on function public.{provision} from public;", self.sql)
        self.assertIn(
            f"revoke all on function public.{provision} from authenticated;", self.sql
        )
        self.assertNotIn(
            f"grant execute on function public.{provision} to authenticated;", self.sql
        )
        self.assertIn(f"revoke all on function public.{read} from public;", self.sql)
        self.assertIn(
            f"grant execute on function public.{read} to authenticated;", self.sql
        )
        self.assertGreaterEqual(self.sql.lower().count("security definer"), 3)

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

    def test_sql_test_dependency_is_declared(self):
        requirements = Path("requirements.txt").read_text(encoding="utf-8")
        self.assertIn("pglast", requirements.lower())


if __name__ == "__main__":
    unittest.main()
