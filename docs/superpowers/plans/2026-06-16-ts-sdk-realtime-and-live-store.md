# TypeScript SDK — Plan 3: Realtime + Live Store Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the realtime layer of `@zigbase/client` — the low-level `RealtimeService` (one shared auto-reconnecting WebSocket to `/api/realtime`, auth-on-open + re-auth, resubscribe-on-reconnect) and the high-level **live store** (`zb.realtime.collection(name)`) whose `getOne`/`getList`/`getPage` return wrapped, in-place-patched live records and ordered, observable live lists backed by one per-collection record cache, with **tiered-correctness** membership (precise client-side evaluation for own-field filters, debounced re-fetch fallback otherwise).

**Architecture:** A single `WebSocket` per client, created lazily on first `subscribe`, multiplexes all topic subscriptions. A `RealtimeService` owns connection lifecycle (auth frame from the `AuthStore`, re-auth on `authStore.onChange`, bounded exponential-backoff reconnect, resubscribe of every active topic), frame parsing, and per-topic callback dispatch. On top of it, a `LiveCollection` mirrors the Plan 2 read API: a per-collection `RecordCache` hands out stable `LiveRecord` wrappers (same enumerable keys as the record they wrap, patched in place on `update`, flagged `deleted` on `delete`); a `LiveList` seeds via REST and maintains an ordered `items` array using the Plan 2 `compareBySort`/`parseSort` engine, inserting/removing/moving on events. A `filter-eval` module parses the filter grammar to an AST, `evaluateFilter` decides membership on own scalar fields, and `analyzeFilter` classifies a filter as locally-evaluable (precise membership) vs relation/macro (debounced re-fetch fallback).

**Tech Stack:** TypeScript, `vitest` (unit + integration), platform `WebSocket` (read from globals, overridable via `ClientOptions.WebSocket`). Unit tests mock the WebSocket with a small controllable `FakeWebSocket` test double (`test/support/fake-websocket.ts`); integration tests run against a real `zigbase serve` binary over a real WebSocket, reusing the Plan 1 harness.

**Plan context:** This is **Plan 3 of 3** for SP1 (base runtime SDK). It builds directly on:

- **Plan 1 (foundation):** `src/client.ts` `createClient(baseUrl, opts)` → `Client` (opts include `WebSocket?: typeof WebSocket`); `src/auth-store.ts` `AuthStore` with `token` + `onChange(cb)`; `src/transport.ts` `Transport` for REST. This plan **adds a lazy `zb.realtime` accessor** to the client.
- **Plan 2 (records/cursors/files), which provides these CONTRACTS this plan imports — do NOT redefine them:**
  - `src/query.ts` exports `parseSort(sort: string): SortTerm[]` where `SortTerm = { field: string; dir: 'asc' | 'desc' }`, and `compareBySort(a: Record<string, unknown>, b: Record<string, unknown>, terms: SortTerm[]): number`.
  - `src/records.ts` `RecordService` (via `zb.collection(name)`) provides `getOne(id, opts?)`, `getList(page, perPage, opts?)`, `getPage(opts?)` returning `ListResult<T>` / `CursorPage<T>` with `items: T[]`. The live store **wraps** these.

Spec: `docs/superpowers/specs/2026-06-16-zigbase-ts-sdk-base-design.md` (read the "Realtime — low-level protocol + high-level live store" section closely — it is the heart of this plan).

### Wire protocol (authoritative, from the zigbase source)

- **Upgrade:** `GET /api/realtime` (WebSocket). CORS gated by `--realtime-origins`.
- **Client → server JSON frames:** `{ action: "auth", token }`, `{ action: "subscribe", topic, filter? }`, `{ action: "unsubscribe", topic }`. Topic = `"<collection>"` or `"<collection>/<recordId>"`.
- **Server → client frames:** `{ type: "connect", clientId }` (on open), `{ type: "auth", status: "ok"|"error" }`, `{ type: "ack", action, topic }`, `{ type: "event", topic, action: "create"|"update"|"delete", record }` (delete carries only `{ id }`), `{ type: "error", message }`.
- Anonymous subscriptions are only allowed for `@public`-view collections (server-enforced); the client does **not** pre-gate — it surfaces the server's `error` frame.

---

## File Structure

| File | Responsibility |
| --- | --- |
| `clients/typescript/test/support/fake-websocket.ts` | Controllable `WebSocket` test double (queues sent frames; `emitOpen`/`emitMessage`/`emitClose`/`emitError`; records `close()`). |
| `clients/typescript/src/realtime.ts` | Low-level `RealtimeService`: shared WS, auth/re-auth, reconnect+resubscribe, per-topic dispatch; `RealtimeEvent` type. |
| `clients/typescript/src/live/cache.ts` | `RecordCache` (id-keyed) + `LiveRecord<T>` wrapper (in-place patch, `deleted` flag, observable, ref-counted). |
| `clients/typescript/src/live/filter-eval.ts` | Filter grammar parser → AST, `evaluateFilter`, `analyzeFilter` (own-field vs relation/macro classification). |
| `clients/typescript/src/live/live-collection.ts` | `LiveCollection` (`getOne` → `LiveRecord`, `getList`/`getPage` → `LiveList`) + `LiveList` (ordered, observable, tiered membership). |
| `clients/typescript/src/client.ts` | (modify) lazy `realtime` getter constructing `RealtimeService`; `realtime.collection(name)` → `LiveCollection`. |
| `clients/typescript/src/index.ts` | (modify) re-export `RealtimeService`, `LiveCollection`, `LiveRecord`, `LiveList`, `RealtimeEvent`, observable types. |
| `clients/typescript/test/integration/realtime.integration.test.ts` | Real binary + real WS: subscribe→event round-trip; live-store list insert/patch/remove. |
| `clients/typescript/docs/typescript-sdk.md` *(repo `docs/typescript-sdk.md`)* | Full base-SDK guide (SP1 completion). |

---

## Task 1: FakeWebSocket test double

**Files:**
- Create: `clients/typescript/test/support/fake-websocket.ts`
- Test: `clients/typescript/test/support/fake-websocket.test.ts`

- [ ] **Step 1: Write the failing test**

```ts
import { describe, it, expect, vi } from "vitest";
import { FakeWebSocket, FakeWebSocketFactory } from "./fake-websocket.js";

describe("FakeWebSocket", () => {
  it("records the URL and exposes the latest instance via the factory", () => {
    const factory = new FakeWebSocketFactory();
    const ws = new factory.WebSocket("ws://api.test/api/realtime") as FakeWebSocket;
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
    const ev = onmessage.mock.calls[0][0] as MessageEvent;
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd clients/typescript && npm test -- fake-websocket`
Expected: FAIL — cannot find `./fake-websocket.js`.

- [ ] **Step 3: Implement `test/support/fake-websocket.ts`**

