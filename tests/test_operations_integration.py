import json
import os
import unittest
import uuid

try:
    import psycopg2
except ImportError:  # pragma: no cover - optional dependency
    psycopg2 = None

TEST_DATABASE_URL = os.environ.get("PROJECT_RECORDER_TEST_DATABASE_URL", "")
SKIP_REASON = (
    "PROJECT_RECORDER_TEST_DATABASE_URL is not set or psycopg2 is unavailable"
)


@unittest.skipUnless(TEST_DATABASE_URL and psycopg2, SKIP_REASON)
class OperationsIntegrationTest(unittest.TestCase):
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
            claims = json.dumps({"sub": str(user_id), "role": "authenticated"})
            cur.execute(
                "select set_config('request.jwt.claim.sub',%s,true),"
                " set_config('request.jwt.claims',%s,true)",
                (str(user_id), claims),
            )
            cur.execute("savepoint expected_operations_denial")
            with self.assertRaises(psycopg2.Error) as caught:
                cur.execute(sql, params)
            cur.execute("rollback to savepoint expected_operations_denial")
        if expected:
            self.assertIn(expected, str(caught.exception))

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
        project = self._as(
            owner_id,
            "select public.save_project(null,1,%s::jsonb)",
            (json.dumps({"name": "Ops project", "budget": 100000}),),
        )[0]
        return enterprise_id, owner_id, employee_id, project["id"]

    def test_economics_dashboard_is_permissioned_and_audited(self):
        enterprise_id, owner_id, employee_id, project_id = self._fixture()
        result = self._as(
            owner_id,
            "select public.upsert_project_economics(%s,%s::jsonb)",
            (
                project_id,
                json.dumps({
                    "contract_amount": 100000,
                    "invoiced_amount": 60000,
                    "collected_amount": 45000,
                    "outsourced_committed": 10000,
                    "labor_cost": 35000,
                    "estimated_completion_cost": 65000,
                }),
            ),
        )[0]
        self.assertEqual(float(result["projected_margin"]), 35000.0)
        dashboard = self._as(
            owner_id, "select public.get_operations_dashboard(4)"
        )[0]
        self.assertEqual(dashboard["window_weeks"], 4)
        project = next(p for p in dashboard["projects"] if p["project_id"] == project_id)
        self.assertEqual(float(project["collection_gap"]), 55000.0)
        self.assertEqual(float(project["projected_margin_percent"]), 35.0)
        audit_count = self._as(
            None,
            "select count(*) from public.enterprise_identity_audit "
            "where enterprise_id=%s and action='operations.economics.updated'",
            (enterprise_id,),
        )[0]
        self.assertEqual(1, audit_count)
        self._expect_error(
            employee_id,
            "select public.get_operations_dashboard(4)",
            expected="management permission required",
        )
        self._expect_error(
            employee_id,
            "select public.upsert_project_economics(%s,'{}'::jsonb)",
            (project_id,),
            expected="permission required",
        )

    def test_worklog_dimensions_skills_capacity_and_performance_round_trip(self):
        _, owner_id, employee_id, _ = self._fixture()
        worklog_id = self._as(
            employee_id,
            "insert into public.worklogs("
            "boss_id,employee_id,work_date,hours,content,source"
            ") values((select boss_id from public.profiles where id=%s),"
            "%s,current_date,3,'ops','manual') returning id",
            (employee_id, employee_id),
        )[0]
        dimension = self._as(
            employee_id,
            "select public.upsert_worklog_dimensions(%s,%s::jsonb)",
            (
                worklog_id,
                json.dumps({
                    "billable": False,
                    "overtime": True,
                    "work_kind": "presales",
                    "rework": True,
                    "waiting": False,
                    "travel": True,
                }),
            ),
        )[0]
        self.assertTrue(dimension["overtime"])
        self.assertEqual("presales", dimension["work_kind"])

        self._as(
            owner_id,
            "select public.upsert_profile_skill(%s,'python',%s::jsonb)",
            (
                employee_id,
                json.dumps({
                    "level": 4,
                    "certified": True,
                    "certification": "PyCert",
                    "available_hours": 40,
                    "valid_until": "2030-12-31",
                }),
            ),
        )
        self._as(
            owner_id,
            "select public.upsert_capacity_demand(null,%s::jsonb)",
            (json.dumps({
                "skill": "python",
                "required_hours": 80,
                "needed_from": "2026-01-01",
                "needed_until": "2026-01-28",
            }),),
        )
        dashboard = self._as(
            owner_id, "select public.get_operations_dashboard(4)"
        )[0]
        gap = next(g for g in dashboard["capacity_gaps"] if g["skill"] == "python")
        self.assertGreater(float(gap["gap_hours"]), 0)
        self.assertTrue(dashboard["worklog_summary"]["overtime_hours"] >= 3)

        evidence = self._as(
            owner_id,
            "select public.upsert_performance_evidence(%s,'2026-11',%s::jsonb)",
            (
                employee_id,
                json.dumps({
                    "on_time_rate": 0.9,
                    "first_pass_rate": 0.8,
                    "rework_rate": 0.1,
                    "collaboration_score": 4.5,
                    "complexity_score": 3,
                    "business_contribution": 4,
                    "evidence": [{"type": "task", "id": "t1"}],
                }),
            ),
        )[0]
        own = self._as(
            employee_id, "select public.get_my_performance_evidence()"
        )[0]
        self.assertEqual(1, len(own["items"]))
        self.assertEqual("t1", own["items"][0]["evidence"][0]["id"])
        self._as(
            employee_id,
            "select public.submit_performance_statement(%s,%s)",
            (evidence["id"], "Delivered the migration in two weeks."),
        )
        reviewed = self._as(
            owner_id,
            "select public.review_performance_evidence(%s,%s)",
            (evidence["id"], "Evidence checked."),
        )[0]
        self.assertEqual("reviewed", reviewed["status"])
        self.assertGreater(float(reviewed["score"]), 70)
        self.assertNotIn("wage", reviewed)
        self.assertNotIn("promotion", reviewed)
        self.assertFalse(
            self._as(
                None,
                "select has_table_privilege("
                "'authenticated','public.project_economics','SELECT')",
            )[0]
        )


if __name__ == "__main__":
    unittest.main()

