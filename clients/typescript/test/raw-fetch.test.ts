import { describe, it, expect, vi } from "vitest";
import { createClient } from "../src/index.js";
import { MemoryAuthStore } from "../src/index.js";

describe("client.fetch — raw Response escape hatch", () => {
  it("returns the raw Response without JSON-parsing it (status + headers intact)", async () => {
    const fetchMock = vi.fn(async (url: string) => {
      expect(url).toBe("http://api.test/api/export.csv?format=csv");
      return new Response("id,name\n1,Ada\n", {
        status: 200,
        headers: { "content-type": "text/csv", "x-total": "1" },
      });
    }) as unknown as typeof fetch;

    const zb = createClient("http://api.test", { fetch: fetchMock });
    const res = await zb.fetch("GET", "/api/export.csv", { query: { format: "csv" } });

    expect(res).toBeInstanceOf(Response);
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toBe("text/csv");
    expect(res.headers.get("x-total")).toBe("1");
    expect(await res.text()).toBe("id,name\n1,Ada\n");
  });

  it("does NOT throw on a non-2xx response — returns it for the caller to inspect", async () => {
    const fetchMock = vi.fn(async () =>
      new Response("nope", { status: 418, headers: { "content-type": "text/plain" } }),
    ) as unknown as typeof fetch;
    const zb = createClient("http://api.test", { fetch: fetchMock });
    const res = await zb.fetch("GET", "/api/teapot");
    expect(res.status).toBe(418);
    expect(await res.text()).toBe("nope");
  });

  it("applies the auth header, body, and passes through the signal", async () => {
    const store = new MemoryAuthStore();
    store.save("tok.tok.tok", { id: "u1" });
    const fetchMock = vi.fn(async (_url: string, init: RequestInit) => {
      const headers = new Headers(init.headers);
      expect(headers.get("Authorization")).toBe("Bearer tok.tok.tok");
      expect(init.body).toBe(JSON.stringify({ a: 1 }));
      expect(init.signal).toBeInstanceOf(AbortSignal);
      return new Response("{}", { headers: { "content-type": "application/json" } });
    }) as unknown as typeof fetch;
    const zb = createClient("http://api.test", { fetch: fetchMock, authStore: store });
    const ctrl = new AbortController();
    await zb.fetch("POST", "/api/custom", { body: { a: 1 }, signal: ctrl.signal });
  });

  it("honors requestKey on the raw path", async () => {
    const releasers: Array<() => void> = [];
    const fetchMock = vi.fn((_url: string, init?: RequestInit) =>
      new Promise<Response>((resolve, reject) => {
        const signal = init?.signal;
        // Stay pending until released (mirrors a real in-flight request), so a
        // later keyed request can abort this one before it settles.
        releasers.push(() => resolve(new Response("ok")));
        signal?.addEventListener("abort", () => reject(new DOMException("Aborted", "AbortError")));
      }),
    ) as unknown as typeof fetch;
    const zb = createClient("http://api.test", { fetch: fetchMock });
    const first = zb.fetch("GET", "/api/x", { requestKey: "r" });
    const second = zb.fetch("GET", "/api/x", { requestKey: "r" });
    releasers[1]!(); // resolve the second (still-live) request
    await expect(first).rejects.toMatchObject({ name: "AbortError" });
    await expect(second).resolves.toBeInstanceOf(Response);
  });
});
