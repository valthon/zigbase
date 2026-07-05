//! Pure feature-flag + experiment resolution (0.8.0, #128/#129/#130).
//!
//! These functions take the declared definitions (from `features.zig`) plus the
//! relevant `_kv` overrides and return resolved values. They perform NO database
//! IO themselves — the ctx/data layer scans `_kv` and hands the entries in — so
//! they are trivially unit-testable and deterministic.
//!
//! `_kv` key conventions (distinct prefixes so a batched scan can group them and
//! they never collide with arbitrary settings):
//!   - `flag:<name>`         = `"true"` / `"false"` (a per-flag override)
//!   - `exp:<name>:weights`  = JSON array, e.g. `[90,10]` (a weight override)
//!
//! Experiments resolve by PURE deterministic hash by default. An experiment declared
//! `.sticky = true` instead PERSISTS its first assignment in `_experiment_assignments`
//! (keyed by `(experiment, subject)`) so the variant SURVIVES later weight changes
//! (#129) — `resolveExperiment` reads/writes that row when handed a writer connection.

const std = @import("std");
const features = @import("features.zig");
const db = @import("db.zig");
const param_sink = @import("sql/param_sink.zig");

pub const FlagDef = features.FlagDef;
pub const ExperimentDef = features.ExperimentDef;
pub const Registry = features.Registry;

/// A minimal key/value pair (a projection of `data.KvEntry`) the resolver operates
/// on, so it need not import the DB layer.
pub const KvPair = struct { key: []const u8, value: []const u8 };

pub const ResolvedFlag = struct { name: []const u8, value: bool };
pub const ResolvedExperiment = struct { name: []const u8, variant: []const u8 };
pub const Resolved = struct {
    flags: []const ResolvedFlag = &.{},
    experiments: []const ResolvedExperiment = &.{},
};

fn isTruthy(v: []const u8) bool {
    return std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1");
}

/// Resolve a flag: if an override string is present, use its truthiness; otherwise
/// the declared default. (So a default-ON kill switch stays ON until an override
/// explicitly sets `"false"`.)
pub fn resolveFlag(override: ?[]const u8, def: FlagDef) bool {
    if (override) |v| return isTruthy(v);
    return def.default;
}

/// Deterministic bucketing: `FNV1a-64(name ++ 0x00 ++ subject) % 256`, then the
/// first variant whose cumulative weight threshold (scaled to 256) exceeds the
/// bucket. Stable for a given `(name, subject, weights)`. An empty subject always
/// maps to variant 0 (a stable "anonymous" assignment).
pub fn bucket(name: []const u8, subject: []const u8, weights: []const u16) usize {
    if (subject.len == 0) return 0;
    var total: u64 = 0;
    for (weights) |w| total += w;
    if (total == 0) return 0;

    var h = std.hash.Fnv1a_64.init();
    h.update(name);
    h.update("\x00");
    h.update(subject);
    const b: u64 = h.final() % 256;

    var cum: u64 = 0;
    for (weights, 0..) |w, i| {
        cum += w;
        const thr = (256 * cum) / total;
        if (b < thr) return i;
    }
    return weights.len - 1;
}

/// Parse a `[n,n,…]` weight-override JSON into `[]u16`, or null on any problem
/// (malformed JSON, wrong length, all-zero). Caller falls back to declared weights.
fn parseWeightOverride(alloc: std.mem.Allocator, json: []const u8, expect_len: usize) ?[]const u16 {
    const parsed = std.json.parseFromSlice([]u16, alloc, json, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value.len != expect_len) return null;
    var total: u64 = 0;
    for (parsed.value) |w| total += w;
    if (total == 0) return null;
    return alloc.dupe(u16, parsed.value) catch null;
}

/// Resolve an experiment to a variant. `override_weights_json` (the `exp:<name>:weights`
/// value, or null) replaces the declared weights when valid. The returned slice is one
/// of `def.variants` (static), so it outlives `alloc`.
///
/// Resolution is a pure deterministic hash bucket UNLESS the experiment is `.sticky` and
/// a non-empty `subject` and `sticky` connections are supplied — then the first assignment
/// is persisted in `_experiment_assignments` and re-read on subsequent resolves, so the
/// variant SURVIVES a later weight change (#129). Resolution is **reader-first**: a stored
/// assignment is read on `sticky.read` (a pooled reader, or the bound writer inside a tx)
/// with NO writer involvement; only a MISS briefly borrows the writer to persist + read
/// back the authoritative variant (see `StickyConns`). Passing `sticky == null` (or an
/// empty subject) always takes the pure path; an empty subject is never persisted.
pub fn resolveExperiment(
    alloc: std.mem.Allocator,
    sticky: ?StickyConns,
    override_weights_json: ?[]const u8,
    def: ExperimentDef,
    subject: []const u8,
) ![]const u8 {
    // Single-accessor path: no batched prefetch — a sticky miss reads on `sticky.read` first.
    return resolveExperimentImpl(alloc, sticky, override_weights_json, def, subject, null);
}

