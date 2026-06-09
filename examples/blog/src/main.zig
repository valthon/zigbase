const std = @import("std");
const zigbase = @import("zigbase");

/// before_create on "posts": derive a URL slug from the title if one isn't set.
/// NOTE: record mutations MUST allocate with `ev.arena` (the request-scoped
/// allocator that owns `ev.record`), NOT `ev.app.allocator` (the long-lived gpa) —
/// mixing allocators on the arena-backed JSON map is undefined behavior.
fn slugify(ev: *zigbase.RecordEvent) anyerror!void {
    if (ev.record.* != .object) return; // framework already guards this; defensive
    if (ev.record.object.get("slug") != null) return;
    const title = if (ev.record.object.get("title")) |t| switch (t) {
        .string => |s| s,
        else => return,
    } else return;

    // Build a clean slug: lowercase alphanumerics, collapse every run of
    // non-alphanumerics into a single '-', and trim leading/trailing dashes.
    // "Hello, World!" -> "hello-world". Output is never longer than the title.
    const buf = try ev.arena.alloc(u8, title.len);
    var len: usize = 0;
    var in_run = false; // true while we're inside a run of alphanumerics
    for (title) |ch| {
        if (std.ascii.isAlphanumeric(ch)) {
            buf[len] = std.ascii.toLower(ch);
            len += 1;
            in_run = true;
        } else if (in_run) {
            // Transitioning out of an alphanumeric run: emit one separator.
            // Leading separators never appear because in_run starts false.
            buf[len] = '-';
            len += 1;
            in_run = false;
        }
    }
    // Trim a trailing '-' left by a run of non-alphanumerics at the end.
    if (len > 0 and buf[len - 1] == '-') len -= 1;

    try ev.record.object.put(ev.arena, "slug", .{ .string = buf[0..len] });
}

pub fn main(init: std.process.Init) !void {
    return zigbase.App(.{
        .hooks = .{ .posts = .{ .beforeCreate = slugify } },
    }).runCli(init);
}
