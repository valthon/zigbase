//! Offline collection rename. Immutable storage namespaces keep all file objects
//! in place while durable upload/cleanup ownership follows the logical name.
const std = @import("std");
const db = @import("db.zig");
const schema = @import("schema.zig");
const collections = @import("collections.zig");
const ddl = @import("ddl.zig");
const generation = @import("schema_gen.zig");
const fts = @import("search/fts.zig");

pub const Error = collections.EngineError || fts.EnsureIndexError || error{
    InvalidRenameName,
    SystemCollectionRename,
    PendingStorageDependency,
    InvalidPendingMetadata,
    LegacyAlterTableEnabled,
    PendingIdempotencyReceipts,
    InvalidReceiptLedger,
    RenameEpochExhausted,
} || @import("collection_rename_indexes.zig").Error;

const Reference = struct { table: []const u8, column: []const u8 = "collectionRef" };
const persistent = [_]Reference{
    .{ .table = "_externalAuths" },
    .{ .table = "_webauthnCredentials" },
    .{ .table = "_twoFactorCredentials" },
    .{ .table = "_twoFactorRates" },
    .{ .table = "_memberships", .column = "user_collection" },
    .{ .table = "_events", .column = "actor_collection" },
};
const transient = [_]Reference{
    .{ .table = "_sessions" },
    .{ .table = "_oauthStates" },
    .{ .table = "_authChallenges" },
    .{ .table = "_twoFactorAttempts" },
    .{ .table = "_cursorStates" },
};

fn prepare(a: std.mem.Allocator, w: *db.Db, sql: []const u8) (db.DbError || std.mem.Allocator.Error)!db.Stmt {
    const lowered = db.dbDialect(w).renumberPlaceholders(a, sql) catch return error.OutOfMemory;
    defer a.free(lowered);
    return w.prepare(lowered);
}

fn objectExists(a: std.mem.Allocator, w: *db.Db, name: []const u8) (db.DbError || std.mem.Allocator.Error)!bool {
    var st = try prepare(a, w, if (db.dbDialect(w).kind == .sqlite)
        "SELECT 1 FROM sqlite_master WHERE name=?1 COLLATE NOCASE LIMIT 1;"
    else
        "SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname=current_schema() AND c.relname=?1 LIMIT 1;");
    defer st.finalize();
    try st.bindText(1, name);
    return st.step();
}

fn hasReference(a: std.mem.Allocator, w: *db.Db, ref: Reference, name: []const u8) Error!bool {
    if (!try objectExists(a, w, ref.table)) return false;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    var st = try prepare(scratch, w, try std.fmt.allocPrint(scratch, "SELECT 1 FROM {s} WHERE {s}=?1 LIMIT 1;", .{
        try ddl.quoteIdent(scratch, ref.table), try ddl.quoteIdent(scratch, ref.column),
    }));
    defer st.finalize();
    try st.bindText(1, name);
    return st.step();
}

fn changeReference(a: std.mem.Allocator, w: *db.Db, ref: Reference, old: []const u8, new: ?[]const u8) Error!void {
    if (!try objectExists(a, w, ref.table)) return;
    const table = try ddl.quoteIdent(a, ref.table);
    defer a.free(table);
    const column = try ddl.quoteIdent(a, ref.column);
    defer a.free(column);
    const sql = if (new != null)
        try std.fmt.allocPrint(a, "UPDATE {s} SET {s}=?2 WHERE {s}=?1;", .{ table, column, column })
    else
        try std.fmt.allocPrint(a, "DELETE FROM {s} WHERE {s}=?1;", .{ table, column });
    defer a.free(sql);
    var st = try prepare(a, w, sql);
    defer st.finalize();
    try st.bindText(1, old);
    if (new) |name| try st.bindText(2, name);
    _ = try st.step();
}

fn remapStorageOwner(value: *std.json.Value, old: schema.Collection, new: []const u8) Error!bool {
    if (value.* != .object) return error.InvalidPendingMetadata;
    const name = value.object.getPtr("collection") orelse return error.InvalidPendingMetadata;
    const cid = value.object.get("collection_id") orelse return error.InvalidPendingMetadata;
    if (name.* != .string or cid != .string) return error.InvalidPendingMetadata;
    const same_name = std.mem.eql(u8, name.string, old.name);
    const same_id = std.mem.eql(u8, cid.string, old.id);
    if (same_name != same_id) return error.InvalidPendingMetadata;
    if (same_id) {
        name.* = .{ .string = new };
        return true;
    }
    if (std.mem.eql(u8, name.string, new)) return error.PendingStorageDependency;
    return false;
}

fn remapStorage(alloc: std.mem.Allocator, w: *db.Db, old: schema.Collection, new: []const u8) Error!void {
    for ([_]struct { table: []const u8, column: []const u8, predicate: []const u8, update: []const u8, upload: bool }{
        .{ .table = "_upload_sessions", .column = "metadata", .predicate = "1=1", .update = "UPDATE \"_upload_sessions\" SET metadata=?1 WHERE id=?2;", .upload = true },
        .{ .table = "_queue_jobs", .column = "payload", .predicate = "kind='file_cleanup' AND status<>'done'", .update = "UPDATE \"_queue_jobs\" SET payload=?1 WHERE id=?2;", .upload = false },
    }) |source| {
        if (!try objectExists(alloc, w, source.table)) continue;
        // Return oversized payloads as invalid NULL, not a truncated JSON prefix.
        // SQLite TEXT length/substr stop at NUL: measure raw bytes instead.
        const length = if (db.dbDialect(w).kind == .sqlite)
            try std.fmt.allocPrint(alloc, "length(CAST({s} AS BLOB))", .{source.column})
        else
            try std.fmt.allocPrint(alloc, "octet_length({s})", .{source.column});
        defer alloc.free(length);
        const sql = try std.fmt.allocPrint(alloc, "SELECT id,CASE WHEN {s}<=65536 THEN {s} ELSE NULL END FROM \"{s}\" WHERE {s}", .{ length, source.column, source.table, source.predicate });
        defer alloc.free(sql);
        const first_sql = try std.fmt.allocPrint(alloc, "{s} ORDER BY id LIMIT 64;", .{sql});
        defer alloc.free(first_sql);
        const next_sql = try std.fmt.allocPrint(alloc, "{s} AND id>?1 ORDER BY id LIMIT 64;", .{sql});
        defer alloc.free(next_sql);
        var first = try prepare(alloc, w, first_sql);
        defer first.finalize();
        var next = try prepare(alloc, w, next_sql);
        defer next.finalize();
        var update = try prepare(alloc, w, source.update);
        defer update.finalize();
        var last: std.ArrayList(u8) = .empty;
        defer last.deinit(alloc);
        var initial = true;
        while (true) {
            const st = if (initial) &first else &next;
            if (!initial) {
                st.reset();
                try st.clearBindings();
                try st.bindText(1, last.items);
            }
            var count: usize = 0;
            while (try st.step()) {
                // NULL cannot be addressed by equality and would also vanish
                // from subsequent keyset pages. Never silently skip that row.
                if (st.isNull(0)) return error.InvalidPendingMetadata;
                count += 1;
                last.clearRetainingCapacity();
                try last.appendSlice(alloc, st.columnText(0));
                // Parsing storage work is row-scoped, not retained in the migration
                // arena when a large durable queue must be relinked.
                var row = std.heap.ArenaAllocator.init(alloc);
                defer row.deinit();
                const a = row.allocator();
                if (st.isNull(1)) return error.InvalidPendingMetadata;
                const raw = st.columnText(1);
                if (raw.len > 65536) return error.InvalidPendingMetadata;
                const parsed = std.json.parseFromSlice(std.json.Value, a, raw, .{}) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    else => return error.InvalidPendingMetadata,
                };
                defer parsed.deinit();
                var value = parsed.value;
                if (value != .object) return error.InvalidPendingMetadata;
                const changed = if (source.upload) blk: {
                    const binding = value.object.getPtr("binding") orelse return error.InvalidPendingMetadata;
                    const target = value.object.getPtr("target") orelse return error.InvalidPendingMetadata;
                    const binding_changed = try remapStorageOwner(binding, old, new);
                    const target_changed = try remapStorageOwner(target, old, new);
                    break :blk binding_changed or target_changed;
                } else try remapStorageOwner(&value, old, new);
                if (changed) {
                    update.reset();
                    try update.clearBindings();
                    try update.bindText(1, try std.json.Stringify.valueAlloc(a, value, .{}));
                    try update.bindText(2, st.columnText(0));
                    _ = try update.step();
                    if (w.changesCount() != 1) return error.InvalidPendingMetadata;
                }
            }
            // Payloads change, but IDs and selection predicates remain stable.
            // Bound PostgreSQL's buffered SELECT and release the first page too.
            st.reset();
            if (count < 64) break;
            initial = false;
        }
    }
}

