import { describe, it, expect } from "vitest";
import { makeTypedFiles } from "../../src/typed/files.js";
import { FilesService } from "../../src/files.js";

describe("makeTypedFiles", () => {
  // NOTE: `fileUrl` accepts the STORED FILENAME (e.g. "photo_abc.png"),
  // NOT the field name (e.g. "cover"). The generated concrete wrapper (Task 9)
  // does the `record[field]` lookup and calls this helper with the resulting
  // filename. The distinction matters: the field name may differ from the
  // stored filename that PocketBase assigns.
  it("fileUrl builds the SP1 file URL using the stored filename, not the field name", () => {
    const files = new FilesService(null as never, "http://api.test");
    const typed = makeTypedFiles(files);
    // "photo_abc.png" is the STORED filename; the field name would be e.g. "cover"
    const url = typed.fileUrl(
      { id: "p1", collectionName: "posts" },
      "photo_abc.png",
    );
    expect(url).toBe("http://api.test/api/files/posts/p1/photo_abc.png");
    expect(url).toContain("photo_abc.png"); // filename, not field name
  });

  it("passes through file URL options (thumb)", () => {
    const files = new FilesService(null as never, "http://api.test");
    const typed = makeTypedFiles(files);
    const url = typed.fileUrl({ id: "p1", collectionName: "posts" }, "photo_abc.png", {
      thumb: "100x100",
    });
    expect(url).toContain("photo_abc.png");
    expect(url).toContain("thumb=100x100");
  });
});
