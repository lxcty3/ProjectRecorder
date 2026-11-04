"""Opt-in PostgreSQL integration tests for governance and point fixes.

These tests are intentionally skipped during normal test runs. To execute them,
point PROJECT_RECORDER_TEST_DATABASE_URL at a disposable database with the
enterprise identity and governance migrations already applied, and install a
PostgreSQL driver compatible with psycopg2.

Most tests roll back all fixture data and do not require a persistent seed.
The concurrent award test commits its isolated fixture so two connections can
race, then removes that fixture in a finally block.
"""

import json
import os
import threading
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

    def _as_authenticated(self, user_id, sql, params=()):
        claims = json.dumps({"sub": str(user_id), "role": "authenticated"})
        with self.conn.cursor() as cur:
            cur.execute(
                "select set_config('request.jwt.claim.sub',%s,true),"
                " set_config('request.jwt.claims',%s,true)",
                (str(user_id), claims),
            )
            cur.execute("set local role authenticated")
            cur.execute(sql, params)
            result = cur.fetchone() if cur.description else None
            cur.execute("reset role")
            return result

    def _assert_authenticated_error(
        self, user_id, message, sql, params=()
    ):
        claims = json.dumps({"sub": str(user_id), "role": "authenticated"})
        with self.conn.cursor() as cur:
            cur.execute(
                "select set_config('request.jwt.claim.sub',%s,true),"
                " set_config('request.jwt.claims',%s,true)",
                (str(user_id), claims),
            )
            cur.execute("set local role authenticated")
            cur.execute("savepoint expected_authenticated_error")
            caught = None
            try:
                cur.execute(sql, params)
            except psycopg2.Error as exc:
                caught = exc
            if caught is not None:
                cur.execute("rollback to savepoint expected_authenticated_error")
                cur.execute("release savepoint expected_authenticated_error")
            cur.execute("reset role")
            if caught is None:
                self.fail(f"expected SQL error containing: {message}")
            self.assertIn(message, str(caught))

    @staticmethod
    def _current_quarter():
        now = datetime.now(timezone.utc)
        return f"{now.year}-Q{((now.month - 1) // 3) + 1}"

    @classmethod
    def _shift_quarter(cls, quarter, offset):
        year_text, quarter_text = quarter.split("-Q")
        index = int(year_text) * 4 + int(quarter_text) - 1 + offset
        return f"{index // 4}-Q{(index % 4) + 1}"

    def _create_point_pool(
        self, owner_id, total_amount, single_award_limit,
        quarter=None,
    ):
        quarter = quarter or self._current_quarter()
        payload = json.dumps({
            "quarter": quarter,
            "total_amount": total_amount,
            "single_award_limit": single_award_limit,
        })
        motion = self._as(
            owner_id,
            "select public.create_board_motion("
            "'Point pool integration','point_pool',%s::jsonb,false)",
            (payload,),
        )[0]
        motion_id = motion["board_motion_id"]
        vote = self._as(
            owner_id,
            "select public.cast_board_vote(%s,'yes')",
            (motion_id,),
        )[0]
        self.assertEqual("passed", vote["motion_status"])
        return self._as(
            None,
            "select id,remaining_amount,total_amount,single_award_limit,status "
            "from public.enterprise_point_pools "
            "where board_motion_id=%s",
            (motion_id,),
        )

    def _create_community_post(
        self, author_id, content, unlock_cost=0, is_required=False
    ):
        return self._as(
            None,
            "insert into public.community_posts("
            "author_id,content,unlock_cost,is_required"
            ") values(%s,%s,%s,%s) returning id",
            (author_id, content, unlock_cost, is_required),
        )[0]

    def _create_acceptance_evidence(self, owner_id, employee_id, label):
        task_id = uuid.uuid4()
        log_id = uuid.uuid4()
        self._as(
            None,
            "insert into public.tasks("
            "id,boss_id,employee_id,title,detail,plan_date,est_hours"
            ") values(%s,%s,%s,%s,'',current_date,1)",
            (task_id, owner_id, employee_id, label),
        )
        self._as(
            None,
            "insert into public.task_logs("
            "id,task_id,employee_id,finished_at,finish_date"
            ") values(%s,%s,%s,now(),current_date)",
            (log_id, task_id, employee_id),
        )
        return log_id
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

    def _set_share_split(
        self, enterprise_id, owner_id, employee_id,
        owner_shares, employee_shares,
    ):
        self._as(
            None,
            "update public.enterprise_shareholders set shares=%s "
            "where enterprise_id=%s and profile_id=%s",
            (owner_shares, enterprise_id, owner_id),
        )
        self._as(
            None,
            "insert into public.enterprise_shareholders("
            "enterprise_id,profile_id,shares,updated_by"
            ") values(%s,%s,%s,%s) "
            "on conflict (enterprise_id,profile_id) do update "
            "set shares=excluded.shares,updated_by=excluded.updated_by,"
            "updated_at=now()",
            (enterprise_id, employee_id, employee_shares, owner_id),
        )

    def _close_after_expiry(self, owner_id, motion_id):
        self._as(
            None,
            "update public.enterprise_role_motions "
            "set closes_at=now()-interval '1 second' where id=%s",
            (motion_id,),
        )
        return self._as(
            owner_id,
            "select public.close_enterprise_role_vote(%s)",
            (motion_id,),
        )[0]

    def _propose_major_and_close(
        self, enterprise_id, owner_id, employee_id, owner_shares,
        employee_shares,
    ):
        self._set_share_split(
            enterprise_id, owner_id, employee_id,
            owner_shares, employee_shares,
        )
        result = self._as(
            owner_id,
            "select public.propose_enterprise_role("
            "%s,'appointment','director','','','',3,false)",
            (employee_id,),
        )[0]
        motion_id = result["motion_id"]
        self._as(
            owner_id,
            "select public.cast_enterprise_role_vote(%s,'yes')",
            (motion_id,),
        )
        return motion_id, self._close_after_expiry(owner_id, motion_id)

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
        ends_at = datetime.now(timezone.utc) + timedelta(days=6)
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


    def test_major_exact_6667_bps_passes(self):
        enterprise_id, owner_id, employee_id = self._create_enterprise_fixture()
        motion_id, result = self._propose_major_and_close(
            enterprise_id, owner_id, employee_id, 6667, 3333
        )
        self.assertEqual("passed", result["status"])
        self.assertEqual(6667, result["yes_bps"])
        self.assertEqual(
            "passed",
            self._as(
                None,
                "select status from public.enterprise_role_motions where id=%s",
                (motion_id,),
            )[0],
        )

    def test_major_exact_6666_bps_is_rejected(self):
        enterprise_id, owner_id, employee_id = self._create_enterprise_fixture()
        motion_id, result = self._propose_major_and_close(
            enterprise_id, owner_id, employee_id, 6666, 3334
        )
        self.assertEqual("rejected", result["status"])
        self.assertEqual(6666, result["yes_bps"])
        self.assertEqual(
            "rejected",
            self._as(
                None,
                "select status from public.enterprise_role_motions where id=%s",
                (motion_id,),
            )[0],
        )

    def test_ordinary_exact_50_percent_quorum_passes(self):
        enterprise_id, owner_id, employee_id = self._create_enterprise_fixture()
        self._set_share_split(
            enterprise_id, owner_id, employee_id, 5000, 5000
        )
        result = self._as(
            owner_id,
            "select public.propose_enterprise_role("
            "%s,'appointment','project_manager','','','',3,false)",
            (employee_id,),
        )[0]
        motion_id = result["motion_id"]
        self._as(
            owner_id,
            "select public.cast_enterprise_role_vote(%s,'yes')",
            (motion_id,),
        )
        closed = self._close_after_expiry(owner_id, motion_id)
        self.assertEqual("passed", closed["status"])
        self.assertEqual(5000, closed["turnout_bps"])

    def test_ordinary_exact_50_percent_approval_is_rejected(self):
        enterprise_id, owner_id, employee_id = self._create_enterprise_fixture()
        self._set_share_split(
            enterprise_id, owner_id, employee_id, 5000, 5000
        )
        result = self._as(
            owner_id,
            "select public.propose_enterprise_role("
            "%s,'appointment','project_manager','','','',3,false)",
            (employee_id,),
        )[0]
        motion_id = result["motion_id"]
        self._as(
            owner_id,
            "select public.cast_enterprise_role_vote(%s,'yes')",
            (motion_id,),
        )
        vote_result = self._as(
            employee_id,
            "select public.cast_enterprise_role_vote(%s,'no')",
            (motion_id,),
        )[0]
        self.assertEqual("rejected", vote_result["motion_status"])
        decision = self._as(
            None,
            "select status,decision_reason "
            "from public.enterprise_role_motions where id=%s",
            (motion_id,),
        )
        self.assertEqual("rejected", decision[0])
        self.assertIn("Approval threshold", decision[1])

    def test_board_vote_replacement_keeps_one_vote_per_director(self):
        enterprise_id, owner_id, employee_id = self._create_enterprise_fixture()
        self._as(
            None,
            "update public.enterprise_members set role_key='director' "
            "where enterprise_id=%s and profile_id=%s",
            (enterprise_id, employee_id),
        )
        board_motion = self._as(
            owner_id,
            "select public.create_board_motion("
            "'Vote replacement','operations','{}',false)",
        )[0]
        motion_id = board_motion["board_motion_id"]
        self._as(
            owner_id,
            "select public.cast_board_vote(%s,'yes')",
            (motion_id,),
        )
        second = self._as(
            owner_id,
            "select public.cast_board_vote(%s,'no')",
            (motion_id,),
        )[0]
        self.assertEqual(1, second["cast_count"])
        vote = self._as(
            None,
            "select count(*),min(choice) "
            "from public.enterprise_board_votes "
            "where motion_id=%s and director_profile_id=%s",
            (motion_id, owner_id),
        )
        self.assertEqual(1, vote[0])
        self.assertEqual("no", vote[1])


    def test_point_pool_motion_must_use_current_quarter(self):
        _, owner_id, _ = self._create_enterprise_fixture()
        current_pool = self._create_point_pool(owner_id, 100, 50)
        previous_quarter = self._shift_quarter(self._current_quarter(), -1)
        next_quarter = self._shift_quarter(self._current_quarter(), 1)
        for quarter in (previous_quarter, next_quarter):
            payload = json.dumps({
                "quarter": quarter,
                "total_amount": 100,
                "single_award_limit": 50,
            })
            self._assert_sql_error(
                owner_id,
                "point pool quarter must be the current quarter",
                "select public.create_board_motion("
                "'Invalid lifecycle pool','point_pool',%s::jsonb,false)",
                (payload,),
            )
        status = self._as(
            None,
            "select status from public.enterprise_point_pools where id=%s",
            (current_pool[0],),
        )[0]
        self.assertEqual("active", status)

    def test_point_pool_motion_crossing_quarter_finalizes_as_rejected(self):
        _, owner_id, _ = self._create_enterprise_fixture()
        payload = json.dumps({
            "quarter": self._current_quarter(),
            "total_amount": 100,
            "single_award_limit": 50,
        })
        motion = self._as(
            owner_id,
            "select public.create_board_motion("
            "'Quarter boundary pool','point_pool',%s::jsonb,false)",
            (payload,),
        )[0]
        motion_id = motion["board_motion_id"]
        previous_quarter = self._shift_quarter(self._current_quarter(), -1)
        self._as(
            None,
            "update public.enterprise_board_motions "
            "set payload=jsonb_set(payload,'{quarter}',to_jsonb(%s::text)) "
            "where id=%s",
            (previous_quarter, motion_id),
        )

        vote = self._as(
            owner_id,
            "select public.cast_board_vote(%s,'yes')",
            (motion_id,),
        )[0]
        self.assertEqual("rejected", vote["motion_status"])
        motion_state = self._as(
            None,
            "select status,decided_at is not null "
            "from public.enterprise_board_motions where id=%s",
            (motion_id,),
        )
        self.assertEqual(("rejected", True), motion_state)
        pools = self._as(
            None,
            "select count(*) from public.enterprise_point_pools "
            "where board_motion_id=%s",
            (motion_id,),
        )[0]
        self.assertEqual(0, pools)
        audit = self._as(
            None,
            "select action,details->>'reason' "
            "from public.enterprise_identity_audit "
            "where details->>'board_motion_id'=%s "
            "and action='board_motion.rejected' "
            "order by id desc limit 1",
            (str(motion_id),),
        )
        self.assertEqual(
            ("board_motion.rejected",
             "Point pool quarter is no longer current"),
            audit,
        )

    def test_award_points_requires_chairperson_and_rejects_self(self):
        _, owner_id, employee_id = self._create_enterprise_fixture()
        self._create_point_pool(owner_id, 100, 50)
        self._assert_sql_error(
            employee_id,
            "only the active chairperson may award points",
            "select public.award_points(%s,10,'acceptance',%s,'not chair')",
            (owner_id, uuid.uuid4()),
        )
        self._assert_sql_error(
            owner_id,
            "chairperson cannot award points to self",
            "select public.award_points(%s,10,'acceptance',%s,'self award')",
            (owner_id, uuid.uuid4()),
        )

    def test_award_points_rejects_arbitrary_evidence_uuid(self):
        _, owner_id, employee_id = self._create_enterprise_fixture()
        self._create_point_pool(owner_id, 100, 50)
        self._assert_sql_error(
            owner_id,
            "evidence record is not allowed",
            "select public.award_points(%s,10,'acceptance',%s,'forged')",
            (employee_id, uuid.uuid4()),
        )

    def test_award_points_enforces_pool_and_duplicate_evidence(self):
        _, owner_id, employee_id = self._create_enterprise_fixture()
        pool_id = self._create_point_pool(owner_id, 100, 80)[0]
        first_evidence = self._create_acceptance_evidence(
            owner_id, employee_id, "first acceptance"
        )
        first = self._as(
            owner_id,
            "select public.award_points(%s,80,'acceptance',%s,'first award')",
            (employee_id, first_evidence),
        )[0]
        self.assertEqual(20, first["pool_remaining"])
        self.assertTrue(first["points_are_permanent"])
        self._assert_sql_error(
            owner_id,
            "point pool exceeded",
            "select public.award_points(%s,30,'acceptance',%s,'too much')",
            (employee_id, self._create_acceptance_evidence(
                owner_id, employee_id, "oversized acceptance"
            )),
        )
        self._assert_sql_error(
            owner_id,
            "point evidence was already awarded",
            "select public.award_points(%s,10,'acceptance',%s,'duplicate')",
            (employee_id, first_evidence),
        )
        remaining = self._as(
            owner_id,
            "select public.award_points(%s,20,'acceptance',%s,'remaining award')",
            (employee_id, self._create_acceptance_evidence(
                owner_id, employee_id, "remaining acceptance"
            )),
        )[0]
        self.assertEqual(0, remaining["pool_remaining"])
        self._assert_sql_error(
            owner_id,
            "point pool exceeded",
            "select public.award_points(%s,1,'acceptance',%s,'exhausted')",
            (employee_id, self._create_acceptance_evidence(
                owner_id, employee_id, "exhausted acceptance"
            )),
        )
        state = self._as(
            None,
            "select remaining_amount,status from public.enterprise_point_pools "
            "where id=%s",
            (pool_id,),
        )
        self.assertEqual((0, "active"), state)
        audit_count = self._as(
            None,
            "select count(*) from public.enterprise_identity_audit "
            "where action='point.awarded' and details->>'pool_id'=%s",
            (str(pool_id),),
        )[0]
        self.assertEqual(2, audit_count)
    def test_concurrent_awards_cannot_overspend_pool(self):
        enterprise_id, owner_id, employee_id = (
            self._create_enterprise_fixture()
        )
        pool_id = None
        try:
            pool_id = self._create_point_pool(owner_id, 100, 100)[0]
            self.conn.commit()

            barrier = threading.Barrier(2)
            results = []
            results_lock = threading.Lock()

            def award(evidence_id):
                conn = psycopg2.connect(TEST_DATABASE_URL)
                try:
                    claims = json.dumps({
                        "sub": str(owner_id),
                        "role": "authenticated",
                    })
                    with conn.cursor() as cur:
                        cur.execute(
                            "select set_config("
                            "'request.jwt.claim.sub',%s,true),"
                            " set_config('request.jwt.claims',%s,true)",
                            (str(owner_id), claims),
                        )
                        cur.execute("set local role authenticated")
                        barrier.wait(timeout=10)
                        cur.execute(
                            "select public.award_points("
                            "%s,60,'acceptance',%s,'concurrent award')",
                            (employee_id, evidence_id),
                        )
                        result = cur.fetchone()[0]
                    conn.commit()
                    with results_lock:
                        results.append(("ok", result))
                except Exception as exc:
                    conn.rollback()
                    with results_lock:
                        results.append(("error", str(exc)))
                finally:
                    conn.close()

            evidence_ids = [
                self._create_acceptance_evidence(
                    owner_id, employee_id, f"concurrent acceptance {index}"
                )
                for index in range(2)
            ]
            threads = [
                threading.Thread(target=award, args=(evidence_id,))
                for evidence_id in evidence_ids
            ]
            for thread in threads:
                thread.start()
            for thread in threads:
                thread.join(timeout=20)

            self.assertFalse(any(thread.is_alive() for thread in threads))
            successes = [result for kind, result in results if kind == "ok"]
            errors = [result for kind, result in results if kind == "error"]
            self.assertEqual(1, len(successes))
            self.assertEqual(1, len(errors))
            self.assertIn("point pool exceeded", errors[0])

            ledger = self._as(
                None,
                "select count(*),coalesce(sum(amount),0) "
                "from public.enterprise_point_ledger "
                "where pool_id=%s and entry_type='award'",
                (pool_id,),
            )
            self.assertEqual((1, 60), ledger)
            remaining = self._as(
                None,
                "select remaining_amount from public.enterprise_point_pools "
                "where id=%s",
                (pool_id,),
            )[0]
            self.assertEqual(40, remaining)
            audit_count = self._as(
                None,
                "select count(*) from public.enterprise_identity_audit "
                "where action='point.awarded' and details->>'pool_id'=%s",
                (str(pool_id),),
            )[0]
            self.assertEqual(1, audit_count)
        finally:
            self.conn.rollback()
            self._as(
                None,
                "delete from public.enterprises where id=%s",
                (enterprise_id,),
            )
            self._as(
                None,
                "delete from public.profiles where id=%s",
                (employee_id,),
            )
            self._as(
                None,
                "delete from public.profiles where id=%s",
                (owner_id,),
            )
            self._as(
                None,
                "delete from auth.users where id in (%s,%s)",
                (owner_id, employee_id),
            )
            self.conn.commit()

    def test_required_free_and_paid_unlocks_are_permanent(self):
        enterprise_id, owner_id, employee_id = self._create_enterprise_fixture()
        self._create_point_pool(owner_id, 200, 100)
        self._as(
            owner_id,
            "select public.award_points(%s,100,'acceptance',%s,'unlock budget')",
            (employee_id, self._create_acceptance_evidence(
                owner_id, employee_id, "unlock budget"
            )),
        )
        required_id = self._create_community_post(
            owner_id, "required content", unlock_cost=50, is_required=True
        )
        free_id = self._create_community_post(
            owner_id, "free content", unlock_cost=0, is_required=False
        )
        paid_id = self._create_community_post(
            owner_id, "paid content", unlock_cost=30, is_required=False
        )

        required = self._as(
            employee_id,
            "select public.unlock_knowledge_content(%s)",
            (required_id,),
        )[0]
        self.assertTrue(required["required"])
        self.assertEqual(0, required["cost"])
        self.assertEqual("required content", required["content"])
        self.assertEqual(
            (1, 100),
            self._as(
                None,
                "select count(*),coalesce(sum(amount),0) "
                "from public.enterprise_point_ledger where enterprise_id=%s",
                (enterprise_id,),
            ),
        )

        free = self._as(
            employee_id,
            "select public.unlock_knowledge_content(%s)",
            (free_id,),
        )[0]
        self.assertFalse(free["required"])
        self.assertEqual(0, free["cost"])
        self.assertEqual("free content", free["content"])
        self.assertEqual(
            (1, 100),
            self._as(
                None,
                "select count(*),coalesce(sum(amount),0) "
                "from public.enterprise_point_ledger where enterprise_id=%s",
                (enterprise_id,),
            ),
        )

        paid = self._as(
            employee_id,
            "select public.unlock_knowledge_content(%s)",
            (paid_id,),
        )[0]
        self.assertEqual(30, paid["cost"])
        self.assertEqual(70, paid["balance"])
        self.assertEqual("paid content", paid["content"])
        again = self._as(
            employee_id,
            "select public.unlock_knowledge_content(%s)",
            (paid_id,),
        )[0]
        self.assertTrue(again["already_unlocked"])
        self.assertEqual("paid content", again["content"])
        ledger = self._as(
            None,
            "select count(*),coalesce(sum(amount),0) "
            "from public.enterprise_point_ledger where enterprise_id=%s",
            (enterprise_id,),
        )
        self.assertEqual((2, 70), ledger)
        unlocks = self._as(
            None,
            "select count(*) from public.enterprise_knowledge_unlocks "
            "where enterprise_id=%s",
            (enterprise_id,),
        )[0]
        self.assertEqual(1, unlocks)
        audit_count = self._as(
            None,
            "select count(*) from public.enterprise_identity_audit "
            "where action='knowledge.unlocked' and enterprise_id=%s",
            (enterprise_id,),
        )[0]
        self.assertEqual(1, audit_count)

    def test_paid_post_rls_and_user_id_probe_are_safe(self):
        _, owner_id, employee_id = self._create_enterprise_fixture()
        self._create_point_pool(owner_id, 200, 100)
        self._as(
            owner_id,
            "select public.award_points(%s,100,'acceptance',%s,'rls budget')",
            (employee_id, self._create_acceptance_evidence(
                owner_id, employee_id, "rls budget"
            )),
        )
        required_id = self._create_community_post(
            owner_id, "rls required", unlock_cost=25, is_required=True
        )
        free_id = self._create_community_post(owner_id, "rls free")
        paid_id = self._create_community_post(
            owner_id, "rls paid", unlock_cost=20
        )
        locked_id = self._create_community_post(
            owner_id, "rls locked", unlock_cost=20
        )
        self._as(
            employee_id,
            "select public.unlock_knowledge_content(%s)",
            (paid_id,),
        )

        visible = self._as_authenticated(
            employee_id,
            "select array_agg(id order by id) from public.community_posts "
            "where id in (%s,%s,%s,%s)",
            (required_id, free_id, paid_id, locked_id),
        )[0]
        self.assertEqual({required_id, free_id, paid_id}, set(visible))

        probe_other = self._as_authenticated(
            employee_id,
            "select public._identity_can_read_community_post(%s,%s)",
            (paid_id, owner_id),
        )[0]
        self.assertFalse(probe_other)
        unlocked_self = self._as_authenticated(
            employee_id,
            "select public._identity_can_read_community_post(%s,%s)",
            (paid_id, employee_id),
        )[0]
        self.assertTrue(unlocked_self)
        locked_self = self._as_authenticated(
            employee_id,
            "select public._identity_can_read_community_post(%s,%s)",
            (locked_id, employee_id),
        )[0]
        self.assertFalse(locked_self)

    def test_full_point_ledger_visible_to_board_and_auditor(self):
        enterprise_id, owner_id, employee_id = self._create_enterprise_fixture()
        other_id = uuid.uuid4()
        self._as(
            None,
            "insert into auth.users(id,email) values(%s,%s)",
            (other_id, "other-" + other_id.hex + "@example.test"),
        )
        self._as(
            None,
            "insert into public.profiles(id,code,name,role,boss_id) "
            "values(%s,%s,'Other','employee',%s)",
            (other_id, "other-" + other_id.hex, owner_id),
        )
        self._as(
            None,
            "insert into public.enterprise_members("
            "enterprise_id,profile_id,role_key,status"
            ") values(%s,%s,'employee','active')",
            (enterprise_id, other_id),
        )
        self._create_point_pool(owner_id, 200, 100)
        for profile_id, label in (
            (employee_id, "employee ledger"),
            (other_id, "other ledger"),
        ):
            self._as(
                owner_id,
                "select public.award_points(%s,10,'acceptance',%s,%s)",
                (
                    profile_id,
                    self._create_acceptance_evidence(
                        owner_id, profile_id, label
                    ),
                    label,
                ),
            )

        for index in range(105):
            self._as(
                None,
                "insert into public.enterprise_point_ledger("
                "enterprise_id,profile_id,amount,entry_type,evidence_type,"
                "evidence_id,reason,actor_profile_id"
                ") values(%s,%s,1,'award','acceptance',%s,%s,%s)",
                (
                    enterprise_id,
                    employee_id,
                    uuid.uuid4(),
                    f"bulk ledger row {index}",
                    owner_id,
                ),
            )

        owner_state = self._as(
            owner_id, "select public.get_point_state()"
        )[0]
        self.assertGreater(len(owner_state["ledger"]), 100)
        self.assertTrue(owner_state["can_read_full_ledger"])
        self.assertEqual("enterprise", owner_state["ledger_scope"])
        self.assertEqual(
            {employee_id, other_id},
            {uuid.UUID(entry["profile_id"]) for entry in owner_state["ledger"]},
        )

        employee_state = self._as(
            employee_id, "select public.get_point_state()"
        )[0]
        self.assertFalse(employee_state["can_read_full_ledger"])
        self.assertGreater(len(employee_state["ledger"]), 100)
        self.assertEqual(
            {employee_id},
            {uuid.UUID(entry["profile_id"]) for entry in employee_state["ledger"]},
        )

        self._as(
            None,
            "update public.enterprise_members set role_key='auditor' "
            "where enterprise_id=%s and profile_id=%s",
            (enterprise_id, employee_id),
        )
        auditor_state = self._as(
            employee_id, "select public.get_point_state()"
        )[0]
        self.assertTrue(auditor_state["can_read_full_ledger"])
        self.assertEqual(
            {employee_id, other_id},
            {uuid.UUID(entry["profile_id"]) for entry in auditor_state["ledger"]},
        )
        self.assertGreater(len(auditor_state["ledger"]), 100)

    def test_point_function_and_table_grants_are_least_privilege(self):
        user_id = uuid.uuid4()
        expected_function_grants = (
            ("public.award_points(uuid,integer,text,uuid,text)", True),
            ("public.get_point_state()", True),
            ("public.unlock_knowledge_content(uuid)", True),
            ("public._identity_can_read_community_post(uuid,uuid)", True),
            ("public._identity_is_chairperson(uuid,uuid)", False),
            ("public._identity_apply_point_pool_motion(uuid)", False),
        )
        for signature, expected in expected_function_grants:
            granted = self._as(
                None,
                "select has_function_privilege("
                "'authenticated',%s,'execute')",
                (signature,),
            )[0]
            self.assertEqual(expected, granted, signature)

        for table in (
            "enterprise_point_pools",
            "enterprise_point_ledger",
            "enterprise_knowledge_unlocks",
        ):
            for privilege in ("select", "insert", "update", "delete"):
                granted = self._as(
                    None,
                    "select has_table_privilege('authenticated',%s,%s)",
                    (f"public.{table}", privilege),
                )[0]
                self.assertFalse(granted, f"{table}:{privilege}")

        self._assert_authenticated_error(
            user_id,
            "permission denied for function",
            "select public._identity_is_chairperson(%s,%s)",
            (uuid.uuid4(), user_id),
        )
        self._assert_authenticated_error(
            user_id,
            "permission denied for function",
            "select public._identity_apply_point_pool_motion(%s)",
            (uuid.uuid4(),),
        )

if __name__ == "__main__":
    unittest.main()
