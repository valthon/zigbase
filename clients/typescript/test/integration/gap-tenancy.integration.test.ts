import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { startAppServer, superuserToken, DATING_BIN, type TestServer } from "./harness.js";
import { createClient } from "../codegen/dating/zbase.gen.js";
import { isZigbaseError } from "../../src/errors.js";

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

describe("tenancy + abilities (live)", () => {
  it("activate -> scope; withAccount scoping; stamped tenant field; cross-account fail closed", async () => {
    const { zb: alice, profile: aliceP } = await authedProfile("alice@t.app");
    const acctA = await seedAccount("acme");
    const acctB = await seedAccount("beta");
    await seedMembership(acctA, aliceP.id, "editor");
    await seedMembership(acctB, aliceP.id, "editor");

    // activate verifies membership and returns the scope
    const scope = await alice.accounts.activate(acctA);
    expect(scope).toEqual({ account: acctA, role: "editor" });

    // withAccount + create: the server STAMPS the tenant field (NoteCreate has no `account`)
    const inA = alice.withAccount(acctA);
    const inB = alice.withAccount(acctB);
    const noteA = await inA.db.notes.create({ title: "a-note" });
    expect(noteA.account).toBe(acctA);
    await inB.db.notes.create({ title: "b-note" });

    // scoped list isolation
    const listA = await inA.db.notes.getList({});
    expect(listA.items.map((n) => n.title)).toEqual(["a-note"]);
    const listB = await inB.db.notes.getList({});
    expect(listB.items.map((n) => n.title)).toEqual(["b-note"]);

    // a non-member scope fails closed on create (no active account context)
    const { zb: mallory } = await authedProfile("mallory@t.app");
    try {
      await mallory.withAccount(acctA).db.notes.create({ title: "steal" });
      expect.unreachable();
    } catch (e) {
      expect(isZigbaseError(e)).toBe(true);
      expect((e as { status: number }).status).toBeGreaterThanOrEqual(400);
    }
    // ...and sees nothing on list
    const stolen = await mallory.withAccount(acctA).db.notes.getList({});
    expect(stolen.items.length).toBe(0);
  });

  it("abilities: role ladder decides update/delete; non-viewable is a 404", async () => {
    const { zb: owner, profile: ownerP } = await authedProfile("owner@t.app");
    const { zb: viewer, profile: viewerP } = await authedProfile("viewer@t.app");
    const { zb: outsider } = await authedProfile("outsider@t.app");
    const acct = await seedAccount("abilities-acct");
    await seedMembership(acct, ownerP.id, "editor");
    await seedMembership(acct, viewerP.id, "viewer");

    const note = await owner.withAccount(acct).db.notes.create({ title: "guarded" });

    // editor: update yes (min_role editor), delete no (min_role admin)
    const abEditor = await owner.withAccount(acct).db.notes.getAbilities(note.id);
    expect(abEditor).toEqual({ view: true, update: true, delete: false });

    // viewer member: sees it, cannot update/delete
    const abViewer = await viewer.withAccount(acct).db.notes.getAbilities(note.id);
    expect(abViewer).toEqual({ view: true, update: false, delete: false });

    // outsider (no membership -> no tenant scope): 404, never reveals existence
    try {
      await outsider.withAccount(acct).db.notes.getAbilities(note.id);
      expect.unreachable();
    } catch (e) {
      expect(isZigbaseError(e)).toBe(true);
      expect((e as { status: number }).status).toBe(404);
    }
  });

  // Finding 1 (gap-closure final review): file serving (GET /api/files/:col/:rec/:name) must
  // resolve tenant scope EXACTLY like records/dispatchCustom, so a tenant-owned collection's
  // file field is not reachable cross-tenant by a principal who merely knows col/rid/filename.
  // `notes.viewRule` is `@request.auth.id != ""` (any authed user) with NO membership check of
  // its own — isolation here can ONLY come from the tenancy scope predicate applied to `.view`.
  it("file serving on a tenant-owned collection: same-tenant fetch works, cross-tenant is denied", async () => {
    const { zb: alice, profile: aliceP } = await authedProfile("alice-files@t.app");
    const { zb: mallory, profile: malloryP } = await authedProfile("mallory-files@t.app");
    const acctA = await seedAccount("files-acme");
    const acctB = await seedAccount("files-beta");
    await seedMembership(acctA, aliceP.id, "editor");
    await seedMembership(acctB, malloryP.id, "editor");

    const inA = alice.withAccount(acctA);
    const blob = new Blob(["tenant-file-contents"], { type: "text/plain" });
    const note = await inA.db.notes.create({ title: "with-attachment", attachment: blob });
    expect(note.attachment).toBeTruthy();
    const filename = note.attachment as string;

    // Same-tenant fetch (alice, active account A, the note's owning account): 200 + body.
    const okRes = await inA.fetch("GET", `/api/files/notes/${note.id}/${filename}`);
    expect(okRes.status).toBe(200);
    expect(await okRes.text()).toBe("tenant-file-contents");

    // Cross-tenant fetch: mallory is authenticated and knows col/rid/filename, but her active
    // account (B) is not the note's owning account (A) — must be denied (404, hides existence)
    // even though `viewRule` alone (`@request.auth.id != ""`) would allow any authed user.
    const crossRes = await mallory.withAccount(acctB).fetch("GET", `/api/files/notes/${note.id}/${filename}`);
    expect(crossRes.status).toBe(404);

    // Mallory with NO active account (never activated/withAccount'd to A) is equally denied.
    const noScopeRes = await mallory.fetch("GET", `/api/files/notes/${note.id}/${filename}`);
    expect(noScopeRes.status).toBe(404);

    // Fully unauthenticated (no bearer/cookie/token at all): fail-closed the same way, pinning
    // the anonymous path empirically rather than inferring it from the authed-no-scope case above.
    const anonRes = await fetch(`${server.url}/api/files/notes/${note.id}/${filename}`);
    expect(anonRes.status).toBe(404);
  });
});
