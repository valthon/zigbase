import { describe, it, expect, vi } from "vitest";
import { createClient, TwoFactorRequiredError } from "../src/index.js";

const response = (body: unknown) => new Response(JSON.stringify(body), { headers: { "content-type": "application/json" } });
const pending = { status: "factor_required", pendingToken: "restricted", expiresIn: 300 };

describe("two-factor authentication", () => {
  it.each(["password", "oauth2"])("keeps %s pending attempts out of the auth store", async method => {
    const client = createClient("https://api.test", { fetch: vi.fn(async () => response(pending)) as typeof fetch });
    client.authStore.save("previous-session", { id: "previous" });
    const users = client.collection("users");
    const result = method === "password" ? users.authWithPassword("alice", "password") : users.authWithOAuth2({ provider: "test", code: "code", codeVerifier: "verifier", redirectUrl: "https://app.test/cb" });
    await expect(result).rejects.toMatchObject({ name: "TwoFactorRequiredError", pending });
    expect(client.authStore.token).toBeNull();
    await expect(result).rejects.toBeInstanceOf(TwoFactorRequiredError);
  });

  it("saves only the completed session and exposes recovery and management material", async () => {
    const fetcher = vi.fn(async (url: string | URL | Request, init?: RequestInit) => {
      expect(String(url).endsWith("/auth/two-factor/complete")).toBe(true);
      expect(JSON.parse(init!.body as string)).toEqual({ pendingToken: "restricted", factor: "totp", code: "123456" });
      return response({ token: "full-session", record: { id: "alice" }, managementToken: "management" });
    });
    const client = createClient("https://api.test", { fetch: fetcher as typeof fetch });
    const result = await client.collection("users").completeSecondFactor("restricted", { factor: "totp", code: "123456" });
    expect(result.managementToken).toBe("management");
    expect(client.authStore.token).toBe("full-session");
  });

  it("does not save an enrollment capability or setup secret", async () => {
    const client = createClient("https://api.test", { fetch: vi.fn(async () => response({ secret: "SETUPKEY", ceremonyId: "ceremony" })) as typeof fetch });
    await client.collection("users").beginTotpEnrollment("restricted");
    expect(client.authStore.token).toBeNull();
  });
});
