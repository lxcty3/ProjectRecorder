import unittest
from unittest.mock import patch

from community_client import CommunityClient, CommunitySession


class DecisionClientTest(unittest.TestCase):
    def setUp(self):
        self.session = CommunitySession("token", expires_at=9999999999)
        self.client = CommunityClient()

    @patch("community_client._request")
    def test_decision_center_rpc(self, request):
        request.return_value = {"decisions": [], "approvals": []}
        self.assertEqual(
            self.client.decision_center(self.session),
            {"decisions": [], "approvals": []},
        )
        request.assert_called_once_with(
            "POST", "/rest/v1/rpc/get_decision_center",
            token="token", body={},
        )

    @patch("community_client._request")
    def test_decision_center_non_dict_fallback(self, request):
        request.return_value = []
        self.assertEqual(self.client.decision_center(self.session), {})

    @patch("community_client._request")
    def test_decision_action(self, request):
        request.return_value = {"ok": True, "status": "assigned"}
        self.client.act_on_decision(
            self.session, "d1", "assigned", owner_id="u2",
            note="请处理", idempotency_key="k1",
        )
        request.assert_called_once_with(
            "POST", "/rest/v1/rpc/act_on_decision",
            token="token",
            body={
                "p_decision": "d1", "p_action": "assigned",
                "p_owner": "u2", "p_note": "请处理",
                "p_idempotency_key": "k1",
            },
        )

    @patch("community_client._request")
    def test_approval_action(self, request):
        request.return_value = {"ok": True}
        self.client.act_on_approval(
            self.session, "a1", "approve", "同意", "k1"
        )
        request.assert_called_once_with(
            "POST", "/rest/v1/rpc/act_on_approval", token="token",
            body={"p_approval": "a1", "p_action": "approved",
                  "p_note": "同意", "p_idempotency_key": "k1"},
        )

    @patch("community_client._request")
    def test_actions_validate_and_generate_idempotency_keys(self, request):
        request.return_value = {"ok": True}
        with self.assertRaises(ValueError):
            self.client.act_on_decision(
                self.session, "d1", "delete", idempotency_key="k1"
            )
        with self.assertRaises(ValueError):
            self.client.act_on_approval(
                self.session, "a1", "delete", idempotency_key="k1"
            )
        self.client.act_on_approval(self.session, "a1", "approve")
        key = request.call_args.kwargs["body"]["p_idempotency_key"]
        self.assertTrue(key)
        self.assertNotEqual(key, "")


if __name__ == "__main__":
    unittest.main()