/// Shared implementation of `resolveExperiment`; `batch` is `null` on the single-accessor path
/// (reader-first per experiment) and set on `resolveAll`'s batched path (the sticky read already
/// happened once, in `stickyBatchLookup`, so the prefetched hit is threaded straight through).
fn resolveExperimentImpl(
    alloc: std.mem.Allocator,
    sticky: ?StickyConns,
    override_weights_json: ?[]const u8,
    def: ExperimentDef,
    subject: []const u8,
    batch: ?BatchState,
) ![]const u8 {
    // An override parse dupes its own []u16 onto `alloc`; the declared weights are
    // static. Track + free the duped copy so the function is leak-free under a
    // general-purpose allocator (and a no-op under the arena it gets on the ctx path).
    var owned_weights: ?[]const u16 = null;
    defer if (owned_weights) |w| alloc.free(w);
    const weights: []const u16 = blk: {
        if (override_weights_json) |j| {
            if (parseWeightOverride(alloc, j, def.variants.len)) |w| {
                owned_weights = w;
                break :blk w;
            }
        }
        break :blk def.weights;
    };

    // Sticky: a previously-stored assignment wins over a fresh bucket, so the variant
    // is stable across weight changes. An empty subject always maps to variant 0 and is
    // never persisted; a non-sticky experiment always follows the live weights.
    if (def.sticky and subject.len > 0) {
        if (sticky) |sc| {
            // `batch` distinguishes the single-accessor path (reader-first, one SELECT per
            // experiment) from `resolveAll`'s batched path (the sticky read already happened
            // in one combined SELECT, so the prefetched hit — or a miss → persist — is used
            // directly with NO per-experiment reader SELECT). Both share `stickyPersist`.
            if (batch) |b| return stickyVariantBatched(alloc, sc, def, subject, weights, b.prefetched);
            return stickyVariant(alloc, sc, def, subject, weights);
        }
    }

    const idx = bucket(def.name, subject, weights);
    return def.variants[idx];
}

/// Carries a prefetched batched sticky hit (or a null miss) into `resolveExperimentImpl`, so
/// `resolveAll` can resolve a sticky experiment against its batched read instead of issuing a
/// per-experiment reader SELECT. `null` for `batch` means the single-accessor path (`stickyVariant`).
const BatchState = struct { prefetched: ?[]const u8 };

/// A batched sticky-assignment hit: an experiment name mapped to its stored, still-declared
/// variant (already mapped back to the static `def.variants` slice, so it outlives the row buffer).
const BatchHit = struct { name: []const u8, variant: []const u8 };

/// Connections for **reader-first** sticky resolution. `read` is used for the assignment
/// lookup (a pooled reader on the public/route/job path, or the bound writer inside a
/// `ctx.tx`). `pool`, when set, is the source of the single writer borrowed *only on a
/// miss* to persist the assignment — so a steady-state sticky HIT never contends the
/// writer lock. `pool == null` means `read` IS the writer (a bound transaction): the
/// miss-path insert reuses it directly, taking/releasing no pool writer.
pub const StickyConns = struct {
    read: *db.Db,
    pool: ?*db.Pool = null,
};

/// Reader-first sticky resolution against `_experiment_assignments`.
///   1. READ (`sc.read`): a stored, still-declared assignment wins → returned with NO
///      writer involvement (the common steady-state path).
///   2. MISS: borrow the writer (`sc.pool.acquireWriter()`, or reuse the bound `sc.read`
///      when `pool == null`), `INSERT OR IGNORE` the bucketed variant, then read the row
///      BACK on the writer — so a concurrent winner that inserted first is honored — and
///      release the writer. The returned slice is mapped back to the static `def.variants`
///      so it outlives any row buffer; a stored variant no longer declared is recomputed.
fn stickyVariant(alloc: std.mem.Allocator, sc: StickyConns, def: ExperimentDef, subject: []const u8, weights: []const u16) ![]const u8 {
    // 1. Reader-first: a stored assignment short-circuits without touching the writer.
    if (try stickyLookup(alloc, sc.read, def, subject)) |hit| return hit;
    // 2. Miss: persist + read back the authoritative variant on the writer.
    return stickyPersist(alloc, sc, def, subject, weights);
}

/// Batched-path sticky resolution: the assignment read already happened once in
/// `stickyBatchLookup`, so a prefetched hit is returned directly (NO per-experiment reader SELECT);
/// a batch miss (`prefetched == null`) goes straight to `stickyPersist`. Behavior is identical to
/// `stickyVariant` given the same underlying stored row — the batch read replaces the reader-first
/// SELECT, and the miss/persist path is byte-for-byte the same helper.
fn stickyVariantBatched(alloc: std.mem.Allocator, sc: StickyConns, def: ExperimentDef, subject: []const u8, weights: []const u16, prefetched: ?[]const u8) ![]const u8 {
    if (prefetched) |hit| return hit;
    return stickyPersist(alloc, sc, def, subject, weights);
}

/// The MISS/persist path shared by `stickyVariant` and `stickyVariantBatched`: briefly take the
/// writer (`sc.pool.acquireWriter()`, or reuse the bound `sc.read` when `pool == null`),
/// `INSERT OR IGNORE` the bucketed variant, then read the row BACK on the writer — so a concurrent
/// winner that inserted first is honored — and release the writer. The returned slice is mapped
/// back to the static `def.variants` so it outlives any row buffer.
fn stickyPersist(alloc: std.mem.Allocator, sc: StickyConns, def: ExperimentDef, subject: []const u8, weights: []const u16) ![]const u8 {
    const writer = if (sc.pool) |p| p.acquireWriter() else sc.read;
    defer if (sc.pool) |p| p.releaseWriter();

    const idx = bucket(def.name, subject, weights);
    const computed = def.variants[idx];
    // Dialect-ize the conflict-ignoring insert: `INSERT OR IGNORE` (SQLite) ⇄ `INSERT … ON
    // CONFLICT DO NOTHING` (Postgres), `strftime` ISO now ⇄ `to_char(now())`, `?N` ⇄ `$n`.
    // `created` is the ISO-8601 `Z` shape (matches the records autodate format) → `nowIso8601Expr`.
    const dialect = db.dbDialect(writer);
    const ins_tmpl = try std.fmt.allocPrintSentinel(alloc, "{s} INTO \"_experiment_assignments\" (\"experiment\",\"subject\",\"variant\",\"created\") VALUES (?1, ?2, ?3, {s}){s};", .{ dialect.insertVerb(true), dialect.nowIso8601Expr(), dialect.onConflictDoNothing() }, 0);
    defer alloc.free(ins_tmpl);
    const ins_sql = try param_sink.renumberZ(alloc, dialect, ins_tmpl);
    defer if (dialect.kind == .postgres) alloc.free(ins_sql); // SQLite returns the input slice
    var ins = try writer.prepare(ins_sql);
    defer ins.finalize();
    try ins.bindText(1, def.name);
    try ins.bindText(2, subject);
    try ins.bindText(3, computed);
    _ = try ins.step();

    // Read back the AUTHORITATIVE variant on the writer: under conflict-ignore, a row
    // another request persisted first (between our reader miss and acquiring the writer)
    // is the one that wins, and we must return it for consistency with `App.experiment`.
    if (try stickyLookup(alloc, writer, def, subject)) |stored| return stored;
    return computed; // unreachable in practice (we just inserted), but a safe fallback.
}

