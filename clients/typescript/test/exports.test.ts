import { describe, it, expect } from "vitest";
import * as zb from "../src/index.js";

describe("public exports (Plan 2)", () => {
  it("re-exports the query helpers", () => {
    expect(typeof zb.filter).toBe("function");
    expect(typeof zb.parseSort).toBe("function");
    expect(typeof zb.compareBySort).toBe("function");
  });

  it("no longer exports client-side cursor synthesis helpers", () => {
    // Native server cursors replaced client synthesis; these are intentionally gone.
    expect((zb as Record<string, unknown>).encodeCursor).toBeUndefined();
    expect((zb as Record<string, unknown>).decodeCursor).toBeUndefined();
    expect((zb as Record<string, unknown>).buildKeysetFilter).toBeUndefined();
    expect((zb as Record<string, unknown>).appendIdTiebreaker).toBeUndefined();
  });

  it("re-exports FilesService", () => {
    expect(typeof zb.FilesService).toBe("function");
  });

  it("re-exports record/multipart helpers", () => {
    expect(typeof zb.hasBlob).toBe("function");
    expect(typeof zb.toFormData).toBe("function");
  });
});
