import type { Transport } from "./transport.js";
import type { AuthStore, AuthRecord } from "./auth-store.js";
import { ZigbaseError } from "./errors.js";
import {
  type ZbRecord,
  type ListResult,
  type ListOpts,
  type RecordCrudOpts,
  hasBlob,
  toFormData,
} from "./records.js";
import { type CursorPage } from "./cursor.js";
import { vectorSpec } from "./query.js";

export interface AuthResponse {
  token: string;
  record: AuthRecord;
  meta?: Record<string, unknown>;
}

/** Response shape from POST /auth/oauth2/complete (record and meta are no longer included). */
export interface OAuth2AuthResponse {
  token: string;
}

/** Response shape from POST /auth/oauth2/initiate. */
export interface OAuth2InitResponse {
  authURL?: string;
  clientId?: string;
  scopes?: string[];
  /** OAuth2 CSRF state — present when the server included state in the initiate response. */
  state?: string;
}

export interface OAuth2Provider {
  name: string;
  authURL?: string;
  clientId?: string;
  scopes?: string[];
}

export interface OAuth2Args {
  provider: string;
  code: string;
  codeVerifier: string;
  redirectUrl: string;
  state?: string;
}

export class CollectionService {
  constructor(
    protected readonly transport: Transport,
    protected readonly authStore: AuthStore,
    readonly name: string,
  ) {}

  protected base(): string {
    return `/api/collections/${encodeURIComponent(this.name)}`;
  }

  private async authRequest(path: string, body: unknown): Promise<AuthResponse> {
    const res = await this.transport.send<AuthResponse>(`${this.base()}${path}`, {
      method: "POST",
      body,
      skipAuth: path === "/auth-with-password",
    });
    this.authStore.save(res.token, res.record);
    return res;
  }

  authWithPassword(identity: string, password: string): Promise<AuthResponse> {
    return this.authRequest("/auth-with-password", { identity, password });
  }

  authRefresh(): Promise<AuthResponse> {
    return this.authRequest("/auth-refresh", {});
  }

  async authWithOAuth2(args: OAuth2Args): Promise<OAuth2AuthResponse> {
    const res = await this.transport.send<OAuth2AuthResponse>(
      `${this.base()}/auth/oauth2/complete`,
      { method: "POST", body: args, skipAuth: true },
    );
    // The /auth/oauth2/complete endpoint sets zb_auth/zb_csrf cookies directly.
    // It does not return a record; store the token only.
    this.authStore.save(res.token, null);
    return res;
  }

  async logout(): Promise<void> {
    try {
      await this.transport.send<void>(`${this.base()}/auth-logout`, { method: "POST" });
    } finally {
      this.authStore.clear();
    }
  }

  listAuthProviders(): Promise<{ providers: OAuth2Provider[] }> {
    return this.transport.send(`${this.base()}/auth/oauth2/providers`, { method: "GET" });
  }

  oauth2Init(provider: string): Promise<OAuth2InitResponse> {
    return this.transport.send(`${this.base()}/auth/oauth2/initiate`, {
      method: "POST",
      body: { provider },
    });
  }

  requestVerification(email: string): Promise<void> {
    return this.transport.send(`${this.base()}/request-verification`, {
      method: "POST",
      body: { email },
    });
  }

  confirmVerification(token: string): Promise<{ verified: boolean }> {
    return this.transport.send(`${this.base()}/confirm-verification`, {
      method: "POST",
      body: { token },
      skipAuth: true,
    });
  }

  requestPasswordReset(email: string): Promise<void> {
    return this.transport.send(`${this.base()}/request-password-reset`, {
      method: "POST",
      body: { email },
    });
  }

  confirmPasswordReset(token: string, password: string): Promise<{ success: boolean }> {
    return this.transport.send(`${this.base()}/confirm-password-reset`, {
      method: "POST",
      body: { token, password },
      skipAuth: true,
    });
  }

  /** `/api/collections/<name>/records` */
  private recordsBase(): string {
    return `${this.base()}/records`;
  }

  /** Offset pagination. `perPage` is clamped to the server max of 500. */
  getList<T = ZbRecord>(page = 1, perPage = 30, opts: ListOpts = {}): Promise<ListResult<T>> {
    return this.transport.send<ListResult<T>>(this.recordsBase(), {
      method: "GET",
      query: {
        page,
        perPage: Math.min(Math.max(perPage, 1), 500),
        filter: opts.filter,
        sort: opts.sort,
        expand: opts.expand,
        fields: opts.fields,
        skipTotal: opts.skipTotal ? 1 : undefined,
        search: opts.search,
        vector: opts.vector ? vectorSpec(opts.vector) : undefined,
      },
      signal: opts.signal,
      requestKey: opts.requestKey,
    });
  }

  getOne<T = ZbRecord>(id: string, opts: RecordCrudOpts = {}): Promise<T> {
    return this.transport.send<T>(`${this.recordsBase()}/${encodeURIComponent(id)}`, {
      method: "GET",
      query: { expand: opts.expand, fields: opts.fields },
      signal: opts.signal,
      requestKey: opts.requestKey,
    });
  }

