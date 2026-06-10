const std = @import("std");
const schema = @import("../schema.zig");
const http = @import("../http.zig");
const naming = @import("naming.zig");
const mime = @import("mime.zig");

pub const PlannedWrite = struct { filename: []const u8, bytes: []const u8 };

pub const FieldPlan = struct {
    value: std.json.Value, // single: .string (""=cleared); multi: .array of strings
    writes: []const PlannedWrite,
    deletes: []const []const u8,
};

pub const PlanError = error{ TooMany, TooLarge, BadMimeType } || std.mem.Allocator.Error;

fn existingList(alloc: std.mem.Allocator, existing: ?std.json.Value) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const v = existing orelse return out.toOwnedSlice(alloc);
    switch (v) {
        .string => |s| if (s.len > 0) try out.append(alloc, s),
        .array => |arr| for (arr.items) |it| if (it == .string and it.string.len > 0) try out.append(alloc, it.string),
        else => {},
    }
    return out.toOwnedSlice(alloc);
}

fn validateAndName(io: std.Io, alloc: std.mem.Allocator, opts: anytype, u: http.UploadedFile) PlanError!PlannedWrite {
    if (opts.maxSize) |mx| if (u.bytes.len > mx) return error.TooLarge;
    if (!mime.allowed(opts.mimeTypes, mime.sniff(u.bytes))) return error.BadMimeType;
    const name = try naming.storedName(io, alloc, u.filename);
    return .{ .filename = name, .bytes = u.bytes };
}

/// Compute the new value + files to write/delete for one file `field`.
/// `existing` is the current stored value (null on create). `uploads`/`removals` are this field's
/// parts and `<field>-` values. `field_present` = was the field mentioned at all. Returns null when
/// the field is unchanged.
pub fn planFileField(
    io: std.Io,
    alloc: std.mem.Allocator,
    field: schema.Field,
    existing: ?std.json.Value,
    uploads: []const http.UploadedFile,
    removals: []const []const u8,
    field_present: bool,
) PlanError!?FieldPlan {
    const opts = field.options.file;

    if (opts.maxSelect == 1) {
        if (uploads.len > 1) return error.TooMany;
        if (uploads.len == 1) {
            const w = try validateAndName(io, alloc, opts, uploads[0]);
            const writes = try alloc.dupe(PlannedWrite, &.{w});
            const deletes = try existingList(alloc, existing);
            return .{ .value = .{ .string = w.filename }, .writes = writes, .deletes = deletes };
        }
        if (field_present) {
            const deletes = try existingList(alloc, existing);
            return .{ .value = .{ .string = "" }, .writes = &.{}, .deletes = deletes };
        }
        return null;
    }

    if (!field_present) return null;
    const existing_names = try existingList(alloc, existing);

    var deletes: std.ArrayList([]const u8) = .empty;
    var kept: std.ArrayList([]const u8) = .empty;
    for (existing_names) |name| {
        var is_removed = false;
        for (removals) |r| if (std.mem.eql(u8, r, name)) {
            is_removed = true;
            break;
        };
        if (is_removed) try deletes.append(alloc, name) else try kept.append(alloc, name);
    }

    var writes: std.ArrayList(PlannedWrite) = .empty;
    for (uploads) |u| try writes.append(alloc, try validateAndName(io, alloc, opts, u));

    if (kept.items.len + writes.items.len > opts.maxSelect) return error.TooMany;

    var arr = std.json.Array.init(alloc);
    for (kept.items) |name| try arr.append(.{ .string = name });
    for (writes.items) |w| try arr.append(.{ .string = w.filename });

    return .{
        .value = .{ .array = arr },
        .writes = try writes.toOwnedSlice(alloc),
        .deletes = try deletes.toOwnedSlice(alloc),
    };
}

pub const FieldWrite = struct { filename: []const u8, bytes: []const u8 };

pub const AllPlan = struct {
    data: std.json.Value,
    writes: []const FieldWrite,
    deletes: []const []const u8,
};