/// Self-freeing. A missing destination must stay missing for existing relations:
/// otherwise the rename would adopt dangling links instead of preserving them.
fn rejectDestinationRelations(alloc: std.mem.Allocator, w: *db.Db, to: []const u8) Error!void {
    const all = try collections.list(alloc, w);
    defer {
        for (all) |col| col.deinit(alloc);
        alloc.free(all);
    }
    for (all) |col| {
        for (col.fields) |field| {
            if (field.options == .relation and std.mem.eql(u8, field.options.relation.targetCollectionId, to)) return error.Conflict;
        }
    }
    // PostgreSQL FKs bind existing relation OIDs and cannot dangle. SQLite
    // permits missing parents, including in tables not owned by collections.
    // Its identifier matching is case-insensitive even for quoted FK targets.
    if (db.dbDialect(w).kind == .sqlite) {
        var st = try w.prepare("SELECT 1 FROM main.sqlite_schema AS s JOIN pragma_foreign_key_list(s.name, 'main') AS fk WHERE s.type='table' AND fk.\"table\"=?1 COLLATE NOCASE LIMIT 1;");
        defer st.finalize();
        try st.bindText(1, to);
        if (try st.step()) return error.Conflict;
    }
}

fn rollback(w: *db.Db, nested: bool) void {
    if (nested) {
        w.exec("ROLLBACK TO SAVEPOINT zb_collection_rename;") catch |err| {
            std.debug.panic("collection rename savepoint rollback failed: {s}; writer safety cannot be restored", .{@errorName(err)});
        };
        w.exec("RELEASE SAVEPOINT zb_collection_rename;") catch |err| std.debug.panic("collection rename savepoint release failed: {s}; writer safety cannot be restored", .{@errorName(err)});
    } else w.rollback() catch |err| std.debug.panic("collection rename rollback failed: {s}; writer safety cannot be restored", .{@errorName(err)});
}

/// Self-freeing. Requires all serving/worker processes stopped. Preserves stable
/// identities and user index names; invalidates in-flight auth/session capabilities.
pub fn rename(alloc: std.mem.Allocator, io: std.Io, w: *db.Db, from: []const u8, to: []const u8) Error!void {
    // Leave room for backend-generated FTS suffixes within PostgreSQL's 63 bytes.
    for ([_][]const u8{ from, to }) |name| {
        if (!schema.isValidIdentifier(name) or name.len > 55 or std.mem.endsWith(u8, name, "_fts")) return error.InvalidRenameName;
    }
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const a = scratch.allocator();
    const nested = w.inTransaction();
    if (nested) try w.exec("SAVEPOINT zb_collection_rename;") else try w.begin();
    errdefer rollback(w, nested);
    try @import("collection_rename_indexes.zig").rejectTemporaryRelations(w);
    try generation.lock(w);
    const old = (try collections.getByName(a, w, from)) orelse return error.NotFound;
    // The reverse operation uses these arguments as names, not lookup keys.
    // Accepting a collection ID here would make the apparent inverse ambiguous.
    if (!std.mem.eql(u8, from, old.name)) return error.InvalidRenameName;
    if (old.system or !schema.isValidIdentifier(old.name)) return error.SystemCollectionRename;
    if (old.name.len > 55 or std.mem.endsWith(u8, old.name, "_fts")) return error.InvalidRenameName;
    if (old.rename_epoch == std.math.maxInt(i64)) return error.RenameEpochExhausted;
    try @import("collection_rename_indexes.zig").preflight(a, w, old, to);
    if ((try collections.get(a, w, to)) != null or try objectExists(a, w, to)) return error.Conflict;
    for ([_][]const u8{ "_fts", "_fts_ai", "_fts_ad", "_fts_au", "_fts_idx", "_fts_data", "_fts_docsize", "_fts_config", "_fts_content" }) |suffix| {
        if (try objectExists(a, w, try std.fmt.allocPrint(a, "{s}{s}", .{ to, suffix }))) return error.Conflict;
    }
    try rejectDestinationRelations(alloc, w, to);
    // Imported metadata can make a legacy target name indistinguishable from
    // another collection's stable ID. Refuse ambiguity before changing either
    // the physical FK or its metadata; never silently retarget an ID relation.
    {
        var alias = try prepare(a, w, "SELECT 1 FROM \"_collections\" WHERE id=?1 AND id<>?2 LIMIT 1;");
        defer alias.finalize();
        try alias.bindText(1, old.name);
        try alias.bindText(2, old.id);
        if (try alias.step()) {
            for (try collections.list(a, w)) |col| {
                for (col.fields) |field| if (field.options == .relation and std.mem.eql(u8, field.options.relation.targetCollectionId, old.name)) return error.Conflict;
            }
        }
    }
    // Receipt scopes are opaque hashes of principal, operation and key. Even a
    // base collection's name may occur in an application operation scope, so no
    // subset can be proven unrelated. Preserve their promised retention window.
    const receipts_exist = if (db.dbDialect(w).kind == .postgres)
        try @import("idempotency.zig").pgLedgerExists(w)
    else
        try @import("idempotency.zig").sqliteLedgerExists(w);
    if (receipts_exist) {
        var receipts = try prepare(a, w, "SELECT 1 FROM \"_idempotency_receipts\" WHERE expires>?1 LIMIT 1;");
        defer receipts.finalize();
        try receipts.bindInt(1, try @import("clock.zig").sqlNowUnix(w));
        if (try receipts.step()) return error.PendingIdempotencyReceipts;
    }
    for (persistent) |ref| if (try hasReference(a, w, ref, to)) return error.Conflict;
    if (db.dbDialect(w).kind == .sqlite) {
        var pragma = try w.prepare("PRAGMA legacy_alter_table;");
        defer pragma.finalize();
        if (try pragma.step() and pragma.columnInt(0) != 0) return error.LegacyAlterTableEnabled;
    }

    try remapStorage(alloc, w, old, to);

    // Remove only the old collection's generated search objects before renaming;
    // otherwise SQLite triggers still address old FTS external-content metadata,
    // and PostgreSQL retains its old name-derived tsvector column.
    if (!fts.enabled and db.dbDialect(w).kind == .sqlite and
        try objectExists(a, w, try fts.tableName(a, old.name))) return error.SearchDisabled;
    var without_search = old;
    without_search.fields = &.{};
    try fts.ensureIndex(a, w, without_search);
    try w.exec(try std.fmt.allocPrintSentinel(a, "ALTER TABLE {s} RENAME TO {s};", .{
        try ddl.quoteIdent(a, old.name), try ddl.quoteIdent(a, to),
    }, 0));
    try @import("collection_rename_indexes.zig").renameAuthIndexes(a, w, old, to);
    const now = db.dbDialect(w).nowTextExpr();
    var st = try prepare(a, w, try std.fmt.allocPrint(a, "UPDATE \"_collections\" SET name=?1, updated={s}, rename_epoch=rename_epoch+1 WHERE id=?2;", .{now}));
    defer st.finalize();
    try st.bindText(1, to);
    try st.bindText(2, old.id);
    _ = try st.step();

    // Rotate every principal's signing key, including link-token capabilities:
    // renaming back must never resurrect a token minted under the former name.
    if (old.type == .auth) try rotatePrincipals(alloc, io, w, to);

    // Existing ID-based relations already point to the right identity. Normalize
    // legacy name-based references (including self-relations) without replacing IDs.
    const all = try collections.list(a, w);
    for (all) |col| {
        var fields: std.ArrayList(schema.Field) = .empty;
        var changed = false;
        for (col.fields) |field| {
            if (col.type == .auth and schema.isSystemFieldName(field.name)) continue;
            var updated = field;
            if (field.options == .relation and std.mem.eql(u8, field.options.relation.targetCollectionId, old.name)) {
                updated.options.relation.targetCollectionId = old.id;
                changed = true;
            }
            try fields.append(a, updated);
        }
        if (changed) {
            var update = try prepare(a, w, try std.fmt.allocPrint(a, "UPDATE \"_collections\" SET schema=?1, updated={s} WHERE id=?2;", .{now}));
            defer update.finalize();
            try update.bindText(1, try schema.fieldsToJson(a, fields.items));
            try update.bindText(2, col.id);
            _ = try update.step();
        }
    }
    for (persistent) |ref| try changeReference(a, w, ref, old.name, to);
    for (transient) |ref| {
        try changeReference(a, w, ref, old.name, null);
        try changeReference(a, w, ref, to, null);
    }
    var renamed = old;
    renamed.name = to;
    if (fts.isSearchable(old)) try fts.ensureIndex(a, w, renamed);
    try generation.bump(w);
    if (nested) try w.exec("RELEASE SAVEPOINT zb_collection_rename;") else try w.commit();
}

