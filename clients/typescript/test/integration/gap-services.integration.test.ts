// Task 14b: `dispatchCustom` (src/server.zig) now resolves the active tenant scope for comptime
// `.routes` EXACTLY like the REST chokepoints (`tenancy.resolveRequest`, shared with
// api/records.zig/api/senders.zig/analytics/api.zig — see src/tenancy/tenancy.zig). A custom
// route's `ctx.track(...)` (fixtures/dating/schema.zig's `testingTrack`) now stamps the caller's
// verified active account, so the events-feed content assertion below (previously `it.todo`,
// blocked on this bug) is live again.
import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { startAppServer, superuserToken, DATING_BIN, type TestServer } from "./harness.js";
import { createClient } from "../codegen/dating/zbase.gen.js";
import { createClient as createBaseClient } from "../../src/index.js";

let server: TestServer;
let suToken: string;
beforeAll(async () => {
  server = await startAppServer({ bin: DATING_BIN });
  suToken = await superuserToken(server);
});
afterAll(() => server?.stop());

async function su(path: string, body: Record<string, unknown>): Promise<Record<string, unknown>> {
  const res = await fetch(`${server.url}${path}`, {
    method: "POST",
    headers: { "content-type": "application/json", Authorization: `Bearer ${suToken}` },
    body: JSON.stringify(body),
  });
  if (!res.ok) throw new Error(`${path} failed: ${res.status} ${await res.text()}`);
  return (await res.json()) as Record<string, unknown>;
}
const seedAccount = async (slug: string) =>
  (await su("/api/collections/_accounts/records", { name: slug, slug, owner_user: "", status: "active" })).id as string;
const seedMembership = (account: string, user: string, role: string) =>
  su("/api/collections/_memberships/records", { account, user_collection: "profiles", user, role, status: "active" });

async function authedProfile(email: string) {
  const zb = createClient(server.url, { WebSocket: globalThis.WebSocket });
  const profile = await zb.db.profiles.create({
    email, password: "member-pass-1", passwordConfirm: "member-pass-1",
    name: email.split("@")[0]!, age: 30,
  });
  await zb.db.profiles.authWithPassword(email, "member-pass-1");
  return { zb, profile };
}

describe("analytics + senders (live)", () => {
  it("events feed reflects a seeded event's account; anon 401; rollup 404-undeclared + declared envelope", async () => {
    const { zb, profile } = await authedProfile("ana@t.app");
    const acct = await seedAccount("analytics-acct");
    await seedMembership(acct, profile.id, "editor");
    const scoped = zb.withAccount(acct);

    // A custom route (`/api/testing/track`, dispatched through dispatchCustom) calling
    // `ctx.track(...)` now stamps the request's resolved active account (Task 14b).
    await scoped.rpc.testingTrack({ name: "note.created" });
    const feed = await scoped.analytics.events({ name: "note.created" });
    expect(feed.items[0]).toMatchObject({ name: "note.created", account: acct });

    // anonymous -> 401
    await expect(createBaseClient(server.url).analytics.events()).rejects.toMatchObject({ status: 401 });
    // undeclared rollup -> 404
    await expect(scoped.analytics.rollup("nope")).rejects.toMatchObject({ status: 404 });
    // declared rollup -> items envelope (buckets may be empty before the hourly job runs)
    const buckets = await scoped.analytics.rollup("notes_daily");
    expect(Array.isArray(buckets.items)).toBe(true);
  });

  it("senders: create pending -> {items} list -> wrong-token verify 404", async () => {
    const { zb, profile } = await authedProfile("snd@t.app");
    const acct = await seedAccount("senders-acct");
    await seedMembership(acct, profile.id, "editor");
    const scoped = zb.withAccount(acct);

    const created = await scoped.senders.create("noreply@acme.example");
    expect(created.status).toBe("pending");
    expect(created.email).toBe("noreply@acme.example");

    const list = await scoped.senders.list(); // {items} envelope — requires >= 0.10.0
    expect(list.items.map((i) => i.email)).toContain("noreply@acme.example");
    expect(list.items[0]).toHaveProperty("verified_at");

    // wrong token collapses to 404 (non-oracle); happy-path verify is skipped —
    // the token only travels by email.
    await expect(scoped.senders.verify(created.id, "wrong-token")).rejects.toMatchObject({ status: 404 });
  });
});
