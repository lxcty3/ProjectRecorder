import os
import unittest
from pathlib import Path
from unittest.mock import patch

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PyQt6.QtWidgets import QApplication

from community_client import CommunityClient, CommunitySession
from intake_ui import IntakePage


class IntakeUiTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = QApplication.instance() or QApplication([])

    def _snapshot(self, management=True):
        return {
            "my_requests": [{
                "id": "r3", "request_no": "INT-3", "request_type": "improvement",
                "title": "我的建议", "status": "submitted", "priority_score": 12,
                "sla_due_at": "2026-11-06T10:00:00Z",
            }],
            "requests": [{
                "id": "r1", "request_no": "INT-1", "request_type": "incident",
                "title": "支付页面报错", "status": "submitted",
                "priority_score": 51, "sla_due_at": "2026-11-05T12:00:00Z",
                "sla_overdue": True, "owner_name": "", "converted_kind": None,
            }, {
                "id": "r2", "request_no": "INT-2", "request_type": "customer",
                "title": "官网改版", "status": "in_progress",
                "priority_score": 35, "sla_due_at": "2026-11-07T12:00:00Z",
                "owner_name": "李经理", "converted_kind": "project",
            }],
            "forms": [{
                "id": "f1", "name": "客户入口", "public_token": "token",
                "public_url": "https://example.com/intake.html?token=token",
            }],
            "members": [{"id": "u1", "name": "李经理"}],
            "projects": [{"id": "p1", "name": "官网项目"}],
            "tasks": [],
            "access": {"management": management} if management else {},
        }

    def test_management_render_and_actions(self):
        page = IntakePage(None)
        page.snapshot = self._snapshot()
        page.render()
        self.assertEqual(page.request_table.rowCount(), 2)
        self.assertEqual(page.my_table.rowCount(), 1)
        self.assertFalse(page.management_group.isHidden())
        self.assertIn("SLA 超时 1", page.summary_label.text())
        page.request_table.selectRow(0)
        self.assertTrue(page.triage_button.isEnabled())
        self.assertTrue(page.convert_button.isEnabled())
        self.assertTrue(page.merge_button.isEnabled())
        self.assertTrue(page.message_button.isEnabled())

    def test_simple_mode_hides_management_board(self):
        page = IntakePage(None)
        page.snapshot = self._snapshot(management=False)
        page.render()
        self.assertTrue(page.management_group.isHidden())
        self.assertTrue(page.public_group.isHidden())
        self.assertEqual(page.my_table.rowCount(), 1)

    def test_quick_capture_calls_real_rpc(self):
        page = IntakePage(None)
        page.session = CommunitySession("token", expires_at=9999999999)
        captured = {}
        page._start_worker = lambda work, done=None, failed=None: captured.update(
            work=work
        )
        page.quick_type.setCurrentIndex(page.quick_type.findData("incident"))
        page.quick_title.setText("付款失败")
        page.quick_detail.setPlainText("客户完成支付后看到空白页")
        page.business_score.setValue(4)
        page.urgency_score.setValue(5)
        page.risk_score.setValue(3)
        page.dependency_score.setValue(2)
        page.effort_score.setValue(1)
        with patch.object(
            CommunityClient, "create_intake_request", return_value={"ok": True}
        ) as create:
            page._submit_quick()
            self.assertEqual(captured["work"](), {"ok": True})
            data = create.call_args.args[1]
            self.assertEqual(data["title"], "付款失败")
            self.assertEqual(data["request_type"], "incident")
            self.assertEqual(data["business_value"], 4)
            self.assertEqual(data["effort"], 1)

    def test_form_actions_use_server_url(self):
        page = IntakePage(None)
        page.snapshot = self._snapshot()
        page.render()
        QApplication.clipboard().clear()
        page._copy_link()
        self.assertIn("intake.html?token=token", QApplication.clipboard().text())

    def test_main_wires_intake_tab_for_logged_in_users(self):
        source = Path("main.py").read_text(encoding="utf-8")
        self.assertIn("from intake_ui import IntakePage", source)
        self.assertIn("self.intake_tab = self.tabs.addTab(", source)
        self.assertIn("self.intake_page.apply_account_session(session)", source)
        self.assertIn("self.tabs.setTabVisible(self.intake_tab, logged)", source)


if __name__ == "__main__":
    unittest.main()
