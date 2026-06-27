# ZigBase golfsim example — a realistic complete app

"**Airbnb for golf simulators**": hosts list golf simulators, guests book time
slots. This is the **middle rung** of a three-example ladder:

| Rung | Example | Purpose |
|------|---------|---------|
| 1 | `examples/blog` | Minimal packaging proof — one hook, one route, one cron |
| 2 | **`examples/golfsim`** | Realistic complete product — multi-collection relations, hooks, files, realtime |
| 3 | `examples/plugins` | Advanced framework surface — custom storage, comptime migrations, pool tuning |

`golfsim` covers the **hard parts** of building a real backend on ZigBase *as a
library*: multi-collection relations with cascadeDelete, invariant-enforcing hooks
(double-booking prevention), access rules with relation traversal, file uploads,
WebSocket realtime, and multiple custom business routes — all with a working
Astro + React frontend.

Everything else (HTTP API, SQLite storage, auth, file storage, the admin UI, the
CLI) comes straight from the framework via the public `zigbase.*` exports.

> **Pre-1.0:** ZigBase is pre-1.0 — the hook/route/job config shapes and the module
> API may change between releases.

---

## What golfsim demonstrates

### 1. Invariant-enforcing hooks

#### `prepareBooking` — `beforeCreate` on `bookings`

```zig
fn prepareBooking(ctx: *zigbase.Ctx, ev: *zigbase.RecordEvent) anyerror!void {
    // 1. Validate listing exists and is published. DB access goes through the
    //    per-request capability object: `ctx.records()` (bound to the triggering
    //    write's in-transaction connection).
    const listing = (try ctx.records().get("listings", listing_id, .{})) orelse
        return error.ListingNotFound;

    // 2. Double-booking check — allocate filter with ev.arena (NEVER ev.app.allocator).
    const overlap_filter = try std.fmt.allocPrint(ev.arena,
        "listing = \"{s}\" && status != \"cancelled\" && starts_at < \"{s}\" && ends_at > \"{s}\"",
        .{ listing_id, ends_at, starts_at });
    const conflicts = try ctx.records().list("bookings", .{ .filter = overlap_filter, .perPage = 1 });
    // totalItems is optional (cursor mode may skip COUNT); offset mode always sets it.
    if ((conflicts.totalItems orelse 0) > 0) return error.TimeSlotConflict; // -> HTTP 400

    // 3. Compute price_total = hours × rate (server-side, unforgeable).
    try rec.put(ev.arena, "price_total", .{ .float = hours * rate });

    // 4. Stamp guest and force status=pending from the server.
    try rec.put(ev.arena, "guest", .{ .string = try ev.arena.dupe(u8, auth_id) });
    try rec.put(ev.arena, "status", .{ .string = "pending" });
}
```

Record mutations that enter `ev.record` **must** allocate with `ev.arena`
(the request-scoped allocator that owns `ev.record`), never `ev.app.allocator`.
Returning any error rejects the write → HTTP 400 to the client.

#### `prepareReview` — `beforeCreate` on `reviews`

A second invariant hook gates who may leave a review. It stamps the `author`
from the authenticated identity (server-authoritative) and rejects the write
unless the referenced booking exists, was made by *this* author (they were the
`guest`), and is already `confirmed` — you can't review someone else's booking,
or a session that hasn't happened:

```zig
fn prepareReview(ctx: *zigbase.Ctx, ev: *zigbase.RecordEvent) anyerror!void {
    const booking = (try ctx.records().get("bookings", booking_id, .{})) orelse
        return error.BookingNotFound;
    // gate 1: the booking must be the caller's own
    if (!std.mem.eql(u8, guest, author)) return error.BookingNotYours;     // -> 400
    // gate 2: only a CONFIRMED (completed) session may be reviewed
    if (!std.mem.eql(u8, status, "confirmed")) return error.BookingNotConfirmed; // -> 400
    // stamp author from the identity (overwriting any client-supplied value)
    try rec.put(ev.arena, "author", .{ .string = try ev.arena.dupe(u8, author) });
}
```

---

### 2. Custom business routes

