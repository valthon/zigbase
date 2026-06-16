import { describe, it, expect, vi } from "vitest";
import { createClient } from "../src/index.js";
import { MemoryAuthStore } from "../src/index.js";

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

describe("createClient", () => {
  it("exposes baseUrl, authStore, collection(), and send()", async () => {
    const fetchMock = vi.fn(async (url: string) => {
      expect(url).toBe("http://api.test/api/health");
      return jsonResponse({ status: "ok" });
    }) as unknown as typeof fetch;

    const zb = createClient("http://api.test/", { fetch: fetchMock });
    expect(zb.baseUrl).toBe("http://api.test");
    expect(zb.authStore).toBeInstanceOf(MemoryAuthStore);
    expect(typeof zb.collection).toBe("function");

    const health = await zb.send<{ status: string }>("GET", "/api/health");
    expect(health.status).toBe("ok");
  });

  it("returns a CollectionService from collection()", () => {
    const zb = createClient("http://api.test", { fetch: (async () => new Response()) as unknown as typeof fetch });
    const posts = zb.collection("posts");
    expect(typeof posts.authWithPassword).toBe("function");
  });
});
