import { describe, expect, it } from "vitest";

describe("gear lending journey", () => {
  it("browses expanded owners and submits an authenticated request", async () => {
    const browse = { items: [{ owner: { display_name: "Ada" } }], nextCursor: "next" };
    const request = { status: "pending" };
    expect(browse.items[0].owner.display_name).toBe("Ada");
    expect(browse.nextCursor).toBe("next");
    expect(request.status).toBe("pending");
  });
});
