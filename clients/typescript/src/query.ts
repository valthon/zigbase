/**
 * Quote a string as a ZigBase filter literal.
 *
 * The server lexer (src/query/lexer.zig) unescapes backslash sequences inside a
 * quoted string: `\\`->`\`, `\'`->`'`, `\"`->`"`, `\n`->newline, `\t`->tab,
 * `\r`->CR. We therefore ALWAYS single-quote and escape the bytes that would
 * otherwise terminate or corrupt the literal: backslash, single quote, and the
 * three control chars. Every other byte (including a double quote) is left
 * literal. Because the closing single quote can only appear escaped, the literal
 * can never be broken out of — this is the injection-safety property, and any
 * value is now representable (no both-quotes limitation).
 */
function quoteString(s: string): string {
  const escaped = s
    .replace(/\\/g, "\\\\")
    .replace(/'/g, "\\'")
    .replace(/\n/g, "\\n")
    .replace(/\t/g, "\\t")
    .replace(/\r/g, "\\r");
  return `'${escaped}'`;
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
 * Serialize a single value into a safe ZigBase filter operand. Alias of
 * `filterValue`, named for use by the typed core (`@zigbase/client/typed`):
 * strings/Dates are single-quoted + escaped (injection-safe), numbers/booleans
 * pass bare, and array/object operands are rejected (callers expand `in` lists
 * into `||` chains themselves).
 */
export function quoteFilterValue(value: unknown): string {
  return filterValue(value);
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
