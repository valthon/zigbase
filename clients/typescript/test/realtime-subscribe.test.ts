import { describe, it, expect, vi } from "vitest";
import { RealtimeService } from "../src/realtime.js";
import type { TopicMessage } from "../src/realtime.js";
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

  it("unsubscribe(topic, cb) removes a FILTERED subscription (no filter arg needed)", async () => {
    const { service, factory } = makeService();
    const cb = vi.fn();
    const subPromise = service.subscribe("posts", cb, { filter: "status = 'published'" });
    const ws = factory.last;
    ws.emitOpen();
    ws.emitMessage({ type: "ack", action: "subscribe", topic: "posts" });
    await subPromise;

    // Public path passes only (topic, cb) — it must still find and drop the
    // filtered subscription so delivery stops and an unsubscribe frame is sent.
    service.unsubscribe("posts", cb);

    ws.emitMessage({ type: "event", topic: "posts", action: "update", record: { id: "p1" } });
    expect(cb).not.toHaveBeenCalled();
    expect(ws.sentFrames).toContainEqual({ action: "unsubscribe", topic: "posts" });
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

  it("concurrent subscribes on an open socket send ONE subscribe frame before the ack", async () => {
    const { service, factory } = makeService();
    const cb1 = vi.fn();
    const cb2 = vi.fn();
    const p1 = service.subscribe("posts", cb1);
    const ws = factory.last;
    ws.emitOpen();
    // Second subscriber arrives while the first frame is still awaiting its ack.
    const p2 = service.subscribe("posts", cb2);

    const subFrames = ws.sentFrames.filter(
      (f) => (f as { action: string }).action === "subscribe",
    );
    expect(subFrames).toHaveLength(1);

    ws.emitMessage({ type: "ack", action: "subscribe", topic: "posts" });
    await Promise.all([p1, p2]); // the single ack resolves both waiters

    ws.emitMessage({ type: "event", topic: "posts", action: "update", record: { id: "p1" } });
    expect(cb1).toHaveBeenCalledTimes(1);
    expect(cb2).toHaveBeenCalledTimes(1);
  });
});

