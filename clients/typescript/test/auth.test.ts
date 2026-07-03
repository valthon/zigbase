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
      expect(url).toBe("http://api.test/api/collections/users/auth/oauth2/providers");
      return jsonResponse({ items: [{ name: "google", authURL: "https://g", clientId: "cid" }] });
    }) as unknown as typeof fetch;
    const zb = createClient("http://api.test", { fetch: fetchMock });
    const out = await zb.collection("users").listAuthProviders();
    expect(out.items[0]?.name).toBe("google");
  });

  it("oauth2Init posts provider and returns initiate response", async () => {
    const fetchMock = vi.fn(async (url: string, init: RequestInit) => {
      expect(url).toBe("http://api.test/api/collections/users/auth/oauth2/initiate");
      expect(init.method).toBe("POST");
      expect(JSON.parse(init.body as string)).toEqual({ provider: "google" });
      return jsonResponse({ authURL: "https://accounts.google.com/o/oauth2/auth?...", clientId: "cid", scopes: ["email"], state: "abc" });
    }) as unknown as typeof fetch;
    const zb = createClient("http://api.test", { fetch: fetchMock });
    const out = await zb.collection("users").oauth2Init("google");
    expect(out.authURL).toContain("accounts.google.com");
    expect(out.state).toBe("abc");
  });

  it("authWithOAuth2 posts to complete endpoint and stores token only", async () => {
    const token = makeJwt({ id: "u1", exp: Math.floor(Date.now() / 1000) + 3600 });
    const fetchMock = vi.fn(async (url: string, init: RequestInit) => {
      expect(url).toBe("http://api.test/api/collections/users/auth/oauth2/complete");
      expect(init.method).toBe("POST");
      const body = JSON.parse(init.body as string);
      expect(body.provider).toBe("google");
      expect(body.code).toBe("authcode");
      return jsonResponse({ token });
    }) as unknown as typeof fetch;
    const zb = createClient("http://api.test", { fetch: fetchMock });
    const out = await zb.collection("users").authWithOAuth2({
      provider: "google",
      code: "authcode",
      codeVerifier: "verifier",
      redirectUrl: "http://localhost/cb",
    });
    expect(out.token).toBe(token);
    expect(zb.authStore.token).toBe(token);
    // record is no longer returned by the complete endpoint
    expect(zb.authStore.record).toBeNull();
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
