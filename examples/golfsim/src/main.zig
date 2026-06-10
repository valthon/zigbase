//! ZigBase "golfsim" example — a realistic consumer app ("Airbnb for golf
//! simulators") built on ZigBase *as a library*. Where examples/blog is a bare
//! packaging proof (one slug hook, a literal ping route, a log-only cron), this
//! example exercises the HARD parts of building a real backend:
//!
//!   1. A computed + validating `before_create` hook on `bookings` that reads
//!      RELATED data (the target listing), REJECTS invalid input (-> HTTP 400),
//!      stamps an owner-derived field, and COMPUTES a derived `price_total`.
//!   2. A custom business route `POST /api/bookings/:id/confirm` that reads a
//!      path param, loads the booking from the DB, flips its status, and returns
//!      the updated record as JSON (404 when the booking does not exist).
//!   3. A DB-touching interval cron job that opens a `Data` from the pool and
//!      expires stale pending holds.
//!   4. A trivial public smoke route `GET /api/golfsim/health`.
//!
//! The collections (users / simulators / listings / bookings) are provisioned at
//! COMPTIME via `.collections` in the App config — the schema is set up
//! automatically at startup (additive auto-migration). The Astro + React frontend
//! in `frontend/` is served at the root path via the comptime-hardcoded
//! `.static_files = .{ .dir = "frontend/dist" }` — no `--serve-static` flag needed
//! (and that flag is rejected as unknown in this mode).

const std = @import("std");
const zigbase = @import("zigbase");

// ---------------------------------------------------------------------------
// 1. Computed + validating before_create hook on `bookings`.
//
//    Signature: fn(*zigbase.RecordEvent) anyerror!void. Returning an error
//    REJECTS the write and surfaces as a 400 to the client. Record mutations
//    MUST allocate with `ev.arena` (the request-scoped allocator that owns
//    `ev.record`), never `ev.app.allocator`.
// ---------------------------------------------------------------------------
fn prepareBooking(ev: *zigbase.RecordEvent) anyerror!void {
    if (ev.record.* != .object) return error.InvalidBooking;
    const rec = &ev.record.object;

    // The client must reference a listing to book. (`relation` fields are stored
    // as the related record's id string.)
    const listing_id = switch (rec.get("listing") orelse return error.ListingRequired) {
        .string => |s| s,
        else => return error.ListingRequired,
    };
    if (listing_id.len == 0) return error.ListingRequired;

    // Read RELATED data through the curated facade: the listing must exist and be
    // bookable. `findById` returns null for both an unknown collection and a
    // missing record — either way the booking is invalid.
    const listing = (try ev.data.findById("listings", listing_id)) orelse return error.ListingNotFound;
    if (listing != .object) return error.ListingNotFound;

    // Only `published` listings may be booked.
    if (listing.object.get("status")) |st| switch (st) {
        .string => |s| if (!std.mem.eql(u8, s, "published")) return error.ListingNotBookable,
        else => {},
    };

    // Derive the booked duration in hours from starts_at / ends_at (RFC3339).
    const starts_at = stringField(rec, "starts_at") orelse return error.StartRequired;
    const ends_at = stringField(rec, "ends_at") orelse return error.EndRequired;
    const hours = try durationHours(starts_at, ends_at); // > 0 or error -> 400

    // COMPUTE price_total = hours * the listing's price_per_hour. Reject a
    // negative/absent rate rather than silently storing a bogus total.
    const rate = numberField(listing.object, "price_per_hour") orelse return error.ListingMissingRate;
    if (rate < 0) return error.NegativeRate;
    const price_total = hours * rate;
    try rec.put(ev.arena, "price_total", .{ .float = price_total });

    // Stamp the guest from the authenticated identity (server-authoritative;
    // never trust a client-supplied guest). `ev.ctx.auth` is the auth record.
    if (ev.ctx.auth) |auth| if (auth == .object) {
        if (auth.object.get("id")) |idv| if (idv == .string) {
            const guest = try ev.arena.dupe(u8, idv.string);
            try rec.put(ev.arena, "guest", .{ .string = guest });
        };
    };

    // New bookings always start life as a pending hold; a client cannot
    // pre-confirm. (The select field's allowed values are pending/confirmed/
    // cancelled — see docs/recipes.md.)
    try rec.put(ev.arena, "status", .{ .string = "pending" });
}

