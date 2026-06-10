const std = @import("std");
const zigbase = @import("zigbase");

/// ZigBase blog example — demonstrates the DEFAULT static-files mode.
///
/// Comptime schema (provisioned at startup via additive auto-migration):
///   - users  (auth collection, open signup, self-only update/delete)
///   - posts  (title + server-derived slug + body + status; public list/view
///             only when published; authenticated create/update/delete)
///
/// The `slugify` beforeCreate hook derives a URL slug from the post title.
/// The Astro + React frontend in `frontend/` is served via:
///   --serve-static frontend/dist
///
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

/// GET /api/blog/ping — a public custom route returning a small JSON body.
fn ping(ev: *zigbase.RouteEvent) anyerror!zigbase.http.Response {
    _ = ev;
    return .{ .status = 200, .body = "{\"pong\":true}" };
}

/// An interval job: logs a heartbeat (demonstrates background scheduling).
fn heartbeat(ev: *zigbase.events.JobEvent) anyerror!void {
    std.log.info("blog heartbeat job '{s}' ran", .{ev.name});
}

pub fn main(init: std.process.Init) !void {
    return zigbase.App(.{
        .hooks = .{ .posts = .{ .beforeCreate = slugify } },
        .routes = .{
            .{ .method = .GET, .path = "/api/blog/ping", .handler = ping, .auth = .public },
        },
        .jobs = .{ .pool_size = 2 },
        .cron = .{
            .{ .name = "heartbeat", .schedule = zigbase.schedule.Schedule{ .interval = .hourly }, .handler = heartbeat },
        },
        // Provisioned at startup (additive auto-migration): an auth collection with
        // open signup, and public posts readable only when published.
        .collections = .{
            .users = .{
                .type = .auth,
                .fields = .{
                    .{ .name = "name", .type = .text, .max = 100 },
                },
                .rules = .{ .list = "", .view = "", .create = "", .update = "@request.auth.id = id", .delete = "@request.auth.id = id" },
            },
            .posts = .{
                .fields = .{
                    .{ .name = "title", .type = .text, .required = true, .max = 200 },
                    .{ .name = "slug", .type = .text, .max = 220 },
                    .{ .name = "body", .type = .text, .max = 20000 },
                    .{ .name = "status", .type = .select, .values = .{ "draft", "published" } },
                },
                .rules = .{
                    .list = "status = \"published\"",
                    .view = "status = \"published\"",
                    .create = "@request.auth.id != \"\"",
                    .update = "@request.auth.id != \"\"",
                    .delete = "@request.auth.id != \"\"",
                },
            },
        },
    }).runCli(init);
}