/// Self-freeing. PostgreSQL buffers a result before step(), so keyset batches
/// bound retained principal rows independently of the collection's cardinality.
fn rotatePrincipals(alloc: std.mem.Allocator, io: std.Io, w: *db.Db, name: []const u8) Error!void {
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const a = scratch.allocator();
    const table = try ddl.quoteIdent(a, name);
    var first = try prepare(a, w, try std.fmt.allocPrint(a, "SELECT id FROM {s} ORDER BY id LIMIT 256;", .{table}));
    defer first.finalize();
    var next = try prepare(a, w, try std.fmt.allocPrint(a, "SELECT id FROM {s} WHERE id>?1 ORDER BY id LIMIT 256;", .{table}));
    defer next.finalize();
    var rotate = try prepare(a, w, try std.fmt.allocPrint(a, "UPDATE {s} SET \"tokenKey\"=?1, token_epoch=COALESCE(token_epoch,0)+1 WHERE id=?2;", .{table}));
    defer rotate.finalize();
    var last: std.ArrayList(u8) = .empty;
    var initial = true;
    while (true) {
        const rows = if (initial) &first else &next;
        if (!initial) {
            rows.reset();
            try rows.clearBindings();
            try rows.bindText(1, last.items);
        }
        var count: usize = 0;
        while (try rows.step()) {
            var token: [32]u8 = undefined;
            @import("id.zig").generate(io, &token);
            rotate.reset();
            try rotate.clearBindings();
            try rotate.bindText(1, &token);
            try rotate.bindText(2, rows.columnText(0));
            _ = try rotate.step();
            last.clearRetainingCapacity();
            try last.appendSlice(a, rows.columnText(0));
            count += 1;
        }
        if (count < 256) break;
        if (initial) first.reset(); // Release the first buffered page before the next.
        initial = false;
    }
}

test "offline rename preserves identities and rows" {
    var d = try db.Db.openMemory();
    defer d.close();
    try @import("migrations.zig").run(&d);
    const a = std.testing.allocator;
    const old = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "posts", .fields = &.{.{ .id = "title_id", .name = "title", .options = .{ .text = .{} } }} });
    defer old.deinit(a);
    try d.exec("INSERT INTO posts(id,title) VALUES ('record1','hello');");
    try d.exec("UPDATE _collections SET updated='before' WHERE name='posts';");
    try rename(a, std.testing.io, &d, "posts", "articles");
    const renamed = (try collections.get(a, &d, "articles")).?;
    defer renamed.deinit(a);
    try std.testing.expectEqualStrings(old.id, renamed.id);
    try std.testing.expectEqualStrings("title_id", renamed.fields[0].id);
    try std.testing.expect(!std.mem.eql(u8, "before", renamed.updated));
    try std.testing.expect((try collections.get(a, &d, "posts")) == null);
    var row = try d.prepare("SELECT title FROM articles WHERE id='record1';");
    defer row.finalize();
    try std.testing.expect(try row.step());
    try std.testing.expectEqualStrings("hello", row.columnText(0));
}

test "offline rename rejects inconsistent storage metadata and collisions" {
    var d = try db.Db.openMemory();
    defer d.close();
    try @import("migrations.zig").run(&d);
    const a = std.testing.allocator;
    const old = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "posts", .fields = &.{} });
    defer old.deinit(a);
    const before = try generation.read(&d);
    try std.testing.expectError(error.InvalidRenameName, rename(a, std.testing.io, &d, "posts", "bad-name"));
    try std.testing.expectError(error.Conflict, rename(a, std.testing.io, &d, "posts", "POSTS"));
    try d.exec("CREATE TABLE articles_fts_idx(id TEXT);");
    try std.testing.expectError(error.Conflict, rename(a, std.testing.io, &d, "posts", "articles"));
    try d.exec("DROP TABLE articles_fts_idx;");
    try d.exec("CREATE TABLE _upload_sessions(id TEXT,metadata TEXT);");
    try d.exec("INSERT INTO _upload_sessions VALUES ('u1','{\"binding\":{\"collection\":\"posts\",\"collection_id\":\"other\"},\"target\":{\"collection\":\"photos\",\"collection_id\":\"photos_id\"}}');");
    try std.testing.expectError(error.InvalidPendingMetadata, rename(a, std.testing.io, &d, "posts", "articles"));
    try d.exec("DELETE FROM _upload_sessions;");
    try d.exec("INSERT INTO _upload_sessions VALUES ('u1','{\"binding\":{\"collection\":\"users\",\"collection_id\":\"users_id\"},\"target\":{\"collection\":\"posts\",\"collection_id\":\"other\"}}');");
    try std.testing.expectError(error.InvalidPendingMetadata, rename(a, std.testing.io, &d, "posts", "articles"));
    try d.exec("DELETE FROM _upload_sessions;");
    try d.exec("INSERT INTO _queue_jobs(id,queue,kind,status,payload,created) VALUES ('cleanup1','files','file_cleanup','failed','{\"collection\":\"posts\",\"collection_id\":\"other\"}','now');");
    try std.testing.expectError(error.InvalidPendingMetadata, rename(a, std.testing.io, &d, "posts", "articles"));
    try d.exec("DELETE FROM _queue_jobs;");
    try d.exec("INSERT INTO _upload_sessions VALUES ('u1','invalid');");
    try std.testing.expectError(error.InvalidPendingMetadata, rename(a, std.testing.io, &d, "posts", "articles"));
    try std.testing.expectEqual(before, try generation.read(&d));
    try std.testing.expect(!d.inTransaction());
    const unchanged = (try collections.get(a, &d, "posts")).?;
    defer unchanged.deinit(a);
    try std.testing.expectEqualStrings(old.id, unchanged.id);
    try std.testing.expect((try collections.get(a, &d, "articles")) == null);
    const files = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "photos", .fields = &.{.{ .id = "file_id", .name = "photo", .options = .{ .file = .{} } }} });
    defer files.deinit(a);
    try d.exec("DELETE FROM _upload_sessions;");
    try rename(a, std.testing.io, &d, "photos", "pictures");
    const renamed = (try collections.get(a, &d, "pictures")).?;
    defer renamed.deinit(a);
    try std.testing.expectEqualStrings("photos", renamed.storage_namespace);
}

test "offline rename requires acknowledgement and reverses through migrator" {
    var d = try db.Db.openMemory();
    defer d.close();
    try @import("migrations.zig").run(&d);
    const a = std.testing.allocator;
    const old = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "posts", .fields = &.{} });
    defer old.deinit(a);
    var m = @import("migrator.zig").Migrator{ .db = &d, .dialect = db.dbDialect(&d), .arena = a, .io = std.testing.io };
    try std.testing.expectError(error.OfflineRenameRequired, m.renameCollection("posts", "articles", .{ .offline = false }));
    try m.renameCollection("posts", "articles", .{ .offline = true });
    m.direction = .reverse;
    try m.renameCollection("posts", "articles", .{ .offline = true });
    const restored = (try collections.get(a, &d, "posts")).?;
    defer restored.deinit(a);
    try std.testing.expectEqualStrings(old.id, restored.id);
}