/// Append the removal names carried by one string value: a JSON-array string
/// (the admin UI / curl convention) contributes its string elements; anything
/// else is a single verbatim filename.
fn appendRemovalString(alloc: std.mem.Allocator, out: *std.ArrayList([]const u8), s: []const u8) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, s, .{}) catch {
        if (s.len > 0) try out.append(alloc, s);
        return;
    };
    if (parsed.value == .array) {
        for (parsed.value.array.items) |it| if (it == .string) try out.append(alloc, it.string);
    } else if (s.len > 0) try out.append(alloc, s);
}

fn parseRemovals(alloc: std.mem.Allocator, v: ?std.json.Value) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const val = v orelse return out.toOwnedSlice(alloc);
    switch (val) {
        .string => |s| try appendRemovalString(alloc, &out, s),
        // Repeated '<field>-' multipart keys arrive as an array of verbatim
        // JSON-text strings; each element gets the same parse-or-verbatim rule.
        .array => |arr| for (arr.items) |it| if (it == .string) try appendRemovalString(alloc, &out, it.string),
        else => {},
    }
    return out.toOwnedSlice(alloc);
}

/// Build the record data + files to write/delete from form `data` + uploaded `files`. `existing` is
/// the current record (update) or null (create). Reuses planFileField per file field; drops the
/// `<field>` raw value and the `<field>-` control key from the data.
pub fn planAllFileFields(
    io: std.Io,
    alloc: std.mem.Allocator,
    col: schema.Collection,
    data: std.json.Value,
    files: []const http.UploadedFile,
    existing: ?std.json.Value,
) PlanError!AllPlan {
    if (data != .object) return .{ .data = data, .writes = &.{}, .deletes = &.{} };

    var out: std.json.ObjectMap = .empty;
    var it = data.object.iterator();
    while (it.next()) |e| try out.put(alloc, e.key_ptr.*, e.value_ptr.*);

    var writes: std.ArrayList(FieldWrite) = .empty;
    var deletes: std.ArrayList([]const u8) = .empty;

    for (col.fields) |field| {
        if (field.options != .file) continue;
        var ups: std.ArrayList(http.UploadedFile) = .empty;
        for (files) |f| if (std.mem.eql(u8, f.field, field.name)) try ups.append(alloc, f);
        const minus_key = try std.fmt.allocPrint(alloc, "{s}-", .{field.name});
        const removals = try parseRemovals(alloc, data.object.get(minus_key));
        _ = out.swapRemove(minus_key);

        const present = ups.items.len > 0 or data.object.get(minus_key) != null or data.object.get(field.name) != null;
        const ex_val: ?std.json.Value = if (existing) |x| (if (x == .object) x.object.get(field.name) else null) else null;

        const plan = try planFileField(io, alloc, field, ex_val, ups.items, removals, present);
        if (plan) |p| {
            try out.put(alloc, field.name, p.value);
            for (p.writes) |wr| try writes.append(alloc, .{ .filename = wr.filename, .bytes = wr.bytes });
            for (p.deletes) |d| try deletes.append(alloc, d);
        } else {
            if (ups.items.len == 0 and data.object.get(field.name) != null and existing == null)
                _ = out.swapRemove(field.name);
        }
    }

    return .{
        .data = .{ .object = out },
        .writes = try writes.toOwnedSlice(alloc),
        .deletes = try deletes.toOwnedSlice(alloc),
    };
}

fn fileField(name: []const u8, max_select: u32, max_size: ?u64, mimes: ?[]const []const u8) schema.Field {
    return .{ .id = "f", .name = name, .options = .{ .file = .{ .maxSelect = max_select, .maxSize = max_size, .mimeTypes = mimes } } };
}
fn upload(field: []const u8, filename: []const u8, bytes: []const u8) http.UploadedFile {
    return .{ .field = field, .filename = filename, .mimetype = "application/octet-stream", .bytes = bytes };
}

test "create single: stores one file, value is the stored name string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = fileField("cover", 1, null, null);
    const ups = [_]http.UploadedFile{upload("cover", "pic.png", &[_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A })};
    const plan = (try planFileField(std.testing.io, a, f, null, &ups, &.{}, true)).?;
    try std.testing.expect(plan.value == .string);
    try std.testing.expect(std.mem.endsWith(u8, plan.value.string, ".png"));
    try std.testing.expectEqual(@as(usize, 1), plan.writes.len);
    try std.testing.expectEqualStrings(plan.value.string, plan.writes[0].filename);
    try std.testing.expectEqual(@as(usize, 0), plan.deletes.len);
}

