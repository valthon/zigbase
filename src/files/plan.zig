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
