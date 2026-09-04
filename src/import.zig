//! Offline, encryption-aware bulk record import (issue #283).
//!
//! Streams an NDJSON file (one JSON object per line) into a target collection **through the
//! record engine** — the same create/update path an HTTP request takes — WITHOUT the HTTP
//! server running. Every row therefore gets: field validation, autodate/required defaults,
//! the `.encrypted` at-rest envelope (fail-closed if a key is missing), and, for an auth
//! collection, the credential transforms (password hashing, `tokenKey`, `verified=false`).
//! This closes the "hand-written SQL bypasses validation + encryption" foot-gun called out
//! in the issue: the only way in is the engine.
//!
//! Design notes:
//!   - **Streaming.** Lines are read one at a time via a buffered `std.Io.Reader`; the whole
//!     file is never slurped. A single record line must fit the caller's line buffer.
//!   - **Batched transactions.** Rows are committed in batches of `batch_size` on the writer
//!     connection. A bad row (malformed JSON, validation failure, duplicate id) FAILS FAST:
//!     the current (uncommitted) batch is rolled back and a line-numbered error is returned.
//!     Batches committed before the failure persist (a resumable checkpoint).
//!   - **Id preservation.** By default the source record's own `id` is preserved (relations
//!     across an exported dataset stay intact). This routes through the IMPORT-ONLY
//!     `records.createInTxnOpts(.{ .allow_provided_id = true })`; the HTTP/route/hook create
//!     path can never reach it (it uses the plain `create`, which always generates the id).
//!   - **Upsert.** With `--upsert-key <field>` each row is matched by that field's value and
//!     UPDATEd if present, else created (idempotent re-import). The key field name and the
//!     collection name are gated through `schema.isValidIdentifier` before interpolation
//!     (the SQL-injection chokepoint); the key's value binds as a parameter. An encrypted
//!     field can never be an upsert key (its ciphertext is non-filterable) — rejected.
//!
//! Library entrypoint: `run` (re-exported as `zigbase.Import.run`). The `zigbase import` CLI
//! subcommand (framework.zig `importImpl`) boots the app offline via `bootApp` and calls it.

const std = @import("std");
const db = @import("db.zig");
const schema = @import("schema.zig");
const collections = @import("collections.zig");
const records = @import("records.zig");
const auth = @import("auth.zig");
const crypto = @import("crypto.zig");
const datetime = @import("datetime.zig");
const param_sink = @import("sql/param_sink.zig");
const ddl = @import("ddl.zig");
const app_mod = @import("app.zig");
const oauth = @import("api/oauth.zig");

pub const App = app_mod.App;

/// Import options. `preserve_ids` defaults true (see the id-preservation note above).
pub const Options = struct {
    /// Target collection name (must already exist; `bootApp` provisions comptime `.collections`).
    collection: []const u8,
    /// When set, upsert by this field instead of always inserting. Must be a scalar,
    /// non-encrypted, existing field; identifier-gated before interpolation.
    upsert_key: ?[]const u8 = null,
    /// Rows per transaction. Must be >= 1.
    batch_size: usize = 500,
    /// Preserve each row's own `id` when present (relation integrity across a dataset).
    preserve_ids: bool = true,
    /// Preserve each row's source `created` and `updated` system timestamps. Import-only,
    /// create-only, and requires a provided id; HTTP writes cannot reach this seam.
    preserve_timestamps: bool = false,
    /// Validate and execute every row, then ROLL BACK each batch instead of committing.
    /// Nothing is written. Note: because nothing commits, an `--upsert-key` lookup never
    /// sees rows created earlier in the same dry run — a dry run reports what a FRESH
    /// import would do.
    dry_run: bool = false,
    /// Record the failure and keep going instead of aborting. Each row is wrapped in a
    /// SAVEPOINT so a failed row leaves the in-flight batch intact.
    continue_on_error: bool = false,
    /// NDJSON sink for per-row failures: one object per line,
    /// `{"line":N,"code":"Validation","detail":"title: … (validation_required)"}`.
    error_log: ?*std.Io.Writer = null,
    /// Write a human progress line to `progress` every N rows (0 = off).
    progress_every: usize = 0,
    progress: ?*std.Io.Writer = null,
    /// Field names to drop from every row before importing. The manifest runner uses this
    /// to hold back relation values it will patch in a second pass.
    strip_fields: []const []const u8 = &.{},
    /// Enable the legacy-credential seam for this run, tagging each row's `passwordHash`
    /// with this algorithm. Only values in `crypto.legacy_algorithms` are accepted.
    /// Requires an auth collection; refuses `_superusers`.
    legacy_hash_algorithm: ?[]const u8 = null,
    /// Install each row's `externalAuths` array as provider linkage in `_externalAuths`.
    /// Off by default so a file cannot mint an identity link an operator did not ask for --
    /// the same property that makes an ignored `passwordHash` safe without `--legacy-hashes`.
    /// Requires an auth collection with the named providers configured; refuses `_superusers`.
    external_auths: bool = false,
};

/// Row counts reported at completion.
pub const Report = struct {
    created: usize = 0,
    updated: usize = 0,
    /// Rows that failed and were skipped (only ever non-zero under `continue_on_error`).
    failed: usize = 0,
    total: usize = 0,
};

/// The 1-based line number of the row that caused the most recent `run` failure (0 when the
/// failure was not row-specific, e.g. a config/collection error). Mirrors `records.last_errors`:
/// a threadlocal the CLI reads AFTER `run` returns an error, to compose a line-numbered message
/// (field-level detail on `error.Validation` comes from `records.last_errors`). Keeping the
/// library free of `.err`-level logging is deliberate — the Zig test runner fails any test that
/// emits one, so presentation lives at the CLI boundary (`framework.importImpl`).
pub threadlocal var last_error_line: usize = 0;

/// Backing store + view for a human-readable detail of the most recent `run` failure (e.g. the
/// failing field on `error.Validation`), captured INSIDE `run` while the engine's arena-owned
/// `records.last_errors` is still alive — the CLI must NOT dereference `records.last_errors`
/// after `run` returns (that memory is freed with `run`'s per-row arena). Empty when there is no
/// extra detail beyond the error name.
threadlocal var last_error_detail_buf: [256]u8 = undefined;
pub threadlocal var last_error_detail: []const u8 = "";

const RowOutcome = enum { created, updated };

/// Import errors surfaced by `run` beyond the engine's own `records.RecordError` /
/// `db.DbError`. On a row-specific failure `last_error_line` is set to the offending 1-based
/// line before the error is returned; config errors leave it 0. The CLI presents them.
pub const ImportError = error{
    InvalidBatchSize,
    InvalidCollectionName,
    UnknownCollection,
    InvalidUpsertKey,
    UnknownUpsertKey,
    EncryptedUpsertKey,
    UnsupportedUpsertKeyValue,
    MalformedJson,
    RowNotObject,
    DuplicateId,
    RowVanishedMidImport,
    LineTooLong,
    LegacyRequiresAuthCollection,
    LegacySuperuserRefused,
    LegacyRowMissingId,
    LegacyHashConflict,
    LegacyRequiresPreservedIds,
    LegacyRequiresCreateOnly,
    TimestampRequiresPreservedIds,
    TimestampRequiresCreateOnly,
    TimestampRowMissingId,
    TimestampMissing,
    TimestampInvalid,
    ExternalAuthRequiresAuthCollection,
    ExternalAuthSuperuserRefused,
    ExternalAuthRequiresPreservedIds,
    ExternalAuthRequiresCreateOnly,
    ExternalAuthRowMissingId,
    MalformedExternalAuth,
    UnknownExternalAuthProvider,
    DuplicateExternalAuth,
};

/// Renumber `?N` placeholders for the active backend before preparing (SQLite verbatim,
/// Postgres `$n`) — mirrors the private `prep` helper in records.zig so import statements
/// work on both backends.
fn prep(a: std.mem.Allocator, w: *db.Db, sql: [:0]const u8) !db.Stmt {
    return w.prepare(try param_sink.renumberZ(a, db.dbDialect(w), sql));
}

fn findField(col: schema.Collection, name: []const u8) ?schema.Field {
    for (col.fields) |f| if (std.mem.eql(u8, f.name, name)) return f;
    return null;
}

/// Best-effort uniqueness check for an upsert key: the field's own `.unique`, or a unique
/// index over exactly this one field. Used only to WARN (a non-unique key can silently
/// update the wrong row); never fatal.
fn fieldLooksUnique(col: schema.Collection, name: []const u8) bool {
    if (findField(col, name)) |f| if (f.unique) return true;
    for (col.indexes) |ix| {
        if (ix.unique and ix.fields.len == 1 and std.mem.eql(u8, ix.fields[0], name)) return true;
    }
    return false;
}

/// Bind a scalar JSON value as the upsert-key lookup parameter. Only scalar shapes are
/// filterable; a multi-value/object key is rejected (matches the "not filterable" contract).
fn bindScalar(st: *db.Stmt, idx: c_int, v: std.json.Value) !void {
    switch (v) {
        .string => |s| try st.bindText(idx, s),
        .integer => |n| try st.bindInt(idx, n),
        .float => |x| try st.bindDouble(idx, x),
        .bool => |b| try st.bindInt(idx, if (b) 1 else 0),
        .null => try st.bindNull(idx),
        else => return ImportError.UnsupportedUpsertKeyValue,
    }
}

/// Look up an existing record id by the upsert key's value on the RE-USED lookup statement `st`
/// (prepared once per `run`). Returns null (⇒ create) when the row omits the key or nothing
/// matches. The statement is reset before binding and again after reading, so it never holds a
/// row cursor across the batch's commit boundary. The returned id is duped into `a` (the per-row
/// arena) BEFORE the reset, since `columnText` borrows statement-owned memory that reset frees.
fn findExistingId(a: std.mem.Allocator, st: *db.Stmt, key: []const u8, data: std.json.Value) !?[]const u8 {
    const key_val = data.object.get(key) orelse return null;
    if (key_val == .null) return null;
    st.reset();
    try bindScalar(st, 1, key_val);
    if (!try st.step()) {
        st.reset();
        return null;
    }
    const id = try a.dupe(u8, st.columnText(0));
    st.reset(); // release the row cursor so the next commit isn't blocked by an active statement
    return id;
}

/// True if `data` carries a non-empty string `id`.
fn hasProvidedId(data: std.json.Value) ?[]const u8 {
    if (data.object.get("id")) |idv| {
        if (idv == .string and idv.string.len > 0) return idv.string;
    }
    return null;
}

