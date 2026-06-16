import { describe, it, expect, vi } from "vitest";
import { FakeWebSocket, FakeWebSocketFactory } from "./fake-websocket.js";

describe("FakeWebSocket", () => {
  it("records the URL and exposes the latest instance via the factory", () => {
    const factory = new FakeWebSocketFactory();
    const ws = new factory.WebSocket(
      "ws://api.test/api/realtime",
    ) as unknown as FakeWebSocket;
    expect(ws.url).toBe("ws://api.test/api/realtime");
    expect(factory.last).toBe(ws);
    expect(factory.instances).toHaveLength(1);
  });

  it("queues sent frames as parsed objects", () => {
    const ws = new FakeWebSocket("ws://x");
    ws.emitOpen();
    ws.send(JSON.stringify({ action: "subscribe", topic: "posts" }));
    expect(ws.sentFrames).toEqual([{ action: "subscribe", topic: "posts" }]);
  });

  it("dispatches emitted server frames to onmessage", () => {
    const ws = new FakeWebSocket("ws://x");
    const onmessage = vi.fn();
    ws.onmessage = onmessage;
    ws.emitOpen();
    ws.emitMessage({ type: "connect", clientId: "c1" });
    expect(onmessage).toHaveBeenCalledTimes(1);
    const ev = onmessage.mock.calls[0]![0] as MessageEvent;
    expect(JSON.parse(ev.data as string)).toEqual({ type: "connect", clientId: "c1" });
  });

  it("supports addEventListener for open/message/close/error", () => {
    const ws = new FakeWebSocket("ws://x");
    const open = vi.fn();
    const msg = vi.fn();
    ws.addEventListener("open", open);
    ws.addEventListener("message", msg);
    ws.emitOpen();
    ws.emitMessage({ type: "ack", action: "subscribe", topic: "posts" });
    expect(open).toHaveBeenCalledTimes(1);
    expect(msg).toHaveBeenCalledTimes(1);
  });

  it("records close() calls and emits a close event", () => {
    const ws = new FakeWebSocket("ws://x");
    const onclose = vi.fn();
    ws.onclose = onclose;
    ws.emitOpen();
    ws.close();
    expect(ws.closed).toBe(true);
    expect(ws.readyState).toBe(FakeWebSocket.CLOSED);
    // emitClose simulates a server/transport-initiated drop.
    ws.emitClose();
    expect(onclose).toHaveBeenCalled();
  });
});
