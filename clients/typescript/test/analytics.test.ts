import { describe, it, expect, vi } from "vitest";
import { createClient } from "../src/index.js";

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

describe("analytics", () => {
  it("events() maps name/actor/since/limit query params (Date -> ISO)", async () => {
    const fetchMock = vi.fn(async (url: string) => {
      const u = new URL(url);
      expect(u.pathname).toBe("/api/analytics/events");
      expect(u.searchParams.get("name")).toBe("user.signup");
      expect(u.searchParams.get("actor")).toBe("u1");
      expect(u.searchParams.get("since")).toBe("2026-01-02T03:04:05.000Z");
      expect(u.searchParams.get("limit")).toBe("10");
      return jsonResponse({ items: [] });
    }) as unknown as typeof fetch;
    const zb = createClient("http://api.test", { fetch: fetchMock });
    const out = await zb.analytics.events({
      name: "user.signup",
      actor: "u1",
      since: new Date("2026-01-02T03:04:05Z"),
      limit: 10,
    });
    expect(out.items).toEqual([]);
  });

  it("rollup() hits /api/analytics/rollups/:name with from/to (name URL-encoded)", async () => {
    const fetchMock = vi.fn(async (url: string) => {
      const u = new URL(url);
      expect(u.pathname).toBe("/api/analytics/rollups/signups%20daily");
      expect(u.searchParams.get("from")).toBe("2026-01-01");
      expect(u.searchParams.get("to")).toBe("2026-02-01");
      return jsonResponse({ items: [{ bucket: "2026-01-01", account: "a", actor: "", value: 3, computed_at: "x" }] });
    }) as unknown as typeof fetch;
    const zb = createClient("http://api.test", { fetch: fetchMock });
    const out = await zb.analytics.rollup("signups daily", { from: "2026-01-01", to: "2026-02-01" });
    expect(out.items[0]?.value).toBe(3);
  });
});
