import { describe, it, expect, vi } from "vitest";
import { LiveCollection } from "../src/live/live-collection.js";
import type { RealtimeCallback, RealtimeEvent } from "../src/realtime.js";

/** A minimal realtime stub that lets the test push events for a topic. */
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
    subscriberCount(topic: string) {
      return subs.get(topic)?.size ?? 0;
    },
  };
}

describe("LiveCollection.getOne", () => {
  it("seeds via REST getOne and returns a wrapped live record", async () => {
    const rt = fakeRealtime();
    const reader = {
      getOne: vi.fn(async (id: string) => ({ id, title: "Seed" })),
      getList: vi.fn(),
      getPage: vi.fn(),
    };
    const lc = new LiveCollection("posts", reader as never, rt.service as never);

    const live = await lc.getOne("p1");
    expect(reader.getOne).toHaveBeenCalledWith("p1", undefined);
    expect(live.get().title).toBe("Seed");
    expect((live as unknown as { title: string }).title).toBe("Seed");
    expect(rt.subscriberCount("posts/p1")).toBe(1);
  });

  it("patches the live record in place on an update event", async () => {
    const rt = fakeRealtime();
    const reader = {
      getOne: vi.fn(async (id: string) => ({ id, title: "Seed", views: 1 })),
      getList: vi.fn(),
      getPage: vi.fn(),
    };
    const lc = new LiveCollection("posts", reader as never, rt.service as never);
    const live = await lc.getOne("p1");
    const cb = vi.fn();
    live.subscribe(cb);

    rt.emit("posts/p1", {
      topic: "posts/p1",
      action: "update",
      record: { id: "p1", title: "Edited", views: 9 },
    });
    expect(live.get().title).toBe("Edited");
    expect((live as unknown as { views: number }).views).toBe(9);
    expect(cb).toHaveBeenCalledTimes(1);
  });

  it("flags the record deleted on a delete event", async () => {
    const rt = fakeRealtime();
    const reader = {
      getOne: vi.fn(async (id: string) => ({ id, title: "Seed" })),
      getList: vi.fn(),
      getPage: vi.fn(),
    };
    const lc = new LiveCollection("posts", reader as never, rt.service as never);
    const live = await lc.getOne("p1");
    rt.emit("posts/p1", { topic: "posts/p1", action: "delete", record: { id: "p1" } });
    expect(live.deleted).toBe(true);
  });
});
