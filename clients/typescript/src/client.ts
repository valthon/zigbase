import { Transport } from "./transport.js";
import { MemoryAuthStore, type AuthStore } from "./auth-store.js";
import { CollectionService } from "./collection.js";

export interface ClientOptions {
  authStore?: AuthStore;
  autoRefresh?: boolean;
  fetch?: typeof fetch;
  WebSocket?: typeof WebSocket;
  lang?: string;
  maxRetries?: number;
}

export interface Client {
  readonly baseUrl: string;
  readonly authStore: AuthStore;
  collection(name: string): CollectionService;
  send<T>(method: string, path: string, opts?: { query?: Record<string, string | number | boolean | undefined>; body?: unknown; headers?: Record<string, string>; signal?: AbortSignal }): Promise<T>;
}

export function createClient(baseUrl: string, opts: ClientOptions = {}): Client {
  const authStore = opts.authStore ?? new MemoryAuthStore();
  const normalizedBase = baseUrl.replace(/\/+$/, "");
  const fetchImpl = opts.fetch ?? globalThis.fetch;
  if (!fetchImpl) throw new Error("No fetch implementation available; pass options.fetch");

  const transport = new Transport({
    baseUrl: normalizedBase,
    authStore,
    fetch: fetchImpl,
    autoRefresh: opts.autoRefresh ?? false,
    maxRetries: opts.maxRetries ?? 3,
    lang: opts.lang,
  });

  return {
    baseUrl: normalizedBase,
    authStore,
    collection(name: string) {
      return new CollectionService(transport, authStore, name);
    },
    send<T>(method, path, sendOpts) {
      return transport.send<T>(path, { method, ...sendOpts });
    },
  };
}
