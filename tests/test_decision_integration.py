"""Opt-in PostgreSQL integration tests for decision center approvals.

Set PROJECT_RECORDER_TEST_DATABASE_URL to a disposable database with the
enterprise identity, governance, unified platform, task acceptance/extension,
and decision approval migrations applied.
"""

import json
import os
import unittest
import uuid

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
class DecisionIntegrationTest(unittest.TestCase):
    def setUp(self):
        self.conn = psycopg2.connect(TEST_DATABASE_URL)
        self.conn.autocommit = False

    def tearDown(self):
        self.conn.rollback()
        self.conn.close()

    def _as(self, user_id, sql, params=()):
        with self.conn.cursor() as cur:
            claims = json.dumps({"sub": str(user_id), "role": "authenticated"})
            cur.execute(
                "select set_config('request.jwt.claim.sub',%s,true),"
                " set_config('request.jwt.claims',%s,true)",
                (str(user_id), claims),
            )
            cur.execute(sql, params)
            if cur.description:
                return cur.fetchone()

    def _fixture(self):
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
        enterprise_id = self._as(
            owner_id, "select public._identity_bootstrap(%s)", (owner_id,)
        )[0]
        return enterprise_id, owner_id, employee_id

    def test_leave_approval_round_trip_is_idempotent_and_audited(self):
        enterprise_id, owner_id, employee_id = self._fixture()
        leave_id = self._as(
            employee_id,
            "select public.request_leave(current_date,current_date,'rest')"
            "->>'id'",
        )[0]
        approvals = self._as(
            owner_id, "select public.get_decision_center()"
        )[0]["approvals"]
        leave = next(item for item in approvals if item["kind"] == "leave")
        self.assertEqual(leave_id, leave["source_id"])
        self.assertTrue(leave["evidence"])
        self.assertIn("owner_name", leave)
        self.assertIn("due_at", leave)

        first = self._as(
            owner_id,
            "select public.act_on_approval(%s,'approved','ok','leave-key-1')",
            (leave["id"],),
        )[0]
        self.assertTrue(first["ok"])
        self.assertFalse(first["duplicate"])
        second = self._as(
            owner_id,
            "select public.act_on_approval(%s,'approved','ok','leave-key-1')",
            (leave["id"],),
        )[0]
        self.assertTrue(second["duplicate"])
        status = self._as(
            None,
            "select status from public.leave_requests where id=%s",
            (leave_id,),
        )[0]
        self.assertEqual("approved", status)
        event_count = self._as(
            None,
            "select count(*) from public.approval_events where approval_id=%s",
            (leave["id"],),
        )[0]
        self.assertEqual(1, event_count)
        audit_count = self._as(
            None,
            "select count(*) from public.enterprise_identity_audit "
            "where enterprise_id=%s and action='approval.approved'",
            (enterprise_id,),
        )[0]
        self.assertEqual(1, audit_count)

    def test_non_approver_cannot_decide_leave(self):
        _, _, employee_id = self._fixture()
        self._as(
            employee_id,
            "select public.request_leave(current_date,current_date,'rest')",
        )
        approval_id = self._as(
            None,
            "select id from public.approval_requests "
            "where kind='leave' order by created_at desc limit 1",
        )[0]
        with self.conn.cursor() as cur:
            claims = json.dumps(
                {"sub": str(employee_id), "role": "authenticated"}
            )
            cur.execute(
                "select set_config('request.jwt.claim.sub',%s,true),"
                " set_config('request.jwt.claims',%s,true)",
                (str(employee_id), claims),
            )
            cur.execute("savepoint expected_decision_denial")
            with self.assertRaises(psycopg2.Error) as caught:
                cur.execute(
                    "select public.act_on_approval(%s,'approved','no','deny-1')",
                    (approval_id,),
                )
            cur.execute("rollback to savepoint expected_decision_denial")
        self.assertIn("approval permission required", str(caught.exception))


if __name__ == "__main__":
    unittest.main()
