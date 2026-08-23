"""Migration boundary checks for the Rails API cutover.

Dependency-free and offline: these assert what the bundle claims about itself, so they
run before a target exists. The live allow/deny and concealment semantics are exercised
against a running server by the rehearsal, not here.
"""

import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class MigrationBoundaryTest(unittest.TestCase):
    def setUp(self):
        self.report = json.loads((ROOT / "migration/bundle/report.json").read_text())
        self.schema = json.loads((ROOT / "migration/bundle/schema.json").read_text())

    def test_every_source_row_reached_the_bundle(self):
        counts = {c["collection"]: c["rows"] for c in self.report["collections"]}
        self.assertEqual(
            counts,
            {
                "clubs": 3,
                "comments": 3,
                "events": 3,
                "flags": 2,
                "memberships": 4,
                "notifications": 1,
                "posts": 4,
                "users": 4,
            },
        )

    def test_the_club_hidden_by_default_scope_still_migrated(self):
        rows = [
            json.loads(line)
            for line in (ROOT / "migration/bundle/data/clubs.ndjson")
            .read_text()
            .splitlines()
            if line
        ]
        # `default_scope { where(archived_at: nil) }`: Rails cannot see this row at
        # all, so a migration that read through the model would drop it silently.
        self.assertTrue(
            any(row.get("archived_at") for row in rows),
            "the archived club Rails hides must still reach the target",
        )

    def test_the_public_surface_is_exactly_what_was_reviewed(self):
        reviewed = json.loads((ROOT / "security/public-rules.json").read_text())
        public = {
            f"{c['name']}.{k[: -len('Rule')]}"
            for c in self.schema["collections"]
            for k, v in c.items()
            if k.endswith("Rule") and v == "@public"
        }
        self.assertEqual(public, set(reviewed["rules"]))

    def test_no_credential_or_ciphertext_left_the_source(self):
        for name in (
            "clubs",
            "comments",
            "events",
            "flags",
            "memberships",
            "notifications",
            "posts",
        ):
            text = (ROOT / f"migration/bundle/data/{name}.ndjson").read_text()
            self.assertNotIn("$2a$", text, f"a bcrypt digest reached {name}")
        users = (ROOT / "migration/bundle/auth/users.ndjson").read_text()
        self.assertNotIn("phone", users, "the encrypted attribute was retired")


if __name__ == "__main__":
    unittest.main()
