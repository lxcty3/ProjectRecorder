import json
import os
import unittest
import uuid
from datetime import date, timedelta

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

    def _denied(self, user_id, sql, params=(), operation=""):
        result = self._as(user_id, sql, params)[0]
        self.assertFalse(result.get("ok", True), result)
        self.assertEqual("permission_denied", result.get("code"))
        if operation:
            self.assertIn(operation, result.get("error", ""))
        return result

    def _project(self, owner_id, name):
        return self._as(
            owner_id,
            "select public.save_project(null,1,%s::jsonb)",
            (json.dumps({"name": name, "budget": 100000}),),
        )[0]["id"]

    def _scoped_manager(self, enterprise_id, owner_id, allowed_project,
                        permission_key="projects.manage", conditions=None):
        manager_id = uuid.uuid4()
        code = "manager-" + manager_id.hex
        template_id = uuid.uuid4()
        version_id = uuid.uuid4()
        with self.conn.cursor() as cur:
            cur.execute(
                "insert into auth.users(id,email) values(%s,%s)",
                (manager_id, code + "@example.test"),
            )
            cur.execute(
                "insert into public.profiles(id,code,name,role,boss_id) "
                "values(%s,%s,'Scoped Manager','employee',%s)",
                (manager_id, code, owner_id),
            )
            cur.execute(
                "insert into public.enterprise_members("
                "enterprise_id,profile_id,role_key,department,status"
                ") values(%s,%s,'project_manager','Delivery','active')",
                (enterprise_id, manager_id),
            )
            cur.execute(
                "insert into public.enterprise_role_templates("
                "id,enterprise_id,key,name,is_system"
                ") values(%s,%s,%s,'Scoped Project Manager',false)",
                (template_id, enterprise_id, code),
            )
            cur.execute(
                "insert into public.enterprise_role_template_versions("
                "id,template_id,version,status,created_by"
                ") values(%s,%s,1,'active',%s)",
                (version_id, template_id, owner_id),
            )
            if conditions is None:
                conditions = {"project_ids": [str(allowed_project)]}
            cur.execute(
                "insert into public.enterprise_role_template_permissions("
                "template_version_id,permission_key,resource,action,scope,"
                "conditions,high_risk"
                ") values(%s,%s,'projects','manage','project',"
                "%s::jsonb,false)",
                (version_id, permission_key, json.dumps(conditions)),
            )
            cur.execute(
                "insert into public.enterprise_role_assignments("
                "enterprise_id,profile_id,template_version_id,is_primary,"
                "status,appointed_by"
                ") values(%s,%s,%s,true,'active',%s)",
                (enterprise_id, manager_id, version_id, owner_id),
            )
        return manager_id

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
        self._denied(
            employee_id,
            "select public.get_operations_dashboard(4)",
            operation="dashboard",
        )
        self._denied(
            employee_id,
            "select public.upsert_project_economics(%s,'{}'::jsonb)",
            (project_id,),
            operation="upsert_project_economics",
        )

    def test_worklog_dimensions_skills_capacity_and_performance_round_trip(self):
        _, owner_id, employee_id, project_id = self._fixture()
        today = date.today()
        period = today.strftime("%Y-%m")
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
                "needed_from": today.isoformat(),
                "needed_until": (today + timedelta(days=27)).isoformat(),
            }),),
        )
        dashboard = self._as(
            owner_id, "select public.get_operations_dashboard(4)"
        )[0]
        gap = next(g for g in dashboard["capacity_gaps"] if g["skill"] == "python")
        self.assertGreater(float(gap["gap_hours"]), 0)
        self.assertTrue(dashboard["worklog_summary"]["overtime_hours"] >= 3)

        task_id = self._as(
            None,
            "insert into public.tasks("
            "boss_id,employee_id,project_id,title,plan_date,est_hours"
            ") values(%s,%s,%s,'Delivered worklog migration',current_date,4)"
            " returning id",
            (owner_id, employee_id, project_id),
        )[0]
        evidence = self._as(
            owner_id,
            "select public.upsert_performance_evidence(%s,%s,%s::jsonb)",
            (
                employee_id,
                period,
                json.dumps({
                    "on_time_rate": 0.9,
                    "first_pass_rate": 0.8,
                    "rework_rate": 0.1,
                    "collaboration_score": 4.5,
                    "complexity_score": 4,
                    "business_contribution": 4,
                    "customer_evaluation": {
                        "score": 4.8,
                        "comment": "Clear and reliable delivery.",
                        "evaluator": "Customer A",
                    },
                    "evidence": [
                        {"type": "task", "id": str(task_id)},
                        {"type": "worklog", "id": str(worklog_id)},
                    ],
                }),
            ),
        )[0]
        own = self._as(
            employee_id, "select public.get_my_performance_evidence()"
        )[0]
        self.assertEqual(1, len(own["items"]))
        self.assertEqual(str(task_id), own["items"][0]["evidence"][0]["id"])
        self.assertEqual(4.8, float(
            own["items"][0]["customer_evaluation"]["score"]
        ))
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

    def test_scoped_manager_can_only_use_assigned_project_and_is_audited(self):
        enterprise_id, owner_id, _, project_a = self._fixture()
        project_b = self._project(owner_id, "Other project")
        manager_id = self._scoped_manager(
            enterprise_id, owner_id, project_a
        )
        allowed = self._as(
            manager_id,
            "select public.upsert_project_economics(%s,%s::jsonb)",
            (project_a, json.dumps({"contract_amount": 1000})),
        )[0]
        self.assertNotIn("ok", allowed)
        denied = self._denied(
            manager_id,
            "select public.upsert_project_economics(%s,%s::jsonb)",
            (project_b, json.dumps({"contract_amount": 1000})),
            operation="upsert_project_economics",
        )
        self.assertEqual("permission_denied", denied["code"])
        dashboard = self._as(
            manager_id, "select public.get_operations_dashboard(4)"
        )[0]
        self.assertEqual([project_a], [p["project_id"] for p in dashboard["projects"]])
        self.assertNotIn("contract_amount", dashboard["projects"][0])
        self.assertFalse(dashboard["access"]["can_finance"])
        performance_denied = self._denied(
            manager_id,
            "select public.upsert_performance_evidence(%s,%s,%s::jsonb)",
            (employee_id, date.today().strftime("%Y-%m"),
             json.dumps({"on_time_rate": 1})),
            operation="upsert_performance_evidence",
        )
        self.assertEqual("permission_denied", performance_denied["code"])
        audit_count = self._as(
            None,
            "select count(*) from public.operations_security_audit "
            "where enterprise_id=%s and actor_profile_id=%s "
            "and operation='upsert_project_economics'",
            (enterprise_id, manager_id),
        )[0]
        self.assertEqual(1, audit_count)

    def test_every_economics_money_field_is_amount_scoped(self):
        enterprise_id, owner_id, _, project_id = self._fixture()
        manager_id = self._scoped_manager(
            enterprise_id,
            owner_id,
            project_id,
            conditions={
                "project_ids": [str(project_id)],
                "amount_limit": 1000,
            },
        )
        for field in (
            "invoiced_amount",
            "collected_amount",
            "outsourced_committed",
            "outsourced_paid",
            "labor_cost",
            "estimated_completion_cost",
            "other_cost",
        ):
            denied = self._denied(
                manager_id,
                "select public.upsert_project_economics(%s,%s::jsonb)",
                (project_id, json.dumps({
                    "contract_amount": 0,
                    field: 5000,
                })),
                operation="upsert_project_economics",
            )
            self.assertIn("monetary field", denied["error"])
        audit_count = self._as(
            None,
            "select count(*) from public.operations_security_audit "
            "where enterprise_id=%s and actor_profile_id=%s "
            "and operation='upsert_project_economics'",
            (enterprise_id, manager_id),
        )[0]
        self.assertEqual(7, audit_count)

    def test_project_only_capacity_never_reports_false_shortage(self):
        enterprise_id, owner_id, employee_id, project_id = self._fixture()
        today = date.today()
        self._as(
            owner_id,
            "select public.upsert_profile_skill(%s,'python',%s::jsonb)",
            (employee_id, json.dumps({"available_hours": 40})),
        )
        self._as(
            owner_id,
            "select public.upsert_capacity_demand(null,%s::jsonb)",
            (json.dumps({
                "skill": "python",
                "required_hours": 80,
                "needed_from": today.isoformat(),
                "needed_until": (today + timedelta(days=27)).isoformat(),
                "project_id": project_id,
            }),),
        )
        manager_id = self._scoped_manager(
            enterprise_id, owner_id, project_id
        )
        dashboard = self._as(
            manager_id, "select public.get_operations_dashboard(4)"
        )[0]
        self.assertFalse(dashboard["access"]["can_capacity"])
        self.assertTrue(
            dashboard["access"]["capacity_requires_people_scope"]
        )
        self.assertIn(
            "people", dashboard["access"]["capacity_permission_message"]
        )
        self.assertEqual([], dashboard["capacity_gaps"])
        self.assertEqual([], dashboard["capacity_demands"])

    def test_profile_skill_self_edit_requires_explicit_people_scope(self):
        enterprise_id, _, employee_id, _ = self._fixture()
        denied = self._denied(
            employee_id,
            "select public.upsert_profile_skill(%s,'python',%s::jsonb)",
            (employee_id, json.dumps({"level": 3})),
            operation="upsert_profile_skill",
        )
        self.assertEqual("permission_denied", denied["code"])
        audit_count = self._as(
            None,
            "select count(*) from public.operations_security_audit "
            "where enterprise_id=%s and actor_profile_id=%s "
            "and operation='upsert_profile_skill'",
            (enterprise_id, employee_id),
        )[0]
        self.assertEqual(1, audit_count)

    def test_cross_enterprise_project_denial_is_audited(self):
        enterprise_id, owner_id, _, _ = self._fixture()
        other_owner = uuid.uuid4()
        with self.conn.cursor() as cur:
            cur.execute(
                "insert into auth.users(id,email) values(%s,%s)",
                (other_owner, "foreign-" + other_owner.hex + "@example.test"),
            )
            cur.execute(
                "insert into public.profiles(id,code,name,role,boss_id) "
                "values(%s,%s,'Foreign Owner','boss',%s)",
                (other_owner, "foreign-" + other_owner.hex, other_owner),
            )
        self._as(
            other_owner,
            "select public._identity_bootstrap(%s)",
            (other_owner,),
        )
        foreign_project = self._project(other_owner, "Foreign project")
        denied = self._denied(
            owner_id,
            "select public.upsert_project_economics(%s,%s::jsonb)",
            (foreign_project, json.dumps({"contract_amount": 1000})),
            operation="upsert_project_economics",
        )
        self.assertIn("cross-enterprise", denied["error"])
        audit_count = self._as(
            None,
            "select count(*) from public.operations_security_audit "
            "where enterprise_id=%s and actor_profile_id=%s "
            "and target_id=%s and operation='upsert_project_economics'",
            (enterprise_id, owner_id, str(foreign_project)),
        )[0]
        self.assertEqual(1, audit_count)

    def test_rejected_worklogs_are_excluded_from_summary(self):
        _, owner_id, employee_id, _ = self._fixture()
        with self.conn.cursor() as cur:
            for status, hours in (("approved", 3), ("rejected", 8), ("pending", 5)):
                cur.execute(
                    "insert into public.worklogs("
                    "boss_id,employee_id,work_date,hours,content,source,"
                    "approval_status"
                    ") values(%s,%s,current_date,%s,%s,'manual',%s)",
                    (owner_id, employee_id, hours, status, status),
                )
        dashboard = self._as(
            owner_id, "select public.get_operations_dashboard(4)"
        )[0]
        self.assertEqual(3, float(dashboard["worklog_summary"]["total_hours"]))

    def test_partial_capacity_update_preserves_unchanged_fields(self):
        _, owner_id, _, project_id = self._fixture()
        today = date.today()
        expected_until = (today + timedelta(days=27)).isoformat()
        demand = self._as(
            owner_id,
            "select public.upsert_capacity_demand(null,%s::jsonb)",
            (json.dumps({
                "skill": "python",
                "required_hours": 80,
                "needed_from": today.isoformat(),
                "needed_until": expected_until,
                "project_id": project_id,
                "note": "initial",
            }),),
        )[0]
        updated = self._as(
            owner_id,
            "select public.upsert_capacity_demand(%s,%s::jsonb)",
            (demand["id"], json.dumps({"note": "updated"})),
        )[0]
        self.assertEqual("python", updated["skill"])
        self.assertEqual(80, float(updated["required_hours"]))
        self.assertEqual(expected_until, str(updated["needed_until"]))
        self.assertEqual("updated", updated["note"])

    def test_performance_rejects_foreign_sources_and_records_customer_evaluation(self):
        enterprise_id, owner_id, employee_id, project_id = self._fixture()
        other_id = uuid.uuid4()
        with self.conn.cursor() as cur:
            cur.execute(
                "insert into auth.users(id,email) values(%s,%s)",
                (other_id, "other-" + other_id.hex + "@example.test"),
            )
            cur.execute(
                "insert into public.profiles(id,code,name,role,boss_id) "
                "values(%s,%s,'Other','employee',%s)",
                (other_id, "other-" + other_id.hex, owner_id),
            )
        foreign_task = self._as(
            None,
            "insert into public.tasks("
            "boss_id,employee_id,project_id,title,plan_date,est_hours"
            ") values(%s,%s,%s,'Foreign task',current_date,2) returning id",
            (owner_id, other_id, project_id),
        )[0]
        self._expect_error(
            owner_id,
            "select public.upsert_performance_evidence(%s,%s,%s::jsonb)",
            (
                employee_id,
                date.today().strftime("%Y-%m"),
                json.dumps({
                    "on_time_rate": 1,
                    "first_pass_rate": 1,
                    "rework_rate": 0,
                    "collaboration_score": 5,
                    "complexity_score": 5,
                    "business_contribution": 5,
                    "evidence": [{"type": "task", "id": str(foreign_task)}],
                }),
            ),
            expected="evidence task",
        )
        self.assertGreater(enterprise_id.int, 0)

    def test_overdue_invoice_creates_collection_alert_and_decision_item(self):
        enterprise_id, owner_id, employee_id, project_id = self._fixture()
        result = self._as(
            owner_id,
            "select public.upsert_project_economics(%s,%s::jsonb)",
            (project_id, json.dumps({
                "contract_amount": 100000,
                "invoiced_amount": 60000,
                "collected_amount": 20000,
                "invoice_due_date": (date.today() - timedelta(days=10)).isoformat(),
                "payment_terms": "Net 30",
            })),
        )[0]
        self.assertEqual("Net 30", result["payment_terms"])
        dashboard = self._as(
            owner_id, "select public.get_operations_dashboard(4)"
        )[0]
        alert = next(
            item for item in dashboard["collection_alerts"]
            if item["project_id"] == project_id
        )
        self.assertGreater(float(alert["overdue_amount"]), 0)
        queue_item = self._as(
            None,
            "select id,status,source_type from public.decision_items "
            "where enterprise_id=%s and source_type='finance' and source_id=%s",
            (enterprise_id, project_id),
        )
        self.assertIsNotNone(queue_item)
        self.assertEqual("finance", queue_item[2])


if __name__ == "__main__":
    unittest.main()