test "offline rename rejects irreversible source names and unexpired opaque receipts" {
    var d = try db.Db.openMemory();
    defer d.close();
    try @import("migrations.zig").run(&d);
    const a = std.testing.allocator;
    const long_name = "a" ** 56;
    const long = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = long_name, .fields = &.{} });
    defer long.deinit(a);
    try std.testing.expectError(error.InvalidRenameName, rename(a, std.testing.io, &d, long_name, "short"));
    const old = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "posts", .fields = &.{} });
    defer old.deinit(a);
    try d.exec("CREATE TABLE _idempotency_receipts(namespace TEXT,scope TEXT,payload TEXT,result TEXT,expires INTEGER);");
    try d.exec("INSERT INTO _idempotency_receipts VALUES ('app','opaque','hash','result',9223372036854775807);");
    const before = try generation.read(&d);
    try std.testing.expectError(error.PendingIdempotencyReceipts, rename(a, std.testing.io, &d, "posts", "articles"));
    try std.testing.expectEqual(before, try generation.read(&d));
    try d.exec("UPDATE _idempotency_receipts SET expires=0;");
    try rename(a, std.testing.io, &d, "posts", "articles");
}

test "SQLite rename refuses ambiguous receipt ownership before schema effects" {
    const a = std.testing.allocator;
    const cases = [_]struct { setup: [:0]const u8, inspect: [:0]const u8 }{
        .{ .setup = "ATTACH DATABASE ':memory:' AS extra; CREATE TABLE extra._idempotency_receipts(expires INTEGER); INSERT INTO extra._idempotency_receipts VALUES(9223372036854775807);", .inspect = "SELECT expires FROM extra._idempotency_receipts;" },
        .{ .setup = "CREATE VIEW _idempotency_receipts AS SELECT 9223372036854775807 AS expires;", .inspect = "SELECT expires FROM main._idempotency_receipts;" },
        .{ .setup = "CREATE TABLE _idempotency_receipts(expires INTEGER); ATTACH DATABASE ':memory:' AS extra; CREATE TABLE extra._idempotency_receipts(expires INTEGER); INSERT INTO extra._idempotency_receipts VALUES(9223372036854775807);", .inspect = "SELECT expires FROM extra._idempotency_receipts;" },
    };
    for (cases) |case| {
        var w = try db.Db.openMemory();
        defer w.close();
        try @import("migrations.zig").run(&w);
        const old = try collections.create(a, std.testing.io, &w, .{ .id = "", .name = "posts", .fields = &.{} });
        defer old.deinit(a);
        try w.exec(case.setup);
        const before = try generation.read(&w);
        try std.testing.expectError(error.InvalidReceiptLedger, rename(a, std.testing.io, &w, "posts", "articles"));
        try std.testing.expectEqual(before, try generation.read(&w));
        try std.testing.expect(!w.inTransaction());
        const retained = (try collections.getByName(a, &w, "posts")).?;
        defer retained.deinit(a);
        try std.testing.expectEqualStrings(old.id, retained.id);
        try std.testing.expectEqual(old.rename_epoch, retained.rename_epoch);
        try std.testing.expect((try collections.getByName(a, &w, "articles")) == null);
        var receipt = try w.prepare(case.inspect);
        defer receipt.finalize();
        try std.testing.expect(try receipt.step());
        try std.testing.expectEqual(std.math.maxInt(i64), receipt.columnInt(0));
    }
}

test "pg rename refuses fallback and view ledgers but respects valid receipt retention" {
    if (comptime !@import("build_options").postgres) return error.SkipZigTest;
    const url = std.testing.environ.getPosix("ZIGBASE_PG_TEST_URL") orelse return error.SkipZigTest;
    const a = std.testing.allocator;
    var w = try db.Db.openPostgres(a, std.testing.io, url);
    defer w.close();
    const token = try @import("crypto.zig").genToken(std.testing.io, a, 12);
    defer a.free(token);
    const create = try std.fmt.allocPrintSentinel(a, "CREATE SCHEMA rename_receipt_{s}; CREATE SCHEMA fallback_receipt_{s}; SET search_path TO rename_receipt_{s},fallback_receipt_{s};", .{ token, token, token, token }, 0);
    defer a.free(create);
    const drop = try std.fmt.allocPrintSentinel(a, "DROP SCHEMA rename_receipt_{s},fallback_receipt_{s} CASCADE;", .{ token, token }, 0);
    defer a.free(drop);
    const fallback = try std.fmt.allocPrintSentinel(a, "CREATE TABLE fallback_receipt_{s}._idempotency_receipts(expires BIGINT); INSERT INTO fallback_receipt_{s}._idempotency_receipts VALUES(9223372036854775807);", .{ token, token }, 0);
    defer a.free(fallback);
    try w.exec(create);
    defer w.exec(drop) catch |err| std.log.err("rename receipt test cleanup: {s}", .{@errorName(err)});
    try @import("migrations.zig").run(&w);
    const old = try collections.create(a, std.testing.io, &w, .{ .id = "", .name = "posts", .fields = &.{} });
    defer old.deinit(a);
    try w.exec(fallback);
    const before = try generation.read(&w);
    try std.testing.expectError(error.InvalidReceiptLedger, rename(a, std.testing.io, &w, "posts", "articles"));
    try w.exec("CREATE VIEW _idempotency_receipts AS SELECT 0::BIGINT AS expires;");
    try std.testing.expectError(error.InvalidReceiptLedger, rename(a, std.testing.io, &w, "posts", "articles"));
    try w.exec("DROP VIEW _idempotency_receipts; CREATE TABLE _idempotency_receipts(expires BIGINT); INSERT INTO _idempotency_receipts VALUES(9223372036854775807);");
    try std.testing.expectError(error.PendingIdempotencyReceipts, rename(a, std.testing.io, &w, "posts", "articles"));
    try std.testing.expectEqual(before, try generation.read(&w));
    const retained = (try collections.getByName(a, &w, "posts")).?;
    defer retained.deinit(a);
    try std.testing.expectEqualStrings(old.id, retained.id);
    try std.testing.expectEqual(old.rename_epoch, retained.rename_epoch);
    try std.testing.expect((try collections.getByName(a, &w, "articles")) == null);
    var receipt = try w.prepare("SELECT expires FROM _idempotency_receipts;");
    defer receipt.finalize();
    try std.testing.expect(try receipt.step());
    try std.testing.expectEqual(std.math.maxInt(i64), receipt.columnInt(0));
    receipt.reset();
    try w.exec("UPDATE _idempotency_receipts SET expires=0;");
    try rename(a, std.testing.io, &w, "posts", "articles");
    const renamed = (try collections.getByName(a, &w, "articles")).?;
    defer renamed.deinit(a);
    try std.testing.expectEqualStrings(old.id, renamed.id);
}

