//! ZigBase blog example — demonstrates the DEFAULT static-files mode.
//!
//! Comptime schema (provisioned at startup via additive auto-migration):
//!   - users  (auth collection, open signup, self-only update/delete)
//!   - posts  (title + server-derived slug + body + status + author relation
//!             + updated_at autodate + reading_time computed; public list/view
//!             only when published; author-scoped update/delete)
//!
//! Hooks on "posts":
//!   - beforeCreate: slugify + setAuthor + computeReadingTime (chained)
//!   - beforeUpdate: computeReadingTime
//!
//! Custom routes:
//!   - GET /api/blog/ping            — public health check
//!   - GET /api/blog/posts/:slug     — fetch a single published post by slug
//!
//! The Astro + React frontend in `frontend/` is served via:
//!   --serve-static frontend/dist

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

/// Stamp the author field from the authenticated identity.
fn setAuthor(ev: *zigbase.RecordEvent) anyerror!void {
    if (ev.record.* != .object) return;
    if (ev.ctx.auth) |auth| if (auth == .object) {
        if (auth.object.get("id")) |idv| if (idv == .string) {
            const uid = try ev.arena.dupe(u8, idv.string);
            try ev.record.object.put(ev.arena, "author", .{ .string = uid });
        };
    };
}

/// Compute reading_time (minutes) from body word count: ceil(words / 200), minimum 1.
fn computeReadingTime(ev: *zigbase.RecordEvent) anyerror!void {
    if (ev.record.* != .object) return;
    const body_val = ev.record.object.get("body") orelse return;
    if (body_val != .string) return;
    const body = body_val.string;
    // Count words by splitting on whitespace
    var word_count: usize = 0;
    var in_word = false;
    for (body) |c| {
        if (c == ' ' or c == '\n' or c == '\t' or c == '\r') {
            in_word = false;
        } else if (!in_word) {
            in_word = true;
            word_count += 1;
        }
    }
    const minutes = if (word_count == 0) 1 else @max(1, (word_count + 199) / 200);
    try ev.record.object.put(ev.arena, "reading_time", .{ .integer = @intCast(minutes) });
}

/// before_create chain for posts: slugify -> setAuthor -> computeReadingTime.
/// The framework accepts one handler per phase; we compose here.
fn postsBeforeCreate(ev: *zigbase.RecordEvent) anyerror!void {
    try slugify(ev);
    try setAuthor(ev);
    try computeReadingTime(ev);
}

/// GET /api/blog/ping — a public custom route returning a small JSON body.
fn ping(ev: *zigbase.RouteEvent) anyerror!zigbase.http.Response {
    _ = ev;
    return .{ .status = 200, .body = "{\"pong\":true}" };
}

/// GET /api/blog/posts/:slug — return a single published post by slug.
fn getPostBySlug(ev: *zigbase.RouteEvent) anyerror!zigbase.http.Response {
    const slug = ev.ctx.param("slug") orelse return .{ .status = 404, .body = "{\"message\":\"not found\"}" };
    var r = try ev.reader();
    defer r.deinit();
    const data = r.data();
    const result = try data.list("posts", .{
        .filter = try std.fmt.allocPrint(ev.ctx.allocator, "slug = '{s}' && status = 'published'", .{slug}),
        .perPage = 1,
    });
    if (result.items.len == 0) return .{ .status = 404, .body = "{\"message\":\"not found\"}" };
    const json = try std.json.Stringify.valueAlloc(ev.ctx.allocator, result.items[0], .{});
    return .{ .status = 200, .body = json };
}

/// An interval job: logs a heartbeat (demonstrates background scheduling).
fn heartbeat(ev: *zigbase.events.JobEvent) anyerror!void {
    std.log.info("blog heartbeat job '{s}' ran", .{ev.name});
}

pub fn main(init: std.process.Init) !void {
    return zigbase.App(.{
        .hooks = .{
            .posts = .{
                .beforeCreate = postsBeforeCreate,
                .beforeUpdate = computeReadingTime,
            },
        },
        .routes = .{
            .{ .method = .GET, .path = "/api/blog/ping", .handler = ping, .auth = .public },
            .{ .method = .GET, .path = "/api/blog/posts/:slug", .handler = getPostBySlug, .auth = .public },
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
                    .{ .name = "author", .type = .relation, .target = "users", .maxSelect = 1, .cascadeDelete = false },
                    .{ .name = "updated_at", .type = .autodate, .onCreate = true, .onUpdate = true },
                    .{ .name = "reading_time", .type = .number, .mode = .int },
                },
                // Authors can edit and delete only their own posts.
                .rules = .{
                    .list = "status = 'published'",
                    .view = "status = 'published'",
                    .create = "@request.auth.id != ''",
                    .update = "@request.auth.id = author",
                    .delete = "@request.auth.id = author",
                },
            },
        },
    }).runCli(init);
}
