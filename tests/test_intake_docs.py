import unittest
from pathlib import Path


class IntakeDocsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.readme = Path("README.md").read_text(encoding="utf-8")
        cls.manifest = Path("sync_manifest.txt").read_text(encoding="utf-8")
        cls.installer = Path("mobile/sql/install-unified.sql").read_text(
            encoding="utf-8"
        )

    def test_readme_documents_phase_four_rollout(self):
        for text in (
            "工作入口", "公开表单", "二维码", "邮件", "分诊", "SLA",
            "重复需求", "内部备注", "转项目", "转任务", "售前",
            "work-intake-v1.sql", "intake.html", "qrcode.min.js",
            "get_public_intake_status", "intake_escalate_sla",
        ):
            self.assertIn(text, self.readme)
        order = self.readme.index("运行前按以下顺序在测试库执行：")
        prerequisites = self.readme[order:]
        self.assertIn("mobile/sql/work-intake-v1.sql", prerequisites)
        self.assertGreater(
            prerequisites.index("mobile/sql/work-intake-v1.sql"),
            prerequisites.index("mobile/sql/operations-economics-v1.sql"),
        )

    def test_manifest_includes_phase_four_sources(self):
        for text in (
            "intake_rules.py", "intake_ui.py", "mobile/intake.js",
            "mobile/intake.html", "mobile/public-intake.js",
            "mobile/vendor/qrcode.min.js", "mobile/sql/work-intake-v1.sql",
            "mobile/www/intake.js", "mobile/www/public-intake.js",
            "tests/test_intake_rules.py", "tests/test_intake_sql.py",
            "tests/test_intake_client.py", "tests/test_intake_ui.py",
            "tests/test_intake_docs.py",
        ):
            self.assertIn(text, self.manifest)

    def test_installer_has_guarded_phase_four_block(self):
        self.assertIn("-- Phase 4: work intake", self.installer)
        for text in (
            "do $intake_installer$", "create table if not exists public.intake_requests",
            "submit_public_intake", "get_public_intake_status",
            "merge_intake_request", "convert_intake_request",
        ):
            self.assertIn(text, self.installer)

    def test_build_and_mobile_assets_are_wired(self):
        build = Path("mobile/build-www.js").read_text(encoding="utf-8")
        for text in (
            '"intake.js"', '"intake.html"', '"public-intake.js"',
            '"qrcode.min.js"',
        ):
            self.assertIn(text, build)
        index = Path("mobile/index.html").read_text(encoding="utf-8")
        self.assertIn('id="page-intake"', index)
        self.assertIn('data-page="intake"', index)
        self.assertIn('src="intake.js"', index)

    def test_dependencies_include_qr_support(self):
        requirements = Path("requirements.txt").read_text(encoding="utf-8")
        self.assertIn("qrcode", requirements.lower())


if __name__ == "__main__":
    unittest.main()
