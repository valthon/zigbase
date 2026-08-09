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
      if (calls <= 2) return jsonResponse({ status: 429, code: "too_many_requests", message: "slow down" }, 429, { "Retry-After": "0" });
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
      if (calls <= 20) return jsonResponse({ status: 429, code: "too_many_requests", message: "slow down" }, 429);
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

  it("single-flight: a parallel 401 burst performs ONE refresh and all requests succeed", async () => {
    // Token expires; the app fires 3 parallel requests. All three 401. The
    // first starts the refresh; the other two must AWAIT that same refresh
    // (not skip it and fail, not start redundant ones) and then retry.
    const store = new MemoryAuthStore();
    store.save("stale.tok", { id: "u1" });
    let refreshed = false;
    let release!: () => void;
    const gate = new Promise<void>((r) => {
      release = r;
    });
    const refresh = vi.fn(async () => {
      await gate; // hold the refresh open so every 401 lands during it
      refreshed = true;
      store.save("fresh.tok", { id: "u1" });
    });
    const fetchMock = vi.fn(async () =>
      refreshed ? jsonResponse({ ok: true }) : jsonResponse({ status: 401, code: "unauthorized", message: "expired" }, 401),
    ) as unknown as typeof fetch;
    const t = new Transport({
      baseUrl: "http://api.test",
      authStore: store,
      fetch: fetchMock,
      autoRefresh: true,
      maxRetries: 0,
      refresh,
      sleep: async () => {},
    });

    const burst = [t.send("/api/a"), t.send("/api/b"), t.send("/api/c")];
    // Let all three 401s land and register on the shared in-flight refresh.
    await new Promise((r) => setTimeout(r, 0));
    expect(refresh).toHaveBeenCalledTimes(1); // not three redundant refreshes

    release();
    const out = await Promise.all(burst); // NO spurious failures
    expect(out).toEqual([{ ok: true }, { ok: true }, { ok: true }]);
    expect(refresh).toHaveBeenCalledTimes(1);
    expect(fetchMock).toHaveBeenCalledTimes(6); // 3 x 401 + 3 retried 200s
  });

  it("a persistently-401ing refresh endpoint stays bounded: waiters reject, no recursion, no deadlock", async () => {
    // The refresh callback issues its OWN (isRefreshCall-marked) request through
    // the transport, exactly like collection.authRefresh() does. When that
    // request also 401s, it must propagate — not await its own refresh
    // (deadlock) and not start another (unbounded recursion).
    const store = new MemoryAuthStore();
    store.save("tok", { id: "u1" });
    let releaseRefreshResponse!: () => void;
    const refreshGate = new Promise<void>((r) => {
      releaseRefreshResponse = r;
    });
    let calls = 0;
    const fetchMock = vi.fn(async (url: string) => {
      calls += 1;
      // Hold the auth-refresh response open until both waiters have joined.
      if (url.includes("auth-refresh")) await refreshGate;
      return jsonResponse({ status: 401, code: "unauthorized", message: "expired" }, 401);
    }) as unknown as typeof fetch;

    let t!: Transport;
    const refresh = vi.fn(async () => {
      await t.send("/api/collections/users/auth-refresh", { method: "POST", isRefreshCall: true });
    });
    t = new Transport({
      baseUrl: "http://api.test",
      authStore: store,
      fetch: fetchMock,
      autoRefresh: true,
      maxRetries: 0,
      refresh,
      sleep: async () => {},
    });

    const a = t.send("/api/a");
    const b = t.send("/api/b");
    await new Promise((r) => setTimeout(r, 0)); // both 401s join the one refresh
    releaseRefreshResponse();

    const results = await Promise.allSettled([a, b]);
    expect(results.map((r) => r.status)).toEqual(["rejected", "rejected"]);
    // Bounded: one refresh; its own 401 propagated. 3 fetches total (a, b,
    // auth-refresh) — no retries, no nested refreshes.
    expect(refresh).toHaveBeenCalledTimes(1);
    expect(calls).toBe(3);
  });

  it("a failed refresh rejects every waiter with its ORIGINAL 401 error", async () => {
    const store = new MemoryAuthStore();
    store.save("tok", { id: "u1" });
    let release!: () => void;
    const gate = new Promise<void>((r) => {
      release = r;
    });
    const refresh = vi.fn(async () => {
      await gate;
      throw new Error("refresh broke");
    });
    const fetchMock = vi.fn(async () =>
      jsonResponse({ status: 401, code: "unauthorized", message: "expired" }, 401),
    ) as unknown as typeof fetch;
    const t = new Transport({
      baseUrl: "http://api.test",
      authStore: store,
      fetch: fetchMock,
      autoRefresh: true,
      maxRetries: 0,
      refresh,
      sleep: async () => {},
    });

    const a = t.send("/api/a");
    const b = t.send("/api/b");
    await new Promise((r) => setTimeout(r, 0)); // both join the one refresh
    release();

    const results = await Promise.allSettled([a, b]);
    for (const r of results) {
      expect(r.status).toBe("rejected");
      // The waiter's own 401 (a ZigbaseError with status 401), not "refresh broke".
      const err = (r as PromiseRejectedResult).reason as { status?: number; message: string };
      expect(err.status).toBe(401);
      expect(err.message).toBe("expired");
    }
    expect(refresh).toHaveBeenCalledTimes(1);
    expect(fetchMock).toHaveBeenCalledTimes(2); // no retries after the failure
  });

  it("performs a one-shot refresh on 401 then retries", async () => {
    const store = new MemoryAuthStore();
    store.save("old.tok.tok", { id: "u1" });
    let calls = 0;
    const fetchMock = vi.fn(async () => {
      calls += 1;
      if (calls === 1) return jsonResponse({ status: 401, code: "unauthorized", message: "expired" }, 401);
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
