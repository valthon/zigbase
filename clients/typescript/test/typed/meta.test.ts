import { describe, it, expect } from "vitest";
import { fieldMeta, type CollectionMeta } from "../../src/typed/meta.js";

const postsMeta: CollectionMeta = {
  name: "posts",
  fields: {
    title: { type: "text" },
    status: { type: "select" },
    price: { type: "number" },
    author: { type: "relation" },
    tags: { type: "relation", multi: true },
    cover: { type: "file" },
    created: { type: "autodate" },
  },
  fileFields: ["cover"],
  expandable: ["author", "tags"],
  isAuth: false,
};

describe("CollectionMeta", () => {
  it("looks up a field by name", () => {
    expect(fieldMeta(postsMeta, "price")?.type).toBe("number");
    expect(fieldMeta(postsMeta, "tags")?.multi).toBe(true);
    expect(fieldMeta(postsMeta, "nope")).toBeUndefined();
  });
});
