import type { RealtimeClient, RealtimeEvent } from "../realtime-entry.js";
import type { LiveList } from "../live/live-collection.js";
import type { ZbRecord } from "../records.js";
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

/** Realtime event narrowed to a concrete record type `Rec`. */
export interface TypedRealtimeEvent<Rec> {
  topic: string;
  action: "create" | "update" | "delete";
  record: Rec;
}

/**
 * The typed realtime surface for one collection. Unlike the per-method
 * expand-narrowing services, the realtime surface varies only by the record type
 * `Rec` and the `where` type `Where`, so a single hand-written generic in the
 * typed core covers every collection — the generated file just instantiates it
 * (`RawTypedRealtime<Post, PostWhere>`) instead of emitting a bespoke interface.
 *
 * Defaults (`ZbRecord`, `unknown`) reproduce the original loose shape so callers
 * that don't supply type arguments (e.g. the typed-core's own tests) keep working
 * unchanged.
 */
// NOTE: the record constraint is `{ id: string }`, NOT `ZbRecord`. A concrete
// generated record (e.g. `Post`) has no `[key: string]: unknown` index signature,
// so `Post extends ZbRecord` is FALSE and `RawTypedRealtime<Post>` would fail the
// constraint with "Index signature for type 'string' is missing in type 'Post'".
// The realtime machinery only forwards record VALUES (it never indexes arbitrary
// keys), so `{ id: string }` is the correct, sufficient bound; the default stays
// `ZbRecord` so no-type-argument callers (the typed-core's own tests) are unchanged.
export interface RawTypedRealtime<Rec extends { id: string } = ZbRecord, Where = unknown> {
  subscribe(
    cb: (e: TypedRealtimeEvent<Rec>) => void,
    opts?: { where?: Where },
  ): Promise<() => void>;
  unsubscribe(cb?: (e: TypedRealtimeEvent<Rec>) => void): void;
  getList(opts?: { where?: Where; sort?: string; expand?: string[] }): Promise<LiveList>;
}

export function makeTypedRealtime<Rec extends { id: string } = ZbRecord, Where = unknown>(
  rt: RealtimeClient,
  meta: CollectionMeta,
  resolve?: RelationResolver,
): RawTypedRealtime<Rec, Where> {
  const filterOf = (where: unknown): string | undefined => {
    const compiled = compileWhere(where, meta, resolve);
    return compiled.length > 0 ? compiled : undefined;
  };

  // Accept a comma-joined `expand` string or a string[] (the historic loose
  // shape) and normalize to the comma-joined form SP1 expects.
  const expandOf = (expand: unknown): string | undefined => {
    if (Array.isArray(expand)) return expand.length > 0 ? expand.join(",") : undefined;
    if (typeof expand === "string") return expand.length > 0 ? expand : undefined;
    return undefined;
  };

  const impl = {
    subscribe(cb: (e: RealtimeEvent) => void, opts?: TypedSubscribeOptions) {
      const filter = filterOf(opts?.where);
      return rt.subscribe(meta.name, cb, filter ? { filter } : {});
    },
    unsubscribe(cb?: (e: RealtimeEvent) => void) {
      rt.unsubscribe(meta.name, cb);
    },
    getList(opts?: TypedLiveListOptions) {
      // SP1 LiveCollection.getList(page, perPage, opts) — confirmed in
      // src/live/live-collection.ts. Returns a Promise<LiveList>.
      const perPage = 30;
      const filter = filterOf(opts?.where);
      const expand = expandOf(opts?.expand);
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

  // The body is loosely typed (record: ZbRecord, where: unknown); the generated
  // file's `Rec`/`Where` narrowing is sound because the runtime never inspects
  // those types — it only forwards values. Cast to the typed surface.
  return impl as unknown as RawTypedRealtime<Rec, Where>;
}
