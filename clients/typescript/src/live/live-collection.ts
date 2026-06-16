import { RecordCache, LiveRecord } from "./cache.js";
import type { ZbRecord, RealtimeEvent } from "../realtime.js";

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
}
