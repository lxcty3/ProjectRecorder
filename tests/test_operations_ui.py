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
                "evidence": {"items": [{"type": "task", "id": "t1"}]},
                "evidence_details": [{
                    "type": "task", "source_id": "t1",
                    "label": "交付接口", "status": "done",
                }],
            }],
            "members": [{"profile_id": "u1", "name": "张三"}],
            "capacity_demands": [{
                "id": "d1", "skill": "Python", "required_hours": 40,
                "needed_from": "2026-11-05", "needed_until": "2026-11-19",
            }],
            "skills": [{
                "profile_id": "u1", "name": "张三", "skill": "Python",
                "level": 4, "available_hours": 40,
            }],
            "worklog_summary": {
                "total_hours": 32, "billable_hours": 24,
                "overtime_hours": 6, "rework_hours": 2,
                "waiting_hours": 1, "travel_hours": 3,
                "by_kind": {"project": 20, "presales": 12},
            },
            "access": {
                "can_finance": True, "can_capacity": True,
                "can_performance": True, "can_worklogs": True,
                "can_people": True,
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
        detail = page.detail_view.toPlainText()
        self.assertIn("task t1", detail)
        self.assertIn("交付接口", detail)

    def test_project_only_capacity_is_hidden_with_permission_message(self):
        page = self._page(["projects.manage"])
        page.snapshot = {
            "projects": [],
            "capacity_gaps": [{
                "skill": "Python", "required_hours": 80,
                "available_hours": 0, "gap_hours": 80,
            }],
            "capacity_demands": [],
            "skills": [],
            "performance": [],
            "worklog_summary": {},
            "access": {
                "can_finance": False,
                "can_capacity": False,
                "capacity_requires_people_scope": True,
                "capacity_permission_message":
                    "Capacity gaps require people visibility scope.",
            },
        }
        page.render()
        self.assertEqual(0, page.capacity_table.rowCount())
        self.assertIn("人员", page.capacity_label.text())

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
        self.assertTrue(page.skill_button.isEnabled())
        self.assertTrue(page.capacity_button.isEnabled())
        self.assertTrue(page.evidence_button.isEnabled())

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
        self.assertFalse(read_only.skill_button.isEnabled())
        self.assertFalse(read_only.capacity_button.isEnabled())
        self.assertFalse(read_only.evidence_button.isEnabled())

    def test_hidden_page_does_not_call_management_rpc_without_permission(self):
        page = OperationsPage(None)
        page.session = CommunitySession(
            "token",
            expires_at=9999999999,
            profile={"id": "u2", "role": "employee",
                     "enterprise_permissions": []},
        )
        page.snapshot = {"projects": [{"project_id": "secret", "name": "Secret"}]}
        called = {"started": False}
        page._start_worker = lambda work, done=None, failed=None: called.update(
            started=True
        )
        page.refresh()
        self.assertFalse(called["started"])
        self.assertEqual(page.project_table.rowCount(), 0)
        self.assertEqual(page.snapshot["projects"], [])

    def test_simple_mode_never_fetches_operations(self):
        class Window:
            def _effective_ui_mode(self):
                return "simple"

        page = OperationsPage(Window())
        page.session = CommunitySession(
            "token",
            expires_at=9999999999,
            profile={"id": "u2", "enterprise_permissions": ["finance.manage"]},
        )
        called = {"started": False}
        page._start_worker = lambda work, done=None, failed=None: called.update(
            started=True
        )
        page.refresh()
        self.assertFalse(called["started"])

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

    def test_skill_capacity_and_evidence_workflows_call_real_rpcs(self):
        page = self._page(["people.manage", "projects.manage"])
        page.session = CommunitySession("token", expires_at=9999999999)
        calls = []
        page._start_worker = lambda work, done=None, failed=None: calls.append(work)
        with patch.object(
            CommunityClient, "upsert_profile_skill", return_value={"ok": True}
        ) as skill_call:
            page._execute_skill("u1", "python", {"level": 4})
            calls.pop()()
        self.assertEqual("u1", skill_call.call_args.args[1])
        self.assertEqual("python", skill_call.call_args.args[2])
        with patch.object(
            CommunityClient, "upsert_capacity_demand", return_value={"ok": True}
        ) as demand_call:
            page._execute_capacity("d1", {"required_hours": 20})
            calls.pop()()
        self.assertEqual("d1", demand_call.call_args.args[1])
        with patch.object(
            CommunityClient, "upsert_performance_evidence", return_value={"ok": True}
        ) as evidence_call:
            page._execute_evidence("u1", "2026-11", {"complexity_score": 4})
            calls.pop()()
        self.assertEqual("u1", evidence_call.call_args.args[1])
        self.assertEqual("2026-11", evidence_call.call_args.args[2])

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
