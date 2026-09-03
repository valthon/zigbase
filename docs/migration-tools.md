> 📖 This documentation is also published, web-native, at <https://valthon.github.io/zigbase/docs/migration-tools> — the site is the canonical reading experience.

# Migrating an existing backend to ZigBase

This guide is about **re-platforming an application from another backend or framework**
onto ZigBase. It is not the SQLite-to-PostgreSQL database-backend guide.

- To move an existing ZigBase instance from SQLite to PostgreSQL, see
  [PostgreSQL backend](postgres.md#move-a-zigbase-instance-from-sqlite-to-postgresql).
- To evolve a ZigBase application's own schema over time, see
  [Explicit migrations](framework.md#explicit-migrations-migrations).

ZigBase ships four pieces of machinery for moving an existing application backend onto it: a
declarative schema format (`zigbase schema dump`/`apply`/`check-rules`), a scaled NDJSON data pump
(`zigbase import --manifest`), a legacy-password-hash import with rehash-on-login
(`zigbase import --legacy-hashes`), and a dependency-free parity-replay harness
(`tools/replay/zb_replay.py`). This guide covers all four end to end.

PocketBase 0.39.11 migrations also have a supported offline converter for inventory, durable
decisions, deterministic extraction, timestamp/password preservation, and local files. Follow
[Migrate PocketBase 0.39.11 to ZigBase](migrate-pocketbase.md) instead of hand-building the schema
and NDJSON described here.

Rails API-only migrations have a supported offline converter as well, driven by metadata observed
from the booted application rather than parsed from Ruby. Follow
[Migrate a Rails API to ZigBase](migrate-rails-api.md) instead of hand-building the schema and
NDJSON described here.

## 1. Re-platforming stages

A real migration — Rails, Express, or another backend you're moving off of — is a
sequence of stages. The supported PocketBase workflow follows the same sequence but automates
additional stages through its offline converter:

1. **Inventory** — enumerate the source's collections/tables, fields, and relations.
2. **Schema transplant** — stand up the equivalent shape in ZigBase.
3. **Data pump** — move the rows, preserving ids so relations still resolve.
4. **Auth migration** — bring user accounts over without forcing a mass password reset.
5. **Endpoint parity map** — decide what a client-facing URL/shape maps to on the new
   backend.
6. **Replay verification** — prove the new backend answers the same requests the same way.
7. **Cutover** — flip traffic.

The generic tooling in this guide covers stages 2, 3, 4, and 6 mechanically:

| Stage | Tool |
|---|---|
| 2. Schema transplant | `zigbase schema apply` (§2) |
| 3. Data pump | `zigbase import --manifest` (§3) |
| 4. Auth migration | `zigbase import --legacy-hashes` (§4) |
| 6. Replay verification | `tools/replay/zb_replay.py` (§5) |

For backends without a dedicated converter, stages 1, 5, and 7 stay **judgment work** — the
generic tools here do not inventory a foreign schema,
decides how a source endpoint's shape maps onto ZigBase's REST/query API, or flips a
load balancer. This guide's §6 stitches 2/3/4/6 into one worked sequence; §7 lists the
sharp edges you'll hit doing 1/5/7 by hand.

## 2. Declarative schema

### The document format

`zigbase schema dump` writes a canonical, deterministic JSON document describing every
**non-system** collection: fields (with their stable ids), indexes, access rules, and
collection options. Annotated example:

```json
{
  "zigbaseSchema": 1,
  "collections": [
    {
      "name": "posts",
      "type": "base",
      "fields": [
        {
          "id": "a1b2c3d4",
          "name": "title",
          "required": true,
          "unique": false,
          "encrypted": false,
          "searchable": true,
          "hidden": false,
          "type": "text",
          "options": { "min": null, "max": 120, "pattern": null }
        },
        {
          "id": "e5f6a7b8",
          "name": "author",
          "required": false,
          "unique": false,
          "encrypted": false,
          "searchable": false,
          "hidden": false,
          "type": "relation",
          "options": {
            "targetCollectionId": "authors",
            "cascadeDelete": false,
            "minSelect": null,
            "maxSelect": 1
          }
        }
      ],
      "indexes": [
        { "name": "idx_posts_title", "fields": ["title"], "unique": true }
      ],
      "listRule": "@public",
      "viewRule": "@public",
      "createRule": null,
      "updateRule": "@request.auth.id = author",
      "deleteRule": null,
      "options": {}
    }
  ]
}
```

Rules `dump` applies:

- **Non-system collections only.** `_superusers`, `_accounts`, and every other
  engine-owned table are never included — they're provisioned by migrations, not by you.
- **System fields are omitted.** Auth-injected columns (`passwordHash`, `tokenKey`,
  `verified`) are stripped; the engine re-injects them on create/update. Ordinary fields
  (including a custom field on an auth collection) are kept.
- **Collection ids are omitted** — they're instance-local (a fresh database assigns new
  ones); a document names collections by string, never by id.
- **Relation targets are written by name**, not by the target's id (`targetCollectionId`
  holds a collection *name* in the document), so a document is portable across instances.
- **OAuth client secrets are redacted** (emitted as `""`). **The document is not a
  secrets backup** — applying a redacted document back preserves whatever secret is
  already stored live; it never blanks it.
