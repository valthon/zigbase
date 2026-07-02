import { describe, it, expect, vi } from "vitest";
import { vectorSpec } from "../src/query.js";
import { createClient } from "../src/index.js";

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

describe("vectorSpec", () => {
  it("serializes to <field>[:metric]:<json-embedding>", () => {
    expect(vectorSpec({ field: "embedding", values: [0.12, 0.04] })).toBe("embedding:[0.12,0.04]");
    expect(vectorSpec({ field: "embedding", metric: "cosine", values: [1, 2] })).toBe(
      "embedding:cosine:[1,2]",
    );
    expect(vectorSpec({ field: "embedding", metric: "l2", values: [0.5] })).toBe("embedding:l2:[0.5]");
  });

  it("throws on non-finite values (same posture as filterValue)", () => {
    expect(() => vectorSpec({ field: "e", values: [Number.NaN] })).toThrow(/non-finite/);
    expect(() => vectorSpec({ field: "e", values: [Infinity] })).toThrow(/non-finite/);
  });
});

describe("search/vector list options", () => {
  it("getList forwards ?search= and compiled ?vector=", async () => {
    const fetchMock = vi.fn(async (url: string) => {
      const u = new URL(url);
      expect(u.searchParams.get("search")).toBe("zig database");
      expect(u.searchParams.get("vector")).toBe("embedding:cosine:[0.1,0.2]");
      return jsonResponse({ page: 1, perPage: 30, totalItems: 0, totalPages: 0, items: [] });
    }) as unknown as typeof fetch;
    const zb = createClient("http://api.test", { fetch: fetchMock });
    await zb.collection("docs").getList(1, 30, {
      search: "zig database",
      vector: { field: "embedding", metric: "cosine", values: [0.1, 0.2] },
    });
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it("getPage forwards ?search= (cursor mode supports search, not vector)", async () => {
    const fetchMock = vi.fn(async (url: string) => {
      const u = new URL(url);
      expect(u.searchParams.get("search")).toBe("hello");
      expect(u.searchParams.get("vector")).toBeNull();
      return jsonResponse({ items: [], nextCursor: null, prevCursor: null, hasNext: false, hasPrev: false });
    }) as unknown as typeof fetch;
    const zb = createClient("http://api.test", { fetch: fetchMock });
    await zb.collection("docs").getPage({ search: "hello", limit: 5 });
  });
});
