const std = @import("std");
const build_options = @import("build_options");
const schema = @import("../schema.zig");
const db = @import("../db.zig");
const migrations = @import("../migrations.zig");
const provision = @import("../provision.zig");
const acquire_core = @import("acquire.zig");

/// Build an id → name map for ALL collections (user + system) so that relation
/// fields stored with UUID targetCollectionId can be resolved back to names.
/// The emitter's collectionExists() checks by name, so without this resolve step
/// the runtime path would differ from the comptime path (which stores names).
fn buildIdNameMap(alloc: std.mem.Allocator, w: *db.Db) !std.StringHashMap([]const u8) {
    var map = std.StringHashMap([]const u8).init(alloc);
    var st = try w.prepare("SELECT id, name FROM \"_collections\";");
    defer st.finalize();
    while (try st.step()) {
        const id = try alloc.dupe(u8, st.columnText(0));
        const name = try alloc.dupe(u8, st.columnText(1));
        try map.put(id, name);
    }
    return map;
}

/// Read all user (non-system) collections from an open db handle's
/// `_collections` table, name-sorted. The schema/indexes/options columns are
/// JSON text the engine wrote via fieldsToJson/indexesToJson/optionsToJson, so
/// they parse back through acquire_core.buildCollection.
pub fn acquireFromDb(gpa: std.mem.Allocator, w: *db.Db) !acquire_core.Acquired {
    // Contract-2 (owns its memory, like std.json.Parsed): the whole interlinked graph — the
    // collections, their fields/indexes/options, the transient id→name map, and the per-row
    // RawRow dupes — is built in this arena, so `Acquired.deinit()` reclaims all of it. No
    // piecewise free (which would mean mirroring every schema parser).
    const arena = try acquire_core.newArena(gpa);
    errdefer {
        arena.deinit();
        gpa.destroy(arena);
    }
    const alloc = arena.allocator();

    // Build id→name map FIRST so we can resolve relation targetCollectionIds.
    // Provisioning stores UUIDs; the emitter and comptime path use names. The map is transient
    // scratch (its resolved names are duped into the graph), so deinit it here — symmetric with
    // acquire_http.parseCollections. (A no-op under this arena, but it documents the lifetime.)
    var id_to_name = try buildIdNameMap(alloc, w);
    defer id_to_name.deinit();

    var st = try w.prepare(
        \\SELECT name, type, schema, indexes, options
        \\ FROM "_collections" WHERE system = 0 ORDER BY name;
    );
    defer st.finalize();

    var list: std.ArrayList(schema.Collection) = .empty;
    while (try st.step()) {
        const row = acquire_core.RawRow{
            .name = try alloc.dupe(u8, st.columnText(0)),
            .type_str = try alloc.dupe(u8, st.columnText(1)),
            .schema_json = try alloc.dupe(u8, st.columnText(2)),
            .indexes_json = try alloc.dupe(u8, st.columnText(3)),
            .options_json = try alloc.dupe(u8, st.columnText(4)),
        };
        try list.append(alloc, try acquire_core.buildCollection(alloc, row));
    }
    const cols = try list.toOwnedSlice(alloc);
    // Resolve UUID targetCollectionIds → names so the emitter's collectionExists()
    // (which checks by name) works identically to the comptime path.
    try acquire_core.resolveRelationTargets(alloc, cols, &id_to_name);
    acquire_core.sortByName(cols); // ORDER BY name already sorts, but keep adapters symmetric.
    return .{ .arena = arena, .collections = cols };
}

/// Acquire collections from a backend-agnostic data source `target`. Two shapes:
///   - a `postgres://…` / `postgresql://…` URI  → opens a PG handle and reads `_collections`
///     (requires a `-Dpostgres` build; the metadata is backend-neutral, so codegen output is
///     identical to the SQLite path).
///   - anything else (a data-dir path)          → opens `<target>/data.db` (SQLite).
/// Errors if the source has no provisioned `_collections` (start the server once first).
pub fn acquire(alloc: std.mem.Allocator, io: std.Io, target: []const u8) !acquire_core.Acquired {
    if (db.connstrLooksLikePostgres(target)) {
        // The `openPostgres` constructor only exists when Postgres is compiled in; the comptime
        // branch keeps the default (`-Dpostgres=false`) build from referencing the PG subtree.
        if (build_options.postgres) {
            var w = db.Db.openPostgres(alloc, io, target) catch |e| {
                // `target` is a postgres:// URI that may carry credentials — never log it.
                std.log.err("typegen: cannot connect to the Postgres data source: {s}", .{@errorName(e)});
                return error.DataDirOpenFailed;
            };
            defer w.close();
            return acquireFromDb(alloc, &w) catch |e| {
                std.log.err("typegen: cannot read _collections from the Postgres data source: {s} (has the server provisioned this database?)", .{@errorName(e)});
                return error.DataDirReadFailed;
            };
        } else {
            std.log.err("typegen: a postgres:// data source requires a -Dpostgres build", .{});
            return error.PostgresNotBuilt;
        }
    }

    const path = try std.fmt.allocPrintSentinel(alloc, "{s}/data.db", .{target}, 0);
    defer alloc.free(path);
    // A URL-like target (a malformed `postgres:/user:pass@host/db` that escaped the `postgres://`
    // detection above, etc.) may carry credentials — NEVER echo it in a log. A plain filesystem
    // path is not a secret, so we show it (and the derived `<path>/data.db`) verbatim.
    const url_like = looksUrlLike(target);
    var w = db.Db.open(path) catch |e| {
        if (url_like) {
            std.log.err("typegen: cannot open the data source ({s}): {s}", .{ redacted, @errorName(e) });
            // Nudge toward the right scheme — without echoing the (possibly credential-bearing) target.
            std.log.err("typegen: the target looks like a URL — did you mean a 'postgres://…' connection string?", .{});
        } else {
            std.log.err("typegen: cannot open '{s}': {s}", .{ path, @errorName(e) });
        }
        return error.DataDirOpenFailed;
    };
    defer w.close();
    return acquireFromDb(alloc, &w) catch |e| {
        const shown: []const u8 = if (url_like) redacted else path;
        std.log.err("typegen: cannot read _collections from '{s}': {s} (has the server provisioned this data dir?)", .{ shown, @errorName(e) });
        return error.DataDirReadFailed;
    };
}

