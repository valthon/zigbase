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
});
