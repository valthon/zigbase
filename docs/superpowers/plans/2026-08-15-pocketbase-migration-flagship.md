# PocketBase migration flagship — implementation plan

> **For agentic workers:** implement tasks in order. Write refusal/negative tests before each
> behavior, keep each task reviewable, and commit every completed task locally.

**Date:** 2026-08-15
**Design:** [PocketBase migration flagship](../specs/2026-08-15-pocketbase-migration-flagship-design.md)
**Baseline:** `codex/sp4-foundation` @ `f0318c29`
**Reference source:** PocketBase v0.39.11 (`5d217dd`)

## Goal

Deliver an offline, source-read-only PocketBase converter; a durable reviewed-decision format; a
safe migration bundle and file installer; a canonical guide and skill; and a deterministically
graded real-agent scenario. Finish with three consecutive clean unattended migrations on one
commit.

## Global constraints

- Zig is exactly 0.16.0 through mise. Python is 3.13 and converter/grader code uses only the
  standard library.
- Use `apply_patch` for source edits, `zig fmt` for Zig, and the repository Ruff configuration for
  Python. Add a changelog fragment; never edit generated `CHANGELOG.md` or site mirrors.
- PocketBase source inputs are always offline snapshots opened read-only. Tests must prove the
  converter cannot modify `data.db`, WAL files, storage, or schema exports.
- The converter never reads PocketBase's private collection metadata as its schema contract. It
  accepts the exported v0.39.11 collection JSON and uses SQLite only for rows/credentials named by
  that export.
- Dynamic SQLite identifiers must first match an exported collection/table and pass one central
  quoting helper. Values are always parameters. No subprocess invocation uses a shell.
- Paths are relative to a recorded root and normalized. Reject absolute paths, `..`, NUL,
  separators in filenames, symlinks, and target collisions with different content.
- Bcrypt hashes are credentials. Never print them, put them in inventory findings, fixture logs,
  eval results, or committed transcripts. They may exist only in synthetic fixtures and
  operator-owned auth import files.
- Unsupported semantics do not degrade to advisory prose. Extraction requires a typed, exact,
  non-stale decision or a named replacement artifact; irreconcilable blockers stay errors.
- Conversion is deterministic: stable collection/field/row ordering, stable JSON key order and
  whitespace, stable manifests, and content hashes over every emitted artifact.
- Reuse `schema apply/check-rules`, `import`, `import_manifest`, parity replay, doctor, and the SP-4
  runner/result/isolation contracts. Do not fork those implementations.
- New bounded parsers reject unknown keys and future versions. Large records/files are streamed;
  limits are explicit and tested.
- After Zig changes run the full Zig suite, CLI tests, gating, and allocator checks. After docs or
  skill changes run docs parity, site build/doctor, and both skill-sync tests.

## Task 1: Narrow source-timestamp import seam

**Files:**

- Modify `src/import.zig`, `src/import_manifest.zig`, `src/cli.zig`, and `src/framework.zig`.
- Modify focused Zig tests in those modules and CLI tests under `tests/cli/` where needed.
- Modify `docs/migration-tools.md` and add `changelog.d/import-preserve-timestamps.md`.

Add `preserve_timestamps: bool = false` to import options and `--preserve-timestamps` to the CLI.
It is create-only, requires `preserve_ids`, conflicts with `--upsert-key`, and is forwarded through
manifest runs. Each input row must contain string `created` and `updated` values accepted by the
existing datetime parser. Create through `records.createInTxnOpts`; then, within the same row
transaction/savepoint, update only the new row's quoted `created` and `updated` columns by id.

Do not expose a record-engine or HTTP option for system columns. Failed timestamp validation or
post-create update must roll back the row exactly like any other import failure. Preserve the
source strings after validation rather than normalizing them, so parity is byte-observable.

**Tests:** exact preservation for base/auth rows, default regeneration unchanged, missing/wrong/
invalid timestamps, duplicate id, `preserve_ids=false`, upsert conflict, dry-run, batch rollback,
continue-on-error, manifest forwarding, CLI parsing/help/JSON summary, SQLite and PostgreSQL
placeholder generation where the existing suite supports it.

**Commit:** `feat: preserve source timestamps during import`

## Task 2: Converter contract, inventory, and typed decisions

**Files:**

- Create `tools/pocketbase/pb2zb.py` and `tools/pocketbase/__init__.py` if package imports need it.
- Create `tests/pocketbase/test_inventory.py`, `test_decisions.py`, and focused fixtures.

Implement strict models/parsers for:

- PocketBase v0.39.11 collection exports;
- source snapshot shape and consistency checks;
- stable inventory findings; and
- `zigbasePocketBaseDecisions: 1` reconciliation.

`inventory` always writes one deterministic report. Exit 0 means no decisions, 2 means judgment
is required, and 1 means invalid input/tool failure. Finding ids derive from stable schema
identity—not list position or message text. Decisions must use an advertised choice, have a
non-empty rationale, match source version, and reconcile one-to-one; reject duplicates, unknowns,
stale entries, and decisions for non-decision findings.

