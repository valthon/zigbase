const std = @import("std");
const db = @import("db.zig");
const schema = @import("schema.zig");
const collections = @import("collections.zig");
const migrations = @import("migrations.zig");
const values = @import("values.zig");
const ddl = @import("ddl.zig");
const id_gen = @import("id.zig");
const compiler = @import("query/compiler.zig");
const lexer = @import("query/lexer.zig");
const parser = @import("query/parser.zig");
const joiner = @import("query/joiner.zig");
const sort = @import("query/sort.zig");

/// readValue / rowToObject can surface std.json parse errors (for json and multi-value
/// fields), and collections.get widens its own inferred error set. Capture those so
/// RecordError covers everything get/create can produce, the way collections.zig does.
const ReadError = @typeInfo(@typeInfo(@TypeOf(values.readValue)).@"fn".return_type.?).error_union.error_set;
const CollectionsGetError = @typeInfo(@typeInfo(@TypeOf(collections.get)).@"fn".return_type.?).error_union.error_set;

pub const RecordError = error{ Validation, NotFound, NotObject } ||
    db.DbError || values.ValueError || ReadError || CollectionsGetError;

fn columnList(alloc: std.mem.Allocator, col: schema.Collection) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "\"id\",\"created\",\"updated\"");
    for (col.fields) |f| {
        try out.append(alloc, ',');
        try out.appendSlice(alloc, try ddl.quoteIdent(alloc, f.name));
    }
    return out.toOwnedSlice(alloc);
}

fn rowToObject(alloc: std.mem.Allocator, stmt: *db.Stmt, col: schema.Collection) !std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "id", .{ .string = try alloc.dupe(u8, stmt.columnText(0)) });
    try obj.put(alloc, "created", .{ .string = try alloc.dupe(u8, stmt.columnText(1)) });
    try obj.put(alloc, "updated", .{ .string = try alloc.dupe(u8, stmt.columnText(2)) });
    for (col.fields, 0..) |f, i| {
        const v = try values.readValue(alloc, stmt, @intCast(3 + i), f);
        try obj.put(alloc, f.name, v);
    }
    return .{ .object = obj };
}

pub fn get(alloc: std.mem.Allocator, r: *db.Db, col: schema.Collection, id: []const u8) RecordError!?std.json.Value {
    const cols = try columnList(alloc, col);
    const sql = try std.fmt.allocPrintSentinel(alloc, "SELECT {s} FROM \"{s}\" WHERE \"id\" = ?1;", .{ cols, col.name }, 0);
    var st = try r.prepare(sql);
    defer st.finalize();
    try st.bindText(1, id);
    if (!try st.step()) return null;
    return try rowToObject(alloc, &st, col);
}

pub threadlocal var last_errors: ?[]const schema.ValidationError = null;

const BindItem = struct { idx: c_int, field: schema.Field, value: std.json.Value };

fn isEmpty(v: std.json.Value) bool {
    return switch (v) {
        .null => true,
        .string => |s| s.len == 0,
        .array => |arr| arr.items.len == 0,
        else => false,
    };
}

fn countValues(v: std.json.Value) usize {
    return switch (v) {
        .array => |arr| arr.items.len,
        .null => 0,
        else => 1,
    };
}

fn convCode(e: anyerror) []const u8 {
    return switch (e) {
        error.TooPrecise => "validation_too_precise",
        error.TypeMismatch => "validation_type",
        error.Overflow => "validation_overflow",
        error.BadNumber => "validation_number",
        else => "validation_value",
    };
}

