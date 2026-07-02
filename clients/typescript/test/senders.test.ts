import { describe, it, expect, vi } from "vitest";
import { createClient } from "../src/index.js";
import { isZigbaseError } from "../src/errors.js";

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

describe("senders", () => {
  it("list() parses the {items} envelope (server >= 0.10.0)", async () => {
    const fetchMock = vi.fn(async (url: string) => {
      expect(url).toBe("http://api.test/api/senders");
      return jsonResponse({ items: [{ id: "s1", email: "a@x.io", status: "verified", verified_at: "t" }] });
    }) as unknown as typeof fetch;
    const zb = createClient("http://api.test", { fetch: fetchMock });
    const out = await zb.senders.list();
    expect(out.items[0]?.email).toBe("a@x.io");
  });

  it("create() POSTs the email; 201 pending parses like 200", async () => {
    const fetchMock = vi.fn(async (url: string, init?: RequestInit) => {
      expect(url).toBe("http://api.test/api/senders");
      expect(JSON.parse(String(init?.body))).toEqual({ email: "from@acct.io" });
      return jsonResponse({ id: "s2", email: "from@acct.io", status: "pending" }, 201);
    }) as unknown as typeof fetch;
    const zb = createClient("http://api.test", { fetch: fetchMock });
    const out = await zb.senders.create("from@acct.io");
    expect(out.status).toBe("pending");
  });

  it("create() surfaces a 429 throttle as a ZigbaseError", async () => {
    const fetchMock = vi.fn(async () =>
      jsonResponse({ status: 429, message: "Verification email already sent recently; try again later." }, 429),
    ) as unknown as typeof fetch;
    // maxRetries: 0 disables the transport's 429 backoff so the error surfaces immediately.
    const zb = createClient("http://api.test", { fetch: fetchMock, maxRetries: 0 });
    try {
      await zb.senders.create("x@y.io");
      expect.unreachable();
    } catch (e) {
      expect(isZigbaseError(e)).toBe(true);
      expect((e as { status: number }).status).toBe(429);
    }
  });

  it("verify() POSTs the token to /api/senders/:id/verify", async () => {
    const fetchMock = vi.fn(async (url: string, init?: RequestInit) => {
      expect(url).toBe("http://api.test/api/senders/s2/verify");
      expect(JSON.parse(String(init?.body))).toEqual({ token: "tok" });
      return jsonResponse({ verified: true });
    }) as unknown as typeof fetch;
    const zb = createClient("http://api.test", { fetch: fetchMock });
    expect(await zb.senders.verify("s2", "tok")).toEqual({ verified: true });
  });
});