/// SELECT the stored, still-declared variant for `(experiment, subject)` on `conn`,
/// mapped back to the static `def.variants` slice (so it outlives the row buffer), or
/// null on a miss / a stored variant that is no longer declared (the variant set changed).
/// Pure read — no writes — so it is safe on a pooled reader.
fn stickyLookup(alloc: std.mem.Allocator, conn: *db.Db, def: ExperimentDef, subject: []const u8) !?[]const u8 {
    const dialect = db.dbDialect(conn);
    const sql_p = try param_sink.renumberZ(alloc, dialect,
        \\SELECT "variant" FROM "_experiment_assignments"
        \\ WHERE "experiment" = ?1 AND "subject" = ?2;
    );
    defer if (dialect.kind == .postgres) alloc.free(sql_p); // SQLite returns the input slice
    var st = try conn.prepare(sql_p);
    defer st.finalize();
    try st.bindText(1, def.name);
    try st.bindText(2, subject);
    if (try st.step()) {
        const stored = st.columnText(0);
        for (def.variants) |v| {
            if (std.mem.eql(u8, v, stored)) return v;
        }
        // Stored variant no longer declared → treat as a miss and recompute.
    }
    return null;
}

/// ONE batched read of `_experiment_assignments` for `subject` over all declared sticky
/// experiments, so `resolveAll` issues a constant 2 queries (the `_kv` scan + this) regardless of
/// how many `.sticky` experiments an app declares — instead of one SELECT per sticky experiment.
///
/// Emits `SELECT "experiment","variant" FROM "_experiment_assignments" WHERE "subject"=?1 AND
/// "experiment" IN (?2, ?3, …)` — the `IN (…)` placeholder list is built from `sticky_defs` (one
/// `?N` per def), then dialect-ized (`?N` ⇄ `$n`) exactly like `stickyLookup`. Subject binds at 1;
/// each def name binds at 2, 3, …. Each returned row's stored variant is mapped back to THAT
/// experiment's `def.variants` — a stored variant no longer declared is dropped (treated as absent,
/// exactly like `stickyLookup`), so only still-declared hits are returned. Pure read — safe on a
/// pooled reader. Returns an owned slice the caller frees.
fn stickyBatchLookup(alloc: std.mem.Allocator, conn: *db.Db, sticky_defs: []const ExperimentDef, subject: []const u8) ![]const BatchHit {
    if (sticky_defs.len == 0) return &.{};
    const dialect = db.dbDialect(conn);

    // Build "…IN (?2, ?3, …)" — one numbered placeholder per sticky def, starting at ?2 (subject
    // is ?1). The whole statement is renumbered as a unit (`?N` ⇄ `$n`) on the Postgres arm.
    var sb: std.ArrayList(u8) = .empty;
    defer sb.deinit(alloc);
    try sb.appendSlice(alloc, "SELECT \"experiment\",\"variant\" FROM \"_experiment_assignments\" WHERE \"subject\" = ?1 AND \"experiment\" IN (");
    var pbuf: [16]u8 = undefined;
    for (sticky_defs, 0..) |_, i| {
        if (i > 0) try sb.append(alloc, ',');
        try sb.appendSlice(alloc, try std.fmt.bufPrint(&pbuf, "?{d}", .{i + 2}));
    }
    try sb.appendSlice(alloc, ");");
    const raw = try sb.toOwnedSliceSentinel(alloc, 0);
    defer alloc.free(raw);
    const sql = try param_sink.renumberZ(alloc, dialect, raw);
    defer if (dialect.kind == .postgres) alloc.free(sql); // SQLite returns the input slice

    var st = try conn.prepare(sql);
    defer st.finalize();
    try st.bindText(1, subject);
    for (sticky_defs, 0..) |def, i| {
        try st.bindText(@intCast(i + 2), def.name);
    }

    var hits: std.ArrayList(BatchHit) = .empty;
    errdefer hits.deinit(alloc);
    while (try st.step()) {
        const exp = st.columnText(0);
        const stored = st.columnText(1);
        // Map the stored variant back to its experiment's static `def.variants` (so it outlives
        // the row buffer); an undeclared experiment/variant is dropped — a miss, per `stickyLookup`.
        for (sticky_defs) |def| {
            if (!std.mem.eql(u8, def.name, exp)) continue;
            for (def.variants) |v| {
                if (std.mem.eql(u8, v, stored)) {
                    try hits.append(alloc, .{ .name = def.name, .variant = v });
                    break;
                }
            }
            break;
        }
    }
    return hits.toOwnedSlice(alloc);
}

