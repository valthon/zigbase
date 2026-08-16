import json
import unittest
from pathlib import Path


class MigrationBoundaryTest(unittest.TestCase):
    def test_bundle_and_public_signup_decision_are_declared(self):
        root = Path(__file__).resolve().parents[1]
        bundle = json.loads(
            (root / "migration/bundle/zigbase-pocketbase-bundle.json").read_text()
        )
        rules = json.loads((root / "security/public-rules.json").read_text())
        self.assertEqual(bundle["rowCounts"], {"members": 1, "posts": 2, "secrets": 1})
        self.assertIn("members.create", rules["rules"])


if __name__ == "__main__":
    unittest.main()
