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
 * Idempotent when `id` already appears ANYWHERE in the sort — since `id` is unique, any
 * such sort is already deterministic. Defaults to `id` asc for empty input.
 */
export function appendIdTiebreaker(sort: string): string {
  const terms = parseSort(sort);
  if (terms.some((t) => t.field === "id")) return normalizeSort(terms);
  const last = terms[terms.length - 1];
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