/// Validate select membership/count, relation existence/count, and number string parsing.
/// Appends field errors to `errs`. `conn` is used for relation existence lookups.
fn validateFieldValue(alloc: std.mem.Allocator, conn: *db.Db, f: schema.Field, v: std.json.Value, errs: *std.ArrayList(schema.ValidationError)) !void {
    switch (f.options) {
        .number => |o| if (v == .string and o.mode != .float) {
            const scale: u8 = if (o.mode == .fixed) (o.scale orelse 0) else 0;
            _ = values.decimalToScaledInt(v.string, scale) catch |e|
                try errs.append(alloc, .{ .field = f.name, .code = convCode(e), .message = "Invalid number." });
        },
        .select => |o| {
            if (countValues(v) > o.maxSelect)
                try errs.append(alloc, .{ .field = f.name, .code = "validation_select", .message = "Too many values." });
            const items: []const std.json.Value = switch (v) {
                .array => |arr| arr.items,
                .string => &.{v},
                else => &.{},
            };
            for (items) |it| if (it == .string) {
                var ok = false;
                for (o.values) |allowed| {
                    if (std.mem.eql(u8, allowed, it.string)) {
                        ok = true;
                        break;
                    }
                }
                if (!ok) try errs.append(alloc, .{ .field = f.name, .code = "validation_select", .message = "Value not in the allowed set." });
            };
        },
        .relation => |o| {
            if (countValues(v) > o.maxSelect)
                try errs.append(alloc, .{ .field = f.name, .code = "validation_relation", .message = "Too many relations." });
            const tcol = (try collections.get(alloc, conn, o.targetCollectionId)) orelse {
                try errs.append(alloc, .{ .field = f.name, .code = "validation_relation", .message = "Relation target missing." });
                return;
            };
            const items: []const std.json.Value = switch (v) {
                .array => |arr| arr.items,
                .string => &.{v},
                else => &.{},
            };
            for (items) |it| if (it == .string) {
                const q = try std.fmt.allocPrintSentinel(alloc, "SELECT 1 FROM \"{s}\" WHERE \"id\" = ?1;", .{tcol.name}, 0);
                var st = try conn.prepare(q);
                defer st.finalize();
                try st.bindText(1, it.string);
                if (!try st.step())
                    try errs.append(alloc, .{ .field = f.name, .code = "validation_not_found", .message = "Referenced record not found." });
            };
        },
        else => {},
    }
}

pub fn create(alloc: std.mem.Allocator, io: std.Io, w: *db.Db, col: schema.Collection, data: std.json.Value) RecordError!std.json.Value {
    last_errors = null;
    if (data != .object) return error.NotObject;
    var errs: std.ArrayList(schema.ValidationError) = .empty;

    var cols: std.ArrayList(u8) = .empty;
    var vals: std.ArrayList(u8) = .empty;
    try cols.appendSlice(alloc, "\"id\",\"created\",\"updated\"");
    try vals.appendSlice(alloc, "?1,strftime('%Y-%m-%dT%H:%M:%SZ','now'),strftime('%Y-%m-%dT%H:%M:%SZ','now')");

    var binds: std.ArrayList(BindItem) = .empty;
    var next: usize = 2;
    for (col.fields) |f| {
        const provided = data.object.get(f.name);
        // autodate is server-set, so it must be handled before the required check
        // (a required autodate field correctly receives no client value).
        if (f.fieldType() == .autodate) {
            try cols.append(alloc, ',');
            try cols.appendSlice(alloc, try ddl.quoteIdent(alloc, f.name));
            try vals.append(alloc, ',');
            try vals.appendSlice(alloc, if (f.options.autodate.onCreate) "strftime('%Y-%m-%dT%H:%M:%SZ','now')" else "NULL");
            continue;
        }
        if (f.required and (provided == null or isEmpty(provided.?))) {
            try errs.append(alloc, .{ .field = f.name, .code = "validation_required", .message = "Missing required value." });
            continue;
        }
        if (provided) |pv| {
            try validateFieldValue(alloc, w, f, pv, &errs);
            try cols.append(alloc, ',');
            try cols.appendSlice(alloc, try ddl.quoteIdent(alloc, f.name));
            try vals.append(alloc, ',');
            try vals.appendSlice(alloc, try std.fmt.allocPrint(alloc, "?{d}", .{next}));
            try binds.append(alloc, .{ .idx = @intCast(next), .field = f, .value = pv });
            next += 1;
        }
    }
    if (errs.items.len > 0) {
        last_errors = errs.items;
        return error.Validation;
    }

    const rcols = try columnList(alloc, col);
    const sql = try std.fmt.allocPrintSentinel(alloc, "INSERT INTO \"{s}\" ({s}) VALUES ({s}) RETURNING {s};", .{ col.name, cols.items, vals.items, rcols }, 0);
    var st = try w.prepare(sql);
    defer st.finalize();
    var gen_id = id_gen.collectionId(io);
    try st.bindText(1, &gen_id);
    for (binds.items) |b| {
        values.bindValue(alloc, &st, b.idx, b.field, b.value) catch |e| {
            try errs.append(alloc, .{ .field = b.field.name, .code = convCode(e), .message = "Invalid value." });
            last_errors = errs.items;
            return error.Validation;
        };
    }
    if (!try st.step()) return error.NotFound;
    return try rowToObject(alloc, &st, col);
}

