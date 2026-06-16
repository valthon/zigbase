import { describe, it, expect, vi } from "vitest";
import { createClient } from "../src/index.js";

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

/** Parse the query out of a records URL for assertions. */
function qp(url: string): URLSearchParams {
  return new URL(url).searchParams;
}

describe("native cursor pagination", () => {
  it("getPage sends limit (no cursor on the first page) and returns the server fields", async () => {
    const fetchMock = vi.fn(async (url: string) => {
      const p = qp(url);
      expect(p.get("limit")).toBe("2");
      expect(p.get("cursor")).toBeNull(); // first page omits the token
      expect(p.get("skipTotal")).toBeNull(); // default: server skips totals
      expect(p.get("sort")).toBe("-created"); // forwarded verbatim, no id tiebreaker
      expect(p.get("page")).toBeNull(); // cursor mode, not offset
      expect(p.get("perPage")).toBeNull();
      return jsonResponse({
        page: 1,
        perPage: 2,
        items: [
          { id: "r1", created: 30 },
          { id: "r2", created: 20 },
        ],
        nextCursor: "TOKEN_NEXT",
        prevCursor: null,
        hasNext: true,
        hasPrev: false,
      });
    }) as unknown as typeof fetch;

    const zb = createClient("http://api.test", { fetch: fetchMock });
    const page = await zb.collection("posts").getPage({ limit: 2, sort: "-created" });

    expect(page.items.map((i) => i.id)).toEqual(["r1", "r2"]);
    expect(page.nextCursor).toBe("TOKEN_NEXT"); // server token forwarded verbatim
    expect(page.prevCursor).toBeNull();
    expect(page.hasNext).toBe(true);
    expect(page.hasPrev).toBe(false);
    expect(page.totalItems).toBeUndefined();
  });

  it("getPage forwards the opaque cursor token on a subsequent page", async () => {
    let seenCursor: string | null = null;
    const fetchMock = vi.fn(async (url: string) => {
      seenCursor = qp(url).get("cursor");
      return jsonResponse({
        page: 1, perPage: 2,
        items: [{ id: "r3", created: 10 }],
        nextCursor: null, prevCursor: "PREV_TOK", hasNext: false, hasPrev: true,
      });
    }) as unknown as typeof fetch;

    const zb = createClient("http://api.test", { fetch: fetchMock });
    const page = await zb.collection("posts").getPage({
      limit: 2, sort: "-created", cursor: "OPAQUE_TOKEN_FROM_SERVER",
    });
    // The token is sent back exactly as the server minted it (no decode/re-encode).
    expect(seenCursor).toBe("OPAQUE_TOKEN_FROM_SERVER");
    expect(page.hasNext).toBe(false);
    expect(page.hasPrev).toBe(true);
    expect(page.prevCursor).toBe("PREV_TOK");
  });

  it("an empty cursor string is treated as the first page (token omitted)", async () => {
    const fetchMock = vi.fn(async (url: string) => {
      expect(qp(url).get("cursor")).toBeNull();
      return jsonResponse({ page: 1, perPage: 2, items: [], nextCursor: null, prevCursor: null, hasNext: false, hasPrev: false });
    }) as unknown as typeof fetch;
    const zb = createClient("http://api.test", { fetch: fetchMock });
    await zb.collection("posts").getPage({ limit: 2, cursor: "" });
  });

  it("withTotal sends skipTotal=false and surfaces totalItems", async () => {
    const fetchMock = vi.fn(async (url: string) => {
      expect(qp(url).get("skipTotal")).toBe("false");
      return jsonResponse({
        page: 1, perPage: 2, totalItems: 42, totalPages: 21,
        items: [{ id: "a", created: 1 }],
        nextCursor: "N", prevCursor: null, hasNext: true, hasPrev: false,
      });
    }) as unknown as typeof fetch;
    const zb = createClient("http://api.test", { fetch: fetchMock });
    const page = await zb.collection("posts").getPage({ limit: 2, sort: "-created", withTotal: true });
    expect(page.totalItems).toBe(42);
  });

  it("getPage defaults limit to 30 when omitted", async () => {
    const fetchMock = vi.fn(async (url: string) => {
      expect(qp(url).get("limit")).toBe("30");
      return jsonResponse({ page: 1, perPage: 30, items: [], nextCursor: null, prevCursor: null, hasNext: false, hasPrev: false });
    }) as unknown as typeof fetch;
    const zb = createClient("http://api.test", { fetch: fetchMock });
    await zb.collection("posts").getPage();
  });

  it("iterate follows nextCursor until hasNext is false", async () => {
    const pages = [
      {
        items: [{ id: "r1", created: 30 }, { id: "r2", created: 20 }],
        nextCursor: "TOK1", prevCursor: null, hasNext: true, hasPrev: false,
      },
      {
        items: [{ id: "r3", created: 10 }, { id: "r4", created: 5 }],
        nextCursor: "TOK2", prevCursor: "P", hasNext: true, hasPrev: true,
      },
      {
        items: [{ id: "r5", created: 1 }],
        nextCursor: null, prevCursor: "P2", hasNext: false, hasPrev: true,
      },
    ];
    const seenCursors: (string | null)[] = [];
    let call = 0;
    const fetchMock = vi.fn(async (url: string) => {
      seenCursors.push(qp(url).get("cursor"));
      const body = pages[call]!;
      call += 1;
      return jsonResponse({ page: 1, perPage: 2, ...body });
    }) as unknown as typeof fetch;

    const zb = createClient("http://api.test", { fetch: fetchMock });
    const seen: string[] = [];
    for await (const rec of zb.collection("posts").iterate({ sort: "-created", batch: 2 })) {
      seen.push(rec.id as string);
    }
    expect(seen).toEqual(["r1", "r2", "r3", "r4", "r5"]);
    // first page: no cursor; then it forwards the server's tokens in order.
    expect(seenCursors).toEqual([null, "TOK1", "TOK2"]);
    expect(call).toBe(3);
  });

  it("getFullList accumulates every record across cursor pages", async () => {
    const pages = [
      { items: [{ id: "a" }, { id: "b" }], nextCursor: "T", prevCursor: null, hasNext: true, hasPrev: false },
      { items: [{ id: "c" }], nextCursor: null, prevCursor: "P", hasNext: false, hasPrev: true },
    ];
    let call = 0;
    const fetchMock = vi.fn(async () => {
      const body = pages[call]!;
      call += 1;
      return jsonResponse({ page: 1, perPage: 2, ...body });
    }) as unknown as typeof fetch;
    const zb = createClient("http://api.test", { fetch: fetchMock });
    const all = await zb.collection("posts").getFullList({ sort: "-created", batch: 2 });
    expect(all.map((r) => r.id)).toEqual(["a", "b", "c"]);
  });
});
