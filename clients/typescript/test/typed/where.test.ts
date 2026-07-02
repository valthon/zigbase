import { describe, it, expect } from "vitest";
import { compileWhere } from "../../src/typed/where.js";
import type { CollectionMeta } from "../../src/typed/meta.js";

const usersMeta: CollectionMeta = {
  name: "users",
  fields: { name: { type: "text" } },
  fileFields: [],
  expandable: [],
  isAuth: true,
};

const postsMeta: CollectionMeta = {
  name: "posts",
  fields: {
    title: { type: "text" },
    status: { type: "select" },
    price: { type: "number" },
    author: { type: "relation" },
    tags: { type: "relation", multi: true },
    created: { type: "autodate" },
  },
  fileFields: [],
  expandable: ["author", "tags"],
  isAuth: false,
  // The nested-relation compiler needs the target collection's meta; the
  // generator supplies it via a side table — modeled here as a property the
  // compiler reads (see Step 3 `relationMeta`).
};

const itemsMeta: CollectionMeta = {
  name: "items",
  fields: {
    active: { type: "bool" },
    created: { type: "date" },
  },
  fileFields: [],
  expandable: [],
  isAuth: false,
};

const compileItems = (w: unknown) => compileWhere(w, itemsMeta);

const compile = (w: unknown) =>
  compileWhere(w, postsMeta, (col, field) =>
    col === "posts" && field === "author" ? usersMeta : undefined,
  );