// ---------------------------------------------------------------------------
// 2. Custom business route: POST /api/bookings/:id/confirm  (auth required).
//
//    Signature: fn(*zigbase.RouteEvent) anyerror!zigbase.http.Response.
//    NOTE: RouteEvent does NOT carry a `Data` (only RecordEvent does), so a
//    route that touches the DB builds its own `Data` from the pool — the same
//    construction the cron job uses below.
//
//    NOTE: this demo route does NOT verify the caller is the listing's owner — any
//    authed user can confirm any booking, and the frontend lets the GUEST confirm
//    their own hold. For the production owner-check pattern (compare
//    @request.auth.id to listing.simulator.owner), see docs/recipes.md.
// ---------------------------------------------------------------------------
fn confirmBooking(ev: *zigbase.RouteEvent) anyerror!zigbase.http.Response {
    const not_found: zigbase.http.Response = .{ .status = 404, .body = "{\"message\":\"Booking not found.\"}" };

    const id = ev.ctx.param("id") orelse
        return .{ .status = 400, .body = "{\"message\":\"Missing booking id.\"}" };

    // Build a connection-bound Data facade on the pooled writer.
    const conn = ev.app.pool.acquireWriter();
    defer ev.app.pool.releaseWriter();
    const data = zigbase.Data{ .app = ev.app, .conn = conn, .io = ev.app.io };

    // Load the booking; 404 when it does not exist (or the collection is absent).
    const existing = (try data.findById("bookings", id)) orelse return not_found;
    if (existing != .object) return not_found;

    // Flip status -> confirmed via a partial update (only the provided field is
    // written). Build the patch in the request arena.
    var patch: std.json.ObjectMap = .empty;
    try patch.put(ev.ctx.allocator, "status", .{ .string = "confirmed" });
    const updated = (try data.update("bookings", id, .{ .object = patch })) orelse return not_found;

    // Serialize the updated record as the 200 body (arena-allocated).
    const body = try std.json.Stringify.valueAlloc(ev.ctx.allocator, updated, .{});
    return .{ .status = 200, .body = body };
}

