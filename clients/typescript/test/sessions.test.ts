import { describe, it, expect, vi } from "vitest";
import { createClient } from "../src/index.js";
import { isZigbaseError } from "../src/errors.js";

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}
const emptyResponse = (status = 204) => new Response(null, { status });

describe("sessions", () => {
  it("listSessions GETs /auth/sessions and unwraps the {items} envelope", async () => {
    const fetchMock = vi.fn(async (url: string) => {
      expect(url).toBe("http://api.test/api/collections/users/auth/sessions");
      return jsonResponse({ items: [{ id: "s1", created: "c", last_seen: "l", user_agent: "ua", ip: "1.2.3.4", is_current: true }] });
    }) as unknown as typeof fetch;
    const zb = createClient("http://api.test", { fetch: fetchMock });
    const out = await zb.collection("users").listSessions();
    expect(out).toHaveLength(1);
    expect(out[0]).toMatchObject({ id: "s1", is_current: true });
  });

  it("revokeSession DELETEs /auth/sessions/:sid (204, id URL-encoded)", async () => {
    const fetchMock = vi.fn(async (url: string, init?: RequestInit) => {
      expect(url).toBe("http://api.test/api/collections/users/auth/sessions/s%2F1");
      expect(init?.method).toBe("DELETE");
      return emptyResponse();
    }) as unknown as typeof fetch;
    const zb = createClient("http://api.test", { fetch: fetchMock });
    await zb.collection("users").revokeSession("s/1");
  });

  it("revokeAllSessions DELETEs /auth/sessions and clears the local auth store — even on failure", async () => {
    const fetchMock = vi.fn(async (url: string, init?: RequestInit) => {
      expect(url).toBe("http://api.test/api/collections/users/auth/sessions");
      expect(init?.method).toBe("DELETE");
      return emptyResponse();
    }) as unknown as typeof fetch;
    const zb = createClient("http://api.test", { fetch: fetchMock });
    zb.authStore.save("tok", { id: "u1" });
    await zb.collection("users").revokeAllSessions();
    expect(zb.authStore.token).toBe(null);

    const failMock = vi.fn(async () => jsonResponse({ status: 401, message: "Not authenticated." }, 401)) as unknown as typeof fetch;
    const zb2 = createClient("http://api.test", { fetch: failMock });
    zb2.authStore.save("tok", { id: "u1" });
    await expect(zb2.collection("users").revokeAllSessions()).rejects.toSatisfy(isZigbaseError);
    expect(zb2.authStore.token).toBe(null); // cleared in finally, like logout()
  });

  it("epoch-mode 404 surfaces as the standard ZigbaseError", async () => {
    const fetchMock = vi.fn(async () => jsonResponse({ status: 404, message: "Not found." }, 404)) as unknown as typeof fetch;
    const zb = createClient("http://api.test", { fetch: fetchMock });
    await expect(zb.collection("users").listSessions()).rejects.toMatchObject({ status: 404 });
  });
});
