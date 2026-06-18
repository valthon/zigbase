import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { startAppServer, DATING_BIN, type TestServer } from "./harness.js";
import { createClient } from "../codegen/dating/zbase.gen.js";

let server: TestServer;

beforeAll(async () => {
  server = await startAppServer({ bin: DATING_BIN });
});
afterAll(() => server?.stop());

describe("zb.rpc live (dating-server)", () => {
  it("GET with query input incl. an enum — messagesSearch echoes limit as count", async () => {
    const zb = createClient(server.url, { WebSocket: globalThis.WebSocket });
    const res = await zb.rpc.messagesSearch({ q: "hello", limit: 7, sort: "newest" });
    expect(res.count).toBe(7);
  });

  it("POST body input round-trips — winksSend echoes note back", async () => {
    const zb = createClient(server.url, { WebSocket: globalThis.WebSocket });
    const res = await zb.rpc.winksSend({ note: "hey", color: "green", sticker: null, tags: ["x"] });
    expect(res).toEqual({ ok: true, note: "hey" });
  });

  it("POST with path param — echoPing echoes :id as note", async () => {
    const zb = createClient(server.url, { WebSocket: globalThis.WebSocket });
    const res = await zb.rpc.echoPing({ id: "abc123" });
    expect(res.note).toBe("abc123");
  });

  it("RouteError (req.fail 400) rejects the promise — empty note triggers fail", async () => {
    const zb = createClient(server.url, { WebSocket: globalThis.WebSocket });
    await expect(
      zb.rpc.winksSend({ note: "", color: "red", sticker: null, tags: [] }),
    ).rejects.toThrow();
  });

  it("void output — winksStatus resolves to undefined", async () => {
    const zb = createClient(server.url, { WebSocket: globalThis.WebSocket });
    await expect(zb.rpc.winksStatus()).resolves.toBeUndefined();
  });
});
