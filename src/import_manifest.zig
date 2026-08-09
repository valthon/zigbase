//! Multi-collection import: load a whole dataset (several NDJSON files, one per collection)
//! in dependency order, deferring the relation values that cannot be ordered at all.
//!
//! Two shapes defeat any static load order:
//!   - a **relation cycle** between collections (`a.toB` -> `b`, `b.toA` -> `a`), and
//!   - a **self-relation** (`comments.parent` -> `comments`), where row 1 may reference row 5
//!     inside the very same file.
//! Both are ordinary in real data. The runner handles them the same way the DDL pump handles
//! a schema-level cycle: phase 1 loads every row with the offending relation keys stripped,
//! phase 2 re-reads each affected file and patches the values in by record id, now that every
//! target row exists.

const std = @import("std");
const db = @import("db.zig");
const schema = @import("schema.zig");
const schema_diff = @import("schema_diff.zig");
const schema_doc = @import("schema_doc.zig");
const collections = @import("collections.zig");
const migrations = @import("migrations.zig");
const records = @import("records.zig");
const import = @import("import.zig");

fn relField(name: []const u8, target: []const u8, max: u32) schema.Field {
    return .{ .id = "", .name = name, .options = .{ .relation = .{ .targetCollectionId = target, .maxSelect = max } } };
}

/// Frozen manifest-format version. Bumping this is a breaking change to the file format.
pub const manifest_version: u32 = 1;

pub const Entry = struct {
    collection: []const u8,
    /// NDJSON path, relative to the manifest file's directory unless absolute.
    file: []const u8,
    upsert_key: ?[]const u8 = null,
};

/// Owns every string. `deinit` frees the whole thing.
pub const Manifest = struct {
    entries: []const Entry,
    arena: std.heap.ArenaAllocator,
    pub fn deinit(self: *Manifest) void {
        self.arena.deinit();
    }
};

pub const ManifestError = error{
    InvalidManifest,
    UnsupportedVersion,
    UnknownCollection,
    DeferredRowMissingId,
    /// A field selected for deferral (a cycle back-edge or a self-relation) is `required`.
    /// There is no legal two-pass load order for it: phase 1 must strip the value to break
    /// the cycle, and a required field absent from every row then fails `validation_required`
    /// on EVERY row in the collection. Raised by `deferralSet` before phase 1 imports
    /// anything; `last_error_detail` names the collection/field and what to do about it.
    RequiredRelationInCycle,
    /// Phase 2 tried to patch a deferred value onto a record id that phase 1 never created
    /// (typically a `continue_on_error` row that failed phase 1). Only raised when
    /// `continue_on_error` is unset; under `continue_on_error` this is logged as a finding
    /// and counted as a failure instead.
    DeferredTargetRowMissing,
} ||
    // `import.run`'s error set is inferred (it fans out into record validation, and for an
    // auth collection, password hashing) so it is pulled in by reflection rather than via
    // the narrower `import.ImportError` alias, which only names import.zig's own literals.
    @typeInfo(@typeInfo(@TypeOf(import.run)).@"fn".return_type.?).error_union.error_set ||
    collections.EngineError || records.RecordError ||
    std.Io.File.OpenError || error{ ReadFailed, StreamTooLong } || std.mem.Allocator.Error;

threadlocal var detail_buf: [256]u8 = undefined;
/// Set alongside `error.RequiredRelationInCycle`: names the collection/field that has no
/// legal load order and what to do about it. Empty for every other error. Mirrors
/// `import.zig`'s `last_error_detail` (same threadlocal-buffer idiom, same reset-on-entry
/// discipline via `run`).
pub threadlocal var last_error_detail: []const u8 = "";

