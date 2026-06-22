//! ZigBase "golfsim" example — a realistic consumer app ("Airbnb for golf
//! simulators") built on ZigBase *as a library*. Where examples/blog is a bare
//! packaging proof (one slug hook, a literal ping route, a log-only cron), this
//! example exercises the HARD parts of building a real backend:
//!
//!   1. A computed + validating `before_create` hook on `bookings` that reads
//!      RELATED data (the target listing), REJECTS invalid input (-> HTTP 400),
//!      stamps an owner-derived field, COMPUTES a derived `price_total`, and
//!      CHECKS for overlapping bookings (double-booking prevention).
//!   2. A custom business route `POST /api/bookings/:id/confirm` that reads a
//!      path param, loads the booking from the DB, verifies the caller is the
//!      listing's owner (multi-hop: booking -> listing -> simulator -> owner),
//!      flips its status, and returns the updated record as JSON (404 when the
//!      booking does not exist, 403 when the caller is not the owner).
//!   3. A custom route `POST /api/bookings/:id/cancel` that lets a guest cancel
//!      their own booking (403 when called by anyone else).
//!   4. A custom route `GET /api/listings/:id/availability` that returns all
//!      non-cancelled bookings for a listing so the frontend can render an
//!      availability calendar.
//!   5. A DB-touching interval cron job that opens a `Data` from the pool and
//!      expires stale pending holds.
//!   6. A trivial public smoke route `GET /api/golfsim/health`.
//!   7. A file-upload logger `onFileUpload` that records every upload.
//!   8. A validating `before_create` hook on `reviews` that stamps the author
//!      from the authenticated identity and enforces the review gate (you may
//!      only review your OWN booking, and only once it is `confirmed`).
//!
//!   9. `require_verified = true` on `users`: email verification is required before
//!      a session is minted — guests cannot hold booking slots with unverified accounts.
//!  10. OTP passwordless login (`auto_create = false`): a one-step login convenience
//!      for existing, verified accounts. First-time onboarding uses password signup +
//!      the `request-verification` / `confirm-verification` flow.
//!  11. Two comptime indexes: `NOCASE` unique on `users.email` (prevents case-variant
//!      duplicate accounts) and a partial composite index on `bookings(listing, starts_at)
//!      WHERE status != 'cancelled'` backing overlap/availability queries.
//!
//! The five collections (users / simulators / listings / bookings / reviews) are
//! provisioned at COMPTIME via `.collections` in the App config — the schema is
//! set up automatically at startup (additive auto-migration). The Astro + React
//! frontend in `frontend/` is served at the root path via the comptime-hardcoded
//! `.static_files = .{ .dir = "frontend/dist" }` — no `--serve-static` flag
//! needed (and that flag is rejected as unknown in this mode).

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
    // listing_id is interpolated into the overlap filter below; reject anything
    // that isn't a clean record id so it can't inject filter syntax (-> 400).
    if (!isSafeId(listing_id)) return error.InvalidListingId;

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

    // Double-booking check: reject if there is already a non-cancelled booking
    // for the same listing whose time window overlaps ours.
    //   overlap condition: existing.starts_at < our ends_at AND existing.ends_at > our starts_at
    // Allocate the filter in ev.arena (request-scoped; never ev.app.allocator here).
    const overlap_filter = try std.fmt.allocPrint(
        ev.arena,
        "listing = \"{s}\" && status != \"cancelled\" && starts_at < \"{s}\" && ends_at > \"{s}\"",
        .{ listing_id, ends_at, starts_at },
    );
    const conflicts = try ev.data.list("bookings", .{ .filter = overlap_filter, .perPage = 1 });
    // totalItems is optional (cursor mode may skip COUNT); offset mode always sets it.
    if ((conflicts.totalItems orelse 0) > 0) return error.TimeSlotConflict;

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
//    Signature (SP2.2a typed): fn(*zigbase.Req(void)) zigbase.RouteError!std.json.Value.
//    `Input` is `void` (the `:id` is a path param read via `req.param`); `Output`
//    is `std.json.Value` (the booking is a dynamic record — `unknown` on the
//    client). This route verifies the caller is the listing's owner via a
//    multi-hop traversal: booking -> listing -> simulator -> owner. Returns
//    `error.Forbidden` (403) when the caller does not own the listing,
//    `error.NotFound` (404) when the booking does not exist. The thunk serializes
//    the returned record to a 200 JSON body (identical wire behavior).
// ---------------------------------------------------------------------------
fn confirmBooking(req: *zigbase.Req(void)) zigbase.RouteError!std.json.Value {
    const id = req.param("id") orelse return req.fail(400, "Missing booking id.");
    // Validate the id before it touches any query (defense-in-depth + consistency).
    if (!isSafeId(id)) return req.fail(400, "Invalid booking id.");

    // The caller's auth id (empty string when unauthenticated — the .authed
    // constraint already rejects anonymous callers, but we guard defensively).
    const caller_id = req.auth_id;

    const app: *zigbase.Runtime = @ptrCast(@alignCast(req.app.?));

    // Build a connection-bound Data facade on the pooled writer.
    const conn = app.pool.acquireWriter();
    defer app.pool.releaseWriter();
    const data = zigbase.Data{ .app = app, .conn = conn, .io = app.io };

    // Load the booking; 404 when it does not exist (or the collection is absent).
    const existing = (data.findById("bookings", id) catch return error.RouteFailed) orelse return error.NotFound;
    if (existing != .object) return error.NotFound;

    // Multi-hop owner check: booking.listing -> listings record -> simulator ->
    // simulators record -> owner.  Any missing hop is treated as not-found rather
    // than exposing the partial state.
    const listing_id = switch (existing.object.get("listing") orelse return error.NotFound) {
        .string => |s| s,
        else => return error.NotFound,
    };
    const listing = (data.findById("listings", listing_id) catch return error.RouteFailed) orelse return error.NotFound;
    if (listing != .object) return error.NotFound;

    const simulator_id = switch (listing.object.get("simulator") orelse return error.NotFound) {
        .string => |s| s,
        else => return error.NotFound,
    };
    const simulator = (data.findById("simulators", simulator_id) catch return error.RouteFailed) orelse return error.NotFound;
    if (simulator != .object) return error.NotFound;

    const owner_id = switch (simulator.object.get("owner") orelse return error.NotFound) {
        .string => |s| s,
        else => return error.NotFound,
    };

    // 403 when the caller is not the simulator's owner.
    if (!std.mem.eql(u8, owner_id, caller_id)) return error.Forbidden;

    // Flip status -> confirmed via a partial update (only the provided field is
    // written). Build the patch in the request arena.
    var patch: std.json.ObjectMap = .empty;
    patch.put(req.arena.?, "status", .{ .string = "confirmed" }) catch return error.RouteFailed;
    const updated = (data.update("bookings", id, .{ .object = patch }) catch return error.RouteFailed) orelse return error.NotFound;

    // Return the updated record; the thunk serializes it as the 200 body.
    return updated;
}

