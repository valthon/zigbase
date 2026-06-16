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
