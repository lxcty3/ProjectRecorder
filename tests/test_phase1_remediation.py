import unittest
from pathlib import Path

from identity_rules import PermissionGrant, can_use_advanced_mode


ROOT = Path(__file__).resolve().parents[1]


def read(path):
    return (ROOT / path).read_text(encoding="utf-8")


class PhaseOneRemediationTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sql = read("mobile/sql/enterprise-governance-v2.sql")
        cls.community_sql = read("mobile/sql/community.sql")
        cls.identity_js = read("mobile/identity.js")
        cls.today_js = read("mobile/today.js")
        cls.main = read("main.py")
        cls.identity_ui = read("identity_ui.py")
        cls.role_ui = read("role_templates_ui.py")

    def lower(self, text):
        return text.lower()

    def function(self, name):
        marker = f"create or replace function public.{name}(".lower()
        start = self.sql.lower().rfind(marker)
        self.assertGreaterEqual(start, 0)
        return self.sql[start:].split("$fn$;", 1)[0]

    def test_advanced_mode_excludes_identity_view_everywhere(self):
        self.assertFalse(can_use_advanced_mode([PermissionGrant("identity.view")]))
        mobile = self.identity_js.split("function identityHasAdvancedAccess", 1)[1]
        mobile = mobile.split("function identityPercent", 1)[0]
        self.assertNotIn('"identity.view"', mobile)
        desktop = self.main.split("def _advanced_mode_allowed", 1)[1]
        desktop = desktop.split("def _effective_ui_mode", 1)[0]
        self.assertNotIn('"identity.view"', desktop)
        mode = self.function("set_enterprise_ui_mode")
        self.assertIn("advanced mode requires management, finance, audit or governance permission", mode)
        self.assertIn("_identity_can_use_advanced_mode", mode)

    def test_share_changes_use_major_motion_and_direct_rpc_is_internal(self):
        self.assertIn("propose_enterprise_share_change", self.sql)
        self.assertIn("'share_change'", self.sql)
        finalize = self.function("_identity_finalize_motion")
        self.assertIn("v_m.kind='share_change'", finalize)
        self.assertIn("v_m.payload->>'shares'", finalize)
        self.assertNotIn(
            "grant execute on function public.set_enterprise_shareholder(uuid,numeric) to authenticated",
            self.lower(self.sql),
        )
        self.assertIn("propose_share_change", self.identity_ui)
        self.assertIn("propose_enterprise_share_change", self.identity_js)

    def test_governance_state_is_privacy_gated_and_returns_mode(self):
        state = self.function("get_enterprise_identity_state")
        self.assertIn("v_can_read_governance", state)
        self.assertIn("'preferred_mode'", state)
        self.assertIn("'point_state',public.get_point_state()", state)
        self.assertIn("'members',case when v_can_read_governance", state)
        self.assertIn("'motions',case when v_can_read_governance", state)
        self.assertIn("'board_motions',case when v_can_read_governance", state)

    def test_board_and_point_workflows_are_wired(self):
        for text in ("create_board_motion", "cast_board_vote",
                     "finalize_board_motion", "award_points"):
            self.assertIn(text, self.identity_ui)
        self.assertIn("BoardPointPage", self.identity_ui)
        self.assertIn("董事长发放积分", self.identity_ui)
        self.assertIn("今天", read("today_ui.py"))
        self.assertIn("point_state", read("today_ui.py"))
        self.assertIn("board_motions", self.identity_js)
        self.assertIn("create_board_motion", self.identity_js)
        self.assertIn("award_points", self.identity_js)

    def test_four_dimensional_permission_editor_and_assignment_ui(self):
        for text in ("PermissionEditorDialog", "RoleAssignmentDialog",
                     "资源", "动作", "范围", "条件", "临时指派"):
            self.assertIn(text, self.role_ui)
        self.assertIn("propose_template_change", read("community_client.py"))
        self.assertIn("p_reason", read("community_client.py"))
        self.assertIn("set_role_assignment", self.role_ui)

    def test_cross_device_mode_memory_and_desktop_toggle(self):
        self.assertIn("'preferred_mode'", self.function("get_enterprise_identity_state"))
        self.assertIn("mode_button", self.main)
        self.assertIn("_toggle_ui_mode", self.main)
        self.assertIn("set_ui_mode", self.main)
        self.assertIn("data.me && data.me.preferred_mode", self.identity_js)

    def test_desktop_today_receives_cloud_tasks(self):
        collaboration = read("collaboration.py")
        self.assertIn("set_cloud_tasks(tasks)", collaboration)
        self.assertIn("set_cloud_tasks", read("today_ui.py"))
        self.assertIn("employee_cloud_page", read("today_ui.py"))

    def test_high_risk_template_changes_create_motions(self):
        for name in ("clone_role_template", "update_role_template"):
            definition = self.function(name)
            self.assertIn("_identity_create_shareholder_motion", definition)
            self.assertIn("'template_change'", definition)
            self.assertNotIn("raise exception 'high-risk template changes", definition)
        self.assertIn("propose_template_change", self.sql)

    def test_motion_duration_defaults_and_client_sync(self):
        helper = self.function("_identity_create_shareholder_motion")
        self.assertIn("when p_motion_class='major' then 5 else 3", helper)
        self.assertIn("IDENTITY_MAJOR_ROLES", self.identity_js)
        self.assertIn("_sync_days", self.identity_ui)
        self.assertIn("setValue(", self.identity_ui)

    def test_conflict_disclosure_is_returned_and_rendered(self):
        state = self.function("get_enterprise_identity_state")
        self.assertIn("'conflict_disclosed',x.conflict_disclosed", state)
        self.assertIn("'conflict_disclosed',bm.conflict_disclosed", state)
        self.assertIn("已披露利益冲突", self.identity_js)
        self.assertIn("已披露利益冲突", self.identity_ui)

    def test_temporary_assignment_guards(self):
        assignment = self.function("set_member_role_assignment")
        self.assertIn("temporary assignment cannot exceed 7 days", assignment)
        self.assertIn("temporary assignment reason is required", assignment)
        self.assertIn("only the CEO or enterprise owner", assignment)

    def test_paid_knowledge_is_discoverable_and_publishable(self):
        self.assertIn("list_knowledge_posts", self.sql)
        self.assertIn("'preview'", self.function("list_knowledge_posts"))
        self.assertIn("unlock_cost", self.community_sql)
        self.assertIn("p_unlock_cost", self.community_sql)
        self.assertIn("community-unlock-cost", read("mobile/index.html"))
        self.assertIn("unlock_cost", read("community_ui.py"))
        self.assertIn("unlock_requested", read("community_ui.py"))

    def test_proposals_require_active_membership(self):
        for name in ("propose_enterprise_role", "propose_enterprise_share_change"):
            definition = self.function(name)
            self.assertIn("_identity_is_member", definition)
            self.assertIn("active shareholders", definition)

    def test_test_dependencies_and_integration_opt_in(self):
        requirements = read("requirements.txt").lower()
        self.assertIn("psycopg2", requirements)
        self.assertIn("skipUnless", read("tests/test_enterprise_governance_integration.py"))
        self.assertIn("PROJECT_RECORDER_TEST_DATABASE_URL", read("tests/test_enterprise_governance_integration.py"))

    def test_carry_forward_adds_prior_remaining(self):
        apply_pool = self.function("_identity_apply_point_pool_motion")
        self.assertIn("v_carry_remaining:=v_carry_pool.remaining_amount", apply_pool)
        self.assertIn("v_total_with_carry:=v_total+v_carry_remaining", apply_pool)
        self.assertIn("v_total_with_carry,v_total_with_carry", apply_pool)

    def test_readme_deployment_order_and_implemented_scope(self):
        readme = read("README.md")
        deployment = readme.split("阶段一升级顺序", 1)[1].split("### 统一云端部署", 1)[0]
        identity = deployment.index("mobile/sql/enterprise-identity.sql")
        community = deployment.index("mobile/sql/community.sql")
        governance = deployment.index("mobile/sql/enterprise-governance-v2.sql")
        self.assertLess(identity, community)
        self.assertLess(community, governance)
        self.assertIn("阶段一升级顺序", readme)
        self.assertIn("服务端返回并保存 `preferred_mode`", readme)
        self.assertIn("普通员工仅有的 `identity.view`", readme)


if __name__ == "__main__":
    unittest.main()