/// Parse the manifest document (camelCase on the wire, per house convention). The whole
/// result lives on one arena; `deinit` is the only cleanup needed.
pub fn parseManifest(alloc: std.mem.Allocator, bytes: []const u8) ManifestError!Manifest {
    var arena = std.heap.ArenaAllocator.init(alloc);
    errdefer arena.deinit(); // the Manifest owns it only on success
    const sa = arena.allocator();

    const root = std.json.parseFromSliceLeaky(std.json.Value, sa, bytes, .{}) catch return ManifestError.InvalidManifest;
    if (root != .object) return ManifestError.InvalidManifest;
    const ver = root.object.get("zigbaseImportManifest") orelse return ManifestError.InvalidManifest;
    if (ver != .integer) return ManifestError.InvalidManifest;
    if (ver.integer != @as(i64, @intCast(manifest_version))) return ManifestError.UnsupportedVersion;
    const list = root.object.get("collections") orelse return ManifestError.InvalidManifest;
    if (list != .array) return ManifestError.InvalidManifest;

    var out: std.ArrayList(Entry) = .empty;
    for (list.array.items) |el| {
        if (el != .object) return ManifestError.InvalidManifest;
        const c = el.object.get("collection") orelse return ManifestError.InvalidManifest;
        const f = el.object.get("file") orelse return ManifestError.InvalidManifest;
        if (c != .string or f != .string) return ManifestError.InvalidManifest;
        var e = Entry{ .collection = try sa.dupe(u8, c.string), .file = try sa.dupe(u8, f.string) };
        if (el.object.get("upsertKey")) |k| {
            if (k == .string) e.upsert_key = try sa.dupe(u8, k.string);
        }
        try out.append(sa, e);
    }
    return .{ .entries = try out.toOwnedSlice(sa), .arena = arena };
}

/// The live collections named by the manifest, in manifest order, with every relation
/// field's `targetCollectionId` normalized to the target's NAME.
///
/// `collections.list` returns the raw stored value, and that value is id-or-name depending
/// on how the collection got its schema: the comptime provisioning path
/// (`provision.resolveTargets`) persists the target's real id ("so the persisted metadata
/// matches what the runtime API produces"), while a collection created straight through
/// `collections.create` persists whatever the caller sent, id or name. `schema_diff`'s
/// `orderWithCycles`/`indexByName` are name-only (they are normally fed a `schema_doc.dump`
/// document, which performs this exact rewrite) — so without normalizing here, every
/// relation on a provisioned (the common, comptime-schema) collection would silently fail to
/// resolve, `orderWithCycles` would treat it as pointing outside the doc, and neither the
/// load ordering nor the self-relation deferral would ever engage.
fn manifestCollections(sa: std.mem.Allocator, live: []const schema.Collection, entries: []const Entry) ![]schema.Collection {
    const out = try sa.alloc(schema.Collection, entries.len);
    for (entries, 0..) |e, i| {
        const idx = schema_diff.indexByName(live, e.collection) orelse return ManifestError.UnknownCollection;
        out[i] = try normalizeRelationTargets(sa, live[idx], live);
    }
    return out;
}

/// Copy of `c` where every relation field's `targetCollectionId` is rewritten id -> name
/// (see `manifestCollections`). Looks the id up across the FULL live schema (`all`), not just
/// the manifest subset, so a target outside the manifest still normalizes correctly; whether
/// the resulting name is itself one of the manifest's collections is for the caller
/// (`orderWithCycles`'s `indexByName`) to decide.
fn normalizeRelationTargets(sa: std.mem.Allocator, c: schema.Collection, all: []const schema.Collection) !schema.Collection {
    const fields = try sa.alloc(schema.Field, c.fields.len);
    for (c.fields, 0..) |f, i| {
        fields[i] = f;
        if (f.options == .relation) {
            var r = f.options.relation;
            r.targetCollectionId = schema_doc.targetName(r.targetCollectionId, c, all);
            fields[i].options = .{ .relation = r };
        }
    }
    var out = c;
    out.fields = fields;
    return out;
}

/// Manifest entry indices in load order (dependency order, restricted to the collections the
/// manifest actually names). Reuses the DDL pump's own three-colour-DFS ordering rather than
/// a second topological sort (`provision.topoOrder` silently skips cycle edges, which would
/// hide the very rows this runner needs to defer). Result lives on `sa`.
pub fn loadOrder(sa: std.mem.Allocator, live: []const schema.Collection, entries: []const Entry) ![]const usize {
    const cols = try manifestCollections(sa, live, entries);
    var order: std.ArrayList(usize) = .empty;
    var back: std.ArrayList(schema_diff.Deferred) = .empty;
    try schema_diff.orderWithCycles(sa, cols, &order, &back);
    return order.toOwnedSlice(sa);
}

