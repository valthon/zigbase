import { describe, it, expect, vi } from "vitest";
import { createClient } from "../src/index.js";
import { withRealtime } from "../src/realtime-entry.js";
import { FakeWebSocketFactory } from "./support/fake-websocket.js";

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function qp(url: string): URLSearchParams {
  return new URL(url).searchParams;
}

describe("fields passthrough on cursor + live read paths", () => {
  it("getPage forwards fields to the wire query", async () => {
    const seen: string[] = [];
    const fetchMock = vi.fn(async (url: string) => {
      seen.push(qp(url).get("fields") ?? "");
      return jsonResponse({ page: 1, perPage: 3, totalItems: 0, totalPages: 0, items: [{ id: "a", created: 1 }] });
    }) as unknown as typeof fetch;

    const zb = createClient("http://api.test", { fetch: fetchMock });
    await zb.collection("posts").getPage({ limit: 2, sort: "-created", fields: "id,title" });
    expect(seen[0]).toBe("id,title");
  });

  it("iterate forwards fields on every batch", async () => {
    const seen: string[] = [];
    let call = 0;
    const fetchMock = vi.fn(async (url: string) => {
      seen.push(qp(url).get("fields") ?? "");
      // First page advertises a next cursor; second page ends the iteration.
      const body = call === 0
        ? { items: [{ id: "r1" }, { id: "r2" }], nextCursor: "TOK", prevCursor: null, hasNext: true, hasPrev: false }
        : { items: [{ id: "r3" }], nextCursor: null, prevCursor: "P", hasNext: false, hasPrev: true };
      call += 1;
      return jsonResponse({ page: 1, perPage: 2, ...body });
    }) as unknown as typeof fetch;

    const zb = createClient("http://api.test", { fetch: fetchMock });
    for await (const _ of zb.collection("posts").iterate({ sort: "-created", batch: 2, fields: "id" })) void _;
    expect(seen.length).toBeGreaterThan(1);
    expect(seen.every((f) => f === "id")).toBe(true);
  });

  it("getFullList forwards fields", async () => {
    const seen: string[] = [];
    const fetchMock = vi.fn(async (url: string) => {
      seen.push(qp(url).get("fields") ?? "");
      return jsonResponse({ page: 1, perPage: 100, totalItems: 0, totalPages: 0, items: [{ id: "a", created: 1 }] });
    }) as unknown as typeof fetch;

    const zb = createClient("http://api.test", { fetch: fetchMock });
    await zb.collection("posts").getFullList({ sort: "-created", fields: "id,slug" });
    expect(seen[0]).toBe("id,slug");
  });

  it("live getList forwards fields to the seed fetch", async () => {
    const factory = new FakeWebSocketFactory();
    const seen: string[] = [];
    const fetchMock = vi.fn(async (url: string) => {
      seen.push(qp(url).get("fields") ?? "");
      return jsonResponse({ page: 1, perPage: 30, totalItems: 0, totalPages: 0, items: [] });
    }) as unknown as typeof fetch;

    const zb = withRealtime(createClient("http://api.test", { fetch: fetchMock, WebSocket: factory.WebSocket }));
    const live = zb.realtime.collection("posts");
    const listPromise = live.getList(1, 30, { sort: "-created", fields: "id,title" });
    // Seed fetch resolves first, then buildList subscribes (constructing the WS).
    // Drive the ack once the socket exists so getList settles.
    await vi.waitFor(() => expect(factory.instances.length).toBeGreaterThan(0));
    const ws = factory.last;
    ws.emitOpen();
    ws.emitMessage({ type: "ack", action: "subscribe", topic: "posts" });
    await listPromise;
    expect(seen[0]).toBe("id,title");
  });
});
