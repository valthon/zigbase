import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { startAppServer, AUTH2_BIN, type TestServer } from "./harness.js";
import { createClient } from "../../src/index.js";
import { isZigbaseError } from "../../src/errors.js";

let server: TestServer;

beforeAll(async () => {
  server = await startAppServer({ bin: AUTH2_BIN });
});

afterAll(() => server?.stop());

/** Fresh client + a signed-up/logged-in `users` record. */
async function signupAndLogin(email: string, password: string) {
  const zb = createClient(server.url);
  const rec = await zb.collection("users").create({ email, password, passwordConfirm: password });
  const auth = await zb.collection("users").authWithPassword(email, password);
  return { zb, id: rec.id as string, token: auth.token };
}

describe("password change (live)", () => {
  it("changePassword in token mode: old token dead, store re-authed, old password rejected", async () => {
    const { zb, id } = await signupAndLogin("u@t.app", "firstpassword");
    const tokenBefore = zb.authStore.token;
    expect(tokenBefore).toBeTruthy();

    await zb.collection("users").changePassword(id, "firstpassword", "secondpassword");

    // The client transparently re-authed under the new password: a fresh, different token.
    expect(zb.authStore.token).toBeTruthy();
    expect(zb.authStore.token).not.toBe(tokenBefore);

    // A second client still holding the pre-change token is dead (tokenKey rotated).
    const stale = createClient(server.url);
    stale.authStore.save(tokenBefore!, { id });
    await expect(stale.collection("users").authRefresh()).rejects.toMatchObject({ status: 401 });

    // The old password no longer authenticates.
    const other = createClient(server.url);
    await expect(other.collection("users").authWithPassword("u@t.app", "firstpassword")).rejects.toMatchObject({
      status: 400,
      message: "Invalid credentials.",
    });
  });

  it("wrong oldPassword → 400 non-oracle; nothing changed", async () => {
    const { zb, id } = await signupAndLogin("w2@t.app", "firstpassword");

    await expect(
      zb.collection("users").changePassword(id, "WRONGpassword", "secondpassword"),
    ).rejects.toMatchObject({ status: 400, message: "Invalid credentials." });

    // Unchanged: the original password still authenticates.
    const other = createClient(server.url);
    const auth = await other.collection("users").authWithPassword("w2@t.app", "firstpassword");
    expect(auth.token.length).toBeGreaterThan(0);
  });
});

describe("sessions (live, table mode)", () => {
  it("two logins → listSessions shows 2 with exactly one is_current; revokeSession kills the other", async () => {
    const email = "sess@t.app";
    const password = "sessionpass1";
    const { zb: zbA } = await signupAndLogin(email, password);
    const zbB = createClient(server.url);
    await zbB.collection("users").authWithPassword(email, password);

    const sessions = await zbB.collection("users").listSessions();
    expect(sessions).toHaveLength(2);
    expect(sessions.filter((s) => s.is_current).length).toBe(1);
    // Newest-first: device B's just-minted session leads.
    expect(sessions[0]!.is_current).toBe(true);

    const other = sessions.find((s) => !s.is_current);
    expect(other).toBeDefined();
    await zbB.collection("users").revokeSession(other!.id);

    // Device A is dead on its next call.
    await expect(zbA.collection("users").authRefresh()).rejects.toMatchObject({ status: 401 });

    // Device B is unaffected: exactly its own session remains.
    const remaining = await zbB.collection("users").listSessions();
    expect(remaining).toHaveLength(1);
    expect(remaining[0]!.is_current).toBe(true);
  });

  it("revokeAllSessions → 204, store cleared, both tokens dead, epoch-mode-agnostic verb", async () => {
    const email = "revoke-all@t.app";
    const password = "revokeallpw1";
    const { zb: zbA } = await signupAndLogin(email, password);
    const zbB = createClient(server.url);
    await zbB.collection("users").authWithPassword(email, password);

    // Raw escape hatch (bypasses JSON-parsing/throw) to observe the wire response directly.
    const res = await zbA.fetch("DELETE", "/api/collections/users/auth/sessions");
    expect(res.status).toBe(204);
    expect(await res.text()).toBe("");

    // Both devices' sessions are dead — revoke-all kills everything, not just the caller.
    await expect(zbB.collection("users").authRefresh()).rejects.toMatchObject({ status: 401 });

    // The real SDK method: its own (now-dead) token 401s, but the store is still
    // cleared in the `finally` — end-to-end proof of the same guarantee the mocked
    // unit test only simulates.
    await expect(zbA.collection("users").revokeAllSessions()).rejects.toSatisfy(isZigbaseError);
    expect(zbA.authStore.token).toBeNull();
  });

  it("beforeAuthSuccess veto (blocked@t.app) surfaces as a 403 ZigbaseError on authWithPassword", async () => {
    const zb = createClient(server.url);
    await zb.collection("users").create({
      email: "blocked@t.app",
      password: "blockedpass1",
      passwordConfirm: "blockedpass1",
    });

    await expect(zb.collection("users").authWithPassword("blocked@t.app", "blockedpass1")).rejects.toMatchObject({
      status: 403,
      message: "login blocked by hook",
    });
  });
});
