import { RecordCache, LiveRecord, type Observable } from "./cache.js";
import type { ZbRecord, RealtimeEvent } from "../realtime.js";
import { parseSort, compareBySort, type SortTerm } from "../query.js";
import { parseFilter, evaluateFilter, analyzeFilter, type FilterNode } from "./filter-eval.js";

/** The subset of RecordService the live store reads through. */
export interface LiveReader {
  getOne(id: string, opts?: { expand?: string }): Promise<ZbRecord>;
  getList(
    page: number,
    perPage: number,
    opts?: { filter?: string; sort?: string; expand?: string },
  ): Promise<{ items: ZbRecord[]; page: number; perPage: number; totalItems: number }>;
  getPage(opts?: {
    cursor?: string;
    limit?: number;
    filter?: string;
    sort?: string;
    expand?: string;
  }): Promise<{ items: ZbRecord[]; nextCursor: string | null }>;
}

/** The subset of RealtimeService the live store subscribes through. */
export interface LiveSubscriber {
  subscribe(
    topic: string,
    cb: (e: RealtimeEvent) => void,
    opts?: { filter?: string },
  ): Promise<() => void>;
  unsubscribe(topic: string, cb?: (e: RealtimeEvent) => void): void;
}

export interface LiveListOpts {
  filter?: string;
  sort?: string;
  expand?: string;
}

export class LiveList implements Observable<LiveRecord[]> {
  readonly items: LiveRecord[] = [];
  private _version = 0;
  private readonly listeners = new Set<() => void>();
  private readonly sortTerms: SortTerm[];
  private readonly filterAst: FilterNode | undefined;
  private readonly precise: boolean;
  private refetchTimer: ReturnType<typeof setTimeout> | null = null;

  constructor(
    private readonly cache: RecordCache,
    seed: ZbRecord[],
    private readonly opts: LiveListOpts,
    private readonly onRefetch: () => Promise<ZbRecord[]>,
    private readonly refetch: {
      debounceMs: number;
      schedule: (fn: () => void, ms: number) => ReturnType<typeof setTimeout>;
    },
  ) {
    // Always include `id` as a final tiebreaker for a deterministic order.
    this.sortTerms = appendIdTiebreaker(parseSort(opts.sort ?? ""));
    this.filterAst = opts.filter ? parseFilter(opts.filter) : undefined;
    this.precise = analyzeFilter(this.filterAst).locallyEvaluable;

    for (const rec of seed) {
      this.items.push(this.cache.retain(rec));
    }
    this.sortItems();
  }

  get version(): number {
    return this._version;
  }

  get(): LiveRecord[] {
    return this.items;
  }

  subscribe(cb: () => void): () => void {
    this.listeners.add(cb);
    return () => this.listeners.delete(cb);
  }

  /** Called by LiveCollection for each realtime event on the collection topic. */
  handleEvent(event: RealtimeEvent): void {
    if (!this.precise) {
      this.scheduleRefetch();
      return;
    }
    if (event.action === "delete") {
      this.removeById(event.record.id);
      return;
    }
    const matches = this.filterAst ? evaluateFilter(event.record, this.filterAst) : true;
    const idx = this.items.findIndex((r) => r.id === event.record.id);
    if (matches) {
      if (idx === -1) {
        this.items.push(this.cache.retain(event.record));
      } else {
        this.cache.applyUpdate(event.record);
      }
      this.sortItems();
      this.bump();
    } else if (idx !== -1) {
      this.removeById(event.record.id);
    }
  }

  private removeById(id: string): void {
    const idx = this.items.findIndex((r) => r.id === id);
    if (idx === -1) return;
    this.items.splice(idx, 1);
    this.cache.release(id);
    this.bump();
  }

  private sortItems(): void {
    this.items.sort((a, b) => compareBySort(a.get(), b.get(), this.sortTerms));
  }

  private scheduleRefetch(): void {
    if (this.refetchTimer) return;
    this.refetchTimer = this.refetch.schedule(() => {
      this.refetchTimer = null;
      void this.doRefetch();
    }, this.refetch.debounceMs);
  }

  private async doRefetch(): Promise<void> {
    const fresh = await this.onRefetch();
    const nextIds = new Set(fresh.map((r) => r.id));
    // Release rows that fell out.
    for (const r of [...this.items]) {
      if (!nextIds.has(r.id)) this.removeById(r.id);
    }
    // Insert/patch the fresh set.
    for (const rec of fresh) {
      const idx = this.items.findIndex((r) => r.id === rec.id);
      if (idx === -1) this.items.push(this.cache.retain(rec));
      else this.cache.applyUpdate(rec);
    }
    this.sortItems();
    this.bump();
  }

  private bump(): void {
    this._version += 1;
    for (const cb of this.listeners) cb();
  }
}

function appendIdTiebreaker(terms: SortTerm[]): SortTerm[] {
  if (terms.some((t) => t.field === "id")) return terms;
  return [...terms, { field: "id", dir: "asc" }];
}

export class LiveCollection {
  private readonly cache = new RecordCache();

  constructor(
    readonly name: string,
    private readonly reader: LiveReader,
    private readonly realtime: LiveSubscriber,
  ) {}

  /** Returns a wrapped live record, seeded via REST and kept live via `name/id`. */
  async getOne(id: string, opts?: { expand?: string }): Promise<LiveRecord> {
    const seed = await this.reader.getOne(id, opts);
    const live = this.cache.retain(seed);
    await this.realtime.subscribe(`${this.name}/${id}`, (event) => {
      if (event.action === "delete") this.cache.applyDelete(id);
      else this.cache.applyUpdate(event.record);
    });
    return live;
  }

  async getList(
    page = 1,
    perPage = 30,
    opts: LiveListOpts & {
      refetchDebounceMs?: number;
      schedule?: (fn: () => void, ms: number) => ReturnType<typeof setTimeout>;
    } = {},
  ): Promise<LiveList> {
    const seed = await this.reader.getList(page, perPage, opts);
    return this.buildList(seed.items, opts, () =>
      this.reader.getList(page, perPage, opts).then((r) => r.items),
    );
  }

  async getPage(
    opts: LiveListOpts & {
      cursor?: string;
      limit?: number;
      refetchDebounceMs?: number;
      schedule?: (fn: () => void, ms: number) => ReturnType<typeof setTimeout>;
    } = {},
  ): Promise<LiveList> {
    const seed = await this.reader.getPage(opts);
    return this.buildList(seed.items, opts, () =>
      this.reader.getPage(opts).then((r) => r.items),
    );
  }

  private async buildList(
    seed: ZbRecord[],
    opts: LiveListOpts & {
      refetchDebounceMs?: number;
      schedule?: (fn: () => void, ms: number) => ReturnType<typeof setTimeout>;
    },
    onRefetch: () => Promise<ZbRecord[]>,
  ): Promise<LiveList> {
    const list = new LiveList(this.cache, seed, opts, onRefetch, {
      debounceMs: opts.refetchDebounceMs ?? 200,
      schedule: opts.schedule ?? ((fn, ms) => setTimeout(fn, ms)),
    });
    await this.realtime.subscribe(
      this.name,
      (event) => list.handleEvent(event),
      opts.filter ? { filter: opts.filter } : undefined,
    );
    return list;
  }
}
