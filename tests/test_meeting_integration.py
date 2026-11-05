import json
import os
import unittest
import uuid
from datetime import datetime, timedelta, timezone

try:
    import psycopg2
    from psycopg2.extras import register_uuid
    register_uuid()
except ImportError:  # pragma: no cover
    psycopg2 = None

TEST_DATABASE_URL = os.environ.get("PROJECT_RECORDER_TEST_DATABASE_URL", "")
SKIP_REASON = "PROJECT_RECORDER_TEST_DATABASE_URL is not set or psycopg2 is unavailable"


@unittest.skipUnless(TEST_DATABASE_URL and psycopg2, SKIP_REASON)
class ShareholderMeetingIntegrationTest(unittest.TestCase):
    def setUp(self):
        self.conn = psycopg2.connect(TEST_DATABASE_URL)
        self.conn.autocommit = False

    def tearDown(self):
        self.conn.rollback()
        self.conn.close()

    def _as(self, user_id, sql, params=()):
        with self.conn.cursor() as cur:
            claims = json.dumps({"sub": str(user_id), "role": "authenticated"})
            cur.execute(
                "select set_config('request.jwt.claim.sub',%s,true),"
                " set_config('request.jwt.claims',%s,true)",
                (str(user_id), claims),
            )
            cur.execute(sql, params)
            if cur.description:
                return cur.fetchone()

    def _fixture(self):
        owner = uuid.uuid4()
        shareholders = [uuid.uuid4() for _ in range(3)]
        with self.conn.cursor() as cur:
            for user_id, name in [(owner, "Owner")] + [
                (item, "Shareholder %d" % index) for index, item in enumerate(shareholders, 1)
            ]:
                cur.execute(
                    "insert into auth.users(id,email) values(%s,%s)",
                    (user_id, user_id.hex + "@meeting.test"),
                )
                cur.execute(
                    "update public.profiles set name=%s,role=%s,boss_id=%s where id=%s",
                    (name, "boss" if user_id == owner else "employee", None if user_id == owner else owner, user_id),
                )
        eid = self._as(owner, "select public._identity_bootstrap(%s)", (owner,))[0]
        for index, user_id in enumerate(shareholders, 1):
            with self.conn.cursor() as cur:
                cur.execute(
                    "insert into public.enterprise_members(enterprise_id,profile_id,role_key,status) "
                    "values(%s,%s,'employee','active') on conflict do nothing",
                    (eid, user_id),
                )
                cur.execute(
                    "insert into public.enterprise_shareholders(enterprise_id,profile_id,shares,updated_by) "
                    "values(%s,%s,%s,%s) on conflict (enterprise_id,profile_id) do update set shares=excluded.shares",
                    (eid, user_id, 20 + index, owner),
                )
        return eid, owner, shareholders

    def _future_at(self, days=1):
        return datetime.now(timezone.utc) + timedelta(days=days)

    def test_monthly_regular_meeting_is_created_once(self):
        eid, owner, _ = self._fixture()
        first = self._as(owner, "select public.get_shareholder_meetings(%s)", (eid,))[0]
        second = self._as(owner, "select public.get_shareholder_meetings(%s)", (eid,))[0]
        self.assertTrue(first["monthly_required"])
        regulars = [m for m in first["meetings"] if m["meeting_type"] == "regular"]
        self.assertEqual(len(regulars), 1)
        self.assertEqual(regulars[0]["status"], "scheduled")
        self.assertEqual(
            len([m for m in second["meetings"] if m["meeting_type"] == "regular"]), 1
        )

    def test_special_meeting_needs_headcount_majority_and_reason(self):
        eid, owner, shareholders = self._fixture()
        scheduled = self._future_at().isoformat()
        with self.assertRaises(psycopg2.Error):
            self._as(
                shareholders[0],
                "select public.initiate_shareholder_meeting('紧急会议','议题',%s,'')",
                (scheduled,),
            )
        created = self._as(
            shareholders[0],
            "select public.initiate_shareholder_meeting('紧急会议','议题',%s,'重大项目风险')",
            (scheduled,),
        )[0]
        self.assertEqual(created["status"], "pending_approval")
        self.assertEqual(created["yes_count"], 1)
        approved = self._as(
            shareholders[1],
            "select public.vote_shareholder_meeting(%s,'yes','')",
            (created["meeting_id"],),
        )[0]
        self.assertEqual(approved["status"], "pending_approval")
        approved = self._as(
            shareholders[2],
            "select public.vote_shareholder_meeting(%s,'yes','')",
            (created["meeting_id"],),
        )[0]
        self.assertEqual(approved["status"], "approved")

    def test_leave_is_recorded_and_completion_needs_executive(self):
        eid, owner, shareholders = self._fixture()
        board = self._as(owner, "select public.get_shareholder_meetings(%s)", (eid,))[0]
        regular = next(m for m in board["meetings"] if m["meeting_type"] == "regular")
        leave = self._as(
            shareholders[0],
            "select public.record_shareholder_meeting_attendance(%s,'leave','外地出差')",
            (regular["id"],),
        )[0]
        self.assertTrue(leave["ok"])
        refreshed = self._as(owner, "select public.get_shareholder_meetings(%s)", (eid,))[0]
        row = next(m for m in refreshed["meetings"] if m["id"] == regular["id"])
        leave_row = next(a for a in row["attendance"] if a["profile_id"] == str(shareholders[0]))
        self.assertEqual(leave_row["status"], "leave")
        self.assertEqual(leave_row["note"], "外地出差")
        with self.assertRaises(psycopg2.Error):
            self._as(shareholders[0], "select public.complete_shareholder_meeting(%s,'记录')", (regular["id"],))
        completed = self._as(
            owner,
            "select public.complete_shareholder_meeting(%s,'会议纪要')",
            (regular["id"],),
        )[0]
        self.assertEqual(completed["status"], "completed")


if __name__ == "__main__":
    unittest.main()
