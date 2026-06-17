import { describe, it, expect } from "vitest";
import { makeTypedFiles } from "../../src/typed/files.js";
import { FilesService } from "../../src/files.js";

describe("makeTypedFiles", () => {
  it("fileUrl builds the SP1 file URL for a record + field", () => {
    const files = new FilesService(null as never, "http://api.test");
    const typed = makeTypedFiles(files);
    const url = typed.fileUrl(
      { id: "p1", collectionName: "posts" },
      "cover",
    );
    expect(url).toBe("http://api.test/api/files/posts/p1/cover");
  });

  it("passes through file URL options (thumb)", () => {
    const files = new FilesService(null as never, "http://api.test");
    const typed = makeTypedFiles(files);
    const url = typed.fileUrl({ id: "p1", collectionName: "posts" }, "cover", {
      thumb: "100x100",
    });
    expect(url).toContain("thumb=100x100");
  });
});