```ts
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
    for (const cb of this.listeners.open) cb(ev);
  }

  emitMessage(obj: unknown): void {
    const ev = { type: "message", data: JSON.stringify(obj) } as MessageEvent;
    this.onmessage?.(ev);
    for (const cb of this.listeners.message) cb(ev);
  }

  emitClose(code = 1006, reason = ""): void {
    this.readyState = FakeWebSocket.CLOSED;
    const ev = { type: "close", code, reason };
    this.onclose?.(ev);
    for (const cb of this.listeners.close) cb(ev);
  }

  emitError(): void {
    const ev = { type: "error" };
    this.onerror?.(ev);
    for (const cb of this.listeners.error) cb(ev);
  }
}

/**
 * A factory whose `.WebSocket` member is shaped like `typeof WebSocket` and
 * records every instance it constructs, so a test can grab `.last` after the
 * service opens (or reopens) a connection.
 */
export class FakeWebSocketFactory {
  readonly instances: FakeWebSocket[] = [];

  // Cast to typeof WebSocket so it slots into ClientOptions.WebSocket.
  readonly WebSocket = ((url: string) => {
    const ws = new FakeWebSocket(url);
    this.instances.push(ws);
    return ws;
  }) as unknown as typeof WebSocket;

  get last(): FakeWebSocket {
    const ws = this.instances[this.instances.length - 1];
    if (!ws) throw new Error("no FakeWebSocket constructed yet");
    return ws;
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npm test -- fake-websocket`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add clients/typescript/test/support/fake-websocket.ts clients/typescript/test/support/fake-websocket.test.ts
git commit -m "test(ts-sdk): FakeWebSocket test double for realtime tests"
```

---

## Task 2: RealtimeService — subscribe → ack → event dispatch

**Files:**
- Create: `clients/typescript/src/realtime.ts`
- Test: `clients/typescript/test/realtime-subscribe.test.ts`

- [ ] **Step 1: Write the failing test**

```ts
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
    expect(cb.mock.calls[0][0]).toEqual({
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npm test -- realtime-subscribe`
Expected: FAIL — cannot find `../src/realtime.js`.

- [ ] **Step 3: Implement `src/realtime.ts`**

```ts
import type { AuthStore } from "./auth-store.js";

export type RealtimeAction = "create" | "update" | "delete";

export interface ZbRecord {
  id: string;
  [key: string]: unknown;
}

export interface RealtimeEvent {
  topic: string;
  action: RealtimeAction;
  record: ZbRecord;
}

export type RealtimeCallback = (event: RealtimeEvent) => void;

export interface RealtimeServiceConfig {
  baseUrl: string;
  authStore: AuthStore;
  WebSocket: typeof WebSocket;
  /** Injectable backoff sleep (tests pass a no-op). */
  sleep?: (ms: number) => Promise<void>;
  /** Bounded exponential backoff bounds (ms). */
  minReconnectMs?: number;
  maxReconnectMs?: number;
  /** Surfaced for server `error` frames that aren't tied to a pending subscribe. */
  onError?: (message: string) => void;
}

interface Subscription {
  topic: string;
  filter?: string;
  callbacks: Set<RealtimeCallback>;
  /** Resolvers waiting for the `ack` of the in-flight subscribe frame. */
  pending: Array<{ resolve: () => void; reject: (e: Error) => void }>;
  acked: boolean;
}

const defaultSleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

export class RealtimeService {
  private ws: WebSocket | null = null;
  private opened = false;
  private clientId: string | null = null;
  private connecting = false;
  private closedByUser = false;
  private reconnectAttempts = 0;
  private authAck: { resolve: () => void; reject: (e: Error) => void } | null = null;

  private readonly subscriptions = new Map<string, Subscription>();
  private readonly authUnsub: () => void;

  constructor(private readonly cfg: RealtimeServiceConfig) {
    // Re-auth whenever the token changes (login/logout/refresh).
    this.authUnsub = cfg.authStore.onChange(() => {
      if (this.opened) void this.sendAuth();
    });
  }

  // ---- public API ---------------------------------------------------------

  async subscribe(
    topic: string,
    cb: RealtimeCallback,
    opts: { filter?: string } = {},
  ): Promise<() => void> {
    const key = subKey(topic, opts.filter);
    let sub = this.subscriptions.get(key);
    if (!sub) {
      sub = { topic, filter: opts.filter, callbacks: new Set(), pending: [], acked: false };
      this.subscriptions.set(key, sub);
    }
    sub.callbacks.add(cb);

    this.ensureConnected();

    if (sub.acked) {
      // Already live — nothing more to send; resolve immediately.
      return () => this.unsubscribe(topic, cb, opts.filter);
    }

    await new Promise<void>((resolve, reject) => {
      sub!.pending.push({ resolve, reject });
      // If the socket is already open, (re)send the subscribe frame now.
      if (this.opened) this.sendSubscribe(sub!);
    });

    return () => this.unsubscribe(topic, cb, opts.filter);
  }

  unsubscribe(topic: string, cb?: RealtimeCallback, filter?: string): void {
    const key = subKey(topic, filter);
    const sub = this.subscriptions.get(key);
    if (!sub) return;
    if (cb) sub.callbacks.delete(cb);
    else sub.callbacks.clear();

    if (sub.callbacks.size === 0) {
      this.subscriptions.delete(key);
      if (this.opened && this.ws) {
        this.send({ action: "unsubscribe", topic });
      }
    }
  }

  /** Tear down the socket and stop reconnecting. */
  close(): void {
    this.closedByUser = true;
    this.authUnsub();
    this.subscriptions.clear();
    this.ws?.close();
    this.ws = null;
    this.opened = false;
  }

  // ---- connection lifecycle ----------------------------------------------

  private ensureConnected(): void {
    if (this.ws || this.connecting) return;
    this.connect();
  }

  private connect(): void {
    this.connecting = true;
    this.opened = false;
    const url = wsUrl(this.cfg.baseUrl);
    const ws = new this.cfg.WebSocket(url);
    this.ws = ws;

    ws.onopen = () => {
      this.connecting = false;
      this.opened = true;
      this.reconnectAttempts = 0;
      void this.onOpen();
    };
    ws.onmessage = (ev: MessageEvent) => this.onMessage(ev);
    ws.onclose = () => this.onClose();
    ws.onerror = () => {
      /* errors precede close; reconnect is driven by onClose */
    };
  }

  private async onOpen(): Promise<void> {
    // Send auth first (if a token exists), then (re)subscribe every active topic.
    await this.sendAuth();
    for (const sub of this.subscriptions.values()) {
      sub.acked = false;
      this.sendSubscribe(sub);
    }
  }

  private async sendAuth(): Promise<void> {
    const token = this.cfg.authStore.token;
    if (!token) return;
    const ack = new Promise<void>((resolve, reject) => {
      this.authAck = { resolve, reject };
    });
    this.send({ action: "auth", token });
    await ack.catch(() => {
      /* auth failure is surfaced via onError; don't block reconnect */
    });
  }

  private sendSubscribe(sub: Subscription): void {
    const frame: Record<string, unknown> = { action: "subscribe", topic: sub.topic };
    if (sub.filter !== undefined) frame.filter = sub.filter;
    this.send(frame);
  }

  private send(frame: Record<string, unknown>): void {
    this.ws?.send(JSON.stringify(frame));
  }

  private onMessage(ev: MessageEvent): void {
    let frame: Record<string, unknown>;
    try {
      frame = JSON.parse(ev.data as string) as Record<string, unknown>;
    } catch {
      return;
    }
    switch (frame.type) {
      case "connect":
        this.clientId = (frame.clientId as string) ?? null;
        break;
      case "auth":
        if (frame.status === "ok") this.authAck?.resolve();
        else this.authAck?.reject(new Error("auth failed"));
        this.authAck = null;
        break;
      case "ack":
        this.onAck(frame.topic as string);
        break;
      case "event":
        this.onEvent(frame);
        break;
      case "error":
        this.onErrorFrame((frame.message as string) ?? "realtime error");
        break;
    }
  }

  private onAck(topic: string): void {
    for (const sub of this.subscriptions.values()) {
      if (sub.topic !== topic) continue;
      sub.acked = true;
      const pending = sub.pending.splice(0);
      for (const p of pending) p.resolve();
    }
  }

  private onEvent(frame: Record<string, unknown>): void {
    const topic = frame.topic as string;
    const event: RealtimeEvent = {
      topic,
      action: frame.action as RealtimeAction,
      record: frame.record as ZbRecord,
    };
    for (const sub of this.subscriptions.values()) {
      if (sub.topic === topic) {
        for (const cb of sub.callbacks) cb(event);
      }
    }
  }

  private onErrorFrame(message: string): void {
    // Reject any still-pending subscribe so the awaiting caller learns of it
    // (e.g. anonymous subscribe to a non-public collection).
    let rejected = false;
    for (const sub of this.subscriptions.values()) {
      if (sub.acked || sub.pending.length === 0) continue;
      const pending = sub.pending.splice(0);
      for (const p of pending) p.reject(new Error(message));
      rejected = true;
    }
    this.cfg.onError?.(message);
    if (!rejected && !this.cfg.onError) {
      // Nothing consumed it; keep it visible in dev.
      // eslint-disable-next-line no-console
      console.warn(`[zigbase realtime] ${message}`);
    }
  }

  private onClose(): void {
    this.opened = false;
    this.ws = null;
    if (this.closedByUser || this.subscriptions.size === 0) return;
    void this.reconnect();
  }

  private async reconnect(): Promise<void> {
    const min = this.cfg.minReconnectMs ?? 250;
    const max = this.cfg.maxReconnectMs ?? 10_000;
    const delay = Math.min(max, min * 2 ** this.reconnectAttempts);
    this.reconnectAttempts += 1;
    await (this.cfg.sleep ?? defaultSleep)(delay);
    if (this.closedByUser) return;
    this.connect();
  }
}

function subKey(topic: string, filter?: string): string {
  return filter === undefined ? topic : `${topic} ${filter}`;
}

function wsUrl(baseUrl: string): string {
  const u = baseUrl.replace(/^http/, "ws").replace(/\/+$/, "");
  return `${u}/api/realtime`;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npm test -- realtime-subscribe`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add clients/typescript/src/realtime.ts clients/typescript/test/realtime-subscribe.test.ts
git commit -m "feat(ts-sdk): RealtimeService subscribe/ack/event dispatch over a shared WS"
```

---

## Task 3: RealtimeService — auth on open + re-auth on token change

**Files:**
- Test: `clients/typescript/test/realtime-auth.test.ts`

(Implementation already exists from Task 2; this task locks the auth lifecycle under test.)

- [ ] **Step 1: Write the failing test**

```ts
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
```

- [ ] **Step 2: Run test to verify it passes**

Run: `npm test -- realtime-auth`
Expected: PASS (3 tests). (Task 2's implementation already supports this; if `sendSubscribe` flushed before `auth` ok, fix `onOpen` to `await this.sendAuth()` before iterating subscriptions — it already does.)

- [ ] **Step 3: Commit**

```bash
git add clients/typescript/test/realtime-auth.test.ts
git commit -m "test(ts-sdk): lock realtime auth-on-open + re-auth-on-token-change"
```

---

## Task 4: RealtimeService — reconnect resubscribes + re-auths; unsubscribe; error frame

**Files:**
- Test: `clients/typescript/test/realtime-reconnect.test.ts`

(Implementation exists from Task 2; this task locks reconnect, unsubscribe teardown, and error surfacing.)

- [ ] **Step 1: Write the failing test**

```ts
import { describe, it, expect, vi } from "vitest";
import { RealtimeService } from "../src/realtime.js";
import { MemoryAuthStore } from "../src/auth-store.js";
import { FakeWebSocketFactory } from "./support/fake-websocket.js";

function makeJwt(payload: Record<string, unknown>): string {
  const b64url = (o: unknown) => Buffer.from(JSON.stringify(o)).toString("base64url");
  return `${b64url({ alg: "HS256" })}.${b64url(payload)}.sig`;
}

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
    ws1.emitMessage({ type: "ack", action: "subscribe", topic: "posts" });
    await subPromise;

    // Transport drop.
    ws1.emitClose();

    // A brand-new socket is created; wait a microtask for the async reconnect.
    await new Promise((r) => setTimeout(r, 0));
    const ws2 = factory.last;
    expect(ws2).not.toBe(ws1);

    ws2.emitOpen();
    expect(ws2.sentFrames).toContainEqual({ action: "auth", token: store.token });
    ws2.emitMessage({ type: "auth", status: "ok" });
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
});
```

- [ ] **Step 2: Run test to verify it passes**

Run: `npm test -- realtime-reconnect`
Expected: PASS (4 tests).

- [ ] **Step 3: Commit**

```bash
git add clients/typescript/test/realtime-reconnect.test.ts
git commit -m "test(ts-sdk): lock realtime reconnect/resubscribe, unsubscribe, error frames"
```

---

## Task 5: RecordCache + LiveRecord (in-place patch, observable, ref-counted)

**Files:**
- Create: `clients/typescript/src/live/cache.ts`
- Test: `clients/typescript/test/live-cache.test.ts`

- [ ] **Step 1: Write the failing test**

```ts
import { describe, it, expect, vi } from "vitest";
import { RecordCache } from "../src/live/cache.js";
import type { ZbRecord } from "../src/realtime.js";

describe("RecordCache + LiveRecord", () => {
  it("returns the SAME wrapped object for a given id across lookups", () => {
    const cache = new RecordCache();
    const a = cache.retain({ id: "p1", title: "First" });
    const b = cache.get("p1");
    expect(b).toBe(a);
    expect(a.get().title).toBe("First");
    // The wrapper "looks like" the record it wraps.
    expect((a as unknown as { title: string }).title).toBe("First");
    expect(a.id).toBe("p1");
  });

  it("patches fields in place, bumps version, and notifies on update", () => {
    const cache = new RecordCache();
    const live = cache.retain({ id: "p1", title: "First", views: 1 });
    const cb = vi.fn();
    live.subscribe(cb);
    const v0 = live.version;

    cache.applyUpdate({ id: "p1", title: "Edited", views: 2 });

    expect(live.get().title).toBe("Edited");
    expect((live as unknown as { views: number }).views).toBe(2);
    expect(live.version).toBe(v0 + 1);
    expect(cb).toHaveBeenCalledTimes(1);
    // Identity is stable through the patch.
    expect(cache.get("p1")).toBe(live);
  });

  it("flags a record deleted on a delete event and notifies", () => {
    const cache = new RecordCache();
    const live = cache.retain({ id: "p1", title: "First" });
    const cb = vi.fn();
    live.subscribe(cb);
    cache.applyDelete("p1");
    expect(live.deleted).toBe(true);
    expect(cb).toHaveBeenCalledTimes(1);
  });

  it("ref-counts: a record is evicted only when the last referer releases it", () => {
    const cache = new RecordCache();
    const a1 = cache.retain({ id: "p1", title: "First" }); // refcount 1
    const a2 = cache.retain({ id: "p1", title: "First" }); // refcount 2 (same object)
    expect(a2).toBe(a1);

    cache.release("p1"); // -> 1
    expect(cache.has("p1")).toBe(true);
    cache.release("p1"); // -> 0, evicted
    expect(cache.has("p1")).toBe(false);
  });

  it("unsubscribing a record observer stops further notifications", () => {
    const cache = new RecordCache();
    const live = cache.retain({ id: "p1", n: 0 });
    const cb = vi.fn();
    const off = live.subscribe(cb);
    cache.applyUpdate({ id: "p1", n: 1 });
    off();
    cache.applyUpdate({ id: "p1", n: 2 });
    expect(cb).toHaveBeenCalledTimes(1);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npm test -- live-cache`
Expected: FAIL — cannot find `../src/live/cache.js`.

- [ ] **Step 3: Implement `src/live/cache.ts`**

```ts
import type { ZbRecord } from "../realtime.js";

/** Framework-agnostic observable contract (matches the spec). */
export interface Observable<T> {
  subscribe(cb: () => void): () => void;
  get(): T;
  readonly version: number;
}

/**
 * A wrapped record that "looks exactly like the record it wraps": every
 * enumerable field of the backing object is exposed as a same-named getter, so
 * `live.title` reads through to the current backing data. Identity is stable —
 * updates patch the backing object IN PLACE and bump `version`; deletes set
 * `deleted = true`. Bind via the Observable contract.
 */
export class LiveRecord<T extends ZbRecord = ZbRecord> implements Observable<T> {
  deleted = false;
  private _version = 0;
  private backing: T;
  private readonly listeners = new Set<() => void>();
  private readonly proxied = new Set<string>();

  constructor(initial: T) {
    this.backing = initial;
    this.defineAccessors(Object.keys(initial));
  }

  get id(): string {
    return this.backing.id;
  }

  get version(): number {
    return this._version;
  }

  get(): T {
    return this.backing;
  }

  /** Returns the current data; alias kept for ergonomics. */
  get data(): T {
    return this.backing;
  }

  subscribe(cb: () => void): () => void {
    this.listeners.add(cb);
    return () => this.listeners.delete(cb);
  }

  /** Patch backing fields in place (used by the cache on update events). */
  patch(next: T): void {
    // Mutate the SAME backing object so external `.get()` references stay live.
    const target = this.backing as Record<string, unknown>;
    for (const k of Object.keys(target)) {
      if (!(k in next)) delete target[k];
    }
    Object.assign(target, next);
    this.defineAccessors(Object.keys(next));
    this.bump();
  }

  markDeleted(): void {
    this.deleted = true;
    this.bump();
  }

  private defineAccessors(keys: string[]): void {
    for (const key of keys) {
      if (key === "id" || key === "version" || key === "deleted" || this.proxied.has(key)) {
        continue;
      }
      this.proxied.add(key);
      Object.defineProperty(this, key, {
        configurable: true,
        enumerable: true,
        get: () => (this.backing as Record<string, unknown>)[key],
      });
    }
  }

  private bump(): void {
    this._version += 1;
    for (const cb of this.listeners) cb();
  }
}

interface Entry {
  record: LiveRecord;
  refs: number;
}

/**
 * Per-collection record cache keyed by record id. Hands out the SAME LiveRecord
 * for a given id so one event updates every view. Ref-counted: retained while
 * ≥1 live view/observer references it; evicted at zero.
 */
export class RecordCache {
  private readonly entries = new Map<string, Entry>();

  /** Retain (and create-or-merge) the record for `data.id`; +1 refcount. */
  retain<T extends ZbRecord>(data: T): LiveRecord<T> {
    const existing = this.entries.get(data.id);
    if (existing) {
      existing.refs += 1;
      // Merge fresher data without losing identity.
      existing.record.patch(data);
      return existing.record as LiveRecord<T>;
    }
    const record = new LiveRecord<T>(data);
    this.entries.set(data.id, { record, refs: 1 });
    return record;
  }

  get<T extends ZbRecord = ZbRecord>(id: string): LiveRecord<T> | undefined {
    return this.entries.get(id)?.record as LiveRecord<T> | undefined;
  }

  has(id: string): boolean {
    return this.entries.has(id);
  }

  release(id: string): void {
    const entry = this.entries.get(id);
    if (!entry) return;
    entry.refs -= 1;
    if (entry.refs <= 0) this.entries.delete(id);
  }

  applyUpdate<T extends ZbRecord>(data: T): void {
    this.entries.get(data.id)?.record.patch(data);
  }

  applyDelete(id: string): void {
    this.entries.get(id)?.record.markDeleted();
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npm test -- live-cache`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add clients/typescript/src/live/cache.ts clients/typescript/test/live-cache.test.ts
git commit -m "feat(ts-sdk): RecordCache + LiveRecord (in-place patch, observable, ref-counted)"
```

---

## Task 6: Filter evaluator — parser + evaluateFilter

**Files:**
- Create: `clients/typescript/src/live/filter-eval.ts`
- Test: `clients/typescript/test/filter-eval.test.ts`

- [ ] **Step 1: Write the failing test**

```ts
import { describe, it, expect } from "vitest";
import { parseFilter, evaluateFilter } from "../src/live/filter-eval.js";

describe("filter evaluator", () => {
  it("evaluates a compound && / || filter on own scalar fields", () => {
    const ast = parseFilter("status = 'published' && (views > 10 || pinned = true)");
    expect(evaluateFilter({ status: "published", views: 3, pinned: true }, ast)).toBe(true);
    expect(evaluateFilter({ status: "published", views: 20, pinned: false }, ast)).toBe(true);
    expect(evaluateFilter({ status: "draft", views: 99, pinned: true }, ast)).toBe(false);
    expect(evaluateFilter({ status: "published", views: 3, pinned: false }, ast)).toBe(false);
  });

  it("handles all comparison operators", () => {
    const r = { n: 5, s: "hello" };
    expect(evaluateFilter(r, parseFilter("n = 5"))).toBe(true);
    expect(evaluateFilter(r, parseFilter("n != 6"))).toBe(true);
    expect(evaluateFilter(r, parseFilter("n >= 5"))).toBe(true);
    expect(evaluateFilter(r, parseFilter("n <= 4"))).toBe(false);
    expect(evaluateFilter(r, parseFilter("n > 4"))).toBe(true);
    expect(evaluateFilter(r, parseFilter("n < 5"))).toBe(false);
  });

  it("does case-sensitive substring with ~ and !~", () => {
    const r = { title: "Hello World" };
    expect(evaluateFilter(r, parseFilter("title ~ 'World'"))).toBe(true);
    expect(evaluateFilter(r, parseFilter("title ~ 'world'"))).toBe(false); // case-sensitive
    expect(evaluateFilter(r, parseFilter("title !~ 'xyz'"))).toBe(true);
  });

  it("compares against null", () => {
    expect(evaluateFilter({ deletedAt: null }, parseFilter("deletedAt = null"))).toBe(true);
    expect(evaluateFilter({ deletedAt: "2026" }, parseFilter("deletedAt = null"))).toBe(false);
    expect(evaluateFilter({ deletedAt: "2026" }, parseFilter("deletedAt != null"))).toBe(true);
  });

  it("reads dotted paths against expanded relations present on the record", () => {
    const r = { id: "p1", author: { name: "Ada" } };
    expect(evaluateFilter(r, parseFilter("author.name = 'Ada'"))).toBe(true);
    // missing path resolves to undefined -> not equal
    expect(evaluateFilter({ id: "p2" }, parseFilter("author.name = 'Ada'"))).toBe(false);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npm test -- filter-eval`
Expected: FAIL — cannot find `../src/live/filter-eval.js`.

- [ ] **Step 3: Implement the parser + evaluator in `src/live/filter-eval.ts`**

```ts
// ---- AST -------------------------------------------------------------------

export type CompareOp = "=" | "!=" | ">" | ">=" | "<" | "<=" | "~" | "!~";
export type Literal = string | number | boolean | null;

export interface CompareNode {
  kind: "compare";
  path: string[];
  op: CompareOp;
  value: Literal;
}

export interface LogicNode {
  kind: "and" | "or";
  left: FilterNode;
  right: FilterNode;
}

export type FilterNode = CompareNode | LogicNode;

// ---- tokenizer -------------------------------------------------------------

type Token =
  | { t: "field"; v: string }
  | { t: "op"; v: CompareOp }
  | { t: "and" }
  | { t: "or" }
  | { t: "lparen" }
  | { t: "rparen" }
  | { t: "lit"; v: Literal };

const OP_CHARS = new Set(["=", "!", ">", "<", "~"]);

function tokenize(input: string): Token[] {
  const tokens: Token[] = [];
  let i = 0;
  const n = input.length;
  while (i < n) {
    const c = input[i]!;
    if (c === " " || c === "\t" || c === "\n") {
      i += 1;
      continue;
    }
    if (c === "(") {
      tokens.push({ t: "lparen" });
      i += 1;
      continue;
    }
    if (c === ")") {
      tokens.push({ t: "rparen" });
      i += 1;
      continue;
    }
    if (c === "&" && input[i + 1] === "&") {
      tokens.push({ t: "and" });
      i += 2;
      continue;
    }
    if (c === "|" && input[i + 1] === "|") {
      tokens.push({ t: "or" });
      i += 2;
      continue;
    }
    if (c === "'" || c === '"') {
      const quote = c;
      let j = i + 1;
      let str = "";
      while (j < n && input[j] !== quote) {
        if (input[j] === "\\" && j + 1 < n) {
          str += input[j + 1];
          j += 2;
        } else {
          str += input[j];
          j += 1;
        }
      }
      tokens.push({ t: "lit", v: str });
      i = j + 1;
      continue;
    }
    if (OP_CHARS.has(c)) {
      // Longest-match the operators.
      const two = input.slice(i, i + 2);
      if (two === "!=" || two === ">=" || two === "<=" || two === "!~") {
        tokens.push({ t: "op", v: two as CompareOp });
        i += 2;
        continue;
      }
      if (c === "=" || c === ">" || c === "<" || c === "~") {
        tokens.push({ t: "op", v: c as CompareOp });
        i += 1;
        continue;
      }
      throw new Error(`unexpected operator near "${input.slice(i)}"`);
    }
    // bareword: number, bool, null, or a (dotted) field path.
    let j = i;
    while (j < n && !" \t\n()&|=!<>~'\"".includes(input[j]!)) j += 1;
    const word = input.slice(i, j);
    i = j;
    if (word === "true") tokens.push({ t: "lit", v: true });
    else if (word === "false") tokens.push({ t: "lit", v: false });
    else if (word === "null") tokens.push({ t: "lit", v: null });
    else if (/^-?\d+(\.\d+)?$/.test(word)) tokens.push({ t: "lit", v: Number(word) });
    else tokens.push({ t: "field", v: word });
  }
  return tokens;
}

// ---- parser (precedence: || lowest, then &&, then comparisons / parens) -----

class Parser {
  private pos = 0;
  constructor(private readonly tokens: Token[]) {}

  parse(): FilterNode {
    const node = this.parseOr();
    if (this.pos !== this.tokens.length) throw new Error("trailing tokens in filter");
    return node;
  }

  private peek(): Token | undefined {
    return this.tokens[this.pos];
  }

  private next(): Token {
    const tok = this.tokens[this.pos];
    if (!tok) throw new Error("unexpected end of filter");
    this.pos += 1;
    return tok;
  }

  private parseOr(): FilterNode {
    let left = this.parseAnd();
    while (this.peek()?.t === "or") {
      this.next();
      left = { kind: "or", left, right: this.parseAnd() };
    }
    return left;
  }

  private parseAnd(): FilterNode {
    let left = this.parsePrimary();
    while (this.peek()?.t === "and") {
      this.next();
      left = { kind: "and", left, right: this.parsePrimary() };
    }
    return left;
  }

  private parsePrimary(): FilterNode {
    const tok = this.peek();
    if (tok?.t === "lparen") {
      this.next();
      const node = this.parseOr();
      const close = this.next();
      if (close.t !== "rparen") throw new Error("expected )");
      return node;
    }
    return this.parseCompare();
  }

  private parseCompare(): CompareNode {
    const field = this.next();
    if (field.t !== "field") throw new Error("expected a field path");
    const op = this.next();
    if (op.t !== "op") throw new Error("expected a comparison operator");
    const lit = this.next();
    if (lit.t !== "lit") throw new Error("expected a literal value");
    return { kind: "compare", path: field.v.split("."), op: op.v, value: lit.v };
  }
}

export function parseFilter(input: string): FilterNode {
  return new Parser(tokenize(input)).parse();
}

// ---- evaluator -------------------------------------------------------------

function resolvePath(record: Record<string, unknown>, path: string[]): unknown {
  let cur: unknown = record;
  for (const key of path) {
    if (cur === null || cur === undefined || typeof cur !== "object") return undefined;
    cur = (cur as Record<string, unknown>)[key];
  }
  return cur;
}

function compare(actual: unknown, op: CompareOp, expected: Literal): boolean {
  switch (op) {
    case "=":
      return actual === expected;
    case "!=":
      return actual !== expected;
    case ">":
      return (actual as number) > (expected as number);
    case ">=":
      return (actual as number) >= (expected as number);
    case "<":
      return (actual as number) < (expected as number);
    case "<=":
      return (actual as number) <= (expected as number);
    case "~":
      return typeof actual === "string" && actual.includes(String(expected));
    case "!~":
      return !(typeof actual === "string" && actual.includes(String(expected)));
  }
}

export function evaluateFilter(record: Record<string, unknown>, node: FilterNode): boolean {
  if (node.kind === "and") {
    return evaluateFilter(record, node.left) && evaluateFilter(record, node.right);
  }
  if (node.kind === "or") {
    return evaluateFilter(record, node.left) || evaluateFilter(record, node.right);
  }
  return compare(resolvePath(record, node.path), node.op, node.value);
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npm test -- filter-eval`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add clients/typescript/src/live/filter-eval.ts clients/typescript/test/filter-eval.test.ts
git commit -m "feat(ts-sdk): filter grammar parser + client-side evaluateFilter"
```

---

## Task 7: analyzeFilter — own-field vs relation/macro classification

**Files:**
- Modify: `clients/typescript/src/live/filter-eval.ts`
- Test: `clients/typescript/test/filter-analyze.test.ts`

- [ ] **Step 1: Write the failing test**

```ts
import { describe, it, expect } from "vitest";
import { parseFilter, analyzeFilter } from "../src/live/filter-eval.js";

describe("analyzeFilter", () => {
  it("classifies own-scalar-field filters as locally evaluable", () => {
    const a = analyzeFilter(parseFilter("status = 'published' && views > 10"));
    expect(a.locallyEvaluable).toBe(true);
    expect(a.referencesRelations).toBe(false);
    expect(a.referencesMacros).toBe(false);
  });

  it("flags relation-traversal filters as NOT locally evaluable", () => {
    const a = analyzeFilter(parseFilter("author.name = 'Ada'"));
    expect(a.locallyEvaluable).toBe(false);
    expect(a.referencesRelations).toBe(true);
  });

  it("flags @request.* / macro filters as NOT locally evaluable", () => {
    const a = analyzeFilter(parseFilter("@request.auth.id = owner"));
    expect(a.locallyEvaluable).toBe(false);
    expect(a.referencesMacros).toBe(true);
  });

  it("treats an empty filter (undefined) as locally evaluable (matches all)", () => {
    const a = analyzeFilter(undefined);
    expect(a.locallyEvaluable).toBe(true);
  });
});
```

Note: a single-segment dotted path (`author.name`) is treated as relation traversal because the second segment reads through a relation/expand the client may not have. The membership engine still *evaluates* such a path when the expansion is present on the record (Task 6), but `analyzeFilter` conservatively classifies it as non-precise so `LiveList` chooses the always-correct re-fetch path.

- [ ] **Step 2: Run test to verify it fails**

Run: `npm test -- filter-analyze`
Expected: FAIL — `analyzeFilter` is not exported.

- [ ] **Step 3: Append `analyzeFilter` to `src/live/filter-eval.ts`**

```ts
export interface FilterAnalysis {
  /** True when membership can be decided precisely from a record's own scalar fields. */
  locallyEvaluable: boolean;
  referencesRelations: boolean;
  referencesMacros: boolean;
}

function isMacroPath(path: string[]): boolean {
  // @request.*, @collection.*, and any @-prefixed macro the client can't resolve.
  return path[0]?.startsWith("@") ?? false;
}

function isRelationPath(path: string[]): boolean {
  // A dotted path beyond a single own field reads through a relation/expand.
  return path.length > 1;
}

export function analyzeFilter(node: FilterNode | undefined): FilterAnalysis {
  if (!node) {
    return { locallyEvaluable: true, referencesRelations: false, referencesMacros: false };
  }
  let referencesRelations = false;
  let referencesMacros = false;

  const walk = (n: FilterNode): void => {
    if (n.kind === "and" || n.kind === "or") {
      walk(n.left);
      walk(n.right);
      return;
    }
    if (isMacroPath(n.path)) referencesMacros = true;
    else if (isRelationPath(n.path)) referencesRelations = true;
  };
  walk(node);

  return {
    locallyEvaluable: !referencesRelations && !referencesMacros,
    referencesRelations,
    referencesMacros,
  };
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npm test -- filter-analyze`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add clients/typescript/src/live/filter-eval.ts clients/typescript/test/filter-analyze.test.ts
git commit -m "feat(ts-sdk): analyzeFilter classifies own-field vs relation/macro filters"
```

---

## Task 8: LiveCollection.getOne — single live record

**Files:**
- Create: `clients/typescript/src/live/live-collection.ts`
- Test: `clients/typescript/test/live-getone.test.ts`

This task introduces `LiveCollection` with `getOne` only; `getList`/`getPage` land in Task 9. `LiveCollection` is constructed with a `RecordService`-shaped reader (so the test can inject a fake) and a `RealtimeService`-shaped subscriber.

- [ ] **Step 1: Write the failing test**

```ts
import { describe, it, expect, vi } from "vitest";
import { LiveCollection } from "../src/live/live-collection.js";
import type { RealtimeCallback, RealtimeEvent } from "../src/realtime.js";

/** A minimal realtime stub that lets the test push events for a topic. */
function fakeRealtime() {
  const subs = new Map<string, Set<RealtimeCallback>>();
  return {
    service: {
      async subscribe(topic: string, cb: RealtimeCallback) {
        let set = subs.get(topic);
        if (!set) subs.set(topic, (set = new Set()));
        set.add(cb);
        return () => set!.delete(cb);
      },
      unsubscribe(topic: string, cb?: RealtimeCallback) {
        if (cb) subs.get(topic)?.delete(cb);
        else subs.delete(topic);
      },
    },
    emit(topic: string, event: RealtimeEvent) {
      for (const cb of subs.get(topic) ?? []) cb(event);
    },
    subscriberCount(topic: string) {
      return subs.get(topic)?.size ?? 0;
    },
  };
}

describe("LiveCollection.getOne", () => {
  it("seeds via REST getOne and returns a wrapped live record", async () => {
    const rt = fakeRealtime();
    const reader = {
      getOne: vi.fn(async (id: string) => ({ id, title: "Seed" })),
      getList: vi.fn(),
      getPage: vi.fn(),
    };
    const lc = new LiveCollection("posts", reader as never, rt.service as never);

    const live = await lc.getOne("p1");
    expect(reader.getOne).toHaveBeenCalledWith("p1", undefined);
    expect(live.get().title).toBe("Seed");
    expect((live as unknown as { title: string }).title).toBe("Seed");
    expect(rt.subscriberCount("posts/p1")).toBe(1);
  });

  it("patches the live record in place on an update event", async () => {
    const rt = fakeRealtime();
    const reader = {
      getOne: vi.fn(async (id: string) => ({ id, title: "Seed", views: 1 })),
      getList: vi.fn(),
      getPage: vi.fn(),
    };
    const lc = new LiveCollection("posts", reader as never, rt.service as never);
    const live = await lc.getOne("p1");
    const cb = vi.fn();
    live.subscribe(cb);

    rt.emit("posts/p1", {
      topic: "posts/p1",
      action: "update",
      record: { id: "p1", title: "Edited", views: 9 },
    });
    expect(live.get().title).toBe("Edited");
    expect((live as unknown as { views: number }).views).toBe(9);
    expect(cb).toHaveBeenCalledTimes(1);
  });

  it("flags the record deleted on a delete event", async () => {
    const rt = fakeRealtime();
    const reader = {
      getOne: vi.fn(async (id: string) => ({ id, title: "Seed" })),
      getList: vi.fn(),
      getPage: vi.fn(),
    };
    const lc = new LiveCollection("posts", reader as never, rt.service as never);
    const live = await lc.getOne("p1");
    rt.emit("posts/p1", { topic: "posts/p1", action: "delete", record: { id: "p1" } });
    expect(live.deleted).toBe(true);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npm test -- live-getone`
Expected: FAIL — cannot find `../src/live/live-collection.js`.

- [ ] **Step 3: Implement `src/live/live-collection.ts` (getOne only)**

```ts
import { RecordCache, LiveRecord } from "./cache.js";
import type { ZbRecord, RealtimeEvent } from "../realtime.js";

/** The subset of RecordService the live store reads through. */
export interface LiveReader {
  getOne(id: string, opts?: { expand?: string }): Promise<ZbRecord>;
  getList(
    page: number,
    perPage: number,
    opts?: { filter?: string; sort?: string; expand?: string },
  ): Promise<{ items: ZbRecord[]; page: number; perPage: number; totalItems: number }>;
  getPage(opts?: {
    cursor?: string;
    limit?: number;
    filter?: string;
    sort?: string;
    expand?: string;
  }): Promise<{ items: ZbRecord[]; nextCursor: string | null }>;
}

/** The subset of RealtimeService the live store subscribes through. */
export interface LiveSubscriber {
  subscribe(
    topic: string,
    cb: (e: RealtimeEvent) => void,
    opts?: { filter?: string },
  ): Promise<() => void>;
  unsubscribe(topic: string, cb?: (e: RealtimeEvent) => void): void;
}

export class LiveCollection {
  private readonly cache = new RecordCache();

  constructor(
    readonly name: string,
    private readonly reader: LiveReader,
    private readonly realtime: LiveSubscriber,
  ) {}

  /** Returns a wrapped live record, seeded via REST and kept live via `name/id`. */
  async getOne(id: string, opts?: { expand?: string }): Promise<LiveRecord> {
    const seed = await this.reader.getOne(id, opts);
    const live = this.cache.retain(seed);
    await this.realtime.subscribe(`${this.name}/${id}`, (event) => {
      if (event.action === "delete") this.cache.applyDelete(id);
      else this.cache.applyUpdate(event.record);
    });
    return live;
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npm test -- live-getone`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add clients/typescript/src/live/live-collection.ts clients/typescript/test/live-getone.test.ts
git commit -m "feat(ts-sdk): LiveCollection.getOne returns a live, in-place-patched record"
```

---

## Task 9: LiveList — ordered, observable, precise membership (own-field filters)

**Files:**
- Modify: `clients/typescript/src/live/live-collection.ts`
- Test: `clients/typescript/test/live-list.test.ts`

The `LiveList` keeps `items: LiveRecord[]` ordered by the query's sort via the Plan 2 `parseSort` + `compareBySort`. On events it uses `evaluateFilter`/`analyzeFilter`: for own-field filters it surgically inserts (sorted), removes, and re-positions on update; if a record is not yet cached it retains it through the shared cache.

- [ ] **Step 1: Write the failing test**

```ts
import { describe, it, expect, vi } from "vitest";
import { LiveCollection } from "../src/live/live-collection.js";
import type { RealtimeCallback, RealtimeEvent } from "../src/realtime.js";

function fakeRealtime() {
  const subs = new Map<string, Set<RealtimeCallback>>();
  return {
    service: {
      async subscribe(topic: string, cb: RealtimeCallback) {
        let set = subs.get(topic);
        if (!set) subs.set(topic, (set = new Set()));
        set.add(cb);
        return () => set!.delete(cb);
      },
      unsubscribe(topic: string, cb?: RealtimeCallback) {
        if (cb) subs.get(topic)?.delete(cb);
        else subs.delete(topic);
      },
    },
    emit(topic: string, event: RealtimeEvent) {
      for (const cb of subs.get(topic) ?? []) cb(event);
    },
  };
}

describe("LiveCollection.getList -> LiveList", () => {
  it("seeds items ordered by sort and notifies observers on changes", async () => {
    const rt = fakeRealtime();
    const reader = {
      getOne: vi.fn(),
      getList: vi.fn(async () => ({
        items: [
          { id: "b", title: "B", rank: 2 },
          { id: "a", title: "A", rank: 1 },
        ],
        page: 1,
        perPage: 30,
        totalItems: 2,
      })),
      getPage: vi.fn(),
    };
    const lc = new LiveCollection("posts", reader as never, rt.service as never);

    const list = await lc.getList(1, 30, { sort: "rank" });
    expect(list.items.map((r) => r.id)).toEqual(["a", "b"]); // sorted by rank asc
    const cb = vi.fn();
    list.subscribe(cb);

    // matching create inserts at sorted position
    rt.emit("posts", {
      topic: "posts",
      action: "create",
      record: { id: "c", title: "C", rank: 0 },
    });
    expect(list.items.map((r) => r.id)).toEqual(["c", "a", "b"]);
    expect(cb).toHaveBeenCalled();
  });

  it("removes on delete and re-sorts in place when an update changes a sort key", async () => {
    const rt = fakeRealtime();
    const reader = {
      getOne: vi.fn(),
      getList: vi.fn(async () => ({
        items: [
          { id: "a", rank: 1 },
          { id: "b", rank: 2 },
          { id: "c", rank: 3 },
        ],
        page: 1,
        perPage: 30,
        totalItems: 3,
      })),
      getPage: vi.fn(),
    };
    const lc = new LiveCollection("posts", reader as never, rt.service as never);
    const list = await lc.getList(1, 30, { sort: "rank" });

    rt.emit("posts", { topic: "posts", action: "delete", record: { id: "b" } });
    expect(list.items.map((r) => r.id)).toEqual(["a", "c"]);

    // update moves "a" to the end and patches it in place
    rt.emit("posts", { topic: "posts", action: "update", record: { id: "a", rank: 9 } });
    expect(list.items.map((r) => r.id)).toEqual(["c", "a"]);
    expect((list.items[1] as unknown as { rank: number }).rank).toBe(9);
  });

  it("drops a record on an update that moves it OUT of an own-field filter", async () => {
    const rt = fakeRealtime();
    const reader = {
      getOne: vi.fn(),
      getList: vi.fn(async () => ({
        items: [
          { id: "a", status: "published", rank: 1 },
          { id: "b", status: "published", rank: 2 },
        ],
        page: 1,
        perPage: 30,
        totalItems: 2,
      })),
      getPage: vi.fn(),
    };
    const lc = new LiveCollection("posts", reader as never, rt.service as never);
    const list = await lc.getList(1, 30, { filter: "status = 'published'", sort: "rank" });

    rt.emit("posts", {
      topic: "posts",
      action: "update",
      record: { id: "a", status: "draft", rank: 1 },
    });
    expect(list.items.map((r) => r.id)).toEqual(["b"]);

    // an update that moves a NEW record INTO the filter inserts it
    rt.emit("posts", {
      topic: "posts",
      action: "update",
      record: { id: "z", status: "published", rank: 0 },
    });
    expect(list.items.map((r) => r.id)).toEqual(["z", "b"]);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npm test -- live-list`
Expected: FAIL — `getList` is not a method on `LiveCollection`.

- [ ] **Step 3: Add `LiveList` + `LiveCollection.getList`/`getPage` to `src/live/live-collection.ts`**

Add the imports at the top of the file:

```ts
import { parseSort, compareBySort, type SortTerm } from "../query.js";
import { parseFilter, evaluateFilter, analyzeFilter, type FilterNode } from "./filter-eval.js";
import type { Observable } from "./cache.js";
```

Append the `LiveList` class:

```ts
export interface LiveListOpts {
  filter?: string;
  sort?: string;
  expand?: string;
}

export class LiveList implements Observable<LiveRecord[]> {
  readonly items: LiveRecord[] = [];
  private _version = 0;
  private readonly listeners = new Set<() => void>();
  private readonly sortTerms: SortTerm[];
  private readonly filterAst: FilterNode | undefined;
  private readonly precise: boolean;
  private refetchTimer: ReturnType<typeof setTimeout> | null = null;

  constructor(
    private readonly cache: RecordCache,
    seed: ZbRecord[],
    private readonly opts: LiveListOpts,
    private readonly onRefetch: () => Promise<ZbRecord[]>,
    private readonly refetch: { debounceMs: number; schedule: (fn: () => void, ms: number) => ReturnType<typeof setTimeout> },
  ) {
    // Always include `id` as a final tiebreaker for a deterministic order.
    this.sortTerms = appendIdTiebreaker(parseSort(opts.sort ?? ""));
    this.filterAst = opts.filter ? parseFilter(opts.filter) : undefined;
    this.precise = analyzeFilter(this.filterAst).locallyEvaluable;

    for (const rec of seed) {
      this.items.push(this.cache.retain(rec));
    }
    this.sortItems();
  }

  get version(): number {
    return this._version;
  }

  get(): LiveRecord[] {
    return this.items;
  }

  subscribe(cb: () => void): () => void {
    this.listeners.add(cb);
    return () => this.listeners.delete(cb);
  }

  /** Called by LiveCollection for each realtime event on the collection topic. */
  handleEvent(event: RealtimeEvent): void {
    if (!this.precise) {
      this.scheduleRefetch();
      return;
    }
    if (event.action === "delete") {
      this.removeById(event.record.id);
      return;
    }
    const matches = this.filterAst ? evaluateFilter(event.record, this.filterAst) : true;
    const idx = this.items.findIndex((r) => r.id === event.record.id);
    if (matches) {
      if (idx === -1) {
        this.items.push(this.cache.retain(event.record));
      } else {
        this.cache.applyUpdate(event.record);
      }
      this.sortItems();
      this.bump();
    } else if (idx !== -1) {
      this.removeById(event.record.id);
    }
  }

  private removeById(id: string): void {
    const idx = this.items.findIndex((r) => r.id === id);
    if (idx === -1) return;
    this.items.splice(idx, 1);
    this.cache.release(id);
    this.bump();
  }

  private sortItems(): void {
    this.items.sort((a, b) => compareBySort(a.get(), b.get(), this.sortTerms));
  }

  private scheduleRefetch(): void {
    if (this.refetchTimer) return;
    this.refetchTimer = this.refetch.schedule(() => {
      this.refetchTimer = null;
      void this.doRefetch();
    }, this.refetch.debounceMs);
  }

  private async doRefetch(): Promise<void> {
    const fresh = await this.onRefetch();
    const nextIds = new Set(fresh.map((r) => r.id));
    // Release rows that fell out.
    for (const r of [...this.items]) {
      if (!nextIds.has(r.id)) this.removeById(r.id);
    }
    // Insert/patch the fresh set.
    for (const rec of fresh) {
      const idx = this.items.findIndex((r) => r.id === rec.id);
      if (idx === -1) this.items.push(this.cache.retain(rec));
      else this.cache.applyUpdate(rec);
    }
    this.sortItems();
    this.bump();
  }

  private bump(): void {
    this._version += 1;
    for (const cb of this.listeners) cb();
  }
}

function appendIdTiebreaker(terms: SortTerm[]): SortTerm[] {
  if (terms.some((t) => t.field === "id")) return terms;
  return [...terms, { field: "id", dir: "asc" }];
}
```

Then add the `getList`/`getPage` methods + a topic subscription to `LiveCollection`. Replace the class body's tail (after `getOne`) with:

```ts
  async getList(
    page = 1,
    perPage = 30,
    opts: LiveListOpts & { refetchDebounceMs?: number; schedule?: (fn: () => void, ms: number) => ReturnType<typeof setTimeout> } = {},
  ): Promise<LiveList> {
    const seed = await this.reader.getList(page, perPage, opts);
    return this.buildList(seed.items, opts, () =>
      this.reader.getList(page, perPage, opts).then((r) => r.items),
    );
  }

  async getPage(
    opts: LiveListOpts & {
      cursor?: string;
      limit?: number;
      refetchDebounceMs?: number;
      schedule?: (fn: () => void, ms: number) => ReturnType<typeof setTimeout>;
    } = {},
  ): Promise<LiveList> {
    const seed = await this.reader.getPage(opts);
    return this.buildList(seed.items, opts, () =>
      this.reader.getPage(opts).then((r) => r.items),
    );
  }

  private async buildList(
    seed: ZbRecord[],
    opts: LiveListOpts & {
      refetchDebounceMs?: number;
      schedule?: (fn: () => void, ms: number) => ReturnType<typeof setTimeout>;
    },
    onRefetch: () => Promise<ZbRecord[]>,
  ): Promise<LiveList> {
    const list = new LiveList(this.cache, seed, opts, onRefetch, {
      debounceMs: opts.refetchDebounceMs ?? 200,
      schedule: opts.schedule ?? ((fn, ms) => setTimeout(fn, ms)),
    });
    await this.realtime.subscribe(
      this.name,
      (event) => list.handleEvent(event),
      opts.filter ? { filter: opts.filter } : undefined,
    );
    return list;
  }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npm test -- live-list`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add clients/typescript/src/live/live-collection.ts clients/typescript/test/live-list.test.ts
git commit -m "feat(ts-sdk): LiveList ordered/observable with precise own-field membership"
```

---

## Task 10: LiveList — debounced re-fetch fallback for relation/macro filters

**Files:**
- Test: `clients/typescript/test/live-list-refetch.test.ts`

(Implementation exists from Task 9; this task locks the tiered-correctness fallback with an injected scheduler.)

- [ ] **Step 1: Write the failing test**

```ts
import { describe, it, expect, vi } from "vitest";
import { LiveCollection } from "../src/live/live-collection.js";
import type { RealtimeCallback, RealtimeEvent } from "../src/realtime.js";

function fakeRealtime() {
  const subs = new Map<string, Set<RealtimeCallback>>();
  return {
    service: {
      async subscribe(topic: string, cb: RealtimeCallback) {
        let set = subs.get(topic);
        if (!set) subs.set(topic, (set = new Set()));
        set.add(cb);
        return () => set!.delete(cb);
      },
      unsubscribe() {},
    },
    emit(topic: string, event: RealtimeEvent) {
      for (const cb of subs.get(topic) ?? []) cb(event);
    },
  };
}

describe("LiveList refetch fallback (relation filter)", () => {
  it("debounces and re-fetches the query on relevant events instead of guessing membership", async () => {
    const rt = fakeRealtime();
    let listCalls = 0;
    const pages = [
      [{ id: "a", rank: 1 }],
      [
        { id: "a", rank: 1 },
        { id: "b", rank: 2 },
      ],
    ];
    const reader = {
      getOne: vi.fn(),
      getList: vi.fn(async () => ({
        items: pages[Math.min(listCalls++, pages.length - 1)]!,
        page: 1,
        perPage: 30,
        totalItems: 2,
      })),
      getPage: vi.fn(),
    };
    const lc = new LiveCollection("posts", reader as never, rt.service as never);

    // Manually-driven scheduler so the test controls debounce flushing.
    let scheduled: (() => void) | null = null;
    const list = await lc.getList(1, 30, {
      // relation traversal -> NOT locally evaluable -> refetch fallback
      filter: "author.name = 'Ada'",
      sort: "rank",
      refetchDebounceMs: 50,
      schedule: (fn) => {
        scheduled = fn;
        return 0 as never;
      },
    });
    expect(list.items.map((r) => r.id)).toEqual(["a"]);

    // Two events arrive; only one refetch should be scheduled (debounced).
    rt.emit("posts", { topic: "posts", action: "create", record: { id: "b", rank: 2 } });
    rt.emit("posts", { topic: "posts", action: "create", record: { id: "x", rank: 9 } });
    expect(typeof scheduled).toBe("function");

    // Flush the debounce.
    scheduled!();
    await new Promise((r) => setTimeout(r, 0));

    expect(reader.getList).toHaveBeenCalledTimes(2); // initial seed + one refetch
    expect(list.items.map((r) => r.id)).toEqual(["a", "b"]);
  });
});
```

- [ ] **Step 2: Run test to verify it passes**

Run: `npm test -- live-list-refetch`
Expected: PASS (1 test).

- [ ] **Step 3: Commit**

```bash
git add clients/typescript/test/live-list-refetch.test.ts
git commit -m "test(ts-sdk): lock LiveList debounced-refetch fallback for relation filters"
```

---

## Task 11: Wire `zb.realtime` into the client + index re-exports

**Files:**
- Modify: `clients/typescript/src/client.ts`
- Modify: `clients/typescript/src/index.ts`
- Test: `clients/typescript/test/realtime-wiring.test.ts`

- [ ] **Step 1: Write the failing test**

```ts
import { describe, it, expect, vi } from "vitest";
import { createClient } from "../src/index.js";
import { FakeWebSocketFactory } from "./support/fake-websocket.js";

describe("zb.realtime wiring", () => {
  it("lazily constructs a RealtimeService using the injected WebSocket", async () => {
    const factory = new FakeWebSocketFactory();
    const zb = createClient("http://api.test", {
      fetch: (async () => new Response("{}")) as unknown as typeof fetch,
      WebSocket: factory.WebSocket,
    });

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
    const zb = createClient("http://api.test", {
      fetch: (async () => new Response("{}")) as unknown as typeof fetch,
      WebSocket: factory.WebSocket,
    });
    const live = zb.realtime.collection("posts");
    expect(live.name).toBe("posts");
    expect(typeof live.getOne).toBe("function");
    expect(typeof live.getList).toBe("function");
  });

  it("returns the SAME realtime accessor across reads (one shared socket)", () => {
    const factory = new FakeWebSocketFactory();
    const zb = createClient("http://api.test", {
      fetch: (async () => new Response("{}")) as unknown as typeof fetch,
      WebSocket: factory.WebSocket,
    });
    expect(zb.realtime).toBe(zb.realtime);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npm test -- realtime-wiring`
Expected: FAIL — `zb.realtime` is undefined.

- [ ] **Step 3: Add a lazy `realtime` accessor to `src/client.ts`**

Add imports at the top:

```ts
import { RealtimeService } from "./realtime.js";
import { LiveCollection, type LiveReader, type LiveSubscriber } from "./live/live-collection.js";
```

Extend the `Client` interface with the accessor type:

```ts
export interface RealtimeClient extends LiveSubscriber {
  subscribe(
    topic: string,
    cb: (e: import("./realtime.js").RealtimeEvent) => void,
    opts?: { filter?: string },
  ): Promise<() => void>;
  unsubscribe(topic: string, cb?: (e: import("./realtime.js").RealtimeEvent) => void): void;
  collection(name: string): LiveCollection;
}

export interface Client {
  readonly baseUrl: string;
  readonly authStore: AuthStore;
  readonly realtime: RealtimeClient;
  collection(name: string): CollectionService;
  send<T>(method: string, path: string, opts?: { query?: Record<string, string | number | boolean | undefined>; body?: unknown; headers?: Record<string, string>; signal?: AbortSignal }): Promise<T>;
}
```

In `createClient`, resolve the WebSocket impl and build a lazily-instantiated realtime accessor. Insert before the `return`:

```ts
  const wsImpl = opts.WebSocket ?? (globalThis.WebSocket as typeof WebSocket | undefined);

  let realtimeService: RealtimeService | null = null;
  const getRealtimeService = (): RealtimeService => {
    if (!realtimeService) {
      if (!wsImpl) {
        throw new Error("No WebSocket implementation available; pass options.WebSocket");
      }
      realtimeService = new RealtimeService({
        baseUrl: normalizedBase,
        authStore,
        WebSocket: wsImpl,
      });
    }
    return realtimeService;
  };

  // The reader the live store wraps is the Plan 2 RecordService per collection.
  const makeReader = (name: string): LiveReader =>
    new CollectionService(transport, authStore, name) as unknown as LiveReader;

  const realtime: RealtimeClient = {
    subscribe: (topic, cb, subOpts) => getRealtimeService().subscribe(topic, cb, subOpts),
    unsubscribe: (topic, cb) => getRealtimeService().unsubscribe(topic, cb),
    collection: (name) => new LiveCollection(name, makeReader(name), getRealtimeService()),
  };
```

Then add `realtime` to the returned object:

```ts
  return {
    baseUrl: normalizedBase,
    authStore,
    realtime,
    collection(name: string) {
      return new CollectionService(transport, authStore, name);
    },
    send<T>(method, path, sendOpts) {
      return transport.send<T>(path, { method, ...sendOpts });
    },
  };
```

Note: `makeReader` casts the Plan 2 `CollectionService` to `LiveReader`; `CollectionService` already exposes `getOne`/`getList`/`getPage` from Plan 2, so this is a structural match. If Plan 2's method signatures differ, narrow `LiveReader` to match them rather than changing `CollectionService`.

- [ ] **Step 4: Update `src/index.ts` re-exports**

Append:

```ts
export { RealtimeService } from "./realtime.js";
export type { RealtimeEvent, RealtimeCallback, RealtimeAction, ZbRecord } from "./realtime.js";
export { LiveCollection, LiveList } from "./live/live-collection.js";
export type { LiveReader, LiveSubscriber, LiveListOpts } from "./live/live-collection.js";
export { LiveRecord, RecordCache } from "./live/cache.js";
export type { Observable } from "./live/cache.js";
export { parseFilter, evaluateFilter, analyzeFilter } from "./live/filter-eval.js";
export type { FilterNode, FilterAnalysis } from "./live/filter-eval.js";
export type { RealtimeClient } from "./client.js";
```

- [ ] **Step 5: Run test to verify it passes + full suite + typecheck**

Run: `npm test -- realtime-wiring && npm test && npm run typecheck`
Expected: wiring tests PASS (3); full unit suite PASS; typecheck clean.

- [ ] **Step 6: Commit**

```bash
git add clients/typescript/src/client.ts clients/typescript/src/index.ts clients/typescript/test/realtime-wiring.test.ts
git commit -m "feat(ts-sdk): wire lazy zb.realtime + realtime.collection into the client"
```

---

## Task 12: Integration tests (real binary + real WebSocket)

**Files:**
- Create: `clients/typescript/test/integration/realtime.integration.test.ts`

Reuses the Plan 1 harness (`test/integration/harness.ts`): `startServer`, `superuserToken`, `createCollection`. The server must allow realtime upgrades from the test origin and permit anonymous subscriptions on a `@public`-view collection.

- [ ] **Step 1: Confirm harness server flags at execution time**

The realtime upgrade is CORS-gated by `--realtime-origins`. If the harness launches `zigbase serve` without it and the WebSocket handshake is rejected, add `--realtime-origins "*"` (or the test origin) to the `serve` args in `test/integration/harness.ts`. Confirm the exact `@public` view-rule syntax for the seeded collection against `src/api/collections.zig` / the access-rule docs at execution time; the test contract below (subscribe → event; live list insert/patch/remove) stays stable regardless of the exact rule string.

Run: `grep -n "realtime-origins" src/**/*.zig docs/*.md 2>/dev/null | head`
Expected: locate the flag name + default to confirm the harness value.

- [ ] **Step 2: Write the integration test**

```ts
import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { startServer, superuserToken, createCollection, type TestServer } from "./harness.js";
import { createClient } from "../../src/index.js";

let server: TestServer;
let suToken: string;

beforeAll(async () => {
  server = await startServer();
  suToken = await superuserToken(server);
  // A @public-view collection so anonymous realtime subscriptions are allowed.
  await createCollection(server, suToken, {
    name: "feed",
    type: "base",
    fields: [
      { name: "title", type: "text" },
      { name: "rank", type: "number" },
    ],
    listRule: "@public",
    viewRule: "@public",
    createRule: "",
    updateRule: "",
    deleteRule: "",
  });
});

afterAll(() => server?.stop());

async function createRecord(body: Record<string, unknown>): Promise<{ id: string }> {
  const res = await fetch(`${server.url}/api/collections/feed/records`, {
    method: "POST",
    headers: { "content-type": "application/json", Authorization: `Bearer ${suToken}` },
    body: JSON.stringify(body),
  });
  if (!res.ok) throw new Error(`create failed: ${res.status} ${await res.text()}`);
  return (await res.json()) as { id: string };
}

async function patchRecord(id: string, body: Record<string, unknown>): Promise<void> {
  const res = await fetch(`${server.url}/api/collections/feed/records/${id}`, {
    method: "PATCH",
    headers: { "content-type": "application/json", Authorization: `Bearer ${suToken}` },
    body: JSON.stringify(body),
  });
  if (!res.ok) throw new Error(`patch failed: ${res.status}`);
}

async function deleteRecord(id: string): Promise<void> {
  const res = await fetch(`${server.url}/api/collections/feed/records/${id}`, {
    method: "DELETE",
    headers: { Authorization: `Bearer ${suToken}` },
  });
  if (!res.ok) throw new Error(`delete failed: ${res.status}`);
}

function waitFor(cond: () => boolean, timeoutMs = 5000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  return new Promise((resolve, reject) => {
    const tick = () => {
      if (cond()) return resolve();
      if (Date.now() > deadline) return reject(new Error("timeout waiting for realtime event"));
      setTimeout(tick, 25);
    };
    tick();
  });
}

describe("realtime (live backend)", () => {
  it("delivers a create event to a low-level subscriber", async () => {
    const zb = createClient(server.url);
    const events: unknown[] = [];
    const unsub = await zb.realtime.subscribe("feed", (e) => events.push(e));

    const created = await createRecord({ title: "Hello", rank: 1 });
    await waitFor(() => events.length > 0);

    const ev = events[0] as { action: string; record: { id: string } };
    expect(ev.action).toBe("create");
    expect(ev.record.id).toBe(created.id);
    await unsub();
  });

  it("keeps a LiveList in sync: insert, in-place patch, remove", async () => {
    const seedA = await createRecord({ title: "A", rank: 10 });
    const zb = createClient(server.url);
    const live = zb.realtime.collection("feed");
    const list = await live.getList(1, 50, { sort: "rank" });
    let notified = 0;
    list.subscribe(() => (notified += 1));

    const before = list.items.length;

    // insert
    const seedB = await createRecord({ title: "B", rank: 5 });
    await waitFor(() => list.items.some((r) => r.id === seedB.id));
    expect(list.items.length).toBe(before + 1);
    // sorted: rank 5 (B) before rank 10 (A)
    const idxA = list.items.findIndex((r) => r.id === seedA.id);
    const idxB = list.items.findIndex((r) => r.id === seedB.id);
    expect(idxB).toBeLessThan(idxA);

    // in-place patch
    const liveA = list.items.find((r) => r.id === seedA.id)!;
    await patchRecord(seedA.id, { title: "A2" });
    await waitFor(() => (liveA as unknown as { title: string }).title === "A2");

    // remove
    await deleteRecord(seedB.id);
    await waitFor(() => !list.items.some((r) => r.id === seedB.id));

    expect(notified).toBeGreaterThan(0);
  });
});
```

- [ ] **Step 3: Run the integration test**

Run: `cd clients/typescript && npm run test:integration -- realtime`
Expected: PASS (2 tests) against a freshly built+launched `zigbase`. If the WS handshake fails, add `--realtime-origins` per Step 1.

- [ ] **Step 4: Add the realtime integration job step / confirm CI coverage**

The Plan 1 `ts-sdk` CI job already runs `npm run test:integration` (all `*.integration.test.ts`), so this file is picked up automatically. No CI change is needed beyond confirming the job builds the binary first.

- [ ] **Step 5: Commit**

```bash
git add clients/typescript/test/integration/realtime.integration.test.ts
git commit -m "test(ts-sdk): realtime + live-store integration against a real binary"
```

---

## Task 13: Final docs (SP1 completion) + version bump

**Files:**
- Create: `docs/typescript-sdk.md`
- Create: `site/src/content/docs/typescript-sdk.md` (mirror — confirm `site/src/content/docs/` layout + frontmatter at execution time)
- Modify: `README.md` (top-level pointer)
- Modify: `clients/typescript/package.json` (version → `0.1.0`)

This task closes out SP1: the base SDK is complete (Plans 1–3), so ship the full base-SDK guide and bump the package to its first publishable version. Follow the repo's doc-sync discipline (CLAUDE.md): every doc change updates the `site/` mirror, READMEs, `docs/*.md`, and examples, and the PR uses `.github/pull_request_template.md`'s sync checklist.

- [ ] **Step 1: Inspect the site docs layout + frontmatter convention**

Run: `ls site/src/content/docs && sed -n '1,8p' site/src/content/docs/api.md`
Expected: see the frontmatter shape (`title`, `description`, `order`, `group`) and the existing groups (`getting-started`, `guides`, `reference`). Mirror that exactly in the new file. Pick a `group`/`order` that slots the SDK page sensibly (e.g. `group: guides`).

- [ ] **Step 2: Write `docs/typescript-sdk.md`** — the full base-SDK guide

Cover, with runnable snippets:

```markdown
# ZigBase TypeScript SDK

The official TypeScript client (`@zigbase/client`) — zero dependencies; runs in browsers,
Node 18+, Bun, Deno, and edge runtimes.

## Install

\`\`\`bash
npm install @zigbase/client
\`\`\`

## Create a client

\`\`\`ts
import { createClient, LocalAuthStore } from "@zigbase/client";
const zb = createClient("http://127.0.0.1:8090", { authStore: new LocalAuthStore() });
\`\`\`

## Auth + stores

- `MemoryAuthStore` (default, SSR-safe), `LocalAuthStore` (browser), `CookieAuthStore` (SSR handoff).
- `authWithPassword`, `authRefresh`, OAuth2 + PKCE, verification + password reset, `logout`.

\`\`\`ts
await zb.collection("users").authWithPassword("you@example.com", "secret");
zb.authStore.isValid; // decodes the JWT exp locally
\`\`\`

## Records

\`\`\`ts
const posts = zb.collection("posts");
const page = await posts.getList(1, 30, { filter: "status = 'published'", sort: "-created", expand: "author" });
const one  = await posts.getOne("REC123", { expand: "author" });
const made = await posts.create({ title: "Hi", cover: fileInput.files[0] }); // multipart auto-detected
\`\`\`

## Pagination — offset + cursor

\`\`\`ts
// offset (random access, exact totals)
const p = await posts.getList(2, 30);
// cursor / keyset (stable under inserts; ideal for feeds)
const c = await posts.getPage({ limit: 30, sort: "-created" });
for await (const post of posts.iterate({ sort: "-created" })) { /* ... */ }
\`\`\`

## Files

\`\`\`ts
const url = zb.files.getUrl(record, record.cover, { thumb: "100x100" });
const token = await zb.files.getToken(); // protected-file access token
\`\`\`

## Realtime + live store

### Low-level subscriptions

\`\`\`ts
const unsub = await zb.realtime.subscribe("posts", (e) => {
  e.action; // "create" | "update" | "delete"
  e.record; // delete carries only { id }
}, { filter: "status = 'published'" });
await zb.realtime.subscribe("posts/REC123", (e) => { /* single record */ });
await unsub();
\`\`\`

The single shared socket auto-reconnects with backoff, re-auths from the AuthStore on
login/logout/refresh, and resubscribes every active topic after a drop.

### High-level live store — "same API, now live"

\`\`\`ts
const live = zb.realtime.collection("posts");

// a live record: looks exactly like the record, patched in place on update events
const post = await live.getOne("REC123");
post.title;            // reads through to current data
post.subscribe(() => render(post)); // observable: subscribe / get() / version

// a live list: ordered items kept in sync as events arrive
const list = await live.getList(1, 30, { sort: "-created" });
list.subscribe(() => render(list.items));
\`\`\`

**Tiered correctness.** When a filter references only the record's own scalar fields, the
list evaluates membership precisely client-side (surgical insert/remove/move). When it uses
relation traversal or macros (`@request.*`) the client can't evaluate locally, the list
degrades to a debounced re-fetch — still live, always correct.

## Runtime overrides

\`\`\`ts
createClient(url, { fetch: customFetch, WebSocket: customWS }); // exotic runtimes
\`\`\`
```

(Expand each section to match the depth of `docs/api.md`. Keep all snippets runnable.)

- [ ] **Step 3: Mirror to `site/src/content/docs/typescript-sdk.md`**

Copy the guide with the site frontmatter block prepended (matching Step 1's convention), e.g.:

```markdown
---
title: TypeScript SDK
description: The official @zigbase/client TypeScript SDK — auth, records, offset + cursor pagination, files, realtime, and the live store.
order: 4
group: guides
---
```

Adjust relative links to the site's routing (the existing pages use `./api`, `./tutorial`, etc. — match that style).

- [ ] **Step 4: Add a top-level README pointer**

In `README.md`, under the features / client section, add a line pointing to the SDK:

```markdown
- **TypeScript SDK** — official zero-dependency client (`@zigbase/client`): auth, records,
  offset + cursor pagination, files, realtime + live store. → [docs/typescript-sdk.md](docs/typescript-sdk.md)
```

- [ ] **Step 5: Bump the package version**

In `clients/typescript/package.json`, set `"version": "0.1.0"` (first publishable base SDK; SP1 complete across Plans 1–3).

- [ ] **Step 6: Build the site to verify docs render**

Run: `cd site && npm install && npm run build`
Expected: the site builds with the new `typescript-sdk` page (confirm no broken-link/frontmatter errors). If the content collection schema requires extra frontmatter fields, add them to match the existing pages.

- [ ] **Step 7: Commit**

```bash
git add docs/typescript-sdk.md site/src/content/docs/typescript-sdk.md README.md clients/typescript/package.json
git commit -m "docs(ts-sdk): base SDK guide + site mirror + README pointer; bump @zigbase/client to 0.1.0"
```

---

## Self-Review notes

### Spec-coverage checklist (every realtime / live-store spec bullet → a task)

- **One shared WS to `/api/realtime`, lazy on first `subscribe`** → Tasks 2, 11 (lazy client wiring).
- **Client frames `auth`/`subscribe`/`unsubscribe`; topic = `<col>` or `<col>/<id>`** → Tasks 2 (subscribe/filter/topic), 4 (unsubscribe), 8 (`posts/id` topic).
- **Server frames `connect`/`auth`/`ack`/`event`/`error`; `delete` carries only `{ id }`** → Task 2 (frame parser/dispatch), Task 4 (error frame), Task 8/9 (delete handling).
- **`subscribe` resolves on `ack`, returns unsubscribe fn; `RealtimeEvent = { topic, action, record }`** → Task 2.
- **Auth on open when a token is present; re-auth on `authStore.onChange`** → Tasks 2 (impl), 3 (locked).
- **Auto-reconnect with bounded exponential backoff (injectable sleep + WS factory); resubscribe every active topic + re-auth** → Tasks 2 (impl), 4 (locked).
- **Multiple callbacks per topic; one WS frame per distinct (topic, filter)** → Task 2 (reuse), Task 4 (zero-at-last-cb unsubscribe).
- **`error` frame rejects pending subscribe and/or `onError` hook; anonymous-only-for-`@public` surfaced, not pre-gated** → Task 4, Task 12 (integration on a `@public` collection).
- **Per-collection `RecordCache` keyed by id; `LiveRecord` looks like the wrapped record, patched IN PLACE, `deleted` flag, stable identity, observable `subscribe`/`get`/`version`; ref-count eviction** → Task 5; same-object-across-views asserted in Tasks 5, 8, 9.
- **`LiveCollection.getOne` seeds via REST, subscribes `name/id`, returns wrapped record (update-in-place / delete-flag)** → Task 8.
- **`getList`/`getPage` return an observable `LiveList`; `.items` ordered by sort via `compareBySort`; create→insert, delete→remove, update→re-evaluate membership + patch + move** → Task 9.
- **Shared single `RecordCache` per collection (one object across all views)** → Tasks 8 + 9 (the `LiveCollection.cache` is shared by `getOne` and every list).
- **Filter grammar parser (`= != > >= < <= ~ !~`, `&&`, `||`, parens, quoted strings/numbers/bool/null, dotted paths) → AST; `evaluateFilter` on own scalar fields + expanded relations; `~`/`!~` case-sensitive substring** → Task 6.
- **`analyzeFilter`: own-fields-only (precise) vs relation/macro (`@request.*`, not locally evaluable)** → Task 7.
- **Tiered correctness in `LiveList`: precise client membership for own-field filters; debounced re-fetch (injectable interval + refetch) otherwise; always correct** → Tasks 9 (precise) + 10 (refetch fallback).
- **Reconnect re-auths + resubscribes so liveness survives drops** → Task 4 (unit) + Task 12 (real-binary round-trip).
- **`zb.realtime` lazy accessor with configured `WebSocket`/authStore/baseUrl; `realtime.collection(name)` → `LiveCollection`; index re-exports** → Task 11.
- **Integration: real binary + real WS — subscribe→event; live `getList` insert/patch/remove + observers fire; `--realtime-origins` + `@public` rule flagged for execution-time confirmation** → Task 12.
- **SP1-completion docs: `docs/typescript-sdk.md` + `site/` mirror + README pointer + version bump; doc-sync discipline + PR template** → Task 13.

### Placeholder scan

No `TODO`/`FIXME`/`...`/`throw new Error("not implemented")` placeholders. Every implementation step contains complete, runnable TypeScript: `FakeWebSocket`/`FakeWebSocketFactory` (Task 1), the full `RealtimeService` (Task 2), `RecordCache`/`LiveRecord` (Task 5), the full filter tokenizer/parser/evaluator + `analyzeFilter` (Tasks 6–7), `LiveCollection`/`LiveList` incl. the refetch fallback (Tasks 8–10), and the client wiring (Task 11). Tasks 3, 4, 10 are test-only locks over earlier implementations (explicitly noted). Execution-time confirmations are flagged inline and leave the test contracts unchanged: realtime CORS flag `--realtime-origins` and the exact `@public` view-rule syntax (Task 12 Step 1), the auth record-creation field names inherited from the Plan 1 harness, and the site content-collection frontmatter schema (Task 13 Steps 1, 3, 6).

### Type-consistency

- **`RealtimeEvent = { topic: string; action: 'create'|'update'|'delete'; record: ZbRecord }`** — defined once in `src/realtime.ts`, consumed identically by `RealtimeService` dispatch (Task 2), `LiveCollection`/`LiveList` (Tasks 8–10), and re-exported (Task 11). `ZbRecord = { id: string; [k: string]: unknown }`.
- **Observable contract `interface Observable<T> { subscribe(cb: () => void): () => void; get(): T; version: number }`** — defined in `src/live/cache.ts`, implemented by both `LiveRecord<T>` (Task 5) and `LiveList` (Task 9), matching the spec verbatim.
- **`LiveRecord<T>`** — single definition (Task 5); used by `getOne` (Task 8) and as the element type of `LiveList.items` (Task 9). Wrapper "looks like the record": same enumerable keys via defined getters over a single mutated backing object; `id`/`version`/`deleted`/`data` reserved.
- **`LiveList`** — `items: LiveRecord[]`, `subscribe`/`get`/`version`; one definition (Task 9), returned by `getList`/`getPage`.
- **Imported Plan 2 signatures used unchanged:** `parseSort(sort: string): SortTerm[]` with `SortTerm = { field: string; dir: 'asc'|'desc' }`, and `compareBySort(a, b, terms): number`. `LiveList` imports both from `../query.js` and appends an `id` tiebreaker (`{ field: 'id', dir: 'asc' }`) to guarantee deterministic order — consistent with the cursor engine's tiebreaker rule in the spec. The `LiveReader` interface narrows Plan 2's `RecordService` (`getOne`/`getList`/`getPage`) structurally; if Plan 2's concrete signatures differ at execution time, narrow `LiveReader` to match rather than altering `RecordService` (flagged in Task 11 Step 3).
```