/// True if `collection.field` (as named in `cols`, i.e. post-normalization) is `required`.
fn fieldRequired(cols: []const schema.Collection, collection: []const u8, field: []const u8) bool {
    for (cols) |c| {
        if (!std.mem.eql(u8, c.name, collection)) continue;
        for (c.fields) |f| if (std.mem.eql(u8, f.name, field)) return f.required;
    }
    return false;
}

/// The (collection, field) relation values that must be stripped on load and patched
/// afterwards: every cross-collection cycle back-edge PLUS every self-relation. Result lives
/// on `sa`.
///
/// Fails with `error.RequiredRelationInCycle` if any of those fields is `required` — a
/// required field on a cycle back-edge or self-relation has no legal two-pass load order
/// (phase 1 must strip it to break the cycle, and a required field absent from every row
/// then fails `validation_required` on every single row). Checked here, before `run` imports
/// anything, so the failure is one actionable error instead of per-row noise.
pub fn deferralSet(sa: std.mem.Allocator, live: []const schema.Collection, entries: []const Entry) ![]const schema_diff.Deferred {
    const cols = try manifestCollections(sa, live, entries);
    var order: std.ArrayList(usize) = .empty;
    var out: std.ArrayList(schema_diff.Deferred) = .empty;
    // Cross-collection cycle back-edges, from the same routine the DDL pump uses.
    try schema_diff.orderWithCycles(sa, cols, &order, &out);
    // Plus every self-relation. `orderWithCycles` deliberately skips these (a table's own FK
    // is satisfiable at CREATE time), but the DATA pump cannot order rows within one file, so
    // a self-relation must be deferred too.
    for (cols) |c| {
        for (c.fields) |f| {
            if (f.options != .relation) continue;
            if (!std.mem.eql(u8, f.options.relation.targetCollectionId, c.name)) continue;
            try out.append(sa, .{ .collection = c.name, .field = f.name });
        }
    }
    for (out.items) |d| {
        if (!fieldRequired(cols, d.collection, d.field)) continue;
        last_error_detail = std.fmt.bufPrint(
            &detail_buf,
            "{s}.{s} is required but sits on a relation cycle/self-relation with no legal load order; " ++
                "make it optional for this import, then restore required and backfill the value afterward",
            .{ d.collection, d.field },
        ) catch "";
        return ManifestError.RequiredRelationInCycle;
    }
    return out.toOwnedSlice(sa);
}

pub const EntryReport = struct {
    collection: []const u8,
    created: usize,
    updated: usize,
    failed: usize,
};

pub const Report = struct {
    entries: []const EntryReport,
    /// Rows whose deferred relation values were patched in phase 2.
    patched: usize = 0,
    failed: usize = 0,
    /// True when phase 2 (the patch pass) was skipped because this was a dry run. Phase 1
    /// rolls every batch back in a dry run, so none of its rows ever exist for phase 2's
    /// `records.updateInTxn` to find — running it anyway would validation-fail on every
    /// deferred row and abort the whole run. `patched` stays 0 in that case; this field lets
    /// a caller (the CLI summary) tell "dry run, patch pass skipped" apart from "real run,
    /// nothing needed patching".
    patch_skipped_dry_run: bool = false,
};

pub const RunOptions = struct {
    /// Directory that relative `file` paths resolve against (the manifest's own directory).
    base_dir: []const u8,
    /// Forwarded verbatim to every `import.run`, minus `collection` / `upsert_key`, which
    /// come from the manifest entry, and `strip_fields`, which the runner computes itself.
    import: import.Options,
};

fn resolvePath(sa: std.mem.Allocator, base: []const u8, file: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(file)) return file;
    return std.fs.path.join(sa, &.{ base, file });
}

