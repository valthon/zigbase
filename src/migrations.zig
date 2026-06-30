const std = @import("std");
const db = @import("db.zig");
const Migrator = @import("migrator.zig").Migrator;

/// A system migration. `up` receives a `*Migrator` carrying the active SQL `Dialect`, so the SAME
/// migration code emits backend-correct SQL on SQLite and Postgres (#159, PR-2). Bodies use
/// `m.execLowered(sql)` — curated SQLite-flavor SQL the dialect lowers (INTEGER→BIGINT,
/// datetime('now')→a text now, INSERT OR IGNORE→ON CONFLICT DO NOTHING) on Postgres while leaving
/// SQLite byte-identical.
pub const Migration = struct { name: []const u8, up: *const fn (m: *Migrator) db.DbError!void };

fn init_0001(m: *Migrator) db.DbError!void {
    try m.execLowered(
        \\CREATE TABLE IF NOT EXISTS "_collections" (
        \\  "id" TEXT PRIMARY KEY, "name" TEXT UNIQUE NOT NULL, "type" TEXT NOT NULL DEFAULT 'base',
        \\  "system" INTEGER NOT NULL DEFAULT 0, "schema" TEXT NOT NULL DEFAULT '[]',
        \\  "indexes" TEXT NOT NULL DEFAULT '[]',
        \\  "listRule" TEXT, "viewRule" TEXT, "createRule" TEXT, "updateRule" TEXT, "deleteRule" TEXT,
        \\  "created" TEXT NOT NULL, "updated" TEXT NOT NULL
        \\);
    );
}

fn init_0002(m: *Migrator) db.DbError!void {
    // add the options column (ignore the duplicate-column error if somehow re-run)
    m.execLowered("ALTER TABLE \"_collections\" ADD COLUMN \"options\" TEXT NOT NULL DEFAULT '{}';") catch {};
    // _superusers system auth collection: its physical table + its _collections row
    try m.execLowered(
        \\CREATE TABLE IF NOT EXISTS "_superusers" (
        \\  "id" TEXT PRIMARY KEY, "created" TEXT, "updated" TEXT,
        \\  "email" TEXT UNIQUE, "username" TEXT, "passwordHash" TEXT, "tokenKey" TEXT, "verified" INTEGER
        \\);
    );
    try m.execLowered(
        \\INSERT OR IGNORE INTO "_collections"
        \\  ("id","name","type","system","schema","indexes","options","listRule","viewRule","createRule","updateRule","deleteRule","created","updated")
        \\ VALUES ('_superusers_____','_superusers','auth',1,'[]','[]',
        \\  '{"auth":{"identityFields":["email"],"minPasswordLength":8}}',
        \\  NULL,NULL,NULL,NULL,NULL,datetime('now'),datetime('now'));
    );
}

fn init_0003(m: *Migrator) db.DbError!void {
    try m.execLowered(
        \\CREATE TABLE IF NOT EXISTS "_externalAuths" (
        \\  "id" TEXT PRIMARY KEY, "collectionRef" TEXT NOT NULL, "recordRef" TEXT NOT NULL,
        \\  "provider" TEXT NOT NULL, "providerId" TEXT NOT NULL,
        \\  "created" TEXT NOT NULL, "updated" TEXT NOT NULL
        \\);
    );
    try m.execLowered("CREATE UNIQUE INDEX IF NOT EXISTS \"idx_extauth_provider_pid\" ON \"_externalAuths\" (\"provider\",\"providerId\");");
    try m.execLowered("CREATE UNIQUE INDEX IF NOT EXISTS \"idx_extauth_rec_provider\" ON \"_externalAuths\" (\"collectionRef\",\"recordRef\",\"provider\");");
}

fn init_0004(m: *Migrator) db.DbError!void {
    // Single-use ledger for verification / password-reset tokens (F7). A token's
    // random "jti" claim is recorded here on first redemption; a UNIQUE primary key
    // makes a second redemption fail atomically under the writer lock, independent of
    // any tokenKey-rotation side effect. "expires" is the token's own exp (unix secs)
    // so a sweeper can prune entries once the token could no longer verify anyway.
    try m.execLowered(
        \\CREATE TABLE IF NOT EXISTS "_consumedTokens" (
        \\  "jti" TEXT PRIMARY KEY, "expires" INTEGER NOT NULL, "consumed" TEXT NOT NULL
        \\);
    );
    try m.execLowered("CREATE INDEX IF NOT EXISTS \"idx_consumed_expires\" ON \"_consumedTokens\" (\"expires\");");
}

fn init_0005(m: *Migrator) db.DbError!void {
    // Optional server-side OAuth `state` store (F11). When server-side CSRF protection
    // is enabled, auth-init mints a random state here; the callback verifies and deletes
    // it (single-use). "expires" is a unix-seconds TTL; a missing/mismatched/expired/reused
    // state is rejected. Unused when server-side state is disabled (client-driven flow).
    try m.execLowered(
        \\CREATE TABLE IF NOT EXISTS "_oauthStates" (
        \\  "state" TEXT PRIMARY KEY, "collectionRef" TEXT NOT NULL, "provider" TEXT NOT NULL,
        \\  "expires" INTEGER NOT NULL, "created" TEXT NOT NULL
        \\);
    );
    try m.execLowered("CREATE INDEX IF NOT EXISTS \"idx_oauthstate_expires\" ON \"_oauthStates\" (\"expires\");");
}

fn init_0006(m: *Migrator) db.DbError!void {
    // Server-side keyset-cursor state store for the STATEFUL token format
    // (App(.{ .pagination = .{ .cursor_token = .stateful } })). A minted cursor stores its
    // opaque keyset payload here keyed by a random "id"; the client receives only the id.
    // On use the payload is looked up (if unexpired) and decoded. "expires" is a unix-seconds
    // TTL; a periodic GC (records.gcCursorStates) prunes expired rows, and an index on
    // "expires" keeps that sweep cheap. Unused entirely in the stateless/signed modes.
    try m.execLowered(
        \\CREATE TABLE IF NOT EXISTS "_cursorStates" (
        \\  "id" TEXT PRIMARY KEY, "collectionRef" TEXT NOT NULL, "payload" TEXT NOT NULL,
        \\  "expires" INTEGER NOT NULL, "created" TEXT NOT NULL
        \\);
    );
    try m.execLowered("CREATE INDEX IF NOT EXISTS \"idx_cursorstate_expires\" ON \"_cursorStates\" (\"expires\");");
}