/// Create one row through the engine, preserving its id when asked. Auth collections take the
/// same provisioning path as `Data.create` (password hashing, `tokenKey`, `verified=false`) so
/// imported accounts are immediately usable — the "awesome" auth-parity choice from the issue.
fn createRow(app: *App, w: *db.Db, io: std.Io, a: std.mem.Allocator, col: schema.Collection, data: std.json.Value, preserve_ids: bool) !void {
    const opts = records.CreateOpts{ .allow_provided_id = preserve_ids };
    if (col.type != .auth) {
        _ = try records.createInTxnOpts(a, io, w, col, data, opts);
        return;
    }
    // Auth parity: hash password, generate tokenKey, force verified=false. applyProvision
    // does NOT strip `id`, so a preserved id still flows through to createInTxnOpts. `a` is a
    // per-row arena, so the duped keys/creds are freed by the arena reset (no freeProvisioned).
    _ = app; // app reserved for future auth-collection lookups; unused today.
    const prepped = try auth.applyProvision(io, a, data, col.options.auth.minPasswordLength);
    _ = try records.createInTxnOpts(a, io, w, col, prepped, opts);
}

/// Install an imported credential. Runs INSIDE the row's transaction, right after the
/// record is created, so the row and its credential commit or roll back together.
///
/// This is the ONLY writer of a `$zblegacy$` value anywhere in the codebase. The HTTP path
/// cannot reach it: `auth.isServerManagedField` strips `passwordHash`/`verified` from every
/// client payload, and that strip is unchanged.
fn applyLegacyCredential(
    w: *db.Db,
    a: std.mem.Allocator,
    col: schema.Collection,
    data: std.json.Value,
    algorithm: []const u8,
) !void {
    const idv = data.object.get("id") orelse return ImportError.LegacyRowMissingId;
    if (idv != .string or idv.string.len == 0) return ImportError.LegacyRowMissingId;
    if (data.object.get("password") != null and data.object.get("passwordHash") != null)
        return ImportError.LegacyHashConflict;

    var tagged: ?[]const u8 = null;
    if (data.object.get("passwordHash")) |hv| {
        if (hv != .string or hv.string.len == 0) return crypto.LegacyError.MalformedLegacyHash;
        // Validates the algorithm allowlist AND the hash format; a bad credential is
        // rejected while an operator is watching, not at some user's next login.
        tagged = try crypto.wrapLegacy(a, algorithm, hv.string);
    }
    var verified: ?bool = null;
    if (data.object.get("verified")) |vv| {
        if (vv == .bool) verified = vv.bool;
    }
    if (tagged == null and verified == null) return;

    // `col.name` came from `_collections` and passed `schema.isValidIdentifier` on creation;
    // re-check before interpolating, per the repo's identifier discipline.
    if (!schema.isValidIdentifier(col.name)) return ImportError.InvalidCollectionName;
    const sql = try std.fmt.allocPrintSentinel(
        a,
        "UPDATE \"{s}\" SET \"passwordHash\" = COALESCE(?2, \"passwordHash\"), \"verified\" = COALESCE(?3, \"verified\") WHERE \"id\" = ?1;",
        .{col.name},
        0,
    );
    // Routed through `prep` (not a bare `w.prepare`) so the `?N` placeholders are renumbered
    // for the active backend (SQLite verbatim, Postgres `$n`) — matches every other
    // statement in this file.
    var st = try prep(a, w, sql);
    defer st.finalize();
    try st.bindText(1, idv.string);
    if (tagged) |t| try st.bindText(2, t) else try st.bindNull(2);
    if (verified) |v| try st.bindInt(3, if (v) 1 else 0) else try st.bindNull(3);
    _ = try st.step();
}

/// Install a row's provider linkage. Runs INSIDE the row's transaction, right after the
/// record is created, so the account and the identity that reaches it commit or roll back
/// together -- a half-migrated user who exists but cannot sign in is the failure this seam
/// exists to prevent.
///
/// Like `applyLegacyCredential`, the HTTP path cannot reach this: `auth.isServerManagedField`
/// strips `externalAuths` from every client payload, so linkage is operator-only.
///
/// A link is authentication: whoever holds `(provider, providerId)` becomes this record. So
/// every refusal below is deliberate rather than defensive -- a typo'd provider that silently
/// produced a dangling link, or a duplicate quietly upserted onto another account, would both
/// hand a login to the wrong person.
fn applyExternalAuths(
    io: std.Io,
    w: *db.Db,
    a: std.mem.Allocator,
    col: schema.Collection,
    data: std.json.Value,
) !void {
    const raw = data.object.get("externalAuths") orelse return;
    if (raw != .array) return ImportError.MalformedExternalAuth;
    if (raw.array.items.len == 0) return;

    const idv = data.object.get("id") orelse return ImportError.ExternalAuthRowMissingId;
    if (idv != .string or idv.string.len == 0) return ImportError.ExternalAuthRowMissingId;

    for (raw.array.items) |entry| {
        if (entry != .object) return ImportError.MalformedExternalAuth;
        const pv = entry.object.get("provider") orelse return ImportError.MalformedExternalAuth;
        const iv = entry.object.get("providerId") orelse return ImportError.MalformedExternalAuth;
        if (pv != .string or pv.string.len == 0) return ImportError.MalformedExternalAuth;
        if (iv != .string or iv.string.len == 0) return ImportError.MalformedExternalAuth;

        // The provider must be one this collection actually declares. A link naming a
        // provider that was never configured can never resolve at login, so importing it
        // would report success and leave the account unreachable -- exactly the outcome
        // this whole feature exists to fix.
        if (!providerConfigured(col, pv.string)) {
            last_error_detail = "no such OAuth2 provider on this collection; configure it in the schema before importing linkage";
            return ImportError.UnknownExternalAuthProvider;
        }

        // Both unique indexes are pre-checked so a collision is a named refusal rather than a
        // raw constraint failure, and NEVER an upsert: silently re-pointing an existing
        // identity at a different record is account takeover.
        if (try oauth.findLink(a, w, pv.string, iv.string)) |link| {
            last_error_detail = if (std.mem.eql(u8, link.recordRef, idv.string))
                "this identity is already linked to this record"
            else
                "this identity is already linked to a different record";
            return ImportError.DuplicateExternalAuth;
        }
        if (try recordHasProvider(a, w, col.name, idv.string, pv.string)) {
            last_error_detail = "this record already has a link for that provider";
            return ImportError.DuplicateExternalAuth;
        }

        try oauth.insertLink(io, a, w, col.name, idv.string, pv.string, iv.string);
    }
}

/// True when `col` declares an OAuth2 provider named `name` that could actually resolve a
/// sign-in. This deliberately mirrors `api/oauth.zig`'s `findProvider` gate -- collection-level
/// `oauth2.enabled` AND the provider's own `enabled` -- because a link the login path would
/// skip is exactly as useless as one naming a provider that was never declared: the account
/// exists and nothing reaches it. Accepting a disabled provider here would reinstate, through
/// the back door, the failure this whole seam removes.
fn providerConfigured(col: schema.Collection, name: []const u8) bool {
    if (!col.options.auth.oauth2.enabled) return false;
    for (col.options.auth.oauth2.providers) |p| {
        if (p.enabled and std.mem.eql(u8, p.name, name)) return true;
    }
    return false;
}

/// The `(collectionRef, recordRef, provider)` half of the uniqueness contract.
fn recordHasProvider(a: std.mem.Allocator, w: *db.Db, col_name: []const u8, record_id: []const u8, provider: []const u8) !bool {
    // Routed through `prep` so the `?N` placeholders are renumbered for the active backend
    // (SQLite verbatim, Postgres `$n`) -- same discipline as every other statement here.
    var st = try prep(a, w,
        \\SELECT 1 FROM "_externalAuths" WHERE "collectionRef"=?1 AND "recordRef"=?2 AND "provider"=?3;
    );
    defer st.finalize();
    try st.bindText(1, col_name);
    try st.bindText(2, record_id);
    try st.bindText(3, provider);
    return try st.step();
}

const SourceTimestamps = struct {
    id: []const u8,
    created: [20]u8,
    updated: [20]u8,
};

/// Validate the three values needed by the timestamp-preservation seam before the engine
/// creates anything. Accepted source shapes are normalized to the same UTC `T...Z` form used
/// by native API rows so text ordering and filtering remain correct after migration.
fn sourceTimestamps(data: std.json.Value) ImportError!SourceTimestamps {
    const idv = data.object.get("id") orelse return ImportError.TimestampRowMissingId;
    if (idv != .string or idv.string.len == 0) return ImportError.TimestampRowMissingId;
    const created = data.object.get("created") orelse return ImportError.TimestampMissing;
    const updated = data.object.get("updated") orelse return ImportError.TimestampMissing;
    if (created != .string or updated != .string or created.string.len == 0 or updated.string.len == 0)
        return ImportError.TimestampInvalid;
    const created_unix = datetime.parse(created.string) catch return ImportError.TimestampInvalid;
    const updated_unix = datetime.parse(updated.string) catch return ImportError.TimestampInvalid;
    return .{
        .id = idv.string,
        .created = datetime.formatIsoUtc(created_unix),
        .updated = datetime.formatIsoUtc(updated_unix),
    };
}

/// Replace only the system timestamps on the row just created by the normal record engine.
/// The caller's batch transaction/savepoint makes this update atomic with creation and any
/// legacy credential installation.
fn applySourceTimestamps(st: *db.Stmt, ts: SourceTimestamps) !void {
    st.reset();
    errdefer st.reset();
    try st.bindText(1, ts.id);
    try st.bindText(2, &ts.created);
    try st.bindText(3, &ts.updated);
    _ = try st.step();
    st.reset();
}

/// Reusable timestamp restorer for manifest phase-2 relation patches. Record updates normally
/// advance `updated`; a timestamp-preserving import must put both source values back after each
/// deferred patch so cyclic relations do not silently destroy migration history.
pub const TimestampRestorer = struct {
    statement: db.Stmt,

    pub fn init(a: std.mem.Allocator, w: *db.Db, col: schema.Collection) !TimestampRestorer {
        var scratch = std.heap.ArenaAllocator.init(a);
        defer scratch.deinit();
        const sa = scratch.allocator();
        const sql = try std.fmt.allocPrintSentinel(
            sa,
            "UPDATE {s} SET \"created\"=?2, \"updated\"=?3 WHERE \"id\"=?1;",
            .{try ddl.quoteIdent(sa, col.name)},
            0,
        );
        return .{ .statement = try prep(sa, w, sql) };
    }

    pub fn deinit(self: *TimestampRestorer) void {
        self.statement.finalize();
    }

    pub fn apply(self: *TimestampRestorer, data: std.json.Value) !void {
        try applySourceTimestamps(&self.statement, try sourceTimestamps(data));
    }
};

test "TimestampRestorer init releases SQL scratch under a general allocator" {
    var d = try db.Db.openMemory();
    defer d.close();
    try d.exec("CREATE TABLE notes (id TEXT PRIMARY KEY, created TEXT, updated TEXT);");
    const col = schema.Collection{ .id = "notes-id", .name = "notes", .fields = &.{} };
    var restorer = try TimestampRestorer.init(std.testing.allocator, &d, col);
    defer restorer.deinit();
}

