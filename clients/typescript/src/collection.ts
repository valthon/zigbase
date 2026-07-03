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

/** The actions the current principal may perform on a specific record (#155). */
export interface RecordAbilities {
  view: boolean;
  update: boolean;
  delete: boolean;
}

/** One active server-side session row (server `.session_store = .table` only). */
export interface SessionInfo {
  id: string;
  created: string;
  last_seen: string;
  user_agent: string;
  ip: string;
  /** True for the session THIS request was authenticated with. */
  is_current: boolean;
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

  /** Changed in server 0.10: was `{providers}`, now the house `{items}` list envelope. */
  listAuthProviders(): Promise<{ items: OAuth2Provider[] }> {
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

  /**
   * Change an auth record's password via `PATCH /records/:id` with `{ password, oldPassword }`
   * (requires ZigBase >= 0.10.0). The server verifies `oldPassword` against the TARGET record
   * (superusers are exempt) and rotates its tokenKey — every outstanding session dies. For a
   * self-change the server re-issues THIS device's session via Set-Cookie (cookie mode needs
   * nothing else); this helper additionally re-runs `authWithPassword` with the stored identity
   * and the new password when the store's principal IS the target, so bearer-token clients stay
   * logged in too (a harmless extra login in cookie mode). Wrong/missing `oldPassword` rejects
   * with the login-identical 400 "Invalid credentials." (non-oracle). `oldPassword` also passes
   * through plain `update()` for callers who want the raw record response.
   */
  async changePassword(id: string, oldPassword: string, newPassword: string): Promise<void> {
    await this.update(id, { password: newPassword, oldPassword });
    const rec = this.authStore.record as Record<string, unknown> | null;
    const identity = (rec?.["email"] ?? rec?.["username"]) as string | undefined;
    if (rec?.["id"] === id && identity) {
      await this.authWithPassword(identity, newPassword);
    }
  }

  /**
   * GET /api/collections/:col/auth/sessions — the caller's active sessions, newest first
   * (requires the server to run `.session_store = .table`; the default `.epoch` mode
   * answers 404, surfaced as a standard ZigbaseError).
   */
  async listSessions(opts: { signal?: AbortSignal; requestKey?: string } = {}): Promise<SessionInfo[]> {
    const res = await this.transport.send<{ items: SessionInfo[] }>(`${this.base()}/auth/sessions`, {
      method: "GET",
      signal: opts.signal,
      requestKey: opts.requestKey,
    });
    return res.items;
  }

  /**
   * DELETE /api/collections/:col/auth/sessions/:sid — "log out THIS device" (table mode
   * only). A non-owned or absent id is a 404, indistinguishable by design.
   */
  revokeSession(id: string, opts: { signal?: AbortSignal; requestKey?: string } = {}): Promise<void> {
    return this.transport.send<void>(`${this.base()}/auth/sessions/${encodeURIComponent(id)}`, {
      method: "DELETE",
      signal: opts.signal,
      requestKey: opts.requestKey,
    });
  }

  /**
   * DELETE /api/collections/:col/auth/sessions — "log out everywhere" (works in BOTH
   * session-store modes: epoch bump + table-row wipe). The current session dies too;
   * the local auth store is cleared even if the request fails (parity with `logout()`).
   */
  async revokeAllSessions(): Promise<void> {
    try {
      await this.transport.send<void>(`${this.base()}/auth/sessions`, { method: "DELETE" });
    } finally {
      this.authStore.clear();
    }
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
   * GET /api/collections/:col/records/:id/abilities — the actions the current principal
   * may perform on this record (requires ZigBase >= 0.9.0). Rejects with a 404
   * `ZigbaseError` when the record is not viewable — the endpoint never reveals a
   * record's existence, so `view` is always `true` on a success.
   */
  getAbilities(
    id: string,
    opts: { signal?: AbortSignal; requestKey?: string } = {},
  ): Promise<RecordAbilities> {
    return this.transport.send<RecordAbilities>(
      `${this.recordsBase()}/${encodeURIComponent(id)}/abilities`,
      { method: "GET", signal: opts.signal, requestKey: opts.requestKey },
    );
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