test "offline rename accepts source names only even when IDs are valid names" {
    var d = try db.Db.openMemory();
    defer d.close();
    try @import("migrations.zig").run(&d);
    const a = std.testing.allocator;
    const random = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "posts", .fields = &.{} });
    defer random.deinit(a);
    const created = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "comments", .fields = &.{} });
    defer created.deinit(a);
    // create owns ID generation; force a deterministic valid-identifier ID in
    // this persisted fixture rather than relying on the random first byte.
    try d.exec("UPDATE _collections SET id='c12345678901234' WHERE name='comments';");
    try d.exec("UPDATE _storage_namespaces SET collection_id='c12345678901234' WHERE namespace='comments';");
    const identifier = (try collections.get(a, &d, "comments")).?;
    defer identifier.deinit(a);
    try std.testing.expectEqualStrings("c12345678901234", identifier.id);
    const before = try generation.read(&d);
    try std.testing.expectError(if (schema.isValidIdentifier(random.id)) error.NotFound else error.InvalidRenameName, rename(a, std.testing.io, &d, random.id, "articles"));
    try std.testing.expectError(error.NotFound, rename(a, std.testing.io, &d, identifier.id, "replies"));
    try std.testing.expectEqual(before, try generation.read(&d));
    try rename(a, std.testing.io, &d, "comments", "replies");
    const renamed = (try collections.get(a, &d, "replies")).?;
    defer renamed.deinit(a);
    try std.testing.expectEqualStrings(identifier.id, renamed.id);
    const alias = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "named_alias", .fields = &.{} });
    defer alias.deinit(a);
    // Legacy/imported metadata can contain a logical name equal to another ID;
    // generic create currently refuses that alias, so persist it explicitly.
    try d.exec("ALTER TABLE named_alias RENAME TO c12345678901234;");
    try d.exec("UPDATE _collections SET name='c12345678901234' WHERE name='named_alias';");
    try rename(a, std.testing.io, &d, identifier.id, "alias_renamed");
    const actual = (try collections.getByName(a, &d, "alias_renamed")).?;
    defer actual.deinit(a);
    try std.testing.expectEqualStrings(alias.id, actual.id);
    try std.testing.expectEqualStrings(identifier.id, renamed.id);
}

test "offline rename validates missing source names before lookup" {
    var d = try db.Db.openMemory();
    defer d.close();
    try @import("migrations.zig").run(&d);
    const before = try generation.read(&d);
    for ([_][]const u8{ "", "bad-name", "a" ** 56, "missing_fts", "9bad" }) |name|
        try std.testing.expectError(error.InvalidRenameName, rename(std.testing.allocator, std.testing.io, &d, name, "destination"));
    try std.testing.expectError(error.NotFound, rename(std.testing.allocator, std.testing.io, &d, "missing", "destination"));
    try std.testing.expectEqual(before, try generation.read(&d));
}

test "offline rename rejects temporary shadows and destination FTS shadow tables" {
    const a = std.testing.allocator;
    var w = try db.Db.openMemory();
    defer w.close();
    try @import("migrations.zig").run(&w);
    const old = try collections.create(a, std.testing.io, &w, .{ .id = "", .name = "posts", .fields = &.{} });
    defer old.deinit(a);
    const before = try generation.read(&w);
    for ([_][]const u8{ "posts", "articles", "_schema_state", "_collections", "_idempotency_receipts" }) |name| {
        const quoted = try ddl.quoteIdent(a, name);
        defer a.free(quoted);
        const create = try std.fmt.allocPrintSentinel(a, "CREATE TEMP TABLE {s}(note TEXT);", .{quoted}, 0);
        defer a.free(create);
        try w.exec(create);
        try std.testing.expectError(error.Conflict, rename(a, std.testing.io, &w, "posts", "articles"));
        const drop = try std.fmt.allocPrintSentinel(a, "DROP TABLE temp.{s};", .{quoted}, 0);
        defer a.free(drop);
        try w.exec(drop);
    }
    for ([_][]const u8{ "articles_fts_data", "articles_fts_docsize", "articles_fts_config", "articles_fts_content" }) |name| {
        const quoted = try ddl.quoteIdent(a, name);
        defer a.free(quoted);
        const create = try std.fmt.allocPrintSentinel(a, "CREATE TABLE {s}(note TEXT);", .{quoted}, 0);
        defer a.free(create);
        try w.exec(create);
        try std.testing.expectError(error.Conflict, rename(a, std.testing.io, &w, "posts", "articles"));
        const drop = try std.fmt.allocPrintSentinel(a, "DROP TABLE {s};", .{quoted}, 0);
        defer a.free(drop);
        try w.exec(drop);
    }
    try std.testing.expectEqual(before, try generation.read(&w));
    const unchanged = (try collections.getByName(a, &w, "posts")).?;
    defer unchanged.deinit(a);
    try std.testing.expectEqualStrings(old.id, unchanged.id);
    try std.testing.expectEqual(@as(i64, 0), unchanged.rename_epoch);
}

test "offline rename refuses ambiguous legacy relation names instead of retargeting IDs" {
    const a = std.testing.allocator;
    var w = try db.Db.openMemory();
    defer w.close();
    try @import("migrations.zig").run(&w);
    const posts = try collections.create(a, std.testing.io, &w, .{ .id = "", .name = "posts", .fields = &.{} });
    defer posts.deinit(a);
    const other = try collections.create(a, std.testing.io, &w, .{ .id = "", .name = "other", .fields = &.{} });
    defer other.deinit(a);
    const links = try collections.create(a, std.testing.io, &w, .{ .id = "", .name = "links", .fields = &.{} });
    defer links.deinit(a);
    try w.exec("UPDATE _collections SET id='posts' WHERE name='other'; ALTER TABLE links ADD COLUMN target TEXT REFERENCES other(id);");
    try w.exec("UPDATE _storage_namespaces SET collection_id='posts' WHERE namespace='other';");
    try w.exec("UPDATE _collections SET schema='[{\"id\":\"targetid\",\"name\":\"target\",\"type\":\"relation\",\"options\":{\"targetCollectionId\":\"posts\",\"maxSelect\":1}}]' WHERE name='links';");
    const before = try generation.read(&w);
    try std.testing.expectError(error.Conflict, rename(a, std.testing.io, &w, "posts", "articles"));
    try std.testing.expectEqual(before, try generation.read(&w));
    const unchanged = (try collections.getByName(a, &w, "links")).?;
    defer unchanged.deinit(a);
    try std.testing.expectEqualStrings("posts", unchanged.fields[0].options.relation.targetCollectionId);
    var fk = try w.prepare("PRAGMA foreign_key_list(links);");
    defer fk.finalize();
    try std.testing.expect(try fk.step());
    try std.testing.expectEqualStrings("other", fk.columnText(2));
}

test "offline rename refuses dangling destination metadata before adopting relations" {
    const a = std.testing.allocator;
    var w = try db.Db.openMemory();
    defer w.close();
    try @import("migrations.zig").run(&w);
    const posts = try collections.create(a, std.testing.io, &w, .{ .id = "", .name = "posts", .fields = &.{} });
    defer posts.deinit(a);
    // A legacy self-reference may name a table that has not been created yet.
    // No physical FK exists here: the metadata check must independently refuse.
    try w.exec("UPDATE _collections SET schema='[{\"id\":\"targetid\",\"name\":\"target\",\"type\":\"relation\",\"options\":{\"targetCollectionId\":\"articles\",\"maxSelect\":1}}]' WHERE name='posts';");
    const before = try generation.read(&w);
    try std.testing.expectError(error.Conflict, rename(a, std.testing.io, &w, "posts", "articles"));
    try std.testing.expectEqual(before, try generation.read(&w));
    try std.testing.expect(!w.inTransaction());
    try std.testing.expect(!try objectExists(a, &w, "articles"));
    const unchanged = (try collections.getByName(a, &w, "posts")).?;
    defer unchanged.deinit(a);
    try std.testing.expectEqual(@as(i64, 0), unchanged.rename_epoch);
    try std.testing.expectEqualStrings("articles", unchanged.fields[0].options.relation.targetCollectionId);
}

