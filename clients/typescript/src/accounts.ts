import type { Transport } from "./transport.js";

/** The active account scope returned by `POST /api/accounts/:id/activate`. */
export interface AccountScope {
  account: string;
  role: string;
}

/** Multi-tenancy account operations (requires ZigBase >= 0.9.0 with `.tenancy` enabled). */
export class AccountsService {
  constructor(private readonly transport: Transport) {}

  /**
   * POST /api/accounts/:id/activate — verifies an ACTIVE membership, sets the signed
   * `zb_account` cookie (same-origin browser apps; the default `credentials: "same-origin"`
   * keeps it), and returns the scope. 403 when not a member; 404 when tenancy is disabled.
   * API/SSR clients should prefer `client.withAccount(id)` / the `accountId` option —
   * the SDK never reads the cookie.
   */
  activate(
    accountId: string,
    opts: { signal?: AbortSignal; requestKey?: string } = {},
  ): Promise<AccountScope> {
    return this.transport.send<AccountScope>(
      `/api/accounts/${encodeURIComponent(accountId)}/activate`,
      { method: "POST", signal: opts.signal, requestKey: opts.requestKey },
    );
  }
}