fn seedPosts(d: *db.Db, a: std.mem.Allocator) !schema.Collection {
    try migrations.run(d);
    const fields = [_]schema.Field{
        .{ .id = "f1", .name = "title", .options = .{ .text = .{} } },
        .{ .id = "f2", .name = "price", .options = .{ .number = .{ .mode = .fixed, .scale = 2 } } },
    };
    return collections.create(a, std.testing.io, d, .{ .id = "", .name = "posts", .fields = &fields });
}

test "get returns a record as a JSON object with typed values" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col = try seedPosts(&d, a);
    try d.exec("INSERT INTO posts (id,created,updated,title,price) VALUES ('r1','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z','hello',1050);");
    const rec = (try get(a, &d, col, "r1")).?;
    try std.testing.expectEqualStrings("r1", rec.object.get("id").?.string);
    try std.testing.expectEqualStrings("hello", rec.object.get("title").?.string);
    try std.testing.expectEqualStrings("10.50", rec.object.get("price").?.string);
    try std.testing.expect((try get(a, &d, col, "nope")) == null);
}

test "create inserts a record, sets id/timestamps, returns it" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col = try seedPosts(&d, a);
    var data: std.json.ObjectMap = .empty;
    try data.put(a, "title", .{ .string = "hi" });
    try data.put(a, "price", .{ .string = "3.25" });
    const rec = try create(a, std.testing.io, &d, col, .{ .object = data });
    try std.testing.expectEqual(@as(usize, 15), rec.object.get("id").?.string.len);
    try std.testing.expect(rec.object.get("created").?.string.len > 0);
    try std.testing.expectEqualStrings("hi", rec.object.get("title").?.string);
    try std.testing.expectEqualStrings("3.25", rec.object.get("price").?.string);
}

test "create rejects an over-precise fixed value with a field error" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col = try seedPosts(&d, a);
    var data: std.json.ObjectMap = .empty;
    try data.put(a, "price", .{ .string = "1.999" });
    try std.testing.expectError(error.Validation, create(a, std.testing.io, &d, col, .{ .object = data }));
    try std.testing.expect(last_errors != null and last_errors.?.len >= 1);
}

test "create rejects a missing required field" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try migrations.run(&d);
    const fields = [_]schema.Field{.{ .id = "f1", .name = "title", .required = true, .options = .{ .text = .{} } }};
    const col = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "posts", .fields = &fields });
    const data: std.json.ObjectMap = .empty;
    try std.testing.expectError(error.Validation, create(a, std.testing.io, &d, col, .{ .object = data }));
}

test "create rejects a value outside a select's allowed set" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try migrations.run(&d);
    const fields = [_]schema.Field{.{ .id = "f1", .name = "status", .options = .{ .select = .{ .values = &.{ "open", "closed" }, .maxSelect = 1 } } }};
    const col = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "tickets", .fields = &fields });
    var data: std.json.ObjectMap = .empty;
    try data.put(a, "status", .{ .string = "banana" });
    try std.testing.expectError(error.Validation, create(a, std.testing.io, &d, col, .{ .object = data }));
}

