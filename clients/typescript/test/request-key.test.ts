import { describe, it, expect, vi } from "vitest";
import { createClient } from "../src/index.js";

/** A fetch that resolves only when `release()` is called, and honors abort. */
function deferredFetch() {
  const calls: Array<{ release: (body: unknown) => void; signal: AbortSignal | undefined }> = [];
  const fetchImpl = ((_url: string, init?: RequestInit) => {
    const signal = init?.signal ?? undefined;
    return new Promise<Response>((resolve, reject) => {
      const entry = {
        release: (body: unknown) =>
          resolve(new Response(JSON.stringify(body), { headers: { "content-type": "application/json" } })),
        signal,
      };
      calls.push(entry);
      if (signal) {
        if (signal.aborted) reject(new DOMException("Aborted", "AbortError"));
        signal.addEventListener("abort", () => reject(new DOMException("Aborted", "AbortError")));
      }
    });
  }) as unknown as typeof fetch;
  return { fetchImpl, calls };
}

const listBody = { page: 1, perPage: 30, totalItems: 0, totalPages: 0, items: [] };

describe("requestKey auto-cancellation", () => {
  it("same requestKey: the first call aborts, the second resolves", async () => {
    const { fetchImpl, calls } = deferredFetch();
    const zb = createClient("http://api.test", { fetch: fetchImpl });

    const first = zb.collection("posts").getList(1, 30, { requestKey: "k" });
    const second = zb.collection("posts").getList(1, 30, { requestKey: "k" });

    // Two fetches issued; the first was aborted by the second.
    expect(calls.length).toBe(2);
    expect(calls[0]!.signal?.aborted).toBe(true);
    expect(calls[1]!.signal?.aborted).toBe(false);

    calls[1]!.release(listBody);

    await expect(first).rejects.toMatchObject({ name: "AbortError" });
    await expect(second).resolves.toMatchObject({ items: [] });
  });

  it("different requestKeys: both resolve independently", async () => {
    const { fetchImpl, calls } = deferredFetch();
    const zb = createClient("http://api.test", { fetch: fetchImpl });

    const a = zb.collection("posts").getList(1, 30, { requestKey: "a" });
    const b = zb.collection("posts").getList(1, 30, { requestKey: "b" });
    expect(calls.length).toBe(2);
    expect(calls[0]!.signal?.aborted).toBe(false);
    expect(calls[1]!.signal?.aborted).toBe(false);

    calls[0]!.release(listBody);
    calls[1]!.release(listBody);
    await expect(a).resolves.toMatchObject({ items: [] });
    await expect(b).resolves.toMatchObject({ items: [] });
  });

  it("no requestKey: concurrent calls do not cancel each other", async () => {
    const { fetchImpl, calls } = deferredFetch();
    const zb = createClient("http://api.test", { fetch: fetchImpl });
    const a = zb.collection("posts").getList(1, 30);
    const b = zb.collection("posts").getList(1, 30);
    expect(calls[0]!.signal?.aborted ?? false).toBe(false);
    calls[0]!.release(listBody);
    calls[1]!.release(listBody);
    await expect(a).resolves.toMatchObject({ items: [] });
    await expect(b).resolves.toMatchObject({ items: [] });
  });

  it("a user-supplied signal still aborts a keyed request", async () => {
    const { fetchImpl, calls } = deferredFetch();
    const zb = createClient("http://api.test", { fetch: fetchImpl });
    const ctrl = new AbortController();
    const p = zb.collection("posts").getList(1, 30, { requestKey: "k", signal: ctrl.signal });
    expect(calls[0]!.signal?.aborted).toBe(false);
    ctrl.abort();
    expect(calls[0]!.signal?.aborted).toBe(true);
    await expect(p).rejects.toMatchObject({ name: "AbortError" });
  });

  it("client.send honors requestKey", async () => {
    const { fetchImpl, calls } = deferredFetch();
    const zb = createClient("http://api.test", { fetch: fetchImpl });
    const first = zb.send("GET", "/api/x", { requestKey: "s" });
    const second = zb.send("GET", "/api/x", { requestKey: "s" });
    expect(calls[0]!.signal?.aborted).toBe(true);
    calls[1]!.release({ ok: true });
    await expect(first).rejects.toMatchObject({ name: "AbortError" });
    await expect(second).resolves.toMatchObject({ ok: true });
  });
});
