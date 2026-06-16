/**
 * One page of native server-side cursor (keyset) pagination.
 *
 * The server (src/api/records.zig + src/query/keyset.zig) mints the opaque
 * `nextCursor`/`prevCursor` tokens; the client forwards whatever it received
 * verbatim — it never decodes, validates, or synthesizes a token. `totalItems`
 * is present only when the page was fetched with `withTotal` (skipTotal=false).
 */
export interface CursorPage<T> {
  items: T[];
  nextCursor: string | null;
  prevCursor: string | null;
  hasNext: boolean;
  hasPrev: boolean;
  totalItems?: number;
}
