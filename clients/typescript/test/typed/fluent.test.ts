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

  it("in expands to an OR chain", () => {
    expect(b.tags!.in(["t1", "t2"]).toString()).toBe(
      "(tags = 't1' || tags = 't2')",
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
});
