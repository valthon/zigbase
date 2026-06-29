### Features

- Email subsystem (#154): a transactional-mail core on top of `ctx.mail()`. A minimal, safe
  template engine (`mail/template.zig`) renders multipart HTML + plain-text from a typed data
  context — `{{ var }}` is HTML-escaped by default, raw output is an explicit `{{{ var }}}` opt-in,
  with named partials (`{{> name }}`) and a shared layout. No arbitrary code evaluation.
- First-class HTTP-API mail providers behind the existing `Mailer` vtable: **Amazon SES**
  (`SesMailer`, SESv2 `SendEmail` with AWS SigV4 signing) and **Postmark** (`PostmarkMailer`).
  Select them via `App(.{ .mailer = … })`, swapping providers without touching call sites. SMTP /
  Command backends are unchanged.
- A per-message `From` override (`mail.Email.from` / `MailMessage.from`, additive `null` default)
  honored by every backend, so a tenant can send as its own verified address rather than the app's
  global From.
- `CaptureMailer` — an in-memory `Mailer` backend for tests: assert outbound mail (subject,
  recipient, both body parts) with no SMTP server and no network. Plus a dev `renderPreview` that
  produces a self-describing HTML preview of one message.
- Verified per-account **sender identities** (`_sender_identities`, migration `0016_email`): request
  verification of a From address (`POST /api/senders`, which emails a single-use token), confirm it
  (`POST /api/senders/:id/verify`), and list (`GET /api/senders`). All routes are tenant-scoped and
  fail closed — a member can only manage its own account's senders.
- Bounce/complaint **suppression** (`_suppressions`, same migration) with an inbound webhook
  (`POST /api/mail/webhooks/:provider`, SES + Postmark payload shapes) that upserts a suppression on
  a hard bounce or complaint.
- `ctx.mail().deliverLater(msg, .{ .queue = "…" })` reads as the async transactional-send entry
  point (an alias of `enqueue`). `ctx.mail()` now attributes mail to the request's active account
  scope automatically, which is the engagement point for the new enforcement.
- New `.mail` framework config key: `App(.{ .mail = .{ .require_verified_sender = true,
  .check_suppression = true, .webhook_secret = "…" } })`. All toggles default OFF — an app that only
  calls the existing mailer is completely unaffected.
- Deferred to 0.9.x fast-follows (not in this release): bulk/throttled personalized list sends;
  scheduled/sequenced (drip) sends; CSS-inlining + inline-image hosting; one-click unsubscribe /
  list management. The send job + suppression + verified-sender checks are the seams those build on.

### Security

- Send-time enforcement is fail closed, and the engagement point is explicit (so existing simple
  SMTP apps never suddenly start rejecting): verified-sender enforcement engages only with
  `.mail.require_verified_sender = true` AND an account-scoped send — a tenant send whose From is not
  a verified `_sender_identities` row for the account is REJECTED; a system/superuser send (no
  account) bypasses. Suppression blocking engages only with `.mail.check_suppression = true` — a send
  to a hard-bounced/complained recipient is BLOCKED.
- The inbound bounce/complaint webhook verifies a shared-secret HMAC-SHA256 signature with a
  CONSTANT-TIME compare; the signed string binds the timestamp, provider, AND the target account
  (`X-Account-Id`) plus the body, so a captured event cannot be redirected to another tenant. A
  ±5-minute timestamp-freshness window rejects replays, and a wrong/missing/stale request is rejected
  (401). With no `webhook_secret` configured the route is disabled (404) — ingestion is strictly
  opt-in. NOTE: a genuine provider webhook cannot sign/scope itself, so it is GLOBAL-only;
  per-account scoping requires an operator-run signing relay (documented).
- Email addresses are normalized (lowercased) for suppression and verified-sender identity, so a
  suppression on `bad@x.io` also blocks `Bad@X.IO` (no case-based fail-open) and a verified
  `From@Acct.com` matches a send from `from@acct.com`.
- Sender-verification emails are rate-limited per `(account, email)` (a re-request within ~60s
  returns 429), preventing an authenticated member from amplifying mail at an arbitrary recipient.
  The verification token is matched in constant time, and the multipart MIME boundary is now random
  (not timestamp-derived) so it cannot be guessed to forge a MIME part.
- The HTTP providers CRLF/ASCII-control-char-reject every header-bound value (from/to/subject/
  reply_to) before it enters the provider JSON body, and SES requests are SigV4-signed over the exact
  payload bytes. Sender-identity verification and suppression are tenant-scoped and parameter-bound
  (no cross-account verification; no SQL interpolation of recipient addresses). Verified-sender +
  suppression enforcement is a `ctx.mail()`-layer policy (not a `Mailer.send` vtable guarantee).