/// Batch size for the sticky-assignment GC sweep: bound each DELETE so a large backlog
/// never holds the single writer for one long statement (mirrors `session_gc_batch`).
pub const assignment_gc_batch: usize = 1000;

/// Garbage-collect `_experiment_assignments` rows older than `ttl_days`, in bounded
/// batches (mirrors `gcExpiredSessions`). Each batch is its own autocommit
/// `DELETE … RETURNING`, so the writer is never held across the whole sweep. The cutoff and
/// physical-row addressing are dialect-selected (`dialect.agedBeyondDaysPredicate` +
/// `dialect.physicalRowId`): on SQLite both sides are normalized via `strftime` (a non-canonical
/// `created` compares correctly; an unparseable one → NULL → kept, fail-safe) addressed by
/// `rowid`; on Postgres the compare is gated on the ISO-`Z` regex (an unparseable value can't be
/// aged out) against a `make_interval` cutoff, addressed by `ctid`. Returns the total rows
/// deleted. Writer required.
pub fn gcExpiredAssignments(conn: *db.Db, ttl_days: u32) !usize {
    // Build the backend-correct DELETE once: the relative-age cutoff (`created` older than
    // `ttl_days`, fail-safe on a malformed value) and the physical-row addressing column both
    // diverge by backend, so route them through the dialect. SQLite keeps the `strftime`
    // normalization + `rowid`; Postgres uses the ISO-`Z` regex gate + `make_interval` cutoff +
    // `ctid`. No bind placeholders (the cutoff is inlined, the trusted `ttl_days` config value),
    // so no `$n` renumber is required. The SQL is small and bounded → a stack allocator suffices
    // (the PG arm's range-bounded ISO regex + make_interval cutoff is the largest, well under 4 KiB
    // even with the Allocating writer's growth slack).
    var buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const a = fba.allocator();
    const dialect = db.dbDialect(conn);
    const aged = try dialect.agedBeyondDaysPredicate(a, "\"created\"", ttl_days);
    const rid = dialect.physicalRowId();
    const sql = try std.fmt.allocPrintSentinel(
        a,
        "DELETE FROM \"_experiment_assignments\" WHERE {s} IN (" ++
            "SELECT {s} FROM \"_experiment_assignments\" WHERE {s} LIMIT {d}" ++
            ") RETURNING \"experiment\";",
        .{ rid, rid, aged, assignment_gc_batch },
        0,
    );

    var total: usize = 0;
    while (true) {
        var st = try conn.prepare(sql);
        defer st.finalize();
        var batch: usize = 0;
        while (try st.step()) batch += 1;
        total += batch;
        if (batch < assignment_gc_batch) break; // partial (or zero) batch → done
    }
    return total;
}