fn init_0007(m: *Migrator) db.DbError!void {
    // Server-side challenge store for pluggable auth methods (OTP, magic-link, FIDO2, etc.).
    // A challenge is minted by `put`, returned to the client as an opaque id (or embedded in
    // a URL), and redeemed exactly once by `take`/`takeByIdentity`. "consumed" tracks
    // single-use semantics atomically under the writer lock; "expires" is a unix-seconds TTL.
    // A periodic GC (auth/challenge_store.gcAuthChallenges) prunes consumed/expired rows.
    try m.execLowered(
        \\CREATE TABLE IF NOT EXISTS "_authChallenges" (
        \\  "id" TEXT PRIMARY KEY, "collectionRef" TEXT NOT NULL, "method" TEXT NOT NULL,
        \\  "identity" TEXT NOT NULL, "payload" TEXT NOT NULL, "expires" INTEGER NOT NULL,
        \\  "consumed" INTEGER NOT NULL DEFAULT 0, "created" TEXT NOT NULL
        \\);
    );
    try m.execLowered("CREATE INDEX IF NOT EXISTS \"idx_authchallenge_expires\" ON \"_authChallenges\" (\"expires\");");
    try m.execLowered("CREATE INDEX IF NOT EXISTS \"idx_authchallenge_lookup\" ON \"_authChallenges\" (\"collectionRef\",\"method\",\"identity\");");
}

fn init_0008(m: *Migrator) db.DbError!void {
    // Per-credential WebAuthn store. One row per registered authenticator credential.
    // "credentialId" is the base64url of the raw credential id bytes returned by the
    // authenticator; it is the lookup key on every assertion and must be globally unique.
    // "publicKey" stores the COSE_Key bytes (base64-encoded) used to verify assertion
    // signatures. "signCount" is updated after every successful assertion (clone detection).
    // "alg" is the COSE algorithm id (e.g. -7 for ES256). "aaguid" / "transports" are
    // RECOMMENDED for passkey UX but optional; they default to empty string.
    try m.execLowered(
        \\CREATE TABLE IF NOT EXISTS "_webauthnCredentials" (
        \\  "id" TEXT PRIMARY KEY,
        \\  "collectionRef" TEXT NOT NULL,
        \\  "recordRef" TEXT NOT NULL,
        \\  "credentialId" TEXT NOT NULL UNIQUE,
        \\  "publicKey" TEXT NOT NULL,
        \\  "alg" INTEGER NOT NULL,
        \\  "signCount" INTEGER NOT NULL,
        \\  "aaguid" TEXT NOT NULL DEFAULT '',
        \\  "transports" TEXT NOT NULL DEFAULT '',
        \\  "created" TEXT NOT NULL,
        \\  "updated" TEXT NOT NULL
        \\);
    );
    try m.execLowered("CREATE INDEX IF NOT EXISTS \"idx_webauthncred_record\" ON \"_webauthnCredentials\" (\"collectionRef\",\"recordRef\");");
}

fn init_0009_kv(m: *Migrator) db.DbError!void {
    // Built-in key→value/settings store (#87). A single internal table holding small,
    // mutable, superuser-managed values keyed by an arbitrary string: feature flags
    // (#88, a typed bool view over this same store), maintenance toggles, cached
    // external tokens, a JSON settings blob the caller (de)serializes, etc. It is NOT a
    // `_collections` row, so it is invisible to the record API, query engine, and
    // access-rule system — settings stay superuser-only by default. "created"/"updated"
    // are ISO-8601 datetimes; an upsert preserves "created" and bumps "updated".
    try m.execLowered(
        \\CREATE TABLE IF NOT EXISTS "_kv" (
        \\  "key" TEXT PRIMARY KEY,
        \\  "value" TEXT NOT NULL,
        \\  "created" TEXT NOT NULL,
        \\  "updated" TEXT NOT NULL
        \\);
    );
}

fn init_0010_token_epoch(m: *Migrator) db.DbError!void {
    // Session epoch column for Variant A revocation (#99). A per-auth-record integer,
    // default 0, embedded in issued `.auth` tokens; "revoke all sessions" bumps it so
    // every outstanding token for the principal stops verifying. Added here for tables
    // that predate the `token_epoch` auth system field (fresh auth collections get the
    // column from `schema.authSystemFields()` at create time). `NOT NULL DEFAULT 0` so
    // existing rows + omitted inserts read as epoch 0, matching the default JWT claim.
    // `execLowered` maps the INTEGER type keyword to the backend (BIGINT on Postgres).
    m.execLowered("ALTER TABLE \"_superusers\" ADD COLUMN \"token_epoch\" INTEGER NOT NULL DEFAULT 0;") catch {};

    // Collect user auth-collection names FIRST: an ALTER TABLE bumps SQLite's schema
    // version and invalidates any open statement, so we cannot ALTER while iterating the
    // _collections cursor. page_allocator (one-shot, startup) keeps this dependency-free.
    const a = std.heap.page_allocator;
    const int_ty = m.dialect.sqlType(.integer);
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |n| a.free(n);
        names.deinit(a);
    }
    {
        // No placeholders → portable across backends; prepare directly.
        var st = try m.db.prepare("SELECT \"name\" FROM \"_collections\" WHERE \"type\"='auth' AND \"name\" != '_superusers';");
        defer st.finalize();
        while (try st.step()) {
            const nm = a.dupe(u8, st.columnText(0)) catch return error.ExecFailed;
            names.append(a, nm) catch {
                a.free(nm);
                return error.ExecFailed;
            };
        }
    }
    for (names.items) |nm| {
        if (!isSafeIdent(nm)) continue; // defensive: never interpolate an unvalidated name
        // Allocate the ALTER (no fixed buffer) so a long-but-valid collection name is never
        // stranded without the column — `schema.isValidIdentifier` has no length cap, so a
        // 251+ char name passes creation and MUST also be migrated here. The column type comes
        // from the dialect (BIGINT on Postgres, INTEGER on SQLite).
        const sql = std.fmt.allocPrintSentinel(a, "ALTER TABLE \"{s}\" ADD COLUMN \"token_epoch\" {s} NOT NULL DEFAULT 0;", .{ nm, int_ty }, 0) catch return error.ExecFailed;
        defer a.free(sql);
        m.db.exec(sql) catch {}; // ignore "duplicate column" when the column already exists
    }
}

/// Local identifier guard for migration 0010's dynamic ALTER (avoids importing schema.zig).
/// Mirrors `schema.isValidIdentifier`'s CHAR CLASS (first char a letter, rest alphanumeric/
/// underscore) for injection safety. Deliberately NO length cap — `isValidIdentifier` has
/// none either, so capping here would strand a long-but-valid auth table without the column.
fn isSafeIdent(s: []const u8) bool {
    if (s.len == 0) return false;
    if (!std.ascii.isAlphabetic(s[0])) return false;
    for (s) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_') return false;
    return true;
}

fn init_0011_sessions(m: *Migrator) db.DbError!void {
    // Variant B session store (#99), populated only when App(.{ .session_store = .table }).
    // One row per issued session enables per-device listActiveSessions()/revoke(sessionId)
    // on top of revoke-all. In the default `.epoch` mode this table is created but stays empty
    // (revocation runs via the token epoch, zero session-table work). Owner = (collectionRef,
    // recordRef) — the auth collection NAME + record id, matching `_externalAuths`. `expires`
    // is nullable (NULL = no expiry); verify accepts `expires IS NULL OR expires > now`.
    // Revocation DELETEs the row. `lastSeen`/`userAgent`/`ip` feed the per-device UI.
    try m.execLowered(
        \\CREATE TABLE IF NOT EXISTS "_sessions" (
        \\  "id" TEXT PRIMARY KEY,
        \\  "collectionRef" TEXT NOT NULL,
        \\  "recordRef" TEXT NOT NULL,
        \\  "created" TEXT NOT NULL,
        \\  "lastSeen" TEXT NOT NULL DEFAULT '',
        \\  "expires" INTEGER,
        \\  "userAgent" TEXT NOT NULL DEFAULT '',
        \\  "ip" TEXT NOT NULL DEFAULT ''
        \\);
    );
    try m.execLowered("CREATE INDEX IF NOT EXISTS \"idx_sessions_owner\" ON \"_sessions\" (\"collectionRef\",\"recordRef\");");
    try m.execLowered("CREATE INDEX IF NOT EXISTS \"idx_sessions_expires\" ON \"_sessions\" (\"expires\");");
}

