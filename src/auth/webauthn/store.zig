const std = @import("std");
const db = @import("../../db.zig");
const id_gen = @import("../../id.zig");
const param_sink = @import("../../sql/param_sink.zig");

/// Lower + renumber a curated `_webauthnCredentials` statement for `conn`'s backend, then prepare.
/// SQLite gets verbatim `?N`/`datetime('now')` (zero-cost); Postgres gets `$n` + `now()`. The lowered
/// SQL lives in a transient arena (`Db.prepare` copies it), so it need only outlive the call.
fn prep(conn: *db.Db, sql: [:0]const u8) db.DbError!db.Stmt {
    // Arena over the page allocator: no fixed ceiling (lowerStmtZ makes several intermediate
    // allocations that the arena frees together on return), and on SQLite lowerStmtZ is a no-op
    // returning the input slice, so this costs one empty arena. `Db.prepare` copies the text.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const lowered = param_sink.lowerStmtZ(arena.allocator(), db.dbDialect(conn), sql) catch return db.DbError.PrepareFailed;
    return conn.prepare(lowered);
}

/// A single registered WebAuthn credential as returned by `getByCredentialId`.
pub const Credential = struct {
    id: []const u8,
    collection_ref: []const u8,
    record_ref: []const u8,
    credential_id: []const u8,
    public_key: []const u8,
    alg: i64,
    sign_count: u32,
    aaguid: []const u8,
};

