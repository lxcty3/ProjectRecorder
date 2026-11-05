import unittest

from decision_rules import (
    DecisionSignals,
    approval_permissions,
    approval_required_level,
    can_act_on_approval,
    can_open_decision_center,
    normalize_approval_action,
    normalize_decision_status,
    normalize_risk,
    score_decision,
)


class DecisionRulesTest(unittest.TestCase):
    def test_high_delivery_impact_outranks_low_value(self):
        high = DecisionSignals(
            delivery_days=12, amount=0, risk="严重", waiting_days=1
        )
        low = DecisionSignals(
            delivery_days=1, amount=50000, risk="健康", waiting_days=1
        )
        self.assertGreater(score_decision(high), score_decision(low))

    def test_amount_and_risk_raise_approval_level(self):
        self.assertEqual(approval_required_level(1000, "健康"), "manager")
        self.assertEqual(approval_required_level(60000, "关注"), "executive")
        self.assertEqual(approval_required_level(0, "严重"), "executive")
        self.assertEqual(approval_required_level(50000, "健康"), "executive")

    def test_negative_signals_do_not_reduce_priority(self):
        negative = DecisionSignals(
            delivery_days=-20, amount=-100000, risk="健康", waiting_days=-3
        )
        empty = DecisionSignals()
        self.assertEqual(score_decision(negative), score_decision(empty))

    def test_risk_aliases_are_normalized(self):
        self.assertEqual(normalize_risk("severe"), "严重")
        self.assertEqual(normalize_risk(" HIGH "), "风险")
        self.assertEqual(normalize_risk("attention"), "关注")
        self.assertEqual(normalize_risk(None), "健康")
        self.assertEqual(normalize_risk("unexpected"), "关注")

    def test_decision_status_is_closed_enum(self):
        self.assertEqual(normalize_decision_status(" RESOLVED "), "resolved")
        self.assertEqual(normalize_decision_status("deferred"), "deferred")
        self.assertEqual(normalize_decision_status("deleted"), "open")
        self.assertEqual(normalize_decision_status(None), "open")

    def test_approval_actions_are_normalized(self):
        self.assertEqual(normalize_approval_action("approve"), "approved")
        self.assertEqual(normalize_approval_action("reject"), "rejected")
        self.assertEqual(normalize_approval_action("return"), "returned")
        self.assertEqual(normalize_approval_action("cancel"), "cancelled")
        self.assertEqual(normalize_approval_action("other"), "")

    def test_approval_permissions_are_kind_specific(self):
        self.assertEqual(approval_permissions("leave"), ("leave.approve",))
        self.assertEqual(approval_permissions("worklog"), ("worklogs.approve",))
        self.assertEqual(approval_permissions("reward"), ("rewards.manage",))
        self.assertEqual(
            approval_permissions("task_extension"), ("tasks.grade", "tasks.assign")
        )
        self.assertIn("governance.vote", approval_permissions("identity_motion"))
        self.assertEqual(approval_permissions("unknown"), ())

    def test_approval_action_requires_matching_identity(self):
        self.assertTrue(
            can_act_on_approval({"leave.approve"}, "leave", "approved")
        )
        self.assertFalse(
            can_act_on_approval({"projects.manage"}, "leave", "approved")
        )
        self.assertTrue(
            can_act_on_approval(
                set(), "identity_motion", "cancelled", is_requester=True
            )
        )
        self.assertFalse(
            can_act_on_approval(
                set(), "identity_motion", "cancelled", is_requester=False
            )
        )

    def test_decision_center_is_advanced_management_only(self):
        self.assertTrue(can_open_decision_center({"finance.view"}))
        self.assertTrue(can_open_decision_center({"projects.manage"}))
        self.assertTrue(can_open_decision_center({"audit.read"}))
        self.assertTrue(can_open_decision_center({"governance.vote"}))
        self.assertFalse(can_open_decision_center({"community.post"}))
        self.assertFalse(can_open_decision_center({"identity.view"}))
        self.assertFalse(can_open_decision_center(set()))


if __name__ == "__main__":
    unittest.main()
