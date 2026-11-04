import unittest
from pathlib import Path


class IdentityDocsTest(unittest.TestCase):
    def test_docs(self):
        readme = Path("README.md").read_text(encoding="utf-8")
        manifest = Path("sync_manifest.txt").read_text(encoding="utf-8")
        install = Path("mobile/sql/install-unified.sql").read_text(encoding="utf-8")
        for text in (
            "enterprise-governance-v2.sql",
            "简单模式",
            "董事会",
            "阶段一升级顺序",
        ):
            self.assertIn(text, readme)
        for path in (
            "identity_rules.py",
            "role_templates_ui.py",
            "today_ui.py",
            "mobile/today.js",
            "mobile/sql/enterprise-governance-v2.sql",
        ):
            self.assertIn(path, manifest)
        self.assertIn("enterprise-governance-v2.sql", install)
        self.assertIn("separately", install)


if __name__ == "__main__":
    unittest.main()
