import type { AuthStore } from "./auth-store.js";
import type { Transport } from "./transport.js";

/**
 * The minimal surface the live store reads through. Structurally a subset of
 * `CollectionService`; declared here (not imported from the realtime graph) so
 * the base entry can hand realtime a reader factory without pulling realtime in.
 */
export interface InternalReader {
  getOne(id: string, opts?: { expand?: string; fields?: string }): Promise<{ id: string; [k: string]: unknown }>;
  getList(
    page: number,
    perPage: number,
    opts?: { filter?: string; sort?: string; expand?: string; fields?: string },
  ): Promise<{ items: Array<{ id: string; [k: string]: unknown }>; page: number; perPage: number; totalItems: number }>;
  getPage(opts?: {
    cursor?: string;
    limit?: number;
    filter?: string;
    sort?: string;
    expand?: string;
    fields?: string;
  }): Promise<{ items: Array<{ id: string; [k: string]: unknown }>; nextCursor: string | null }>;
}

/**
 * Everything the realtime entry needs to bolt itself onto a base client, carried
 * under a unique symbol. This module is deliberately side-effect-free and imports
 * NOTHING from the realtime/live/filter-eval graph, so a REST-only bundle that
 * never touches `@zigbase/client/realtime` can fully shake that graph out.
 */
export interface ClientInternals {
  readonly transport: Transport;
  readonly authStore: AuthStore;
  readonly baseUrl: string;
  /** Resolved WebSocket factory (injected or global); undefined when unavailable. */
  readonly WebSocket: typeof WebSocket | undefined;
  /** Per-collection record reader the live store wraps. */
  readonly makeReader: (name: string) => InternalReader;
}

/** Non-enumerable key under which `createClient` stashes {@link ClientInternals}. */
export const INTERNALS: unique symbol = Symbol("zigbase.internals");

export type WithInternals = { readonly [INTERNALS]: ClientInternals };
