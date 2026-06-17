import { describe, it, expect, vi } from "vitest";
import { makeRecordService } from "../../src/typed/service.js";
import type { CollectionMeta } from "../../src/typed/meta.js";
import type { Client } from "../../src/client.js";
import type { CollectionService } from "../../src/collection.js";
import type { FilterRoot } from "../../src/typed/fluent.js";

const postsMeta: CollectionMeta = {
  name: "posts",
  fields: {
    title: { type: "text" },
    status: { type: "select" },
    price: { type: "number" },
    author: { type: "relation" },
    tags: { type: "relation", multi: true },
  },
  fileFields: [],
  expandable: ["author", "tags"],
  isAuth: false,
};

type ListArgs = Parameters<CollectionService["getList"]>;

function mockClient() {
  const inner = {
    name: "posts",
    getList: vi.fn<ListArgs, Promise<{ page: number; perPage: number; totalItems: number; totalPages: number; items: Record<string, unknown>[] }>>(
      async () => ({ page: 1, perPage: 30, totalItems: 0, totalPages: 0, items: [] }),
    ),
    getOne: vi.fn(async (id: string) => ({ id })),
    getFirstListItem: vi.fn(async () => ({ id: "p1" })),
    getPage: vi.fn(async () => ({ items: [] as Record<string, unknown>[], nextCursor: null, prevCursor: null, hasNext: false, hasPrev: false })),
    create: vi.fn(async (body: Record<string, unknown>) => ({ id: "new", ...body })),
    update: vi.fn(async (id: string, body: Record<string, unknown>) => ({ id, ...body })),
    delete: vi.fn(async () => undefined),
  };
  const client = { collection: vi.fn(() => inner) } as unknown as Client;
  return { client, inner };
}

describe("makeRecordService", () => {
  it("compiles `where` to an SP1 filter string for getList", async () => {
    const { client, inner } = mockClient();
    const svc = makeRecordService(client, postsMeta);
    await svc.getList({ where: { status: "published", price: { gte: 5 } }, sort: "-created", limit: 10 });
    expect(inner.getList).toHaveBeenCalledTimes(1);
    const call = inner.getList.mock.calls[0];
    const [page, perPage, opts] = call as ListArgs;
    expect(page).toBe(1);
    expect(perPage).toBe(10);
    expect(opts).toMatchObject({ filter: "(status = 'published' && price >= 5)", sort: "-created" });
  });

  it("forwards `page` as the first arg to inner.getList", async () => {
    const { client, inner } = mockClient();
    const svc = makeRecordService(client, postsMeta);
    await svc.getList({ page: 2, limit: 15 });
    const call = inner.getList.mock.calls[0];
    const [page, perPage] = call as ListArgs;
    expect(page).toBe(2);
    expect(perPage).toBe(15);
  });

  it("passes expand arrays through as a comma list", async () => {
    const { client, inner } = mockClient();
    const svc = makeRecordService(client, postsMeta);
    await svc.getOne("p1", { expand: ["author", "tags"] });
    expect(inner.getOne).toHaveBeenCalledWith(
      "p1",
      expect.objectContaining({ expand: "author,tags" }),
    );
  });

  it("getPage forwards where->filter, limit, and cursor", async () => {
    const { client, inner } = mockClient();
    const svc = makeRecordService(client, postsMeta);
    await svc.getPage({ where: { status: "a" }, limit: 20, cursor: "tok" });
    expect(inner.getPage).toHaveBeenCalledWith(
      expect.objectContaining({ filter: "status = 'a'", limit: 20, cursor: "tok" }),
    );
  });

  it("create/update/delete delegate to the inner service", async () => {
    const { client, inner } = mockClient();
    const svc = makeRecordService(client, postsMeta);
    await svc.create({ title: "Hi" });
    await svc.update("p1", { title: "Yo" });
    await svc.delete("p1");
    expect(inner.create).toHaveBeenCalledWith({ title: "Hi" }, expect.objectContaining({}));
    expect(inner.update).toHaveBeenCalledWith("p1", { title: "Yo" }, expect.objectContaining({}));
    expect(inner.delete).toHaveBeenCalledWith("p1");
  });

  it("getFirstListItem with `where` delegates to inner.getFirstListItem with compiled filter", async () => {
    const { client, inner } = mockClient();
    const svc = makeRecordService(client, postsMeta);
    await svc.getFirstListItem({ where: { status: "published" } });
    expect(inner.getFirstListItem).toHaveBeenCalledWith(
      "status = 'published'",
      expect.objectContaining({}),
    );
    expect(inner.getList).not.toHaveBeenCalled();
  });

  it("getFirstListItem without `where` uses getList(1,1) to avoid empty-string filter", async () => {
    const { client, inner } = mockClient();
    const svc = makeRecordService(client, postsMeta);
    inner.getList.mockResolvedValueOnce({
      page: 1, perPage: 1, totalItems: 1, totalPages: 1,
      items: [{ id: "p1" } as Record<string, unknown>],
    });
    const result = await svc.getFirstListItem({});
    expect(inner.getList).toHaveBeenCalledWith(1, 1, expect.objectContaining({}));
    expect(inner.getFirstListItem).not.toHaveBeenCalled();
    expect(result).toEqual({ id: "p1" });
  });

  it("iterate and getFullList forward compiled where filter", async () => {
    const { client, inner } = mockClient();
    const svc = makeRecordService(client, postsMeta);
    inner.getPage
      .mockResolvedValueOnce({ items: [{ id: "p1" } as Record<string, unknown>], nextCursor: null, prevCursor: null, hasNext: false, hasPrev: false });
    await svc.getFullList({ where: { status: "published" } });
    expect(inner.getPage).toHaveBeenCalledWith(
      expect.objectContaining({ filter: "status = 'published'" }),
    );
  });

  it("iterate forwards compiled where filter", async () => {
    const { client, inner } = mockClient();
    const svc = makeRecordService(client, postsMeta);
    inner.getPage
      .mockResolvedValueOnce({ items: [], nextCursor: null, prevCursor: null, hasNext: false, hasPrev: false });
    for await (const _ of svc.iterate({ where: { status: "draft" } })) { /* drain */ }
    expect(inner.getPage).toHaveBeenCalledWith(
      expect.objectContaining({ filter: "status = 'draft'" }),
    );
  });

  it("filter(fn) builds an SP1 string via the fluent builder", () => {
    const { client } = mockClient();
    const svc = makeRecordService(client, postsMeta);
    const f = svc.filter((b: FilterRoot) => b["status"]!.eq("published").or(b["author"]!.eq("u1")));
    expect(f).toBe("(status = 'published' || author = 'u1')");
  });

  it("omits filter when where is empty", async () => {
    const { client, inner } = mockClient();
    const svc = makeRecordService(client, postsMeta);
    await svc.getList({});
    const call = inner.getList.mock.calls[0];
    const [, , opts] = call as ListArgs;
    expect(opts?.filter).toBeUndefined();
  });
});
