import unittest
from unittest.mock import patch

from community_client import CommunityClient, CommunitySession


class OperationsClientTest(unittest.TestCase):
    def setUp(self):
        self.session = CommunitySession("token", expires_at=9999999999)
        self.client = CommunityClient()

    @patch("community_client._request")
    def test_dashboard_defaults_to_empty_rpc_body(self, request):
        request.return_value = {"projects": []}
        result = self.client.operations_dashboard(self.session)
        self.assertEqual(result, {"projects": []})
        request.assert_called_once_with(
            "POST",
            "/rest/v1/rpc/get_operations_dashboard",
            token="token",
            body={},
        )

    @patch("community_client._request")
    def test_dashboard_passes_window_weeks(self, request):
        request.return_value = {"window_weeks": 2}
        self.client.operations_dashboard(self.session, weeks=2)
        self.assertEqual(request.call_args.kwargs["body"], {"p_weeks": 2})

    @patch("community_client._request")
    def test_upsert_economics(self, request):
        request.return_value = {"ok": True}
        self.client.upsert_project_economics(
            self.session, "p1", {"contract_amount": 100}
        )
        self.assertEqual(
            request.call_args.kwargs["body"]["p_project"], "p1"
        )
        self.assertEqual(
            request.call_args.kwargs["body"]["p_data"],
            {"contract_amount": 100},
        )

    @patch("community_client._request")
    def test_skill_and_capacity_methods(self, request):
        request.return_value = {"ok": True}
        self.client.upsert_profile_skill(
            self.session, "u1", "python", {"level": 4}
        )
        self.assertEqual(
            request.call_args.kwargs["body"],
            {"p_profile": "u1", "p_skill": "python", "p_data": {"level": 4}},
        )
        self.client.upsert_capacity_demand(
            self.session, None, {"skill": "python", "required_hours": 8}
        )
        self.assertEqual(
            request.call_args.kwargs["body"],
            {"p_demand": None,
             "p_data": {"skill": "python", "required_hours": 8}},
        )

    @patch("community_client._request")
    def test_worklog_dimensions_method(self, request):
        request.return_value = {"billable": False}
        result = self.client.upsert_worklog_dimensions(
            self.session,
            "w1",
            {"billable": False, "work_kind": "internal"},
        )
        self.assertEqual(result, {"billable": False})
        request.assert_called_once_with(
            "POST",
            "/rest/v1/rpc/upsert_worklog_dimensions",
            token="token",
            body={
                "p_worklog": "w1",
                "p_data": {"billable": False, "work_kind": "internal"},
            },
        )

    @patch("community_client._request")
    def test_performance_methods(self, request):
        request.return_value = {"ok": True}
        self.client.my_performance_evidence(self.session)
        request.assert_called_once_with(
            "POST",
            "/rest/v1/rpc/get_my_performance_evidence",
            token="token",
            body={},
        )
        self.client.submit_performance_statement(self.session, "e1", "evidence")
        self.assertEqual(
            request.call_args.kwargs["body"],
            {"p_evidence": "e1", "p_statement": "evidence"},
        )
        self.client.review_performance_evidence(self.session, "e1", "checked")
        self.assertEqual(
            request.call_args.kwargs["body"],
            {"p_evidence": "e1", "p_note": "checked"},
        )
        self.client.upsert_performance_evidence(
            self.session, "u1", "2026-11", {"on_time_rate": 0.9}
        )
        self.assertEqual(
            request.call_args.kwargs["body"],
            {"p_profile": "u1", "p_period": "2026-11",
             "p_data": {"on_time_rate": 0.9}},
        )


if __name__ == "__main__":
    unittest.main()