- **Deterministic**: collections are name-sorted and every object has stable key order,
  so the document diffs cleanly in git.

`--out FILE` writes to a file instead of stdout; `--json` is accepted (for symmetry with
`import --json`) and ignored — `dump`'s stdout is always the document itself.

### Apply semantics

`zigbase schema apply FILE` diffs the document against the live schema and executes the
difference through the **same validation and DDL path the REST collections API uses** —
there is no separate migration-only code path that could disagree with what `POST
/api/collections` would do.

- Collections are **matched by name**; fields within a matched collection are matched by
  their **stable id** (falling back to name for a field with no id in the document, e.g.
  hand-written). This is what lets a rename-by-id survive a table rebuild without losing
  data — see `schema.zig`'s stable-field-id mechanism in the main architecture docs.
- Apply is **scoped to the collections named in the document.** A live collection not
  mentioned in the document is reported as **`untracked`** and left alone; pass `--prune`
  to delete it instead (requires `--allow-destructive`).
- **Relation cycles get a two-pass apply.** Collections that reference each other (or a
  self-relation) can't all be created in one pass — one side's relation field has to wait
  until its target exists. `apply` computes a topological order with cycle detection,
  creates every collection first with the back-edge field omitted, then a second pass adds
  the deferred field back in once every target exists. Unlike the data pump (§3), this
  holds even for a **required** relation: `apply` is creating empty tables, not writing
  rows, so a table temporarily missing a `NOT NULL` column it's about to gain has no rows
  to violate the constraint. The pump can't make the same move — see §3's
  `RequiredRelationInCycle` for why loading actual rows through the same kind of cycle
  needs the field to be optional first.
- **Refused under `.collections_frozen`** — an app that comptime-locks its schema refuses
  `apply` outright, before touching anything.