// ---------------------------------------------------------------------------
// 3. Custom route: POST /api/bookings/:id/cancel  (auth required).
//
//    Lets a guest cancel their own booking. Returns `error.Forbidden` (403) when
//    called by anyone other than the booking's guest, `error.NotFound` (404) when
//    the booking does not exist. Acquires the pooled writer directly (this path
//    performs a write/update). Typed signature mirrors `confirmBooking`.
// ---------------------------------------------------------------------------
fn cancelBooking(req: *zigbase.Req(void)) zigbase.RouteError!std.json.Value {
    const id = req.param("id") orelse return req.fail(400, "Missing booking id.");
    if (!isSafeId(id)) return req.fail(400, "Invalid booking id.");

    const caller_id = req.auth_id;

    const app: *zigbase.Runtime = @ptrCast(@alignCast(req.app.?));

    const conn = app.pool.acquireWriter();
    defer app.pool.releaseWriter();
    const data = zigbase.Data{ .app = app, .conn = conn, .io = app.io };

    // Load the booking to verify ownership before mutating.
    const existing = (data.findById("bookings", id) catch return error.RouteFailed) orelse return error.NotFound;
    if (existing != .object) return error.NotFound;

    // Verify the caller is the booking's guest.
    const guest_id = switch (existing.object.get("guest") orelse return error.Forbidden) {
        .string => |s| s,
        else => return error.Forbidden,
    };
    if (!std.mem.eql(u8, guest_id, caller_id)) return error.Forbidden;

    // Update status -> "cancelled".
    var patch: std.json.ObjectMap = .empty;
    patch.put(req.arena.?, "status", .{ .string = "cancelled" }) catch return error.RouteFailed;
    const updated = (data.update("bookings", id, .{ .object = patch }) catch return error.RouteFailed) orelse return error.NotFound;

    // Return the updated record; the thunk serializes it as the 200 body.
    return updated;
}

