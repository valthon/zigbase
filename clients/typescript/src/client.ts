import { Transport } from "./transport.js";
import { MemoryAuthStore, type AuthStore } from "./auth-store.js";
import { CollectionService } from "./collection.js";
import { FilesService } from "./files.js";
import { RealtimeService } from "./realtime.js";
import type { RealtimeEvent } from "./realtime.js";
import { LiveCollection, type LiveReader, type LiveSubscriber } from "./live/live-collection.js";

export interface ClientOptions {
  authStore?: AuthStore;
  autoRefresh?: boolean;
  fetch?: typeof fetch;
  WebSocket?: typeof WebSocket;
  lang?: string;
  maxRetries?: number;
  /** Collection used for automatic token refresh on 401 (e.g. "users"). */
  authCollection?: string;
}

export interface RealtimeClient extends LiveSubscriber {
  subscribe(
    topic: string,
    cb: (e: RealtimeEvent) => void,
    opts?: { filter?: string },
  ): Promise<() => void>;
  unsubscribe(topic: string, cb?: (e: RealtimeEvent) => void): void;
  collection(name: string): LiveCollection;
}

export interface Client {
  readonly baseUrl: string;
  readonly authStore: AuthStore;
  readonly files: FilesService;
  readonly realtime: RealtimeClient;
  collection(name: string): CollectionService;
  send<T>(method: string, path: string, opts?: { query?: Record<string, string | number | boolean | undefined>; body?: unknown; headers?: Record<string, string>; signal?: AbortSignal }): Promise<T>;
}

export function createClient(baseUrl: string, opts: ClientOptions = {}): Client {
  const authStore = opts.authStore ?? new MemoryAuthStore();
  const normalizedBase = baseUrl.replace(/\/+$/, "");
  const fetchImpl = opts.fetch ?? globalThis.fetch;
  if (!fetchImpl) throw new Error("No fetch implementation available; pass options.fetch");

  let transport!: Transport;
  transport = new Transport({
    baseUrl: normalizedBase,
    authStore,
    fetch: fetchImpl,
    autoRefresh: opts.autoRefresh ?? false,
    maxRetries: opts.maxRetries ?? 3,
    lang: opts.lang,
    refresh: opts.authCollection
      ? async () => {
          await new CollectionService(transport, authStore, opts.authCollection!).authRefresh();
        }
      : undefined,
  });

  let filesService: FilesService | undefined;

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

  return {
    baseUrl: normalizedBase,
    authStore,
    realtime,
    get files() {
      return (filesService ??= new FilesService(transport, normalizedBase));
    },
    collection(name: string) {
      return new CollectionService(transport, authStore, name);
    },
    send<T>(
      method: string,
      path: string,
      sendOpts?: { query?: Record<string, string | number | boolean | undefined>; body?: unknown; headers?: Record<string, string>; signal?: AbortSignal },
    ) {
      return transport.send<T>(path, { method, ...sendOpts });
    },
  };
}
