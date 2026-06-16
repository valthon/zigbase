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
    // When a specific filter is given, target that exact (topic, filter) sub.
    // When it's omitted (the public `unsubscribe(topic, cb)` path), remove `cb`
    // from EVERY subscription variant for the topic regardless of filter — a
    // filtered subscription's subKey would never match `subKey(topic, undefined)`,
    // so keying alone would silently leak it.
    const targets: Subscription[] =
      filter !== undefined
        ? ([this.subscriptions.get(subKey(topic, filter))].filter(Boolean) as Subscription[])
        : [...this.subscriptions.values()].filter((s) => s.topic === topic);

    let removedSub = false;
    for (const sub of targets) {
      if (cb) sub.callbacks.delete(cb);
      else sub.callbacks.clear();

      if (sub.callbacks.size === 0) {
        this.subscriptions.delete(subKey(sub.topic, sub.filter));
        removedSub = true;
      }
    }

    // Send a single unsubscribe frame once the topic has no live variants left.
    if (removedSub && this.opened && this.ws && !this.hasTopic(topic)) {
      this.send({ action: "unsubscribe", topic });
    }
  }

  private hasTopic(topic: string): boolean {
    for (const sub of this.subscriptions.values()) {
      if (sub.topic === topic) return true;
    }
    return false;
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
    let ws: WebSocket;
    try {
      ws = new this.cfg.WebSocket(url);
    } catch (e) {
      // A synchronous constructor throw (invalid URL, env/security policy) must
      // not leave `connecting` stuck true forever. Reset state, surface the
      // error, and schedule a reconnect via the existing backoff path so the
      // connection can still recover.
      this.connecting = false;
      this.ws = null;
      this.cfg.onError?.(e instanceof Error ? e.message : String(e));
      if (!this.closedByUser && this.subscriptions.size > 0) void this.reconnect();
      return;
    }
    this.ws = ws;

    ws.onopen = () => {
      this.connecting = false;
      this.opened = true;
      this.reconnectAttempts = 0;
      this.onOpen();
    };
    ws.onmessage = (ev: MessageEvent) => this.onMessage(ev);
    ws.onclose = () => this.onClose();
    ws.onerror = () => {
      /* errors precede close; reconnect is driven by onClose */
    };
  }

  private onOpen(): void {
    // Send auth first (if a token exists), then (re)subscribe every active topic.
    // When a token is present, gate the (re)subscribes on the auth `ok` so the
    // server has applied the identity before evaluating subscription rules. When
    // anonymous, flush the subscribes synchronously in the same tick.
    const authPromise = this.sendAuth();
    if (authPromise) {
      void authPromise.then(() => this.resubscribeAll());
    } else {
      this.resubscribeAll();
    }
  }

  private resubscribeAll(): void {
    for (const sub of this.subscriptions.values()) {
      sub.acked = false;
      this.sendSubscribe(sub);
    }
  }

  /** Sends an auth frame when a token exists; returns a promise that resolves on
   * the auth ack (or null when anonymous so the caller can act synchronously). */
  private sendAuth(): Promise<void> | null {
    const token = this.cfg.authStore.token;
    if (!token) return null;
    const ack = new Promise<void>((resolve, reject) => {
      this.authAck = { resolve, reject };
    });
    this.send({ action: "auth", token });
    return ack.catch(() => {
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
  return filter === undefined ? topic : `${topic} ${filter}`;
}

function wsUrl(baseUrl: string): string {
  const u = baseUrl.replace(/^http/, "ws").replace(/\/+$/, "");
  return `${u}/api/realtime`;
}