test "offline rename refuses dangling physical FKs even without collection metadata" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "articles", "ARTICLES" }) |target| {
        var w = try db.Db.openMemory();
        defer w.close();
        try @import("migrations.zig").run(&w);
        const posts = try collections.create(a, std.testing.io, &w, .{ .id = "", .name = "posts", .fields = &.{} });
        defer posts.deinit(a);
        const sql = try std.fmt.allocPrintSentinel(a, "CREATE TABLE migration_links(parent TEXT REFERENCES \"{s}\"(id)); INSERT INTO migration_links VALUES ('r1');", .{target}, 0);
        defer a.free(sql);
        // SQLite allows a dangling FK and, with enforcement disabled, records.
        try w.exec("PRAGMA foreign_keys=OFF;");
        try w.exec(sql);
        const before = try generation.read(&w);
        try w.begin();
        try w.exec("INSERT INTO posts(id) VALUES ('r1');");
        try std.testing.expectError(error.Conflict, rename(a, std.testing.io, &w, "posts", "articles"));
        try std.testing.expect(w.inTransaction());
        try std.testing.expectEqual(before, try generation.read(&w));
        try std.testing.expect(!try objectExists(a, &w, "articles"));
        const unchanged = (try collections.getByName(a, &w, "posts")).?;
        defer unchanged.deinit(a);
        try std.testing.expectEqual(@as(i64, 0), unchanged.rename_epoch);
        var fk = try w.prepare("PRAGMA foreign_key_list(migration_links);");
        defer fk.finalize();
        try std.testing.expect(try fk.step());
        try std.testing.expectEqualStrings(target, fk.columnText(2));
        try w.commit();
        var caller = try w.prepare("SELECT id FROM posts;");
        defer caller.finalize();
        try std.testing.expect(try caller.step());
        try std.testing.expectEqualStrings("r1", caller.columnText(0));
    }
}

test "rename epoch is internal monotonic metadata with an overflow guard" {
    const a = std.testing.allocator;
    var d = try db.Db.openMemory();
    defer d.close();
    try @import("migrations.zig").run(&d);
    const created = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "posts", .fields = &.{}, .rename_epoch = 8 });
    defer created.deinit(a);
    try std.testing.expectEqual(@as(i64, 0), created.rename_epoch);
    try rename(a, std.testing.io, &d, "posts", "articles");
    const renamed = (try collections.getByName(a, &d, "articles")).?;
    defer renamed.deinit(a);
    var edited = renamed;
    edited.rename_epoch = 0;
    const updated = try collections.update(a, std.testing.io, &d, renamed.id, edited);
    defer updated.deinit(a);
    try std.testing.expectEqual(@as(i64, 1), updated.rename_epoch);
    const json = try schema.collectionToJson(a, updated);
    defer a.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "rename_epoch") == null);
    try d.exec("UPDATE _collections SET rename_epoch=9223372036854775807 WHERE name='articles';");
    const before = try generation.read(&d);
    try std.testing.expectError(error.RenameEpochExhausted, rename(a, std.testing.io, &d, "articles", "posts"));
    try std.testing.expectEqual(before, try generation.read(&d));
}

test "offline rename rolls back DDL and references inside caller transaction" {
    var d = try db.Db.openMemory();
    defer d.close();
    try @import("migrations.zig").run(&d);
    const a = std.testing.allocator;
    const old = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "posts", .fields = &.{} });
    defer old.deinit(a);
    try d.exec("INSERT INTO _sessions(id,collectionRef,recordRef,created) VALUES ('s1','posts','outer','now');");
    try d.exec("INSERT INTO _twoFactorCredentials(collectionRef,recordRef,kind,id,payload) VALUES ('posts','outer','totp','default','sealed');");
    const before = try generation.read(&d);
    try d.exec("CREATE TRIGGER deny_rename BEFORE UPDATE OF generation ON _schema_state WHEN NEW.generation<>OLD.generation BEGIN SELECT RAISE(ABORT,'injected'); END;");
    try d.begin();
    try d.exec("INSERT INTO posts(id) VALUES ('outer');");
    try std.testing.expectError(error.ExecFailed, rename(a, std.testing.io, &d, "posts", "articles"));
    try std.testing.expect(d.inTransaction());
    try std.testing.expectEqual(before, try generation.read(&d));
    const unchanged = (try collections.get(a, &d, "posts")).?;
    defer unchanged.deinit(a);
    try std.testing.expect((try collections.get(a, &d, "articles")) == null);
    try std.testing.expect(try hasReference(a, &d, .{ .table = "_sessions" }, "posts"));
    try std.testing.expect(try hasReference(a, &d, .{ .table = "_twoFactorCredentials" }, "posts"));
    try d.commit();
    var row = try d.prepare("SELECT id FROM posts;");
    defer row.finalize();
    try std.testing.expect(try row.step());
    try std.testing.expectEqualStrings("outer", row.columnText(0));
}

test "offline rename preserves self relation metadata and physical foreign keys" {
    var d = try db.Db.openMemory();
    defer d.close();
    try @import("migrations.zig").run(&d);
    const a = std.testing.allocator;
    const old = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "posts", .fields = &.{} });
    defer old.deinit(a);
    var definition = old;
    definition.fields = &.{.{ .id = "parent_id", .name = "parent", .options = .{ .relation = .{ .targetCollectionId = old.name, .maxSelect = 1 } } }};
    const updated = try collections.update(a, std.testing.io, &d, old.id, definition);
    defer updated.deinit(a);
    try d.exec("CREATE TABLE incoming(id TEXT PRIMARY KEY,parent TEXT REFERENCES posts(id));");
    try d.exec("INSERT INTO posts(id) VALUES ('root');");
    try d.exec("INSERT INTO posts(id,parent) VALUES ('child','root');");
    try d.exec("INSERT INTO incoming(id,parent) VALUES ('i1','child');");
    try rename(a, std.testing.io, &d, "posts", "articles");
    const renamed = (try collections.get(a, &d, "articles")).?;
    defer renamed.deinit(a);
    try std.testing.expectEqualStrings(old.id, renamed.fields[0].options.relation.targetCollectionId);
    var fk = try d.prepare("PRAGMA foreign_key_list(incoming);");
    defer fk.finalize();
    try std.testing.expect(try fk.step());
    try std.testing.expectEqualStrings("articles", fk.columnText(2));
    var check = try d.prepare("PRAGMA foreign_key_check;");
    defer check.finalize();
    try std.testing.expect(!try check.step());
}

test "offline rename preserves searchable data and explicit indexes" {
    if (!@import("build_options").fts5) return error.SkipZigTest;
    var d = try db.Db.openMemory();
    defer d.close();
    try @import("migrations.zig").run(&d);
    const a = std.testing.allocator;
    const old = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "posts", .fields = &.{.{ .id = "title_id", .name = "title", .searchable = true, .options = .{ .text = .{} } }} });
    defer old.deinit(a);
    try fts.ensureIndex(a, &d, old);
    try d.exec("CREATE UNIQUE INDEX stable_title ON posts(title);");
    try d.exec("INSERT INTO posts(id,title) VALUES ('r1','before');");
    try rename(a, std.testing.io, &d, "posts", "articles");
    try std.testing.expect(!try objectExists(a, &d, "posts_fts"));
    try std.testing.expect(try objectExists(a, &d, "stable_title"));
    try d.exec("UPDATE articles SET title='after' WHERE id='r1';");
    var hit = try d.prepare("SELECT COUNT(*) FROM articles_fts WHERE articles_fts MATCH 'after';");
    defer hit.finalize();
    try std.testing.expect(try hit.step());
    try std.testing.expectEqual(@as(i64, 1), hit.columnInt(0));
}

test "offline rename preserves unproven stale search objects after search was disabled" {
    if (!fts.enabled) return error.SkipZigTest;
    var d = try db.Db.openMemory();
    defer d.close();
    try @import("migrations.zig").run(&d);
    const a = std.testing.allocator;
    var fields = [_]schema.Field{.{ .id = "title_id", .name = "title", .searchable = true, .options = .{ .text = .{} } }};
    const old = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "posts", .fields = &fields });
    defer old.deinit(a);
    try fts.ensureIndex(a, &d, old);
    fields[0].searchable = false;
    var definition = old;
    definition.fields = &fields;
    const updated = try collections.update(a, std.testing.io, &d, old.id, definition);
    defer updated.deinit(a);
    const before = try generation.read(&d);
    try std.testing.expectError(error.Conflict, rename(a, std.testing.io, &d, "posts", "articles"));
    try std.testing.expectEqual(before, try generation.read(&d));
    try std.testing.expect(try objectExists(a, &d, "posts_fts"));
    try std.testing.expect(!try objectExists(a, &d, "articles_fts"));
    try d.exec("INSERT INTO posts(id,title) VALUES ('r1','after');");
}

