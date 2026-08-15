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
//! Auth:
//!   - Built-in magic_link on users (auto_create, ttl 1 h, redirects to "/")
//!   - Set ZIGBASE_PUBLIC_URL for a clickable link (see README)
//!
//! Index:
//!   - NOCASE unique on users.email (prevents Bob@x.com / bob@x.com duplicates)
//!
//! Custom routes:
//!   - GET /api/blog/ping            — public health check
//!   - GET /api/blog/posts/:slug     — fetch a single published post by slug
//!
//! The Zigapagos frontend in `frontend/` is served via:
//!   --serve-static frontend/dist

const std = @import("std");
const zigbase = @import("zigbase");

/// before_create on "posts": derive a URL slug from the title if one isn't set.
/// NOTE: record mutations MUST allocate with `ev.arena.a` — `ev.arena` is a typed
/// `RequestArena` (so a general-purpose allocator can't be passed in by accident) and
/// `.a` is the request-scoped `std.mem.Allocator` inside it, the one that owns
/// `ev.record`. Mixing allocators on the arena-backed JSON map is undefined behavior.
/// Need the app itself? Use `ctx.app`.
fn slugify(ctx: *zigbase.Ctx, ev: *zigbase.RecordEvent) anyerror!void {
    _ = ctx;
    if (ev.record.* != .object) return; // framework already guards this; defensive
    if (ev.record.object.get("slug") != null) return;
    const title = if (ev.record.object.get("title")) |t| switch (t) {
        .string => |s| s,
        else => return,
    } else return;

    // Build a clean slug: lowercase alphanumerics, collapse every run of
    // non-alphanumerics into a single '-', and trim leading/trailing dashes.
    // "Hello, World!" -> "hello-world". Output is never longer than the title.
    const buf = try ev.arena.a.alloc(u8, title.len);
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

    try ev.record.object.put(ev.arena.a, "slug", .{ .string = buf[0..len] });
}

/// Stamp the author field from the authenticated identity.
fn setAuthor(ctx: *zigbase.Ctx, ev: *zigbase.RecordEvent) anyerror!void {
    _ = ctx;
    if (ev.record.* != .object) return;
    if (ev.rctx.auth) |auth| if (auth == .object) {
        if (auth.object.get("id")) |idv| if (idv == .string) {
            const uid = try ev.arena.a.dupe(u8, idv.string);
            try ev.record.object.put(ev.arena.a, "author", .{ .string = uid });
        };
    };
}

/// Compute reading_time (minutes) from body word count: ceil(words / 200), minimum 1.
fn computeReadingTime(ctx: *zigbase.Ctx, ev: *zigbase.RecordEvent) anyerror!void {
    _ = ctx;
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
    // int/fixed-mode number fields use a decimal STRING as their canonical wire form — that's
    // what reads return (see docs/fields.md and src/values.zig readValue), so we write one here
    // for symmetry. A raw JSON integer is also accepted on write (values.zig bindValue binds it
    // directly), so binding `minutes` straight would work too.
    const rt = try std.fmt.allocPrint(ev.arena.a, "{d}", .{minutes});
    try ev.record.object.put(ev.arena.a, "reading_time", .{ .string = rt });
}

/// before_create chain for posts: slugify -> setAuthor -> computeReadingTime.
/// The framework accepts one handler per phase; we compose here.
fn postsBeforeCreate(ctx: *zigbase.Ctx, ev: *zigbase.RecordEvent) anyerror!void {
    try slugify(ctx, ev);
    try setAuthor(ctx, ev);
    try computeReadingTime(ctx, ev);
}

/// GET /api/blog/ping — a public custom route returning a small JSON body.
/// Typed (SP2.2a): `void` input, a typed `{pong: true}` output; the thunk
/// serializes it to `{"pong":true}` (200) — identical wire body.
const PingOut = struct { pong: bool };
fn ping(req: *zigbase.Req(void)) zigbase.RouteError!PingOut {
    _ = req;
    return .{ .pong = true };
}

