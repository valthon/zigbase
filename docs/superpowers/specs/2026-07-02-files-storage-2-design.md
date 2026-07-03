# SP3 Theme D — Files & Storage Round 2 (design spec, rev. 2)

Baseline: `origin/main` @ `0ae3289` (0.9.x line; `-Dpostgres`/`-Dvector` build gates exist). Pre-1.0 —
breaking changes allowed, minor bump. Owner constraints honored: Storage plugin story stays coherent
(examples/plugins is public surface), file-serving authz/tenancy stays fail-closed, docs + site mirrors +
changelog fragment + both test suites.

**Revision note.** This spec was re-litigated under two owner directives that arrived after the first
draft: (1) **facil.io-first** — do not maintain code that facil.io already provides; anything replacing a
facil.io capability needs to be compelling *and* have no alternative; (2) **lean default build** —
alternative capabilities are comptime-gated (`-Dpostgres`/`-Dvector` precedent). The first draft's
centerpiece — a ZigBase-owned serving layer replacing `http_sendfile2` everywhere — is **withdrawn**.
What survives it is much smaller: static serving stays on facil.io end-to-end (with a ~20-line Range
normalization shim and a facil.io-native max-age knob), and only the **record-file download route** moves
to facil.io's own public `http_sendfile` fd primitive, because its headers must diverge per collection and
facil.io's wrapper provably cannot do that (§B.1). S3 moves behind **`-Ds3`**.

## Goal

Ship three coordinated pieces:

1. **A production S3-compatible remote storage backend** (AWS S3, MinIO, Cloudflare R2) behind a new
   **`-Ds3` build flag**, selected at runtime by configuration alone — `ZIGBASE_S3_*` env vars, no code
   change for a consumer binary built with the flag — reusing the SigV4 signer that already ships in
   `src/mail/sigv4.zig` and the shared `src/http_client.zig`, and serving downloads **through the existing
   local-file path** via a spool cache, so Range/ETag/tenancy behavior is byte-identical across backends.
2. **Correct HTTP Range + conditional-request support** for record-file downloads (ZigBase-planned,
   facil.io-transmitted — §B) and for static serving (facil.io-planned, ZigBase-normalized — §A).
3. **Tunable static Cache-Control** (comptime + CLI + env) by replacing the `HTTP_HVALUE_MAX_AGE` FIOBJ
   global through facil.io's own state-callback API — no serving code is taken over (§C).

Plus one latent bug: **record-file downloads emit two `Cache-Control` headers today** (`api/files.zig:142-150`
sets `private`/`public, max-age=3600` via `extra_headers`; `http_sendfile2` then unconditionally adds its
own `max-age=3600` at `http.c:484`; `set_header_add` (`http_internal.h:208`) collects the duplicate into a
FIOBJ array and both are emitted). Fixed by §B; the exhaustive why-not-inside-facil.io analysis is §B.1.

## Directive-1 compliance — item-by-item re-litigation

| Capability | facil.io option examined | Decision |
|---|---|---|
| Static dir-mode serving (stat, mime, ETag, 304, `.gz` sidecar, HEAD/OPTIONS) | `http_sendfile2` — works today | **Keep facil.io wholesale.** First draft's owned layer, nginx-style ETags, RFC-weak `If-None-Match` for dir mode: all withdrawn. |
| Static Range `bytes=X-` / `bytes=-n` / overlong `a-b` | facil.io parses only in-bounds `a-b` correctly (§A.1) | **Pre-processing shim** that rewrites the *request's* Range header into the canonical closed form facil.io handles correctly, then delegates. facil.io's own Range machinery does the 206 (§A.2). |
| Static Cache-Control max-age | No settings knob, no compile-time define — but the value is a mutable non-static C global `HTTP_HVALUE_MAX_AGE` | **Replace the FIOBJ once at startup** via facil.io's `fio_state_callback_add(FIO_CALL_PRE_START, …)` — facil.io's header-emission path is untouched (§C.1). |
| Record-file downloads | `http_sendfile2` cannot emit per-collection Cache-Control exactly once (§B.1 proves this from source) | **ZigBase owns headers + planning for this one route**, transmission stays on facil.io's *public* `http_sendfile(h, fd, len, offset)` extern (zap `src/fio.zig:426`) — the same primitive `http_sendfile2` itself finishes through. This is directive option (c), the sub-path where headers already diverge. Justification in §B.1. |
| Embedded static assets | Never touched facil.io's file path — served from `@embedFile` bytes via `sendBody` (`static_files.zig:127-143`) | ZigBase already owns this path end-to-end; adding Range/Cache-Control there replaces nothing (§A.4). |
| Upstream patch to facil.io/zap for the Range parser | zap vendors a frozen facil.io 0.7.x amalgamation; repo convention forbids editing vendored deps; upstream facil.io 0.8 is a rewrite | **Rejected** — turnaround unknowable, and the shim is forward-compatible (a fixed upstream parser makes the rewrites harmless no-ops). Worth *filing* upstream; not worth blocking on. |

