import unittest
from pathlib import Path

import pglast


class MeetingSqlTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.path = Path("mobile/sql/shareholder-meetings-v1.sql")
        cls.sql = cls.path.read_text(encoding="utf-8") if cls.path.exists() else ""
        cls.lowered = cls.sql.lower()

    def test_parse_ascii_and_balanced_bodies(self):
        self.assertTrue(self.sql, "shareholder-meetings-v1.sql is missing")
        pglast.parse_sql(self.sql)
        self.assertTrue(all(ord(ch) < 128 for ch in self.sql))
        self.assertNotIn("`n", self.sql)

    def test_required_tables(self):
        for name in (
            "shareholder_meetings", "shareholder_meeting_votes",
            "shareholder_meeting_attendance",
        ):
            self.assertIn(name, self.lowered)

    def test_required_rpcs(self):
        for name in (
            "get_shareholder_meetings", "initiate_shareholder_meeting",
            "vote_shareholder_meeting", "record_shareholder_meeting_attendance",
            "complete_shareholder_meeting",
        ):
            self.assertIn(name, self.lowered)

    def test_meeting_contract_and_month_uniqueness(self):
        for fragment in (
            "meeting_type text not null",
            "check (meeting_type in ('regular','special'))",
            "meeting_month date not null",
            "status text not null",
            "pending_approval",
            "scheduled",
            "completed",
            "unique index if not exists shareholder_meetings_one_regular_idx",
            "where meeting_type='regular'",
            "unique index if not exists shareholder_meetings_one_special_idx",
            "where meeting_type='special'",
            "approval_threshold_bps integer not null default 5001",
        ):
            self.assertIn(fragment, self.lowered)

    def test_headcount_majority_and_reason(self):
        for fragment in (
            "v_yes*2>v_total",
            "special meeting reason required",
            "only shareholders may initiate",
            "current month",
            "one active special meeting already exists",
        ):
            self.assertIn(fragment, self.lowered)

    def test_attendance_leave_requires_note(self):
        for fragment in (
            "leave_note text not null default ''",
            "attendance_status text not null default 'pending'",
            "check (attendance_status in ('pending','attending','absent','leave'))",
            "leave note required",
            "record_shareholder_meeting_attendance",
        ):
            self.assertIn(fragment, self.lowered)

    def test_least_privilege_and_audit(self):
        for table in (
            "shareholder_meetings", "shareholder_meeting_votes",
            "shareholder_meeting_attendance",
        ):
            self.assertIn(f"revoke all on table public.{table}", self.lowered)
        self.assertIn("security definer", self.lowered)
        self.assertIn("enterprise_identity_audit", self.lowered)
        self.assertIn("grant execute on function public.get_shareholder_meetings", self.lowered)
        self.assertIn("to authenticated", self.lowered)

    def test_unified_installer_has_guarded_block(self):
        installer = Path("mobile/sql/install-unified.sql").read_text(encoding="utf-8")
        self.assertIn("shareholder-meetings-v1.sql", installer)
        self.assertIn("shareholder_meetings", installer.lower())


if __name__ == "__main__":
    unittest.main()
