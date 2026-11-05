import unittest
from pathlib import Path


class DecisionDocsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.readme = Path("README.md").read_text(encoding="utf-8")
        cls.manifest = Path("sync_manifest.txt").read_text(encoding="utf-8")
        cls.install = Path(
            "mobile/sql/install-unified.sql"
        ).read_text(encoding="utf-8")

    def test_docs_and_manifest(self):
        self.assertIn("decision-approvals-v1.sql", self.readme)
        self.assertIn("经营决策中心", self.readme)
        self.assertIn("decision_ui.py", self.manifest)
        self.assertIn("mobile/decision.js", self.manifest)
        self.assertIn(
            "mobile/sql/decision-approvals-v1.sql", self.manifest
        )

    def test_phase2a_deployment_order(self):
        required = [
            "enterprise-identity.sql",
            "community.sql",
            "enterprise-governance-v2.sql",
            "task-accept-extension.sql",
            "decision-approvals-v1.sql",
        ]
        start = self.readme.index("阶段 2A 部署顺序")
        end = self.readme.index("### 统一云端部署", start)
        block = self.readme[start:end]
        positions = [block.index(item) for item in required]
        self.assertEqual(positions, sorted(positions))

    def test_runtime_boundaries_are_documented(self):
        for text in (
            "统一审批",
            "高级模式",
            "管理、财务、审计或治理",
            "幂等",
            "审计",
            "tests.test_decision_integration",
        ):
            self.assertIn(text, self.readme)

    def test_unified_installer_contains_guarded_phase2a_block(self):
        self.assertTrue(all(ord(char) < 128 for char in self.install))
        for text in (
            "decision_items",
            "approval_requests",
            "get_decision_center",
            "act_on_approval",
            "decision_phase2a",
            "Phase 2A",
        ):
            self.assertIn(text, self.install)


if __name__ == "__main__":
    unittest.main()
