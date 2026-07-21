> 📖 This documentation is also published, web-native, at <https://valthon.github.io/zigbase/docs/email> — the site is the canonical reading experience.

# Email

`ctx.mail()` sends outbound application email from any route, hook, or job — the framework owns
address validation and header-injection rejection so a consumer never re-rolls them. Layered on
top is a transactional-mail subsystem: a small escaped-by-default template engine, first-class
SES/Postmark/SMTP providers, per-account verified senders, and bounce/complaint suppression. This
guide covers sending, templating, providers, background delivery, senders/suppression, and
asserting mail in tests.

## Send your first message

A `MailMessage` is `{ to, subject, text?, html?, reply_to? }` — supply `text`, `html`, or both (at
least one is required):

```zig
// Synchronous: build + deliver through the configured mailer right now.
try ctx.mail().send(.{
    .to       = "user@example.com",
    .subject  = "Welcome",
    .text     = "Thanks for signing up!",
    .html     = "<h1>Thanks for signing up!</h1>",
    .reply_to = "support@example.com",
});
```

When both `text` and `html` are present the message is built as `multipart/alternative`
(plain-text part first, HTML last) so capable clients render the HTML and the rest fall back to
text. Recipient (and `reply_to`) **address validation** and **CRLF / control-char
header-injection rejection** in `to` / `subject` / `reply_to` happen before any byte reaches a
backend or a queue row — errors are `error.InvalidAddress`, `error.HeaderInjection`,
`error.EmptyBody`.

## Templates

The transactional-mail core ships a small, safe renderer for building `text`/`html` bodies — no
arbitrary code, no loops/conditionals, just variable interpolation, named partials, and a shared
layout. Interpolation is **HTML-escaped by default** (`{{ name }}`); raw output is an explicit
opt-in (`{{{ name }}}`). `{{> partial }}` includes a named partial; `renderInLayout` wraps a body
in a layout (which references the child via `{{{ body }}}`). `renderHtml` escapes; `renderText`
does not (text/plain has no markup) — render both parts and pass them as `.html` / `.text`:

```zig
const tpl = zigbase.mail_template;
const html = try tpl.renderHtml(ctx.arena.a, "<p>Hi {{ name }}</p>", &.{ .{ .key = "name", .value = user_name } }, &.{});
```

This layer is **additive and off by default** — an app that only calls `ctx.mail().send` directly
with hand-built strings is unaffected.

## Providers

Two first-class HTTP-API backends implement the same `Mailer` vtable as SMTP, so call sites stay
provider-agnostic — select one via `App(.{ .mailer = MyMailerPlugin })`:

- `zigbase.SesMailer.init(region, access_key, secret_key, from)` — Amazon SES v2 `SendEmail`,
  AWS SigV4-signed.
- `zigbase.PostmarkMailer.init(server_token, from)` — Postmark `/email` API.

A message may set a per-message `from` (additive, `null` default) to override the backend's global
sender — the seam verified per-account senders ride on. For tests, `zigbase.CaptureMailer` records
messages in memory so you can assert subject/recipient/both body parts with no network.

## Deliver in the background

Hand a message to the queue instead of sending it inline — routed to the queue's backend
(durable, survives restart, or memory, in-process) and delivered by a worker via the built-in
`"mail"` job kind:

```zig
try ctx.mail().enqueue(.{ .to = "user@example.com", .subject = "Digest", .html = "<p>…</p>" }, .{ .queue = "emails" });
```

`enqueue` validates the message **up front**, so a malformed or injection-bearing message fails at
the call site rather than later inside a worker; it requires a wired queue (see the
[jobs & webhooks guide](./jobs-and-webhooks.md)). When no mailer is wired (CLI/tests), `send` logs
a fallback line instead of failing.

