import { describe, it, expect, vi } from "vitest";
import { RealtimeService } from "../src/realtime.js";
import { MemoryAuthStore } from "../src/auth-store.js";
import { FakeWebSocketFactory } from "./support/fake-websocket.js";

function makeJwt(payload: Record<string, unknown>): string {
  const b64url = (o: unknown) => Buffer.from(JSON.stringify(o)).toString("base64url");
  return `${b64url({ alg: "HS256" })}.${b64url(payload)}.sig`;
}

const flush = () => new Promise<void>((r) => setTimeout(r, 0));

describe("RealtimeService reconnect", () => {
  it("on reconnect re-auths and resubscribes every active topic", async () => {
    const store = new MemoryAuthStore();
    store.save(makeJwt({ id: "u1", exp: 9999999999 }), { id: "u1" });
    const factory = new FakeWebSocketFactory();
    const service = new RealtimeService({
      baseUrl: "http://api.test",
      authStore: store,
      WebSocket: factory.WebSocket,
      sleep: async () => {}, // collapse backoff
    });

    const cb = vi.fn();
    const subPromise = service.subscribe("posts", cb);
    const ws1 = factory.last;
    ws1.emitOpen();
    ws1.emitMessage({ type: "auth", status: "ok" });
    await flush();
    ws1.emitMessage({ type: "ack", action: "subscribe", topic: "posts" });
    await subPromise;

    // Transport drop.
    ws1.emitClose();

    // A brand-new socket is created; wait a macrotask for the async reconnect.
    await flush();
    const ws2 = factory.last;
    expect(ws2).not.toBe(ws1);

    ws2.emitOpen();
    expect(ws2.sentFrames).toContainEqual({ action: "auth", token: store.token });
    ws2.emitMessage({ type: "auth", status: "ok" });
    await flush();
    expect(ws2.sentFrames).toContainEqual({ action: "subscribe", topic: "posts" });
    ws2.emitMessage({ type: "ack", action: "subscribe", topic: "posts" });

    // Dispatch still works on the new socket.
    ws2.emitMessage({ type: "event", topic: "posts", action: "create", record: { id: "p9" } });
    expect(cb).toHaveBeenCalledWith({ topic: "posts", action: "create", record: { id: "p9" } });
  });

  it("unsubscribe stops dispatch and sends unsubscribe when the last cb is removed", async () => {
    const factory = new FakeWebSocketFactory();
    const service = new RealtimeService({
      baseUrl: "http://api.test",
      authStore: new MemoryAuthStore(),
      WebSocket: factory.WebSocket,
      sleep: async () => {},
    });
    const cb = vi.fn();
    const subPromise = service.subscribe("posts", cb);
    const ws = factory.last;
    ws.emitOpen();
    ws.emitMessage({ type: "ack", action: "subscribe", topic: "posts" });
    const unsub = await subPromise;

    unsub();
    expect(ws.sentFrames).toContainEqual({ action: "unsubscribe", topic: "posts" });
    ws.emitMessage({ type: "event", topic: "posts", action: "create", record: { id: "p1" } });
    expect(cb).not.toHaveBeenCalled();
  });

  it("keeps the subscription while a second cb remains, only unsubscribing at zero", async () => {
    const factory = new FakeWebSocketFactory();
    const service = new RealtimeService({
      baseUrl: "http://api.test",
      authStore: new MemoryAuthStore(),
      WebSocket: factory.WebSocket,
      sleep: async () => {},
    });
    const cb1 = vi.fn();
    const cb2 = vi.fn();
    const p1 = service.subscribe("posts", cb1);
    const ws = factory.last;
    ws.emitOpen();
    ws.emitMessage({ type: "ack", action: "subscribe", topic: "posts" });
    const unsub1 = await p1;
    await service.subscribe("posts", cb2);

    unsub1();
    const unsubFrames = ws.sentFrames.filter(
      (f) => (f as { action: string }).action === "unsubscribe",
    );
    expect(unsubFrames).toHaveLength(0); // cb2 still present
    ws.emitMessage({ type: "event", topic: "posts", action: "update", record: { id: "p1" } });
    expect(cb2).toHaveBeenCalledTimes(1);
  });

  it("recovers when the WebSocket constructor throws synchronously on first connect", async () => {
    const good = new FakeWebSocketFactory();
    let throwNext = true;
    // A factory that throws synchronously on the first construction, then
    // delegates to a real FakeWebSocket so a later attempt can succeed.
    const FlakyWebSocket = function (this: unknown, url: string) {
      if (throwNext) {
        throwNext = false;
        throw new Error("invalid URL / blocked by env policy");
      }
      return new good.WebSocket(url);
    } as unknown as typeof WebSocket;

    const onError = vi.fn();
    const service = new RealtimeService({
      baseUrl: "http://api.test",
      authStore: new MemoryAuthStore(),
      WebSocket: FlakyWebSocket,
      sleep: async () => {}, // collapse backoff
      onError,
    });

    const cb = vi.fn();
    // First subscribe triggers a connect that throws synchronously. The service
    // must reset `connecting` and schedule a reconnect rather than locking up.
    const subPromise = service.subscribe("posts", cb);
    await flush();

    // The scheduled reconnect built a real socket; drive it to readiness.
    const ws = good.last;
    ws.emitOpen();
    ws.emitMessage({ type: "ack", action: "subscribe", topic: "posts" });
    await subPromise;

    // Dispatch works on the recovered socket.
    ws.emitMessage({ type: "event", topic: "posts", action: "create", record: { id: "p1" } });
    expect(cb).toHaveBeenCalledWith({ topic: "posts", action: "create", record: { id: "p1" } });
  });

  it("rejects a pending subscribe and calls onError on a server error frame", async () => {
    const onError = vi.fn();
    const factory = new FakeWebSocketFactory();
    const service = new RealtimeService({
      baseUrl: "http://api.test",
      authStore: new MemoryAuthStore(),
      WebSocket: factory.WebSocket,
      sleep: async () => {},
      onError,
    });
    const subPromise = service.subscribe("private_posts", vi.fn());
    const ws = factory.last;
    ws.emitOpen();
    ws.emitMessage({ type: "error", message: "anonymous subscription not allowed" });

    await expect(subPromise).rejects.toThrow(/anonymous subscription not allowed/);
    expect(onError).toHaveBeenCalledWith("anonymous subscription not allowed");
  });

  it("a rejected subscribe is dropped so a later reconnect never re-subscribes it", async () => {
    const factory = new FakeWebSocketFactory();
    const service = new RealtimeService({
      baseUrl: "http://api.test",
      authStore: new MemoryAuthStore(),
      WebSocket: factory.WebSocket,
      sleep: async () => {},
    });
    // A good subscription keeps the socket alive across the reconnect.
    const good = service.subscribe("posts", vi.fn());
    const ws1 = factory.last;
    ws1.emitOpen();
    ws1.emitMessage({ type: "ack", action: "subscribe", topic: "posts" });
    await good;

    // A second subscribe the server rejects.
    const bad = service.subscribe("private", vi.fn());
    ws1.emitMessage({ type: "error", message: "not allowed" });
    await expect(bad).rejects.toThrow("not allowed");

    // Transport drop -> reconnect resubscribes only the surviving topics.
    ws1.emitClose();
    await flush();
    const ws2 = factory.last;
    expect(ws2).not.toBe(ws1);
    ws2.emitOpen();

    const resubscribed = ws2.sentFrames.filter(
      (f) => (f as { action: string }).action === "subscribe",
    ) as Array<{ topic: string }>;
    expect(resubscribed.map((f) => f.topic)).toEqual(["posts"]); // NOT "private"
  });

  it("a subscribe during the reconnect backoff does not open a second socket", async () => {
    // A gated sleep holds the backoff open so we can inject a subscribe mid-sleep.
    let releaseSleep!: () => void;
    const sleepGate = new Promise<void>((r) => {
      releaseSleep = r;
    });
    const factory = new FakeWebSocketFactory();
    const service = new RealtimeService({
      baseUrl: "http://api.test",
      authStore: new MemoryAuthStore(),
      WebSocket: factory.WebSocket,
      sleep: () => sleepGate,
    });
    const p1 = service.subscribe("posts", vi.fn());
    const ws1 = factory.last;
    ws1.emitOpen();
    ws1.emitMessage({ type: "ack", action: "subscribe", topic: "posts" });
    await p1;
    expect(factory.instances).toHaveLength(1);

    // Drop -> schedules a reconnect that is now parked on the gated sleep.
    ws1.emitClose();
    await flush();
    // A fresh subscribe arrives while the reconnect is still sleeping.
    const p2 = service.subscribe("comments", vi.fn());
    // No competing socket must have been constructed.
    expect(factory.instances).toHaveLength(1);

    // Release the backoff; the reconnect loop opens EXACTLY one new socket.
    releaseSleep();
    await flush();
    expect(factory.instances).toHaveLength(2);
    const ws2 = factory.last;
    ws2.emitOpen();
    ws2.emitMessage({ type: "ack", action: "subscribe", topic: "posts" });
    ws2.emitMessage({ type: "ack", action: "subscribe", topic: "comments" });
    await p2;
  });
});