describe("compileWhere", () => {
  it("scalar shorthand uses = with the field's type", () => {
    expect(compile({ status: "published" })).toBe("status = 'published'");
    expect(compile({ price: 10 })).toBe("price = 10");
  });

  it("operator objects map to the right comparators", () => {
    expect(compile({ price: { gte: 10 } })).toBe("price >= 10");
    expect(compile({ title: { like: "A" } })).toBe("title ~ 'A'");
    expect(compile({ title: { nlike: "A" } })).toBe("title !~ 'A'");
    expect(compile({ price: { gt: 1, lte: 9 } })).toBe("(price > 1 && price <= 9)");
  });

  it("relation-by-id compares the id", () => {
    expect(compile({ author: "u1" })).toBe("author = 'u1'");
    expect(compile({ author: { neq: "u1" } })).toBe("author != 'u1'");
  });

  it("`in` compiles to the native operator; empty `in` is constant-false `in ()`", () => {
    expect(compile({ status: { in: ["a", "b"] } })).toBe("status in ('a', 'b')");
    expect(compile({ tags: { in: ["t1", "t2"] } })).toBe("tags in ('t1', 't2')");
    expect(compile({ price: { in: [1, 2, 3] } })).toBe("price in (1, 2, 3)");
    expect(compile({ status: { in: [] } })).toBe("status in ()");
    // injection-safe: elements go through quoteFilterValue
    expect(compile({ status: { in: ["a'b"] } })).toBe("status in ('a\\'b')");
  });

  it("AND/OR arrays combine sub-wheres", () => {
    expect(
      compile({ AND: [{ status: "published" }, { price: { gte: 5 } }] }),
    ).toBe("(status = 'published' && price >= 5)");
    expect(
      compile({ OR: [{ status: "a" }, { status: "b" }] }),
    ).toBe("(status = 'a' || status = 'b')");
  });

  it("top-level multiple fields are AND-joined", () => {
    expect(compile({ status: "published", price: { gte: 5 } })).toBe(
      "(status = 'published' && price >= 5)",
    );
  });

  it("nested relation where uses a dotted prefix (depth 1)", () => {
    expect(compile({ author: { name: { like: "A" } } })).toBe("author.name ~ 'A'");
    expect(compile({ author: { name: "Ann" } })).toBe("author.name = 'Ann'");
  });

  it("is injection-safe via shared quoting", () => {
    expect(compile({ title: "a' || 1=1 --" })).toBe("title = 'a\\' || 1=1 --'");
  });

  it("empty where compiles to empty string", () => {
    expect(compile({})).toBe("");
    expect(compile(undefined)).toBe("");
  });

  it("empty-object field values are silently dropped", () => {
    // { author: {} } and { price: {} } contain no operator keys, so they compile
    // to no clauses. An empty relation object is not a nested-where (no resolvable
    // fields) and not an id-op (no recognized keys) — the output is "".
    expect(compile({ author: {} })).toBe("");
    expect(compile({ price: {} })).toBe("");
  });

  it("`in` on a resolvable relation field produces id-level `in` (not nested where)", () => {
    // { author: { in: ['u1','u2'] } } — `in` is an operator key, so looksLikeOps
    // is true and this is treated as a relation-id operator, NOT a nested where.
    expect(compile({ author: { in: ["u1", "u2"] } })).toBe(
      "author in ('u1', 'u2')",
    );
  });

  it("AND array containing null does not throw; null element contributes empty string (dropped)", () => {
    // compileNode must guard against non-object elements in AND/OR arrays.
    // A null/undefined element should return "" and be dropped from the clause join.
    expect(
      () => compile({ AND: [{ status: "a" }, null as unknown as object] }),
    ).not.toThrow();
    expect(compile({ AND: [{ status: "a" }, null as unknown as object] })).toBe(
      "status = 'a'",
    );
  });

  it("OR array containing undefined does not throw; undefined element is dropped", () => {
    expect(
      () => compile({ OR: [{ status: "a" }, undefined as unknown as object] }),
    ).not.toThrow();
    expect(compile({ OR: [{ status: "a" }, undefined as unknown as object] })).toBe(
      "status = 'a'",
    );
  });

  it("maxDepth: 0 prevents nested where from recursing (falls through to id-operator)", () => {
    // With maxDepth=0 the depth budget is exhausted before any nesting can happen.
    // { author: { name: { like: 'A' } } } — at depth 0, the object is treated as
    // id-operators; 'name' is not a recognized operator key so compileOps throws.
    // Callers that don't need nested relation wheres should pass maxDepth=0.
    const compileNoDepth = (w: unknown) =>
      compileWhere(w, postsMeta, (col, field) =>
        col === "posts" && field === "author" ? usersMeta : undefined,
        0, // maxDepth = 0
      );
    // Simple relation-id ops still work at depth 0.
    expect(compileNoDepth({ author: "u1" })).toBe("author = 'u1'");
    expect(compileNoDepth({ author: { eq: "u1" } })).toBe("author = 'u1'");
    // Nested field object at depth 0 is treated as id-operators and throws because
    // 'name' is not a recognized operator key.
    expect(() => compileNoDepth({ author: { name: { like: "A" } } })).toThrow();
  });
});

describe("bool and date neq/in ops", () => {
  it("bool neq compiles to != true", () => {
    expect(compileItems({ active: { neq: true } })).toBe("active != true");
  });

  it("date neq compiles to != with quoted string", () => {
    expect(compileItems({ created: { neq: "2026-01-01" } })).toBe("created != '2026-01-01'");
  });

  it("date in compiles to the native operator", () => {
    expect(compileItems({ created: { in: ["2026-01-01", "2026-02-01"] } })).toBe(
      "created in ('2026-01-01', '2026-02-01')",
    );
  });
});

/**
 * DISAMBIGUATION INVARIANT (documented in compileWhere):
 * A plain object on a relation field is treated as a NESTED WHERE only when:
 *   (a) FieldMeta.type === "relation"
 *   (b) depth budget > 0
 *   (c) a resolver returns target meta
 *   (d) the object's keys are NOT all operator keys (looksLikeOps is false)
 * Consequence: relation-target collections must not have fields whose names are
 * operator keys (eq/neq/gt/gte/lt/lte/like/nlike/in) — a nested where on such a
 * field would be misparsed as an id-level operator. Document this constraint in
 * the generated schema validator (SP2.1b).
 */