Inventory collection types, all fields/indexes/rules, `geoPoint`, views, rule-only PocketBase
syntax, local/S3 file configuration, and the presence of hooks/migrations/custom source surfaces.
Never include row data or password hashes.

**Tests:** all three exit classes, malformed/future export, duplicate ids/names, mismatched table,
hot WAL/SHM, unknown field type, every finding category, stable ids/order, stale decisions, and
source-tree hash unchanged before/after.

**Commit:** `feat: inventory PocketBase migrations`

## Task 3: Deterministic schema and row extraction

**Files:**

- Extend `tools/pocketbase/pb2zb.py` with focused modules only if they improve test isolation.
- Create `tests/pocketbase/test_extract.py` and fixture builders.

Map the directly supported fields and collection/rule/index metadata into
`zigbaseSchema: 1`. Preserve field/record ids; retain source collection ids in bundle provenance
and file lookup while allowing the target to generate its intentionally instance-local collection
ids. Write relation targets by collection name. Require a typed `json` or `omit` decision
for `geoPoint`; view/custom/rule/index replacements must be exact artifacts named in decisions.
Require non-system `autodate` to map to history-preserving `date`, a reviewed replacement, or
omission; never silently regenerate its source values.
Run generated rules through the shipped `zigbase schema check-rules` in integration tests.

Open SQLite with `mode=ro`; enumerate only schema-matched tables; stream rows ordered by `id` into
stable NDJSON. Emit base and auth imports separately. Auth rows contain the source bcrypt hash as
`passwordHash`, verification state, and timestamps, but never PocketBase token/session material.
Reject missing/malformed/non-bcrypt credentials. Produce the ordinary import manifest in relation
order and retain cyclic relation values for the existing two-pass runner.

The root bundle manifest records version, source hashes, decisions hash, counts, relative paths,
and SHA-256 for every output. Extraction refuses a non-empty destination and verifies the complete
bundle before reporting success.

**Tests:** all direct field mappings, geoPoint choices, collection/rule/index replacements, stable
schema and row order, JSON-array shapes, nulls, relation cycles, auth separation/redaction,
malformed hashes, row/line limits, repeat-run byte identity, tamper detection, and no source writes.

**Commit:** `feat: extract PocketBase migration bundles`

## Task 4: Safe local-file staging and installation

**Files:**

- Extend the converter's `extract` and `install-files` commands.
- Create `tests/pocketbase/test_files.py`.

Resolve PocketBase bytes from `storage/<collection-id>/<record-id>/<filename>` using exported ids,
verify every file-field reference, hash while copying to bundle storage keyed by ZigBase collection
name, and report unreferenced objects without copying them. Missing referenced files are blockers.

`install-files` verifies the root manifest and each digest before touching the target. Create
directories with restrictive permissions. Create a missing file atomically; treat an identical
existing file as success; refuse a different existing file. Validate the complete plan before the
first write so traversal/collision errors cannot leave a partial install.

**Tests:** single/multi file fields, protected/public assets, missing/unreferenced bytes, empty
filename, nested/traversal/absolute paths, separators, Unicode, symlinks at every source/target
level, duplicate destinations, tampered bundle, identical retry, differing collision, read-only
source, and deterministic digests.

**Commit:** `feat: migrate PocketBase local files safely`

## Task 5: Pinned reference fixture and end-to-end migration

**Files:**

- Create `tests/pocketbase/fixtures/v0.39.11/` with synthetic export/database/storage/parity data.
- Create `tools/pocketbase/regenerate_fixture.py` and fixture manifest.
- Create `tests/pocketbase/test_migration_e2e.py`.

Commit a small non-secret fixture generated from exact PocketBase v0.39.11 behavior. It includes
one auth collection and known test credential, owner-scoped data, one intentional public read,
single/multi/cyclic relations, public/protected files, historical timestamps, and rules that carry
verbatim. Record hashes and generation provenance. CI never downloads or executes PocketBase.

The maintainer-only regeneration path downloads the immutable release asset only when explicitly
run, verifies its published checksum, constructs the fixture, removes superusers/logs, and checks
that a second generation matches. Keep network execution outside normal tests.

The E2E test applies schema to a fresh ZigBase data dir; separately imports auth with bcrypt and
timestamps; imports the ordinary manifest; installs files; starts the server; proves parity,
authorization, relation expansion, file access, legacy login and argon2id rehash, exact timestamps,
doctor accounting, restart persistence, and exact teardown.

**Commit:** `test: prove PocketBase migration end to end`

## Task 6: Canonical guide and migration skill

**Files:**

- Create `docs/migrate-pocketbase.md` and register/link it through the docs registry/navigation.
- Create `skills/zigbase-migrate-pocketbase/SKILL.md`, `agents/openai.yaml`, and canonical reference
  copies following the established Genesis skill shape.
