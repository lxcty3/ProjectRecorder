import os
import unittest
from pathlib import Path
from unittest.mock import patch

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PyQt6.QtWidgets import QApplication

from community_client import CommunityClient, CommunitySession
from meeting_ui import ShareholderMeetingPage


class MeetingUiTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = QApplication.instance() or QApplication([])

    def _snapshot(self):
        return {
            "month_status": "scheduled",
            "total_shareholders": 3,
            "special_pending": 1,
            "access": {"can_initiate_special": True, "can_complete": True, "is_shareholder": True},
            "meetings": [
                {
                    "id": "m1", "meeting_type": "regular", "title": "11月例会",
                    "scheduled_at": "2026-11-30T10:00:00Z", "status": "scheduled",
                    "yes_count": 0, "eligible_count": 3,
                    "attendance": [
                        {"profile_id": "u1", "name": "股东甲", "status": "attending", "note": ""},
                        {"profile_id": "u2", "name": "股东乙", "status": "leave", "note": "出差"},
                    ],
                    "actions": {"vote": False, "attend": True, "complete": True},
                },
                {
                    "id": "m2", "meeting_type": "special", "title": "临时风险会",
                    "scheduled_at": "2026-11-20T10:00:00Z", "status": "pending_approval",
                    "yes_count": 1, "eligible_count": 3,
                    "attendance": [],
                    "actions": {"vote": True, "attend": False, "complete": False},
                },
            ],
        }

    def test_render_and_actions(self):
        page = ShareholderMeetingPage(None)
        page.snapshot = self._snapshot()
        page.render()
        self.assertEqual(page.meeting_table.rowCount(), 2)
        self.assertTrue(page.initiate_button.isEnabled())
        self.assertIn("股东 3 人", page.month_label.text())
        page.meeting_table.selectRow(0)
        self.assertTrue(page.attend_button.isEnabled())
        self.assertTrue(page.complete_button.isEnabled())
        self.assertFalse(page.yes_button.isEnabled())
        self.assertIn("出差", page.detail_label.text())
        page.meeting_table.selectRow(1)
        self.assertTrue(page.yes_button.isEnabled())
        self.assertFalse(page.attend_button.isEnabled())

    def test_vote_and_leave_call_real_rpcs(self):
        page = ShareholderMeetingPage(None)
        page.session = CommunitySession("token", expires_at=9999999999)
        captured = {}
        page._activate = lambda work: captured.update(work=work)
        page.snapshot = self._snapshot()
        page.render()
        page.meeting_table.selectRow(1)
        with patch.object(CommunityClient, "vote_shareholder_meeting", return_value={"ok": True}) as vote:
            page._vote("yes")
            self.assertEqual(captured["work"](), {"ok": True})
            self.assertEqual(vote.call_args.args[1:], ("m2", "yes"))
        page.meeting_table.selectRow(0)
        with patch("meeting_ui.QInputDialog.getMultiLineText", return_value=("外地出差", True)):
            with patch.object(
                CommunityClient, "record_shareholder_meeting_attendance",
                return_value={"ok": True},
            ) as attendance:
                page._attendance("leave")
                self.assertEqual(captured["work"](), {"ok": True})
                self.assertEqual(attendance.call_args.args[1:], ("m1", "leave", "外地出差"))

    def test_identity_page_contains_meeting_tab(self):
        source = Path("identity_ui.py").read_text(encoding="utf-8")
        self.assertIn("from meeting_ui import ShareholderMeetingPage", source)
        self.assertIn("self.meeting_page = ShareholderMeetingPage", source)
        self.assertIn('"股东大会"', source)
        self.assertIn("self.meeting_page.refresh()", source)


if __name__ == "__main__":
    unittest.main()
