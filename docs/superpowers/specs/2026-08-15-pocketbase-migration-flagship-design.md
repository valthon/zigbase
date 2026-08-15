# PocketBase migration flagship — design

**Date:** 2026-08-15
**Status:** Draft for implementation
**Program:** [ZigBase AI-Agents Program](2026-08-08-ai-agents-program-design.md), SP-5 follow-up
**Depends on:** SP-4 App Genesis runner/result/isolation contracts and the landed SP-5 migration machinery
**Reference source:** PocketBase v0.39.11 (`5d217dd`, released 2026-08-14)

## 1. Goal

Given a consistent PocketBase schema export plus an offline `pb_data` snapshot, an agent can
produce and execute a reviewable ZigBase migration bundle, preserve users and files, prove endpoint
parity, and bring up the replacement through the same production gates as App Genesis without
human intervention on the supported reference application.

This project completes the deliberately deferred PocketBase layer over machinery that already
ships:

- canonical `zigbase schema dump/apply/check-rules` documents;
- streaming and manifest-driven NDJSON import with relation-cycle repair;
- bcrypt legacy-password import and rehash-on-login;
- `doctor` visibility for remaining legacy hashes; and
- the provider-neutral parity replay tool and real-agent eval runner.

It adds four things together:

1. a stdlib-only PocketBase inventory/conversion tool;
2. a `zigbase-migrate-pocketbase` Agent Skill and canonical workflow guide;
3. a pinned PocketBase reference fixture plus deterministic migration grader; and
4. the `pocketbase` real-agent scenario and three-run release gate.

## 2. Current upstream facts and corrected assumptions

The reference version is pinned because PocketBase's schema has evolved. Its current documentation
and v0.39.11 release establish:

- three collection kinds: base, auth, and SQL-backed read-only view collections;
- auth collections with password/email/verified system behavior;
- relation and multi-relation values represented as ids and arrays of ids;
- file fields storing filenames in SQLite while bytes live in local or S3 storage;
- collection export/import and migration snapshots as supported schema surfaces; and
- a thirteenth `geoPoint` field type, represented as `{lon,lat}` JSON.

The older SP-5 machinery plan's claim that all PocketBase field types map 1:1 is therefore no
longer true. ZigBase has the original twelve types but no `geoPoint` semantic type. PocketBase view
collections also include a SQL `SELECT` whose semantics are not represented by ZigBase's schema
document. This design makes those differences explicit instead of silently weakening them.

Primary upstream references:

- <https://github.com/pocketbase/pocketbase/releases/tag/v0.39.11>
- <https://pocketbase.io/docs/collections/>
- <https://pocketbase.io/docs/api-collections/>
- <https://pocketbase.io/docs/js-migrations/#collections-snapshot>
- <https://pocketbase.io/docs/api-records/>
- <https://pocketbase.io/docs/api-files/>
- <https://pocketbase.io/docs/going-to-production/>

## 3. Scope

### In scope

- PocketBase v0.39.11 schema-export ingestion.
- Offline, read-only extraction from a consistent local `pb_data/data.db` snapshot.
- Base and auth collections, ids, scalar/multi fields, relations, simple indexes, records, local
  file storage, bcrypt credentials, verification state, and source timestamps.
- Explicit inventory and refusal for unsupported or judgment-bearing behavior.
- Rule carry-over only when syntax is accepted by ZigBase, followed by full-depth rule lint and
  replay; no regex/string-replacement "translation" that merely looks plausible.
- A relocatable, versioned migration bundle with no credentials beyond the bcrypt hashes required
  for the operator-only import.
- Reference-fixture parity across public reads, authenticated ownership, legacy login/rehash,
  relation expansion, files, restart persistence, doctor, and Docker deployment.
- Reuse of SP-4's runner, result schema, workspace isolation, transcript policy, and Compose
  teardown.

### Out of scope

- Live migration while PocketBase continues accepting writes.
- PocketBase S3 object download; the operator must first materialize a complete local storage
  snapshot or migrate those objects through a separately reviewed process.
- Mechanical translation of `pb_hooks`, custom Go code, cron/jobs, mail templates, OAuth provider
  secrets, custom routes, or PocketBase view SQL.
- `geoPoint` query/index semantics. An explicitly acknowledged JSON representation preserves the
  values, not geospatial behavior.
- Existing PocketBase session tokens; users authenticate again against the preserved password
  hash, which then upgrades to argon2id.
