import type { Transport } from "./transport.js";

/** One verified-sender identity of the active account. */
export interface SenderIdentity {
  id: string;
  email: string;
  status: string;
  verified_at: string;
}

/** Verified sender-identity management. `list` requires ZigBase >= 0.10.0 (the `{items}`
 *  envelope); `create`/`verify` exist as of 0.9.0. All three verbs are account-scoped
 *  exactly like the record API (`withAccount` / the `zb_account` cookie / superuser header). */
export class SendersService {
  constructor(private readonly transport: Transport) {}

  /** GET /api/senders — the active account's sender identities. Requires ZigBase >= 0.10.0. */
  list(
    opts: { signal?: AbortSignal; requestKey?: string } = {},
  ): Promise<{ items: SenderIdentity[] }> {
    return this.transport.send<{ items: SenderIdentity[] }>("/api/senders", {
      method: "GET",
      signal: opts.signal,
      requestKey: opts.requestKey,
    });
  }

  /**
   * POST /api/senders — request verification of a From address. The token is EMAILED to
   * that address, never returned. 201 pending / 200 already-verified; rejects with a 429
   * `ZigbaseError` when a re-send is throttled.
   */
  create(
    email: string,
    opts: { signal?: AbortSignal; requestKey?: string } = {},
  ): Promise<{ id: string; email: string; status: string }> {
    return this.transport.send("/api/senders", {
      method: "POST",
      body: { email },
      signal: opts.signal,
      requestKey: opts.requestKey,
    });
  }

  /** POST /api/senders/:id/verify — 404 for a wrong token/account/id (deliberate non-oracle). */
  verify(
    id: string,
    token: string,
    opts: { signal?: AbortSignal; requestKey?: string } = {},
  ): Promise<{ verified: boolean }> {
    return this.transport.send(`/api/senders/${encodeURIComponent(id)}/verify`, {
      method: "POST",
      body: { token },
      signal: opts.signal,
      requestKey: opts.requestKey,
    });
  }
}
