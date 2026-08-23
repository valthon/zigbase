Use the installed `$zigbase-migrate-rails-api` skill to migrate the frozen Rails 8.1 API-only
snapshot in `source/` to ZigBase. Work entirely in this workspace and leave `source/` byte-for-byte
unchanged. The supported converter is at `tools/rails/rails2zb.py`; Ruby is not installed and the
application cannot be booted, so the recorded inventory under `source/inventory/` is the only
observation available. Do not fabricate one.

`ZIGBASE_EVAL_BINARY` names a read-only ZigBase binary built from the same repository revision as
this scenario and grader. Verify its version and required CLI flags, then use it for rehearsal. Do
not download a release or clone a different revision. The operator intentionally supplies this
single environment variable with `--pass-env ZIGBASE_EVAL_BINARY`; it is test infrastructure, not a
credential.

Gate the scope before migrating anything. `source/app_source/` is the application's own source tree;
decide from it whether this application exposes a user-facing Rails presentation surface, and record
which exit of the gate applies. Mailer templates are not a browser-rendered frontend.

Run the converter's `inventory` step, record a durable decision with a rationale for every blocker
it raises in `decisions.json` at the root of this workspace, and produce a deterministic bundle at
`migration/bundle/`. Any file a decision names as its artifact is resolved relative to this
workspace and must exist. Extraction must be byte-identical across two separate runs from the same
source and decisions. Preserve ids, exact timestamps, relations, and Active Storage files. Import auth separately from the ordinary manifest, both with `--preserve-timestamps`,
using `--legacy-hashes bcrypt` for the verified `has_secure_password` hashes so the known user's
credential rehashes to argon2id on first successful login.

The snapshot contains behavior the converter deliberately refuses to convert silently — a
`default_scope` that hides rows, an encrypted attribute, single-table inheritance, a polymorphic
association, a database trigger, a counter cache, and a serialized column. Each needs a decision;
none may be answered by pretending it does not exist. Rows hidden from Rails by `default_scope` must
still reach the target.

Match ZigBase's rule semantics exactly at the integration boundary: a list request whose rule hides
every row is `200` with an empty `items` array, not `403`; a denied single-record request is
concealed as `404`, and where Rails already concealed a record as `404` the target must too. Do not
"fix" a concealment into a `403`.

Create `security/public-rules.json` with exactly this compact reviewed inventory contract, naming
every rule you deliberately made public and nothing else:

```json
{
  "zigbasePublicRules": 1,
  "rules": ["users.create"]
}
```

This is the reviewed decision, not an oversight: the source served several endpoints to anonymous
callers, and closing that surface is deliberate. Do not widen it back to match Rails.

The corresponding converter decisions carry the mandatory rationales. Add a dependency-free
`tests/test_migration.py` runnable with `python3 -m unittest discover -s tests -p test_migration.py`.
It runs offline, before any target exists, so assert what the bundle claims about itself — row
counts, the rows `default_scope` hid, the public surface matching the reviewed inventory, and that
no credential or ciphertext left the source. The live allow/deny, concealment and rehash behavior is
exercised against a running server during rehearsal, not here.

Rehearse the cutover on a fresh disposable target: dry-run and apply the schema, run rule lint,
import auth then ordinary data, verify counts and file digests directly rather than trusting a tool
summary, run production doctor and reconcile the public-rule warning rather than suppressing it,
prove the bcrypt-to-argon2id rehash survives a restart, and restore a backup into a **second**
target. Do not deploy or mutate external infrastructure.

Write `migration/report.json` with exactly these fields:

```json
{
  "zigbaseRailsMigrationReport": 1,
  "railsVersion": "8.1.3.1",
  "sourceMode": "observed",
  "bundle": "migration/bundle",
  "frontend": "A non-empty statement that Rails views and frontend behavior were not migrated, naming any retained frontend.",
  "publicRules": ["users.create"],
  "checks": ["scope", "bundle", "determinism", "rules", "auth", "rehash", "authorization", "parity", "timestamps", "files", "restart", "restore"],
  "unresolved": [],
  "rollback": "A non-empty description of the frozen snapshot, decisions, bundle, target and JWT secret kept as one rollback unit."
}
```

Do not include passwords, password hashes, tokens, raw transcripts, or source database bytes in the
report. Do not claim Rails views, templates, or frontend behavior were migrated. Do not claim Rails
sessions, `secret_key_base`-derived material, or API tokens survive.
