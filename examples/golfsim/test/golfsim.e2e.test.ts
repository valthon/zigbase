import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { startGolfsim, type GolfServer } from "./harness.js";
import { createClient, type Booking } from "../clients/typescript/zbase.gen.js";

let server: GolfServer;
beforeAll(async () => { server = await startGolfsim(); });
afterAll(() => server?.stop());

/** Public signup + auth (users has @public create/list/view).
 *
 * users.require_verified = true means authWithPassword returns 403 until the
 * user is verified.  We simulate the email-verification step by:
 *   1. Calling requestVerification (triggers the LogMailer to emit the token).
 *   2. Capturing the token from server stderr via harness.captureVerificationToken.
 *   3. Calling confirmVerification to set verified=true on the record.
 * Then authWithPassword succeeds.
 */
async function host(email: string) {
  const zb = createClient(server.url, { WebSocket: globalThis.WebSocket });
  await zb.db.users.create({ email, password: "member-pass-1", passwordConfirm: "member-pass-1", name: email.split("@")[0]! });

  // Trigger verification email (LogMailer logs it to server stderr).
  await zb.send("POST", "/api/collections/users/request-verification", { body: { email } });
  // Capture the token the LogMailer wrote and confirm it.
  const token = await server.captureVerificationToken(email);
  await zb.send("POST", "/api/collections/users/confirm-verification", { body: { token } });

  const { record: user } = await zb.db.users.authWithPassword(email, "member-pass-1");
  return { zb, user };
}

describe("golfsim generated client (live golfsim server)", () => {
  it("auth + owner-scoped CRUD across simulators/listings, public review read", async () => {
    const { zb, user } = await host("host@golf.app");

    // simulator (owner = the authed user).
    const sim = await zb.db.simulators.create({ label: "Bay 1", owner: user.id });
    expect(sim.label).toBe("Bay 1");

    // listing referencing the simulator; published so it is publicly viewable.
    const listing = await zb.db.listings.create({
      title: "Prime tee time", price_per_hour: 40, status: "published", simulator: sim.id,
    });
    expect(listing.status).toBe("published");

    // public list (anonymous client sees published listings).
    const anon = createClient(server.url, { WebSocket: globalThis.WebSocket });
    const published = await anon.db.listings.getList({ where: { status: "published" } });
    expect(published.items.some((l) => l.id === listing.id)).toBe(true);

    // expand the listing's simulator relation.
    const withSim = await zb.db.listings.getOne(listing.id, { expand: ["simulator"] });
    expect(withSim.expand.simulator.label).toBe("Bay 1");

    // a second user books, then reviews (reviews are public-read).
    const { zb: guest, user: guestUser } = await host("guest@golf.app");
    const booking = await guest.db.bookings.create({
      listing: listing.id, guest: guestUser.id,
      starts_at: "2027-01-01 10:00:00.000Z", ends_at: "2027-01-01 11:00:00.000Z",
    });
    // The booking starts life as a pending hold and price_total is computed
    // server-side (1h * 40/hr); a guest cannot pre-confirm.
    expect(booking.status).toBe("pending");
    expect(booking.price_total).toBe(40);

    // The review gate (prepareReview) only allows reviewing a CONFIRMED booking,
    // and confirmation is an owner-only action (POST /api/bookings/:id/confirm).
    // So the host (listing owner) confirms the guest's booking first.
    // bookingsConfirm has void input + an :id path param → params object only.
    // Output is std.json.Value → unknown, so narrow to Booking for the assertion.
    const confirmed = await zb.rpc.bookingsConfirm({ id: booking.id }) as Booking;
    expect(confirmed.status).toBe("confirmed");

    const review = await guest.db.reviews.create({ booking: booking.id, author: guestUser.id, rating: 5, body: "great" });
    const reviews = await anon.db.reviews.getList({ where: { rating: { gte: 4 } } });
    expect(reviews.items.some((r) => r.id === review.id)).toBe(true);
  });

  /**
   * Session management (#99). golfsim enables `.auth.session.store = .table`, so each login
   * records a per-device session row. This exercises the full surface:
   *   - GET  /api/golfsim/sessions            -> ctx.auth().listActiveSessions()
   *   - POST /api/golfsim/sessions/:id/revoke -> ctx.auth().revoke(id)  (owner-only)
   *   - POST /api/golfsim/logout-everywhere   -> ctx.auth().revokeAllSessions()
   */
  it("per-device sessions: list, revoke one, then logout-everywhere", async () => {
    // One user, signed in from TWO clients == two device sessions.
    const { zb: c1 } = await host("sessions@golf.app");
    const c2 = createClient(server.url, { WebSocket: globalThis.WebSocket });
    await c2.db.users.authWithPassword("sessions@golf.app", "member-pass-1");

    // c1 sees both sessions; exactly one is flagged is_current (this device).
    const listed = (await c1.rpc.golfsimSessions()) as { items: Array<{ id: string; is_current: boolean }> };
    expect(listed.items.length).toBe(2);
    expect(listed.items.filter((s) => s.is_current).length).toBe(1);

    // Revoke the OTHER device's session (owner-authorized), keeping c1 signed in. After
    // it, only c1's own (current) session remains.
    const other = listed.items.find((s) => !s.is_current)!;
    await c1.rpc.golfsimSessionsRevoke({ id: other.id });
    const afterRevoke = (await c1.rpc.golfsimSessions()) as { items: Array<{ is_current: boolean }> };
    expect(afterRevoke.items.length).toBe(1);
    expect(afterRevoke.items[0]!.is_current).toBe(true);

    // "Log out everywhere" bumps the token epoch + wipes every session row; the calling
    // client's own token is now invalid, so a follow-up authed call is rejected.
    // (`fetch` returns the raw Response so we can assert the 204 status.)
    const res = await c1.fetch("POST", "/api/golfsim/logout-everywhere");
    expect(res.status).toBe(204);
    await expect(c1.rpc.golfsimSessions()).rejects.toThrow();
  });
});
