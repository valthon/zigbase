import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { startGolfsim, type GolfServer } from "./harness.js";
import { createClient, type Booking } from "../clients/typescript/zbase.gen.js";

let server: GolfServer;
beforeAll(async () => { server = await startGolfsim(); });
afterAll(() => server?.stop());

/** Public signup + auth (users has @public create/list/view). */
async function host(email: string) {
  const zb = createClient(server.url, { WebSocket: globalThis.WebSocket });
  const user = await zb.db.users.create({ email, password: "member-pass-1", passwordConfirm: "member-pass-1", name: email.split("@")[0]! });
  await zb.db.users.authWithPassword(email, "member-pass-1");
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
    const confirmed = await zb.send<Booking>("POST", `/api/bookings/${booking.id}/confirm`);
    expect(confirmed.status).toBe("confirmed");

    // `rating` is an int-mode number; the server's wire contract for int/fixed-mode
    // numbers is the decimal STRING form (a bare JSON number is rejected as
    // validation_type, and reads come back as a string too). The generated client
    // types `rating` as `number`, so send the string form via a cast.
    const review = await guest.db.reviews.create({ booking: booking.id, author: guestUser.id, rating: "5" as unknown as number, body: "great" });
    const reviews = await anon.db.reviews.getList({ where: { rating: { gte: 4 } } });
    expect(reviews.items.some((r) => r.id === review.id)).toBe(true);
  });
});
