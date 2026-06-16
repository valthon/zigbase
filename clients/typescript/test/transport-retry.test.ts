import { describe, it, expect, vi } from "vitest";
import { Transport } from "../src/transport.js";
import { MemoryAuthStore } from "../src/auth-store.js";

function jsonResponse(body: unknown, status = 200, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", ...headers },
  });
}

describe("Transport retries", () => {
  it("retries 429 up to maxRetries then succeeds", async () => {
    let calls = 0;
    const fetchMock = vi.fn(async () => {
      calls += 1;
      if (calls <= 2) return jsonResponse({ code: 429, message: "slow down" }, 429, { "Retry-After": "0" });
      return jsonResponse({ ok: true });
    }) as unknown as typeof fetch;
    const t = new Transport({
      baseUrl: "http://api.test",
      authStore: new MemoryAuthStore(),
      fetch: fetchMock,
      autoRefresh: false,
      maxRetries: 3,
      sleep: async () => {},
    });
    const out = await t.send<{ ok: boolean }>("/api/x");
    expect(out.ok).toBe(true);
    expect(calls).toBe(3);
  });

  it("caps the exponential 429 backoff at the max delay", async () => {
    const delays: number[] = [];
    let calls = 0;
    const fetchMock = vi.fn(async () => {
      calls += 1;
      // Always 429 until the last allowed attempt, so we capture a high attempt
      // count whose uncapped delay (2**attempt * 200) would exceed the cap.
      if (calls <= 20) return jsonResponse({ code: 429, message: "slow down" }, 429);
      return jsonResponse({ ok: true });
    }) as unknown as typeof fetch;
    const t = new Transport({
      baseUrl: "http://api.test",
      authStore: new MemoryAuthStore(),
      fetch: fetchMock,
      autoRefresh: false,
      maxRetries: 20,
      sleep: async (ms) => {
        delays.push(ms);
      },
    });
    await t.send<{ ok: boolean }>("/api/x");
    // 2**10*200 = 204800 ms uncapped; every requested delay must be <= 30s.
    expect(Math.max(...delays)).toBeLessThanOrEqual(30_000);
    expect(delays.some((d) => d === 30_000)).toBe(true);
  });

  it("performs a one-shot refresh on 401 then retries", async () => {
    const store = new MemoryAuthStore();
    store.save("old.tok.tok", { id: "u1" });
    let calls = 0;
    const fetchMock = vi.fn(async () => {
      calls += 1;
      if (calls === 1) return jsonResponse({ code: 401, message: "expired" }, 401);
      return jsonResponse({ ok: true });
    }) as unknown as typeof fetch;
    const refresh = vi.fn(async () => {
      store.save("new.tok.tok", { id: "u1" });
    });
    const t = new Transport({
      baseUrl: "http://api.test",
      authStore: store,
      fetch: fetchMock,
      autoRefresh: true,
      maxRetries: 0,
      refresh,
      sleep: async () => {},
    });
    const out = await t.send<{ ok: boolean }>("/api/x");
    expect(out.ok).toBe(true);
    expect(refresh).toHaveBeenCalledTimes(1);
    expect(calls).toBe(2);
  });
});
