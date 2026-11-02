import { existsSync, readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { createClient, createPkceChallenge } from "../src/index.js";

const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;

describe.each(["../README.md", "../../../docs/typescript-sdk.md"])("OAuth example in %s", (path) => {
  const url = new URL(path, import.meta.url);
  const missingGuide = path.startsWith("../../../docs/") && !existsSync(url);

  it.skipIf(missingGuide).each([
    ["server-state", "server-state"],
    ["server-state", "mismatched-state"],
    ["server-state", ""],
    [undefined, "server-state"],
    ["", "server-state"],
  ])("handles issued state %j and callback state %j", async (issuedState, returnedState) => {
    const markdown = readFileSync(url, "utf8");
    const blocks = [...markdown.matchAll(/```ts\n([\s\S]*?)\n```/g)];
    const examples = blocks.map((match) => match[1] ?? "").filter((source) => source.includes('oauth2Init("github")'));
    expect(examples).toHaveLength(1);
    const calls: string[] = [];
    const fetchMock: typeof fetch = async (input, init) => {
      const url = String(input);
      calls.push(url);
      let body: unknown;
      if (url.endsWith("/providers")) body = { items: [{ name: "github" }] };
      else if (url.endsWith("/initiate")) body = { state: issuedState };
      else {
        const payload = JSON.parse(String(init?.body));
        expect(payload.state).toBe("server-state");
        expect(payload.code).toBe("provider-code");
        expect(payload.codeVerifier.length).toBeGreaterThanOrEqual(43);
        body = { token: "session" };
      }
      return new Response(JSON.stringify(body), { headers: { "content-type": "application/json" } });
    };
    const zb = createClient("http://api.test", { fetch: fetchMock });
    const source = examples[0]?.replace(/^import .*;\n/gm, "");
    if (!source) throw new Error("OAuth example missing");
    const run = new AsyncFunction("zb", "createPkceChallenge", "code", "returnedState", source + "\nreturn providers;");
    const result = run(zb, createPkceChallenge, "provider-code", returnedState);
    if (!issuedState) {
      await expect(result).rejects.toThrow("This example requires server-issued OAuth state");
      expect(calls).toHaveLength(2);
    } else if (returnedState === "server-state") {
      expect(await result).toEqual([{ name: "github" }]);
      expect(calls.map((url) => url.split("/").at(-1))).toEqual(["providers", "initiate", "complete"]);
    } else {
      await expect(result).rejects.toThrow("OAuth state mismatch");
      expect(calls).toHaveLength(2);
    }
  });
});
