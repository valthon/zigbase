# SP3 Theme E — Email Round 2 (Bulk Sends, Scheduling, One-Click Unsubscribe, Queue Rate Limiting) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Ship the list-sending layer of #154 on the existing seams: `ctx.mail().sendBulk(...)` fanning one templated message out as per-recipient durable jobs with an idempotent-by-status handler and a durable send-report (`_mail_batches` / `_mail_batch_recipients`, migration `0019_bulk_mail`); a `QueueDef.rate` token-bucket throttle enforced in `durable.pollOnce`; the `deliverAt` / `cancel` scheduling primitives on the existing `_queue_jobs.run_at` column (drip = a documented recipe, not machinery); RFC-8058 one-click unsubscribe (signed stateless token, public endpoint, new `unsubscribe` suppression reason with a `transactional`/`list` kind split); and a >100 KB Gmail-clipping warning. CSS inlining and `cid:` inline images are explicit deferrals (documented pattern instead).

**Architecture:** Schema lands first (Task 1: migration `0019_bulk_mail`, Locked system collections, plus an `updated`-column fix so the records API can actually serve the send-report). Then the pure header/capture plumbing every later task asserts against (Task 2: `Email.list_unsubscribe` + RFC-8058 emission in `buildMessage`/SES/Postmark + `CaptureMailer` extensions). Then the bulk engine (Task 3: `src/mail/bulk.zig` + the `"mail_batch_item"` built-in kind + `MailApi` surface), the queue throttle (Task 4: `QueueDef.rate` + token bucket in `durable.pollOnce`), the scheduling primitives (Task 5: id-returning `durable.enqueue`, `cancelJob`, `MailApi.deliverAt`/`cancel`), the unsubscribe token + suppression kinds + config (Task 6: `src/mail/unsubscribe.zig`), the public endpoint + auto-header wiring (Task 7: `src/api/mail_unsubscribe.zig`), the clipping warning (Task 8), the browser e2e (Task 9), and docs/mirrors/fragment (Task 10). The spec is `/home/valthon/.claude/jobs/85efdf24/tmp/spec-email-2.md`; baseline is **origin/main @ `0ae3289`** (the spec's `1bd02c4` baseline has since advanced by docs-only merges; every file shape referenced below was verified against `0ae3289`). Work on a fresh branch off origin/main (e.g. `feat/email-round-2`), NOT on the session's stale worktree.

**Tech Stack:** Zig 0.16 (mise-pinned), vendored SQLite (+ the Postgres dialect via `execLowered`/portable runtime SQL), Playwright browser suite (`tests/admin/`, Python 3.13), Astro site mirror.

## Global Constraints

- **Zig build/test:** `mise exec zig@0.16.0 -- zig build` and `mise exec zig@0.16.0 -- zig build test --summary all`. The authoritative signal is the `Build Summary: N/N tests passed` line — a spurious `failed command: …` line appears even on success. There is no per-test filter.
- **New `src/*.zig` files MUST be added to the `test { _ = @import(…); }` block in `src/root.zig`** or their tests silently never run. This plan adds three: `mail/bulk.zig` (Task 3), `mail/unsubscribe.zig` (Task 6), `api/mail_unsubscribe.zig` (Task 7). Each task that creates a file wires it in the same task.
- **CRLF/header-injection defense stays framework-owned.** Every new header-bound value (the `list_unsubscribe` URL, bulk template *sources*, rendered per-recipient values) flows through the existing gates: `mail_send.validate`/`validateAddress` up front and `mailer.buildMessage`/`rejectControlChars` as the per-backend backstop. No task introduces a generic headers array — `list_unsubscribe` is ONE vetted field.
- **Default-off compatibility:** `require_verified_sender` / `check_suppression` keep their `false` defaults and their existing semantics for transactional mail. The new `unsubscribe_base_url` defaults to `""` = feature fully off (no headers, endpoint 404s — the `webhook_secret` pattern). The ONE always-on behavior is that **bulk sends honor `unsubscribe` suppressions unconditionally** (not gated by `check_suppression`) — compliance floor, and safe because bulk itself is new surface.
- **Queue is at-least-once ⇒ the `"mail_batch_item"` handler is idempotent by row status:** a redelivered/reclaimed job whose recipient row is not `pending` (or whose batch is `canceled`) returns SUCCESS without sending. Never rely on "the job runs once".
- **The `changes()==0` no-match rule (SQLite trigger footgun):** everywhere a conditional UPDATE detects "did I match a row", detect NO-match as `w.changesCount() == 0` — never assert success as `== 1` (`sqlite3_changes` counts trigger-touched rows, e.g. FTS5, so a match can report >1).
- **CaptureMailer is the assertion seam:** Task 2 extends `Captured` (`reply_to`, `list_unsubscribe`) and adds `all()` / `countTo()`; every bulk/scheduling/unsubscribe test asserts through it with zero network.
- **New system collections register Locked:** the `_collections` seed rows for `_mail_batches` / `_mail_batch_recipients` use `NULL` rules (= Locked, superusers only), `system=1`, hardcoded 8-char stable field ids — exactly the `0016_email` pattern. Superuser read via the records API *is* the send-report UI; no new admin UI.
- **Tenancy rides the existing senders/mail path:** every batch row carries `account` (from `withScope`-style attribution: explicit `b.account` wins, else `ctx.rctx.account_id`, `""` = system send); verified-sender + suppression checks are account-scoped exactly like `send()` today. No new tenancy machinery.
- **Response conventions (repo-wide standard):** the unsubscribe endpoint's side-effect success is **`204 No Content`** — no ad-hoc `{"success":true}`-style body (the GET confirmation page renders HTML, which is fine). No new list-shaped responses are introduced by this plan (the send-report rides the records API's existing `{items:[…]}` envelope).
- **`deliverLater` is being DELETED by a parallel retro stream.** Do not reference it in any new code, test, or doc; do not modify its lines (they must still compile untouched). The scheduling surface is `deliverAt` / `enqueue` / `cancel`.
- **Never edit `CHANGELOG.md`** or `site/src/content/docs/changelog.md`. This work adds ONE fragment `changelog.d/email-round-2.md` (Task 10).
- **Docs mirrors:** every `docs/*.md` change must be mirrored to `site/src/content/docs/*.md`; `cd site && mise exec node@24 -- npm run build` must pass before the final task completes. `KNOWN_LIMITATIONS.md` gains three entries (Task 10).
- **Browser suite:** Task 9 adds `tests/admin/test_mail_unsubscribe.py` and must pass locally: `mise exec python@3.13 -- python -m pytest tests/admin/test_mail_unsubscribe.py -q`. A green `zig build test` does NOT cover it.
- **Temporary compile-error checks** (the `.rate`-on-memory-queue guard, Task 4) are verified with a throwaway edit reverted **via Edit** — never `git checkout <file>`.
- Commit after each task with the message given in the task. All paths are relative to the repo root.

---

### Task 1: Migration `0019_bulk_mail` — send-report tables, Locked system collections, `_suppressions.updated` fix

**Files:**
- Modify: `src/migrations.zig` (new `init_0019_bulk_mail` + registry entry + tests)

**Interfaces:**
- Produces: tables `_mail_batches`, `_mail_batch_recipients` (+ UNIQUE `(batch,email)` dedup/idempotency index + `(batch,status)` report index), their Locked `_collections` seeds, and an `updated` column on `_suppressions`. Consumed by Tasks 3, 7, 9.

**Deviation from the spec DDL, on purpose:** the records engine SELECTs `"id","created","updated"` unconditionally (`src/records.zig:80`, `:592`), so a system collection without `updated` **500s under the records API** — which is exactly how the spec's own e2e reads the send-report and `_suppressions`. Both new tables therefore carry `"updated"` (mirroring the explicit `_events`/0015 rationale), and 0019 also retrofits `updated` onto `_suppressions` (0016 shipped it without one — a latent bug this plan fixes per repo policy; the e2e in Task 9 proves the fix).

- [ ] Read `src/migrations.zig` lines 369–466 (`init_0016_email`) and 483–519 (0018 + the `all` registry) to confirm the seed-row pattern and the registry tail.
- [ ] Add after `init_0018_rt_delete_snapshots`:
  ```zig
  fn init_0019_bulk_mail(m: *Migrator) db.DbError!void {
      // Bulk / list mail (#154 round 2). One `_mail_batches` row per sendBulk call (the
      // templates live ONCE here — per-recipient jobs carry only {batch,to}); one
      // `_mail_batch_recipients` row per DISTINCT recipient (the durable send-report).
      // The UNIQUE (batch,email) index is BOTH submit-time duplicate-recipient dedup
      // (ON CONFLICT DO NOTHING) and the idempotency record for at-least-once delivery
      // (the mail_batch_item handler no-ops any row whose status is not 'pending').
      // `updated` exists on both tables because the records engine's base-column SELECT
      // (id/created/updated) is unconditional — same rationale as _events (0015).
      try m.execLowered(
          \\CREATE TABLE IF NOT EXISTS "_mail_batches" (
          \\  "id" TEXT PRIMARY KEY, "created" TEXT NOT NULL, "updated" TEXT NOT NULL DEFAULT '',
          \\  "account"  TEXT NOT NULL DEFAULT '',
          \\  "list"     TEXT NOT NULL DEFAULT '',
          \\  "queue"    TEXT NOT NULL,
          \\  "from_addr" TEXT NOT NULL DEFAULT '',
          \\  "reply_to"  TEXT NOT NULL DEFAULT '',
          \\  "subject_tpl" TEXT NOT NULL,
          \\  "text_tpl"  TEXT NOT NULL DEFAULT '',
          \\  "html_tpl"  TEXT NOT NULL DEFAULT '',
          \\  "total"  INTEGER NOT NULL DEFAULT 0,
          \\  "status" TEXT NOT NULL DEFAULT 'active'
          \\);
      );
      try m.execLowered(
          \\CREATE TABLE IF NOT EXISTS "_mail_batch_recipients" (
          \\  "id" TEXT PRIMARY KEY, "created" TEXT NOT NULL, "updated" TEXT NOT NULL DEFAULT '',
          \\  "batch" TEXT NOT NULL, "email" TEXT NOT NULL,
          \\  "vars_json" TEXT NOT NULL DEFAULT '{}',
          \\  "status" TEXT NOT NULL DEFAULT 'pending',
          \\  "attempts" INTEGER NOT NULL DEFAULT 0,
          \\  "last_error" TEXT NOT NULL DEFAULT '',
          \\  "sent_at" TEXT NOT NULL DEFAULT ''
          \\);
      );
      try m.execLowered("CREATE UNIQUE INDEX IF NOT EXISTS \"idx_mail_batch_rcpt_unique\" ON \"_mail_batch_recipients\" (\"batch\",\"email\");");
      try m.execLowered("CREATE INDEX IF NOT EXISTS \"idx_mail_batch_rcpt_status\" ON \"_mail_batch_recipients\" (\"batch\",\"status\");");

      // Retrofit: 0016 shipped _suppressions WITHOUT an `updated` column, so browsing it
      // through the records API (base-column SELECT) errors. Additive, default ''.
      // `catch {}` mirrors 0002's ALTER idempotence pattern (ADD COLUMN has no IF NOT EXISTS).
      m.execLowered("ALTER TABLE \"_suppressions\" ADD COLUMN \"updated\" TEXT NOT NULL DEFAULT '';") catch {};

      // Seed the two `_collections` rows (system=1). id/created/updated are implicit base
      // columns and are NOT listed. Rules NULL = Locked (superusers only) — the superuser
      // records API is the send-report read surface; writes happen only via sendBulk.
      try m.execLowered(
          \\INSERT OR IGNORE INTO "_collections"
          \\  ("id","name","type","system","schema","indexes","options","listRule","viewRule","createRule","updateRule","deleteRule","created","updated")
          \\ VALUES
          \\  ('_mailbatches___','_mail_batches','base',1,
          \\    '[{"id":"mbtaccnt","name":"account","type":"text","options":{}},{"id":"mbtlist_","name":"list","type":"text","options":{}},{"id":"mbtqueue","name":"queue","type":"text","options":{}},{"id":"mbtfrom_","name":"from_addr","type":"text","options":{}},{"id":"mbtreply","name":"reply_to","type":"text","options":{}},{"id":"mbtsubjt","name":"subject_tpl","type":"text","options":{}},{"id":"mbttextt","name":"text_tpl","type":"text","options":{}},{"id":"mbthtmlt","name":"html_tpl","type":"text","options":{}},{"id":"mbttotal","name":"total","type":"number","options":{}},{"id":"mbtstatu","name":"status","type":"text","options":{}}]',
          \\    '[]','{}',NULL,NULL,NULL,NULL,NULL,datetime('now'),datetime('now')),
          \\  ('_mailbatchrcpts','_mail_batch_recipients','base',1,
          \\    '[{"id":"mbrbatch","name":"batch","type":"text","options":{}},{"id":"mbremail","name":"email","type":"email","options":{}},{"id":"mbrvars_","name":"vars_json","type":"json","options":{}},{"id":"mbrstatu","name":"status","type":"text","options":{}},{"id":"mbratmpt","name":"attempts","type":"number","options":{}},{"id":"mbrlerr_","name":"last_error","type":"text","options":{}},{"id":"mbrsenta","name":"sent_at","type":"text","options":{}}]',
          \\    '[]','{}',NULL,NULL,NULL,NULL,NULL,datetime('now'),datetime('now'));
      );
  }
  ```
- [ ] Append to the `all` registry (after the 0018 entry): `.{ .name = "0019_bulk_mail", .up = init_0019_bulk_mail },`
- [ ] Add tests at the bottom of `src/migrations.zig` (mirror the existing `"0016 creates email tables…"` test at ~line 792):
  ```zig
  test "0019 creates bulk-mail tables, dedup uniqueness, and seeds Locked _collections rows" {
      var d = try db.Db.openMemory();
      defer d.close();
      try run(&d);
      // Tables exist and accept the canonical column set.
      try d.exec("INSERT INTO \"_mail_batches\" (\"id\",\"created\",\"queue\",\"subject_tpl\") VALUES ('b1',datetime('now'),'emails','Hi {{ name }}');");
      try d.exec("INSERT INTO \"_mail_batch_recipients\" (\"id\",\"created\",\"batch\",\"email\") VALUES ('r1',datetime('now'),'b1','a@x.io');");
      // (batch,email) is UNIQUE — a duplicate recipient is a constraint violation.
      try std.testing.expectError(error.ConstraintViolation, d.exec(
          "INSERT INTO \"_mail_batch_recipients\" (\"id\",\"created\",\"batch\",\"email\") VALUES ('r2',datetime('now'),'b1','a@x.io');",
      ));
      // Same email on a DIFFERENT batch is fine.
      try d.exec("INSERT INTO \"_mail_batch_recipients\" (\"id\",\"created\",\"batch\",\"email\") VALUES ('r3',datetime('now'),'b2','a@x.io');");
      // Seeded as SYSTEM collections with NULL (Locked) rules.
      var st = try d.prepare("SELECT \"system\", \"listRule\" IS NULL FROM \"_collections\" WHERE \"name\" IN ('_mail_batches','_mail_batch_recipients');");
      defer st.finalize();
      var n: usize = 0;
      while (try st.step()) : (n += 1) {
          try std.testing.expectEqual(@as(i64, 1), st.columnInt(0));
          try std.testing.expectEqual(@as(i64, 1), st.columnInt(1));
      }
      try std.testing.expectEqual(@as(usize, 2), n);
  }

  test "0019 retrofits updated onto _suppressions (records-API base-column fix)" {
      var d = try db.Db.openMemory();
      defer d.close();
      try run(&d);
      // The unconditional records-engine SELECT of id/created/updated must now prepare.
      var st = try d.prepare("SELECT \"id\",\"created\",\"updated\" FROM \"_suppressions\" LIMIT 1;");
      st.finalize();
  }
  ```
  NOTE: confirm the exact constraint-error name (`error.ConstraintViolation` vs another `DbError` member) by grepping `src/db.zig` for the SQLITE_CONSTRAINT mapping before writing the duplicate-insert assert; use whatever the 0016 uniqueness test uses.
