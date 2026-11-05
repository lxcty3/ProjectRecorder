import os
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PyQt6.QtWidgets import QApplication

from community_client import CommunityClient, CommunitySession
from decision_ui import DecisionCenterPage


class DecisionUiTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = QApplication.instance() or QApplication([])

    def test_render_decision_and_approval(self):
        page = DecisionCenterPage(None)
        page.snapshot = {
            "decisions": [{
                "id": "d1", "title": "项目延期", "risk": "severe",
                "impact_days": 8, "impact_amount": 0, "status": "open",
                "owner_name": "王经理", "due_at": "2026-11-06T10:00:00Z",
                "evidence": [{"type": "task", "id": "t1"}],
                "actions": {"assign": True, "defer": True},
            }],
            "approvals": [{
                "id": "a1", "title": "采购审批", "amount": 12000,
                "kind": "purchase", "status": "pending",
                "requester_name": "李员工", "due_at": "2026-11-06T10:00:00Z",
                "actions": {"approve": True, "reject": False,
                            "return": True, "cancel": False},
            }],
        }
        page.render()
        self.assertEqual(page.decision_table.rowCount(), 1)
        self.assertEqual(page.approval_table.rowCount(), 1)
        self.assertIn("王经理", page.decision_table.item(0, 3).text())
        self.assertIn("2026-11-06", page.decision_table.item(0, 4).text())
        self.assertIn("8 天", page.decision_table.item(0, 2).text())
        self.assertIn("task t1", page.detail_view.toPlainText())
        self.assertIn("李员工", page.approval_table.item(0, 4).text())

    def test_action_buttons_follow_server_capabilities(self):
        page = DecisionCenterPage(None)
        page.snapshot = {
            "decisions": [{
                "id": "d1", "title": "项目延期", "status": "open",
                "actions": {"acknowledge": True, "assign": True,
                            "defer": True, "resolve": True,
                            "dismiss": True},
            }],
            "approvals": [{
                "id": "a1", "title": "采购审批", "kind": "purchase",
                "status": "pending",
                "actions": {"approve": True, "reject": False,
                            "return": True, "cancel": False},
            }],
        }
        page.render()
        page.decision_table.selectRow(0)
        page.approval_table.selectRow(0)
        page._sync_action_buttons()
        self.assertTrue(page.decision_action_buttons["assign"].isEnabled())
        self.assertTrue(page.approval_action_buttons["approve"].isEnabled())
        self.assertFalse(page.approval_action_buttons["reject"].isEnabled())
        self.assertTrue(page.approval_action_buttons["return"].isEnabled())
        self.assertFalse(page.approval_action_buttons["cancel"].isEnabled())

    def test_approval_execution_calls_real_idempotent_rpc(self):
        page = DecisionCenterPage(None)
        page.session = CommunitySession("token", expires_at=9999999999)
        item = {"id": "a1", "kind": "leave", "title": "请假"}
        captured = {}
        page._start_worker = lambda work, done=None, failed=None: captured.update(
            work=work
        )
        with patch.object(
            CommunityClient, "act_on_approval", return_value={"ok": True}
        ) as call:
            page._execute_approval(item, "approved", "同意")
            captured["work"]()
        body = call.call_args.kwargs
        self.assertEqual("approved", body["action"])
        self.assertEqual("a1", body["approval_id"])
        self.assertTrue(body["idempotency_key"])

    def test_decision_execution_calls_real_idempotent_rpc(self):
        page = DecisionCenterPage(None)
        page.session = CommunitySession("token", expires_at=9999999999)
        item = {"id": "d1", "title": "延期风险"}
        captured = {}
        page._start_worker = lambda work, done=None, failed=None: captured.update(
            work=work
        )
        with patch.object(
            CommunityClient, "act_on_decision", return_value={"ok": True}
        ) as call:
            page._execute_decision(
                item, "assigned", owner_id="u2", note="分派处理"
            )
            captured["work"]()
        kwargs = call.call_args.kwargs
        self.assertEqual("assigned", kwargs["action"])
        self.assertEqual("u2", kwargs["owner_id"])
        self.assertTrue(kwargs["idempotency_key"])

    def test_main_wires_advanced_only_decision_tab(self):
        source = Path("main.py").read_text(encoding="utf-8")
        self.assertIn("DecisionCenterPage", source)
        self.assertIn("self.decision_tab = self.tabs.addTab(", source)
        self.assertIn(
            "self.tabs.setTabVisible(self.decision_tab, advanced and management)",
            source,
        )
        self.assertIn("self.decision_page.refresh()", source)


if __name__ == "__main__":
    unittest.main()
