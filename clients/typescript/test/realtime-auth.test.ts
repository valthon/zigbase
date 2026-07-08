import { describe, it, expect, vi } from "vitest";
import { RealtimeService } from "../src/realtime.js";
import { MemoryAuthStore } from "../src/auth-store.js";
import { FakeWebSocketFactory } from "./support/fake-websocket.js";

function makeJwt(payload: Record<string, unknown>): string {
  const b64url = (o: unknown) => Buffer.from(JSON.stringify(o)).toString("base64url");
  return `${b64url({ alg: "HS256" })}.${b64url(payload)}.sig`;
}

function makeService(authStore = new MemoryAuthStore()) {
  const factory = new FakeWebSocketFactory();
  const service = new RealtimeService({
    baseUrl: "http://api.test",
    authStore,
    WebSocket: factory.WebSocket,
    sleep: async () => {},
  });
  return { service, factory, authStore };
}

describe("RealtimeService auth", () => {
  it("sends an auth frame on open when a token is present, before subscribe", async () => {
    const store = new MemoryAuthStore();
    store.save(makeJwt({ id: "u1", exp: 9999999999 }), { id: "u1" });
    const { service, factory } = makeService(store);

    const subPromise = service.subscribe("posts", vi.fn());
    const ws = factory.last;
    ws.emitOpen();

    // auth precedes subscribe in the frame order.
    const authFrame = ws.sentFrames.find((f) => (f as { action: string }).action === "auth");
    expect(authFrame).toEqual({ action: "auth", token: store.token });

    // subscribe is only flushed after auth ok.
    ws.emitMessage({ type: "auth", status: "ok" });
    // Allow the auth-ack microtask chain to flush the gated subscribe frame.
    await new Promise<void>((r) => setTimeout(r, 0));
    expect(ws.sentFrames).toContainEqual({ action: "subscribe", topic: "posts" });
    ws.emitMessage({ type: "ack", action: "subscribe", topic: "posts" });
    await subPromise;
  });

  it("does not send an auth frame when anonymous", async () => {
    const { service, factory } = makeService();
    service.subscribe("public_posts", vi.fn());
    const ws = factory.last;
    ws.emitOpen();
    const authFrame = ws.sentFrames.find((f) => (f as { action: string }).action === "auth");
    expect(authFrame).toBeUndefined();
  });

  it("re-sends auth when the token changes while connected", async () => {
    const store = new MemoryAuthStore();
    const { service, factory } = makeService(store);
    const subPromise = service.subscribe("posts", vi.fn());
    const ws = factory.last;
    ws.emitOpen();
    ws.emitMessage({ type: "ack", action: "subscribe", topic: "posts" });
    await subPromise;

    const token = makeJwt({ id: "u1", exp: 9999999999 });
    store.save(token, { id: "u1" });
    expect(ws.sentFrames).toContainEqual({ action: "auth", token });
  });

  it("logout while connected sends an empty-token de-auth frame", async () => {
    // Track unhandled rejections: the auth-error response to the de-auth frame
    // must be swallowed, never surfaced.
    const rejections: unknown[] = [];
    const onRejection = (r: unknown) => rejections.push(r);
    process.on("unhandledRejection", onRejection);
    try {
      const store = new MemoryAuthStore();
      store.save(makeJwt({ id: "u1", exp: 9999999999 }), { id: "u1" });
      const { service, factory } = makeService(store);
      const events: unknown[] = [];
      const subPromise = service.subscribe("posts", (e) => events.push(e));
      const ws = factory.last;
      ws.emitOpen();
      // Authenticate + ack the subscription.
      ws.emitMessage({ type: "auth", status: "ok" });
      await new Promise<void>((r) => setTimeout(r, 0));
      ws.emitMessage({ type: "ack", action: "subscribe", topic: "posts" });
      await subPromise;

      // Logout: the connection must be de-authed server-side via an empty token
      // (the server keeps the subscriptions; only the identity is cleared).
      store.clear();
      expect(ws.sentFrames).toContainEqual({ action: "auth", token: "" });

      // The server rejects the empty token; the ack path must be benign (no
      // unhandled rejection) and existing subscriptions keep delivering.
      ws.emitMessage({ type: "auth", status: "error" });
      ws.emitMessage({
        type: "event",
        topic: "posts",
        action: "update",
        record: { id: "p1" },
      });
      await new Promise<void>((r) => setTimeout(r, 0));
      expect(events).toHaveLength(1);
      expect((events[0] as { record: { id: string } }).record.id).toBe("p1");
      expect(rejections).toHaveLength(0);
    } finally {
      process.off("unhandledRejection", onRejection);
    }
  });

  it("does not send an auth frame on an anonymous open (de-auth regression guard)", async () => {
    // The connected-then-logged-out transition sends {token:""}, but a fresh
    // anonymous connect must not send any auth frame and must resubscribe at once.
    const { service, factory } = makeService();
    const subPromise = service.subscribe("public", vi.fn());
    const ws = factory.last;
    ws.emitOpen();
    expect(ws.sentFrames.some((f) => (f as { action: string }).action === "auth")).toBe(false);
    expect(ws.sentFrames).toContainEqual({ action: "subscribe", topic: "public" });
    ws.emitMessage({ type: "ack", action: "subscribe", topic: "public" });
    await subPromise;
  });

  it("rapid re-auth before responses does not strand the auth gate", async () => {
    const store = new MemoryAuthStore();
    store.save("tok-1", { id: "u1" });
    const { service, factory } = makeService(store);
    const subPromise = service.subscribe("posts", vi.fn());
    const ws = factory.last;
    ws.emitOpen();

    // onOpen sent auth tok-1; before its response, the token changes twice.
    store.save("tok-2", { id: "u1" });
    store.save("tok-3", { id: "u1" });
    const auths = ws.sentFrames.filter((f) => (f as { action: string }).action === "auth");
    expect(auths).toEqual([
      { action: "auth", token: "tok-1" },
      { action: "auth", token: "tok-2" },
      { action: "auth", token: "tok-3" },
    ]);

    // A single response must open the (reused) auth gate so the subscribe
    // flushes — the superseded waiters must not hang.
    ws.emitMessage({ type: "auth", status: "ok" });
    await new Promise<void>((r) => setTimeout(r, 0));
    expect(ws.sentFrames).toContainEqual({ action: "subscribe", topic: "posts" });

    // Superseded responses arriving late must not raise a double-settle.
    ws.emitMessage({ type: "auth", status: "ok" });
    ws.emitMessage({ type: "auth", status: "error" });
    await new Promise<void>((r) => setTimeout(r, 0));

    ws.emitMessage({ type: "ack", action: "subscribe", topic: "posts" });
    // Fails (times out) if the subscribe gate hung on a superseded auth.
    await Promise.race([
      subPromise,
      new Promise<void>((_, reject) =>
        setTimeout(() => reject(new Error("subscribe gate hung on superseded auth")), 2000),
      ),
    ]);
  });
});
