import { expect, it } from "vitest";
import { MemoryAuthStore } from "../src/auth-store.js";
import { Transport } from "../src/transport.js";

const overload = '{"code":"overloaded","message":"busy"}';

it.each(["POST", "PATCH", "DELETE"])("retries pre-routing overload for %s without duplicating effects", async (method) => {
  let calls = 0;
  let effects = 0;
  const delays: number[] = [];
  const t = new Transport({
    baseUrl: "http://api.test", authStore: new MemoryAuthStore(), autoRefresh: false,
    maxRetries: 2, sleep: async (ms) => { delays.push(ms); },
    fetch: (async (_url, opts) => {
      expect(opts?.method).toBe(method);
      expect(opts?.body).toBe('{"value":1}');
      if (++calls <= 2) return new Response(overload, { status: 503, headers: { "Retry-After": "1" } });
      effects++;
      return new Response(null, { status: 204 });
    }) as typeof fetch,
  });
  await t.send("/api/write", { method, body: { value: 1 } });
  expect([calls, effects]).toEqual([3, 1]);
  expect(delays).toEqual([1000, 1000]);
});

it.each([0, 2])("bounds overload retries with maxRetries=%i", async (maxRetries) => {
  let calls = 0;
  const delays: number[] = [];
  const t = new Transport({
    baseUrl: "http://api.test", authStore: new MemoryAuthStore(), autoRefresh: false,
    maxRetries, sleep: async (ms) => { delays.push(ms); },
    fetch: (async () => { calls++; return new Response(overload, { status: 503 }); }) as typeof fetch,
  });
  await expect(t.send("/api/write", { method: "POST" })).rejects.toMatchObject({ status: 503, code: "overloaded" });
  expect(calls).toBe(maxRetries + 1);
  expect(delays).toEqual(maxRetries ? [200, 400] : []);
});

it.each(["oops", "null", "[]", '{"code":503}', '{"code":"unavailable"}', '{"data":{"x":{"code":"overloaded","message":"field"}}}'])(
  "does not retry a generic or malformed 503: %s", async (body) => {
    let calls = 0;
    const t = new Transport({
      baseUrl: "http://api.test", authStore: new MemoryAuthStore(), autoRefresh: false,
      maxRetries: 2, sleep: async () => { throw new Error("must not sleep"); },
      fetch: (async () => { calls++; return new Response(body, { status: 503, headers: { "Retry-After": "1" } }); }) as typeof fetch,
    });
    await expect(t.send("/api/write", { method: "POST" })).rejects.toMatchObject({ status: 503 });
    expect(calls).toBe(1);
  },
);

it("raw leaves overload responses and bodies untouched", async () => {
  let calls = 0;
  const t = new Transport({
    baseUrl: "http://api.test", authStore: new MemoryAuthStore(), autoRefresh: false,
    maxRetries: 2, sleep: async () => { throw new Error("must not sleep"); },
    fetch: (async () => { calls++; return new Response(overload, { status: 503 }); }) as typeof fetch,
  });
  const res = await t.raw("/api/write", { method: "POST" });
  expect(res.status).toBe(503);
  expect(await res.text()).toBe(overload);
  expect(calls).toBe(1);
});