/// Thin data-access layer over the `_webauthnCredentials` table (created by migration 0008).
/// All methods that need entropy take `io: anytype` (compatible with `std.Io` and test io).
/// All write methods use parameter-bound SQL — no string interpolation of values.
pub const CredentialStore = struct {
    conn: *db.Db,

    /// Insert a new credential row. `credential_id_b64` and `cose_pubkey_b64` must already be
    /// base64(url)-encoded strings. Returns `error.StepFailed` (propagated from SQLite) when the
    /// `credentialId` UNIQUE constraint fires (i.e. the credential is already registered).
    pub fn insert(
        self: CredentialStore,
        alloc: std.mem.Allocator,
        io: anytype,
        collection_ref: []const u8,
        record_ref: []const u8,
        credential_id_b64: []const u8,
        cose_pubkey_b64: []const u8,
        alg: i64,
        sign_count: u32,
        aaguid_b64: []const u8,
        transports: []const u8,
    ) !void {
        _ = alloc;
        var rid = id_gen.collectionId(io);
        var st = try prep(self.conn,
            \\INSERT INTO "_webauthnCredentials"
            \\  ("id","collectionRef","recordRef","credentialId","publicKey","alg","signCount","aaguid","transports","created","updated")
            \\ VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,datetime('now'),datetime('now'));
        );
        defer st.finalize();
        try st.bindText(1, &rid);
        try st.bindText(2, collection_ref);
        try st.bindText(3, record_ref);
        try st.bindText(4, credential_id_b64);
        try st.bindText(5, cose_pubkey_b64);
        try st.bindInt(6, alg);
        try st.bindInt(7, @as(i64, sign_count));
        try st.bindText(8, aaguid_b64);
        try st.bindText(9, transports);
        _ = try st.step();
    }

    /// Look up a credential by its base64url credential id (the assertion lookup key).
    /// Returns `null` when no such credential exists. All string fields are duplicated from `alloc`.
    pub fn getByCredentialId(
        self: CredentialStore,
        alloc: std.mem.Allocator,
        credential_id_b64: []const u8,
    ) !?Credential {
        var st = try prep(self.conn,
            \\SELECT "id","collectionRef","recordRef","credentialId","publicKey","alg","signCount","aaguid"
            \\ FROM "_webauthnCredentials" WHERE "credentialId"=?1;
        );
        defer st.finalize();
        try st.bindText(1, credential_id_b64);
        if (!try st.step()) return null;
        return .{
            .id = try alloc.dupe(u8, st.columnText(0)),
            .collection_ref = try alloc.dupe(u8, st.columnText(1)),
            .record_ref = try alloc.dupe(u8, st.columnText(2)),
            .credential_id = try alloc.dupe(u8, st.columnText(3)),
            .public_key = try alloc.dupe(u8, st.columnText(4)),
            .alg = st.columnInt(5),
            .sign_count = @intCast(st.columnInt(6)),
            .aaguid = try alloc.dupe(u8, st.columnText(7)),
        };
    }

    /// Update the stored `signCount` after a successful assertion (clone-detection counter).
    pub fn updateSignCount(
        self: CredentialStore,
        credential_id_b64: []const u8,
        new_count: u32,
    ) !void {
        var st = try prep(self.conn,
            \\UPDATE "_webauthnCredentials"
            \\ SET "signCount"=?1,"updated"=datetime('now')
            \\ WHERE "credentialId"=?2;
        );
        defer st.finalize();
        try st.bindInt(1, @as(i64, new_count));
        try st.bindText(2, credential_id_b64);
        _ = try st.step();
    }

    /// Uniqueness pre-check at registration time. Returns true if the credential id is already
    /// stored (caller should abort the registration). Cheaper than catching a UNIQUE violation.
    pub fn existsCredentialId(
        self: CredentialStore,
        credential_id_b64: []const u8,
    ) !bool {
        var st = try prep(self.conn,
            \\SELECT 1 FROM "_webauthnCredentials" WHERE "credentialId"=?1 LIMIT 1;
        );
        defer st.finalize();
        try st.bindText(1, credential_id_b64);
        return try st.step();
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const migrations = @import("../../migrations.zig");

test "CredentialStore: insert / getByCredentialId / existsCredentialId / updateSignCount / uniqueness" {
    var d = try db.Db.openMemory();
    defer d.close();
    // Apply all system migrations so the table exists.
    try migrations.run(&d);

    const store = CredentialStore{ .conn = &d };
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    // --- insert a credential ---
    try store.insert(
        alloc,
        io,
        "users",       // collection_ref
        "rec001",      // record_ref
        "cred_b64url", // credential_id_b64
        "pubkey_b64",  // cose_pubkey_b64
        -7,            // alg  (ES256)
        0,             // sign_count at registration
        "aaguid_b64",  // aaguid
        "usb,nfc",     // transports
    );

    // --- getByCredentialId returns the row ---
    const maybe = try store.getByCredentialId(alloc, "cred_b64url");
    try std.testing.expect(maybe != null);
    const cred = maybe.?;
    defer {
        alloc.free(cred.id);
        alloc.free(cred.collection_ref);
        alloc.free(cred.record_ref);
        alloc.free(cred.credential_id);
        alloc.free(cred.public_key);
        alloc.free(cred.aaguid);
    }
    try std.testing.expectEqualStrings("users", cred.collection_ref);
    try std.testing.expectEqualStrings("rec001", cred.record_ref);
    try std.testing.expectEqualStrings("pubkey_b64", cred.public_key);
    try std.testing.expectEqual(@as(i64, -7), cred.alg);
    try std.testing.expectEqual(@as(u32, 0), cred.sign_count);

    // --- existsCredentialId: true for known, false for unknown ---
    try std.testing.expect(try store.existsCredentialId("cred_b64url"));
    try std.testing.expect(!try store.existsCredentialId("does_not_exist"));

    // --- updateSignCount updates the counter ---
    try store.updateSignCount("cred_b64url", 5);
    const after = (try store.getByCredentialId(alloc, "cred_b64url")).?;
    defer {
        alloc.free(after.id);
        alloc.free(after.collection_ref);
        alloc.free(after.record_ref);
        alloc.free(after.credential_id);
        alloc.free(after.public_key);
        alloc.free(after.aaguid);
    }
    try std.testing.expectEqual(@as(u32, 5), after.sign_count);

    // --- second insert with same credentialId must fail (UNIQUE constraint) ---
    try std.testing.expectError(
        error.StepFailed,
        store.insert(alloc, io, "users", "rec002", "cred_b64url", "other_key", -7, 0, "", ""),
    );
}

test "CredentialStore: getByCredentialId returns null for unknown id" {
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    const store = CredentialStore{ .conn = &d };
    const result = try store.getByCredentialId(std.testing.allocator, "nonexistent");
    try std.testing.expect(result == null);
}