/// Per-run statements prepared ONCE and reused for every row via reset/re-bind — avoiding an N+1
/// prepare per row. Exactly one read statement is non-null: `upsert` with `--upsert-key`, or
/// `dup_check` when preserving ids without a key. `timestamp_update` is independently present when
/// source timestamps are preserved. All are connection-scoped and reset before batch boundaries.
const Lookups = struct {
    upsert: ?db.Stmt = null,
    dup_check: ?db.Stmt = null,
    timestamp_update: ?db.Stmt = null,

    fn finalize(self: *Lookups) void {
        if (self.upsert) |*s| s.finalize();
        if (self.dup_check) |*s| s.finalize();
        if (self.timestamp_update) |*s| s.finalize();
    }
};

/// Import a single already-parsed JSON object. The caller records the 1-based line on failure.
fn importRow(app: *App, w: *db.Db, io: std.Io, a: std.mem.Allocator, col: schema.Collection, data: std.json.Value, opts: Options, lookups: *Lookups) !RowOutcome {
    const timestamps = if (opts.preserve_timestamps) try sourceTimestamps(data) else null;
    if (opts.upsert_key) |key| {
        if (try findExistingId(a, &lookups.upsert.?, key, data)) |existing_id| {
            // Update the matched row's provided fields. Note: an auth `password` on UPDATE is
            // not re-hashed (there is no `password` column) — same as the Data.update path;
            // credential rotation is not an import-update concern.
            _ = (try records.updateInTxn(a, w, col, existing_id, data)) orelse
                // The SELECT saw it a statement ago inside this same txn; a null here would be a
                // genuine engine inconsistency, not a normal miss.
                return ImportError.RowVanishedMidImport;
            return .updated;
        }
        // Fall through to create (no existing match).
    } else if (opts.preserve_ids) {
        // No upsert key: a provided id that already exists would hit the PK constraint. Detect
        // it up front for a clean error instead of a raw SQLite constraint failure — on the
        // per-run reused statement (reset before/after so no cursor spans the commit boundary).
        if (hasProvidedId(data)) |id| {
            const st = &lookups.dup_check.?;
            st.reset();
            try st.bindText(1, id);
            const exists = try st.step();
            st.reset();
            if (exists) return ImportError.DuplicateId;
        }
    }
    try createRow(app, w, io, a, col, data, opts.preserve_ids);
    if (opts.legacy_hash_algorithm) |alg| try applyLegacyCredential(w, a, col, data, alg);
    if (opts.external_auths) try applyExternalAuths(io, w, a, col, data);
    if (timestamps) |ts| try applySourceTimestamps(&lookups.timestamp_update.?, ts);
    return .created;
}

/// Write one NDJSON finding. Never fails the import: a full or broken sink loses the
/// finding, not the data — the counters in the Report remain authoritative. `detail` is run
/// through `std.json.fmt` (which itself emits the surrounding quotes and escapes) so a quote
/// or newline in a validation message cannot corrupt the NDJSON line.
fn logFinding(opts: Options, line_no: usize, code: []const u8, detail: []const u8) void {
    const sink = opts.error_log orelse return;
    sink.print(
        "{{\"line\":{d},\"code\":\"{s}\",\"detail\":{f}}}\n",
        .{ line_no, code, std.json.fmt(detail, .{}) },
    ) catch {};
}

/// Print a progress line to `opts.progress` every `opts.progress_every` rows. `seen` is the
/// 1-based line number just processed (blank lines included, matching how `line_no` is
/// counted in `run`).
fn tickProgress(opts: Options, seen: usize) void {
    if (opts.progress_every == 0) return;
    if (seen % opts.progress_every != 0) return;
    const sink = opts.progress orelse return;
    sink.print("import: {d} rows read\n", .{seen}) catch {};
    sink.flush() catch {};
}

/// One import batch. Standalone imports own a transaction; a manifest-wide dry run already
/// has one open, so batches join it through a savepoint and leave the outer scope in charge
/// of the final rollback.
pub const WriteScope = struct {
    const savepoint = "zb_import_batch";

    w: *db.Db,
    nested: bool,

    pub fn begin(w: *db.Db) db.DbError!WriteScope {
        const nested = w.inTransaction();
        if (nested) try w.exec("SAVEPOINT " ++ savepoint ++ ";") else try w.begin();
        return .{ .w = w, .nested = nested };
    }

    pub fn close(self: WriteScope, dry_run: bool) db.DbError!void {
        if (self.nested) {
            if (dry_run) try self.w.exec("ROLLBACK TO SAVEPOINT " ++ savepoint ++ ";");
            return self.w.exec("RELEASE SAVEPOINT " ++ savepoint ++ ";");
        }
        if (dry_run) return self.w.rollback();
        return self.w.commit();
    }

    pub fn rollback(self: WriteScope) void {
        if (self.nested) {
            self.w.exec("ROLLBACK TO SAVEPOINT " ++ savepoint ++ ";") catch return;
            self.w.exec("RELEASE SAVEPOINT " ++ savepoint ++ ";") catch {};
            return;
        }
        self.w.rollback() catch {};
    }
};

/// Parse one NDJSON line and import it. Split out of `run` so the malformed-JSON and the
/// engine-error paths share one savepoint/finding/counter treatment.
fn importOneRow(
    app: *App,
    w: *db.Db,
    io: std.Io,
    a: std.mem.Allocator,
    col: schema.Collection,
    line: []const u8,
    opts: Options,
    lookups: *Lookups,
) !RowOutcome {
    var parsed = std.json.parseFromSliceLeaky(std.json.Value, a, line, .{}) catch
        return ImportError.MalformedJson;
    if (parsed != .object) return ImportError.RowNotObject;
    // Drop the caller's held-back keys before the engine (validation, defaults, encryption)
    // ever sees them. No allocator needed: removal only unlinks the entry, it doesn't free.
    for (opts.strip_fields) |name| _ = parsed.object.swapRemove(name);
    return importRow(app, w, io, a, col, parsed, opts, lookups);
}

/// Capture the failing field detail while `records.last_errors` is still valid — it points
/// into the row arena, which this row's scope is about to reset. Empty for anything but
/// `error.Validation`.
fn captureDetail(e: anyerror) []const u8 {
    if (e != error.Validation) return "";
    const errs = records.last_errors orelse return "";
    if (errs.len == 0) return "";
    const ve = errs[0];
    return std.fmt.bufPrint(&last_error_detail_buf, "{s}: {s} ({s})", .{ ve.field, ve.message, ve.code }) catch "";
}

