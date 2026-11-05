import json
import os
import unittest
import uuid
from datetime import date, timedelta

try:
    import psycopg2
    from psycopg2.extras import register_uuid

    register_uuid()
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

    def _expect_error(self, user_id, sql, params=(), expected=""):
        with self.conn.cursor() as cur:
            cur.execute("savepoint expected_error")
        try:
            with self.assertRaises(psycopg2.Error) as raised:
                self._as(user_id, sql, params)
            if expected:
                self.assertIn(expected.lower(), str(raised.exception).lower())
        finally:
            with self.conn.cursor() as cur:
                cur.execute("rollback to savepoint expected_error")

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
                domain = "boss.pr" if role == "boss" else "staff.pr"
                cur.execute(
                    "insert into auth.users(id,email) values(%s,%s)",
                    (user_id, code + "@" + domain),
                )
                cur.execute(
                    "update public.profiles set name=%s,role=%s,boss_id=%s "
                    "where id=%s",
                    (name, role, boss_id, user_id),
                )
        enterprise_id = self._as(
            owner, "select public._identity_bootstrap(%s)", (owner,)
        )[0]
        self._as(
            owner,
            "update public.enterprise_members set role_key='project_manager' "
            "where enterprise_id=%s and profile_id=%s",
            (enterprise_id, reviewer),
        )
        project = self._as(
            owner,
            "select public.save_project(null,1,%s::jsonb)",
            (json.dumps({"name": "Execution project", "budget": 1000}),),
        )[0]
        return enterprise_id, owner, employee, recipient, reviewer, project["id"]

    def _task(
        self, owner, employee, project_id, title, plan_date=None,
        accept_status="accepted",
    ):
        plan_date = plan_date or date.today()
        return self._as(
            owner,
            "insert into public.tasks("
            "boss_id,employee_id,title,detail,plan_date,project_id,accept_status,est_hours"
            ") values(%s,%s,%s,'',%s,%s,%s,1) returning id",
            (owner, employee, title, plan_date, project_id, accept_status),
        )[0]

    def _complete(self, employee, task_id):
        return self._as(
            employee,
            "insert into public.task_logs("
            "id,task_id,employee_id,finished_at,finish_date"
            ") values(%s,%s,%s,now(),current_date) returning id",
            (uuid.uuid4(), task_id, employee),
        )[0]

    def _submitted_acceptance(self, owner, employee, reviewer, project_id):
        task_id = self._task(owner, employee, project_id, "Deliver API")
        self._complete(employee, task_id)
        submitted = self._as(
            employee,
            "select public.submit_task_acceptance("
            "%s,'Tests and docs pass','commit abc123',%s,'submitted')",
            (task_id, reviewer),
        )[0]
        return task_id, submitted

    def test_board_loads_every_section_with_limits_and_orders(self):
        enterprise_id, owner, employee, recipient, reviewer, project_id = (
            self._fixture()
        )
        task_id, _ = self._submitted_acceptance(
            owner, employee, reviewer, project_id
        )
        upstream = self._task(
            owner, employee, project_id, "Upstream",
            date.today() - timedelta(days=4),
        )
        self._as(
            owner,
            "select public.upsert_task_dependency(%s,%s,1,true)",
            (task_id, upstream),
        )
        self._as(
            owner,
            "select public.create_task_handoff(%s,%s,'bundle','review')",
            (task_id, recipient),
        )
        self._as(
            owner,
            "select public.create_change_request(%s,%s::jsonb)",
            (
                project_id,
                json.dumps({
                    "title": "Expand scope",
                    "scope": "Add one team",
                    "reason": "Client request",
                    "urgency": "urgent",
                    "schedule_impact_days": 5,
                    "cost_impact": 60000,
                    "resource_impact": "One engineer",
                    "risk": "risk",
                    "cross_department": True,
                }),
            ),
        )
        board = self._as(
            owner, "select public.get_execution_board(%s)", (enterprise_id,)
        )[0]
        self.assertTrue(board["ok"])
        for key in (
            "acceptance", "dependencies", "handoffs", "changes",
            "tasks", "projects", "members",
        ):
            self.assertIsInstance(board[key], list)
            self.assertGreaterEqual(len(board[key]), 1)

    def test_acceptance_is_independent_audited_and_final(self):
        _, owner, employee, _, reviewer, project_id = self._fixture()
        task_id, submitted = self._submitted_acceptance(
            owner, employee, reviewer, project_id
        )
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

    def test_grade_and_merit_require_accepted_acceptance(self):
        _, owner, employee, _, reviewer, project_id = self._fixture()
        task_id, _ = self._submitted_acceptance(
            owner, employee, reviewer, project_id
        )
        self._expect_error(
            owner,
            "select public.grade_task(%s,'A')",
            (task_id,),
            "task acceptance required before grading",
        )
        self._as(
            reviewer,
            "select public.review_task_acceptance(%s,'accepted','verified')",
            (task_id,),
        )
        graded = self._as(
            owner, "select public.grade_task(%s,'A')", (task_id,)
        )[0]
        self.assertTrue(graded["ok"])
        merit_count = self._as(
            None,
            "select count(*) from public.merit_ledger where source_id=%s",
            (task_id,),
        )[0]
        self.assertEqual(1, merit_count)

    def test_rework_removes_completion_logs_and_reopens_task(self):
        _, owner, employee, _, reviewer, project_id = self._fixture()
        task_id, _ = self._submitted_acceptance(
            owner, employee, reviewer, project_id
        )
        reworked = self._as(
            reviewer,
            "select public.review_task_acceptance(%s,'rework','missing tests')",
            (task_id,),
        )[0]
        self.assertEqual("rework", reworked["status"])
        self.assertTrue(reworked["reopened"])
        self.assertGreaterEqual(reworked["completion_logs_removed"], 1)
        remaining = self._as(
            None,
            "select count(*) from public.task_logs where task_id=%s",
            (task_id,),
        )[0]
        self.assertEqual(0, remaining)

    def test_completion_cannot_bypass_assignment_acceptance(self):
        _, owner, employee, _, _, project_id = self._fixture()
        task_id = self._task(
            owner, employee, project_id, "Not accepted", accept_status="pending"
        )
        self._expect_error(
            employee,
            "insert into public.task_logs("
            "task_id,employee_id,finished_at,finish_date"
            ") values(%s,%s,now(),current_date)",
            (task_id, employee),
            "assignment must be accepted before completion",
        )

    def test_dependencies_reject_cycles_honor_optional_and_remove(self):
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
        self._as(
            owner,
            "select public.upsert_task_dependency(%s,%s,0,false)",
            (task_a, task_c),
        )
        board = self._as(
            owner, "select public.get_execution_board(%s)", (enterprise_id,)
        )[0]
        optional = next(
            row for row in board["dependencies"]
            if str(row["task_id"]) == str(task_a) and str(row["depends_on_task_id"]) == str(task_c)
        )
        self.assertFalse(optional["required"])
        self.assertFalse(optional["blocked"])
        removed = self._as(
            owner,
            "select public.delete_task_dependency(%s,%s)",
            (task_a, task_c),
        )[0]
        self.assertTrue(removed["ok"])

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

    def test_change_normalization_and_bidirectional_decision_sync(self):
        enterprise_id, owner, _, _, _, project_id = self._fixture()
        created = self._as(
            owner,
            "select public.create_change_request(%s,%s::jsonb)",
            (
                project_id,
                json.dumps({
                    "title": "Expand scope",
                    "scope": "Add a second delivery team",
                    "reason": "Client request",
                    "urgency": "紧急",
                    "schedule_impact_days": 1,
                    "cost_impact": 100,
                    "resource_impact": "One engineer",
                    "risk": "严重",
                    "cross_department": False,
                }),
            ),
        )[0]
        self.assertTrue(created["high_impact"])
        stored = self._as(
            None,
            "select urgency,risk from public.change_requests where id=%s",
            (created["change_id"],),
        )
        self.assertEqual(("urgent", "severe"), stored)
        self._as(
            owner,
            "select public.act_on_decision(%s,'resolved',null,'authorized','decision-sync')",
            (created["decision_item_id"],),
        )
        synced = self._as(
            None,
            "select status from public.change_requests where id=%s",
            (created["change_id"],),
        )[0]
        self.assertEqual("approved", synced)

    def test_change_approval_never_mutates_plan(self):
        _, owner, employee, _, _, project_id = self._fixture()
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

    def test_auditor_and_supervisor_are_read_only(self):
        enterprise_id, owner, employee, recipient, reviewer, project_id = (
            self._fixture()
        )
        task_id, _ = self._submitted_acceptance(
            owner, employee, reviewer, project_id
        )
        for role_key, viewer in (("auditor", employee), ("supervisor", recipient)):
            self._as(
                owner,
                "update public.enterprise_members set role_key=%s "
                "where enterprise_id=%s and profile_id=%s",
                (role_key, enterprise_id, viewer),
            )
            board = self._as(
                viewer,
                "select public.get_execution_board(%s)",
                (enterprise_id,),
            )[0]
            self.assertTrue(board["access"]["read_only"])
            self.assertFalse(board["access"]["can_review_acceptance"])
            self.assertFalse(board["access"]["can_manage_dependencies"])
            self.assertFalse(board["access"]["can_create_handoff"])
            self.assertFalse(board["access"]["can_manage_changes"])
            acceptance = next(
                row for row in board["acceptance"] if str(row["task_id"]) == str(task_id)
            )
            self.assertFalse(acceptance["actions"]["accept"])
            self.assertFalse(acceptance["actions"]["rework"])

    def test_task_acceptance_feeds_operations_performance(self):
        _, owner, employee, _, reviewer, project_id = self._fixture()
        task_id, _ = self._submitted_acceptance(
            owner, employee, reviewer, project_id
        )
        self._as(
            reviewer,
            "select public.review_task_acceptance(%s,'accepted','verified')",
            (task_id,),
        )
        dashboard = self._as(
            owner, "select public.get_operations_dashboard(4)"
        )[0]
        derived = [
            row for row in dashboard["performance"]
            if row.get("source") == "task_acceptance"
        ]
        self.assertEqual(1, len(derived))
        self.assertEqual(1, derived[0]["accepted_count"])
        self.assertEqual(0, derived[0]["rework_count"])

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
