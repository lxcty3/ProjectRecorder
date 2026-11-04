import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from community_client import CommunityClient


class GovernanceClientContractTest(unittest.TestCase):
    def test_propose_role_change_sends_conflict_disclosure(self):
        session = SimpleNamespace(access_token="test-token")
        for disclosed in (False, True):
            with self.subTest(disclosed=disclosed):
                with patch(
                    "community_client._request",
                    return_value={"ok": True},
                ) as request:
                    CommunityClient().propose_role_change(
                        session,
                        "profile-id",
                        "appointment",
                        role_key="project_manager",
                        conflict_disclosed=disclosed,
                    )
                kwargs = request.call_args.kwargs
                self.assertEqual(kwargs["token"], "test-token")
                self.assertIs(
                    kwargs["body"]["p_conflict_disclosed"],
                    disclosed,
                )

    def test_mobile_motion_sheet_sends_conflict_disclosure(self):
        for path in (
            Path("mobile/identity.js"),
            Path("mobile/www/identity.js"),
        ):
            with self.subTest(path=path):
                source = path.read_text(encoding="utf-8")
                self.assertIn('id="id-conflict-disclosed"', source)
                self.assertIn('type="checkbox"', source)
                self.assertIn(
                    '$("id-conflict-disclosed").checked',
                    source,
                )
                self.assertIn(
                    "p_conflict_disclosed:",
                    source,
                )

    def test_desktop_role_motion_dialog_has_conflict_disclosure(self):
        source = Path("identity_ui.py").read_text(encoding="utf-8")
        self.assertIn("QCheckBox", source)
        self.assertIn("self.conflict_box = QCheckBox(", source)
        self.assertIn(
            '"conflict_disclosed": self.conflict_box.isChecked()',
            source,
        )
        self.assertIn(
            'conflict_disclosed=data["conflict_disclosed"]',
            source,
        )


if __name__ == "__main__":
    unittest.main()
