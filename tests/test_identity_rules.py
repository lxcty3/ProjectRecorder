import unittest
from datetime import datetime, timedelta, timezone
from identity_rules import (
    PermissionGrant, can_manage_template, can_use_advanced_mode,
    evaluate_vote, has_permission, merge_permissions, motion_class,
    point_balance, required_threshold_bps,
)

class IdentityRulesTest(unittest.TestCase):
    def test_expired_grant_is_ignored(self):
        now = datetime(2026, 11, 3, tzinfo=timezone.utc)
        grants = [PermissionGrant("projects.manage", expires_at=now - timedelta(seconds=1))]
        self.assertFalse(has_permission(grants, "projects.manage", now))
        self.assertEqual(merge_permissions(grants, now), {})

    def test_high_risk_forces_major(self):
        self.assertEqual(motion_class(["projects.manage"]), "ordinary")
        self.assertEqual(motion_class(["finance.manage"]), "major")
        self.assertEqual(required_threshold_bps("ordinary"), 5001)
        self.assertEqual(required_threshold_bps("major"), 6667)

    def test_ordinary_vote(self):
        result = evaluate_vote(100, 30, 20, 0, 5000, 5001)
        self.assertTrue(result.passed)
        self.assertEqual((result.turnout_bps, result.approval_bps), (5000, 6000))

    def test_major_vote_needs_two_thirds_of_all_shares(self):
        result = evaluate_vote(100, 60, 40, 0, 0, 6667)
        self.assertFalse(result.passed)
        self.assertEqual(result.approval_bps, 6000)

    def test_admin_cannot_edit_self_or_overgrant(self):
        actor = [PermissionGrant("people.manage")]
        self.assertFalse(can_manage_template("u1", "u1", actor, ["people.manage"]))
        self.assertFalse(can_manage_template("u1", "u2", actor, ["finance.manage"]))
        self.assertTrue(can_manage_template("u1", "u2", actor, ["people.manage"]))

    def test_modes_and_points(self):
        self.assertFalse(can_use_advanced_mode([PermissionGrant("community.post")]))
        self.assertTrue(can_use_advanced_mode([PermissionGrant("projects.manage")]))
        self.assertEqual(point_balance([{"amount": 100}, {"amount": -30}]), 70)

if __name__ == "__main__":
    unittest.main()