fn init_0012_experiment_assignments(m: *Migrator) db.DbError!void {
    // Sticky experiment assignments (#129): one row per (experiment, subject) persists
    // the FIRST variant the subject was bucketed into, so a later weight change never
    // re-buckets an already-assigned subject (the survive-weight-change guarantee).
    // Populated only for experiments declared `.sticky = true`; pure-hash experiments
    // never touch this table. `created` is an ISO-8601 UTC string (matches the records
    // autodate format); the index on it lets the comptime-gated `_experiment_gc` job
    // reap rows older than `.experiment_assignment_ttl` in bounded batches.
    try m.execLowered(
        \\CREATE TABLE IF NOT EXISTS "_experiment_assignments" (
        \\  "experiment" TEXT NOT NULL,
        \\  "subject" TEXT NOT NULL,
        \\  "variant" TEXT NOT NULL,
        \\  "created" TEXT NOT NULL,
        \\  PRIMARY KEY ("experiment","subject")
        \\);
    );
    try m.execLowered("CREATE INDEX IF NOT EXISTS \"idx_experiment_assignments_created\" ON \"_experiment_assignments\" (\"created\");");
}

fn init_0013_queue_jobs(m: *Migrator) db.DbError!void {
    // Durable background-job queue (#137 PR2). One row per enqueued durable job; the
    // memory backend never touches this table. A per-worker poller claims ready rows
    // (status='pending' AND run_at<=now) for its queues, ORDER BY priority,run_at,
    // marking them 'claimed' (claimed_at/claimed_by) — at-least-once: a crashed worker's
    // 'claimed' row is reclaimed to 'pending' once claimed_at is older than the visibility
    // timeout. On success → 'done'; a retryable failure bumps attempts and pushes run_at
    // out by the backoff; exhausting max_attempts → 'failed' (last_error + .onError). The
    // (status,priority,run_at) index serves the claim query; (created) serves the GC sweep
    // that reaps old done/failed rows in bounded batches (mirrors _experiment_assignments).
    try m.execLowered(
        \\CREATE TABLE IF NOT EXISTS "_queue_jobs" (
        \\  "id" TEXT PRIMARY KEY,
        \\  "queue" TEXT NOT NULL,
        \\  "kind" TEXT NOT NULL,
        \\  "payload" TEXT NOT NULL DEFAULT '',
        \\  "priority" INTEGER NOT NULL DEFAULT 1,
        \\  "attempts" INTEGER NOT NULL DEFAULT 0,
        \\  "max_attempts" INTEGER NOT NULL DEFAULT 5,
        \\  "run_at" INTEGER NOT NULL DEFAULT 0,
        \\  "claimed_at" INTEGER,
        \\  "claimed_by" TEXT NOT NULL DEFAULT '',
        \\  "status" TEXT NOT NULL DEFAULT 'pending',
        \\  "last_error" TEXT NOT NULL DEFAULT '',
        \\  "created" TEXT NOT NULL
        \\);
    );
    // Column order matches the claim query: status (equality) then the ORDER BY
    // (priority, run_at), so SQLite can serve the sort straight from the index (no
    // filesort) and stop at LIMIT instead of materializing every ready row.
    try m.execLowered("CREATE INDEX IF NOT EXISTS \"idx_queue_jobs_ready\" ON \"_queue_jobs\" (\"status\",\"priority\",\"run_at\");");
    try m.execLowered("CREATE INDEX IF NOT EXISTS \"idx_queue_jobs_created\" ON \"_queue_jobs\" (\"created\");");
}

