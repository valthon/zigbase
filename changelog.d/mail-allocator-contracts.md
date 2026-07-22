### Fixes

- Fix several memory leaks in the mail subsystem, latent in the request/job-arena path but real
  under any non-arena allocator:
  - Bulk email: `bulk.sendBulk` never freed the per-recipient `vars_json`/durable-job `payload`
    scratch (freed per iteration now that SQLite/enqueue copy it), and `bulk.jobHandler` never
    freed the ~9 fields it rendered per delivery (now routed through a function-scoped scratch
    arena freed on every return path).
  - Inbound webhooks: `suppression.parseProvider`/`mapSes`/`mapPostmark` never freed the provider
    JSON parse tree and returned `Event.email` as a slice borrowed from it (now duped before the
    tree is freed); `inbound.ingest` discarded the suppression `Event` slice without freeing it;
    and `inbound.webhook_handler` leaked its response `ObjectMap`.

### Internal

- Restore real leak detection for the `mail/` subsystem: convert 27 of 28 arena-masked tests in
  `bulk`/`senders`/`suppression`/`inbound` to run under `std.testing.allocator`, removing three
  files from `scripts/allocator-allowlist.txt`. One `bulk` test remains arena-scoped pending a
  fix to `mail/unsubscribe.verify` (it returns slices into an unfreed decode buffer) — deferred
  to the dedicated mail-unsubscribe batch with its main consumer `api/mail_unsubscribe.zig`.
