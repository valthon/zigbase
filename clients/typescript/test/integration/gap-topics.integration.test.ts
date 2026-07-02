import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { startAppServer, superuserToken, DATING_BIN, type TestServer } from "./harness.js";
import { createClient } from "../../src/index.js";
import { withRealtime, type TopicMessage } from "../../src/realtime-entry.js";

let server: TestServer;
let suToken: string;
beforeAll(async () => {
  server = await startAppServer({ bin: DATING_BIN });
  suToken = await superuserToken(server);
});
afterAll(() => server?.stop());

function waitFor(cond: () => boolean, timeoutMs = 8000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  return new Promise((resolve, reject) => {
    const tick = () => {
      if (cond()) return resolve();
      if (Date.now() > deadline) return reject(new Error("timeout waiting for condition"));
      setTimeout(tick, 25);
    };
    tick();
  });
}

describe("custom topics + __features (live, server >= 0.10.0 frames)", () => {
  it("receives both kinds from ctx.realtime().signal/.broadcast via the publish route", async () => {
    const zb = withRealtime(createClient(server.url, { WebSocket: globalThis.WebSocket }));
    const got: TopicMessage[] = [];
    const unsub = await zb.realtime.subscribeTopic("orders", (m) => got.push(m));

    await zb.send("POST", "/api/testing/publish", { body: { topic: "orders", note: "hi" } });
    await waitFor(() => got.length >= 2);

    expect(got).toContainEqual({ topic: "orders", kind: "signal" });
    const msg = got.find((m) => m.kind === "message");
    expect(msg?.data).toEqual({ note: "hi" });
    unsub();
  });

  it("a flag-override write emits the standard signal on __features", async () => {
    const zb = withRealtime(createClient(server.url, { WebSocket: globalThis.WebSocket }));
    const got: TopicMessage[] = [];
    await zb.realtime.subscribeTopic("__features", (m) => got.push(m));

    const res = await fetch(`${server.url}/api/settings/flag:device_link_v2`, {
      method: "PUT",
      headers: { "content-type": "application/json", Authorization: `Bearer ${suToken}` },
      body: JSON.stringify({ value: "true" }),
    });
    expect(res.ok).toBe(true);

    await waitFor(() => got.length >= 1);
    expect(got[0]).toEqual({ topic: "__features", kind: "signal" });
  });
});