/// The placeholder logged in place of a URL-like target (which may carry credentials).
const redacted = "<redacted url-like target>";

/// True if `s` looks like a URL / connection string (so it must NOT be logged raw): it contains
/// `://`, contains an `@` (a `user:pass@host` credential pattern), or begins with an RFC-3986 URI
/// scheme (`scheme:` where `scheme` is `ALPHA *( ALPHA / DIGIT / "+" / "-" / "." )`). A plain
/// filesystem path (`/var/data`, `./out`, `mydir`) is none of these and is safe to log.
fn looksUrlLike(s: []const u8) bool {
    if (std.mem.indexOf(u8, s, "://") != null) return true;
    if (std.mem.indexOfScalar(u8, s, '@') != null) return true;
    // Leading `scheme:` (e.g. `postgres:/…` with a single slash, which is URL-ish but not `://`).
    if (s.len == 0 or !std.ascii.isAlphabetic(s[0])) return false;
    var i: usize = 1;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == ':') return true; // a scheme delimiter before any other terminator
        if (!(std.ascii.isAlphanumeric(c) or c == '+' or c == '-' or c == '.')) return false;
    }
    return false;
}

test "looksUrlLike: redacts URL/credential targets, allows plain paths" {
    // URL-like → must be treated as a secret (redacted in logs).
    try std.testing.expect(looksUrlLike("postgres://u:p@h/db"));
    try std.testing.expect(looksUrlLike("postgresql://h:5432/db"));
    try std.testing.expect(looksUrlLike("postgres:/u:p@h/db")); // malformed single-slash, scheme prefix
    try std.testing.expect(looksUrlLike("u:p@host/db")); // credential pattern, no scheme
    try std.testing.expect(looksUrlLike("scheme:rest"));
    // Plain filesystem paths → not secrets, safe to log verbatim.
    try std.testing.expect(!looksUrlLike("/var/data"));
    try std.testing.expect(!looksUrlLike("./out"));
    try std.testing.expect(!looksUrlLike("mydir"));
    try std.testing.expect(!looksUrlLike("data_dir/sub"));
    try std.testing.expect(!looksUrlLike(""));
}

test "acquireFromDb returns user collections (sorted, system excluded, auth stripped)" {
    // Provisioning is test SETUP — keep it arena-scoped. `acquireFromDb` returns a contract-2
    // `Acquired` that OWNS its whole graph, so it runs under the leak detector directly: if it
    // allocated anything outside its arena, or the test forgot `deinit`, this would leak-fail.
    var setup = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer setup.deinit();
    const sa = setup.allocator();

    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);

    const specs = [_]schema.Collection{
        .{ .id = "", .name = "users", .type = .auth, .fields = &.{
            .{ .id = "", .name = "displayName", .options = .{ .text = .{} } },
        } },
        .{ .id = "", .name = "articles", .fields = &.{
            .{ .id = "", .name = "title", .options = .{ .text = .{} } },
            .{ .id = "", .name = "views", .options = .{ .number = .{ .mode = .int } } },
        } },
    };
    try provision.applySpecs(sa, std.testing.io, &d, &specs);

    var acq = try acquireFromDb(std.testing.allocator, &d);
    defer acq.deinit();
    const cols = acq.collections;
    // _superusers (system) excluded; only the two user collections, name-sorted.
    try std.testing.expectEqual(@as(usize, 2), cols.len);
    try std.testing.expectEqualStrings("articles", cols[0].name);
    try std.testing.expectEqualStrings("users", cols[1].name);
    // Auth system fields stripped: users has only displayName.
    try std.testing.expectEqual(@as(usize, 1), cols[1].fields.len);
    try std.testing.expectEqualStrings("displayName", cols[1].fields[0].name);
    // Number mode preserved through the round-trip.
    try std.testing.expectEqual(schema.FieldType.number, cols[0].fields[1].fieldType());
}
