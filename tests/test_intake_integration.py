import json
import os
import unittest
import uuid

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
class IntakeIntegrationTest(unittest.TestCase):
    def setUp(self):
        self.conn = psycopg2.connect(TEST_DATABASE_URL)
        self.conn.autocommit = False

    def tearDown(self):
        self.conn.rollback()
        self.conn.close()

    def _as(self, user_id, sql, params=()):
        with self.conn.cursor() as cur:
            if user_id is not None:
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
        manager = uuid.uuid4()
        users = (
            (owner, "owner-", "Owner", "boss", None),
            (employee, "employee-", "Employee", "employee", owner),
            (manager, "manager-", "Manager", "employee", owner),
        )
        with self.conn.cursor() as cur:
            for user_id, prefix, name, role, boss_id in users:
                code = prefix + user_id.hex
                cur.execute(
                    "insert into auth.users(id,email) values(%s,%s)",
                    (user_id, code + "@example.test"),
                )
                cur.execute(
                    "update public.profiles set name=%s,role=%s,boss_id=%s where id=%s",
                    (name, role, boss_id, user_id),
                )
        enterprise_id = self._as(
            owner, "select public._identity_bootstrap(%s)", (owner,)
        )[0]
        self._as(
            owner,
            "update public.enterprise_members set role_key='project_manager' "
            "where enterprise_id=%s and profile_id=%s",
            (enterprise_id, manager),
        )
        form = self._as(
            owner,
            "select public.create_intake_form(%s::jsonb)",
            (json.dumps({"name": "Public intake"}),),
        )[0]
        return enterprise_id, owner, employee, manager, form["form"]

    def _quick(self, user_id, title="支付失败"):
        result = self._as(
            user_id,
            "select public.create_intake_request(%s::jsonb)",
            (json.dumps({
                "title": title,
                "detail": "客户完成支付后看到空白页面",
                "request_type": "incident",
                "business_value": 4,
                "urgency": 5,
                "risk": 3,
                "dependency_impact": 2,
                "effort": 1,
            }),),
        )[0]
        return result

    def _public(self, token, email="client@example.com", title="官网空白"):
        return self._as(
            None,
            "select public.submit_public_intake(%s,%s::jsonb)",
            (token, json.dumps({
                "title": title,
                "detail": "客户联系客服说页面无法打开",
                "request_type": "incident",
                "requester_name": "Client",
                "requester_email": email,
                "consent": True,
            })),
        )[0]

    def test_public_form_status_isolated_and_rate_limited(self):
        _, owner, _, _, form = self._fixture()
        submitted = self._public(form["public_token"])
        self.assertTrue(submitted["ok"])
        wrong = self._as(
            None,
            "select public.get_public_intake_status(%s,%s)",
            (submitted["tracking_code"], "wrong@example.com"),
        )[0]
        self.assertFalse(wrong["ok"])
        status = self._as(
            None,
            "select public.get_public_intake_status(%s,%s)",
            (submitted["tracking_code"], "client@example.com"),
        )[0]
        self.assertTrue(status["ok"])
        self.assertNotIn("owner_profile_id", status)
        self.assertNotIn("linked_project_id", status)
        self._as(
            owner,
            "select public.add_intake_message("
            "(select id from public.intake_requests where tracking_code=%s),"
            "'internal only',false)",
            (submitted["tracking_code"],),
        )
        status2 = self._as(
            None,
            "select public.get_public_intake_status(%s,%s)",
            (submitted["tracking_code"], "client@example.com"),
        )[0]
        self.assertNotIn("internal only", json.dumps(status2, ensure_ascii=False))

    def test_sla_priority_and_triage(self):
        enterprise_id, owner, employee, manager, _ = self._fixture()
        created = self._quick(employee)
        board = self._as(
            owner, "select public.get_intake_board(%s)", (enterprise_id,)
        )[0]
        row = next(item for item in board["requests"] if item["id"] == created["request_id"])
        self.assertEqual(row["request_type"], "incident")
        self.assertGreater(row["priority_score"], 0)
        self.assertEqual(len(row["priority_factors"]), 5)
        with self.assertRaises(psycopg2.Error):
            self._as(
                owner,
                "select public.triage_intake_request(%s,%s,'incident',95,'','triage')",
                (created["request_id"], manager),
            )
        triaged = self._as(
            owner,
            "select public.triage_intake_request(%s,%s,'incident',95,'CEO asked','in_progress')",
            (created["request_id"], manager),
        )[0]
        self.assertTrue(triaged["ok"])
        self.assertEqual(triaged["priority_score"], 95)

    def test_merge_preserves_source_messages(self):
        enterprise_id, owner, employee, _, _ = self._fixture()
        source = self._quick(employee, "支付报错")
        target = self._quick(employee, "付款失败")
        self._as(
            employee,
            "select public.add_intake_message(%s,'source public note',true)",
            (source["request_id"],),
        )
        merged = self._as(
            owner,
            "select public.merge_intake_request(%s,%s,'same issue')",
            (source["request_id"], target["request_id"]),
        )[0]
        self.assertTrue(merged["ok"])
        board = self._as(
            owner, "select public.get_intake_board(%s)", (enterprise_id,)
        )[0]
        source_row = next(row for row in board["requests"] if row["id"] == source["request_id"])
        target_row = next(row for row in board["requests"] if row["id"] == target["request_id"])
        self.assertEqual(source_row["status"], "merged")
        self.assertTrue(any(
            row["body"] == "source public note" for row in target_row["messages"]
        ))

    def test_conversion_to_project_task_and_presales(self):
        enterprise_id, owner, employee, manager, _ = self._fixture()
        project_request = self._quick(employee, "项目需求")
        project = self._as(
            owner,
            "select public.convert_intake_request(%s,'project',%s::jsonb)",
            (project_request["request_id"], json.dumps({"name": "Intake project"})),
        )[0]
        self.assertTrue(project["ok"])
        task_request = self._quick(employee, "任务需求")
        task = self._as(
            owner,
            "select public.convert_intake_request(%s,'task',%s::jsonb)",
            (task_request["request_id"], json.dumps({
                "title": "Fix payment", "project_id": project["project_id"],
                "employee_id": employee, "plan_date": "2026-11-10",
            })),
        )[0]
        self.assertTrue(task["ok"])
        presales_request = self._quick(employee, "售前需求")
        presales = self._as(
            owner,
            "select public.convert_intake_request(%s,'presales',%s::jsonb)",
            (presales_request["request_id"], json.dumps({
                "owner_id": manager, "estimated_value": 120000,
                "customer_name": "Client",
            })),
        )[0]
        self.assertTrue(presales["ok"])
        stored = self._as(
            None,
            "select converted_kind,linked_project_id,linked_task_id from public.intake_requests where id=%s",
            (presales_request["request_id"],),
        )[0]
        self.assertEqual(stored[0], "presales")
        history = self._as(
            None,
            "select count(*) from public.intake_conversions where request_id=%s",
            (presales_request["request_id"],),
        )[0]
        self.assertEqual(history, 1)


if __name__ == "__main__":
    unittest.main()