describe("RealtimeService.subscribeTopic", () => {
  it("subscribes with the standard frame and delivers signal + message frames by topic", async () => {
    const { service, factory } = makeService();
    const got: TopicMessage[] = [];
    const p = service.subscribeTopic("orders", (m) => got.push(m));
    const ws = factory.last;
    ws.emitOpen();
    expect(ws.sentFrames).toContainEqual({ action: "subscribe", topic: "orders" });
    ws.emitMessage({ type: "ack", action: "subscribe", topic: "orders" });
    await p;

    ws.emitMessage({ type: "signal", topic: "orders" });
    ws.emitMessage({ type: "message", topic: "orders", data: { n: 1 } });
    ws.emitMessage({ type: "message", topic: "other", data: { n: 2 } }); // other topic -> dropped
    ws.emitMessage({ type: "bogus", topic: "orders" }); // unknown type -> dropped
    ws.emitMessage({ type: "signal" }); // missing topic -> dropped

    expect(got).toEqual([
      { topic: "orders", kind: "signal" },
      { topic: "orders", kind: "message", data: { n: 1 } },
    ]);
  });

  it("topic frames do not reach record subscriptions (and record events do not reach topic subs)", async () => {
    const { service, factory } = makeService();
    const recordCb = vi.fn();
    const topicCb = vi.fn();
    const p1 = service.subscribe("posts", recordCb);
    const ws = factory.last;
    ws.emitOpen();
    ws.emitMessage({ type: "ack", action: "subscribe", topic: "posts" });
    await p1;
    const p2 = service.subscribeTopic("posts", topicCb); // same name, disjoint delivery
    ws.emitMessage({ type: "ack", action: "subscribe", topic: "posts" });
    await p2;

    ws.emitMessage({ type: "signal", topic: "posts" });
    ws.emitMessage({ type: "event", topic: "posts", action: "create", record: { id: "p1" } });
    expect(topicCb).toHaveBeenCalledTimes(1);
    expect(topicCb).toHaveBeenCalledWith({ topic: "posts", kind: "signal" });
    expect(recordCb).toHaveBeenCalledTimes(1); // only the event frame
  });

  it("unsubscribeTopic drops delivery and sends one unsubscribe frame when the topic empties", async () => {
    const { service, factory } = makeService();
    const cb = vi.fn();
    const p = service.subscribeTopic("orders", cb);
    const ws = factory.last;
    ws.emitOpen();
    ws.emitMessage({ type: "ack", action: "subscribe", topic: "orders" });
    await p;
    service.unsubscribeTopic("orders", cb);
    ws.emitMessage({ type: "signal", topic: "orders" });
    expect(cb).not.toHaveBeenCalled();
    expect(ws.sentFrames).toContainEqual({ action: "unsubscribe", topic: "orders" });
  });

  it("a server error frame rejects a pending subscribeTopic (non-canSubscribe topic)", async () => {
    const { service, factory } = makeService();
    const p = service.subscribeTopic("private", vi.fn());
    const ws = factory.last;
    ws.emitOpen();
    ws.emitMessage({ type: "error", message: "authentication required to subscribe" });
    await expect(p).rejects.toThrow("authentication required to subscribe");
  });

  it("topic subscriptions resubscribe after reconnect", async () => {
    const { service, factory } = makeService();
    const p = service.subscribeTopic("orders", vi.fn());
    const ws1 = factory.last;
    ws1.emitOpen();
    ws1.emitMessage({ type: "ack", action: "subscribe", topic: "orders" });
    await p;
    ws1.emitClose();
    // backoff sleep is a no-op in makeService; a new socket is created
    await Promise.resolve();
    const ws2 = factory.last;
    expect(ws2).not.toBe(ws1);
    ws2.emitOpen();
    expect(ws2.sentFrames).toContainEqual({ action: "subscribe", topic: "orders" });
  });

  it("concurrent subscribeTopic calls on an open socket send ONE subscribe frame; both callbacks deliver", async () => {
    const { service, factory } = makeService();
    const got1: TopicMessage[] = [];
    const got2: TopicMessage[] = [];
    const p1 = service.subscribeTopic("orders", (m) => got1.push(m));
    const ws = factory.last;
    ws.emitOpen();
    // Second subscriber arrives while the first frame is still awaiting its ack.
    const p2 = service.subscribeTopic("orders", (m) => got2.push(m));

    const subFrames = ws.sentFrames.filter(
      (f) => (f as { action: string }).action === "subscribe",
    );
    expect(subFrames).toHaveLength(1);

    ws.emitMessage({ type: "ack", action: "subscribe", topic: "orders" });
    await Promise.all([p1, p2]); // the single ack resolves both waiters

    ws.emitMessage({ type: "signal", topic: "orders" });
    expect(got1).toEqual([{ topic: "orders", kind: "signal" }]);
    expect(got2).toEqual([{ topic: "orders", kind: "signal" }]);
  });

  it("a rejected subscribe clears the in-flight guard so a retry re-sends the frame", async () => {
    const { service, factory } = makeService();
    const p1 = service.subscribeTopic("private", vi.fn());
    const ws = factory.last;
    ws.emitOpen();
    ws.emitMessage({ type: "error", message: "authentication required to subscribe" });
    await expect(p1).rejects.toThrow("authentication required to subscribe");

    const p2 = service.subscribeTopic("private", vi.fn());
    const subFrames = ws.sentFrames.filter(
      (f) => (f as { action: string }).action === "subscribe",
    );
    expect(subFrames).toHaveLength(2); // retry sent a fresh frame
    ws.emitMessage({ type: "ack", action: "subscribe", topic: "private" });
    await p2;
  });

  it("a record subscription's internal key never collides with a topic subscription's, even with adversarial topic/filter text", async () => {
    const { service, factory } = makeService();
    const recordCb = vi.fn();
    const topicCb = vi.fn();

    // Craft a record subscription whose (topic, filter) pair would have produced the
    // exact same internal Map key as `subscribeTopic("x")` under the old ` topic:${topic}`
    // scheme: subKey("", "topic:x") === " topic:x" === topicKey("x"). With disjoint `r:`/`t:`
    // prefixes these must land in two independent Map entries.
    const p1 = service.subscribe("", recordCb, { filter: "topic:x" });
    const ws = factory.last;
    ws.emitOpen();
    ws.emitMessage({ type: "ack", action: "subscribe", topic: "" });
    await p1;

    const p2 = service.subscribeTopic("x", topicCb);
    ws.emitMessage({ type: "ack", action: "subscribe", topic: "x" });
    await p2;

    // Both subscriptions are live simultaneously (no clobber on subscribe/set).
    expect(ws.sentFrames).toContainEqual({ action: "subscribe", topic: "", filter: "topic:x" });
    expect(ws.sentFrames).toContainEqual({ action: "subscribe", topic: "x" });

    // Deliveries stay isolated to their own callback.
    ws.emitMessage({ type: "event", topic: "", action: "create", record: { id: "r1" } });
    ws.emitMessage({ type: "signal", topic: "x" });
    expect(recordCb).toHaveBeenCalledTimes(1);
    expect(topicCb).toHaveBeenCalledTimes(1);
    expect(topicCb).toHaveBeenCalledWith({ topic: "x", kind: "signal" });

    // Unsubscribing the topic sub must not disturb the record sub (proves they're
    // independent Map entries, not one accidentally overwriting the other).
    service.unsubscribeTopic("x", topicCb);
    ws.emitMessage({ type: "event", topic: "", action: "update", record: { id: "r1" } });
    expect(recordCb).toHaveBeenCalledTimes(2);
  });
});
