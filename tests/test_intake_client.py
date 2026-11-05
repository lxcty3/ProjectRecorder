import unittest
from unittest.mock import patch

from community_client import CommunityClient, CommunitySession


class IntakeClientTest(unittest.TestCase):
    def setUp(self):
        self.session = CommunitySession("token", expires_at=9999999999)
        self.client = CommunityClient()

    @patch("community_client._request")
    def test_board_quick_capture_and_my_requests(self, request):
        request.return_value = {"ok": True}
        self.client.intake_board(self.session)
        request.assert_called_once_with(
            "POST", "/rest/v1/rpc/get_intake_board",
            token="token", body={},
        )
        data = {
            "title": "支付页面报错", "detail": "客户付款后看到空白页",
            "request_type": "incident", "urgency": 5,
        }
        self.client.create_intake_request(self.session, data)
        self.assertEqual(request.call_args.kwargs["body"], {"p_data": data})
        self.client.my_intake_requests(self.session)
        request.assert_called_with(
            "POST", "/rest/v1/rpc/get_my_intake_requests",
            token="token", body={},
        )

    @patch("community_client._request")
    def test_form_settings_and_alias(self, request):
        request.return_value = {"ok": True}
        self.client.create_intake_form(self.session, {"name": "Customer form"})
        self.assertEqual(
            request.call_args.kwargs["body"],
            {"p_data": {"name": "Customer form"}},
        )
        self.client.update_intake_form(self.session, "f1", {"active": False})
        self.assertEqual(
            request.call_args.kwargs["body"],
            {"p_form": "f1", "p_data": {"active": False}},
        )
        self.client.upsert_intake_settings(
            self.session, {"email_domain": "inbound.example.com"}
        )
        self.assertEqual(
            request.call_args.kwargs["body"],
            {"p_data": {"email_domain": "inbound.example.com"}},
        )
        self.client.create_intake_email_alias(self.session, "Website")
        self.assertEqual(request.call_args.kwargs["body"], {"p_label": "Website"})

    @patch("community_client._request")
    def test_triage_requires_reason_for_override(self, request):
        request.return_value = {"ok": True}
        with self.assertRaises(ValueError):
            self.client.triage_intake_request(
                self.session, "r1", priority_override=95, reason=""
            )
        self.client.triage_intake_request(
            self.session, "r1", owner_id="u2", request_type="incident",
            priority_override=95, reason="CEO escalation", status="in_progress",
        )
        self.assertEqual(
            request.call_args.kwargs["body"],
            {
                "p_request": "r1", "p_owner": "u2", "p_request_type": "incident",
                "p_priority_override": 95, "p_reason": "CEO escalation",
                "p_status": "in_progress",
            },
        )

    @patch("community_client._request")
    def test_messages_duplicates_merge_and_conversion(self, request):
        request.return_value = {"ok": True}
        self.client.add_intake_message(self.session, "r1", "已收到", True)
        self.assertEqual(
            request.call_args.kwargs["body"],
            {"p_request": "r1", "p_body": "已收到", "p_public": True},
        )
        with self.assertRaises(ValueError):
            self.client.add_intake_message(self.session, "r1", "", True)
        self.client.find_intake_duplicates(self.session, "r1", 3)
        self.assertEqual(
            request.call_args.kwargs["body"],
            {"p_request": "r1", "p_limit": 3},
        )
        self.client.merge_intake_request(self.session, "r1", "r2", "same issue")
        self.assertEqual(
            request.call_args.kwargs["body"],
            {"p_source": "r1", "p_target": "r2", "p_note": "same issue"},
        )
        self.client.convert_intake_request(
            self.session, "r1", "task",
            {"title": "修复", "project_id": "p1", "employee_id": "u1",
             "plan_date": "2026-11-06"},
        )
        self.assertEqual(
            request.call_args.kwargs["body"]["p_kind"], "task"
        )
        with self.assertRaises(ValueError):
            self.client.convert_intake_request(self.session, "r1", "task", {})

    @patch("community_client._request")
    def test_public_form_submission_and_status_use_anon_token(self, request):
        request.return_value = {"ok": True}
        self.client.public_intake_form("form-token")
        request.assert_called_once_with(
            "POST", "/rest/v1/rpc/get_public_intake_form",
            token="", body={"p_token": "form-token"},
        )
        self.client.submit_public_intake("form-token", {
            "title": "官网无法打开", "detail": "首页一直空白",
            "request_type": "incident", "requester_name": "王女士",
            "requester_email": "wang@example.com", "consent": True,
        })
        self.assertEqual(request.call_args.kwargs["body"]["p_token"], "form-token")
        self.client.public_intake_status("AB12CD34", "wang@example.com")
        self.assertEqual(
            request.call_args.kwargs["body"],
            {"p_tracking_code": "AB12CD34", "p_email": "wang@example.com"},
        )
        with self.assertRaises(ValueError):
            self.client.submit_public_intake("form-token", {"title": "x"})

    @patch("community_client._request")
    def test_email_ingestion_and_escalation(self, request):
        request.return_value = {"ok": True}
        self.client.ingest_intake_email(
            "alias-token", "client@example.com", "登录故障", "无法登录系统", "incident"
        )
        self.assertEqual(
            request.call_args.kwargs["body"],
            {
                "p_alias_token": "alias-token", "p_from": "client@example.com",
                "p_subject": "登录故障", "p_body": "无法登录系统",
                "p_request_type": "incident",
            },
        )
        self.client.intake_escalate_sla(self.session, "e1")
        self.assertEqual(
            request.call_args.kwargs["body"], {"p_enterprise": "e1"}
        )


if __name__ == "__main__":
    unittest.main()
