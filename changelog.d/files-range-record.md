### Breaking
- Custom-route surface: `http.Response.file_path` is now `Response.file` (`.file_path = p` → `.file = .{ .path = p }`). Plain-path delegation behavior is unchanged; the new optional `offset`/`len` window enables handler-planned partial responses.

### Features
- Record-file downloads (`GET /api/files/:col/:rec/:name`) support HTTP Range and conditional requests: `206` with `Content-Range` for `bytes=a-b` / `bytes=a-` / `bytes=-n`, `Accept-Ranges: bytes`, a strong content-immutable `ETag` with `304` revalidation, `If-Range`, `416` for unsatisfiable ranges, and `HEAD` parity.

### Fixes
- Record-file downloads no longer emit a duplicate `Cache-Control` header (the handler's per-collection value used to be joined on the wire by facil.io's global `max-age=3600`).
- `HEAD /api/files/:col/:rec/:name` now reaches the file-serving handler (previously unrouted and always 404).
