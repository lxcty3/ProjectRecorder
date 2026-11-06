"""Static contracts for the v2.1 community foundation."""

from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8-sig")


class CommunityForumContractTest(unittest.TestCase):
    def setUp(self):
        self.sql = read("mobile/sql/community-forum-v1.sql")
        self.client = read("community_client.py")
        self.desktop = read("community_ui.py")
        self.mobile = read("mobile/community.js")
        self.markup = read("mobile/index.html")
        self.unified = read("mobile/sql/install-unified.sql")

    def test_migration_is_ascii_and_idempotent(self):
        raw = (ROOT / "mobile/sql/community-forum-v1.sql").read_bytes()
        self.assertTrue(all(byte < 128 for byte in raw))
        for table in (
            "community_boards",
            "community_comments",
            "community_reactions",
            "community_bookmarks",
            "community_board_follows",
            "community_reports",
            "community_notifications",
        ):
            self.assertIn(f"create table if not exists public.{table}", self.sql)
        self.assertIn("add column if not exists board_id", self.sql)
        self.assertIn("update public.community_posts", self.sql)
        self.assertIn("10000000-0000-4000-8000-000000000001", self.sql)

    def test_required_rpcs_and_server_permissions(self):
        for rpc in (
            "get_community_boards",
            "list_community_posts_v2",
            "get_community_post",
            "post_community_message_v2",
            "add_community_comment",
            "toggle_community_like",
            "toggle_community_bookmark",
            "follow_community_board",
            "report_community_content",
            "get_community_notifications",
            "mark_community_notifications_read",
            "create_community_board",
            "update_community_board",
            "moderate_community_post",
            "resolve_community_report",
            "get_community_admin_stats",
        ):
            self.assertIn(f"function public.{rpc}", self.sql)
        self.assertIn("_community_can_view_board", self.sql)
        self.assertIn("_community_post_unlocked", self.sql)
        self.assertIn("enterprise_knowledge_unlocks", self.sql)
        self.assertNotIn("using (true)", self.sql.lower())
        self.assertIn("enable row level security", self.sql)

    def test_desktop_client_and_ui_use_v2_contract(self):
        for method in (
            "def boards(", "def list_posts_v2(", "def post_detail(",
            "def publish_v2(", "def add_comment(", "def toggle_like(",
            "def toggle_bookmark(", "def report_content(",
            "def notifications(", "def create_board(", "def admin_stats(",
            "def moderate_post(",
        ):
            self.assertIn(method, self.client)
        self.assertIn("self.client.boards(session)", self.desktop)
        self.assertIn("self.client.list_posts_v2(", self.desktop)
        self.assertIn("self.client.add_comment(", self.desktop)
        self.assertIn("self.client.moderate_post(", self.desktop)
        self.assertIn("self.client.admin_stats(", self.desktop)

    def test_mobile_has_full_forum_controls(self):
        for marker in (
            "community-boards", "community-search", "community-notifications",
            "list_community_posts_v2", "get_community_post",
            "add_community_comment", "toggle_community_like",
            "toggle_community_bookmark", "report_community_content",
            "create_community_board", "moderate_community_post",
            "list_knowledge_posts",
        ):
            self.assertIn(marker, self.mobile + self.markup)

    def test_unified_installer_contains_guarded_phase_six(self):
        compact = " ".join(self.unified.lower().split())
        self.assertIn("phase 6: community forum foundation", compact)
        self.assertIn("community-forum-v1.sql", compact)
        self.assertIn("community_installer", compact)
        self.assertIn("community_boards", compact)


if __name__ == "__main__":
    unittest.main()
