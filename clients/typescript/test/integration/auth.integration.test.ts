import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { startServer, superuserToken, createCollection, type TestServer } from "./harness.js";
import { createClient, isZigbaseError, type ZigbaseError } from "../../src/index.js";

let server: TestServer;

beforeAll(async () => {
  server = await startServer();
  const token = await superuserToken(server);
  await createCollection(server, token, {
    name: "members",
    type: "auth",
    fields: [{ id: "", name: "name", type: "text" }],
    createRule: "",        // allow public signup for the test
    listRule: "",
    viewRule: "",
  });
});

afterAll(() => server?.stop());

describe("auth (live backend)", () => {
  it("registers, logs in, and refreshes a real session", async () => {
    const su = await superuserToken(server);
    // Create a member record (as superuser) with a password.
    const createRes = await fetch(`${server.url}/api/collections/members/records`, {
      method: "POST",
      headers: { "content-type": "application/json", Authorization: `Bearer ${su}` },
      body: JSON.stringify({ email: "m@test.local", password: "member-pass-1", passwordConfirm: "member-pass-1", name: "Mem" }),
    });
    expect(createRes.ok).toBe(true);

    const zb = createClient(server.url);
    const auth = await zb.collection("members").authWithPassword("m@test.local", "member-pass-1");
    expect(auth.token.length).toBeGreaterThan(0);
    expect(zb.authStore.isValid).toBe(true);

    const refreshed = await zb.collection("members").authRefresh();
    expect(refreshed.token.length).toBeGreaterThan(0);

    await zb.collection("members").logout();
    expect(zb.authStore.token).toBeNull();
  });

  it("surfaces a ZigbaseError on bad credentials", async () => {
    const zb = createClient(server.url);
    await expect(
      zb.collection("members").authWithPassword("m@test.local", "wrong"),
    ).rejects.toMatchObject({ status: expect.any(Number) });
  });

  it("carries the frozen machine code end-to-end from a real server", async () => {
    // The unit tests parse a hand-written body; this proves the code survives an
    // actual round-trip through the running binary, which is what makes `code`
    // usable as a branch target instead of the message text.
    const zb = createClient(server.url);
    let caught: unknown;
    try {
      await zb.collection("members").authWithPassword("m@test.local", "wrong");
    } catch (e) {
      caught = e;
    }
    expect(isZigbaseError(caught)).toBe(true);
    const err = caught as ZigbaseError;
    expect(err.code).toBeTruthy();
    // Whatever the server chose, it must be a registered snake_case machine code —
    // never the integer status the pre-unification envelope used to put here.
    expect(err.code).toMatch(/^[a-z][a-z0-9_]*$/);
  });
});
