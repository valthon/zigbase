import { describe, it, expect } from "vitest";
import { parseFilter, evaluateFilter } from "../src/live/filter-eval.js";

describe("filter evaluator", () => {
  it("evaluates a compound && / || filter on own scalar fields", () => {
    const ast = parseFilter("status = 'published' && (views > 10 || pinned = true)");
    expect(evaluateFilter({ status: "published", views: 3, pinned: true }, ast)).toBe(true);
    expect(evaluateFilter({ status: "published", views: 20, pinned: false }, ast)).toBe(true);
    expect(evaluateFilter({ status: "draft", views: 99, pinned: true }, ast)).toBe(false);
    expect(evaluateFilter({ status: "published", views: 3, pinned: false }, ast)).toBe(false);
  });

  it("handles all comparison operators", () => {
    const r = { n: 5, s: "hello" };
    expect(evaluateFilter(r, parseFilter("n = 5"))).toBe(true);
    expect(evaluateFilter(r, parseFilter("n != 6"))).toBe(true);
    expect(evaluateFilter(r, parseFilter("n >= 5"))).toBe(true);
    expect(evaluateFilter(r, parseFilter("n <= 4"))).toBe(false);
    expect(evaluateFilter(r, parseFilter("n > 4"))).toBe(true);
    expect(evaluateFilter(r, parseFilter("n < 5"))).toBe(false);
  });

  it("does case-sensitive substring with ~ and !~", () => {
    const r = { title: "Hello World" };
    expect(evaluateFilter(r, parseFilter("title ~ 'World'"))).toBe(true);
    expect(evaluateFilter(r, parseFilter("title ~ 'world'"))).toBe(false); // case-sensitive
    expect(evaluateFilter(r, parseFilter("title !~ 'xyz'"))).toBe(true);
  });

  it("compares against null", () => {
    expect(evaluateFilter({ deletedAt: null }, parseFilter("deletedAt = null"))).toBe(true);
    expect(evaluateFilter({ deletedAt: "2026" }, parseFilter("deletedAt = null"))).toBe(false);
    expect(evaluateFilter({ deletedAt: "2026" }, parseFilter("deletedAt != null"))).toBe(true);
  });

  it("reads dotted paths against expanded relations present on the record", () => {
    const r = { id: "p1", author: { name: "Ada" } };
    expect(evaluateFilter(r, parseFilter("author.name = 'Ada'"))).toBe(true);
    // missing path resolves to undefined -> not equal
    expect(evaluateFilter({ id: "p2" }, parseFilter("author.name = 'Ada'"))).toBe(false);
  });
});
