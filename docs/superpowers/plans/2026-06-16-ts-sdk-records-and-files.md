# TypeScript SDK — Plan 2: Records, Pagination & Files Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Layer record CRUD, offset + cursor (keyset) pagination, a safe `filter` template tag with a reusable sort comparator engine, automatic multipart uploads, and file URL/token helpers onto the `@zigbase/client` foundation from Plan 1 — so `zb.collection('posts')` can read, write, paginate, stream, and upload against a real ZigBase backend.

**Architecture:** Record methods are added **directly to the existing `CollectionService`** (`src/collection.ts`) — not a separate `RecordService` — so `zb.collection('x')` exposes both auth methods (Plan 1) and record methods on one object, matching the spec's "RecordService (+ auth methods; dynamic, so both present)". Pure, transport-free engines live in their own tree-shakeable modules: `src/query.ts` (filter tag + sort comparator), `src/cursor.ts` (opaque keyset token + predicate builder), and `src/files.ts` (`FilesService`). Cursor pagination is **client-synthesized over the offset+filter wire** (fetch `limit+1` rows; append a keyset predicate to the user filter; auto-append an `id` tiebreaker whose direction follows the last user-sort term) so a future native server cursor can slot in without changing the public surface.

**Tech Stack:** TypeScript (ES2022, strict), `vitest` with a mocked `fetch` for unit tests, the real `zigbase serve` binary (via the Plan 1 integration harness) for integration tests. Zero runtime dependencies — platform globals only (`fetch`, `FormData`, `Blob`, `btoa`/`atob`, `TextEncoder`).

**Plan context:** This is **Plan 2 of 3** for SP1 (the base runtime SDK). Plan 1 (`docs/superpowers/plans/2026-06-16-ts-sdk-foundation.md`) built the error model, JWT decode, AuthStores, transport, client core, and auth service. **Plan 3** adds realtime + the high-level live store and will **import the `compareBySort` / `SortTerm` signatures and the `ListResult` / `CursorPage` types defined here unchanged** — keep them stable. Spec: `docs/superpowers/specs/2026-06-16-zigbase-ts-sdk-base-design.md` (read **Records & pagination** and **Files** closely).

### Existing API this plan builds on (from Plan 1 — do NOT redefine)

- `src/transport.ts` → `class Transport` with `send<T>(path, opts)`, `opts = { method?, query?, body?, headers?, signal?, skipAuth? }`. If `body instanceof FormData` it is passed through **without** a JSON `Content-Type`; otherwise a non-GET body is JSON-stringified. `204` returns `undefined`. Non-2xx throws `ZigbaseError`.
- `src/collection.ts` → `class CollectionService` (constructor `(transport, authStore, name)`, protected `base()` → `/api/collections/<name>`, plus the auth methods). **Record methods extend this same class.**
- `src/errors.ts` → `ZigbaseError`, `isZigbaseError` (and `parseErrorResponse`). `src/auth-store.ts` → `AuthStore`, `AuthRecord`. `src/client.ts` → `createClient`, `collection(name)` → `CollectionService`. `src/index.ts` re-exports.
- `test/integration/harness.ts` → `startServer`, `superuserToken`, `createCollection`; `vitest.integration.config.ts` runs `test/integration/**/*.integration.test.ts`.

All paths below are relative to `clients/typescript/`. Run commands assume `cd clients/typescript`.

---

## File Structure

| File | Responsibility |
| --- | --- |
| `src/records.ts` | Shared record types (`ZbRecord`, `ListResult`, `ListOpts`, `RecordCrudOpts`) + the `hasBlob` multipart detector + `toFormData`. |
| `src/collection.ts` | **Modified** — add record CRUD (`getList`/`getOne`/`getFirstListItem`/`create`/`update`/`delete`/`getFullList`) and cursor methods (`getPage`/`iterate`) to `CollectionService`. |
| `src/query.ts` | safe `filter\`…\`` template tag, `parseSort`, `compareBySort`, `SortTerm`. |
| `src/cursor.ts` | `CursorPage`, `CursorState`, `encodeCursor`/`decodeCursor`, `buildKeysetFilter`, `appendIdTiebreaker`. |
| `src/files.ts` | `FilesService` (`getUrl`, `getToken`). |
| `src/client.ts` | **Modified** — lazy `files` getter exposing `FilesService`. |
| `src/index.ts` | **Modified** — re-export new types/classes/helpers. |
| `README.md` | **Modified** — records + cursor + file examples. |
| `test/records.test.ts`, `test/query.test.ts`, `test/cursor.test.ts`, `test/files.test.ts` | unit tests (mocked `fetch`). |
| `test/integration/records.integration.test.ts` | live-binary records/cursor/files round-trip. |

---

## Task 1: Record types + multipart detection (`src/records.ts`)

**Files:**
- Create: `clients/typescript/src/records.ts`
- Test: `clients/typescript/test/records-util.test.ts`

- [ ] **Step 1: Write the failing test**

```ts
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
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npm test -- records-util`
Expected: FAIL — cannot find `../src/records.js`.

- [ ] **Step 3: Implement `src/records.ts`**

```ts
/** Permissive default record shape used by the dynamic base SDK. SP2 substitutes real types. */
export interface ZbRecord {
  id: string;
  [key: string]: unknown;
}

/** Result shape of an offset-paginated list (`getList`). Mirrors the wire envelope. */
export interface ListResult<T> {
  page: number;
  perPage: number;
  totalItems: number;
  totalPages: number;
  items: T[];
}

/** Options accepted by list reads. */
export interface ListOpts {
  filter?: string;
  sort?: string;
  expand?: string;
  fields?: string;
  skipTotal?: boolean;
  signal?: AbortSignal;
}

/** Options accepted by single-record reads/writes. */
export interface RecordCrudOpts {
  expand?: string;
  fields?: string;
  signal?: AbortSignal;
}

function isBlobLike(v: unknown): v is Blob {
  return typeof Blob !== "undefined" && v instanceof Blob;
}

/**
 * True when `body` contains a File/Blob (or an array of them) at the top level,
 * meaning the request must be sent as multipart/form-data instead of JSON.
 */
export function hasBlob(body: unknown): boolean {
  if (!body || typeof body !== "object" || Array.isArray(body)) return false;
  for (const value of Object.values(body as Record<string, unknown>)) {
    if (isBlobLike(value)) return true;
    if (Array.isArray(value) && value.some(isBlobLike)) return true;
  }
  return false;
}

/**
 * Build a FormData payload from a plain object:
 * - undefined values are skipped, null becomes "".
 * - Blob/File values (and arrays thereof) are appended as files (repeated for arrays).
 * - scalars are stringified; nested plain objects/arrays are JSON-encoded.
 */
export function toFormData(body: Record<string, unknown>): FormData {
  const fd = new FormData();
  for (const [key, value] of Object.entries(body)) {
    if (value === undefined) continue;
    if (value === null) {
      fd.append(key, "");
    } else if (isBlobLike(value)) {
      fd.append(key, value);
    } else if (Array.isArray(value)) {
      for (const item of value) {
        if (isBlobLike(item)) fd.append(key, item);
        else if (item === null || item === undefined) continue;
        else if (typeof item === "object") fd.append(key, JSON.stringify(item));
        else fd.append(key, String(item));
      }
    } else if (typeof value === "object") {
      fd.append(key, JSON.stringify(value));
    } else {
      fd.append(key, String(value));
    }
  }
  return fd;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npm test -- records-util`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add clients/typescript/src/records.ts clients/typescript/test/records-util.test.ts
git commit -m "feat(ts-sdk): record types + multipart (hasBlob/toFormData)"
```

---

## Task 2: Safe filter template tag (`src/query.ts`)

**Files:**
- Create: `clients/typescript/src/query.ts`
- Test: `clients/typescript/test/query-filter.test.ts`

- [ ] **Step 1: Write the failing test**

```ts
import { describe, it, expect } from "vitest";
import { filter } from "../src/query.js";

