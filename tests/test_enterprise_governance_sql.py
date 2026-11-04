import unittest
from pathlib import Path

import pglast


class EnterpriseGovernanceSqlTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sql = Path("mobile/sql/enterprise-governance-v2.sql").read_text(
            encoding="utf-8"
        )

    def rpc_definition(self, name):
        lowered = self.sql.lower()
        marker = f"create or replace function public.{name}("
        start = lowered.find(marker)
        self.assertGreaterEqual(start, 0)
        return lowered[start:].split("$fn$;", 1)[0]
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
            "required_bps",
            "conflict_disclosed",
            "enterprise_board_motions",
            "enterprise_board_votes",
            "board_vote_idx",
            "6667",
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
            "public.set_member_role_assignment(uuid,uuid,timestamptz,text)",
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
        self.assertIn(
            "join public.enterprise_members em on em.enterprise_id=a.enterprise_id and em.profile_id=a.profile_id and em.status='active'",
            compact,
        )

    def test_mutation_rpcs_require_template_management_permission(self):
        for name in (
            "clone_role_template",
            "update_role_template",
            "set_member_role_assignment",
            "expire_role_assignments",
        ):
            self.assertIn(
                "? 'identity.manage_templates'",
                self.rpc_definition(name),
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

    def test_permission_ceiling_requires_full_exact_grant(self):
        compact = " ".join(self.sql.lower().split())
        self.assertIn("public._identity_permissions_are_grantable", compact)
        self.assertIn(
            "held.value->>'permission_key'=requested.value->>'permission_key'",
            compact,
        )
        self.assertIn(
            "held.value->>'resource'=requested.value->>'resource'",
            compact,
        )
        self.assertIn(
            "held.value->>'action'=requested.value->>'action'",
            compact,
        )
        self.assertIn("jsonb_typeof(p_requested) is distinct from 'array'", compact)
        self.assertIn("return false", compact)
        for name in (
            "clone_role_template",
            "update_role_template",
            "set_member_role_assignment",
        ):
            self.assertIn(
                "public._identity_permissions_are_grantable",
                self.rpc_definition(name),
            )

    def test_permission_ceiling_rejects_scope_escalation(self):
        compact = " ".join(self.sql.lower().split())
        self.assertIn(
            "held.value->>'scope'=requested.value->>'scope'",
            compact,
        )

    def test_permission_ceiling_rejects_condition_mismatch(self):
        compact = " ".join(self.sql.lower().split())
        self.assertIn(
            "coalesce(held.value->'conditions','{}'::jsonb)=coalesce(requested.value->'conditions','{}'::jsonb)",
            compact,
        )

    def test_assignment_rpc_accepts_reason_and_audits_it(self):
        compact = " ".join(self.sql.lower().split())
        self.assertIn("p_reason text default ''", compact)
        self.assertIn("'reason',v_reason", compact)
        self.assertIn(
            "drop function if exists public.set_member_role_assignment(uuid,uuid,timestamptz);",
            compact,
        )

    def test_successful_mutations_write_identity_audit(self):
        for name, action in (
            ("clone_role_template", "role_template.cloned"),
            ("update_role_template", "role_template.updated"),
            ("set_member_role_assignment", "role_assignment.set"),
            ("expire_role_assignments", "role_assignments.expired"),
        ):
            definition = self.rpc_definition(name)
            self.assertIn(
                "insert into public.enterprise_identity_audit",
                definition,
            )
            self.assertIn(action, definition)

    def test_internal_permission_helpers_are_not_client_executable(self):
        for signature in (
            "_identity_role_permission_grants(uuid,uuid)",
            "_identity_permissions_are_grantable(uuid,uuid,jsonb)",
        ):
            for role in ("public", "anon", "authenticated"):
                self.assertIn(
                    f"revoke all on function public.{signature} from {role};",
                    self.sql,
                )
            self.assertNotIn(
                f"grant execute on function public.{signature} to authenticated;",
                self.sql,
            )
    def test_new_rpcs_are_authenticated_only(self):
        for signature in (
            "clone_role_template(uuid,text,text,text,integer,boolean)",
            "update_role_template(uuid,text,jsonb,text,integer,boolean)",
            "set_member_role_assignment(uuid,uuid,timestamptz,text)",
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

    def test_shareholder_proposal_snapshots_active_shares(self):
        propose = self.rpc_definition("propose_enterprise_role")
        compact = " ".join(propose.split())
        self.assertIn(
            "jsonb_object_agg(s.profile_id::text,s.shares)",
            compact,
        )
        self.assertIn("into v_snapshot", compact)
        self.assertIn("share_snapshot", compact)
        self.assertIn(
            "join public.enterprise_members m on m.enterprise_id=s.enterprise_id and m.profile_id=s.profile_id",
            compact,
        )
        self.assertIn("s.shares>0 and m.status='active'", compact)
        self.assertIn(
            "from public.enterprises where id=v_eid for update",
            compact,
        )

    def test_shareholder_motion_class_and_required_thresholds(self):
        compact = " ".join(self.rpc_definition("propose_enterprise_role").split())
        self.assertIn("v_motion_class:=case", compact)
        for role in (
            "chairperson",
            "director",
            "supervisor",
            "ceo",
            "finance",
            "identity_admin",
        ):
            self.assertIn(f"'{role}'", compact)
        self.assertIn(
            "v_required_bps:=case when v_motion_class='major' then 6667 else 5001 end",
            compact,
        )

    def test_shareholder_vote_weight_comes_from_snapshot(self):
        compact = " ".join(
            self.rpc_definition("cast_enterprise_role_vote").split()
        )
        self.assertIn("v_m.share_snapshot", compact)
        self.assertIn("v_uid::text", compact)
        self.assertNotIn("v_shares:=public._identity_shares", compact)

    def test_shareholder_finalize_uses_snapshot_and_class_thresholds(self):
        compact = " ".join(
            self.rpc_definition("_identity_finalize_motion").split()
        )
        self.assertIn("jsonb_each_text(v_m.share_snapshot)", compact)
        self.assertIn("motion_class='major'", compact)
        self.assertIn("v_m.required_bps", compact)
        self.assertIn("v_turnout_bps<5000", compact)
        self.assertIn("v_yes*10000<=(v_yes+v_no)*5000", compact)
        self.assertNotIn(
            "public._identity_total_shares(v_m.enterprise_id)",
            compact,
        )

    def test_shareholder_proposal_vote_and_finalize_are_audited(self):
        self.assertIn(
            "'motion.created'",
            self.rpc_definition("propose_enterprise_role"),
        )
        self.assertIn(
            "'motion.vote_cast'",
            self.rpc_definition("cast_enterprise_role_vote"),
        )
        self.assertIn(
            "'motion.'||v_status",
            self.rpc_definition("_identity_finalize_motion"),
        )

    def test_open_motions_block_share_changes_and_new_holders(self):
        compact = " ".join(
            self.rpc_definition("set_enterprise_shareholder").split()
        )
        self.assertIn(
            "from public.enterprises where id=v_eid for update",
            compact,
        )
        self.assertIn("from public.enterprise_role_motions", compact)
        self.assertIn("from public.enterprise_board_motions", compact)
        self.assertIn("status='open'", compact)
        self.assertIn("cannot change shares while a role or board motion is open", compact)
        self.assertIn("ordinary employee additions do not pass through this rpc", compact)

    def test_sensitive_role_assignments_freeze_while_any_motion_is_open(self):
        compact = " ".join(
            self.rpc_definition("set_member_role_assignment").split()
        )
        self.assertIn(
            "from public.enterprises where id=v_eid for update",
            compact,
        )
        self.assertIn("v_high_risk", compact)
        self.assertIn(
            "v_governance_sensitive:=v_office_key<>'' or v_high_risk",
            compact,
        )
        self.assertIn("from public.enterprise_role_motions", compact)
        self.assertIn("from public.enterprise_board_motions", compact)
        self.assertIn(
            "cannot change voting-sensitive composition while a motion is open",
            compact,
        )
        self.assertIn(
            "ordinary, non-governance assignments remain available while votes are open",
            compact,
        )

    def test_role_motion_conflict_disclosure_is_required_for_self_dealing(self):
        compact = " ".join(self.rpc_definition("propose_enterprise_role").split())
        self.assertIn(
            "p_conflict_disclosed boolean default false",
            compact,
        )
        self.assertIn(
            "v_conflict_disclosed boolean:=coalesce(p_conflict_disclosed,false)",
            compact,
        )
        self.assertIn(
            "if p_target=v_uid and not v_conflict_disclosed then",
            compact,
        )
        self.assertIn(
            "proposer must disclose a conflict when proposing for self",
            compact,
        )
        self.assertIn("conflict_disclosed", compact)
        self.assertIn("'conflict_disclosed',v_conflict_disclosed", compact)

    def test_board_motion_conflict_disclosure_is_persisted_and_audited(self):
        compact = " ".join(self.rpc_definition("create_board_motion").split())
        self.assertIn("p_conflict_disclosed boolean default false", compact)
        self.assertIn(
            "v_conflict_disclosed boolean:=coalesce(p_conflict_disclosed,false)",
            compact,
        )
        self.assertIn("conflict_disclosed", compact)
        self.assertIn("'conflict_disclosed',v_conflict_disclosed", compact)
        self.assertIn(
            "from public.enterprises where id=v_eid for update",
            compact,
        )
        self.assertIn(
            "alter table public.enterprise_board_motions add column if not exists conflict_disclosed boolean not null default false;",
            " ".join(self.sql.lower().split()),
        )

    def test_changed_rpc_signatures_drop_stale_overloads_and_grants(self):
        compact = " ".join(self.sql.lower().split())
        self.assertIn(
            "drop function if exists public.propose_enterprise_role(uuid,text,text,text,text,text,integer);",
            compact,
        )
        self.assertIn(
            "drop function if exists public.create_board_motion(text,text,jsonb);",
            compact,
        )
        self.assertNotIn(
            "grant execute on function public.propose_enterprise_role(uuid,text,text,text,text,text,integer) to authenticated;",
            compact,
        )
        self.assertNotIn(
            "grant execute on function public.create_board_motion(text,text,jsonb) to authenticated;",
            compact,
        )

    def test_board_tables_enforce_one_director_one_vote(self):
        compact = " ".join(self.sql.lower().split())
        self.assertIn("create table if not exists public.enterprise_board_motions", compact)
        self.assertIn("create table if not exists public.enterprise_board_votes", compact)
        self.assertIn(
            "primary key (motion_id,director_profile_id)",
            compact,
        )
        self.assertIn(
            "on conflict (motion_id,director_profile_id) do update",
            compact,
        )
        self.assertNotIn("shares_at_vote", self.rpc_definition("cast_board_vote"))
        self.assertIn(
            "alter table public.enterprise_board_motions enable row level security;",
            self.sql,
        )
        self.assertIn(
            "alter table public.enterprise_board_votes enable row level security;",
            self.sql,
        )

    def test_board_rpcs_require_director_office(self):
        for name in (
            "create_board_motion",
            "cast_board_vote",
            "finalize_board_motion",
        ):
            definition = self.rpc_definition(name)
            self.assertIn("public._identity_is_board_director", definition)
            self.assertIn("security definer", definition)
            self.assertIn("set search_path=public,auth,pg_temp", definition)
        director = " ".join(
            self.rpc_definition("_identity_is_board_director").split()
        )
        self.assertIn("a.office_key in ('chairperson','director')", director)
        self.assertIn("m.role_key in ('chairperson','director')", director)

    def test_board_finalize_requires_majority_quorum_and_yes_votes(self):
        compact = " ".join(
            self.rpc_definition("finalize_board_motion").split()
        )
        self.assertIn("v_cast_count*2>v_director_count", compact)
        self.assertIn("v_yes_count*2>v_cast_count", compact)

    def test_board_actions_are_audited(self):
        for name, action in (
            ("create_board_motion", "board_motion.created"),
            ("cast_board_vote", "board_motion.vote_cast"),
            ("finalize_board_motion", "board_motion."),
        ):
            definition = self.rpc_definition(name)
            self.assertIn(
                "insert into public.enterprise_identity_audit",
                definition,
            )
            self.assertIn(action, definition)

    def test_board_and_shareholder_rpcs_have_least_privilege_grants(self):
        for signature in (
            "create_board_motion(text,text,jsonb,boolean)",
            "cast_board_vote(uuid,text)",
            "finalize_board_motion(uuid)",
            "propose_enterprise_role(uuid,text,text,text,text,text,integer,boolean)",
            "cast_enterprise_role_vote(uuid,text)",
            "close_enterprise_role_vote(uuid)",
        ):
            for role in ("public", "anon", "authenticated"):
                self.assertIn(
                    f"revoke all on function public.{signature} from {role};",
                    self.sql,
                )
            self.assertIn(
                f"grant execute on function public.{signature} to authenticated;",
                self.sql,
            )
        for signature in (
            "_identity_finalize_motion(uuid)",
            "_identity_is_board_director(uuid,uuid)",
            "_identity_board_director_count(uuid)",
            "set_enterprise_shareholder(uuid,numeric)",
        ):
            for role in ("public", "anon", "authenticated"):
                self.assertIn(
                    f"revoke all on function public.{signature} from {role};",
                    self.sql,
                )
            self.assertNotIn(
                f"grant execute on function public.{signature} to authenticated;",
                self.sql,
            )

    def test_board_tables_have_no_client_table_grants(self):
        for table in (
            "enterprise_board_motions",
            "enterprise_board_votes",
        ):
            for role in ("anon", "authenticated"):
                self.assertIn(
                    f"revoke all on table public.{table} from {role};",
                    self.sql,
                )
            self.assertNotIn(
                f"grant all on table public.{table} to authenticated;",
                self.sql,
            )

    def test_point_pool_schema_is_finite_and_board_approved(self):
        compact = " ".join(self.sql.lower().split())
        for text in (
            "create table if not exists public.enterprise_point_pools",
            "create table if not exists public.enterprise_point_ledger",
            "create table if not exists public.enterprise_knowledge_unlocks",
            "single_award_limit",
            "remaining_amount<=total_amount",
            "board_motion_id",
            "quarter",
            "carries_to",
        ):
            self.assertIn(text, compact)
        apply_pool = " ".join(
            self.rpc_definition("_identity_apply_point_pool_motion").split()
        )
        self.assertIn("v_m.kind<>'point_pool'", apply_pool)
        self.assertIn("v_m.status<>'passed'", apply_pool)
        self.assertIn("point pool already approved for quarter", apply_pool)
        finalize = " ".join(self.rpc_definition("finalize_board_motion").split())
        self.assertIn("_identity_apply_point_pool_motion", finalize)

    def test_point_pool_lifecycle_is_current_quarter_only(self):
        create = " ".join(self.rpc_definition("create_board_motion").split())
        apply_pool = " ".join(
            self.rpc_definition("_identity_apply_point_pool_motion").split()
        )
        award = " ".join(self.rpc_definition("award_points").split())
        for definition in (create, apply_pool):
            self.assertIn("point pool quarter must be the current quarter", definition)
            self.assertIn("to_char(now() at time zone 'utc','yyyy')", definition)
            self.assertIn("to_char(now() at time zone 'utc','q')", definition)
        self.assertIn("no active point pool for current quarter", award)
        compact = " ".join(self.sql.lower().split())
        self.assertIn(
            "update public.enterprise_point_pools set status='closed'",
            compact,
        )
        self.assertIn("quarter<>to_char(now() at time zone 'utc','yyyy')", compact)

    def test_stale_point_pool_motion_finalizes_as_rejected(self):
        finalize = " ".join(
            self.rpc_definition("finalize_board_motion").split()
        )
        for text in (
            "v_m.kind='point_pool'",
            "v_pool_quarter<>v_current_quarter",
            "v_status:='rejected'",
            "point pool quarter is no longer current",
            "board_motion.'||v_status",
            "'reason',v_reason",
        ):
            self.assertIn(text, finalize)

    def test_point_pool_motion_requires_finite_budget_payload(self):
        create = " ".join(self.rpc_definition("create_board_motion").split())
        for text in (
            "v_kind='point_pool'",
            "point pool quarter is invalid",
            "point pool total must be positive",
            "point pool single award limit is invalid",
            "v_payload->>'quarter'",
            "v_payload->>'total_amount'",
            "v_payload->>'single_award_limit'",
        ):
            self.assertIn(text, create)

    def test_award_points_guards_and_writes_permanent_ledger(self):
        award = " ".join(self.rpc_definition("award_points").split())
        for text in (
            "p_profile uuid",
            "p_amount integer",
            "p_evidence_type text",
            "p_evidence_id uuid",
            "p_reason text",
            "security definer",
            "set search_path=public,auth,pg_temp",
            "public._identity_is_chairperson",
            "chairperson cannot award points to self",
            "point amount must be positive",
            "single award limit exceeded",
            "evidence is required for point awards",
            "reason is required for point awards",
            "point evidence was already awarded",
            "no active point pool for current quarter",
            "point pool exceeded",
            "for update",
            "remaining_amount=remaining_amount-p_amount",
            "insert into public.enterprise_point_ledger",
            "'award'",
            "point.awarded",
            "points_are_permanent',true",
        ):
            self.assertIn(text, award)
        chair = " ".join(
            self.rpc_definition("_identity_is_chairperson").split()
        )
        self.assertIn("m.role_key='chairperson'", chair)
        self.assertIn("a.office_key='chairperson'", chair)
        self.assertIn("a.status='active'", chair)

    def test_point_state_and_knowledge_unlocks_are_permanent(self):
        state = " ".join(self.rpc_definition("get_point_state").split())
        for text in (
            "security definer",
            "set search_path=public,auth,pg_temp",
            "'balance'",
            "'pool'",
            "'ledger'",
            "sum(l.amount)",
            "order by l.created_at desc",
            "v_quarter",
        ):
            self.assertIn(text, state)

        unlock = " ".join(
            self.rpc_definition("unlock_knowledge_content").split()
        )
        for text in (
            "p_post uuid",
            "security definer",
            "set search_path=public,auth,pg_temp",
            "v_post.is_required",
            "v_post.unlock_cost",
            "for update",
            "enterprise_knowledge_unlocks",
            "insufficient points to unlock knowledge",
            "insert into public.enterprise_point_ledger",
            "'unlock'",
            "knowledge.unlocked",
            "points_are_permanent',true",
            "'content',v_post.content",
        ):
            self.assertIn(text, unlock)
        compact_unlock = unlock.replace(" ", "")
        self.assertIn("-v_cost", compact_unlock)

    def test_point_tables_and_content_access_are_least_privilege(self):
        for table in (
            "enterprise_point_pools",
            "enterprise_point_ledger",
            "enterprise_knowledge_unlocks",
        ):
            self.assertIn(
                f"alter table public.{table} enable row level security;",
                self.sql,
            )
            for role in ("public", "anon", "authenticated"):
                self.assertIn(
                    f"revoke all on table public.{table} from {role};",
                    self.sql,
                )
            self.assertNotIn(
                f"grant all on table public.{table} to authenticated;",
                self.sql,
            )

        helper = " ".join(
            self.rpc_definition("_identity_can_read_community_post").split()
        )
        for text in (
            "security definer",
            "set search_path=public,auth,pg_temp",
            "p.is_required",
            "p.unlock_cost=0",
            "p.author_id=p_uid",
            "p_uid is distinct from auth.uid()",
            "enterprise_knowledge_unlocks",
            "u.profile_id=p_uid",
            "u.post_id=p.id",
        ):
            self.assertIn(text, helper)
        compact = " ".join(self.sql.lower().split())
        self.assertIn(
            "create policy \"community posts readable by members\"",
            compact,
        )
        self.assertIn(
            "using (public._identity_can_read_community_post(id,auth.uid()))",
            compact,
        )

        for signature in (
            "award_points(uuid,integer,text,uuid,text)",
            "get_point_state()",
            "unlock_knowledge_content(uuid)",
        ):
            for role in ("public", "anon", "authenticated"):
                self.assertIn(
                    f"revoke all on function public.{signature} from {role};",
                    self.sql,
                )
            self.assertIn(
                f"grant execute on function public.{signature} to authenticated;",
                self.sql,
            )
        for signature in (
            "_identity_is_chairperson(uuid,uuid)",
            "_identity_apply_point_pool_motion(uuid)",
        ):
            for role in ("public", "anon", "authenticated"):
                self.assertIn(
                    f"revoke all on function public.{signature} from {role};",
                    self.sql,
                )
            self.assertNotIn(
                f"grant execute on function public.{signature} to authenticated;",
                self.sql,
            )

if __name__ == "__main__":
    unittest.main()
