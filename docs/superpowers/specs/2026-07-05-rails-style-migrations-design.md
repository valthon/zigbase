# Rails-Style Migrations — Design

**Status:** Approved (design). Ready for implementation planning.
**Date:** 2026-07-05
**Related issue:** #241 (`Migrator.records()` — records-aware migrations) is folded into this work (Piece A).

## Goal

Make ZigBase's migration escape hatch Rails-nice: a dialect-aware schema DSL,
auto-reversible migrations with rollback, transactional-by-default (already the
case) with an opt-out, and a schema dump — **without** introducing a second
schema-definition paradigm.

## Foundational model (decided): augment the escape hatch

The comptime `.collections` literal **stays the source of truth** and is
auto-provisioned at boot (additive create-missing + field-add). Migrations remain
the escape hatch for the non-additive / custom DDL provisioning won't perform.
This work makes *that escape hatch* ergonomic; it does **not** turn migrations
into an alternative schema source. Consequently "schema dump" here means "dump the
live DB's structure for inspection/diff/test-setup," not "the canonical schema
that drives provisioning."

Rejected alternative: migrations as a co-equal/alternative schema source (Rails
`schema.rb`-as-truth). It forks "how do I define schema?" into two competing
answers and cuts against ZigBase's comptime-first identity.

## Current state (what exists today)

- `Migration = struct { name: []const u8, up: *const fn (*Migrator) DbError!void }`
  — name + a forward-only `up`. No `down`, no checksum, no DSL.
- `up` writes raw, dialect-lowered SQL via `m.execLowered(portable_sqlite_sql)`
  (the dialect lowers INTEGER→BIGINT, `?N`→`$n`, etc.) and `m.dialect.*` helpers.
- Ledger: the `_migrations` table (`id` autoincrement PK, `name` UNIQUE,
  `applied_at`). `run()` skips already-applied (by name), and **already wraps each
  migration in a transaction** (`begin → up → commit`).
- Consumer `.migrations` run in order, before comptime provisioning.
- CLI: `zigbase migrate` runs migrations. No `rollback` / `status` / `dump`.

## Design

### 1. Migration type (backward-compatible)

```zig
pub const Migration = struct {
    name: []const u8,
    /// Auto-reversible forward change (the Rails `change` method). Applied forward
    /// normally; rollback re-runs it with the Migrator in reverse mode.
    change: ?*const fn (*Migrator) MigError!void = null,
    /// Explicit forward step (use when the change isn't auto-reversible).
    up: ?*const fn (*Migrator) MigError!void = null,
    /// Explicit reverse step for rollback (pairs with `up`, or overrides `change`).
    down: ?*const fn (*Migrator) MigError!void = null,
    /// Per-migration transactional opt-out for DDL that cannot run inside a tx
    /// (e.g. Postgres `CREATE INDEX CONCURRENTLY`). Default true (today's behavior).
    transactional: bool = true,
};
```

- Comptime validation: exactly one of `change` or `up` must be set (a forward step
  is required); `down` requires a forward step — a lone `down` (no `up`, no
  `change`) is an error. Valid combinations: `change` alone (auto-reversible);
  `change` + `down` (auto-forward, explicit reverse override); `up` alone
  (irreversible); `up` + `down` (explicit both).
- **Backward compatibility:** today's `{ name, up }` remains valid — it is a
  forward-only, irreversible migration (rollback of it errors unless a `down` is
  added). The config-lowering that maps the `.migrations` tuple `.id` field to the
  Migration `name` is preserved.

### 2. The Migrator DSL (portable-by-default + per-statement dialect breakout)

A curated op set for v1 (YAGNI — add more as needed), each emitting correct
SQLite/Postgres SQL through the existing dialect lowering:

- `createTable(name, columns, opts)` / `dropTable(name, opts)`
- `addColumn(table, column)` / `dropColumn(table, name, opts)`
- `renameColumn(table, from, to)` / `renameTable(from, to)`
- `addIndex(table, columns, opts)` / `dropIndex(name, opts)`
- `addForeignKey(table, column, ref_table, ref_column, opts)`

Column/type specs are expressed with a small typed vocabulary that maps to
dialect-native types (reusing `m.dialect.sqlType`).

**Per-statement breakout (i)** — freely mixed inside one `change`/`up`:
- `m.exec("portable SQLite-flavor SQL")` — dialect-lowered, as today (`execLowered`).
- `m.raw(.{ .sqlite = "…", .postgres = "…" })` — a statement that genuinely diverges.
- `m.rawFor(.postgres, "…")` — a one-backend-only statement (no-op on the other).