describe("filter template tag", () => {
  it("inlines numbers, booleans, and null without quotes", () => {
    expect(filter`n > ${5}`).toBe("n > 5");
    expect(filter`active = ${true}`).toBe("active = true");
    expect(filter`deleted = ${null}`).toBe("deleted = null");
    expect(filter`x = ${3.14}`).toBe("x = 3.14");
  });

  it("single-quotes strings", () => {
    expect(filter`status = ${"published"}`).toBe("status = 'published'");
  });

  it("escapes embedded single quotes and backslashes", () => {
    expect(filter`name = ${"O'Brien"}`).toBe("name = 'O\\'Brien'");
    expect(filter`path = ${"a\\b"}`).toBe("path = 'a\\\\b'");
  });

  it("escapes control characters (newline, tab)", () => {
    expect(filter`note = ${"a\nb\tc"}`).toBe("note = 'a\\nb\\tc'");
  });

  it("neutralizes an injection attempt", () => {
    const evil = "' || 1=1 --";
    // the quote is escaped, so the whole value stays a single string literal
    expect(filter`name = ${evil}`).toBe("name = '\\' || 1=1 --'");
  });

  it("serializes Date as an ISO string literal", () => {
    const d = new Date("2026-06-16T00:00:00.000Z");
    expect(filter`created > ${d}`).toBe("created > '2026-06-16T00:00:00.000Z'");
  });

  it("throws on array operands (ambiguous; callers must expand explicitly)", () => {
    expect(() => filter`id = ${["a", "b"]}`).toThrow(/array/i);
  });

  it("composes multiple interpolations with static text", () => {
    const q = "ab";
    expect(filter`status = ${"x"} && author.name ~ ${q}`).toBe(
      "status = 'x' && author.name ~ 'ab'",
    );
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npm test -- query-filter`
Expected: FAIL — cannot find `../src/query.js`.

- [ ] **Step 3: Implement the `filter` tag in `src/query.ts`**

Create the file with the filter tag (sort helpers append in Task 3):

```ts
/** Escape a JS string into a single-quoted filter literal per the ZigBase grammar. */
function quoteString(s: string): string {
  let out = "'";
  for (const ch of s) {
    switch (ch) {
      case "\\":
        out += "\\\\";
        break;
      case "'":
        out += "\\'";
        break;
      case "\n":
        out += "\\n";
        break;
      case "\r":
        out += "\\r";
        break;
      case "\t":
        out += "\\t";
        break;
      default:
        // other C0 control chars -> \u00XX
        if (ch.charCodeAt(0) < 0x20) {
          out += "\\u" + ch.charCodeAt(0).toString(16).padStart(4, "0");
        } else {
          out += ch;
        }
    }
  }
  return out + "'";
}

/** Serialize a single interpolated value into a safe filter operand. */
export function filterValue(value: unknown): string {
  if (value === null || value === undefined) return "null";
  if (typeof value === "number") {
    if (!Number.isFinite(value)) throw new Error(`filter: non-finite number operand: ${value}`);
    return String(value);
  }
  if (typeof value === "boolean") return value ? "true" : "false";
  if (value instanceof Date) return quoteString(value.toISOString());
  if (typeof value === "string") return quoteString(value);
  if (Array.isArray(value)) {
    throw new Error(
      "filter: array operands are ambiguous; expand them yourself (e.g. build an `||` chain)",
    );
  }
  // objects, functions, symbols, bigint -> reject rather than silently coerce
  throw new Error(`filter: unsupported operand type: ${typeof value}`);
}

/**
 * Tagged template that safely builds a ZigBase filter string. Interpolated values are
 * quoted/escaped against the grammar; static template text is passed through verbatim.
 *
 *   filter`status = ${'published'} && n > ${5}`  // => status = 'published' && n > 5
 */
export function filter(strings: TemplateStringsArray, ...values: unknown[]): string {
  let out = strings[0] ?? "";
  for (let i = 0; i < values.length; i++) {
    out += filterValue(values[i]) + (strings[i + 1] ?? "");
  }
  return out;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npm test -- query-filter`
Expected: PASS (8 tests).

- [ ] **Step 5: Commit**

```bash
git add clients/typescript/src/query.ts clients/typescript/test/query-filter.test.ts
git commit -m "feat(ts-sdk): safe filter template tag with grammar escaping"
```

---

## Task 3: Sort engine — `parseSort` + `compareBySort` (`src/query.ts`)

**Files:**
- Modify: `clients/typescript/src/query.ts`
- Test: `clients/typescript/test/query-sort.test.ts`

> **Stability contract for Plan 3:** `SortTerm` and the exact `compareBySort(a, b, terms)` signature defined here are imported unchanged by Plan 3's live store to decide list ordering. Do not rename or reshape them.

- [ ] **Step 1: Write the failing test**

```ts
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npm test -- query-sort`
Expected: FAIL — `parseSort`/`compareBySort` not exported.

- [ ] **Step 3: Append the sort engine to `src/query.ts`**

```ts
export interface SortTerm {
  field: string;
  dir: "asc" | "desc";
}

/**
 * Parse a sort string ("-created,title") into ordered terms.
 * Leading "-" = desc; leading "+" or no prefix = asc; blank terms are dropped.
 */
export function parseSort(sort: string): SortTerm[] {
  const terms: SortTerm[] = [];
  for (const raw of sort.split(",")) {
    const t = raw.trim();
    if (!t) continue;
    if (t.startsWith("-")) terms.push({ field: t.slice(1).trim(), dir: "desc" });
    else if (t.startsWith("+")) terms.push({ field: t.slice(1).trim(), dir: "asc" });
    else terms.push({ field: t, dir: "asc" });
  }
  return terms.filter((t) => t.field.length > 0);
}

/** Read a possibly-dotted field path ("author.name") out of a record. */
function readPath(obj: Record<string, unknown>, path: string): unknown {
  if (!path.includes(".")) return obj[path];
  let cur: unknown = obj;
  for (const seg of path.split(".")) {
    if (cur === null || cur === undefined || typeof cur !== "object") return undefined;
    cur = (cur as Record<string, unknown>)[seg];
  }
  return cur;
}

/** Compare two scalar values; nulls/undefined sort BEFORE everything (caller flips for desc). */
function compareScalar(a: unknown, b: unknown): number {
  const an = a === null || a === undefined;
  const bn = b === null || b === undefined;
  if (an && bn) return 0;
  if (an) return -1; // null first (ascending baseline)
  if (bn) return 1;
  if (typeof a === "number" && typeof b === "number") return a - b;
  if (typeof a === "boolean" && typeof b === "boolean") {
    return (a ? 1 : 0) - (b ? 1 : 0);
  }
  const as = String(a);
  const bs = String(b);
  return as < bs ? -1 : as > bs ? 1 : 0;
}

/**
 * Multi-key comparator over sort terms. Null/undefined values sort first under asc
 * and last under desc. Reused by cursor keyset boundaries (Task 5) and Plan 3's live list.
 */
export function compareBySort(
  a: Record<string, unknown>,
  b: Record<string, unknown>,
  terms: SortTerm[],
): number {
  for (const term of terms) {
    const cmp = compareScalar(readPath(a, term.field), readPath(b, term.field));
    if (cmp !== 0) return term.dir === "desc" ? -cmp : cmp;
  }
  return 0;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npm test -- query-sort`
Expected: PASS (8 tests across the two describe blocks).

- [ ] **Step 5: Commit**

```bash
git add clients/typescript/src/query.ts clients/typescript/test/query-sort.test.ts
git commit -m "feat(ts-sdk): sort engine (parseSort + compareBySort comparator)"
```

---

## Task 4: Offset CRUD on `CollectionService` (`src/collection.ts`)

**Files:**
- Modify: `clients/typescript/src/collection.ts`
- Test: `clients/typescript/test/records.test.ts`

> **Design decision:** record methods are added to `CollectionService` itself (not a separate `RecordService`), so a single `zb.collection('x')` object carries both auth and record methods — exactly as the spec describes. `getFirstListItem` **throws** a `ZigbaseError`-shaped `404` when no record matches (matching PocketBase-familiar behavior); this is asserted in the test.

- [ ] **Step 1: Write the failing test**

```ts
import { describe, it, expect, vi } from "vitest";
import { createClient } from "../src/index.js";
import { isZigbaseError } from "../src/errors.js";
import { hasBlob } from "../src/records.js";

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

describe("record CRUD", () => {
  it("getList builds the records URL with page/perPage/filter/sort and parses the envelope", async () => {
    const fetchMock = vi.fn(async (url: string) => {
      expect(url).toBe(
        "http://api.test/api/collections/posts/records?page=2&perPage=10&filter=status+%3D+%27x%27&sort=-created",
      );
      return jsonResponse({ page: 2, perPage: 10, totalItems: 12, totalPages: 2, items: [{ id: "a" }] });
    }) as unknown as typeof fetch;

    const zb = createClient("http://api.test", { fetch: fetchMock });
    const out = await zb.collection("posts").getList(2, 10, { filter: "status = 'x'", sort: "-created" });
    expect(out.totalItems).toBe(12);
    expect(out.items[0]?.id).toBe("a");
  });

  it("getList clamps perPage to the server max of 500", async () => {
    const fetchMock = vi.fn(async (url: string) => {
      expect(url).toContain("perPage=500");
      return jsonResponse({ page: 1, perPage: 500, totalItems: 0, totalPages: 0, items: [] });
    }) as unknown as typeof fetch;
    const zb = createClient("http://api.test", { fetch: fetchMock });
    await zb.collection("posts").getList(1, 9999);
  });

  it("getOne fetches a single record with expand", async () => {
    const fetchMock = vi.fn(async (url: string) => {
      expect(url).toBe("http://api.test/api/collections/posts/records/abc?expand=author");
      return jsonResponse({ id: "abc", title: "Hi" });
    }) as unknown as typeof fetch;
    const zb = createClient("http://api.test", { fetch: fetchMock });
    const out = await zb.collection("posts").getOne("abc", { expand: "author" });
    expect(out.id).toBe("abc");
  });

  it("getFirstListItem returns the first match", async () => {
    const fetchMock = vi.fn(async (url: string) => {
      expect(url).toContain("page=1");
      expect(url).toContain("perPage=1");
      return jsonResponse({ page: 1, perPage: 1, totalItems: 1, totalPages: 1, items: [{ id: "f1" }] });
    }) as unknown as typeof fetch;
    const zb = createClient("http://api.test", { fetch: fetchMock });
    const out = await zb.collection("posts").getFirstListItem("status = 'x'");
    expect(out.id).toBe("f1");
  });

  it("getFirstListItem throws a 404 ZigbaseError when empty", async () => {
    const fetchMock = vi.fn(async () =>
      jsonResponse({ page: 1, perPage: 1, totalItems: 0, totalPages: 0, items: [] }),
    ) as unknown as typeof fetch;
    const zb = createClient("http://api.test", { fetch: fetchMock });
    await expect(zb.collection("posts").getFirstListItem("status = 'none'")).rejects.toSatisfy(
      (e: unknown) => isZigbaseError(e) && (e as { status: number }).status === 404,
    );
  });

  it("create sends a JSON body and returns the 201 record", async () => {
    const fetchMock = vi.fn(async (url: string, init: RequestInit) => {
      expect(url).toBe("http://api.test/api/collections/posts/records");
      expect(init.method).toBe("POST");
      expect(JSON.parse(init.body as string)).toEqual({ title: "Hi" });
      return jsonResponse({ id: "new1", title: "Hi" }, 201);
    }) as unknown as typeof fetch;
    const zb = createClient("http://api.test", { fetch: fetchMock });
    const out = await zb.collection("posts").create({ title: "Hi" });
    expect(out.id).toBe("new1");
  });

  it("create auto-switches to multipart when a Blob is present", async () => {
    expect(hasBlob({ title: "Hi", file: new Blob(["x"]) })).toBe(true);
    const fetchMock = vi.fn(async (_url: string, init: RequestInit) => {
      expect(init.body).toBeInstanceOf(FormData);
      const headers = new Headers(init.headers);
      // transport must NOT set a JSON content-type for FormData (Plan 1 behavior)
      expect(headers.get("content-type")).toBeNull();
      return jsonResponse({ id: "up1" }, 201);
    }) as unknown as typeof fetch;
    const zb = createClient("http://api.test", { fetch: fetchMock });
    const out = await zb.collection("posts").create({ title: "Hi", file: new Blob(["x"]) });
    expect(out.id).toBe("up1");
  });

  it("update PATCHes and returns the record", async () => {
    const fetchMock = vi.fn(async (url: string, init: RequestInit) => {
      expect(url).toBe("http://api.test/api/collections/posts/records/x1");
      expect(init.method).toBe("PATCH");
      return jsonResponse({ id: "x1", title: "Edited" });
    }) as unknown as typeof fetch;
    const zb = createClient("http://api.test", { fetch: fetchMock });
    const out = await zb.collection("posts").update("x1", { title: "Edited" });
    expect(out.title).toBe("Edited");
  });

  it("delete sends DELETE and resolves void on 204", async () => {
    const fetchMock = vi.fn(async (url: string, init: RequestInit) => {
      expect(url).toBe("http://api.test/api/collections/posts/records/x1");
      expect(init.method).toBe("DELETE");
      return new Response(null, { status: 204 });
    }) as unknown as typeof fetch;
    const zb = createClient("http://api.test", { fetch: fetchMock });
    await expect(zb.collection("posts").delete("x1")).resolves.toBeUndefined();
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npm test -- records.test`
Expected: FAIL — `getList` is not a function.

- [ ] **Step 3: Add record CRUD to `src/collection.ts`**

At the top of `src/collection.ts`, add imports alongside the existing ones:

```ts
import { ZigbaseError } from "./errors.js";
import {
  type ZbRecord,
  type ListResult,
  type ListOpts,
  type RecordCrudOpts,
  hasBlob,
  toFormData,
} from "./records.js";
```

Then add these methods **inside** the existing `CollectionService` class body (after the auth methods, before the closing brace):

```ts
  /** `/api/collections/<name>/records` */
  private recordsBase(): string {
    return `${this.base()}/records`;
  }

  /** Offset pagination. `perPage` is clamped to the server max of 500. */
  getList<T = ZbRecord>(page = 1, perPage = 30, opts: ListOpts = {}): Promise<ListResult<T>> {
    return this.transport.send<ListResult<T>>(this.recordsBase(), {
      method: "GET",
      query: {
        page,
        perPage: Math.min(Math.max(perPage, 1), 500),
        filter: opts.filter,
        sort: opts.sort,
        expand: opts.expand,
        fields: opts.fields,
        skipTotal: opts.skipTotal ? 1 : undefined,
      },
      signal: opts.signal,
    });
  }

  getOne<T = ZbRecord>(id: string, opts: RecordCrudOpts = {}): Promise<T> {
    return this.transport.send<T>(`${this.recordsBase()}/${encodeURIComponent(id)}`, {
      method: "GET",
      query: { expand: opts.expand, fields: opts.fields },
      signal: opts.signal,
    });
  }

  /** getList(1, 1) sugar. Throws a 404 ZigbaseError when nothing matches. */
  async getFirstListItem<T = ZbRecord>(
    filter: string,
    opts: Omit<ListOpts, "filter"> = {},
  ): Promise<T> {
    const list = await this.getList<T>(1, 1, { ...opts, filter, skipTotal: true });
    const first = list.items[0];
    if (first === undefined) {
      throw new ZigbaseError({
        status: 404,
        message: "No record found matching the filter.",
        url: this.recordsBase(),
      });
    }
    return first;
  }

  /** Create a record. Auto-switches to multipart when the body contains a Blob/File. */
  create<T = ZbRecord>(body: Record<string, unknown>, opts: RecordCrudOpts = {}): Promise<T> {
    const payload = hasBlob(body) ? toFormData(body) : body;
    return this.transport.send<T>(this.recordsBase(), {
      method: "POST",
      body: payload,
      query: { expand: opts.expand, fields: opts.fields },
      signal: opts.signal,
    });
  }

  update<T = ZbRecord>(
    id: string,
    body: Record<string, unknown>,
    opts: RecordCrudOpts = {},
  ): Promise<T> {
    const payload = hasBlob(body) ? toFormData(body) : body;
    return this.transport.send<T>(`${this.recordsBase()}/${encodeURIComponent(id)}`, {
      method: "PATCH",
      body: payload,
      query: { expand: opts.expand, fields: opts.fields },
      signal: opts.signal,
    });
  }

  async delete(id: string): Promise<void> {
    await this.transport.send<void>(`${this.recordsBase()}/${encodeURIComponent(id)}`, {
      method: "DELETE",
    });
  }
```

> **Note (execution time):** Plan 1's `RequestOptions` already includes `signal`. If `query` does not accept `1` (number) for `skipTotal`, the value is stringified by the transport's `URLSearchParams` path; this is fine. The transport drops `undefined` query values, so unset opts produce no query keys.

- [ ] **Step 4: Run test to verify it passes**

Run: `npm test -- records.test`
Expected: PASS (9 tests).

- [ ] **Step 5: Commit**

```bash
git add clients/typescript/src/collection.ts clients/typescript/test/records.test.ts
git commit -m "feat(ts-sdk): offset record CRUD on CollectionService"
```

---

## Task 5: Cursor token + keyset predicate (`src/cursor.ts`)

**Files:**
- Create: `clients/typescript/src/cursor.ts`
- Test: `clients/typescript/test/cursor.test.ts`

> **Cross-cutting requirement (document in code + README):** the cursor engine auto-appends `id` as the **final sort tiebreaker**, and the synthesized `id` term's direction follows the **last user sort term's direction** (NOT hardcoded `desc`). This keeps SDK-synthesized cursors byte/semantics-compatible with a future native server cursor. The keyset predicate uses the SAME value escaping as the `filter` tag (`filterValue`).

- [ ] **Step 1: Write the failing test**

```ts
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npm test -- cursor.test`
Expected: FAIL — cannot find `../src/cursor.js`.

- [ ] **Step 3: Implement `src/cursor.ts`**

```ts
import { ZigbaseError } from "./errors.js";
import { filterValue, parseSort, type SortTerm } from "./query.js";

export interface CursorPage<T> {
  items: T[];
  nextCursor: string | null;
  prevCursor: string | null;
  hasNext: boolean;
  hasPrev: boolean;
  totalItems?: number;
}

/** Opaque cursor payload. `sort` is the EFFECTIVE sort (incl. the id tiebreaker). */
export interface CursorState {
  v: 1;
  sort: string;
  values: unknown[];
  dir: "next" | "prev";
}

function toBase64Url(s: string): string {
  // utf8 -> base64url, no padding
  const bytes = new TextEncoder().encode(s);
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function fromBase64Url(token: string): string {
  const padded = token.replace(/-/g, "+").replace(/_/g, "/");
  const pad = padded.length % 4 === 0 ? "" : "=".repeat(4 - (padded.length % 4));
  const binary = atob(padded + pad);
  const bytes = Uint8Array.from(binary, (c) => c.charCodeAt(0));
  return new TextDecoder().decode(bytes);
}

export function encodeCursor(state: CursorState): string {
  return toBase64Url(JSON.stringify(state));
}

/**
 * Decode + structurally validate a cursor token. `activeSort` is the effective sort the
 * caller is paginating with; a mismatch (or any malformed token) throws a 400 ZigbaseError.
 */
export function decodeCursor(token: string, activeSort: string): CursorState {
  let parsed: unknown;
  try {
    parsed = JSON.parse(fromBase64Url(token));
  } catch {
    throw new ZigbaseError({ status: 400, message: "Malformed cursor token.", url: "" });
  }
  const s = parsed as Partial<CursorState>;
  if (
    !s ||
    s.v !== 1 ||
    typeof s.sort !== "string" ||
    !Array.isArray(s.values) ||
    (s.dir !== "next" && s.dir !== "prev")
  ) {
    throw new ZigbaseError({ status: 400, message: "Invalid cursor structure.", url: "" });
  }
  if (s.sort !== activeSort) {
    throw new ZigbaseError({
      status: 400,
      message: `Cursor sort "${s.sort}" does not match the active sort "${activeSort}".`,
      url: "",
    });
  }
  return { v: 1, sort: s.sort, values: s.values, dir: s.dir };
}

function normalizeSort(terms: SortTerm[]): string {
  return terms.map((t) => (t.dir === "desc" ? `-${t.field}` : t.field)).join(",");
}

/**
 * Append `id` as a final tiebreaker term. The id term's direction follows the LAST
 * user-sort term's direction (so synthesized cursors match a future native server cursor).
 * Idempotent when `id` is already the final term; defaults to `id` asc for empty input.
 */
export function appendIdTiebreaker(sort: string): string {
  const terms = parseSort(sort);
  const last = terms[terms.length - 1];
  if (last && last.field === "id") return normalizeSort(terms);
  const dir: SortTerm["dir"] = last ? last.dir : "asc";
  terms.push({ field: "id", dir });
  return normalizeSort(terms);
}

const OP_NEXT = { asc: ">", desc: "<" } as const;
const OP_PREV = { asc: "<", desc: ">" } as const;

/**
 * Build the keyset predicate for a boundary row. Given the EFFECTIVE sort (must already
 * include the id tiebreaker), the ordered boundary sort-key values, and a direction,
 * produce a lexicographic OR-of-AND-chains predicate. Values are escaped via `filterValue`,
 * matching the `filter` template tag exactly.
 *
 *   buildKeysetFilter("created,id", [10, "r5"], "next")
 *     => "(created > 10) || (created = 10 && id > 'r5')"
 */
export function buildKeysetFilter(
  effectiveSort: string,
  values: unknown[],
  dir: "next" | "prev",
): string {
  const terms = parseSort(effectiveSort);
  if (terms.length !== values.length) {
    throw new Error(
      `buildKeysetFilter: ${terms.length} sort terms but ${values.length} boundary values`,
    );
  }
  const opTable = dir === "next" ? OP_NEXT : OP_PREV;
  const clauses: string[] = [];
  for (let i = 0; i < terms.length; i++) {
    const conds: string[] = [];
    // all earlier keys equal...
    for (let j = 0; j < i; j++) {
      conds.push(`${terms[j]!.field} = ${filterValue(values[j])}`);
    }
    // ...and this key strictly past the boundary in its sort direction
    conds.push(`${terms[i]!.field} ${opTable[terms[i]!.dir]} ${filterValue(values[i])}`);
    clauses.push(`(${conds.join(" && ")})`);
  }
  return clauses.join(" || ");
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npm test -- cursor.test`
Expected: PASS (all describe blocks green).

- [ ] **Step 5: Commit**

```bash
git add clients/typescript/src/cursor.ts clients/typescript/test/cursor.test.ts
git commit -m "feat(ts-sdk): cursor token + id-tiebreaker + keyset predicate builder"
```

---

## Task 6: Cursor pagination methods — `getPage` / `iterate` / `getFullList`

**Files:**
- Modify: `clients/typescript/src/collection.ts`
- Test: `clients/typescript/test/cursor-paging.test.ts`

> **Implementation strategy:** client-synthesized over the offset+filter wire. Fetch `limit + 1` rows (page 1, perPage = limit+1) with the user filter AND-ed with the keyset predicate (when a cursor is present). The extra row signals `hasNext`; it is trimmed before returning. `nextCursor` encodes the LAST returned row's sort-key values; `prevCursor` encodes the FIRST. The effective sort always carries the `id` tiebreaker.

- [ ] **Step 1: Write the failing test**

```ts
import { describe, it, expect, vi } from "vitest";
import { createClient } from "../src/index.js";
import { decodeCursor } from "../src/cursor.js";

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

/** Parse the query out of a records URL for assertions. */
function qp(url: string): URLSearchParams {
  return new URL(url).searchParams;
}

describe("cursor pagination", () => {
  it("getPage fetches limit+1, trims the extra, sets hasNext, and round-trips nextCursor", async () => {
    const fetchMock = vi.fn(async (url: string) => {
      const p = qp(url);
      expect(p.get("page")).toBe("1");
      expect(p.get("perPage")).toBe("3"); // limit(2) + 1
      expect(p.get("sort")).toBe("-created,-id"); // id tiebreaker follows last term (desc)
      // 3 rows returned -> there IS a next page
      return jsonResponse({
        page: 1,
        perPage: 3,
        totalItems: 0,
        totalPages: 0,
        items: [
          { id: "r1", created: 30 },
          { id: "r2", created: 20 },
          { id: "r3", created: 10 },
        ],
      });
    }) as unknown as typeof fetch;

    const zb = createClient("http://api.test", { fetch: fetchMock });
    const page = await zb.collection("posts").getPage({ limit: 2, sort: "-created" });

    expect(page.items.map((i) => i.id)).toEqual(["r1", "r2"]); // extra row trimmed
    expect(page.hasNext).toBe(true);
    expect(page.hasPrev).toBe(false);
    expect(page.nextCursor).not.toBeNull();

    // nextCursor encodes the LAST returned row's [created, id] under the effective sort
    const state = decodeCursor(page.nextCursor!, "-created,-id");
    expect(state.values).toEqual([20, "r2"]);
    expect(state.dir).toBe("next");
  });

  it("getPage on the next page applies the keyset predicate AND-ed with the user filter", async () => {
    let seenFilter: string | null = null;
    let call = 0;
    const fetchMock = vi.fn(async (url: string) => {
      call += 1;
      seenFilter = qp(url).get("filter");
      if (call === 1) {
        // page 1: user filter only, return limit+1 rows so a cursor is produced
        return jsonResponse({
          page: 1, perPage: 6, totalItems: 0, totalPages: 0,
          items: [
            { id: "r1", created: 30 }, { id: "r2", created: 20 },
            { id: "r3", created: 10 }, { id: "r4", created: 8 },
            { id: "r5", created: 6 }, { id: "r6", created: 4 },
          ],
        });
      }
      // page 2: short batch -> no further next
      return jsonResponse({
        page: 1, perPage: 6, totalItems: 0, totalPages: 0,
        items: [{ id: "r7", created: 2 }],
      });
    }) as unknown as typeof fetch;

    const zb = createClient("http://api.test", { fetch: fetchMock });
    const first = await zb.collection("posts").getPage({
      limit: 5, sort: "-created", filter: "status = 'published'",
    });
    expect(seenFilter).toBe("status = 'published'");

    const second = await zb.collection("posts").getPage({
      limit: 5, sort: "-created", filter: "status = 'published'", cursor: first.nextCursor!,
    });
    // filter must be (user) && (keyset); boundary row is r5/created=6 (last of trimmed page 1)
    expect(seenFilter).toContain("status = 'published'");
    expect(seenFilter).toContain("&&");
    expect(seenFilter).toMatch(/\(created < 6\)/);
    expect(seenFilter).toContain("id < 'r5'");
    expect(second.hasNext).toBe(false);
    expect(second.hasPrev).toBe(true);
  });

  it("getPage requests the count only when withTotal is set", async () => {
    const fetchMock = vi.fn(async (url: string) => {
      const p = qp(url);
      // withTotal omits skipTotal; otherwise skipTotal=1 is sent
      expect(p.get("skipTotal")).toBeNull();
      return jsonResponse({ page: 1, perPage: 3, totalItems: 42, totalPages: 14, items: [{ id: "a", created: 1 }] });
    }) as unknown as typeof fetch;
    const zb = createClient("http://api.test", { fetch: fetchMock });
    const page = await zb.collection("posts").getPage({ limit: 2, sort: "-created", withTotal: true });
    expect(page.totalItems).toBe(42);
  });

  it("getPage without withTotal sends skipTotal=1", async () => {
    const fetchMock = vi.fn(async (url: string) => {
      expect(qp(url).get("skipTotal")).toBe("1");
      return jsonResponse({ page: 1, perPage: 3, totalItems: 0, totalPages: 0, items: [{ id: "a", created: 1 }] });
    }) as unknown as typeof fetch;
    const zb = createClient("http://api.test", { fetch: fetchMock });
    const page = await zb.collection("posts").getPage({ limit: 2, sort: "-created" });
    expect(page.totalItems).toBeUndefined();
  });

  it("iterate yields every record across batches and stops on a short batch", async () => {
    const batches = [
      [
        { id: "r1", created: 30 },
        { id: "r2", created: 20 },
        { id: "r3", created: 10 }, // sentinel -> hasNext
      ],
      [
        { id: "r3b", created: 9 },
        { id: "r4", created: 5 }, // short -> last batch
      ],
    ];
    let call = 0;
    const fetchMock = vi.fn(async () => {
      const body = batches[call] ?? [];
      call += 1;
      return jsonResponse({ page: 1, perPage: 3, totalItems: 0, totalPages: 0, items: body });
    }) as unknown as typeof fetch;

    const zb = createClient("http://api.test", { fetch: fetchMock });
    const seen: string[] = [];
    for await (const rec of zb.collection("posts").iterate({ sort: "-created", batch: 2 })) {
      seen.push(rec.id as string);
    }
    // batch=2 -> fetch 3 each time; first batch trims sentinel -> r1,r2 ; second -> r3b,r4
    expect(seen).toEqual(["r1", "r2", "r3b", "r4"]);
    expect(call).toBe(2);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npm test -- cursor-paging`
Expected: FAIL — `getPage` is not a function.

- [ ] **Step 3: Add cursor methods to `src/collection.ts`**

Extend the imports at the top of `src/collection.ts`:

```ts
import {
  type CursorPage,
  type CursorState,
  encodeCursor,
  decodeCursor,
  appendIdTiebreaker,
  buildKeysetFilter,
} from "./cursor.js";
import { parseSort } from "./query.js";
```

Add these methods inside the `CollectionService` class body:

```ts
  /**
   * Keyset (cursor) pagination, synthesized client-side over the offset+filter wire.
   * Stable under inserts; cannot random-access page N. The effective sort always carries
   * an `id` tiebreaker whose direction follows the last user-sort term.
   */
  async getPage<T extends Record<string, unknown> = ZbRecord>(opts: {
    cursor?: string;
    limit?: number;
    filter?: string;
    sort?: string;
    expand?: string;
    withTotal?: boolean;
    signal?: AbortSignal;
  } = {}): Promise<CursorPage<T>> {
    const limit = Math.min(Math.max(opts.limit ?? 30, 1), 500);
    const effectiveSort = appendIdTiebreaker(opts.sort ?? "");
    const terms = parseSort(effectiveSort);

    let dir: "next" | "prev" = "next";
    const userFilter = opts.filter ?? "";
    let filterStr = userFilter;

    if (opts.cursor) {
      const state = decodeCursor(opts.cursor, effectiveSort);
      dir = state.dir;
      const keyset = buildKeysetFilter(effectiveSort, state.values, dir);
      filterStr = userFilter ? `(${userFilter}) && (${keyset})` : keyset;
    }

    const res = await this.transport.send<ListResult<T>>(this.recordsBase(), {
      method: "GET",
      query: {
        page: 1,
        perPage: limit + 1,
        filter: filterStr || undefined,
        sort: effectiveSort,
        expand: opts.expand,
        skipTotal: opts.withTotal ? undefined : 1,
      },
      signal: opts.signal,
    });

    let rows = res.items;
    const hasMore = rows.length > limit;
    if (hasMore) rows = rows.slice(0, limit);
    // "prev" pages come back in reverse order; flip to restore forward order
    if (dir === "prev") rows = [...rows].reverse();

    const boundaryValues = (row: T): unknown[] => terms.map((t) => readSortKey(row, t.field));
    const first = rows[0];
    const last = rows[rows.length - 1];

    const nextCursor =
      last !== undefined
        ? encodeCursor({ v: 1, sort: effectiveSort, values: boundaryValues(last), dir: "next" })
        : null;
    const prevCursor =
      first !== undefined
        ? encodeCursor({ v: 1, sort: effectiveSort, values: boundaryValues(first), dir: "prev" })
        : null;

    return {
      items: rows,
      nextCursor: hasMore || dir === "prev" ? nextCursor : null,
      prevCursor: opts.cursor ? prevCursor : null,
      hasNext: dir === "next" ? hasMore : true,
      hasPrev: opts.cursor ? true : false,
      ...(opts.withTotal ? { totalItems: res.totalItems } : {}),
    };
  }

  /** Async-iterate every matching record using the stable cursor engine. */
  async *iterate<T extends Record<string, unknown> = ZbRecord>(opts: {
    filter?: string;
    sort?: string;
    expand?: string;
    batch?: number;
    signal?: AbortSignal;
  } = {}): AsyncIterableIterator<T> {
    let cursor: string | undefined;
    for (;;) {
      const page: CursorPage<T> = await this.getPage<T>({
        cursor,
        limit: opts.batch ?? 100,
        filter: opts.filter,
        sort: opts.sort,
        expand: opts.expand,
        signal: opts.signal,
      });
      for (const item of page.items) yield item;
      if (!page.hasNext || !page.nextCursor) return;
      cursor = page.nextCursor;
    }
  }

  /** Stable full read, re-backed by the keyset engine (safe even while rows are inserted). */
  async getFullList<T extends Record<string, unknown> = ZbRecord>(opts: {
    filter?: string;
    sort?: string;
    expand?: string;
    batch?: number;
    signal?: AbortSignal;
  } = {}): Promise<T[]> {
    const out: T[] = [];
    for await (const item of this.iterate<T>(opts)) out.push(item);
    return out;
  }
```

Add this module-private helper near the bottom of `src/collection.ts` (outside the class):

```ts
/** Read a (possibly dotted) sort key off a record for cursor boundary encoding. */
function readSortKey(row: Record<string, unknown>, path: string): unknown {
  if (!path.includes(".")) return row[path];
  let cur: unknown = row;
  for (const seg of path.split(".")) {
    if (cur === null || cur === undefined || typeof cur !== "object") return undefined;
    cur = (cur as Record<string, unknown>)[seg];
  }
  return cur;
}
```

> **Note on `CursorState` typing:** `encodeCursor` takes a `CursorState` whose `v` is the literal `1`; the object literals above set `v: 1`, which TypeScript widens to `number` only if inferred separately. Passing the literal inline (as written) satisfies the `v: 1` field. If strict inference complains, annotate: `encodeCursor({ v: 1, ... } satisfies CursorState)`.

- [ ] **Step 4: Run test to verify it passes**

Run: `npm test -- cursor-paging`
Expected: PASS (5 tests).

- [ ] **Step 5: Run the full unit suite to confirm no regressions**

Run: `npm test`
Expected: all unit tests PASS.

- [ ] **Step 6: Commit**

```bash
git add clients/typescript/src/collection.ts clients/typescript/test/cursor-paging.test.ts
git commit -m "feat(ts-sdk): cursor getPage/iterate/getFullList on CollectionService"
```

---

## Task 7: Files service (`src/files.ts`)

**Files:**
- Create: `clients/typescript/src/files.ts`
- Modify: `clients/typescript/src/client.ts` (lazy `files` getter)
- Test: `clients/typescript/test/files.test.ts`

- [ ] **Step 1: Write the failing test**

```ts
import { describe, it, expect, vi } from "vitest";
import { FilesService } from "../src/files.js";
import { createClient } from "../src/index.js";
import { Transport } from "../src/transport.js";
import { MemoryAuthStore } from "../src/auth-store.js";

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function makeFiles(fetchImpl?: typeof fetch): FilesService {
  const transport = new Transport({
    baseUrl: "http://api.test",
    authStore: new MemoryAuthStore(),
    fetch: (fetchImpl ?? (async () => new Response())) as unknown as typeof fetch,
    autoRefresh: false,
    maxRetries: 0,
    sleep: async () => {},
  });
  return new FilesService(transport, "http://api.test");
}

describe("FilesService.getUrl", () => {
  it("builds a file URL from a record object + filename", () => {
    const files = makeFiles();
    const url = files.getUrl({ id: "rec1", collectionName: "posts" }, "photo.png");
    expect(url).toBe("http://api.test/api/files/posts/rec1/photo.png");
  });

  it("prefers collectionId when present", () => {
    const files = makeFiles();
    const url = files.getUrl({ id: "rec1", collectionId: "col_abc", collectionName: "posts" }, "p.png");
    expect(url).toBe("http://api.test/api/files/col_abc/rec1/p.png");
  });

  it("accepts explicit string ids", () => {
    const files = makeFiles();
    const url = files.getUrl("posts", "rec1", "p.png"); // overloaded form
    expect(url).toBe("http://api.test/api/files/posts/rec1/p.png");
  });

  it("adds download, thumb, and token query params", () => {
    const files = makeFiles();
    const url = files.getUrl({ id: "r", collectionName: "posts" }, "p.png", {
      download: true,
      thumb: "100x100",
      token: "tok123",
    });
    const u = new URL(url);
    expect(u.pathname).toBe("/api/files/posts/r/p.png");
    expect(u.searchParams.get("download")).toBe("1");
    expect(u.searchParams.get("thumb")).toBe("100x100");
    expect(u.searchParams.get("token")).toBe("tok123");
  });

  it("URL-encodes the filename", () => {
    const files = makeFiles();
    const url = files.getUrl({ id: "r", collectionName: "posts" }, "a b.png");
    expect(url).toBe("http://api.test/api/files/posts/r/a%20b.png");
  });
});

describe("FilesService.getToken", () => {
  it("POSTs /api/files/token and returns the token", async () => {
    const fetchMock = vi.fn(async (url: string, init: RequestInit) => {
      expect(url).toBe("http://api.test/api/files/token");
      expect(init.method).toBe("POST");
      return jsonResponse({ token: "file-tok" });
    }) as unknown as typeof fetch;
    const files = makeFiles(fetchMock);
    expect(await files.getToken()).toBe("file-tok");
  });
});

describe("client.files", () => {
  it("is exposed as a lazy getter on the client", () => {
    const zb = createClient("http://api.test", {
      fetch: (async () => new Response()) as unknown as typeof fetch,
    });
    expect(zb.files).toBeInstanceOf(FilesService);
    expect(zb.files).toBe(zb.files); // memoized
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npm test -- files.test`
Expected: FAIL — cannot find `../src/files.js`.

- [ ] **Step 3: Implement `src/files.ts`**

```ts
import type { Transport } from "./transport.js";

/** Minimal record shape `getUrl` can derive a collection + id from. */
export interface FileRecordRef {
  id: string;
  collectionId?: string;
  collectionName?: string;
}

export interface FileUrlOptions {
  download?: boolean;
  token?: string;
  thumb?: string;
}

export class FilesService {
  constructor(
    private readonly transport: Transport,
    private readonly baseUrl: string,
  ) {}

  /**
   * Build a file URL. Either pass a record object + filename, or explicit
   * (collectionIdOrName, recordId, filename). Optional query params: download/token/thumb.
   *
   *   files.getUrl(record, "photo.png", { thumb: "100x100" })
   *   files.getUrl("posts", "rec1", "photo.png")
   */
  getUrl(record: FileRecordRef, filename: string, opts?: FileUrlOptions): string;
  getUrl(collectionIdOrName: string, recordId: string, filename: string, opts?: FileUrlOptions): string;
  getUrl(
    a: FileRecordRef | string,
    b: string,
    c?: string | FileUrlOptions,
    d?: FileUrlOptions,
  ): string {
    let col: string;
    let rec: string;
    let filename: string;
    let opts: FileUrlOptions | undefined;

    if (typeof a === "string") {
      col = a;
      rec = b;
      filename = c as string;
      opts = d;
    } else {
      col = a.collectionId ?? a.collectionName ?? "";
      rec = a.id;
      filename = b;
      opts = c as FileUrlOptions | undefined;
    }

    const base = this.baseUrl.replace(/\/+$/, "");
    let url =
      `${base}/api/files/${encodeURIComponent(col)}/${encodeURIComponent(rec)}/` +
      encodeURIComponent(filename);

    const params = new URLSearchParams();
    if (opts?.download) params.set("download", "1");
    if (opts?.thumb) params.set("thumb", opts.thumb);
    if (opts?.token) params.set("token", opts.token);
    const qs = params.toString();
    if (qs) url += `?${qs}`;
    return url;
  }

  /** Mint a short-lived file-access token for embedding protected files. */
  async getToken(): Promise<string> {
    const res = await this.transport.send<{ token: string }>("/api/files/token", {
      method: "POST",
    });
    return res.token;
  }
}
```

- [ ] **Step 4: Wire the lazy `files` getter into `src/client.ts`**

Add the import:

```ts
import { FilesService } from "./files.js";
```

Add `files` to the `Client` interface:

```ts
export interface Client {
  readonly baseUrl: string;
  readonly authStore: AuthStore;
  readonly files: FilesService;
  collection(name: string): CollectionService;
  send<T>(method: string, path: string, opts?: { query?: Record<string, string | number | boolean | undefined>; body?: unknown; headers?: Record<string, string>; signal?: AbortSignal }): Promise<T>;
}
```

In `createClient`, memoize the service and expose it via a getter on the returned object:

```ts
  let filesService: FilesService | undefined;

  return {
    baseUrl: normalizedBase,
    authStore,
    get files() {
      return (filesService ??= new FilesService(transport, normalizedBase));
    },
    collection(name: string) {
      return new CollectionService(transport, authStore, name);
    },
    send<T>(method, path, sendOpts) {
      return transport.send<T>(path, { method, ...sendOpts });
    },
  };
```

> **Note:** if Plan 1 returned a plain object literal without a getter, converting `files` to a getter is the only change needed; `baseUrl`, `authStore`, `collection`, and `send` stay identical. The `transport` reference is already in scope from Plan 1's `createClient` body.

- [ ] **Step 5: Run test to verify it passes**

Run: `npm test -- files.test`
Expected: PASS (8 tests).

- [ ] **Step 6: Commit**

```bash
git add clients/typescript/src/files.ts clients/typescript/src/client.ts clients/typescript/test/files.test.ts
git commit -m "feat(ts-sdk): FilesService (getUrl/getToken) + lazy client.files"
```

---

## Task 8: Public re-exports (`src/index.ts`)

**Files:**
- Modify: `clients/typescript/src/index.ts`
- Test: `clients/typescript/test/exports.test.ts`

- [ ] **Step 1: Write the failing test**

```ts
import { describe, it, expect } from "vitest";
import * as zb from "../src/index.js";

describe("public exports (Plan 2)", () => {
  it("re-exports the query helpers", () => {
    expect(typeof zb.filter).toBe("function");
    expect(typeof zb.parseSort).toBe("function");
    expect(typeof zb.compareBySort).toBe("function");
  });

  it("re-exports the cursor helpers", () => {
    expect(typeof zb.encodeCursor).toBe("function");
    expect(typeof zb.decodeCursor).toBe("function");
  });

  it("re-exports FilesService", () => {
    expect(typeof zb.FilesService).toBe("function");
  });

  it("re-exports record/multipart helpers", () => {
    expect(typeof zb.hasBlob).toBe("function");
    expect(typeof zb.toFormData).toBe("function");
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npm test -- exports.test`
Expected: FAIL — `filter`/`FilesService`/etc. not exported.

- [ ] **Step 3: Append Plan 2 re-exports to `src/index.ts`**

Add to the existing `src/index.ts` (below the Plan 1 exports):

```ts
// --- Plan 2: records, pagination, files ---
export { hasBlob, toFormData } from "./records.js";
export type { ZbRecord, ListResult, ListOpts, RecordCrudOpts } from "./records.js";
export { filter, filterValue, parseSort, compareBySort } from "./query.js";
export type { SortTerm } from "./query.js";
export {
  encodeCursor,
  decodeCursor,
  appendIdTiebreaker,
  buildKeysetFilter,
} from "./cursor.js";
export type { CursorPage, CursorState } from "./cursor.js";
export { FilesService } from "./files.js";
export type { FileRecordRef, FileUrlOptions } from "./files.js";
```

- [ ] **Step 4: Run test + typecheck**

Run: `npm test -- exports.test && npm run typecheck`
Expected: PASS (4 tests); typecheck clean.

- [ ] **Step 5: Commit**

```bash
git add clients/typescript/src/index.ts clients/typescript/test/exports.test.ts
git commit -m "feat(ts-sdk): re-export records/query/cursor/files from index"
```

---

## Task 9: Integration — records, cursor, multipart, files (live binary)

**Files:**
- Create: `clients/typescript/test/integration/records.integration.test.ts`

> Reuses the Plan 1 harness (`startServer`, `superuserToken`, `createCollection`). Seeds a public `posts`-like base collection so the client can read/write without auth. **The exact collection-definition JSON (field types, rule keys) must be confirmed at execution time against `src/api/collections.zig` and `src/schema.zig`; the test *contract* (create → read → paginate → upload → update → delete) stays stable.**

- [ ] **Step 1: Write the integration test**

```ts
import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { startServer, superuserToken, createCollection, type TestServer } from "./harness.js";
import { createClient } from "../../src/index.js";

let server: TestServer;

beforeAll(async () => {
  server = await startServer();
  const token = await superuserToken(server);
  // NOTE: confirm field/rule keys against src/api/collections.zig / src/schema.zig at execution time.
  await createCollection(server, token, {
    name: "posts",
    type: "base",
    fields: [
      { name: "title", type: "text", required: true },
      { name: "views", type: "number" },
      { name: "cover", type: "file", maxSelect: 1 },
    ],
    listRule: "",
    viewRule: "",
    createRule: "",
    updateRule: "",
    deleteRule: "",
  });
});

afterAll(() => server?.stop());

describe("records (live backend)", () => {
  it("creates, reads, paginates, cursors, uploads, updates, and deletes", async () => {
    const zb = createClient(server.url);
    const posts = zb.collection("posts");

    // --- create (JSON) a handful of records with distinct sort keys ---
    const created: string[] = [];
    for (let i = 0; i < 5; i++) {
      const rec = await posts.create({ title: `Post ${i}`, views: i });
      expect(rec.id).toBeTruthy();
      created.push(rec.id as string);
    }

    // --- getOne ---
    const one = await posts.getOne(created[0]!);
    expect(one.title).toBe("Post 0");

    // --- getList with filter + sort ---
    const list = await posts.getList(1, 30, { filter: "views >= 2", sort: "-views" });
    expect(list.items.length).toBe(3);
    expect((list.items[0] as { views: number }).views).toBe(4); // desc

    // --- offset pagination across 2 pages ---
    const p1 = await posts.getList(1, 2, { sort: "views" });
    const p2 = await posts.getList(2, 2, { sort: "views" });
    expect(p1.items.length).toBe(2);
    expect(p2.items.length).toBe(2);
    expect(p1.totalItems).toBe(5);

    // --- cursor getPage forward across 2 pages ---
    const c1 = await posts.getPage({ limit: 2, sort: "views" });
    expect(c1.items.length).toBe(2);
    expect(c1.hasNext).toBe(true);
    const c2 = await posts.getPage({ limit: 2, sort: "views", cursor: c1.nextCursor! });
    expect(c2.items.length).toBe(2);
    // forward progress: no overlap with page 1
    const p1ids = new Set(c1.items.map((i) => i.id));
    for (const rec of c2.items) expect(p1ids.has(rec.id)).toBe(false);

    // --- iterate counts every record ---
    let count = 0;
    for await (const _ of posts.iterate({ sort: "views", batch: 2 })) count += 1;
    expect(count).toBe(5);

    // --- multipart create with a small Blob, then files.getUrl GETs 200 ---
    const blob = new Blob(["hello-file"], { type: "text/plain" });
    const withFile = await posts.create({ title: "With cover", cover: blob });
    const coverName = (withFile as { cover?: string }).cover;
    expect(coverName).toBeTruthy();
    const fileUrl = zb.files.getUrl(
      { id: withFile.id as string, collectionName: "posts" },
      coverName as string,
    );
    const fileRes = await fetch(fileUrl);
    expect(fileRes.status).toBe(200);
    expect(await fileRes.text()).toBe("hello-file");

    // --- update ---
    const updated = await posts.update(created[0]!, { title: "Renamed" });
    expect(updated.title).toBe("Renamed");

    // --- delete ---
    await posts.delete(created[0]!);
    await expect(posts.getOne(created[0]!)).rejects.toMatchObject({ status: 404 });
  });
});
```

- [ ] **Step 2: Run the integration test**

Run: `npm run test:integration -- records`
Expected: PASS (1 test) against a freshly built+launched `zigbase`. If the collection-definition keys differ from the seed above, adjust them per `src/api/collections.zig`/`src/schema.zig` while keeping every assertion intact.

- [ ] **Step 3: Commit**

```bash
git add clients/typescript/test/integration/records.integration.test.ts
git commit -m "test(ts-sdk): integration — records/cursor/multipart/files round-trip"
```

---

## Task 10: README — records, cursor, and file examples

**Files:**
- Modify: `clients/typescript/README.md`

> Doc-sync note: the package README is updated here. The full user-facing docs (`docs/typescript-sdk.md` + its `site/src/content/` mirror + the top-level `README.md` pointer) land in **Plan 3's** final docs task, once realtime completes the SP1 surface. Do NOT skip the README update — keep published examples runnable.

- [ ] **Step 1: Replace the "Records, pagination..." placeholder paragraph in `clients/typescript/README.md`**

Replace the trailing line from Plan 1:

```markdown
Records, pagination, file uploads, and realtime arrive in subsequent releases
(see the SDK plans under `docs/superpowers/plans/`).
```

with:

````markdown
## Records & CRUD

```ts
const posts = zb.collection("posts");

const list = await posts.getList(1, 30, {
  filter: "status = 'published'",
  sort: "-created,title",
  expand: "author,tags",
});

const post = await posts.getOne("REC_ID", { expand: "author" });
const first = await posts.getFirstListItem("slug = 'hello'"); // throws 404 if none
const created = await posts.create({ title: "Hi", views: 0 });
const updated = await posts.update(created.id, { title: "Edited" });
await posts.delete(created.id);
```

### Safe filters

Use the `filter` template tag to interpolate user input without injection risk —
strings are single-quoted and escaped, numbers/booleans inline, `Date` -> ISO:

```ts
import { filter } from "@zigbase/client";

const q = userInput; // even "' || 1=1 --" is safely quoted
await posts.getList(1, 30, {
  filter: filter`status = ${"published"} && author.name ~ ${q}`,
});
```

## Cursor (keyset) pagination

Stable under inserts, no deep-offset cost — ideal for feeds and infinite scroll.
The SDK auto-appends an `id` tiebreaker (its direction follows your last sort term),
so the order is always deterministic. Cursors are opaque base64url tokens.

```ts
let page = await posts.getPage({ limit: 20, sort: "-created" });
render(page.items);
while (page.hasNext) {
  page = await posts.getPage({ limit: 20, sort: "-created", cursor: page.nextCursor! });
  render(page.items);
}

// Or iterate everything (stable even while rows are inserted mid-iteration):
for await (const post of posts.iterate({ sort: "-created" })) {
  handle(post);
}
const all = await posts.getFullList({ filter: "status = 'published'" });
```

> Cursor pagination is currently synthesized client-side over the offset+filter API.
> The public surface is shaped so a future native server cursor can replace the
> synthesis without any code change on your side.

## File uploads & URLs

A `create`/`update` body containing a `File`/`Blob` (or an array of them) is sent as
multipart automatically — no special method:

```ts
const rec = await posts.create({ title: "Hi", cover: fileInput.files[0] });

// Build a URL to the stored file:
const url = zb.files.getUrl(rec, rec.cover as string, { thumb: "100x100" });

// Protected files: mint a short-lived access token for <img src> / emails:
const token = await zb.files.getToken();
const protectedUrl = zb.files.getUrl(rec, rec.cover as string, { token });
```
````

- [ ] **Step 2: Verify the README renders and the package still builds**

Run: `npm run typecheck && npm run build`
Expected: typecheck clean; `dist/` produced.

- [ ] **Step 3: Commit**

```bash
git add clients/typescript/README.md
git commit -m "docs(ts-sdk): README records + cursor + file examples"
```

---

## Self-Review notes

### Spec-coverage checklist (every Records/Files spec bullet → a task)

| Spec bullet (Records & pagination / Files) | Task |
| --- | --- |
| `getList(page, perPage, opts)` → `ListResult<T>`, perPage clamp to 500 | Task 4 |
| `getOne(id, { expand })` | Task 4 |
| `getFirstListItem(filter, opts)` (getList(1,1) sugar) | Task 4 |
| `create(body, { expand })` → 201, multipart auto-detected | Tasks 1 + 4 |
| `update(id, body, opts)` | Task 4 |
| `delete(id)` → 204 void | Task 4 |
| `ListOpts` / `ListResult<T>` types; default `ZbRecord` | Task 1 |
| Multipart auto-build when body contains File/Blob (incl. arrays) | Task 1 (`hasBlob`/`toFormData`) + Task 4 |
| Safe `filter` template tag (escape against grammar; injection-proof) | Task 2 |
| Sort comparator engine shared with cursors + live store | Task 3 (`parseSort`/`compareBySort`) |
| `getPage(opts)` → `CursorPage<T>` (cursor/limit/filter/sort/expand/withTotal) | Task 6 |
| `iterate(opts)` AsyncIterable | Task 6 |
| Opaque base64 cursor token (sort-key values + direction) | Task 5 (`encodeCursor`/`decodeCursor`) |
| Keyset predicate appended to user filter | Task 5 (`buildKeysetFilter`) + Task 6 (merge) |
| Auto-append `id` tiebreaker; **id dir follows last user sort term** | Task 5 (`appendIdTiebreaker`) |
| `withTotal` opts back into `totalItems` | Task 6 |
| `getFullList` re-backed by keyset engine (stable under inserts) | Task 6 |
| Forward-compatible with a future native server cursor | Tasks 5–6 (documented; surface unchanged) |
| `files.getUrl(record\|ids, filename, { download, token, thumb })` | Task 7 |
| `files.getToken()` → `POST /api/files/token` | Task 7 |
| `zb.files` lazy accessor on the client | Task 7 |
| Integration: real-binary CRUD + offset + cursor + multipart + file GET | Task 9 |
| Docs/index sync (re-exports + README) | Tasks 8 + 10 |

### Placeholder scan

- No `TODO`, no "similar to above", no "...": every implementation step contains complete, runnable TypeScript.
- One inline **execution-time confirmation** is explicitly flagged (contract unchanged): the live `posts` collection-definition JSON in Task 9 (confirm field/rule keys against `src/api/collections.zig`/`src/schema.zig`).
- One TypeScript-strictness escape hatch is noted in Task 6 (`satisfies CursorState`) in case literal-`1` inference for `CursorState.v` complains; the load-bearing code is unchanged.

### Type-consistency (must match what Plan 3 imports)

- `ListResult<T> { page; perPage; totalItems; totalPages; items: T[] }` — defined once in `src/records.ts`, imported by `collection.ts`. Plan 3's live list returns the same shape.
- `CursorPage<T> { items; nextCursor; prevCursor; hasNext; hasPrev; totalItems? }` — defined once in `src/cursor.ts`. Plan 3's live `getPage` returns the same shape.
- `SortTerm { field: string; dir: 'asc' | 'desc' }` and `compareBySort(a: Record<string, unknown>, b: Record<string, unknown>, terms: SortTerm[]): number` — exact signatures Plan 3 imports to order live lists. **Do not change.**
- `ZbRecord = { id: string; [k: string]: unknown }` — the permissive default record type SP2 substitutes real types for.
- Record/cursor methods live on `CollectionService` (single object carries auth + records), so `zb.realtime.collection(name)` in Plan 3 can mirror the same method names over a live cache.
