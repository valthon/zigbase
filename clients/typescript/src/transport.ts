import type { AuthStore } from "./auth-store.js";
import { parseErrorResponse } from "./errors.js";

export type QueryValue = string | number | boolean | undefined | null;

export interface RequestOptions {
  method?: string;
  query?: Record<string, QueryValue>;
  body?: unknown;
  headers?: Record<string, string>;
  signal?: AbortSignal;
  skipAuth?: boolean;
  /**
   * Opt-in de-duplication key. When set, any in-flight request sharing the same key
   * is aborted before this one is issued (PocketBase-style last-write-wins). The aborted
   * request rejects with a DOMException whose `name` is `"AbortError"`.
   */
  requestKey?: string;
  /**
   * Internal: marks the auth-refresh request itself (`CollectionService.authRequest`
   * sets it for `/auth-refresh`). A 401 from this request propagates instead of
   * entering the single-flight refresh branch — awaiting there would mean awaiting
   * its own refresh (deadlock), and starting another would recurse without bound.
   * It cannot ride on `skipAuth` because auth-refresh must still send the bearer
   * header.
   */
  isRefreshCall?: boolean;
}

export interface TransportConfig {
  baseUrl: string;
  authStore: AuthStore;
  fetch: typeof fetch;
  autoRefresh: boolean;
  maxRetries: number;
  lang?: string;
  /** Send X-Account-Id on every request (multi-tenant scoping); per-request headers win. */
  accountId?: string;
  refresh?: () => Promise<void>;
  sleep?: (ms: number) => Promise<void>;
}

const defaultSleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

export class Transport {
  /** In-flight controllers keyed by `requestKey`, for opt-in auto-cancellation. */
  private readonly inflight = new Map<string, AbortController>();

  /** The single-flight 401 refresh. The first 401 starts it; every 401 that
   *  lands while it runs awaits the SAME promise and then retries its request
   *  once (still bounded per exchange by `didRefresh`), so a parallel burst of
   *  expired-token requests all succeed after exactly one refresh. Cleared in a
   *  `finally` so a later expiry starts a fresh refresh. The refresh endpoint's
   *  own request never enters this path (see `RequestOptions.isRefreshCall`) —
   *  its 401 propagates, which both avoids a self-await deadlock and keeps a
   *  persistently-401ing refresh from recursing without bound. */
  private refreshInFlight: Promise<void> | null = null;

  constructor(private readonly cfg: TransportConfig) {}

  /** Join (or start) the single-flight refresh. */
  private awaitRefresh(): Promise<void> {
    this.refreshInFlight ??= Promise.resolve()
      .then(() => this.cfg.refresh!())
      .finally(() => {
        this.refreshInFlight = null;
      });
    return this.refreshInFlight;
  }

  buildUrl(path: string, query?: Record<string, QueryValue>): string {
    const base = this.cfg.baseUrl.replace(/\/+$/, "");
    let url = path.startsWith("http") ? path : base + path;
    if (query) {
      const params = new URLSearchParams();
      for (const [k, v] of Object.entries(query)) {
        if (v === undefined || v === null) continue;
        params.set(k, String(v));
      }
      const qs = params.toString();
      if (qs) url += (url.includes("?") ? "&" : "?") + qs;
    }
    return url;
  }

  async send<T>(path: string, opts: RequestOptions = {}): Promise<T> {
    const { signal, cleanup } = this.resolveSignal(opts);
    try {
      return await this.exchange<T>(path, opts, signal);
    } finally {
      cleanup();
    }
  }

  /**
   * Resolve the effective AbortSignal for a request, wiring opt-in `requestKey`
   * de-duplication: a new keyed request aborts any in-flight one with the same key.
   * The returned signal is also aborted by the caller's own `opts.signal`.
   */
  private resolveSignal(opts: RequestOptions): { signal: AbortSignal | undefined; cleanup: () => void } {
    if (opts.requestKey === undefined) {
      return { signal: opts.signal, cleanup: () => {} };
    }
    const key = opts.requestKey;
    // Abort any prior in-flight request sharing this key (last write wins).
    this.inflight.get(key)?.abort();

    const controller = new AbortController();
    this.inflight.set(key, controller);

    // Compose the caller's signal: if it fires, abort this controller too.
    const userSignal = opts.signal;
    let onUserAbort: (() => void) | undefined;
    if (userSignal) {
      if (userSignal.aborted) controller.abort(userSignal.reason);
      else {
        onUserAbort = () => controller.abort(userSignal.reason);
        userSignal.addEventListener("abort", onUserAbort, { once: true });
      }
    }

    const cleanup = () => {
      if (onUserAbort && userSignal) userSignal.removeEventListener("abort", onUserAbort);
      // Only clear the map slot if it still points at THIS controller (a newer
      // keyed request may have replaced it).
      if (this.inflight.get(key) === controller) this.inflight.delete(key);
    };
    return { signal: controller.signal, cleanup };
  }

