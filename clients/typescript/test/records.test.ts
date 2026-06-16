import { describe, it, expect, vi } from "vitest";
import { createClient } from "../src/index.js";
import { isZigbaseError } from "../src/errors.js";
import { hasBlob } from "../src/records.js";

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

describe("record CRUD", () => {
  it("getList builds the records URL with page/perPage/filter/sort and parses the envelope", async () => {
    const fetchMock = vi.fn(async (url: string) => {
      expect(url).toBe(
        "http://api.test/api/collections/posts/records?page=2&perPage=10&filter=status+%3D+%27x%27&sort=-created",
      );
      return jsonResponse({ page: 2, perPage: 10, totalItems: 12, totalPages: 2, items: [{ id: "a" }] });
    }) as unknown as typeof fetch;

    const zb = createClient("http://api.test", { fetch: fetchMock });
    const out = await zb.collection("posts").getList(2, 10, { filter: "status = 'x'", sort: "-created" });
    expect(out.totalItems).toBe(12);
    expect(out.items[0]?.id).toBe("a");
  });

  it("getList clamps perPage to the server max of 500", async () => {
    const fetchMock = vi.fn(async (url: string) => {
      expect(url).toContain("perPage=500");
      return jsonResponse({ page: 1, perPage: 500, totalItems: 0, totalPages: 0, items: [] });
    }) as unknown as typeof fetch;
    const zb = createClient("http://api.test", { fetch: fetchMock });
    await zb.collection("posts").getList(1, 9999);
  });

  it("getOne fetches a single record with expand", async () => {
    const fetchMock = vi.fn(async (url: string) => {
      expect(url).toBe("http://api.test/api/collections/posts/records/abc?expand=author");
      return jsonResponse({ id: "abc", title: "Hi" });
    }) as unknown as typeof fetch;
    const zb = createClient("http://api.test", { fetch: fetchMock });
    const out = await zb.collection("posts").getOne("abc", { expand: "author" });
    expect(out.id).toBe("abc");
  });

  it("getFirstListItem returns the first match", async () => {
    const fetchMock = vi.fn(async (url: string) => {
      expect(url).toContain("page=1");
      expect(url).toContain("perPage=1");
      return jsonResponse({ page: 1, perPage: 1, totalItems: 1, totalPages: 1, items: [{ id: "f1" }] });
    }) as unknown as typeof fetch;
    const zb = createClient("http://api.test", { fetch: fetchMock });
    const out = await zb.collection("posts").getFirstListItem("status = 'x'");
    expect(out.id).toBe("f1");
  });

  it("getFirstListItem throws a 404 ZigbaseError when empty", async () => {
    const fetchMock = vi.fn(async () =>
      jsonResponse({ page: 1, perPage: 1, totalItems: 0, totalPages: 0, items: [] }),
    ) as unknown as typeof fetch;
    const zb = createClient("http://api.test", { fetch: fetchMock });
    await expect(zb.collection("posts").getFirstListItem("status = 'none'")).rejects.toSatisfy(
      (e: unknown) => isZigbaseError(e) && (e as { status: number }).status === 404,
    );
  });

  it("create sends a JSON body and returns the 201 record", async () => {
    const fetchMock = vi.fn(async (url: string, init: RequestInit) => {
      expect(url).toBe("http://api.test/api/collections/posts/records");
      expect(init.method).toBe("POST");
      expect(JSON.parse(init.body as string)).toEqual({ title: "Hi" });
      return jsonResponse({ id: "new1", title: "Hi" }, 201);
    }) as unknown as typeof fetch;
    const zb = createClient("http://api.test", { fetch: fetchMock });
    const out = await zb.collection("posts").create({ title: "Hi" });
    expect(out.id).toBe("new1");
  });

  it("create auto-switches to multipart when a Blob is present", async () => {
    expect(hasBlob({ title: "Hi", file: new Blob(["x"]) })).toBe(true);
    const fetchMock = vi.fn(async (_url: string, init: RequestInit) => {
      expect(init.body).toBeInstanceOf(FormData);
      const headers = new Headers(init.headers);
      // transport must NOT set a JSON content-type for FormData (Plan 1 behavior)
      expect(headers.get("content-type")).toBeNull();
      return jsonResponse({ id: "up1" }, 201);
    }) as unknown as typeof fetch;
    const zb = createClient("http://api.test", { fetch: fetchMock });
    const out = await zb.collection("posts").create({ title: "Hi", file: new Blob(["x"]) });
    expect(out.id).toBe("up1");
  });

  it("update PATCHes and returns the record", async () => {
    const fetchMock = vi.fn(async (url: string, init: RequestInit) => {
      expect(url).toBe("http://api.test/api/collections/posts/records/x1");
      expect(init.method).toBe("PATCH");
      return jsonResponse({ id: "x1", title: "Edited" });
    }) as unknown as typeof fetch;
    const zb = createClient("http://api.test", { fetch: fetchMock });
    const out = await zb.collection("posts").update("x1", { title: "Edited" });
    expect(out.title).toBe("Edited");
  });

  it("delete sends DELETE and resolves void on 204", async () => {
    const fetchMock = vi.fn(async (url: string, init: RequestInit) => {
      expect(url).toBe("http://api.test/api/collections/posts/records/x1");
      expect(init.method).toBe("DELETE");
      return new Response(null, { status: 204 });
    }) as unknown as typeof fetch;
    const zb = createClient("http://api.test", { fetch: fetchMock });
    await expect(zb.collection("posts").delete("x1")).resolves.toBeUndefined();
  });
});
