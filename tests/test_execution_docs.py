import unittest
from pathlib import Path


class ExecutionDocsTest(unittest.TestCase):
    def test_readme_documents_phase_3_rollout(self):
        readme = Path("README.md").read_text(encoding="utf-8")
        for text in (
            "execution-tracking-v1.sql",
            "执行追踪",
            "验收标准",
            "交付证据",
            "独立验收",
            "待验收",
            "返工",
            "已验收",
            "依赖",
            "下游",
            "交接",
            "接收方",
            "变更",
            "工期",
            "成本",
            "资源",
            "未批准",
            "原计划",
            "decision_items",
            "tests.test_execution_integration",
            "PROJECT_RECORDER_TEST_DATABASE_URL",
        ):
            self.assertIn(text, readme)
        self.assertLess(
            readme.index("execution-tracking-v1.sql"),
            readme.index("operations-economics-v1.sql"),
        )
        prerequisites = readme[readme.index("运行前按以下顺序在测试库执行："):]
        for prerequisite in (
            "setup-tables.sql", "migrate-notify.sql", "work-session.sql",
            "merit-ledger.sql", "rewards-leave.sql", "unified-platform.sql",
        ):
            self.assertIn(prerequisite, prerequisites)
        self.assertIn("mobile/sql/execution-tracking-v1.sql", prerequisites)
        self.assertLess(
            prerequisites.index("mobile/sql/execution-tracking-v1.sql"),
            prerequisites.index("mobile/sql/operations-economics-v1.sql"),
        )

    def test_manifest_includes_phase_3_sources(self):
        manifest = Path("sync_manifest.txt").read_text(encoding="utf-8")
        for text in (
            "execution_rules.py",
            "execution_ui.py",
            "tests/test_execution_rules.py",
            "tests/test_execution_sql.py",
            "tests/test_execution_client.py",
            "tests/test_execution_ui.py",
            "tests/test_execution_integration.py",
            "tests/test_execution_docs.py",
            "mobile/execution.js",
            "mobile/www/execution.js",
            "mobile/sql/execution-tracking-v1.sql",
        ):
            self.assertIn(text, manifest)

    def test_unified_installer_has_guarded_phase_3_block(self):
        installer = Path("mobile/sql/install-unified.sql").read_text(
            encoding="utf-8"
        )
        for text in (
            "Phase 3",
            "execution_installer",
            "to_regclass('public.task_acceptance')",
            "execution-tracking-v1.sql",
            "review_task_acceptance",
            "accept_task_handoff",
            "decide_change_request",
            "get_execution_board",
            "delete_task_dependency",
            "_execution_urgency",
        ):
            self.assertIn(text, installer)
        self.assertTrue(all(ord(ch) < 128 for ch in installer))


if __name__ == "__main__":
    unittest.main()