## Non-goals (explicit deferrals, one-line rationale each)

- **Full ZigBase-owned static serving layer** — withdrawn under directive 1 (this was the first draft's §A);
  everything it bought for static (nginx ETags, RFC-weak conditionals, owned `.gz` handling,
  `Vary: Accept-Encoding` on sidecar responses) is dropped or deferred with it. `Vary` alone survives as a
  one-line `extra_headers` addition in dir mode (facil.io never sets `Vary`, so no duplicate).
- **Image thumbnails / transforms** — vendoring an image decoder is a supply-chain and RCE-surface decision
  (codecs are the classic memory-safety CVE vector) that deserves its own theme with a sandboxing story.
- **Resumable / chunked uploads** — needs an upload-session protocol (tus-style), staging storage, and
  orphan GC; today's arena-buffered `max_body_size`-capped design is a deliberate simplicity.
- **Presigned-URL redirect serving for S3** — requires SigV4 *query-string* signing (a second signing mode)
  and surrenders the response-header invariants (Content-Disposition, sandbox CSP, tenancy Cache-Control)
  to S3; proxy-serving ships first, presign is an additive follow-on on the same S3 client.
- **S3 multipart upload** — request bodies are capped by the zap listener's `max_body_size`
  (`ZIGBASE_MAX_UPLOAD_SIZE`, default 50 MiB), far under the 5 GiB single-PUT limit; `create()` fails fast
  if `max_upload_size > 5 GiB` so the gap can never silently open.
- **`multipart/byteranges` (multi-range 206)** — vanishingly rare client need; RFC 9110 permits ignoring
  the Range header, so multi-range requests are served as a full 200 (facil.io's existing behavior for
  static; the record-file planner does the same).
- **Authenticated static serving** — the static root is contractually public ("never place secrets there");
  authenticated delivery already exists via file storage. Design note kept (§C.4) because a future guard
  interacts with the SPA fallback.
- **On-the-fly compression** — unchanged stance (pre-compress / CDN); dir mode's *undocumented* `.gz`
  sidecar negotiation stays exactly facil.io's (now documented for the first time, §A.3).
- **Per-path cache-control rules** — one global knob first; a glob→policy table is an easy later add.
- **S3 orphan GC / reconciler** — deletes stay best-effort exactly like the local backend; S3 lifecycle
  rules are the documented mitigation.

---

## A. Static serving — facil.io kept, Range normalized, knob via facil.io's own global

### A.1 Grounded findings (vendored `facil.io/lib/facil/http/http.c`, Range block at ~505-560)

Dir-mode static already flows Response.`file_path` → `server.zig:910-916` → `r.sendFile` →
`http_sendfile2`. Its Range parser is correct **only** for in-bounds `bytes=a-b`:

- `bytes=X-` (open-ended — the form video players send when seeking): `end_at <= 0 → goto open_file` →
  full 200. This is the KNOWN_LIMITATIONS bullet.
- `bytes=-n` (suffix): computes `offset = st_size - start_at` with **negative** `start_at`, i.e. an offset
  *past EOF*, and prints the negative `start_at` as `%lu` into Content-Range — broken output, not just a
  missing feature.
- `bytes=a-b` with `b >= size`: the length-clamp branch (`length = length - start_at`) produces a bogus
  Content-Length.
- `a >= size`: falls through to a full 200 instead of RFC 9110's 416.
- `If-None-Match`/`If-Range` are exact `fiobj_iseq` matches against facil.io's unquoted base64
  size^mtime ETag — not RFC list/weak semantics, but self-consistent and **kept as-is** for static.

### A.2 Range normalization shim (`static_files.zig`, dir mode; ~20 lines + pure helper)

Before returning the `file_path` response, `serveDir` normalizes the *request's* Range header so facil.io
only ever sees the one form it handles correctly:

- Pick the file facil.io will serve — mirror its sidecar probe: if the request's `Accept-Encoding` contains
  `gzip` and `<path>.gz` exists, stat the sidecar, else the base file (facil.io's exact order,
  `http.c:449-470`). `serveDir` already stats/canonicalizes; this adds at most one extra `stat`.
- `pub fn normalizeRange(alloc, raw: []const u8, size: u64) ?union { rewrite: []const u8, unsatisfiable }`
  — a **pure, unit-testable** helper: `X-` → `X-(size-1)`; `-n` → `(size-n)-(size-1)` (`n >= size` →
  `0-(size-1)`); `a-b` with `b >= size` → `a-(size-1)`; `a >= size` or `-0` → `.unsatisfiable`; already
  in-bounds `a-b`, malformed, or multi-range → `null` (leave untouched; facil.io ignores → 200,
  RFC-permitted).
- `.rewrite` is written back into the request-header hash via `zap.fio.fiobj_hash_set(r.h.*.headers, …)`
  (exported at zap `src/fio.zig:137`; replace semantics, frees the old value) — then delegation proceeds
  and **facil.io's own machinery produces the 206/Content-Range/Accept-Ranges**.
- `.unsatisfiable` → ZigBase answers **416** with `Content-Range: bytes */N` directly (tiny owned response;
  facil.io's alternative is a *wrong* 200 — this is the one static status facil.io cannot be made to emit).
- `If-Range` ordering is preserved: the shim only edits the header value; facil.io still deletes the Range
  header itself when `If-Range` mismatches, exactly as today.

One additive header while we're here: dir-mode `extra_headers` gains `Vary: Accept-Encoding` (one line;
facil.io serves `.gz` sidecars without it — a shared-cache correctness fix that goes *through* facil.io's
header API, no duplicate possible since facil.io never sets `Vary`).

### A.3 What is explicitly NOT built for static

No ZigBase ETag scheme, no RFC-weak `If-None-Match`, no owned `.gz` handling, no owned 206 assembly, no
HEAD/OPTIONS handling — facil.io's existing behavior for all of these is kept verbatim and now *documented*
(the `.gz` sidecar for the first time). If facil.io's conditional semantics ever become a real limitation,
that is a new conversation with this directive on the table.

### A.4 Embedded static (already ZigBase-owned — improving it replaces nothing)

Embedded assets never touch `http_sendfile2`: they are `@embedFile` bytes served via `sendBody` with a
build-time CRC32 ETag and ZigBase's own RFC-weak `etagMatches` (`static_files.zig:107,127-143`). Directive
1 is not implicated. Additions: single-range 206 by **subslicing the embedded bytes** (planner from §B.2
reused; `Accept-Ranges: bytes`, `Content-Range`, 416 on unsatisfiable) and the §C Cache-Control knob value
(embedded assets currently send *no* Cache-Control). ETag format unchanged — existing Playwright
assertions keep passing.

## B. Record-file downloads (`GET /api/files/:col/:rec/:name`) — the one owned sub-path

### B.1 Why this route cannot stay on `http_sendfile2` (the compelling + no-alternative case)

The route must emit **per-collection** Cache-Control — `cacheControlFor` (`api/files.zig:57`) returns
`private` for tenant-owned/non-public collections and this is a PINned tenancy invariant. Against the
vendored source, every way to keep `http_sendfile2` fails:

1. *Pre-set the header and let facil.io "override" it* — `http_set_header` → `set_header_add`
   (`http_internal.h:208`) does `fiobj_hash_replace` then **arrays** old+new; both go on the wire. That IS
   today's double-header bug. (zap's `sendFile` doc-comment claiming "you can override by setting those
   headers yourself" is contradicted by this source.)
2. *Strip facil.io's copy after the call* — `http_sendfile2` finishes the response internally; the handle
   is consumed and invalid on return. There is no after.
3. *Drop ZigBase's header, accept facil.io's global* — every download gets `max-age=3600`, including
   tenant-owned files that must be `private`. Violates the load-bearing tenancy invariant. Rejected.
4. *Swap the `HTTP_HVALUE_MAX_AGE` global per request under a mutex* — technically works (the dup at
   `http.c:484` is synchronous), but it serializes all file sends and makes a security-relevant header
   depend on cross-module mutation of a C global per request. Rejected as fragile beyond the bug it fixes.

Additionally: an S3-spooled file, correct 206/304/416 semantics, a content-addressed ETag, and the already-
divergent headers (Content-Disposition, sandbox CSP, nosniff) all want header ownership on this route. So:
**ZigBase plans and sets headers; facil.io still transmits** via its public `http_sendfile(h, fd, length,
offset)` extern — the same primitive `http_sendfile2` itself finishes through (it takes fd ownership and
sets Content-Length). ZigBase reimplements no socket/streaming code. This is the last-resort owned path the
directive allows, confined to the single route where the alternatives are exhausted above.

### B.2 Pure planner (`src/files/serve_file.zig` — unit-testable, no I/O)

```zig
pub const PlanInput = struct {
    size: u64,
    etag: []const u8,            // quoted, strong
    range: []const u8,           // raw Range header value ("" = none)
    if_none_match: []const u8,
    if_range: []const u8,
    head: bool,
};
pub const Plan = struct {
    status: u16,                 // 200 | 206 | 304 | 416
    offset: u64, len: u64,
    content_range: ?[]const u8,  // "bytes a-b/N" or "bytes */N"
};
pub fn plan(alloc, in: PlanInput) !Plan;
```

Evaluation order (RFC 9110): `If-None-Match` (weak comparison, list + `*` — reuse
`static_files.etagMatches`) → 304; else `If-Range` (exact strong ETag match required, otherwise Range is
ignored); else parse a **single** `bytes=` range (`a-b`, `a-`, `-n`; syntactically-multi → ignore → 200);
unsatisfiable (`a >= size`, `-0`) → 416 with `Content-Range: bytes */N`. Scope: this planner serves the
record-file route and the embedded-static path (§A.4) only — dir-mode static never uses it (§A.3).

**Transport.** `http.Response.file_path: ?[]const u8` (`http.zig:117`) becomes:

```zig
file: ?struct { path: []const u8, offset: u64 = 0, len: ?u64 = null } = null,
```

`server.zig`'s sink opens the path, `fstat`s, sets status + all headers, then calls
`zap.fio.http_sendfile(r.h, fd, len, offset)`. A thin `sendFileRange(r, path, offset, len)` helper wraps
the open/fstat/extern dance; open failure → the existing 404 raw envelope (unchanged semantics). Since
facil.io no longer infers Content-Type on this route, the handler sets it explicitly via
`mime.fromExtension` (unknown → `application/octet-stream`). **Sink discriminator:** `len == null` →
plain `r.sendFile(path)` delegation exactly as today (dir-mode static rides this untouched); `len` set →
the owned-header `http_sendfile` path. The record-file handler *always* sets `len` (the planner computes
it even for a full-body 200), so the route deterministically takes the owned path.

### B.3 Semantics

- **Authorization is untouched and runs first.** The existing chain — record lookup,
  `recordReferencesFile`, `fileIdentity` (`?token=` / bearer / cookie), `tenancy.resolveRequest`,
  `policy.decide/authorizes(.view)`, `file.beforeServe` hook, all failing closed as 404 — completes before
  any Range/conditional logic. No new code path can serve bytes that today's path would deny; the PIN tests
  in `api/files.zig` (policy-parity, tenant-cacheability) must pass unchanged.
- **ETag** (strong, quoted): stored names are content-immutable — `naming.storedName` appends a random
  10-char base36 suffix and an update always mints a new name — so
  `ETag = "<hex FNV-1a-64 of col ++ "/" ++ rid ++ "/" ++ name>"`. No stat-derived component; identical for
  local and S3-spooled serving.
- `Accept-Ranges: bytes` on every 200/206. 206 carries `Content-Range` + the slice via `file.offset/len`.
  416 carries `Content-Range: bytes */N` and the standard security headers.
- **Headers**: `Referrer-Policy`, `X-Content-Type-Options`, sandbox CSP, `Content-Disposition`, and
  `cacheControlFor(col)` exactly as today on 200/206/416 — but now exactly once, plus `ETag` and explicit
  `Content-Type`. 304 replays `ETag` + `Cache-Control` only. `cacheControlFor` itself is unchanged
  (tenancy invariant PINned). HEAD mirrors GET: same status + headers + Content-Length, no body.
- `?download` and `?token=` compose orthogonally with Range (disposition and identity resolved before
  planning).
- **Design note — file tokens vs. seeking**: `ZIGBASE_FILE_TOKEN_TTL` defaults to 120 s; a video player
  seeking via `?token=` URLs will get 404s once the token expires mid-playback. Documented guidance: use
  cookie/bearer auth for long media, or re-mint tokens per seek. No TTL change in this theme.

## C. Tunable static Cache-Control

### C.1 Mechanism — facil.io's own global, replaced through facil.io's own callback API

There is **no facil.io settings field and no compile-time define** for the static max-age (verified: the
value is a runtime FIOBJ, `fiobj_str_new("max-age=3600", 12)` at `http_internal.c:223`, not a macro — so a
build.zig `-D` define cannot exist to set). But `HTTP_HVALUE_MAX_AGE` is a **non-static C global**
(`extern FIOBJ HTTP_HVALUE_MAX_AGE;`, `http_internal.h:81`) created in `http_lib_init` at
`FIO_CALL_ON_INITIALIZE`. ZigBase therefore:

- declares `extern var HTTP_HVALUE_MAX_AGE: zap.fio.FIOBJ;` (links against the same compiled facil.io),
- registers `fio_state_callback_add(FIO_CALL_PRE_START, replaceStaticMaxAge, …)` before starting the
  listener (`FIO_CALL_PRE_START` is forced inside `fio_start` at `fio.c:3925`, strictly *after*
  `ON_INITIALIZE` — so the FIOBJ exists and our replacement is never clobbered),
- in the callback: `fiobj_free(old)`, `HTTP_HVALUE_MAX_AGE = fiobj_str_new(knob)`.

facil.io's header-emission path is untouched — `http_sendfile2` keeps `fiobj_dup`-ing the global at
`http.c:484`; it just dups our value. **Scope note (documented):** the global affects every
`http_sendfile2` response process-wide — in ZigBase that is exactly dir-mode static (record files leave
this path in §B), but a consumer route calling `r.sendFile` directly inherits it too; that *is* the knob.
Single-process; the PRE_START timing is fork-safe (runs in the master before workers).

### C.2 Knob surface

- Comptime: `.static_cache_control = "public, max-age=86400, immutable"` (App config key; validated at
  comptime for CR/LF and length ≤ 256 — `@compileError` on violation). Sets the *default*.
- Runtime: `--static-cache-control <value>` flag + `ZIGBASE_STATIC_CACHE_CONTROL` env (flag wins over env,
  matching `--serve-static` / `cfg.static_dir` precedence). Runtime overrides the comptime default; same
  CR/LF+length validation fails startup with a named error. Flag rejected (`UnknownFlag`) when
  `.static_files = .disabled`, mirroring `--serve-static` gating. When nothing is set, the callback is not
  registered at all — facil.io's stock `max-age=3600` byte-identical to today.
- **Embedded mode**: assets previously sent *no* Cache-Control; they now send the knob value (or the
  `max-age=3600` default), applied directly on the ZigBase-owned sendBody path (changelog Fixes entry —
  revalidation still works via the CRC32 ETag, strictly additive).

### C.3 Composition with SPA fallback and directory indexes

- A **fallback-served** SPA shell (a miss resolved via the `.spa` marker) always gets
  `Cache-Control: no-cache` regardless of the knob: a cached stale shell after a redeploy references
  hashed assets that no longer exist, breaking deep links — correctness over configurability.
  *Implementation note:* per-response divergence is impossible through `http_sendfile2` (§B.1 items 1-2),
  so the fallback shell — one small HTML file — is read and served via the owned `sendBody` path with a
  stat-derived strong ETag (`"<hex size>-<hex mtime>"`), making revalidation one cheap 304. This is a
  deliberate, tiny widening of the owned surface, justified the same way as §B: facil.io cannot emit a
  per-response Cache-Control, and the alternative (knob value on the fallback shell) breaks deployments.
- A **direct hit** on any real file — including `index.html` reached by name or directory resolution —
  gets the knob value via facil.io. Rationale: the knob owner knows their deploy story; the fallback is the
  only case where ZigBase *invents* a response for a URL that names something else.

### C.4 Record files are out of scope for the knob; authenticated static stays deferred

`cacheControlFor(col)` stays authorization-derived (tenancy invariant); a static-serving knob must not
loosen it. Authenticated-static design note unchanged: if ever built, the guard must also gate the SPA
fallback shell, or a 200-shell-vs-404 difference leaks path existence under a protected prefix.

## D. S3-compatible storage backend — behind `-Ds3`

### D.0 Build gate (directive 2; mirrors `-Dpostgres`/`-Dvector`)

- `build.zig`: `const s3 = b.option(bool, "s3", "Compile in the opt-in S3-compatible storage backend
  (default: off)") orelse false;` + `build_options.addOption(bool, "s3", s3);` — same
  `b.addOptions()`/`addOptions("build_options", …)` plumbing as `-Dpostgres` (`build.zig:25,50-52`).
- **Compiled out when off** (db.zig conditional-import pattern, `db.zig:27`):
  `src/files/s3.zig` (client ops + spool cache) via
  `const s3mod = if (build_options.s3) @import("files/s3.zig") else struct {};`; the `S3Storage` root.zig
  export becomes the conditional type (present under the flag, a `@compileError`-on-use stub otherwise —
  same shape as the PG-gated types). The generalized SigV4 signer and `http_client.zig` are **not** gated —
  they already ship in the default binary via SES (§E). `HttpClient.download()` (§D.4) is ungated source;
  with no callers in a default build, Zig's lazy analysis never codegens it.
- **Stock binary (no `-Ds3`) with `ZIGBASE_S3_BUCKET` set** — mirrors the `postgres_url_without_build`
  precedent exactly (`db.zig:477`, `framework.zig:1517-1524`): the `ZIGBASE_S3_*` config fields parse in
  every build (cheap, ungated — detection requires it), and `DefaultStoragePlugin` logs
  `std.log.warn("ZIGBASE_S3_BUCKET is set but this binary was built without -Ds3; falling back to local
  storage at {s}/storage (build with -Ds3=true to use S3)", …)` and falls back to `LocalStorage` —
  fail-loud, not silent, not fatal, same contract as a `postgres://` URL on a stock binary.
- **CI**: the new `s3` job (see Test plan) builds and tests with `-Ds3=true`; the existing `test` job keeps
  the default flags so both configurations compile on every PR (the `postgres` job already proves this
  two-config pattern, `ci.yml:117,165-166`).

### D.1 Selection & configuration (mirrors the `DefaultMailerPlugin` precedent)

Under the flag, `DefaultStoragePlugin.create(gpa, io, cfg)` is config-driven: `cfg.s3_bucket` non-empty →
`S3Storage`, else `LocalStorage` at `<data_dir>/storage` (unchanged). Standalone users of an `-Ds3` build
get S3 with zero code, exactly like SMTP-vs-log mail. `S3Storage` is exported from `root.zig` (like
`LocalStorage`) so custom plugins can wrap it — the plugin contract (`create`/`interface`/`deinit`,
comptime-enforced by `assertPluginContract`) is untouched.

New `Config` fields + `applyEnv` lines (SMTP-cluster pattern; parse errors abort startup):

| Env | Meaning | Default |
|---|---|---|
| `ZIGBASE_S3_BUCKET` | bucket name; non-empty enables S3 | — |
| `ZIGBASE_S3_REGION` | SigV4 region | `us-east-1` |
| `ZIGBASE_S3_ENDPOINT` | endpoint override (MinIO/R2); `http://` allowed with a loud startup warning | `https://s3.<region>.amazonaws.com` |
| `ZIGBASE_S3_ACCESS_KEY_ID` / `ZIGBASE_S3_SECRET_ACCESS_KEY` | credentials; missing either → startup error naming the var | — |
| `ZIGBASE_S3_FORCE_PATH_STYLE` | path-style addressing | `true` when endpoint set, else `false` |
| `ZIGBASE_S3_KEY_PREFIX` | optional key prefix | `""` |
| `ZIGBASE_S3_CACHE_DIR` | spool cache root | `<data_dir>/storage_cache` |
| `ZIGBASE_S3_CACHE_MAX_BYTES` | spool cache cap | `1 GiB` |

No TLS-verification-skip knob (consistent with `http_client.zig`'s hard stance); MinIO in dev/CI uses plain
`http://`. Secrets are never logged (config-dump paths redact, matching SMTP password handling).

### D.2 SigV4 generalization (`src/mail/sigv4.zig` → `src/aws/sigv4.zig` — default build, not gated)

The existing signer is SES-shaped (POST-only, fixed `content-type;host;x-amz-date`). Generalize:
parameterized method, canonical URI with S3 `UriEncode` of each key segment (`/` preserved), arbitrary
sorted signed-header list including `x-amz-content-sha256` (S3 requires it signed), canonical query string
(empty for now; the seam presigning will use later), service parameter. `ses.zig` moves to the new surface;
**its existing test vectors must pass byte-identically** (pinned). Add S3 GET/PUT vectors from the AWS
signature test suite, plus UriEncode edge cases (space, `+`, unicode, `~`). This is a refactor of code the
stock binary already ships — the S3-only *call sites* are what `-Ds3` gates.

### D.3 S3 client ops (`src/files/s3.zig` — gated)

`PutObject` (body = full upload bytes — matches the arena-buffered upload path; `Content-Type` from
`mime.sniff` stored as object metadata), `GetObject` (streamed), `DeleteObject`, `HeadObject` (probe),
`ListObjectsV2` (prefix `col/rid/`, for `deleteRecord`; minimal bounded `<Key>` tag scan — no general XML
parser). Key layout mirrors local disk: `<prefix><col>/<rid>/<filename>` (all three components are
validated/sanitized already; keys additionally UriEncoded per SigV4).

### D.4 Streaming download (`http_client.zig` addition — ungated source, S3 is the only caller)

`HttpClient.download(opts, writer: *std.Io.Writer) !{status, headers}` beside `request()` — same TLS
stance, same `testcapture` intercept seam (mock body written through the writer) — so a large object never
transits a fixed 1 MiB buffer (`max_response_bytes` doesn't apply on this path).

### D.5 Storage vtable change (BREAKING, the only one — applies to all builds)

`localPath(ctx, alloc, col, rid, name) !?[]const u8` → **`fetch(ctx, io, alloc, col, rid, name) anyerror!?[]const u8`**:
"return a local filesystem path whose contents are the file, **materializing it locally if necessary**;
`null` = the backend has no such object." The rename is forced anyway: the old signature lacks the `io`
needed for network/disk I/O. `LocalStorage.fetch` = the same pure path-join. Migration is mechanical
(rename + one parameter); `examples/plugins` `AuditStorage` and docs §9 are updated in the same PR.
`serve()` maps `null` → 404 + `std.log.err` (DB references an object the backend lost — hide existence,
scream in logs) and error → 500 (transient; retry-once already applied below).

### D.6 Spool cache (gated with `s3.zig`)

`fetch` on S3: cache hit → path; miss → `GetObject` streamed to `<cache>/<col>/<rid>/<name>.tmp<rand>` then
atomically renamed (a concurrently-served reader can never see a partial file). Stored names are
content-immutable → **no invalidation problem**; eviction is size-triggered on miss-fill: when the cache
exceeds the cap, evict oldest-mtime entries to a low-water mark. Concurrent misses may download twice; both
renames are idempotent — accepted (no singleflight machinery). `delete`/`deleteRecord` also remove spool
entries (hygiene, not security — `recordReferencesFile` already 404s de-referenced names before storage is
consulted). The spooled file is served by the §B path — Range/ETag/tenancy byte-identical to local.

### D.7 Failure semantics (startup-vs-runtime philosophy)

- **Startup, fail-fast**: config validation (missing creds, bad ints, CR/LF in values);
  `max_upload_size ≤ 5 GiB` assert; then a **`HeadObject` probe** on `<prefix>.zigbase/probe` — 200 *or*
  404 proves DNS/TLS/SigV4/bucket/permissions end-to-end (404 expected; it needs exactly the permission
  serving needs); 403/301/5xx/connect-failure → `std.log.err("refusing to start: …")` + error, matching the
  JWT-secret and `FieldKeyRequired` precedents. This is deliberately a *new* precedent (SMTP has no probe):
  storage sits on the synchronous request path, mail is queued and retryable.
- **Runtime, degrade to 5xx, never crash**: `put` failure → error into the existing
  rollback-plus-best-effort-cleanup path in `api/records.zig` (unchanged); one immediate retry on
  transport/5xx for `put` and `fetch` (both idempotent); `fetch` failure after retry → 500; `delete`/
  `deleteRecord` stay best-effort (`catch {}` call sites unchanged) — S3 orphans are possible exactly as
  local orphans are today; documented with the lifecycle-rule mitigation.
- **Documented trade-off**: `put` runs inside the global write transaction (deliberate: a storage failure
  rolls the row back), so a slow S3 PUT holds the writer lock. Goes in KNOWN_LIMITATIONS; staging-outside-
  txn is deferred until it hurts someone real.

---

## E. Default-build impact (directive 2)

Honest accounting of what the stock (`zig build`, no flags) binary gains. The mail `HttpClient` and SigV4
signer **already ship in every default build** — `root.zig:53` exports `SesMailer` unconditionally and
`mail/ses.zig` imports both — so neither is "new weight" here; only their deltas are.

| Item | Default? | New default-build weight (estimate) | Justification |
|---|---|---|---|
| Record-file planner + owned-header serving (§B) | **On** | ~10-25 KiB (planner, ETag, header assembly; transmission is facil.io's existing extern) | Correct HTTP + the double-header fix on a core route; every deployment benefits; not separable from correctness. |
| Range normalization shim (§A.2) | **On** | ~2-4 KiB (pure helper + one stat) | Fixes video seeking on static for everyone; delegates the actual serving. |
| Cache-Control knob + PRE_START global replace (§C) | **On** | ~1-2 KiB | A config knob; callback not even registered when unset. |
| Embedded-static Range + Cache-Control (§A.4) | **On** | ~2-4 KiB | Path is already ZigBase-owned; planner reused, no new machinery. |
| SigV4 generalization (§D.2) | **On** (refactor of shipped code) | ~1-3 KiB (parameterization of the existing signer; S3-only branches unreferenced → not codegen'd) | SES already requires the signer; gating a refactor would fork the signer in two. |
| `HttpClient.download` (§D.4) | Source ungated, **zero default cost** | 0 (no default-build caller → Zig lazy analysis never codegens it) | Keeping it beside `request()` avoids a gated fork of http_client.zig. |
| S3 client + `S3Storage` + spool cache (§D.3/D.6) | **Gated `-Ds3`** | 0 by construction (conditional import) | Alternative-capability backend per directive 2; estimated ~40-80 KiB when enabled. |
| `ZIGBASE_S3_*` config fields + stock-binary warning (§D.0) | **On** | <1 KiB | Required for the fail-loud `postgres://`-precedent warning; strings + parse only. |

Net default-binary delta: **roughly +15-35 KiB**, dominated by the §B serving path. Verified post-hoc in
PR review by comparing `zig build -Doptimize=ReleaseSafe` binary sizes before/after (same procedure the
postgres gate used); estimates above are good-faith, not measured.

---

## Test plan

**Zig unit tests** (every new `src/*.zig` file added to `root.zig`'s test block — the discovery footgun):

- `serve_file.plan` matrix (~30 cases): `bytes=a-b`/`a-`/`-n`, malformed, multi-range→200, `a>=size`→416,
  `-0`→416, If-Range strong match/mismatch/weak-refused, If-None-Match single/list/`W/`/`*`, HEAD.
- `normalizeRange` matrix: `X-`→`X-(size-1)`, `-n`→closed form, `-n` with `n>=size`→`0-(size-1)`, overlong
  `a-b` clamped, `a>=size`/`-0`→unsatisfiable, in-bounds/malformed/multi→null (passthrough), gz-sidecar
  size selection (sidecar stat drives the rewrite when Accept-Encoding matches).
- Header-emission tests (record route): exactly one Cache-Control (regression), explicit Content-Type,
  304/416 header sets, record-immutable ETag; embedded CRC32 ETag unchanged. (Dir-mode ETag/`.gz`/
  conditional tests: **dropped** — that behavior is facil.io's, pinned e2e instead.)
- SigV4: SES vectors byte-identical (pin), new S3 vectors, UriEncode edges. (Default build — not gated.)
- Gated behind `build_options.s3` (compiled/run only in the `s3` CI job): `s3.zig` via the `testcapture`
  mock seam (no network) — signed-header presence, status→error mapping, retry-once, probe 200/404 pass vs
  403/connect fail, ListObjectsV2 tag-scan on hostile input; spool cache — atomic fill, LRU eviction at
  cap, delete-evicts; `DefaultStoragePlugin` selection matrix + config errors (missing secret names the
  var; >5 GiB upload cap). Default-build test: `ZIGBASE_S3_BUCKET` set without the flag → LocalStorage +
  the warning (mirrors the `postgres_url_without_build` test).
- Both suites re-run with `-Ddev-clock=false` in CI as today.

**Live MinIO in CI** (new `s3` job, built with `-Ds3=true`): start MinIO via `docker run` (the `services:`
block can't pass the `server /data` command — same reason `postgres-tls` uses `docker run`,
`ci.yml:204-226`, incl. readiness poll + `if: always()` teardown), `mc mb` the bucket, then (1) gated Zig
live tests reading `ZIGBASE_S3_TEST_ENDPOINT`/`_BUCKET`/`_KEY`/`_SECRET` — skip cleanly when unset,
mirroring the `ZIGBASE_PG_TEST_URL` pattern; (2) a Python raw-HTTP e2e (`tests/s3/`, urllib pattern from
`test_static_files.py`): launch `zigbase serve` with `ZIGBASE_S3_*` env → create collection with a file
field → multipart upload → full GET, open-ended-range 206, 304, 416 → delete record → object gone in
MinIO; plus a negative boot test (bad creds → process exits non-zero with "refusing to start").

**Python admin/raw-HTTP suite additions** (run locally before merge — unit-green has hidden e2e regressions
here before): `tests/admin/test_file_range.py` on the local backend (206 matrix incl. `bytes=X-` and
`bytes=-n`, `Accept-Ranges`, **exactly one Cache-Control header**, If-Range, HEAD, tenant-owned stays
`private`); `test_static_files.py` extensions — these are the *pin* for delegated facil.io behavior: dir
mode `bytes=X-`/`-n` seek → correct 206 bytes (shim + facil.io), knob via flag + env (single header, knob
value on the wire), no-knob default still `max-age=3600`, embedded now emits Cache-Control, SPA-fallback
shell `no-cache` + ETag, `.gz` sidecar still served + new `Vary`. Existing `test_file_upload.py` runs
unchanged as the upload regression.

**Examples**: CI already builds all three; `examples/plugins` compiles against the renamed vtable (that
compile *is* the public-surface test) and its README/steps re-verified.

## Docs & sync checklist

- `docs/api.md` + `site/src/content/docs/api.md`: Files section (Range/conditional semantics,
  `Accept-Ranges`, ETag, 416, token-TTL-vs-seeking note); Static section (knob, embedded Cache-Control,
  Range forms now working — noting conditional/ETag semantics in dir mode remain facil.io's, `.gz` sidecar
  documented for the first time).
- `docs/framework.md` + mirror: §9 (S3 backend + env table + **`-Ds3` build requirement**, `localPath` →
  `fetch` migration one-liner, updated `MyStorage` example), §13 (cache knob, its process-wide scope for
  consumer `sendFile` routes, SPA-shell `no-cache` composition).
- `site/src/content/docs/configuration.md`: `ZIGBASE_S3_*`, `ZIGBASE_STATIC_CACHE_CONTROL`,
  `--static-cache-control` in the env/flag tables; `-Ds3` beside `-Dpostgres`/`-Dvector` in the build-flags
  docs.
- `KNOWN_LIMITATIONS.md`: delete the static "No Range" (line 36) and "max-age not configurable yet"
  (line 45) bullets; remove S3 from "other deferred"; add S3 put-inside-txn latency, best-effort-delete
  orphans + lifecycle mitigation, proxy-only serving (no presigned redirect yet), dir-mode conditional
  requests use facil.io's exact-match ETag semantics.
- `README.md` feature bullets (S3 noted as `-Ds3`); `examples/plugins/src/main.zig` + README (vtable
  rename); blog/golfsim unaffected (build-verified). `docs/superpowers/` untouched (historical archive).
- `changelog.d/files-storage-2.md`: **Breaking** (Storage vtable `localPath` → `fetch(io, …)`),
  **Features** (opt-in `-Ds3` S3/MinIO/R2 backend; HTTP Range + conditional requests for record files;
  working `bytes=X-`/`bytes=-n` Range on static; tunable static Cache-Control), **Fixes** (duplicate
  Cache-Control on file downloads; embedded static missing Cache-Control), **Internal** (Range
  normalization shim; MinIO CI job; SigV4 generalization).
- `cd site && npm run build` green; PR-template sync checklist per PR.

## Sequencing (independent, reviewable PRs)

1. **PR1** — record-file route: planner + `Response.file{path,offset,len}` transport +
   `http_sendfile`-primitive send + ETag/304/416/Range + duplicate-Cache-Control fix (the riskiest
   behavioral diff, isolated; static untouched).
2. **PR2** — static: Range-normalization shim + owned 416 + `Vary` one-liner; Cache-Control knob
   (comptime/flag/env + PRE_START global replace); embedded Range + Cache-Control; SPA-fallback
   `no-cache` via sendBody.
3. **PR3** — SigV4 generalization (default build, pure, vector-pinned, zero behavior change).
4. **PR4** — `-Ds3` gate + S3 backend + vtable rename + spool cache + MinIO CI job + stock-binary warning
   + examples/docs.

Each PR carries its fragment + docs sync; the Playwright suite runs locally before each merge.
