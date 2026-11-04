"""Opt-in PostgreSQL integration tests for Task 4 governance fixes.

These tests are intentionally skipped during normal test runs. To execute them,
point PROJECT_RECORDER_TEST_DATABASE_URL at a disposable database with the
enterprise identity and governance migrations already applied, and install a
PostgreSQL driver compatible with psycopg2.

The tests roll back all fixture data and do not require a persistent seed.
"""

import json
import os
import unittest
import uuid
from datetime import datetime, timedelta, timezone

try:
    import psycopg2
except ImportError:
    psycopg2 = None


TEST_DATABASE_URL = os.environ.get("PROJECT_RECORDER_TEST_DATABASE_URL")
SKIP_REASON = (
    "set PROJECT_RECORDER_TEST_DATABASE_URL and install psycopg2 "
    "to run PostgreSQL integration tests"
)


@unittest.skipUnless(TEST_DATABASE_URL and psycopg2, SKIP_REASON)
class EnterpriseGovernanceIntegrationTest(unittest.TestCase):
    def setUp(self):
        self.conn = psycopg2.connect(TEST_DATABASE_URL)
        self.conn.autocommit = False

    def tearDown(self):
        self.conn.rollback()
        self.conn.close()

    def _as(self, user_id, sql, params=()):
        with self.conn.cursor() as cur:
            if user_id is not None:
                claims = json.dumps(
                    {"sub": str(user_id), "role": "authenticated"}
                )
                cur.execute(
                    "select set_config('request.jwt.claim.sub',%s,true),"
                    " set_config('request.jwt.claims',%s,true)",
                    (str(user_id), claims),
                )
            cur.execute(sql, params)
            if cur.description:
                return cur.fetchone()

    def _assert_sql_error(self, user_id, message, sql, params=()):
        with self.conn.cursor() as cur:
            claims = json.dumps({"sub": str(user_id), "role": "authenticated"})
            cur.execute(
                "select set_config('request.jwt.claim.sub',%s,true),"
                " set_config('request.jwt.claims',%s,true)",
                (str(user_id), claims),
            )
            cur.execute("savepoint expected_governance_error")
            try:
                cur.execute(sql, params)
            except psycopg2.Error as exc:
                self.assertIn(message, str(exc))
                cur.execute("rollback to savepoint expected_governance_error")
                cur.execute("release savepoint expected_governance_error")
            else:
                self.fail(f"expected SQL error containing: {message}")

    def _create_enterprise_fixture(self):
        owner_id = uuid.uuid4()
        employee_id = uuid.uuid4()
        with self.conn.cursor() as cur:
            for user_id, code, name, role, boss_id in (
                (owner_id, "owner-" + owner_id.hex, "Owner", "boss", None),
                (
                    employee_id,
                    "employee-" + employee_id.hex,
                    "Employee",
                    "employee",
                    owner_id,
                ),
            ):
                cur.execute(
                    "insert into auth.users(id,email) values(%s,%s) "
                    "on conflict (id) do nothing",
                    (user_id, code + "@example.test"),
                )
                cur.execute(
                    "insert into public.profiles(id,code,name,role,boss_id) "
                    "values(%s,%s,%s,%s,%s)",
                    (user_id, code, name, role, boss_id),
                )
            cur.execute(
                "insert into public.enterprises(owner_profile_id,name) "
                "values(%s,%s) returning id",
                (owner_id, "Governance Integration Test"),
            )
            enterprise_id = cur.fetchone()[0]
        self._as(
            owner_id,
            "select public._identity_bootstrap(%s)",
            (owner_id,),
        )
        return enterprise_id, owner_id, employee_id

    def _provision_templates(self, enterprise_id):
        self._as(
            None,
            "select public.provision_default_role_templates(%s)",
            (enterprise_id,),
        )

    def _template_id(self, enterprise_id, key):
        return self._as(
            None,
            "select id from public.enterprise_role_templates "
            "where enterprise_id=%s and key=%s and archived_at is null",
            (enterprise_id, key),
        )[0]

    def _add_identity_admin_assignment(
        self, enterprise_id, owner_id
    ):
        template_id = self._template_id(enterprise_id, "identity_admin")
        version_id = self._as(
            None,
            "select id from public.enterprise_role_template_versions "
            "where template_id=%s and status='active' "
            "order by version desc limit 1",
            (template_id,),
        )[0]
        self._as(
            None,
            "insert into public.enterprise_role_assignments("
            "enterprise_id,profile_id,template_version_id,office_key,"
            "is_primary,status,starts_at,ends_at,appointed_by"
            ") values(%s,%s,%s,'identity_admin',false,'active',now(),"
            "now()+interval '30 days',%s)",
            (enterprise_id, owner_id, version_id, owner_id),
        )

    def test_snapshot_is_used_after_direct_share_mutation(self):
        enterprise_id, owner_id, employee_id = self._create_enterprise_fixture()
        result = self._as(
            owner_id,
            "select public.propose_enterprise_role("
            "%s,'appointment','project_manager','','','',3,false)",
            (employee_id,),
        )[0]
        motion_id = result["motion_id"]

        snapshot_owner_shares = self._as(
            None,
            "select (share_snapshot->>%s)::numeric "
            "from public.enterprise_role_motions where id=%s",
            (str(owner_id), motion_id),
        )[0]
        self.assertEqual(100, snapshot_owner_shares)

        self._as(
            None,
            "update public.enterprise_shareholders set shares=60 "
            "where enterprise_id=%s and profile_id=%s",
            (enterprise_id, owner_id),
        )
        self._as(
            None,
            "update public.enterprise_shareholders set shares=40 "
            "where enterprise_id=%s and profile_id=%s",
            (enterprise_id, employee_id),
        )

        vote_result = self._as(
            owner_id,
            "select public.cast_enterprise_role_vote(%s,'yes')",
            (motion_id,),
        )[0]
        self.assertEqual(100, vote_result["shares"])
        stored_weight = self._as(
            None,
            "select shares_at_vote from public.enterprise_role_votes "
            "where motion_id=%s and voter_profile_id=%s",
            (motion_id, owner_id),
        )[0]
        self.assertEqual(100, stored_weight)

    def test_self_proposal_requires_disclosure_and_audits_it(self):
        _, owner_id, _ = self._create_enterprise_fixture()
        self._assert_sql_error(
            owner_id,
            "proposer must disclose a conflict when proposing for self",
            "select public.propose_enterprise_role("
            "%s,'appointment','project_manager','','','',3,false)",
            (owner_id,),
        )
        result = self._as(
            owner_id,
            "select public.propose_enterprise_role("
            "%s,'appointment','project_manager','','','',3,true)",
            (owner_id,),
        )[0]
        motion_id = result["motion_id"]
        self.assertTrue(result["conflict_disclosed"])
        stored = self._as(
            None,
            "select conflict_disclosed from public.enterprise_role_motions "
            "where id=%s",
            (motion_id,),
        )[0]
        self.assertTrue(stored)
        audited = self._as(
            None,
            "select details->>'conflict_disclosed' "
            "from public.enterprise_identity_audit "
            "where action='motion.created' and details->>'motion_id'=%s "
            "order by id desc limit 1",
            (str(motion_id),),
        )[0]
        self.assertEqual("true", audited)

    def test_open_board_motion_freezes_sensitive_but_not_ordinary_roles(self):
        enterprise_id, owner_id, employee_id = self._create_enterprise_fixture()
        self._provision_templates(enterprise_id)
        self._add_identity_admin_assignment(enterprise_id, owner_id)

        board_motion = self._as(
            owner_id,
            "select public.create_board_motion("
            "'Integration board motion','governance','{}',false)",
        )[0]
        self.assertEqual("open", board_motion["status"])

        self._assert_sql_error(
            owner_id,
            "cannot change shares while a role or board motion is open",
            "select public.set_enterprise_shareholder(%s,10)",
            (employee_id,),
        )

        director_template = self._template_id(enterprise_id, "director")
        employee_template = self._template_id(enterprise_id, "project_manager")
        ends_at = datetime.now(timezone.utc) + timedelta(days=30)
        self._assert_sql_error(
            owner_id,
            "cannot change voting-sensitive composition while a motion is open",
            "select public.set_member_role_assignment(%s,%s,%s,'freeze')",
            (employee_id, director_template, ends_at),
        )

        ordinary_result = self._as(
            owner_id,
            "select public.set_member_role_assignment(%s,%s,%s,'ordinary')",
            (employee_id, employee_template, ends_at),
        )[0]
        self.assertTrue(ordinary_result["ok"])


if __name__ == "__main__":
    unittest.main()
