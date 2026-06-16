export const VERSION = "0.0.0";

export { createClient } from "./client.js";
export type { Client, ClientOptions } from "./client.js";
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
export { RealtimeService } from "./realtime.js";
// Note: ZbRecord is already re-exported above from ./records.js (structurally identical).
export type { RealtimeEvent, RealtimeCallback, RealtimeAction } from "./realtime.js";
export { LiveCollection, LiveList } from "./live/live-collection.js";
export type { LiveReader, LiveSubscriber, LiveListOpts } from "./live/live-collection.js";
export { LiveRecord, RecordCache } from "./live/cache.js";
export type { Observable } from "./live/cache.js";
export { parseFilter, evaluateFilter, analyzeFilter } from "./live/filter-eval.js";
export type { FilterNode, FilterAnalysis } from "./live/filter-eval.js";
export type { RealtimeClient } from "./client.js";
