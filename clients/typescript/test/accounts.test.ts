import { describe, it, expect, vi } from "vitest";
import { createClient } from "../src/index.js";

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

describe("account scoping", () => {
  it("accountId option sends X-Account-Id on every request", async () => {
    const fetchMock = vi.fn(async (_url: string, init?: RequestInit) => {
      expect(new Headers(init?.headers).get("X-Account-Id")).toBe("acct1");
      return jsonResponse({ items: [], page: 1, perPage: 30, totalItems: 0, totalPages: 0 });
    }) as unknown as typeof fetch;
    const zb = createClient("http://api.test", { fetch: fetchMock, accountId: "acct1" });
    await zb.collection("notes").getList();
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it("per-request headers win over the baked-in accountId", async () => {
    const fetchMock = vi.fn(async (_url: string, init?: RequestInit) => {
      expect(new Headers(init?.headers).get("X-Account-Id")).toBe("override");
      return jsonResponse({ ok: true });
    }) as unknown as typeof fetch;
    const zb = createClient("http://api.test", { fetch: fetchMock, accountId: "acct1" });
    await zb.send("GET", "/api/health", { headers: { "X-Account-Id": "override" } });
  });

  it("withAccount builds a sibling client sharing the AuthStore", async () => {
    const seen: Array<string | null> = [];
    const fetchMock = vi.fn(async (url: string, init?: RequestInit) => {
      seen.push(new Headers(init?.headers).get("X-Account-Id"));
      if (String(url).includes("auth-with-password")) {
        return jsonResponse({ token: "tok1", record: { id: "u1" } });
      }
      return jsonResponse({ ok: true });
    }) as unknown as typeof fetch;
    const zb = createClient("http://api.test", { fetch: fetchMock });
    const scoped = zb.withAccount("acct9");
    // login through the SCOPED view updates the shared store...
    await scoped.collection("users").authWithPassword("a@b.c", "pw");
    expect(zb.authStore.token).toBe("tok1"); // ...visible on the original
    await zb.send("GET", "/x");
    await scoped.send("GET", "/x");
    expect(seen).toContain("acct9");
    // the unscoped view sent NO account header
    expect(seen.filter((h) => h === null).length).toBeGreaterThan(0);
  });

  it("accounts.activate POSTs /api/accounts/:id/activate and returns the scope", async () => {
    const fetchMock = vi.fn(async (url: string, init?: RequestInit) => {
      expect(url).toBe("http://api.test/api/accounts/a%2F1/activate");
      expect(init?.method).toBe("POST");
      return jsonResponse({ account: "a/1", role: "editor" });
    }) as unknown as typeof fetch;
    const zb = createClient("http://api.test", { fetch: fetchMock });
    const scope = await zb.accounts.activate("a/1");
    expect(scope).toEqual({ account: "a/1", role: "editor" });
  });
});