// ---------------------------------------------------------------------------
// 4. Custom route: GET /api/listings/:id/availability  (auth required).
//
//    Returns all non-cancelled bookings for the listing so the frontend can
//    render an availability calendar. Acquires a pooled READER directly (this is
//    a read-only path). Output is `std.json.Value` so the exact `{"items":[...]}`
//    body is preserved byte-for-byte (including an empty `{"items":[]}`).
// ---------------------------------------------------------------------------
fn listingAvailability(req: *zigbase.Req(void)) zigbase.RouteError!std.json.Value {
    const id = req.param("id") orelse return req.fail(400, "Missing listing id.");
    // The id is interpolated into the filter below — validate it first so a
    // crafted id cannot inject filter syntax.
    if (!isSafeId(id)) return req.fail(400, "Invalid listing id.");

    const app: *zigbase.Runtime = @ptrCast(@alignCast(req.app.?));

    // Acquire a pooled, read-only connection and build a reader-bound Data facade.
    // `acquireReader` returns the connection by value; keep it in a local so its
    // address is stable for `releaseReader(&conn)` and the Data facade.
    var conn = app.pool.acquireReader() catch return error.RouteFailed;
    defer app.pool.releaseReader(&conn);
    const data = zigbase.Data{ .app = app, .conn = &conn, .io = app.io };

    const filter = std.fmt.allocPrint(
        req.arena.?,
        "listing = \"{s}\" && status != \"cancelled\"",
        .{id},
    ) catch return error.RouteFailed;
    const result = data.list("bookings", .{ .filter = filter, .perPage = 200 }) catch return error.RouteFailed;

    // Build the `{"items":[...]}` wrapper as a JSON Value; the thunk serializes it
    // to the 200 body (identical wire shape, including an empty array).
    var arr = std.json.Array.init(req.arena.?);
    for (result.items) |item| arr.append(item) catch return error.RouteFailed;
    var obj: std.json.ObjectMap = .empty;
    obj.put(req.arena.?, "items", .{ .array = arr }) catch return error.RouteFailed;
    return .{ .object = obj };
}

// ---------------------------------------------------------------------------
// 5. DB-touching interval cron job: expire stale pending holds.
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
// 6. Public smoke route: GET /api/golfsim/health.
//
//    A typed struct output (the client gets a typed health shape). The thunk
//    serializes it to `{"status":"ok","app":"golfsim"}` (200) — identical body.
// ---------------------------------------------------------------------------
const HealthOut = struct { status: []const u8, app: []const u8 };
fn health(req: *zigbase.Req(void)) zigbase.RouteError!HealthOut {
    _ = req;
    return .{ .status = "ok", .app = "golfsim" };
}

// ---------------------------------------------------------------------------
// 6b. Untyped route: GET /api/golfsim/calendar.ics
//
//    An UNTYPED handler — `fn(*RouteEvent) anyerror!http.Response` — owns the
//    whole response, so it can return a non-JSON `content-type` that a typed
//    `Req(_)`/`Output` route (always 200/204 JSON) cannot express. Untyped
//    routes are deliberately left out of the generated `zb.rpc.*` client, so
//    fetch this URL directly (e.g. subscribe to it from a calendar app). The
//    body is a static literal, so it safely outlives the handler.
// ---------------------------------------------------------------------------
fn calendarFeed(ev: *zigbase.RouteEvent) anyerror!zigbase.http.Response {
    _ = ev;
    const ics =
        \\BEGIN:VCALENDAR
        \\VERSION:2.0
        \\PRODID:-//ZigBase//golfsim//EN
        \\BEGIN:VEVENT
        \\UID:demo-tee-time@golfsim
        \\SUMMARY:Tee time at the ZigBase Golf Sim
        \\DTSTART:20260615T140000Z
        \\DTEND:20260615T150000Z
        \\END:VEVENT
        \\END:VCALENDAR
        \\
    ;
    return .{ .status = 200, .content_type = "text/calendar; charset=utf-8", .body = ics };
}

// ---------------------------------------------------------------------------
// 7. File-upload event logger.
//
//    Fires after every successful file upload. Signature: fn(*FileEvent) void
//    (no error return — errors are swallowed by the framework backstop).
// ---------------------------------------------------------------------------
fn logFileUpload(ev: *zigbase.events.FileEvent) void {
    std.log.info("file-upload: collection={s} record={s} file={s}", .{ ev.collection, ev.record_id, ev.filename });
}