- [ ] Run `mise exec zig@0.16.0 -- zig build test --summary all` — expect `Build Summary: … tests passed`.
- [ ] `git add -A && git commit -m "feat(mail): 0019_bulk_mail migration — send-report tables + Locked system collections + _suppressions.updated fix"`

---

### Task 2: `Email.list_unsubscribe` + RFC-8058 header emission + CaptureMailer extensions

**Files:**
- Modify: `src/mail/mailer.zig` (`Email` field, `buildMessage` emission, tests)
- Modify: `src/mail/send.zig` (`MailMessage.list_unsubscribe`, `validate`, `toEmail`, tests)
- Modify: `src/mail/ses.zig` (`Content.Simple.Headers` mapping, tests)
- Modify: `src/mail/postmark.zig` (`Headers` array mapping + arena-scratch refactor, tests)
- Modify: `src/mail/capture.zig` (`Captured.reply_to`/`.list_unsubscribe`, `all`, `countTo`, tests)

**Interfaces:**
- Produces: `Email.list_unsubscribe: ?[]const u8 = null` (bare URL; emission adds RFC-8058 framing), `MailMessage.list_unsubscribe`, `CaptureMailer.all()`/`.countTo()`. Consumed by Tasks 3 (test assertions), 7 (auto-wiring). Nothing sets the field yet, so this task is behaviorally inert for every existing caller.

