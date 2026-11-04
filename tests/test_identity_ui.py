import os
import unittest
from types import SimpleNamespace

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PyQt6.QtWidgets import QApplication

from identity_ui import IdentityPage
from role_templates_ui import RoleTemplatePage
from today_ui import TodayPage
from main import MainWindow


class RoleTemplateUiTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = QApplication.instance() or QApplication([])

    def test_render_template(self):
        page = RoleTemplatePage(None)
        page.snapshot = {
            "templates": [{
                "key": "pm",
                "name": "项目经理",
                "current_version": 1,
                "permissions": [],
            }]
        }
        page.render()
        self.assertEqual(page.table.item(0, 1).text(), "项目经理")

    def test_empty_render_clears_rows(self):
        page = RoleTemplatePage(None)
        page.snapshot = {"templates": [{"key": "pm", "name": "项目经理"}]}
        page.render()
        page.snapshot = {"templates": []}
        page.render()
        self.assertEqual(page.table.rowCount(), 0)

    def test_identity_page_has_template_and_board_tabs(self):
        page = IdentityPage(None)
        labels = [page.tabs.tabText(i) for i in range(page.tabs.count())]
        self.assertIn("身份模板", labels)
        self.assertIn("董事会与积分", labels)

    def test_template_page_exposes_editor_and_assignment_actions(self):
        page = RoleTemplatePage(None)
        self.assertEqual(page.edit_button.text(), "编辑四维权限")
        self.assertEqual(page.assign_button.text(), "临时指派")

    def test_today_page_empty(self):
        page = TodayPage(None)
        page.render()
        self.assertEqual(page.task_list.count(), 0)
        self.assertEqual(page.card_done.value_label.text(), "0/0")
        self.assertFalse(page.next_button.isEnabled())

    def test_today_page_renders_tasks_and_points(self):
        window = SimpleNamespace(identity_state={
            "me": {"preferred_mode": "simple"},
            "point_state": {"balance": 42},
        })
        page = TodayPage(window)
        page.tasks = [
            {"title": "完成验收", "due": "2026-11-04", "done": True},
            {"title": "整理交付证据", "due": "2026-11-05", "done": False},
        ]
        page.render()
        self.assertEqual(page.task_list.count(), 2)
        self.assertIn("完成验收", page.task_list.item(0).text())
        self.assertIn("整理交付证据", page.task_list.item(1).text())
        self.assertEqual(page.card_done.value_label.text(), "1/2")
        self.assertEqual(page.card_points.value_label.text(), "42")
        self.assertTrue(page.next_button.isEnabled())
        self.assertEqual(page.ledger_list.count(), 0)
        page.set_cloud_tasks([{"title": "云端任务"}])
        self.assertEqual(page.task_list.count(), 1)

    def test_today_page_refresh_rerenders(self):
        page = TodayPage(None)
        page.tasks = [{"title": "只做这一件事", "due": "今天"}]
        page.refresh()
        self.assertEqual(page.task_list.count(), 1)

    def test_advanced_mode_requires_loaded_permission(self):
        window = MainWindow.__new__(MainWindow)
        window.account_session = SimpleNamespace(role="boss")
        window.identity_state = {
            "me": {"permissions": [], "preferred_mode": "advanced"}
        }
        self.assertEqual(window._effective_ui_mode(), "simple")

    def test_advanced_mode_uses_saved_preference(self):
        window = MainWindow.__new__(MainWindow)
        window.account_session = SimpleNamespace(role="employee")
        window.identity_state = {"me": {
            "permissions": ["finance.view"],
            "preferred_mode": "advanced",
        }}
        self.assertEqual(window._effective_ui_mode(), "advanced")


if __name__ == "__main__":
    unittest.main()
