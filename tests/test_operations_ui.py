import os
import unittest
from pathlib import Path
from unittest.mock import patch

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PyQt6.QtWidgets import QApplication

from community_client import CommunityClient, CommunitySession
from operations_ui import OperationsPage


class OperationsUiTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = QApplication.instance() or QApplication([])

    def _page(self, permissions=None):
        page = OperationsPage(None)
        page.session = CommunitySession(
            "token",
            expires_at=9999999999,
            profile={"id": "u1", "enterprise_permissions": permissions or []},
        )
        return page

    def test_render(self):
        page = OperationsPage(None)
        page.snapshot = {
            "projects": [{
                "project_id": "p1",
                "name": "A",
                "contract_amount": 100000,
                "invoiced_amount": 60000,
                "collected_amount": 45000,
                "outsourced_committed": 10000,
                "labor_cost": 35000,
                "projected_completion_cost": 65000,
                "projected_margin": 35000,
                "projected_margin_percent": 35,
                "collection_gap": 55000,
            }],
            "capacity_gaps": [{
                "skill": "Python", "required_hours": 80,
                "available_hours": 40, "gap_hours": 40,
                "period_start": "2026-11-05", "period_end": "2026-12-02",
            }],
            "performance": [{
                "id": "e1", "name": "张三", "period": "2026-11",
                "score": 88, "status": "reviewed",
                "evidence": [{"type": "task", "id": "t1"}],
            }],
            "worklog_summary": {
                "total_hours": 32, "billable_hours": 24,
                "overtime_hours": 6, "rework_hours": 2,
                "waiting_hours": 1, "travel_hours": 3,
                "by_kind": {"project": 20, "presales": 12},
            },
            "window_weeks": 4,
        }
        page.render()
        self.assertEqual(page.project_table.rowCount(), 1)
        self.assertEqual(page.capacity_table.rowCount(), 1)
        self.assertEqual(page.performance_table.rowCount(), 1)
        self.assertIn("35.0", page.project_table.item(0, 8).text())
        self.assertIn("40", page.capacity_table.item(0, 3).text())
        self.assertIn("32", page.worklog_label.text())
        page.performance_table.selectRow(0)
        page._performance_selected()
        self.assertIn("task t1", page.detail_view.toPlainText())

    def test_actions_follow_permissions(self):
        page = self._page(["finance.manage", "people.manage"])
        page.snapshot = {
            "projects": [{"project_id": "p1", "name": "A"}],
            "performance": [{"id": "e1", "name": "B", "status": "submitted"}],
        }
        page.render()
        page.project_table.selectRow(0)
        page.performance_table.selectRow(0)
        page._sync_actions()
        self.assertTrue(page.edit_economics_button.isEnabled())
        self.assertTrue(page.review_button.isEnabled())

        read_only = self._page(["reports.view"])
        read_only.snapshot = {
            "projects": [{"project_id": "p1", "name": "A"}],
            "performance": [{"id": "e1", "name": "B", "status": "submitted"}],
        }
        read_only.render()
        read_only.project_table.selectRow(0)
        read_only.performance_table.selectRow(0)
        read_only._sync_actions()
        self.assertFalse(read_only.edit_economics_button.isEnabled())
        self.assertFalse(read_only.review_button.isEnabled())

    def test_hidden_page_does_not_call_management_rpc_without_permission(self):
        page = OperationsPage(None)
        page.session = CommunitySession(
            "token",
            expires_at=9999999999,
            profile={"id": "u2", "role": "employee",
                     "enterprise_permissions": []},
        )
        called = {"started": False}
        page._start_worker = lambda work, done=None, failed=None: called.update(
            started=True
        )
        page.refresh()
        self.assertFalse(called["started"])
        self.assertEqual(page.project_table.rowCount(), 0)

    def test_economics_execution_calls_real_rpc(self):
        page = self._page(["finance.manage"])
        page.session = CommunitySession("token", expires_at=9999999999)
        captured = {}
        page._start_worker = lambda work, done=None, failed=None: captured.update(
            work=work
        )
        with patch.object(
            CommunityClient, "upsert_project_economics", return_value={"ok": True}
        ) as call:
            page._execute_economics({"project_id": "p1"}, {"contract_amount": 100})
            captured["work"]()
        self.assertEqual("p1", call.call_args.args[1])
        self.assertEqual({"contract_amount": 100}, call.call_args.args[2])

    def test_review_execution_calls_real_rpc(self):
        page = self._page(["people.manage"])
        page.session = CommunitySession("token", expires_at=9999999999)
        captured = {}
        page._start_worker = lambda work, done=None, failed=None: captured.update(
            work=work
        )
        with patch.object(
            CommunityClient,
            "review_performance_evidence",
            return_value={"ok": True},
        ) as call:
            page._execute_review({"id": "e1"}, "证据已核对")
            captured["work"]()
        self.assertEqual("e1", call.call_args.args[1])
        self.assertEqual("证据已核对", call.call_args.args[2])

    def test_main_wires_advanced_management_only_operations_tab(self):
        source = Path("main.py").read_text(encoding="utf-8")
        self.assertIn("OperationsPage", source)
        self.assertIn("self.operations_tab = self.tabs.addTab(", source)
        self.assertIn(
            "self.tabs.setTabVisible(self.operations_tab, advanced and management)",
            source,
        )
        self.assertIn("self.operations_page.refresh()", source)


if __name__ == "__main__":
    unittest.main()
