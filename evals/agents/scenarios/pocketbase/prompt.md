Use the installed `$zigbase-migrate-pocketbase` skill to migrate the stopped PocketBase 0.39.11
snapshot in `source/` to ZigBase. Work entirely in this workspace and leave `source/` byte-for-byte
unchanged. The supported converter is at `tools/pocketbase/pb2zb.py`.

`ZIGBASE_EVAL_BINARY` names a read-only ZigBase binary built from the same repository revision as
this scenario and grader. Verify its version and required CLI flags, then use it for rehearsal and
copy it into a pinned local deployment image. Do not substitute the older public release image or
clone a different source revision. The operator intentionally supplies this single environment
variable with `--pass-env ZIGBASE_EVAL_BINARY`; it is test infrastructure, not a credential.

Review the supplied inventory and durable decisions, then create a verified deterministic bundle at
`migration/bundle/`. Rehearse schema, auth, ordinary-row, timestamp, relation, and file migration.
Preserve the known user's bcrypt credential for rehash on first successful login. Port and test the
captured public, owner-scoped, protected-file, and relation-expansion behavior. The source's public
auth create rule is intentional: anonymous signup must work, while production doctor must enumerate
`members.createRule` as a warning rather than an error.

Match collection-rule HTTP semantics precisely in the integration boundary: an owner-filtered list
request succeeds with `200` and an empty `items` array when no rows are visible, while a denied
single-record request is concealed with `404`. Test both boundaries; do not expect `403` from the
owner-filtered list.

Create `security/public-rules.json` with exactly this compact reviewed inventory contract:

```json
{
  "zigbasePublicRules": 1,
  "rules": ["members.create", "posts.list", "posts.view"]
}
```

The corresponding converter decisions carry the mandatory rationales. Add a dependency-free
`tests/test_migration.py` integration boundary runnable with
`python3 -m unittest discover -s tests -p test_migration.py`.

Provide a production-shaped Docker Compose deployment that migrates the bundle into a named durable
`/data` volume, uses a pinned image or build, keeps secure cookies enabled behind HTTPS, configures
mail through environment interpolation, and serves the migrated API and files. It must survive
`docker compose restart` without re-import failures and support exact `down -v --remove-orphans`
teardown.

Write `migration/report.json` with exactly these fields:

```json
{
  "zigbasePocketBaseMigrationReport": 1,
  "sourceVersion": "0.39.11",
  "bundle": "migration/bundle",
  "publicRules": ["members.create", "posts.list", "posts.view"],
  "checks": ["bundle", "rules", "auth", "signup", "authorization", "parity", "timestamps", "files", "restart", "rollback"],
  "unresolved": [],
  "rollback": "A non-empty description of the immutable snapshot and target rollback unit."
}
```

Do not include passwords, password hashes, tokens, raw transcripts, or source database bytes in the
report. Do not claim PocketBase sessions survive. Do not deploy or mutate external infrastructure.
