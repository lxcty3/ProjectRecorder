import json
import os
import unittest
import uuid
from datetime import date, timedelta

try:
    import psycopg2
except ImportError:  # pragma: no cover
    psycopg2 = None

TEST_DATABASE_URL = os.environ.get("PROJECT_RECORDER_TEST_DATABASE_URL", "")
SKIP_REASON = (
    "PROJECT_RECORDER_TEST_DATABASE_URL is not set or psycopg2 is unavailable"
)


@unittest.skipUnless(TEST_DATABASE_URL and psycopg2, SKIP_REASON)
class ExecutionIntegrationTest(unittest.TestCase):
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
        owner = uuid.uuid4()
        employee = uuid.uuid4()
        recipient = uuid.uuid4()
        reviewer = uuid.uuid4()
        users = (
            (owner, "owner-", "Owner", "boss", None),
            (employee, "employee-", "Employee", "employee", owner),
            (recipient, "recipient-", "Recipient", "employee", owner),
            (reviewer, "reviewer-", "Reviewer", "employee", owner),
        )
        with self.conn.cursor() as cur:
            for user_id, prefix, name, role, boss_id in users:
                code = prefix + user_id.hex
                cur.execute(
                    "insert into auth.users(id,email) values(%s,%s)",
                    (user_id, code + "@example.test"),
                )
                cur.execute(
                    "insert into public.profiles(id,code,name,role,boss_id) "
                    "values(%s,%s,%s,%s,%s)",
                    (user_id, code, name, role, boss_id),
                )
        enterprise_id = self._as(
            owner, "select public._identity_bootstrap(%s)", (owner,)
        )[0]
        project = self._as(
            owner,
            "select public.save_project(null,1,%s::jsonb)",
            (json.dumps({"name": "Execution project", "budget": 1000}),),
        )[0]
        return enterprise_id, owner, employee, recipient, reviewer, project["id"]

    def _task(self, owner, employee, project_id, title, plan_date=None):
        plan_date = plan_date or date.today()
        return self._as(
            owner,
            "insert into public.tasks("
            "boss_id,employee_id,title,detail,plan_date,project_id"
            ") values(%s,%s,%s,'',%s,%s) returning id",
            (owner, employee, title, plan_date, project_id),
        )[0]

    def test_acceptance_is_independent_audited_and_final(self):
        _, owner, employee, _, reviewer, project_id = self._fixture()
        task_id = self._task(owner, employee, project_id, "Deliver API")
        submitted = self._as(
            employee,
            "select public.submit_task_acceptance("
            "%s,'Tests and docs pass','commit abc123',%s,'submitted')",
            (task_id, reviewer),
        )[0]
        self.assertEqual("pending", submitted["status"])
        accepted = self._as(
            reviewer,
            "select public.review_task_acceptance(%s,'accepted','verified')",
            (task_id,),
        )[0]
        self.assertTrue(accepted["final_complete"])
        accepted_again = self._as(
            reviewer,
            "select public.review_task_acceptance(%s,'accepted','verified')",
            (task_id,),
        )[0]
        self.assertTrue(accepted_again["duplicate"])
        audit_count = self._as(
            None,
            "select count(*) from public.execution_audit where entity_id=%s",
            (str(task_id),),
        )[0]
        self.assertGreaterEqual(audit_count, 2)

    def test_dependencies_reject_cycles_and_report_downstream(self):
        enterprise_id, owner, employee, _, _, project_id = self._fixture()
        task_a = self._task(owner, employee, project_id, "A")
        task_b = self._task(owner, employee, project_id, "B")
        task_c = self._task(
            owner, employee, project_id, "C", date.today() - timedelta(days=5)
        )
        self._as(
            owner,
            "select public.upsert_task_dependency(%s,%s,2,true)",
            (task_a, task_b),
        )
        self._as(
            owner,
            "select public.upsert_task_dependency(%s,%s,1,true)",
            (task_b, task_c),
        )
        cycle = self._as(
            owner,
            "select public.upsert_task_dependency(%s,%s,0,true)",
            (task_c, task_a),
        )[0]
        self.assertFalse(cycle["ok"])
        self.assertEqual("dependency_cycle", cycle["code"])
        board = self._as(
            owner, "select public.get_execution_board(%s)", (enterprise_id,)
        )[0]
        dependency = next(
            row for row in board["dependencies"]
            if row["task_id"] == task_b
            and row["depends_on_task_id"] == task_c
        )
        self.assertTrue(dependency["blocked"])
        affected = {
            row["task_id"] for row in dependency["affected_tasks"]
        }
        self.assertEqual({task_a, task_b}, affected)

    def test_handoff_requires_recipient_acceptance(self):
        enterprise_id, owner, employee, recipient, _, project_id = self._fixture()
        task_id = self._task(owner, employee, project_id, "Handoff task")
        handoff = self._as(
            owner,
            "select public.create_task_handoff(%s,%s,'build bundle','review')",
            (task_id, recipient),
        )[0]
        self.assertEqual("pending", handoff["status"])
        denied = self._as(
            employee,
            "select public.accept_task_handoff(%s,'accepted','not mine')",
            (handoff["handoff_id"],),
        )[0]
        self.assertEqual("permission_denied", denied["code"])
        accepted = self._as(
            recipient,
            "select public.accept_task_handoff(%s,'accepted','received')",
            (handoff["handoff_id"],),
        )[0]
        self.assertEqual("accepted", accepted["status"])
        audit_count = self._as(
            None,
            "select count(*) from public.execution_audit "
            "where enterprise_id=%s and entity_type='task_handoff'",
            (enterprise_id,),
        )[0]
        self.assertGreaterEqual(audit_count, 2)

    def test_change_approval_never_mutates_plan(self):
        enterprise_id, owner, employee, _, _, project_id = self._fixture()
        before = self._as(
            None,
            "select budget,due_date,status from public.projects where id=%s",
            (project_id,),
        )[0]
        created = self._as(
            owner,
            "select public.create_change_request(%s,%s::jsonb)",
            (
                project_id,
                json.dumps({
                    "title": "Expand scope",
                    "scope": "Add a second delivery team",
                    "reason": "Client request",
                    "urgency": "urgent",
                    "schedule_impact_days": 5,
                    "cost_impact": 60000,
                    "resource_impact": "Two engineers and a designer",
                    "risk": "risk",
                    "cross_department": True,
                }),
            ),
        )[0]
        self.assertTrue(created["high_impact"])
        self.assertIsNotNone(created["decision_item_id"])
        self.assertFalse(created["plan_mutated"])
        denied = self._as(
            employee,
            "select public.decide_change_request(%s,'approved','ok','test-key')",
            (created["change_id"],),
        )[0]
        self.assertEqual("permission_denied", denied["code"])
        approved = self._as(
            owner,
            "select public.decide_change_request(%s,'approved','authorized','test-key')",
            (created["change_id"],),
        )[0]
        self.assertEqual("approved", approved["status"])
        self.assertFalse(approved["plan_mutated"])
        after = self._as(
            None,
            "select budget,due_date,status from public.projects where id=%s",
            (project_id,),
        )[0]
        self.assertEqual(before, after)
        decision_status = self._as(
            None,
            "select status from public.decision_items where id=%s",
            (created["decision_item_id"],),
        )[0]
        self.assertEqual("resolved", decision_status)

    def test_direct_execution_table_writes_are_denied(self):
        _, owner, employee, _, _, project_id = self._fixture()
        task_id = self._task(owner, employee, project_id, "Protected task")
        with self.conn.cursor() as cur:
            claims = json.dumps({"sub": str(employee), "role": "authenticated"})
            cur.execute(
                "select set_config('request.jwt.claim.sub',%s,true),"
                " set_config('request.jwt.claims',%s,true)",
                (str(employee), claims),
            )
            cur.execute("set local role authenticated")
            cur.execute("savepoint direct_write")
            with self.assertRaises(psycopg2.Error):
                cur.execute(
                    "insert into public.task_acceptance("
                    "task_id,enterprise_id,criteria,evidence,submitter_id,reviewer_id"
                    ") values(%s,(select public._execution_task_enterprise(%s)),"
                    "'x','y',%s,%s)",
                    (task_id, task_id, employee, owner),
                )
            cur.execute("rollback to savepoint direct_write")


if __name__ == "__main__":
    unittest.main()