/// Resolve every declared flag and experiment for `subject` from a single batched
/// `_kv` scan (the entries matching `flag:*` / `exp:*`). Results are allocated on
/// `alloc`.
pub fn resolveAll(
    alloc: std.mem.Allocator,
    reg: Registry,
    entries: []const KvPair,
    subject: []const u8,
    sticky: ?StickyConns,
) !Resolved {
    const flags_out = try alloc.alloc(ResolvedFlag, reg.flags.len);
    for (reg.flags, 0..) |def, i| {
        const key = try std.fmt.allocPrint(alloc, "flag:{s}", .{def.name});
        defer alloc.free(key);
        var ov: ?[]const u8 = null;
        for (entries) |e| {
            if (std.mem.eql(u8, e.key, key)) {
                ov = e.value;
                break;
            }
        }
        flags_out[i] = .{ .name = def.name, .value = resolveFlag(ov, def) };
    }

    // Batched sticky pre-read: ONE SELECT over EVERY declared sticky experiment's assignment for
    // `subject`, so resolveAll issues a constant 2 queries (this + the `_kv` scan) regardless of
    // how many `.sticky` experiments are declared — instead of 1 + N (one reader SELECT each).
    // Only meaningful with a sticky connection AND a live subject: `sticky == null` and the empty
    // subject take the pure-hash path in `resolveExperimentImpl` and never touch the table, so the
    // batched hits are simply unused there (no experiment reaches `stickyVariantBatched`).
    var batch_hits: []const BatchHit = &.{};
    defer if (batch_hits.len > 0) alloc.free(batch_hits);
    if (sticky) |sc| {
        if (subject.len > 0) {
            var sticky_defs: std.ArrayList(ExperimentDef) = .empty;
            defer sticky_defs.deinit(alloc);
            for (reg.experiments) |def| {
                if (def.sticky) try sticky_defs.append(alloc, def);
            }
            if (sticky_defs.items.len > 0) {
                batch_hits = try stickyBatchLookup(alloc, sc.read, sticky_defs.items, subject);
            }
        }
    }

    const exps_out = try alloc.alloc(ResolvedExperiment, reg.experiments.len);
    for (reg.experiments, 0..) |def, i| {
        const key = try std.fmt.allocPrint(alloc, "exp:{s}:weights", .{def.name});
        defer alloc.free(key);
        var ov: ?[]const u8 = null;
        for (entries) |e| {
            if (std.mem.eql(u8, e.key, key)) {
                ov = e.value;
                break;
            }
        }
        // Thread the batched hit (or a null miss) for a sticky experiment straight through: a hit
        // returns without any per-experiment read; a miss persists per-experiment (misses are
        // once-per-subject by definition — the writes are NOT batched). Non-sticky experiments and
        // the empty-subject / `sticky == null` cases take the pure-hash path and ignore `prefetched`.
        var prefetched: ?[]const u8 = null;
        if (def.sticky) {
            for (batch_hits) |h| {
                if (std.mem.eql(u8, h.name, def.name)) {
                    prefetched = h.variant;
                    break;
                }
            }
        }
        exps_out[i] = .{ .name = def.name, .variant = try resolveExperimentImpl(alloc, sticky, ov, def, subject, .{ .prefetched = prefetched }) };
    }

    return .{ .flags = flags_out, .experiments = exps_out };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "resolveFlag returns declared default when unset; override wins" {
    const off = FlagDef{ .name = "f", .default = false };
    const on = FlagDef{ .name = "f", .default = true };

    // Unset → default.
    try std.testing.expect(!resolveFlag(null, off));
    try std.testing.expect(resolveFlag(null, on));

    // Override wins either way.
    try std.testing.expect(resolveFlag("true", off));
    try std.testing.expect(resolveFlag("1", off));
    try std.testing.expect(!resolveFlag("false", on));
    try std.testing.expect(!resolveFlag("0", on)); // non-truthy → false
}

test "default-ON flag stays on when unset (#128 kill-switch)" {
    const killswitch = FlagDef{ .name = "checkout_enabled", .default = true };
    // No operator action → still on.
    try std.testing.expect(resolveFlag(null, killswitch));
    // Operator flips it off.
    try std.testing.expect(!resolveFlag("false", killswitch));
}

test "bucket is deterministic and respects empty subject" {
    const weights = [_]u16{ 50, 50 };
    // Same (name, subject) → same bucket every time.
    const a = bucket("exp", "user-123", &weights);
    const b = bucket("exp", "user-123", &weights);
    try std.testing.expectEqual(a, b);
    try std.testing.expect(a < 2);
    // Empty subject → variant 0.
    try std.testing.expectEqual(@as(usize, 0), bucket("exp", "", &weights));
}

test "bucket distribution roughly follows weights" {
    const weights = [_]u16{ 90, 10 };
    var counts = [_]usize{ 0, 0 };
    var i: usize = 0;
    var buf: [32]u8 = undefined;
    while (i < 2000) : (i += 1) {
        const subj = std.fmt.bufPrint(&buf, "subject-{d}", .{i}) catch unreachable;
        counts[bucket("layout", subj, &weights)] += 1;
    }
    // Variant 0 should dominate (~90%). Loose bounds to avoid flakiness.
    try std.testing.expect(counts[0] > counts[1]);
    try std.testing.expect(counts[0] > 1500); // >75%
    try std.testing.expect(counts[1] > 50); // variant 1 not starved
}

test "weight override changes the split" {
    const def = ExperimentDef{
        .name = "layout",
        .variants = &.{ "control", "compact" },
        .weights = &.{ 50, 50 },
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Count variants under declared 50/50 vs an override pinning everything to control.
    var control_default: usize = 0;
    var control_override: usize = 0;
    var i: usize = 0;
    var buf: [32]u8 = undefined;
    while (i < 1000) : (i += 1) {
        const subj = std.fmt.bufPrint(&buf, "u{d}", .{i}) catch unreachable;
        if (std.mem.eql(u8, try resolveExperiment(a, null, null, def, subj), "control")) control_default += 1;
        if (std.mem.eql(u8, try resolveExperiment(a, null, "[100,0]", def, subj), "control")) control_override += 1;
    }
    // 50/50 ≈ half control; the [100,0] override forces ALL to control.
    try std.testing.expect(control_default < 1000);
    try std.testing.expectEqual(@as(usize, 1000), control_override);
}

test "resolveExperiment falls back to declared weights on a bad override" {
    const def = ExperimentDef{
        .name = "layout",
        .variants = &.{ "control", "compact" },
        .weights = &.{ 100, 0 }, // declared: always control
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Malformed / wrong-length / all-zero overrides all fall back to declared.
    try std.testing.expectEqualStrings("control", try resolveExperiment(a, null, "not json", def, "x"));
    try std.testing.expectEqualStrings("control", try resolveExperiment(a, null, "[1,2,3]", def, "x"));
    try std.testing.expectEqualStrings("control", try resolveExperiment(a, null, "[0,0]", def, "x"));
}

test "resolveAll returns every declared flag + experiment via the batched scan" {
    const reg = Registry{
        .flags = &.{
            .{ .name = "checkout_enabled", .default = true },
            .{ .name = "new_dashboard", .default = false },
        },
        .experiments = &.{
            .{ .name = "layout", .variants = &.{ "control", "compact" }, .weights = &.{ 50, 50 } },
        },
    };
    // Simulated batched _kv scan: one flag override + one weight override.
    const entries = [_]KvPair{
        .{ .key = "flag:new_dashboard", .value = "true" },
        .{ .key = "exp:layout:weights", .value = "[0,100]" },
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const resolved = try resolveAll(a, reg, &entries, "user-7", null);
    try std.testing.expectEqual(@as(usize, 2), resolved.flags.len);
    // checkout_enabled has no override → declared default true.
    try std.testing.expectEqualStrings("checkout_enabled", resolved.flags[0].name);
    try std.testing.expect(resolved.flags[0].value);
    // new_dashboard override → true (was default false).
    try std.testing.expectEqualStrings("new_dashboard", resolved.flags[1].name);
    try std.testing.expect(resolved.flags[1].value);
    // layout weight override [0,100] forces "compact".
    try std.testing.expectEqual(@as(usize, 1), resolved.experiments.len);
    try std.testing.expectEqualStrings("layout", resolved.experiments[0].name);
    try std.testing.expectEqualStrings("compact", resolved.experiments[0].variant);
}

// ---------------------------------------------------------------------------
// Sticky-assignment tests (#129) — exercise the real `_experiment_assignments`
// table on an in-memory db.
// ---------------------------------------------------------------------------

const assignments_ddl =
    \\CREATE TABLE "_experiment_assignments" (
    \\  "experiment" TEXT NOT NULL,
    \\  "subject" TEXT NOT NULL,
    \\  "variant" TEXT NOT NULL,
    \\  "created" TEXT NOT NULL,
    \\  PRIMARY KEY ("experiment","subject")
    \\);
;

test "sticky experiment SURVIVES a weight change (#129)" {
    var d = try db.Db.openMemory();
    defer d.close();
    try d.exec(assignments_ddl);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const def = ExperimentDef{
        .name = "checkout_layout",
        .variants = &.{ "control", "compact" },
        .weights = &.{ 50, 50 },
        .sticky = true,
    };

    // First resolve under the declared 50/50 weights persists an assignment.
    const first = try resolveExperiment(a, .{ .read = &d }, null, def, "user-42");

    // A later weight override that would otherwise force EVERYONE to the other
    // variant must NOT move an already-assigned subject.
    const opposite = if (std.mem.eql(u8, first, "control")) "[0,100]" else "[100,0]";
    const after = try resolveExperiment(a, .{ .read = &d }, opposite, def, "user-42");
    try std.testing.expectEqualStrings(first, after);

    // And a brand-new subject under the override DOES follow the new weights.
    const newcomer = try resolveExperiment(a, .{ .read = &d }, opposite, def, "newcomer-1");
    const forced = if (std.mem.eql(u8, first, "control")) "compact" else "control";
    try std.testing.expectEqualStrings(forced, newcomer);

    // Exactly one row for the sticky subject was persisted.
    var st = try d.prepare("SELECT COUNT(*) FROM \"_experiment_assignments\" WHERE \"subject\" = ?1;");
    defer st.finalize();
    try st.bindText(1, "user-42");
    try std.testing.expect(try st.step());
    try std.testing.expectEqual(@as(i64, 1), st.columnInt(0));
}

test "non-sticky experiment FOLLOWS the new weights (no persistence)" {
    var d = try db.Db.openMemory();
    defer d.close();
    try d.exec(assignments_ddl);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const def = ExperimentDef{
        .name = "layout",
        .variants = &.{ "control", "compact" },
        .weights = &.{ 50, 50 },
        .sticky = false,
    };

    // Even with a writer connection, a non-sticky experiment ignores the table and
    // honors the override on every resolve.
    try std.testing.expectEqualStrings("control", try resolveExperiment(a, .{ .read = &d }, "[100,0]", def, "user-42"));
    try std.testing.expectEqualStrings("compact", try resolveExperiment(a, .{ .read = &d }, "[0,100]", def, "user-42"));

    // Nothing was persisted.
    var st = try d.prepare("SELECT COUNT(*) FROM \"_experiment_assignments\";");
    defer st.finalize();
    try std.testing.expect(try st.step());
    try std.testing.expectEqual(@as(i64, 0), st.columnInt(0));
}

test "sticky never persists an empty-subject assignment" {
    var d = try db.Db.openMemory();
    defer d.close();
    try d.exec(assignments_ddl);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const def = ExperimentDef{
        .name = "layout",
        .variants = &.{ "control", "compact" },
        .weights = &.{ 50, 50 },
        .sticky = true,
    };

    // Empty subject → variant 0, and NO row is written.
    try std.testing.expectEqualStrings("control", try resolveExperiment(a, .{ .read = &d }, null, def, ""));
    var st = try d.prepare("SELECT COUNT(*) FROM \"_experiment_assignments\";");
    defer st.finalize();
    try std.testing.expect(try st.step());
    try std.testing.expectEqual(@as(i64, 0), st.columnInt(0));
}

test "sticky HIT is reader-first: resolves with NO write (#129/#130)" {
    // Reader-first invariant: once an assignment is persisted, resolving it again must
    // touch NO writer. Prove it deterministically by setting `PRAGMA query_only=ON` on
    // the connection — any write (the miss-path INSERT) would then fail with SQLITE_READONLY,
    // so a clean resolve guarantees only the SELECT ran.
    var d = try db.Db.openMemory();
    defer d.close();
    try d.exec(assignments_ddl);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const def = ExperimentDef{
        .name = "checkout_layout",
        .variants = &.{ "control", "compact" },
        .weights = &.{ 50, 50 },
        .sticky = true,
    };

    // First resolve persists the assignment (writes are still allowed here).
    const first = try resolveExperiment(a, .{ .read = &d }, null, def, "user-42");

    // Forbid writes, then resolve again under a weight override that WOULD re-bucket: a
    // reader-first HIT returns the stored variant via a pure SELECT and never writes.
    try d.exec("PRAGMA query_only=ON;");
    const opposite = if (std.mem.eql(u8, first, "control")) "[0,100]" else "[100,0]";
    const again = try resolveExperiment(a, .{ .read = &d, .pool = null }, opposite, def, "user-42");
    try std.testing.expectEqualStrings(first, again);
}

test "resolveAll honors a sticky PERSISTED variant across a weight override (#129/#130)" {
    // The public `/api/state` projection goes through resolveAll; it must agree with the
    // single-accessor `App.experiment` and return the persisted sticky variant — not a
    // fresh re-bucket — after a weight override that would otherwise move the subject.
    var d = try db.Db.openMemory();
    defer d.close();
    try d.exec(assignments_ddl);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const reg = Registry{
        .flags = &.{},
        .experiments = &.{
            .{ .name = "checkout_layout", .variants = &.{ "control", "compact" }, .weights = &.{ 50, 50 }, .sticky = true },
        },
    };
    const sc = StickyConns{ .read = &d, .pool = null }; // single conn doubles as reader + writer

    // First projection persists the assignment under the declared 50/50 weights.
    const r1 = try resolveAll(a, reg, &.{}, "user-42", sc);
    const persisted = r1.experiments[0].variant;

    // Now apply a weight override that would force EVERYONE to the opposite variant.
    const opposite = if (std.mem.eql(u8, persisted, "control")) "[0,100]" else "[100,0]";
    const entries = [_]KvPair{.{ .key = "exp:checkout_layout:weights", .value = opposite }};
    const r2 = try resolveAll(a, reg, &entries, "user-42", sc);
    // Sticky → the projection still reports the persisted variant.
    try std.testing.expectEqualStrings(persisted, r2.experiments[0].variant);

    // A brand-new subject under the override DOES follow the new weights (proves the
    // override is live for the unseen subject, so the stickiness above is real).
    const forced = if (std.mem.eql(u8, persisted, "control")) "compact" else "control";
    const r3 = try resolveAll(a, reg, &entries, "newcomer-9", sc);
    try std.testing.expectEqualStrings(forced, r3.experiments[0].variant);
}

// ---------------------------------------------------------------------------
// Batched sticky-read tests (#229) — resolveAll issues ONE assignment read over
// every declared sticky experiment, not 1 + N. These pin BYTE-IDENTICAL variants
// vs the single-accessor path and the miss/persist behavior.
// ---------------------------------------------------------------------------

fn assignmentRowCount(d: *db.Db) !i64 {
    var st = try d.prepare("SELECT COUNT(*) FROM \"_experiment_assignments\";");
    defer st.finalize();
    try std.testing.expect(try st.step());
    return st.columnInt(0);
}

test "resolveAll batched sticky reads == per-experiment resolve (equivalence, #229)" {
    var d = try db.Db.openMemory();
    defer d.close();
    try d.exec(assignments_ddl);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const e1 = ExperimentDef{ .name = "checkout_layout", .variants = &.{ "control", "compact" }, .weights = &.{ 50, 50 }, .sticky = true };
    const e2 = ExperimentDef{ .name = "pricing", .variants = &.{ "a", "b", "c" }, .weights = &.{ 34, 33, 33 }, .sticky = true };
    const e3 = ExperimentDef{ .name = "hero", .variants = &.{ "x", "y" }, .weights = &.{ 50, 50 }, .sticky = false };
    const reg = Registry{ .flags = &.{}, .experiments = &.{ e1, e2, e3 } };
    const sc = StickyConns{ .read = &d, .pool = null };
    const subject = "user-42";

    // Seed persisted assignments (declared variants) for the two sticky experiments.
    try d.exec(
        \\INSERT INTO "_experiment_assignments" ("experiment","subject","variant","created")
        \\ VALUES ('checkout_layout','user-42','compact','2024-01-01T00:00:00Z'),
        \\        ('pricing','user-42','c','2024-01-01T00:00:00Z');
    );

    // Single-accessor resolve per experiment (all sticky ones HIT the seeded rows → no writes).
    const s1 = try resolveExperiment(a, sc, null, e1, subject);
    const s2 = try resolveExperiment(a, sc, null, e2, subject);
    const s3 = try resolveExperiment(a, sc, null, e3, subject);

    // Batched resolveAll must produce byte-identical variants.
    const r = try resolveAll(a, reg, &.{}, subject, sc);
    try std.testing.expectEqualStrings(s1, r.experiments[0].variant);
    try std.testing.expectEqualStrings(s2, r.experiments[1].variant);
    try std.testing.expectEqualStrings(s3, r.experiments[2].variant);
    // And specifically the seeded sticky variants (proves the batch mapped them back).
    try std.testing.expectEqualStrings("compact", r.experiments[0].variant);
    try std.testing.expectEqualStrings("c", r.experiments[1].variant);
}

test "resolveAll batched all-hits writes NO new rows (batch is actually used, #229)" {
    var d = try db.Db.openMemory();
    defer d.close();
    try d.exec(assignments_ddl);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const e1 = ExperimentDef{ .name = "checkout_layout", .variants = &.{ "control", "compact" }, .weights = &.{ 50, 50 }, .sticky = true };
    const e2 = ExperimentDef{ .name = "pricing", .variants = &.{ "a", "b", "c" }, .weights = &.{ 34, 33, 33 }, .sticky = true };
    const reg = Registry{ .flags = &.{}, .experiments = &.{ e1, e2 } };
    const sc = StickyConns{ .read = &d, .pool = null };

    try d.exec(
        \\INSERT INTO "_experiment_assignments" ("experiment","subject","variant","created")
        \\ VALUES ('checkout_layout','user-42','compact','2024-01-01T00:00:00Z'),
        \\        ('pricing','user-42','c','2024-01-01T00:00:00Z');
    );
    try std.testing.expectEqual(@as(i64, 2), try assignmentRowCount(&d));

    // With every sticky assignment pre-seeded, resolveAll resolves all as HITs — the single
    // batched SELECT satisfies them, so NO per-experiment read/persist runs. Forbid writes to
    // prove it: any INSERT (a miss-path persist) would fail with SQLITE_READONLY.
    try d.exec("PRAGMA query_only=ON;");
    const r = try resolveAll(a, reg, &.{}, "user-42", sc);
    try d.exec("PRAGMA query_only=OFF;");

    try std.testing.expectEqualStrings("compact", r.experiments[0].variant);
    try std.testing.expectEqualStrings("c", r.experiments[1].variant);
    // Row count unchanged — the batch wrote nothing.
    try std.testing.expectEqual(@as(i64, 2), try assignmentRowCount(&d));
}

test "resolveAll batched: a stored UNDECLARED variant is a MISS (recompute), like stickyLookup (#229)" {
    var d = try db.Db.openMemory();
    defer d.close();
    try d.exec(assignments_ddl);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const def = ExperimentDef{ .name = "checkout_layout", .variants = &.{ "control", "compact" }, .weights = &.{ 50, 50 }, .sticky = true };
    const reg = Registry{ .flags = &.{}, .experiments = &.{def} };
    const sc = StickyConns{ .read = &d, .pool = null };

    // Seed a variant that is no longer declared → must be treated as a miss (recomputed).
    try d.exec(
        \\INSERT INTO "_experiment_assignments" ("experiment","subject","variant","created")
        \\ VALUES ('checkout_layout','user-42','legacy','2024-01-01T00:00:00Z');
    );

    // Batched resolveAll agrees with the single-accessor path, and returns a DECLARED variant
    // (the recomputed bucket), never the stored 'legacy'.
    const single = try resolveExperiment(a, sc, null, def, "user-42");
    const r = try resolveAll(a, reg, &.{}, "user-42", sc);
    try std.testing.expectEqualStrings(single, r.experiments[0].variant);
    try std.testing.expect(std.mem.eql(u8, r.experiments[0].variant, "control") or std.mem.eql(u8, r.experiments[0].variant, "compact"));
}

test "resolveAll batched: a sticky MISS is bucketed + persisted, stable on re-resolve (#229)" {
    var d = try db.Db.openMemory();
    defer d.close();
    try d.exec(assignments_ddl);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const def = ExperimentDef{ .name = "checkout_layout", .variants = &.{ "control", "compact" }, .weights = &.{ 50, 50 }, .sticky = true };
    const reg = Registry{ .flags = &.{}, .experiments = &.{def} };
    const sc = StickyConns{ .read = &d, .pool = null };

    // No seeded row → the batch misses → resolveAll persists the bucketed variant.
    try std.testing.expectEqual(@as(i64, 0), try assignmentRowCount(&d));
    const r1 = try resolveAll(a, reg, &.{}, "user-42", sc);
    const v = r1.experiments[0].variant;
    try std.testing.expectEqual(@as(i64, 1), try assignmentRowCount(&d));

    // A second resolveAll returns the now-stored variant (a batch HIT) and writes no new row.
    const r2 = try resolveAll(a, reg, &.{}, "user-42", sc);
    try std.testing.expectEqualStrings(v, r2.experiments[0].variant);
    try std.testing.expectEqual(@as(i64, 1), try assignmentRowCount(&d));
}

test "resolveAll issues NO assignment query when no experiment is sticky (#229)" {
    var d = try db.Db.openMemory();
    defer d.close();
    // Intentionally do NOT create `_experiment_assignments`: any read of it would error with
    // "no such table", so a clean pure-hash resolve proves the batch read was skipped entirely.

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const def = ExperimentDef{ .name = "layout", .variants = &.{ "control", "compact" }, .weights = &.{ 50, 50 }, .sticky = false };
    const reg = Registry{ .flags = &.{}, .experiments = &.{def} };
    const sc = StickyConns{ .read = &d, .pool = null };

    const r = try resolveAll(a, reg, &.{}, "user-1", sc);
    // Pure-hash result matches the single-accessor pure path (no sticky connection needed).
    const expect = try resolveExperiment(a, null, null, def, "user-1");
    try std.testing.expectEqualStrings(expect, r.experiments[0].variant);
}

test "resolveAll with sticky==null takes the pure-hash path for a sticky experiment (#229)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A sticky experiment, but `sticky == null` → never touches the table (no db at all).
    const def = ExperimentDef{ .name = "checkout_layout", .variants = &.{ "control", "compact" }, .weights = &.{ 50, 50 }, .sticky = true };
    const reg = Registry{ .flags = &.{}, .experiments = &.{def} };

    const r = try resolveAll(a, reg, &.{}, "user-42", null);
    const expect = try resolveExperiment(a, null, null, def, "user-42");
    try std.testing.expectEqualStrings(expect, r.experiments[0].variant);
}

test "gcExpiredAssignments reaps rows older than the TTL and keeps newer ones" {
    var d = try db.Db.openMemory();
    defer d.close();
    try d.exec(assignments_ddl);

    // One ancient row (well past any TTL) and one fresh row (created now).
    try d.exec(
        \\INSERT INTO "_experiment_assignments" ("experiment","subject","variant","created")
        \\ VALUES ('layout','old','control','2000-01-01T00:00:00Z');
    );
    try d.exec(
        \\INSERT INTO "_experiment_assignments" ("experiment","subject","variant","created")
        \\ VALUES ('layout','new','compact', strftime('%Y-%m-%dT%H:%M:%SZ','now'));
    );

    // TTL 90 days → the 2000 row is reaped, the fresh one survives.
    const reaped = try gcExpiredAssignments(&d, 90);
    try std.testing.expectEqual(@as(usize, 1), reaped);

    var st = try d.prepare("SELECT \"subject\" FROM \"_experiment_assignments\";");
    defer st.finalize();
    try std.testing.expect(try st.step());
    try std.testing.expectEqualStrings("new", st.columnText(0));
    try std.testing.expect(!try st.step()); // exactly one row left
}
