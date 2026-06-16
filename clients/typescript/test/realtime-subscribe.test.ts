import { describe, it, expect, vi } from "vitest";
import { RealtimeService } from "../src/realtime.js";
import { MemoryAuthStore } from "../src/auth-store.js";
import { FakeWebSocketFactory } from "./support/fake-websocket.js";

function makeService(factory = new FakeWebSocketFactory(), authStore = new MemoryAuthStore()) {
  const service = new RealtimeService({
    baseUrl: "http://api.test",
    authStore,
    WebSocket: factory.WebSocket,
    sleep: async () => {},
  });
  return { service, factory, authStore };
}

describe("RealtimeService.subscribe", () => {
  it("opens one WS to /api/realtime, sends a subscribe frame, resolves on ack", async () => {
    const { service, factory } = makeService();
    const cb = vi.fn();
    const subPromise = service.subscribe("posts", cb);

    // Lazy connect: a socket exists, but the subscribe frame is buffered until open.
    const ws = factory.last;
    expect(ws.url).toBe("ws://api.test/api/realtime");

    ws.emitOpen();
    ws.emitMessage({ type: "connect", clientId: "c1" });
    // After open (no token) the subscribe frame is flushed.
    expect(ws.sentFrames).toContainEqual({ action: "subscribe", topic: "posts" });

    ws.emitMessage({ type: "ack", action: "subscribe", topic: "posts" });
    const unsub = await subPromise;
    expect(typeof unsub).toBe("function");
  });

  it("dispatches event frames to the topic callback", async () => {
    const { service, factory } = makeService();
    const cb = vi.fn();
    const subPromise = service.subscribe("posts", cb);
    const ws = factory.last;
    ws.emitOpen();
    ws.emitMessage({ type: "ack", action: "subscribe", topic: "posts" });
    await subPromise;

    ws.emitMessage({
      type: "event",
      topic: "posts",
      action: "create",
      record: { id: "p1", title: "Hi" },
    });
    expect(cb).toHaveBeenCalledTimes(1);
    expect(cb.mock.calls[0]![0]).toEqual({
      topic: "posts",
      action: "create",
      record: { id: "p1", title: "Hi" },
    });
  });

  it("passes a filter through on the subscribe frame", async () => {
    const { service, factory } = makeService();
    const subPromise = service.subscribe("posts", vi.fn(), { filter: "status = 'published'" });
    const ws = factory.last;
    ws.emitOpen();
    expect(ws.sentFrames).toContainEqual({
      action: "subscribe",
      topic: "posts",
      filter: "status = 'published'",
    });
    ws.emitMessage({ type: "ack", action: "subscribe", topic: "posts" });
    await subPromise;
  });

  it("reuses one WS subscription frame for two callbacks on the same (topic, filter)", async () => {
    const { service, factory } = makeService();
    const cb1 = vi.fn();
    const cb2 = vi.fn();
    const p1 = service.subscribe("posts", cb1);
    const ws = factory.last;
    ws.emitOpen();
    ws.emitMessage({ type: "ack", action: "subscribe", topic: "posts" });
    await p1;

    const p2 = service.subscribe("posts", cb2);
    await p2; // resolves immediately — already subscribed
    const subFrames = ws.sentFrames.filter(
      (f) => (f as { action: string }).action === "subscribe",
    );
    expect(subFrames).toHaveLength(1);

    ws.emitMessage({ type: "event", topic: "posts", action: "update", record: { id: "p1" } });
    expect(cb1).toHaveBeenCalledTimes(1);
    expect(cb2).toHaveBeenCalledTimes(1);
  });
});