fn strippedFor(sa: std.mem.Allocator, set: []const schema_diff.Deferred, collection: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (set) |d| if (std.mem.eql(u8, d.collection, collection)) try out.append(sa, d.field);
    return out.toOwnedSlice(sa);
}

/// Write one NDJSON finding for a phase-2 patch failure. Mirrors `import.zig`'s `logFinding`
/// format (line-oriented JSON on `opts.import.error_log`), keyed by record id rather than
/// line number — phase 2 identifies rows by id, not by their position in the file. Never
/// fails the run: a full or broken sink loses the finding, not the data.
fn logPatchFinding(log: ?*std.Io.Writer, collection: []const u8, id: []const u8, code: []const u8, detail: []const u8) void {
    const sink = log orelse return;
    sink.print(
        "{{\"collection\":{f},\"id\":{f},\"code\":\"{s}\",\"detail\":{f}}}\n",
        .{ std.json.fmt(collection, .{}), std.json.fmt(id, .{}), code, std.json.fmt(detail, .{}) },
    ) catch {};
}

threadlocal var patch_detail_buf: [256]u8 = undefined;
/// Capture the failing field detail while `records.last_errors` is still valid — it points
/// into the row arena, which is reset on the next loop iteration. Empty for anything but
/// `error.Validation`.
fn capturePatchDetail(err: anyerror) []const u8 {
    if (err != error.Validation) return "";
    const errs = records.last_errors orelse return "";
    if (errs.len == 0) return "";
    const ve = errs[0];
    return std.fmt.bufPrint(&patch_detail_buf, "{s}: {s} ({s})", .{ ve.field, ve.message, ve.code }) catch "";
}

const PatchOutcome = struct { patched: usize = 0, failed: usize = 0 };

/// Re-read the file and issue one update per row carrying a deferred value. Requires the row
/// to carry its own `id` — without one there is nothing to patch, since the record's
/// generated id is not knowable from the file. Rows with no deferred value are skipped.
///
/// Only called for a real (non-dry-run) run — see `Report.patch_skipped_dry_run`. Always
/// commits: a dry run never reaches here.
///
/// A missing target row (phase 1 never created this id — typically a `continue_on_error`
/// row that failed phase 1) or a validation failure on the patch itself: under
/// `continue_on_error` both are logged as an NDJSON finding and counted in
/// `PatchOutcome.failed`, and the pass continues; otherwise they abort the whole patch pass
/// (rolled back) and propagate.
fn patchDeferred(
    w: *db.Db,
    io: std.Io,
    sa: std.mem.Allocator,
    opts: RunOptions,
    e: Entry,
    strip: []const []const u8,
    line_buf: []u8,
) ManifestError!PatchOutcome {
    const path = try resolvePath(sa, opts.base_dir, e.file);
    const col = (try collections.get(sa, w, e.collection)) orelse return ManifestError.UnknownCollection;

    const f = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer f.close(io);
    var fr = f.readerStreaming(io, line_buf);

    var row_arena = std.heap.ArenaAllocator.init(sa);
    defer row_arena.deinit();

    var out: PatchOutcome = .{};
    try w.begin();
    errdefer w.rollback() catch {};
    while (true) {
        const maybe = try fr.interface.takeDelimiter('\n');
        const raw = maybe orelse break;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        _ = row_arena.reset(.retain_capacity);
        const a = row_arena.allocator();

        var parsed = std.json.parseFromSliceLeaky(std.json.Value, a, line, .{}) catch continue;
        if (parsed != .object) continue;

        var patch: std.json.ObjectMap = .empty;
        for (strip) |field| {
            const v = parsed.object.get(field) orelse continue;
            if (v == .null) continue;
            try patch.put(a, field, v);
        }
        if (patch.count() == 0) continue;

        const idv = parsed.object.get("id") orelse return ManifestError.DeferredRowMissingId;
        if (idv != .string or idv.string.len == 0) return ManifestError.DeferredRowMissingId;

        const updated = records.updateInTxn(a, w, col, idv.string, .{ .object = patch }) catch |err| {
            if (!opts.import.continue_on_error) return err;
            logPatchFinding(opts.import.error_log, e.collection, idv.string, @errorName(err), capturePatchDetail(err));
            out.failed += 1;
            continue;
        };
        if (updated == null) {
            // The id this row names does not exist to patch — phase 1 either failed it
            // (continue_on_error) or, absent that, this is a manifest/data inconsistency.
            if (!opts.import.continue_on_error) return ManifestError.DeferredTargetRowMissing;
            logPatchFinding(
                opts.import.error_log,
                e.collection,
                idv.string,
                "DeferredTargetRowMissing",
                "phase-1 row for this id was not found; the deferred value was not patched",
            );
            out.failed += 1;
            continue;
        }
        out.patched += 1;
    }
    try w.commit();
    return out;
}