fn init_0014_tenancy(m: *Migrator) db.DbError!void {
    // Multi-tenancy data model (#156, PR2). Three built-in system collections back account-scoped
    // tenancy. They are seeded into `_collections` with system=1 and HARDCODED stable field ids
    // (8-char, matching `provision`'s FNV id width) so additive rebuilds match columns by id and a
    // raw-SQL migration can index the human-named physical columns directly. Membership
    // lifecycle (invite / accept / remove) is PR4 — this migration creates TABLES ONLY.
    //
    // _accounts: one row per tenant. `slug` is the human handle (UNIQUE); `owner_user` is the
    // creating principal's record id; `status` gates soft-disable.
    try m.execLowered(
        \\CREATE TABLE IF NOT EXISTS "_accounts" (
        \\  "id" TEXT PRIMARY KEY, "created" TEXT NOT NULL, "updated" TEXT NOT NULL,
        \\  "name" TEXT NOT NULL DEFAULT '',
        \\  "slug" TEXT NOT NULL,
        \\  "owner_user" TEXT NOT NULL DEFAULT '',
        \\  "status" TEXT NOT NULL DEFAULT 'active'
        \\);
    );
    try m.execLowered("CREATE UNIQUE INDEX IF NOT EXISTS \"idx_accounts_slug\" ON \"_accounts\" (\"slug\");");

    // _memberships: the principal<->account edge. `(user_collection,user)` is a COMPOSITE owner
    // (mirrors _sessions/_externalAuths) because multiple auth collections may exist. `role` is a
    // tenancy role (see tenancy/roles.zig); `status` is 'active' once accepted. The
    // (user_collection,user,status) index serves the per-request "my active accounts" resolution
    // SELECT; (account,status) serves account member listings.
    try m.execLowered(
        \\CREATE TABLE IF NOT EXISTS "_memberships" (
        \\  "id" TEXT PRIMARY KEY, "created" TEXT NOT NULL, "updated" TEXT NOT NULL,
        \\  "account" TEXT NOT NULL,
        \\  "user_collection" TEXT NOT NULL,
        \\  "user" TEXT NOT NULL,
        \\  "role" TEXT NOT NULL DEFAULT 'viewer',
        \\  "status" TEXT NOT NULL DEFAULT 'active'
        \\);
    );
    try m.execLowered("CREATE UNIQUE INDEX IF NOT EXISTS \"idx_memberships_unique\" ON \"_memberships\" (\"account\",\"user_collection\",\"user\");");
    try m.execLowered("CREATE INDEX IF NOT EXISTS \"idx_memberships_user\" ON \"_memberships\" (\"user_collection\",\"user\",\"status\");");
    try m.execLowered("CREATE INDEX IF NOT EXISTS \"idx_memberships_account\" ON \"_memberships\" (\"account\",\"status\");");

    // _invitations: a pending invite to join an account. `token` is the single-use claim handle
    // (UNIQUE); `expires`/`accepted_at` drive the accept flow (wired in PR4).
    try m.execLowered(
        \\CREATE TABLE IF NOT EXISTS "_invitations" (
        \\  "id" TEXT PRIMARY KEY, "created" TEXT NOT NULL, "updated" TEXT NOT NULL,
        \\  "account" TEXT NOT NULL,
        \\  "email" TEXT NOT NULL DEFAULT '',
        \\  "role" TEXT NOT NULL DEFAULT 'viewer',
        \\  "token" TEXT NOT NULL,
        \\  "invited_by" TEXT NOT NULL DEFAULT '',
        \\  "expires" TEXT NOT NULL DEFAULT '',
        \\  "accepted_at" TEXT NOT NULL DEFAULT ''
        \\);
    );
    try m.execLowered("CREATE UNIQUE INDEX IF NOT EXISTS \"idx_invitations_token\" ON \"_invitations\" (\"token\");");
    try m.execLowered("CREATE INDEX IF NOT EXISTS \"idx_invitations_account\" ON \"_invitations\" (\"account\");");

    // Seed the three `_collections` rows (system=1) so the engine can address them as collections.
    // The `schema` blob carries each row's user fields with HARDCODED stable field ids (id/created/
    // updated are implicit base columns and are NOT listed). Rules are NULL = Locked (superusers
    // only) — tenant CRUD lands in PR4; until then only superuser tooling touches these tables.
    try m.execLowered(
        \\INSERT OR IGNORE INTO "_collections"
        \\  ("id","name","type","system","schema","indexes","options","listRule","viewRule","createRule","updateRule","deleteRule","created","updated")
        \\ VALUES
        \\  ('_accounts______','_accounts','base',1,
        \\    '[{"id":"acctname","name":"name","type":"text","options":{}},{"id":"acctslug","name":"slug","type":"text","unique":true,"options":{}},{"id":"acctownr","name":"owner_user","type":"text","options":{}},{"id":"acctstat","name":"status","type":"text","options":{}}]',
        \\    '[]','{}',NULL,NULL,NULL,NULL,NULL,datetime('now'),datetime('now')),
        \\  ('_memberships___','_memberships','base',1,
        \\    '[{"id":"membacct","name":"account","type":"text","options":{}},{"id":"membucol","name":"user_collection","type":"text","options":{}},{"id":"membuser","name":"user","type":"text","options":{}},{"id":"membrole","name":"role","type":"text","options":{}},{"id":"membstat","name":"status","type":"text","options":{}}]',
        \\    '[]','{}',NULL,NULL,NULL,NULL,NULL,datetime('now'),datetime('now')),
        \\  ('_invitations___','_invitations','base',1,
        \\    '[{"id":"invtacct","name":"account","type":"text","options":{}},{"id":"invtmail","name":"email","type":"email","options":{}},{"id":"invtrole","name":"role","type":"text","options":{}},{"id":"invttokn","name":"token","type":"text","unique":true,"options":{}},{"id":"invtinvb","name":"invited_by","type":"text","options":{}},{"id":"invtexpr","name":"expires","type":"text","options":{}},{"id":"invtacpt","name":"accepted_at","type":"text","options":{}}]',
        \\    '[]','{}',NULL,NULL,NULL,NULL,NULL,datetime('now'),datetime('now'));
    );
}

fn init_0016_email(m: *Migrator) db.DbError!void {
    // Email subsystem (#154): verified per-account sender identities + bounce/complaint
    // suppression. Two built-in system collections, seeded into `_collections` with system=1 and
    // HARDCODED 8-char stable field ids (matching `provision`'s FNV id width) so additive rebuilds
    // match columns by id. Rules are NULL = Locked (superusers only): tenant CRUD goes through the
    // dedicated, account-scoped sender-management + webhook routes (api/senders.zig, mail/inbound.zig),
    // NOT the generic record API. (NOTE: 0015 is reserved for the parallel analytics workstream.)
    //
    // _sender_identities: one row per (account, from-email). A send whose From is not a `verified`
    // identity for the sending account is REJECTED when verified-sender enforcement is on. `status`
    // is 'pending' until the verification token is confirmed, then 'verified' + `verified_at` set.
    try m.execLowered(
        \\CREATE TABLE IF NOT EXISTS "_sender_identities" (
        \\  "id" TEXT PRIMARY KEY, "created" TEXT NOT NULL, "updated" TEXT NOT NULL,
        \\  "account" TEXT NOT NULL DEFAULT '',
        \\  "email" TEXT NOT NULL,
        \\  "verified_at" TEXT NOT NULL DEFAULT '',
        \\  "verification_token" TEXT NOT NULL DEFAULT '',
        \\  "status" TEXT NOT NULL DEFAULT 'pending'
        \\);
    );
    try m.execLowered("CREATE UNIQUE INDEX IF NOT EXISTS \"idx_sender_identities_unique\" ON \"_sender_identities\" (\"account\",\"email\");");
    try m.execLowered("CREATE INDEX IF NOT EXISTS \"idx_sender_identities_token\" ON \"_sender_identities\" (\"verification_token\");");

    // _suppressions: a (account, email) the app must NOT send to, populated by the bounce/complaint
    // webhook on a hard bounce or complaint. `reason` is 'hard_bounce'|'complaint'; `source` records
    // the provider ('ses'|'postmark'|…). A send to a suppressed address is BLOCKED when suppression
    // checking is on. An empty `account` is a GLOBAL suppression (applies to every account's sends).
    try m.execLowered(
        \\CREATE TABLE IF NOT EXISTS "_suppressions" (
        \\  "id" TEXT PRIMARY KEY, "created" TEXT NOT NULL,
        \\  "account" TEXT NOT NULL DEFAULT '',
        \\  "email" TEXT NOT NULL,
        \\  "reason" TEXT NOT NULL DEFAULT '',
        \\  "source" TEXT NOT NULL DEFAULT ''
        \\);
    );
    try m.execLowered("CREATE UNIQUE INDEX IF NOT EXISTS \"idx_suppressions_unique\" ON \"_suppressions\" (\"account\",\"email\");");
    try m.execLowered("CREATE INDEX IF NOT EXISTS \"idx_suppressions_email\" ON \"_suppressions\" (\"email\");");

    // Seed the two `_collections` rows (system=1). id/created/updated are implicit base columns and
    // are NOT listed in the schema blob. Rules NULL = Locked (superusers only).
    try m.execLowered(
        \\INSERT OR IGNORE INTO "_collections"
        \\  ("id","name","type","system","schema","indexes","options","listRule","viewRule","createRule","updateRule","deleteRule","created","updated")
        \\ VALUES
        \\  ('_senderidents_','_sender_identities','base',1,
        \\    '[{"id":"sidaccnt","name":"account","type":"text","options":{}},{"id":"sidemail","name":"email","type":"email","options":{}},{"id":"sidvrfat","name":"verified_at","type":"text","options":{}},{"id":"sidvtokn","name":"verification_token","type":"text","options":{}},{"id":"sidstatu","name":"status","type":"text","options":{}}]',
        \\    '[]','{}',NULL,NULL,NULL,NULL,NULL,datetime('now'),datetime('now')),
        \\  ('_suppression__','_suppressions','base',1,
        \\    '[{"id":"supaccnt","name":"account","type":"text","options":{}},{"id":"supemail","name":"email","type":"email","options":{}},{"id":"supreasn","name":"reason","type":"text","options":{}},{"id":"supsourc","name":"source","type":"text","options":{}}]',
        \\    '[]','{}',NULL,NULL,NULL,NULL,NULL,datetime('now'),datetime('now'));
    );
}