test "create multi: value is an array of stored names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = fileField("docs", 3, null, null);
    const ups = [_]http.UploadedFile{ upload("docs", "a.txt", "A"), upload("docs", "b.txt", "B") };
    const plan = (try planFileField(std.testing.io, a, f, null, &ups, &.{}, true)).?;
    try std.testing.expect(plan.value == .array);
    try std.testing.expectEqual(@as(usize, 2), plan.value.array.items.len);
    try std.testing.expectEqual(@as(usize, 2), plan.writes.len);
}

test "update single: replace deletes the old file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = fileField("cover", 1, null, null);
    const existing = std.json.Value{ .string = "old_x1.png" };
    const ups = [_]http.UploadedFile{upload("cover", "new.png", &[_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A })};
    const plan = (try planFileField(std.testing.io, a, f, existing, &ups, &.{}, true)).?;
    try std.testing.expectEqual(@as(usize, 1), plan.deletes.len);
    try std.testing.expectEqualStrings("old_x1.png", plan.deletes[0]);
}

test "update single: explicit clear (present, no upload) empties + deletes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = fileField("cover", 1, null, null);
    const existing = std.json.Value{ .string = "old_x1.png" };
    const plan = (try planFileField(std.testing.io, a, f, existing, &.{}, &.{}, true)).?;
    try std.testing.expect(plan.value == .string and plan.value.string.len == 0);
    try std.testing.expectEqual(@as(usize, 1), plan.deletes.len);
}

test "update multi: add + remove = (existing - removed) ++ added" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = fileField("docs", 5, null, null);
    var ex = std.json.Array.init(a);
    try ex.append(.{ .string = "k1.txt" });
    try ex.append(.{ .string = "drop.txt" });
    try ex.append(.{ .string = "k2.txt" });
    const removals = [_][]const u8{"drop.txt"};
    const ups = [_]http.UploadedFile{upload("docs", "new.txt", "N")};
    const plan = (try planFileField(std.testing.io, a, f, .{ .array = ex }, &ups, &removals, true)).?;
    try std.testing.expectEqual(@as(usize, 3), plan.value.array.items.len);
    try std.testing.expectEqualStrings("k1.txt", plan.value.array.items[0].string);
    try std.testing.expectEqualStrings("k2.txt", plan.value.array.items[1].string);
    try std.testing.expectEqual(@as(usize, 1), plan.writes.len);
    try std.testing.expectEqual(@as(usize, 1), plan.deletes.len);
    try std.testing.expectEqualStrings("drop.txt", plan.deletes[0]);
}

test "field absent -> unchanged (null plan)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = fileField("docs", 3, null, null);
    try std.testing.expect((try planFileField(std.testing.io, a, f, null, &.{}, &.{}, false)) == null);
}

test "validation: maxSize, maxSelect, mimeTypes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const big = fileField("cover", 1, 2, null);
    try std.testing.expectError(error.TooLarge, planFileField(std.testing.io, a, big, null, &[_]http.UploadedFile{upload("cover", "x", "ABC")}, &.{}, true));
    const f2 = fileField("docs", 1, null, null);
    const ups2 = [_]http.UploadedFile{ upload("docs", "a", "A"), upload("docs", "b", "B") };
    try std.testing.expectError(error.TooMany, planFileField(std.testing.io, a, f2, null, &ups2, &.{}, true));
    const mimes = [_][]const u8{"image/png"};
    const f3 = fileField("cover", 1, null, &mimes);
    try std.testing.expectError(error.BadMimeType, planFileField(std.testing.io, a, f3, null, &[_]http.UploadedFile{upload("cover", "x.txt", "hello")}, &.{}, true));
}

fn collWithFile(name: []const u8, max_select: u32) schema.Collection {
    const S = struct {
        var fields: [1]schema.Field = undefined;
    };
    S.fields[0] = fileField(name, max_select, null, null);
    return .{ .id = "c", .name = "posts", .fields = &S.fields };
}

