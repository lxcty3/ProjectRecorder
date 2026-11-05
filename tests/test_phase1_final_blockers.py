import os
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PyQt6.QtWidgets import QApplication

from today_ui import TodayPage


ROOT = Path(__file__).resolve().parents[1]


def read(path):
    return (ROOT / path).read_text(encoding="utf-8")


class PhaseOneFinalBlockersTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.governance_sql = read("mobile/sql/enterprise-governance-v2.sql")
        cls.community_sql = read("mobile/sql/community.sql")
        cls.community_client = read("community_client.py")
        cls.mobile_community = read("mobile/community.js")

    def rpc_definition(self, name):
        lowered = self.governance_sql.lower()
        marker = f"create or replace function public.{name}("
        start = lowered.find(marker)
        self.assertGreaterEqual(start, 0, name)
        return lowered[start:].split("$fn$;", 1)[0]

    def test_paid_knowledge_direct_reads_are_policy_gated(self):
        compact_community = " ".join(self.community_sql.lower().split())
        self.assertNotIn("using (true)", compact_community)
        self.assertNotIn("using (true)", read("mobile/sql/install-unified.sql").lower())
        self.assertIn("_community_post_readable", compact_community)
        self.assertIn(
            "using (public._community_post_readable(id,auth.uid()))",
            compact_community,
        )
        helper = self.rpc_definition("_identity_can_read_community_post")
        for marker in (
            "p.is_required",
            "p.unlock_cost=0",
            "p.author_id=p_uid",
            "enterprise_knowledge_unlocks",
        ):
            self.assertIn(marker, helper)
        listing = self.rpc_definition("list_knowledge_posts")
        self.assertNotIn("_identity_bootstrap", listing)
        self.assertIn("select e.id into v_eid", listing)
        self.assertIn("'content',case", listing)
        self.assertIn("enterprise_knowledge_unlocks", listing)
        self.assertIn("'locked',", listing)
        self.assertIn("list_knowledge_posts", self.community_client)
        self.assertIn("list_knowledge_posts", self.mobile_community)

    def test_template_motions_preserve_operation_reason_and_conflict(self):
        clone = self.rpc_definition("clone_role_template")
        self.assertIn("p_source_template", clone)
        self.assertIn("p_reason", clone)
        self.assertIn("p_conflict_disclosed", clone)
        self.assertIn("'operation','clone'", clone)
        self.assertIn("'source_template_id',p_source_template", clone)
        self.assertNotIn("'source_template',p_source", clone)
        self.assertIn("v_reason", clone)

        apply_motion = self.rpc_definition("_identity_apply_template_change_motion")
        self.assertIn("v_m.payload->>'operation'", apply_motion)
        self.assertIn("v_m.payload->>'source_template_id'", apply_motion)
        self.assertIn("insert into public.enterprise_role_templates", apply_motion)

        update = self.rpc_definition("update_role_template")
        self.assertIn("p_reason", update)
        self.assertIn("p_conflict_disclosed", update)
        self.assertIn("v_reason", update)
        self.assertNotIn("'Update role template '||v_template.key", update)

        role_ui = read("role_templates_ui.py")
        self.assertIn("TemplateCloneDialog", role_ui)
        self.assertIn('data["reason"]', role_ui)
        self.assertIn('data["conflict_disclosed"]', role_ui)
        client = read("community_client.py")
        self.assertIn('"p_source_template": str(source_id)', client)
        self.assertIn('"p_reason": str(reason or "")', client)
        self.assertIn('"p_conflict_disclosed": bool(conflict_disclosed)', client)
    def test_today_completion_uses_task_logs_not_acceptance_status(self):
        from collaboration import cloud_tasks_for_user

        snapshot = {
            "tasks": [
                {"id": "accepted-only", "title": "Accepted", "employee_id": "u1",
                 "accept_status": "accepted"},
                {"id": "logged", "title": "Logged", "employee_id": "u1",
                 "accept_status": "accepted"},
                {"id": "other", "title": "Other", "employee_id": "u2"},
            ],
            "task_logs": [
                {"id": "log-1", "task_id": "logged", "employee_id": "u1",
                 "finished_at": "2026-11-04T10:00:00Z"},
            ],
        }
        tasks = cloud_tasks_for_user(snapshot, "u1")
        self.assertEqual(["accepted-only", "logged"], [task["id"] for task in tasks])
        self.assertFalse(tasks[0]["completed"])
        self.assertTrue(tasks[1]["completed"])
        self.assertFalse(TodayPage._is_done({"accept_status": "accepted"}))
        self.assertTrue(TodayPage._is_done({"completed": True}))

    def test_today_clears_old_account_tasks_before_switch(self):
        app = QApplication.instance() or QApplication([])
        self.assertIsNotNone(app)
        window = SimpleNamespace(identity_state={}, employee_cloud_page=None)
        page = TodayPage(window)
        page.account_user_id = "old-user"
        page.tasks = [{"title": "Old user's task"}]
        page.render()
        page.apply_account_session(SimpleNamespace(user_id="new-user"))
        self.assertEqual([], page.tasks)
        self.assertEqual(0, page.task_list.count())

    def test_today_refresh_failure_clears_visible_tasks(self):
        from collaboration import EmployeeCloudPage

        app = QApplication.instance() or QApplication([])
        self.assertIsNotNone(app)
        window = SimpleNamespace(identity_state={})
        today = TodayPage(window)
        window.today_page = today
        page = EmployeeCloudPage(window)
        page.session = SimpleNamespace(user_id="u1")
        today.tasks = [{"title": "Stale task"}]
        today.render()
        page.table.setRowCount(1)
        with patch("collaboration.QMessageBox.warning"):
            page._refresh_failed("offline")
        self.assertEqual([], today.tasks)
        self.assertEqual(0, today.task_list.count())
        self.assertEqual(0, page.table.rowCount())
    def test_simple_mode_blocks_management_actions_not_only_tabs(self):
        from main import MainWindow

        window = MainWindow.__new__(MainWindow)
        window.account_session = SimpleNamespace(role="boss")
        window.identity_state = {"me": {
            "permissions": ["projects.manage", "data.export_all"],
            "preferred_mode": "simple",
        }}
        self.assertFalse(window._management_action_allowed("projects.manage"))
        self.assertFalse(window._management_action_allowed("data.export_all"))

        window.identity_state["me"]["preferred_mode"] = "advanced"
        self.assertTrue(window._management_action_allowed("projects.manage"))
        window.identity_state["me"]["permissions"] = []
        self.assertFalse(window._management_action_allowed("projects.manage"))

        class FakeAction:
            def __init__(self):
                self.enabled = True

            def setEnabled(self, enabled):
                self.enabled = enabled

        project_action = FakeAction()
        export_action = FakeAction()
        window.management_actions = [
            (project_action, "projects.manage"),
            (export_action, "data.export_all"),
        ]
        window._refresh_management_actions()
        self.assertFalse(project_action.enabled)
        self.assertFalse(export_action.enabled)

        flashes = []
        window.flash = lambda text, milliseconds=2600: flashes.append(text)
        self.assertFalse(window._ensure_management_action("projects.manage"))
        self.assertTrue(flashes)
        main_text = read("main.py")
        self.assertIn('(self.act_new, "projects.manage")', main_text)
        self.assertIn('(self.act_export, "data.export_all")', main_text)
        self.assertIn("if not self._ensure_management_action(\"projects.manage\")", main_text)
        self.assertIn("if not self._ensure_management_action(\"data.export_all\")", main_text)
    def test_point_ledger_visibility_and_evidence_validation(self):
        point_state = self.rpc_definition("get_point_state")
        self.assertIn("_identity_can_read_full_point_ledger", point_state)
        self.assertIn("'profile_id',l.profile_id", point_state)
        self.assertIn("'profile_name',recipient.name", point_state)
        self.assertIn("v_can_read_full_ledger", point_state)
        identity_ui = read("identity_ui.py")
        self.assertIn("entry.get(\"profile_name\")", identity_ui)
        self.assertIn("can_read_full_ledger", identity_ui)
        mobile_identity = read("mobile/identity.js")
        self.assertIn("can_read_full_ledger", mobile_identity)
        self.assertIn("entry.profile_name", mobile_identity)

        ledger_reader = self.rpc_definition(
            "_identity_can_read_full_point_ledger"
        )
        self.assertIn("_identity_is_board_director", ledger_reader)
        self.assertIn("role_key='auditor'", ledger_reader)
        self.assertIn("audit.read", ledger_reader)

        award = self.rpc_definition("award_points")
        self.assertIn("_identity_award_evidence_is_valid", award)
        self.assertIn("evidence record is not allowed", award)
        evidence = self.rpc_definition("_identity_award_evidence_is_valid")
        for marker in (
            "task_logs", "worklogs", "knowledge_items", "community_posts"
        ):
            self.assertIn(marker, evidence)
        self.assertIn("boss_id", evidence)
    def test_integration_dependencies_and_ci_notes_are_documented(self):
        test_requirements = read("requirements-test.txt").lower()
        self.assertIn("psycopg2-binary", test_requirements)
        self.assertIn("pglast", test_requirements)
        readme = read("README.md")
        for marker in (
            "PROJECT_RECORDER_TEST_DATABASE_URL",
            "python -m pip install -r requirements-test.txt",
            "python -m unittest tests.test_enterprise_governance_integration -v",
            "一次性 PostgreSQL/Supabase 测试库",
            "CI",
            "enterprise-identity.sql",
            "community.sql",
            "enterprise-governance-v2.sql",
        ):
            self.assertIn(marker, readme)
        integration = read("tests/test_enterprise_governance_integration.py")
        self.assertIn("skipUnless", integration)
        self.assertIn("psycopg2", integration)

    def test_employee_cloud_loaded_publishes_log_enriched_tasks(self):
        from collaboration import EmployeeCloudPage

        app = QApplication.instance() or QApplication([])
        self.assertIsNotNone(app)
        window = SimpleNamespace(identity_state={})
        today = TodayPage(window)
        window.today_page = today
        page = EmployeeCloudPage(window)
        page.session = SimpleNamespace(user_id="u1")
        page._loaded({
            "tasks": [
                {"id": "logged", "title": "Logged", "employee_id": "u1",
                 "accept_status": "accepted", "plan_date": "2026-11-04"},
                {"id": "accepted-only", "title": "Accepted",
                 "employee_id": "u1", "accept_status": "accepted",
                 "plan_date": "2026-11-04"},
            ],
            "task_logs": [
                {"id": "log-1", "task_id": "logged", "employee_id": "u1",
                 "finished_at": "2026-11-04T10:00:00Z"},
            ],
        })
        self.assertEqual(
            [True, False], [task["completed"] for task in today.tasks]
        )
        self.assertEqual("已完成", page.table.item(0, 2).text())

    def test_logged_out_local_actions_are_not_simple_mode_blocked(self):
        from main import MainWindow

        window = MainWindow.__new__(MainWindow)
        window.account_session = None
        window.identity_state = {}
        self.assertTrue(window._management_action_allowed("projects.manage"))
        self.assertTrue(window._management_action_allowed("data.export_all"))

        class FakeAction:
            def __init__(self):
                self.enabled = False

            def setEnabled(self, enabled):
                self.enabled = enabled

        project_action = FakeAction()
        export_action = FakeAction()
        window.management_actions = [
            (project_action, "projects.manage"),
            (export_action, "data.export_all"),
        ]
        window._refresh_management_actions()
        self.assertTrue(project_action.enabled)
        self.assertTrue(export_action.enabled)

        window.account_session = SimpleNamespace(
            user_id="u1", role="boss", profile={}
        )
        window.identity_state = {"me": {
            "permissions": ["projects.manage", "data.export_all"],
            "preferred_mode": "simple",
        }}
        self.assertFalse(window._management_action_allowed("projects.manage"))
        self.assertFalse(window._management_action_allowed("data.export_all"))
        window._refresh_management_actions()
        self.assertFalse(project_action.enabled)
        self.assertFalse(export_action.enabled)

    def test_install_unified_declares_unlock_columns_before_references(self):
        import pglast

        install = read("mobile/sql/install-unified.sql")
        pglast.parse_sql(install)
        create_start = install.index(
            "create table if not exists public.community_posts"
        )
        index_start = install.index("create index", create_start)
        policy_start = install.index("create policy", create_start)
        create_block = install[create_start:index_start]
        self.assertIn("unlock_cost integer", create_block)
        self.assertIn("is_required boolean", create_block)
        for column in ("unlock_cost", "is_required"):
            alter = f"add column if not exists {column}"
            alter_start = install.index(alter, create_start)
            self.assertLess(alter_start, policy_start)
        self.assertLess(create_start, policy_start)
        self.assertIn(
            "using (author_id = auth.uid() or is_required or unlock_cost = 0)",
            install,
        )

    def test_identity_motion_aggregate_avoids_correlated_order_by(self):
        import pglast

        for name in ('enterprise-identity.sql', 'enterprise-governance-v2.sql'):
            sql = read('mobile/sql/' + name)
            pglast.parse_sql(sql)
            self.assertNotIn(
                "order by case when x.status='open' then 0 else 1 end,x.created_at desc",
                sql,
            )

    def test_standalone_community_migration_adds_unlock_columns(self):
        import pglast

        community = read("mobile/sql/community.sql")
        pglast.parse_sql(community)
        create_start = community.index(
            "create table if not exists public.community_posts"
        )
        index_start = community.index("create index", create_start)
        create_block = community[create_start:index_start]
        self.assertIn("unlock_cost integer", create_block)
        self.assertIn("is_required boolean", create_block)
        for column in ("unlock_cost", "is_required"):
            alter = f"add column if not exists {column}"
            alter_start = community.index(alter, create_start)
            self.assertLess(alter_start, community.index("create or replace function", create_start))

    def test_authorized_ledger_is_not_truncated(self):
        point_state = self.rpc_definition("get_point_state")
        self.assertNotIn("limit 100", point_state)
        mobile_identity = read("mobile/identity.js")
        self.assertNotIn("ledger.slice(0, 30)", mobile_identity)


if __name__ == "__main__":
    unittest.main()
