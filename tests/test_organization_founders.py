"""Static contracts for organization founding and founder equity."""

from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8-sig")


class OrganizationFounderContractTest(unittest.TestCase):
    def setUp(self):
        self.sql = read("mobile/sql/organization-founders-v1.sql")
        self.client = read("community_client.py")
        self.mobile = read("mobile/identity.js")
        self.desktop = read("organization_ui.py")
        self.unified = read("mobile/sql/install-unified.sql")

    def test_migration_is_ascii_and_has_core_objects(self):
        raw = (ROOT / "mobile/sql/organization-founders-v1.sql").read_bytes()
        self.assertTrue(all(byte < 128 for byte in raw))
        for table in (
            "organization_foundations", "organization_founder_invites",
            "organization_founders", "organization_share_lots",
            "organization_equity_motions", "organization_equity_votes",
            "organization_employee_pools", "organization_employee_grants",
            "organization_share_transfers",
        ):
            self.assertIn(f"create table if not exists public.{table}", self.sql)

    def test_required_rpcs_and_weight_rules(self):
        for rpc in (
            "list_my_organizations", "set_active_organization",
            "create_organization", "invite_organization_founder",
            "respond_organization_founder_invite", "get_organization_state",
            "propose_initial_split", "create_equity_motion",
            "cast_equity_vote", "cancel_equity_motion",
            "grant_employee_equity",
        ):
            self.assertIn(f"function public.{rpc}", self.sql)
        self.assertIn("voting_weight", self.sql)
        self.assertIn("1.1", self.sql)
        self.assertIn("weighted_4_5", self.sql)
        self.assertIn("founder_unanimous", self.sql)
        self.assertIn("employee_pool", self.sql)
        self.assertIn("share_transfer", self.sql)
        self.assertIn("p_preserve_original", self.sql)
        self.assertIn("v_original_units:=least", self.sql)
        self.assertNotIn("using (true)", self.sql.lower())

    def test_clients_and_both_uis_are_wired(self):
        for method in (
            "def organization_state(", "def create_organization(",
            "def invite_organization_founder(", "def propose_initial_split(",
            "def create_equity_motion(", "def cast_equity_vote(",
            "def grant_employee_equity(",
        ):
            self.assertIn(method, self.client)
        for marker in (
            "get_organization_state", "create_organization",
            "propose_initial_split", "cast_equity_vote",
            "employee_pool", "share_transfer",
        ):
            self.assertIn(marker, self.mobile)
        for marker in (
            "client.organization_state(", "client.create_organization(",
            "client.propose_initial_split(", "client.cast_equity_vote(",
            "employee_pool", "share_transfer",
        ):
            self.assertIn(marker, self.desktop)

    def test_unified_installer_has_phase_seven(self):
        compact = " ".join(self.unified.lower().split())
        self.assertIn("phase 7: organization founding and equity", compact)
        self.assertIn("organization-founders-v1.sql", compact)
        self.assertIn("organization_installer", compact)


if __name__ == "__main__":
    unittest.main()
