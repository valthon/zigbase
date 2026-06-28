### Features

- Custom route handlers gain ergonomic `Ctx` helpers for shaping responses and reading the
  request:
  - Deferred response mutation — `ctx.setCookie(cookie)` / `ctx.addHeader(header)` queue
    cookies/headers that are merged onto whatever `http.Response` the handler returns, on
    **both** the success and error paths (a deferred Set-Cookie survives a handler error).
    The raw `http.Response` literal stays fully usable; handler-set cookies/headers are kept
    and the deferred ones appended.
  - Response builders — `ctx.json(status, value)`, `ctx.jsonError(status, code)` (emits
    `{"error":"<code>"}`), `ctx.html(status, body)`, `ctx.redirect(status, location)`, and
    `ctx.notFound()`, all allocating on the request arena.
  - Request reads — `ctx.query()` lazily parses + caches the decoded URL query string
    (`q.get("k") -> ?[]const u8`; `+` → space, `%XX` decoded) and `ctx.randomToken(n)` /
    `ctx.randomHex(n)` mint arena-owned random tokens.
  - `ctx.subjectCookie(name, opts)` — read-or-mint an opaque, anonymous-friendly per-visitor
    id stored in a cookie. Returns an existing well-formed value verbatim, otherwise mints
    one and queues a single Set-Cookie; idempotent within a request. An explicit `?subject=`
    query param still takes precedence.
- `http.Cookie` now carries an optional `domain` attribute (defaults to host-scoped).
