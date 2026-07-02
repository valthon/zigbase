import { Transport } from "./transport.js";
import { MemoryAuthStore, type AuthStore } from "./auth-store.js";
import { CollectionService } from "./collection.js";
import { FilesService } from "./files.js";
import { AccountsService } from "./accounts.js";
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
  /** Send `X-Account-Id: <id>` on every request (multi-tenant scoping; server >= 0.9.0).
   *  The server grants scope only via a verified ACTIVE membership — fail closed — so
   *  no client-side validation. */
  accountId?: string;
}

export interface SendOptions {
  query?: Record<string, string | number | boolean | undefined>;
  body?: unknown;
  headers?: Record<string, string>;
  signal?: AbortSignal;
  /** Opt-in de-duplication key; a new request aborts any in-flight one with the same key. */
  requestKey?: string;
}

export interface Client {
  readonly baseUrl: string;
  readonly authStore: AuthStore;
  readonly files: FilesService;
  readonly accounts: AccountsService;
  collection(name: string): CollectionService;
  send<T>(method: string, path: string, opts?: SendOptions): Promise<T>;
  /**
   * Raw escape hatch — returns the underlying `Response` WITHOUT JSON-parsing it.
   * Use for binary/text bodies, custom headers, or streaming. The auth header,
   * `query`/`body`/`headers`/`signal`/`requestKey` all apply; non-2xx responses are
   * returned as-is (no throw), and there is no auto-refresh/429-retry on this path.
   */
  fetch(method: string, path: string, opts?: SendOptions): Promise<Response>;
  /** A view of this client whose every request carries `X-Account-Id: <id>`. Shares the
   *  AuthStore (login/logout propagate both ways) and the fetch/WebSocket implementations. */
  withAccount(accountId: string): Client;
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
    accountId: opts.accountId,
    refresh: opts.authCollection
      ? async () => {
          await new CollectionService(transport, authStore, opts.authCollection!).authRefresh();
        }
      : undefined,
  });

  let filesService: FilesService | undefined;
  let accountsService: AccountsService | undefined;

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
    get accounts() {
      return (accountsService ??= new AccountsService(transport));
    },
    collection(name: string) {
      return new CollectionService(transport, authStore, name);
    },
    send<T>(method: string, path: string, sendOpts?: SendOptions) {
      return transport.send<T>(path, { method, ...sendOpts });
    },
    fetch(method: string, path: string, sendOpts?: SendOptions) {
      return transport.raw(path, { method, ...sendOpts });
    },
    withAccount(accountId: string) {
      // Sibling client: SAME AuthStore instance (explicitly forwarded), same fetch/WS impls,
      // a new Transport with the account header baked in.
      return createClient(baseUrl, { ...opts, authStore, accountId });
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
