### Features

- `ctx.mail()` — send outbound application mail from any route, hook, or job.
  `ctx.mail().send(.{ .to = …, .subject = …, .text = …, .html = …, .reply_to = … })`
  delivers synchronously through the configured mailer, and
  `ctx.mail().enqueue(msg, .{ .queue = "…" })` hands it to the background queue (the
  built-in `"mail"` job kind) for durable/memory delivery. A message carries an optional
  HTML alternative and `reply_to`; when both `text` and `html` are set the message is
  built as `multipart/alternative`.
- `mail.Email` gains optional `html_body` and `reply_to` fields (additive, `null`
  defaults — existing `Mailer` implementations and `Email` literals compile unchanged).
  `buildMessage` now emits a `text/html` part or a `multipart/alternative` body when an
  HTML alternative is present, so HTML mail works across every backend (SMTP / Command /
  custom plugins).
- Consumer mail is assertable in tests exactly like the framework's own auth mail: both
  `send` and the enqueued `"mail"` job route through the one `Mailer.send` vtable seam that
  feeds the dev-only `testcapture.mail` outbox.

### Security

- The framework owns email header safety for `ctx.mail()`: recipient/`reply_to` address
  validation and CRLF / ASCII-control-char rejection in `to`, `subject`, and `reply_to`
  happen in the framework (`mail/send.zig`) before any byte reaches a backend or a durable
  queue row — consumers neither have to nor should re-roll header-injection defenses.
  `enqueue` validates up front, so a malformed or injection-bearing message fails at the
  call site rather than later inside a worker.
