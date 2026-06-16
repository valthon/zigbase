import type { Transport } from "./transport.js";
import type { AuthStore, AuthRecord } from "./auth-store.js";

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
}