fn init_0015_events(m: *Migrator) db.DbError!void {
    // Product analytics event log (#158). A single append-only `_events` table backs
    // `ctx.track` (event capture) and the declarative rollups (scheduled aggregation into
    // `_rollup_<name>` summary tables). It is seeded into `_collections` with system=1 and
    // HARDCODED stable field ids (8-char, matching `provision`'s FNV id width) so a raw-SQL
    // migration can index the human-named physical columns directly and the records engine
    // can address it as a system collection (Locked rules — superuser-only via the records
    // API; tenant reads go through the dedicated `/api/analytics/*` endpoints).
    //
    // `actor`/`actor_collection` identify the principal that emitted the event (resolved
    // SERVER-SIDE by `ctx.track`); `account` is the tenant scope (rctx.account_id, "" when
    // tenancy is disabled or unscoped); `payload` is opaque JSON text (bound param);
    // `occurred_at` is the server-stamped ISO-8601 UTC time the event fired. `updated`
    // mirrors `created` and exists only so the records engine's base-column SELECT
    // (id/created/updated) does not break for a superuser browsing the collection.
    try m.execLowered(
        \\CREATE TABLE IF NOT EXISTS "_events" (
        \\  "id" TEXT PRIMARY KEY, "created" TEXT NOT NULL, "updated" TEXT NOT NULL,
        \\  "name" TEXT NOT NULL DEFAULT '',
        \\  "payload" TEXT NOT NULL DEFAULT '',
        \\  "actor_collection" TEXT NOT NULL DEFAULT '',
        \\  "actor" TEXT NOT NULL DEFAULT '',
        \\  "account" TEXT NOT NULL DEFAULT '',
        \\  "occurred_at" TEXT NOT NULL DEFAULT ''
        \\);
    );
    // The incremental rollup watermark advances over a MONOTONIC insertion-order column. SQLite
    // has the implicit `rowid`; Postgres has none, so add an identity column `_seq` there (the
    // app `id` is a RANDOM base36 string, not monotonic, so it cannot serve). `analytics.seqCol`
    // selects `rowid`/`_seq` per backend. Adding it before any rows exist keeps the migration cheap.
    if (m.dialect.kind == .postgres) {
        try m.db.exec("ALTER TABLE \"_events\" ADD COLUMN IF NOT EXISTS \"_seq\" BIGINT GENERATED ALWAYS AS IDENTITY;");
    }
    // (account,name,occurred_at) serves the per-event-name rollup scan + a name-filtered feed;
    // (account,occurred_at) serves the account-scoped activity feed (newest-first by occurred_at).
    try m.execLowered("CREATE INDEX IF NOT EXISTS \"idx_events_account_name_occurred\" ON \"_events\" (\"account\",\"name\",\"occurred_at\");");
    try m.execLowered("CREATE INDEX IF NOT EXISTS \"idx_events_account_occurred\" ON \"_events\" (\"account\",\"occurred_at\");");

    // Seed the `_collections` row (system=1) so the engine can address `_events` as a
    // collection. Rules are NULL = Locked (superusers only) — members never read raw events
    // through the records API; they use the tenant-scoped `/api/analytics/events` endpoint.
    try m.execLowered(
        \\INSERT OR IGNORE INTO "_collections"
        \\  ("id","name","type","system","schema","indexes","options","listRule","viewRule","createRule","updateRule","deleteRule","created","updated")
        \\ VALUES
        \\  ('_events________','_events','base',1,
        \\    '[{"id":"evtsname","name":"name","type":"text","options":{}},{"id":"evtspayl","name":"payload","type":"json","options":{}},{"id":"evtsacol","name":"actor_collection","type":"text","options":{}},{"id":"evtsactr","name":"actor","type":"text","options":{}},{"id":"evtsacct","name":"account","type":"text","options":{}},{"id":"evtsocat","name":"occurred_at","type":"text","options":{}}]',
        \\    '[]','{}',NULL,NULL,NULL,NULL,NULL,datetime('now'),datetime('now'));
    );
}

pub const all = [_]Migration{
    .{ .name = "0001_init", .up = init_0001 },
    .{ .name = "0002_auth", .up = init_0002 },
    .{ .name = "0003_external_auths", .up = init_0003 },
    .{ .name = "0004_consumed_tokens", .up = init_0004 },
    .{ .name = "0005_oauth_states", .up = init_0005 },
    .{ .name = "0006_cursor_states", .up = init_0006 },
    .{ .name = "0007_auth_challenges", .up = init_0007 },
    .{ .name = "0008_webauthn_credentials", .up = init_0008 },
    .{ .name = "0009_kv", .up = init_0009_kv },
    .{ .name = "0010_token_epoch", .up = init_0010_token_epoch },
    .{ .name = "0011_sessions", .up = init_0011_sessions },
    .{ .name = "0012_experiment_assignments", .up = init_0012_experiment_assignments },
    .{ .name = "0013_queue_jobs", .up = init_0013_queue_jobs },
    .{ .name = "0014_tenancy", .up = init_0014_tenancy },
    .{ .name = "0015_events", .up = init_0015_events },
    .{ .name = "0016_email", .up = init_0016_email },
};

pub fn run(w: *db.Db) db.DbError!void {
    // One-shot startup arena backing the Migrator's SQL lowering; freed when `run` returns.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    // The system migrations never read `io`; it is provided only on the consumer-migration path.
    var m = Migrator{ .db = w, .dialect = db.dbDialect(w), .arena = arena.allocator(), .io = undefined };

    // The `_migrations` ledger: the auto-increment PK keyword diverges per backend (AUTOINCREMENT
    // vs IDENTITY), so it is composed via the dialect rather than lowered textually.
    try m.execf(
        \\CREATE TABLE IF NOT EXISTS "_migrations" (
        \\  "id" {[pk]s}, "name" TEXT UNIQUE NOT NULL, "applied_at" TEXT NOT NULL
        \\);
    , .{ .pk = m.dialect.autoIncPk() });

    for (all) |mig| {
        if (try isApplied(&m, mig.name)) continue;
        try w.begin();
        errdefer w.rollback() catch {};
        try mig.up(&m);
        try recordApplied(&m, mig.name);
        try w.commit();
    }
}

fn isApplied(m: *Migrator, name: []const u8) db.DbError!bool {
    var st = try m.prepare("SELECT 1 FROM \"_migrations\" WHERE \"name\" = ?1;");
    defer st.finalize();
    try st.bindText(1, name);
    return try st.step();
}

