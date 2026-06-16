import { describe, it, expect } from "vitest";
import { parseSort, compareBySort, type SortTerm } from "../src/query.js";

describe("parseSort", () => {
  it("parses +/-/none prefixes and trims blanks", () => {
    expect(parseSort("-created,title")).toEqual<SortTerm[]>([
      { field: "created", dir: "desc" },
      { field: "title", dir: "asc" },
    ]);
    expect(parseSort("+name")).toEqual<SortTerm[]>([{ field: "name", dir: "asc" }]);
    expect(parseSort(" a , , -b ")).toEqual<SortTerm[]>([
      { field: "a", dir: "asc" },
      { field: "b", dir: "desc" },
    ]);
    expect(parseSort("")).toEqual<SortTerm[]>([]);
  });
});

describe("compareBySort", () => {
  const by = (s: string) => (a: Record<string, unknown>, b: Record<string, unknown>) =>
    compareBySort(a, b, parseSort(s));

  it("orders numbers ascending and descending", () => {
    expect(by("n")({ n: 1 }, { n: 2 })).toBeLessThan(0);
    expect(by("-n")({ n: 1 }, { n: 2 })).toBeGreaterThan(0);
  });

  it("orders strings lexically", () => {
    expect(by("name")({ name: "a" }, { name: "b" })).toBeLessThan(0);
  });

  it("orders booleans (false < true)", () => {
    expect(by("flag")({ flag: false }, { flag: true })).toBeLessThan(0);
  });

  it("breaks ties on the second key", () => {
    const cmp = by("-created,title");
    const a = { created: 5, title: "a" };
    const b = { created: 5, title: "b" };
    expect(cmp(a, b)).toBeLessThan(0); // created equal -> title asc -> a<b
  });

  it("places nulls first for asc and last for desc", () => {
    expect(by("x")({ x: null }, { x: 1 })).toBeLessThan(0); // null first asc
    expect(by("-x")({ x: null }, { x: 1 })).toBeGreaterThan(0); // null last desc
    expect(by("x")({ x: null }, { x: null })).toBe(0);
  });

  it("returns 0 when no terms", () => {
    expect(compareBySort({ a: 1 }, { a: 2 }, [])).toBe(0);
  });
});
