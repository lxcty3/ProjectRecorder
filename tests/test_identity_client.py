import unittest
from unittest.mock import patch

from community_client import CommunityClient, CommunitySession


class IdentityClientTest(unittest.TestCase):
    def setUp(self):
        self.session = CommunitySession("token", expires_at=9999999999)
        self.client = CommunityClient()

    @patch("community_client._request")
    def test_role_templates(self, request):
        request.return_value = [{"key": "pm"}]
        self.assertEqual(self.client.role_templates(self.session), [{"key": "pm"}])
        request.assert_called_once_with(
            "POST", "/rest/v1/rpc/get_enterprise_role_templates",
            token="token", body={},
        )

    @patch("community_client._request")
    def test_role_templates_non_list_fallback(self, request):
        request.return_value = {"unexpected": True}
        self.assertEqual(self.client.role_templates(self.session), [])

    @patch("community_client._request")
    def test_clone_template(self, request):
        request.return_value = {"ok": True}
        self.client.clone_role_template(self.session, "src", "sales", "销售")
        request.assert_called_once_with(
            "POST", "/rest/v1/rpc/clone_role_template", token="token",
            body={
                "p_source_template": "src", "p_key": "sales", "p_name": "销售",
                "p_reason": "", "p_days": 5, "p_conflict_disclosed": False,
            },
        )

    @patch("community_client._request")
    def test_update_template(self, request):
        request.return_value = {"ok": True}
        permissions = [{"key": "projects.manage", "scope": "project"}]
        self.client.update_role_template(self.session, "t1", "项目经理", permissions)
        request.assert_called_once_with(
            "POST", "/rest/v1/rpc/update_role_template", token="token",
            body={
                "p_template": "t1", "p_name": "项目经理",
                "p_permissions": permissions, "p_reason": "",
                "p_days": 5, "p_conflict_disclosed": False,
            },
        )

    @patch("community_client._request")
    def test_set_role_assignment(self, request):
        request.return_value = {"ok": True}
        self.client.set_role_assignment(self.session, "u2", "t1", "2027-01-01T00:00:00Z")
        request.assert_called_once_with(
            "POST", "/rest/v1/rpc/set_member_role_assignment", token="token",
            body={
                "p_profile": "u2", "p_template": "t1",
                "p_ends_at": "2027-01-01T00:00:00Z", "p_reason": "",
            },
        )

    @patch("community_client._request")
    def test_propose_share_change(self, request):
        request.return_value = {"ok": True}
        self.client.propose_share_change(
            self.session, "u2", 12.5, "股权激励", conflict_disclosed=True
        )
        request.assert_called_once_with(
            "POST", "/rest/v1/rpc/propose_enterprise_share_change",
            token="token",
            body={
                "p_profile": "u2", "p_shares": 12.5,
                "p_reason": "股权激励", "p_days": 5,
                "p_conflict_disclosed": True,
            },
        )

    @patch("community_client._request")
    def test_propose_template_change(self, request):
        request.return_value = {"ok": True, "motion_required": True}
        permissions = [{"permission_key": "finance.manage"}]
        self.client.propose_template_change(
            self.session, "t1", "财务", permissions, "调整职责"
        )
        request.assert_called_once_with(
            "POST", "/rest/v1/rpc/propose_template_change",
            token="token",
            body={
                "p_template": "t1", "p_name": "财务",
                "p_permissions": permissions, "p_reason": "调整职责",
                "p_days": 5, "p_conflict_disclosed": False,
            },
        )

    @patch("community_client._request")
    def test_create_board_motion(self, request):
        request.return_value = {"ok": True}
        payload = {"quarter": "2026-Q4", "total": 100}
        self.client.create_board_motion(self.session, "积分池", "point_pool", payload)
        request.assert_called_once_with(
            "POST", "/rest/v1/rpc/create_board_motion", token="token",
            body={
                "p_title": "积分池", "p_kind": "point_pool",
                "p_payload": payload, "p_conflict_disclosed": False,
            },
        )

    @patch("community_client._request")
    def test_cast_board_vote(self, request):
        request.return_value = {"ok": True}
        self.client.cast_board_vote(self.session, "m1", "yes")
        request.assert_called_once_with(
            "POST", "/rest/v1/rpc/cast_board_vote", token="token",
            body={"p_motion": "m1", "p_choice": "yes"},
        )

    @patch("community_client._request")
    def test_finalize_board_motion(self, request):
        request.return_value = {"ok": True, "status": "passed"}
        self.client.finalize_board_motion(self.session, "m1")
        request.assert_called_once_with(
            "POST", "/rest/v1/rpc/finalize_board_motion", token="token",
            body={"p_motion": "m1"},
        )

    @patch("community_client._request")
    def test_point_state(self, request):
        request.return_value = {"balance": 50, "pool": {"total": 100}}
        self.assertEqual(
            self.client.point_state(self.session),
            {"balance": 50, "pool": {"total": 100}},
        )
        request.assert_called_once_with(
            "POST", "/rest/v1/rpc/get_point_state", token="token", body={},
        )

    @patch("community_client._request")
    def test_point_state_non_dict_fallback(self, request):
        request.return_value = []
        self.assertEqual(self.client.point_state(self.session), {})

    @patch("community_client._request")
    def test_award_points(self, request):
        request.return_value = {"ok": True}
        self.client.award_points(self.session, "u2", 50, "acceptance", "e1", "验收通过")
        request.assert_called_once_with(
            "POST", "/rest/v1/rpc/award_points", token="token",
            body={"p_profile": "u2", "p_amount": 50,
                  "p_evidence_type": "acceptance", "p_evidence_id": "e1",
                  "p_reason": "验收通过"},
        )

    @patch("community_client._request")
    def test_unlock_knowledge(self, request):
        request.return_value = {"unlocked": True}
        self.client.unlock_knowledge(self.session, "post-1")
        request.assert_called_once_with(
            "POST", "/rest/v1/rpc/unlock_knowledge_content", token="token",
            body={"p_post": "post-1"},
        )

    @patch("community_client._request")
    def test_mode_validation(self, request):
        with self.assertRaises(ValueError):
            self.client.set_ui_mode(self.session, "complex")
        request.assert_not_called()

    @patch("community_client._request")
    def test_set_ui_mode(self, request):
        request.return_value = {"ok": True, "mode": "advanced"}
        self.client.set_ui_mode(self.session, "advanced")
        request.assert_called_once_with(
            "POST", "/rest/v1/rpc/set_enterprise_ui_mode", token="token",
            body={"p_mode": "advanced"},
        )


if __name__ == "__main__":
    unittest.main()