fn recordApplied(m: *Migrator, name: []const u8) db.DbError!void {
    const sql = std.fmt.allocPrint(m.arena, "INSERT INTO \"_migrations\" (\"name\", \"applied_at\") VALUES (?1, {s});", .{m.dialect.nowTextExpr()}) catch return error.PrepareFailed;
    var st = try m.prepare(sql);
    defer st.finalize();
    try st.bindText(1, name);
    _ = try st.step();
}

test "migrations apply once and are idempotent" {
    var d = try db.Db.openMemory();
    defer d.close();
    try run(&d);
    try run(&d);
    var st = try d.prepare("SELECT COUNT(*) FROM \"_migrations\";");
    defer st.finalize();
    try std.testing.expect((try st.step()));
    try std.testing.expectEqual(@as(i64, all.len), st.columnInt(0));
    var c = try d.prepare("SELECT COUNT(*) FROM \"_collections\";");
    defer c.finalize();
    try std.testing.expect((try c.step()));
}

test "0002 adds options column and seeds _superusers" {
    var d = try db.Db.openMemory();
    defer d.close();
    try run(&d);
    var st = try d.prepare("SELECT type, system FROM \"_collections\" WHERE name='_superusers';");
    defer st.finalize();
    try std.testing.expect((try st.step()));
    try std.testing.expectEqualStrings("auth", st.columnText(0));
    try std.testing.expectEqual(@as(i64, 1), st.columnInt(1)); // system=1
    // re-running migrations does not duplicate the seed
    try run(&d);
    var dup = try d.prepare("SELECT COUNT(*) FROM \"_collections\" WHERE name='_superusers';");
    defer dup.finalize();
    _ = try dup.step();
    try std.testing.expectEqual(@as(i64, 1), dup.columnInt(0));
    var c = try d.prepare("SELECT COUNT(*) FROM pragma_table_info('_collections') WHERE name='options';");
    defer c.finalize();
    _ = try c.step();
    try std.testing.expectEqual(@as(i64, 1), c.columnInt(0));
}

test "0009 creates _kv settings table with key/value/created/updated columns" {
    var d = try db.Db.openMemory();
    defer d.close();
    try run(&d);
    var t = try d.prepare("SELECT COUNT(*) FROM pragma_table_info('_kv');");
    defer t.finalize();
    _ = try t.step();
    try std.testing.expectEqual(@as(i64, 4), t.columnInt(0));
    // key is the primary key.
    var pk = try d.prepare("SELECT pk FROM pragma_table_info('_kv') WHERE name='key';");
    defer pk.finalize();
    _ = try pk.step();
    try std.testing.expectEqual(@as(i64, 1), pk.columnInt(0));
}

test "0010 adds token_epoch to _superusers (default 0, idempotent)" {
    var d = try db.Db.openMemory();
    defer d.close();
    try run(&d);
    var c = try d.prepare("SELECT COUNT(*) FROM pragma_table_info('_superusers') WHERE name='token_epoch';");
    defer c.finalize();
    _ = try c.step();
    try std.testing.expectEqual(@as(i64, 1), c.columnInt(0));
    // A row inserted without token_epoch reads back as 0 (NOT NULL DEFAULT 0).
    try d.exec("INSERT INTO \"_superusers\" (\"id\",\"created\",\"updated\",\"email\") VALUES ('s1','','','a@b.c');");
    var e = try d.prepare("SELECT token_epoch FROM \"_superusers\" WHERE id='s1';");
    defer e.finalize();
    _ = try e.step();
    try std.testing.expectEqual(@as(i64, 0), e.columnInt(0));
    // Re-running migrations does not fail on the already-present column.
    try run(&d);
}

test "0010 backfills token_epoch onto a pre-existing user auth table" {
    var d = try db.Db.openMemory();
    defer d.close();
    // Simulate an OLD database: the migrations table is current up to 0009 but a user auth
    // collection's physical table predates the token_epoch column.
    try d.exec(
        \\CREATE TABLE "_migrations" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "name" TEXT UNIQUE NOT NULL, "applied_at" TEXT NOT NULL);
    );
    inline for (.{ "0001_init", "0002_auth", "0003_external_auths", "0004_consumed_tokens", "0005_oauth_states", "0006_cursor_states", "0007_auth_challenges", "0008_webauthn_credentials", "0009_kv" }) |name| {
        try d.exec("INSERT INTO \"_migrations\" (\"name\",\"applied_at\") VALUES ('" ++ name ++ "', datetime('now'));");
    }
    // A realistic (full) _collections, as a real DB at 0009 would have from 0001/0002 — so the
    // later 0014 tenancy seed (which INSERTs schema/options/rule columns) applies cleanly.
    try d.exec(
        \\CREATE TABLE "_collections" ("id" TEXT PRIMARY KEY, "name" TEXT UNIQUE NOT NULL, "type" TEXT NOT NULL DEFAULT 'base',
        \\  "system" INTEGER NOT NULL DEFAULT 0, "schema" TEXT NOT NULL DEFAULT '[]', "indexes" TEXT NOT NULL DEFAULT '[]',
        \\  "listRule" TEXT, "viewRule" TEXT, "createRule" TEXT, "updateRule" TEXT, "deleteRule" TEXT,
        \\  "created" TEXT NOT NULL DEFAULT '', "updated" TEXT NOT NULL DEFAULT '', "options" TEXT NOT NULL DEFAULT '{}');
    );
    try d.exec("CREATE TABLE \"_superusers\" (\"id\" TEXT PRIMARY KEY, \"email\" TEXT);");
    try d.exec("INSERT INTO \"_collections\" (\"id\",\"name\",\"type\") VALUES ('c1','members','auth');");
    try d.exec("CREATE TABLE \"members\" (\"id\" TEXT PRIMARY KEY, \"email\" TEXT, \"tokenKey\" TEXT);");
    try d.exec("INSERT INTO \"members\" (\"id\",\"email\",\"tokenKey\") VALUES ('m1','m@x.io','tk');");

    try run(&d); // applies 0010 + 0011

    var c = try d.prepare("SELECT COUNT(*) FROM pragma_table_info('members') WHERE name='token_epoch';");
    defer c.finalize();
    _ = try c.step();
    try std.testing.expectEqual(@as(i64, 1), c.columnInt(0));
    // The pre-existing row gets epoch 0 (data preserved).
    var e = try d.prepare("SELECT token_epoch, tokenKey FROM \"members\" WHERE id='m1';");
    defer e.finalize();
    _ = try e.step();
    try std.testing.expectEqual(@as(i64, 0), e.columnInt(0));
    try std.testing.expectEqualStrings("tk", e.columnText(1));
}

