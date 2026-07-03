### Features

- Bulk list sends: `ctx.mail().sendBulk(...)` fans one templated message out as per-recipient-rendered emails over the durable queue, with submit-time validation/dedup, per-recipient suppression checks, idempotent redelivery, and a durable send-report (`_mail_batches` / `_mail_batch_recipients`, readable as superuser via the records API) plus `batchStatus` / `cancelBatch`.
- Scheduled sends: `ctx.mail().deliverAt(msg, .{ .at | .delay_s })` returns a cancellable job id, `ctx.mail().cancel(id)` calls a pending send off, and `sendBulk` accepts `.at` — the documented drip-sequence primitives.
- One-click unsubscribe (RFC 8058): configure `.mail.unsubscribe_base_url` (or `ZIGBASE_UNSUBSCRIBE_BASE_URL`) and bulk mail automatically carries `List-Unsubscribe` / `List-Unsubscribe-Post` headers pointing at the new signed public `POST/GET /api/mail/unsubscribe` endpoint; one-click opt-outs are recorded as `unsubscribe` suppressions that block list mail only (transactional mail is unaffected).
- Per-queue rate throttling: durable queues accept `.rate = .{ .per_second = N }` — a token-bucket ceiling enforced at claim time (e.g. match SES's 14 msg/s).
- `ctx.mail()` warns when an HTML body exceeds ~100 KB (Gmail clipping threshold).

### Changed

- `Email` / `MailMessage` gained an additive `list_unsubscribe` field (default `null`; CRLF-checked like every header field) emitted as RFC 8058 headers by all backends (SMTP/Command/SES/Postmark).
- `durable.enqueue` now returns the generated job id, and the queue GC reaps `canceled` jobs (internal signature change, pre-1.0).
- `CaptureMailer` records `reply_to`/`list_unsubscribe` and gained `all()` / `countTo()` accessors.

### Fixes

- `_suppressions` gained the `updated` column the records engine's base-column SELECT requires, so superusers can actually browse it via the records API (migration `0019_bulk_mail`).