test "offline auth rename retains enrollment and invalidates capabilities even after reverse" {
    var d = try db.Db.openMemory();
    defer d.close();
    try @import("migrations.zig").run(&d);
    const a = std.testing.allocator;
    const old = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "users", .type = .auth, .fields = &.{} });
    defer old.deinit(a);
    try d.exec("INSERT INTO users(id,email,passwordHash,tokenKey) VALUES ('u1','a@example.com','password-hash','old-key');");
    try d.exec("INSERT INTO users(id,email,tokenKey) VALUES ('u2','b@example.com','old-key-2'),('u3','c@example.com','old-key-3');");
    try d.exec("INSERT INTO _sessions(id,collectionRef,recordRef,created) VALUES ('s1','users','u1','now');");
    try d.exec("INSERT INTO _webauthnCredentials(id,collectionRef,recordRef,credentialId,publicKey,alg,signCount,created,updated) VALUES ('w1','users','u1','credential','public-key',-7,12,'now','now');");
    try d.exec("INSERT INTO _twoFactorCredentials(collectionRef,recordRef,kind,id,payload,counter) VALUES ('users','u1','totp','default','sealed-payload',123);");
    try rename(a, std.testing.io, &d, "users", "people");
    try std.testing.expect(!try hasReference(a, &d, .{ .table = "_sessions" }, "users"));
    try std.testing.expect(try hasReference(a, &d, .{ .table = "_webauthnCredentials" }, "people"));
    try std.testing.expect(try hasReference(a, &d, .{ .table = "_twoFactorCredentials" }, "people"));
    try rename(a, std.testing.io, &d, "people", "users");
    var row = try d.prepare("SELECT passwordHash,tokenKey,token_epoch FROM users WHERE id='u1';");
    defer row.finalize();
    try std.testing.expect(try row.step());
    try std.testing.expectEqualStrings("password-hash", row.columnText(0));
    try std.testing.expect(!std.mem.eql(u8, "old-key", row.columnText(1)));
    try std.testing.expectEqual(@as(i64, 2), row.columnInt(2));
    var epochs = try d.prepare("SELECT COUNT(*) FROM users WHERE token_epoch=2 AND tokenKey NOT LIKE 'old-key%';");
    defer epochs.finalize();
    try std.testing.expect(try epochs.step());
    try std.testing.expectEqual(@as(i64, 3), epochs.columnInt(0));
    var credential = try d.prepare("SELECT payload,counter FROM _twoFactorCredentials WHERE collectionRef='users';");
    defer credential.finalize();
    try std.testing.expect(try credential.step());
    try std.testing.expectEqualStrings("sealed-payload", credential.columnText(0));
    try std.testing.expectEqual(@as(i64, 123), credential.columnInt(1));
}

test "offline rename normalizes incoming name relations and survives additive provisioning" {
    var d = try db.Db.openMemory();
    defer d.close();
    try @import("migrations.zig").run(&d);
    const a = std.testing.allocator;
    const indexes = [_]schema.Index{.{ .name = "posts_title_unique", .fields = &.{"title"}, .unique = true }};
    const old = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "posts", .fields = &.{.{ .id = "title_id", .name = "title", .options = .{ .text = .{} } }}, .indexes = &indexes });
    defer old.deinit(a);
    const incoming = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "comments", .fields = &.{.{ .id = "parent_id", .name = "parent", .options = .{ .relation = .{ .targetCollectionId = "posts", .maxSelect = 1 } } }} });
    defer incoming.deinit(a);
    try d.exec("INSERT INTO posts(id,title) VALUES ('r1','hello');");
    try d.exec("INSERT INTO comments(id,parent) VALUES ('c1','r1');");
    try rename(a, std.testing.io, &d, "posts", "articles");
    const comments = (try collections.get(a, &d, "comments")).?;
    defer comments.deinit(a);
    try std.testing.expectEqualStrings("parent_id", comments.fields[0].id);
    try std.testing.expectEqualStrings(old.id, comments.fields[0].options.relation.targetCollectionId);
    try @import("provision.zig").applySpecs(a, std.testing.io, &d, &.{.{ .id = "", .name = "articles", .indexes = &indexes, .fields = &.{
        .{ .id = "new_declared_title_id", .name = "title", .options = .{ .text = .{} } },
        .{ .id = "new_field_id", .name = "subtitle", .options = .{ .text = .{} } },
    } }});
    const reloaded = (try collections.get(a, &d, "articles")).?;
    defer reloaded.deinit(a);
    try std.testing.expectEqualStrings(old.id, reloaded.id);
    try std.testing.expectEqualStrings("title_id", reloaded.fields[0].id);
    try std.testing.expectEqual(@as(usize, 2), reloaded.fields.len);
    try std.testing.expectEqualStrings("posts_title_unique", reloaded.indexes[0].name);
    try std.testing.expect(try objectExists(a, &d, "posts_title_unique"));
    try std.testing.expectError(error.ExecFailed, d.exec("INSERT INTO articles(id,title) VALUES ('r2','hello');"));
    var rows = try d.prepare("SELECT title FROM articles JOIN comments ON articles.id=comments.parent;");
    defer rows.finalize();
    try std.testing.expect(try rows.step());
    try std.testing.expectEqualStrings("hello", rows.columnText(0));
    var fk = try d.prepare("PRAGMA foreign_key_check;");
    defer fk.finalize();
    try std.testing.expect(!try fk.step());
}

fn storageBatchRegression(w: *db.Db) !void {
    const a = std.testing.allocator;
    try @import("migrations.zig").run(w);
    const docs = try collections.create(a, std.testing.io, w, .{ .id = "", .name = "docs", .fields = &.{} });
    defer docs.deinit(a);
    try w.exec("CREATE TABLE _upload_sessions(id TEXT PRIMARY KEY,metadata TEXT);");
    const owner = .{ .collection = "docs", .collection_id = docs.id };
    const payload = try std.json.Stringify.valueAlloc(a, owner, .{});
    defer a.free(payload);
    const metadata = try std.json.Stringify.valueAlloc(a, .{ .binding = owner, .target = owner }, .{});
    defer a.free(metadata);
    var upload = try prepare(a, w, "INSERT INTO _upload_sessions VALUES (?1,?2);");
    defer upload.finalize();
    if (db.dbDialect(w).kind == .sqlite) {
        var invalid = try w.prepare("INSERT INTO _upload_sessions VALUES(NULL,?1);");
        defer invalid.finalize();
        try invalid.bindText(1, metadata);
        _ = try invalid.step();
        const before_null = try generation.read(w);
        try std.testing.expectError(error.InvalidPendingMetadata, rename(a, std.testing.io, w, "docs", "documents"));
        try std.testing.expectEqual(before_null, try generation.read(w));
        try w.exec("DELETE FROM _upload_sessions WHERE id IS NULL;");
    }
    var job = try prepare(a, w, "INSERT INTO _queue_jobs(id,queue,kind,payload,created) VALUES (?1,'files','file_cleanup',?2,'now');");
    defer job.finalize();
    // More than two 64-row pages, including the empty ID before every keyset.
    for (0..129) |i| {
        var buf: [32]u8 = undefined;
        const id = if (i == 0) "" else try std.fmt.bufPrint(&buf, "{d:0>5}", .{i});
        upload.reset();
        try upload.clearBindings();
        try upload.bindText(1, id);
        try upload.bindText(2, metadata);
        _ = try upload.step();
        job.reset();
        try job.clearBindings();
        try job.bindText(1, id);
        try job.bindText(2, payload);
        _ = try job.step();
    }
    if (db.dbDialect(w).kind == .sqlite) {
        try w.exec("CREATE TRIGGER ignore_session_relink BEFORE UPDATE ON _upload_sessions WHEN old.id='00128' BEGIN SELECT RAISE(IGNORE); END;");
        try std.testing.expectError(error.InvalidPendingMetadata, rename(a, std.testing.io, w, "docs", "documents"));
        var retained = try w.prepare("SELECT count(*) FROM _upload_sessions WHERE metadata=?1;");
        defer retained.finalize();
        try retained.bindText(1, metadata);
        try std.testing.expect(try retained.step());
        try std.testing.expectEqual(@as(i64, 129), retained.columnInt(0));
        try w.exec("DROP TRIGGER ignore_session_relink;");
    }
    try w.exec("INSERT INTO _queue_jobs(id,queue,kind,payload,created) VALUES ('zzbad','files','file_cleanup','invalid','now');");
    try std.testing.expectError(error.InvalidPendingMetadata, rename(a, std.testing.io, w, "docs", "documents"));
    var unchanged = try prepare(a, w, "SELECT count(*) FROM _upload_sessions WHERE metadata=?1;");
    defer unchanged.finalize();
    try unchanged.bindText(1, metadata);
    try std.testing.expect(try unchanged.step());
    try std.testing.expectEqual(@as(i64, 129), unchanged.columnInt(0));
    unchanged.reset();
    const oversized = try a.alloc(u8, 65537);
    defer a.free(oversized);
    @memset(oversized, ' ');
    @memcpy(oversized[0..payload.len], payload);
    var bad = try prepare(a, w, "UPDATE _queue_jobs SET payload=?1 WHERE id='zzbad';");
    defer bad.finalize();
    try bad.bindText(1, oversized);
    _ = try bad.step();
    try std.testing.expectError(error.InvalidPendingMetadata, rename(a, std.testing.io, w, "docs", "documents"));
    if (db.dbDialect(w).kind == .sqlite) {
        const nul_payload = try std.mem.concat(a, u8, &.{ payload, "\x00" });
        defer a.free(nul_payload);
        bad.reset();
        try bad.clearBindings();
        try bad.bindText(1, nul_payload);
        _ = try bad.step();
        try std.testing.expectError(error.InvalidPendingMetadata, rename(a, std.testing.io, w, "docs", "documents"));
    }
    try w.exec("DELETE FROM _queue_jobs WHERE id='zzbad'; INSERT INTO _queue_jobs(id,queue,kind,payload,status,created) VALUES ('done','files','file_cleanup','invalid','done','now');");
    try rename(a, std.testing.io, w, "docs", "documents");
    var count = try w.prepare("SELECT count(*) FROM _upload_sessions WHERE metadata LIKE '%\"collection\":\"documents\"%';");
    defer count.finalize();
    try std.testing.expect(try count.step());
    try std.testing.expectEqual(@as(i64, 129), count.columnInt(0));
    var queued = try w.prepare("SELECT count(*) FROM _queue_jobs WHERE payload LIKE '%\"collection\":\"documents\"%';");
    defer queued.finalize();
    try std.testing.expect(try queued.step());
    try std.testing.expectEqual(@as(i64, 129), queued.columnInt(0));
}

