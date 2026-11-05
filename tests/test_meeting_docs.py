import unittest
from pathlib import Path


class MeetingDocsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.readme = Path("README.md").read_text(encoding="utf-8")
        cls.manifest = Path("sync_manifest.txt").read_text(encoding="utf-8")
        cls.installer = Path("mobile/sql/install-unified.sql").read_text(encoding="utf-8")

    def test_readme_documents_shareholder_meetings(self):
        for text in (
            "股东大会", "月度例行会议", "临时股东大会", "超过半数",
            "人数", "请假", "会议纪要", "shareholder-meetings-v1.sql",
        ):
            self.assertIn(text, self.readme)
        marker = "股东大会升级顺序："
        block = self.readme[self.readme.index(marker):]
        self.assertIn("enterprise-identity.sql", block)
        self.assertIn("enterprise-governance-v2.sql", block)
        self.assertIn("shareholder-meetings-v1.sql", block)

    def test_manifest_includes_meeting_sources(self):
        for text in (
            "meeting_rules.py", "meeting_ui.py", "mobile/meeting.js",
            "mobile/www/meeting.js", "mobile/sql/shareholder-meetings-v1.sql",
            "tests/test_meeting_rules.py", "tests/test_meeting_sql.py",
            "tests/test_meeting_client.py", "tests/test_meeting_ui.py",
            "tests/test_meeting_integration.py", "tests/test_meeting_docs.py",
        ):
            self.assertIn(text, self.manifest)

    def test_installer_has_guarded_meeting_block(self):
        self.assertIn("-- Phase 5: shareholder meetings", self.installer)
        for text in (
            "create table if not exists public.shareholder_meetings",
            "shareholder_meetings_one_regular_idx",
            "shareholder_meetings_one_special_idx",
            "v_yes*2>v_total",
            "leave note required",
        ):
            self.assertIn(text, self.installer)

    def test_mobile_assets_are_wired(self):
        build = Path("mobile/build-www.js").read_text(encoding="utf-8")
        index = Path("mobile/index.html").read_text(encoding="utf-8")
        self.assertIn('"meeting.js"', build)
        self.assertIn('src="meeting.js"', index)
        self.assertIn('id="identity-meetings"', index)


if __name__ == "__main__":
    unittest.main()