describe("RealtimeService post-close lifecycle", () => {
  function makeService() {
    const factory = new FakeWebSocketFactory();
    const service = new RealtimeService({
      baseUrl: "http://api.test",
      authStore: new MemoryAuthStore(),
      WebSocket: factory.WebSocket,
      sleep: async () => {},
    });
    return { service, factory };
  }

  it("subscribe() after close() throws instead of opening a socket", async () => {
    const { service, factory } = makeService();
    service.close();
    await expect(service.subscribe("posts", vi.fn())).rejects.toThrow("closed");
    expect(factory.instances).toHaveLength(0);
  });

  it("subscribeTopic() after close() throws instead of opening a socket", async () => {
    const { service, factory } = makeService();
    service.close();
    await expect(service.subscribeTopic("orders", vi.fn())).rejects.toThrow("closed");
    expect(factory.instances).toHaveLength(0);
  });

  it("close() rejects a still-pending subscribe rather than leaving it dangling", async () => {
    const { service, factory } = makeService();
    const p = service.subscribe("posts", vi.fn());
    factory.last.emitOpen(); // frame sent, awaiting an ack that never comes
    service.close();
    await expect(p).rejects.toThrow("closed");
  });

  it("close() during an in-flight connect cannot wedge the flags or resurrect the socket", async () => {
    const { service, factory } = makeService();
    const p = service.subscribe("posts", vi.fn()); // constructs a socket, not yet open
    const ws1 = factory.last;
    service.close();
    await expect(p).rejects.toThrow("closed");

    // The stale socket opening after close() must be ignored: no frames sent,
    // no state resurrected.
    ws1.emitOpen();
    expect(ws1.sentFrames).toHaveLength(0);

    // A later subscribe still throws (the service stays closed) and opens no
    // new socket — proving `connecting` was not left wedged.
    await expect(service.subscribe("posts", vi.fn())).rejects.toThrow("closed");
    expect(factory.instances).toHaveLength(1);
  });
});
