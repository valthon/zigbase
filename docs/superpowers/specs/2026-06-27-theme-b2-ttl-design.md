# Theme B2 — TTL records (`.ttl_field`)

**Status:** Design approved 2026-06-27. Implemented in `feat/theme-b2-ttl` (issue #81).

## Background

Issue #81 (one of the consumer-porting issues #80–#88) asks for **row expiry**:
a collection should be able to declare that a timestamp field marks each row's
expiry, and the framework should reap expired rows automatically. Real apps
accumulate ephemeral data — pending holds, one-time tokens, transient
notifications, soft sessions — and re-implementing a sweep job for every one of
them is exactly the kind of "fall off a cliff the moment you write custom Zig"
gap the four themes target.

Today the only way to schedule recurring framework work is a user `.cron` job.
There is **no mechanism for framework-internal scheduled jobs**, so a
framework-owned GC needs a small one built first.

## Goals

- A collection-level option `.ttl_field = "expires_at"` that names an existing
  `date`/`autodate` field as the row's expiry timestamp.
- A framework-internal, provisioned GC job that periodically deletes rows whose
  ttl_field is in the past, plus a one-shot sweep at startup.
- The GC is **safe-by-default**: SQL identifiers are validated before
  interpolation; only collections that opt in are touched; an error never crashes
  the server.
- The internal-job mechanism is general (not TTL-specific) so future
  framework-owned jobs can reuse it.

## Non-goals (this cycle)

- **Auto-excluding expired-but-not-yet-reaped rows from reads** (see Design
  appendix). GC runs every 5 minutes, so a just-expired row can still be returned
  by a query in the window before the sweep. Excluding it at read time is a
  separate, larger change (it touches the query compiler + every read path +
  realtime delivery). Documented below; **not implemented**.
- Per-collection GC cadence tuning. Fixed 5-minute interval for now.
- TTL on the auth system tables (handled by their own challenge/cursor GC).

## Design

### A. The collection option

`schema.CollectionOptions` gains `ttl_field: ?[]const u8 = null`.

- **Comptime path** (`provision.buildCollection`): reading `.ttl_field` off the
  comptime spec literal. Validated at **compile time** — the named field must
  exist in the collection's fields AND be of type `.date` or `.autodate` (so the
  stored value is an ISO-8601 UTC string, lexically comparable to `now`). A
  missing/ wrong-typed field is a `@compileError`.
- **Persistence** (`schema.optionsToJson` / `optionsFromJson`): when set, a
  `"ttl": {"field": "<name>"}` object is written into the options root and parsed
  back, so a collection's TTL config survives a `_collections` round-trip the same
  way `auth` options do.

Why `date`/`autodate` only: ZigBase writes autodate values via
`strftime('%Y-%m-%dT%H:%M:%SZ','now')` and validates `date` fields as ISO-8601.
Fixed-width UTC ISO-8601 strings compare correctly with lexical `<=`, so the GC
predicate is a plain string comparison against the same `strftime` expression —
no date parsing, no format skew.

### B. The GC routine

`records.gcExpiredRecords(alloc, w: *db.Db) !usize` mirrors the existing
`gcCursorStates` / `gcAuthChallenges` sweeps:

1. Load all collections (`collections.list`).
2. For each collection whose `options.ttl_field != null`:
   - Validate BOTH `col.name` and the ttl_field name with
     `schema.isValidIdentifier` before interpolating into SQL (the query-string
     threat model in `docs/security-audit.md` requires every interpolated
     identifier be gated). A failing name is skipped (defense-in-depth; the
     comptime path already guarantees valid names, but a hand-rolled
     `_collections` row must not be trusted).
   - Run `DELETE FROM "<name>" WHERE "<ttl_field>" IS NOT NULL AND "<ttl_field>"
     <= strftime('%Y-%m-%dT%H:%M:%SZ','now');`.
   - Add `w.changesCount()` to a running total.
3. Return the total rows deleted. Collections without a ttl_field are untouched.

Using SQL `strftime(...,'now')` keeps the comparison format byte-identical to how
autodate columns are written, and means the GC reads the DB clock (consistent
with the rest of the engine). `IS NOT NULL` keeps an optional, never-set ttl
column from being treated as already-expired.

### C. The framework-internal scheduled-job mechanism

`scheduler.concatJobs(comptime a, comptime b) []const RuntimeJob` — a comptime
helper returning a static-lifetime slice combining two job tables (same
`Holder`-struct static-const pattern `buildJobs` uses to return a `[]const`).

In `framework.zig`:

- `user_jobs` = the existing `.cron`-derived table (renamed from `jobs`).
- `internal_jobs` = when COMPTIME any collection has `options.ttl_field != null`,
  a one-element table built via
  `buildJobs(.{ .{ .name = "_ttl_gc", .schedule = .{ .interval = .{ .minutes = 5 } }, .handler = ttlGcJob } })`;
  else `&.{}`.
- `pub const jobs = concatJobs(user_jobs, internal_jobs)`.
- `ttlGcJob(ctx, ev)` acquires the writer (`ctx.app.pool.acquireWriter()` /
  `releaseWriter()`) and calls `records.gcExpiredRecords(ctx.arena, w)`.

The scheduler only starts when `jobs.len > 0` (framework.zig), so a TTL
collection makes the scheduler start even with **no** user `.cron` — exactly what
we want. A startup one-shot sweep is added next to the cursor/challenge GC,
gated on the same comptime "any TTL collection" flag (threaded through
`ServeOpts.has_ttl`).

### D. (Design only — NOT implemented) Excluding expired rows from reads

To make expiry observable immediately rather than within one GC interval, every
read path (`records.list` / `get`, realtime delivery, expand joins) would need an
implicit `AND "<ttl_field>" > strftime(...)` predicate on TTL collections. This
is attractive but invasive: it must be threaded through the query compiler and
the joiner (so expanded relations to a TTL collection also hide expired targets),
and realtime would need to re-check expiry on delivery. It also raises questions
(should a superuser see expired-but-unreaped rows? should `view` by id 404 or
410?). Deferred. The GC's 5-minute window is the documented eventual-consistency
contract for now.

## Test plan (TDD)

- `schema.zig`: `ttl_field` round-trips through `optionsToJson`/`optionsFromJson`.
- `records.zig`: `gcExpiredRecords` deletes a past-timestamp row, keeps a
  future-timestamp row, and leaves a non-TTL collection untouched.
- `scheduler.zig`: `concatJobs` combines lengths + names from both halves.
- `provision.zig`: a collection with `.ttl_field` naming a date field compiles and
  sets `options.ttl_field`.

## Rollout

Additive and opt-in. No migration; existing collections are unaffected. The
internal job + startup sweep only exist in binaries whose comptime schema declares
at least one TTL collection.