pub fn update(alloc: std.mem.Allocator, w: *db.Db, col: schema.Collection, id: []const u8, data: std.json.Value) RecordError!?std.json.Value {
    last_errors = null;
    if (data != .object) return error.NotObject;
    var errs: std.ArrayList(schema.ValidationError) = .empty;

    var sets: std.ArrayList(u8) = .empty;
    try sets.appendSlice(alloc, "\"updated\"=strftime('%Y-%m-%dT%H:%M:%SZ','now')");
    var binds: std.ArrayList(BindItem) = .empty;
    var next: usize = 2; // ?1 is the id in WHERE

    for (col.fields) |f| {
        if (f.fieldType() == .autodate) {
            if (f.options.autodate.onUpdate) {
                try sets.appendSlice(alloc, try std.fmt.allocPrint(alloc, ",\"{s}\"=strftime('%Y-%m-%dT%H:%M:%SZ','now')", .{f.name}));
            }
            continue;
        }
        const provided = data.object.get(f.name) orelse continue; // partial: only provided fields
        try validateFieldValue(alloc, w, f, provided, &errs);
        try sets.appendSlice(alloc, try std.fmt.allocPrint(alloc, ",\"{s}\"=?{d}", .{ f.name, next }));
        try binds.append(alloc, .{ .idx = @intCast(next), .field = f, .value = provided });
        next += 1;
    }
    if (errs.items.len > 0) { last_errors = errs.items; return error.Validation; }

    const rcols = try columnList(alloc, col);
    const sql = try std.fmt.allocPrintSentinel(alloc, "UPDATE \"{s}\" SET {s} WHERE \"id\"=?1 RETURNING {s};", .{ col.name, sets.items, rcols }, 0);
    var st = try w.prepare(sql);
    defer st.finalize();
    try st.bindText(1, id);
    for (binds.items) |b| {
        values.bindValue(alloc, &st, b.idx, b.field, b.value) catch |e| {
            try errs.append(alloc, .{ .field = b.field.name, .code = convCode(e), .message = "Invalid value." });
            last_errors = errs.items;
            return error.Validation;
        };
    }
    if (!try st.step()) return null;
    return try rowToObject(alloc, &st, col);
}

pub fn delete(alloc: std.mem.Allocator, w: *db.Db, col: schema.Collection, id: []const u8) RecordError!bool {
    const sql = try std.fmt.allocPrintSentinel(alloc, "DELETE FROM \"{s}\" WHERE \"id\"=?1 RETURNING \"id\";", .{col.name}, 0);
    var st = try w.prepare(sql);
    defer st.finalize();
    try st.bindText(1, id);
    return try st.step();
}

test "update merges provided fields, bumps updated, 404 on missing" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col = try seedPosts(&d, a);
    try d.exec("INSERT INTO posts (id,created,updated,title,price) VALUES ('r1','t','t','old',100);");

    var data: std.json.ObjectMap = .empty;
    try data.put(a, "title", .{ .string = "new" }); // price omitted -> unchanged
    const rec = (try update(a, &d, col, "r1", .{ .object = data })).?;
    try std.testing.expectEqualStrings("new", rec.object.get("title").?.string);
    try std.testing.expectEqualStrings("1.00", rec.object.get("price").?.string);

    const empty: std.json.ObjectMap = .empty;
    try std.testing.expect((try update(a, &d, col, "missing", .{ .object = empty })) == null);
}

test "delete removes the row; 404 on missing" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col = try seedPosts(&d, a);
    try d.exec("INSERT INTO posts (id,created,updated,title,price) VALUES ('r1','t','t','x',1);");
    try std.testing.expect(try delete(a, &d, col, "r1"));
    try std.testing.expect(!try delete(a, &d, col, "r1"));
}

pub const ListQuery = struct { filter: ?[]const u8 = null, sort: ?[]const u8 = null, page: u32 = 1, perPage: u32 = 30 };
pub const ListResult = struct { page: u32, perPage: u32, totalItems: i64, items: []std.json.Value };

fn baseColumnList(alloc: std.mem.Allocator, col: schema.Collection) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "\"{s}\".\"id\",\"{s}\".\"created\",\"{s}\".\"updated\"", .{ col.name, col.name, col.name }));
    for (col.fields) |f| {
        try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, ",\"{s}\".{s}", .{ col.name, try ddl.quoteIdent(alloc, f.name) }));
    }
    return out.toOwnedSlice(alloc);
}

