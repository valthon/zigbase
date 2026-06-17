import type { RealtimeClient, RealtimeEvent } from "../realtime-entry.js";
import { compileWhere, type RelationResolver } from "./where.js";
import type { CollectionMeta } from "./meta.js";

/** Options a typed live subscription / live list accepts. */
export interface TypedSubscribeOptions {
  where?: unknown;
}

export interface TypedLiveListOptions {
  where?: unknown;
  sort?: string;
  expand?: string[];
}

/**
 * Broad runtime shape of a typed realtime service for one collection. The
 * generated file casts this to a concrete interface whose `subscribe` callback
 * receives a typed `RealtimeEvent` (record typed to the collection) and whose
 * `getList` returns a typed live list.
 */
export interface RawTypedRealtime {
  subscribe(
    cb: (e: RealtimeEvent) => void,
    opts?: TypedSubscribeOptions,
  ): Promise<() => void>;
  unsubscribe(cb?: (e: RealtimeEvent) => void): void;
  getList(opts?: TypedLiveListOptions): Promise<unknown>;
}

export function makeTypedRealtime(
  rt: RealtimeClient,
  meta: CollectionMeta,
  resolve?: RelationResolver,
): RawTypedRealtime {
  const filterOf = (where: unknown): string | undefined => {
    const compiled = compileWhere(where, meta, resolve);
    return compiled.length > 0 ? compiled : undefined;
  };

  return {
    subscribe(cb, opts) {
      const filter = filterOf(opts?.where);
      return rt.subscribe(meta.name, cb, filter ? { filter } : {});
    },
    unsubscribe(cb) {
      rt.unsubscribe(meta.name, cb);
    },
    getList(opts) {
      // SP1 LiveCollection.getList(page, perPage, opts) — confirmed in
      // src/live/live-collection.ts. Returns a Promise<LiveList>.
      const perPage = 30;
      const filter = filterOf(opts?.where);
      const expand =
        opts?.expand && opts.expand.length > 0 ? opts.expand.join(",") : undefined;
      const listOpts: { filter?: string; sort?: string; expand?: string } = {};
      if (filter !== undefined) listOpts.filter = filter;
      if (opts?.sort !== undefined) listOpts.sort = opts.sort;
      if (expand !== undefined) listOpts.expand = expand;
      return (rt.collection(meta.name) as unknown as {
        getList(
          page: number,
          perPage: number,
          opts?: { filter?: string; sort?: string; expand?: string },
        ): Promise<unknown>;
      }).getList(1, perPage, listOpts);
    },
  };
}