/// Load every file in dependency order, then patch the deferred relation values. Phase 1
/// imports every row per manifest entry with its collection's deferred fields stripped;
/// phase 2 re-reads each affected file and patches those fields in by record id, now that
/// every target row exists (mirrors the schema apply two-pass design in `schema_diff.zig` /
/// `ddl.zig`). Owned result on `alloc`; free `Report.entries`. NOT fully self-contained,
/// though: each `Report.entries[i].collection` is the SAME slice as
/// `manifest.entries[i].collection` (never duped onto `alloc`), so `manifest` must outlive
/// every read of `Report.entries[].collection` — do not `manifest.deinit()` before you're
/// done with the report.
pub fn run(
    app: *import.App,
    w: *db.Db,
    io: std.Io,
    alloc: std.mem.Allocator,
    manifest: Manifest,
    opts: RunOptions,
) ManifestError!Report {
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const sa = scratch.allocator();

    const all_live = try collections.list(sa, w);
    const order = try loadOrder(sa, all_live, manifest.entries);
    const deferred = try deferralSet(sa, all_live, manifest.entries);

    var reports = try alloc.alloc(EntryReport, manifest.entries.len);
    // The caller owns `reports` only once we return it; free it on every error path.
    errdefer alloc.free(reports);

    var total_failed: usize = 0;
    const line_buf = try sa.alloc(u8, 1 << 20);

    // Phase 1 — load, with deferred relation keys stripped from every row.
    for (order) |i| {
        const e = manifest.entries[i];
        const path = try resolvePath(sa, opts.base_dir, e.file);
        var o = opts.import;
        o.collection = e.collection;
        o.upsert_key = e.upsert_key;
        o.strip_fields = try strippedFor(sa, deferred, e.collection);

        const f = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer f.close(io);
        var fr = f.readerStreaming(io, line_buf);
        const rep = try import.run(app, w, io, &fr.interface, o);
        reports[i] = .{ .collection = e.collection, .created = rep.created, .updated = rep.updated, .failed = rep.failed };
        total_failed += rep.failed;
    }

    // Phase 2 — patch the deferred values, now that every target row exists. Skipped
    // entirely in a dry run: phase 1 rolled every one of its batches back, so none of those
    // rows ever exist on disk for `records.updateInTxn` to find. Running phase 2 anyway would
    // validation-fail on every deferred row and abort the whole run — see
    // `Report.patch_skipped_dry_run`.
    var patched: usize = 0;
    var patch_skipped_dry_run = false;
    if (opts.import.dry_run) {
        patch_skipped_dry_run = true;
    } else {
        for (order) |i| {
            const e = manifest.entries[i];
            const strip = try strippedFor(sa, deferred, e.collection);
            if (strip.len == 0) continue;
            const outcome = try patchDeferred(w, io, sa, opts, e, strip, line_buf);
            patched += outcome.patched;
            total_failed += outcome.failed;
        }
    }

    return .{ .entries = reports, .patched = patched, .failed = total_failed, .patch_skipped_dry_run = patch_skipped_dry_run };
}

