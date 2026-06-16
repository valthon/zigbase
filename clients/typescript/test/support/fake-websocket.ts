type Listener = (ev: unknown) => void;

/**
 * Minimal controllable WebSocket double. Implements just the surface the
 * RealtimeService touches: send/close, onopen/onmessage/onclose/onerror,
 * addEventListener, and the readyState constants. Tests drive it via the
 * emit* helpers.
 */
export class FakeWebSocket {
  static readonly CONNECTING = 0;
  static readonly OPEN = 1;
  static readonly CLOSING = 2;
  static readonly CLOSED = 3;

  readonly url: string;
  readyState = FakeWebSocket.CONNECTING;
  closed = false;

  /** Frames passed to send(), parsed from JSON. */
  readonly sentFrames: unknown[] = [];
  /** Raw close() invocations (code/reason captured for assertions). */
  readonly closeCalls: Array<{ code?: number; reason?: string }> = [];

  onopen: Listener | null = null;
  onmessage: Listener | null = null;
  onclose: Listener | null = null;
  onerror: Listener | null = null;

  private readonly listeners: Record<string, Set<Listener>> = {
    open: new Set(),
    message: new Set(),
    close: new Set(),
    error: new Set(),
  };

  constructor(url: string) {
    this.url = url;
  }

  send(data: string): void {
    this.sentFrames.push(JSON.parse(data));
  }

  close(code?: number, reason?: string): void {
    this.closed = true;
    this.readyState = FakeWebSocket.CLOSED;
    this.closeCalls.push({ code, reason });
  }

  addEventListener(type: string, cb: Listener): void {
    this.listeners[type]?.add(cb);
  }

  removeEventListener(type: string, cb: Listener): void {
    this.listeners[type]?.delete(cb);
  }

  // ---- test drivers -------------------------------------------------------

  emitOpen(): void {
    this.readyState = FakeWebSocket.OPEN;
    const ev = { type: "open" };
    this.onopen?.(ev);
    for (const cb of this.listeners.open!) cb(ev);
  }

  emitMessage(obj: unknown): void {
    const ev = { type: "message", data: JSON.stringify(obj) } as MessageEvent;
    this.onmessage?.(ev);
    for (const cb of this.listeners.message!) cb(ev);
  }

  emitClose(code = 1006, reason = ""): void {
    this.readyState = FakeWebSocket.CLOSED;
    const ev = { type: "close", code, reason };
    this.onclose?.(ev);
    for (const cb of this.listeners.close!) cb(ev);
  }

  emitError(): void {
    const ev = { type: "error" };
    this.onerror?.(ev);
    for (const cb of this.listeners.error!) cb(ev);
  }
}

/**
 * A factory whose `.WebSocket` member is shaped like `typeof WebSocket` and
 * records every instance it constructs, so a test can grab `.last` after the
 * service opens (or reopens) a connection.
 */
export class FakeWebSocketFactory {
  readonly instances: FakeWebSocket[] = [];

  // A real constructor (so `new factory.WebSocket(url)` works) that records every
  // instance it builds. Cast to typeof WebSocket so it slots into ClientOptions.WebSocket.
  readonly WebSocket: typeof WebSocket;

  constructor() {
    const instances = this.instances;
    this.WebSocket = class extends FakeWebSocket {
      constructor(url: string) {
        super(url);
        instances.push(this);
      }
    } as unknown as typeof WebSocket;
  }

  get last(): FakeWebSocket {
    const ws = this.instances[this.instances.length - 1];
    if (!ws) throw new Error("no FakeWebSocket constructed yet");
    return ws;
  }
}
