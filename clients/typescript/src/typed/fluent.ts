import { quoteFilterValue } from "../query.js";
import { OP_MAP, type OpKey, compileIn } from "./where.js";
import type { CollectionMeta } from "./meta.js";
import { fieldMeta } from "./meta.js";

/**
 * A compiled boolean expression. Combine with `.and`/`.or` (each wraps the
 * result in parentheses to make precedence explicit), and materialize with
 * `.toString()` / `.compile()` to an SP1 filter string.
 */
export class Expr {
  constructor(private readonly src: string) {}

  and(other: Expr): Expr {
    return new Expr(`(${this.src} && ${other.src})`);
  }

  or(other: Expr): Expr {
    return new Expr(`(${this.src} || ${other.src})`);
  }

  compile(): string {
    return this.src;
  }

  toString(): string {
    return this.src;
  }
}

/** Per-field accessor exposing the operator methods. */
export class FieldExpr {
  constructor(private readonly field: string) {}

  private op(key: OpKey, value: unknown): Expr {
    return new Expr(`${this.field} ${OP_MAP[key]} ${quoteFilterValue(value)}`);
  }

  eq(value: unknown): Expr {
    return this.op("eq", value);
  }
  neq(value: unknown): Expr {
    return this.op("neq", value);
  }
  gt(value: unknown): Expr {
    return this.op("gt", value);
  }
  gte(value: unknown): Expr {
    return this.op("gte", value);
  }
  lt(value: unknown): Expr {
    return this.op("lt", value);
  }
  lte(value: unknown): Expr {
    return this.op("lte", value);
  }
  like(value: unknown): Expr {
    return this.op("like", value);
  }
  nlike(value: unknown): Expr {
    return this.op("nlike", value);
  }
  in(values: unknown[]): Expr {
    return new Expr(compileIn(this.field, values));
  }
}

/**
 * A typed view over `FieldExpr` that constrains operator operands to the field's
 * value type `V`. The generated file uses this (instead of the loose `FieldExpr`)
 * for each field in the `*Fields` accessor types, so `f.status.eq('bad')` errors
 * at the call site while the runtime `FieldExpr` instance still backs it
 * structurally (the `as unknown as PostFields` cast in the fixture is sound).
 *
 * `like`/`nlike` additionally require `V & string` (i.e. the field's type must
 * be or overlap `string`).
 */
export interface TypedFieldExpr<V> {
  eq(value: V): Expr;
  neq(value: V): Expr;
  gt(value: V): Expr;
  gte(value: V): Expr;
  lt(value: V): Expr;
  lte(value: V): Expr;
  like(value: V & string): Expr;
  nlike(value: V & string): Expr;
  in(values: V[]): Expr;
}

/**
 * The fluent root. At runtime it is a `Proxy` that returns a `FieldExpr` for any
 * known field name (throwing on unknown fields). The generated file casts this
 * to a CONCRETE accessor type so the consumer sees only that collection's
 * fields, each typed to accept the right operand type.
 */
export type FilterRoot = Record<string, FieldExpr>;

export function makeFilterBuilder(meta: CollectionMeta): FilterRoot {
  return new Proxy({} as FilterRoot, {
    get(_target, prop): FieldExpr {
      if (typeof prop !== "string") {
        throw new Error(`filter builder: non-string field access`);
      }
      if (!fieldMeta(meta, prop)) {
        throw new Error(`filter builder: unknown field "${prop}" on ${meta.name}`);
      }
      return new FieldExpr(prop);
    },
  });
}