test "parseManifest reads entries and rejects a bad document" {
    const a = std.testing.allocator;
    var m = try parseManifest(a,
        \\{"zigbaseImportManifest":1,"collections":[
        \\  {"collection":"authors","file":"authors.ndjson"},
        \\  {"collection":"posts","file":"posts.ndjson","upsertKey":"slug"}
        \\]}
    );
    defer m.deinit();
    try std.testing.expectEqual(@as(usize, 2), m.entries.len);
    try std.testing.expectEqualStrings("authors", m.entries[0].collection);
    try std.testing.expectEqual(@as(?[]const u8, null), m.entries[0].upsert_key);
    try std.testing.expectEqualStrings("slug", m.entries[1].upsert_key.?);

    try std.testing.expectError(ManifestError.InvalidManifest, parseManifest(a, "[]"));
    try std.testing.expectError(ManifestError.UnsupportedVersion, parseManifest(a,
        \\{"zigbaseImportManifest":7,"collections":[]}
    ));
    try std.testing.expectError(ManifestError.InvalidManifest, parseManifest(a,
        \\{"zigbaseImportManifest":1,"collections":[{"collection":"a"}]}
    ));
}

test "loadOrder puts relation targets before their referrers" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const sa = arena.allocator();

    const live = [_]schema.Collection{
        .{ .id = "c1", .name = "posts", .fields = &.{relField("author", "authors", 1)} },
        .{ .id = "c2", .name = "authors", .fields = &.{} },
    };
    const entries = [_]Entry{
        .{ .collection = "posts", .file = "p.ndjson" },
        .{ .collection = "authors", .file = "a.ndjson" },
    };
    const order = try loadOrder(sa, &live, &entries);
    try std.testing.expectEqual(@as(usize, 2), order.len);
    try std.testing.expectEqual(@as(usize, 1), order[0]); // authors first
    try std.testing.expectEqual(@as(usize, 0), order[1]);
}

test "loadOrder and deferralSet also work when targetCollectionId is stored as an id, not a name" {
    // The comptime provisioning path (`provision.resolveTargets`) persists a relation's
    // target as the target's real collection id, not its name — "so the persisted metadata
    // matches what the runtime API produces" (see provision.zig). `collections.list` hands
    // that raw value straight through, so a manifest run against a normally-provisioned app
    // must normalize it the same way `schema_doc.dump` does before it reaches
    // `schema_diff.orderWithCycles`, which is name-only.
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const sa = arena.allocator();

    const live = [_]schema.Collection{
        .{ .id = "cPosts", .name = "posts", .fields = &.{relField("author", "cAuthors", 1)} },
        .{ .id = "cAuthors", .name = "authors", .fields = &.{} },
        .{ .id = "cTree", .name = "tree", .fields = &.{relField("parent", "cTree", 1)} },
    };
    const entries = [_]Entry{
        .{ .collection = "posts", .file = "p.ndjson" },
        .{ .collection = "authors", .file = "a.ndjson" },
        .{ .collection = "tree", .file = "t.ndjson" },
    };

    const order = try loadOrder(sa, &live, &entries);
    try std.testing.expectEqual(@as(usize, 3), order.len);
    // authors (index 1) must precede posts (index 0); tree's self-relation is not an edge.
    var authors_pos: usize = 0;
    var posts_pos: usize = 0;
    for (order, 0..) |idx, pos| {
        if (idx == 1) authors_pos = pos;
        if (idx == 0) posts_pos = pos;
    }
    try std.testing.expect(authors_pos < posts_pos);

    const set = try deferralSet(sa, &live, &entries);
    try std.testing.expectEqual(@as(usize, 1), set.len);
    try std.testing.expectEqualStrings("tree", set[0].collection);
    try std.testing.expectEqualStrings("parent", set[0].field);
}

test "deferralSet covers cycle back-edges AND self-relations" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const sa = arena.allocator();

    const live = [_]schema.Collection{
        .{ .id = "c1", .name = "a", .fields = &.{relField("toB", "b", 1)} },
        .{ .id = "c2", .name = "b", .fields = &.{relField("toA", "a", 1)} },
        .{ .id = "c3", .name = "tree", .fields = &.{relField("parent", "tree", 1)} },
    };
    const entries = [_]Entry{
        .{ .collection = "a", .file = "a.ndjson" },
        .{ .collection = "b", .file = "b.ndjson" },
        .{ .collection = "tree", .file = "t.ndjson" },
    };
    const set = try deferralSet(sa, &live, &entries);
    // One cycle back-edge plus the self-relation.
    try std.testing.expectEqual(@as(usize, 2), set.len);
    var saw_self = false;
    for (set) |d| if (std.mem.eql(u8, d.collection, "tree") and std.mem.eql(u8, d.field, "parent")) {
        saw_self = true;
    };
    try std.testing.expect(saw_self);
}

