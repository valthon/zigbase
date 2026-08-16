> 📖 This documentation is also published, web-native, at <https://valthon.github.io/zigbase/docs/migrate-pocketbase> — the site is the canonical reading experience.

# Migrate PocketBase 0.39.11 to ZigBase

This is the supported offline workflow for migrating a PocketBase **0.39.11** application to
ZigBase. It preserves record and field ids, bcrypt credentials, historical timestamps, relations,
and referenced local files. It makes every semantic mismatch a durable decision instead of
guessing.

For migrations from other backends, or for the underlying schema/import/replay contracts, see
[migration-tools.md](https://github.com/valthon/zigbase/blob/main/docs/migration-tools.md).

## Support boundary

The converter supports a stopped PocketBase 0.39.11 snapshot containing:

- a public collection JSON export;
- `pb_data/data.db`, fully checkpointed with no `data.db-wal` or `data.db-shm`; and
- local file bytes under `pb_data/storage/`.

It does not download S3 objects, preserve PocketBase sessions or token keys, translate view SQL,
hooks, custom Go, cron, mail templates, OAuth/MFA/OTP behavior, geospatial query semantics, or run
a live dual-write. Those surfaces produce decisions or blockers. Port required behavior into
trusted ZigBase hooks, routes, jobs, or configuration and test its allow and deny cases before
cutover.

Never run the converter against a live database. Stop writes, stop PocketBase, make a recoverable
copy, and operate on that copy. The converter opens SQLite read-only and refuses WAL/SHM sidecars,
symlinks, unsafe identifiers, and output paths inside the source tree.

## 1. Capture and identify the source

Record the exact PocketBase version:

```sh
./pocketbase --version
```

This workflow currently requires `pocketbase version 0.39.11`. Export the application collections
from PocketBase, stop the process, and copy the entire `pb_data` directory. Hash the export,
database, and storage tree in the migration ticket or report. Keep the source snapshot immutable
through every rehearsal and cutover attempt.

Inventory these non-data surfaces alongside the snapshot:

- `pb_hooks/` and `pb_migrations/`;
- a custom `main.go`, `go.mod`, or compiled PocketBase extension;
- views and expression/partial indexes;
- OAuth2, MFA, OTP, password, token, and email settings;
- cron or external workers;
- local storage versus S3; and
- client endpoints and response shapes that must remain compatible.

## 2. Inventory before deciding

Run the converter from the ZigBase repository:

```sh
python3 tools/pocketbase/pb2zb.py inventory \
  --schema ./snapshot/pb_schema.json \
  --pb-data ./snapshot/pb_data \
  --out ./review/inventory.json
```

Exit `0` means the snapshot is directly representable. Exit `2` means review is required. Exit
`1` means the input or tool failed. The inventory is stable for the same source hashes.

Every finding has a stable id, severity, code, explanation, and allowed choices. Public
PocketBase rules (`""`) are not errors, including intentional public auth signup. They require an
explicit `public` decision and become exact ZigBase `@public` rules. Production doctor then reports
them as warnings for review; they are not inescapable errors.

## 3. Record durable decisions

Create a versioned `decisions.json`:

```json
{
  "zigbasePocketBaseDecisions": 1,
  "sourceVersion": "0.39.11",
  "decisions": [
    {
      "id": "rule.posts_collection.listRule.public",
      "choice": "public",
      "rationale": "The marketing catalog is intentionally readable without authentication."
    }
  ]
}
```

Use the exact finding id and one allowed choice. Rationale must be non-empty. Unknown, duplicate,
stale, or unacknowledged findings fail extraction.

A replacement decision must name a separate typed JSON artifact. The artifact binds itself to the
finding and declares whether it replaces a `field`, `rule`, `index`, or `collection`. Do not use
comments or broad ignore switches as approvals. Commit decisions and artifacts with the migration
work so another operator can reproduce the judgment.

Important choices include:

- Public rules: confirm `public` only when anonymous access is intended.
- Auth configuration: review password identity fields and port every enabled non-password method.
- Auth rules: only `verified = true` maps directly, to ZigBase's `require_verified`; disabled or
  other PocketBase login rules require an explicit replacement decision.
- Hidden fields: PocketBase also makes hidden fields non-superuser-write-protected. ZigBase's
  `hidden` flag only suppresses reads, so each non-system hidden field must be omitted or replaced
  with a trusted write boundary before self-service updates are enabled.
- Email visibility: ZigBase does not have PocketBase's per-record `emailVisibility` behavior and
  serializes auth email to any caller admitted by the collection rules. Any auth collection whose
  profiles are not strictly owner-scoped requires an explicit privacy review or replacement.
- Protected files: preserve access through an equivalent collection `viewRule` or trusted route.
- Custom autodates: map to `date` to preserve history, provide replacement behavior, or omit.
- `geoPoint`: preserve values as JSON with accepted semantic loss, or omit.
- Views, custom indexes, PocketBase-only rules, hooks, migrations, and Go code: provide reviewed
  replacement artifacts; never silently drop behavior.

## 4. Extract and review the bundle

```sh
python3 tools/pocketbase/pb2zb.py extract \
  --schema ./snapshot/pb_schema.json \
  --pb-data ./snapshot/pb_data \
  --decisions ./review/decisions.json \
  --out ./review/bundle
```

Extraction refuses a non-empty destination and every unresolved finding. The bundle contains the
target schema, ordinary and auth NDJSON, an import manifest, copied replacement artifacts,
referenced file bytes, decisions, inventory, and a root manifest with sizes and SHA-256 digests.
Unreferenced PocketBase storage objects are listed but not copied. Missing referenced files block
the run.

Review at minimum:

- source and decision hashes;
- collection, row, auth, and file counts;
- every `@public` rule;
- every replacement artifact;
- omitted collections, fields, indexes, and behaviors;
- `unreferencedStorage`; and
- the absence of PocketBase token keys, sessions, superusers, logs, and plaintext passwords.

Repeat extraction from the same snapshot and decisions. The bundle must be byte-identical.

## 5. Rehearse offline

Use a fresh, disposable ZigBase data directory. Keep the server stopped while applying schema,
importing rows, and installing files.

```sh
zigbase schema check-rules ./review/bundle/schema.json
zigbase schema apply ./review/bundle/schema.json \
  --dry-run --data-dir ./rehearsal/zb_data
zigbase schema apply ./review/bundle/schema.json \
  --data-dir ./rehearsal/zb_data
zigbase schema check-rules --data-dir ./rehearsal/zb_data
```

The file-based lint is syntax depth. The data-dir lint is full depth and must run after apply so it
can resolve fields and relations. Both commands exit `0` when clean, `1` for an invalid rule, and
`2` for warnings only. Reviewed `@public` rules deliberately produce exit `2`; inspect and account
for every warning instead of treating it as either a failure or a silent success.

Import each auth entry separately before ordinary records:

```sh
zigbase import --collection members \
  --legacy-hashes bcrypt \
  --preserve-timestamps \
  --data-dir ./rehearsal/zb_data \
  ./review/bundle/imports/auth/members.ndjson

zigbase import --manifest ./review/bundle/imports/manifest.json \
  --preserve-timestamps \
  --dry-run --data-dir ./rehearsal/zb_data

zigbase import --manifest ./review/bundle/imports/manifest.json \
  --preserve-timestamps \
  --data-dir ./rehearsal/zb_data
```

`--preserve-timestamps` is create-only, requires preserved ids, and cannot be combined with an
upsert key. The manifest runner preserves timestamps through its deferred relation pass, including
self-relations and cycles.

Install local files only after rows validate:

```sh
python3 tools/pocketbase/pb2zb.py install-files \
  --bundle ./review/bundle \
  --target-data-dir ./rehearsal/zb_data
```

Installation verifies the complete bundle and target plan before writing. It creates missing files
atomically, accepts an identical retry, refuses different existing bytes, and rejects traversal,
symlinks, and path collisions. This installs only into ZigBase local storage. Materialize S3
objects into the reviewed snapshot first or migrate them with an independently reviewed process.

## 6. Port behavior and prove parity

Port each required hook, view, custom route, scheduled task, auth method, and mail behavior before
cutover. Keep ordinary CRUD on collection APIs. Use trusted hooks/routes/jobs only where source
semantics cannot be represented by fields and rules.

For every replacement add:

- one allowed actor or input test;
- one denied actor or invalid input test; and
- a parity assertion against the captured PocketBase behavior.

Capture representative requests before stopping source writes, then replay them against the
rehearsal target with `tools/replay/zb_replay.py`. Include anonymous and authenticated list/view,
relation expansion, denied owner access, public and protected files, validation failures, and any
custom endpoint clients depend on.

Verify a known migrated account twice:

1. a wrong password fails and leaves the legacy hash unchanged;
2. the correct old password succeeds and rewrites `$zblegacy$bcrypt$...` to argon2id; and
3. the same password succeeds after restart.

PocketBase sessions do not survive. Plan for users to authenticate again.

## 7. Doctor and deployment gate

Run:

```sh
zigbase doctor --production --json --data-dir ./rehearsal/zb_data
```

Reconcile the exact public-rule findings against `decisions.json`. Intentional reviewed public
rules are warnings, not errors. Resolve real production errors such as missing mail configuration,
and account for remaining legacy password hashes. A legacy-hash warning may be an accepted rollout
state only when the login/rehash test passed and the migration plan tracks the count to zero.
An offline fixture or rehearsal without deployment SMTP settings is therefore expected to retain a
mailer error; supply the production mail configuration before using doctor as a cutover gate.

Start the production-shaped service, verify health/meta/data/files, restart it against the same
durable volume, and repeat. Follow [deployment.md](https://github.com/valthon/zigbase/blob/main/docs/deployment.md) and [docker.md](https://github.com/valthon/zigbase/blob/main/docs/docker.md): persist
the whole data directory, protect the JWT secret, terminate TLS, use one SQLite process, configure
mail, and rehearse backup restore.

## 8. Cut over and roll back as one unit

Immediately before cutover:

1. stop source writes;
2. take and hash the final stopped snapshot;
3. regenerate and review the bundle from the already-approved decisions;
4. migrate into a fresh target using the rehearsed commands;
5. run counts, authorization, parity, login/rehash, file, doctor, and restart checks; and
6. switch traffic only after every required check passes.

Treat the source snapshot, decisions, extracted bundle, target database, target storage, and JWT
secret as one rollback unit. If verification fails, keep PocketBase authoritative, discard the
partial target, diagnose from the immutable artifacts, and rehearse again. Do not reverse traffic
onto a PocketBase instance that accepted writes after the final snapshot without a deliberate data
reconciliation plan.

## Migration report

Record:

- source version and hashes;
- inventory summary and every decision/replacement;
- bundle manifest hash and counts;
- exact commands and exit codes;
- schema/rule/doctor findings;
- allow/deny and parity results;
- legacy hash count before and after the known login;
- restart and backup-restore results;
- cutover owner/time; and
- rollback trigger and immutable snapshot location.

Rows matching and files downloading are necessary, but they are not sufficient. The migration is
complete only when authorization, behavior, credentials, history, durability, and rollback are
all evidenced.
