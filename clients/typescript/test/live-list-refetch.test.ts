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

describe("LiveList refetch fallback (relation filter)", () => {
  it("debounces and re-fetches the query on relevant events instead of guessing membership", async () => {
    const rt = fakeRealtime();
    let listCalls = 0;
    const pages = [
      [{ id: "a", rank: 1 }],
      [
        { id: "a", rank: 1 },
        { id: "b", rank: 2 },
      ],
    ];
    const reader = {
      getOne: vi.fn(),
      getList: vi.fn(async () => ({
        items: pages[Math.min(listCalls++, pages.length - 1)]!,
        page: 1,
        perPage: 30,
        totalItems: 2,
      })),
      getPage: vi.fn(),
    };
    const lc = new LiveCollection("posts", reader as never, rt.service as never);

    // Manually-driven scheduler so the test controls debounce flushing.
    let scheduled: (() => void) | null = null;
    const list = await lc.getList(1, 30, {
      // relation traversal -> NOT locally evaluable -> refetch fallback
      filter: "author.name = 'Ada'",
      sort: "rank",
      refetchDebounceMs: 50,
      schedule: (fn) => {
        scheduled = fn;
        return 0 as never;
      },
    });
    expect(list.items.map((r) => r.id)).toEqual(["a"]);

    // Two events arrive; only one refetch should be scheduled (debounced).
    rt.emit("posts", { topic: "posts", action: "create", record: { id: "b", rank: 2 } });
    rt.emit("posts", { topic: "posts", action: "create", record: { id: "x", rank: 9 } });
    expect(typeof scheduled).toBe("function");

    // Flush the debounce.
    scheduled!();
    await new Promise((r) => setTimeout(r, 0));

    expect(reader.getList).toHaveBeenCalledTimes(2); // initial seed + one refetch
    expect(list.items.map((r) => r.id)).toEqual(["a", "b"]);
  });
});
