import unittest
from datetime import date, datetime, timezone

import meeting_rules as rules


class MeetingRulesTest(unittest.TestCase):
    def test_headcount_majority(self):
        self.assertEqual(rules.majority_required(0), 0)
        self.assertEqual(rules.majority_required(1), 1)
        self.assertEqual(rules.majority_required(2), 2)
        self.assertEqual(rules.majority_required(3), 2)
        self.assertEqual(rules.majority_required(4), 3)
        self.assertTrue(rules.has_headcount_majority(2, 3))
        self.assertFalse(rules.has_headcount_majority(1, 2))

    def test_month_key_and_regular_meeting_compliance(self):
        month = rules.meeting_month(datetime(2026, 11, 18, tzinfo=timezone.utc))
        self.assertEqual(month, date(2026, 11, 1))
        meetings = [{
            "meeting_type": "regular", "meeting_month": "2026-11-01",
            "status": "scheduled",
        }]
        self.assertEqual(rules.month_compliance(meetings, month), "scheduled")
        self.assertEqual(rules.month_compliance([], month), "missing")

    def test_special_meeting_requires_reason_and_future_time(self):
        now = datetime(2026, 11, 5, 10, tzinfo=timezone.utc)
        base = {
            "title": "临时股东大会", "agenda": "审议紧急预算",
            "reason": "", "scheduled_at": "2026-11-06T10:00:00+00:00",
        }
        invalid = rules.validate_special_meeting(base, now)
        self.assertFalse(invalid["valid"])
        self.assertIn("reason", invalid["reason"])
        base["reason"] = "重大项目风险"
        valid = rules.validate_special_meeting(base, now)
        self.assertTrue(valid["valid"])
        base["scheduled_at"] = "2026-11-04T10:00:00+00:00"
        self.assertFalse(rules.validate_special_meeting(base, now)["valid"])

    def test_only_one_active_special_meeting_per_month(self):
        month = date(2026, 11, 1)
        meetings = [{
            "meeting_type": "special", "meeting_month": "2026-11-01",
            "status": "pending_approval",
        }]
        result = rules.can_initiate_special(meetings, month)
        self.assertFalse(result["valid"])
        meetings[0]["status"] = "rejected"
        self.assertTrue(rules.can_initiate_special(meetings, month)["valid"])

    def test_vote_counts_and_approval(self):
        votes = [
            {"choice": "yes"}, {"choice": "yes"}, {"choice": "no"},
            {"choice": "abstain"},
        ]
        counts = rules.count_votes(votes)
        self.assertEqual(counts, {"yes": 2, "no": 1, "abstain": 1})
        self.assertTrue(rules.has_headcount_majority(counts["yes"], 3))
        self.assertFalse(rules.has_headcount_majority(counts["yes"], 4))

    def test_attendance_leave_requires_note(self):
        self.assertTrue(rules.validate_attendance("attending", "")["valid"])
        invalid = rules.validate_attendance("leave", "")
        self.assertFalse(invalid["valid"])
        self.assertIn("note", invalid["reason"])
        valid = rules.validate_attendance("leave", "外地出差")
        self.assertTrue(valid["valid"])
        self.assertFalse(rules.validate_attendance("unknown", "")["valid"])

    def test_special_actions_follow_status_and_shareholder_identity(self):
        pending = {"status": "pending_approval", "meeting_type": "special"}
        actions = rules.meeting_actions(pending, is_shareholder=True, is_executive=False)
        self.assertTrue(actions["vote"])
        self.assertFalse(actions["attend"])
        scheduled = {"status": "scheduled", "meeting_type": "regular"}
        actions = rules.meeting_actions(scheduled, is_shareholder=True, is_executive=True)
        self.assertFalse(actions["vote"])
        self.assertTrue(actions["attend"])
        self.assertTrue(actions["complete"])
        actions = rules.meeting_actions(scheduled, is_shareholder=False, is_executive=False)
        self.assertFalse(actions["attend"])
        self.assertFalse(actions["complete"])

    def test_leave_summary(self):
        attendees = [
            {"status": "attending", "note": ""},
            {"status": "leave", "note": "病假"},
            {"status": "absent", "note": ""},
        ]
        summary = rules.attendance_summary(attendees)
        self.assertEqual(summary["attending"], 1)
        self.assertEqual(summary["leave"], 1)
        self.assertEqual(summary["absent"], 1)
        self.assertEqual(summary["leave_records"][0]["note"], "病假")

    def test_meeting_month_must_be_current_for_special(self):
        now = datetime(2026, 11, 5, tzinfo=timezone.utc)
        result = rules.validate_special_meeting({
            "title": "临时会", "agenda": "议题", "reason": "紧急事项",
            "scheduled_at": "2026-12-01T10:00:00+00:00",
        }, now)
        self.assertFalse(result["valid"])
        self.assertIn("current month", result["reason"])


if __name__ == "__main__":
    unittest.main()
