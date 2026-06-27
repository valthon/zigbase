# Test-mode capture for outbound mail + HTTP (Theme C follow-up, #96)

## Goal

For deterministic e2e/integration testing, give tests a way to assert what the
framework *sent* — outbound mail and outbound `ctx.http()` calls — and to inject
canned HTTP responses instead of hitting the network. The whole facility is
**DEV-GATED at comptime** so a production binary is byte-for-byte unaffected: no
runtime branch, no perf cost, the capture code folds away.

This pairs with the determinism seam (`src/clock.zig`, `ZIGBASE_FAKE_NOW`): same
gate, same "compiled out in release" contract.

## The gate

Reuse the existing `build_options.dev_clock` comptime flag (on in `Debug`, off in
any release build / shipped binary — see `build.zig` and `src/clock.zig`). A new
module `src/testcapture.zig` exposes:

```zig
pub const enabled = build_options.dev_clock;
```

Every call site that touches capture is wrapped in `if (testcapture.enabled) { … }`.
Because `enabled` is `comptime false` in a release build, the whole block is
comptime-dead and dead-code-eliminated — exactly like the clock override.

## Seam 1 — Mail outbox

`Mailer.send` (in `src/mail/mailer.zig`) is the single chokepoint every backend
(Log / SMTP / Command / a consumer plugin) routes through — they are all invoked
via the vtable wrapper `Mailer.send`. We hook there:

```zig
pub fn send(self: Mailer, io, alloc, email) anyerror!void {
    if (testcapture.enabled) {
        testcapture.mail.record(self.from, email.to, email.subject, email.text_body);
        if (testcapture.mail.suppressed()) return; // skip real delivery in capture mode
    }
    return self.vtable.send(self.ptr, io, alloc, email);
}
```

To capture the **from** address (which lives on the backend config, not on
`Email`), we add an additive `from: []const u8 = ""` field to the `Mailer` struct,
populated by each backend's `mailer()` helper (`SmtpMailer`/`CommandMailer` pass
their configured `from`; `LogMailer` leaves it `""`). This is non-breaking — the
field defaults to `""`, so existing consumer plugins compile unchanged.

### Capture-vs-deliver semantics

Capture is **opt-in** even on a dev build: `testcapture.mail.enable(suppress)`.
- `suppress = true` → record the email and **skip** real delivery (no SMTP / no
  log line). This is the normal e2e mode: deterministic, no side effects.
- `suppress = false` → record **and** still deliver (useful to assert against a
  real MailHog/log run).

When capture is not enabled, `record`/`suppressed` are no-ops and delivery is
exactly as today.

### Test-facing API

```zig
testcapture.mail.enable(suppress: bool);   // start capturing
testcapture.mail.disable();                 // stop capturing (keep entries)
testcapture.mail.reset();                   // clear entries + disable + free
testcapture.mail.count() usize;
testcapture.mail.get(i) ?MailEntry;         // { from, to, subject, body }
testcapture.mail.entries() []const MailEntry;
testcapture.mail.find(subject_substr) ?MailEntry;
```

## Seam 2 — HTTP capture / mock

`ctx.http()` returns an `HttpClient` whose `request()` (in `src/http_client.zig`)
drives `std.http.Client` directly. Mirroring the oauth `Transport` injection
(`src/oauth/client.zig`), we intercept at the top of `request()`:

```zig
pub fn request(self, opts) !HttpResponse {
    if (testcapture.enabled) {
        switch (try testcapture.http.intercept(self.alloc, opts)) {
            .passthrough => {},                  // not capturing → real network
            .response => |r| return r,           // canned response (recorded)
            .blocked => return error.TransportFailed, // unmocked + block-unmocked
        }
    }
    … real network …
}
```

`intercept`:
1. If capture not enabled → `.passthrough` (real network, nothing recorded).
2. Record the request (method/url/headers/body) into the capture arena.
3. Find a mock whose `url_substring` matches `opts.url`; if found, **dupe** its
   status/headers/body onto the **caller's** allocator (`self.alloc`, the Ctx
   arena) and return `.response` — same lifetime as a real response, **no
   network**.
4. No mock match → `.blocked` if `block_unmocked` (the default, so a test can't
   silently hit the network), else `.passthrough` (real network).

### Test-facing API

```zig
testcapture.http.enable(block_unmocked: bool); // start capturing
testcapture.http.disable();
testcapture.http.reset();                       // clear requests + mocks + free
testcapture.http.mock(url_substring, MockResponse); // { status, headers, body }
testcapture.http.requestCount() usize;
testcapture.http.requestAt(i) ?HttpRequest;     // { method, url, headers, body }
testcapture.http.requests() []const HttpRequest;
```

## Memory model

Both seams keep a process-global, mutex-guarded store backed by a lazily-created
`ArenaAllocator` over `std.heap.page_allocator` (not `std.testing.allocator`, so
nothing trips leak detection across tests). `record`/`mock` dupe their inputs into
that arena; `reset()` deinits the arena and re-empties the lists. HTTP mock
**responses** are duped onto the *caller's* allocator at return time, so they
share the normal response lifetime (the Ctx arena) and never dangle.

## Production gate — hard contract

- `testcapture.enabled == comptime false` in any release build.
- Every public fn early-returns when `!enabled`; every call site is wrapped in
  `if (testcapture.enabled)`, so the branch folds to nothing.
- Verified by a `-Ddev-clock=false` test: with the gate off, `mail.enable`/
  `http.mock` are no-ops, captures stay empty, and a send/`http` call behaves
  exactly as without the facility.

## Testing plan (TDD)

1. Mail: enable(suppress) → `Mailer.send` records to/subject/body, real delivery
   skipped; assert via `mail.get`. With `LogMailer`, suppressed send produces no
   log; non-suppressed still delivers.
2. HTTP: `http.mock("example.com", …)` → `HttpClient.request` returns the canned
   response with **no** loopback server, and the request is recorded.
3. HTTP block: unmocked URL with `block_unmocked` → `error.TransportFailed`, no
   network.
4. Prod gate (`-Ddev-clock=false`): `enabled == false`, captures stay empty.
```