| Method | Path | Auth | What it does |
|--------|------|------|--------------|
| `POST` | `/api/bookings/:id/confirm` | authed | Host confirms a booking. Multi-hop owner check: booking → listing → simulator → owner. 403 if caller doesn't own the simulator. |
| `POST` | `/api/bookings/:id/cancel` | authed | Guest cancels their own booking. 403 if caller is not the booking's guest. Reads/writes via `req.ctx.records()`. |
| `GET` | `/api/listings/:id/availability` | authed | Returns all non-cancelled bookings for a listing for availability calendar rendering. Reads via `req.ctx.records()`. |
| `GET` | `/api/golfsim/health` | public | Smoke endpoint. |

The `confirmBooking` route shows the multi-hop imperative owner check (the access
rule engine does this via traversal for CRUD endpoints; custom routes do it via
`records.get` hops). It is a typed route — `req.ctx.records()` manages the pooled
connection itself (no manual acquireWriter / Data wiring):

```zig
fn confirmBooking(req: *zigbase.Req(void)) zigbase.RouteError!std.json.Value {
    const records = req.ctx.records();
    // booking.listing -> listings -> listing.simulator -> simulators -> simulator.owner
    const listing = (records.get("listings", listing_id, .{}) catch return error.RouteFailed) orelse return error.NotFound;
    const simulator = (records.get("simulators", simulator_id, .{}) catch return error.RouteFailed) orelse return error.NotFound;
    const owner_id = // simulator.owner
    if (!std.mem.eql(u8, owner_id, caller_id)) return error.Forbidden; // 403
    const updated = (records.update("bookings", id, patch) catch return error.RouteFailed) orelse return error.NotFound;
    return updated; // thunk serializes it to the 200 body
}
```

---

### 3. Files — listing photos

`listings` has a `photos` file field accepting up to 6 images (5 MB each, png/jpeg/webp):

```zig
.{ .name = "photos", .type = .file, .maxSelect = 6, .maxSize = 5242880,
   .mimeTypes = .{ "image/png", "image/jpeg", "image/webp" } }
```

Upload via `PATCH /api/collections/listings/records/:id` with `multipart/form-data`.
Do NOT set `Content-Type` — the browser sets the multipart boundary automatically.
Serve stored photos at `/api/files/listings/:recId/:filename`.

An `onFileUpload` handler logs every upload:

```zig
fn logFileUpload(ev: *zigbase.events.FileEvent) void {
    std.log.info("file-upload: collection={s} record={s} file={s}",
        .{ ev.collection, ev.record_id, ev.filename });
}
// registered as: .onFileUpload = logFileUpload
```

---

### 4. Access rules with relation traversal

```
bookings.list = "@request.auth.id = guest || @request.auth.id = listing.simulator.owner"
```

The rule engine traverses `booking.listing → listing.simulator → simulator.owner`
at query time for all CRUD endpoints — the application layer doesn't join manually
for authorization. Custom routes re-implement this imperatively (via
`records.get` hops) to return a proper 403.

---

### 5. Realtime

`MyBookings` subscribes to the `bookings` topic over WebSocket so the booking
list live-updates without polling whenever a host confirms, a guest cancels, or
the `expire-holds` cron sweeps stale holds:

```ts
// lib/api.ts — subscribeBookings()
const ws = new WebSocket(`${proto}://${location.host}/api/realtime`);
ws.onopen = () => ws.send(JSON.stringify({ action: 'auth', token }));
// on { type:"auth", status:"ok" } → send { action:"subscribe", topic:"bookings" }
// on { type:"event", topic:"bookings", action, record } → call onEvent
```

Returns a cleanup function (calls `ws.close()`) wired into a React `useEffect`
teardown.

---

### 6. DB-touching cron job

```zig
fn expireHolds(ctx: *zigbase.Ctx, ev: *zigbase.events.JobEvent) anyerror!void {
    _ = ev;
    const stale = ctx.records().list("bookings", .{
        .filter = "status = \"pending\" && starts_at < @now",
        .perPage = 200,
    }) catch |err| switch (err) {
        error.UnknownCollection => return, // no-op until provisioning runs
        else => return err,
    };
    for (stale.items) |item| _ = ctx.records().update("bookings", id, /* cancelled */) catch continue;
}
```

Real DB access inside a background job: the scheduler hands the job a `*Ctx` whose
`records()` handle reads via a pooled reader and writes via the pool writer — no
manual `pool.acquireWriter()` + hand-built `Data`. The framework owns the ctx
lifetime and releases any lazily-acquired connection on exit.

---

## Collections

| Collection | Type | Key fields |
|---|---|---|
| `users` | auth | `name`; `require_verified=true`; OTP + password methods; Google OAuth2 |
| `simulators` | base | `label`, `owner` → users |
| `listings` | base | `title`, `price_per_hour`, `status` (draft/published/archived), `simulator` → simulators, `photos` (file ×6) |
| `bookings` | base | `listing`, `guest`, `starts_at`, `ends_at`, `price_total`, `status` (pending/confirmed/cancelled) |
| `reviews` | base | `booking` → bookings, `author` → users, `rating` (int 1–5), `body` (text) |

All five collections are provisioned at startup via comptime `.collections` — no
manual API calls needed. (Lowering a schema this size FNV-hashes every collection
+ field name at comptime, which would exceed Zig's default branch quota; ZigBase
raises its own quota in `provision.buildCollections`, so it just works.)

---

## Handler signatures

| Feature | Signature |
|---|---|
| record hook | `fn(*zigbase.Ctx, *zigbase.RecordEvent) anyerror!void` |
| typed custom route | `fn(*zigbase.Req(In)) zigbase.RouteError!Out` |
| untyped custom route | `fn(*zigbase.Ctx) anyerror!zigbase.http.Response` |
| cron job | `fn(*zigbase.Ctx, *zigbase.events.JobEvent) anyerror!void` |
| file upload | `fn(*zigbase.events.FileEvent) void` |

DB access is through the per-request capability object: `ctx.records()` in hooks/
jobs/untyped routes, `req.ctx.records()` in typed routes — the pooled connection
is managed for you (`.get` / `.list` / `.create` / `.update` / `.delete`).

For raw SQL on a migration-owned table, acquire the pooled writer directly:
`const w = ctx.app.pool.acquireWriter(); defer ctx.app.pool.releaseWriter();`.

---

## Frontend (Astro + React)

`frontend/` is an Astro site with React islands:

- **`ListingsBrowser`** — sign in, browse listings with photo gallery, check
  availability (lazy via `/api/listings/:id/availability`), book a slot, upload
  photos via multipart/form-data.
- **`MyBookings`** — view bookings, cancel pending/confirmed bookings, leave a
  rating + review on a confirmed booking; live-updates via realtime WebSocket.
- **`Auth`** — multi-step auth: password sign-in, OTP initiate/complete, signup, email-verification, and OAuth2 (Google).

---

## Generated TypeScript client

> **SDK Tier 2 — comptime-generated typed client.** `zig build gen-client` reads this example's `pub const App` at build time and emits a fully-typed `zbase.gen.ts`: typed `zb.db.<collection>.*` and typed custom-route RPC via `zb.rpc.*` (e.g. `zb.rpc.bookingsConfirm({ id })`). This is the richest tier — it's the only one with typed custom-route RPC. See the [TypeScript SDK docs](../../docs/typescript-sdk.md) and, for runtime generation without Zig source, the plugins example (Tier 3).

`examples/golfsim` ships a **generated, fully type-safe TypeScript client** at
`clients/typescript/zbase.gen.ts`. The file is committed to the repo; `zig build
gen-client` regenerates it from the schema, and the CI staleness gate (`zig build
gen-client-check`) fails if the committed snapshot is out of date.

The prerequisite for code generation is that `src/main.zig` exposes `pub const App`
at module scope — the generator reads the schema directly from the comptime `App`
declaration:

```zig
// src/main.zig
pub const App = zigbase.App(.{
    .collections = .{ ... },
    // ... hooks, routes, jobs ...
});

pub fn main(init: std.process.Init) !void {
    return App.runCli(init);
}
```

### Commands

```bash
# Regenerate the typed client from the schema:
zig build gen-client

# CI staleness gate — fails if the committed zbase.gen.ts is stale:
zig build gen-client-check

# Build @zigbase/client, then typecheck + run the full e2e suite against a live
# golfsim binary:
cd ../../clients/typescript && npm run build && cd ../../examples/golfsim
npm install && npm run typecheck && npm run test:e2e
```

The e2e suite (`test/`) drives the generated typed client (`clients/typescript/zbase.gen.ts`)
against a live `golfsim` binary — covering CRUD, filtering, auth, and realtime with
full TypeScript type-checking via `vitest`.

### Using `zb.rpc.*`

The generated client exposes typed methods for each custom route under `zb.rpc.*`:

```ts
// bookingsConfirm: POST /api/bookings/:id/confirm → unknown (cast for type-safe access)
const confirmed = await zb.rpc.bookingsConfirm({ id: booking.id }) as Booking;

