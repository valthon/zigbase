import { describe, it, expect, vi } from "vitest";
import { createClient } from "../src/index.js";
import { isZigbaseError } from "../src/errors.js";

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

describe("changePassword", () => {
  it("PATCHes {password, oldPassword} then re-auths with the stored identity (self-change)", async () => {
    const calls: Array<{ url: string; method: string; body: unknown }> = [];
    const fetchMock = vi.fn(async (url: string, init?: RequestInit) => {
      calls.push({ url: String(url), method: init?.method ?? "GET", body: init?.body ? JSON.parse(String(init.body)) : null });
      if (String(url).includes("auth-with-password")) {
        return jsonResponse({ token: "tok2", record: { id: "u1", email: "a@b.c" } });
      }
      return jsonResponse({ id: "u1", email: "a@b.c" });
    }) as unknown as typeof fetch;
    const zb = createClient("http://api.test", { fetch: fetchMock });
    // Seed the store as a logged-in u1 (token mode).
    zb.authStore.save("tok1", { id: "u1", email: "a@b.c" });

    await zb.collection("users").changePassword("u1", "oldpw", "newpw");

    const patch = calls.find((c) => c.method === "PATCH");
    expect(patch?.url).toBe("http://api.test/api/collections/users/records/u1");
    expect(patch?.body).toEqual({ password: "newpw", oldPassword: "oldpw" });
    // Transparent re-auth with the STORE identity + the NEW password, store updated.
    const reauth = calls.find((c) => c.url.includes("auth-with-password"));
    expect(reauth?.body).toEqual({ identity: "a@b.c", password: "newpw" });
    expect(zb.authStore.token).toBe("tok2");
  });

  it("does NOT re-auth when changing someone else's password (admin reset)", async () => {
    const fetchMock = vi.fn(async (url: string) => {
      expect(String(url)).not.toContain("auth-with-password");
      return jsonResponse({ id: "victim" });
    }) as unknown as typeof fetch;
    const zb = createClient("http://api.test", { fetch: fetchMock });
    zb.authStore.save("admintok", { id: "admin1", email: "root@b.c" });
    await zb.collection("users").changePassword("victim", "", "resetpw123");
    expect(zb.authStore.token).toBe("admintok"); // untouched
  });

  it("surfaces the non-oracle 400 as a ZigbaseError", async () => {
    const fetchMock = vi.fn(async () =>
      jsonResponse({ status: 400, message: "Invalid credentials." }, 400),
    ) as unknown as typeof fetch;
    const zb = createClient("http://api.test", { fetch: fetchMock });
    try {
      await zb.collection("users").changePassword("u1", "wrong", "newpw");
      expect.unreachable();
    } catch (e) {
      expect(isZigbaseError(e)).toBe(true);
      expect((e as { status: number }).status).toBe(400);
    }
  });
});
