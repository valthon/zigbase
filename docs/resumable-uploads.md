# Resumable uploads (opt-in)

Build with `-Dresumable-uploads=true` to resume interrupted **network transfers within one running process**. The default build includes no upload-session handlers, store, or runtime budgets. RAM sessions disappear on restart; another instance returns `404`. An additional explicit [SQLite persistence option](#sqlite-process-restart-persistence) preserves sessions across process restarts. Neither mode is tus, large-file streaming, direct-to-S3 upload, or a cross-instance capability service.

Sessions target one file field of an **existing record**. Commit goes through the normal record update: current collection schema and record, current update rules/tenant scope, file size/MIME constraints, hooks, transactional cleanup if configured, and realtime notifications. The backend receives its normal fully buffered `Storage.put`; local storage and configured storage plugins use that same contract. S3 may use its existing outbound multipart implementation, but the client session is still local RAM and does not survive restart.

## Budget configuration

The build flag pays the binary cost. Framework applications can adjust structure/resource budgets at comptime:

```zig
pub const App = zigbase.App(.{
    .files = .{ .resumable = .{
        .max_sessions = 8,
        .max_sessions_per_principal = 2,
        .max_upload_bytes = 8 << 20,
        .max_total_bytes = 32 << 20,
        .max_chunk_bytes = 1 << 20,
        .ttl_seconds = 900,
    } },
});
```

These are also the standalone defaults. Unknown keys or invalid budgets fail compilation: positive limits, principal sessions no greater than total sessions (maximum 1,024), chunk ≤ upload ≤ aggregate payload bytes (maximum 1 GiB), and TTL at most one day. Configuring the group without the build flag is an error.

The store allocates exactly the configured session-slot metadata on startup and allocates each complete declared payload lazily at session creation; it does not reserve the aggregate budget eagerly. Payload reservations count against `max_total_bytes` even before chunks arrive. Each live session additionally owns at most 2,295 bytes of bounded identifying metadata. Completed/failed tombstones count against session quotas but free their payload immediately. Expiry is fixed, never extended by chunks or reads. Reclamation is a bounded sweep **on API operations**, not a background timer: an idle process can retain expired payloads until its next operation or shutdown. Abort releases only a `receiving` session immediately; terminal slots cannot be manually reclaimed before expiry.

The per-principal session count and per-upload size impose an implicit per-principal payload bound of `max_sessions_per_principal * max_upload_bytes`, further limited by the aggregate budget. There is no independent per-principal byte budget, fairness guarantee, or protection against one actor using multiple principals. With defaults, four principals reserving two 4 MiB uploads each exhaust both the eight slots and 32 MiB payload budget; other callers receive `429` until reservations are aborted or expire. Even completed/failed uploads retain slots: one principal can exhaust its two slots after two quick commit attempts and must wait until their original 900-second TTLs expire. Size session counts and TTL for expected attempt throughput and the desired retry-acknowledgement window; shortening TTL also shortens that window. Use access rules and request rate limits to restrict who may consume capacity. These bounds limit resource use, not fair availability.

The aggregate bound covers retained payloads, **not total RSS**: HTTP bodies, request arenas, normal file planning, and backend buffers can allocate separately. The HTTP server's body limit also applies to individual chunks. A parking, I/O-aware store mutex serializes bounded allocation, ID generation, chunk copy, and state transitions. Durable mode also holds it while persisting those transitions, including waiting for the shared SQLite writer; contending operations park rather than busy-spin. The final storage transfer and record mutation run outside that mutex, with their session pinned. A commit already admitted before expiry may finish after `expiresAt`; expiry does not cancel a mutation in flight.

## Protocol

Every operation requires a fresh `Authorization: Bearer …` authentication. Cookie credentials alone are ignored. Session IDs contain OS randomness but **are not bearer authorization**: only the same authenticated principal in the same auth collection can use them. IDs appear in request paths and may appear in normal access logs; protect bearer credentials and never log Authorization headers. No stored privileges or tenant roles are reused at commit.

1. `POST /api/collections/{collection}/records/{record}/uploads` with JSON `{ "field": "attachment", "filename": "report.txt", "length": 4, "mimetype": "text/plain" }`. `mimetype` is optional and advisory; normal content sniffing applies at commit. Creation preauthorizes the existing record with an empty proposed update, before field-shape validation and reserving memory. Declared length exceeding the current file field's `maxSize` returns `413` without consuming slots or payload quota; commit checks current constraints again. Rules that require proposed body fields may deny creation; this slice does not accept accompanying record edits. Success is `201` with `{id, offset, length, expiresAt, state, durability}`. `offset` starts at zero, `state` is `receiving`, and `durability` is `process-local` for RAM sessions or `sqlite-restart` with SQLite persistence enabled.
2. `PATCH /api/uploads/{id}` with raw bytes, `Content-Type: application/octet-stream`, and the unsigned decimal `Upload-Offset` header. Success is `204`. An exact append advances the offset. A wholly acknowledged, byte-identical range is an idempotent retry; differing bytes, holes, partial overlaps, or writes beyond declared length return `409` without progress. Empty/oversized chunks return `400`.
3. `GET /api/uploads/{id}` returns `200` with the same status fields. Use its offset after a lost chunk response. A different principal, expired/aborted session, or wrong instance returns `404`; missing/invalid authentication returns `401`. A process restart also returns `404` for RAM sessions. SQLite persistence restores unexpired sessions after restart; the same principal must freshly authenticate.
4. `POST /api/uploads/{id}/commit` after all bytes are acknowledged. The atomic transition to `committing` pins the payload and rejects competing chunks, aborts, or commits with `409`. Commit independently verifies the current principal and the target collection's stable ID, so replacing a collection under the same name cannot redirect an old upload. Rules are checked again in the normal write transaction. Other record changes made before commit are preserved; conflicting changes during storage transfer are rejected by the normal upload snapshot checks.
5. `DELETE /api/uploads/{id}` aborts only a `receiving` session and returns `204`; subsequent operations return `404`. It returns `409` for `committing`, `completed`, and `failed`, preserving terminal acknowledgements until expiry. It never undoes a record mutation. Aborting an unknown ID is `404`, not a claim that a previous commit was cancelled.

Quota exhaustion returns `429` with the standard `too_many_requests` error code. Invalid metadata or declared length outside store budgets returns `400`; exceeding the current field's `maxSize` returns `413 payload_too_large` (the field limit is checked first). Unsupported/missing storage returns `501`. Other failures use the standard API error envelope.

### Commit retries and uncertain outcomes

Every admitted commit attempt is terminal. A confirmed database commit produces a `completed` tombstone and `204`. Repeating commit with valid same-principal credentials returns `204` **only to acknowledge that previous commit**: it does not read the record again, repeat hooks, or assert that permissions or file contents remain unchanged.

The acknowledgement window is the time remaining until the original `expiresAt`,
not a fresh TTL after commit: approximately `ttl_seconds` minus transfer and
commit duration. A transfer finishing near expiry leaves almost no retry window;
a commit finishing after expiry leaves none. Size TTL for the expected transfer
duration **plus** the desired acknowledgement window, while accounting for the
longer retention of abandoned payloads and terminal slots.

A failed attempt becomes `failed`, frees its payload, and cannot execute again (`409`). This includes failures before mutation, hook rejection, and indeterminate database/storage failures. Pre-commit writes use normal upload cleanup; a failing backend cleanup can still leave an orphan exactly as on ordinary uploads. A failure after confirmed DB commit still records `completed`, even if the original HTTP response fails. Inspect status after a lost response. If status is `failed` or unavailable, inspect the current record before deciding whether to start a new session: **no exactly-once guarantee crosses restart, expiry, or an indeterminate commit**. External side effects in before-hooks are not rollback-safe; use after-hooks as usual.

## SQLite process-restart persistence

Framework applications may additionally build with
`-Ddurable-resumable-uploads=true` and configure
`.files = .{ .resumable = .{ .durable = true } }` (plus any budgets above).
Both upload build flags are required. Merely compiling persistence does not enable
it. RAM remains the default, with no persistence tables, owner lock, or persistence
state when its build flag is absent. The [golfsim example](../examples/golfsim/README.md#resume-a-listing-photo-transfer)
exercises the opt-in configuration.

This mode requires file-backed SQLite and built-in local storage; PostgreSQL,
`:memory:`, S3 and custom storage are refused. Status reports
`durability: "sqlite-restart"`. The same principal, identified by its stable auth
collection ID as well as record ID, must freshly authenticate after restart.

- Creation reserves the complete declared payload in RAM **and** a SQLite BLOB,
  pre-writing the declared length as zero bytes under the shared writer lock.
  Restart reconstructs the bounded RAM store. This is persistence, not a reduction
  in upload memory. Payload BLOBs occupy separate rows from mutable session metadata,
  so updating an offset does not rewrite the payload record. Incremental BLOB writes
  and the acknowledged offset commit in one transaction. Begin/abort churn still
  incurs full-length allocation and database/WAL writes; size budgets accordingly.
- The record mutation and `completed` receipt commit in the same SQLite transaction.
  A lost response, including process death in an after-hook, can be acknowledged
  after restart without rerunning hooks. Recovery marks any remaining `committing`
  session `failed`: it never automatically retries an interrupted mutation.
  Hooks/realtime notifications are not a durable outbox and may be lost after the
  database commit. A precommit crash can leave an orphan local file; ordinary file
  reconciliation remains a separate maintenance operation.
- One process owns `<canonical-database-path>.zigbase-uploads.lock` immediately
  after pool opening, before migrations, provisioning or startup cleanup, through the
  upload-store lifetime. A competing durable owner fails before that boot work,
  including with `serve --ignore-lock`. Payload recovery remains after provisioning
  so their memory budgets do not overlap. Never remove or replace this permanent lock file.
  Use the same local database/storage paths across restarts; do not use hard-link
  aliases, network filesystems, or independently copied DB/storage pairs. This is
  cooperative single-owner recovery, not cross-instance resume or fencing against
  arbitrary external database writers.
- Fixed expiry, principal/aggregate quotas and terminal-slot retention survive
  restart. Startup removes expired sessions; normal operations also sweep expired
  slots. Configuration changes are refused while nonexpired sessions remain;
  drain/abort receiving sessions and wait for tombstones to expire before changing
  budgets. Unknown store versions and invalid state fail startup without silently
  discarding uploads: before sweeping even expired rows, recovery validates SQLite
  value types, IDs, bounded metadata, state/offset/payload relationships, and prior
  slot, principal and aggregate budgets. Committing and completed rows require full
  offsets; failed rows may retain partial offsets but no payload. Expired payloads
  are never loaded into RAM. Run a persistence-enabled process to reclaim idle data.
- A completion-receipt write failure returns `503`/`internal`. The record update
  rolls back and the session becomes `failed` if failure cleanup succeeds;
  inspect its status. Other uploads and record writes remain usable in that case.
  An uncertain store persistence operation stops upload operations with `503`/`internal`
  until restart, so RAM never silently diverges from an uncertain SQLite write.
  Inspect storage/database health before restarting. Unrelated routes ordinarily
  continue, but a **failed rollback of a live durable transaction terminates the
  process**. It cannot remain apparently healthy with an unusable shared writer.
  Inspect and recover the database before restarting; normal boot recovery marks
  interrupted commits failed without replaying their hooks.
- This promises **process-restart recovery**, not power-loss durability. SQLite's
  existing `synchronous=NORMAL` and local-file write behavior are unchanged.
  Retain the original client file; never treat this as end-to-end exactly-once
  delivery across expiry, external hooks, indeterminate failure, or machine loss.

Durable uploads additionally cap each payload at **999,983,360 bytes**: SQLite's
vendored 1,000,000,000-byte row limit minus 16 KiB of metadata and 256 bytes for
the remaining fields and row header. Startup checks the connection's actual
`SQLITE_LIMIT_LENGTH`, rejecting budgets that cannot fit the complete row before
creating or recovering upload state. RAM-only uploads retain the 1 GiB limit.

Budgets bound live reserved payloads and slot metadata, **not physical DB/WAL
size**. SQLite page overhead, WAL retention, free pages, request buffers and backend
copies are additional costs. Begin/append/cleanup use the shared SQLite writer;
database-generation-based public response caches are invalidated by these writes.
Measure upload load with caching enabled before tuning deployment budgets.
For a report-only comparison of the metadata/payload row layouts, run
`mise exec python@3.13 -- python tools/bench_upload_layout.py` from a checkout.
It builds vendored SQLite and measures the SQL/BLOB sequence, including creation
and WAL costs; it does not measure HTTP, RAM copies, or time waiting for locks.

Staged bytes and identifying metadata are persisted in the application database,
and consequently enter its backups. File-field encryption does not encrypt this
staging BLOB. Protect database/backups as sensitive uploaded content. Expiry and
abort are logical deletions, not secure erasure from pages, WAL or old backups.

The store format is version 2. Earlier experimental version-1 stores are refused,
not rewritten or discarded automatically. An existing partial upload schema or
one missing its settings/version marker is also refused, even when empty; only a
database without any upload tables is initialized as a fresh store.
Before upgrading an experimental build,
finish or abort uploads and retire its staging store while the old process is
stopped, preserving the application database and any receipts you need.
