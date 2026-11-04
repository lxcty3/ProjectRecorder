import os
import unittest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PyQt6.QtWidgets import QApplication

from identity_ui import IdentityPage
from role_templates_ui import RoleTemplatePage


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

    def test_identity_page_has_template_tab(self):
        page = IdentityPage(None)
        labels = [page.tabs.tabText(i) for i in range(page.tabs.count())]
        self.assertIn("身份模板", labels)


if __name__ == "__main__":
    unittest.main()
