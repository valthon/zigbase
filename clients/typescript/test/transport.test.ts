import { describe, it, expect, vi } from "vitest";
import { Transport } from "../src/transport.js";
import { MemoryAuthStore } from "../src/auth-store.js";
import { isZigbaseError } from "../src/errors.js";

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function makeTransport(fetchImpl: typeof fetch, authStore = new MemoryAuthStore()) {
  return new Transport({
    baseUrl: "http://api.test",
    authStore,
    fetch: fetchImpl,
    autoRefresh: false,
    maxRetries: 0,
    sleep: async () => {},
  });
}

describe("Transport", () => {
  it("builds URL with query params and parses JSON", async () => {
    const fetchMock = vi.fn(async (url: string) => {
      expect(url).toBe("http://api.test/api/collections/posts/records?page=2&perPage=10");
      return jsonResponse({ items: [], page: 2 });
    }) as unknown as typeof fetch;
    const t = makeTransport(fetchMock);
    const out = await t.send<{ page: number }>("/api/collections/posts/records", {
      query: { page: 2, perPage: 10, expand: undefined },
    });
    expect(out.page).toBe(2);
  });

  it("attaches Bearer header when authenticated", async () => {
    const store = new MemoryAuthStore();
    store.save("tok.tok.tok", { id: "u1" });
    const fetchMock = vi.fn(async (_url: string, init: RequestInit) => {
      const headers = new Headers(init.headers);
      expect(headers.get("Authorization")).toBe("Bearer tok.tok.tok");
      return jsonResponse({ ok: true });
    }) as unknown as typeof fetch;
    await makeTransport(fetchMock, store).send("/api/health");
  });

  it("serializes a JSON body and sets content-type", async () => {
    const fetchMock = vi.fn(async (_url: string, init: RequestInit) => {
      const headers = new Headers(init.headers);
      expect(headers.get("content-type")).toContain("application/json");
      expect(init.body).toBe(JSON.stringify({ title: "hi" }));
      return jsonResponse({ id: "1" }, 201);
    }) as unknown as typeof fetch;
    await makeTransport(fetchMock).send("/api/collections/posts/records", {
      method: "POST",
      body: { title: "hi" },
    });
  });

  it("passes FormData through without a JSON content-type", async () => {
    const fd = new FormData();
    fd.set("title", "hi");
    const fetchMock = vi.fn(async (_url: string, init: RequestInit) => {
      const headers = new Headers(init.headers);
      expect(headers.get("content-type")).toBeNull();
      expect(init.body).toBe(fd);
      return jsonResponse({ id: "1" }, 201);
    }) as unknown as typeof fetch;
    await makeTransport(fetchMock).send("/api/collections/posts/records", {
      method: "POST",
      body: fd,
    });
  });

  it("returns undefined for 204 responses", async () => {
    const fetchMock = vi.fn(async () => new Response(null, { status: 204 })) as unknown as typeof fetch;
    const out = await makeTransport(fetchMock).send("/api/collections/posts/records/1", {
      method: "DELETE",
    });
    expect(out).toBeUndefined();
  });

  it("throws ZigbaseError on non-2xx", async () => {
    const fetchMock = vi.fn(async () =>
      jsonResponse({ code: 403, message: "Nope.", data: {} }, 403),
    ) as unknown as typeof fetch;
    await expect(makeTransport(fetchMock).send("/api/x")).rejects.toSatisfy(isZigbaseError);
  });
});