  /** getList(1, 1) sugar. Throws a 404 ZigbaseError when nothing matches. */
  async getFirstListItem<T = ZbRecord>(
    filter: string,
    opts: Omit<ListOpts, "filter"> = {},
  ): Promise<T> {
    const list = await this.getList<T>(1, 1, { ...opts, filter, skipTotal: true });
    const first = list.items[0];
    if (first === undefined) {
      throw new ZigbaseError({
        status: 404,
        message: "No record found matching the filter.",
        url: this.recordsBase(),
      });
    }
    return first;
  }

  /** Create a record. Auto-switches to multipart when the body contains a Blob/File. */
  create<T = ZbRecord>(body: Record<string, unknown>, opts: RecordCrudOpts = {}): Promise<T> {
    const payload = hasBlob(body) ? toFormData(body) : body;
    return this.transport.send<T>(this.recordsBase(), {
      method: "POST",
      body: payload,
      query: { expand: opts.expand, fields: opts.fields },
      signal: opts.signal,
      requestKey: opts.requestKey,
    });
  }

  update<T = ZbRecord>(
    id: string,
    body: Record<string, unknown>,
    opts: RecordCrudOpts = {},
  ): Promise<T> {
    const payload = hasBlob(body) ? toFormData(body) : body;
    return this.transport.send<T>(`${this.recordsBase()}/${encodeURIComponent(id)}`, {
      method: "PATCH",
      body: payload,
      query: { expand: opts.expand, fields: opts.fields },
      signal: opts.signal,
      requestKey: opts.requestKey,
    });
  }

  async delete(id: string): Promise<void> {
    await this.transport.send<void>(`${this.recordsBase()}/${encodeURIComponent(id)}`, {
      method: "DELETE",
    });
  }

  /**
   * Native server-side cursor (keyset) pagination. The server mints the opaque
   * `nextCursor`/`prevCursor` tokens (src/query/keyset.zig); the client forwards
   * whatever it received and never decodes or synthesizes one. Sending `limit`
   * (with no `cursor`) requests the FIRST cursor page. Stable under inserts and
   * free of deep-offset cost. By default the server skips the total count; pass
   * `withTotal: true` to include `totalItems`.
   */
  async getPage<T extends Record<string, unknown> = ZbRecord>(opts: {
    cursor?: string;
    limit?: number;
    filter?: string;
    sort?: string;
    expand?: string;
    fields?: string;
    withTotal?: boolean;
    search?: string;
    signal?: AbortSignal;
    requestKey?: string;
  } = {}): Promise<CursorPage<T>> {
    const body = await this.transport.send<
      ListResult<T> & {
        nextCursor?: string | null;
        prevCursor?: string | null;
        hasNext?: boolean;
        hasPrev?: boolean;
      }
    >(this.recordsBase(), {
      method: "GET",
      query: {
        limit: String(opts.limit ?? 30),
        // A non-empty cursor token requests that page; omit it for the first page.
        cursor: opts.cursor && opts.cursor.length > 0 ? opts.cursor : undefined,
        // The server skips totals in cursor mode by default; opt back in explicitly.
        skipTotal: opts.withTotal ? "false" : undefined,
        filter: opts.filter,
        sort: opts.sort,
        expand: opts.expand,
        fields: opts.fields,
        search: opts.search,
      },
      signal: opts.signal,
      requestKey: opts.requestKey,
    });

    return {
      items: body.items,
      nextCursor: body.nextCursor ?? null,
      prevCursor: body.prevCursor ?? null,
      hasNext: !!body.hasNext,
      hasPrev: !!body.hasPrev,
      totalItems: body.totalItems,
    };
  }

  /** Async-iterate every matching record, following the server's `nextCursor`. */
  async *iterate<T extends Record<string, unknown> = ZbRecord>(opts: {
    filter?: string;
    sort?: string;
    expand?: string;
    fields?: string;
    batch?: number;
    search?: string;
    signal?: AbortSignal;
    requestKey?: string;
  } = {}): AsyncIterableIterator<T> {
    let page: CursorPage<T> = await this.getPage<T>({
      limit: opts.batch ?? 100,
      filter: opts.filter,
      sort: opts.sort,
      expand: opts.expand,
      fields: opts.fields,
      search: opts.search,
      signal: opts.signal,
      requestKey: opts.requestKey,
    });
    for (;;) {
      for (const item of page.items) yield item;
      if (!page.hasNext || !page.nextCursor) return;
      page = await this.getPage<T>({
        cursor: page.nextCursor,
        limit: opts.batch ?? 100,
        filter: opts.filter,
        sort: opts.sort,
        expand: opts.expand,
        fields: opts.fields,
        search: opts.search,
        signal: opts.signal,
        requestKey: opts.requestKey,
      });
    }
  }

  /** Accumulate every matching record into an array via the native cursor engine. */
  async getFullList<T extends Record<string, unknown> = ZbRecord>(opts: {
    filter?: string;
    sort?: string;
    expand?: string;
    fields?: string;
    batch?: number;
    search?: string;
    signal?: AbortSignal;
    requestKey?: string;
  } = {}): Promise<T[]> {
    const out: T[] = [];
    for await (const item of this.iterate<T>(opts)) out.push(item);
    return out;
  }
}
