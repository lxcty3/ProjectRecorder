import unittest
from unittest.mock import patch

from community_client import CommunityClient, CommunitySession


class ExecutionClientTest(unittest.TestCase):
    def setUp(self):
        self.session = CommunitySession("token", expires_at=9999999999)
        self.client = CommunityClient()

    @patch("community_client._request")
    def test_board_defaults_to_empty_rpc_body(self, request):
        request.return_value = {"acceptance": []}
        self.assertEqual(
            self.client.execution_board(self.session), {"acceptance": []}
        )
        request.assert_called_once_with(
            "POST",
            "/rest/v1/rpc/get_execution_board",
            token="token",
            body={},
        )

    @patch("community_client._request")
    def test_board_passes_enterprise(self, request):
        request.return_value = {"ok": True}
        self.client.execution_board(self.session, enterprise_id="e1")
        self.assertEqual(
            request.call_args.kwargs["body"], {"p_enterprise": "e1"}
        )

    @patch("community_client._request")
    def test_submit_and_review_acceptance(self, request):
        request.return_value = {"ok": True}
        self.client.submit_task_acceptance(
            self.session, "t1", "tests pass", "commit abc", "u2", "submit"
        )
        self.assertEqual(
            request.call_args.kwargs["body"],
            {
                "p_task": "t1",
                "p_criteria": "tests pass",
                "p_evidence": "commit abc",
                "p_reviewer": "u2",
                "p_note": "submit",
            },
        )
        self.client.review_task_acceptance(
            self.session, "t1", "accepted", "verified"
        )
        request.assert_called_with(
            "POST",
            "/rest/v1/rpc/review_task_acceptance",
            token="token",
            body={"p_task": "t1", "p_decision": "accepted", "p_note": "verified"},
        )
        with self.assertRaises(ValueError):
            self.client.review_task_acceptance(
                self.session, "t1", "completed", "bypass"
            )

    @patch("community_client._request")
    def test_dependency_and_handoff_rpcs(self, request):
        request.return_value = {"ok": True}
        self.client.upsert_task_dependency(self.session, "t1", "t2", 2, True)
        self.assertEqual(
            request.call_args.kwargs["body"],
            {"p_task": "t1", "p_depends_on": "t2", "p_lag_days": 2,
             "p_required": True},
        )
        handoff = self.client.create_task_handoff(
            self.session, "t1", "u2", "build artifact", "review it"
        )
        self.assertEqual(handoff, {"ok": True})
        self.assertEqual(
            request.call_args.kwargs["body"],
            {"p_task": "t1", "p_to": "u2", "p_artifact": "build artifact",
             "p_note": "review it"},
        )
        self.client.accept_task_handoff(
            self.session, "h1", "rejected", "wrong artifact"
        )
        request.assert_called_with(
            "POST",
            "/rest/v1/rpc/accept_task_handoff",
            token="token",
            body={"p_handoff": "h1", "p_decision": "rejected",
                  "p_note": "wrong artifact"},
        )
        with self.assertRaises(ValueError):
            self.client.accept_task_handoff(
                self.session, "h1", "pending", ""
            )

    @patch("community_client._request")
    def test_change_rpcs_and_validation(self, request):
        request.return_value = {"ok": True, "change_id": "c1"}
        data = {
            "title": "Scope change",
            "scope": "Add API",
            "reason": "Client request",
            "urgency": "urgent",
            "schedule_impact_days": 5,
            "cost_impact": 60000,
            "resource_impact": "Two engineers",
            "cross_department": True,
        }
        self.client.create_change_request(self.session, "p1", data)
        self.assertEqual(
            request.call_args.kwargs["body"],
            {"p_project": "p1", "p_data": data},
        )
        self.client.decide_change_request(
            self.session, "c1", "approved", "authorized", "key-1"
        )
        request.assert_called_with(
            "POST",
            "/rest/v1/rpc/decide_change_request",
            token="token",
            body={"p_change": "c1", "p_decision": "approved",
                  "p_note": "authorized", "p_idempotency_key": "key-1"},
        )
        with self.assertRaises(ValueError):
            self.client.create_change_request(
                self.session, "p1", {"title": "incomplete"}
            )
        with self.assertRaises(ValueError):
            self.client.decide_change_request(
                self.session, "c1", "pending", "", "key-1"
            )


if __name__ == "__main__":
    unittest.main()