  /** Build the per-attempt headers + body (auth, lang, content-type, JSON/FormData). */
  private buildRequestInit(opts: RequestOptions, signal: AbortSignal | undefined): RequestInit {
    const isForm = typeof FormData !== "undefined" && opts.body instanceof FormData;
    const headers = new Headers(opts.headers);
    if (!opts.skipAuth && this.cfg.authStore.token) {
      headers.set("Authorization", `Bearer ${this.cfg.authStore.token}`);
    }
    if (this.cfg.lang) headers.set("Accept-Language", this.cfg.lang);
    if (this.cfg.accountId && !headers.has("X-Account-Id")) {
      headers.set("X-Account-Id", this.cfg.accountId);
    }

    let body: BodyInit | undefined;
    if (opts.body !== undefined && opts.method && opts.method !== "GET") {
      if (isForm) {
        body = opts.body as FormData;
      } else {
        headers.set("Content-Type", "application/json");
        body = JSON.stringify(opts.body);
      }
    }
    return { method: opts.method ?? "GET", headers, body, signal };
  }

  /**
   * Raw escape hatch — performs the request and returns the `Response` WITHOUT
   * JSON-parsing or error-mapping it. Auth header, `query`/`body`/`headers`/`signal`
   * and opt-in `requestKey` de-duplication all apply; non-2xx responses are returned
   * as-is (no throw) and there is no auto-refresh/429-retry. Use for binary/text
   * bodies, custom headers, or streaming.
   */
  async raw(path: string, opts: RequestOptions = {}): Promise<Response> {
    const { signal, cleanup } = this.resolveSignal(opts);
    try {
      const url = this.buildUrl(path, opts.query);
      return await this.cfg.fetch(url, this.buildRequestInit(opts, signal));
    } finally {
      cleanup();
    }
  }

  private async exchange<T>(path: string, opts: RequestOptions, signal: AbortSignal | undefined): Promise<T> {
    const url = this.buildUrl(path, opts.query);
    let didRefresh = false;
    let attempt = 0;

    for (;;) {
      const res = await this.cfg.fetch(url, this.buildRequestInit(opts, signal));

      if (res.ok) {
        if (res.status === 204) return undefined as T;
        const text = await res.text();
        return (text ? JSON.parse(text) : undefined) as T;
      }

      // Single-flight auto-refresh on 401 (one retry per exchange): join the
      // in-flight refresh if one is running, else start it, then retry with
      // the fresh token. A failed refresh falls through to this request's
      // original 401. The refresh endpoint's own request is exempt via
      // `isRefreshCall` — its 401 propagates (no self-await deadlock, no
      // unbounded recursion).
      if (
        res.status === 401 &&
        this.cfg.autoRefresh &&
        this.cfg.refresh &&
        !didRefresh &&
        !opts.skipAuth &&
        !opts.isRefreshCall
      ) {
        didRefresh = true;
        try {
          await this.awaitRefresh();
          continue;
        } catch {
          // refresh failed — fall through to the original 401 error
        }
      }

      // 429 backoff. Exponential, but capped so a high attempt count can't
      // request an absurd multi-minute sleep. A numeric Retry-After is honored
      // verbatim (the server's explicit instruction wins).
      if (res.status === 429 && attempt < this.cfg.maxRetries) {
        const maxDelayMs = 30_000;
        const retryAfter = Number(res.headers.get("Retry-After"));
        const delay = Number.isFinite(retryAfter) && retryAfter > 0
          ? retryAfter * 1000
          : Math.min(maxDelayMs, 2 ** attempt * 200);
        attempt += 1;
        await (this.cfg.sleep ?? defaultSleep)(delay);
        continue;
      }

      throw await parseErrorResponse(res, url);
    }
  }
}
