import { describe, it, expect, vi } from "vitest";
import { createClient } from "../src/index.js";

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function makeJwt(payload: Record<string, unknown>): string {
  const b64url = (o: unknown) => Buffer.from(JSON.stringify(o)).toString("base64url");
  return `${b64url({ alg: "HS256" })}.${b64url(payload)}.sig`;
}

describe("auth service", () => {
  it("authWithPassword posts identity+password and stores token+record", async () => {
    const token = makeJwt({ id: "u1", exp: Math.floor(Date.now() / 1000) + 3600 });
    const fetchMock = vi.fn(async (url: string, init: RequestInit) => {
      expect(url).toBe("http://api.test/api/collections/users/auth-with-password");
      expect(init.method).toBe("POST");
      expect(JSON.parse(init.body as string)).toEqual({ identity: "a@b.c", password: "pw" });
      return jsonResponse({ token, record: { id: "u1", email: "a@b.c" } });
    }) as unknown as typeof fetch;

    const zb = createClient("http://api.test", { fetch: fetchMock });
    const out = await zb.collection("users").authWithPassword("a@b.c", "pw");
    expect(out.token).toBe(token);
    expect(zb.authStore.token).toBe(token);
    expect(zb.authStore.record?.id).toBe("u1");
    expect(zb.authStore.isValid).toBe(true);
  });

  it("logout clears the auth store", async () => {
    const fetchMock = vi.fn(async () => new Response(null, { status: 204 })) as unknown as typeof fetch;
    const zb = createClient("http://api.test", { fetch: fetchMock });
    zb.authStore.save("x.y.z", { id: "u1" });
    await zb.collection("users").logout();
    expect(zb.authStore.token).toBeNull();
  });

  it("listAuthProviders fetches provider metadata", async () => {
    const fetchMock = vi.fn(async (url: string) => {
      expect(url).toBe("http://api.test/api/collections/users/oauth2-providers");
      return jsonResponse({ providers: [{ name: "google", authURL: "https://g", clientId: "cid" }] });
    }) as unknown as typeof fetch;
    const zb = createClient("http://api.test", { fetch: fetchMock });
    const out = await zb.collection("users").listAuthProviders();
    expect(out.providers[0]?.name).toBe("google");
  });

  it("requestPasswordReset posts email and returns void", async () => {
    const fetchMock = vi.fn(async (url: string, init: RequestInit) => {
      expect(url).toBe("http://api.test/api/collections/users/request-password-reset");
      expect(JSON.parse(init.body as string)).toEqual({ email: "a@b.c" });
      return new Response(null, { status: 204 });
    }) as unknown as typeof fetch;
    const zb = createClient("http://api.test", { fetch: fetchMock });
    await expect(zb.collection("users").requestPasswordReset("a@b.c")).resolves.toBeUndefined();
  });
});
