import type { Client } from "../client.js";
import type { CollectionService } from "../collection.js";
import type { ListResult, ZbRecord } from "../records.js";
import type { CursorPage } from "../cursor.js";
import { ZigbaseError } from "../errors.js";
import { compileWhere, type RelationResolver } from "./where.js";
import { makeFilterBuilder, type FilterRoot, type Expr } from "./fluent.js";
import type { CollectionMeta } from "./meta.js";

/** Options the typed list/read surface accepts (loosely typed; narrowed by the generated file). */
export interface TypedListOptions {
  where?: unknown;
  sort?: string;
  expand?: string[];
  page?: number;
  limit?: number;
  fields?: string;
  signal?: AbortSignal;
  requestKey?: string;
}

export interface TypedReadOptions {
  expand?: string[];
  fields?: string;
  signal?: AbortSignal;
  requestKey?: string;
}

export interface TypedPageOptions {
  where?: unknown;
  sort?: string;
  expand?: string[];
  limit?: number;
  cursor?: string;
  withTotal?: boolean;
  signal?: AbortSignal;
  requestKey?: string;
}

/**
 * The broad runtime shape of a typed record service. The generated file casts
 * this (`as unknown as PostsService`) to a CONCRETE per-collection interface
 * whose method generics narrow `expand`, `where`, and create/update payloads.
 */
export interface RawTypedService {
  getList(opts?: TypedListOptions): Promise<ListResult<ZbRecord>>;
  getOne(id: string, opts?: TypedReadOptions): Promise<ZbRecord>;
  getFirstListItem(opts?: TypedListOptions): Promise<ZbRecord>;
  getPage(opts?: TypedPageOptions): Promise<CursorPage<ZbRecord>>;
  iterate(opts?: TypedListOptions): AsyncIterableIterator<ZbRecord>;
  getFullList(opts?: TypedListOptions): Promise<ZbRecord[]>;
  create(data: Record<string, unknown>, opts?: TypedReadOptions): Promise<ZbRecord>;
  update(id: string, data: Record<string, unknown>, opts?: TypedReadOptions): Promise<ZbRecord>;
  delete(id: string): Promise<void>;
  filter(fn: (b: FilterRoot) => Expr): string;
}

const expandList = (e: string[] | undefined): string | undefined =>
  e && e.length > 0 ? e.join(",") : undefined;

/**
 * Build a typed record service over SP1's `client.collection(meta.name)`. A
 * `where` option is compiled to an SP1 `filter` string via `compileWhere`
 * (reusing the same operator mapping + escaping as the fluent builder);
 * `sort`/`expand`/`limit`/`cursor` pass through; results are SP1's. Pass
 * `resolve` to enable one level of nested relation `where`.
 */
export function makeRecordService(
  client: Client,
  meta: CollectionMeta,
  resolve?: RelationResolver,
): RawTypedService {
  const inner = client.collection(meta.name) as CollectionService;
  const builder = makeFilterBuilder(meta);

  const whereToFilter = (where: unknown): string | undefined => {
    const compiled = compileWhere(where, meta, resolve);
    return compiled.length > 0 ? compiled : undefined;
  };

  const readOpts = (opts?: TypedReadOptions) => ({
    expand: expandList(opts?.expand),
    fields: opts?.fields,
    signal: opts?.signal,
    requestKey: opts?.requestKey,
  });

  const listOpts = (opts?: TypedListOptions) => ({
    filter: whereToFilter(opts?.where),
    sort: opts?.sort,
    expand: expandList(opts?.expand),
    fields: opts?.fields,
    signal: opts?.signal,
    requestKey: opts?.requestKey,
  });

  return {
    getList(opts) {
      return inner.getList(opts?.page ?? 1, opts?.limit ?? 30, listOpts(opts));
    },
    getOne(id, opts) {
      return inner.getOne(id, readOpts(opts));
    },
    async getFirstListItem(opts) {
      const filter = whereToFilter(opts?.where);
      const listOpts2 = {
        sort: opts?.sort,
        expand: expandList(opts?.expand),
        fields: opts?.fields,
        signal: opts?.signal,
        requestKey: opts?.requestKey,
      };
      if (filter !== undefined) {
        // A where clause is present: delegate to SP1's getFirstListItem which
        // applies the filter server-side and throws a 404 ZigbaseError when empty.
        return inner.getFirstListItem(filter, listOpts2);
      }
      // No where: avoid passing an empty string to the server (which may match all
      // or behave differently per server). Use getList(1,1) instead and surface
      // the same 404-style ZigbaseError SP1 would throw.
      const res = await inner.getList(1, 1, listOpts2);
      const first = res.items[0];
      if (first === undefined) {
        throw new ZigbaseError({
          status: 404,
          message: "No record found.",
          url: `(${meta.name})`,
        });
      }
      return first;
    },
    getPage(opts) {
      return inner.getPage({
        filter: whereToFilter(opts?.where),
        sort: opts?.sort,
        expand: expandList(opts?.expand),
        limit: opts?.limit,
        cursor: opts?.cursor,
        withTotal: opts?.withTotal,
        signal: opts?.signal,
        requestKey: opts?.requestKey,
      });
    },
    iterate(opts) {
      return inner.iterate({
        filter: whereToFilter(opts?.where),
        sort: opts?.sort,
        expand: expandList(opts?.expand),
        fields: opts?.fields,
        signal: opts?.signal,
        requestKey: opts?.requestKey,
      });
    },
    getFullList(opts) {
      return inner.getFullList({
        filter: whereToFilter(opts?.where),
        sort: opts?.sort,
        expand: expandList(opts?.expand),
        fields: opts?.fields,
        signal: opts?.signal,
        requestKey: opts?.requestKey,
      });
    },
    create(data, opts) {
      return inner.create(data, readOpts(opts));
    },
    update(id, data, opts) {
      return inner.update(id, data, readOpts(opts));
    },
    delete(id) {
      return inner.delete(id);
    },
    filter(fn) {
      return fn(builder).compile();
    },
  };
}
