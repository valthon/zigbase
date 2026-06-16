/** Permissive default record shape used by the dynamic base SDK. SP2 substitutes real types. */
export interface ZbRecord {
  id: string;
  [key: string]: unknown;
}

/** Result shape of an offset-paginated list (`getList`). Mirrors the wire envelope. */
export interface ListResult<T> {
  page: number;
  perPage: number;
  totalItems: number;
  totalPages: number;
  items: T[];
}

/** Options accepted by list reads. */
export interface ListOpts {
  filter?: string;
  sort?: string;
  expand?: string;
  fields?: string;
  skipTotal?: boolean;
  signal?: AbortSignal;
  /** Opt-in de-duplication key; a new request aborts any in-flight one with the same key. */
  requestKey?: string;
}

/** Options accepted by single-record reads/writes. */
export interface RecordCrudOpts {
  expand?: string;
  fields?: string;
  signal?: AbortSignal;
  /** Opt-in de-duplication key; a new request aborts any in-flight one with the same key. */
  requestKey?: string;
}

function isBlobLike(v: unknown): v is Blob {
  return typeof Blob !== "undefined" && v instanceof Blob;
}

/**
 * True when `body` contains a File/Blob (or an array of them) at the top level,
 * meaning the request must be sent as multipart/form-data instead of JSON.
 */
export function hasBlob(body: unknown): boolean {
  if (!body || typeof body !== "object" || Array.isArray(body)) return false;
  for (const value of Object.values(body as Record<string, unknown>)) {
    if (isBlobLike(value)) return true;
    if (Array.isArray(value) && value.some(isBlobLike)) return true;
  }
  return false;
}

/**
 * Build a FormData payload from a plain object:
 * - undefined values are skipped, null becomes "".
 * - Blob/File values (and arrays thereof) are appended as files (repeated for arrays).
 * - scalars are stringified; nested plain objects/arrays are JSON-encoded.
 */
export function toFormData(body: Record<string, unknown>): FormData {
  const fd = new FormData();
  for (const [key, value] of Object.entries(body)) {
    if (value === undefined) continue;
    if (value === null) {
      fd.append(key, "");
    } else if (isBlobLike(value)) {
      fd.append(key, value);
    } else if (Array.isArray(value)) {
      for (const item of value) {
        if (isBlobLike(item)) fd.append(key, item);
        else if (item === null || item === undefined) continue;
        else if (typeof item === "object") fd.append(key, JSON.stringify(item));
        else fd.append(key, String(item));
      }
    } else if (typeof value === "object") {
      fd.append(key, JSON.stringify(value));
    } else {
      fd.append(key, String(value));
    }
  }
  return fd;
}