/// Stream NDJSON from `reader` into `opts.collection` on writer `w`. Returns the row counts.
/// See the file header for the streaming/batch/txn/id/upsert contract.
pub fn run(app: *App, w: *db.Db, io: std.Io, reader: *std.Io.Reader, opts: Options) !Report {
    // Runtime check, not std.debug.assert: `run` is a public library entrypoint and asserts are
    // compiled out in ReleaseFast/ReleaseSmall, where a 0 would divide the loop into never-committing
    // batches. Fail with a stable error instead.
    if (opts.batch_size < 1) return ImportError.InvalidBatchSize;

    last_error_line = 0; // reset; set to the offending 1-based line on a row failure.
    last_error_detail = "";

    if (opts.external_auths and opts.upsert_key != null) {
        // `importRow`'s upsert branch returns as soon as the matched row is updated, so a
        // matched row would be written with NO linkage — the account would exist and still
        // be unreachable, which is the exact failure this seam removes. Refuse rather than
        // half-perform it.
        last_error_detail = "external-auth import is create-only and cannot be combined with an upsert key";
        return ImportError.ExternalAuthRequiresCreateOnly;
    }
    if (opts.preserve_timestamps and opts.upsert_key != null) {
        last_error_detail = "source timestamp preservation is create-only; remove --upsert-key / manifest `upsertKey`";
        return ImportError.TimestampRequiresCreateOnly;
    }
    if (opts.preserve_timestamps and !opts.preserve_ids) {
        last_error_detail = "source timestamp preservation requires preserve_ids=true and an id on every row";
        return ImportError.TimestampRequiresPreservedIds;
    }

    // Resolve the target collection ONCE into a run-lived arena (never per row — that would
    // leak collections.get's allocations each row and re-hit the DB).
    var col_arena = std.heap.ArenaAllocator.init(app.allocator);
    defer col_arena.deinit();
    const ca = col_arena.allocator();

    // Validate the legacy-hash mode's collection-independent checks BEFORE the identifier
    // gate below: `_superusers` (like every system table) starts with `_` and so never
    // passes `schema.isValidIdentifier`, which would otherwise mask this refusal behind a
    // generic `InvalidCollectionName`. A misconfigured run must fail before it writes
    // anything, so this all runs before any row is read.
    // Same reasoning as the legacy block below: `_superusers` starts with `_` and so never
    // passes the identifier gate, which would mask this refusal behind a generic
    // `InvalidCollectionName`. Linking a provider identity to a superuser would hand
    // administrative access to whoever controls that provider account.
    if (opts.external_auths and std.mem.eql(u8, opts.collection, "_superusers"))
        return ImportError.ExternalAuthSuperuserRefused;

    if (opts.legacy_hash_algorithm) |alg| {
        // The superuser table is created by `zigbase superuser create` with a real password;
        // there is no migration story for it, and it is the highest-value target.
        if (std.mem.eql(u8, opts.collection, "_superusers")) return ImportError.LegacySuperuserRefused;
        // Fail on an unknown algorithm here rather than per row.
        if (!blk: {
            for (crypto.legacy_algorithms) |a| if (std.mem.eql(u8, a, alg)) break :blk true;
            break :blk false;
        }) return crypto.LegacyError.UnsupportedAlgorithm;
        // Legacy credential installation is CREATE-ONLY: `importRow`'s upsert branch returns
        // as soon as the matched row is updated, so a matched row would be written with NO
        // credential at all — a silent, security-relevant loss (exit 0, no warning). Refuse
        // the combination up front rather than half-performing it. This also covers a
        // manifest run: `import_manifest.run` copies the run-level Options and sets
        // `upsert_key` per entry, so an entry carrying `upsertKey` under a run-level
        // `--legacy-hashes` lands here on that entry's own `import.run`.
        if (opts.upsert_key != null) {
            last_error_detail = "legacy credential import is create-only; run it as a separate create-only import (no --upsert-key / no manifest `upsertKey`)";
            return ImportError.LegacyRequiresCreateOnly;
        }
    }

    if (!schema.isValidIdentifier(opts.collection)) return ImportError.InvalidCollectionName;
    const col = (try collections.get(ca, w, opts.collection)) orelse return ImportError.UnknownCollection;

    if (opts.legacy_hash_algorithm != null and col.type != .auth)
        return ImportError.LegacyRequiresAuthCollection;

    if (opts.legacy_hash_algorithm != null and !opts.preserve_ids) {
        last_error_detail = "legacy credential import requires preserve_ids=true — the credential row is matched by its source id";
        return ImportError.LegacyRequiresPreservedIds;
    }

    if (opts.external_auths and col.type != .auth)
        return ImportError.ExternalAuthRequiresAuthCollection;

    if (opts.external_auths and !opts.preserve_ids) {
        last_error_detail = "external-auth import requires preserve_ids=true — a link points at the record's source id";
        return ImportError.ExternalAuthRequiresPreservedIds;
    }

    // Prepare the per-run lookup statement(s) ONCE — reused for every row (reset + re-bind) so a
    // large import doesn't re-format + re-`prepare` a statement per row (an N+1 that ~doubles DB
    // work). The table/column are fixed for the whole run, so the identifier gate runs once here,
    // at prepare time, before interpolation. Read statements are connection-scoped and safely
    // survive the batch commit/begin boundaries.
    var lookups: Lookups = .{};
    defer lookups.finalize();

    if (opts.upsert_key) |key| {
        if (!schema.isValidIdentifier(key)) return ImportError.InvalidUpsertKey;
        const f = findField(col, key) orelse return ImportError.UnknownUpsertKey;
        if (f.encrypted) return ImportError.EncryptedUpsertKey;
        if (!fieldLooksUnique(col, key)) {
            // Operational heads-up (warn is not counted as a test-failing error log).
            std.log.warn("import: --upsert-key '{s}' is not backed by a unique constraint; a non-unique key may update the wrong row", .{key});
        }
        const sql = try std.fmt.allocPrintSentinel(ca, "SELECT \"id\" FROM {s} WHERE {s}=?1 LIMIT 1;", .{ try ddl.quoteIdent(ca, col.name), try ddl.quoteIdent(ca, key) }, 0);
        lookups.upsert = try prep(ca, w, sql);
    } else if (opts.preserve_ids) {
        const sql = try std.fmt.allocPrintSentinel(ca, "SELECT 1 FROM {s} WHERE \"id\"=?1 LIMIT 1;", .{try ddl.quoteIdent(ca, col.name)}, 0);
        lookups.dup_check = try prep(ca, w, sql);
    }
    if (opts.preserve_timestamps) {
        const sql = try std.fmt.allocPrintSentinel(
            ca,
            "UPDATE {s} SET \"created\"=?2, \"updated\"=?3 WHERE \"id\"=?1;",
            .{try ddl.quoteIdent(ca, col.name)},
            0,
        );
        lookups.timestamp_update = try prep(ca, w, sql);
    }

    // Per-row scratch arena, reset (retaining capacity) after each row so memory stays bounded
    // by the largest single record regardless of file/batch size.
    var row_arena = std.heap.ArenaAllocator.init(app.allocator);
    defer row_arena.deinit();

    var report: Report = .{};
    var line_no: usize = 0;
    var in_batch: usize = 0;

    var batch = try WriteScope.begin(w);
    // `batch_open` tracks whether this transaction/savepoint scope is open, so errdefer only
    // rolls back when there is something to roll back. It is cleared as soon as close succeeds
    // and re-set after the next scope begins.
    var batch_open = true;
    errdefer if (batch_open) batch.rollback();

    while (true) {
        const maybe = reader.takeDelimiter('\n') catch |e| switch (e) {
            error.StreamTooLong => {
                last_error_line = line_no + 1;
                return ImportError.LineTooLong;
            },
            else => |other| return other, // ReadFailed
        };
        const raw = maybe orelse break; // null = EOF
        line_no += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue; // skip blank lines

        _ = row_arena.reset(.retain_capacity);
        const a = row_arena.allocator();

        // SAVEPOINT isolates one row inside the open batch transaction, so a bad row does
        // not cost the good rows already in it. Portable spelling (SQLite + Postgres).
        // Only paid when continue_on_error is set.
        if (opts.continue_on_error) try w.exec("SAVEPOINT zb_row;");

        const outcome = importOneRow(app, w, io, a, col, line, opts, &lookups) catch |e| {
            last_error_line = line_no;
            // Capture the failing field detail NOW, while records.last_errors is still valid
            // (it points into `a` = row_arena, which this function's defer will free).
            last_error_detail = captureDetail(e);
            if (!opts.continue_on_error) {
                logFinding(opts, line_no, @errorName(e), last_error_detail);
                return e;
            }
            w.exec("ROLLBACK TO SAVEPOINT zb_row;") catch |re| return re;
            w.exec("RELEASE SAVEPOINT zb_row;") catch |re| return re;
            logFinding(opts, line_no, @errorName(e), last_error_detail);
            report.failed += 1;
            tickProgress(opts, line_no);
            continue;
        };
        if (opts.continue_on_error) try w.exec("RELEASE SAVEPOINT zb_row;");
        switch (outcome) {
            .created => report.created += 1,
            .updated => report.updated += 1,
        }
        report.total += 1;
        in_batch += 1;
        tickProgress(opts, line_no);

        if (in_batch >= opts.batch_size) {
            try batch.close(opts.dry_run);
            batch_open = false; // scope closed; a failed next begin must not roll it back again
            in_batch = 0;
            batch = try WriteScope.begin(w);
            batch_open = true;
        }
    }

    try batch.close(opts.dry_run);
    batch_open = false;
    return report;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
const migrations = @import("migrations.zig");
const field_policy = @import("field_policy.zig");

/// Build a minimal App wrapping a pool-less writer for tests (mirrors data.zig's test setup:
/// only `.allocator` is read by import.run). The connection is passed separately to run().
/// Public: the manifest runner's own tests (`src/import_manifest.zig`) need the same fixture.
pub fn testApp(alloc: std.mem.Allocator, io: std.Io) App {
    return App{ .allocator = alloc, .io = io, .pool = undefined };
}

fn seedPosts(d: *db.Db, a: std.mem.Allocator, io: std.Io) !schema.Collection {
    try migrations.run(d);
    const fields = [_]schema.Field{
        .{ .id = "f1", .name = "title", .required = true, .options = .{ .text = .{} } },
        .{ .id = "f2", .name = "slug", .unique = true, .options = .{ .text = .{} } },
        .{ .id = "f3", .name = "body", .options = .{ .text = .{} } },
    };
    return collections.create(a, io, d, .{ .id = "", .name = "posts", .fields = &fields });
}

fn runNdjson(app: *App, w: *db.Db, io: std.Io, ndjson: []const u8, opts: Options) !Report {
    var reader = std.Io.Reader.fixed(ndjson);
    return run(app, w, io, &reader, opts);
}

test "import: multi-row NDJSON creates all rows through the engine (defaults applied)" {
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    const io = std.testing.io;
    const posts_col = try seedPosts(&d, a, io);
    defer posts_col.deinit(a);
    var app = testApp(std.testing.allocator, io);

    const ndjson =
        \\{"title":"first","slug":"a"}
        \\{"title":"second","slug":"b"}
        \\{"title":"third","slug":"c"}
    ;
    const rep = try runNdjson(&app, &d, io, ndjson, .{ .collection = "posts" });
    try std.testing.expectEqual(@as(usize, 3), rep.created);
    try std.testing.expectEqual(@as(usize, 0), rep.updated);
    try std.testing.expectEqual(@as(usize, 3), rep.total);

    // Rows are actually persisted and carry engine-set created/updated defaults.
    var st = try d.prepare("SELECT COUNT(*) FROM posts;");
    defer st.finalize();
    _ = try st.step();
    try std.testing.expectEqual(@as(i64, 3), st.columnInt(0));
}

test "import: blank lines are skipped" {
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    const io = std.testing.io;
    const posts_col = try seedPosts(&d, a, io);
    defer posts_col.deinit(a);
    var app = testApp(std.testing.allocator, io);

    const ndjson = "{\"title\":\"x\",\"slug\":\"x\"}\n\n   \n{\"title\":\"y\",\"slug\":\"y\"}\n";
    const rep = try runNdjson(&app, &d, io, ndjson, .{ .collection = "posts" });
    try std.testing.expectEqual(@as(usize, 2), rep.total);
}

test "import: batch boundary smaller than row count commits every batch" {
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    const io = std.testing.io;
    const posts_col = try seedPosts(&d, a, io);
    defer posts_col.deinit(a);
    var app = testApp(std.testing.allocator, io);

    const ndjson =
        \\{"title":"1","slug":"s1"}
        \\{"title":"2","slug":"s2"}
        \\{"title":"3","slug":"s3"}
        \\{"title":"4","slug":"s4"}
        \\{"title":"5","slug":"s5"}
    ;
    const rep = try runNdjson(&app, &d, io, ndjson, .{ .collection = "posts", .batch_size = 2 });
    try std.testing.expectEqual(@as(usize, 5), rep.created);
    var st = try d.prepare("SELECT COUNT(*) FROM posts;");
    defer st.finalize();
    _ = try st.step();
    try std.testing.expectEqual(@as(i64, 5), st.columnInt(0));
}

test "import: batch_size=1 commits every row (commit/begin cycle bookkeeping)" {
    // batch_size=1 hits the commit-then-begin boundary after EVERY row, exercising the
    // `batch_open` flag flip (clear-after-commit, set-after-begin) on every iteration. All
    // rows must still persist and the final commit must leave no open transaction dangling.
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    const io = std.testing.io;
    const posts_col = try seedPosts(&d, a, io);
    defer posts_col.deinit(a);
    var app = testApp(std.testing.allocator, io);

    const ndjson =
        \\{"title":"1","slug":"b1"}
        \\{"title":"2","slug":"b2"}
        \\{"title":"3","slug":"b3"}
    ;
    const rep = try runNdjson(&app, &d, io, ndjson, .{ .collection = "posts", .batch_size = 1 });
    try std.testing.expectEqual(@as(usize, 3), rep.created);
    try std.testing.expectEqual(@as(usize, 3), rep.total);
    var st = try d.prepare("SELECT COUNT(*) FROM posts;");
    defer st.finalize();
    _ = try st.step();
    try std.testing.expectEqual(@as(i64, 3), st.columnInt(0));
    // A subsequent write must succeed — proving no transaction was left open by the import.
    _ = try runNdjson(&app, &d, io, "{\"title\":\"4\",\"slug\":\"b4\"}", .{ .collection = "posts", .batch_size = 1 });
}

test "import: id preservation on vs off" {
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    const io = std.testing.io;
    const posts_col = try seedPosts(&d, a, io);
    defer posts_col.deinit(a);
    var app = testApp(std.testing.allocator, io);

    // preserve_ids = true (default): the provided id survives.
    _ = try runNdjson(&app, &d, io, "{\"id\":\"keepme01\",\"title\":\"t\",\"slug\":\"k\"}", .{ .collection = "posts" });
    {
        var st = try d.prepare("SELECT COUNT(*) FROM posts WHERE id='keepme01';");
        defer st.finalize();
        _ = try st.step();
        try std.testing.expectEqual(@as(i64, 1), st.columnInt(0));
    }
    // preserve_ids = false: the provided id is ignored, a new id generated.
    _ = try runNdjson(&app, &d, io, "{\"id\":\"ignored99\",\"title\":\"t2\",\"slug\":\"k2\"}", .{ .collection = "posts", .preserve_ids = false });
    {
        var st = try d.prepare("SELECT COUNT(*) FROM posts WHERE id='ignored99';");
        defer st.finalize();
        _ = try st.step();
        try std.testing.expectEqual(@as(i64, 0), st.columnInt(0));
    }
}

test "import: source timestamps are canonicalized and ordinary imports still regenerate" {
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    const io = std.testing.io;
    const posts_col = try seedPosts(&d, a, io);
    defer posts_col.deinit(a);
    var app = testApp(a, io);

    const source_created = "2001-02-03 04:05:06.789Z";
    const source_updated = "2002-03-04 05:06:07+01:30";
    _ = try runNdjson(
        &app,
        &d,
        io,
        "{\"id\":\"time0001\",\"created\":\"" ++ source_created ++ "\",\"updated\":\"" ++ source_updated ++ "\",\"title\":\"old\",\"slug\":\"old\"}",
        .{ .collection = "posts", .preserve_timestamps = true },
    );
    var preserved = try d.prepare("SELECT created, updated FROM posts WHERE id='time0001';");
    defer preserved.finalize();
    _ = try preserved.step();
    try std.testing.expectEqualStrings("2001-02-03T04:05:06Z", preserved.columnText(0));
    try std.testing.expectEqualStrings("2002-03-04T03:36:07Z", preserved.columnText(1));

    _ = try runNdjson(
        &app,
        &d,
        io,
        "{\"id\":\"native01\",\"title\":\"native\",\"slug\":\"native\"}",
        .{ .collection = "posts" },
    );
    try d.exec("UPDATE posts SET created='2001-02-03T04:05:07Z' WHERE id='native01';");
    var ordered = try d.prepare("SELECT id FROM posts WHERE id IN ('native01','time0001') ORDER BY created DESC;");
    defer ordered.finalize();
    _ = try ordered.step();
    try std.testing.expectEqualStrings("native01", ordered.columnText(0));
    _ = try ordered.step();
    try std.testing.expectEqualStrings("time0001", ordered.columnText(0));
    var filtered = try d.prepare("SELECT COUNT(*) FROM posts WHERE id='time0001' AND created >= '2001-02-03T00:00:00Z';");
    defer filtered.finalize();
    _ = try filtered.step();
    try std.testing.expectEqual(@as(i64, 1), filtered.columnInt(0));

    _ = try runNdjson(
        &app,
        &d,
        io,
        "{\"id\":\"time0002\",\"created\":\"1999-01-01T00:00:00Z\",\"updated\":\"1999-01-01T00:00:00Z\",\"title\":\"new\",\"slug\":\"new\"}",
        .{ .collection = "posts" },
    );
    var ordinary = try d.prepare("SELECT created, updated FROM posts WHERE id='time0002';");
    defer ordinary.finalize();
    _ = try ordinary.step();
    try std.testing.expect(!std.mem.eql(u8, "1999-01-01T00:00:00Z", ordinary.columnText(0)));
    try std.testing.expect(!std.mem.eql(u8, "1999-01-01T00:00:00Z", ordinary.columnText(1)));

    const dry = try runNdjson(
        &app,
        &d,
        io,
        "{\"id\":\"time0003\",\"created\":\"1998-01-01\",\"updated\":\"1998-01-02\",\"title\":\"dry\",\"slug\":\"dry\"}",
        .{ .collection = "posts", .preserve_timestamps = true, .dry_run = true },
    );
    try std.testing.expectEqual(@as(usize, 1), dry.created);
    var absent = try d.prepare("SELECT COUNT(*) FROM posts WHERE id='time0003';");
    defer absent.finalize();
    _ = try absent.step();
    try std.testing.expectEqual(@as(i64, 0), absent.columnInt(0));
}

test "import: auth credential and source timestamps are installed atomically" {
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    const io = std.testing.io;
    try migrations.run(&d);
    const members = try collections.create(a, io, &d, .{ .id = "", .name = "members", .type = .auth, .fields = &.{} });
    defer members.deinit(a);
    var app = testApp(a, io);
    const bc = "$2a$10$N9qo8uLOickgx2ZMRZoMyeIjZAgcfl7p92ldGxad68LJZdL17lhWy";
    const row = "{\"id\":\"membertime00001\",\"email\":\"a@b.c\",\"passwordHash\":\"" ++ bc ++ "\",\"verified\":true,\"created\":\"2003-04-05T06:07:08.900Z\",\"updated\":\"2004-05-06T07:08:09Z\"}";
    _ = try runNdjson(&app, &d, io, row, .{
        .collection = "members",
        .legacy_hash_algorithm = "bcrypt",
        .preserve_timestamps = true,
    });

    var st = try d.prepare("SELECT passwordHash, verified, created, updated FROM members WHERE id='membertime00001';");
    defer st.finalize();
    try std.testing.expect(try st.step());
    try std.testing.expect(std.mem.startsWith(u8, st.columnText(0), "$zblegacy$bcrypt$"));
    try std.testing.expectEqual(@as(i64, 1), st.columnInt(1));
    try std.testing.expectEqualStrings("2003-04-05T06:07:08Z", st.columnText(2));
    try std.testing.expectEqualStrings("2004-05-06T07:08:09Z", st.columnText(3));
}

test "import: timestamp preservation validates shape before writing" {
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    const io = std.testing.io;
    const posts_col = try seedPosts(&d, a, io);
    defer posts_col.deinit(a);
    var app = testApp(a, io);
    const opts = Options{ .collection = "posts", .preserve_timestamps = true };

    try std.testing.expectError(ImportError.TimestampRowMissingId, runNdjson(&app, &d, io, "{\"created\":\"2001-01-01\",\"updated\":\"2001-01-01\",\"title\":\"a\",\"slug\":\"a\"}", opts));
    try std.testing.expectError(ImportError.TimestampMissing, runNdjson(&app, &d, io, "{\"id\":\"time0010\",\"created\":\"2001-01-01\",\"title\":\"a\",\"slug\":\"a\"}", opts));
    try std.testing.expectError(ImportError.TimestampInvalid, runNdjson(&app, &d, io, "{\"id\":\"time0011\",\"created\":\"yesterday\",\"updated\":\"2001-01-01\",\"title\":\"a\",\"slug\":\"a\"}", opts));

    var st = try d.prepare("SELECT COUNT(*) FROM posts;");
    defer st.finalize();
    _ = try st.step();
    try std.testing.expectEqual(@as(i64, 0), st.columnInt(0));
}

test "import: timestamp preservation is create-only and requires preserved ids" {
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    const io = std.testing.io;
    const posts_col = try seedPosts(&d, a, io);
    defer posts_col.deinit(a);
    var app = testApp(a, io);
    const row = "{\"id\":\"time0020\",\"created\":\"2001-01-01\",\"updated\":\"2001-01-01\",\"title\":\"a\",\"slug\":\"a\"}";
    try std.testing.expectError(ImportError.TimestampRequiresCreateOnly, runNdjson(&app, &d, io, row, .{
        .collection = "posts",
        .upsert_key = "slug",
        .preserve_timestamps = true,
    }));
    try std.testing.expectError(ImportError.TimestampRequiresPreservedIds, runNdjson(&app, &d, io, row, .{
        .collection = "posts",
        .preserve_ids = false,
        .preserve_timestamps = true,
    }));
}

test "import: invalid preserved timestamp rolls back its whole batch" {
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    const io = std.testing.io;
    const posts_col = try seedPosts(&d, a, io);
    defer posts_col.deinit(a);
    var app = testApp(a, io);
    const ndjson =
        \\{"id":"time0030","created":"2001-01-01","updated":"2001-01-01","title":"a","slug":"a"}
        \\{"id":"time0031","created":"bad","updated":"2001-01-01","title":"b","slug":"b"}
    ;
    try std.testing.expectError(ImportError.TimestampInvalid, runNdjson(&app, &d, io, ndjson, .{
        .collection = "posts",
        .preserve_timestamps = true,
    }));
    var st = try d.prepare("SELECT COUNT(*) FROM posts;");
    defer st.finalize();
    _ = try st.step();
    try std.testing.expectEqual(@as(i64, 0), st.columnInt(0));
}

test "import: continue-on-error skips only the row with an invalid source timestamp" {
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    const io = std.testing.io;
    const posts_col = try seedPosts(&d, a, io);
    defer posts_col.deinit(a);
    var app = testApp(a, io);
    const ndjson =
        \\{"id":"time0040","created":"2001-01-01","updated":"2001-01-02","title":"a","slug":"a"}
        \\{"id":"time0041","created":"bad","updated":"2001-01-02","title":"b","slug":"b"}
        \\{"id":"time0042","created":"2001-01-03","updated":"2001-01-04","title":"c","slug":"c"}
    ;
    const rep = try runNdjson(&app, &d, io, ndjson, .{
        .collection = "posts",
        .preserve_timestamps = true,
        .continue_on_error = true,
    });
    try std.testing.expectEqual(@as(usize, 2), rep.created);
    try std.testing.expectEqual(@as(usize, 1), rep.failed);
    try std.testing.expectEqual(@as(usize, 2), rep.total);
    var st = try d.prepare("SELECT COUNT(*) FROM posts;");
    defer st.finalize();
    _ = try st.step();
    try std.testing.expectEqual(@as(i64, 2), st.columnInt(0));
}

test "import: duplicate preserved id fails fast and names the line" {
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    const io = std.testing.io;
    const posts_col = try seedPosts(&d, a, io);
    defer posts_col.deinit(a);
    var app = testApp(std.testing.allocator, io);

    const ndjson =
        \\{"id":"dupe0001","title":"a","slug":"a"}
        \\{"id":"dupe0001","title":"b","slug":"b"}
    ;
    try std.testing.expectError(error.DuplicateId, runNdjson(&app, &d, io, ndjson, .{ .collection = "posts" }));
    // First row committed? It is in the SAME batch (default 500), so the failing batch — which
    // includes row 1 — rolled back: zero rows.
    var st = try d.prepare("SELECT COUNT(*) FROM posts;");
    defer st.finalize();
    _ = try st.step();
    try std.testing.expectEqual(@as(i64, 0), st.columnInt(0));
}

test "import: malformed JSON line fails with its line number" {
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    const io = std.testing.io;
    const posts_col = try seedPosts(&d, a, io);
    defer posts_col.deinit(a);
    var app = testApp(std.testing.allocator, io);

    const ndjson = "{\"title\":\"ok\",\"slug\":\"ok\"}\n{not json}\n";
    try std.testing.expectError(error.MalformedJson, runNdjson(&app, &d, io, ndjson, .{ .collection = "posts" }));
}

test "import: a non-object line is rejected" {
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    const io = std.testing.io;
    const posts_col = try seedPosts(&d, a, io);
    defer posts_col.deinit(a);
    var app = testApp(std.testing.allocator, io);
    try std.testing.expectError(error.RowNotObject, runNdjson(&app, &d, io, "[1,2,3]", .{ .collection = "posts" }));
}

test "import: upsert create-then-update by key" {
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    const io = std.testing.io;
    const posts_col = try seedPosts(&d, a, io);
    defer posts_col.deinit(a);
    var app = testApp(std.testing.allocator, io);

    // First import creates.
    const r1 = try runNdjson(&app, &d, io, "{\"title\":\"v1\",\"slug\":\"same\"}", .{ .collection = "posts", .upsert_key = "slug" });
    try std.testing.expectEqual(@as(usize, 1), r1.created);
    try std.testing.expectEqual(@as(usize, 0), r1.updated);
    // Re-import with the same key updates.
    const r2 = try runNdjson(&app, &d, io, "{\"title\":\"v2\",\"slug\":\"same\"}", .{ .collection = "posts", .upsert_key = "slug" });
    try std.testing.expectEqual(@as(usize, 0), r2.created);
    try std.testing.expectEqual(@as(usize, 1), r2.updated);
    // Exactly one row, updated title.
    var st = try d.prepare("SELECT title FROM posts WHERE slug='same';");
    defer st.finalize();
    _ = try st.step();
    try std.testing.expectEqualStrings("v2", st.columnText(0));
    try std.testing.expect(!try st.step()); // only one row
}

test "import: multi-row upsert reuses the lookup statement across a batch boundary" {
    // batch_size=1 forces a commit+begin between every row, so the reused upsert lookup
    // statement (prepared once) must keep working across those transaction boundaries. Mixes
    // creates and updates in one stream, spanning multiple batches.
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    const io = std.testing.io;
    const posts_col = try seedPosts(&d, a, io);
    defer posts_col.deinit(a);
    var app = testApp(std.testing.allocator, io);

    // Seed two distinct slugs, then re-touch one and add a third — 4 lines, batch_size 1.
    const ndjson =
        \\{"title":"a1","slug":"a"}
        \\{"title":"b1","slug":"b"}
        \\{"title":"a2","slug":"a"}
        \\{"title":"c1","slug":"c"}
    ;
    const rep = try runNdjson(&app, &d, io, ndjson, .{ .collection = "posts", .upsert_key = "slug", .batch_size = 1 });
    try std.testing.expectEqual(@as(usize, 3), rep.created); // a, b, c
    try std.testing.expectEqual(@as(usize, 1), rep.updated); // a again
    try std.testing.expectEqual(@as(usize, 4), rep.total);

    // Three distinct rows; slug 'a' holds the updated title.
    var cst = try d.prepare("SELECT COUNT(*) FROM posts;");
    defer cst.finalize();
    _ = try cst.step();
    try std.testing.expectEqual(@as(i64, 3), cst.columnInt(0));
    var ast = try d.prepare("SELECT title FROM posts WHERE slug='a';");
    defer ast.finalize();
    _ = try ast.step();
    try std.testing.expectEqualStrings("a2", ast.columnText(0));
}

test "import: batch_size of 0 is rejected (runtime check, not a debug assert)" {
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    const io = std.testing.io;
    const posts_col = try seedPosts(&d, a, io);
    defer posts_col.deinit(a);
    var app = testApp(std.testing.allocator, io);
    try std.testing.expectError(error.InvalidBatchSize, runNdjson(&app, &d, io, "{\"title\":\"x\",\"slug\":\"x\"}", .{ .collection = "posts", .batch_size = 0 }));
}

test "import: validation error reports the failing 1-based line" {
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    const io = std.testing.io;
    try migrations.run(&d);
    const fields = [_]schema.Field{.{ .id = "f1", .name = "title", .required = true, .options = .{ .text = .{} } }};
    const notes_col = try collections.create(a, io, &d, .{ .id = "", .name = "notes", .fields = &fields });
    defer notes_col.deinit(a);
    var app = testApp(std.testing.allocator, io);

    // Row 2 is missing the required `title`.
    const ndjson = "{\"title\":\"ok\"}\n{}\n";
    try std.testing.expectError(error.Validation, runNdjson(&app, &d, io, ndjson, .{ .collection = "notes" }));
}

test "import: unknown collection and injection-guarded bad names are rejected" {
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    const io = std.testing.io;
    const posts_col = try seedPosts(&d, a, io);
    defer posts_col.deinit(a);
    var app = testApp(std.testing.allocator, io);

    try std.testing.expectError(error.UnknownCollection, runNdjson(&app, &d, io, "{}", .{ .collection = "nope" }));
    // A weird collection name never reaches SQL — the identifier gate rejects it first.
    try std.testing.expectError(error.InvalidCollectionName, runNdjson(&app, &d, io, "{}", .{ .collection = "posts; DROP TABLE posts;--" }));
    // A weird upsert key is likewise gated.
    try std.testing.expectError(error.InvalidUpsertKey, runNdjson(&app, &d, io, "{}", .{ .collection = "posts", .upsert_key = "slug\" OR 1=1--" }));
    // A non-existent upsert key field is rejected.
    try std.testing.expectError(error.UnknownUpsertKey, runNdjson(&app, &d, io, "{}", .{ .collection = "posts", .upsert_key = "nosuch" }));
}

test "import: an .encrypted field is sealed at rest (ciphertext, not plaintext)" {
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    const io = std.testing.io;
    try migrations.run(&d);
    // Stamp a field cipher on the connection, as bootApp's pool does in the real flow.
    var cipher = field_policy.Cipher.fromEnv(io, "import-field-key");
    db.dbSetFieldCipher(&d, @ptrCast(&cipher));
    const fields = [_]schema.Field{
        .{ .id = "f1", .name = "secret", .encrypted = true, .options = .{ .text = .{} } },
        .{ .id = "f2", .name = "plain", .options = .{ .text = .{} } },
    };
    const col = try collections.create(a, io, &d, .{ .id = "", .name = "vault", .fields = &fields });
    defer col.deinit(a);
    var app = testApp(std.testing.allocator, io);

    _ = try runNdjson(&app, &d, io, "{\"id\":\"vaultrow01\",\"secret\":\"topsecret\",\"plain\":\"visible\"}", .{ .collection = "vault" });

    // Raw cell holds a v1 envelope, never the plaintext.
    var st = try d.prepare("SELECT secret FROM vault WHERE id='vaultrow01';");
    defer st.finalize();
    _ = try st.step();
    const raw = st.columnText(0);
    try std.testing.expect(std.mem.startsWith(u8, raw, "v1:"));
    try std.testing.expect(std.mem.indexOf(u8, raw, "topsecret") == null);
    // Read-back through the engine decrypts transparently.
    const got = (try records.get(a, &d, col, "vaultrow01")).?;
    defer records.freeRecord(a, got);
    try std.testing.expectEqualStrings("topsecret", got.object.get("secret").?.string);
}

test "import: an encrypted field cannot be an upsert key" {
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    const io = std.testing.io;
    try migrations.run(&d);
    var cipher = field_policy.Cipher.fromEnv(io, "k");
    db.dbSetFieldCipher(&d, @ptrCast(&cipher));
    const fields = [_]schema.Field{.{ .id = "f1", .name = "secret", .encrypted = true, .options = .{ .text = .{} } }};
    const vault2_col = try collections.create(a, io, &d, .{ .id = "", .name = "vault2", .fields = &fields });
    defer vault2_col.deinit(a);
    var app = testApp(std.testing.allocator, io);
    try std.testing.expectError(error.EncryptedUpsertKey, runNdjson(&app, &d, io, "{}", .{ .collection = "vault2", .upsert_key = "secret" }));
}

test "import: auth collection hashes the password (never stored plaintext)" {
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    const io = std.testing.io;
    try migrations.run(&d);
    const users = try collections.create(a, io, &d, .{ .id = "", .name = "members", .type = .auth, .fields = &.{} });
    defer users.deinit(a);
    var app = testApp(std.testing.allocator, io);

    _ = try runNdjson(&app, &d, io, "{\"id\":\"member0001\",\"email\":\"a@b.c\",\"password\":\"supersecret\"}", .{ .collection = "members" });

    var st = try d.prepare("SELECT passwordHash, tokenKey, verified FROM members WHERE id='member0001';");
    defer st.finalize();
    _ = try st.step();
    const hash = st.columnText(0);
    // Argon2id PHC string, and definitely not the plaintext.
    try std.testing.expect(std.mem.startsWith(u8, hash, "$argon2"));
    try std.testing.expect(std.mem.indexOf(u8, hash, "supersecret") == null);
    try std.testing.expect(st.columnText(1).len > 0); // tokenKey generated
    try std.testing.expectEqual(@as(i64, 0), st.columnInt(2)); // verified forced false
}

test "import: dry run validates every row and writes nothing" {
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    const io = std.testing.io;
    const posts_col = try seedPosts(&d, a, io);
    defer posts_col.deinit(a);
    var app = testApp(std.testing.allocator, io);

    const rep = try runNdjson(&app, &d, io,
        \\{"title":"a"}
        \\{"title":"b"}
        \\
    , .{ .collection = "posts", .dry_run = true });
    try std.testing.expectEqual(@as(usize, 2), rep.created);
    try std.testing.expectEqual(@as(usize, 0), rep.failed);

    var st = try d.prepare("SELECT COUNT(*) FROM posts;");
    defer st.finalize();
    try std.testing.expect(try st.step());
    try std.testing.expectEqual(@as(i64, 0), st.columnInt(0)); // nothing committed
}

test "import: dry run still fails fast on a bad row" {
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    const io = std.testing.io;
    const posts_col = try seedPosts(&d, a, io);
    defer posts_col.deinit(a);
    var app = testApp(std.testing.allocator, io);

    try std.testing.expectError(ImportError.MalformedJson, runNdjson(&app, &d, io,
        \\{"title":"a"}
        \\not json
        \\
    , .{ .collection = "posts", .dry_run = true }));
}

test "import: continue-on-error skips bad rows, keeps good ones, and logs NDJSON findings" {
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    const io = std.testing.io;
    const posts_col = try seedPosts(&d, a, io);
    defer posts_col.deinit(a);
    var app = testApp(std.testing.allocator, io);

    var buf: [4096]u8 = undefined;
    var sink = std.Io.Writer.fixed(&buf);

    const rep = try runNdjson(&app, &d, io,
        \\{"title":"good1"}
        \\not json
        \\{"title":"good2"}
        \\{"nope":"missing required title"}
        \\{"title":"good3"}
        \\
    , .{ .collection = "posts", .continue_on_error = true, .error_log = &sink });

    try std.testing.expectEqual(@as(usize, 3), rep.created);
    try std.testing.expectEqual(@as(usize, 2), rep.failed);
    try std.testing.expectEqual(@as(usize, 3), rep.total);

    var st = try d.prepare("SELECT COUNT(*) FROM posts;");
    defer st.finalize();
    try std.testing.expect(try st.step());
    try std.testing.expectEqual(@as(i64, 3), st.columnInt(0)); // the good rows COMMITTED

    const findings = sink.buffered();
    var lines = std.mem.tokenizeScalar(u8, findings, '\n');
    const first = lines.next().?;
    try std.testing.expect(std.mem.indexOf(u8, first, "\"line\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "MalformedJson") != null);
    const second = lines.next().?;
    try std.testing.expect(std.mem.indexOf(u8, second, "\"line\":4") != null);
    try std.testing.expect(std.mem.indexOf(u8, second, "validation_required") != null);
    try std.testing.expect(lines.next() == null);
}

test "import: continue-on-error rolls back only the failing row, not its batch" {
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    const io = std.testing.io;
    const posts_col = try seedPosts(&d, a, io);
    defer posts_col.deinit(a);
    var app = testApp(std.testing.allocator, io);

    // batch_size 10 keeps all five rows in ONE transaction: proof the savepoint (not the
    // batch boundary) is what isolates the failure.
    const rep = try runNdjson(&app, &d, io,
        \\{"id":"dupdupdupdup001","title":"first"}
        \\{"id":"dupdupdupdup001","title":"duplicate id"}
        \\{"title":"after the failure"}
        \\
    , .{ .collection = "posts", .batch_size = 10, .continue_on_error = true });
    try std.testing.expectEqual(@as(usize, 2), rep.created);
    try std.testing.expectEqual(@as(usize, 1), rep.failed);
}

test "import: progress lines are emitted every N rows" {
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    const io = std.testing.io;
    const posts_col = try seedPosts(&d, a, io);
    defer posts_col.deinit(a);
    var app = testApp(std.testing.allocator, io);

    var buf: [1024]u8 = undefined;
    var sink = std.Io.Writer.fixed(&buf);
    _ = try runNdjson(&app, &d, io,
        \\{"title":"1"}
        \\{"title":"2"}
        \\{"title":"3"}
        \\{"title":"4"}
        \\{"title":"5"}
        \\
    , .{ .collection = "posts", .progress_every = 2, .progress = &sink });
    // Rows 2 and 4 tick; the final total is reported by the CLI, not here.
    var lines = std.mem.tokenizeScalar(u8, sink.buffered(), '\n');
    try std.testing.expect(std.mem.indexOf(u8, lines.next().?, "2") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines.next().?, "4") != null);
    try std.testing.expect(lines.next() == null);
}

test "import: 20k rows stay leak-free and memory-bounded" {
    // Scale guard. `std.testing.allocator` fails the test on any leak, and the per-row arena
    // is reset with .retain_capacity, so a per-row allocation that escaped the arena would
    // show up here as unbounded growth or a leak — neither is visible at 3 rows.
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    const io = std.testing.io;
    const posts_col = try seedPosts(&d, a, io);
    defer posts_col.deinit(a);
    var app = testApp(std.testing.allocator, io);

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(std.testing.allocator);
    for (0..20_000) |i|
        try body.print(std.testing.allocator, "{{\"title\":\"row {d}\"}}\n", .{i});

    var reader = std.Io.Reader.fixed(body.items);
    const rep = try run(&app, &d, io, &reader, .{ .collection = "posts", .batch_size = 1000 });
    try std.testing.expectEqual(@as(usize, 20_000), rep.created);
}

test "import: --legacy-hashes stores a tagged hash, honors verified, and never stores plaintext" {
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    const io = std.testing.io;
    try migrations.run(&d);
    const members = try collections.create(a, io, &d, .{
        .id = "",
        .name = "members",
        .type = .auth,
        .fields = &.{.{ .id = "", .name = "nom", .options = .{ .text = .{} } }},
    });
    defer members.deinit(a);
    var app = testApp(std.testing.allocator, io);

    const bc = "$2a$10$N9qo8uLOickgx2ZMRZoMyeIjZAgcfl7p92ldGxad68LJZdL17lhWy";
    const rep = try runNdjson(&app, &d, io, "{\"id\":\"member000000001\",\"email\":\"ada@example.com\",\"nom\":\"Ada\"," ++
        "\"passwordHash\":\"" ++ bc ++ "\",\"verified\":true}\n", .{ .collection = "members", .legacy_hash_algorithm = "bcrypt" });
    try std.testing.expectEqual(@as(usize, 1), rep.created);

    var st = try d.prepare("SELECT \"passwordHash\", \"verified\", \"tokenKey\" FROM \"members\" WHERE \"id\"='member000000001';");
    defer st.finalize();
    try std.testing.expect(try st.step());
    try std.testing.expectEqualStrings("$zblegacy$bcrypt$" ++ bc, st.columnText(0));
    try std.testing.expectEqual(@as(i64, 1), st.columnInt(1)); // verified carried over
    try std.testing.expect(st.columnText(2).len > 0); // tokenKey still provisioned
}

test "import: --legacy-hashes refuses a base collection, _superusers, an id-less row, and a bad hash" {
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    const io = std.testing.io;
    const posts_col = try seedPosts(&d, a, io); // also runs migrations, seeding `_superusers`
    defer posts_col.deinit(a);
    var app = testApp(std.testing.allocator, io);

    const bc = "$2a$10$N9qo8uLOickgx2ZMRZoMyeIjZAgcfl7p92ldGxad68LJZdL17lhWy";
    // A base collection has no credentials to import into.
    try std.testing.expectError(ImportError.LegacyRequiresAuthCollection, runNdjson(&app, &d, io, "{\"id\":\"x00000000000001\",\"title\":\"t\"}\n", .{ .collection = "posts", .legacy_hash_algorithm = "bcrypt" }));

    const members = try collections.create(a, io, &d, .{
        .id = "",
        .name = "members",
        .type = .auth,
        .fields = &.{},
    });
    defer members.deinit(a);

    // No id: nothing to key the credential UPDATE on.
    try std.testing.expectError(ImportError.LegacyRowMissingId, runNdjson(&app, &d, io, "{\"email\":\"a@b.c\",\"passwordHash\":\"" ++ bc ++ "\"}\n", .{ .collection = "members", .legacy_hash_algorithm = "bcrypt" }));
    // Plaintext AND a source hash in one row: ambiguous, so refused rather than guessed.
    try std.testing.expectError(ImportError.LegacyHashConflict, runNdjson(&app, &d, io, "{\"id\":\"m00000000000001\",\"email\":\"a@b.c\",\"password\":\"plaintext1\",\"passwordHash\":\"" ++ bc ++ "\"}\n", .{ .collection = "members", .legacy_hash_algorithm = "bcrypt" }));
    // A malformed or non-allowlisted hash is caught at IMPORT time, not at some login.
    try std.testing.expectError(crypto.LegacyError.MalformedLegacyHash, runNdjson(&app, &d, io, "{\"id\":\"m00000000000002\",\"email\":\"c@d.e\",\"passwordHash\":\"nope\"}\n", .{ .collection = "members", .legacy_hash_algorithm = "bcrypt" }));
    try std.testing.expectError(crypto.LegacyError.UnsupportedAlgorithm, runNdjson(&app, &d, io, "{\"id\":\"m00000000000003\",\"email\":\"e@f.g\",\"passwordHash\":\"" ++ bc ++ "\"}\n", .{ .collection = "members", .legacy_hash_algorithm = "md5" }));
    // The highest-value target is never importable.
    try std.testing.expectError(ImportError.LegacySuperuserRefused, runNdjson(&app, &d, io, "{\"id\":\"s00000000000001\",\"email\":\"root@x.io\",\"passwordHash\":\"" ++ bc ++ "\"}\n", .{ .collection = "_superusers", .legacy_hash_algorithm = "bcrypt" }));
}

test "import: WITHOUT --legacy-hashes a passwordHash in the row is silently ignored" {
    // The pre-existing strip must not weaken: an ordinary import can never install a
    // credential, no matter what the file claims.
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    const io = std.testing.io;
    try migrations.run(&d);
    const members = try collections.create(a, io, &d, .{
        .id = "",
        .name = "members",
        .type = .auth,
        .fields = &.{},
    });
    defer members.deinit(a);
    var app = testApp(std.testing.allocator, io);

    _ = try runNdjson(&app, &d, io, "{\"id\":\"m00000000000009\",\"email\":\"a@b.c\",\"passwordHash\":\"$2a$10$whatever\",\"verified\":true}\n", .{ .collection = "members" });
    var st = try d.prepare("SELECT \"passwordHash\", \"verified\" FROM \"members\" WHERE \"id\"='m00000000000009';");
    defer st.finalize();
    try std.testing.expect(try st.step());
    try std.testing.expectEqual(@as(usize, 0), st.columnText(0).len);
    try std.testing.expectEqual(@as(i64, 0), st.columnInt(1));
}

test "import: --legacy-hashes with preserve_ids=false is rejected before any write" {
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    const io = std.testing.io;
    try migrations.run(&d);
    const members = try collections.create(a, io, &d, .{
        .id = "",
        .name = "members",
        .type = .auth,
        .fields = &.{},
    });
    defer members.deinit(a);
    var app = testApp(std.testing.allocator, io);

    const bc = "$2a$10$N9qo8uLOickgx2ZMRZoMyeIjZAgcfl7p92ldGxad68LJZdL17lhWy";
    // This combination is rejected at validation time, before any row is read or written.
    try std.testing.expectError(
        ImportError.LegacyRequiresPreservedIds,
        runNdjson(&app, &d, io, "{\"id\":\"m00000000000001\",\"email\":\"a@b.c\",\"passwordHash\":\"" ++ bc ++ "\"}\n", .{
            .collection = "members",
            .legacy_hash_algorithm = "bcrypt",
            .preserve_ids = false,
        }),
    );
    // Verify nothing was written to the collection.
    var st = try d.prepare("SELECT COUNT(*) FROM \"members\";");
    defer st.finalize();
    try std.testing.expect(try st.step());
    try std.testing.expectEqual(@as(i64, 0), st.columnInt(0));
}

test "import: --legacy-hashes with an upsert key is rejected before any write" {
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    const io = std.testing.io;
    try migrations.run(&d);
    const members = try collections.create(a, io, &d, .{
        .id = "",
        .name = "members",
        .type = .auth,
        .fields = &.{},
    });
    defer members.deinit(a);
    var app = testApp(std.testing.allocator, io);

    const bc = "$2a$10$N9qo8uLOickgx2ZMRZoMyeIjZAgcfl7p92ldGxad68LJZdL17lhWy";
    // `importRow`'s upsert branch returns `.updated` BEFORE `applyLegacyCredential` runs, so
    // a matched row would land with no credential at all and the run would still exit 0.
    // The combination must be refused up front, with its own distinct error.
    try std.testing.expectError(
        ImportError.LegacyRequiresCreateOnly,
        runNdjson(&app, &d, io, "{\"id\":\"m00000000000001\",\"email\":\"a@b.c\",\"passwordHash\":\"" ++ bc ++ "\"}\n", .{
            .collection = "members",
            .legacy_hash_algorithm = "bcrypt",
            .upsert_key = "email",
        }),
    );
    try std.testing.expect(std.mem.indexOf(u8, last_error_detail, "create-only") != null);

    // Nothing was written — not even the row that would have been created had the refusal
    // come later (the check runs before the first line is read).
    var st = try d.prepare("SELECT COUNT(*) FROM \"members\";");
    defer st.finalize();
    try std.testing.expect(try st.step());
    try std.testing.expectEqual(@as(i64, 0), st.columnInt(0));
}

test "import: strip_fields drops the named keys before the engine sees them" {
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    const io = std.testing.io;
    const posts_col = try seedPosts(&d, a, io);
    defer posts_col.deinit(a);
    var app = testApp(std.testing.allocator, io);

    const rep = try runNdjson(&app, &d, io,
        \\{"title":"t","body":"dropped"}
        \\
    , .{ .collection = "posts", .strip_fields = &.{"body"} });
    try std.testing.expectEqual(@as(usize, 1), rep.created);
    var st = try d.prepare("SELECT \"body\" FROM \"posts\";");
    defer st.finalize();
    try std.testing.expect(try st.step());
    try std.testing.expectEqual(@as(usize, 0), st.columnText(0).len);
}

// ---------------------------------------------------------------------------
// external-auth linkage
// ---------------------------------------------------------------------------

/// An auth collection declaring one OAuth2 provider, for the linkage tests below.
fn seedLinkable(d: *db.Db, a: std.mem.Allocator, io: std.Io) !schema.Collection {
    return try collections.create(a, io, d, .{
        .id = "",
        .name = "members",
        .type = .auth,
        .fields = &.{},
        .options = .{ .auth = .{ .oauth2 = .{
            .enabled = true,
            .providers = &.{.{ .name = "google", .clientId = "cid", .clientSecret = "sec" }},
        } } },
    });
}

fn linkCountFor(d: *db.Db, record_id: []const u8) !i64 {
    var st = try d.prepare("SELECT COUNT(*) FROM \"_externalAuths\" WHERE \"recordRef\"=?1;");
    defer st.finalize();
    try st.bindText(1, record_id);
    _ = try st.step();
    return st.columnInt(0);
}

test "import: --external-auths installs provider linkage with the record" {
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    const io = std.testing.io;
    try migrations.run(&d);
    const members = try seedLinkable(&d, a, io);
    defer members.deinit(a);
    var app = testApp(a, io);

    const rep = try runNdjson(&app, &d, io,
        \\{"id":"member000000001","email":"ada@example.com","externalAuths":[{"provider":"google","providerId":"g-1"}]}
        \\
    , .{ .collection = "members", .external_auths = true });
    try std.testing.expectEqual(@as(usize, 1), rep.created);

    // The link must point at the imported record, so a later OAuth login resolves to it
    // instead of being refused as an already-registered email.
    const link = (try oauth.findLink(a, &d, "google", "g-1")).?;
    defer a.free(link.collectionRef);
    defer a.free(link.recordRef);
    try std.testing.expectEqualStrings("members", link.collectionRef);
    try std.testing.expectEqualStrings("member000000001", link.recordRef);
}

test "import: WITHOUT --external-auths the linkage in the row is silently ignored" {
    // Mirrors the passwordHash property: a file alone can never mint an identity link.
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    const io = std.testing.io;
    try migrations.run(&d);
    const members = try seedLinkable(&d, a, io);
    defer members.deinit(a);
    var app = testApp(a, io);

    _ = try runNdjson(&app, &d, io,
        \\{"id":"member000000001","email":"ada@example.com","externalAuths":[{"provider":"google","providerId":"g-1"}]}
        \\
    , .{ .collection = "members" });
    try std.testing.expectEqual(@as(i64, 0), try linkCountFor(&d, "member000000001"));
}

test "import: a disabled provider or disabled oauth2 is refused like an unknown one" {
    // The login path skips both, so a link naming either can never resolve -- the account
    // would exist and stay unreachable, which is the outcome this flag exists to prevent.
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    const io = std.testing.io;
    try migrations.run(&d);
    var app = testApp(a, io);
    const row =
        \\{"id":"member000000001","email":"ada@example.com","externalAuths":[{"provider":"google","providerId":"g-1"}]}
        \\
    ;

    // The provider itself is switched off.
    const off_provider = try collections.create(a, io, &d, .{
        .id = "",
        .name = "provider_off",
        .type = .auth,
        .fields = &.{},
        .options = .{ .auth = .{ .oauth2 = .{
            .enabled = true,
            .providers = &.{.{ .name = "google", .clientId = "cid", .clientSecret = "sec", .enabled = false }},
        } } },
    });
    defer off_provider.deinit(a);
    try std.testing.expectError(ImportError.UnknownExternalAuthProvider, runNdjson(&app, &d, io, row, .{ .collection = "provider_off", .external_auths = true }));

    // OAuth2 is switched off for the whole collection.
    const oauth_off = try collections.create(a, io, &d, .{
        .id = "",
        .name = "oauth_off",
        .type = .auth,
        .fields = &.{},
        .options = .{ .auth = .{ .oauth2 = .{
            .enabled = false,
            .providers = &.{.{ .name = "google", .clientId = "cid", .clientSecret = "sec" }},
        } } },
    });
    defer oauth_off.deinit(a);
    try std.testing.expectError(ImportError.UnknownExternalAuthProvider, runNdjson(&app, &d, io, row, .{ .collection = "oauth_off", .external_auths = true }));
}

test "import: an unconfigured provider is refused rather than left dangling" {
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    const io = std.testing.io;
    try migrations.run(&d);
    const members = try seedLinkable(&d, a, io);
    defer members.deinit(a);
    var app = testApp(a, io);

    try std.testing.expectError(ImportError.UnknownExternalAuthProvider, runNdjson(&app, &d, io,
        \\{"id":"member000000001","email":"ada@example.com","externalAuths":[{"provider":"githbu","providerId":"x"}]}
        \\
    , .{ .collection = "members", .external_auths = true }));
}

test "import: a duplicate identity is refused, never re-pointed" {
    // Silently moving an existing identity to another record is account takeover.
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    const io = std.testing.io;
    try migrations.run(&d);
    const members = try seedLinkable(&d, a, io);
    defer members.deinit(a);
    var app = testApp(a, io);

    _ = try runNdjson(&app, &d, io,
        \\{"id":"member000000001","email":"ada@example.com","externalAuths":[{"provider":"google","providerId":"g-1"}]}
        \\
    , .{ .collection = "members", .external_auths = true });

    try std.testing.expectError(ImportError.DuplicateExternalAuth, runNdjson(&app, &d, io,
        \\{"id":"member000000002","email":"bob@example.com","externalAuths":[{"provider":"google","providerId":"g-1"}]}
        \\
    , .{ .collection = "members", .external_auths = true }));

    // The original link is untouched by the refusal.
    const link = (try oauth.findLink(a, &d, "google", "g-1")).?;
    defer a.free(link.collectionRef);
    defer a.free(link.recordRef);
    try std.testing.expectEqualStrings("member000000001", link.recordRef);
}

test "import: a malformed linkage entry is refused" {
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    const io = std.testing.io;
    try migrations.run(&d);
    const members = try seedLinkable(&d, a, io);
    defer members.deinit(a);
    var app = testApp(a, io);

    for ([_][]const u8{
        "{\"id\":\"member000000001\",\"email\":\"a@b.c\",\"externalAuths\":{\"provider\":\"google\"}}\n",
        "{\"id\":\"member000000001\",\"email\":\"a@b.c\",\"externalAuths\":[{\"provider\":\"google\"}]}\n",
        "{\"id\":\"member000000001\",\"email\":\"a@b.c\",\"externalAuths\":[{\"provider\":\"\",\"providerId\":\"g\"}]}\n",
        "{\"id\":\"member000000001\",\"email\":\"a@b.c\",\"externalAuths\":[{\"provider\":\"google\",\"providerId\":\"\"}]}\n",
    }) |row| {
        try std.testing.expectError(ImportError.MalformedExternalAuth, runNdjson(&app, &d, io, row, .{ .collection = "members", .external_auths = true }));
    }
}

test "import: linkage requires an id on the row" {
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    const io = std.testing.io;
    try migrations.run(&d);
    const members = try seedLinkable(&d, a, io);
    defer members.deinit(a);
    var app = testApp(a, io);

    try std.testing.expectError(ImportError.ExternalAuthRowMissingId, runNdjson(&app, &d, io,
        \\{"email":"ada@example.com","externalAuths":[{"provider":"google","providerId":"g-1"}]}
        \\
    , .{ .collection = "members", .external_auths = true }));
}

test "import: linkage refuses a non-auth collection, _superusers, and an upsert key" {
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    const io = std.testing.io;
    try migrations.run(&d);
    const posts_col = try seedPosts(&d, a, io);
    defer posts_col.deinit(a);
    const members = try seedLinkable(&d, a, io);
    defer members.deinit(a);
    var app = testApp(a, io);

    try std.testing.expectError(ImportError.ExternalAuthRequiresAuthCollection, runNdjson(&app, &d, io, "{\"id\":\"p00000000000001\",\"title\":\"x\"}\n", .{ .collection = "posts", .external_auths = true }));
    // Linking a provider to a superuser would hand admin access to whoever holds it.
    try std.testing.expectError(ImportError.ExternalAuthSuperuserRefused, runNdjson(&app, &d, io, "{\"id\":\"s00000000000001\",\"email\":\"root@x.io\"}\n", .{ .collection = "_superusers", .external_auths = true }));
    // An upserted row returns before linkage runs, so the account would exist unreachable.
    try std.testing.expectError(ImportError.ExternalAuthRequiresCreateOnly, runNdjson(&app, &d, io, "{\"id\":\"member000000001\",\"email\":\"a@b.c\"}\n", .{ .collection = "members", .external_auths = true, .upsert_key = "email" }));
}

test "import: a refused link rolls back the record it belonged to" {
    // The account and the identity that reaches it commit together or not at all.
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    const io = std.testing.io;
    try migrations.run(&d);
    const members = try seedLinkable(&d, a, io);
    defer members.deinit(a);
    var app = testApp(a, io);

    try std.testing.expectError(ImportError.UnknownExternalAuthProvider, runNdjson(&app, &d, io,
        \\{"id":"member000000001","email":"ada@example.com","externalAuths":[{"provider":"nope","providerId":"x"}]}
        \\
    , .{ .collection = "members", .external_auths = true }));

    var st = try d.prepare("SELECT COUNT(*) FROM \"members\" WHERE \"id\"='member000000001';");
    defer st.finalize();
    _ = try st.step();
    try std.testing.expectEqual(@as(i64, 0), st.columnInt(0));
}
