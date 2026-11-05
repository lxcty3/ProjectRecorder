import unittest
from unittest.mock import patch

from community_client import CommunityClient, CommunitySession


class MeetingClientTest(unittest.TestCase):
    def setUp(self):
        self.session = CommunitySession("token", expires_at=9999999999)
        self.client = CommunityClient()

    @patch("community_client._request")
    def test_meeting_board_and_enterprise(self, request):
        request.return_value = {"ok": True, "meetings": []}
        self.client.shareholder_meetings(self.session)
        request.assert_called_once_with(
            "POST", "/rest/v1/rpc/get_shareholder_meetings",
            token="token", body={},
        )
        self.client.shareholder_meetings(self.session, "e1")
        self.assertEqual(request.call_args.kwargs["body"], {"p_enterprise": "e1"})

    @patch("community_client._request")
    def test_initiate_special_meeting(self, request):
        request.return_value = {"ok": True, "status": "pending_approval"}
        with self.assertRaises(ValueError):
            self.client.initiate_shareholder_meeting(
                self.session, "临时会议", "议题", "2026-11-06T10:00:00+08:00", ""
            )
        self.client.initiate_shareholder_meeting(
            self.session, "临时会议", "议题", "2026-11-06T10:00:00+08:00", "紧急风险"
        )
        self.assertEqual(
            request.call_args.kwargs["body"],
            {
                "p_title": "临时会议", "p_agenda": "议题",
                "p_scheduled_at": "2026-11-06T10:00:00+08:00",
                "p_reason": "紧急风险",
            },
        )

    @patch("community_client._request")
    def test_vote_and_attendance(self, request):
        request.return_value = {"ok": True}
        self.client.vote_shareholder_meeting(self.session, "m1", "yes", "支持")
        self.assertEqual(
            request.call_args.kwargs["body"],
            {"p_meeting": "m1", "p_choice": "yes", "p_note": "支持"},
        )
        with self.assertRaises(ValueError):
            self.client.vote_shareholder_meeting(self.session, "m1", "maybe")
        with self.assertRaises(ValueError):
            self.client.record_shareholder_meeting_attendance(
                self.session, "m1", "leave", ""
            )
        self.client.record_shareholder_meeting_attendance(
            self.session, "m1", "leave", "出差"
        )
        self.assertEqual(
            request.call_args.kwargs["body"],
            {"p_meeting": "m1", "p_status": "leave", "p_note": "出差"},
        )

    @patch("community_client._request")
    def test_complete_meeting(self, request):
        request.return_value = {"ok": True, "status": "completed"}
        self.client.complete_shareholder_meeting(self.session, "m1", "会议纪要")
        self.assertEqual(
            request.call_args.kwargs["body"],
            {"p_meeting": "m1", "p_minutes": "会议纪要"},
        )
        with self.assertRaises(ValueError):
            self.client.complete_shareholder_meeting(self.session, "m1", "")


if __name__ == "__main__":
    unittest.main()
