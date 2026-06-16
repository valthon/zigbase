export const VERSION = "0.1.0";

export { createClient } from "./client.js";
export type { Client, ClientOptions, SendOptions } from "./client.js";
export { CollectionService } from "./collection.js";
export {
  BaseAuthStore,
  MemoryAuthStore,
  LocalAuthStore,
  CookieAuthStore,
} from "./auth-store.js";
export type { AuthStore, AuthRecord, AuthChangeListener } from "./auth-store.js";
export { ZigbaseError, isZigbaseError } from "./errors.js";
export type { FieldError } from "./errors.js";
export { decodeJwtPayload, isTokenExpired } from "./jwt.js";
export { createPkceChallenge, randomState } from "./pkce.js";

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

// --- Plan 3: realtime + live store ---
// The realtime / live-store / filter-eval graph lives behind the dedicated
// `@zigbase/client/realtime` subpath (see ./realtime-entry.ts) so a REST-only
// app never bundles it. Import { withRealtime } from "@zigbase/client/realtime".
//
// Note: ZbRecord is already re-exported above from ./records.js (structurally identical).
