import { describe, expect, it, vi } from "vitest";
import { ZigbaseError } from "../src/errors.js";
import { evaluateFilter, parseFilter } from "../src/live/filter-eval.js";
import { LiveCollection, type LiveReader, type LiveSubscriber } from "../src/live/live-collection.js";
import type { RealtimeEvent } from "../src/realtime.js";

const serverFilters = ["'x' = a", "a in ('x', 'y')", "id in @request.auth.roles"];

describe.each(["offset", "cursor"] as const)("%s live filters", (pagination) => {
  it.each(serverFilters)("refetches unsupported local grammar: %s", async (filter) => {
    let callback!: (event: RealtimeEvent) => void;
    let scheduled!: () => void;
    let calls = 0;
    const read = () => [{ id: ++calls === 1 ? "seed" : "fresh", a: "x" }];
    const reader: LiveReader = {
      getOne: vi.fn(),
      getList: vi.fn(async () => ({ items: read(), page: 1, perPage: 30, totalItems: 1 })),
      getPage: vi.fn(async () => ({ items: read(), nextCursor: null })),
    };
    const realtime: LiveSubscriber = {
      subscribe: vi.fn(async (_topic, cb) => { callback = cb; return () => {}; }),
      unsubscribe: vi.fn(),
    };
    const collection = new LiveCollection("posts", reader, realtime);
    const opts = { filter, schedule: (fn: () => void) => { scheduled = fn; return 0 as never; } };
    const list = pagination === "offset"
      ? await collection.getList(1, 30, opts) : await collection.getPage(opts);
    expect(list.mode).toBe("refetch");
    expect(list.items.map((r) => r.id)).toEqual(["seed"]);
    expect(realtime.subscribe).toHaveBeenCalledWith("posts", expect.any(Function), { filter });
    callback({ topic: "posts", action: "update", record: { id: "seed", a: "changed" } });
    expect(list.items.map((r) => r.id)).toEqual(["seed"]);
    scheduled();
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(calls).toBe(2);
    expect(list.items.map((r) => r.id)).toEqual(["fresh"]);
    const request = pagination === "offset" ? reader.getList : reader.getPage;
    const args = pagination === "offset" ? [1, 30, opts] : [opts];
    expect(request).toHaveBeenNthCalledWith(1, ...args);
    expect(request).toHaveBeenNthCalledWith(2, ...args);
    list.close();
  });

  it("propagates the server's HTTP rejection before constructing a live list", async () => {
    const error = new ZigbaseError({ status: 400, message: "invalid filter", url: "/records" });
    const reader: LiveReader = {
      getOne: vi.fn(), getList: vi.fn(async () => { throw error; }),
      getPage: vi.fn(async () => { throw error; }),
    };
    const realtime: LiveSubscriber = { subscribe: vi.fn(), unsubscribe: vi.fn() };
    const collection = new LiveCollection("posts", reader, realtime);
    const promise = pagination === "offset"
      ? collection.getList(1, 30, { filter: "a = -b" }) : collection.getPage({ filter: "a = -b" });
    await expect(promise).rejects.toBe(error);
    expect(realtime.subscribe).not.toHaveBeenCalled();
  });
});

it.each(["a = 1.2.3", "a = -b", "-b = 1", "a = in", "a & b"])("rejects invalid local barewords: %s", (filter) => {
  expect(() => parseFilter(filter)).toThrow();
});

it("treats CR as a token terminator and keeps supported filters precise", async () => {
  const filter = "a\r=\r'x'\r&&\rn >= -2";
  expect(evaluateFilter({ a: "x", n: 1 }, parseFilter(filter))).toBe(true);
  let callback!: (event: RealtimeEvent) => void;
  const reader = { getList: async () => ({ items: [{ id: "a", a: "x", n: 1 }], page: 1, perPage: 30, totalItems: 1 }) };
  const realtime = { subscribe: async (_topic: string, cb: (event: RealtimeEvent) => void) => { callback = cb; return () => {}; } };
  const list = await new LiveCollection("posts", reader as never, realtime as never).getList(1, 30, { filter });
  expect(list.mode).toBe("precise");
  callback({ topic: "posts", action: "update", record: { id: "a", a: "other", n: 1 } });
  expect(list.items).toEqual([]);
  list.close();
});