- [ ] In `src/mail/mailer.zig`, add to `Email` (after `from`):
  ```zig
  /// Optional one-click unsubscribe URL (#154 round 2). When set, the backends emit the
  /// RFC 8058 pair — `List-Unsubscribe: <URL>` and `List-Unsubscribe-Post:
  /// List-Unsubscribe=One-Click`. Deliberately ONE vetted field, not a generic headers
  /// array: it is CRLF/control-char checked like every other header-bound value, so the
  /// injection surface stays closed. Set automatically by the bulk item handler when
  /// `unsubscribe_base_url` is configured; transactional `send()` NEVER sets it.
  list_unsubscribe: ?[]const u8 = null,
  ```
- [ ] In `buildMessage`, validate + emit the pair. Add `if (email.list_unsubscribe) |lu| try checkHeaderField(lu);` beside the existing field checks, then build the header block (place next to `reply_hdr`):
  ```zig
  const unsub_hdr = if (email.list_unsubscribe) |lu|
      try std.fmt.allocPrint(alloc, "List-Unsubscribe: <{s}>\r\nList-Unsubscribe-Post: List-Unsubscribe=One-Click\r\n", .{lu})
  else
      "";
  defer if (email.list_unsubscribe != null) alloc.free(unsub_hdr);
  ```
  and extend the `head` format string to include it after the `reply_hdr` slot:
  ```zig
  const head = try std.fmt.allocPrint(
      alloc,
      "From: {s}\r\nTo: {s}\r\n{s}{s}Subject: {s}\r\nDate: {s}\r\nMIME-Version: 1.0\r\n",
      .{ from, email.to, reply_hdr, unsub_hdr, email.subject, date },
  );
  ```
- [ ] mailer.zig tests:
  ```zig
  test "buildMessage emits BOTH RFC 8058 headers when list_unsubscribe is set, none when null" {
      const a = std.testing.allocator;
      const msg = try buildMessage(a, std.testing.io, "n@a.io", .{
          .to = "u@x.io", .subject = "News", .text_body = "b",
          .list_unsubscribe = "https://app.example/api/mail/unsubscribe?t=abc.def",
      }, 0);
      defer a.free(msg);
      try std.testing.expect(std.mem.indexOf(u8, msg, "\r\nList-Unsubscribe: <https://app.example/api/mail/unsubscribe?t=abc.def>\r\n") != null);
      try std.testing.expect(std.mem.indexOf(u8, msg, "\r\nList-Unsubscribe-Post: List-Unsubscribe=One-Click\r\n") != null);

      const plain = try buildMessage(a, std.testing.io, "n@a.io", .{ .to = "u@x.io", .subject = "s", .text_body = "b" }, 0);
      defer a.free(plain);
      try std.testing.expect(std.mem.indexOf(u8, plain, "List-Unsubscribe") == null);
  }

  test "buildMessage rejects CRLF in the list_unsubscribe URL (header injection)" {
      try std.testing.expectError(error.HeaderInjection, buildMessage(std.testing.allocator, std.testing.io, "n@a.io", .{
          .to = "u@x.io", .subject = "s", .text_body = "b",
          .list_unsubscribe = "https://x/u?t=1\r\nBcc: spam@evil.com",
      }, 0));
  }
  ```
- [ ] In `src/mail/send.zig`, add to `MailMessage`:
  ```zig
  /// Optional one-click unsubscribe URL (#154 round 2), lowered onto `Email.list_unsubscribe`.
  /// Set by the framework's bulk item handler (or via `ctx.mail().unsubscribeUrl` for
  /// hand-rolled list mail). Transactional mail must NOT carry it.
  list_unsubscribe: ?[]const u8 = null,
  ```
  Extend `validate` with `if (msg.list_unsubscribe) |lu| try checkHeader(lu);`, extend `toEmail` with `.list_unsubscribe = msg.list_unsubscribe,`, and add a small test asserting `validate` rejects a CRLF URL and `toEmail` maps the field.
- [ ] In `src/mail/ses.zig` `buildBody`, after the `ReplyToAddresses` block (still inside the scratch arena, and note `simple` must gain the key BEFORE it is put into `content` — move the `simple.put`/`content.put`/`root.put` sequence below this block if needed):
  ```zig
  if (email.list_unsubscribe) |lu| {
      try mailer_mod.rejectControlChars(lu);
      // SES v2 supports per-message Headers on the Simple content object (since 2023) —
      // no switch to Raw MIME. Do NOT use ListManagementOptions (that binds unsubscribe
      // to SES's own contact lists rather than our endpoint).
      var h1: std.json.ObjectMap = .empty;
      try h1.put(a, "Name", .{ .string = "List-Unsubscribe" });
      try h1.put(a, "Value", .{ .string = try std.fmt.allocPrint(a, "<{s}>", .{lu}) });
      var h2: std.json.ObjectMap = .empty;
      try h2.put(a, "Name", .{ .string = "List-Unsubscribe-Post" });
      try h2.put(a, "Value", .{ .string = "List-Unsubscribe=One-Click" });
      var hdrs = std.json.Array.init(a);
      try hdrs.append(.{ .object = h1 });
      try hdrs.append(.{ .object = h2 });
      try simple.put(a, "Headers", .{ .array = hdrs });
  }
  ```
  Test: `buildBody` with `list_unsubscribe` set contains `"Headers":[` , `"Name":"List-Unsubscribe"`, `"Value":"<https://…>"`, and `"List-Unsubscribe=One-Click"`; without it contains no `"Headers"`; a CRLF URL is `error.HeaderInjection`.
- [ ] In `src/mail/postmark.zig` `buildBody`: refactor to the SES scratch-arena pattern (build the whole tree on an internal `ArenaAllocator`, serialize, `return alloc.dupe(u8, json)`) — the current `defer obj.deinit(alloc)` cannot free nested header objects and would leak under the test allocator. Then:
  ```zig
  if (email.list_unsubscribe) |lu| {
      try mailer_mod.rejectControlChars(lu);
      var h1: std.json.ObjectMap = .empty;
      try h1.put(a, "Name", .{ .string = "List-Unsubscribe" });
      try h1.put(a, "Value", .{ .string = try std.fmt.allocPrint(a, "<{s}>", .{lu}) });
      var h2: std.json.ObjectMap = .empty;
      try h2.put(a, "Name", .{ .string = "List-Unsubscribe-Post" });
      try h2.put(a, "Value", .{ .string = "List-Unsubscribe=One-Click" });
      var hdrs = std.json.Array.init(a);
      try hdrs.append(.{ .object = h1 });
      try hdrs.append(.{ .object = h2 });
      try obj.put(a, "Headers", .{ .array = hdrs });
  }
  ```
  Existing postmark tests keep passing byte-for-byte (same key insertion order); add the header-presence/absence/injection test trio mirroring SES.
- [ ] In `src/mail/capture.zig`: extend `Captured` with `reply_to: ?[]u8` and `list_unsubscribe: ?[]u8`; dupe them in `record` (each with its own `errdefer`, mirroring `html_copy`); free them in `deinit` and `clear`. Add:
  ```zig
  /// Every captured message, oldest first. BORROWED — valid until the next `record`/
  /// `clear`/`deinit` (single-threaded test usage; take the values you need eagerly).
  pub fn all(self: *CaptureMailer) []const Captured {
      lockMutex(&self.mutex);
      defer self.mutex.unlock();
      return self.messages.items;
  }

  /// Number of captured messages addressed to exactly `addr` (bulk tests assert
  /// per-recipient fan-out and dedup with this).
  pub fn countTo(self: *CaptureMailer, addr: []const u8) usize {
      lockMutex(&self.mutex);
      defer self.mutex.unlock();
      var n: usize = 0;
      for (self.messages.items) |m| {
          if (std.mem.eql(u8, m.to, addr)) n += 1;
      }
      return n;
  }
  ```
  Update `CaptureMailer.send` → `record` to pass the new fields, and extend the existing capture test to assert `reply_to`/`list_unsubscribe` round-trip plus `all().len`/`countTo`.
- [ ] Run `mise exec zig@0.16.0 -- zig build test --summary all` — expect all green (the new fields are additive `null` defaults; every existing `Email`/`Captured` literal compiles unchanged).
- [ ] `git add -A && git commit -m "feat(mail): Email.list_unsubscribe + RFC 8058 header emission (buildMessage/SES/Postmark) + CaptureMailer all/countTo"`

---

### Task 3: `src/mail/bulk.zig` — `sendBulk` / `cancelBatch` / `batchStatus` + the idempotent `"mail_batch_item"` handler

**Files:**
- Create: `src/mail/bulk.zig`
- Modify: `src/mail/send.zig` (make `validateAddress` `pub`)
- Modify: `src/ctx.zig` (`MailApi.sendBulk`/`cancelBatch`/`batchStatus` + `mail_bulk` import)
- Modify: `src/framework.zig` (`builtin_job_regs` gains `"mail_batch_item"`)
- Modify: `src/root.zig` (re-exports `BulkSend`/`BulkRecipient`/`BatchReport`; test block gains `mail/bulk.zig`)

**Interfaces:**
- Produces: `ctx.mail().sendBulk(b: BulkSend) ![]const u8` (batch id), `.cancelBatch(id) !usize`, `.batchStatus(id) !BatchReport`; built-in job kind `"mail_batch_item"` with payload `{"batch":"…","to":"…"}`. Consumed by Tasks 4 (rated-queue draining), 7 (header wiring), 9/10.

- [ ] In `src/mail/send.zig`, change `fn validateAddress` to `pub fn validateAddress` (bulk validates each recipient with the same rule; doc comment unchanged).
- [ ] Create `src/mail/bulk.zig`:
  ```zig
  //! Bulk / throttled personalized list sends (#154 round 2). One `sendBulk` call writes
  //! ONE `_mail_batches` row (the templates live once there) plus one
  //! `_mail_batch_recipients` row per DISTINCT recipient, and enqueues one durable
  //! `"mail_batch_item"` job per distinct recipient with the tiny payload
  //! `{"batch":"…","to":"…"}`. N jobs (not one driver job) buys per-recipient
  //! retry/backoff, priority ordering, visibility-timeout crash recovery, and queue rate
  //! throttling from the EXISTING engine with zero new machinery.
  //!
  //! IDEMPOTENCY (at-least-once queue): the recipient row's `status` is the dedup
  //! record. The handler returns SUCCESS without sending whenever the row is not
  //! `pending` (or the batch is `canceled`) — a redelivered/reclaimed job is a no-op.
  //! The one unavoidable window: a crash between backend-accept and the `sent` row
  //! update replays as ONE duplicate send (identical to the "mail" kind; documented).
  //!
  //! SUPPRESSION for list mail is ALWAYS ON here (not gated by `check_suppression`):
  //! sending list mail past a suppression is a compliance violation, not a tuning knob.
  //! A suppressed recipient is a REPORTED OUTCOME (row status `suppressed`), not a job
  //! failure. Tenancy: the batch's `account` scopes both the verified-sender assertion
  //! and the suppression check, exactly like `send()`.

  const std = @import("std");
  const db = @import("../db.zig");
  const id_gen = @import("../id.zig");
  const clock = @import("../clock.zig");
  const queue_mod = @import("../queue/queue.zig");
  const durable = @import("../queue/durable.zig");
  const mail_send = @import("send.zig");
  const mailer_mod = @import("mailer.zig");
  const template = @import("template.zig");
  const senders = @import("senders.zig");
  const suppression = @import("suppression.zig");
  const App = @import("../app.zig").App;
  const Ctx = @import("../ctx.zig").Ctx;

  /// The built-in durable job kind backing bulk delivery (registered in framework.zig).
  pub const job_kind = "mail_batch_item";

  /// One list recipient: the address plus its personalization vars (rendered into the
  /// batch's subject/text/html templates at DELIVERY time — vars differ per recipient,
  /// so render errors are a delivery-time outcome, not a submit-time one).
  pub const BulkRecipient = struct { to: []const u8, vars: []const template.Var = &.{} };

  /// A bulk send: template SOURCES (rendered per recipient) + the recipient list.
  pub const BulkSend = struct {
      subject: []const u8,
      text: ?[]const u8 = null, // >=1 of text/html required (error.EmptyBody)
      html: ?[]const u8 = null,
      from: ?[]const u8 = null,
      reply_to: ?[]const u8 = null,
      recipients: []const BulkRecipient, // non-empty (error.NoRecipients)
      /// List name — recorded on the batch (unsubscribe audit scoping). "" is fine.
      list: []const u8 = "",
      /// MUST name a durable queue (error.BulkRequiresDurable) — memory jobs cannot
      /// survive restart, carry run_at, or be rate-throttled.
      queue: []const u8 = "default",
      /// Unix seconds; earliest delivery for EVERY item job (default: now).
      at: ?i64 = null,
      /// Sending-account override. `null` = the request's active account scope (the
      /// same withScope attribution as `send()`); "" = an explicit system send.
      account: ?[]const u8 = null,
  };

  /// Durable per-recipient send-report counters (from the report rows).
  pub const BatchReport = struct {
      total: u32 = 0,
      pending: u32 = 0,
      sent: u32 = 0,
      suppressed: u32 = 0,
      invalid: u32 = 0,
      failed: u32 = 0,
      canceled: u32 = 0,
  };

  pub const BulkError = error{
      NoRecipients,
      UnknownQueue,
      BulkRequiresDurable,
      BatchNotFound,
  };

  /// Serialize `vars` as a flat JSON object (last duplicate key wins). Stored on the
  /// recipient row; parsed back by the handler.
  fn varsToJson(alloc: std.mem.Allocator, vars: []const template.Var) ![]const u8 {
      var obj: std.json.ObjectMap = .empty;
      for (vars) |v| try obj.put(alloc, v.key, .{ .string = v.value });
      return std.json.Stringify.valueAlloc(alloc, std.json.Value{ .object = obj }, .{});
  }

  /// Parse a stored vars_json object back into template vars (arena-owned). String
  /// values pass through; non-string values are re-serialized as their JSON text.
  fn varsFromJson(arena: std.mem.Allocator, json_text: []const u8) ![]template.Var {
      const parsed = try std.json.parseFromSlice(std.json.Value, arena, json_text, .{});
      if (parsed.value != .object) return error.BadVars;
      var out: std.ArrayList(template.Var) = .empty;
      var it = parsed.value.object.iterator();
      while (it.next()) |e| {
          const val: []const u8 = switch (e.value_ptr.*) {
              .string => |s| s,
              else => try std.json.Stringify.valueAlloc(arena, e.value_ptr.*, .{}),
          };
          try out.append(arena, .{ .key = e.key_ptr.*, .value = val });
      }
      return out.toOwnedSlice(arena);
  }

  /// Submit a bulk send. Fail-fast validation happens HERE at the call site — a bad
  /// recipient anywhere fails the whole call with NOTHING persisted. `w` is the writer
  /// connection; `own_txn` is false when the caller already holds an open transaction
  /// (ctx.tx's bound_conn) so we never nest BEGIN. Returns the batch id (duped on `arena`).
  pub fn sendBulk(
      app: *App,
      arena: std.mem.Allocator,
      reg: *const queue_mod.Registry,
      w: *db.Db,
      own_txn: bool,
      b: BulkSend,
      account: []const u8,
  ) ![]const u8 {
      // 1. Validate everything up front (template SOURCES; rendered values are
      //    re-validated at delivery by mail_send.send — fail closed twice, cheap).
      if (b.recipients.len == 0) return error.NoRecipients;
      if (b.text == null and b.html == null) return error.EmptyBody;
      const q = reg.queueByName(b.queue) orelse return error.UnknownQueue;
      if (q.backend != .durable) return error.BulkRequiresDurable;
      try mailer_mod.rejectControlChars(b.subject);
      try mailer_mod.rejectControlChars(b.list);
      try mailer_mod.rejectControlChars(account);
      if (b.from) |f| try mail_send.validateAddress(f);
      if (b.reply_to) |rt| try mail_send.validateAddress(rt);
      for (b.recipients) |r| try mail_send.validateAddress(r.to);

      // 2. Verified-sender assertion ONCE at submit when enforcement is on and the
      //    batch is account-scoped (delivery re-checks via send() anyway).
      if (app.mail.require_verified_sender and account.len > 0) {
          const from = b.from orelse return error.SenderNotVerified;
          var rd = try app.pool.acquireReader();
          defer app.pool.releaseReader(&rd);
          try senders.assertVerified(arena, &rd, account, from);
      }

      const io = app.io;
      const run_at = b.at orelse clock.nowUnix(io);
      const batch_id_buf = id_gen.collectionId(io);
      const batch_id = try arena.dupe(u8, &batch_id_buf);

      // 3. One writer transaction: batch row + all recipient rows (duplicates collapse
      //    via ON CONFLICT DO NOTHING on the UNIQUE (batch,email)) + one durable job
      //    per DISTINCT recipient.
      if (own_txn) try w.begin();
      errdefer if (own_txn) w.rollback() catch {};
      {
          var st = try w.prepare(
              \\INSERT INTO "_mail_batches"
              \\ ("id","created","updated","account","list","queue","from_addr","reply_to","subject_tpl","text_tpl","html_tpl","total","status")
              \\ VALUES (?1,datetime('now'),datetime('now'),?2,?3,?4,?5,?6,?7,?8,?9,0,'active');
          );
          defer st.finalize();
          try st.bindText(1, batch_id);
          try st.bindText(2, account);
          try st.bindText(3, b.list);
          try st.bindText(4, b.queue);
          try st.bindText(5, b.from orelse "");
          try st.bindText(6, b.reply_to orelse "");
          try st.bindText(7, b.subject);
          try st.bindText(8, b.text orelse "");
          try st.bindText(9, b.html orelse "");
          _ = try st.step();
      }
      var total: i64 = 0;
      for (b.recipients) |r| {
          const rid = id_gen.collectionId(io);
          var st = try w.prepare(
              \\INSERT INTO "_mail_batch_recipients" ("id","created","updated","batch","email","vars_json")
              \\ VALUES (?1,datetime('now'),datetime('now'),?2,?3,?4)
              \\ ON CONFLICT("batch","email") DO NOTHING
              \\ RETURNING "id";
          );
          defer st.finalize();
          try st.bindText(1, &rid);
          try st.bindText(2, batch_id);
          try st.bindText(3, r.to);
          try st.bindText(4, try varsToJson(arena, r.vars));
          if (try st.step()) {
              // Distinct recipient: enqueue exactly one item job. Small constant
              // payload — the template lives once on the batch row.
              total += 1;
              const payload = try std.json.Stringify.valueAlloc(arena, .{ .batch = batch_id, .to = r.to }, .{});
              _ = try durable.enqueue(w, io, q, job_kind, payload, run_at);
          }
      }
      {
          var st = try w.prepare("UPDATE \"_mail_batches\" SET \"total\"=?2, \"updated\"=datetime('now') WHERE \"id\"=?1;");
          defer st.finalize();
          try st.bindText(1, batch_id);
          try st.bindInt(2, total);
          _ = try st.step();
      }
      if (own_txn) try w.commit();
      return batch_id;
  }

  /// Cancel every still-pending recipient of `batch_id`. The stray item jobs are NOT
  /// hunted down in `_queue_jobs` (payload LIKE-matching is fragile) — the handler's
  /// batch-canceled / row-status check makes them drain as instant no-op successes,
  /// and a job claimed mid-cancel finishes or no-ops. Returns the number of recipient
  /// rows transitioned pending→canceled (0 for an unknown/already-canceled batch —
  /// idempotent). Wrap in a txn only when we own the connection.
  pub fn cancelBatch(app: *App, w: *db.Db, own_txn: bool, batch_id: []const u8) !usize {
      _ = app;
      if (own_txn) try w.begin();
      errdefer if (own_txn) w.rollback() catch {};
      {
          var st = try w.prepare("UPDATE \"_mail_batches\" SET \"status\"='canceled', \"updated\"=datetime('now') WHERE \"id\"=?1 AND \"status\"='active';");
          defer st.finalize();
          try st.bindText(1, batch_id);
          _ = try st.step();
      }
      var st = try w.prepare(
          \\UPDATE "_mail_batch_recipients" SET "status"='canceled', "updated"=datetime('now')
          \\ WHERE "batch"=?1 AND "status"='pending';
      );
      defer st.finalize();
      try st.bindText(1, batch_id);
      _ = try st.step();
      // changes() counts trigger-touched rows too, so this COUNT is advisory-accurate
      // only on trigger-free tables (ours are); no-match is still reliably ==0.
      const n: usize = @intCast(@max(w.changesCount(), 0));
      if (own_txn) try w.commit();
      return n;
  }

  /// Read the durable send-report counters for `batch_id` (error.BatchNotFound when
  /// the batch row does not exist).
  pub fn batchStatus(app: *App, alloc: std.mem.Allocator, batch_id: []const u8) !BatchReport {
      _ = alloc;
      var rd = try app.pool.acquireReader();
      defer app.pool.releaseReader(&rd);
      var rep = BatchReport{};
      {
          var st = try rd.prepare("SELECT \"total\" FROM \"_mail_batches\" WHERE \"id\"=?1;");
          defer st.finalize();
          try st.bindText(1, batch_id);
          if (!try st.step()) return error.BatchNotFound;
          rep.total = @intCast(@max(st.columnInt(0), 0));
      }
      var st = try rd.prepare("SELECT \"status\", COUNT(*) FROM \"_mail_batch_recipients\" WHERE \"batch\"=?1 GROUP BY \"status\";");
      defer st.finalize();
      try st.bindText(1, batch_id);
      while (try st.step()) {
          const s = st.columnText(0);
          const c: u32 = @intCast(@max(st.columnInt(1), 0));
          if (std.mem.eql(u8, s, "pending")) rep.pending = c
          else if (std.mem.eql(u8, s, "sent")) rep.sent = c
          else if (std.mem.eql(u8, s, "suppressed")) rep.suppressed = c
          else if (std.mem.eql(u8, s, "invalid")) rep.invalid = c
          else if (std.mem.eql(u8, s, "failed")) rep.failed = c
          else if (std.mem.eql(u8, s, "canceled")) rep.canceled = c;
      }
      return rep;
  }

  const ItemPayload = struct { batch: []const u8, to: []const u8 };
  const BatchRow = struct {
      account: []const u8,
      list: []const u8,
      queue: []const u8,
      from_addr: []const u8,
      reply_to: []const u8,
      subject_tpl: []const u8,
      text_tpl: []const u8,
      html_tpl: []const u8,
      status: []const u8,
  };

  fn markStatus(app: *App, rcpt_id: []const u8, status: []const u8, last_error: []const u8) !void {
      const w = app.pool.acquireWriter();
      defer app.pool.releaseWriter();
      var st = try w.prepare(
          \\UPDATE "_mail_batch_recipients"
          \\ SET "status"=?2, "last_error"=?3, "updated"=datetime('now'),
          \\     "sent_at"=CASE WHEN ?2='sent' THEN datetime('now') ELSE "sent_at" END
          \\ WHERE "id"=?1;
      );
      defer st.finalize();
      try st.bindText(1, rcpt_id);
      try st.bindText(2, status);
      try st.bindText(3, last_error);
      _ = try st.step();
  }

  /// The `"mail_batch_item"` durable job handler. IDEMPOTENT BY ROW STATUS (step 1) —
  /// see the file doc comment. Registered beside the `"mail"` kind in framework.zig.
  pub fn jobHandler(ctx: *Ctx, payload: []const u8) anyerror!void {
      const app = ctx.app;
      const parsed = try std.json.parseFromSlice(ItemPayload, ctx.arena, payload, .{ .ignore_unknown_fields = true });
      const p = parsed.value;

      // 1. Load recipient + batch. Anything already resolved → SUCCESS no-op (dedup).
      var rcpt_id: []const u8 = undefined;
      var rcpt_attempts: i64 = 0;
      var vars_json: []const u8 = undefined;
      var batch: BatchRow = undefined;
      {
          var rd = try app.pool.acquireReader();
          defer app.pool.releaseReader(&rd);
          var st = try rd.prepare("SELECT \"id\",\"status\",\"vars_json\",\"attempts\" FROM \"_mail_batch_recipients\" WHERE \"batch\"=?1 AND \"email\"=?2;");
          defer st.finalize();
          try st.bindText(1, p.batch);
          try st.bindText(2, p.to);
          if (!try st.step()) return; // row gone — nothing to deliver
          if (!std.mem.eql(u8, st.columnText(1), "pending")) return; // at-least-once dedup
          rcpt_id = try ctx.arena.dupe(u8, st.columnText(0));
          vars_json = try ctx.arena.dupe(u8, st.columnText(2));
          rcpt_attempts = st.columnInt(3);

          var bst = try rd.prepare(
              \\SELECT "account","list","queue","from_addr","reply_to","subject_tpl","text_tpl","html_tpl","status"
              \\ FROM "_mail_batches" WHERE "id"=?1;
          );
          defer bst.finalize();
          try bst.bindText(1, p.batch);
          if (!try bst.step()) return; // orphaned job — no-op
          batch = .{
              .account = try ctx.arena.dupe(u8, bst.columnText(0)),
              .list = try ctx.arena.dupe(u8, bst.columnText(1)),
              .queue = try ctx.arena.dupe(u8, bst.columnText(2)),
              .from_addr = try ctx.arena.dupe(u8, bst.columnText(3)),
              .reply_to = try ctx.arena.dupe(u8, bst.columnText(4)),
              .subject_tpl = try ctx.arena.dupe(u8, bst.columnText(5)),
              .text_tpl = try ctx.arena.dupe(u8, bst.columnText(6)),
              .html_tpl = try ctx.arena.dupe(u8, bst.columnText(7)),
              .status = try ctx.arena.dupe(u8, bst.columnText(8)),
          };
      }
      if (std.mem.eql(u8, batch.status, "canceled")) return; // canceled batches drain as no-ops

      // 2. Per-recipient render — HTML part escaped by default (renderHtml), subject/
      //    text via renderText. A render failure is hopeless across retries (same vars
      //    every time) → status 'invalid', job SUCCESS (never burn the queue on it).
      const vars = varsFromJson(ctx.arena, vars_json) catch {
          return markStatus(app, rcpt_id, "invalid", "BadVarsJson");
      };
      const subject = template.renderText(ctx.arena, batch.subject_tpl, vars, &.{}) catch |e| {
          return markStatus(app, rcpt_id, "invalid", @errorName(e));
      };
      const text: ?[]const u8 = if (batch.text_tpl.len > 0)
          template.renderText(ctx.arena, batch.text_tpl, vars, &.{}) catch |e| {
              return markStatus(app, rcpt_id, "invalid", @errorName(e));
          }
      else
          null;
      const html: ?[]const u8 = if (batch.html_tpl.len > 0)
          template.renderHtml(ctx.arena, batch.html_tpl, vars, &.{}) catch |e| {
              return markStatus(app, rcpt_id, "invalid", @errorName(e));
          }
      else
          null;

      // 3. Suppression — ALWAYS ON for list mail (see file doc comment). A suppressed
      //    recipient is a reported outcome, not a job failure.
      {
          var rd = try app.pool.acquireReader();
          defer app.pool.releaseReader(&rd);
          if (try suppression.isSuppressed(ctx.arena, &rd, batch.account, p.to)) {
              return markStatus(app, rcpt_id, "suppressed", "");
          }
      }

      // 4. Deliver through the ONE send path — inherits verified-sender enforcement,
      //    the CRLF backstop on RENDERED values, and the CaptureMailer/testcapture seams.
      const msg = mail_send.MailMessage{
          .to = p.to,
          .subject = subject,
          .text = text,
          .html = html,
          .reply_to = if (batch.reply_to.len > 0) batch.reply_to else null,
          .from = if (batch.from_addr.len > 0) batch.from_addr else null,
          .account = if (batch.account.len > 0) batch.account else null,
      };
      mail_send.send(app, ctx.arena, msg) catch |e| switch (e) {
          error.RecipientSuppressed => return markStatus(app, rcpt_id, "suppressed", @errorName(e)),
          // Validation outcomes are hopeless across retries (vars/templates won't change).
          error.InvalidAddress, error.HeaderInjection, error.EmptyBody, error.SenderNotVerified => {
              return markStatus(app, rcpt_id, "invalid", @errorName(e));
          },
          else => {
              // Backend failure → RETRYABLE. Mirror attempts onto the report row, mark
              // 'failed' on the terminal attempt (per the queue's RetryPolicy, read from
              // the registry by the batch's queue name — no JobHandler signature change),
              // and PROPAGATE so the queue applies its normal backoff/terminal policy.
              const policy = blk: {
                  if (queue_mod.registryFromApp(app)) |reg| {
                      if (reg.queueByName(batch.queue)) |q| break :blk q.retry;
                  }
                  break :blk queue_mod.RetryPolicy{};
              };
              const new_attempts = rcpt_attempts + 1;
              const terminal = new_attempts >= policy.max_attempts;
              const w = app.pool.acquireWriter();
              defer app.pool.releaseWriter();
              var st = try w.prepare(
                  \\UPDATE "_mail_batch_recipients"
                  \\ SET "attempts"=?2, "last_error"=?3, "updated"=datetime('now'),
                  \\     "status"=CASE WHEN ?4=1 THEN 'failed' ELSE "status" END
                  \\ WHERE "id"=?1;
              );
              defer st.finalize();
              try st.bindText(1, rcpt_id);
              try st.bindInt(2, new_attempts);
              try st.bindText(3, @errorName(e));
              try st.bindInt(4, if (terminal) 1 else 0);
              _ = try st.step();
              return e;
          },
      };
      // 5. Success. (Crash between backend-accept and this update ⇒ one duplicate send
      //    on redelivery — standard at-least-once; documented.)
      try markStatus(app, rcpt_id, "sent", "");
  }
  ```
- [ ] In `src/ctx.zig`: add `const mail_bulk = @import("mail/bulk.zig");` beside the other mail imports, and extend `MailApi` (after `enqueue`, WITHOUT touching the `deliverLater` lines):
  ```zig
  pub const BulkSend = mail_bulk.BulkSend;
  pub const BulkRecipient = mail_bulk.BulkRecipient;
  pub const BatchReport = mail_bulk.BatchReport;

  /// Submit a bulk list send (#154 round 2): one templated message fanned out as
  /// per-recipient durable jobs with a durable send-report. Validates EVERYTHING at
  /// the call site (a bad recipient anywhere persists nothing). Requires a durable
  /// queue (`error.BulkRequiresDurable`) and a wired registry. Returns the batch id
  /// (arena-owned) — hand it to `batchStatus`/`cancelBatch`.
  pub fn sendBulk(self: MailApi, b: BulkSend) ![]const u8 {
      const account = b.account orelse self.ctx.rctx.account_id; // withScope parity: explicit wins
      const reg = queue_mod.registryFromApp(self.ctx.app) orelse return error.QueuesUnavailable;
      if (self.ctx.bound_conn) |c| return mail_bulk.sendBulk(self.ctx.app, self.ctx.arena, reg, c, false, b, account);
      const w = self.ctx.app.pool.acquireWriter();
      defer self.ctx.app.pool.releaseWriter();
      return mail_bulk.sendBulk(self.ctx.app, self.ctx.arena, reg, w, true, b, account);
  }

  /// Cancel every still-pending recipient of a batch (idempotent; stray queued item
  /// jobs drain as no-ops). Returns how many recipients moved pending→canceled.
  pub fn cancelBatch(self: MailApi, batch_id: []const u8) !usize {
      if (self.ctx.bound_conn) |c| return mail_bulk.cancelBatch(self.ctx.app, c, false, batch_id);
      const w = self.ctx.app.pool.acquireWriter();
      defer self.ctx.app.pool.releaseWriter();
      return mail_bulk.cancelBatch(self.ctx.app, w, true, batch_id);
  }

  /// The durable per-recipient send-report, aggregated.
  pub fn batchStatus(self: MailApi, batch_id: []const u8) !BatchReport {
      return mail_bulk.batchStatus(self.ctx.app, self.ctx.arena, batch_id);
  }
  ```
- [ ] In `src/framework.zig`, extend `builtin_job_regs` (~line 394) and its doc comment:
  ```zig
  const builtin_job_regs: []const queue.JobReg = &.{
      .{ .kind = "mail", .handler = mail_send.jobHandler },
      .{ .kind = "mail_batch_item", .handler = mail_bulk.jobHandler },
      // … (keep any existing entries, e.g. "webhook", in place)
  };
  ```
  with `const mail_bulk = @import("mail/bulk.zig");` at the top. `reserved_job_kinds` derives from `builtin_job_regs`, so the consumer-collision guard picks the new kind up automatically.
- [ ] In `src/root.zig`: re-export next to `MailMessage`:
  ```zig
  pub const BulkSend = @import("mail/bulk.zig").BulkSend;
  pub const BulkRecipient = @import("mail/bulk.zig").BulkRecipient;
  pub const BatchReport = @import("mail/bulk.zig").BatchReport;
  ```
  and add `_ = @import("mail/bulk.zig");` to the test block (beside `mail/send.zig`).
- [ ] Tests in `src/mail/bulk.zig` (build a `BulkEnv` mirroring `send.zig`'s `EnforceEnv` — tmp-dir pool + `migrations.run` + `App{…}` — plus a `CaptureMailer` wired via `app.mailer = &m;` where `const m = cap.mailer();` is a stack var outliving the test body, and `app.queues = @ptrCast(&test_registry);` with `const test_registry = queue_mod.Registry{ .queues = &.{ .{ .name = "emails", .backend = .durable }, .{ .name = "default" } }, .jobs = &.{ .{ .kind = job_kind, .handler = jobHandler } } };`):
  1. **Submit validation, nothing persisted:** recipients `.{ good, "no-at-sign" }` → `error.InvalidAddress`; then `SELECT COUNT(*)` from both tables and `_queue_jobs` all 0 (the errdefer rolled back). Also `error.NoRecipients`, `error.EmptyBody`, `error.BulkRequiresDurable` (queue `"default"` memory), `error.UnknownQueue`.
  2. **Dedup:** 3 recipients where two are byte-identical → batch `total==2`, 2 recipient rows, 2 pending `_queue_jobs` of kind `mail_batch_item`.
  3. **Fan-out + personalization:** submit 2 recipients with different `name` vars over subject `"Hi {{ name }}"` and html `"<b>{{ name }}</b>"`; drive `durable.pollOnce(&env.app, &test_registry, worker)` until 0 processed; assert `cap.count()==2`, `cap.countTo("a@x.io")==1`, per-message subject/html rendered with THAT recipient's var, html-escaping applied for a var containing `<`; both rows `sent` with non-empty `sent_at`; `batchStatus` reports `.{ .total=2, .sent=2 }`.
  4. **Handler idempotency:** run `jobHandler` twice directly with the same `{"batch":…,"to":…}` payload (fresh `Ctx{ .app = &env.app, .arena = …, .rctx = .{} }` each time) → exactly 1 captured message, row `sent`.
  5. **Suppressed recipient:** `suppression.upsert(...)` one recipient first; after draining, that row is `suppressed`, `cap.countTo(it)==0`, the other is `sent`; job status in `_queue_jobs` is `done` (a suppressed recipient is NOT a job failure).
  6. **Render error → invalid, job success:** subject `"{{ broken"` (UnterminatedTag) → row `invalid`, `last_error="UnterminatedTag"`, job `done`, nothing captured.
  7. **Backend error → attempts + propagate + terminal `failed`:** wire a failing mailer (local `FailMailer` whose vtable send returns `error.Boom`) and a registry whose queue has `.retry = .{ .max_attempts = 2, .base_ms = 0, .jitter = false }`; first poll → row attempts 1, still `pending`, job `pending`; second poll → row `failed`, job `failed`.
  8. **cancelBatch:** submit 2, cancel → returns 2, batch `canceled`, rows `canceled`; then drain the (still-pending) jobs → they complete as no-op successes, `cap.count()==0`; `cancelBatch` again → 0.
  9. **Tenancy:** with `.mail = .{ .require_verified_sender = true }`, `sendBulk(..., account="acc1")` with an unverified from → `error.SenderNotVerified` (nothing persisted); verify the identity for acc1 (the `senders.requestVerification`/`confirm` dance from send.zig's test) → submit succeeds. And a suppression scoped to `acc2` does NOT suppress acc1's batch recipient.
- [ ] Run `mise exec zig@0.16.0 -- zig build test --summary all` — all green.
- [ ] `git add -A && git commit -m "feat(mail): sendBulk/cancelBatch/batchStatus + idempotent mail_batch_item durable job kind"`

---

### Task 4: `QueueDef.rate` — token-bucket throttling in `durable.pollOnce`

**Files:**
- Modify: `src/queue/queue.zig` (`Rate` type + `QueueDef.rate`)
- Modify: `src/queue/config.zig` (lowering + `@compileError` guards)
- Modify: `src/queue/durable.zig` (`TokenBucket`, global bucket map, `pollOnce` partitioning, tests)
- Modify: `src/root.zig` (re-export `Rate`)

**Interfaces:**
- Produces: `QueueDef.rate: ?Rate = null` (`Rate = struct { per_second: u16 }`); `pollOnce` claims ≤ available tokens for rated queues. Consumed by consumers routing provider mail (SES 14/s etc.) and by the docs (Task 10).

- [ ] In `src/queue/queue.zig`, add above `QueueDef`:
  ```zig
  /// Sustained per-queue delivery ceiling (durable only). `per_second` is BOTH the
  /// refill rate and the bucket capacity, so the maximum burst is one second's worth
  /// of tokens. The bucket is in-process, per queue name, shared by every worker
  /// draining that queue — authoritative because the scheduler is single-process
  /// (documented). Memory queues cannot be rated (loud @compileError at lowering).
  pub const Rate = struct { per_second: u16 };
  ```
  and to `QueueDef`: `rate: ?Rate = null,` with a doc comment pointing at `Rate`.
- [ ] In `src/queue/config.zig` `queueMeta`: add `"rate"` to the recognized-key check (and to the error message's recognized list), lower it:
  ```zig
  if (@hasField(ST, "rate")) {
      const rs = spec.rate;
      const RST = @TypeOf(rs);
      if (@typeInfo(RST) != .@"struct" or !@hasField(RST, "per_second"))
          @compileError("queue '" ++ f.name ++ "': .rate must be '.{ .per_second = N }'");
      if (rs.per_second == 0)
          @compileError("queue '" ++ f.name ++ "': .rate.per_second must be >= 1");
      def.rate = .{ .per_second = rs.per_second };
  }
  ```
  and AFTER the backend/priority/retry lowering (so `def.backend` is resolved):
  ```zig
  if (def.rate != null and def.backend != .durable)
      @compileError("queue '" ++ f.name ++ "': .rate requires .backend = .durable (memory jobs dispatch inline and cannot be throttled)");
  ```
  Add a lowering test: `queueMeta(.{ .ses_mail = .{ .backend = .durable, .rate = .{ .per_second = 14 } } })` → `defs[1].rate.?.per_second == 14`; default queue `rate == null`.
- [ ] **Temporary compile-error check (revert via Edit, never `git checkout`):** momentarily add `_ = comptime queueMeta(.{ .bad = .{ .rate = .{ .per_second = 1 } } });` in a test, run `zig build test`, confirm the ".rate requires .backend = .durable" message, then REVERT that edit with the Edit tool.
- [ ] In `src/queue/durable.zig`, add (below the `gc_batch` decl):
  ```zig
  // ── Per-queue rate throttling (#154 round 2) ─────────────────────────────
  // Enforced HERE, at claim time: rated queues are claimed per-queue with
  // `limit = min(worker's remaining concurrency, reserved tokens)`. Unclaimed ready
  // jobs simply wait for the next ~500ms scheduler tick — no sleeping in the worker,
  // no per-job pacing. Refill is INTEGER-SECOND on the framework clock (capacity ==
  // per_second, so any new second refills to full): deterministic, ZIGBASE_FAKE_NOW-
  // compatible, and equivalent to continuous refill at the tick granularity. The map
  // is process-global (single-process scheduler ⇒ authoritative) and lazily populated
  // ONLY for queues that set `.rate` — zero cost for unrated queues.

  /// Pure token-bucket math (unit-tested directly; production drives it via
  /// reserveTokens/refundTokens under the global mutex).
  pub const TokenBucket = struct {
      capacity: u32,
      tokens: u32,
      last_s: i64,

      pub fn init(per_second: u16, now_s: i64) TokenBucket {
          return .{ .capacity = per_second, .tokens = per_second, .last_s = now_s };
      }

      fn refill(self: *TokenBucket, now_s: i64) void {
          if (now_s <= self.last_s) return; // clock went backwards / same second: no refill
          self.tokens = self.capacity; // capacity == per_second ⇒ any elapsed second refills to full
          self.last_s = now_s;
      }

      /// Reserve up to `want` tokens (decrementing). Returns the grant.
      pub fn reserve(self: *TokenBucket, now_s: i64, want: usize) usize {
          self.refill(now_s);
          const take: u32 = @intCast(@min(want, self.tokens));
          self.tokens -= take;
          return take;
      }

      /// Return unused reserved tokens (claim came up short), capped at capacity.
      pub fn refund(self: *TokenBucket, n: usize) void {
          self.tokens = @intCast(@min(@as(usize, self.capacity), self.tokens + n));
      }
  };

  fn lockMutex(m: *std.atomic.Mutex) void {
      while (!m.tryLock()) std.atomic.spinLoopHint();
  }

  var rate_mutex: std.atomic.Mutex = .unlocked;
  // page_allocator: process-lifetime map (a handful of tiny entries keyed by the
  // registry's comptime-static queue names — no key dup, never freed in prod).
  var rate_buckets: std.StringHashMapUnmanaged(TokenBucket) = .empty;

  fn reserveTokens(name: []const u8, per_second: u16, now_s: i64, want: usize) usize {
      lockMutex(&rate_mutex);
      defer rate_mutex.unlock();
      const gop = rate_buckets.getOrPut(std.heap.page_allocator, name) catch return 0; // OOM: claim nothing this tick
      if (!gop.found_existing) gop.value_ptr.* = TokenBucket.init(per_second, now_s);
      return gop.value_ptr.reserve(now_s, want);
  }

  fn refundTokens(name: []const u8, n: usize) void {
      if (n == 0) return;
      lockMutex(&rate_mutex);
      defer rate_mutex.unlock();
      if (rate_buckets.getPtr(name)) |b| b.refund(n);
  }

  /// TEST-ONLY: drop all buckets so each test starts from a full burst.
  pub fn resetRateBucketsForTest() void {
      if (!@import("builtin").is_test) @compileError("resetRateBucketsForTest is test-only");
      lockMutex(&rate_mutex);
      defer rate_mutex.unlock();
      rate_buckets.deinit(std.heap.page_allocator);
      rate_buckets = .empty;
  }
  ```
- [ ] Rework `pollOnce`'s claim block: partition the worker's durable queues into unrated (claimed together via the existing multi-queue `claimBatch` — byte-identical behavior for today's configs) and rated (claimed per-queue against a token grant):
  ```zig
  var durable_qs: std.ArrayList([]const u8) = .empty; // unrated
  var rated_qs: std.ArrayList(QueueDef) = .empty;
  for (worker.queues) |qn| {
      if (reg.queueByName(qn)) |q| {
          if (q.backend != .durable) continue;
          if (q.rate == null) try durable_qs.append(pa, qn) else try rated_qs.append(pa, q);
      }
  }
  if (durable_qs.items.len == 0 and rated_qs.items.len == 0) return 0;

  var claimed_list: std.ArrayList(Claimed) = .empty;
  {
      const w = app.pool.acquireWriter();
      defer app.pool.releaseWriter();
      for (durable_qs.items) |qn| { … existing reclaim … }
      for (rated_qs.items) |q| {
          _ = reclaimStale(w, q.name, now, q.visibility_timeout_s) catch |e|
              std.log.warn("queue '{s}' reclaim sweep failed: {s}", .{ q.name, @errorName(e) });
      }
      var remaining: usize = worker.concurrency;
      if (durable_qs.items.len > 0 and remaining > 0) {
          const c = try claimBatch(pa, w, durable_qs.items, worker.name, remaining, now);
          try claimed_list.appendSlice(pa, c);
          remaining -= c.len;
      }
      for (rated_qs.items) |q| {
          if (remaining == 0) break;
          // Reserve-then-claim-then-refund is race-safe: tokens are decremented up
          // front, and only the shortfall (grant - actually claimed) is returned.
          const grant = reserveTokens(q.name, q.rate.?.per_second, now, remaining);
          if (grant == 0) continue;
          const c = try claimBatch(pa, w, &.{q.name}, worker.name, grant, now);
          if (c.len < grant) refundTokens(q.name, grant - c.len);
          try claimed_list.appendSlice(pa, c);
          remaining -= c.len;
      }
  }
  const claimed = claimed_list.items;
  ```
  The dispatch/outcome loop below is unchanged (it iterates `claimed`).
- [ ] Tests in `src/queue/durable.zig`:
  ```zig
  test "TokenBucket: full burst, drain, integer-second refill, refund cap" {
      var b = TokenBucket.init(3, 100);
      try testing.expectEqual(@as(usize, 3), b.reserve(100, 10)); // burst = 1s of tokens
      try testing.expectEqual(@as(usize, 0), b.reserve(100, 1)); // same second: empty
      try testing.expectEqual(@as(usize, 3), b.reserve(101, 5)); // new second: refilled to capacity
      b.refund(99);
      try testing.expectEqual(@as(u32, 3), b.tokens); // refund never exceeds capacity
      try testing.expectEqual(@as(usize, 2), b.reserve(50, 2)); // clock going BACKWARDS: no refill, but reserve still works
  }
  ```
  and a `pollOnce` integration test (uses `clock.setForTest` to advance the framework clock — dev builds only, which `zig build test` is):
  ```zig
  test "pollOnce claims <= tokens on a rated queue while an unrated queue drains unthrottled" {
      const env = try PollTestEnv.init();
      defer env.deinit();
      resetRateBucketsForTest();
      defer resetRateBucketsForTest();
      clock.setForTest(1_000_000);
      defer clock.resetForTest();
      th_runs = 0;
      const reg = Registry{
          .queues = &.{
              .{ .name = "fast", .backend = .durable },
              .{ .name = "slow", .backend = .durable, .rate = .{ .per_second = 2 } },
          },
          .jobs = &.{.{ .kind = "ok", .handler = okHandler }},
      };
      {
          const w = env.pool.acquireWriter();
          defer env.pool.releaseWriter();
          var i: usize = 0;
          while (i < 3) : (i += 1) _ = try enqueue(w, env.app.io, reg.queues[0], "ok", "{}", clock.nowUnix(env.app.io));
          i = 0;
          while (i < 5) : (i += 1) _ = try enqueue(w, env.app.io, reg.queues[1], "ok", "{}", clock.nowUnix(env.app.io));
      }
      const worker = WorkerDef{ .name = "w1", .queues = &.{ "fast", "slow" }, .concurrency = 10 };
      // Tick 1: all 3 unrated + only 2 rated (the 1s burst).
      try testing.expectEqual(@as(usize, 5), try pollOnce(&env.app, &reg, worker));
      // Tick 2, same frozen second: the bucket is empty — nothing more claimed.
      try testing.expectEqual(@as(usize, 0), try pollOnce(&env.app, &reg, worker));
      // Advance one second: 2 more.
      clock.setForTest(1_000_001);
      try testing.expectEqual(@as(usize, 2), try pollOnce(&env.app, &reg, worker));
      clock.setForTest(1_000_002);
      try testing.expectEqual(@as(usize, 1), try pollOnce(&env.app, &reg, worker));
      try testing.expectEqual(@as(usize, 8), th_runs);
  }
  ```
  (`enqueue` gains a return value in Task 5; at THIS task it is still void — write these calls without `_ =` now, and Task 5's sweep updates them. Add `const clock = @import("../clock.zig");` import already present.)
- [ ] In `src/root.zig`, re-export beside `RetryPolicy`: `pub const Rate = @import("queue/queue.zig").Rate;`
- [ ] Run `mise exec zig@0.16.0 -- zig build test --summary all` — all green (existing pollOnce tests exercise the unrated path unchanged).
- [ ] `git add -A && git commit -m "feat(queue): QueueDef.rate token-bucket throttle enforced at claim time in pollOnce"`

---

### Task 5: Scheduling primitives — id-returning `durable.enqueue`, `cancelJob`, `MailApi.deliverAt`/`cancel`

**Files:**
- Modify: `src/queue/durable.zig` (`enqueue` returns the job id; `cancelJob`; `gcDoneJobs` reaps `canceled`; tests)
- Modify: `src/ctx.zig` (`MailApi.EnqueueOpts.at/delay_s`, `deliverAt`, `cancel`, `enqueue` forwarding; `enqueueByName` call-site updates)
- Modify: `src/mail/bulk.zig` (call-site `_ = try durable.enqueue(…)` — one-line sweep)

**Interfaces:**
- Produces: `durable.enqueue(w, io, def, kind, payload, run_at) ![15]u8` → **changed to return the generated job id**; `durable.cancelJob(w, job_id) !bool`; `ctx.mail().deliverAt(msg, .{ .queue, .at, .delay_s }) ![]const u8` and `ctx.mail().cancel(job_id) !bool`. Consumed by the drip recipe (Task 10) and consumers.

- [ ] In `src/queue/durable.zig`, change `enqueue` to return the id it already generates (no allocation — the id is a fixed 15-byte array, callers dupe if they need to keep it):
  ```zig
  /// Insert a `pending` durable job and return its generated id. `run_at` is the earliest
  /// unix-second the job may be claimed (pass `clock.nowUnix(io)` for immediate; a future
  /// value is the SCHEDULING primitive — `claimBatch` only claims `run_at <= now`, indexed).
  /// The writer must be held by the caller.
  pub fn enqueue(w: *db.Db, io: std.Io, def: QueueDef, kind: []const u8, payload: []const u8, run_at: i64) ![15]u8 {
      const jid = id.collectionId(io);
      … (body unchanged) …
      return jid;
  }
  ```
  Sweep every existing call site: the durable.zig tests and `ctx.enqueueByName`'s two calls become `_ = try enqueue(…)`; Task 3's `bulk.zig` call is already `_ = try …`; Task 4's test calls get `_ =` added.
- [ ] Add `cancelJob` (below `markFailed`):
  ```zig
  /// Cancel a still-PENDING durable job. Returns true when the row transitioned
  /// pending→canceled; false when nothing matched (already claimed/done/failed/
  /// canceled, or unknown id — it ran or is running). NO-MATCH IS DETECTED AS
  /// `changes() == 0`, NEVER as "success == 1": sqlite3_changes also counts rows
  /// touched by triggers (e.g. FTS5), so equality-with-1 false-positives on tables
  /// with triggers. `claimBatch` only claims 'pending', so no claim-path change.
  pub fn cancelJob(w: *db.Db, job_id: []const u8) !bool {
      var st = try w.prepare(
          \\UPDATE "_queue_jobs" SET "status"='canceled', "claimed_at"=NULL
          \\ WHERE "id"=?1 AND "status"='pending';
      );
      defer st.finalize();
      try st.bindText(1, job_id);
      _ = try st.step();
      return w.changesCount() != 0;
  }
  ```
- [ ] In `gcDoneJobs`, change the status set to `"status" IN ('done','failed','canceled')` (and its doc comment) so canceled rows age out.
- [ ] durable.zig tests:
  ```zig
  test "enqueue returns the persisted job id; a future run_at is not claimed until due" {
      var d = try db.Db.openMemory();
      defer d.close();
      try migrations.run(&d);
      const io = testing.io;
      const def = QueueDef{ .name = "default", .backend = .durable };
      const jid = try enqueue(&d, io, def, "k", "{}", 2_000_000); // due at t=2M
      {
          var st = try d.prepare("SELECT \"status\" FROM \"_queue_jobs\" WHERE \"id\"=?1;");
          defer st.finalize();
          try st.bindText(1, &jid);
          try testing.expect(try st.step());
          try testing.expectEqualStrings("pending", st.columnText(0));
      }
      var arena = std.heap.ArenaAllocator.init(testing.allocator);
      defer arena.deinit();
      // Before due: nothing claimable. At/after due: claimed.
      try testing.expectEqual(@as(usize, 0), (try claimBatch(arena.allocator(), &d, &.{"default"}, "w", 10, 1_999_999)).len);
      try testing.expectEqual(@as(usize, 1), (try claimBatch(arena.allocator(), &d, &.{"default"}, "w", 10, 2_000_000)).len);
  }

  test "cancelJob: pending -> true; claimed/done/second-cancel -> false (changes()==0 no-match rule)" {
      var d = try db.Db.openMemory();
      defer d.close();
      try migrations.run(&d);
      const io = testing.io;
      const def = QueueDef{ .name = "default", .backend = .durable };
      const jid = try enqueue(&d, io, def, "k", "{}", clock.nowUnix(io) + 3600);
      try testing.expect(try cancelJob(&d, &jid)); // pending -> canceled
      try testing.expect(!try cancelJob(&d, &jid)); // already canceled -> no match
      try testing.expect(!try cancelJob(&d, "nonexistent-id!")); // unknown -> no match
      // A canceled job is invisible to the claim query.
      var arena = std.heap.ArenaAllocator.init(testing.allocator);
      defer arena.deinit();
      try testing.expectEqual(@as(usize, 0), (try claimBatch(arena.allocator(), &d, &.{"default"}, "w", 10, clock.nowUnix(io) + 7200)).len);
  }

  test "gcDoneJobs reaps old canceled rows" {
      var d = try db.Db.openMemory();
      defer d.close();
      try migrations.run(&d);
      try d.exec("INSERT INTO \"_queue_jobs\" (\"id\",\"queue\",\"kind\",\"max_attempts\",\"status\",\"created\") VALUES ('c1','q','k',5,'canceled',datetime('now','-400 days'));");
      try d.exec("INSERT INTO \"_queue_jobs\" (\"id\",\"queue\",\"kind\",\"max_attempts\",\"status\",\"created\") VALUES ('c2','q','k',5,'canceled',datetime('now'));");
      try testing.expectEqual(@as(usize, 1), try gcDoneJobs(&d, "q", 30 * 24 * 3600)); // old canceled reaped, fresh kept
  }
  ```
- [ ] In `src/ctx.zig`, replace `MailApi.EnqueueOpts` and add the two verbs (leave the `deliverLater` block byte-untouched — a parallel stream deletes it; it still compiles because `EnqueueOpts`'s new fields have defaults):
  ```zig
  /// Options for the background-delivery verbs. `queue` routes the "mail" job;
  /// `at` (unix seconds) / `delay_s` schedule its earliest delivery — mutually
  /// exclusive (`error.ConflictingSchedule`), and scheduling requires a DURABLE
  /// queue (`error.ScheduleRequiresDurable` — a memory job cannot survive to a
  /// future time). Both null = deliver on the next poll (today's behavior).
  pub const EnqueueOpts = struct {
      queue: []const u8 = "default",
      at: ?i64 = null,
      delay_s: ?u32 = null,
  };

  /// Schedule a message for (earliest) delivery at `opts.at` / now+`opts.delay_s`,
  /// returning the durable JOB ID (arena-owned). Persist that id (your own record,
  /// `ctx.kv()`, …) and hand it to `cancel` to call the send off — this pair is the
  /// drip-sequence primitive (see framework.md's recipe; there is no campaign
  /// machinery). Validates the message up front like `enqueue`.
  pub fn deliverAt(self: MailApi, msg: Message, opts: EnqueueOpts) ![]const u8 {
      if (opts.at != null and opts.delay_s != null) return error.ConflictingSchedule;
      const scoped = self.withScope(msg);
      try mail_send.validate(scoped);
      const reg = queue_mod.registryFromApp(self.ctx.app) orelse return error.QueuesUnavailable;
      const q = reg.queueByName(opts.queue) orelse return error.UnknownQueue;
      if (q.backend != .durable) return error.ScheduleRequiresDurable;
      const io = self.ctx.app.io;
      const now = clock.nowUnix(io);
      const run_at: i64 = opts.at orelse (now + @as(i64, opts.delay_s orelse 0));
      const payload = try self.ctx.serializePayload(scoped);
      const jid = blk: {
          if (self.ctx.bound_conn) |c| break :blk try queue_durable.enqueue(c, io, q, "mail", payload, run_at);
          const w = self.ctx.app.pool.acquireWriter();
          defer self.ctx.app.pool.releaseWriter();
          break :blk try queue_durable.enqueue(w, io, q, "mail", payload, run_at);
      };
      return self.ctx.arena.dupe(u8, &jid);
  }

  /// Cancel a still-pending scheduled job by the id `deliverAt` returned. True when
  /// it was called off; false when it already ran / is running / was canceled.
  pub fn cancel(self: MailApi, job_id: []const u8) !bool {
      if (self.ctx.bound_conn) |c| return queue_durable.cancelJob(c, job_id);
      const w = self.ctx.app.pool.acquireWriter();
      defer self.ctx.app.pool.releaseWriter();
      return queue_durable.cancelJob(w, job_id);
  }
  ```
  and make `enqueue` honor scheduling by forwarding (keeping its void shape and its immediate-path behavior byte-identical when no schedule is given):
  ```zig
  pub fn enqueue(self: MailApi, msg: Message, opts: EnqueueOpts) !void {
      if (opts.at != null or opts.delay_s != null) {
          _ = try self.deliverAt(msg, opts);
          return;
      }
      const scoped = self.withScope(msg);
      try mail_send.validate(scoped);
      return self.ctx.enqueueByName(opts.queue, "mail", scoped);
  }
  ```
  (`queue_durable` / `clock` are already imported by ctx.zig; verify and add if not.)
- [ ] ctx.zig tests (mirror the existing `enqueueByName` test env at ~line 1940 — it wires a registry + pool): `deliverAt` on a durable queue with `.at = now+3600` returns a 15-char id and the `_queue_jobs` row has that `run_at`; `deliverAt` on a memory queue → `error.ScheduleRequiresDurable`; both `at` and `delay_s` → `error.ConflictingSchedule`; `cancel(id)` → true then false; `enqueue` with `.delay_s` schedules (row `run_at > now`).
- [ ] Run `mise exec zig@0.16.0 -- zig build test --summary all` — all green.
- [ ] `git add -A && git commit -m "feat(mail): deliverAt/cancel scheduling primitives on _queue_jobs.run_at; durable.enqueue returns the job id; gc reaps canceled"`

---

### Task 6: Unsubscribe token module + suppression kinds + `unsubscribe_base_url` config

**Files:**
- Create: `src/mail/unsubscribe.zig`
- Modify: `src/mail/suppression.zig` (`reason_unsubscribe`, `Kind`, kind-aware `isSuppressed`/`assertNotSuppressed`, tests)
- Modify: `src/mail/send.zig` (`.transactional` call site), `src/mail/bulk.zig` (`.list` call site)
- Modify: `src/mail/config.zig` (`Runtime.unsubscribe_base_url`), `src/framework.zig` (comptime key + validation), `src/config.zig` (`ZIGBASE_UNSUBSCRIBE_BASE_URL`), `src/root.zig` (test block)

**Interfaces:**
- Produces: `unsubscribe.mint/verify/buildUrl` (signed stateless token, constant-time verify), `suppression.Kind = enum { transactional, list }`, `reason_unsubscribe`, `app.mail.unsubscribe_base_url` (comptime config OR `ZIGBASE_UNSUBSCRIBE_BASE_URL` env, env wins — the env source is what lets the browser suite drive the stock binary). Consumed by Task 7 (endpoint + wiring) and Task 9.

- [ ] Create `src/mail/unsubscribe.zig`:
  ```zig
  //! RFC 8058 one-click unsubscribe token (#154 round 2). STATELESS + SIGNED + NON-ORACLE:
  //!   token = base64url(payload) ++ "." ++ base64url(HMAC-SHA256(key, payload))
  //!   payload = "v1\x00" ++ account ++ "\x00" ++ list ++ "\x00" ++ recipient
  //! (NUL-delimited — every field is CRLF/NUL-rejected upstream, so the framing is
  //! unambiguous; mint re-rejects embedded NULs as a fail-closed backstop.)
  //!
  //! key = HMAC-SHA256(jwt_secret, "zigbase.mail.unsub.v1") — a LABELED derivation of the
  //! already-persisted app secret: no new secret to configure, and the mail-unsubscribe
  //! key can never be confused with a JWT signature. NO EXPIRY by design: unsubscribe
  //! links must keep working from years-old inboxes, and the worst-case "attack" is
  //! unsubscribing an address whose mail the attacker already possesses.
  //!
  //! Verification is length-checked and CONSTANT-TIME on the MAC (crypto.timingSafeEql,
  //! the same discipline as the inbound-webhook HMAC); every failure collapses to null
  //! so the endpoint can emit one generic 400 (no bad-MAC vs unknown-account oracle).

  const std = @import("std");
  const crypto = @import("../crypto.zig");

  const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
  const b64 = std.base64.url_safe_no_pad;

  /// Key-derivation label. Versioned so a future token format can rotate cleanly.
  pub const key_label = "zigbase.mail.unsub.v1";
  /// Hard cap on an encoded token part (payload is account+list+email ≤ a few hundred
  /// bytes in practice; the cap bounds attacker-supplied decode work).
  pub const max_part_len = 1024;

  /// Derive the unsubscribe MAC key from the app JWT secret (labeled, stable).
  pub fn deriveKey(jwt_secret: []const u8) [HmacSha256.mac_length]u8 {
      var key: [HmacSha256.mac_length]u8 = undefined;
      HmacSha256.create(&key, key_label, jwt_secret);
      return key;
  }

  fn buildPayload(alloc: std.mem.Allocator, account: []const u8, list: []const u8, recipient: []const u8) ![]u8 {
      // Fail-closed framing backstop: NULs would make the payload ambiguous.
      for ([_][]const u8{ account, list, recipient }) |f| {
          if (std.mem.indexOfScalar(u8, f, 0) != null) return error.InvalidField;
      }
      var out: std.ArrayList(u8) = .empty;
      errdefer out.deinit(alloc);
      try out.appendSlice(alloc, "v1\x00");
      try out.appendSlice(alloc, account);
      try out.append(alloc, 0);
      try out.appendSlice(alloc, list);
      try out.append(alloc, 0);
      try out.appendSlice(alloc, recipient);
      return out.toOwnedSlice(alloc);
  }

  /// Mint a token for (account, list, recipient). Caller-owned bytes.
  pub fn mint(alloc: std.mem.Allocator, jwt_secret: []const u8, account: []const u8, list: []const u8, recipient: []const u8) ![]u8 {
      const payload = try buildPayload(alloc, account, list, recipient);
      defer alloc.free(payload);
      const key = deriveKey(jwt_secret);
      var mac: [HmacSha256.mac_length]u8 = undefined;
      HmacSha256.create(&mac, payload, &key);
      const p_len = b64.Encoder.calcSize(payload.len);
      const m_len = b64.Encoder.calcSize(mac.len);
      const out = try alloc.alloc(u8, p_len + 1 + m_len);
      _ = b64.Encoder.encode(out[0..p_len], payload);
      out[p_len] = '.';
      _ = b64.Encoder.encode(out[p_len + 1 ..], &mac);
      return out;
  }

  /// The verified token fields (slices into an alloc'd decode buffer — arena usage).
  pub const Parts = struct { account: []const u8, list: []const u8, recipient: []const u8 };

  /// Verify `token`. Returns null on ANY failure — malformed, oversized, bad MAC,
  /// wrong version, wrong field count — deliberately indistinguishable (non-oracle).
  pub fn verify(alloc: std.mem.Allocator, jwt_secret: []const u8, token: []const u8) ?Parts {
      const dot = std.mem.indexOfScalar(u8, token, '.') orelse return null;
      const p_enc = token[0..dot];
      const m_enc = token[dot + 1 ..];
      if (p_enc.len == 0 or p_enc.len > max_part_len or m_enc.len == 0 or m_enc.len > max_part_len) return null;

      const p_len = b64.Decoder.calcSizeForSlice(p_enc) catch return null;
      const payload = alloc.alloc(u8, p_len) catch return null;
      b64.Decoder.decode(payload, p_enc) catch return null;

      var mac_given: [HmacSha256.mac_length]u8 = undefined;
      const m_len = b64.Decoder.calcSizeForSlice(m_enc) catch return null;
      if (m_len != mac_given.len) return null; // length-checked before any compare
      b64.Decoder.decode(&mac_given, m_enc) catch return null;

      const key = deriveKey(jwt_secret);
      var mac_want: [HmacSha256.mac_length]u8 = undefined;
      HmacSha256.create(&mac_want, payload, &key);
      if (!crypto.timingSafeEql(&mac_want, &mac_given)) return null; // constant-time

      // Parse "v1\x00account\x00list\x00recipient" — exactly four NUL-framed fields.
      var it = std.mem.splitScalar(u8, payload, 0);
      const ver = it.next() orelse return null;
      if (!std.mem.eql(u8, ver, "v1")) return null;
      const account = it.next() orelse return null;
      const list = it.next() orelse return null;
      const recipient = it.next() orelse return null;
      if (it.next() != null) return null;
      if (recipient.len == 0) return null;
      return .{ .account = account, .list = list, .recipient = recipient };
  }

  /// Build the full public unsubscribe URL: `<base>/api/mail/unsubscribe?t=<token>`.
  /// The token alphabet (base64url + '.') is URL- and header-safe as-is.
  pub fn buildUrl(alloc: std.mem.Allocator, base_url: []const u8, jwt_secret: []const u8, account: []const u8, list: []const u8, recipient: []const u8) ![]u8 {
      const token = try mint(alloc, jwt_secret, account, list, recipient);
      defer alloc.free(token);
      const base = std.mem.trimRight(u8, base_url, "/");
      return std.fmt.allocPrint(alloc, "{s}/api/mail/unsubscribe?t={s}", .{ base, token });
  }
  ```
  NOTE: confirm `crypto.timingSafeEql` accepts two `[]const u8` (it does — `src/crypto.zig:64`); pass `&mac_want`/`&mac_given` coerced to slices.
- [ ] Tests in `unsubscribe.zig`: round-trip (`mint` → `verify` returns the exact three fields, including empty account AND empty list); tampering (flip one byte in the payload half → null; flip one MAC byte → null; wrong secret → null; truncated/`"."`-less/oversized → null); key derivation is stable (`deriveKey("s")` equals itself and differs from `deriveKey("t")`); `buildUrl` output starts with the trimmed base and contains `?t=`.
- [ ] In `src/mail/suppression.zig`:
  1. Add `pub const reason_unsubscribe = "unsubscribe";` beside the other reasons.
  2. Add the kind and thread it through:
  ```zig
  /// Which send path is asking (#154 round 2). `transactional` (plain send()/enqueue/
  /// deliverAt) IGNORES `reason='unsubscribe'` rows — a user who opts out of the
  /// newsletter must still get password resets (RFC 8058 one-click is a LIST-mail
  /// mechanism). `list` (the bulk item handler) honors every reason. Bounce/complaint
  /// rows block BOTH kinds, exactly as today.
  pub const Kind = enum { transactional, list };

  pub fn isSuppressed(alloc: std.mem.Allocator, reader: *db.Db, account: []const u8, email_in: []const u8, kind: Kind) (db.DbError || std.mem.Allocator.Error)!bool {
      const email = try addr.normalize(alloc, email_in);
      defer alloc.free(email);
      var st = try reader.prepare(
          "SELECT 1 FROM \"_suppressions\" WHERE \"email\"=?1 AND (\"account\"='' OR \"account\"=?2) AND (?3=1 OR \"reason\"<>'unsubscribe') LIMIT 1;",
      );
      defer st.finalize();
      try st.bindText(1, email);
      try st.bindText(2, account);
      try st.bindInt(3, if (kind == .list) 1 else 0);
      return st.step();
  }

  pub fn assertNotSuppressed(alloc: std.mem.Allocator, reader: *db.Db, account: []const u8, email: []const u8, kind: Kind) SuppressionError!void {
      if (try isSuppressed(alloc, reader, account, email, kind)) return error.RecipientSuppressed;
  }
  ```
  3. Update EVERY call site: `send.zig` `enforce` passes `.transactional`; `bulk.zig` handler step 3 passes `.list` (change `isSuppressed(ctx.arena, &rd, batch.account, p.to)` → `…, p.to, .list)`); the existing suppression/send/inbound tests pass `.transactional` (their semantics are unchanged for bounce/complaint rows).
  4. Add the kind-matrix test:
  ```zig
  test "suppression kinds: unsubscribe blocks .list only; hard_bounce blocks both" {
      var d = try testDb();
      defer d.close();
      const a = testing.allocator;
      try upsert(testing.io, a, &d, "acc1", "opted-out@x.io", reason_unsubscribe, "one_click:news");
      try upsert(testing.io, a, &d, "acc1", "bounced@x.io", reason_hard_bounce, "ses");
      // unsubscribe: list blocked, transactional passes (password resets still deliver).
      try testing.expect(try isSuppressed(a, &d, "acc1", "opted-out@x.io", .list));
      try testing.expect(!try isSuppressed(a, &d, "acc1", "opted-out@x.io", .transactional));
      // hard bounce: both blocked.
      try testing.expect(try isSuppressed(a, &d, "acc1", "bounced@x.io", .list));
      try testing.expect(try isSuppressed(a, &d, "acc1", "bounced@x.io", .transactional));
  }
  ```
  and a `bulk.zig` test: upsert an `unsubscribe` suppression for one recipient → after draining, that row is `suppressed` with no capture, while `ctx.mail().send`-style transactional delivery to the same address still succeeds under `.check_suppression = true`.
- [ ] In `src/mail/config.zig`, add to `Runtime`:
  ```zig
  /// Public base URL for the one-click unsubscribe endpoint (#154 round 2), e.g.
  /// "https://app.example.com". EMPTY (default) = the feature is OFF: no
  /// List-Unsubscribe headers are emitted and the endpoint 404s (the same
  /// default-off pattern as `webhook_secret`). Set the comptime `.mail` key or the
  /// ZIGBASE_UNSUBSCRIBE_BASE_URL env var (env wins).
  unsubscribe_base_url: []const u8 = "",
  ```
  (+ extend the defaults test.)
- [ ] In `src/framework.zig` `mail_config` lowering (~line 960): add `"unsubscribe_base_url"` to the recognized keys, lower it, and validate the comptime literal loudly:
  ```zig
  if (@hasField(MC, "unsubscribe_base_url")) {
      const u = mc.unsubscribe_base_url;
      if (u.len > 0) {
          if (!std.mem.startsWith(u8, u, "http://") and !std.mem.startsWith(u8, u, "https://"))
              @compileError(".mail.unsubscribe_base_url must start with http:// or https://");
          for (u) |c| if (c <= ' ' or c == 127)
              @compileError(".mail.unsubscribe_base_url must not contain whitespace or control characters");
      }
      rt.unsubscribe_base_url = u;
  }
  ```
- [ ] In `src/config.zig`: add `unsubscribe_base_url: []const u8 = "",` to `Config` and `if (getter.get("ZIGBASE_UNSUBSCRIBE_BASE_URL")) |v| cfg.unsubscribe_base_url = v;` to `fromEnv` (+ one fromEnv test line). In `src/framework.zig` `serveImpl`, immediately after the `app_mod.App{…}` init (~line 1925, the struct that sets `.mail = opts.mail` at ~1954), thread + validate at startup (fail fast, mirroring the field-key refusal):
  ```zig
  // One-click unsubscribe (#154 round 2): env overrides the comptime .mail key so the
  // stock binary is configurable at runtime (and e2e-testable). Validate the EFFECTIVE
  // value fail-fast — a malformed base URL would mint dead links into outbound mail.
  if (cfg.unsubscribe_base_url.len > 0) app.mail.unsubscribe_base_url = cfg.unsubscribe_base_url;
  if (app.mail.unsubscribe_base_url.len > 0) {
      const u = app.mail.unsubscribe_base_url;
      var bad = !std.mem.startsWith(u8, u, "http://") and !std.mem.startsWith(u8, u, "https://");
      for (u) |c| {
          if (c <= ' ' or c == 127) bad = true;
      }
      if (bad) {
          std.log.err("refusing to start: ZIGBASE_UNSUBSCRIBE_BASE_URL / .mail.unsubscribe_base_url must be an http(s) URL with no whitespace/control chars (got \"{s}\")", .{u});
          return error.InvalidUnsubscribeBaseUrl;
      }
  }
  ```
- [ ] In `src/root.zig`, add `_ = @import("mail/unsubscribe.zig");` to the test block.
- [ ] Run `mise exec zig@0.16.0 -- zig build test --summary all` — all green.
- [ ] `git add -A && git commit -m "feat(mail): signed one-click unsubscribe token + suppression kinds (unsubscribe blocks list mail only) + unsubscribe_base_url config"`

---

### Task 7: Public unsubscribe endpoint + auto List-Unsubscribe wiring + `MailApi.unsubscribeUrl`

**Files:**
- Create: `src/api/mail_unsubscribe.zig`
- Modify: `src/server.zig` (two route-table entries)
- Modify: `src/mail/bulk.zig` (handler sets `list_unsubscribe` when configured; test)
- Modify: `src/ctx.zig` (`MailApi.unsubscribeUrl` escape hatch)
- Modify: `src/root.zig` (test block gains `api/mail_unsubscribe.zig`)

**Interfaces:**
- Produces: `POST /api/mail/unsubscribe?t=<token>` (RFC 8058 one-click target → upsert + **204 No Content**, also 204 when the row already existed — non-oracle), `GET /api/mail/unsubscribe?t=<token>` (confirmation page, NEVER mutates), both 404 when `unsubscribe_base_url` is unset and IP-rate-limited; bulk mail automatically carries the header. Consumed by Task 9 (e2e).

- [ ] Create `src/api/mail_unsubscribe.zig`:
  ```zig
  //! Public one-click unsubscribe endpoint (#154 round 2, RFC 8058). UNAUTHENTICATED by
  //! design (mail providers POST it on the user's behalf) — the SIGNED TOKEN is the
  //! authorization. Threat posture:
  //!   * 404 when `unsubscribe_base_url` is unset — the feature-off binary exposes only
  //!     the route-table entry and this branch (the `webhook_secret` pattern).
  //!   * ONE generic 400 for every invalid token (bad MAC, malformed, oversized…) — no
  //!     oracle distinguishing bad-signature from unknown-account.
  //!   * POST success is 204 No Content — ALSO when the suppression row already existed
  //!     (no "was this address known" oracle). Repo standard: side-effect success bodies
  //!     are 204, not ad-hoc JSON.
  //!   * GET NEVER mutates (link prefetchers/scanners must not unsubscribe people) — it
  //!     renders a minimal confirmation page whose button POSTs back.
  //!   * IP rate-limited via the shared RateLimiter (bounds token-grinding and
  //!     suppression-row spam).
  //! The suppression row: reason='unsubscribe' (blocks LIST mail only — transactional
  //! sends ignore it, see suppression.Kind), source='one_click:<list>' for audit.

  const std = @import("std");
  const http = @import("../http.zig");
  const clock = @import("../clock.zig");
  const params_mod = @import("../query/params.zig");
  const unsubscribe = @import("../mail/unsubscribe.zig");
  const suppression = @import("../mail/suppression.zig");
  const template = @import("../mail/template.zig");
  const ApiError = @import("error.zig").ApiError;

  /// Per-IP limit: plenty for humans + providers, hostile for grinders.
  pub const rate_max: u32 = 30;
  pub const rate_window_s: i64 = 60;

  pub fn post(ctx: *http.RequestCtx) anyerror!http.Response {
      return handle(ctx, true);
  }

  pub fn get(ctx: *http.RequestCtx) anyerror!http.Response {
      return handle(ctx, false);
  }

  fn handle(ctx: *http.RequestCtx, mutate: bool) anyerror!http.Response {
      const app = ctx.app orelse return ApiError.notFound().toResponse(ctx.allocator);
      // Feature off ⇒ the route "does not exist".
      if (app.mail.unsubscribe_base_url.len == 0) return ApiError.notFound().toResponse(ctx.allocator);

      // IP rate limit (shared limiter; honors ZIGBASE_TRUST_PROXY via ctx.remote_ip).
      if (app.rate_limiter) |rl| {
          const key = try std.fmt.allocPrint(ctx.allocator, "mail_unsub:ip:{s}", .{ctx.remote_ip});
          if (!rl.allowCustom(key, clock.nowUnix(app.io), rate_max, rate_window_s)) {
              return (ApiError{ .status = 429, .message = "Too many requests. Try again later." }).toResponse(ctx.allocator);
          }
      }

      const qp = params_mod.parse(ctx.allocator, ctx.query) catch null;
      const token = if (qp) |q| (q.get("t") orelse "") else "";
      const parts = unsubscribe.verify(ctx.allocator, app.jwt_secret, token) orelse
          return ApiError.badRequest("Invalid token.").toResponse(ctx.allocator); // ONE generic failure

      if (!mutate) return confirmPage(ctx, token);

      const source = try std.fmt.allocPrint(ctx.allocator, "one_click:{s}", .{parts.list});
      {
          const w = app.pool.acquireWriter();
          defer app.pool.releaseWriter();
          try suppression.upsert(app.io, ctx.allocator, w, parts.account, parts.recipient, suppression.reason_unsubscribe, source);
      }
      // 204 whether or not the row already existed (idempotent upsert; non-oracle).
      return .{ .status = 204, .body = "" };
  }

  /// Minimal self-contained confirmation page. The button POSTs back to this same
  /// endpoint with the same token; the token is interpolated HTML-ESCAPED (its
  /// base64url+'.' alphabet is inert anyway — defense in depth via the template engine).
  fn confirmPage(ctx: *http.RequestCtx, token: []const u8) !http.Response {
      const page_tpl =
          \\<!doctype html><html><head><meta charset="utf-8"><title>Unsubscribe</title></head>
          \\<body style="font-family:sans-serif;max-width:32em;margin:4em auto">
          \\<h1>Unsubscribe</h1>
          \\<p>Click the button below to stop receiving this mailing list. Transactional
          \\messages (password resets, receipts) are not affected.</p>
          \\<form method="post" action="?t={{ token }}"><button type="submit">Unsubscribe</button></form>
          \\</body></html>
      ;
      const body = try template.renderHtml(ctx.allocator, page_tpl, &.{.{ .key = "token", .value = token }}, &.{});
      return .{ .status = 200, .content_type = "text/html; charset=utf-8", .body = body };
  }
  ```
  NOTE: confirm `params_mod.parse`'s exact signature/return against its use in `src/api/files.zig:70` and `http.Response`'s field names (`content_type`, `body`) against `mail/inbound.zig`'s 200 response before writing; adapt mechanically if the getter is named differently.
- [ ] In `src/server.zig`: import `const mail_unsub_api = @import("api/mail_unsubscribe.zig");` and add to the `routes` table beside the mail webhook entry:
  ```zig
  // Email (#154 round 2): PUBLIC one-click unsubscribe (RFC 8058). 404 unless
  // unsubscribe_base_url is configured; signed-token authorized; GET never mutates.
  .{ .method = .POST, .pattern = "/api/mail/unsubscribe", .handler = mail_unsub_api.post },
  .{ .method = .GET, .pattern = "/api/mail/unsubscribe", .handler = mail_unsub_api.get },
  ```
- [ ] In `src/mail/bulk.zig` `jobHandler` step 4, wire the header (import `const unsubscribe = @import("unsubscribe.zig");`), just before building `msg`:
  ```zig
  // RFC 8058 headers ride ONLY list mail, and only when the feature is configured.
  // Emitted even when batch.list == "" (the token just carries an empty list).
  const list_unsub: ?[]const u8 = if (app.mail.unsubscribe_base_url.len > 0)
      try unsubscribe.buildUrl(ctx.arena, app.mail.unsubscribe_base_url, app.jwt_secret, batch.account, batch.list, p.to)
  else
      null;
  ```
  and add `.list_unsubscribe = list_unsub,` to the `MailMessage` literal.
- [ ] In `src/ctx.zig` `MailApi`, add the escape hatch:
  ```zig
  /// Escape hatch for hand-rolled list mail: the signed one-click unsubscribe URL for
  /// (account, list, recipient) — set it on your MailMessage.list_unsubscribe. Errors
  /// with `error.UnsubscribeNotConfigured` when `unsubscribe_base_url` is unset.
  pub fn unsubscribeUrl(self: MailApi, account: []const u8, list: []const u8, recipient: []const u8) ![]const u8 {
      const base = self.ctx.app.mail.unsubscribe_base_url;
      if (base.len == 0) return error.UnsubscribeNotConfigured;
      return mail_unsubscribe.buildUrl(self.ctx.arena, base, self.ctx.app.jwt_secret, account, list, recipient);
  }
  ```
  (with `const mail_unsubscribe = @import("mail/unsubscribe.zig");` at the top of ctx.zig).
- [ ] In `src/root.zig`, add `_ = @import("api/mail_unsubscribe.zig");` to the test block (beside `api/senders.zig`).
- [ ] Tests in `src/api/mail_unsubscribe.zig` (mirror `mail/inbound.zig`'s handler tests — real tmp-dir pool + migrations for the mutating cases, `pool = undefined` for pure-rejection paths; `App{ .allocator, .io, .pool, .jwt_secret = "test-secret", .mail = .{ .unsubscribe_base_url = "https://app.example" } }`):
  1. **POST valid → 204 + row:** mint via `unsubscribe.mint(a, "test-secret", "acc1", "news", "u@x.io")`, build `RequestCtx{ .method = .POST, .path = "/api/mail/unsubscribe", .query = "t=<token>", … }` → 204; `suppression.isSuppressed(a, reader, "acc1", "u@x.io", .list)` true and `.transactional` false; the row's `reason` is `unsubscribe` and `source` is `one_click:news`.
  2. **Repeat POST → 204** (idempotent, no oracle), still exactly one row.
  3. **Invalid/tampered/absent token → 400** with the generic message; no row written.
  4. **GET does not mutate:** valid token via GET → 200 HTML containing `method="post"`; suppression count still 0.
  5. **Feature off → 404:** `.mail = .{}` → 404 for both verbs even with a valid token.
  6. **Rate limit:** wire `var rl = ratelimit.RateLimiter.init(a, 1000, 60); app.rate_limiter = &rl;`, loop `rate_max` allowed calls then assert the next returns 429.
- [ ] `src/mail/bulk.zig` test: with `app.mail.unsubscribe_base_url = "https://app.example"` and `app.jwt_secret = "s"`, drain a 1-recipient batch → `cap.last().?.list_unsubscribe.?` starts with `https://app.example/api/mail/unsubscribe?t=` and `unsubscribe.verify` on its `t` value returns the batch's (account, list, recipient); with the base unset → `list_unsubscribe == null`. Also assert a plain `mail_send.send` capture has `list_unsubscribe == null` (transactional mail never carries it).
- [ ] Run `mise exec zig@0.16.0 -- zig build test --summary all` — all green.
- [ ] `git add -A && git commit -m "feat(mail): public RFC 8058 unsubscribe endpoint (204/400/404, GET never mutates, IP rate-limited) + auto List-Unsubscribe on bulk mail"`

