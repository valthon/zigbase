import { Transport } from "./transport.js";
import { MemoryAuthStore, type AuthStore } from "./auth-store.js";
import { CollectionService } from "./collection.js";
import { FilesService } from "./files.js";
import { INTERNALS, type ClientInternals, type InternalReader } from "./internal.js";

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

export interface SendOptions {
  query?: Record<string, string | number | boolean | undefined>;
  body?: unknown;
  headers?: Record<string, string>;
  signal?: AbortSignal;
}

export interface Client {
  readonly baseUrl: string;
  readonly authStore: AuthStore;
  readonly files: FilesService;
  collection(name: string): CollectionService;
  send<T>(method: string, path: string, opts?: SendOptions): Promise<T>;
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

  // The reader the live store wraps is the Plan 2 RecordService per collection.
  const makeReader = (name: string): InternalReader =>
    new CollectionService(transport, authStore, name) as unknown as InternalReader;

  const internals: ClientInternals = {
    transport,
    authStore,
    baseUrl: normalizedBase,
    WebSocket: wsImpl,
    makeReader,
  };

  const client: Client = {
    baseUrl: normalizedBase,
    authStore,
    get files() {
      return (filesService ??= new FilesService(transport, normalizedBase));
    },
    collection(name: string) {
      return new CollectionService(transport, authStore, name);
    },
    send<T>(method: string, path: string, sendOpts?: SendOptions) {
      return transport.send<T>(path, { method, ...sendOpts });
    },
  };

  // Stash internals under a non-enumerable symbol so `@zigbase/client/realtime`
  // can bolt realtime on without the base entry importing the realtime graph.
  Object.defineProperty(client, INTERNALS, {
    value: internals,
    enumerable: false,
    configurable: false,
    writable: false,
  });

  return client;
}
