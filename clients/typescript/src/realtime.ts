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

/** A frame delivered on a custom (non-collection) topic (server >= 0.10.0 for `__features`;
 *  custom `ctx.realtime()` topics exist as of 0.9.0). */
export interface TopicMessage {
  topic: string;
  /** "signal" = re-fetch hint (no payload); "message" = payload-carrying broadcast. */
  kind: "signal" | "message";
  /** The envelope's `data` value; absent for signals. */
  data?: unknown;
}

export type TopicCallback = (msg: TopicMessage) => void;

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
  /** "records" = collection subscription (event frames); "topic" = custom topic (signal/message). */
  kind: "records" | "topic";
  filter?: string;
  callbacks: Set<RealtimeCallback>;
  topicCallbacks: Set<TopicCallback>;
  /** Resolvers waiting for the `ack` of the in-flight subscribe frame. */
  pending: Array<{ resolve: () => void; reject: (e: Error) => void }>;
  acked: boolean;
  /** A subscribe frame is on the wire awaiting its ack — concurrent subscribers
   *  must join `pending` without sending a duplicate frame. */
  inflight: boolean;
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
      sub = {
        topic,
        kind: "records",
        filter: opts.filter,
        callbacks: new Set(),
        topicCallbacks: new Set(),
        pending: [],
        acked: false,
        inflight: false,
      };
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
      // If the socket is already open and no subscribe frame is awaiting its
      // ack, send one now; concurrent callers just join `pending`.
      if (this.opened && !sub!.inflight) this.sendSubscribe(sub!);
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

  /**
   * Subscribe to a custom (non-collection) topic. Delivers the standard topic frames:
   * `{"type":"signal","topic"}` (kind "signal", no payload — re-fetch hint) and
   * `{"type":"message","topic","data"}` (kind "message" — `ctx.realtime().broadcast`
   * payloads). Feature-change notifications are `subscribeTopic("__features", cb)`
   * (server >= 0.10.0). Same wire frame, ack, resubscribe and backoff machinery as
   * record subscriptions; a server-rejected subscribe rejects the returned promise.
   */
  async subscribeTopic(topic: string, cb: TopicCallback): Promise<() => void> {
    const key = topicKey(topic);
    let sub = this.subscriptions.get(key);
    if (!sub) {
      sub = { topic, kind: "topic", callbacks: new Set(), topicCallbacks: new Set(), pending: [], acked: false, inflight: false };
      this.subscriptions.set(key, sub);
    }
    sub.topicCallbacks.add(cb);

    this.ensureConnected();

    if (sub.acked) {
      return () => this.unsubscribeTopic(topic, cb);
    }
    await new Promise<void>((resolve, reject) => {
      sub!.pending.push({ resolve, reject });
      // Same dedup as `subscribe`: don't re-send while a frame awaits its ack.
      if (this.opened && !sub!.inflight) this.sendSubscribe(sub!);
    });
    return () => this.unsubscribeTopic(topic, cb);
  }

  /** Remove a topic callback (all of them when `cb` is omitted); sends one unsubscribe
   *  frame when the topic has no live subscription variants left. */
  unsubscribeTopic(topic: string, cb?: TopicCallback): void {
    const sub = this.subscriptions.get(topicKey(topic));
    if (!sub) return;
    if (cb) sub.topicCallbacks.delete(cb);
    else sub.topicCallbacks.clear();
    if (sub.topicCallbacks.size === 0) {
      this.subscriptions.delete(topicKey(topic));
      if (this.opened && this.ws && !this.hasTopic(topic)) {
        this.send({ action: "unsubscribe", topic });
      }
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
    sub.inflight = true;
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
      case "signal":
      case "message":
        this.onTopicFrame(frame);
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
      sub.inflight = false;
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

  private onTopicFrame(frame: Record<string, unknown>): void {
    const topic = frame.topic;
    if (typeof topic !== "string") return; // malformed (missing topic) -> dropped
    const kind = frame.type as "signal" | "message";
    const msg: TopicMessage =
      kind === "message" ? { topic, kind, data: frame.data } : { topic, kind };
    for (const sub of this.subscriptions.values()) {
      if (sub.kind !== "topic" || sub.topic !== topic) continue;
      for (const cb of sub.topicCallbacks) cb(msg);
    }
  }

  private onErrorFrame(message: string): void {
    // Reject any still-pending subscribe so the awaiting caller learns of it
    // (e.g. anonymous subscribe to a non-public collection).
    let rejected = false;
    for (const sub of this.subscriptions.values()) {
      if (sub.acked || sub.pending.length === 0) continue;
      sub.inflight = false; // allow a later subscribe to retry with a fresh frame
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

// Record-subscription and topic-subscription keys share one Map, so their key spaces
// must be structurally disjoint: `r:`/`t:` prefixes guarantee no record key (however
// adversarial the topic/filter text) can ever collide with a topic key, or vice versa.
function subKey(topic: string, filter?: string): string {
  return filter === undefined ? `r:${topic}` : `r:${topic} ${filter}`;
}

function topicKey(topic: string): string {
  return `t:${topic}`;
}

function wsUrl(baseUrl: string): string {
  const u = baseUrl.replace(/^http/, "ws").replace(/\/+$/, "");
  return `${u}/api/realtime`;
}