// ---------------------------------------------------------------------------
// 8. Validating before_create hook on `reviews`.
//
//    Signature: fn(*zigbase.RecordEvent) anyerror!void. Like `prepareBooking`,
//    record mutations MUST allocate with `ev.arena`. This hook (a) stamps the
//    review's `author` from the authenticated identity (server-authoritative —
//    a client cannot review *as* someone else), and (b) enforces the review
//    gate: you may only review a booking that EXISTS, was made by YOU (you were
//    the guest), and is already `confirmed` (you can't review a pending hold or
//    a session that never happened). Any violation returns an error -> HTTP 400.
// ---------------------------------------------------------------------------
fn prepareReview(ev: *zigbase.RecordEvent) anyerror!void {
    if (ev.record.* != .object) return error.InvalidReview;
    const rec = &ev.record.object;

    // The review must reference the booking it is about.
    const booking_id = switch (rec.get("booking") orelse return error.BookingRequired) {
        .string => |s| s,
        else => return error.BookingRequired,
    };
    if (booking_id.len == 0) return error.BookingRequired;

    // Resolve the authenticated identity (server-authoritative author).
    var author_id: ?[]const u8 = null;
    if (ev.ctx.auth) |auth| if (auth == .object) {
        if (auth.object.get("id")) |idv| if (idv == .string) {
            author_id = idv.string;
        };
    };
    const author = author_id orelse return error.Unauthenticated;

    // The referenced booking must exist (null = unknown collection or missing).
    const booking = (try ev.data.findById("bookings", booking_id)) orelse return error.BookingNotFound;
    if (booking != .object) return error.BookingNotFound;

    // Gate 1: the booking must belong to THIS author (they were the guest).
    const guest = stringField(&booking.object, "guest") orelse return error.BookingNotYours;
    if (!std.mem.eql(u8, guest, author)) return error.BookingNotYours;

    // Gate 2: only a CONFIRMED booking (a completed session) may be reviewed.
    const status = stringField(&booking.object, "status") orelse return error.BookingNotConfirmed;
    if (!std.mem.eql(u8, status, "confirmed")) return error.BookingNotConfirmed;

    // Stamp the author from the identity (overwriting any client-supplied value).
    const author_dup = try ev.arena.dupe(u8, author);
    try rec.put(ev.arena, "author", .{ .string = author_dup });
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// True iff `s` is a non-empty record id of only [A-Za-z0-9]. ZigBase record ids
/// are alphanumeric, so validating BEFORE interpolating an id into a filter
/// string (or even a parameterized lookup) closes the filter-injection footgun:
/// a crafted id like `x" || status != "cancelled` can never reach the filter.
/// Routes reject a bad id with 400; hooks reject the write with an error (-> 400).
fn isSafeId(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (!std.ascii.isAlphanumeric(c)) return false;
    }
    return true;
}

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
pub const App = zigbase.App(.{
        .hooks = .{
            .bookings = .{ .beforeCreate = prepareBooking },
            .reviews = .{ .beforeCreate = prepareReview },
        },
        .routes = .{
            .{ .method = .POST, .path = "/api/bookings/:id/confirm", .handler = confirmBooking, .auth = .authed },
            .{ .method = .POST, .path = "/api/bookings/:id/cancel", .handler = cancelBooking, .auth = .authed },
            .{ .method = .GET, .path = "/api/listings/:id/availability", .handler = listingAvailability, .auth = .authed },
            .{ .method = .GET, .path = "/api/golfsim/health", .handler = health, .auth = .public },
            // Untyped raw-response route (text/calendar) — see `calendarFeed`. Not in `zb.rpc.*`.
            .{ .method = .GET, .path = "/api/golfsim/calendar.ics", .handler = calendarFeed, .auth = .public },
        },
        .jobs = .{ .pool_size = 2 },
        .cron = .{
            .{
                .name = "expire-holds",
                .schedule = zigbase.schedule.Schedule{ .interval = .{ .minutes = 15 } },
                .handler = expireHolds,
            },
        },
        // Fires after every successful file upload (e.g. a listing photo).
        .onFileUpload = logFileUpload,
        // Pagination: both modes on with the default STATELESS cursor tokens (no secret, CDN-
        // friendly, byte-compatible with the SDK's client-synthesized cursors). To force every
        // list to use keyset paging, set `.offset = false` (then `page`/`perPage` are rejected
        // with a 400 and clients must walk via `cursor`).
        .pagination = .{
            .offset = true,
            .cursor = true,
            .cursor_token = .stateless,
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
                // require_verified: guests must verify their email before a session is minted.
                // Justified for a booking/payments app — unverified accounts cannot hold slots.
                // OTP offers a one-step passwordless login convenience for existing, verified accounts.
                // First-time onboarding: password signup + email verification (see Auth.tsx).
                // NOTE: .password = .{} must be explicit — specifying .methods at all opts OUT of the
                // implicit password default. Omitting it would disable /auth-with-password entirely.
                .auth = .{
                    .require_verified = true,
                    .methods = .{
                        .password = .{}, // keep password login (required for post-verify signin)
                        .otp = .{ .auto_create = false }, // OTP for existing, verified accounts only
                    },
                    // OAuth2: "Sign in with Google" — client credentials are sourced from env
                    // at provision time (ZIGBASE_OAUTH_GOOGLE_CLIENT_ID / _SECRET).
                    // Google-verified accounts are created with verified=true so they can
                    // book immediately without a separate email-verification step.
                    // See README.md "Auth & onboarding > OAuth2" for setup instructions.
                    .oauth2 = .{
                        .enabled = true,
                        .providers = .{
                            .{
                                .name = "google",
                                // clientId/clientSecret left empty here; the framework
                                // injects ZIGBASE_OAUTH_GOOGLE_CLIENT_ID/SECRET at provision.
                                .redirectUrls = .{"http://localhost:8090/api/oauth2/google/callback"},
                                .enabled = true,
                            },
                        },
                    },
                },
                // Public profiles + open signup: "@public" is the explicit allow-all sentinel
                // (empty "" is now LOCKED, not public).
                .rules = .{ .list = "@public", .view = "@public", .create = "@public", .update = "@request.auth.id = id", .delete = "@request.auth.id = id" },
                // NOCASE unique index on email: prevents Bob@x.com and bob@x.com from being
                // treated as distinct accounts (doubly important with require_verified since
                // a collision would block both from verifying).
                .indexes = .{
                    .{ .name = "idx_users_email_nocase", .fields = .{"email"}, .unique = true, .collation = .nocase },
                },
            },
            .simulators = .{
                .fields = .{
                    .{ .name = "label", .type = .text, .required = true, .max = 120 },
                    .{ .name = "owner", .type = .relation, .target = "users", .required = true, .cascadeDelete = true },
                },
                // NOTE: any authed user can create a simulator (become a host) — deliberately
                // simple for a demo; restrict with a role/claim check in a real app.
                // Anyone may browse the directory of simulators ("@public" list/view);
                // create/update/delete stay owner-scoped.
                .rules = .{ .list = "@public", .view = "@public", .create = "@request.auth.id != \"\"", .update = "@request.auth.id = owner", .delete = "@request.auth.id = owner" },
            },
            .listings = .{
                .fields = .{
                    .{ .name = "title", .type = .text, .required = true, .max = 140 },
                    .{ .name = "price_per_hour", .type = .number, .required = true },
                    .{ .name = "status", .type = .select, .required = true, .values = .{ "draft", "published", "archived" } },
                    .{ .name = "simulator", .type = .relation, .target = "simulators", .required = true, .cascadeDelete = true },
                    // Up to six listing photos; uploaded via multipart on record create/update
                    // and served from GET /api/files/listings/:id/:name.
                    .{ .name = "photos", .type = .file, .maxSelect = 6, .maxSize = 5242880, .mimeTypes = .{ "image/png", "image/jpeg", "image/webp" } },
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
                // Partial composite index backing the overlap check (prepareBooking) and
                // availability route (listingAvailability). Only active (non-cancelled)
                // bookings are indexed: shrinks the index and makes availability queries
                // O(active bookings per listing) rather than O(all bookings per listing).
                .indexes = .{
                    .{
                        .name = "idx_bookings_listing_time_active",
                        .fields = .{ "listing", "starts_at" },
                        .where = "status != 'cancelled'",
                    },
                },
            },
            // The FIFTH comptime collection. Provisioning five collections / ~19 fields
            // exceeds Zig's *default* comptime branch quota inside the framework's
            // `.collections` lowering; ZigBase raises its own quota (see
            // provision.buildCollections), so a rich schema like this lowers cleanly.
            .reviews = .{
                .fields = .{
                    .{ .name = "booking", .type = .relation, .target = "bookings", .required = true, .cascadeDelete = true },
                    .{ .name = "author", .type = .relation, .target = "users", .required = true, .cascadeDelete = true },
                    .{ .name = "rating", .type = .number, .mode = .int, .min = 1, .max = 5 },
                    .{ .name = "body", .type = .text, .max = 2000 },
                },
                // Reviews are public to read; the prepareReview hook enforces that only
                // the booking's guest (after a confirmed session) may create one, and
                // an author may edit/delete only their own review.
                .rules = .{
                    // Reviews are public to read ("@public"); the prepareReview hook still gates
                    // creation. (Empty "" would now LOCK these, not make them public.)
                    .list = "@public",
                    .view = "@public",
                    .create = "@request.auth.id != \"\"",
                    .update = "@request.auth.id = author",
                    .delete = "@request.auth.id = author",
                },
            },
        },
});

pub fn main(init: std.process.Init) !void {
    return App.runCli(init);
}
