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
}

export interface TransportConfig {
  baseUrl: string;
  authStore: AuthStore;
  fetch: typeof fetch;
  autoRefresh: boolean;
  maxRetries: number;
  lang?: string;
  refresh?: () => Promise<void>;
  sleep?: (ms: number) => Promise<void>;
}

const defaultSleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

export class Transport {
  constructor(private readonly cfg: TransportConfig) {}

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
    const url = this.buildUrl(path, opts.query);
    const isForm = typeof FormData !== "undefined" && opts.body instanceof FormData;
    let didRefresh = false;
    let attempt = 0;

    for (;;) {
      const headers = new Headers(opts.headers);
      if (!opts.skipAuth && this.cfg.authStore.token) {
        headers.set("Authorization", `Bearer ${this.cfg.authStore.token}`);
      }
      if (this.cfg.lang) headers.set("Accept-Language", this.cfg.lang);

      let body: BodyInit | undefined;
      if (opts.body !== undefined && opts.method && opts.method !== "GET") {
        if (isForm) {
          body = opts.body as FormData;
        } else {
          headers.set("Content-Type", "application/json");
          body = JSON.stringify(opts.body);
        }
      }

      const res = await this.cfg.fetch(url, {
        method: opts.method ?? "GET",
        headers,
        body,
        signal: opts.signal,
      });

      if (res.ok) {
        if (res.status === 204) return undefined as T;
        const text = await res.text();
        return (text ? JSON.parse(text) : undefined) as T;
      }

      // One-shot auto-refresh on 401.
      if (res.status === 401 && this.cfg.autoRefresh && this.cfg.refresh && !didRefresh && !opts.skipAuth) {
        didRefresh = true;
        try {
          await this.cfg.refresh();
          continue;
        } catch {
          // fall through to error
        }
      }

      // 429 backoff.
      if (res.status === 429 && attempt < this.cfg.maxRetries) {
        const retryAfter = Number(res.headers.get("Retry-After"));
        const delay = Number.isFinite(retryAfter) && retryAfter > 0
          ? retryAfter * 1000
          : 2 ** attempt * 200;
        attempt += 1;
        await (this.cfg.sleep ?? defaultSleep)(delay);
        continue;
      }

      throw await parseErrorResponse(res, url);
    }
  }
}
