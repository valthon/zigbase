import { describe, it, expect } from "vitest";
import { makeFilterBuilder } from "../../src/typed/fluent.js";
import type { CollectionMeta } from "../../src/typed/meta.js";

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

describe("makeFilterBuilder", () => {
  const b = makeFilterBuilder(postsMeta);

  it("single operator", () => {
    expect(b.status!.eq("published").toString()).toBe("status = 'published'");
    expect(b.price!.gte(10).toString()).toBe("price >= 10");
    expect(b.title!.like("A").toString()).toBe("title ~ 'A'");
    expect(b.title!.nlike("A").toString()).toBe("title !~ 'A'");
  });

  it("and / or combine with precedence parentheses", () => {
    expect(b.status!.eq("published").or(b.author!.eq("u1")).toString()).toBe(
      "(status = 'published' || author = 'u1')",
    );
    expect(
      b.status!.eq("published").and(b.price!.gte(5)).toString(),
    ).toBe("(status = 'published' && price >= 5)");
  });

  it("in compiles to the native operator", () => {
    expect(b.tags!.in(["t1", "t2"]).toString()).toBe(
      "tags in ('t1', 't2')",
    );
  });

  it("is injection-safe", () => {
    expect(b.title!.eq("a' || 1=1 --").toString()).toBe(
      "title = 'a\\' || 1=1 --'",
    );
  });

  it("throws on an unknown field", () => {
    expect(() => b.nope!.eq("x")).toThrow();
  });

  it("accessing a Symbol property returns without throwing (runtime inspection safety)", () => {
    // JS runtime inspection accesses Symbol.toStringTag, Symbol.toPrimitive, etc.
    // These should NOT throw — they fall through Reflect.get which returns undefined.
    const sym = Symbol.toStringTag;
    expect(() => (b as unknown as Record<symbol, unknown>)[sym]).not.toThrow();
    expect((b as unknown as Record<symbol, unknown>)[sym]).toBeUndefined();
  });

  it("`then` property returns undefined (prevents thenable trap in async contexts)", () => {
    // If a FilterBuilder is accidentally returned from an async fn / awaited,
    // Promise.resolve() checks for a `.then` method. Returning `undefined` makes
    // the builder a non-thenable, preventing infinite resolution loops.
    const result = (b as unknown as Record<string, unknown>)["then"];
    expect(result).toBeUndefined();
  });

  it("known fields still work after robustness guard is in place", () => {
    expect(b.status!.eq("published").toString()).toBe("status = 'published'");
    expect(b.author!.eq("u1").toString()).toBe("author = 'u1'");
  });
});
