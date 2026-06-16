import type { ZbRecord } from "../realtime.js";

/** Framework-agnostic observable contract (matches the spec). */
export interface Observable<T> {
  subscribe(cb: () => void): () => void;
  get(): T;
  readonly version: number;
}

/**
 * A wrapped record that "looks exactly like the record it wraps": every
 * enumerable field of the backing object is exposed as a same-named getter, so
 * `live.title` reads through to the current backing data. Identity is stable —
 * updates patch the backing object IN PLACE and bump `version`; deletes set
 * `deleted = true`. Bind via the Observable contract.
 */
export class LiveRecord<T extends ZbRecord = ZbRecord> implements Observable<T> {
  deleted = false;
  private _version = 0;
  private backing: T;
  private readonly listeners = new Set<() => void>();
  private readonly proxied = new Set<string>();

  constructor(initial: T) {
    this.backing = initial;
    this.defineAccessors(Object.keys(initial));
  }

  get id(): string {
    return this.backing.id;
  }

  get version(): number {
    return this._version;
  }

  get(): T {
    return this.backing;
  }

  /** Returns the current data; alias kept for ergonomics. */
  get data(): T {
    return this.backing;
  }

  subscribe(cb: () => void): () => void {
    this.listeners.add(cb);
    return () => this.listeners.delete(cb);
  }

  /** Patch backing fields in place (used by the cache on update events). */
  patch(next: T): void {
    // Mutate the SAME backing object so external `.get()` references stay live.
    const target = this.backing as Record<string, unknown>;
    for (const k of Object.keys(target)) {
      if (!(k in next)) delete target[k];
    }
    Object.assign(target, next);
    this.defineAccessors(Object.keys(next));
    this.bump();
  }

  markDeleted(): void {
    this.deleted = true;
    this.bump();
  }

  private defineAccessors(keys: string[]): void {
    for (const key of keys) {
      if (key === "id" || key === "version" || key === "deleted" || this.proxied.has(key)) {
        continue;
      }
      this.proxied.add(key);
      Object.defineProperty(this, key, {
        configurable: true,
        enumerable: true,
        get: () => (this.backing as Record<string, unknown>)[key],
      });
    }
  }

  private bump(): void {
    this._version += 1;
    for (const cb of this.listeners) cb();
  }
}

interface Entry {
  record: LiveRecord;
  refs: number;
}

/**
 * Per-collection record cache keyed by record id. Hands out the SAME LiveRecord
 * for a given id so one event updates every view. Ref-counted: retained while
 * ≥1 live view/observer references it; evicted at zero.
 */
export class RecordCache {
  private readonly entries = new Map<string, Entry>();

  /** Retain (and create-or-merge) the record for `data.id`; +1 refcount. */
  retain<T extends ZbRecord>(data: T): LiveRecord<T> {
    const existing = this.entries.get(data.id);
    if (existing) {
      existing.refs += 1;
      // Merge fresher data without losing identity.
      existing.record.patch(data);
      return existing.record as LiveRecord<T>;
    }
    const record = new LiveRecord<T>(data);
    this.entries.set(data.id, { record, refs: 1 });
    return record;
  }

  get<T extends ZbRecord = ZbRecord>(id: string): LiveRecord<T> | undefined {
    return this.entries.get(id)?.record as LiveRecord<T> | undefined;
  }

  has(id: string): boolean {
    return this.entries.has(id);
  }

  release(id: string): void {
    const entry = this.entries.get(id);
    if (!entry) return;
    entry.refs -= 1;
    if (entry.refs <= 0) this.entries.delete(id);
  }

  applyUpdate<T extends ZbRecord>(data: T): void {
    this.entries.get(data.id)?.record.patch(data);
  }

  applyDelete(id: string): void {
    this.entries.get(id)?.record.markDeleted();
  }
}