// ---------------------------------------------------------------------------
// 3. DB-touching interval cron job: expire stale pending holds.
//
//    Signature: fn(*zigbase.events.JobEvent) anyerror!void. The job builds a
//    `Data` from the pool (acquire the writer, release on exit), lists stale
//    pending bookings via a filter, and marks them cancelled.
// ---------------------------------------------------------------------------
fn expireHolds(ev: *zigbase.events.JobEvent) anyerror!void {
    const conn = ev.app.pool.acquireWriter();
    defer ev.app.pool.releaseWriter();
    const data = zigbase.Data{ .app = ev.app, .conn = conn, .io = ev.app.io };

    // Holds that are still "pending" but whose slot already started are stale.
    // The filter language compares fields to a literal; `@now` is the current
    // server time. (No-op until the `bookings` collection exists.)
    const stale = data.list("bookings", .{
        .filter = "status = \"pending\" && starts_at < @now",
        .perPage = 200,
    }) catch |err| switch (err) {
        // Until provisioning runs there is no `bookings` collection — that's fine.
        error.UnknownCollection => return,
        else => return err,
    };

    var expired: usize = 0;
    for (stale.items) |item| {
        if (item != .object) continue;
        const id = switch (item.object.get("id") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        var patch: std.json.ObjectMap = .empty;
        defer patch.deinit(ev.app.allocator);
        try patch.put(ev.app.allocator, "status", .{ .string = "cancelled" });
        _ = data.update("bookings", id, .{ .object = patch }) catch continue;
        expired += 1;
    }
    if (expired > 0) std.log.info("expire-holds: cancelled {d} stale hold(s)", .{expired});
}

// ---------------------------------------------------------------------------
// 4. Public smoke route: GET /api/golfsim/health.
// ---------------------------------------------------------------------------
fn health(ev: *zigbase.RouteEvent) anyerror!zigbase.http.Response {
    _ = ev;
    return .{ .status = 200, .body = "{\"status\":\"ok\",\"app\":\"golfsim\"}" };
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn stringField(map: *const std.json.ObjectMap, name: []const u8) ?[]const u8 {
    return switch (map.get(name) orelse return null) {
        .string => |s| if (s.len == 0) null else s,
        else => null,
    };
}

fn numberField(map: std.json.ObjectMap, name: []const u8) ?f64 {
    return switch (map.get(name) orelse return null) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

/// Whole hours between two RFC3339 timestamps (ceil), requiring end > start.
/// Returns error.InvalidWindow when the window is empty or malformed.
fn durationHours(starts_at: []const u8, ends_at: []const u8) !f64 {
    const start = try epochSeconds(starts_at);
    const end = try epochSeconds(ends_at);
    if (end <= start) return error.InvalidWindow;
    const secs: f64 = @floatFromInt(end - start);
    return secs / 3600.0;
}

/// Parse a `YYYY-MM-DDTHH:MM:SSZ`-style RFC3339 timestamp into a unix epoch.
/// Tolerates a trailing `Z` and an optional fractional-seconds suffix; rejects
/// anything it cannot read as a clear "bad input -> 400".
fn epochSeconds(ts: []const u8) !i64 {
    if (ts.len < 19) return error.BadTimestamp;
    const year = std.fmt.parseInt(i64, ts[0..4], 10) catch return error.BadTimestamp;
    const month = std.fmt.parseInt(u8, ts[5..7], 10) catch return error.BadTimestamp;
    const day = std.fmt.parseInt(u8, ts[8..10], 10) catch return error.BadTimestamp;
    const hour = std.fmt.parseInt(i64, ts[11..13], 10) catch return error.BadTimestamp;
    const minute = std.fmt.parseInt(i64, ts[14..16], 10) catch return error.BadTimestamp;
    const second = std.fmt.parseInt(i64, ts[17..19], 10) catch return error.BadTimestamp;
    if (month < 1 or month > 12 or day < 1 or day > 31) return error.BadTimestamp;

    // Days since the Unix epoch (Howard Hinnant's days_from_civil).
    var y: i64 = year;
    if (month <= 2) y -= 1;
    const era = @divFloor(if (y >= 0) y else y - 399, 400);
    const yoe: i64 = y - era * 400;
    const mp: i64 = @mod(@as(i64, month) + 9, 12);
    const doy: i64 = @divTrunc(153 * mp + 2, 5) + @as(i64, day) - 1;
    const doe: i64 = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    const days: i64 = era * 146097 + doe - 719468;
    return days * 86400 + hour * 3600 + minute * 60 + second;
}

// ---------------------------------------------------------------------------
// App wiring
// ---------------------------------------------------------------------------
pub fn main(init: std.process.Init) !void {
    return zigbase.App(.{
        .hooks = .{ .bookings = .{ .beforeCreate = prepareBooking } },
        .routes = .{
            .{ .method = .POST, .path = "/api/bookings/:id/confirm", .handler = confirmBooking, .auth = .authed },
            .{ .method = .GET, .path = "/api/golfsim/health", .handler = health, .auth = .public },
        },
        .jobs = .{ .pool_size = 2 },
        .cron = .{
            .{
                .name = "expire-holds",
                .schedule = zigbase.schedule.Schedule{ .interval = .{ .minutes = 15 } },
                .handler = expireHolds,
            },
        },
        // Comptime-hardcoded static dir: the Astro frontend in frontend/dist is
        // served at the root path, no flag needed (and --serve-static is rejected).
        .static_files = .{ .dir = "frontend/dist" },
        // The schema the hooks/route/cron reference, provisioned at startup.
        // Mirrors the runtime-provisioning recipe in docs/recipes.md.
        .collections = .{
            .users = .{
                .type = .auth,
                .fields = .{
                    .{ .name = "name", .type = .text, .max = 100 },
                },
                .rules = .{ .list = "", .view = "", .create = "", .update = "@request.auth.id = id", .delete = "@request.auth.id = id" },
            },
            .simulators = .{
                .fields = .{
                    .{ .name = "label", .type = .text, .required = true, .max = 120 },
                    .{ .name = "owner", .type = .relation, .target = "users", .required = true, .cascadeDelete = true },
                },
                // NOTE: any authed user can create a simulator (become a host) — deliberately
                // simple for a demo; restrict with a role/claim check in a real app.
                .rules = .{ .list = "", .view = "", .create = "@request.auth.id != \"\"", .update = "@request.auth.id = owner", .delete = "@request.auth.id = owner" },
            },
            .listings = .{
                .fields = .{
                    .{ .name = "title", .type = .text, .required = true, .max = 140 },
                    .{ .name = "price_per_hour", .type = .number, .required = true },
                    .{ .name = "status", .type = .select, .required = true, .values = .{ "draft", "published", "archived" } },
                    .{ .name = "simulator", .type = .relation, .target = "simulators", .required = true, .cascadeDelete = true },
                },
                .rules = .{
                    .list = "status = \"published\"",
                    .view = "status = \"published\" || @request.auth.id = simulator.owner",
                    .create = "@request.auth.id != \"\"",
                    .update = "@request.auth.id = simulator.owner",
                    .delete = "@request.auth.id = simulator.owner",
                },
            },
            .bookings = .{
                .fields = .{
                    .{ .name = "listing", .type = .relation, .target = "listings", .required = true, .cascadeDelete = true },
                    .{ .name = "guest", .type = .relation, .target = "users", .required = true, .cascadeDelete = true },
                    .{ .name = "starts_at", .type = .date, .required = true },
                    .{ .name = "ends_at", .type = .date, .required = true },
                    .{ .name = "price_total", .type = .number },
                    .{ .name = "status", .type = .select, .values = .{ "pending", "confirmed", "cancelled" } },
                },
                .rules = .{
                    .list = "@request.auth.id = guest || @request.auth.id = listing.simulator.owner",
                    .view = "@request.auth.id = guest || @request.auth.id = listing.simulator.owner",
                    .create = "@request.auth.id != \"\"",
                    .update = "@request.auth.id = listing.simulator.owner",
                    .delete = "@request.auth.id = guest",
                },
            },
        },
    }).runCli(init);
}