- Extend `tests/skills/sync.sh` and `tests/skills/test-sync.sh`.
- Modify `README.md`, `docs/agents.md`, and `docs/migration-tools.md` links.
- Add `changelog.d/pocketbase-migration.md`.

Document the offline snapshot contract, inventory/decision loop, bundle review, rehearsal,
separate auth import, data import, file install, custom behavior port, parity capture/replay,
doctor/deployment gates, cutover, and unit-of-rollback. State the v0.39.11 support boundary and the
exact unsupported semantics. Do not imply S3 download, live dual-write, session preservation,
geospatial semantics, or automatic view/hook translation.

The skill must trigger for PocketBase migration requests and make durable decisions mandatory. It
routes to byte-copied canonical references, uses the converter as the only extraction path, and
requires allow/deny tests for replacement code. Generate metadata only after the body is complete.
The sync guard rejects drift, unexpected markdown, bad frontmatter/metadata, and stale references.

**Tests:** skill validation; clean and negative sync controls; docs registry/navigation parity;
site build, doctor, generated-doc checks, and a full scan for contradictory PocketBase claims.

**Commit:** `docs: publish PocketBase migration workflow`

## Task 7: PocketBase scenario and deterministic grader

**Files:**

- Create `evals/agents/scenarios/pocketbase/scenario.json` and `prompt.md`.
- Create `evals/agents/graders/pocketbase.py`.
- Extend grader dispatch without changing the result schema.
- Create positive and one-failure-per-grade fixtures/tests under `tests/agent_evals/`.

Reuse the SP-4 runner, workspace isolation, output bounds, transcript rules, result object, and
Compose cleanup. The scenario supplies the pinned snapshot and asks for migration using the
installed skill without revealing grader implementation.

Grade independently:

- `completion`: valid, hash-verified bundle; expected schema/rows/files; migration report.
- `rules_locked`: full-depth rule lint, doctor result, exact reviewed public-rule inventory and
  typed-decision reconciliation.
- `tests_green`: converter/authorization/parity/client-boundary commands succeed, legacy login
  upgrades its hash, and timestamp/file assertions pass.
- `deployed`: Docker health/meta/data/files pass before and after restart, named storage is durable,
  and exact project teardown succeeds.

The grader executes only fixed or scenario-declared argv, never bundle/report commands. It parses
JSON/NDJSON defensively, bounds reads/timeouts, verifies fixture/bundle hashes, and redacts hashes
and credentials from failure text.

**Tests:** positive and one isolated negative for every boolean; malformed/forged reports;
stale/extra decisions and public rules; parity drift; missing file; failed rehash; timestamp loss;
Docker timeout/restart/teardown; no transcript or credential leakage.

**Commit:** `feat: grade PocketBase agent migrations`

## Task 8: CI/operator surface and full deterministic verification

**Files:**

- Modify `.github/workflows/ci.yml` to run converter and deterministic grader tests.
- Update agent/operator docs with exact local commands and artifact policy.

Keep real-agent execution opt-in; blocking CI requires no model credentials, PocketBase download,
or model tokens. Add the stdlib converter suite and fake-agent/grader suite to the existing job,
then run the full repository verification matrix.

**Commit:** `ci: gate PocketBase migration tooling`

## Task 9: Forward-test and close the flagship

Run the `pocketbase` scenario from a fresh context that receives only the installed skill,
scenario prompt, fixture, and ordinary repository-visible tools. Do not expose this plan or grader
implementation. For every failure, preserve local artifacts, classify the owning surface, add a
deterministic regression where possible, fix that surface, commit, and restart the pass count.

Completion requires three consecutive score-4, zero-intervention results on one commit with the
same agent/model id. Commit only sanitized result summaries and consumer-visible claims; retain no
raw transcript, workspace, credential, container, or data directory.

**Commit:** `docs: record verified PocketBase migration flagship`

## Full verification before merge

- `mise exec zig@0.16.0 -- zig build test --summary all`
- `mise exec python@3.13 -- python -m pytest tests/cli tests/pocketbase tests/agent_evals -q`
- repository Ruff checks for all Python touched here
- `bash tests/skills/test-sync.sh` and `bash tests/skills/sync.sh`
- `mise exec python@3.13 -- python -m pytest tests/admin/test_docs_parity.py -q`
- `./scripts/check-gating.sh` and `./scripts/check-allocator-contracts.sh`
- all examples build; blog and GolfSim in-process/browser boundaries pass
- site build, doctor, static checks, and generated-doc checks pass
- live Docker grader passes from a clean target and leaves no scenario resources
- `git status --short` contains no generated mirrors, transcripts, data dirs, containers, or
  credentials

## Follow-up handoff

Once Task 9 passes, audit the Rails migration instance against this converter/decision/bundle/
grader interface. Rails may add pepper-aware bcrypt and frontend coordination, but it must not
weaken source-read-only extraction, typed decisions, bundle hashes, parity, or the three-run gate.
