import unittest
from pathlib import Path

import pglast


class IntakeSqlTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.path = Path("mobile/sql/work-intake-v1.sql")
        cls.sql = cls.path.read_text(encoding="utf-8") if cls.path.exists() else ""
        cls.lowered = cls.sql.lower()

    def test_parse_ascii_and_balanced_bodies(self):
        self.assertTrue(self.sql, "work-intake-v1.sql is missing")
        pglast.parse_sql(self.sql)
        self.assertTrue(all(ord(ch) < 128 for ch in self.sql))

    def test_required_tables(self):
        for name in (
            "intake_forms", "intake_requests", "intake_messages",
            "intake_links", "intake_events", "intake_security_audit",
            "intake_submission_attempts", "intake_email_aliases",
            "intake_notifications", "intake_settings", "intake_conversions",
            "presales_opportunities",
        ):
            self.assertIn(name, self.lowered)

    def test_required_rpcs_and_public_grants(self):
        for name in (
            "create_intake_form", "update_intake_form", "get_intake_board",
            "get_my_intake_requests", "create_intake_request",
            "submit_public_intake", "get_public_intake_form",
            "get_public_intake_status", "ingest_intake_email",
            "triage_intake_request", "add_intake_message",
            "find_intake_duplicates", "merge_intake_request",
            "convert_intake_request", "create_intake_email_alias",
            "upsert_intake_settings", "intake_escalate_sla",
        ):
            self.assertIn(name, self.lowered)
        self.assertIn("grant execute on function public.submit_public_intake", self.lowered)
        self.assertIn("grant execute on function public.get_public_intake_status", self.lowered)
        self.assertIn("to anon, authenticated", self.lowered)

    def test_public_privacy_and_email_tracking_gate(self):
        for fragment in (
            "tracking_code", "requester_email", "visibility in ('public','internal','system')",
            "lower(btrim(requester_email))=lower(btrim(coalesce(p_email,'')))",
            "m.visibility='public'", "internal_note", "reply-to",
            "rate limit", "intake_submission_attempts",
        ):
            self.assertIn(fragment, self.lowered)
        public_status = self.lowered.split(
            "create or replace function public.get_public_intake_status", 1
        )[1].split("create or replace function public.ingest_intake_email", 1)[0]
        self.assertNotIn("owner_profile_id", public_status)
        self.assertNotIn("linked_project_id", public_status)
        self.assertNotIn("priority_factors", public_status)

    def test_sla_and_priority_contract(self):
        for fragment in (
            "interval '2 hours'", "interval '1 day'", "interval '3 days'",
            "sla_due_at", "business_value", "urgency", "risk",
            "dependency_impact", "effort", "priority_factors",
            "priority_override_reason", "escalated_at",
            "_intake_escalate_due", "intake_escalate_sla",
        ):
            self.assertIn(fragment, self.lowered)

    def test_duplicate_merge_preserves_sources_and_messages(self):
        for fragment in (
            "merged_into_id", "intake_links", "source_request_id",
            "insert into public.intake_messages", "merged", "never delete",
            "merge_intake_request", "find_intake_duplicates",
        ):
            self.assertIn(fragment, self.lowered)

    def test_conversion_links_do_not_break_chain(self):
        for fragment in (
            "linked_project_id", "linked_task_id", "converted_kind",
            "converted_at", "presales_opportunities", "intake_conversions",
            "insert into public.projects", "insert into public.tasks", "conversion.",
        ):
            self.assertIn(fragment, self.lowered)

    def test_direct_writes_are_revoked_and_functions_audited(self):
        for table in (
            "intake_forms", "intake_requests", "intake_messages",
            "intake_links", "intake_events", "intake_notifications",
            "intake_conversions", "presales_opportunities",
        ):
            self.assertIn(f"revoke all on table public.{table}", self.lowered)
        self.assertIn("_intake_success", self.lowered)
        self.assertIn("_intake_denied", self.lowered)
        self.assertIn("security definer", self.lowered)

    def test_unified_installer_has_guarded_phase_four_block(self):
        installer = Path("mobile/sql/install-unified.sql").read_text(encoding="utf-8")
        self.assertIn("Phase 4: work intake", installer)
        self.assertIn("work-intake-v1.sql", installer)
        self.assertIn("intake_requests", installer.lower())


if __name__ == "__main__":
    unittest.main()
