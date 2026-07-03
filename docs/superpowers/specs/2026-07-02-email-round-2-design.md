# SP3 Theme E — Email round 2 (#154 remainder)

**Baseline:** origin/main @ `1bd02c4`. Builds on the shipped #154 core: `ctx.mail()`
(`src/mail/send.zig`, `src/ctx.zig` `MailApi`), the `Mailer` vtable + SES/Postmark/SMTP/Capture
backends, `mail_template`, verified senders (`_sender_identities`), bounce/complaint suppression
(`_suppressions`), and the queue engine (`src/queue/{queue,durable,memory}.zig`, migration
`0013_queue_jobs`, worker poller wired in `framework.zig` at ~500ms scheduler ticks).

This theme is the documented "planned 0.9.x fast-follows" paragraph in `docs/framework.md`
(~line 678): bulk/throttled personalized list sends; scheduled/drip sends; one-click
unsubscribe / list management; CSS-inlining + inline images.

## Goal

Ship the list-sending layer of #154 on the existing seams, keeping every new behavior
additive and default-off:

1. **Bulk sends** — `ctx.mail().sendBulk(...)`: one templated message fanned out to N
   recipients as individual, per-recipient-rendered emails, riding the durable queue with
   per-queue rate throttling, per-recipient suppression checks, idempotent redelivery, and a
   durable per-recipient send-report.
2. **Scheduled sends** — expose the `run_at` primitive the durable queue already has
   (`durable.enqueue(..., run_at)` exists; `ctx.enqueueByName` currently hardcodes `now`):
   `deliverAt` + `cancel`, and `.at` on bulk sends. Drip = the documented pattern
   (schedule steps, cancel on conversion), **not** campaign machinery (see Non-goals).
3. **One-click unsubscribe** — RFC 8058 `List-Unsubscribe` / `List-Unsubscribe-Post` headers,
   a public signed-token endpoint, writing into the existing `_suppressions` store with a new
   `unsubscribe` reason that blocks **list** mail only (transactional mail unaffected).
4. **Deliverability hygiene (right-sized)** — a Gmail-clipping size warning on oversized HTML;
   CSS inlining and `cid:` inline-image attachments are explicit deferrals (rationale below).

Standing constraints honored throughout: CRLF/header-injection defense stays in
`mail/send.zig`/`mailer.buildMessage` (framework-owned); `require_verified_sender` /
`check_suppression` stay default-off; tenancy: every bulk artifact carries `account` and
enforcement is account-scoped exactly like `send()` today; CaptureMailer asserts everything
without network; queue at-least-once ⇒ per-recipient dedup is designed in, not hoped for.

## Non-goals (explicit cuts)

- **CSS inlining — DEFERRED.** A correct `<style>`-block → `style=""` inliner needs an HTML
  parser, a CSS selector engine, specificity/cascade resolution, and at-rule handling. A
  "minimal declaration-inliner" was evaluated and rejected: anything less than real selector
  matching silently produces wrong styling in exactly the clients (Outlook, Gmail) the feature
  exists for — a footgun shipped as a feature. Inlining is a *build-time* concern; the docs
  will say so: author templates with inline styles, or run MJML/juice/premailer in the
  consumer's asset pipeline and paste the output into `mail_template` sources (interpolation
  syntax passes through untouched). Revisit only if a vendored C inliner appears worth it.