test "0010 backfills a long-named (251+ char) auth table — no fixed-buffer length cap" {
    var d = try db.Db.openMemory();
    defer d.close();
    try d.exec(
        \\CREATE TABLE "_migrations" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "name" TEXT UNIQUE NOT NULL, "applied_at" TEXT NOT NULL);
    );
    inline for (.{ "0001_init", "0002_auth", "0003_external_auths", "0004_consumed_tokens", "0005_oauth_states", "0006_cursor_states", "0007_auth_challenges", "0008_webauthn_credentials", "0009_kv" }) |name| {
        try d.exec("INSERT INTO \"_migrations\" (\"name\",\"applied_at\") VALUES ('" ++ name ++ "', datetime('now'));");
    }
    try d.exec(
        \\CREATE TABLE "_collections" ("id" TEXT PRIMARY KEY, "name" TEXT UNIQUE NOT NULL, "type" TEXT NOT NULL DEFAULT 'base',
        \\  "system" INTEGER NOT NULL DEFAULT 0, "schema" TEXT NOT NULL DEFAULT '[]', "indexes" TEXT NOT NULL DEFAULT '[]',
        \\  "listRule" TEXT, "viewRule" TEXT, "createRule" TEXT, "updateRule" TEXT, "deleteRule" TEXT,
        \\  "created" TEXT NOT NULL DEFAULT '', "updated" TEXT NOT NULL DEFAULT '', "options" TEXT NOT NULL DEFAULT '{}');
    );
    try d.exec("CREATE TABLE \"_superusers\" (\"id\" TEXT PRIMARY KEY, \"email\" TEXT);");
    // A valid identifier of 260 chars (alpha-first, alnum) — passes schema.isValidIdentifier
    // (no length cap), so it must also be migrated. The old [320]u8/len<=250 guard skipped it.
    const long_name = "a" ++ ("b" ** 259);
    try std.testing.expectEqual(@as(usize, 260), long_name.len);
    try d.exec("INSERT INTO \"_collections\" (\"id\",\"name\",\"type\") VALUES ('c1','" ++ long_name ++ "','auth');");
    try d.exec("CREATE TABLE \"" ++ long_name ++ "\" (\"id\" TEXT PRIMARY KEY, \"tokenKey\" TEXT);");

    try run(&d); // applies 0010 + 0011

    var c = try d.prepare("SELECT COUNT(*) FROM pragma_table_info('" ++ long_name ++ "') WHERE name='token_epoch';");
    defer c.finalize();
    _ = try c.step();
    try std.testing.expectEqual(@as(i64, 1), c.columnInt(0)); // column present -> auth won't break
}

test "0011 creates the _sessions store with its indexes" {
    var d = try db.Db.openMemory();
    defer d.close();
    try run(&d);
    var t = try d.prepare("SELECT COUNT(*) FROM pragma_table_info('_sessions');");
    defer t.finalize();
    _ = try t.step();
    try std.testing.expectEqual(@as(i64, 8), t.columnInt(0));
    var idx = try d.prepare("SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name IN ('idx_sessions_owner','idx_sessions_expires');");
    defer idx.finalize();
    _ = try idx.step();
    try std.testing.expectEqual(@as(i64, 2), idx.columnInt(0));
    // expires is nullable (NULL = no expiry); a row may omit it.
    try d.exec("INSERT INTO \"_sessions\" (\"id\",\"collectionRef\",\"recordRef\",\"created\") VALUES ('s1','users','u1',datetime('now'));");
    var e = try d.prepare("SELECT expires FROM \"_sessions\" WHERE id='s1';");
    defer e.finalize();
    _ = try e.step();
    try std.testing.expect(e.isNull(0));
}

test "0013 creates the _queue_jobs table with its indexes" {
    var d = try db.Db.openMemory();
    defer d.close();
    try run(&d);
    var t = try d.prepare("SELECT COUNT(*) FROM pragma_table_info('_queue_jobs');");
    defer t.finalize();
    _ = try t.step();
    try std.testing.expectEqual(@as(i64, 13), t.columnInt(0));
    var idx = try d.prepare("SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name IN ('idx_queue_jobs_ready','idx_queue_jobs_created');");
    defer idx.finalize();
    _ = try idx.step();
    try std.testing.expectEqual(@as(i64, 2), idx.columnInt(0));
    // claimed_at is nullable (NULL = unclaimed); a fresh row omits it.
    try d.exec("INSERT INTO \"_queue_jobs\" (\"id\",\"queue\",\"kind\",\"max_attempts\",\"created\") VALUES ('j1','default','mail',5,datetime('now'));");
    var e = try d.prepare("SELECT claimed_at, status, attempts FROM \"_queue_jobs\" WHERE id='j1';");
    defer e.finalize();
    _ = try e.step();
    try std.testing.expect(e.isNull(0));
    try std.testing.expectEqualStrings("pending", e.columnText(1));
    try std.testing.expectEqual(@as(i64, 0), e.columnInt(2));
}

test "0014 creates the tenancy tables, indexes, uniqueness, and seeds _collections" {
    var d = try db.Db.openMemory();
    defer d.close();
    try run(&d);

    // Tables exist with the expected column counts (id/created/updated + the named fields).
    inline for (.{
        .{ "_accounts", @as(i64, 7) }, // id,created,updated,name,slug,owner_user,status
        .{ "_memberships", @as(i64, 8) }, // id,created,updated,account,user_collection,user,role,status
        .{ "_invitations", @as(i64, 10) }, // id,created,updated,account,email,role,token,invited_by,expires,accepted_at
    }) |spec| {
        var t = try d.prepare("SELECT COUNT(*) FROM pragma_table_info('" ++ spec[0] ++ "');");
        defer t.finalize();
        _ = try t.step();
        try std.testing.expectEqual(spec[1], t.columnInt(0));
    }

    // Indexes present.
    var idx = try d.prepare("SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name IN " ++
        "('idx_accounts_slug','idx_memberships_unique','idx_memberships_user','idx_memberships_account','idx_invitations_token','idx_invitations_account');");
    defer idx.finalize();
    _ = try idx.step();
    try std.testing.expectEqual(@as(i64, 6), idx.columnInt(0));

    // Seeded into _collections as system collections.
    var c = try d.prepare("SELECT COUNT(*) FROM \"_collections\" WHERE name IN ('_accounts','_memberships','_invitations') AND system=1;");
    defer c.finalize();
    _ = try c.step();
    try std.testing.expectEqual(@as(i64, 3), c.columnInt(0));

    // slug uniqueness on _accounts.
    try d.exec("INSERT INTO \"_accounts\" (\"id\",\"created\",\"updated\",\"slug\") VALUES ('a1','','','acme');");
    try std.testing.expectError(error.ExecFailed, d.exec("INSERT INTO \"_accounts\" (\"id\",\"created\",\"updated\",\"slug\") VALUES ('a2','','','acme');"));

    // composite (account,user_collection,user) uniqueness on _memberships.
    try d.exec("INSERT INTO \"_memberships\" (\"id\",\"created\",\"updated\",\"account\",\"user_collection\",\"user\",\"role\",\"status\") VALUES ('m1','','','a1','users','u1','owner','active');");
    try std.testing.expectError(error.ExecFailed, d.exec("INSERT INTO \"_memberships\" (\"id\",\"created\",\"updated\",\"account\",\"user_collection\",\"user\",\"role\",\"status\") VALUES ('m2','','','a1','users','u1','viewer','active');"));
    // same user, different account is fine.
    try d.exec("INSERT INTO \"_memberships\" (\"id\",\"created\",\"updated\",\"account\",\"user_collection\",\"user\",\"role\",\"status\") VALUES ('m3','','','a-other','users','u1','viewer','active');");

    // token uniqueness on _invitations.
    try d.exec("INSERT INTO \"_invitations\" (\"id\",\"created\",\"updated\",\"account\",\"token\") VALUES ('i1','','','a1','tok-1');");
    try std.testing.expectError(error.ExecFailed, d.exec("INSERT INTO \"_invitations\" (\"id\",\"created\",\"updated\",\"account\",\"token\") VALUES ('i2','','','a1','tok-1');"));

    // Re-running migrations does not duplicate the seeded collection rows.
    try run(&d);
    var dup = try d.prepare("SELECT COUNT(*) FROM \"_collections\" WHERE name='_accounts';");
    defer dup.finalize();
    _ = try dup.step();
    try std.testing.expectEqual(@as(i64, 1), dup.columnInt(0));
}

