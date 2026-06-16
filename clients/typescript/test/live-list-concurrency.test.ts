import { describe, it, expect, vi } from "vitest";
import { LiveCollection } from "../src/live/live-collection.js";
import type { RealtimeCallback, RealtimeEvent } from "../src/realtime.js";

function fakeRealtime() {
  const subs = new Map<string, Set<RealtimeCallback>>();
  return {
    service: {
      async subscribe(topic: string, cb: RealtimeCallback) {
        let set = subs.get(topic);
        if (!set) subs.set(topic, (set = new Set()));
        set.add(cb);
        return () => set!.delete(cb);
      },
      unsubscribe() {},
    },
    emit(topic: string, event: RealtimeEvent) {
      for (const cb of subs.get(topic) ?? []) cb(event);
    },
  };
}

describe("LiveList refetch concurrency guard", () => {
  it("never runs two refetches in parallel and reconciles to the latest data", async () => {
    const rt = fakeRealtime();

    // A reader whose getList we can hold open, to force overlap.
    let inFlight = 0;
    let maxInFlight = 0;
    const resolvers: Array<(items: { id: string; rank: number }[]) => void> = [];
    let call = 0;
    const reader = {
      getOne: vi.fn(),
      getList: vi.fn(() => {
        call += 1;
        if (call === 1) {
          // synchronous seed
          return Promise.resolve({
            items: [{ id: "a", rank: 1 }],
            page: 1,
            perPage: 30,
            totalItems: 1,
          });
        }
        inFlight += 1;
        maxInFlight = Math.max(maxInFlight, inFlight);
        return new Promise((resolve) => {
          resolvers.push((items) => {
            inFlight -= 1;
            resolve({ items, page: 1, perPage: 30, totalItems: items.length });
          });
        });
      }),
      getPage: vi.fn(),
    };
    const lc = new LiveCollection("posts", reader as never, rt.service as never);

    // Synchronous scheduler so each event flushes a refetch attempt immediately.
    const list = await lc.getList(1, 30, {
      filter: "author.name = 'Ada'", // relation -> refetch tier
      sort: "rank",
      schedule: (fn) => {
        fn();
        return 0 as never;
      },
    });
    expect(list.items.map((r) => r.id)).toEqual(["a"]);

    // Burst of events: each triggers scheduleRefetch synchronously.
    rt.emit("posts", { topic: "posts", action: "create", record: { id: "b", rank: 2 } });
    rt.emit("posts", { topic: "posts", action: "create", record: { id: "c", rank: 3 } });
    rt.emit("posts", { topic: "posts", action: "create", record: { id: "d", rank: 4 } });

    // Exactly one refetch should be in flight despite the burst.
    expect(maxInFlight).toBe(1);
    expect(resolvers.length).toBe(1);

    // Complete the first refetch with stale data; because more events came in
    // while it ran, a second refetch must auto-run on completion.
    resolvers.shift()!([
      { id: "a", rank: 1 },
      { id: "b", rank: 2 },
    ]);
    await new Promise((r) => setTimeout(r, 0));

    // A rerun was requested -> a second fetch fires (still only one at a time).
    expect(resolvers.length).toBe(1);
    expect(maxInFlight).toBe(1);

    // Final reconcile reflects the latest data.
    resolvers.shift()!([
      { id: "a", rank: 1 },
      { id: "b", rank: 2 },
      { id: "c", rank: 3 },
      { id: "d", rank: 4 },
    ]);
    await new Promise((r) => setTimeout(r, 0));
    expect(list.items.map((r) => r.id)).toEqual(["a", "b", "c", "d"]);
  });
});

describe("LiveList sorted insertion", () => {
  it("lands a matching create at the correct sorted position via insertion", async () => {
    const rt = fakeRealtime();
    const reader = {
      getOne: vi.fn(),
      getList: vi.fn(async () => ({
        items: [
          { id: "a", rank: 10 },
          { id: "c", rank: 30 },
          { id: "e", rank: 50 },
        ],
        page: 1,
        perPage: 30,
        totalItems: 3,
      })),
      getPage: vi.fn(),
    };
    const lc = new LiveCollection("posts", reader as never, rt.service as never);
    const list = await lc.getList(1, 30, { sort: "rank" });
    expect(list.items.map((r) => r.id)).toEqual(["a", "c", "e"]);

    // Insert in the middle.
    rt.emit("posts", { topic: "posts", action: "create", record: { id: "d", rank: 40 } });
    expect(list.items.map((r) => r.id)).toEqual(["a", "c", "d", "e"]);
    // Insert at the front.
    rt.emit("posts", { topic: "posts", action: "create", record: { id: "z", rank: 5 } });
    expect(list.items.map((r) => r.id)).toEqual(["z", "a", "c", "d", "e"]);
    // Insert at the end.
    rt.emit("posts", { topic: "posts", action: "create", record: { id: "y", rank: 99 } });
    expect(list.items.map((r) => r.id)).toEqual(["z", "a", "c", "d", "e", "y"]);
  });

  it("O(1) membership: get(id) returns the live record", async () => {
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
    expect(list.getById("a")?.id).toBe("a");
    expect(list.getById("missing")).toBeUndefined();
  });
});