test "a self-relation loads in any row order and is patched afterwards" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    var app = import.testApp(a, io);

    const tree = try collections.create(a, io, &d, .{
        .id = "",
        .name = "tree",
        .fields = &.{
            .{ .id = "", .name = "label", .options = .{ .text = .{} } },
            relField("parent", "tree", 1),
        },
    });
    defer tree.deinit(a);

    // The CHILD comes first and references a parent that does not exist yet: without
    // deferral this is a foreign-key / validation_not_found failure.
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    try dir.dir.writeFile(io, .{ .sub_path = "tree.ndjson", .data =
        \\{"id":"treechild00001","label":"child","parent":"treeroot000001"}
        \\{"id":"treeroot000001","label":"root","parent":null}
        \\
    });
    const base = try dir.dir.realPathFileAlloc(io, ".", a);
    defer a.free(base);

    var m = try parseManifest(a,
        \\{"zigbaseImportManifest":1,"collections":[{"collection":"tree","file":"tree.ndjson"}]}
    );
    defer m.deinit();

    const rep = try run(&app, &d, io, a, m, .{ .base_dir = base, .import = .{ .collection = "" } });
    defer a.free(rep.entries);
    try std.testing.expectEqual(@as(usize, 2), rep.entries[0].created);
    try std.testing.expectEqual(@as(usize, 1), rep.patched); // only the child had a parent

    var st = try d.prepare("SELECT \"parent\" FROM \"tree\" WHERE \"id\"='treechild00001';");
    defer st.finalize();
    try std.testing.expect(try st.step());
    try std.testing.expectEqualStrings("treeroot000001", st.columnText(0));
}

test "run fails fast with RequiredRelationInCycle instead of drowning every row in validation_required" {
    // A required self-relation has no legal two-pass load order: phase 1 must strip it to
    // break the cycle, and a required field absent from every row then fails
    // `validation_required` on EVERY row. `deferralSet` must catch this before phase 1 ever
    // runs, not let it manifest as per-row noise.
    const a = std.testing.allocator;
    const io = std.testing.io;
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    var app = import.testApp(a, io);

    const tree = try collections.create(a, io, &d, .{
        .id = "",
        .name = "tree",
        .fields = &.{
            .{ .id = "", .name = "label", .options = .{ .text = .{} } },
            .{ .id = "", .name = "parent", .required = true, .options = .{ .relation = .{ .targetCollectionId = "tree", .maxSelect = 1 } } },
        },
    });
    defer tree.deinit(a);

    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    try dir.dir.writeFile(io, .{ .sub_path = "tree.ndjson", .data =
        \\{"id":"treechild00001","label":"child","parent":"treeroot000001"}
        \\{"id":"treeroot000001","label":"root","parent":null}
        \\
    });
    const base = try dir.dir.realPathFileAlloc(io, ".", a);
    defer a.free(base);

    var m = try parseManifest(a,
        \\{"zigbaseImportManifest":1,"collections":[{"collection":"tree","file":"tree.ndjson"}]}
    );
    defer m.deinit();

    try std.testing.expectError(
        ManifestError.RequiredRelationInCycle,
        run(&app, &d, io, a, m, .{ .base_dir = base, .import = .{ .collection = "" } }),
    );
    // The detail names the collection and field that made this unsatisfiable.
    try std.testing.expect(std.mem.indexOf(u8, last_error_detail, "tree.parent") != null);

    // Zero rows imported: the error surfaces at manifest analysis, before phase 1 opens the
    // file at all.
    var st = try d.prepare("SELECT COUNT(*) FROM \"tree\";");
    defer st.finalize();
    try std.testing.expect(try st.step());
    try std.testing.expectEqual(@as(i64, 0), st.columnInt(0));
}

