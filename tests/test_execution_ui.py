import os
import unittest
from pathlib import Path
from unittest.mock import patch

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PyQt6.QtWidgets import QApplication

from community_client import CommunityClient, CommunitySession
from execution_ui import ExecutionPage


class ExecutionUiTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = QApplication.instance() or QApplication([])

    def _snapshot(self):
        return {
            "acceptance": [{
                "task_id": "t1", "title": "A", "status": "pending",
                "criteria": "tests", "evidence": "commit abc",
                "reviewer_id": "u1", "submitter_name": "B",
                "actions": {"accept": True, "rework": True},
            }],
            "handoffs": [{
                "id": "h1", "title": "B", "status": "pending",
                "artifact": "bundle", "from_name": "C", "to_name": "D",
                "to_profile_id": "u1", "actions": {"accept": True, "reject": True},
            }],
            "changes": [{
                "id": "c1", "title": "C", "status": "pending",
                "scope": "expand", "reason": "client", "urgency": "urgent",
                "schedule_impact_days": 5, "cost_impact": 60000,
                "resource_impact": "two engineers", "risk": "risk",
                "actions": {"approve": True, "reject": True, "return": True},
            }],
            "dependencies": [{
                "title": "D", "depends_on_title": "E", "lag_days": 2,
                "blocked": True, "delayed_days": 4,
                "affected_tasks": [
                    {"task_id": "t2", "title": "F", "delay_days": 6}
                ],
            }],
            "access": {
                "can_review_acceptance": True,
                "can_manage_changes": True,
            },
        }

    def test_render_all_queues_and_impact_details(self):
        page = ExecutionPage(None)
        page.snapshot = self._snapshot()
        page.render()
        self.assertEqual(page.acceptance_table.rowCount(), 1)
        self.assertEqual(page.handoff_table.rowCount(), 1)
        self.assertEqual(page.change_table.rowCount(), 1)
        self.assertEqual(page.dependency_table.rowCount(), 1)
        self.assertIn("5", page.change_table.item(0, 3).text())
        self.assertIn("60,000", page.change_table.item(0, 4).text())
        self.assertIn("two engineers", page.change_table.item(0, 5).text())
        self.assertIn("4", page.dependency_table.item(0, 3).text())
        self.assertIn("F", page.dependency_table.item(0, 5).text())

    def test_actions_follow_selected_server_capabilities(self):
        page = ExecutionPage(None)
        page.snapshot = self._snapshot()
        page.render()
        page.acceptance_table.selectRow(0)
        page.handoff_table.selectRow(0)
        page.change_table.selectRow(0)
        page._sync_actions()
        self.assertTrue(page.accept_button.isEnabled())
        self.assertTrue(page.rework_button.isEnabled())
        self.assertTrue(page.handoff_accept_button.isEnabled())
        self.assertTrue(page.handoff_reject_button.isEnabled())
        self.assertTrue(page.change_approve_button.isEnabled())
        self.assertTrue(page.change_return_button.isEnabled())

    def test_desktop_actions_call_real_rpcs(self):
        page = ExecutionPage(None)
        page.session = CommunitySession("token", expires_at=9999999999)
        captured = {}
        page._start_worker = lambda work, done=None, failed=None: captured.update(
            work=work
        )
        with patch.object(
            CommunityClient, "review_task_acceptance", return_value={"ok": True}
        ) as accept:
            page._execute_acceptance({"task_id": "t1"}, "accepted", "ok")
            self.assertEqual(captured["work"](), {"ok": True})
            self.assertEqual(accept.call_args.args[1], "t1")
        with patch.object(
            CommunityClient, "accept_task_handoff", return_value={"ok": True}
        ) as handoff:
            page._execute_handoff({"id": "h1"}, "rejected", "bad")
            self.assertEqual(captured["work"](), {"ok": True})
            self.assertEqual(handoff.call_args.args[1], "h1")
        with patch.object(
            CommunityClient, "decide_change_request", return_value={"ok": True}
        ) as change:
            page._execute_change({"id": "c1"}, "approved", "ok")
            self.assertEqual(captured["work"](), {"ok": True})
            self.assertEqual(change.call_args.args[1], "c1")

    def test_main_wires_execution_tab_only_for_advanced_management(self):
        source = Path("main.py").read_text(encoding="utf-8")
        self.assertIn("from execution_ui import ExecutionPage", source)
        self.assertIn("self.execution_tab = self.tabs.addTab(", source)
        self.assertIn(
            "self.tabs.setTabVisible(self.execution_tab, advanced and management)",
            source,
        )
        self.assertIn("self.execution_page.refresh()", source)
        self.assertIn("self.execution_page.apply_account_session(session)", source)


if __name__ == "__main__":
    unittest.main()
