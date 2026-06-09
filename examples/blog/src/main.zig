const std = @import("std");
const zigbase = @import("zigbase");

/// before_create on "posts": derive a URL slug from the title if one isn't set.
fn slugify(ev: *zigbase.RecordEvent) anyerror!void {
    if (ev.record.* != .object) return; // framework already guards this; defensive
    if (ev.record.object.get("slug") != null) return;
    const title = if (ev.record.object.get("title")) |t| switch (t) {
        .string => |s| s,
        else => return,
    } else return;
    const buf = try ev.app.allocator.alloc(u8, title.len);
    for (title, 0..) |ch, i| buf[i] = if (std.ascii.isAlphanumeric(ch)) std.ascii.toLower(ch) else '-';
    try ev.record.object.put(ev.app.allocator, "slug", .{ .string = buf });
}

pub fn main(init: std.process.Init) !void {
    return zigbase.App(.{
        .hooks = .{ .posts = .{ .beforeCreate = slugify } },
    }).runCli(init);
}
