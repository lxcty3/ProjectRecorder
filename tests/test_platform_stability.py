"""Contracts for platform migration registry and diagnostics."""

from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]

class PlatformStabilityTest(unittest.TestCase):
    def setUp(self):
        self.sql = (ROOT / "mobile/sql/platform-stability-v1.sql").read_text(encoding="ascii")
        self.app = (ROOT / "mobile/app.js").read_text(encoding="utf-8-sig")
        self.sync = (ROOT / "mobile/sync.js").read_text(encoding="utf-8-sig")
        self.unified = (ROOT / "mobile/sql/install-unified.sql").read_text(encoding="utf-8-sig")

    def test_migration_registry_and_health_rpc(self):
        self.assertIn("create table if not exists public.app_migrations", self.sql)
        self.assertIn("function public.get_platform_health", self.sql)
        self.assertIn("function public.record_app_migration", self.sql)
        self.assertIn("database_ready", self.sql)
        self.assertIn("organization-founders-v1", self.sql)
        self.assertIn("phase 8: platform stability", " ".join(self.unified.lower().split()))

    def test_session_refresh_and_diagnostics_are_wired(self):
        self.assertIn("ensureFreshCloudSession", self.sync)
        self.assertIn("refreshSession", self.sync)
        self.assertIn("get_platform_health", self.app)
        self.assertIn("btn-system-diagnose", self.app)
        self.assertIn("system-health-result", self.app)

if __name__ == "__main__":
    unittest.main()
