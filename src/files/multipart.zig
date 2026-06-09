const std = @import("std");
const zap = @import("zap");
const http = @import("../http.zig");

pub const Extracted = struct { form_fields: std.json.Value, files: []const http.UploadedFile };

/// Parse a multipart/form-data request into neutral form fields + uploaded files. All borrows from `alloc`.
pub fn extract(r: zap.Request, alloc: std.mem.Allocator) !Extracted {
    try r.parseBody();
    var fields: std.json.ObjectMap = .empty;
    var files: std.ArrayList(http.UploadedFile) = .empty;

    const list = try r.parametersToOwnedList(alloc);
    for (list.items) |kv| {
        const key = kv.key;
        const v = kv.value orelse continue;
        switch (v) {
            .String => |s| try fields.put(alloc, key, .{ .string = s }),
            .Int => |n| try fields.put(alloc, key, .{ .integer = @intCast(n) }),
            .Bool => |b| try fields.put(alloc, key, .{ .bool = b }),
            .Float => |f| try fields.put(alloc, key, .{ .float = f }),
            .Hash_Binfile => |bf| if (bf.data) |d|
                try files.append(alloc, .{ .field = key, .filename = bf.filename orelse "file", .mimetype = bf.mimetype orelse "", .bytes = d }),
            .Array_Binfile => |arr| for (arr.items) |bf| if (bf.data) |d|
                try files.append(alloc, .{ .field = key, .filename = bf.filename orelse "file", .mimetype = bf.mimetype orelse "", .bytes = d }),
            .Unsupported => {},
        }
    }
    return .{ .form_fields = .{ .object = fields }, .files = try files.toOwnedSlice(alloc) };
}
