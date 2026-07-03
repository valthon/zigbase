### Features
- Opt-in S3-compatible storage backend (`-Ds3` build flag; AWS S3, MinIO, Cloudflare R2), selected by configuration alone — set `ZIGBASE_S3_*` env vars on an `-Ds3` binary, no code change. Downloads are served through a local spool cache, so Range/ETag/tenancy behavior is byte-identical to local storage. A stock binary with `ZIGBASE_S3_BUCKET` set warns loudly and falls back to local storage. Startup runs a fail-fast HeadObject probe (DNS/TLS/SigV4/bucket/permissions verified before serving).

### Breaking
- Storage plugin vtable: `localPath(ctx, alloc, col, record_id, filename)` is now `fetch(ctx, io, alloc, col, record_id, filename)` — return a local filesystem path whose contents are the file, **materializing it locally if necessary**; `null` = the backend has no such object. Local-disk backends migrate mechanically (rename + the `io` parameter).

### Fixes
- Outbound HTTP client (`http_client.zig`, shared by S3, webhooks, OAuth2, and CAPTCHA verification): a response DEFINED to carry no body (a `HEAD` response, any `1xx`, `204 No Content`, or `304 Not Modified`) was still read as if it might have one, using whatever `Content-Length` it happened to arrive with — or, absent that, "read until the connection closes." Real S3 servers don't close keep-alive connections, so every S3 `DELETE` (always `204`, no `Content-Length`) and every `HEAD` on an existing key blocked for ~30 seconds (an unrelated idle-connection timeout eventually unblocking it) before this was caught by the new live MinIO tests.

### Internal
- New `s3` CI job: MinIO via `docker run` + gated live Zig tests + a raw-HTTP upload→Range→delete e2e (`tests/s3/`).