test "SQLite storage remap crosses keyset pages and rolls back late failures" {
    var w = try db.Db.openMemory();
    defer w.close();
    try storageBatchRegression(&w);
}

test "pg: storage remap crosses keyset pages and rolls back late failures" {
    if (comptime !@import("build_options").postgres) return error.SkipZigTest;
    const url = std.testing.environ.getPosix("ZIGBASE_PG_TEST_URL") orelse return error.SkipZigTest;
    var w = try db.Db.openPostgres(std.testing.allocator, std.testing.io, url);
    defer w.close();
    try w.exec("CREATE SCHEMA zb_namespace_batches;");
    defer w.exec("DROP SCHEMA zb_namespace_batches CASCADE;") catch {};
    try w.exec("SET search_path TO zb_namespace_batches;");
    try storageBatchRegression(&w);
}

test "offline rename relinks durable targets auth bindings and cleanup without moving bytes" {
    const CleanupPayload = struct { collection: []const u8, collection_id: []const u8, record: []const u8, filename: ?[]const u8 = null };
    var w = try db.Db.openMemory();
    defer w.close();
    try @import("migrations.zig").run(&w);
    const a = std.testing.allocator;
    const users = try collections.create(a, std.testing.io, &w, .{ .id = "", .name = "users", .type = .auth, .fields = &.{} });
    defer users.deinit(a);
    const docs = try collections.create(a, std.testing.io, &w, .{ .id = "", .name = "docs", .fields = &.{.{ .id = "f1", .name = "file", .options = .{ .file = .{} } }} });
    defer docs.deinit(a);
    try w.exec("CREATE TABLE _upload_sessions(id TEXT PRIMARY KEY,metadata TEXT,length INTEGER,offset INTEGER,expires INTEGER,state TEXT);");
    try w.exec("CREATE TABLE _upload_payloads(session TEXT,payload BLOB);");
    const metadata = try std.json.Stringify.valueAlloc(a, .{
        .binding = .{ .collection = "users", .collection_id = users.id, .principal = "u1" },
        .target = .{ .collection = "docs", .collection_id = docs.id, .record = "r1", .field = "file", .filename = "a.txt", .mimetype = "text/plain" },
    }, .{});
    defer a.free(metadata);
    var insert = try w.prepare("INSERT INTO _upload_sessions VALUES ('upload1',?1,3,3,9999999999,'receiving');");
    defer insert.finalize();
    try insert.bindText(1, metadata);
    _ = try insert.step();
    try w.exec("INSERT INTO _upload_payloads VALUES ('upload1',X'616263');");
    try w.exec("INSERT INTO _queue_jobs(id,queue,kind,payload,status,created) VALUES ('bad','files','file_cleanup','invalid','failed','now');");
    // Upload metadata is rewritten before the queue scan; a later malformed job
    // must roll that change back along with the rest of the migration.
    try std.testing.expectError(error.InvalidPendingMetadata, rename(a, std.testing.io, &w, "users", "people"));
    var original = try w.prepare("SELECT metadata FROM _upload_sessions;");
    defer original.finalize();
    try std.testing.expect(try original.step());
    try std.testing.expectEqualStrings(metadata, original.columnText(0));
    _ = try original.step();
    try w.exec("DELETE FROM _queue_jobs WHERE id='bad';");
    const cleanup = try std.json.Stringify.valueAlloc(a, CleanupPayload{ .collection = "docs", .collection_id = docs.id, .record = "r1", .filename = "old.txt" }, .{});
    defer a.free(cleanup);
    var job = try w.prepare("INSERT INTO _queue_jobs(id,queue,kind,payload,status,created) VALUES ('cleanup','files','file_cleanup',?1,'failed','now');");
    defer job.finalize();
    try job.bindText(1, cleanup);
    _ = try job.step();
    try rename(a, std.testing.io, &w, "users", "people");
    try rename(a, std.testing.io, &w, "docs", "documents");
    var stored = try w.prepare("SELECT metadata,offset FROM _upload_sessions;");
    defer stored.finalize();
    try std.testing.expect(try stored.step());
    const parsed = try std.json.parseFromSlice(std.json.Value, a, stored.columnText(0), .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("people", parsed.value.object.get("binding").?.object.get("collection").?.string);
    try std.testing.expectEqualStrings(users.id, parsed.value.object.get("binding").?.object.get("collection_id").?.string);
    try std.testing.expectEqualStrings("documents", parsed.value.object.get("target").?.object.get("collection").?.string);
    try std.testing.expectEqualStrings(docs.id, parsed.value.object.get("target").?.object.get("collection_id").?.string);
    try std.testing.expectEqual(@as(i64, 3), stored.columnInt(1));
    var blob = try w.prepare("SELECT hex(payload) FROM _upload_payloads;");
    defer blob.finalize();
    try std.testing.expect(try blob.step());
    try std.testing.expectEqualStrings("616263", blob.columnText(0));
    var queued = try w.prepare("SELECT payload FROM _queue_jobs WHERE id='cleanup';");
    defer queued.finalize();
    try std.testing.expect(try queued.step());
    const queued_payload = try std.json.parseFromSlice(CleanupPayload, a, queued.columnText(0), .{});
    defer queued_payload.deinit();
    try std.testing.expectEqualStrings("documents", queued_payload.value.collection);
    try std.testing.expectEqualStrings(docs.id, queued_payload.value.collection_id);
    const renamed = (try collections.get(a, &w, "documents")).?;
    defer renamed.deinit(a);
    try std.testing.expectEqualStrings("docs", renamed.storage_namespace);
}
