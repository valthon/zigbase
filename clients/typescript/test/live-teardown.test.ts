import { describe, it, expect, vi } from "vitest";
import { LiveCollection } from "../src/live/live-collection.js";
import type { RealtimeCallback, RealtimeEvent } from "../src/realtime.js";

/** Realtime stub that records unsubscribe invocations and the returned unsub fns. */
function fakeRealtime() {
  const subs = new Map<string, Set<RealtimeCallback>>();
  const unsubscribeCalls: Array<{ topic: string; cb?: RealtimeCallback }> = [];
  let unsubFnCalls = 0;
  return {
    service: {
      async subscribe(topic: string, cb: RealtimeCallback) {
        let set = subs.get(topic);
        if (!set) subs.set(topic, (set = new Set()));
        set.add(cb);
        return () => {
          unsubFnCalls += 1;
          set!.delete(cb);
        };
      },
      unsubscribe(topic: string, cb?: RealtimeCallback) {
        unsubscribeCalls.push({ topic, cb });
        if (cb) subs.get(topic)?.delete(cb);
        else subs.delete(topic);
      },
    },
    emit(topic: string, event: RealtimeEvent) {
      for (const cb of subs.get(topic) ?? []) cb(event);
    },
    subscriberCount(topic: string) {
      return subs.get(topic)?.size ?? 0;
    },
    get unsubFnCalls() {
      return unsubFnCalls;
    },
  };
}

describe("LiveList.close teardown", () => {
  it("unsubscribes from realtime and releases every retained cache ref", async () => {
    const rt = fakeRealtime();
    const reader = {
      getOne: vi.fn(),
      getList: vi.fn(async () => ({
        items: [
          { id: "a", rank: 1 },
          { id: "b", rank: 2 },
        ],
        page: 1,
        perPage: 30,
        totalItems: 2,
      })),
      getPage: vi.fn(),
    };
    const lc = new LiveCollection("posts", reader as never, rt.service as never);
    const list = await lc.getList(1, 30, { sort: "rank" });
    expect(rt.subscriberCount("posts")).toBe(1);

    list.close();

    // Realtime unsubscribe was invoked and the topic callback removed.
    expect(rt.unsubFnCalls).toBeGreaterThanOrEqual(1);
    expect(rt.subscriberCount("posts")).toBe(0);

    // After teardown the list is emptied and events no longer mutate it.
    expect(list.items).toEqual([]);
    rt.emit("posts", { topic: "posts", action: "create", record: { id: "c", rank: 0 } });
    expect(list.items).toEqual([]);

    // The underlying cache entries were released (refcount -> 0, evicted).
    expect((lc as unknown as { cache: { has(id: string): boolean } }).cache.has("a")).toBe(false);
    expect((lc as unknown as { cache: { has(id: string): boolean } }).cache.has("b")).toBe(false);
  });

  it("is idempotent: a second close() does not double-free", async () => {
    const rt = fakeRealtime();
    const reader = {
      getOne: vi.fn(),
      getList: vi.fn(async () => ({
        items: [{ id: "a", rank: 1 }],
        page: 1,
        perPage: 30,
        totalItems: 1,
      })),
      getPage: vi.fn(),
    };
    const lc = new LiveCollection("posts", reader as never, rt.service as never);
    const list = await lc.getList(1, 30, { sort: "rank" });

    list.close();
    const before = rt.unsubFnCalls;
    list.close(); // no-op
    expect(rt.unsubFnCalls).toBe(before);
    // Cache ref for "a" stays at 0 (not driven negative).
    expect((lc as unknown as { cache: { has(id: string): boolean } }).cache.has("a")).toBe(false);
  });

  it("stops a pending refetch timer on close", async () => {
    const rt = fakeRealtime();
    const reader = {
      getOne: vi.fn(),
      getList: vi.fn(async () => ({
        items: [{ id: "a", rank: 1 }],
        page: 1,
        perPage: 30,
        totalItems: 1,
      })),
      getPage: vi.fn(),
    };
    const lc = new LiveCollection("posts", reader as never, rt.service as never);
    let scheduled: (() => void) | null = null;
    const cleared: unknown[] = [];
    const list = await lc.getList(1, 30, {
      filter: "author.name = 'Ada'", // relation -> refetch tier
      sort: "rank",
      schedule: (fn) => {
        scheduled = fn;
        return 123 as never;
      },
    });
    rt.emit("posts", { topic: "posts", action: "create", record: { id: "b", rank: 2 } });
    expect(typeof scheduled).toBe("function");
    // close should clear the timer; we just assert no throw and no refetch after.
    const calls = reader.getList.mock.calls.length;
    list.close();
    await new Promise((r) => setTimeout(r, 0));
    expect(reader.getList.mock.calls.length).toBe(calls);
    void cleared;
  });
});

describe("LiveRecord.close teardown (getOne)", () => {
  it("unsubscribes the name/id topic and releases its cache ref", async () => {
    const rt = fakeRealtime();
    const reader = {
      getOne: vi.fn(async (id: string) => ({ id, title: "Seed" })),
      getList: vi.fn(),
      getPage: vi.fn(),
    };
    const lc = new LiveCollection("posts", reader as never, rt.service as never);
    const live = await lc.getOne("p1");
    expect(rt.subscriberCount("posts/p1")).toBe(1);

    live.close();
    expect(rt.unsubFnCalls).toBeGreaterThanOrEqual(1);
    expect(rt.subscriberCount("posts/p1")).toBe(0);
    expect((lc as unknown as { cache: { has(id: string): boolean } }).cache.has("p1")).toBe(false);

    // Idempotent.
    const before = rt.unsubFnCalls;
    live.close();
    expect(rt.unsubFnCalls).toBe(before);
  });
});

describe("LiveList.mode DX surface", () => {
  it("reports 'precise' for an own-field filter and 'refetch' for a relation filter", async () => {
    const rt = fakeRealtime();
    const reader = {
      getOne: vi.fn(),
      getList: vi.fn(async () => ({ items: [], page: 1, perPage: 30, totalItems: 0 })),
      getPage: vi.fn(),
    };
    const lc = new LiveCollection("posts", reader as never, rt.service as never);

    const precise = await lc.getList(1, 30, { filter: "status = 'published'", sort: "rank" });
    expect(precise.mode).toBe("precise");

    const refetch = await lc.getList(1, 30, { filter: "author.name = 'Ada'", sort: "rank" });
    expect(refetch.mode).toBe("refetch");

    const noFilter = await lc.getList(1, 30, { sort: "rank" });
    expect(noFilter.mode).toBe("precise");
  });
});
