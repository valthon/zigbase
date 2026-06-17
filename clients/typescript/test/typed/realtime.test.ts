import { describe, it, expect, vi } from "vitest";
import { makeTypedRealtime } from "../../src/typed/realtime.js";
import type { CollectionMeta } from "../../src/typed/meta.js";

const postsMeta: CollectionMeta = {
  name: "posts",
  fields: { title: { type: "text" }, status: { type: "select" } },
  fileFields: [],
  expandable: [],
  isAuth: false,
};

function mockRealtime() {
  const off = vi.fn();
  // SP1 LiveCollection.getList(page, perPage, opts) returns a LiveList.
  // The mock returns a minimal fake LiveList shape.
  const fakeLiveList = { items: [], version: 0, subscribe: vi.fn(), close: vi.fn() };
  const collectionObj = {
    getList: vi.fn(async () => fakeLiveList),
  };
  const rt = {
    subscribe: vi.fn(async () => off),
    unsubscribe: vi.fn(),
    collection: vi.fn(() => collectionObj),
  };
  return { rt, off, collectionObj, fakeLiveList };
}

describe("makeTypedRealtime", () => {
  it("subscribe compiles where into the topic filter", async () => {
    const { rt } = mockRealtime();
    const typed = makeTypedRealtime(rt as never, postsMeta);
    const cb = vi.fn();
    await typed.subscribe(cb, { where: { status: "published" } });
    expect(rt.subscribe).toHaveBeenCalledWith(
      "posts",
      cb,
      { filter: "status = 'published'" },
    );
  });

  it("subscribe without where omits the filter", async () => {
    const { rt } = mockRealtime();
    const typed = makeTypedRealtime(rt as never, postsMeta);
    const cb = vi.fn();
    await typed.subscribe(cb);
    expect(rt.subscribe).toHaveBeenCalledWith("posts", cb, {});
  });

  it("getList delegates to the SP1 LiveCollection.getList with a compiled filter", async () => {
    const { rt, collectionObj } = mockRealtime();
    const typed = makeTypedRealtime(rt as never, postsMeta);
    await typed.getList({ where: { status: "a" }, sort: "-created" });
    expect(rt.collection).toHaveBeenCalledWith("posts");
    expect(collectionObj.getList).toHaveBeenCalledWith(
      1,
      30,
      expect.objectContaining({ filter: "status = 'a'", sort: "-created" }),
    );
  });

  it("getList with no options passes a clean empty object (no undefined keys)", async () => {
    const { rt, collectionObj } = mockRealtime();
    const typed = makeTypedRealtime(rt as never, postsMeta);
    await typed.getList();
    expect(rt.collection).toHaveBeenCalledWith("posts");
    const call = collectionObj.getList.mock.calls[0] as unknown as [number, number, Record<string, unknown>];
    const opts = call[2];
    // No undefined-valued keys should be present
    expect(Object.keys(opts).filter((k) => opts[k] === undefined)).toHaveLength(0);
    expect(opts).toEqual({});
  });

  it("unsubscribe delegates to SP1 rt.unsubscribe with the collection name", () => {
    const { rt } = mockRealtime();
    const typed = makeTypedRealtime(rt as never, postsMeta);
    const cb = vi.fn();
    typed.unsubscribe(cb);
    expect(rt.unsubscribe).toHaveBeenCalledWith("posts", cb);
  });
});
