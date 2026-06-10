---
title: Golf simulator booking
summary: Airbnb for golf simulators — hooks, a business route, a DB-touching cron, and an Astro/React frontend via the comptime-hardcoded static dir.
rung: A realistic app
order: 2
repoPath: examples/golfsim
---

# Golf simulator booking

"**Airbnb for golf simulators**": hosts list golf simulators, guests book time
slots. This is the **realistic** counterpart to the blog example — where the blog
example is a bare packaging proof (one slug hook), `golfsim` exercises the **hard
parts** of building a real backend on ZigBase *as a library*.

## What it proves

1. **A computed + validating `before_create` hook on `bookings`.** It reads
   **related** data (the target listing) through `ev.data`, **rejects** invalid
   input (a 400 to the client), stamps a server-authoritative `guest` from the
   authenticated identity, and **computes** a derived `price_total` = booked hours ×
   the listing's `price_per_hour`.
2. **A custom business route** `POST /api/bookings/:id/confirm` (auth required). It
   reads the `:id` path param, loads the booking from the DB, flips its `status` to
   `"confirmed"`, and returns the updated record as JSON — or **404** when the
   booking does not exist.
3. **A DB-touching interval cron job** `expire-holds` (every 15 minutes). It opens a
   `Data` from the connection pool, lists stale **pending** holds whose slot has
   already started, and marks them `"cancelled"`.
4. **A public smoke route** `GET /api/golfsim/health` returning a small JSON literal.

Everything else (HTTP API, SQLite storage, auth, file storage, the admin UI, the
CLI) comes straight from the framework via the public `zigbase.*` exports.

> **Pre-1.0:** ZigBase is pre-1.0 — the hook/route/job config shapes and the module
> API may change between releases.

## The computed + validating hook (`before_create` on `bookings`)

```zig
fn prepareBooking(ev: *zigbase.RecordEvent) anyerror!void {
    const rec = &ev.record.object;
    const listing_id = /* read the `listing` relation id from rec */;

    // Read RELATED data through the curated facade; reject if it's not bookable.
    const listing = (try ev.data.findById("listings", listing_id)) orelse return error.ListingNotFound;

    // COMPUTE a derived field — note: mutations allocate with ev.arena, NOT ev.app.allocator.
    const price_total = hours * rate;
    try rec.put(ev.arena, "price_total", .{ .float = price_total });

    // Stamp the guest from the authenticated identity (server-authoritative).
    try rec.put(ev.arena, "guest", .{ .string = guest_id });
    try rec.put(ev.arena, "status", .{ .string = "pending" });
}
```

Returning an error from a `before_create` hook **rejects** the write → the client
gets a `400`. Record mutations **must** allocate with `ev.arena` (the request-scoped
allocator that owns `ev.record`), never `ev.app.allocator`.

## The business route (path param + DB write)

```zig
fn confirmBooking(ev: *zigbase.RouteEvent) anyerror!zigbase.http.Response {
    const id = ev.ctx.param("id") orelse return .{ .status = 400, .body = "..." };

    // RouteEvent carries no `Data` — build one from the pool (acquire/release the writer).
    const conn = ev.app.pool.acquireWriter();
    defer ev.app.pool.releaseWriter();
    const data = zigbase.Data{ .app = ev.app, .conn = conn, .io = ev.app.io };

    _ = (try data.findById("bookings", id)) orelse return .{ .status = 404, .body = "..." };
    const updated = (try data.update("bookings", id, /* { "status": "confirmed" } */)).?;
    const body = try std.json.Stringify.valueAlloc(ev.ctx.allocator, updated, .{});
    return .{ .status = 200, .body = body };
}
```

The route is registered with `.auth = .authed`, so the framework enforces
authentication before the handler runs.

## The DB-touching cron job

```zig
fn expireHolds(ev: *zigbase.events.JobEvent) anyerror!void {
    const conn = ev.app.pool.acquireWriter();
    defer ev.app.pool.releaseWriter();
    const data = zigbase.Data{ .app = ev.app, .conn = conn, .io = ev.app.io };

    const stale = data.list("bookings", .{
        .filter = "status = \"pending\" && starts_at < @now",
        .perPage = 200,
    }) catch |err| switch (err) {
        error.UnknownCollection => return, // no-op until provisioning runs
        else => return err,
    };
    for (stale.items) |item| _ = try data.update("bookings", /* item.id */, /* cancelled */);
}
```

This is the pattern for **real DB access inside a background job**: acquire the
pooled writer, wrap it in a `Data`, and release on exit.

## Handler signatures (the contract)

| Feature | Signature |
| --- | --- |
| record hook | `fn(*zigbase.RecordEvent) anyerror!void` |
| custom route | `fn(*zigbase.RouteEvent) anyerror!zigbase.http.Response` |
| cron job | `fn(*zigbase.events.JobEvent) anyerror!void` |

## Frontend (Astro + React islands)

`frontend/` is an Astro site whose React islands drive the whole booking flow: sign in,
browse published listings, hold a slot (the `beforeCreate` hook validates the listing,
computes `price_total`, stamps the guest, and forces `status=pending`), then confirm it
through the custom `POST /api/bookings/:id/confirm` route.

```sh
cd frontend && npm install && npm run build && cd ..
zig build
ZIGBASE_JWT_SECRET="$(head -c 32 /dev/urandom | base64)" \
  ./zig-out/bin/golfsim serve --data-dir ./data
# open http://127.0.0.1:8090/  — no --serve-static needed
```

This demonstrates the **comptime-hardcoded** static mode: `.static_files = .{ .dir =
"frontend/dist" }` bakes the directory into the binary's config, and `--serve-static` is
rejected as an unknown flag. The collections (users / simulators / listings / bookings) are
provisioned at startup from the comptime `.collections` schema.

## Provisioning the collections

The collections are provisioned automatically at startup via the comptime `.collections`
schema in `src/main.zig` — no manual API calls needed. The canonical REST-API provisioning
script in [Recipes → Provisioning your schema](./recipes#recipe-provisioning-your-schema)
remains as an alternative for running the stock binary or fine-grained control.

A quick smoke once the server is up:

```sh
curl -s http://127.0.0.1:8090/api/golfsim/health
# -> {"status":"ok","app":"golfsim"}
```

## Building and running

This example needs **Zig 0.16**, which you can get via [mise](https://mise.jdx.dev)
(`mise exec zig@0.16.0 -- zig ...`). From `examples/golfsim/`:

```sh
cd frontend && npm install && npm run build && cd ..
zig build       # produces ./zig-out/bin/golfsim
./zig-out/bin/golfsim superuser create --email you@example.com --password "<pw>" --data-dir ./data
ZIGBASE_JWT_SECRET="$(head -c 32 /dev/urandom | base64)" \
  ./zig-out/bin/golfsim serve --data-dir ./data
# open http://127.0.0.1:8090/  — frontend served automatically, no --serve-static flag
```

Register a guest, create a `published` listing, and `POST /api/collections/bookings/records`
— the hook fills in `guest`, `status` and `price_total`; `POST /api/bookings/:id/confirm`
flips it to `confirmed`; and the `expire-holds` cron sweeps stale pending holds.

---

[View source on GitHub →](https://github.com/valthon/zigbase/tree/main/examples/golfsim)