- OpenAPI export and later Rails/Express/Laravel/Go skill instances.

## 4. Settled decisions

### D1. Inputs are an exported schema plus a consistent offline snapshot

The tool never discovers schema by reverse-engineering PocketBase's private `_collections` table.
It consumes:

1. `pb_schema.json`, exported from the v0.39.11 Dashboard/API or produced by a collection snapshot;
2. a copied `pb_data` directory whose `data.db` and `storage/` belong to the same stopped instance
   or transactional backup; and
3. an optional operator decisions file described in D3.

The schema export is PocketBase's public contract. SQLite is used only to stream rows named by that
schema and recover the password hash unavailable through public APIs. The source database opens
with SQLite URI `mode=ro`; the tool never writes or migrates it. A source with a hot `-wal`/`-shm`,
missing database, or mismatched collection/table shape is refused with an actionable finding.

### D2. One stdlib Python tool produces a versioned, relocatable bundle

`tools/pocketbase/pb2zb.py` uses only Python 3's standard library and has three subcommands:

```text
pb2zb.py inventory --schema pb_schema.json --pb-data pb_data --out inventory.json
pb2zb.py extract   --schema pb_schema.json --pb-data pb_data --decisions decisions.json --out bundle/
pb2zb.py install-files --bundle bundle/ --target-data-dir zb_data/
```

All subprocess-free conversion uses structured parsers and `sqlite3` parameter binding. No source
identifier becomes raw SQL until it has been matched against the exported schema and quoted with a
single canonical identifier helper.

`inventory` is read-only and always emits one JSON report. Exit `0` means directly representable;
exit `2` means findings need decisions; exit `1` means the input/tool failed. `extract` refuses an
existing non-empty output directory and refuses every unacknowledged blocker. `install-files`
allows only bundle-owned relative paths, rejects symlinks/traversal, and never overwrites a
different target file.

### D3. Judgment is durable and typed, never hidden in comments

`inventory.json` assigns a stable id and severity to every finding. Examples:

```json
{
  "id": "field.locations.point.geoPoint",
  "severity": "decision",
  "code": "GeoPointRequiresMapping",
  "choices": ["json", "omit"]
}
```

`decisions.json` is versioned and keyed by exact finding id:

```json
{
  "zigbasePocketBaseDecisions": 1,
  "sourceVersion": "0.39.11",
  "decisions": [
    {"id": "field.locations.point.geoPoint", "choice": "json", "rationale": "Coordinates are displayed but never queried spatially."}
  ]
}
```

Unknown, duplicate, stale, or empty-rationale decisions fail extraction. Some findings have no
automatic choice—PocketBase view SQL, non-empty `pb_hooks`, custom Go code, unsupported rule
macros, and complex expression indexes are blockers until the operator supplies a replacement
artifact named by the finding. This mirrors Genesis public-rule inventory: review is durable,
machine-reconcilable evidence, not a magic suppression comment.

### D4. The bundle is the audit and execution boundary

An extracted bundle contains only deterministic text plus copied file bytes:

```text
bundle/
├── zigbase-pocketbase-bundle.json
├── inventory.json
├── decisions.json
├── schema.json
├── imports/
│   ├── manifest.json
│   ├── <base-collection>.ndjson
│   └── auth/<auth-collection>.ndjson
├── storage/<collection-name>/<record-id>/<filename>
└── replay/requests.ndjson
```

The root manifest has `zigbasePocketBaseBundle: 1`, source version, input content hashes,
collection/row/file counts, auth import entries, ordinary manifest path, and every output digest.
Paths are relative and normalized. Runs are deterministic for the same snapshot and decisions:
collection order, field order, row order (`id`), JSON keys, NDJSON lines, and manifest entries are
stable.

Auth imports are deliberately separate from the ordinary manifest because ZigBase's
`--legacy-hashes bcrypt` option applies uniformly to a run and refuses base collections. The skill
executes each auth file as its own create-only import before the relation-ordered base manifest.

### D5. Mapping is lossless by default and explicit where it cannot be

Direct field mappings are `text`, `number`, `bool`, `email`, `url`, `editor`, `date`, `autodate`,
`select`, `json`, `file`, and `relation`. Stable field ids and record ids are preserved. PocketBase
collection ids remain in bundle provenance and source-file lookup, but ZigBase collection ids are
intentionally instance-local: the target schema omits them and writes relation targets by portable
collection name, matching the canonical `zigbase schema dump/apply` contract.
Single and multi relation/select/file values retain their string/JSON-array shapes.