`enqueue` also requires mail to be configured — a `.mailer` plugin, or `.mail = .{}` to enable
background delivery with the default env-configured mailer. Without either, the `"mail"` job kind
is not compiled in and `enqueue` fails at call time with `error.UnknownJobKind`. `send` is
unaffected — it delivers directly through the mailer, not the queue.

## Senders & suppression

**Verified per-account sender identities.** Prove an account controls a From address before it may
send as it. **Enforcement engages only when you set `.mail.require_verified_sender = true`** —
this flag (and the suppression flag below) **default OFF**, so an existing simple-SMTP app never
starts rejecting mail on upgrade. Enforcement also only applies to account-scoped sends (`ctx.mail()`
attributes mail to the request's active account automatically); a system/superuser send (no
account) bypasses it.

```zig
const App = zigbase.App(.{
    .mailer = MyProviderPlugin, // SES / Postmark / SMTP
    .mail = .{
        .require_verified_sender = true, // tenant sends must use a verified From
        .check_suppression = true,       // block hard-bounced / complained recipients
        .webhook_secret = "…",           // enable the bounce/complaint webhook (signed relay)
    },
});
```

Routes (tenant-scoped, fail closed): `POST /api/senders` requests verification of a From address
(emails a single-use token); `POST /api/senders/:id/verify` confirms it; `GET /api/senders` lists
the active account's identities. A send whose From is not verified for the account is rejected
(`error.SenderNotVerified`); addresses compare case-insensitively.

**Bounce/complaint suppression.** `POST /api/mail/webhooks/:provider` (`ses` | `postmark`) ingests
delivery events behind an HMAC-SHA256 signature check; with no `.mail.webhook_secret` set the
route is disabled (`404`) — ingestion is opt-in. A hard bounce or complaint upserts a
`_suppressions` row. When `.mail.check_suppression = true`, a send to a suppressed recipient is
**blocked** (`error.RecipientSuppressed`).

> **Enforcement boundary.** Verified-sender + suppression checks are a policy of the `ctx.mail()`
> layer, not of the `Mailer.send` vtable seam — code that bypasses `ctx.mail()` and calls a
> backend directly skips them. Always send application mail through `ctx.mail()`.

## Test it

`zigbase.testcapture.mail` records every send through the same `Mailer.send` seam every backend
routes through, so tests assert mail with no network:

```zig
const tc = zigbase.testcapture;
tc.mail.enable(true);     // capture + SUPPRESS real delivery (deterministic e2e mode)
defer tc.mail.reset();    // clear + free

// ... trigger a flow that sends mail (signup verification, password reset, your route) ...

try expectEqual(@as(usize, 1), tc.mail.count());
const e = tc.mail.get(0).?;               // { from, to, subject, body }
try expectEqualStrings("user@example.com", e.to);
try expect(tc.mail.find("Verify") != null);
```

`mail.enable(suppress)`: `suppress = true` records and skips real delivery; `false` records **and**
still delivers. This is compiled in only on a `dev_mode` build (on in `Debug`, off in release), so
a production binary is unaffected.

> **`testcapture.mail` vs `CaptureMailer`.** These are two different things. `testcapture.mail` is
> the **framework-internal** outbox above — it captures the framework's own auth mail (and anything
> else sent through the wired mailer) for e2e tests, gated on a `dev_mode` build. `CaptureMailer`
> is a **consumer-owned** `Mailer` backend you plug in yourself via `App(.{ .mailer =
> CaptureMailer })` (or call its `mailer()` directly) to capture and assert your own application's
> mail with no network, independent of the `dev_mode` gate.

## Reference

- [ctx.mail()](./framework.md#ctxmail--send-application-mail)
- [Email subsystem](./framework.md#email-subsystem-154-templates-providers-verified-senders-suppression)
- [Verified senders & bounce webhook API](./api.md#email--verified-senders--bounce-webhook-154)
- [Test-mode capture](./framework.md#test-mode-capture--assert-sent-mail--mock-outbound-http-zigbasetestcapture)