/// True iff `s` is a non-empty slug of only [A-Za-z0-9-]. We validate the path
/// param BEFORE interpolating it into a filter string, so a crafted slug can't
/// inject filter syntax (e.g. `' || status = 'draft`). Slugs we generate match
/// this set, so a legitimate request never trips it.
fn isSafeSlug(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-') return false;
    }
    return true;
}

/// GET /api/blog/posts/:slug — return a single published post by slug.
/// Typed (SP2.2a): `void` input, `std.json.Value` output (the post is a dynamic
/// record — `unknown` on the client). 404 when the slug is missing or no
/// published post matches; 400 on an unsafe slug. The thunk serializes the
/// returned record to a 200 JSON body (identical wire behavior).
fn getPostBySlug(req: *zigbase.Req(void)) zigbase.RouteError!std.json.Value {
    const slug = req.param("slug") orelse return req.fail(404, "not found");
    // Reject anything that isn't a clean slug before it reaches the filter.
    if (!isSafeSlug(slug)) return req.fail(400, "invalid slug");

    // Read through the per-request capability object — `req.ctx.records()` manages
    // the pooled connection itself (no manual acquireReader / Data wiring).
    const filter = std.fmt.allocPrint(req.ctx.arena.a, "slug = '{s}' && status = 'published'", .{slug}) catch return error.RouteFailed;
    const result = req.ctx.records().list("posts", .{ .filter = filter, .perPage = 1 }) catch return error.RouteFailed;
    if (result.items.len == 0) return error.NotFound;
    return result.items[0];
}

/// An interval job: logs a heartbeat (demonstrates background scheduling).
fn heartbeat(ctx: *zigbase.Ctx, ev: *zigbase.events.JobEvent) anyerror!void {
    _ = ctx;
    std.log.info("blog heartbeat job '{s}' ran", .{ev.name});
}

/// Structured logging: this routes every std.log call through the same JSON-capable
/// encoder as request logging. Access lines and --log-format/--log-level work either
/// way; omitting this line just leaves std.log output in Zig's default format, mixed
/// with JSON access lines under --log-format=json. Every ZigBase consumer needs it in
/// its own root, because `std_options` is resolved from the root source file.
pub const std_options = zigbase.std_options;

