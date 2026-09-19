import { describe, it, expect, vi } from "vitest";
import { createClient } from "../fixtures/blog.gen.js";

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

// The transport builds query strings with URLSearchParams, which encodes spaces
// as `+` (x-www-form-urlencoded). decodeURIComponent leaves `+` intact, so swap
// it back to a space before asserting on the decoded filter.
function decodeQuery(url: string): string {
  return decodeURIComponent(url.replace(/\+/g, " "));
}

describe("blog.gen fixture wiring", () => {
  it("forwards explicit retry keys through the fixture mutation services", async () => {
    const fetchMock = vi.fn(async (_url: string, init?: RequestInit) => {
      expect(new Headers(init?.headers).get("Idempotency-Key")).toBe("logical-write");
      return init?.method === "DELETE" ? new Response(null, { status: 204 }) : jsonResponse({ id: "p1" });
    }) as unknown as typeof fetch;
    const zb = createClient("http://api.test", { fetch: fetchMock });
    const opts = { idempotencyKey: "logical-write" };
    await zb.db.posts.create({ title: "Hi" }, opts);
    await zb.db.posts.update("p1", { title: "Updated" }, opts);
    await zb.db.posts.delete("p1", opts);
    expect(fetchMock).toHaveBeenCalledTimes(3);
  });

  it("db.posts.getList compiles where -> filter and hits the records endpoint", async () => {
    const fetchMock = vi.fn(async (url: string) => {
      expect(url).toContain("/api/collections/posts/records");
      expect(decodeQuery(url)).toContain("filter=status = 'published'");
      return jsonResponse({ page: 1, perPage: 30, totalItems: 0, totalPages: 0, items: [] });
    }) as unknown as typeof fetch;

    const zb = createClient("http://api.test", { fetch: fetchMock });
    await zb.db.posts.getList({ where: { status: "published" } });
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it("files.url reads the stored filename off the record", () => {
    const zb = createClient("http://api.test", { fetch: (async () => new Response()) as unknown as typeof fetch });
    const url = zb.files.url(
      { id: "p1", cover: "pic.png" } as never,
      "cover",
    );
    expect(url).toBe("http://api.test/api/files/posts/p1/pic.png");
  });

  it("db.posts.filter builds an SP1 filter string", () => {
    const zb = createClient("http://api.test", { fetch: (async () => new Response()) as unknown as typeof fetch });
    expect(zb.db.posts.filter((f) => f.status.eq("published").or(f.price.gte(10)))).toBe(
      "(status = 'published' || price >= 10)",
    );
  });
});