**Records-aware data transforms (#241):** `m.records()` exposes the records layer
inside a migration so data transforms (e.g. re-encrypting a field) go through the
real record read/write path rather than raw SQL. Data operations are **not**
auto-reversible (see §3).

### 3. Auto-reversibility

The `Migrator` carries a `direction: enum { forward, reverse }`. Applying a
migration runs `change(m)` with `direction = .forward` (or `up`). Rolling one back
runs `change(m)` with `direction = .reverse` (or `down`).

In **reverse** mode, each DSL op emits its inverse:

| forward op | reverse (inverse) |
|---|---|
| `createTable` | `DROP TABLE` |
| `addColumn` | `DROP COLUMN` |
| `addIndex` | `DROP INDEX` |
| `renameColumn(a→b)` | `renameColumn(b→a)` |
| `renameTable(a→b)` | `renameTable(b→a)` |
| `addForeignKey` | drop the FK |
| `dropTable` / `dropColumn` | re-create **only if** the original definition was supplied to the op (Rails parity: `dropColumn(table, name, .{ .was = <column spec> })` is reversible; without `.was` it is irreversible) |

**Not auto-reversible** → the op **errors in reverse mode** with a clear message
("`<op>` is not auto-reversible in a `change` migration; provide `up`/`down`"):
- `m.exec` / `m.raw` / `m.rawFor` (arbitrary SQL — no known inverse)
- `m.records()` data transforms
- a `dropTable`/`dropColumn` without the original definition

For those, the author writes explicit `up` + `down`. A migration may not mix an
auto-reversible `change` with an irreversible raw statement and expect rollback —
if any op in a `change` errors in reverse mode, the rollback fails loudly (it does
not partially roll back; it is inside a transaction, §5).

### 4. Rollback + status (CLI + ledger)

The `_migrations` ledger's autoincrement `id` already records apply-order.

- `zigbase migrate rollback [N]` — reverse the last **N consumer** migrations
  (default `N=1`), most-recent first. For each: run `down` / reverse-`change`,
  then delete its ledger row, inside a transaction (unless `.transactional=false`).
  **Framework-internal migrations (the `migrations.zig` `0001…` set) are never
  rolled back** — rollback operates only over the consumer `.migrations` set. If
  the target migration is irreversible (no `down`, non-auto-reversible `change`),
  the command fails with a clear error and rolls back nothing.
- `zigbase migrate status` — list applied vs pending consumer migrations (name,
  applied_at or "pending"), in order.
- **v1 scope:** "last N steps" (the Rails default). "Rollback to version X" is a
  natural follow-on but is **out of v1 scope** (revisit if wanted).

### 5. Transactional-by-default + opt-out

Already the behavior (`run()` wraps each migration in `begin → … → commit`). The
only addition is the `Migration.transactional` opt-out: when `false`, the migration
runs outside a transaction (for DDL that cannot run in one, e.g. Postgres
`CREATE INDEX CONCURRENTLY`). Rollback of such a migration likewise runs outside a
transaction. Document the loss of atomicity for opt-out migrations.

### 6. Schema dump

`zigbase migrate dump [--out db/structure.sql]` introspects the **live** database
and writes a canonical, dialect-native `structure.sql`:

- SQLite: read `sqlite_master` (the stored `CREATE TABLE`/`CREATE INDEX` text) plus
  the applied `_migrations` names.
- Postgres: generate the DDL from the system catalogs (`pg_catalog` /
  `information_schema`) — **no external `pg_dump` dependency**; ZigBase emits the
  DDL itself, consistent with how it already talks to Postgres.

Purpose (per model A): inspection, review-diffing, and fast test-DB setup. It does
**not** replace `.collections` provisioning and is not loaded at boot.

## Decomposition (implementation pieces)

One spec, but the plan sequences three buildable/testable pieces:

- **Piece A — DSL + auto-reversibility core.** The extended `Migration` type +
  comptime validation, the `Migrator` `direction` + the DSL op set (forward +
  inverse) + the per-statement breakout (`exec`/`raw`/`rawFor`) + `m.records()`
  (#241). Testable in isolation (apply forward, apply reverse, assert schema;
  irreversible-op-in-reverse errors).
- **Piece B — rollback/status CLI + tx opt-out.** `migrate rollback [N]`,
  `migrate status`, the ledger-ordered reverse over consumer migrations, and the
  `.transactional=false` path. Depends on A's reverse mode.
- **Piece C — schema dump CLI.** `migrate dump` (SQLite + Postgres introspection).
  Independent of A/B.

## Error handling

- Comptime: invalid `Migration` shape (both/neither of `change`/`up`, `down`
  without `up`) is a `@compileError`.
- Runtime forward: a failing statement aborts the migration; the surrounding
  transaction rolls back (unless opted out), leaving the ledger untouched — the
  migration is retried on the next `migrate`.
- Reverse: an irreversible op or a failing `down` aborts the rollback in its
  transaction; the ledger row is not deleted; the command reports which migration
  and why.

## Testing

- **A:** per DSL op — forward SQL correct on both dialects (assert emitted/lowered
  SQL and the resulting schema via introspection); reverse mode emits the inverse
  and restores the prior schema; each not-auto-reversible op errors in reverse
  mode; `records()` transforms a seeded row. Backward-compat: an existing
  `{ name, up }` still applies.
- **B:** `rollback 1` / `rollback N` undo the right consumer migrations and delete
  the right ledger rows; framework-internal migrations are untouched; an
  irreversible target fails and changes nothing; `status` output; `.transactional
  = false` runs outside a tx.
- **C:** `dump` output round-trips (a dumped SQLite schema re-creates an equivalent
  DB; the Postgres dump is valid DDL) on a representative schema.

Both suites run on SQLite and `-Dpostgres`.

## Docs

`docs/framework.md` (+ site mirror) migrations section: the DSL op reference, the
`change`/auto-reversibility model, `up`/`down` fallback, per-statement breakout,
`transactional` opt-out, and the `migrate rollback|status|dump` CLI. KNOWN_LIMITATIONS
if any migration limitation is stated. A changelog fragment per merged piece.