pub fn list(alloc: std.mem.Allocator, conn: *db.Db, col: schema.Collection, q: ListQuery) !ListResult {
    var j = joiner.Joiner.init(alloc, conn, col);
    var where_sql: []const u8 = "";
    var params: []const compiler.Param = &.{};
    if (q.filter) |fstr| if (fstr.len > 0) {
        const toks = try lexer.lex(alloc, fstr);
        const ast = try parser.parse(alloc, toks);
        const compiled = try compiler.compile(alloc, &j, ast, null);
        where_sql = compiled.where_sql;
        params = compiled.params;
    };
    var order_sql: []const u8 = try std.fmt.allocPrint(alloc, "\"{s}\".\"created\" DESC", .{col.name});
    if (q.sort) |sstr| if (sstr.len > 0) {
        const ob = try sort.compile(alloc, &j, sstr);
        if (ob.len > 0) order_sql = ob;
    };
    var joins_sql: std.ArrayList(u8) = .empty;
    for (j.joins.items) |jn| { try joins_sql.append(alloc, ' '); try joins_sql.appendSlice(alloc, jn); }

    const where_clause = if (where_sql.len > 0) try std.fmt.allocPrint(alloc, " WHERE {s}", .{where_sql}) else "";

    const count_sql = try std.fmt.allocPrintSentinel(alloc, "SELECT COUNT(*) FROM \"{s}\"{s}{s};", .{ col.name, joins_sql.items, where_clause }, 0);
    var cst = try conn.prepare(count_sql);
    defer cst.finalize();
    _ = try bindParams(&cst, params, 1);
    _ = try cst.step();
    const total = cst.columnInt(0);

    const per: u32 = if (q.perPage == 0) 30 else @min(q.perPage, 500);
    const page: u32 = if (q.page == 0) 1 else q.page;
    const offset: i64 = @as(i64, (page - 1)) * @as(i64, per);
    const bcols = try baseColumnList(alloc, col);
    const page_sql = try std.fmt.allocPrintSentinel(alloc, "SELECT {s} FROM \"{s}\"{s}{s} ORDER BY {s} LIMIT ? OFFSET ?;", .{ bcols, col.name, joins_sql.items, where_clause, order_sql }, 0);
    var pst = try conn.prepare(page_sql);
    defer pst.finalize();
    const after = try bindParams(&pst, params, 1);
    try pst.bindInt(after, @intCast(per));
    try pst.bindInt(after + 1, offset);

    var items: std.ArrayList(std.json.Value) = .empty;
    while (try pst.step()) try items.append(alloc, try rowToObject(alloc, &pst, col));
    return .{ .page = page, .perPage = per, .totalItems = total, .items = try items.toOwnedSlice(alloc) };
}

fn bindParams(st: *db.Stmt, params: []const compiler.Param, start: c_int) !c_int {
    var idx = start;
    for (params) |p| {
        switch (p) {
            .text => |t| try st.bindText(idx, t),
            .int => |n| try st.bindInt(idx, n),
            .double => |dv| try st.bindDouble(idx, dv),
        }
        idx += 1;
    }
    return idx;
}

test "list filters, sorts, and paginates" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col = try seedPosts(&d, a); // posts(title text, price fixed/2)
    try d.exec("INSERT INTO posts (id,created,updated,title,price) VALUES ('r1','2026-01-01T00:00:00Z','t','aaa',100),('r2','2026-01-02T00:00:00Z','t','bbb',200),('r3','2026-01-03T00:00:00Z','t','ccc',300);");
    const res = try list(a, &d, col, .{ .filter = "price >= 2.00", .sort = "-created", .page = 1, .perPage = 1 });
    try std.testing.expectEqual(@as(i64, 2), res.totalItems);
    try std.testing.expectEqual(@as(usize, 1), res.items.len);
    try std.testing.expectEqualStrings("r3", res.items[0].object.get("id").?.string);
}
