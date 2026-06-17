// @zigbase/client/typed — the hand-written generic typed core that a generated
// zbase.gen.ts instantiates. All intricate type-level machinery lives here; the
// generator emits a thin declarative layer that instantiates it.
export const TYPED_CORE_VERSION = "0.1.0";

// The one expand-narrowing generic.
export type { WithExpand } from "./expand.js";

// Operator-object types referenced by generated `*Where` types.
export type {
  StringOps,
  NumberOps,
  BoolOps,
  DateOps,
  EnumOps,
  RelOps,
} from "./operators.js";

// Runtime field metadata.
export type { FieldType, FieldMeta, CollectionMeta } from "./meta.js";
export { fieldMeta } from "./meta.js";

// where-DSL compiler + fluent builder.
export { compileWhere, compileIn, OP_MAP } from "./where.js";
export type { RelationResolver, OpKey } from "./where.js";
export { makeFilterBuilder, Expr, FieldExpr } from "./fluent.js";
export type { FilterRoot, TypedFieldExpr } from "./fluent.js";

// Typed runtime factories (narrowed by the generated file).
export { makeRecordService } from "./service.js";
export type {
  RawTypedService,
  TypedListOptions,
  TypedReadOptions,
  TypedPageOptions,
} from "./service.js";
export { makeTypedRealtime } from "./realtime.js";
export type {
  RawTypedRealtime,
  TypedSubscribeOptions,
  TypedLiveListOptions,
} from "./realtime.js";
export { makeTypedFiles } from "./files.js";
export type { RawTypedFiles } from "./files.js";
