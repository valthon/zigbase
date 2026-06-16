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

export interface AuthResponse {
  token: string;
  record: AuthRecord;
  meta?: Record<string, unknown>;
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
      skipAuth: path === "/auth-with-password" || path === "/auth-with-oauth2",
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

  authWithOAuth2(args: OAuth2Args): Promise<AuthResponse> {
    return this.authRequest("/auth-with-oauth2", args);
  }

  async logout(): Promise<void> {
    try {
      await this.transport.send<void>(`${this.base()}/auth-logout`, { method: "POST" });
    } finally {
      this.authStore.clear();
    }
  }

  listAuthProviders(): Promise<{ providers: OAuth2Provider[] }> {
    return this.transport.send(`${this.base()}/oauth2-providers`, { method: "GET" });
  }

  oauth2Init(provider: string): Promise<{ state: string }> {
    return this.transport.send(`${this.base()}/oauth2-init`, {
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
      },
      signal: opts.signal,
    });
  }

  getOne<T = ZbRecord>(id: string, opts: RecordCrudOpts = {}): Promise<T> {
    return this.transport.send<T>(`${this.recordsBase()}/${encodeURIComponent(id)}`, {
      method: "GET",
      query: { expand: opts.expand, fields: opts.fields },
      signal: opts.signal,
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
    });
  }

  async delete(id: string): Promise<void> {
    await this.transport.send<void>(`${this.recordsBase()}/${encodeURIComponent(id)}`, {
      method: "DELETE",
    });
  }
}
