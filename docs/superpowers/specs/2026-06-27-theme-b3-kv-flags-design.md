# Theme B3 — KV/Settings Store (#87) + Feature Flags (#88)

**Status:** Design approved 2026-06-27. Implemented in `feat/theme-b3-kv-flags`.

## Background

Issues #87 and #88 are part of the Theme B family (data shapes/policies) filed by
agents porting a real application onto ZigBase. They share the meta-pattern of the
whole Theme A/B effort: the consumer-facing surface lags what the framework can do
internally.

- **#87 — KV/settings store.** A consumer app routinely needs a place to stash a
  handful of small, mutable, server-managed values (a feature toggle, a "site is in
  maintenance" flag, a cached external token, a counter, a JSON blob of settings).
  Today they must declare a whole collection with a schema and access rules just to
  hold one row. That is heavy and easy to get wrong (a `@public` rule leaks it).
- **#88 — Feature flags.** A binary on/off toggle is the single most common shape of
  the above. It deserves a typed accessor (`bool`, not "parse this string") rather
  than every consumer re-implementing the string→bool dance.

## Goals

- A built-in key→value primitive over a new internal system table `_kv`, exposed as
  `data.kvGet/kvSet/kvDelete` on the curated `Data` facade and as a `ctx.kv()`
  namespace (`get`/`set`/`delete`) on the handler/hook capability context.
- Feature flags as a **typed boolean view over the same KV store** (NOT a second
  table): `ctx.flag(name) -> bool` and `ctx.setFlag(name, enabled)`.
- Safe by default: KV/flags are **superuser-managed settings**, never exposed
  publicly by default. A consumer opts into any public read via their own custom
  route built on `ctx.flag`.
- Keep the 90% case a one-liner. No schema, no access rules, no ceremony.

## Non-goals (this cycle)

- A built-in public flags endpoint. Flags are server-side; a consumer exposes
  whatever subset they want via a custom route (documented pattern).
- Typed/structured values beyond strings. The value column is `TEXT`; a caller that
  wants JSON stringifies/parses it themselves (documented). A typed/comptime schema
  for settings is a possible follow-up.
- An admin-UI settings editor (Playwright `data-test` hooks). Follow-up.
- Per-key access rules, namespacing, TTLs, or change events. Follow-up if demanded.

## Design

### A. The system table (`_kv`)

A new migration `0009_kv` creates an internal system table, following the exact
pattern of `_consumedTokens`/`_oauthStates`/etc. in `src/migrations.zig`:

```sql
CREATE TABLE IF NOT EXISTS "_kv" (
  "key" TEXT PRIMARY KEY,
  "value" TEXT NOT NULL,
  "created" TEXT NOT NULL,
  "updated" TEXT NOT NULL
);
```

`key` is the natural primary key (no surrogate id). `created`/`updated` are
`datetime('now')` ISO-8601 strings, matching the rest of the schema. The table is
internal (`_`-prefixed); it is NOT a `_collections` row, so it is invisible to the
record API, query engine, and access-rule system — exactly the isolation we want for
superuser-managed settings.

### B. Data methods (the KV core)

On the `Data` struct in `src/data.zig` (the curated facade hooks/routes/jobs get):

- `kvGet(key) !?[]const u8` — `SELECT value FROM "_kv" WHERE key=?1`. Returns `null`
  if absent, else `self.alloc.dupe(u8, value)` so the result outlives the finalized
  statement and lives on the caller-chosen allocator (arena on the ctx path).
- `kvSet(key, value) !void` — upsert that **preserves `created`** across updates:
  ```sql
  INSERT INTO "_kv"(key,value,created,updated)
  VALUES(?1,?2,datetime('now'),datetime('now'))
  ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated=datetime('now');
  ```
- `kvDelete(key) !bool` — `DELETE FROM "_kv" WHERE key=?1`; returns whether a row
  existed (via `conn.changesCount()`), cheap and useful for idempotency checks.

These mirror the prepare/bindText/step/finalize idioms already used across
`data.zig`, `collections.zig`, and `migrations.zig`. No new file is introduced
(keeping it in `data.zig` is simplest, per the plan).

### C. ctx accessors (consumer surface)

On `Ctx` in `src/ctx.zig`, mirroring the existing `Records` namespace:

- `kv() KeyValue` returns a `KeyValue{ .ctx = self }` namespace with:
  - `get(name) !?[]const u8` — builds a `Data` on `connForRead()` (bound conn wins).
  - `set(name, value) !void` / `delete(name) !bool` — uses `bound_conn` if present,
    else acquires/releases the pool writer (EXACTLY like `Records.create`), so it is
    deadlock-safe inside `ctx.tx`/before-hooks and self-managing on the route/job
    path.
- `flag(name) !bool` — the typed view over `kv().get`:
  `const v = (try self.kv().get(name)) orelse return false;`
  `return std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1");`
  An unset flag is `false`. `"true"` and `"1"` are truthy; anything else is `false`.
- `setFlag(name, enabled) !void` — `self.kv().set(name, if (enabled) "true" else "false")`.

`flag`/`setFlag` are built strictly ON TOP of `kv()` — flags are a typed lens over
the one KV store, not a separate mechanism (#88 on top of #87).

### D. Read path + admin toggle (security posture)

KV/flags are superuser-managed settings and are **not** exposed publicly by default.
The server-side `ctx.kv`/`ctx.flag` surface is the contract. A consumer who wants a
public flag endpoint writes a one-line custom route:

```zig
.routes = .{
    .{ .method = .GET, .path = "/api/public-flags/:name", .handler = publicFlag },
},
// ...
fn publicFlag(ctx: *zigbase.Ctx) !zigbase.Response {
    const name = ctx.rctx... // path param
    const on = try ctx.flag(name);
    return ctx.json(.{ .enabled = on });
}
```

**HTTP settings API (`GET/PUT/DELETE /api/settings[/:key]`, superuser-only): see the
implementation note in the plan.** It is "cheap-if-feasible"; if wiring it cleanly is
large it is deferred and only the custom-route pattern above is documented. The admin
UI is out of scope for this cycle.

## Test plan (TDD)

- `migrations.zig`: after `run`, `_kv` exists with the four columns.
- `data.zig`: `kvSet`→`kvGet` round-trips; `kvGet` of a missing key is `null`;
  `kvSet` twice updates `value` AND preserves `created`; `kvDelete` removes it and
  reports existence.
- `ctx.zig`: `ctx.kv` set/get round-trip; `ctx.flag` true for a set flag and false
  for unset; `ctx.setFlag` toggles; works inside `ctx.tx` (bound_conn path).

## Risks / decisions

- **Value type is `TEXT`.** JSON is a stringified value the caller manages. Chosen
  for simplicity and to keep #88 a trivial lens; a typed layer can come later.
- **No access-rule integration.** The table is invisible to the rule engine on
  purpose; this is the safe default (superuser-only). Public exposure is an explicit
  consumer choice.
- **`created` preservation** is the one non-obvious correctness property and is
  asserted directly in the data.zig test.