Additional rules:

- PocketBase system fields already supplied by ZigBase (`id`, `created`, `updated`, auth email,
  token key, password) are not duplicated as user fields.
- `passwordHash` is emitted only in auth NDJSON; PocketBase token keys and session state are never
  copied.
- `verified` and email visibility are carried when ZigBase has the corresponding auth field.
- PocketBase `geoPoint` requires a `json` or `omit` decision. `json` preserves `{lon,lat}` values
  and emits a permanent semantic-loss warning in the bundle.
- View collections are never emitted as ordinary tables. A decision must point to reviewed ZigBase
  framework code/custom route or to an explicitly materialized base-collection design.
- Only simple column indexes supported by ZigBase's index model are converted. Expression/collation
  indexes block extraction pending a replacement.
- `manageRule`, `@collection.*`, back-relation syntax, and any PocketBase rule surface not accepted
  by `zigbase schema check-rules` require an explicit replacement. Exact rules already in ZigBase's
  grammar are carried verbatim.

### D6. Source timestamps need a narrow import capability

Current `zigbase import` preserves ids but regenerates `created`/`updated`. A real migration must
not reorder historical feeds or destroy audit timestamps. Add:

```text
zigbase import ... --preserve-timestamps
```

This is local/operator-only, create-only, and requires preserved ids. Each row must contain valid
`created` and `updated` strings. The record is validated and created through the normal engine;
inside the same transaction the importer then replaces only those two system columns with the
validated source values. It is incompatible with `--upsert-key`. REST/client writes remain unable
to author system timestamps.

The manifest runner forwards the option. Tests prove timestamp preservation, rollback, invalid
timestamp refusal, option conflicts, and that ordinary import behavior is unchanged.

### D7. Local files are staged safely and installed only after rows validate

PocketBase local files live below `pb_data/storage/<collection-id>/<record-id>/<filename>` while
ZigBase local files live below `<data-dir>/storage/<collection-name>/<record-id>/<filename>`.
Extraction verifies every filename referenced by a file field, hashes and copies each byte stream
to the bundle layout, and reports both missing and unreferenced source objects.

The workflow dry-runs schema/data first, applies/imports rows, then runs `install-files` while the
target server is stopped. Installation uses create-new semantics or verifies an identical existing
digest; a different existing file is a conflict. The grader downloads representative public and
protected files through ZigBase after startup.

### D8. Password continuity is mandatory

For every auth collection, extraction reads the PocketBase bcrypt hash from its row and emits it as
`passwordHash`. The skill imports auth collections first with:

```sh
zigbase import --collection <auth> --legacy-hashes bcrypt \
  --preserve-timestamps --data-dir <target> imports/auth/<auth>.ndjson
```

The grader logs in with a known reference user, verifies a session is issued, then confirms doctor
reports one fewer legacy hash (ultimately zero for the fixture). A migration that replaces all
passwords, omits auth rows, imports hashes into `_superusers`, or claims old sessions survive fails.

### D9. The skill ports behavior before cutover

`skills/zigbase-migrate-pocketbase/` is a thin workflow over byte-copied canonical references. It
must:

1. make/verify a consistent source snapshot and record the exact PocketBase version;
2. run inventory and resolve every typed decision;
3. inventory `pb_hooks`, `pb_migrations`, custom Go, cron, mail, OAuth, view SQL, and S3;
4. extract and review the deterministic bundle;
5. capture parity requests against PocketBase before stopping writes;
6. dry-run rules, schema, auth imports, and ordinary imports against a rehearsal target;
7. apply schema, import auth then data, and install files;
8. port custom behavior into trusted Zig hooks/routes/jobs and add allow/deny tests;
9. replay parity, test legacy login/rehash and files, run production doctor, then Docker restart;
10. produce a cutover/rollback report with exact checks and unresolved decisions.

The skill never edits the source snapshot, never treats a converter warning as authorization, and
never opens production traffic merely because row counts match.

### D10. Scenario 2 reuses the SP-4 harness without forking it

Add `evals/agents/scenarios/pocketbase/` and `evals/agents/graders/pocketbase.py`. The runner and
`EvalResult` fields remain unchanged. For this scenario:

- `completion` means a valid bundle, replacement app, migration report, and expected shape exist;
- `rules_locked` means full-depth rule lint, doctor findings, and reviewed public-rule inventory
  reconcile exactly;
- `tests_green` means converter/unit/authz/parity tests and the declared client boundary pass; and
- `deployed` means the migrated Docker app serves health/meta/data/files, survives restart, and
  tears down exactly.

The fixture is generated once from pinned PocketBase v0.39.11 and committed as non-secret source
artifacts: schema export, a small consistent SQLite snapshot, local storage bytes, parity capture,
and a fixture manifest containing their hashes. CI does not download or execute PocketBase. A
maintainer-only regeneration script downloads the exact immutable release asset, verifies its
published checksum, builds the fixture, strips superuser credentials/logs, and proves deterministic
hashes.

The happy fixture contains:

- one auth collection and known bcrypt test user;
- owner-scoped base data with one intentional public read;
- single and multi relations;
- a file field with public and protected file checks;
- historical timestamps;
- a rule that carries verbatim; and
- parity cases for list/view/denial/login/file behavior.

Dedicated negative fixtures cover an unacknowledged `geoPoint`, view SQL, custom hook inventory,
stale decisions, missing file, rule incompatibility, bad bcrypt hash, timestamp loss, parity drift,
and teardown.

### D11. The flagship gate is three consecutive clean migrations

The same release criterion as Genesis applies: one commit must produce three consecutive
`pocketbase` results with all four booleans true, score 4, zero interventions, no failures, and the
same agent/model identifier. Only sanitized summaries are committed; source snapshots contain only
synthetic fixture data, and raw transcripts/workspaces remain local.

## 5. Security and failure semantics

- Source database access is read-only; source storage is never modified.
- Every path is resolved below an exact recorded root; symlinks, absolute bundle paths, `..`, NUL,
  and filename separators are refused.
- SQLite identifiers come only from schema-matched names and are quoted centrally; values are
  parameters.
- Individual rows and JSON values are bounded; extraction streams rows/files rather than loading a
  production database or storage tree into memory.
- Bcrypt hashes are treated as credentials: never logged, never included in inventory findings,
  and present only in the operator-owned bundle/auth NDJSON.
- Bundle hashes detect post-review mutation before apply.
- Destructive schema choices, omitted collections/fields, semantic-loss mappings, missing files,
  custom code, and unsupported rules cannot collapse into a warning-only success.
- A partial target migration is never an in-place rollback strategy. Rollback restores the old
  PocketBase service/snapshot and discards or restores the rehearsed ZigBase target as a unit.

## 6. Implementation sequence

1. Add `--preserve-timestamps` to the existing importer with Zig/CLI tests and docs.
2. Implement the inventory model, stable findings, decisions reconciliation, and schema mapping.
3. Implement streaming row/auth extraction and deterministic bundle manifests.
4. Implement file staging/install with traversal/collision/digest tests.
5. Add the pinned PocketBase fixture and end-to-end converter/import/login/file tests.
6. Publish the canonical PocketBase migration guide and drift-guarded skill.
7. Add the PocketBase deterministic grader, scenario contract, and CI tests.
8. Forward-test, fix owning surfaces, and close on three consecutive clean runs.

Each executable step gets its own implementation plan and reviewable commits. The PocketBase tool
and grader are Python because the source is SQLite/JSON and the provider-neutral harness is already
Python; the timestamp seam remains in Zig because only the trusted import engine may write system
columns.

## 7. Acceptance criteria

- The reference app migrates from the pinned snapshot without editing source data.
- Schema/rules/data/relations/auth hashes/verification/files/timestamps match the supported source
  semantics or have an exact reviewed decision.
- Known legacy login succeeds and rewrites bcrypt to argon2id.
- Public and protected replay cases pass against the replacement.
- Production doctor has no errors/skips; every warning is durably inventoried.
- Docker health/meta/data/files pass before and after restart; teardown is exact.
- Deterministic tests cover every refusal and each grade independently.
- Three consecutive real-agent score-4, zero-intervention results exist on one commit.

## 8. Follow-ups after PocketBase

The same skill skeleton and `pocketbase` grader interfaces become the template for Rails and
Express, but their source adapters remain separate. Rails adds pepper-aware bcrypt and frontend
coordination; Express begins with route/query discovery. Neither may weaken the typed decisions,
bundle hashes, source-read-only rule, parity requirement, or three-run gate established here.