// bookingsCancel: POST /api/bookings/:id/cancel
await zb.rpc.bookingsCancel({ id: booking.id });

// listingsAvailability: GET /api/listings/:id/availability
const avail = await zb.rpc.listingsAvailability({ id: listing.id });

// golfsimHealth: GET /api/golfsim/health → typed HealthOut { status: string; app: string }
const health = await zb.rpc.golfsimHealth();
```

`unknown` outputs correspond to `std.json.Value` in Zig — cast to your concrete type for field access. The e2e test (`test/golfsim.e2e.test.ts`) exercises `bookingsConfirm` live through this surface.

---

## Auth & onboarding

`golfsim` uses `require_verified = true` on the `users` collection: a guest must
have a verified email before a session is minted. This is appropriate for a
booking/payments app — unverified accounts cannot hold time slots.

### Onboarding flow (new users)

1. **Sign up** — email + password via the login card on the home page.
   (API: `POST /api/collections/users/records`)
2. **Verify email** — a verification token is emailed (dev: printed to the server log
   by the default LogMailer). Paste it into the "Verify your account" input.
   (API: `POST /api/collections/users/confirm-verification`)
3. **Sign in** — password login now succeeds, or use OTP for future logins.

### OTP passwordless login (returning verified users)

Once verified, users may sign in with a one-time code instead of their password:

1. Enter email → "Send one-time code".
   (API: `POST /api/collections/users/auth/otp/initiate`)
2. Enter the 6-digit code from the email (dev: server log). Valid for 5 minutes.
   (API: `POST /api/collections/users/auth/otp/complete`)

`auto_create = false` means OTP will NOT create new accounts — it is a convenience
for existing, verified users only. First-time onboarding always uses password signup.

### OAuth2 — Sign in with Google

Google OAuth2 is declared at comptime and enabled when environment credentials are set:

```sh
export ZIGBASE_OAUTH_GOOGLE_CLIENT_ID=<your_client_id>
export ZIGBASE_OAUTH_GOOGLE_CLIENT_SECRET=<your_client_secret>
```

Google-verified accounts are created with `verified=true` and can book immediately,
bypassing the email-verification step. This flow is **not exercised in CI** (it
requires live Google credentials).

To test locally:
1. Create a Google OAuth2 client in GCP (Web application type).
2. Add `http://localhost:8090/api/oauth2/google/callback` as an authorized redirect URI.
3. Set the env vars above and restart the binary.
4. The "Sign in with Google" button on the login card will redirect to Google.

### Comptime indexes

Two indexes are provisioned at startup via comptime `.indexes`:

- **`idx_users_email_nocase`** — unique, `COLLATE NOCASE` on `users.email`. Prevents
  `Bob@x.com` and `bob@x.com` from being treated as distinct accounts.
- **`idx_bookings_listing_time_active`** — composite `(listing, starts_at)` with
  `WHERE status != 'cancelled'`. Backs the double-booking overlap check
  (`prepareBooking`) and the availability route — only active bookings are indexed,
  so availability queries are O(active bookings per listing).

---

## Building and running

```sh
# 1. Build the frontend
cd frontend && npm install && npm run build && cd ..

# 2. Build the backend
mise exec zig@0.16.0 -- zig build          # -> ./zig-out/bin/golfsim

# 3. Create a superuser (optional — admin UI at /_/)
./zig-out/bin/golfsim superuser create --email you@example.com --password "<pw>" --data-dir ./data

# 4. Run
# --insecure-cookies: local dev over plain HTTP (auth cookies are Secure by default).
# The frontend is served from this same binary, so its live-bookings WebSocket is
# same-origin and allowed by default — no --realtime-origins needed.
# A random JWT secret is generated + persisted at data/.jwt_secret on first run.
./zig-out/bin/golfsim serve --insecure-cookies --data-dir ./data
# open http://127.0.0.1:8090/  — frontend served automatically, no --serve-static flag
```

The collections provision themselves at startup. A quick smoke:

```sh
curl -s http://127.0.0.1:8090/api/golfsim/health
# -> {"status":"ok","app":"golfsim"}
```

## Using ZigBase in your own project

```sh
zig fetch --save git+https://github.com/valthon/zigbase
```

```zig
const zigbase = b.dependency("zigbase", .{ .target = target, .optimize = optimize });
exe_mod.addImport("zigbase", zigbase.module("zigbase"));
```

Your executable module must `.link_libc = true` (SQLite needs libc).
