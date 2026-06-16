import { describe, it, expect } from "vitest";
import { hasBlob, toFormData } from "../src/records.js";

describe("records util", () => {
  it("hasBlob is false for plain JSON-ish bodies", () => {
    expect(hasBlob({ title: "hi", n: 3, ok: true, tags: ["a", "b"] })).toBe(false);
    expect(hasBlob({})).toBe(false);
    expect(hasBlob(undefined)).toBe(false);
  });

  it("hasBlob detects a top-level Blob/File value", () => {
    expect(hasBlob({ title: "hi", avatar: new Blob(["x"]) })).toBe(true);
  });

  it("hasBlob detects an array of Blobs", () => {
    expect(hasBlob({ photos: [new Blob(["a"]), new Blob(["b"])] })).toBe(true);
    expect(hasBlob({ photos: ["a", new Blob(["b"])] })).toBe(true);
  });

  it("toFormData appends scalars, JSON-encodes nested objects, and repeats array files", async () => {
    const fd = toFormData({
      title: "hi",
      count: 3,
      flag: true,
      meta: { a: 1 },
      avatar: new Blob(["x"], { type: "text/plain" }),
      photos: [new Blob(["a"]), new Blob(["b"])],
      skipMe: undefined,
    });
    expect(fd.get("title")).toBe("hi");
    expect(fd.get("count")).toBe("3");
    expect(fd.get("flag")).toBe("true");
    // nested non-blob object is JSON-encoded
    expect(fd.get("meta")).toBe(JSON.stringify({ a: 1 }));
    // single blob present
    expect(fd.get("avatar")).toBeInstanceOf(Blob);
    // array of blobs -> repeated field
    expect(fd.getAll("photos")).toHaveLength(2);
    // undefined dropped
    expect(fd.has("skipMe")).toBe(false);
  });

  it("toFormData null becomes empty string", () => {
    const fd = toFormData({ note: null });
    expect(fd.get("note")).toBe("");
  });

  it("toFormData serializes a Date as a plain ISO string (not JSON-quoted)", () => {
    const fd = toFormData({ when: new Date("2026-01-02T03:04:05.000Z") });
    expect(fd.get("when")).toBe("2026-01-02T03:04:05.000Z");
  });
});