/// The application. Hoisted to a `pub const` (rather than inlined into `main`)
/// so the test block below can boot it in-process — an `App(.{...})` literal
/// inside `main` is unreachable from a test.
pub const App = zigbase.App(.{
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
    .pools = .{ .jobs = 2 },
    .cron = .{
        .{ .name = "heartbeat", .schedule = zigbase.schedule.Schedule{ .interval = .hourly }, .handler = heartbeat },
    },
    // Pagination: keep BOTH modes enabled (offset for the admin tables, cursor for the public
    // infinite-scroll feed). Use HMAC-SIGNED cursor tokens so a hand-crafted/tampered cursor is
    // rejected with a clear 400 — the MAC is keyed by the server's JWT secret, no extra config.
    // (Swap .signed for .stateless — the default, SDK-byte-compatible — or .stateful — opaque
    // ids stored server-side with a TTL — to change the token format.)
    .pagination = .{
        .offset = true,
        .cursor = true,
        .cursor_token = .signed,
    },
    // Provisioned at startup (additive auto-migration): an auth collection with
    // open signup, and public posts readable only when published.
    .collections = .{
        .users = .{
            .type = .auth,
            .fields = .{
                .{ .name = "name", .type = .text, .max = 100 },
            },
            // Public profiles + open signup: list/view/create are intentionally allow-all
            // (the explicit "@public" sentinel; an empty string is now LOCKED, not public).
            .rules = .{ .list = "@public", .view = "@public", .create = "@public", .update = "@request.auth.id = id", .delete = "@request.auth.id = id" },
            // Built-in magic-link login: POST initiate -> link emailed (or logged in dev) ->
            // GET consume sets session cookie + redirects to "/". No password required.
            // auto_create = true: a first-time visitor signing in gets an account automatically.
            // Set ZIGBASE_PUBLIC_URL=http://blog.test/ (fake; override to your host to click
            // the link) so the emailed link is a real clickable URL instead of a raw token.
            .auth = .{
                .methods = .{
                    .magic_link = .{
                        .ttl_s = 3600,
                        .auto_create = true,
                        .redirect_default = "/",
                    },
                },
            },
            // NOCASE unique index on email: prevents duplicate accounts differing only in
            // case (e.g. Bob@x.com and bob@x.com would otherwise be two separate users).
            .indexes = .{
                .{ .name = "users_email_nocase", .fields = .{"email"}, .unique = true, .collation = .nocase },
            },
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
});

pub fn main(init: std.process.Init) !void {
    return App.runCli(init);
}

// ---------------------------------------------------------------------------
// In-process tests. `zigbase.testing` boots this app against a throwaway data dir
// and injects requests through the REAL router, access rules, auth, and hooks —
// no socket, no port. Run with `zig build test`.
//
// The vitest suite under test/ is a different surface: it drives @zigbase/client
// against a spawned server over HTTP. Neither replaces the other.

test "the posts list rule hides drafts from the public" {
    var t = try zigbase.testing.start(App, .{});
    defer t.deinit();

    _ = try t.createRecord("posts", .{ .title = "Draft", .status = "draft" });
    _ = try t.createRecord("posts", .{ .title = "Live", .status = "published" });

    const r = try t.request(.GET, "/api/collections/posts/records", .{});
    try std.testing.expectEqual(@as(u16, 200), r.status);
    const page = try r.json(struct { items: []struct { title: []const u8 } });
    try std.testing.expectEqual(@as(usize, 1), page.items.len);
    try std.testing.expectEqualStrings("Live", page.items[0].title);
}

test "beforeCreate derives the slug, the author, and the reading time" {
    var t = try zigbase.testing.start(App, .{});
    defer t.deinit();

    _ = try t.createRecord("users", .{ .email = "writer@example.com", .password = "hunter2xyz" });
    const token = try t.loginPassword("users", "writer@example.com", "hunter2xyz");

    const created = try t.request(.POST, "/api/collections/posts/records", .{
        .json = .{ .title = "Hello There World", .body = "one two three four five", .status = "published" },
        .auth = token,
    });
    try std.testing.expectEqual(@as(u16, 201), created.status);
    const rec = try created.json(struct {
        slug: []const u8,
        author: []const u8,
        // computeReadingTime stamps this as a JSON STRING (e.g. "1"), not a number —
        // std.json's int parsing accepts that string-coerced-to-int form transparently.
        reading_time: i64,
    });
    try std.testing.expectEqualStrings("hello-there-world", rec.slug);
    try std.testing.expect(rec.author.len > 0); // setAuthor stamped the caller
    try std.testing.expect(rec.reading_time >= 1);
}

test "the ping route is public and the by-slug route only serves published posts" {
    var t = try zigbase.testing.start(App, .{});
    defer t.deinit();

    const ping_r = try t.request(.GET, "/api/blog/ping", .{});
    try std.testing.expectEqual(@as(u16, 200), ping_r.status);
    try std.testing.expect((try ping_r.json(struct { pong: bool })).pong);

    _ = try t.createRecord("posts", .{ .title = "Secret", .slug = "secret", .status = "draft" });
    const miss = try t.request(.GET, "/api/blog/posts/secret", .{});
    try std.testing.expectEqual(@as(u16, 404), miss.status);
}

test "creating a post requires authentication" {
    var t = try zigbase.testing.start(App, .{});
    defer t.deinit();

    const r = try t.request(.POST, "/api/collections/posts/records", .{
        .json = .{ .title = "Anonymous" },
    });
    try std.testing.expect(r.status == 401 or r.status == 403);
}
