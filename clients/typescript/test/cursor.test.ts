import { describe, it, expect } from "vitest";
import {
  encodeCursor,
  decodeCursor,
  appendIdTiebreaker,
  buildKeysetFilter,
  type CursorState,
} from "../src/cursor.js";
import { isZigbaseError } from "../src/errors.js";

describe("cursor token", () => {
  it("round-trips an opaque base64url token", () => {
    const state: CursorState = {
      v: 1,
      sort: "-created,-id",
      values: ["2026-01-01", "rec_9"],
      dir: "next",
    };
    const token = encodeCursor(state);
    expect(token).toMatch(/^[A-Za-z0-9\-_]+$/); // base64url, no padding
    expect(decodeCursor(token, "-created,-id")).toEqual(state);
  });

  it("decodeCursor throws a ZigbaseError on malformed input", () => {
    let threw: unknown;
    try {
      decodeCursor("Zm9v", "-created,-id"); // "foo" — not JSON
    } catch (e) {
      threw = e;
    }
    expect(isZigbaseError(threw)).toBe(true);
  });

  it("decodeCursor throws when the embedded sort does not match the active sort", () => {
    const token = encodeCursor({ v: 1, sort: "-created,-id", values: ["x"], dir: "next" });
    let threw: unknown;
    try {
      decodeCursor(token, "title,id");
    } catch (e) {
      threw = e;
    }
    expect(isZigbaseError(threw)).toBe(true);
    expect((threw as { status: number }).status).toBe(400);
  });
});

describe("appendIdTiebreaker", () => {
  it("appends id with the last term's direction and no duplicate", () => {
    expect(appendIdTiebreaker("-created")).toBe("-created,-id");
    expect(appendIdTiebreaker("title")).toBe("title,id");
    expect(appendIdTiebreaker("-created,title")).toBe("-created,title,id"); // last term asc
    expect(appendIdTiebreaker("-a,-b")).toBe("-a,-b,-id"); // last term desc
  });

  it("does not double-append when id is already the final term", () => {
    expect(appendIdTiebreaker("-created,-id")).toBe("-created,-id");
    expect(appendIdTiebreaker("id")).toBe("id");
  });

  it("defaults to id ascending for an empty sort", () => {
    expect(appendIdTiebreaker("")).toBe("id");
  });
});

describe("buildKeysetFilter", () => {
  it("builds a lexicographic keyset predicate for a single asc key (forward)", () => {
    // sort: created asc (+ id asc tiebreaker); boundary row created=10,id='r5'
    const frag = buildKeysetFilter("created,id", ["10", "r5"], "next");
    expect(frag).toBe("(created > '10') || (created = '10' && id > 'r5')");
  });

  it("inlines numeric boundary values without quotes", () => {
    const frag = buildKeysetFilter("created,id", [10, "r5"], "next");
    expect(frag).toBe("(created > 10) || (created = 10 && id > 'r5')");
  });

  it("flips comparison operators for a desc key", () => {
    const frag = buildKeysetFilter("-created,id", [5, "r5"], "next");
    // created desc -> use <, id asc -> use >
    expect(frag).toBe("(created < 5) || (created = 5 && id > 'r5')");
  });

  it("inverts every operator when paginating backward (prev)", () => {
    const frag = buildKeysetFilter("created,id", [10, "r5"], "prev");
    expect(frag).toBe("(created < 10) || (created = 10 && id < 'r5')");
  });

  it("handles a mixed asc/desc sort with three keys", () => {
    const frag = buildKeysetFilter("title,-created,id", ["Hi", 7, "r1"], "next");
    expect(frag).toBe(
      "(title > 'Hi') || (title = 'Hi' && created < 7) || (title = 'Hi' && created = 7 && id > 'r1')",
    );
  });
});
