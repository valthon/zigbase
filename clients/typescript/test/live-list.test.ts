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
      unsubscribe(topic: string, cb?: RealtimeCallback) {
        if (cb) subs.get(topic)?.delete(cb);
        else subs.delete(topic);
      },
    },
    emit(topic: string, event: RealtimeEvent) {
      for (const cb of subs.get(topic) ?? []) cb(event);
    },
  };
}

describe("LiveCollection.getList -> LiveList", () => {
  it("seeds items ordered by sort and notifies observers on changes", async () => {
    const rt = fakeRealtime();
    const reader = {
      getOne: vi.fn(),
      getList: vi.fn(async () => ({
        items: [
          { id: "b", title: "B", rank: 2 },
          { id: "a", title: "A", rank: 1 },
        ],
        page: 1,
        perPage: 30,
        totalItems: 2,
      })),
      getPage: vi.fn(),
    };
    const lc = new LiveCollection("posts", reader as never, rt.service as never);

    const list = await lc.getList(1, 30, { sort: "rank" });
    expect(list.items.map((r) => r.id)).toEqual(["a", "b"]); // sorted by rank asc
    const cb = vi.fn();
    list.subscribe(cb);

    // matching create inserts at sorted position
    rt.emit("posts", {
      topic: "posts",
      action: "create",
      record: { id: "c", title: "C", rank: 0 },
    });
    expect(list.items.map((r) => r.id)).toEqual(["c", "a", "b"]);
    expect(cb).toHaveBeenCalled();
  });

  it("removes on delete and re-sorts in place when an update changes a sort key", async () => {
    const rt = fakeRealtime();
    const reader = {
      getOne: vi.fn(),
      getList: vi.fn(async () => ({
        items: [
          { id: "a", rank: 1 },
          { id: "b", rank: 2 },
          { id: "c", rank: 3 },
        ],
        page: 1,
        perPage: 30,
        totalItems: 3,
      })),
      getPage: vi.fn(),
    };
    const lc = new LiveCollection("posts", reader as never, rt.service as never);
    const list = await lc.getList(1, 30, { sort: "rank" });

    rt.emit("posts", { topic: "posts", action: "delete", record: { id: "b" } });
    expect(list.items.map((r) => r.id)).toEqual(["a", "c"]);

    // update moves "a" to the end and patches it in place
    rt.emit("posts", { topic: "posts", action: "update", record: { id: "a", rank: 9 } });
    expect(list.items.map((r) => r.id)).toEqual(["c", "a"]);
    expect((list.items[1] as unknown as { rank: number }).rank).toBe(9);
  });

  it("drops a record on an update that moves it OUT of an own-field filter", async () => {
    const rt = fakeRealtime();
    const reader = {
      getOne: vi.fn(),
      getList: vi.fn(async () => ({
        items: [
          { id: "a", status: "published", rank: 1 },
          { id: "b", status: "published", rank: 2 },
        ],
        page: 1,
        perPage: 30,
        totalItems: 2,
      })),
      getPage: vi.fn(),
    };
    const lc = new LiveCollection("posts", reader as never, rt.service as never);
    const list = await lc.getList(1, 30, { filter: "status = 'published'", sort: "rank" });

    rt.emit("posts", {
      topic: "posts",
      action: "update",
      record: { id: "a", status: "draft", rank: 1 },
    });
    expect(list.items.map((r) => r.id)).toEqual(["b"]);

    // an update that moves a NEW record INTO the filter inserts it
    rt.emit("posts", {
      topic: "posts",
      action: "update",
      record: { id: "z", status: "published", rank: 0 },
    });
    expect(list.items.map((r) => r.id)).toEqual(["z", "b"]);
  });
});
