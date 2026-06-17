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
    iterate: vi.fn(async function* () { /* empty */ } as () => AsyncIterableIterator<Record<string, unknown>>),
    getFullList: vi.fn(async () => [] as Record<string, unknown>[]),
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

  it("create forwards expand string[] as a comma-joined string to inner.create", async () => {
    const { client, inner } = mockClient();
    const svc = makeRecordService(client, postsMeta);
    await svc.create({ title: "Hi" }, { expand: ["author", "tags"] });
    expect(inner.create).toHaveBeenCalledWith(
      { title: "Hi" },
      expect.objectContaining({ expand: "author,tags" }),
    );
  });

  it("update forwards expand string[] as a comma-joined string to inner.update", async () => {
    const { client, inner } = mockClient();
    const svc = makeRecordService(client, postsMeta);
    await svc.update("p1", { title: "Yo" }, { expand: ["author"] });
    expect(inner.update).toHaveBeenCalledWith(
      "p1",
      { title: "Yo" },
      expect.objectContaining({ expand: "author" }),
    );
  });

  it("create forwards requestKey and fields to inner.create", async () => {
    const { client, inner } = mockClient();
    const svc = makeRecordService(client, postsMeta);
    await svc.create({ title: "Hi" }, { requestKey: "ck-1", fields: "id,title" });
    expect(inner.create).toHaveBeenCalledWith(
      { title: "Hi" },
      expect.objectContaining({ requestKey: "ck-1", fields: "id,title" }),
    );
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

  it("getFirstListItem without `where` throws ZigbaseError 404 when getList returns empty", async () => {
    const { client, inner } = mockClient();
    const svc = makeRecordService(client, postsMeta);
    // Default mock already returns { items: [] }
    await expect(svc.getFirstListItem()).rejects.toMatchObject({ status: 404 });
    expect(inner.getList).toHaveBeenCalledWith(1, 1, expect.objectContaining({}));
  });

  it("getFullList delegates to inner.getFullList with compiled where filter", async () => {
    const { client, inner } = mockClient();
    const svc = makeRecordService(client, postsMeta);
    inner.getFullList.mockResolvedValueOnce([{ id: "p1" } as Record<string, unknown>]);
    const result = await svc.getFullList({ where: { status: "published" } });
    expect(inner.getFullList).toHaveBeenCalledWith(
      expect.objectContaining({ filter: "status = 'published'" }),
    );
    expect(inner.getPage).not.toHaveBeenCalled();
    expect(result).toEqual([{ id: "p1" }]);
  });

  it("iterate delegates to inner.iterate with compiled where filter", async () => {
    const { client, inner } = mockClient();
    const svc = makeRecordService(client, postsMeta);
    const items = [{ id: "p1" } as Record<string, unknown>];
    inner.iterate.mockImplementationOnce(async function* () {
      for (const item of items) yield item;
    } as () => AsyncIterableIterator<Record<string, unknown>>);
    const collected: unknown[] = [];
    for await (const item of svc.iterate({ where: { status: "draft" } })) {
      collected.push(item);
    }
    expect(inner.iterate).toHaveBeenCalledWith(
      expect.objectContaining({ filter: "status = 'draft'" }),
    );
    expect(inner.getPage).not.toHaveBeenCalled();
    expect(collected).toEqual(items);
  });

  it("coerces int/fixed number fields to decimal strings on create, leaving floats as numbers", async () => {
    // meta with one int-mode, one fixed-mode (scale 2), and one float field.
    const numMeta: CollectionMeta = {
      name: "things",
      fields: {
        count: { type: "number", mode: "int" },
        price: { type: "number", mode: "fixed", scale: 2 },
        weight: { type: "number" },
      },
      fileFields: [],
      expandable: [],
      isAuth: false,
    };
    const { client, inner } = mockClient();
    const svc = makeRecordService(client, numMeta);
    await svc.create({ count: 5, price: 40, weight: 3.14 });
    const body = inner.create.mock.calls[0]![0];
    expect(body.count).toBe("5");
    expect(body.price).toBe("40.00");
    expect(body.weight).toBe(3.14);
    expect(typeof body.count).toBe("string");
    expect(typeof body.price).toBe("string");
    expect(typeof body.weight).toBe("number");
  });

  it("coerces int/fixed number fields on update too", async () => {
    const numMeta: CollectionMeta = {
      name: "things",
      fields: {
        count: { type: "number", mode: "int" },
        price: { type: "number", mode: "fixed", scale: 2 },
      },
      fileFields: [],
      expandable: [],
      isAuth: false,
    };
    const { client, inner } = mockClient();
    const svc = makeRecordService(client, numMeta);
    await svc.update("t1", { count: 7, price: 1.5 });
    const id = inner.update.mock.calls[0]![0];
    const body = inner.update.mock.calls[0]![1];
    expect(id).toBe("t1");
    expect(body.count).toBe("7");
    expect(body.price).toBe("1.50");
  });

  it("leaves data untouched (same reference) when no number-mode field is present in payload", async () => {
    const numMeta: CollectionMeta = {
      name: "things",
      fields: { count: { type: "number", mode: "int" }, label: { type: "text" } },
      fileFields: [],
      expandable: [],
      isAuth: false,
    };
    const { client, inner } = mockClient();
    const svc = makeRecordService(client, numMeta);
    const payload = { label: "hi" };
    await svc.create(payload);
    const body = inner.create.mock.calls[0]![0];
    // No mode-bearing key present as a number, so the original object passes through.
    expect(body).toBe(payload);
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

  // Fix 2: requestKey threading tests
  it("threads requestKey through to inner.getList", async () => {
    const { client, inner } = mockClient();
    const svc = makeRecordService(client, postsMeta);
    await svc.getList({ where: { status: "published" }, requestKey: "my-key" });
    const call = inner.getList.mock.calls[0];
    const [, , opts] = call as ListArgs;
    expect(opts).toMatchObject({ requestKey: "my-key" });
  });

  it("threads requestKey through to inner.getPage", async () => {
    const { client, inner } = mockClient();
    const svc = makeRecordService(client, postsMeta);
    await svc.getPage({ where: { status: "a" }, requestKey: "page-key" });
    expect(inner.getPage).toHaveBeenCalledWith(
      expect.objectContaining({ requestKey: "page-key" }),
    );
  });

  it("threads requestKey through to inner.iterate", async () => {
    const { client, inner } = mockClient();
    const svc = makeRecordService(client, postsMeta);
    inner.iterate.mockImplementationOnce(async function* () {
      /* empty */
    } as () => AsyncIterableIterator<Record<string, unknown>>);
    for await (const _ of svc.iterate({ requestKey: "iter-key" })) { /* drain */ }
    expect(inner.iterate).toHaveBeenCalledWith(
      expect.objectContaining({ requestKey: "iter-key" }),
    );
  });

  it("threads requestKey through to inner.getFullList", async () => {
    const { client, inner } = mockClient();
    const svc = makeRecordService(client, postsMeta);
    await svc.getFullList({ requestKey: "full-key" });
    expect(inner.getFullList).toHaveBeenCalledWith(
      expect.objectContaining({ requestKey: "full-key" }),
    );
  });
});