test "0016 creates email tables, uniqueness, and seeds _collections" {
    var d = try db.Db.openMemory();
    defer d.close();
    try run(&d);

    // Tables exist with the expected column counts.
    inline for (.{
        .{ "_sender_identities", @as(i64, 8) }, // id,created,updated,account,email,verified_at,verification_token,status
        .{ "_suppressions", @as(i64, 6) }, // id,created,account,email,reason,source
    }) |spec| {
        var t = try d.prepare("SELECT COUNT(*) FROM pragma_table_info('" ++ spec[0] ++ "');");
        defer t.finalize();
        _ = try t.step();
        try std.testing.expectEqual(spec[1], t.columnInt(0));
    }

    // Indexes present.
    var idx = try d.prepare("SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name IN " ++
        "('idx_sender_identities_unique','idx_sender_identities_token','idx_suppressions_unique','idx_suppressions_email');");
    defer idx.finalize();
    _ = try idx.step();
    try std.testing.expectEqual(@as(i64, 4), idx.columnInt(0));

    // Seeded into _collections as system collections.
    var c = try d.prepare("SELECT COUNT(*) FROM \"_collections\" WHERE name IN ('_sender_identities','_suppressions') AND system=1;");
    defer c.finalize();
    _ = try c.step();
    try std.testing.expectEqual(@as(i64, 2), c.columnInt(0));

    // UNIQUE(account,email) on _sender_identities.
    try d.exec("INSERT INTO \"_sender_identities\" (\"id\",\"created\",\"updated\",\"account\",\"email\") VALUES ('s1','','','a1','from@x.io');");
    try std.testing.expectError(error.ExecFailed, d.exec("INSERT INTO \"_sender_identities\" (\"id\",\"created\",\"updated\",\"account\",\"email\") VALUES ('s2','','','a1','from@x.io');"));
    // Same email, different account is fine.
    try d.exec("INSERT INTO \"_sender_identities\" (\"id\",\"created\",\"updated\",\"account\",\"email\") VALUES ('s3','','','a2','from@x.io');");

    // UNIQUE(account,email) on _suppressions.
    try d.exec("INSERT INTO \"_suppressions\" (\"id\",\"created\",\"account\",\"email\",\"reason\") VALUES ('p1','','a1','bad@x.io','hard_bounce');");
    try std.testing.expectError(error.ExecFailed, d.exec("INSERT INTO \"_suppressions\" (\"id\",\"created\",\"account\",\"email\",\"reason\") VALUES ('p2','','a1','bad@x.io','complaint');"));

    // Re-running migrations does not duplicate the seeded collection rows.
    try run(&d);
    var dup = try d.prepare("SELECT COUNT(*) FROM \"_collections\" WHERE name='_sender_identities';");
    defer dup.finalize();
    _ = try dup.step();
    try std.testing.expectEqual(@as(i64, 1), dup.columnInt(0));
}

test "0015 creates the _events table, indexes, and seeds the _events collection" {
    var d = try db.Db.openMemory();
    defer d.close();
    try run(&d);

    // Table exists with id/created/updated + the 6 analytics columns (9 total).
    var t = try d.prepare("SELECT COUNT(*) FROM pragma_table_info('_events');");
    defer t.finalize();
    _ = try t.step();
    try std.testing.expectEqual(@as(i64, 9), t.columnInt(0));

    // Both scan indexes present.
    var idx = try d.prepare("SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name IN ('idx_events_account_name_occurred','idx_events_account_occurred');");
    defer idx.finalize();
    _ = try idx.step();
    try std.testing.expectEqual(@as(i64, 2), idx.columnInt(0));

    // Seeded into _collections as a system collection with Locked (NULL) rules.
    var c = try d.prepare("SELECT system, listRule FROM \"_collections\" WHERE name='_events';");
    defer c.finalize();
    try std.testing.expect((try c.step()));
    try std.testing.expectEqual(@as(i64, 1), c.columnInt(0));
    try std.testing.expect(c.isNull(1)); // listRule NULL = Locked (superusers only)

    // A row can be inserted (append-only event capture).
    try d.exec("INSERT INTO \"_events\" (\"id\",\"created\",\"updated\",\"name\",\"payload\",\"account\",\"occurred_at\") VALUES ('e1','t','t','user.signup','{}','acc1','2026-01-01T00:00:00Z');");

    // Re-running migrations does not duplicate the seeded collection row.
    try run(&d);
    var dup = try d.prepare("SELECT COUNT(*) FROM \"_collections\" WHERE name='_events';");
    defer dup.finalize();
    _ = try dup.step();
    try std.testing.expectEqual(@as(i64, 1), dup.columnInt(0));
}

test "0003 creates _externalAuths with unique provider/providerId and per-record indexes" {
    var d = try db.Db.openMemory();
    defer d.close();
    try run(&d);
    var t = try d.prepare("SELECT COUNT(*) FROM pragma_table_info('_externalAuths');");
    defer t.finalize();
    _ = try t.step();
    try std.testing.expect(t.columnInt(0) >= 7);
    try d.exec("INSERT INTO \"_externalAuths\" (\"id\",\"collectionRef\",\"recordRef\",\"provider\",\"providerId\",\"created\",\"updated\") VALUES ('e1','users','r1','google','G1','','');");
    try std.testing.expectError(error.ExecFailed, d.exec("INSERT INTO \"_externalAuths\" (\"id\",\"collectionRef\",\"recordRef\",\"provider\",\"providerId\",\"created\",\"updated\") VALUES ('e2','users','r2','google','G1','','');"));
    try d.exec("INSERT INTO \"_externalAuths\" (\"id\",\"collectionRef\",\"recordRef\",\"provider\",\"providerId\",\"created\",\"updated\") VALUES ('e3','users','r1','github','H1','','');");
    try std.testing.expectError(error.ExecFailed, d.exec("INSERT INTO \"_externalAuths\" (\"id\",\"collectionRef\",\"recordRef\",\"provider\",\"providerId\",\"created\",\"updated\") VALUES ('e4','users','r1','github','H2','','');"));
}
