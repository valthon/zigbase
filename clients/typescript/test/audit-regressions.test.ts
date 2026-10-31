import { describe, expect, it } from "vitest";
import { MemoryAuthStore } from "../src/auth-store.js";
import { analyzeFilter, evaluateFilter, parseFilter } from "../src/live/filter-eval.js";
import { filter } from "../src/query.js";
import { Transport } from "../src/transport.js";
import { LiveCollection } from "../src/live/live-collection.js";
import type { RealtimeCallback } from "../src/realtime.js";

it("joins a pending newer refresh before retrying a delayed old-token 401", async () => {
  const auth = new MemoryAuthStore();
  auth.save("T0", null);
  const gate = () => {
    let resolve!: () => void;
    const promise = new Promise<void>((r) => { resolve = r; });
    return { promise, resolve };
  };
  const delayedStarted = gate();
  const releaseDelayed = gate();
  const secondRefreshStarted = gate();
  const releaseSecondRefresh = gate();
  const delayedTokens: (string | null)[] = [];
  let refreshes = 0;
  const transport = new Transport({
    baseUrl: "http://test", authStore: auth, autoRefresh: true, maxRetries: 0,
    fetch: async (url, init) => {
      const token = new Headers(init?.headers).get("Authorization");
      if (String(url).endsWith("/delayed")) {
        delayedTokens.push(token);
        if (token === "Bearer T0") { delayedStarted.resolve(); await releaseDelayed.promise; }
      }
      return token === "Bearer T2" || (token === "Bearer T1" && String(url).endsWith("/first"))
        ? Response.json({ ok: true }) : Response.json({}, { status: 401 });
    },
    refresh: async () => {
      refreshes += 1;
      if (refreshes === 2) { secondRefreshStarted.resolve(); await releaseSecondRefresh.promise; }
      auth.save(`T${refreshes}`, null);
    },
  });
  const delayed = transport.send("/delayed");
  await delayedStarted.promise;
  await transport.send("/first");
  const newer = transport.send("/newer");
  await secondRefreshStarted.promise;
  releaseDelayed.resolve();
  // Drain the old response's continuation while the newer refresh stays blocked.
  await new Promise((resolve) => setTimeout(resolve, 0));
  expect(delayedTokens).toEqual(["Bearer T0"]);
  releaseSecondRefresh.resolve();
  expect(await newer).toEqual({ ok: true });
  expect(await delayed).toEqual({ ok: true });
  expect(delayedTokens).toEqual(["Bearer T0", "Bearer T2"]);
  expect(refreshes).toBe(2);
});

describe("filter grammar parity", () => {
  it.each(["a\nb", "a\tb", "a\rb", "a\\b", "a'b", 'a"b'])("roundtrips %j", (title) => {
    expect(evaluateFilter({ title }, parseFilter(filter`title = ${title}`))).toBe(true);
  });
  it.each([String.raw`title = 'bad\q'`, "title = 'unfinished", "title = 'trailing\\"])("rejects %s", (input) => {
    expect(() => parseFilter(input)).toThrow();
  });
  it.each(["=", "!="])("refetches for field RHS %s", (op) => {
    expect(analyzeFilter(parseFilter(`left ${op} right`)).locallyEvaluable).toBe(false);
  });
});

it.each(["=", "!="])("field RHS %s invalidates live lists on events", async (op) => {
  let callback!: RealtimeCallback;
  let scheduled!: () => void;
  let calls = 0;
  const reader = {
    getList: async () => {
      calls += 1;
      return { items: [{ id: "a", left: 3, right: 3 }], page: 1, perPage: 30, totalItems: 1 };
    },
  };
  const realtime = { subscribe: async (_topic: string, cb: RealtimeCallback) => {
    callback = cb;
    return () => {};
  } };
  const list = await new LiveCollection("posts", reader as never, realtime as never).getList(1, 30, {
    filter: `left ${op} right`, schedule: (fn) => { scheduled = fn; return 0 as never; },
  });
  callback({ topic: "posts", action: "update", record: { id: "a", left: 3, right: 3 } });
  expect(scheduled).toBeTypeOf("function");
  scheduled();
  await new Promise((resolve) => setTimeout(resolve, 0));
  expect(calls).toBe(2);
  expect(list.items.map((r) => r.id)).toEqual(["a"]);
});

it("preserves escaped control characters in live membership updates", async () => {
  let callback!: RealtimeCallback;
  const reader = { getList: async () => ({
    items: [{ id: "a", title: "a\nb" }], page: 1, perPage: 30, totalItems: 1,
  }) };
  const realtime = { subscribe: async (_topic: string, cb: RealtimeCallback) => {
    callback = cb; return () => {};
  } };
  const list = await new LiveCollection("posts", reader as never, realtime as never).getList(1, 30, {
    filter: filter`title = ${"a\nb"}`,
  });
  callback({ topic: "posts", action: "update", record: { id: "a", title: "a\nb" } });
  expect(list.items.map((r) => r.id)).toEqual(["a"]);
});

it("reuses a completed refresh for a delayed stale 401, but refreshes a later expiry", async () => {
  const auth = new MemoryAuthStore();
  auth.save("old", null);
  let release!: () => void;
  let started!: () => void;
  const delayedStarted = new Promise<void>((resolve) => { started = resolve; });
  const delayed = new Promise<void>((resolve) => { release = resolve; });
  let refreshes = 0;
  let expireNext = false;
  const transport = new Transport({
    baseUrl: "http://test", authStore: auth, autoRefresh: true, maxRetries: 0,
    fetch: async (url, init) => {
      const token = new Headers(init?.headers).get("Authorization");
      if (token === "Bearer old") {
        if (String(url).endsWith("/delayed")) { started(); await delayed; }
        return Response.json({}, { status: 401 });
      }
      if (expireNext) { expireNext = false; return Response.json({}, { status: 401 }); }
      return Response.json({ ok: true });
    },
    refresh: async () => { auth.save(`fresh-${++refreshes}`, null); },
  });
  const second = transport.send("/delayed");
  await delayedStarted;
  expect(await transport.send("/first")).toEqual({ ok: true });
  release();
  expect(await second).toEqual({ ok: true });
  expect(refreshes).toBe(1);
  expireNext = true;
  expect(await transport.send("/later")).toEqual({ ok: true });
  expect(refreshes).toBe(2);
});
