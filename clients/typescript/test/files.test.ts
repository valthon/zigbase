import { describe, it, expect, vi } from "vitest";
import { FilesService } from "../src/files.js";
import { createClient } from "../src/index.js";
import { Transport } from "../src/transport.js";
import { MemoryAuthStore } from "../src/auth-store.js";

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function makeFiles(fetchImpl?: typeof fetch): FilesService {
  const transport = new Transport({
    baseUrl: "http://api.test",
    authStore: new MemoryAuthStore(),
    fetch: (fetchImpl ?? (async () => new Response())) as unknown as typeof fetch,
    autoRefresh: false,
    maxRetries: 0,
    sleep: async () => {},
  });
  return new FilesService(transport, "http://api.test");
}

describe("FilesService.getUrl", () => {
  it("builds a file URL from a record object + filename", () => {
    const files = makeFiles();
    const url = files.getUrl({ id: "rec1", collectionName: "posts" }, "photo.png");
    expect(url).toBe("http://api.test/api/files/posts/rec1/photo.png");
  });

  it("prefers collectionId when present", () => {
    const files = makeFiles();
    const url = files.getUrl({ id: "rec1", collectionId: "col_abc", collectionName: "posts" }, "p.png");
    expect(url).toBe("http://api.test/api/files/col_abc/rec1/p.png");
  });

  it("accepts explicit string ids", () => {
    const files = makeFiles();
    const url = files.getUrl("posts", "rec1", "p.png"); // overloaded form
    expect(url).toBe("http://api.test/api/files/posts/rec1/p.png");
  });

  it("adds download, thumb, and token query params", () => {
    const files = makeFiles();
    const url = files.getUrl({ id: "r", collectionName: "posts" }, "p.png", {
      download: true,
      thumb: "100x100",
      token: "tok123",
    });
    const u = new URL(url);
    expect(u.pathname).toBe("/api/files/posts/r/p.png");
    expect(u.searchParams.get("download")).toBe("1");
    expect(u.searchParams.get("thumb")).toBe("100x100");
    expect(u.searchParams.get("token")).toBe("tok123");
  });

  it("URL-encodes the filename", () => {
    const files = makeFiles();
    const url = files.getUrl({ id: "r", collectionName: "posts" }, "a b.png");
    expect(url).toBe("http://api.test/api/files/posts/r/a%20b.png");
  });
});

describe("FilesService.getToken", () => {
  it("POSTs /api/files/token and returns the token", async () => {
    const fetchMock = vi.fn(async (url: string, init: RequestInit) => {
      expect(url).toBe("http://api.test/api/files/token");
      expect(init.method).toBe("POST");
      return jsonResponse({ token: "file-tok" });
    }) as unknown as typeof fetch;
    const files = makeFiles(fetchMock);
    expect(await files.getToken()).toBe("file-tok");
  });
});

describe("client.files", () => {
  it("is exposed as a lazy getter on the client", () => {
    const zb = createClient("http://api.test", {
      fetch: (async () => new Response()) as unknown as typeof fetch,
    });
    expect(zb.files).toBeInstanceOf(FilesService);
    expect(zb.files).toBe(zb.files); // memoized
  });
});
