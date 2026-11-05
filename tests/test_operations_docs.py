import unittest
from pathlib import Path


class OperationsDocsTest(unittest.TestCase):
    def test_readme_documents_phase_2b(self):
        readme = Path("README.md").read_text(encoding="utf-8")
        for text in (
            "operations-economics-v1.sql",
            "经营分析",
            "工时经营标签",
            "能力缺口",
            "绩效证据",
            "工资或晋升",
            "decision-approvals-v1.sql",
            "PROJECT_RECORDER_TEST_DATABASE_URL",
            "tests.test_operations_integration",
            "逐字段",
            "迁移队列",
            "人员查看范围",
        ):
            self.assertIn(text, readme)
        self.assertLess(
            readme.index("decision-approvals-v1.sql"),
            readme.index("operations-economics-v1.sql"),
        )

    def test_manifest_includes_phase_2b_sources(self):
        manifest = Path("sync_manifest.txt").read_text(encoding="utf-8")
        for text in (
            "operations_rules.py",
            "operations_ui.py",
            "tests/test_operations_rules.py",
            "tests/test_operations_sql.py",
            "tests/test_operations_client.py",
            "tests/test_operations_ui.py",
            "tests/test_operations_integration.py",
            "tests/test_operations_docs.py",
            "mobile/operations.js",
            "mobile/www/operations.js",
            "mobile/sql/operations-economics-v1.sql",
        ):
            self.assertIn(text, manifest)

    def test_unified_installer_has_guarded_phase_2b_block(self):
        installer = Path("mobile/sql/install-unified.sql").read_text(
            encoding="utf-8"
        )
        for text in (
            "Phase 2B",
            "operations_installer",
            "to_regclass('public.decision_items')",
            "operations-economics-v1.sql",
            "operations.economics.updated",
            "get_operations_dashboard",
        ):
            self.assertIn(text, installer)
        self.assertTrue(all(ord(ch) < 128 for ch in installer))


if __name__ == "__main__":
    unittest.main()
