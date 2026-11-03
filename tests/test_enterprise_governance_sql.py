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

    def test_legacy_identity_admin_members_are_singletons(self):
        compact = " ".join(self.sql.lower().split())
        self.assertIn(
            "create unique index if not exists enterprise_single_identity_admin_member_idx",
            compact,
        )
        self.assertIn("on public.enterprise_members(enterprise_id)", compact)
        self.assertIn("where role_key='identity_admin' and status='active'", compact)

    def test_assignments_require_primary_or_an_end(self):
        self.assertIn("enterprise_assignment_primary_or_ends_check", self.sql)
        compact = " ".join(self.sql.lower().split())
        self.assertIn("check ( is_primary or ends_at is not null )", compact)

    def test_assignments_reject_cross_enterprise_template_versions(self):
        self.assertIn("enterprise_role_assignment_same_tenant", self.sql)
        self.assertIn("template must belong to the same enterprise", self.sql)
        compact = " ".join(self.sql.lower().split())
        self.assertIn("before insert or update of enterprise_id, template_version_id", compact)

    def test_provisioning_stays_internal_and_read_is_exposed(self):
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

    def test_template_rpc_guards(self):
        for text in (
            "clone_role_template",
            "update_role_template",
            "set_member_role_assignment",
            "expire_role_assignments",
            "cannot edit your own role",
            "cannot grant permissions you do not hold",
            "high-risk template changes require a major shareholder motion",
            "secondary assignments must expire",
        ):
            self.assertIn(text, self.sql)
        self.assertIn("cannot assign a role to yourself", self.sql)

    def test_template_mutation_rpcs_are_present(self):
        for signature in (
            "public.clone_role_template(uuid,text,text)",
            "public.update_role_template(uuid,text,jsonb)",
            "public.set_member_role_assignment(uuid,uuid,timestamptz)",
            "public.expire_role_assignments()",
        ):
            self.assertIn(signature, self.sql)

    def test_update_role_template_retires_old_version_and_inserts_new(self):
        compact = " ".join(self.sql.lower().split())
        self.assertIn("update public.enterprise_role_template_versions", compact)
        self.assertIn("set status='retired'", compact)
        self.assertIn("v_new_version:=v_current_version.version+1", compact)
        self.assertIn("resource", compact)
        self.assertIn("scope", compact)
        self.assertIn("conditions", compact)

    def test_clone_copies_current_template_permissions_to_version_one(self):
        compact = " ".join(self.sql.lower().split())
        self.assertIn("create or replace function public.clone_role_template", compact)
        self.assertIn("v_source_version_id", compact)
        self.assertIn("v_template_id,1,'active'", compact)
        self.assertIn("from public.enterprise_role_template_permissions p", compact)

    def test_assignment_rpc_records_required_fields_and_rejects_high_risk(self):
        compact = " ".join(self.sql.lower().split())
        self.assertIn("insert into public.enterprise_role_assignments", compact)
        for field in ("office_key", "starts_at", "ends_at", "appointed_by", "is_primary"):
            self.assertIn(field, compact)
        self.assertIn("ends_at is null", compact)
        self.assertIn("p.high_risk", compact)
        self.assertIn("template contains high-risk permissions", compact)

    def test_expiry_rpc_only_expires_due_active_assignments(self):
        compact = " ".join(self.sql.lower().split())
        self.assertIn("update public.enterprise_role_assignments", compact)
        self.assertIn("set status='expired'", compact)
        self.assertIn("where enterprise_id=v_eid", compact)
        self.assertIn("status='active'", compact)
        self.assertIn("ends_at is not null", compact)
        self.assertIn("ends_at <= now()", compact)

    def test_active_assignments_contribute_time_bound_permissions(self):
        compact = " ".join(self.sql.lower().split())
        self.assertIn("create or replace function public._identity_role_permissions", compact)
        self.assertIn("from public.enterprise_role_assignments a", compact)
        self.assertIn("a.starts_at <= now()", compact)
        self.assertIn("a.ends_at is null or a.ends_at > now()", compact)
        self.assertIn("tv.status='active'", compact)

    def test_mutation_rpcs_require_template_management_permission(self):
        compact = " ".join(self.sql.lower().split())
        self.assertGreaterEqual(
            compact.count("? 'identity.manage_templates'"),
            3,
        )

    def test_assignment_reuses_only_secondary_rows(self):
        compact = " ".join(self.sql.lower().split())
        self.assertIn("and a.is_primary=false", compact)

    def test_assignment_locks_template_before_resolving_current_version(self):
        compact = " ".join(self.sql.lower().split())
        assignment = compact.split(
            "-- ------------------------------------------------------------ secondary assignments",
            1,
        )[1].split("-- ------------------------------------------------------------ template rpc grants", 1)[0]
        self.assertIn(
            "from public.enterprise_role_templates t where t.id=p_template and t.enterprise_id=v_eid and t.archived_at is null for update",
            assignment,
        )
    def test_new_rpcs_are_authenticated_only(self):
        for signature in (
            "clone_role_template(uuid,text,text)",
            "update_role_template(uuid,text,jsonb)",
            "set_member_role_assignment(uuid,uuid,timestamptz)",
            "expire_role_assignments()",
        ):
            self.assertIn(
                f"revoke all on function public.{signature} from public;", self.sql
            )
            self.assertIn(
                f"revoke all on function public.{signature} from anon;", self.sql
            )
            self.assertIn(
                f"revoke all on function public.{signature} from authenticated;",
                self.sql,
            )
            self.assertIn(
                f"grant execute on function public.{signature} to authenticated;",
                self.sql,
            )

    def test_new_rpcs_are_security_definer_with_fixed_search_path(self):
        lowered = self.sql.lower()
        for name in (
            "clone_role_template",
            "update_role_template",
            "set_member_role_assignment",
            "expire_role_assignments",
        ):
            marker = f"create or replace function public.{name}("
            start = lowered.find(marker)
            self.assertGreaterEqual(start, 0)
            definition = lowered[start:].split("$fn$;", 1)[0]
            self.assertIn("security definer", definition)
            self.assertIn("set search_path=public,auth,pg_temp", definition)

if __name__ == "__main__":
    unittest.main()
