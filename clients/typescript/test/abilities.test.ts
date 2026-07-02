import { describe, it, expect, vi } from "vitest";
import { createClient } from "../src/index.js";
import { isZigbaseError } from "../src/errors.js";

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

describe("getAbilities", () => {
  it("GETs /records/:id/abilities and parses the boolean set", async () => {
    const fetchMock = vi.fn(async (url: string, init?: RequestInit) => {
      expect(url).toBe("http://api.test/api/collections/notes/records/r%201/abilities");
      expect(init?.method ?? "GET").toBe("GET");
      return jsonResponse({ view: true, update: false, delete: false });
    }) as unknown as typeof fetch;
    const zb = createClient("http://api.test", { fetch: fetchMock });
    const ab = await zb.collection("notes").getAbilities("r 1");
    expect(ab).toEqual({ view: true, update: false, delete: false });
  });

  it("maps a non-viewable record to a 404 ZigbaseError", async () => {
    const fetchMock = vi.fn(async () =>
      jsonResponse({ status: 404, message: "Not found." }, 404),
    ) as unknown as typeof fetch;
    const zb = createClient("http://api.test", { fetch: fetchMock });
    try {
      await zb.collection("notes").getAbilities("ghost");
      expect.unreachable();
    } catch (e) {
      expect(isZigbaseError(e)).toBe(true);
      expect((e as { status: number }).status).toBe(404);
    }
  });
});
