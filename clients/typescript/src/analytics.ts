import type { Transport } from "./transport.js";

/** One row of the tenant-scoped activity feed (`_events`). Field names are the wire's snake_case. */
export interface AnalyticsEvent {
  id: string;
  created: string;
  name: string;
  /** JSON value; null when unparseable/empty. */
  payload: unknown;
  actor_collection: string;
  actor: string;
  account: string;
  occurred_at: string;
}

/** One summary row of a declared rollup. */
export interface RollupBucket {
  bucket: string;
  account: string;
  actor: string;
  value: number;
  computed_at: string;
}

const iso = (d: string | Date | undefined): string | undefined =>
  d instanceof Date ? d.toISOString() : d;

/** Product-analytics read APIs (requires ZigBase >= 0.9.0). Tenant-scoped, fail closed. */
export class AnalyticsService {
  constructor(private readonly transport: Transport) {}

  /**
   * GET /api/analytics/events — the tenant-scoped activity feed. 401 anonymous; empty
   * `items` with no active account; a superuser sees everything. Paginates with the house
   * cursor: pass the previous page's `nextCursor` back as `opts.cursor` to fetch the next one;
   * `hasNext` is false (and `nextCursor` null) on the last page.
   */
  events(
    opts: {
      name?: string;
      actor?: string;
      since?: string | Date;
      limit?: number;
      cursor?: string;
      signal?: AbortSignal;
      requestKey?: string;
    } = {},
  ): Promise<{ items: AnalyticsEvent[]; nextCursor: string | null; hasNext: boolean }> {
    return this.transport.send<{ items: AnalyticsEvent[]; nextCursor: string | null; hasNext: boolean }>(
      "/api/analytics/events",
      {
        method: "GET",
        query: {
          name: opts.name,
          actor: opts.actor,
          since: iso(opts.since),
          limit: opts.limit,
          cursor: opts.cursor,
        },
        signal: opts.signal,
        requestKey: opts.requestKey,
      },
    );
  }

  /**
   * GET /api/analytics/rollups/:name — a declared rollup's summary rows. 404 for an
   * undeclared name; 403 for a non-account-grouped rollup queried by a non-superuser.
   */
  rollup(
    name: string,
    opts: {
      from?: string | Date;
      to?: string | Date;
      signal?: AbortSignal;
      requestKey?: string;
    } = {},
  ): Promise<{ items: RollupBucket[] }> {
    return this.transport.send<{ items: RollupBucket[] }>(
      `/api/analytics/rollups/${encodeURIComponent(name)}`,
      {
        method: "GET",
        query: { from: iso(opts.from), to: iso(opts.to) },
        signal: opts.signal,
        requestKey: opts.requestKey,
      },
    );
  }
}