- **A live server picks the change up on its own, within about five seconds.** A server keeps
  an in-process cache of parsed collection metadata, including *negative* lookups ("no such
  collection") — see `src/colcache.zig` — and `schema apply` is a separate CLI process, so it
  cannot invalidate that cache directly. Instead, every engine write to `_collections` bumps a
  one-row `_schema_state` generation marker inside its own transaction, and the server runs a
  background observer that polls the marker and drops the cache when it moves. The practical
  effect: apply any time, against a running server, and it takes effect there without a
  restart — but requests landing in the polling window still see the pre-change view, so a
  cutover that must be seen immediately should still restart the server. This applies equally
  to SQLite and Postgres, and runs under `.collections_frozen` too (which refuses `apply`
  itself, above, but not a rolling-deploy migration from another instance).
- **Every access rule in the document is syntax-checked first, and one bad rule refuses the
  whole apply.** Before any write derived from the document happens, all five rule fields of
  every collection the document declares are run through the filter lexer and parser (the
  same two modules `check-rules` uses — see §2's linting section). If any rule fails to
  parse, `apply` writes **nothing at all** — not even the collections whose rules are fine —
  prints the offending collection, rule field and error code on stderr, and exits `1`. This
  runs in `--dry-run` too, and *ahead of* the destructive check, so a document that is both
  unparseable and destructive exits `1` (the document is invalid) rather than `2`. There is
  no flag to skip it: nothing else in the engine validates a rule at write time, and a rule
  that fails to parse fails **closed** at request time (`500`), so `apply` is the last
  chokepoint before a typo becomes an outage.

  This gate is deliberately **syntax only** — it does not resolve field or relation names,
  and it does not report `@public`:

  - Full field resolution would cry wolf. A rule may legitimately name a field this same
    apply is about to add, or traverse a relation created in the second pass; resolved
    against the not-yet-updated live schema those read as errors. A linter that
    false-positives during apply gets suppressed, and a suppressed linter protects nothing.
  - Exit code `2` is frozen as "`--dry-run` found destructive changes". Reporting `@public`
    rules or resolution findings from `apply` would have to land on exit `2`, and an agent
    branching on `2` must never have to work out whether it means "you just opened a
    collection to the public" or "destructive schema change pending". Overloading a frozen
    exit code to save a flag is a bad trade.
  - Judgment-shaped findings live in `zigbase schema check-rules`, where exit `2` already
    means "needs judgment" and where you asked for an opinion. Run it against the document
    before `apply`, and again at full depth once the collections exist — that is exactly the
    two-step in §6's worked migration.
- **Every collection is validated first, and one bad field refuses the whole apply.** The
  same check `POST /api/collections` runs — collection and field names, reserved names,
  duplicate fields, index and `select`/`number`/`date`/`relation` option constraints,
  `tenant_field`/`ttl_field`, and the encryption/full-text rules — is run over every
  collection in the document *before any write*. Every problem in the document is printed at
  once, on stderr, with its error code (e.g. `validation_invalid_name`,
  `validation_reserved_name`), and `apply` exits `1` having written nothing.

  Like the rule gate, this runs in `--dry-run` **and** in the real run, from the same call,
  so a rehearsal refuses exactly what a run refuses. Failures that need the *live* schema —
  a relation whose target exists nowhere, a name already taken — still surface from the
  write itself, which is rolled back whole.
- **Atomic across collections.** All three passes — creates and updates, the second pass
  that closes relation cycles, and `--prune` — run inside **one** transaction, which
  `collections.create`/`update`/`delete` join with a `SAVEPOINT` rather than opening their
  own. If collection 3 of 5 fails, nothing is left behind: not the first two, not their
  `_collections` rows, not the schema-generation bump. Fix the document and re-run against
  the state you started from. The emitted `applied` list is therefore empty on a failure.
- **`dump` → `apply` is a no-op**, and stays one: re-running `apply` against an
  already-converged document changes nothing — no timestamp bump, no table rebuild, not
  even on a document containing a relation cycle. This holds for GitOps-style repeated
  applies, not just a single round trip.
- **`--dry-run` is not a true no-op.** It computes and prints the plan without executing
  it, but reaching that point still boots the app — system migrations and the comptime
  `.collections` provisioning run first, and those *do* write, same as any other startup.
  What `--dry-run` guarantees is that the *document's own* changes are not applied; it is
  not a read-only connection to an already-running database. `import --dry-run` (§3) has
  the same caveat.
- **`--json` is accepted and ignored** on `apply`, exactly as on `dump` — stdout is
  already the one JSON object described below; there is no separate flag needed to get it.

Exit codes:

| Code | Meaning |
|---|---|
| `0` | Success, or `--dry-run` found no destructive changes. |
| `1` | The command failed (bad document, an unparseable access rule, refused operation, DB error). |
| `2` | `--dry-run` found **destructive** changes (drop/retype) that `--allow-destructive` would be needed to apply. |

**Round-trip guarantee:** `schema dump` on a freshly-`apply`-ed database, re-`apply`-ed,
produces zero changes. This is what makes the document a reliable thing to commit: what
you see in the file is what's live, byte for byte in effect (never in the literal OAuth
secret bytes — see above).

### Stdout JSON (machine contract)

Every `schema apply` invocation — dry run or real, success or a refusal that still gets
as far as computing a plan — prints exactly one JSON object to stdout (logs go to
stderr). This is the shape an agent or CI job should parse; it is emitted by
`emitApplyJson` in `src/framework.zig`, verified field-for-field against that function:

```jsonc
{
  "zigbase_schema_apply": 1,        // format discriminator, currently always 1
  "dry_run": false,                 // echoes --dry-run
  "allow_destructive": false,       // echoes --allow-destructive
  "destructive": false,             // true iff `changes` contains a destructive kind (see below)
  "changes": [                      // the full diff, in no particular order
    { "kind": "modify_index", "collection": "posts", "field": null, "detail": "idx_posts_slug" }
  ],
  "untracked": ["legacy_table"],    // live, non-system collections the document doesn't name
  "deferred_relations": [           // relation fields held back to break a create-order cycle
    { "collection": "a", "field": "toB" }
  ],
  "applied": ["posts"],             // collections actually written this run, in write order
  "apply_order": ["authors", "posts"] // full topological create/update order (cycle back-edges omitted)
}
```

Every `changes[]` entry has `kind` (see the table below), `collection` (name), `field`
(the affected field name, or `null` for a collection- or index-level change), and
`detail` (a human string — NOT part of the contract; do not match on its content, only
on `kind`).

**The `kind` values are a frozen, append-only wire contract** — the enum tag name IS the
JSON string (`schema_diff.zig`'s `ChangeKind`), and both the doc comment on the type and
this table are load-bearing for anything that scripts against `schema apply`. A kind is
never renamed or removed; a new one may be appended.

| `kind` | Meaning | Destructive? |
|---|---|---|
| `create_collection` | A collection in the document doesn't exist live yet. | No |
| `add_field` | A field in the document is absent from the live collection. | No |
| `modify_field` | A field exists on both sides but differs (options, required, unique, etc. — not type). | No |
| `rename_field` | Same stable field id, different name. | No |
| `add_index` | An index name in the document isn't defined live. | No |
| `drop_index` | A live index's name is absent from the document. | No |
| `modify_rules` | `listRule`/`viewRule`/`createRule`/`updateRule`/`deleteRule` differ. | No |
| `modify_options` | Collection-level `options` differ (e.g. auth settings). | No |
| `modify_index` | Same index name on both sides, but its definition differs (columns, `unique`, collation, or `where`). | No |
| `retype_field` | A field's underlying storage type changed. | **Yes** |
| `drop_field` | A live field is absent from the document. | **Yes** |
| `drop_collection` | A live, non-system collection absent from the document, only reported with `--prune`. | **Yes** |

Exactly the last three are destructive (`schema_diff.isDestructive`); `destructive` at
the root and exit code `2` on `--dry-run` both key off that same three-way boundary —
nothing else in the table ever sets them, including `modify_index`: rewriting an index's
definition drops no column and no table, only the index object itself, which SQLite/
Postgres recreate atomically as part of the same collection update.

### Linting access rules (`schema check-rules`)

**Access rules are never validated when they are written.** `schema.parseCollectionInput`
decodes `listRule`/`viewRule`/`createRule`/`updateRule`/`deleteRule` as opaque strings and
`collections.create`/`update` bind them straight into `_collections` — the REST API does the
same. The first thing that ever parses a rule is the request that has to evaluate it, and a
rule that fails to parse fails **closed** (`500`, and on a write the write never runs). So a
typo'd rule applies cleanly, ships, and takes the collection down on the first request that
touches it. `zigbase schema check-rules` is the preflight that closes that gap.

It does **not** reimplement the grammar: the live check calls `rules.compileGuard`, the exact
function the request path calls (lexer → parser → joiner → compiler), and the document check
calls the same lexer and parser modules, just stopping before the stages that need a database.

```bash
zigbase schema check-rules schema.json                 # DOCUMENT mode — syntax depth
zigbase schema check-rules --data-dir ./zb_data        # LIVE mode — full depth
```

#### Two modes, two depths

| Mode | Invocation | `depth` | What it can catch |
|---|---|---|---|
| Live (default) | no positional; reads `--data-dir` | `"full"` | Malformed expressions **and** unknown fields, non-relation traversals, unjoinable multi-relation paths, encrypted-field comparisons. |
| Document | a `schema.json` positional | `"syntax"` | Malformed expressions only. |

The difference is not a limitation of the linter — it is where the information lives. Field
and relation names are resolved by the *joiner*, which looks the target collection up in the
database. A document carries no live schema and no connection, so `viewRule: "nope = \"x\""`
is perfectly well-formed syntax and passes document mode; only the live check knows `nope`
isn't a column. **Every run states its depth in the summary**, and a clean `"syntax"` run is
not a clean bill of health: lint the document in CI to catch typos before review, then run
the live check after `schema apply` to catch everything else. (Building a throwaway instance
to fake a full check offline would duplicate `apply`'s two-pass create ordering, so it is
deliberately not done.)

`schema apply` does **not** run this automatically — whether it should is an open design
question, not a settled default.

#### Policy: what is and is not a finding

Rule policy sits above the parser (`rules.decide`), so three values never reach it:

- `null` and `""` both mean **Locked** (superusers only) — the safe default. Never a finding,
  and not counted in `rules_checked` (they are not rules).
- `"@public"` is the one allow-all sentinel. Reported as a **warning**, not an error: the rule
  is valid, but opening a collection to everyone is a judgment an operator should confirm.
  This deliberately overlaps `doctor`'s `public-rules-enumerated` check at a *different
  lifecycle stage* — `doctor` asks "what is this running server exposing right now?",
  `check-rules` asks "what is this document/schema about to expose?". Both are wanted;
  neither replaces the other, and `doctor`'s frozen check-id ledger is untouched by this.

System collections are skipped entirely.

#### Output (machine contract)

NDJSON on stdout, exactly like `doctor`: one compact object per finding, terminated by
exactly one summary object whose **first** key is `"summary"` (so a line-skipping reader
identifies it by content, not by position). Human text goes to stderr. There are **no
per-rule "ok" lines** — a clean run prints only the summary, and `rules_checked` is what
tells you the silence covered something. `--json` is accepted and ignored; NDJSON is the
only format.

```jsonc
{"collection":"posts","rule":"listRule","severity":"error","code":"UnknownField","message":"the rule references a field this collection does not have"}
{"collection":"posts","rule":"viewRule","severity":"warn","code":"PublicRule","message":"the rule is \"@public\": this collection is open to everyone, unauthenticated included"}
{"summary":true,"depth":"full","collections":1,"rules_checked":3,"errors":1,"warnings":1}
```

Finding keys (key order is the wire order; frozen and append-only):

| Key | Meaning |
|---|---|
| `collection` | Collection name. |
| `rule` | `listRule` \| `viewRule` \| `createRule` \| `updateRule` \| `deleteRule` — camelCase, mirroring the document's own field names, so a finding names the key you edit. |
| `severity` | `"error"` (the rule does not compile) or `"warn"` (`@public`). |
| `code` | The machine field: the pipeline's own `@errorName` — `UnexpectedChar`, `UnterminatedString`, `InvalidEscape`, `UnexpectedToken`, `BadOperand`, `Empty`, `TooDeep`, `BadFilter`, `BadValue`, `UnknownField`, `NotARelation`, `MultiRelationTraversal`, `EncryptedField`, `HiddenField`, … — or `PublicRule` for the `@public` warning. |
| `message` | Human gloss. **Not** a contract; match on `code`. |

There is deliberately **no position or column**: every stage of the query pipeline returns a
bare error enum with no location and no text, so a reported offset would be invented.

Summary keys:

| Key | Meaning |
|---|---|
| `summary` | Always `true` — the discriminator. |
| `depth` | `"full"` or `"syntax"` (see above). |
| `collections` | Non-system collections examined. |
| `rules_checked` | Non-blank rules examined, `@public` included. The coverage number. |
| `errors` / `warnings` | Finding counts by severity. |

Exit codes — exactly `doctor`'s mapping:

| Code | Meaning |
|---|---|
| `0` | No findings. |
| `1` | At least one rule failed to parse or compile. |
| `2` | No errors, but at least one warning (an `@public` rule). |

An infrastructure failure (unreadable file, invalid document, DB error) exits non-zero with a
stderr message and no summary — the lint could not run, which is different from finding
nothing.

## 3. Data pump

### NDJSON row shape

`zigbase import` streams NDJSON (one JSON object per line) into a collection **through
the record engine** — the same validation, defaults, `.encrypted` envelope, and (for an
auth collection) credential provisioning a live `POST /api/collections/<c>/records`
would apply. There is no bypass: a row that wouldn't pass the REST API doesn't pass
`import` either.

**Id preservation.** By default, each row's own `id` is preserved rather than replaced
with a fresh one. This is deliberate (decision D8 in the plan): a migrated dataset's
relations reference source ids, and only by keeping them does `posts.author = "abc123"`
still resolve after the pump. This is import-only — the HTTP/route/hook create path never
honors a client-supplied id.

### Manifest format

`--manifest FILE` loads several collections from one manifest in relation-dependency
order, instead of invoking `import` once per collection by hand:

```json
{
  "zigbaseImportManifest": 1,
  "collections": [
    { "collection": "authors", "file": "authors.ndjson" },
    { "collection": "posts", "file": "posts.ndjson", "upsertKey": "slug" }
  ]
}
```

`file` paths resolve against the **manifest's own directory** (not the current working
directory), so a migration bundle — manifest plus its NDJSON files — is relocatable as a
unit.

**Ordering and deferred relations.** Collections load in the order their relations
require (`authors` before `posts`, above). A cross-collection relation **cycle**, or a
**self-relation** (a collection referencing itself, e.g. `authors.mentor -> authors`),
defeats any single load order — some row has to reference an id that doesn't exist yet.
The manifest runner handles this the same way `schema apply` handles a schema cycle:
strip the offending relation value on load, then patch it back in by record id once every
target row exists. **A row headed for a deferred field must carry its own `id`** — the
patch pass matches purely by id, so an id-less row's cyclic/self relation can never be
backfilled. A **required** field on a cycle back-edge or self-relation is refused up front
(`RequiredRelationInCycle`) for the same reason `schema apply` refuses one — see §2.

### Flags

- **`--dry-run`** — execute every row through the full engine (validation, defaults,
  encryption, auth transforms), then roll back instead of committing: no record data is
  written. It is not a true no-op, though — reaching that point still boots the app, and
  system migrations and the comptime `.collections` provisioning run first and *do* write,
  same as any other startup (see §2's `schema apply --dry-run` caveat, which shares this
  boot path). A bad row still fails the same way it would for real.
- **`--continue-on-error`** — isolate each row in its own `SAVEPOINT` and skip a failing
  one instead of aborting the whole run. Paired with **`--error-log FILE`**, every skip is
  logged as one NDJSON line: `{"line":N,"code":"...","detail":"..."}`.
- **`--progress N`** — print a heartbeat to stderr every N rows (`0` = off).
- **`--json`** — print the run summary as one JSON object on stdout instead of (or
  alongside) the human log line: `{"zigbase_import":1,"collection":"...","dry_run":...,
  "preserve_timestamps":false,"created":N,"updated":N,"failed":N,"total":N,
  "error_log":"..."}`. `import --manifest`'s
  summary uses the `zigbase_import_manifest` discriminator instead, plus a `collections`
  array of per-entry counts and a `patched` count (rows whose deferred relation value was
  backfilled in the second pass).
- **`--preserve-timestamps`** — preserve each row's source `created` and `updated` strings
  after validating them as dates. Every row must carry those two values and a non-empty `id`.
  This is a create-only migration seam: it requires id preservation and refuses
  `--upsert-key` (including a manifest entry's `upsertKey`). The record is still created
  through the normal engine; only those two system columns are replaced inside the same
  transaction. HTTP, route, hook, and ordinary import writes remain unable to author system
  timestamps.

### Exit codes

| Code | Meaning |
|---|---|
| `0` | Every row imported cleanly. |
| `1` | The import failed outright (fatal error, bad manifest, unknown collection). Batches committed before the failure persist — a resumable checkpoint. |
| `3` | **The import completed but skipped rows** (only reachable with `--continue-on-error`). A lossy import is never reported as exit `0` success. |

## 4. Legacy password import

### Workflow

`zigbase import --legacy-hashes ALG` (currently `ALG` = `bcrypt` only) imports each row's
existing password hash **as-is**, without your users having to reset anything, and
transparently upgrades it to argon2id the next time they log in successfully.

The imported hash is stored in the ordinary `passwordHash` column, tagged:

```
$zblegacy$<alg>$<original-hash>
```

e.g. `$zblegacy$bcrypt$$2b$10$abcdefghijklmnopqrstuv...` — note the doubled `$` between
`bcrypt` and `2b`: the tag's own trailing `$` is followed immediately by the bcrypt hash's
leading `$`. On the next successful login,
the stored value is verified against the tagged hash and then **rewritten as an ordinary
argon2id hash** — from that point the row is indistinguishable from one that was always
native.

**The bcrypt allowlist.** `$2a$`, `$2b$`, and `$2y$` are accepted (they're the same KDF
under different historical version markers). **`$2x$` is refused** — it marks the
deliberately-preserved `crypt_blowfish` 8-bit-handling bug, which this implementation
does not reproduce, so silently accepting it would mean *any* password containing a
high-bit byte would never again verify. A `$2x$` hash needs to be re-derived (or the
account reset) before import.

**72-byte truncation.** Like every mainstream bcrypt implementation (PHP, Go, Node,
Python), verification silently truncates the password at 72 bytes rather than pre-hashing
past it — this matches what the *source* system did when it created the hash, so a
long password still verifies correctly.

**`verified` carry-over.** A row's `verified` flag is imported as-is. Without this, a
cutover would mail every migrated user a "please verify your email" demand on day one.

### Requirements and refusals

- Requires the target to be an **auth** collection (`LegacyRequiresAuthCollection`
  otherwise).
- **`_superusers` always refuses** legacy-hash import (`LegacySuperuserRefused`) —
  there is no migration story for the admin account; create it fresh with
  `zigbase superuser create`.
- Requires **id preservation** (the default) — a legacy credential is matched to its row
  by the row's own source `id`, so importing with an id-replacing flag combination is
  refused (`LegacyRequiresPreservedIds`).
- A row carrying **both** `password` and `passwordHash` is refused (`LegacyHashConflict`)
  — ambiguous which credential should win.
- A row targeted for legacy import must carry its own `id` (`LegacyRowMissingId`).
- **Create-only.** `--legacy-hashes` cannot be combined with `--upsert-key`
  (`LegacyRequiresCreateOnly`; the CLI also refuses the flag pair as a usage error). The
  upsert path *updates* a matched row and never installs a credential, so accepting the
  combination would silently leave every matched user without a password and still exit
  `0`. The same refusal fires for a **manifest entry carrying `upsertKey`** under a
  run-level `--legacy-hashes`. Run the legacy import as its own create-only import.
- **`--legacy-hashes` applies uniformly to the whole run.** `import --manifest` shares one
  `Options` value across every entry in the manifest — there is no per-entry
  `legacyHashes`. `--manifest FILE --legacy-hashes bcrypt` therefore does not mean "hash
  the `users` entries and load the rest normally"; it means "every entry in this manifest
  is a legacy-hash row", and aborts (`LegacyRequiresAuthCollection`) at the first
  non-auth collection the manifest names. A legacy-hash import must be its own
  single-collection, users-only run — see §6's worked sequence.

### The upgrade-on-login mechanic

Every password-verification site (`authWithPassword`, the password auth method's
completion handler, and the `oldPassword` check on a record update) routes through one
helper that: verifies against whichever form is stored (native argon2id, or a tagged
legacy hash); on a **successful** legacy verification, immediately rewrites the row to a
fresh argon2id hash, guarded by `WHERE passwordHash = <the old stored value>` so a
concurrent duplicate login can't race the upgrade into running twice. An upgrade write
failure is logged and swallowed — it **never** turns a valid login into a failure.

Operator progress query, to track how many accounts remain on legacy hashes:

```sql
SELECT count(*) FROM users WHERE "passwordHash" LIKE '$zblegacy$%';
```

## 4b. External identities (OAuth / OmniAuth / social login)

An account that authenticates through a provider has no password, so `--legacy-hashes` does
nothing for it. What it needs instead is its **provider linkage** — the `(provider, providerId)`
pair that tells ZigBase which record an incoming identity resolves to. Without it a migrated
social-login user is locked out: their first sign-in finds no link, cannot create a record
because the email already exists, and is refused
`409 Email already registered; sign in and link instead.` — with no password to sign in with.

Carry the linkage on the auth row itself and import it with `--external-auths`:

```json
{"id":"42","email":"ada@example.test","externalAuths":[{"provider":"google","providerId":"110…"}]}
```

```sh
zigbase import --collection users --external-auths --preserve-timestamps \
  --data-dir ./zb_data users.ndjson
```

The record and its linkage are written in one transaction, so an account and the identity that
reaches it commit or roll back together — there is no state where the user exists but cannot
sign in.

**Constraints, each of which is a refusal rather than a warning:**

- **Off by default.** Without `--external-auths` the array is ignored, exactly as `passwordHash`
  is ignored without `--legacy-hashes`. A file alone can never mint an identity link.
- **The provider must already be declared** on the target collection's `auth.oauth2.providers`.
  Apply your schema first. A link naming an unconfigured provider could never resolve at login,
  so importing one would report success and leave the account unreachable.
- **A `providerId` already linked to any record is a hard failure**, never a re-point. Silently
  moving an existing identity to a different account is account takeover.
- **Auth collections only, `_superusers` refused, create-only, and an id is required** on every
  row. An upserted row returns before the linkage is written, which would leave the account
  unreachable — the exact failure this seam removes.
- **Identity only.** Provider access and refresh tokens are credentials and never migrate;
  neither do sessions. `externalAuths` is stripped from every client payload by
  `auth.isServerManagedField`, so this seam is reachable only by an operator with local disk
  access.

Verify afterwards, before cutover:

```sql
SELECT "provider", count(*) FROM "_externalAuths" GROUP BY "provider";
```

### Security constraints

These are non-negotiable properties of the legacy-hash machinery, reproduced here
verbatim from the design plan:

1. **Explicit hardcoded algorithm allowlist**, matched against the hash's explicit tag,
   never inferred from the hash's own prefix — an untagged foreign hash matches no
   verifier and fails closed.
2. **No downgrade path** — only the offline `import --legacy-hashes` writes a
   `$zblegacy$` value; login rehash only ever writes argon2id; the REST/records path
   keeps stripping `passwordHash` from every client payload via
   `auth.isServerManagedField`. Nothing ever writes a legacy hash back after an upgrade.
3. **Rehash only on a successful verification**, in the same request, before the response
   is written.
4. **Import requires operator-level/local-disk access.** No REST seam is added for
   legacy-hash import; if one is ever added, it must go through `requireSuperuser`.
5. **Constant-time comparison parity** is preserved on both verification paths. One
   accepted residual: bcrypt's and argon2id's different verification costs mean response
   timing can distinguish a **not-yet-migrated** account from a **migrated** one — it
   **cannot** distinguish an **existing** account from a **non-existent** one, because
   `dummyVerify` still covers the unknown-identity path.
6. **`_superusers` never accepts a legacy hash** — import refuses it outright (see above).

## 5. Parity replay

`tools/replay/zb_replay.py` is a standalone, dependency-free Python 3 tool — **not** a
`zigbase` subcommand, because it has to run against an *old* backend (PocketBase, Rails,
an older ZigBase, anything that speaks HTTP/JSON) to record expectations, so it can't
assume anything about what it's talking to. Full reference:
[`tools/replay/README.md`](../tools/replay/README.md).

### Capture format (NDJSON, one case per line)

| Key | Meaning |
|---|---|
| `id` | Stable, unique case identifier. Required. Strings are recommended; numeric v1 identifiers remain accepted. Findings key off it. |
| `method`, `path` | Required. `method` is an HTTP token. `path` is absolute and appended to `--base-url`. Legacy query-bearing paths, percent escapes, and raw Unicode remain valid in v1; prefer `query` for new captures. |
| `query` | Object of string → string. Optional. |
| `headers` | Only the headers that matter. `{{name}}` placeholders resolve from `--var`. |
| `body` | JSON value or `null`. Sent as `application/json` when non-null. |
| `expect.status` | Exact match. Omitted or `null` means no status expectation. |
| `expect.bodySubset` | Recursive **subset** of the response body. |
| `expect.control` | Optional producer-reviewed semantic label. Predeclare it before `record`; recording preserves it while refreshing status/body. |
| `followRedirects` | Optional boolean, default `true` for v1 compatibility. Set `false` when the first `3xx` response is itself the evidence. |

### Subset matching

`expect.bodySubset` is a recursive subset, not equality: every key present in the
expectation must exist and match in the actual response, but extra response keys are
fine, and arrays compare element-wise up to the expectation's length (a longer actual
array is not a failure). Matching on full equality would fail on every field the old and
new backends legitimately disagree on. A key that's **entirely absent** from the actual
response is always a diff — even when the expectation holds `null` — so an expectation of
`null` still requires the key to exist, not merely be unset or missing (this is what
catches a migration silently dropping a nullable field, e.g. `deletedAt`).

### Volatile keys

Stripped recursively from the response at **record** time, so they never become
expectations: `id`, `created`, `updated`, `token`, `collectionId`, `collectionName`,
`expand`. Add more with repeatable `--volatile KEY`.

### The two commands

```bash
zb_replay.py record --base-url URL --requests requests.ndjson --out capture.ndjson \
    [--var NAME=VALUE ...] [--volatile KEY ...]
zb_replay.py replay --base-url URL capture.ndjson [--out findings.ndjson] \
    [--var NAME=VALUE ...]
```

`record` runs each case in `requests.ndjson` against the **old** backend and fills in
`expect.status` and `expect.bodySubset` from the actual (volatile-stripped) response while preserving
an explicitly supplied `expect.control`. `replay` runs a capture against
the **new** backend and diffs each response against its `expect`. Explicit `"expect": null`
retains its historical meaning of no expectation. Before replay, every recorded control is checked
against its status classification. `record` atomically replaces a complete capture with private
`0600` permissions; `replay` atomically installs private `0600` findings only after every case has
run, since response diffs may contain sensitive values. Both outputs flush the completed payload
before replacement. Validation and failures before replacement leave
the previous complete artifact unchanged.
Binary responses remain usable as status evidence. Because v1 has no binary-body encoding, `record`
omits `bodySubset` for a non-UTF-8 response; a textual `bodySubset` against one becomes a parity diff
rather than a transport failure. Use byte-oriented tests when body content itself matters.
Replay ignores ambient HTTP proxy variables. It follows redirects by default for v1 compatibility,
but strips credentials when a redirect crosses origins; set `followRedirects` to `false` when the
first `3xx` response is itself the evidence.

Put query parameters in the `query` object for new captures. Query and header names and values are
strings. The complete file is size-bounded and validated as strict UTF-8/RFC JSON before any request
is sent. Resolved paths are checked again immediately before network I/O for unresolved placeholders
and control characters; empty inputs fail because they exercise nothing, non-RFC JSON responses are
compared as raw text, and emitted artifacts always use strict JSON. Response bodies are bounded to
32 MiB; non-UTF-8 bodies remain available for status-only evidence.

### Findings and summary channels

Findings stream as NDJSON to `--out` (default `findings.ndjson`); the run summary is one
JSON object printed to stdout. These never share a channel — script around the summary
without parsing the findings stream, or vice versa.

### Exit codes

| Code | Meaning |
|---|---|
| `0` | All cases passed (or, for `record`, the recording run completed). |
| `1` | Tool failure — unreadable capture, an unresolved `{{placeholder}}`, or **every** case dying in transport on a replay (the target itself was unreachable, so nothing could actually be exercised). |
| `2` | Ran correctly; at least one case has a parity failure, and/or **some** (not all) cases errored in transport on a live run. A per-case transport error alongside other passing cases is parity signal, not a tool failure — an endpoint that vanished between the old backend and the new one is exactly the kind of thing this tool exists to catch, so it's folded into the findings as exit `2`. |

### Worked example

Record against the old backend, replay against the new one:

```bash
cat > requests.ndjson <<'EOF'
{"id":"posts-list","method":"GET","path":"/api/collections/posts/records","query":{"perPage":"5"}}
EOF

python3 zb_replay.py record --base-url http://old-backend:8080 \
    --requests requests.ndjson --out capture.ndjson
```

`capture.ndjson` now holds, roughly:

```json
{"id":"posts-list","method":"GET","path":"/api/collections/posts/records",
 "query":{"perPage":"5"},"expect":{"status":200,"bodySubset":{"items":[{"title":"Hello"}]}}}
```

```bash
python3 zb_replay.py replay capture.ndjson --base-url http://localhost:8090 \
    --out findings.ndjson
echo "exit=$?"
```

A parity break (say the new backend paginates under a different key) lands in
`findings.ndjson` as one line naming the case id, the expected/actual status, and a
`diff` array of the mismatched paths — and the process exits `2`.

## 6. Worked end-to-end migration

A single copy-pasteable sequence, once you've hand-inventoried the source schema into a
`schema.json` document (§2) and exported the source data into a manifest bundle (§3):

```bash
# 1. Sanity-check the schema transplant before touching a live database. `check-rules` on
#    the document is SYNTAX depth only (it has no live schema to resolve names against).
zigbase schema check-rules schema.json
zigbase schema apply schema.json --dry-run --data-dir ./zb_data

# 2. Actually create the collections, then re-lint at FULL depth now that there IS a live
#    schema — this is the pass that catches a rule naming a field that doesn't exist.
zigbase schema apply schema.json --data-dir ./zb_data
zigbase schema check-rules --data-dir ./zb_data

# 2a. A server already running against this data dir picks the change up on its own within
#     about five seconds (it polls the `_schema_state` marker — see §7). Requests in that
#     window still see the old view; restart it if the cutover must be seen immediately.

# 3. Bring user accounts over first, without a mass password reset. Relation values
#    validate their target exists, and a single relation carries a real foreign key, so
#    any manifest entry relating to `users` (step 5) would fail every row if `users`
#    weren't already populated. `--legacy-hashes` is its own create-only, users-only run
#    — see the note at the end of §4 for why it can't be folded into the manifest step.
zigbase import --collection users --legacy-hashes bcrypt --data-dir ./zb_data users.ndjson

# 4. Rehearse the rest of the data pump — every row validated, nothing written.
zigbase import --manifest manifest.json --dry-run --data-dir ./zb_data

# 5. Actually load the data. `users` already exists (step 3), so relations into it resolve.
zigbase import --manifest manifest.json --data-dir ./zb_data

# 6. Verify the new backend answers the same requests the old one did.
python3 tools/replay/zb_replay.py replay capture.ndjson --base-url http://localhost:8090

# 7. Commit the resulting schema as the new source of truth.
zigbase schema dump --out schema.json --data-dir ./zb_data
```

## 7. Limitations

- **`schema apply` checks access-rule SYNTAX only** — it refuses a document containing an
  unparseable rule (see §2's apply semantics), but it does not resolve field or relation
  names, so a rule naming a field that does not exist still applies cleanly and fails closed
  at evaluation time (500). The REST API validates neither. Run `zigbase schema check-rules`
  (§2) against the data dir *after* applying for the full-depth pass; `apply` never runs
  that depth itself. Exercising every rule once via the replay harness (§5) before cutover
  remains worthwhile too — the linter proves a rule *compiles*, not that it *decides* what
  you meant.
- **Collection rename is not supported by the engine** (`collections.update` preserves
  the stored name), so a renamed collection in a document reads as create + untracked.
- **A live server sees another process's schema change within about five seconds, not
  instantly** — it polls the `_schema_state` generation marker and then drops its
  collection cache (see §2's apply semantics for the mechanism). Requests in that window
  still see the pre-change view; restart the server if the cutover must be seen at once.
- **`import --manifest`'s deferred relation values (cycles, self-relations) require the
  source row to carry its own `id`** — the patch pass matches purely by id, and a
  **required** field on a cycle back-edge or self-relation is refused up front
  (`RequiredRelationInCycle`), since a legal two-pass row load doesn't exist for it.
  `schema apply`'s own cycle handling is unaffected (see §2) — it defers a *field
  definition* between two passes over empty tables, not a *row value*.
