/**
 * Operator-object shapes referenced by generated `*Where` types. Every key is
 * optional; a `where` field accepts either a scalar shorthand (`status: 'x'`) or
 * one of these operator objects (`price: { gte: 10 }`). The runtime compiler
 * (`compileWhere`) and the fluent builder share the same operator → filter
 * mapping; these types only constrain what the consumer may write.
 */

/** String fields: `text`, `email`, `url`, `editor`. */
export interface StringOps {
  eq?: string;
  neq?: string;
  like?: string;
  nlike?: string;
  in?: string[];
}

/** Numeric fields: `number`. */
export interface NumberOps {
  eq?: number;
  neq?: number;
  gt?: number;
  gte?: number;
  lt?: number;
  lte?: number;
  in?: number[];
}

/** Boolean fields: `bool`. */
export interface BoolOps {
  eq?: boolean;
  neq?: boolean;
}

/** Date / autodate fields (ISO-8601 strings or `Date`). */
export interface DateOps {
  eq?: string | Date;
  neq?: string | Date;
  gt?: string | Date;
  gte?: string | Date;
  lt?: string | Date;
  lte?: string | Date;
  in?: (string | Date)[];
}

/** Single-select fields. `T` is the value union (e.g. `'draft' | 'published'`). */
export interface EnumOps<T extends string> {
  eq?: T;
  neq?: T;
  in?: T[];
}

/** Relation fields: operate on the related record id(s). */
export interface RelOps {
  eq?: string;
  neq?: string;
  in?: string[];
}