test "run: dry_run skips the patch pass instead of aborting on the now-rolled-back targets" {
    // Phase 1 rolls every batch back in a dry run, so phase 2 would find none of its target
    // rows and validation-fail on all of them if it ran. `run` must skip phase 2 entirely and
    // report that honestly instead of aborting.
    const a = std.testing.allocator;
    const io = std.testing.io;
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    var app = import.testApp(a, io);

    const tree = try collections.create(a, io, &d, .{
        .id = "",
        .name = "tree",
        .fields = &.{
            .{ .id = "", .name = "label", .options = .{ .text = .{} } },
            relField("parent", "tree", 1),
        },
    });
    defer tree.deinit(a);

    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    try dir.dir.writeFile(io, .{ .sub_path = "tree.ndjson", .data =
        \\{"id":"treechild00001","label":"child","parent":"treeroot000001"}
        \\{"id":"treeroot000001","label":"root","parent":null}
        \\
    });
    const base = try dir.dir.realPathFileAlloc(io, ".", a);
    defer a.free(base);

    var m = try parseManifest(a,
        \\{"zigbaseImportManifest":1,"collections":[{"collection":"tree","file":"tree.ndjson"}]}
    );
    defer m.deinit();

    const rep = try run(&app, &d, io, a, m, .{ .base_dir = base, .import = .{ .collection = "", .dry_run = true } });
    defer a.free(rep.entries);
    try std.testing.expectEqual(@as(usize, 2), rep.entries[0].created); // what a real run WOULD create
    try std.testing.expectEqual(@as(usize, 0), rep.patched);
    try std.testing.expect(rep.patch_skipped_dry_run);
    try std.testing.expectEqual(@as(usize, 0), rep.failed);

    var st = try d.prepare("SELECT COUNT(*) FROM \"tree\";");
    defer st.finalize();
    try std.testing.expect(try st.step());
    try std.testing.expectEqual(@as(i64, 0), st.columnInt(0)); // nothing actually committed
}

test "run: continue_on_error survives a phase-1-failed row that also carried a deferred value" {
    // "badchild" fails phase 1 (missing required label) but still names a deferred `parent`
    // value. Phase 2 must not silently count a patch against an id that was never created,
    // must not abort the run, and must surface the failure in the report counts.
    const a = std.testing.allocator;
    const io = std.testing.io;
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    var app = import.testApp(a, io);

    const tree = try collections.create(a, io, &d, .{
        .id = "",
        .name = "tree",
        .fields = &.{
            .{ .id = "", .name = "label", .required = true, .options = .{ .text = .{} } },
            relField("parent", "tree", 1),
        },
    });
    defer tree.deinit(a);

    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    try dir.dir.writeFile(io, .{ .sub_path = "tree.ndjson", .data =
        \\{"id":"badchild00001","label":"","parent":"rootok0000001"}
        \\{"id":"rootok0000001","label":"root","parent":null}
        \\
    });
    const base = try dir.dir.realPathFileAlloc(io, ".", a);
    defer a.free(base);

    var m = try parseManifest(a,
        \\{"zigbaseImportManifest":1,"collections":[{"collection":"tree","file":"tree.ndjson"}]}
    );
    defer m.deinit();

    const rep = try run(&app, &d, io, a, m, .{ .base_dir = base, .import = .{ .collection = "", .continue_on_error = true } });
    defer a.free(rep.entries);

    try std.testing.expectEqual(@as(usize, 1), rep.entries[0].created); // rootok0000001 only
    try std.testing.expectEqual(@as(usize, 1), rep.entries[0].failed); // badchild00001
    try std.testing.expectEqual(@as(usize, 0), rep.patched); // the only deferred value belonged to the failed row
    try std.testing.expectEqual(@as(usize, 2), rep.failed); // phase-1 failure + phase-2 missing-target failure

    var st = try d.prepare("SELECT COUNT(*) FROM \"tree\";");
    defer st.finalize();
    try std.testing.expect(try st.step());
    try std.testing.expectEqual(@as(i64, 1), st.columnInt(0));
}