---

### Task 8: Gmail-clipping size warning (>100 KB HTML)

**Files:**
- Modify: `src/mail/send.zig`

**Interfaces:**
- Produces: one `std.log.warn` per oversized send — a warning, NEVER an error. Consumed by docs (Task 10's "HTML that renders everywhere" note).

- [ ] In `src/mail/send.zig`, add near the top:
  ```zig
  /// Gmail clips messages around ~102KB and hides the rest behind "[Message clipped]"
  /// — which also hides the RFC 8058 unsubscribe footer if the template renders one.
  /// Warn (never error) above a round 100KB so list templates get fixed at dev time.
  pub const gmail_clip_warn_bytes: usize = 100 * 1024;
  ```
  and in `send`, after `try validate(msg);`:
  ```zig
  if (msg.html) |h| {
      if (h.len > gmail_clip_warn_bytes) std.log.warn(
          "mail: html body to {s} is {d} bytes (>100KB); Gmail clips ~102KB — the message may be truncated for recipients",
          .{ msg.to, h.len },
      );
  }
  ```
- [ ] Test (smoke — the log line is not assertable without a sink, and `sentry.log_sink` only captures errors; the test pins the behavior contract "warn, never error"):
  ```zig
  test "an oversized html body warns but still sends (never an error)" {
      const a = std.testing.allocator;
      const big = try a.alloc(u8, gmail_clip_warn_bytes + 1);
      defer a.free(big);
      @memset(big, 'x');
      var env = try EnforceEnv.init(.{});
      defer env.deinit();
      // No mailer wired → log-fallback path; the send must succeed despite the warning.
      try send(&env.app, a, .{ .to = "u@x.io", .subject = "big", .html = big });
  }
  ```
- [ ] Run `mise exec zig@0.16.0 -- zig build test --summary all` — all green.
- [ ] `git add -A && git commit -m "feat(mail): warn when an html body exceeds the ~100KB Gmail clipping threshold"`

---

### Task 9: Browser e2e — `tests/admin/test_mail_unsubscribe.py`

**Files:**
- Create: `tests/admin/test_mail_unsubscribe.py`

**Why this shape:** the stock binary (`src/main.zig`) declares **no durable queue and no bulk HTTP surface**, so the spec's "extend the existing queue/mail e2e with a sendBulk run" cannot execute in the browser suite (and no queue/mail e2e file exists to extend) — the full-engine bulk path (sendBulk → pollOnce → CaptureMailer + report rows, including a pre-suppressed recipient) is covered by the Task 3/6/7 Zig integration tests instead. What only e2e can prove — the live route table, the env-config path, real HTTP semantics, and the records-API read of the suppression store — is covered here. The unsubscribe feature IS runtime-configurable on the stock binary via `ZIGBASE_UNSUBSCRIBE_BASE_URL` (Task 6) with a pinned `ZIGBASE_JWT_SECRET`, so the test can mint valid tokens in Python.

- [ ] Create `tests/admin/test_mail_unsubscribe.py` (standalone module fixture, mirroring `test_state.py`'s `_http`/`_su_token` pattern — read those helpers first and reuse their exact shapes):
  ```python
  import base64, hashlib, hmac, json, os, shutil, socket, subprocess, tempfile, time, pytest
  import urllib.request, urllib.error
  from _bin import resolve_binary
  import pathlib

  REPO = pathlib.Path(__file__).resolve().parents[2]
  JWT_SECRET = "e2e-unsub-secret-0123456789abcdef"

  def _free_port():
      s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close(); return p

  def _http(method, url, body=None, token=None):
      data = json.dumps(body).encode() if body is not None else None
      req = urllib.request.Request(url, data=data, method=method)
      if body is not None: req.add_header("Content-Type", "application/json")
      if token: req.add_header("Authorization", f"Bearer {token}")
      try:
          with urllib.request.urlopen(req, timeout=5) as r:
              return r.status, r.read().decode()
      except urllib.error.HTTPError as e:
          return e.code, e.read().decode()

  def mint_token(secret: str, account: str, list_name: str, recipient: str) -> str:
      # Mirrors src/mail/unsubscribe.zig: key = HMAC-SHA256(jwt_secret, label);
      # payload = "v1\0account\0list\0recipient"; token = b64url(payload).b64url(mac).
      key = hmac.new(secret.encode(), b"zigbase.mail.unsub.v1", hashlib.sha256).digest()
      payload = b"v1\x00" + account.encode() + b"\x00" + list_name.encode() + b"\x00" + recipient.encode()
      mac = hmac.new(key, payload, hashlib.sha256).digest()
      b64 = lambda b: base64.urlsafe_b64encode(b).rstrip(b"=").decode()
      return f"{b64(payload)}.{b64(mac)}"

  @pytest.fixture(scope="module")
  def unsub_server():
      binary = resolve_binary("ZIGBASE_TEST_BINARY", REPO, "zigbase")
      data = tempfile.mkdtemp(prefix="zb_unsub_")
      env = {**os.environ, "ZIGBASE_DATA_DIR": data, "ZIGBASE_JWT_SECRET": JWT_SECRET}
      subprocess.run([binary, "superuser", "create", "--email", "admin@x.io",
                      "--password", "adminpassword", "--data-dir", data], check=True, env=env)
      port = _free_port()
      env["ZIGBASE_HTTP_PORT"] = str(port)
      env["ZIGBASE_UNSUBSCRIBE_BASE_URL"] = f"http://127.0.0.1:{port}"
      proc = subprocess.Popen([binary, "serve", "--insecure-cookies"], env=env,
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
      for _ in range(100):
          try:
              with socket.create_connection(("127.0.0.1", port), timeout=0.2): break
          except OSError: time.sleep(0.1)
      try:
          yield f"http://127.0.0.1:{port}"
      finally:
          proc.terminate(); proc.wait(timeout=5); shutil.rmtree(data, ignore_errors=True)

  def _su_token(base):
      status, body = _http("POST", f"{base}/api/collections/_superusers/auth-with-password",
                           body={"identity": "admin@x.io", "password": "adminpassword"})
      assert status == 200, body
      return json.loads(body)["token"]

  def test_one_click_post_writes_unsubscribe_suppression(unsub_server):
      t = mint_token(JWT_SECRET, "", "newsletter", "reader@example.com")
      status, body = _http("POST", f"{unsub_server}/api/mail/unsubscribe?t={t}")
      assert status == 204, body
      # Repeat POST: still 204 (idempotent, no already-existed oracle).
      status, _ = _http("POST", f"{unsub_server}/api/mail/unsubscribe?t={t}")
      assert status == 204
      # Verify through the superuser records API — _suppressions is a Locked system
      # collection (this ALSO proves the 0019 `updated` retrofit: the base-column
      # SELECT no longer errors).
      su = _su_token(unsub_server)
      status, body = _http("GET", f"{unsub_server}/api/collections/_suppressions/records", token=su)
      assert status == 200, body
      items = json.loads(body)["items"]
      rows = [r for r in items if r["email"] == "reader@example.com"]
      assert len(rows) == 1
      assert rows[0]["reason"] == "unsubscribe"
      assert rows[0]["source"] == "one_click:newsletter"

  def test_get_renders_confirmation_without_mutating(unsub_server):
      t = mint_token(JWT_SECRET, "", "digest", "getonly@example.com")
      status, body = _http("GET", f"{unsub_server}/api/mail/unsubscribe?t={t}")
      assert status == 200
      assert 'method="post"' in body  # a prefetcher following the link changes nothing
      su = _su_token(unsub_server)
      _, body = _http("GET", f"{unsub_server}/api/collections/_suppressions/records", token=su)
      assert all(r["email"] != "getonly@example.com" for r in json.loads(body)["items"])

  def test_invalid_token_is_generic_400(unsub_server):
      for bad in ["", "garbage", "a.b", mint_token("wrong-secret", "", "l", "x@y.io")]:
          status, body = _http("POST", f"{unsub_server}/api/mail/unsubscribe?t={bad}")
          assert status == 400, (bad, status, body)

  def test_bulk_report_collections_exist_and_are_locked(unsub_server):
      su = _su_token(unsub_server)
      # Superuser can list the (empty) send-report collections; anonymous cannot (Locked).
      for col in ("_mail_batches", "_mail_batch_recipients"):
          status, body = _http("GET", f"{unsub_server}/api/collections/{col}/records", token=su)
          assert status == 200, (col, body)
          assert json.loads(body)["items"] == []
          status, _ = _http("GET", f"{unsub_server}/api/collections/{col}/records")
          assert status in (401, 403, 404)
  ```
  NOTE: confirm before running that (a) `superuser create` accepts `--data-dir` (conftest.py uses exactly this form), (b) the records list envelope key is `items` (check `test_records.py`), and (c) the anonymous-Locked status code matches what `test_records.py` asserts for locked collections — adjust the `in (401, 403, 404)` set to the exact code the suite uses.
- [ ] Build the binary, then run the suite: `mise exec zig@0.16.0 -- zig build && mise exec python@3.13 -- python -m pytest tests/admin/test_mail_unsubscribe.py -q` — expect `4 passed`.
- [ ] Also run one neighboring suite file to catch route-table regressions: `mise exec python@3.13 -- python -m pytest tests/admin/test_records.py -q` — expect green.
- [ ] **Caveat:** the endpoint 404s unless `ZIGBASE_UNSUBSCRIBE_BASE_URL` is set — if the 204 asserts fail with 404, check the env threading from Task 6 first (this is precisely the e2e-only class of bug the browser suite exists for). Note the release binary is a NON-dev build with the same runtime env path, so nothing here depends on `dev_clock`/testcapture gates.
- [ ] `git add -A && git commit -m "test(e2e): one-click unsubscribe endpoint + suppression records-API round-trip + Locked send-report collections"`

---

### Task 10: Docs (+ site mirrors), KNOWN_LIMITATIONS, changelog fragment, final verification

**Files:**
- Modify: `docs/framework.md`, `site/src/content/docs/framework.md`, `KNOWN_LIMITATIONS.md`
- Create: `changelog.d/email-round-2.md`

**Interfaces:** none produced — documentation of everything above. `docs/superpowers/` is a historical archive: do NOT touch it.

- [ ] In `docs/framework.md`, REPLACE the "Deferred (planned 0.9.x fast-follows…)" paragraph (~line 678) with four new subsections under the Email-subsystem heading (each with a short runnable example; keep the existing voice):
  1. **"Bulk list sends (`sendBulk`)"** — the `BulkSend`/`BulkRecipient` shape; per-recipient rendering (HTML-escaped `{{ }}`, raw opt-in `{{{ }}}`); durable-queue requirement; the `{"batch","to"}` job fan-out rationale (per-recipient retry/backoff/priority/visibility-timeout/rate for free); the send-report — `batchStatus`, `cancelBatch` (stray jobs drain as no-ops), and superuser reads of `_mail_batches`/`_mail_batch_recipients` via the records API (Locked collections); always-on suppression for list mail vs the `check_suppression` knob; account attribution + verified-sender interplay; the at-least-once duplicate-send window (crash between backend-accept and the row update).
     ```zig
     const batch_id = try ctx.mail().sendBulk(.{
         .subject = "Hi {{ name }} — May updates",
         .html = "<p>Hi {{ name }},</p><p>…</p>",
         .list = "newsletter",
         .queue = "ses_mail",
         .recipients = &.{
             .{ .to = "a@example.com", .vars = &.{.{ .key = "name", .value = "Ann" }} },
             .{ .to = "b@example.com", .vars = &.{.{ .key = "name", .value = "Bo" }} },
         },
     });
     const report = try ctx.mail().batchStatus(batch_id); // {total, pending, sent, suppressed, invalid, failed, canceled}
     ```
  2. **"Scheduled sends + the drip recipe (`deliverAt` / `cancel`)"** — `EnqueueOpts.at`/`.delay_s` (mutually exclusive; durable-only), `deliverAt` returns the job id, `cancel(id) !bool` semantics (false = it already ran/is running), `.at` on `sendBulk`. Then the **"Drip sequences"** recipe verbatim in spirit: on trigger, `deliverAt` each step, persist the returned ids on your own record (or `ctx.kv()`), `cancel` the pending ones on conversion; cron + a query is the escape hatch for dynamic sequences — deliberately a recipe, not campaign machinery. Reference ONLY `deliverAt`/`enqueue`/`cancel` (never the deprecated alias being removed).
  3. **"One-click unsubscribe (RFC 8058)"** — `unsubscribe_base_url` (comptime `.mail` key or `ZIGBASE_UNSUBSCRIBE_BASE_URL`, empty = off: no headers, endpoint 404s); the signed stateless token (labeled derivation of the JWT secret — no new secret; no expiry, and why); the endpoint contract (POST one-click → 204 also on repeat, generic 400, GET renders confirmation and never mutates, per-IP rate limit); suppression semantics — `reason='unsubscribe'` blocks **list mail only**, account-global, list recorded in `source` for audit (per-list preference centers are app-level UX; the framework guarantees the compliance floor); always-on for bulk; `unsubscribeUrl` escape hatch for hand-rolled list mail; transactional mail never carries the headers.
  4. **"HTML that renders everywhere"** — the deferral note: author inline styles or run a build-time inliner (MJML/juice/premailer) over template sources and paste the output into `mail_template` sources (interpolation passes through untouched); host images at absolute HTTPS URLs (the app's file storage / static assets); keep HTML under ~100 KB (the framework warns above that). One sentence each on WHY CSS inlining and `cid:` attachments are out (wrong-styling footgun below a real selector engine; Raw-MIME rewrite cost vs hosted images).
- [ ] In `docs/framework.md` §7b (~line 2013 config block + the "Backends, priority, and reliability" bullets): add `.rate = .{ .per_second = 14 },  // durable only: per-queue send-rate ceiling (e.g. SES default 14/s)` to the queues example, and a bullet: **Rate throttling** — token bucket per rated queue (capacity = one second's tokens = the max burst), enforced at claim time; unclaimed jobs wait for the next ~500ms tick; in-process and single-process-authoritative (see Caveats); `.rate` on a memory queue is a compile error.
- [ ] Mirror EVERY edit into `site/src/content/docs/framework.md` (diff the two files' section headers first — the mirror's internal links use the site's `./…` form).
- [ ] `KNOWN_LIMITATIONS.md`: add three entries — (1) queue rate limiting is per-process/in-memory (authoritative only because the scheduler is single-process; multi-process coordination is out of scope); (2) durable delivery is at-least-once: a crash between provider-accept and the report-row update can produce one duplicate send (bulk and `"mail"` kind alike); (3) no CSS inliner / no `cid:` inline attachments — link the "HTML that renders everywhere" doc pattern.
- [ ] Create `changelog.d/email-round-2.md`:
  ```markdown
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
  ```
- [ ] Build the site: `cd site && mise exec node@24 -- npm install && mise exec node@24 -- npm run build` — expect success.
- [ ] Final full verification, in order:
  1. `mise exec zig@0.16.0 -- zig build test --summary all` → `Build Summary: … tests passed` (ignore the spurious `failed command:` line).
  2. `mise exec zig@0.16.0 -- zig build` → binary builds.
  3. `mise exec python@3.13 -- python -m pytest tests/admin/test_mail_unsubscribe.py tests/admin/test_records.py -q` → green.
  4. Examples still build (CI parity; additive surface should not touch them): `cd examples/blog && mise exec zig@0.16.0 -- zig build && cd ../..` (repeat for golfsim; plugins needs its `npm run build` first per CLAUDE.md — or rely on CI if local npm is unavailable, but say so in the PR).
- [ ] PR body: complete the template's docs-sync checklist; note the two documented deviations (204 endpoint contract per the repo API standard; bulk e2e realized as full-engine Zig integration because the stock binary declares no durable queue).
- [ ] `git add -A && git commit -m "docs(mail): bulk sends, scheduling + drip recipe, one-click unsubscribe, queue .rate; changelog fragment + known limitations"`

---

## Self-review: spec coverage map

- **§1 Bulk** — data model (Task 1, + the `updated` records-API fix the spec's own e2e depends on); `sendBulk`/`cancelBatch`/`batchStatus` + fail-fast validation + `withScope` attribution + submit-time verified-sender assert + one-writer-txn insert/enqueue (Task 3); idempotent handler steps 1–5 exactly as specced, incl. render-error→`invalid`, suppressed→reported-outcome, backend-error→attempts/terminal-`failed`/propagate reading the queue's RetryPolicy from the registry (Task 3); cancel-without-payload-matching via the handler's no-op check (Task 3 test 8).
- **§1 Rate** — `Rate`/`QueueDef.rate`, unrated queues claimed together unchanged, rated claimed per-queue `limit = min(remaining, tokens)`, process-global mutex-guarded lazy buckets, no worker sleeping, memory+rate `@compileError` (Task 4). Deviation: integer-second framework-clock refill instead of continuous monotonic (equivalent at tick granularity, FAKE_NOW-deterministic — documented in the code comment and below).
- **§2 Scheduling** — id-returning `durable.enqueue`, `EnqueueOpts.at/delay_s` + `ConflictingSchedule`, `ScheduleRequiresDurable`, `deliverAt`, `cancel` with the changes()==0 rule, gc reaps `canceled`, `claimBatch` untouched (Task 5); drip = documented recipe only (Task 10). Spec's `deliverLater` forwarding is superseded by the coordinator directive (alias being deleted); `enqueue` carries the scheduling forwarding instead and `deliverLater`'s lines are untouched.
- **§3 Unsubscribe** — token format/derivation/no-expiry/constant-time (Task 6); `unsubscribe_base_url` default-off validation at comptime AND startup + env source (Task 6); `Email.list_unsubscribe` single vetted field + buildMessage/SES-`Simple.Headers`(-not-ListManagementOptions)/Postmark emission (Task 2); endpoint POST/GET/400/404/rate-limit, GET-never-mutates, `reason='unsubscribe'`+`source='one_click:<list>'` (Task 7; success = 204 per repo standard, non-oracle preserved); `Kind` matrix with always-on bulk enforcement while `check_suppression` stays default-off for transactional (Task 6); auto-header on bulk incl. empty list, never on plain send, `unsubscribeUrl` escape hatch (Task 7).
- **§4 Hygiene** — >100KB warn (Task 8); "HTML that renders everywhere" + both deferral rationales (Task 10).
- **CaptureMailer** — `reply_to`/`list_unsubscribe` capture + `all`/`countTo` (Task 2), used throughout Tasks 3/6/7 tests.
- **Test plan** — every spec bullet mapped: bulk unit rows 1–9 (Task 3, kinds in Task 6), queue/token-bucket + pollOnce + compile-error-reverted-via-Edit (Task 4), durable enqueue-id/run_at/cancel/gc (Task 5), unsubscribe token suite (Task 6), mailer/SES/Postmark header tests (Task 2), suppression-kind matrix + oversized-html (Tasks 6/8), endpoint suite (Task 7), browser e2e (Task 9 — reshaped, see ambiguity list).
- **Docs checklist** — all boxes in Task 10 + root.zig re-exports/test-block distributed into Tasks 3/4/6/7; examples unchanged (verified building); fragment only, never CHANGELOG.md.