- **`cid:` inline-image attachments — OUT.** Requires `multipart/related` + base64 attachment
  encoding in `buildMessage`, Postmark `Attachments[].ContentID` mapping, and — the real cost —
  rewriting `SesMailer` from SES v2 *Simple* content to *Raw* MIME. Hosted images
  (`https://` URLs served from the app's existing file storage / static assets) are the 90%
  answer, work in every client, and keep messages under clipping limits. Documented pattern.
- **Full drip-campaign machinery — DEFERRED.** Sequence definitions, step state machines, exit
  conditions, re-entry rules, and per-step analytics are campaign software. The honest 90% cut
  is `deliverAt` + `cancel`: schedule the steps up front, persist the returned job ids on your
  own record, cancel the pending ones when the user converts. This is a documented recipe, not
  a framework object.
- **Per-list suppression granularity.** An unsubscribe suppresses *all list mail from that
  account* to the address. The list name is recorded for audit, not enforced per-list.
  Per-list preference centers are app-level UX; the framework guarantees the compliance floor.
- **Campaign analytics / opens / clicks / admin-UI mail dashboard.** The send-report tables are
  readable via the existing records API (superuser) — no new UI.
- **Multi-process rate coordination.** The scheduler/worker system is single-process
  (documented); the token bucket is in-memory per process, which is therefore authoritative.

## Default-build impact

**Default-on, extending already-default subsystems — not a new opt-in surface.** `ctx.mail()`,
the queue engine (`src/queue/{queue,durable,memory}.zig`), and `mail_send`/`mail_template` are
already compiled into every binary; nothing in this theme is behind a build flag, and nothing here
introduces one. What's genuinely new in the default binary:

- **Two new system tables** (migration `0019_bulk_mail`: `_mail_batches`,
  `_mail_batch_recipients`, plus one unique + one secondary index) — schema-only, zero runtime cost
  until `sendBulk` is called. Comparable in weight to the `0016_email`/`0013_queue_jobs` tables
  the #154 core already ships unconditionally.
- **One new public route + file**: `POST`/`GET /api/mail/unsubscribe` (`src/api/mail_unsubscribe.zig`).
  The route is live in every binary, but is a **404 unless `unsubscribe_base_url` is configured**
  (the same default-off-compatible pattern as `webhook_secret`) — so an app that never sets the
  option pays only the route-table entry and the 404 branch, not a live attack surface.
- **One new in-memory rate-limiter structure**: a process-global, mutex-guarded token bucket per
  queue name, allocated lazily only for queues that set `.rate` in their `QueueDef` — zero cost
  for the common unrated-queue case, and the struct itself is small (one counter + one timestamp
  per rated queue name, not per job).
- **Two new small files** (`src/mail/bulk.zig`, `src/mail/unsubscribe.zig`) plus the
  `mail_batch_item` job-kind handler registered beside the existing `"mail"` kind — code-size
  delta comparable to any other framework-owned handler, not a vendored dependency.

**Why comptime-gating would fragment a core subsystem (and isn't worth it here).** Mail and the
durable queue are not optional add-ons in this codebase's model — every consumer that configures a
`Mailer` already links the full mail stack, and every app using durable queues already links
`durable.zig`. Bulk sends are *the same send path* (`mail_send.send()`) fanned out through *the
same queue engine* with a couple of new system tables; there is no natural seam that would let
`-Dbulk-mail=false` remove meaningful code without also splitting `ctx.mail()` itself into two
APIs (plain `send` vs. `sendBulk`) that consumers would have to reason about choosing between at
build time. That's the opposite of "lean" — it's a fork in a subsystem consumers already opted
into via `.mailer`. Compare to genuinely alternative-choice capabilities (Postgres vs. SQLite
backend, SSE vs. WS transport) where comptime-gating avoids compiling in a whole competing
implementation: bulk/scheduling/unsubscribe are not alternatives to anything, they're the next
increment of the one mail path every mail-using consumer already has. **Recommended: default-on**,
consistent with how `0013_queue_jobs`/`0016_email` themselves shipped default-on in #154.

## Facil.io-first check

**None of these items replace a facil.io capability.** Bulk sends ride the existing durable queue
(SQLite/Postgres-backed, framework-owned, no facil.io involvement); scheduling reuses
`_queue_jobs.run_at` (already-indexed SQL, not a timer facility facil.io provides); the
rate-limiter token bucket is in-process Zig state, not a networking primitive; the unsubscribe
endpoint rides the existing router (`router.zig`) and HTTP response path, which already sits on
facil.io/zap — no new facil.io feature is touched, replaced, or reimplemented.

---

## 1. Bulk / throttled personalized list sends

### Data model — migration `0019_bulk_mail`

Two system tables (+ `_collections` seed rows with NULL rules = Locked, mirroring `0016_email`,
so superusers get list/read via the records API for free — that *is* the send-report UI):

```sql
CREATE TABLE "_mail_batches" (
  "id" TEXT PRIMARY KEY, "created" TEXT NOT NULL,
  "account"  TEXT NOT NULL DEFAULT '',   -- tenancy scope; '' = system send
  "list"     TEXT NOT NULL DEFAULT '',   -- list name (unsubscribe scoping/audit)
  "queue"    TEXT NOT NULL,              -- queue the item jobs ride
  "from_addr" TEXT NOT NULL DEFAULT '', "reply_to" TEXT NOT NULL DEFAULT '',
  "subject_tpl" TEXT NOT NULL, "text_tpl" TEXT NOT NULL DEFAULT '', "html_tpl" TEXT NOT NULL DEFAULT '',
  "total" INTEGER NOT NULL, "status" TEXT NOT NULL DEFAULT 'active'  -- active|canceled
);
CREATE TABLE "_mail_batch_recipients" (
  "id" TEXT PRIMARY KEY, "created" TEXT NOT NULL,
  "batch" TEXT NOT NULL, "email" TEXT NOT NULL,
  "vars_json" TEXT NOT NULL DEFAULT '{}',
  "status" TEXT NOT NULL DEFAULT 'pending', -- pending|sent|suppressed|invalid|failed|canceled
  "attempts" INTEGER NOT NULL DEFAULT 0, "last_error" TEXT NOT NULL DEFAULT '',
  "sent_at" TEXT NOT NULL DEFAULT ''
);
CREATE UNIQUE INDEX "idx_mail_batch_rcpt_unique" ON "_mail_batch_recipients"("batch","email");
CREATE INDEX "idx_mail_batch_rcpt_status" ON "_mail_batch_recipients"("batch","status");
```

The UNIQUE `(batch,email)` is both duplicate-recipient dedup at submit time (`INSERT OR
IGNORE`) and the idempotency record for at-least-once delivery.

### API shape (`ctx.mail()`)

```zig
pub const BulkRecipient = struct { to: []const u8, vars: []const mail_template.Var = &.{} };
pub const BulkSend = struct {
    subject: []const u8,                 // template source, rendered per recipient (renderText)
    text: ?[]const u8 = null,            // template sources; >=1 of text/html required
    html: ?[]const u8 = null,
    from: ?[]const u8 = null, reply_to: ?[]const u8 = null,
    recipients: []const BulkRecipient,   // non-empty
    list: []const u8 = "",               // enables List-Unsubscribe when unsubscribe is configured
    queue: []const u8 = "default",       // MUST be a durable queue (error.BulkRequiresDurable)
    at: ?i64 = null,                     // unix seconds; earliest delivery (default: now)
};

pub fn sendBulk(self: MailApi, b: BulkSend) ![]const u8      // returns batch id (arena)
pub fn cancelBatch(self: MailApi, batch_id: []const u8) !usize // # of pending recipients canceled
pub const BatchReport = struct { total: u32, pending: u32, sent: u32, suppressed: u32,
                                 invalid: u32, failed: u32, canceled: u32 };
pub fn batchStatus(self: MailApi, batch_id: []const u8) !BatchReport
```

`sendBulk` (in `src/mail/bulk.zig`, new file — **add to `root.zig`'s test block**):
1. Validates up front, fail-fast at the call site: every recipient address
   (`send.validateAddress`), CRLF checks on subject/from/reply_to/list templates *sources*,
   `EmptyBody`, non-empty recipients, queue exists + durable. Template render errors per
   recipient are a delivery-time concern (vars differ), not a submit-time one.
2. Applies `withScope` account attribution (same as `send`); when `require_verified_sender`
   is on and the batch is account-scoped, asserts the verified From **once** at submit
   (delivery re-checks via `send()` anyway — fail-closed twice, cheap).
3. In one writer acquisition: inserts the batch row + all recipient rows (`INSERT OR IGNORE`;
   duplicates collapse), then enqueues **one `"mail_batch_item"` durable job per distinct
   recipient** with payload `{"batch":"...","to":"..."}` and `run_at = b.at orelse now`.
   Small constant payload — template lives once on the batch row. N jobs (not one driver job)
   buys per-recipient retry/backoff, priority ordering, visibility-timeout crash recovery, and
   rate throttling from the existing engine with zero new machinery.

### The `"mail_batch_item"` job handler (idempotent per recipient)

Registered in `framework.zig` beside the `"mail"` kind. Steps:
1. Load recipient row + batch row. Row status not `pending` (or batch `canceled`) → **return
   success** — this is the at-least-once dedup: a redelivered/reclaimed job is a no-op.
2. Render `subject/text/html` templates with the row's vars (HTML-escaped by default via
   `mail_template.renderHtml`; subject/text via `renderText`). Render or validation error →
   status `invalid` + `last_error`, return success (retrying a hopeless render burns the queue).
3. Suppression check via `assertNotSuppressed(..., .list)` (see §3 — includes `unsubscribe`
   rows). Suppressed → status `suppressed`, return success (a suppressed recipient is a
   *reported outcome*, not a job failure).
4. Deliver via `mail_send.send()` (inherits verified-sender enforcement, CRLF backstop,
   CaptureMailer seam, and the List-Unsubscribe header from §3). On success: status `sent`,
   `sent_at`, then return (crash between backend-accept and the row update ⇒ one duplicate
   send on redelivery — standard at-least-once; identical to today's `"mail"` job; documented).
5. On backend error: bump row `attempts` + `last_error`; if `attempts >= queue.retry.max_attempts`
   set status `failed`; return the error so the queue applies its normal backoff/terminal policy.
   (The handler reads the queue's `RetryPolicy` from the registry via the batch row's queue
   name — no `JobHandler` signature change.)

`cancelBatch`: one writer txn — batch status `canceled`, recipient rows
`pending → canceled`, and `UPDATE "_queue_jobs" SET status='canceled' WHERE kind='mail_batch_item'
AND status='pending' AND payload LIKE '{"batch":"<id>"%'` is avoided (payload matching is
fragile); instead the handler's step-1 batch-canceled check makes stray jobs no-ops, and
claimed-mid-cancel jobs finish or no-op. Jobs for canceled batches drain as instant successes.

### Rate throttling — queue config, not magic

Provider ceilings are real: SES default is 14 msg/s (sandbox 1/s; quota-raised accounts
higher); Postmark enforces API rate limits and recommends ≤500/batch. Since an app routes a
provider's mail onto a queue, the throttle is a **`QueueDef` knob**:

```zig
pub const Rate = struct { per_second: u16 };       // sustained ceiling; burst = 1s of tokens
// QueueDef gains: rate: ?Rate = null               // null = today's unthrottled behavior
.queues = .{ .ses_mail = .{ .backend = .durable, .rate = .{ .per_second = 14 } } },
```

Enforcement in `durable.pollOnce`: worker queues are partitioned into unrated (claimed
together via the existing multi-queue `claimBatch`, unchanged) and rated (claimed
per-queue with `limit = min(worker.concurrency_remaining, tokens(queue))`). Tokens come from a
process-global, mutex-guarded token bucket per queue name (capacity `per_second`, continuous
refill from a monotonic clock) — shared across workers draining the same queue, correct
because the scheduler is single-process. Unclaimed jobs simply wait for the next ~500ms tick;
no sleeping in the worker, no per-job pacing. Memory queues ignore `rate`
(`@compileError` at config lowering: rate requires `.backend = .durable`).

---

## 2. Scheduled sends + drip

The storage primitive exists: `_queue_jobs.run_at` gates `claimBatch`
(`"run_at" <= now`, indexed). Only the enqueue surface pins it to `now`. Changes:

```zig
// MailApi.EnqueueOpts gains scheduling (mail-scoped; generic ctx.enqueue untouched):
pub const EnqueueOpts = struct {
    queue: []const u8 = "default",
    at: ?i64 = null,          // unix seconds; requires a durable queue
    delay_s: ?u32 = null,     // convenience; at and delay_s together = error.ConflictingSchedule
};
pub fn deliverAt(self: MailApi, msg: Message, opts: EnqueueOpts) ![]const u8  // returns job id
pub fn cancel(self: MailApi, job_id: []const u8) !bool                        // canceled?
```

- `durable.enqueue` changes to **return the generated job id** (internal signature change;
  pre-1.0 fine). `enqueueByName` grows an internal `run_at` parameter (existing callers pass
  `now`). A schedule on a memory queue is `error.ScheduleRequiresDurable` at the call site —
  honest, since a memory job can't survive restart to a future time.
- `deliverLater` keeps its void-return shape and now honors `opts.at`/`delay_s` too
  (it forwards to `deliverAt` and drops the id).
- `cancel`: `UPDATE "_queue_jobs" SET status='canceled' WHERE id=?1 AND status='pending'` —
  returns `changes() > 0`... **no**: per the SQLite-triggers memory, detect no-match as
  `changes() == 0`. A claimed/done/failed job returns `false` (it ran or is running).
  `claimBatch` only claims `'pending'` so no claim-path change; `gcDoneJobs` adds `'canceled'`
  to its status set so canceled rows age out.
- **Drip = documented recipe** (framework.md section "Drip sequences"): on trigger, call
  `deliverAt` per step, store the returned ids on your own record (or `_kv`), `cancel` the
  rest on conversion. Cron + a query is the escape hatch for dynamic sequences. No sequence
  tables, no step state machine (see Non-goals).

---

## 3. One-click unsubscribe / list management

### Token (signed, stateless, non-oracle)

`src/mail/unsubscribe.zig` (new; add to `root.zig` test block). Token =
`base64url(payload) ~ "." ~ base64url(HMAC-SHA256(key, payload))` where payload is
`"v1\x00" ++ account ++ "\x00" ++ list ++ "\x00" ++ recipient` (NUL-delimited — the fields are
already CRLF/NUL-rejected upstream, so unambiguous). Key = `HMAC-SHA256(jwt_secret,
"zigbase.mail.unsub.v1")` — a labeled derivation of the already-persisted app secret; **no new
secret to configure**. No expiry: unsubscribe links must keep working in old inboxes, and the
worst-case "attack" is unsubscribing an address the attacker already possesses the mail of.
Verification: length-checked decode, **constant-time** MAC compare (same discipline as the
webhook HMAC).

### Config + headers

`MailConfig.Runtime` gains `unsubscribe_base_url: []const u8 = ""` — empty (default) means the
whole feature is off: no headers emitted, endpoint 404s (exactly the `webhook_secret` opt-in
pattern; default-off compatible). Validated at startup: `http(s)://`, no control chars.

`Email` gains an additive field `list_unsubscribe: ?[]const u8 = null` (the URL). It is
deliberately **not** a generic headers array — one vetted field keeps the injection surface
closed. Emission:
- `buildMessage` (SMTP/Command/Log/Capture): emits `List-Unsubscribe: <URL>` and
  `List-Unsubscribe-Post: List-Unsubscribe=One-Click` (RFC 8058), after `rejectControlChars`.
- `SesMailer`: map both headers via the `Headers` array on the SES v2 `Simple` content object
  (supported since 2023 — no switch to Raw MIME needed; do not use `ListManagementOptions`,
  which ties unsubscribe to SES's own contact lists rather than our endpoint).
- `PostmarkMailer`: `Headers: [{Name, Value}, ...]` on the `/email` payload.

The bulk item handler sets `list_unsubscribe` automatically when `unsubscribe_base_url` is
configured (URL = `<base>/api/mail/unsubscribe?t=<token(account,list,to)>`; emitted even when
`b.list == ""` — the token just carries an empty list). Plain `send()` never sets it
(transactional mail must not carry unsubscribe headers). Escape hatch: `unsubscribeUrl(account,
list, recipient) ![]const u8` on `MailApi` for consumers hand-rolling list mail.

### Endpoint (public, unauthenticated, non-oracle)

`router.zig` + `src/api/mail_unsubscribe.zig`:
- `POST /api/mail/unsubscribe?t=<token>` — the RFC 8058 one-click target (mail providers POST
  `List-Unsubscribe=One-Click` form bodies). Valid signature → upsert `_suppressions`
  (`reason='unsubscribe'`, `source='one_click:' ++ list`) and return `200 {}` — **also 200 when
  the row already existed** (no oracle for "was this address known"). Invalid/malformed token →
  generic `400 {"error":"invalid token"}`; never distinguishes bad-MAC from unknown-account.
- `GET /api/mail/unsubscribe?t=<token>` — human click: renders a minimal embedded confirmation
  page with a POST button. **GET never mutates** (link prefetchers/scanners must not
  unsubscribe people).
- Rate-limited by IP via the existing `RateLimiter` (`allowCustom`, e.g. 30/min) — bounds
  token-forgery grinding and suppression-row spam.
- 404 when `unsubscribe_base_url` is unset (feature off).

### Suppression semantics (per-list vs global — the lean call)

Decision: **account-global for list mail, invisible to transactional mail.**
- `_suppressions` gets the new `reason` value `unsubscribe` (no schema change; the list is
  recorded inside `source` for audit — no new column, no UNIQUE churn).
- `assertNotSuppressed` / `isSuppressed` gain a `kind: enum { transactional, list }` parameter.
  `transactional` (plain `send()`/`deliverLater`) ignores `reason='unsubscribe'` rows — a user
  who opts out of the newsletter **must still get password resets** (and RFC 8058 one-click is
  a list-mail mechanism, not a transactional block). `list` (the bulk handler) honors all
  reasons. Bounce/complaint rows block both kinds, as today.
- Enforcement of the `unsubscribe` reason for list sends is **always on for bulk** (not gated
  by `check_suppression`): sending list mail past a one-click unsubscribe is a compliance
  violation, not a tuning knob. `check_suppression` keeps gating bounce/complaint blocking of
  transactional mail exactly as today — default-off compatibility holds because bulk itself
  is new surface.

---

## 4. Deliverability hygiene (the in-scope sliver)

- `mail_send.send` logs one `std.log.warn` when `html` exceeds 100 KB ("Gmail clips ~102KB;
  message may be truncated…"). Warning, never an error.
- framework.md gains a short "HTML that renders everywhere" note: inline your styles (or run a
  build-time inliner like juice/premailer over your template sources), host images at absolute
  HTTPS URLs (the app's file storage/static assets work), keep HTML under ~100 KB. This is the
  documented substitute for the two deferred items.

## CaptureMailer / testcapture

- `Captured` gains `reply_to: ?[]u8`, `list_unsubscribe: ?[]u8` (recorded from the new `Email`
  field); `record` copies them.
- New accessors: `all(self) []const Captured` and `countTo(self, addr) usize` — bulk tests
  assert N distinct personalized messages, per-recipient rendered bodies, and header presence
  with zero network. Bulk/scheduled/unsubscribe mail all route through the same `Mailer.send`
  seam, so the dev `testcapture.mail` outbox sees them unchanged.

## Test plan

**Unit (Zig, `zig build test --summary all`; every new file added to `root.zig`'s test block):**
- `bulk.zig`: submit-time validation (bad address in recipient #2 fails the whole call, nothing
  persisted); duplicate recipients collapse to one row/job; per-recipient render with escaping;
  handler idempotency (run the handler twice on the same payload → exactly 1 CaptureMailer
  message, status `sent`); suppressed recipient → status `suppressed`, no send; render error →
  `invalid`, job success; backend error → attempts bumped, error propagates, terminal attempt
  sets `failed`; cancelBatch → pending rows `canceled`, redelivered job no-ops; batchStatus
  counts; tenancy: batch under `acc1` enforces `acc1`'s verified sender + suppressions only.
- `queue`: token-bucket math (refill, cap, burst); `pollOnce` claims ≤ tokens for a rated queue
  while an unrated queue on the same worker drains unthrottled; rate+memory queue is a
  `@compileError` (temporary compile-error test, reverted via Edit).
- `durable`: `enqueue` returns id; `run_at` in the future not claimed until due (drive with
  `ZIGBASE_FAKE_NOW`/fake clock); `cancel` pending→true, claimed/done→false; gc reaps `canceled`.
- `unsubscribe.zig`: token round-trip; tampered payload/MAC rejected; MAC compare is the
  constant-time helper; key derivation stable; empty-list token valid.
- `mailer.zig`: `buildMessage` emits both RFC 8058 headers when `list_unsubscribe` set, none
  when null; CRLF in the URL rejected. SES/Postmark: header mapping asserted via the mocked
  outbound-HTTP capture.
- `send.zig`: suppression-kind matrix — `unsubscribe` row blocks `.list`, passes
  `.transactional`; `hard_bounce` blocks both; >100KB html warns (log assertion or smoke).
- `api/mail_unsubscribe.zig`: POST valid → suppression row + 200; repeat POST → 200 (no
  oracle); invalid token → 400 generic; GET does not mutate; unset base_url → 404; rate limit.

**Integration/browser (`tests/admin/`, run locally before merge — unit green ≠ e2e green):**
- `tests/admin/test_mail_unsubscribe.py`: boot the real server with a configured
  `unsubscribe_base_url` + capture mailer, POST the endpoint with a minted token, verify the
  suppression row via the superuser records API (`_suppressions` is a system collection);
  verify GET returns the confirmation page without creating a row.
- Extend the existing queue/mail e2e to run a small `sendBulk` end-to-end (3 recipients, one
  pre-suppressed) and read the send-report through `GET /api/collections/_mail_batch_recipients/records`
  as superuser.

## Docs checklist (every box, per repo policy)

- [ ] `docs/framework.md`: replace the "Deferred (planned 0.9.x fast-follows)" paragraph with
      new sections — Bulk sends + send-report, Scheduling (`deliverAt`/`cancel`) + the drip
      recipe, One-click unsubscribe (config, token, endpoint, suppression semantics), the
      queue `.rate` knob (in §7b), and the "HTML that renders everywhere" note with the
      CSS-inlining / cid-images deferral rationale.
- [ ] `site/src/content/` mirror of every touched doc; `cd site && npm run build` passes.
- [ ] `changelog.d/email-round-2.md` fragment: `### Features` (bulk, scheduling, unsubscribe,
      queue rate limiting), `### Changed` (Email.list_unsubscribe additive field, durable
      enqueue returns id). No direct CHANGELOG.md edits.
- [ ] `root.zig`: re-export `BulkSend`/`BulkRecipient`/`BatchReport`/`Rate`; test block gains
      `mail/bulk.zig`, `mail/unsubscribe.zig`, `api/mail_unsubscribe.zig`.
- [ ] `KNOWN_LIMITATIONS.md`: single-process rate throttle; at-least-once duplicate-send
      window; no CSS inliner / cid attachments (link the doc pattern).
- [ ] Examples: no ladder changes required (feature is additive/off-by-default); add the drip
      recipe + a minimal `sendBulk` snippet to `docs/framework.md` only. Verify all three
      examples still build in CI.
- [ ] PR template sync checklist completed; review threads replied to *and* resolved.