test "planAllFileFields create: sets file fields, collects writes, drops control keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var data: std.json.ObjectMap = .empty;
    try data.put(a, "title", .{ .string = "hi" });
    const col = collWithFile("cover", 1);
    const ups = [_]http.UploadedFile{upload("cover", "p.png", &[_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A })};
    const all = try planAllFileFields(std.testing.io, a, col, .{ .object = data }, &ups, null);
    try std.testing.expectEqualStrings("hi", all.data.object.get("title").?.string);
    try std.testing.expect(std.mem.endsWith(u8, all.data.object.get("cover").?.string, ".png"));
    try std.testing.expectEqual(@as(usize, 1), all.writes.len);
    try std.testing.expectEqual(@as(usize, 0), all.deletes.len);
}

test "planAllFileFields update multi: <field>- JSON array removes, uploads add" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col = collWithFile("docs", 5);
    var existing: std.json.ObjectMap = .empty;
    var ex = std.json.Array.init(a);
    try ex.append(.{ .string = "k1.txt" });
    try ex.append(.{ .string = "drop.txt" });
    try existing.put(a, "docs", .{ .array = ex });
    var data: std.json.ObjectMap = .empty;
    try data.put(a, "docs-", .{ .string = "[\"drop.txt\"]" });
    const ups = [_]http.UploadedFile{upload("docs", "n.txt", "N")};
    const all = try planAllFileFields(std.testing.io, a, col, .{ .object = data }, &ups, .{ .object = existing });
    const arr = all.data.object.get("docs").?.array;
    try std.testing.expectEqual(@as(usize, 2), arr.items.len);
    try std.testing.expectEqualStrings("k1.txt", arr.items[0].string);
    try std.testing.expect(all.data.object.get("docs-") == null);
    try std.testing.expectEqual(@as(usize, 1), all.deletes.len);
    try std.testing.expectEqualStrings("drop.txt", all.deletes[0]);
}

test "planAllFileFields: repeated '<field>-' removal keys (array of JSON-text strings) all apply" {
    // The multipart parser promotes repeated keys to an array of verbatim strings,
    // so `-F 'photos-=["a.jpg"]' -F 'photos-=["b.jpg"]'` arrives as
    // ["[\"a.jpg\"]", "[\"b.jpg\"]"]: each element must be JSON-parsed.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col = collWithFile("docs", 5);
    var existing: std.json.ObjectMap = .empty;
    var ex = std.json.Array.init(a);
    try ex.append(.{ .string = "a.txt" });
    try ex.append(.{ .string = "b.txt" });
    try ex.append(.{ .string = "keep.txt" });
    try existing.put(a, "docs", .{ .array = ex });
    var data: std.json.ObjectMap = .empty;
    var minus = std.json.Array.init(a);
    try minus.append(.{ .string = "[\"a.txt\"]" });
    try minus.append(.{ .string = "[\"b.txt\"]" });
    try minus.append(.{ .string = "plain.txt" }); // a non-JSON element stays verbatim
    try data.put(a, "docs-", .{ .array = minus });
    const all = try planAllFileFields(std.testing.io, a, col, .{ .object = data }, &.{}, .{ .object = existing });
    try std.testing.expectEqual(@as(usize, 2), all.deletes.len);
    try std.testing.expectEqualStrings("a.txt", all.deletes[0]);
    try std.testing.expectEqualStrings("b.txt", all.deletes[1]);
    const arr = all.data.object.get("docs").?.array;
    try std.testing.expectEqual(@as(usize, 1), arr.items.len);
    try std.testing.expectEqualStrings("keep.txt", arr.items[0].string);
}

test "planAllFileFields: non-file fields and absent file field are untouched" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col = collWithFile("cover", 1);
    var data: std.json.ObjectMap = .empty;
    try data.put(a, "title", .{ .string = "x" });
    const all = try planAllFileFields(std.testing.io, a, col, .{ .object = data }, &.{}, null);
    try std.testing.expectEqualStrings("x", all.data.object.get("title").?.string);
    try std.testing.expect(all.data.object.get("cover") == null);
    try std.testing.expectEqual(@as(usize, 0), all.writes.len);
}
