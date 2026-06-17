import { quoteFilterValue } from "../query.js";
import type { CollectionMeta } from "./meta.js";
import { fieldMeta } from "./meta.js";

/** Operator-key → SP1 filter comparator. Shared with the fluent builder. */
export const OP_MAP = {
  eq: "=",
  neq: "!=",
  gt: ">",
  gte: ">=",
  lt: "<",
  lte: "<=",
  like: "~",
  nlike: "!~",
} as const;

export type OpKey = keyof typeof OP_MAP;

const OP_KEYS = new Set<string>(Object.keys(OP_MAP));

/**
 * Resolve the target collection's meta for a nested relation `where`. The
 * generator supplies one of these closures so the compiler can recurse one level
 * into a related collection. Returning `undefined` disables nested expansion for
 * that field (its value is then treated as a relation-id scalar/operator).
 */
export type RelationResolver = (
  collection: string,
  field: string,
) => CollectionMeta | undefined;

const noRelations: RelationResolver = () => undefined;

function isPlainObject(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v) && !(v instanceof Date);
}

/** Build `(f = a || f = b || …)`; empty list is the always-false sentinel `1 = 2`. */
export function compileIn(field: string, values: unknown[]): string {
  if (values.length === 0) return "1 = 2";
  const parts = values.map((v) => `${field} = ${quoteFilterValue(v)}`);
  return parts.length === 1 ? (parts[0] as string) : `(${parts.join(" || ")})`;
}

/** Join compiled clauses with a boolean op, parenthesizing when more than one. */
function joinClauses(clauses: string[], op: "&&" | "||"): string {
  const nonEmpty = clauses.filter((c) => c.length > 0);
  if (nonEmpty.length === 0) return "";
  if (nonEmpty.length === 1) return nonEmpty[0] as string;
  return `(${nonEmpty.join(` ${op} `)})`;
}

/** Compile one `{ op: value, … }` operator object for a (possibly dotted) field. */
function compileOps(field: string, ops: Record<string, unknown>): string {
  const clauses: string[] = [];
  for (const [key, value] of Object.entries(ops)) {
    if (value === undefined) continue;
    if (key === "in") {
      if (!Array.isArray(value)) throw new Error(`compileWhere: \`in\` on ${field} must be an array`);
      clauses.push(compileIn(field, value));
    } else if (key in OP_MAP) {
      const cmp = OP_MAP[key as OpKey];
      clauses.push(`${field} ${cmp} ${quoteFilterValue(value)}`);
    } else {
      throw new Error(`compileWhere: unknown operator \`${key}\` on field ${field}`);
    }
  }
  return joinClauses(clauses, "&&");
}

/** True when an object's keys are all known operator keys (vs. nested field names). */
function looksLikeOps(obj: Record<string, unknown>): boolean {
  const keys = Object.keys(obj);
  return keys.length > 0 && keys.every((k) => OP_KEYS.has(k) || k === "in");
}

function compileNode(
  where: Record<string, unknown>,
  meta: CollectionMeta,
  resolve: RelationResolver,
  prefix: string,
  depth: number,
): string {
  const clauses: string[] = [];

  for (const [key, value] of Object.entries(where)) {
    if (value === undefined) continue;

    if (key === "AND" || key === "OR") {
      if (!Array.isArray(value)) throw new Error(`compileWhere: ${key} must be an array`);
      const sub = value.map((w) =>
        compileNode(w as Record<string, unknown>, meta, resolve, prefix, depth),
      );
      clauses.push(joinClauses(sub, key === "AND" ? "&&" : "||"));
      continue;
    }

    const dotted = prefix ? `${prefix}.${key}` : key;
    const fm = fieldMeta(meta, key);

    // Nested relation `where`: a plain object on a relation field whose keys are
    // NOT operator keys, and we still have depth budget + a resolvable target.
    if (
      fm?.type === "relation" &&
      depth > 0 &&
      isPlainObject(value) &&
      !looksLikeOps(value)
    ) {
      const target = resolve(meta.name, key);
      if (target) {
        clauses.push(compileNode(value, target, resolve, dotted, depth - 1));
        continue;
      }
      // No target meta -> fall through and treat as id operators below.
    }

    if (isPlainObject(value)) {
      clauses.push(compileOps(dotted, value));
    } else {
      // Scalar shorthand -> equality (relations compare the id, which is the value).
      clauses.push(`${dotted} = ${quoteFilterValue(value)}`);
    }
  }

  return joinClauses(clauses, "&&");
}

/**
 * Compile a `where` object to an SP1 filter string.
 *
 * - scalar shorthand: `{ status: 'published' }` -> `status = 'published'`
 * - operator objects: `{ price: { gte: 10 } }` -> `price >= 10`
 * - relation-by-id: `{ author: 'u1' }` -> `author = 'u1'`
 * - `in`: `{ status: { in: ['a','b'] } }` -> `(status = 'a' || status = 'b')`
 * - AND/OR arrays of sub-wheres
 * - ONE level of nested relation where: `{ author: { name: { like: 'A' } } }`
 *   -> `author.name ~ 'A'` (cycle-guarded by the `depth` budget; default 1)
 *
 * `resolve` maps `(collection, field)` to the related collection's meta so a
 * nested relation can recurse; omit it (or return `undefined`) to disable
 * nesting. Returns `""` for an empty/absent `where` (caller omits `filter`).
 */
export function compileWhere(
  where: unknown,
  meta: CollectionMeta,
  resolve: RelationResolver = noRelations,
  maxDepth = 1,
): string {
  if (!isPlainObject(where)) return "";
  return compileNode(where, meta, resolve, "", maxDepth);
}
