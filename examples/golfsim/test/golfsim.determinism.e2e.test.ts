import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { createServer, type Server } from "node:http";
import { AddressInfo } from "node:net";
import { startGolfsim, type GolfServer } from "./harness.js";
import { createClient, type Booking, type Hold } from "../clients/typescript/zbase.gen.js";

// The whole process clock is frozen to this instant via ZIGBASE_FAKE_NOW. The seam is
// compiled in only on a dev-mode build (the default Debug build the harness produces),
// so every framework + consumer `'now'` (token exp, SQLite `unixepoch('now')`, autodate
// columns) resolves to this fixed point. golfsim's prepareHold hook reads "now" from the
// DB clock, so a hold's expires_at becomes deterministic: FROZEN + 15 minutes.
const FROZEN = "2030-06-15T12:00:00Z";
const FROZEN_PLUS_15M = "2030-06-15T12:15:00"; // expires_at = now + hold_ttl_seconds

// In-process capture server for the outbound booking-confirmation webhook (ctx.http()).
// golfsim POSTs here when a booking is confirmed; we record the request to assert on it.
interface Captured {
  method: string | undefined;
  url: string | undefined;
  body: string;
}
let webhook: Server;
let webhookUrl: string;
const captured: Captured[] = [];

let server: GolfServer;

beforeAll(async () => {
  webhook = await new Promise<Server>((resolve) => {
    const s = createServer((req, res) => {
      let body = "";
      req.on("data", (c) => (body += c));
      req.on("end", () => {
        captured.push({ method: req.method, url: req.url, body });
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end('{"ok":true}');
      });
    });
    s.listen(0, "127.0.0.1", () => resolve(s));
  });
  const port = (webhook.address() as AddressInfo).port;
  webhookUrl = `http://127.0.0.1:${port}/hooks/booking`;

  // Start a golfsim server with frozen time + the webhook URL wired through env. seedConfig
  // (onBootstrap) reads GOLFSIM_BOOKING_WEBHOOK_URL and persists it into the KV store.
  server = await startGolfsim({ env: { ZIGBASE_FAKE_NOW: FROZEN, GOLFSIM_BOOKING_WEBHOOK_URL: webhookUrl } });
});

afterAll(() => {
  server?.stop();
  webhook?.close();
});

/** Signup + email-verification + password login (mirrors the main suite's `host`). */
async function signIn(email: string) {
  const zb = createClient(server.url, { WebSocket: globalThis.WebSocket });
  await zb.db.users.create({ email, password: "member-pass-1", passwordConfirm: "member-pass-1", name: email.split("@")[0]! });
  await zb.send("POST", "/api/collections/users/request-verification", { body: { email } });
  const token = await server.captureVerificationToken(email);
  await zb.send("POST", "/api/collections/users/confirm-verification", { body: { token } });
  const { record: user } = await zb.db.users.authWithPassword(email, "member-pass-1");
  return { zb, user };
}

describe("golfsim determinism seam + ctx.tx + ctx.http (frozen clock)", () => {
  it("ZIGBASE_FAKE_NOW freezes a hold's server-stamped expires_at", async () => {
    const { zb: host, user: hostUser } = await signIn("det-host@golf.app");
    const sim = await host.db.simulators.create({ label: "Frozen Bay", owner: hostUser.id });
    const listing = await host.db.listings.create({
      title: "Deterministic tee time", price_per_hour: 50, status: "published", simulator: sim.id,
    });

    const { zb: guest, user: guestUser } = await signIn("det-guest@golf.app");
    // prepareHold stamps expires_at = now + 15m using the DB clock; under FAKE_NOW that is
    // a fixed instant, NOT wall-clock 2026 — proving the seam reaches consumer hook code.
    // @ts-expect-error expires_at is required in the schema but stamped server-side by prepareHold.
    const hold = (await guest.db.holds.create({ listing: listing.id, guest: guestUser.id })) as Hold;
    expect(hold.expires_at).toContain("2030-06-15");
    expect(hold.expires_at).toContain("12:15:00");
    expect(hold.expires_at.startsWith(FROZEN_PLUS_15M)).toBe(true);
  });

  it("ctx.tx converts a hold into a booking atomically (booking created, hold deleted)", async () => {
    const { zb: host, user: hostUser } = await signIn("tx-host@golf.app");
    const sim = await host.db.simulators.create({ label: "Tx Bay", owner: hostUser.id });
    const listing = await host.db.listings.create({
      title: "Convertible slot", price_per_hour: 50, status: "published", simulator: sim.id,
    });

    const { zb: guest, user: guestUser } = await signIn("tx-guest@golf.app");
    // @ts-expect-error expires_at is required in the schema but stamped server-side by prepareHold.
    const hold = await guest.db.holds.create({ listing: listing.id, guest: guestUser.id });

    // POST /api/holds/:id/convert runs the booking-create + hold-delete in one ctx.tx.
    const booking = (await guest.rpc.holdsConvert(
      { id: hold.id },
      { starts_at: "2030-06-20 09:00:00.000Z", ends_at: "2030-06-20 10:00:00.000Z" },
    )) as Booking;
    expect(booking.status).toBe("pending");
    expect(booking.price_total).toBe(50); // 1h * 50/hr, computed server-side

    // The hold no longer exists — both writes committed together.
    await expect(guest.db.holds.getOne(hold.id)).rejects.toThrow();
  });

  it("ctx.http() fires a booking-confirmation webhook on confirm", async () => {
    const { zb: host, user: hostUser } = await signIn("hook-host@golf.app");
    const sim = await host.db.simulators.create({ label: "Hook Bay", owner: hostUser.id });
    const listing = await host.db.listings.create({
      title: "Notified slot", price_per_hour: 40, status: "published", simulator: sim.id,
    });

    const { zb: guest, user: guestUser } = await signIn("hook-guest@golf.app");
    const booking = await guest.db.bookings.create({
      listing: listing.id, guest: guestUser.id,
      starts_at: "2030-07-01 10:00:00.000Z", ends_at: "2030-07-01 11:00:00.000Z",
    });

    const before = captured.length;
    // The host confirms; confirmBooking OFFLOADS the webhook to the background worker pool
    // (ctx.app.submit), so the POST arrives shortly AFTER the confirm response — poll for it.
    await host.rpc.bookingsConfirm({ id: booking.id });

    const ours = await poll(() => captured.slice(before).find((c) => c.body.includes(booking.id)), 2000);
    expect(ours).toBeDefined();
    expect(ours!.method).toBe("POST");
    const payload = JSON.parse(ours!.body);
    expect(payload.event).toBe("booking.confirmed");
    expect(payload.booking).toBe(booking.id);
  });
});

/** Poll `fn` until it returns a truthy value or the timeout elapses (50ms interval). */
async function poll<T>(fn: () => T | undefined, timeoutMs: number): Promise<T | undefined> {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const v = fn();
    if (v) return v;
    if (Date.now() > deadline) return undefined;
    await new Promise((r) => setTimeout(r, 50));
  }
}
