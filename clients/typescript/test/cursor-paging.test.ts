import { describe, it, expect, vi } from "vitest";
import { createClient } from "../src/index.js";
import { decodeCursor } from "../src/cursor.js";

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

describe("cursor pagination", () => {
  it("getPage fetches limit+1, trims the extra, sets hasNext, and round-trips nextCursor", async () => {
    const fetchMock = vi.fn(async (url: string) => {
      const p = qp(url);
      expect(p.get("page")).toBe("1");
      expect(p.get("perPage")).toBe("3"); // limit(2) + 1
      expect(p.get("sort")).toBe("-created,-id"); // id tiebreaker follows last term (desc)
      // 3 rows returned -> there IS a next page
      return jsonResponse({
        page: 1,
        perPage: 3,
        totalItems: 0,
        totalPages: 0,
        items: [
          { id: "r1", created: 30 },
          { id: "r2", created: 20 },
          { id: "r3", created: 10 },
        ],
      });
    }) as unknown as typeof fetch;

    const zb = createClient("http://api.test", { fetch: fetchMock });
    const page = await zb.collection("posts").getPage({ limit: 2, sort: "-created" });

    expect(page.items.map((i) => i.id)).toEqual(["r1", "r2"]); // extra row trimmed
    expect(page.hasNext).toBe(true);
    expect(page.hasPrev).toBe(false);
    expect(page.nextCursor).not.toBeNull();

    // nextCursor encodes the LAST returned row's [created, id] under the effective sort
    const state = decodeCursor(page.nextCursor!, "-created,-id");
    expect(state.values).toEqual([20, "r2"]);
    expect(state.dir).toBe("next");
  });

  it("getPage on the next page applies the keyset predicate AND-ed with the user filter", async () => {
    let seenFilter: string | null = null;
    let call = 0;
    const fetchMock = vi.fn(async (url: string) => {
      call += 1;
      seenFilter = qp(url).get("filter");
      if (call === 1) {
        // page 1: user filter only, return limit+1 rows so a cursor is produced
        return jsonResponse({
          page: 1, perPage: 6, totalItems: 0, totalPages: 0,
          items: [
            { id: "r1", created: 30 }, { id: "r2", created: 20 },
            { id: "r3", created: 10 }, { id: "r4", created: 8 },
            { id: "r5", created: 6 }, { id: "r6", created: 4 },
          ],
        });
      }
      // page 2: short batch -> no further next
      return jsonResponse({
        page: 1, perPage: 6, totalItems: 0, totalPages: 0,
        items: [{ id: "r7", created: 2 }],
      });
    }) as unknown as typeof fetch;

    const zb = createClient("http://api.test", { fetch: fetchMock });
    const first = await zb.collection("posts").getPage({
      limit: 5, sort: "-created", filter: "status = 'published'",
    });
    expect(seenFilter).toBe("status = 'published'");

    const second = await zb.collection("posts").getPage({
      limit: 5, sort: "-created", filter: "status = 'published'", cursor: first.nextCursor!,
    });
    // filter must be (user) && (keyset); boundary row is r5/created=6 (last of trimmed page 1)
    expect(seenFilter).toContain("status = 'published'");
    expect(seenFilter).toContain("&&");
    expect(seenFilter).toMatch(/\(created < 6\)/);
    expect(seenFilter).toContain("id < 'r5'");
    expect(second.hasNext).toBe(false);
    expect(second.hasPrev).toBe(true);
  });

  it("getPage requests the count only when withTotal is set", async () => {
    const fetchMock = vi.fn(async (url: string) => {
      const p = qp(url);
      // withTotal omits skipTotal; otherwise skipTotal=1 is sent
      expect(p.get("skipTotal")).toBeNull();
      return jsonResponse({ page: 1, perPage: 3, totalItems: 42, totalPages: 14, items: [{ id: "a", created: 1 }] });
    }) as unknown as typeof fetch;
    const zb = createClient("http://api.test", { fetch: fetchMock });
    const page = await zb.collection("posts").getPage({ limit: 2, sort: "-created", withTotal: true });
    expect(page.totalItems).toBe(42);
  });

  it("getPage without withTotal sends skipTotal=1", async () => {
    const fetchMock = vi.fn(async (url: string) => {
      expect(qp(url).get("skipTotal")).toBe("1");
      return jsonResponse({ page: 1, perPage: 3, totalItems: 0, totalPages: 0, items: [{ id: "a", created: 1 }] });
    }) as unknown as typeof fetch;
    const zb = createClient("http://api.test", { fetch: fetchMock });
    const page = await zb.collection("posts").getPage({ limit: 2, sort: "-created" });
    expect(page.totalItems).toBeUndefined();
  });

  it("iterate yields every record across batches and stops on a short batch", async () => {
    const batches = [
      [
        { id: "r1", created: 30 },
        { id: "r2", created: 20 },
        { id: "r3", created: 10 }, // sentinel -> hasNext
      ],
      [
        { id: "r3b", created: 9 },
        { id: "r4", created: 5 }, // short -> last batch
      ],
    ];
    let call = 0;
    const fetchMock = vi.fn(async () => {
      const body = batches[call] ?? [];
      call += 1;
      return jsonResponse({ page: 1, perPage: 3, totalItems: 0, totalPages: 0, items: body });
    }) as unknown as typeof fetch;

    const zb = createClient("http://api.test", { fetch: fetchMock });
    const seen: string[] = [];
    for await (const rec of zb.collection("posts").iterate({ sort: "-created", batch: 2 })) {
      seen.push(rec.id as string);
    }
    // batch=2 -> fetch 3 each time; first batch trims sentinel -> r1,r2 ; second -> r3b,r4
    expect(seen).toEqual(["r1", "r2", "r3b", "r4"]);
    expect(call).toBe(2);
  });
});
