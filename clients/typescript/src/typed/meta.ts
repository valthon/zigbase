/** Field kinds the generator emits metadata for (mirrors the spec's field table). */
export type FieldType =
  | "text"
  | "editor"
  | "email"
  | "url"
  | "number"
  | "bool"
  | "date"
  | "autodate"
  | "select"
  | "relation"
  | "file"
  | "json";

/** Per-field runtime metadata. `multi` marks `maxSelect > 1` (select/relation/file).
 *  `mode`/`scale` carry int/fixed number-mode so writes can be coerced to the
 *  decimal-string wire form the server requires (float fields omit `mode`). */
export interface FieldMeta {
  type: FieldType;
  multi?: boolean;
  mode?: "int" | "fixed";
  scale?: number;
}

/**
 * Per-collection runtime descriptor baked by the generator. The typed-core
 * factories read this to compile `where`/fluent filters, validate file fields,
 * whitelist `expand` keys, and derive the realtime topic. `name` is the
 * collection name (also the realtime topic and the SP1 `client.collection(name)`
 * key). `isAuth` marks auth collections.
 */
export interface CollectionMeta {
  name: string;
  fields: Record<string, FieldMeta>;
  fileFields: string[];
  expandable: string[];
  isAuth: boolean;
}

/** Safe field lookup honoring `noUncheckedIndexedAccess`. */
export function fieldMeta(meta: CollectionMeta, name: string): FieldMeta | undefined {
  return meta.fields[name];
}
