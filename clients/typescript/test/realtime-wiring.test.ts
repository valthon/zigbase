import { describe, it, expect, vi } from "vitest";
import { createClient } from "../src/index.js";
import { withRealtime } from "../src/realtime-entry.js";
import { FakeWebSocketFactory } from "./support/fake-websocket.js";

describe("zb.realtime wiring", () => {
  it("lazily constructs a RealtimeService using the injected WebSocket", async () => {
    const factory = new FakeWebSocketFactory();
    const zb = withRealtime(createClient("http://api.test", {
      fetch: (async () => new Response("{}")) as unknown as typeof fetch,
      WebSocket: factory.WebSocket,
    }));

    // No socket until the first subscribe.
    expect(factory.instances).toHaveLength(0);

    const cb = vi.fn();
    const subPromise = zb.realtime.subscribe("posts", cb);
    const ws = factory.last;
    expect(ws.url).toBe("ws://api.test/api/realtime");

    ws.emitOpen();
    ws.emitMessage({ type: "ack", action: "subscribe", topic: "posts" });
    await subPromise;

    ws.emitMessage({ type: "event", topic: "posts", action: "create", record: { id: "p1" } });
    expect(cb).toHaveBeenCalledTimes(1);
  });

  it("realtime.collection(name) returns a LiveCollection backed by the same client", () => {
    const factory = new FakeWebSocketFactory();
    const zb = withRealtime(createClient("http://api.test", {
      fetch: (async () => new Response("{}")) as unknown as typeof fetch,
      WebSocket: factory.WebSocket,
    }));
    const live = zb.realtime.collection("posts");
    expect(live.name).toBe("posts");
    expect(typeof live.getOne).toBe("function");
    expect(typeof live.getList).toBe("function");
  });

  it("returns the SAME realtime accessor across reads (one shared socket)", () => {
    const factory = new FakeWebSocketFactory();
    const zb = withRealtime(createClient("http://api.test", {
      fetch: (async () => new Response("{}")) as unknown as typeof fetch,
      WebSocket: factory.WebSocket,
    }));
    expect(zb.realtime).toBe(zb.realtime);
  });
});
