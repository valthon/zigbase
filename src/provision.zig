//! Comptime collection definitions + startup provisioning.
//!
//! Developers describe their schema IN ZIG at comptime via `Schema(.{ ... })`,
//! and ZigBase provisions it at startup: creating not-yet-existing collections,
//! resolving relation targets BY NAME, and applying safe ADDITIVE auto-migration
//! (new columns). Destructive changes (type change / column drop) are detected,
//! logged, and SKIPPED — never silently applied. An explicit-migration escape
//! hatch (`.migrations`) covers the rest.
//!
//! The comptime `.collections` literal is lowered to a `[]const schema.Collection`
//! by `buildCollections`, validated where possible at comptime via `@compileError`
//! (unknown field type, bad option, missing relation target name). The runtime
//! provisioner (`applySchema`) then diffs each spec against the live `_collections`
//! and applies the minimal safe change set. Running it twice is a clean no-op.

const std = @import("std");
const schema = @import("schema.zig");
const collections = @import("collections.zig");
const db = @import("db.zig");
const ddl = @import("ddl.zig");
const schema_gen = @import("schema_gen.zig");
const rules = @import("rules.zig");
const regex = @import("regex.zig");
const datetime = @import("datetime.zig");
const secrets = @import("oauth/secrets.zig");
const discovery = @import("oauth/discovery.zig");
const oauth_client = @import("oauth/client.zig");
const fts = @import("search/fts.zig");
const vector = @import("search/vector.zig");
const Migrator = @import("migrator.zig").Migrator;

/// F3 startup lint: log a prominent warning for every `@public` (allow-all) rule on `col`, so a
/// wide-open collection is never silent. Called once per collection during provisioning.
fn warnPublicRules(col: schema.Collection) void {
    const Pair = struct { op: []const u8, rule: ?[]const u8 };
    const pairs = [_]Pair{
        .{ .op = "list", .rule = col.listRule },
        .{ .op = "view", .rule = col.viewRule },
        .{ .op = "create", .rule = col.createRule },
        .{ .op = "update", .rule = col.updateRule },
        .{ .op = "delete", .rule = col.deleteRule },
    };
    for (pairs) |p| {
        if (rules.isPublic(p.rule)) {
            std.log.warn(
                "collection '{s}' is PUBLIC for {s} (anyone can {s}) — @public rule",
                .{ col.name, p.op, p.op },
            );
        }
    }
}

/// Tenancy startup lint (#156): log that a collection is account-scoped (tenant-owned), mirroring
/// the `@public` warning so a collection whose visibility is silently narrowed to the active
/// account is never a surprise. Called once per collection during provisioning.
fn warnTenantOwned(col: schema.Collection) void {
    if (col.options.tenant_field) |tf| {
        std.log.warn(
            "collection '{s}' is TENANT-OWNED (auto-scoped to the active account via field '{s}') — #156 tenancy",
            .{ col.name, tf },
        );
    }
}

/// Auto-create the index backing the `tenant_field` column so the per-request tenant scope
/// predicate (`"<col>"."<tenant_field>" = ?`) is served from an index, not a scan. Idempotent
/// (`IF NOT EXISTS`); identifiers are gated through `schema.isValidIdentifier` before interpolation.
fn ensureTenantIndex(alloc: std.mem.Allocator, w: *db.Db, col: schema.Collection) ProvisionError!void {
    const tf = col.options.tenant_field orelse return;
    if (!schema.isValidIdentifier(col.name) or !schema.isValidIdentifier(tf)) return;
    // Bound + freed rather than nested inside the allocPrint: `alloc` here is the caller's
    // allocator, not an arena (the `sql` free below says so), so a nested temporary would leak.
    const qidx = try ddl.quoteComposite(alloc, "idx_{s}_{s}_tenant", .{ col.name, tf });
    defer alloc.free(qidx);
    const qtbl = try ddl.quoteIdent(alloc, col.name);
    defer alloc.free(qtbl);
    const qtf = try ddl.quoteIdent(alloc, tf);
    defer alloc.free(qtf);
    const sql = try std.fmt.allocPrintSentinel(
        alloc,
        "CREATE INDEX IF NOT EXISTS {s} ON {s} ({s});",
        .{ qidx, qtbl, qtf },
        0,
    );
    defer alloc.free(sql);
    try w.exec(sql);
    std.log.info("provision: ensured tenant index on '{s}'.'{s}'", .{ col.name, tf });
}

/// Wrap `fts.ensureIndex`: on SQLite, a build compiled with `-Dfts5=false` cannot serve a
/// `.searchable` schema. Rather than let that surface as a silent no-op (and a later `?search=`
/// 500), fail LOUDLY at startup with an actionable message — the fail-fast-at-boot principle
/// (better a clear boot error than a runtime surprise). Postgres is never affected (the flag
/// doesn't gate `ensureIndexPg`).
fn ensureSearchIndex(alloc: std.mem.Allocator, w: *db.Db, spec: schema.Collection) ProvisionError!void {
    fts.ensureIndex(alloc, w, spec) catch |err| switch (err) {
        error.SearchDisabled => {
            std.log.err(
                "refusing to start: collection '{s}' declares .searchable fields but this binary was built with -Dfts5=false — rebuild with -Dfts5 (or its default) to enable full-text search",
                .{spec.name},
            );
            return error.FtsDisabled;
        },
        // `err`'s static type is fts.EnsureIndexError (includes SearchDisabled, handled above);
        // every OTHER member is genuinely a ProvisionError member, so this narrowing cast is safe.
        else => return @errorCast(err),
    };
}

// ---------------------------------------------------------------------------
// Comptime builder: a `.collections` literal -> []const schema.Collection
// ---------------------------------------------------------------------------

/// A comptime relation field stores its target collection BY NAME in
/// `targetCollectionId`. `applySchema` resolves the name -> the target
/// collection's id at provisioning time (after the target exists).
///
/// `buildCollections` accepts a comptime struct literal of the shape:
///
///     .{
///         .users = .{ .type = .auth, .fields = .{
///             .{ .name = "display_name", .type = .text },
///         }, .rules = .{ .list = "", .view = "" } },
///         .listings = .{ .fields = .{
///             .{ .name = "title", .type = .text, .required = true },
///             .{ .name = "price", .type = .number, .mode = .fixed, .scale = 2 },
///             .{ .name = "owner", .type = .relation, .target = "users" },
///             .{ .name = "status", .type = .select, .values = .{ "draft", "published" } },
///         }, .rules = .{ .list = "status = \"published\"" } },
///     }
///
/// Each top-level field name is a collection name; its value carries
/// `.type` (default `.base`), `.fields` (a tuple of field literals), and an
/// optional `.rules = .{ .list, .view, .create, .update, .delete }`.
pub fn buildCollections(comptime cfg: anytype) []const schema.Collection {
    comptime {
        // Lowering walks every collection, field, validation, and FNV id hash at
        // comptime; a realistic multi-collection schema exceeds Zig's default
        // 1000 backward-branch budget. Raise it here — a downstream consumer
        // cannot: @setEvalBranchQuota in their code does not propagate into this
        // lazily-evaluated framework decl. Scaled generously to fit large schemas.
        @setEvalBranchQuota(1_000_000);
        const Cfg = @TypeOf(cfg);
        const info = @typeInfo(Cfg);
        if (info != .@"struct") @compileError("collections config must be a struct literal");
        const cols_fields = info.@"struct".fields;
        var out: [cols_fields.len]schema.Collection = undefined;
        for (cols_fields, 0..) |cf, ci| {
            out[ci] = buildCollection(cf.name, @field(cfg, cf.name));
        }
        const frozen = out;
        return &frozen;
    }
}

/// Comma-joined `.key` list for a friendly @compileError message.
fn keyList(comptime allowed: []const []const u8) []const u8 {
    comptime {
        var msg: []const u8 = "";
        for (allowed, 0..) |a, i| msg = msg ++ (if (i == 0) "" else ", ") ++ "." ++ a;
        return msg;
    }
}

/// Fail loud on a typo'd key. For each declared field of the struct literal `spec`,
/// `@compileError` if its name is not in `allowed`. Mirrors the unknown-key gates in
/// `events.validateHooks` / `events.validateRouteSpecs`: a misspelled option (e.g.
/// `.requied`, `.ttl_filed`, `.viewRul`) would otherwise be SILENTLY IGNORED because the
/// builders read keys via `@hasField`. `what` describes the spec for the message.
/// Non-struct specs are left to the existing shape checks (which produce their own error).
fn rejectUnknownKeys(comptime spec: anytype, comptime allowed: []const []const u8, comptime what: []const u8) void {
    comptime {
        const info = @typeInfo(@TypeOf(spec));
        if (info != .@"struct") return;
        for (info.@"struct".fields) |fld| {
            var ok = false;
            for (allowed) |a| {
                if (std.mem.eql(u8, fld.name, a)) {
                    ok = true;
                    break;
                }
            }
            if (!ok)
                @compileError(what ++ ": unknown key '." ++ fld.name ++ "' (recognized keys: " ++ keyList(allowed) ++ ")");
        }
    }
}

/// Field keys read by `buildOptions` for a given field type, on top of the common
/// keys handled in `buildField` (name/type/required/unique/hidden/encrypted/searchable). Kept in
/// lock-step with the `switch (ftype)` in `buildOptions` — a key read there must appear
/// here or a valid spec would falsely @compileError.
fn fieldOptionKeys(comptime ftype: schema.FieldType) []const []const u8 {
    return switch (ftype) {
        .text => &.{ "min", "max", "pattern" },
        .email => &.{},
        .url => &.{},
        .editor => &.{},
        .date => &.{ "min", "max" },
        .autodate => &.{ "onCreate", "onUpdate" },
        .bool => &.{},
        .number => &.{ "mode", "scale", "min", "max" },
        .json => &.{"maxSize"},
        .select => &.{ "values", "maxSelect" },
        .relation => &.{ "target", "cascadeDelete", "minSelect", "maxSelect" },
        .file => &.{ "maxSelect", "maxSize", "mimeTypes" },
    };
}

/// Field-key gate: a field literal's allowed keys are the common ones (read in
/// `buildField`) plus the per-type option keys (`fieldOptionKeys`). Split out from
/// `rejectUnknownKeys` because the allowed set is two parts and varies by field type.
fn rejectUnknownFieldKeys(comptime f: anytype, comptime ftype: schema.FieldType, comptime where: []const u8) void {
    comptime {
        const info = @typeInfo(@TypeOf(f));
        if (info != .@"struct") return;
        const common = [_][]const u8{ "name", "type", "required", "unique", "hidden", "encrypted", "searchable" };
        const opt = fieldOptionKeys(ftype);
        for (info.@"struct".fields) |fld| {
            var ok = false;
            for (common) |a| {
                if (std.mem.eql(u8, fld.name, a)) ok = true;
            }
            if (!ok) for (opt) |a| {
                if (std.mem.eql(u8, fld.name, a)) ok = true;
            };
            if (!ok) {
                const opt_msg = if (opt.len == 0) "" else " (+ for type ." ++ @tagName(ftype) ++ ": " ++ keyList(opt) ++ ")";
                @compileError(where ++ ": unknown key '." ++ fld.name ++ "' (recognized keys: " ++ keyList(&common) ++ opt_msg ++ ")");
            }
        }
    }
}

fn buildCollection(comptime name: []const u8, comptime spec: anytype) schema.Collection {
    comptime {
        if (!schema.isValidIdentifier(name))
            @compileError("collection name '" ++ name ++ "' must be a valid identifier (letter, then letters/digits/underscore)");
        const S = @TypeOf(spec);
        const sinfo = @typeInfo(S);
        if (sinfo != .@"struct") @compileError("collection '" ++ name ++ "' must be a struct literal");
        // Fail loud on an unknown collection-level key (a typo would otherwise be a silent
        // no-op). These are exactly the keys read below in this function.
        rejectUnknownKeys(spec, &.{ "type", "fields", "rules", "auth", "indexes", "ttl_field", "tenant_field" }, "collection '" ++ name ++ "'");

        // collection type (default .base)
        const ctype: schema.CollectionType = if (@hasField(S, "type")) spec.type else .base;

        // fields
        const ftuple = if (@hasField(S, "fields")) spec.fields else .{};
        const FT = @TypeOf(ftuple);
        const ftinfo = @typeInfo(FT);
        if (ftinfo != .@"struct") @compileError("collection '" ++ name ++ "' .fields must be a tuple of field literals");
        const ff = ftinfo.@"struct".fields;
        var fields: [ff.len]schema.Field = undefined;
        for (ff, 0..) |f, i| {
            fields[i] = buildField(name, @field(ftuple, f.name));
        }
        const frozen_fields = fields;

        // rules
        var col = schema.Collection{
            .id = "",
            .name = name,
            .type = ctype,
            .fields = &frozen_fields,
        };
        if (@hasField(S, "rules")) {
            rejectUnknownKeys(spec.rules, &.{ "list", "view", "create", "update", "delete" }, "collection '" ++ name ++ "' .rules");
            const R = @TypeOf(spec.rules);
            if (@hasField(R, "list")) col.listRule = spec.rules.list;
            if (@hasField(R, "view")) col.viewRule = spec.rules.view;
            if (@hasField(R, "create")) col.createRule = spec.rules.create;
            if (@hasField(R, "update")) col.updateRule = spec.rules.update;
            if (@hasField(R, "delete")) col.deleteRule = spec.rules.delete;
        }
        // auth-specific collection options
        if (@hasField(S, "auth")) {
            rejectUnknownKeys(spec.auth, &.{ "methods", "require_verified", "oauth2", "two_factor" }, "collection '" ++ name ++ "' .auth");
            const A = @TypeOf(spec.auth);
            if (@hasField(A, "two_factor")) col.options.auth.two_factor = spec.auth.two_factor;
            if (@hasField(A, "methods")) {
                col.options.auth.methods = buildMethodsOptions("collection '" ++ name ++ "' .auth.methods", spec.auth.methods);
            }
            if (@hasField(A, "require_verified")) {
                col.options.auth.require_verified = spec.auth.require_verified;
            }
            if (@hasField(A, "oauth2")) {
                col.options.auth.oauth2 = buildOAuth2Options("collection '" ++ name ++ "' .auth.oauth2", spec.auth.oauth2);
            }
        }
        if (@hasField(S, "indexes")) col.indexes = buildIndexes(name, spec.indexes);
        // TTL: `.ttl_field` names an existing date/autodate field as the row's expiry
        // timestamp (a framework-internal GC reaps expired rows). Validate at comptime:
        // the field must exist and be a date/autodate (so it holds an ISO-8601 instant).
        // The GC normalizes both sides via SQLite `strftime('%Y-%m-%dT%H:%M:%SZ', ...)`
        // before comparing, so non-canonical `.date` values (timezone offsets, space
        // separator, date-only) are handled correctly.
        if (@hasField(S, "ttl_field")) {
            const tf: []const u8 = spec.ttl_field;
            var matched: ?schema.FieldType = null;
            for (frozen_fields) |f| {
                if (std.mem.eql(u8, f.name, tf)) {
                    matched = f.fieldType();
                    break;
                }
            }
            if (matched == null)
                @compileError("collection '" ++ name ++ "': .ttl_field '" ++ tf ++ "' must name an existing date/autodate field, but no such field exists");
            if (matched.? != .date and matched.? != .autodate)
                @compileError("collection '" ++ name ++ "': .ttl_field '" ++ tf ++ "' must name a date/autodate field (got ." ++ @tagName(matched.?) ++ ")");
            col.options.ttl_field = tf;
        }

        // Tenancy: `.tenant_field` names the field whose column holds the owning account id for
        // account-scoped multi-tenancy (#156). Validate at comptime that the field EXISTS and is
        // TEXT-storage — an account id is always text, bound as a text param and compared as text,
        // so a `number`/`bool` tenant_field would fail closed silently at runtime. The runtime
        // auto-scopes every read/write of this collection to the request's active account.
        if (@hasField(S, "tenant_field")) {
            const tf: []const u8 = spec.tenant_field;
            var matched: ?schema.Field = null;
            for (frozen_fields) |f| {
                if (std.mem.eql(u8, f.name, tf)) {
                    matched = f;
                    break;
                }
            }
            if (matched == null)
                @compileError("collection '" ++ name ++ "': .tenant_field '" ++ tf ++ "' must name an existing field, but no such field exists");
            if (matched.?.storageClass() != .text)
                @compileError("collection '" ++ name ++ "': .tenant_field '" ++ tf ++ "' must name a TEXT-storage field (it holds an account id), but '" ++ tf ++ "' is ." ++ @tagName(matched.?.fieldType()));
            col.options.tenant_field = tf;
        }

        // An encrypted field cannot be indexed (the index would be built over
        // per-row-nonce ciphertext and could never satisfy a lookup). Reject at
        // compile time once both the field list and indexes are known.
        for (col.indexes) |ix| {
            for (ix.fields) |ixf| {
                for (col.fields) |fld| {
                    if (std.mem.eql(u8, fld.name, ixf) and fld.encrypted)
                        @compileError("collection '" ++ name ++ "': index '" ++ ix.name ++ "' references encrypted field '" ++ ixf ++ "' — encrypted fields cannot be indexed");
                }
            }
        }
        return col;
    }
}

/// `.rate_limit` lowering now lives in `schema.buildRateLimitOpt` (shared with the
/// per-route guard pipeline in `events.buildRoutes`). Kept as a thin local alias so the
/// existing call sites below read unchanged.
const buildRateLimitOpt = schema.buildRateLimitOpt;

fn buildMethodsOptions(comptime what: []const u8, comptime m: anytype) schema.MethodsOptions {
    const M = @TypeOf(m);
    // Fail loud on a typo'd method name (e.g. `.magiclink`) — an unknown key would otherwise
    // be silently dropped and the method left unconfigured, mirroring the collection/field gates.
    rejectUnknownKeys(m, &.{ "password", "magic_link", "otp", "webauthn", "custom" }, what);
    var out = schema.MethodsOptions{};
    // Each optional built-in method field in the comptime literal is an anonymous
    // struct (not a typed optional), so we use @hasField to detect presence and
    // treat it as "enabled with those settings".
    if (@hasField(M, "password")) {
        const pw = m.password;
        rejectUnknownKeys(pw, &.{"rate_limit"}, what ++ ".password");
        var p = schema.PasswordMethodOpts{};
        if (@hasField(@TypeOf(pw), "rate_limit")) p.rate_limit = buildRateLimitOpt(pw.rate_limit);
        out.password = p;
    }
    if (@hasField(M, "magic_link")) {
        const ml = m.magic_link;
        rejectUnknownKeys(ml, &.{ "ttl_s", "auto_create", "rate_limit", "redirect_default", "redirect_allow" }, what ++ ".magic_link");
        var p = schema.MagicLinkMethodOpts{};
        if (@hasField(@TypeOf(ml), "ttl_s")) p.ttl_s = ml.ttl_s;
        if (@hasField(@TypeOf(ml), "auto_create")) p.auto_create = ml.auto_create;
        if (@hasField(@TypeOf(ml), "rate_limit")) p.rate_limit = buildRateLimitOpt(ml.rate_limit);
        if (@hasField(@TypeOf(ml), "redirect_default")) p.redirect_default = ml.redirect_default;
        if (@hasField(@TypeOf(ml), "redirect_allow")) p.redirect_allow = strTupleToSlice(ml.redirect_allow);
        out.magic_link = p;
    }
    if (@hasField(M, "otp")) {
        const otp = m.otp;
        rejectUnknownKeys(otp, &.{ "length", "ttl_s", "auto_create", "rate_limit" }, what ++ ".otp");
        var p = schema.OtpMethodOpts{};
        if (@hasField(@TypeOf(otp), "length")) p.length = otp.length;
        if (@hasField(@TypeOf(otp), "ttl_s")) p.ttl_s = otp.ttl_s;
        if (@hasField(@TypeOf(otp), "auto_create")) p.auto_create = otp.auto_create;
        if (@hasField(@TypeOf(otp), "rate_limit")) p.rate_limit = buildRateLimitOpt(otp.rate_limit);
        out.otp = p;
    }
    if (@hasField(M, "webauthn")) {
        const wa = m.webauthn;
        rejectUnknownKeys(wa, &.{ "rp_id", "rp_name", "origin", "credentials_collection", "require_uv", "rate_limit" }, what ++ ".webauthn");
        var p = schema.WebAuthnMethodOpts{};
        if (@hasField(@TypeOf(wa), "rp_id")) p.rp_id = wa.rp_id;
        if (@hasField(@TypeOf(wa), "rp_name")) p.rp_name = wa.rp_name;
        if (@hasField(@TypeOf(wa), "origin")) p.origin = wa.origin;
        if (@hasField(@TypeOf(wa), "credentials_collection")) p.credentials_collection = wa.credentials_collection;
        if (@hasField(@TypeOf(wa), "require_uv")) p.require_uv = wa.require_uv;
        if (@hasField(@TypeOf(wa), "rate_limit")) p.rate_limit = buildRateLimitOpt(wa.rate_limit);
        out.webauthn = p;
    }
    if (@hasField(M, "custom")) out.custom = customSlugsToSlice(m.custom);
    return out;
}

fn buildOAuth2Options(comptime what: []const u8, comptime o: anytype) schema.OAuth2Options {
    comptime {
        const O = @TypeOf(o);
        // Fail loud on a typo'd `.oauth2` key so it isn't silently dropped.
        rejectUnknownKeys(o, &.{ "enabled", "providers" }, what);
        var out = schema.OAuth2Options{};
        if (@hasField(O, "enabled")) out.enabled = o.enabled;
        if (@hasField(O, "providers")) {
            const pt = o.providers;
            const PT = @TypeOf(pt);
            const pinfo = @typeInfo(PT);
            if (pinfo != .@"struct")
                @compileError(".auth.oauth2.providers must be a tuple of provider literals");
            const pf = pinfo.@"struct".fields;
            var provs: [pf.len]schema.OAuth2Provider = undefined;
            for (pf, 0..) |pff, i| {
                provs[i] = buildOAuth2Provider(@field(pt, pff.name));
            }
            const frozen = provs;
            out.providers = &frozen;
        }
        return out;
    }
}

/// Lower a single comptime provider literal into a `schema.OAuth2Provider`.
/// - `.name` is REQUIRED; must be a valid identifier (uppercased into env var name).
/// - `.clientId`/`.clientSecret` are accepted but discouraged (they bake values into
///   the binary); env always wins at provision time (`injectOAuthSecrets`).
/// - Negative (compile-error) cases: missing `.name`, or a `.name` that fails
///   `schema.isValidIdentifier`, produce a `@compileError`.
fn buildOAuth2Provider(comptime p: anytype) schema.OAuth2Provider {
    comptime {
        const P = @TypeOf(p);
        if (!@hasField(P, "name"))
            @compileError(".auth.oauth2 provider is missing .name");
        const pname: []const u8 = p.name;
        // Fail loud on a typo'd provider key (e.g. `.tokenUrl` for `.tokenURL`) — an unknown
        // key would otherwise be dropped, leaving the endpoint null and every login failing at
        // runtime instead of at build time.
        rejectUnknownKeys(p, &.{ "name", "clientId", "clientSecret", "enabled", "redirectUrls", "authURL", "tokenURL", "userinfoURL", "scopes", "discoveryURL" }, "oauth2 provider '" ++ pname ++ "'");
        if (!schema.isValidIdentifier(pname))
            @compileError("oauth2 provider name '" ++ pname ++ "' must be a valid identifier (it is used as a slug and uppercased into an env var name)");
        var out = schema.OAuth2Provider{ .name = pname };
        if (@hasField(P, "clientId")) out.clientId = p.clientId;
        if (@hasField(P, "clientSecret")) out.clientSecret = p.clientSecret;
        if (@hasField(P, "enabled")) out.enabled = p.enabled;
        if (@hasField(P, "redirectUrls")) out.redirectUrls = strTupleToSlice(p.redirectUrls);
        if (@hasField(P, "authURL")) out.authURL = p.authURL;
        if (@hasField(P, "tokenURL")) out.tokenURL = p.tokenURL;
        if (@hasField(P, "userinfoURL")) out.userinfoURL = p.userinfoURL;
        if (@hasField(P, "scopes")) out.scopes = strTupleToSlice(p.scopes);
        if (@hasField(P, "discoveryURL")) {
            if (@hasField(P, "authURL") or @hasField(P, "tokenURL") or @hasField(P, "userinfoURL"))
                @compileError("oauth2 provider '" ++ pname ++ "': .discoveryURL is mutually exclusive with explicit .authURL/.tokenURL/.userinfoURL");
            const durl: []const u8 = p.discoveryURL;
            if (!(durl.len > "https://".len and std.mem.startsWith(u8, durl, "https://")))
                @compileError("oauth2 provider '" ++ pname ++ "': .discoveryURL must be an https:// URL");
            if (@import("oauth/providers.zig").lookup(pname) != null)
                @compileError("oauth2 provider '" ++ pname ++ "' is a built-in preset; .discoveryURL is for generic OIDC providers — pick a non-preset name");
            out.discoveryURL = durl;
        }
        return out;
    }
}

fn buildField(comptime col_name: []const u8, comptime f: anytype) schema.Field {
    comptime {
        const F = @TypeOf(f);
        if (!@hasField(F, "name")) @compileError("a field in collection '" ++ col_name ++ "' is missing .name");
        const fname: []const u8 = f.name;
        if (schema.isSystemFieldName(fname)) @compileError("collection '" ++ col_name ++ "': field name '" ++ fname ++ "' is reserved by the engine (id/created/updated/email/username/passwordHash/tokenKey/verified/token_epoch); pick another name");
        if (!@hasField(F, "type")) @compileError("field '" ++ fname ++ "' in collection '" ++ col_name ++ "' is missing .type");
        const ftype: schema.FieldType = f.type;

        // Fail loud on an unknown field key (a typo like `.requied`/`.encrypte` would
        // otherwise be silently ignored). Allowed = the common keys read below plus the
        // per-type option keys read in `buildOptions`.
        rejectUnknownFieldKeys(f, ftype, "field '" ++ fname ++ "' in collection '" ++ col_name ++ "'");

        // A stable field id derived from collection+field name keeps provisioning
        // idempotent (the rebuild path matches columns by field id across runs).
        const fid = stableFieldId(col_name, fname);

        var field = schema.Field{
            .id = fid,
            .name = fname,
            .options = undefined,
        };
        if (@hasField(F, "required")) field.required = f.required;
        if (@hasField(F, "unique")) field.unique = f.unique;
        if (@hasField(F, "hidden")) field.hidden = f.hidden;
        if (@hasField(F, "encrypted")) field.encrypted = f.encrypted;
        if (@hasField(F, "searchable")) field.searchable = f.searchable;

        // Full-text search (#157): only free-text columns can be mirrored into an FTS5 index, and an
        // encrypted column (per-row-nonce ciphertext) can never be searchable. Enforced loud at
        // comptime here; the runtime collections API mirrors these in schema.validate.
        if (field.searchable) {
            if (!schema.isSearchableType(ftype))
                @compileError("field '" ++ fname ++ "' in collection '" ++ col_name ++ "': .searchable is only supported on text/editor fields");
            if (field.encrypted)
                @compileError("field '" ++ fname ++ "' in collection '" ++ col_name ++ "': an encrypted field cannot be .searchable (ciphertext is not full-text searchable)");
        }

        // At-rest encryption (Theme B1) is only meaningful for string-stored types
        // and is incompatible with uniqueness (a per-row nonce means identical
        // plaintexts produce different ciphertexts). Index references are checked in
        // buildCollection once the full field list is known.
        if (field.encrypted) {
            if (!schema.isEncryptableType(ftype))
                @compileError("field '" ++ fname ++ "' in collection '" ++ col_name ++ "': .encrypted is only supported on text/editor/json fields");
            if (field.unique)
                @compileError("field '" ++ fname ++ "' in collection '" ++ col_name ++ "': an encrypted field cannot be .unique (encryption uses a per-row nonce, so a uniqueness constraint over ciphertext is meaningless)");
        }

        field.options = buildOptions(col_name, fname, ftype, f);
        return field;
    }
}

fn buildOptions(comptime col: []const u8, comptime fname: []const u8, comptime ftype: schema.FieldType, comptime f: anytype) schema.FieldOptions {
    comptime {
        const F = @TypeOf(f);
        const where = "field '" ++ fname ++ "' in collection '" ++ col ++ "'";
        return switch (ftype) {
            .text => blk: {
                const pat = optStr(f, "pattern");
                if (pat) |p| _ = regex.compileComptime(p); // @compileError on a bad pattern
                break :blk .{ .text = .{
                    .min = optU32(f, "min"),
                    .max = optU32(f, "max"),
                    .pattern = pat,
                } };
            },
            .email => .{ .email = .{} },
            .url => .{ .url = .{} },
            .editor => .{ .editor = .{} },
            .date => blk: {
                const dmin = optStr(f, "min");
                const dmax = optStr(f, "max");
                const min_secs: ?i64 = if (dmin) |b| (datetime.parse(b) catch @compileError(where ++ ": date .min is not a valid date \"" ++ b ++ "\"")) else null;
                const max_secs: ?i64 = if (dmax) |b| (datetime.parse(b) catch @compileError(where ++ ": date .max is not a valid date \"" ++ b ++ "\"")) else null;
                // Reject an unsatisfiable range at build time: min > max can never
                // accept any value once both bounds are enforced.
                if (min_secs) |lo| if (max_secs) |hi| if (lo > hi)
                    @compileError(where ++ ": date .min \"" ++ dmin.? ++ "\" is after .max \"" ++ dmax.? ++ "\"");
                break :blk .{ .date = .{ .min = dmin, .max = dmax } };
            },
            .autodate => .{ .autodate = .{
                .onCreate = if (@hasField(F, "onCreate")) f.onCreate else true,
                .onUpdate = if (@hasField(F, "onUpdate")) f.onUpdate else false,
            } },
            .bool => .{ .bool = .{} },
            .number => blk: {
                const mode: schema.NumberMode = if (@hasField(F, "mode")) f.mode else .float;
                const scale = optU8(f, "scale");
                if (mode == .fixed and (scale == null or scale.? < 1 or scale.? > 8))
                    @compileError(where ++ ": fixed number requires .scale = 1..8");
                break :blk .{ .number = .{
                    .mode = mode,
                    .scale = scale,
                    .min = optF64(f, "min"),
                    .max = optF64(f, "max"),
                } };
            },
            .json => .{ .json = .{ .maxSize = optU32(f, "maxSize") } },
            .select => blk: {
                if (!@hasField(F, "values")) @compileError(where ++ ": select requires .values = .{ ... }");
                const vals = strTupleToSlice(f.values);
                if (vals.len == 0) @compileError(where ++ ": select requires at least one value");
                break :blk .{ .select = .{
                    .values = vals,
                    .maxSelect = if (@hasField(F, "maxSelect")) f.maxSelect else 1,
                } };
            },
            .relation => blk: {
                if (!@hasField(F, "target")) @compileError(where ++ ": relation requires .target = \"<collection name>\"");
                const target: []const u8 = f.target;
                if (target.len == 0) @compileError(where ++ ": relation .target must be a non-empty collection name");
                // NOTE: at comptime we store the TARGET NAME in targetCollectionId;
                // applySchema resolves it to the target collection's id at provisioning.
                break :blk .{ .relation = .{
                    .targetCollectionId = target,
                    .cascadeDelete = if (@hasField(F, "cascadeDelete")) f.cascadeDelete else false,
                    .minSelect = optU32(f, "minSelect"),
                    .maxSelect = if (@hasField(F, "maxSelect")) f.maxSelect else 1,
                } };
            },
            .file => .{ .file = .{
                .maxSelect = if (@hasField(F, "maxSelect")) f.maxSelect else 1,
                .maxSize = optU64(f, "maxSize"),
                .mimeTypes = if (@hasField(F, "mimeTypes")) strTupleToSlice(f.mimeTypes) else null,
            } },
        };
    }
}

// --- comptime option extractors ---

fn optStr(comptime f: anytype, comptime key: []const u8) ?[]const u8 {
    return if (@hasField(@TypeOf(f), key)) @field(f, key) else null;
}
fn optU32(comptime f: anytype, comptime key: []const u8) ?u32 {
    return if (@hasField(@TypeOf(f), key)) @field(f, key) else null;
}
fn optU8(comptime f: anytype, comptime key: []const u8) ?u8 {
    return if (@hasField(@TypeOf(f), key)) @field(f, key) else null;
}
fn optU64(comptime f: anytype, comptime key: []const u8) ?u64 {
    return if (@hasField(@TypeOf(f), key)) @field(f, key) else null;
}
fn optF64(comptime f: anytype, comptime key: []const u8) ?f64 {
    return if (@hasField(@TypeOf(f), key)) @field(f, key) else null;
}

/// Lower a comptime tuple of string literals (e.g. `.{ "a", "b" }`) into a
/// `[]const []const u8` usable in a runtime schema spec.
fn strTupleToSlice(comptime t: anytype) []const []const u8 {
    comptime {
        const info = @typeInfo(@TypeOf(t));
        if (info != .@"struct") @compileError("expected a tuple of string literals");
        const tf = info.@"struct".fields;
        var out: [tf.len][]const u8 = undefined;
        for (tf, 0..) |tff, i| {
            const v: []const u8 = @field(t, tff.name);
            out[i] = v;
        }
        const frozen = out;
        return &frozen;
    }
}

/// Lower a comptime `.auth.methods.custom` tuple into the runtime slug list
/// (`[]const []const u8`). Each element is EITHER a bare slug string (back-compat)
/// OR a typed-method struct `.{ .slug = "...", .Initiate = ..., .Complete = ... }`;
/// both forms contribute their slug. The comptime I/O types on a struct entry are
/// reflected separately by `events.customAuthMeta` (the typed-codegen channel) and
/// are intentionally discarded here — the runtime dispatch keys only on the slug, so
/// this lowering is byte-for-byte compatible with the previous string-only behavior.
fn customSlugsToSlice(comptime t: anytype) []const []const u8 {
    comptime {
        // Accept a bare tuple `.{ ... }` or a `&.{ ... }` pointer-to-tuple.
        const tup = if (@typeInfo(@TypeOf(t)) == .pointer) t.* else t;
        const info = @typeInfo(@TypeOf(tup));
        if (info != .@"struct") @compileError(".auth.methods.custom must be a tuple of slug strings and/or typed-method structs");
        const tf = info.@"struct".fields;
        var out: [tf.len][]const u8 = undefined;
        for (tf, 0..) |tff, i| {
            const elem = @field(tup, tff.name);
            switch (@typeInfo(@TypeOf(elem))) {
                .pointer => {
                    const slug: []const u8 = elem;
                    if (std.mem.eql(u8, slug, "sessions") or std.mem.eql(u8, slug, "two-factor"))
                        @compileError("auth method slug '" ++ slug ++ "' is reserved for framework session or two-factor routes");
                    out[i] = elem; // bare slug string
                },
                .@"struct" => {
                    if (!@hasField(@TypeOf(elem), "slug"))
                        @compileError(".auth.methods.custom struct entry must have a .slug field");
                    const slug: []const u8 = elem.slug;
                    if (std.mem.eql(u8, slug, "sessions") or std.mem.eql(u8, slug, "two-factor"))
                        @compileError("auth method slug '" ++ slug ++ "' is reserved for framework session or two-factor routes");
                    out[i] = slug;
                },
                else => @compileError(".auth.methods.custom entry must be a slug string or a struct with a .slug field"),
            }
        }
        const frozen = out;
        return &frozen;
    }
}

fn buildIndexes(comptime col_name: []const u8, comptime t: anytype) []const schema.Index {
    comptime {
        const T = @TypeOf(t);
        const info = @typeInfo(T);
        if (info != .@"struct")
            @compileError("collection '" ++ col_name ++ "' .indexes must be a tuple of index literals");
        const tf = info.@"struct".fields;
        var out: [tf.len]schema.Index = undefined;
        for (tf, 0..) |tff, i| {
            const idx = @field(t, tff.name);
            const I = @TypeOf(idx);
            if (!@hasField(I, "name"))
                @compileError("an index in collection '" ++ col_name ++ "' is missing .name");
            if (!@hasField(I, "fields"))
                @compileError("an index in collection '" ++ col_name ++ "' is missing .fields");
            // Fail loud on a typo'd key (e.g. `.uniqe`): the builder reads .unique/.collation/
            // .where via @hasField, so a misspelling would be silently dropped and silently
            // change index semantics (a non-unique index, a full instead of partial one).
            rejectUnknownKeys(idx, &.{ "name", "fields", "unique", "collation", "where" }, "index in collection '" ++ col_name ++ "'");
            const iname: []const u8 = idx.name;
            if (!schema.isValidIdentifier(iname))
                @compileError("index name '" ++ iname ++ "' in collection '" ++ col_name ++ "' is not a valid identifier");
            const fields = strTupleToSlice(idx.fields);
            for (fields) |fname| {
                if (!schema.isValidIdentifier(fname))
                    @compileError("index '" ++ iname ++ "' in collection '" ++ col_name ++ "' references an invalid field identifier '" ++ fname ++ "'");
            }
            var oi = schema.Index{ .name = iname, .fields = fields };
            if (@hasField(I, "unique")) oi.unique = idx.unique;
            if (@hasField(I, "collation")) oi.collation = idx.collation;
            if (@hasField(I, "where")) oi.where = idx.where;
            out[i] = oi;
        }
        const frozen = out;
        return &frozen;
    }
}

/// Deterministic 8-char lowercase-hex id derived from collection+field name.
/// Stable across runs so additive provisioning matches columns by id.
fn stableFieldId(comptime col: []const u8, comptime name: []const u8) []const u8 {
    comptime {
        var h = std.hash.Fnv1a_64.init();
        h.update(col);
        h.update("\x00");
        h.update(name);
        const v = h.final();
        const hex = "0123456789abcdef";
        var buf: [8]u8 = undefined;
        var x = v;
        var i: usize = 8;
        while (i > 0) {
            i -= 1;
            buf[i] = hex[@intCast(x & 0xf)];
            x >>= 4;
        }
        const frozen = buf;
        return &frozen;
    }
}

// ---------------------------------------------------------------------------
// Explicit-migration escape hatch
// ---------------------------------------------------------------------------

/// An explicit migration for changes additive auto-provisioning won't do
/// (renames, retypes, data backfills). Recorded in `_migrations` under
/// `id` (prefixed), so it runs exactly once and is idempotent across restarts.
///
/// `up` receives a `*Migrator` carrying the active SQL `Dialect` (#159, PR-2): the SAME migration
/// can therefore run on SQLite or Postgres. Use `m.execLowered(sql)` for portable additive
/// DDL/seeds (the dialect lowers the SQLite-isms), `m.exec(sql)` for raw backend-specific SQL
/// (the consumer owns dialect correctness — SQLite-only SQL run on Postgres fails loud at
/// startup), or branch on `m.dialect.kind` / `m.rawFor(.postgres, …)`. `m.db`/`m.io` expose the
/// writer + `std.Io`. See `src/migrator.zig` for the full contract.
///
/// Note: `m.arena` is a short-lived arena scoped to the `runMigrations` call — anything
/// allocated from it is freed before `runMigrations` returns. Do not store pointers derived from
/// it in state that outlives the call; use a separate long-lived allocator for persistent data.
pub const Migration = struct {
    id: []const u8,
    /// Auto-reversible forward change (Rails `change`). Applied with the Migrator in
    /// forward mode; Piece B rolls it back by re-running with direction = .reverse.
    change: ?*const fn (m: *Migrator) anyerror!void = null,
    /// Explicit forward step (use when the change isn't auto-reversible).
    up: ?*const fn (m: *Migrator) anyerror!void = null,
    /// Explicit reverse step for rollback (Piece B). Pairs with `up`, or overrides `change`.
    down: ?*const fn (m: *Migrator) anyerror!void = null,
    /// Per-migration transactional opt-out (default true) for DDL that can't run in a tx.
    transactional: bool = true,
};

// ---------------------------------------------------------------------------
// Runtime provisioner
// ---------------------------------------------------------------------------

pub const ProvisionError = error{ UnknownRelationTarget, RelationTargetMissing, FtsDisabled } ||
    collections.EngineError;

/// Apply the comptime-defined schema to the live database. Safe to call on
/// every startup: it is idempotent. Two-pass so name-based relations resolve
/// after all targets exist.
///   pass 1: ensure every collection exists (create missing; additive field-add
///           for existing). Relation fields are created with their target NAME
///           still in targetCollectionId — collections.create resolves the FK by
///           name, but the persisted metadata must carry the target *id*, so...
///   pass 2: resolve every relation field's target name -> id and reconcile.
pub fn applySchema(
    alloc: std.mem.Allocator,
    io: std.Io,
    w: *db.Db,
    comptime cfg: anytype,
) ProvisionError!void {
    const specs = comptime buildCollections(cfg);
    try applySpecs(alloc, io, w, specs);
}

/// Like `applySchema` but takes already-lowered specs (used by tests and by
/// `applySchema`). Relation targetCollectionId carries the target NAME on input.
///
/// `alloc` is used only as the backing allocator for an internal arena; nothing
/// allocated inside this function escapes the call (all results are written to
/// the DB). Callers may safely pass their long-lived gpa.
/// Return a copy of `specs` where every auth collection's oauth2 providers have their
/// clientId/clientSecret filled in from the environment and the secret encrypted.
/// A provider whose env CLIENT_ID/SECRET are both absent is left as declared (empty strings).
///
/// `getter` is a duck-typed env getter: `fn get(self, key: []const u8) ?[]const u8`.
/// Pass `config.EnvGetter{ .environ = environ }` in production; pass a stub in tests.
///
/// Only allocates a new outer slice when at least one auth collection has providers to
/// rewrite; passes the original slice through otherwise (cheap pre-scan).
pub fn injectOAuthSecrets(
    alloc: std.mem.Allocator,
    io: std.Io,
    app_secret: []const u8,
    getter: anytype,
    specs: []const schema.Collection,
) ![]const schema.Collection {
    // Cheap pre-scan: only allocate a new outer slice when any auth collection has providers.
    var any = false;
    for (specs) |c| if (c.type == .auth and c.options.auth.oauth2.providers.len > 0) {
        any = true;
        break;
    };
    if (!any) return specs;

    const out = try alloc.alloc(schema.Collection, specs.len);
    for (specs, 0..) |c, ci| {
        out[ci] = c;
        if (c.type != .auth or c.options.auth.oauth2.providers.len == 0) continue;
        const src = c.options.auth.oauth2.providers;
        const np = try alloc.alloc(schema.OAuth2Provider, src.len);
        for (src, 0..) |p, i| {
            np[i] = p;
            // Build ZIGBASE_OAUTH_<UPPER(NAME)>_CLIENT_ID / _SECRET.
            // Provider names are validated as identifiers at comptime (buildOAuth2Provider),
            // so they are ASCII letters/digits/underscore — uppercase is char-by-char.
            // These three are scratch for the env lookup only — none escape, so free them
            // at the end of the iteration (callers may pass a long-lived gpa).
            const upper_buf = try alloc.alloc(u8, p.name.len);
            defer alloc.free(upper_buf);
            for (p.name, 0..) |ch, ui| upper_buf[ui] = std.ascii.toUpper(ch);
            const upper = upper_buf;
            const id_key = try std.fmt.allocPrint(alloc, "ZIGBASE_OAUTH_{s}_CLIENT_ID", .{upper});
            defer alloc.free(id_key);
            const sec_key = try std.fmt.allocPrint(alloc, "ZIGBASE_OAUTH_{s}_CLIENT_SECRET", .{upper});
            defer alloc.free(sec_key);
            if (getter.get(id_key)) |v| if (v.len > 0) {
                np[i].clientId = try alloc.dupe(u8, v);
            };
            if (getter.get(sec_key)) |v| if (v.len > 0) {
                // Guard: if somehow the env already contains an encrypted blob (e.g. the
                // operator copied a blob), pass it through unchanged — never double-encrypt.
                np[i].clientSecret = if (secrets.isEncrypted(v))
                    try alloc.dupe(u8, v)
                else
                    try secrets.encryptSecret(io, alloc, app_secret, v);
            };
            // Encrypt any still-plaintext secret regardless of its source (env above OR a
            // plaintext clientSecret baked into the comptime literal). Mirrors the admin path
            // (api/collections.zig prepareOAuthConfig): no plaintext secret is ever persisted.
            // The isEncrypted guard keeps this idempotent (never double-encrypts).
            if (np[i].clientSecret.len > 0 and !secrets.isEncrypted(np[i].clientSecret)) {
                np[i].clientSecret = try secrets.encryptSecret(io, alloc, app_secret, np[i].clientSecret);
            }
        }
        out[ci].options.auth.oauth2.providers = np;
    }
    return out;
}

/// Free the OWNED parts of a `resolveDiscoveryProviders`-built provider array: for each of the
/// first `done` providers (the rest, if any, never got as far as being touched), the resolved
/// authURL/tokenURL/userinfoURL dupes IFF that provider actually has a `discoveryURL` (the only
/// path that overwrites them with fresh owned strings — a provider without one is an untouched
/// shallow copy whose URL fields, if set at all, are BORROWED from the original spec and must
/// never be freed here), then the backing array itself.
fn freeResolvedProviders(alloc: std.mem.Allocator, ps: []schema.OAuth2Provider, done: usize) void {
    for (ps[0..done]) |p| {
        if (p.discoveryURL != null) {
            if (p.authURL) |u| alloc.free(u);
            if (p.tokenURL) |u| alloc.free(u);
            if (p.userinfoURL) |u| alloc.free(u);
        }
    }
    alloc.free(ps);
}

/// Resolve every `discoveryURL` provider's endpoints via OIDC discovery (spec §F4). Runs at
/// startup, after env-secret injection, BEFORE applySpecs persists the collection options —
/// so the resolved endpoints are stored exactly like literal generic endpoints. The fetch
/// happens on every startup for deterministic fail-fast (a broken IdP config can never boot
/// a server with dead login); persistence still follows the normal provisioning caveat
/// (existing collections are not rewritten — re-resolution needs a migration/admin PATCH).
/// ANY failure propagates — the caller aborts startup loudly (production has no cleanup to do,
/// the process exits; the errdefer below exists so a non-arena caller — e.g. a test — never sees
/// this as a leak).
pub fn resolveDiscoveryProviders(
    alloc: std.mem.Allocator,
    transport: oauth_client.Transport,
    specs: []const schema.Collection,
) ![]const schema.Collection {
    var any = false;
    for (specs) |c| {
        if (c.type != .auth) continue;
        for (c.options.auth.oauth2.providers) |p| if (p.discoveryURL != null) {
            any = true;
        };
    }
    if (!any) return specs; // zero-cost when no discovery provider is configured

    const out = try alloc.alloc(schema.Collection, specs.len);
    // Every provider array `out[ci]` has actually had replaced (vs. still aliasing `specs[ci]`'s
    // original array), plus how far into it processing got — freed on any later error.
    var replaced: std.ArrayList(struct { ps: []schema.OAuth2Provider, done: usize }) = .empty;
    errdefer {
        for (replaced.items) |r| freeResolvedProviders(alloc, r.ps, r.done);
        replaced.deinit(alloc);
        alloc.free(out);
    }
    for (specs, 0..) |c, ci| {
        out[ci] = c;
        if (c.type != .auth or c.options.auth.oauth2.providers.len == 0) continue;
        const src = c.options.auth.oauth2.providers;
        const np = try alloc.alloc(schema.OAuth2Provider, src.len);
        try replaced.append(alloc, .{ .ps = np, .done = 0 });
        const slot = &replaced.items[replaced.items.len - 1];
        for (src, 0..) |p, i| {
            np[i] = p;
            const durl = p.discoveryURL orelse {
                slot.done = i + 1;
                continue;
            };
            const eps = discovery.resolve(transport, alloc, durl) catch |e| {
                // .warn, not .err: the real startup failure is logged (at .err) by the
                // framework.zig caller, which is not itself hit by these unit tests — an
                // .err-level log call here would trip the test runner's "logged N errors"
                // failure on this function's own expected-failure test coverage below
                // (see static_files.zig's validateRouteTargetsDir for the same precedent).
                std.log.warn("OIDC discovery for provider '{s}' failed ({s}) fetching {s}", .{ p.name, @errorName(e), durl });
                return e;
            };
            np[i].authURL = eps.authURL;
            np[i].tokenURL = eps.tokenURL;
            np[i].userinfoURL = eps.userinfoURL;
            std.log.info("oauth provider '{s}': endpoints resolved via OIDC discovery", .{p.name});
            slot.done = i + 1;
        }
        out[ci].options.auth.oauth2.providers = np;
    }
    // Success: every `np` array's ownership transferred into `out`; only the bookkeeping list
    // itself (not the arrays it points at) is discarded.
    replaced.deinit(alloc);
    return out;
}

pub fn applySpecs(
    alloc: std.mem.Allocator,
    io: std.Io,
    w: *db.Db,
    specs: []const schema.Collection,
) ProvisionError!void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    // Opt-in vector search (#157/#159): on Postgres the `?vector=` KNN lowering needs the pgvector
    // `vector` type + `<=>`/`<->` operators, so ensure the server extension once at startup. A no-op
    // in a default (non-`-Dvector`) build or on SQLite; best-effort under Postgres (a privilege
    // failure warns, never aborts).
    vector.ensureExtension(w);

    // Validate all relation targets reference a known comptime collection name up
    // front, so an unknown target is a clear startup error (not a broken relation).
    for (specs) |spec| {
        for (spec.fields) |f| switch (f.options) {
            .relation => |r| {
                if (!nameInSpecs(specs, r.targetCollectionId)) {
                    // Allow targeting a pre-existing live collection too (e.g. _superusers).
                    if ((try collections.get(a, w, r.targetCollectionId)) == null) {
                        std.log.warn(
                            "provision: collection '{s}' field '{s}' relates to unknown target '{s}' — refusing to provision",
                            .{ spec.name, f.name, r.targetCollectionId },
                        );
                        return error.UnknownRelationTarget;
                    }
                }
            },
            else => {},
        };
    }

    // Topologically order so relation targets are created first; on cycle, fall
    // back to declaration order (collections.create resolves by name and will
    // error clearly if a target is genuinely missing).
    const order = try topoOrder(a, specs);

    for (order) |idx| {
        try ensureCollection(a, io, w, specs[idx]);
    }
}

/// Idempotent ensure: create the collection if absent, else additively add any
/// comptime field missing from the live schema. Destructive diffs are logged
/// and skipped. Relation fields' targetCollectionId (a NAME on input) is resolved
/// to the live target id before persisting.
pub fn ensureCollection(
    alloc: std.mem.Allocator,
    io: std.Io,
    w: *db.Db,
    spec_in: schema.Collection,
) ProvisionError!void {
    const spec = try resolveTargets(alloc, w, spec_in);

    // F3 lint: surface any allow-all (@public) rule prominently at startup.
    warnPublicRules(spec);
    // Tenancy lint: surface every tenant-owned collection so the operator can confirm scoping.
    warnTenantOwned(spec);
    // A `.nocase` index is now genuinely case-INSENSITIVE on BOTH backends (#159): SQLite via
    // COLLATE NOCASE, Postgres via a `lower()` functional index (see ddl.createIndexSql). No
    // startup weakening warning is needed any longer.

    const existing = try collections.get(alloc, w, spec.name);
    if (existing == null) {
        _ = try collections.create(alloc, io, w, spec);
        std.log.info("provision: created collection '{s}'", .{spec.name});
        try ensureTenantIndex(alloc, w, spec);
        try ensureSearchIndex(alloc, w, spec);
        return;
    }
    const live = existing.?;
    // The physical table exists now; ensure the tenant_field is indexed (idempotent).
    try ensureTenantIndex(alloc, w, spec);
    // Provision/refresh the FTS5 full-text index (#157) — idempotent; rebuilds if the searchable
    // column set drifted or an earlier additive rebuild dropped the sync triggers. Runs every
    // startup so an upgrade that adds `.searchable` builds the index without a migration.
    try ensureSearchIndex(alloc, w, spec);

    // Diff user fields. `live.fields` from get() includes injected auth system
    // fields for auth collections; compare only against non-system field names.
    // (additions/merged below skip .deinit(): this fn runs under applySpecs'
    // arena, which reclaims them wholesale.)
    var additions: std.ArrayList(schema.Field) = .empty;
    var changed = false;
    for (spec.fields) |sf| {
        const lf = schema.fieldByName(live, sf.name);
        if (lf == null) {
            try additions.append(alloc, sf);
            changed = true;
            continue;
        }
        // present in both: detect a non-additive change (field type or backend-neutral storage
        // class — the dialect maps storageClass to the concrete column type, so comparing the
        // class is correct on either backend).
        if (lf.?.fieldType() != sf.fieldType() or lf.?.storageClass() != sf.storageClass()) {
            std.log.warn(
                "provision: collection '{s}' field '{s}' type changed ({s} -> {s}); SKIPPED — write an explicit migration (auto-migration is additive-only)",
                .{ spec.name, sf.name, @tagName(lf.?.fieldType()), @tagName(sf.fieldType()) },
            );
        }
    }

    // Detect drops: a live user field absent from the comptime spec. We do NOT
    // drop it (data loss); just warn so the developer knows the schemas diverge.
    for (live.fields) |lf| {
        if (lf.id.len > 0 and lf.id[0] == '_') continue; // injected auth system field
        if (schema.isSystemFieldName(lf.name)) continue;
        if (specFieldByName(spec, lf.name) == null) {
            std.log.warn(
                "provision: collection '{s}' has live field '{s}' not in the comptime schema; left in place (auto-migration never drops columns)",
                .{ spec.name, lf.name },
            );
        }
    }

    // TTL: a `.ttl_field` newly added to (or changed on) an EXISTING collection must
    // be persisted, else the GC never sees it. Compare the spec's ttl_field against
    // the live one and, if it differs, force an update (narrowly — we only carry the
    // ttl_field across below, never wholesale-copying spec.options, which would clobber
    // persisted OAuth secrets).
    const ttl_differs = blk: {
        const a = spec.options.ttl_field;
        const b = live.options.ttl_field;
        if (a == null and b == null) break :blk false;
        if (a == null or b == null) break :blk true;
        break :blk !std.mem.eql(u8, a.?, b.?);
    };
    if (ttl_differs) changed = true;

    // Access rules: a rule-only comptime change carries NO physical-schema consequence, so it
    // must not be gated behind `changed` (which only tracks field additions and the ttl_field) —
    // and it must not go through collections.update either, whose unconditional table rebuild
    // would copy every row and drop unknown indexes just to tighten a rule. Persist it with the
    // metadata-only writer instead. This matters for security: policy.zig enforces the rules on
    // the collection loaded out of _collections, so a developer who TIGHTENS a rule in code and
    // redeploys would otherwise keep enforcing the old, looser rule indefinitely.
    const merged_rules = mergeRules(spec, live);
    if (!changed and !merged_rules.eql(collections.Rules.from(live))) {
        try collections.updateRules(alloc, w, live.id, merged_rules);
        std.log.info("provision: collection '{s}' access rules updated", .{spec.name});
    }

    if (!changed) return; // idempotent no-op

    // Additive auto-migration: rebuild the table with the union of live + new
    // fields, matching existing columns by id (rebuildPlan preserves their data),
    // and persist the merged user-field schema.
    var merged: std.ArrayList(schema.Field) = .empty;
    // keep the live user fields (preserves their ids/order), then append additions
    for (live.fields) |lf| {
        if (lf.id.len > 0 and lf.id[0] == '_') continue; // skip injected auth fields
        if (schema.isSystemFieldName(lf.name)) continue;
        try merged.append(alloc, lf);
    }
    for (additions.items) |sf| try merged.append(alloc, sf);

    var newdef = live;
    newdef.fields = merged.items;
    newdef.indexes = spec.indexes;
    merged_rules.applyTo(&newdef);
    // Carry the (possibly newly-set) ttl_field; keep the rest of live.options
    // (e.g. persisted OAuth secrets) untouched by NOT copying spec.options wholesale.
    newdef.options.ttl_field = spec.options.ttl_field;
    _ = try collections.update(alloc, io, w, live.id, newdef);
    std.log.info("provision: collection '{s}' added {d} field(s)", .{ spec.name, additions.items.len });
    // The additive rebuild drops triggers tied to the old table; re-ensure the FTS index so its
    // sync triggers (and any newly-searchable column) are restored.
    try ensureSearchIndex(alloc, w, spec);
}

/// `spec`'s access rules overlaid on `live`'s: a `null` spec rule means "unspecified —
/// inherit whatever is live", NEVER "clear the rule". (An explicitly-locked rule is spelled
/// `""`, which is a value and does override.)
///
/// The single source of truth for the merge, shared by the rule-only persist path and the
/// additive-rebuild path in `ensureCollection`, so the two can never drift apart.
fn mergeRules(spec: schema.Collection, live: schema.Collection) collections.Rules {
    return .{
        .list = spec.listRule orelse live.listRule,
        .view = spec.viewRule orelse live.viewRule,
        .create = spec.createRule orelse live.createRule,
        .update = spec.updateRule orelse live.updateRule,
        .delete = spec.deleteRule orelse live.deleteRule,
    };
}

/// Return a copy of `col` where each single-relation field's targetCollectionId
/// (a target NAME on input) is replaced by the live target collection's id, so the
/// persisted metadata matches what the runtime API produces. Errors clearly if the
/// target is missing — EXCEPT a self-relation (`targetCollectionId == col.name`) on a
/// collection that does not exist live yet: it is being created by THIS `ensureCollection`
/// call, so there is no id to resolve to (a chicken-and-egg the id generation inside
/// `collections.create` cannot avoid). Left as the bare name in that one case; `collections.get`'s
/// `WHERE id = ?1 OR name = ?1` treats a name exactly like an id, so this is functionally
/// identical to the resolved-id form once the collection exists (and is exactly why the
/// manifest importer's `manifestCollections` already normalizes id-or-name — see import_manifest.zig).
fn resolveTargets(alloc: std.mem.Allocator, w: *db.Db, col: schema.Collection) ProvisionError!schema.Collection {
    var any = false;
    for (col.fields) |f| if (f.options == .relation) {
        any = true;
    };
    if (!any) return col;

    const fields = try alloc.alloc(schema.Field, col.fields.len);
    for (col.fields, 0..) |f, i| {
        fields[i] = f;
        switch (f.options) {
            .relation => |r| {
                if (try collections.get(alloc, w, r.targetCollectionId)) |target| {
                    var nr = r;
                    nr.targetCollectionId = target.id;
                    fields[i].options = .{ .relation = nr };
                } else if (!std.mem.eql(u8, r.targetCollectionId, col.name)) {
                    std.log.warn("provision: relation target '{s}' not found while provisioning '{s}' — refusing to provision", .{ r.targetCollectionId, col.name });
                    return error.RelationTargetMissing;
                }
                // else: self-relation on a not-yet-created collection — leave `fields[i]` as
                // copied above (targetCollectionId stays the name).
            },
            else => {},
        }
    }
    var out = col;
    out.fields = fields;
    return out;
}

/// Run explicit migrations in order, each recorded once in `_migrations` under a
/// `prov:` prefix (so they never collide with the built-in system migrations).
///
/// `alloc` is used only as the backing allocator for an internal arena; nothing
/// allocated inside this function escapes the call. Callers may safely pass their
/// long-lived gpa.
pub fn runMigrations(
    alloc: std.mem.Allocator,
    io: std.Io,
    w: *db.Db,
    migs: []const Migration,
) !void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    // The dialect-aware handle threaded into each consumer migration's `up`.
    var mig = Migrator{ .db = w, .dialect = db.dbDialect(w), .arena = a, .io = io };

    for (migs) |m| {
        const name = try std.fmt.allocPrint(a, "prov:{s}", .{m.id});
        if (try migrationApplied(&mig, name)) continue;
        // Piece A applies migrations FORWARD only (Piece B adds the reverse/rollback pass). Set the
        // direction explicitly per migration so a `change`'s DSL ops emit their forward SQL.
        mig.direction = .forward;
        // A `change` (auto-reversible) or an explicit `up` — exactly one is present (comptime-checked
        // in framework.zig's `.migrations` lowering, so `m.up.?` is safe here).
        const fwd = m.change orelse m.up.?;
        if (m.transactional) {
            // Default: the migration's DDL/DML + its `_migrations` bookkeeping commit atomically;
            // any failure rolls the whole thing back (nothing recorded).
            try w.begin();
            errdefer w.rollback() catch {};
            try fwd(&mig);
            try recordMigration(&mig, name);
            try w.commit();
        } else {
            // Opt-out: statements that cannot run inside a transaction (e.g. VACUUM, some CREATE
            // INDEX CONCURRENTLY on Postgres). No wrapping tx and no rollback — the migration owns
            // its own atomicity. Record only after it succeeds so a failure leaves it un-applied
            // (and re-runnable) rather than falsely marked done.
            try fwd(&mig);
            try recordMigration(&mig, name);
        }
        // A consumer migration runs arbitrary raw SQL and may create/alter/drop collections
        // without going through the collections.zig primitives, so nothing has bumped the marker.
        // Bump per applied migration — deliberately conservative: we cannot tell whether a given
        // migration touched collection metadata, and an unnecessary bump costs one cache reload
        // while a missed one serves stale metadata until restart.
        //
        // Outside the migration's own transaction on purpose: the `.transactional = false` arm has
        // no transaction to join, and the bump must behave identically on both arms. A migration
        // that committed but whose bump then fails surfaces the error to the caller (startup
        // fails loudly) rather than silently leaving the marker behind.
        try schema_gen.bump(w);
        std.log.info("provision: applied migration '{s}'", .{m.id});
    }
}

fn migrationApplied(m: *Migrator, name: []const u8) db.DbError!bool {
    var st = try m.prepare("SELECT 1 FROM \"_migrations\" WHERE \"name\" = ?1;");
    defer st.finalize();
    try st.bindText(1, name);
    return try st.step();
}

fn recordMigration(m: *Migrator, name: []const u8) db.DbError!void {
    const sql = std.fmt.allocPrint(m.arena, "INSERT INTO \"_migrations\" (\"name\", \"applied_at\") VALUES (?1, {s});", .{m.dialect.nowTextExpr()}) catch return error.PrepareFailed;
    var st = try m.prepare(sql);
    defer st.finalize();
    try st.bindText(1, name);
    _ = try st.step();
}

// ---------------------------------------------------------------------------
// Migration status (CLI `migrate status`, Piece B stage B1)
// ---------------------------------------------------------------------------

/// One applied consumer-migration ledger row (`prov:`-prefixed name + its `applied_at`).
pub const AppliedMigration = struct { name: []const u8, applied_at: []const u8 };

/// Free a fully-owned `[]AppliedMigration` — exactly the shape `appliedConsumerMigrations`/
/// `recentConsumerMigrations` return (every `.name`/`.applied_at` duped onto `alloc`).
pub fn freeAppliedMigrations(alloc: std.mem.Allocator, ms: []const AppliedMigration) void {
    for (ms) |m| {
        alloc.free(m.name);
        alloc.free(m.applied_at);
    }
    alloc.free(ms);
}

/// Strip the `prov:` ledger prefix a consumer migration is recorded under; returns the bare id.
fn stripProv(name: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, name, "prov:")) name[5..] else name;
}

/// Read the applied CONSUMER migrations from the `_migrations` ledger, in apply order
/// (`id` ascending). Names retain the `prov:` prefix. Mirrors `migrationApplied`'s dialect-aware
/// `m.prepare` (placeholder renumbering, harmless here — the query is placeholder-free) so it
/// works on SQLite and Postgres. Self-freeing (contract 1): `Migrator.prepare` lowers the SQL onto
/// `m.arena` and never frees that scratch (SQLite copies the SQL text internally on prepare, so
/// it's safe to reclaim right after) — give it a function-local arena rather than `alloc`, so only
/// the retained `AppliedMigration` dupes escape on `alloc`.
pub fn appliedConsumerMigrations(alloc: std.mem.Allocator, w: *db.Db) ![]AppliedMigration {
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    var m = Migrator{ .db = w, .dialect = db.dbDialect(w), .arena = scratch.allocator(), .io = undefined };
    var st = try m.prepare("SELECT \"name\", \"applied_at\" FROM \"_migrations\" WHERE \"name\" LIKE 'prov:%' ORDER BY \"id\";");
    defer st.finalize();
    var list: std.ArrayList(AppliedMigration) = .empty;
    while (try st.step()) {
        const name = try alloc.dupe(u8, st.columnText(0));
        const at = try alloc.dupe(u8, st.columnText(1));
        try list.append(alloc, .{ .name = name, .applied_at = at });
    }
    return try list.toOwnedSlice(alloc);
}

/// One declared consumer migration cross-referenced against the ledger: `applied_at` is set
/// (the ledger timestamp) when applied, `null` when pending.
pub const StatusEntry = struct { id: []const u8, applied_at: ?[]const u8 };

/// The result of cross-referencing the compiled-in `.migrations` against the ledger.
///   - `declared`: every compiled-in migration, in DECLARED order, applied-or-pending.
///   - `orphaned`: applied `prov:` rows whose id is NOT compiled in (migration deleted from
///     source). `.name` here is the bare id (prefix stripped).
pub const MigrationStatus = struct {
    declared: []StatusEntry,
    orphaned: []AppliedMigration,
    applied_count: usize,
    pending_count: usize,

    /// Free a fully-owned `MigrationStatus` (the shape `migrationStatus` returns). Each
    /// `declared[i].applied_at` (when present) and both of `orphaned[i]`'s strings are owned
    /// dupes, freed individually; `declared[i].id` BORROWS the caller's own `migs[i].id` and is
    /// never freed here.
    pub fn deinit(self: MigrationStatus, alloc: std.mem.Allocator) void {
        for (self.declared) |e| if (e.applied_at) |at| alloc.free(at);
        alloc.free(self.declared);
        for (self.orphaned) |o| {
            alloc.free(o.name);
            alloc.free(o.applied_at);
        }
        alloc.free(self.orphaned);
    }
};

/// Compute the applied/pending/orphaned buckets by cross-referencing the compiled-in migrations
/// (`migs`, in declared order) against the ledger. Owned-result (contract 2): `applied` (the raw
/// ledger read) is scratch, freed before return — every string retained in the result is a FRESH
/// dupe, not a borrow into `applied`'s buffers (a borrow would leave `orphaned[i].name`, a
/// stripped-prefix sub-slice, impossible to free on its own). Free the result with
/// `MigrationStatus.deinit`.
pub fn migrationStatus(alloc: std.mem.Allocator, w: *db.Db, migs: []const Migration) !MigrationStatus {
    const applied = try appliedConsumerMigrations(alloc, w);
    defer {
        for (applied) |ar| {
            alloc.free(ar.name);
            alloc.free(ar.applied_at);
        }
        alloc.free(applied);
    }

    const declared = try alloc.alloc(StatusEntry, migs.len);
    errdefer alloc.free(declared);
    var applied_count: usize = 0;
    var di: usize = 0;
    errdefer for (declared[0..di]) |e| if (e.applied_at) |at| alloc.free(at);
    while (di < migs.len) : (di += 1) {
        const mig = migs[di];
        var at: ?[]const u8 = null;
        for (applied) |ar| {
            if (std.mem.eql(u8, stripProv(ar.name), mig.id)) {
                at = try alloc.dupe(u8, ar.applied_at);
                break;
            }
        }
        if (at != null) applied_count += 1;
        declared[di] = .{ .id = mig.id, .applied_at = at };
    }

    var orphans: std.ArrayList(AppliedMigration) = .empty;
    errdefer {
        for (orphans.items) |o| {
            alloc.free(o.name);
            alloc.free(o.applied_at);
        }
        orphans.deinit(alloc);
    }
    for (applied) |ar| {
        const id = stripProv(ar.name);
        var known = false;
        for (migs) |mig| if (std.mem.eql(u8, mig.id, id)) {
            known = true;
            break;
        };
        if (!known) {
            const owned_id = try alloc.dupe(u8, id);
            errdefer alloc.free(owned_id);
            const owned_at = try alloc.dupe(u8, ar.applied_at);
            try orphans.append(alloc, .{ .name = owned_id, .applied_at = owned_at });
        }
    }

    return .{
        .declared = declared,
        .orphaned = try orphans.toOwnedSlice(alloc),
        .applied_count = applied_count,
        .pending_count = migs.len - applied_count,
    };
}

// ---------------------------------------------------------------------------
// Migration rollback (CLI `migrate rollback [N]`, Piece B stage B2)
// ---------------------------------------------------------------------------

/// Read the N most-recently-applied CONSUMER migrations, NEWEST FIRST (`id` descending). Mirrors
/// `appliedConsumerMigrations` but bounded + reversed so a rollback reverses the last-applied
/// migrations first. Dialect-aware via `m.prepare` (SQLite `?1` → Postgres `$1`); the bound `LIMIT`
/// is portable across both backends. Self-freeing (contract 1): see `appliedConsumerMigrations` —
/// `m.arena` is a function-local scratch arena, not `alloc`; only the returned dupes escape.
pub fn recentConsumerMigrations(alloc: std.mem.Allocator, w: *db.Db, limit: usize) ![]AppliedMigration {
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    var m = Migrator{ .db = w, .dialect = db.dbDialect(w), .arena = scratch.allocator(), .io = undefined };
    var st = try m.prepare("SELECT \"name\", \"applied_at\" FROM \"_migrations\" WHERE \"name\" LIKE 'prov:%' ORDER BY \"id\" DESC LIMIT ?1;");
    defer st.finalize();
    // Clamp rather than @intCast: a hostile N (e.g. u64 max from the CLI) must cap the LIMIT, not
    // panic on overflow (safe build) / bind a negative LIMIT (release). Mirrors the queryAs cast fix.
    try st.bindInt(1, std.math.cast(i64, limit) orelse std.math.maxInt(i64));
    var list: std.ArrayList(AppliedMigration) = .empty;
    while (try st.step()) {
        const name = try alloc.dupe(u8, st.columnText(0));
        const at = try alloc.dupe(u8, st.columnText(1));
        try list.append(alloc, .{ .name = name, .applied_at = at });
    }
    return try list.toOwnedSlice(alloc);
}

/// Delete one consumer-migration ledger row by its full (`prov:`-prefixed) name. The inverse of
/// `recordMigration`; called inside the same transaction as a migration's reverse body so the two
/// commit or roll back atomically. Dialect-aware via `m.prepare`.
fn deleteConsumerMigration(m: *Migrator, name: []const u8) db.DbError!void {
    var st = try m.prepare("DELETE FROM \"_migrations\" WHERE \"name\" = ?1;");
    defer st.finalize();
    try st.bindText(1, name);
    _ = try st.step();
}

/// Find a compiled-in migration by its bare id (no `prov:` prefix).
fn findMigration(migs: []const Migration, id: []const u8) ?Migration {
    for (migs) |m| if (std.mem.eql(u8, m.id, id)) return m;
    return null;
}

/// The outcome of a `rollbackMigrations` run. DB/IO failures still propagate as Zig errors; the
/// refusal cases below carry the offending migration's bare id so the CLI can name it.
///   - `ok`: the bare ids reversed, NEWEST FIRST (may be shorter than the requested N when fewer
///     consumer migrations are applied — PocketBase-style `min(N, applied)`).
///   - `irreversible`: a selected migration has no usable reverse (a lone `up`; a non-transactional
///     migration reversed via a `change`; or a `change` whose reverse hit an irreversible op such as
///     `records()`/`raw`/a `.was`-less drop, or `addForeignKey` on SQLite). `reversed` lists the
///     ids that WERE reversed+committed (newest-first) BEFORE the offender — empty for a pre-flight
///     refusal (which touches nothing), or non-empty when a cleanly-reversible NEWER migration
///     committed before a mid-batch offender hit (whose own partial reverse its tx rolled back).
///   - `orphaned`: a selected `prov:` ledger row whose migration is no longer compiled in; it cannot
///     be reversed and its ledger row is left intact. Pre-flight-only (`reversed` is always empty),
///     so it never partially executes.
pub const RollbackOutcome = union(enum) {
    ok: [][]const u8,
    irreversible: struct { reversed: [][]const u8, id: []const u8 },
    orphaned: struct { reversed: [][]const u8, id: []const u8 },

    /// Free a fully-owned `RollbackOutcome` — every id and the `reversed`/`ok` backing array(s)
    /// are `alloc`-owned dupes (see `rollbackMigrations`); `.reversed = &.{}` on a pre-flight
    /// refusal is a static empty literal, a no-op to free.
    pub fn deinit(self: RollbackOutcome, alloc: std.mem.Allocator) void {
        switch (self) {
            .ok => |ids| {
                for (ids) |id| alloc.free(id);
                alloc.free(ids);
            },
            .irreversible => |r| {
                for (r.reversed) |id| alloc.free(id);
                alloc.free(r.reversed);
                alloc.free(r.id);
            },
            .orphaned => |r| {
                for (r.reversed) |id| alloc.free(id);
                alloc.free(r.reversed);
                alloc.free(r.id);
            },
        }
    }
};

/// Reverse the `n` most-recently-applied CONSUMER migrations, newest first. The reverse of a
/// migration is `down orelse change` (spec §3): an explicit `down` runs in FORWARD semantics; a bare
/// `change` runs with `direction = .reverse` (each DSL op emits its inverse). A migration with only
/// an `up` has NO reverse. The ledger row is deleted in the SAME transaction as the reverse body,
/// mirroring the forward apply's tx wrapping (`transactional = false` runs both bare, no tx).
///
/// Fails LOUDLY, changing nothing it cannot undo: a full PRE-FLIGHT pass refuses the whole batch
/// (touching nothing) when any selected migration is orphaned, a lone `up`, or a non-transactional
/// `change` (no tx to undo a partial reverse). Only a transactional `change` whose irreversibility is
/// unknowable without running reaches execution — and its per-migration tx undoes the partial work
/// before the run reports it. `alloc` backs an internal arena; the returned ids are duped from it.
pub fn rollbackMigrations(
    alloc: std.mem.Allocator,
    io: std.Io,
    w: *db.Db,
    migs: []const Migration,
    n: usize,
) !RollbackOutcome {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const selected = try recentConsumerMigrations(a, w, n);

    // The ids reversed+committed so far, newest-first. Reported on every outcome so a partial
    // mid-batch stop tells the user exactly what WAS undone (pre-flight refusals leave it empty).
    // Every id is duped from `alloc` (the caller-owned allocator, not the arena), so an error path
    // that never returns the list would leak it — the function-scoped errdefer frees it. On the
    // return paths `toOwnedSlice` clears `reversed` first, so this errdefer then sees an empty list
    // (no double-free) and the returned slice is owned by the caller.
    var reversed: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (reversed.items) |id| alloc.free(id);
        reversed.deinit(alloc);
    }

    // Pre-flight: refuse the WHOLE batch up front (changing nothing) on any cheaply-knowable
    // irreversibility — an orphaned row, a lone `up`, or a non-transactional `change` (which would
    // have no tx to undo a partial reverse). Newest-first, so the first refusal names the newest.
    for (selected) |row| {
        const id = stripProv(row.name);
        const m = findMigration(migs, id) orelse return .{ .orphaned = .{ .reversed = &.{}, .id = try alloc.dupe(u8, id) } };
        if (m.down == null and m.change == null) {
            std.log.warn("migrate rollback: '{s}' has only an `up` and no reverse; add a `down` to make it reversible", .{id});
            return .{ .irreversible = .{ .reversed = &.{}, .id = try alloc.dupe(u8, id) } };
        }
        if (!m.transactional and m.down == null) {
            std.log.warn("migrate rollback: '{s}' is `transactional = false` and reverses via a `change`; add an explicit `down` (an auto-reversed `change` needs a transaction to undo a partial reverse)", .{id});
            return .{ .irreversible = .{ .reversed = &.{}, .id = try alloc.dupe(u8, id) } };
        }
    }

    var mig = Migrator{ .db = w, .dialect = db.dbDialect(w), .arena = a, .io = io };

    for (selected) |row| {
        const id = stripProv(row.name);
        const m = findMigration(migs, id).?; // pre-flight established it exists
        // Reverse fn selection (spec §3): explicit `down` runs FORWARD; a bare `change` runs REVERSE.
        const reverse_fn = m.down orelse m.change.?;
        mig.direction = if (m.down != null) .forward else .reverse;

        if (m.transactional) try w.begin();
        reverse_fn(&mig) catch |e| {
            if (m.transactional) w.rollback() catch {};
            // A `change` reversed into an irreversible op (records/raw/.was-less drop → NotReversible;
            // addForeignKey on SQLite → WrongBackend): the tx undid the partial reverse. Report the
            // ids already reversed+committed (newest-first) BEFORE this offender, then name it. Dupe
            // the id FIRST (guarded) so if it OOMs the function-scoped errdefer still frees `reversed`;
            // once `toOwnedSlice` succeeds `reversed` is empty, so that errdefer becomes a no-op.
            if (e == error.MigrationNotReversible or e == error.WrongBackend) {
                const duped_id = try alloc.dupe(u8, id);
                errdefer alloc.free(duped_id);
                const reversed_slice = try reversed.toOwnedSlice(alloc);
                return .{ .irreversible = .{ .reversed = reversed_slice, .id = duped_id } };
            }
            return e; // a genuine DB/IO error — propagate (errdefer frees `reversed`).
        };
        deleteConsumerMigration(&mig, row.name) catch |e| {
            if (m.transactional) w.rollback() catch {};
            return e;
        };
        if (m.transactional) {
            // Match the forward path: undo the open tx if the commit itself fails, so a commit
            // error never leaves a dangling transaction on the pooled writer.
            errdefer w.rollback() catch {};
            try w.commit();
        }

        // Same reasoning as the forward path: a reversal runs raw SQL that can reshape collections
        // without touching the collections.zig primitives. Bump per reversed migration, outside
        // the (optional) transaction so both the transactional and non-transactional arms behave
        // identically. A rollback that moves the counter is still a CHANGE — the observer's
        // predicate is `!=`, not `>`, precisely so a value moving is always noticed.
        try schema_gen.bump(w);
        std.log.info("migrate rollback: reversed migration '{s}'", .{id});
        // Dupe into a guarded local BEFORE appending, so a failing `append` frees the dupe rather
        // than leaking it (the function-scoped errdefer only covers ids already in `reversed`).
        const duped_id = try alloc.dupe(u8, id);
        errdefer alloc.free(duped_id);
        try reversed.append(alloc, duped_id);
    }

    return .{ .ok = try reversed.toOwnedSlice(alloc) };
}

// --- helpers ---

fn nameInSpecs(specs: []const schema.Collection, name: []const u8) bool {
    for (specs) |s| if (std.mem.eql(u8, s.name, name)) return true;
    return false;
}

fn specFieldByName(c: schema.Collection, name: []const u8) ?schema.Field {
    for (c.fields) |f| if (std.mem.eql(u8, f.name, name)) return f;
    return null;
}

/// Order spec indices so every relation target (within the spec set) is created
/// before the collection that references it. Falls back to declaration order for
/// targets outside the spec set or on cycle.
fn topoOrder(alloc: std.mem.Allocator, specs: []const schema.Collection) std.mem.Allocator.Error![]usize {
    const n = specs.len;
    const visited = try alloc.alloc(u8, n); // 0=unseen 1=on-stack 2=done
    // No-op under applySpecs' arena; effective for direct callers with a raw
    // allocator (e.g. the std.testing.allocator leak test).
    defer alloc.free(visited);
    @memset(visited, 0);
    var out: std.ArrayList(usize) = .empty;

    const Walker = struct {
        fn visit(s: []const schema.Collection, vis: []u8, o: *std.ArrayList(usize), a: std.mem.Allocator, i: usize) std.mem.Allocator.Error!void {
            if (vis[i] != 0) return; // done or on-stack (cycle): skip to break the loop
            vis[i] = 1;
            for (s[i].fields) |f| switch (f.options) {
                .relation => |r| {
                    for (s, 0..) |t, ti| {
                        if (ti != i and std.mem.eql(u8, t.name, r.targetCollectionId)) {
                            try visit(s, vis, o, a, ti);
                        }
                    }
                },
                else => {},
            };
            vis[i] = 2;
            try o.append(a, i);
        }
    };
    for (0..n) |i| try Walker.visit(specs, visited, &out, alloc, i);
    return out.toOwnedSlice(alloc);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const migrations = @import("migrations.zig");

test "buildCollections lowers a literal into collection/field specs" {
    const specs = comptime buildCollections(.{
        .users = .{ .type = .auth, .fields = .{
            .{ .name = "display_name", .type = .text },
        }, .rules = .{ .list = "", .view = "" } },
        .listings = .{ .fields = .{
            .{ .name = "title", .type = .text, .required = true },
            .{ .name = "price", .type = .number, .mode = .fixed, .scale = 2 },
            .{ .name = "owner", .type = .relation, .target = "users" },
            .{ .name = "status", .type = .select, .values = .{ "draft", "published" } },
        }, .rules = .{ .list = "status = \"published\"", .update = "@request.auth.id = owner" } },
    });
    try std.testing.expectEqual(@as(usize, 2), specs.len);

    const users = specs[0];
    try std.testing.expectEqualStrings("users", users.name);
    try std.testing.expectEqual(schema.CollectionType.auth, users.type);
    try std.testing.expectEqual(@as(usize, 1), users.fields.len);
    try std.testing.expectEqualStrings("display_name", users.fields[0].name);

    const listings = specs[1];
    try std.testing.expectEqualStrings("listings", listings.name);
    try std.testing.expectEqual(@as(usize, 4), listings.fields.len);
    try std.testing.expect(listings.fields[0].required);
    try std.testing.expectEqual(schema.NumberMode.fixed, listings.fields[1].options.number.mode);
    try std.testing.expectEqual(@as(?u8, 2), listings.fields[1].options.number.scale);
    // relation stores the TARGET NAME at comptime
    try std.testing.expectEqualStrings("users", listings.fields[2].options.relation.targetCollectionId);
    try std.testing.expectEqual(@as(usize, 2), listings.fields[3].options.select.values.len);
    try std.testing.expectEqualStrings("status = \"published\"", listings.listRule.?);
    try std.testing.expectEqualStrings("@request.auth.id = owner", listings.updateRule.?);

    // field ids are stable + 8 chars
    try std.testing.expectEqual(@as(usize, 8), listings.fields[0].id.len);
}

test "unknown-key gate (#103): accepts a spec exercising every recognized key, across all field types" {
    // POSITIVE coverage for the unknown-key @compileError gate: a typo'd key
    // (e.g. `.requied`, `.encrypte`, `.ttl_filed`, `.viewRul`) is now a comptime error
    // instead of a silent no-op. A @compileError cannot be asserted at runtime, so this
    // test instead pins the FULL valid key surface: if a future edit to the gate drops a
    // legitimate key from the allowed set, THIS spec stops compiling and the test fails to
    // build — i.e. it guards against the gate becoming over-strict (a false positive on a
    // valid spec). The negative case (a bad key fails to compile) is verified by building
    // the stock binary + all three examples in CI; see `rejectUnknownKeys`/`rejectUnknownFieldKeys`.
    const specs = comptime buildCollections(.{
        .everything = .{
            .type = .auth,
            .fields = .{
                .{ .name = "t", .type = .text, .required = true, .unique = true, .hidden = true, .min = 1, .max = 10, .pattern = "^x" },
                .{ .name = "secret", .type = .text, .encrypted = true },
                .{ .name = "e", .type = .email },
                .{ .name = "u", .type = .url },
                .{ .name = "rich", .type = .editor },
                .{ .name = "d", .type = .date, .min = "2020-01-01", .max = "2030-01-01" },
                .{ .name = "ad", .type = .autodate, .onCreate = true, .onUpdate = true },
                .{ .name = "flag", .type = .bool },
                .{ .name = "n", .type = .number, .mode = .fixed, .scale = 2, .min = 0, .max = 100 },
                .{ .name = "j", .type = .json, .maxSize = 4096 },
                .{ .name = "sel", .type = .select, .values = .{ "a", "b" }, .maxSelect = 2 },
                .{ .name = "rel", .type = .relation, .target = "everything", .cascadeDelete = true, .minSelect = 0, .maxSelect = 3 },
                .{ .name = "files", .type = .file, .maxSelect = 4, .maxSize = 1024, .mimeTypes = .{"image/png"} },
            },
            .rules = .{ .list = "", .view = "", .create = "", .update = "", .delete = "" },
            .auth = .{ .require_verified = true, .methods = .{ .password = .{} } },
            .indexes = .{
                .{ .name = "idx_t", .fields = .{"t"}, .unique = true },
            },
            .ttl_field = "d",
        },
    });
    try std.testing.expectEqual(@as(usize, 1), specs.len);
    try std.testing.expectEqual(@as(usize, 13), specs[0].fields.len);
}

test "buildCollection lowers .ttl_field naming a date/autodate field into options" {
    const specs = comptime buildCollections(.{
        .sessions = .{ .fields = .{
            .{ .name = "token", .type = .text },
            .{ .name = "expires_at", .type = .date },
        }, .ttl_field = "expires_at" },
        .events = .{ .fields = .{
            .{ .name = "kind", .type = .text },
            .{ .name = "created_at", .type = .autodate },
        }, .ttl_field = "created_at" },
        .plain = .{ .fields = .{
            .{ .name = "title", .type = .text },
        } },
    });
    try std.testing.expect(specs[0].options.ttl_field != null);
    try std.testing.expectEqualStrings("expires_at", specs[0].options.ttl_field.?);
    try std.testing.expect(specs[1].options.ttl_field != null);
    try std.testing.expectEqualStrings("created_at", specs[1].options.ttl_field.?);
    // a collection without .ttl_field leaves it null
    try std.testing.expect(specs[2].options.ttl_field == null);
}

test "buildCollections lowers a large schema without exhausting the comptime branch budget" {
    // Regression: a realistic consumer schema (here 6 collections, ~30 fields)
    // must lower at comptime without tripping Zig's default 1000 backward-branch
    // eval quota. There is no consumer-side workaround (@setEvalBranchQuota in the
    // caller does not propagate into this lazily-evaluated decl), so buildCollections
    // must raise its own budget. Keep this above the per-call default to stay a guard.
    const specs = comptime buildCollections(.{
        .users = .{ .type = .auth, .fields = .{
            .{ .name = "display_name", .type = .text },
            .{ .name = "bio", .type = .text },
            .{ .name = "avatar", .type = .file },
        } },
        .listings = .{ .fields = .{
            .{ .name = "title", .type = .text, .required = true },
            .{ .name = "summary", .type = .text },
            .{ .name = "price", .type = .number, .mode = .fixed, .scale = 2 },
            .{ .name = "owner", .type = .relation, .target = "users" },
            .{ .name = "status", .type = .select, .values = .{ "draft", "published" } },
        } },
        .bookings = .{ .fields = .{
            .{ .name = "listing", .type = .relation, .target = "listings" },
            .{ .name = "guest", .type = .relation, .target = "users" },
            .{ .name = "start_at", .type = .date },
            .{ .name = "end_at", .type = .date },
            .{ .name = "price_total", .type = .number, .mode = .fixed, .scale = 2 },
            .{ .name = "status", .type = .select, .values = .{ "pending", "confirmed", "cancelled" } },
        } },
        .reviews = .{ .fields = .{
            .{ .name = "booking", .type = .relation, .target = "bookings" },
            .{ .name = "author", .type = .relation, .target = "users" },
            .{ .name = "rating", .type = .number },
            .{ .name = "body", .type = .text },
        } },
        .comments = .{ .fields = .{
            .{ .name = "review", .type = .relation, .target = "reviews" },
            .{ .name = "author", .type = .relation, .target = "users" },
            .{ .name = "body", .type = .text },
        } },
        .audits = .{ .fields = .{
            .{ .name = "actor", .type = .relation, .target = "users" },
            .{ .name = "action", .type = .text },
            .{ .name = "detail", .type = .text },
            .{ .name = "at", .type = .date },
        } },
    });
    try std.testing.expectEqual(@as(usize, 6), specs.len);
    try std.testing.expectEqualStrings("audits", specs[5].name);
    try std.testing.expectEqual(@as(usize, 8), specs[5].fields[0].id.len);
}

test "stable field ids are deterministic and collision-distinct" {
    const a = comptime stableFieldId("posts", "title");
    const b = comptime stableFieldId("posts", "title");
    const c = comptime stableFieldId("posts", "body");
    try std.testing.expectEqualStrings(a, b);
    try std.testing.expect(!std.mem.eql(u8, a, c));
}

test "topoOrder places relation targets before dependents" {
    const a = std.testing.allocator;
    const lf = [_]schema.Field{.{ .id = "r", .name = "owner", .options = .{ .relation = .{ .targetCollectionId = "users", .maxSelect = 1 } } }};
    const specs = [_]schema.Collection{
        .{ .id = "", .name = "listings", .fields = &lf },
        .{ .id = "", .name = "users", .fields = &.{} },
    };
    const order = try topoOrder(a, &specs);
    defer a.free(order);
    // users (idx 1) must come before listings (idx 0)
    try std.testing.expectEqual(@as(usize, 2), order.len);
    var pos_users: usize = 0;
    var pos_listings: usize = 0;
    for (order, 0..) |idx, p| {
        if (idx == 1) pos_users = p;
        if (idx == 0) pos_listings = p;
    }
    try std.testing.expect(pos_users < pos_listings);
}

test "topoOrder is leak-free (std.testing.allocator)" {
    // std.testing.allocator is a leak-detecting allocator; this test would fail
    // before the defer alloc.free(visited) fix was applied.
    const lf = [_]schema.Field{.{ .id = "r", .name = "owner", .options = .{ .relation = .{ .targetCollectionId = "users", .maxSelect = 1 } } }};
    const specs = [_]schema.Collection{
        .{ .id = "", .name = "listings", .fields = &lf },
        .{ .id = "", .name = "users", .fields = &.{} },
    };
    const order = try topoOrder(std.testing.allocator, &specs);
    defer std.testing.allocator.free(order);
    try std.testing.expectEqual(@as(usize, 2), order.len);
}

test "applySpecs provisions collections + name-based relation resolves to target id; idempotent" {
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    const a = std.testing.allocator;

    const lf = [_]schema.Field{
        .{ .id = "f_owner", .name = "owner", .options = .{ .relation = .{ .targetCollectionId = "users", .maxSelect = 1 } } },
    };
    const uf = [_]schema.Field{.{ .id = "f_dn", .name = "display_name", .options = .{ .text = .{} } }};
    const specs = [_]schema.Collection{
        .{ .id = "", .name = "listings", .fields = &lf },
        .{ .id = "", .name = "users", .type = .auth, .fields = &uf },
    };

    try applySpecs(a, std.testing.io, &d, &specs);

    const users = (try collections.get(a, &d, "users")).?;
    defer users.deinit(a);
    const listings = (try collections.get(a, &d, "listings")).?;
    defer listings.deinit(a);
    try std.testing.expectEqual(schema.CollectionType.auth, users.type);
    // the relation's stored targetCollectionId equals the users collection's id
    const owner = schema.fieldByName(listings, "owner").?;
    try std.testing.expectEqualStrings(users.id, owner.options.relation.targetCollectionId);

    // physical FK works: insert a user, then a listing referencing it
    try d.exec("INSERT INTO \"users\" (\"id\",\"created\",\"updated\") VALUES ('u1','','');");
    try d.exec("INSERT INTO \"listings\" (\"id\",\"created\",\"updated\",\"owner\") VALUES ('l1','','','u1');");

    // re-provision: clean no-op (no error, no duplicate collection)
    try applySpecs(a, std.testing.io, &d, &specs);
    const all = try collections.list(a, &d);
    defer {
        for (all) |c| c.deinit(a);
        a.free(all);
    }
    var listings_count: usize = 0;
    for (all) |c| if (std.mem.eql(u8, c.name, "listings")) {
        listings_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), listings_count);
}

test "applySpecs additively adds a new field (auto-migration), preserving data" {
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    const a = std.testing.allocator;

    const v1 = [_]schema.Field{.{ .id = "f_title", .name = "title", .options = .{ .text = .{} } }};
    const s1 = [_]schema.Collection{.{ .id = "", .name = "posts", .fields = &v1 }};
    try applySpecs(a, std.testing.io, &d, &s1);
    try d.exec("INSERT INTO \"posts\" (\"id\",\"created\",\"updated\",\"title\") VALUES ('p1','','','hello');");

    // v2 adds a `views` field
    const v2 = [_]schema.Field{
        .{ .id = "f_title", .name = "title", .options = .{ .text = .{} } },
        .{ .id = "f_views", .name = "views", .options = .{ .number = .{ .mode = .int } } },
    };
    const s2 = [_]schema.Collection{.{ .id = "", .name = "posts", .fields = &v2 }};
    try applySpecs(a, std.testing.io, &d, &s2);

    var st = try d.prepare("SELECT title, views FROM \"posts\" WHERE id='p1';");
    defer st.finalize();
    try std.testing.expect(try st.step());
    try std.testing.expectEqualStrings("hello", st.columnText(0)); // data preserved
    try std.testing.expect(st.isNull(1)); // new column, null for old row
}

test "applySpecs persists a ttl_field added to an existing collection (then GC reaps)" {
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    const a = std.testing.allocator;

    // v1: a collection with a date field but NO ttl_field.
    const fields = [_]schema.Field{
        .{ .id = "f_tok", .name = "token", .options = .{ .text = .{} } },
        .{ .id = "f_exp", .name = "expires_at", .options = .{ .date = .{} } },
    };
    const s1 = [_]schema.Collection{.{ .id = "", .name = "sessions", .fields = &fields }};
    try applySpecs(a, std.testing.io, &d, &s1);
    try d.exec("INSERT INTO \"sessions\" (\"id\",\"created\",\"updated\",\"token\",\"expires_at\") VALUES ('s1','','','t','2000-01-01T00:00:00Z');");

    // Before: ttl_field not set, GC reaps nothing.
    {
        const before = (try collections.get(a, &d, "sessions")).?;
        defer before.deinit(a);
        try std.testing.expect(before.options.ttl_field == null);
    }
    try std.testing.expectEqual(@as(usize, 0), try @import("records.zig").gcExpiredRecords(a, &d));

    // v2: same fields, now declaring .ttl_field — must be persisted by re-provisioning.
    const s2 = [_]schema.Collection{.{ .id = "", .name = "sessions", .fields = &fields, .options = .{ .ttl_field = "expires_at" } }};
    try applySpecs(a, std.testing.io, &d, &s2);

    // The persisted options blob now carries the ttl_field...
    const live = (try collections.get(a, &d, "sessions")).?;
    defer live.deinit(a);
    try std.testing.expect(live.options.ttl_field != null);
    try std.testing.expectEqualStrings("expires_at", live.options.ttl_field.?);

    // ...and the GC now reaps the expired row.
    try std.testing.expectEqual(@as(usize, 1), try @import("records.zig").gcExpiredRecords(a, &d));
    var st = try d.prepare("SELECT COUNT(*) FROM \"sessions\";");
    defer st.finalize();
    _ = try st.step();
    try std.testing.expectEqual(@as(i64, 0), st.columnInt(0));
}

test "applySpecs persists a TIGHTENED access rule on an existing collection" {
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    const a = std.testing.allocator;

    const fields = [_]schema.Field{.{ .id = "f_title", .name = "title", .options = .{ .text = .{} } }};
    // v1 is wide open.
    const s1 = [_]schema.Collection{
        .{ .id = "", .name = "posts", .fields = &fields, .listRule = "@public", .viewRule = "@public" },
    };
    try applySpecs(a, std.testing.io, &d, &s1);

    // v2 tightens both rules and changes NOTHING else — the exact shape of a developer
    // closing a hole in their comptime `.collections` literal and redeploying.
    const tightened = "@request.auth.id != \"\"";
    const s2 = [_]schema.Collection{
        .{ .id = "", .name = "posts", .fields = &fields, .listRule = tightened, .viewRule = tightened },
    };
    try applySpecs(a, std.testing.io, &d, &s2);

    // policy.zig enforces from the collection loaded out of _collections, NOT from the
    // comptime literal — so the persisted ROW is what has to change.
    const live = (try collections.get(a, &d, "posts")).?;
    defer live.deinit(a);
    try std.testing.expectEqualStrings(tightened, live.listRule.?);
    try std.testing.expectEqualStrings(tightened, live.viewRule.?);
    // The metadata-only write must leave the rest of the row alone.
    try std.testing.expect(schema.fieldByName(live, "title") != null);
    try std.testing.expect(live.createRule == null);
}

test "applySpecs persists a rule change WITHOUT rebuilding the physical table" {
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    const a = std.testing.allocator;

    const fields = [_]schema.Field{.{ .id = "f_title", .name = "title", .options = .{ .text = .{} } }};
    const s1 = [_]schema.Collection{.{ .id = "", .name = "posts", .fields = &fields, .listRule = "@public" }};
    try applySpecs(a, std.testing.io, &d, &s1);
    try d.exec("INSERT INTO \"posts\" (\"id\",\"created\",\"updated\",\"title\") VALUES ('p1','','','hello');");

    // A hand-made index the provisioner knows nothing about. `collections.update` always runs
    // ddl.rebuildPlan (CREATE "posts__new" + INSERT…SELECT the whole table + DROP TABLE +
    // RENAME), which re-creates only the indexes IT knows about — so this index's survival is
    // the probe that a rule-only change ran no DDL at all.
    try d.exec("CREATE INDEX \"idx_probe_title\" ON \"posts\" (\"title\");");

    const s2 = [_]schema.Collection{
        .{ .id = "", .name = "posts", .fields = &fields, .listRule = "@request.auth.id != \"\"" },
    };
    try applySpecs(a, std.testing.io, &d, &s2);

    const live = (try collections.get(a, &d, "posts")).?;
    defer live.deinit(a);
    try std.testing.expectEqualStrings("@request.auth.id != \"\"", live.listRule.?);

    var idx = try d.prepare("SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name='idx_probe_title';");
    defer idx.finalize();
    _ = try idx.step();
    try std.testing.expectEqual(@as(i64, 1), idx.columnInt(0));

    // and the row is still there (a rebuild would have copied it, but a DROP-less path proves
    // the cheap route was taken rather than the expensive-but-correct one)
    var rows = try d.prepare("SELECT COUNT(*) FROM \"posts\";");
    defer rows.finalize();
    _ = try rows.step();
    try std.testing.expectEqual(@as(i64, 1), rows.columnInt(0));
}

test "applySpecs does not rewrite _collections when the rules are unchanged (null == empty)" {
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    const a = std.testing.allocator;

    const fields = [_]schema.Field{.{ .id = "f_title", .name = "title", .options = .{ .text = .{} } }};
    // v1 leaves every rule unspecified — persisted as SQL NULL.
    const s1 = [_]schema.Collection{.{ .id = "", .name = "posts", .fields = &fields }};
    try applySpecs(a, std.testing.io, &d, &s1);
    try d.exec("UPDATE \"_collections\" SET \"updated\"='SENTINEL' WHERE \"name\"='posts';");

    // v2 spells every rule "" — the SAME rule as null (both mean Locked: superusers only), but
    // persisted DISTINCTLY by bindOptText. A differ comparing them literally would rewrite the
    // row on every single boot.
    const s2 = [_]schema.Collection{.{
        .id = "",
        .name = "posts",
        .fields = &fields,
        .listRule = "",
        .viewRule = "",
        .createRule = "",
        .updateRule = "",
        .deleteRule = "",
    }};
    try applySpecs(a, std.testing.io, &d, &s2);

    const live = (try collections.get(a, &d, "posts")).?;
    defer live.deinit(a);
    try std.testing.expectEqualStrings("SENTINEL", live.updated);
}

test "applySpecs logs+skips a destructive type change (does not destroy data)" {
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    const a = std.testing.allocator;

    const v1 = [_]schema.Field{.{ .id = "f_n", .name = "n", .options = .{ .text = .{} } }};
    const s1 = [_]schema.Collection{.{ .id = "", .name = "items", .fields = &v1 }};
    try applySpecs(a, std.testing.io, &d, &s1);
    try d.exec("INSERT INTO \"items\" (\"id\",\"created\",\"updated\",\"n\") VALUES ('i1','','','keepme');");

    // v2 changes `n` text -> number (REAL): a destructive retype, must be skipped
    const v2 = [_]schema.Field{.{ .id = "f_n", .name = "n", .options = .{ .number = .{ .mode = .float } } }};
    const s2 = [_]schema.Collection{.{ .id = "", .name = "items", .fields = &v2 }};
    try applySpecs(a, std.testing.io, &d, &s2);

    // the column was NOT retyped/rebuilt: original text value survives
    var st = try d.prepare("SELECT n FROM \"items\" WHERE id='i1';");
    defer st.finalize();
    try std.testing.expect(try st.step());
    try std.testing.expectEqualStrings("keepme", st.columnText(0));
    // and the live schema still reports text (skip preserved it)
    const live = (try collections.get(a, &d, "items")).?;
    defer live.deinit(a);
    try std.testing.expectEqual(schema.FieldType.text, schema.fieldByName(live, "n").?.fieldType());
}

test "applySpecs rejects an unknown relation target" {
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    const a = std.testing.allocator;
    const lf = [_]schema.Field{.{ .id = "f_o", .name = "owner", .options = .{ .relation = .{ .targetCollectionId = "ghosts", .maxSelect = 1 } } }};
    const specs = [_]schema.Collection{.{ .id = "", .name = "listings", .fields = &lf }};
    try std.testing.expectError(error.UnknownRelationTarget, applySpecs(a, std.testing.io, &d, &specs));
}

test "applySpecs provisions a self-relation; idempotent re-provision is a no-op" {
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    const a = std.testing.allocator;

    // Self-relation: authors.mentor -> authors (a field referencing its own collection).
    const af = [_]schema.Field{
        .{ .id = "f_nm", .name = "name", .options = .{ .text = .{} } },
        .{ .id = "f_mentor", .name = "mentor", .options = .{ .relation = .{ .targetCollectionId = "authors", .maxSelect = 1 } } },
    };
    const specs = [_]schema.Collection{
        .{ .id = "", .name = "authors", .fields = &af },
    };

    // First provision: self-relation on a newly created collection must succeed.
    try applySpecs(a, std.testing.io, &d, &specs);

    const authors = (try collections.get(a, &d, "authors")).?;
    defer authors.deinit(a);
    // The relation field survives and references the collection (by name or id — both are valid).
    const mentor = schema.fieldByName(authors, "mentor").?;
    // Self-relations store the target as the collection name or id (both resolve correctly via collections.get).
    try std.testing.expect(
        std.mem.eql(u8, mentor.options.relation.targetCollectionId, authors.name) or
            std.mem.eql(u8, mentor.options.relation.targetCollectionId, authors.id),
    );

    // Physical FK works: insert a row, then a row referencing it via self-relation.
    try d.exec("INSERT INTO \"authors\" (\"id\",\"created\",\"updated\",\"name\") VALUES ('a1','','','Ada');");
    try d.exec("INSERT INTO \"authors\" (\"id\",\"created\",\"updated\",\"name\",\"mentor\") VALUES ('a2','','','Grace','a1');");

    // Re-provision: clean no-op (no error, no duplicate collection).
    try applySpecs(a, std.testing.io, &d, &specs);
    const all = try collections.list(a, &d);
    defer {
        for (all) |c| c.deinit(a);
        a.free(all);
    }
    var authors_count: usize = 0;
    for (all) |c| if (std.mem.eql(u8, c.name, "authors")) {
        authors_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), authors_count);
}

test "buildOptions accepts a valid comptime pattern and date bounds" {
    const cols = comptime buildCollections(.{
        .events = .{
            .fields = .{
                .{ .name = "slug", .type = .text, .pattern = "^[a-z-]+$" },
                .{ .name = "happens", .type = .date, .min = "2026-01-01", .max = "2026-12-31 23:59:59" },
            },
        },
    });
    try std.testing.expectEqual(@as(usize, 1), cols.len);
}

test "buildCollections lowers the dating-app fixture schema (every field type + capability)" {
    // SP2.1b Task 6: prove buildCollections accepts the full dating-app literal with every
    // field type and option combination. This acts as the comptime guard for fixtures/dating/schema.zig.
    const cols = comptime buildCollections(.{
        .profiles = .{
            .type = .auth,
            .fields = .{
                .{ .name = "name", .type = .text },
                .{ .name = "bio", .type = .editor },
                .{ .name = "website", .type = .url },
                .{ .name = "age", .type = .number, .mode = .int },
                .{ .name = "gender", .type = .select, .values = .{ "female", "male", "nonbinary", "other" } },
                .{ .name = "avatar", .type = .file },
            },
        },
        .tags = .{
            .fields = .{
                .{ .name = "label", .type = .text, .required = true, .unique = true },
            },
        },
        .photos = .{
            .fields = .{
                .{ .name = "owner", .type = .relation, .target = "profiles" },
                .{ .name = "image", .type = .file },
                .{ .name = "visibility", .type = .select, .values = .{ "public", "private" } },
                .{ .name = "caption", .type = .text },
                .{ .name = "tags", .type = .relation, .target = "tags", .maxSelect = 20 },
            },
        },
        .messages = .{
            .fields = .{
                .{ .name = "from", .type = .relation, .target = "profiles" },
                .{ .name = "to", .type = .relation, .target = "profiles" },
                .{ .name = "body", .type = .text, .required = true },
                .{ .name = "sentAt", .type = .autodate, .onCreate = true },
                .{ .name = "read", .type = .bool },
            },
        },
        .winks = .{
            .fields = .{
                .{ .name = "from", .type = .relation, .target = "profiles" },
                .{ .name = "to", .type = .relation, .target = "profiles" },
                .{ .name = "createdAt", .type = .autodate, .onCreate = true },
            },
        },
        .subscriptions = .{
            .fields = .{
                .{ .name = "profile", .type = .relation, .target = "profiles" },
                .{ .name = "plan", .type = .select, .values = .{ "free", "plus", "premium" } },
                .{ .name = "price", .type = .number, .mode = .fixed, .scale = 2 },
                .{ .name = "renewsAt", .type = .date, .min = "2020-01-01", .max = "2099-12-31" },
                .{ .name = "active", .type = .bool },
                .{ .name = "metadata", .type = .json },
            },
        },
    });

    // 6 collections
    try std.testing.expectEqual(@as(usize, 6), cols.len);

    // Verify collection names (topo order may differ; find by scan)
    const findCol = struct {
        fn find(cs: []const schema.Collection, n: []const u8) ?schema.Collection {
            for (cs) |c| if (std.mem.eql(u8, c.name, n)) return c;
            return null;
        }
    }.find;

    const profiles = findCol(cols, "profiles").?;
    try std.testing.expectEqual(schema.CollectionType.auth, profiles.type);
    try std.testing.expectEqual(@as(usize, 6), profiles.fields.len);
    // auth collection: verify field types
    try std.testing.expectEqual(schema.FieldType.text, profiles.fields[0].fieldType());
    try std.testing.expectEqual(schema.FieldType.editor, profiles.fields[1].fieldType());
    try std.testing.expectEqual(schema.FieldType.url, profiles.fields[2].fieldType());
    try std.testing.expectEqual(schema.NumberMode.int, profiles.fields[3].options.number.mode);
    try std.testing.expectEqual(@as(usize, 4), profiles.fields[4].options.select.values.len);
    try std.testing.expectEqual(schema.FieldType.file, profiles.fields[5].fieldType());

    const tags = findCol(cols, "tags").?;
    try std.testing.expectEqual(@as(usize, 1), tags.fields.len);
    try std.testing.expect(tags.fields[0].unique);

    const photos = findCol(cols, "photos").?;
    try std.testing.expectEqual(@as(usize, 5), photos.fields.len);
    // photos.tags is a multi-relation (maxSelect = 20)
    try std.testing.expectEqual(@as(u32, 20), photos.fields[4].options.relation.maxSelect);

    const messages = findCol(cols, "messages").?;
    try std.testing.expectEqual(@as(usize, 5), messages.fields.len);
    // two relations to the same target
    try std.testing.expectEqualStrings("profiles", messages.fields[0].options.relation.targetCollectionId);
    try std.testing.expectEqualStrings("profiles", messages.fields[1].options.relation.targetCollectionId);
    try std.testing.expectEqual(schema.FieldType.autodate, messages.fields[3].fieldType());
    try std.testing.expect(messages.fields[3].options.autodate.onCreate);
    try std.testing.expectEqual(schema.FieldType.bool, messages.fields[4].fieldType());

    const winks = findCol(cols, "winks").?;
    try std.testing.expectEqual(@as(usize, 3), winks.fields.len);

    const subscriptions = findCol(cols, "subscriptions").?;
    try std.testing.expectEqual(@as(usize, 6), subscriptions.fields.len);
    try std.testing.expectEqual(schema.NumberMode.fixed, subscriptions.fields[2].options.number.mode);
    try std.testing.expectEqual(@as(?u8, 2), subscriptions.fields[2].options.number.scale);
    try std.testing.expectEqualStrings("2020-01-01", subscriptions.fields[3].options.date.min.?);
    try std.testing.expectEqualStrings("2099-12-31", subscriptions.fields[3].options.date.max.?);
    try std.testing.expectEqual(schema.FieldType.json, subscriptions.fields[5].fieldType());
}

test "runMigrations runs each explicit migration once (idempotent)" {
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    const a = std.testing.allocator;

    const M = struct {
        var calls: usize = 0;
        fn up(m: *Migrator) anyerror!void {
            calls += 1;
            try m.execLowered("CREATE TABLE IF NOT EXISTS \"prov_demo\" (\"x\" TEXT);");
        }
    };
    M.calls = 0;
    const migs = [_]Migration{.{ .id = "0001_demo", .up = M.up }};
    try runMigrations(a, std.testing.io, &d, &migs);
    try runMigrations(a, std.testing.io, &d, &migs);
    try std.testing.expectEqual(@as(usize, 1), M.calls);
}

test "runMigrations applies a change-migration forward (schema effect present)" {
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    const a = std.testing.allocator;

    const M = struct {
        fn change(m: *Migrator) anyerror!void {
            // Runs in FORWARD mode → createTable creates (not drops).
            try std.testing.expectEqual(Migrator.Direction.forward, m.direction);
            try m.createTable("widgets", &[_]Migrator.Col{
                .{ .name = "id", .type = .integer, .pk = true, .null = false },
                .{ .name = "name", .type = .text },
            });
        }
    };
    const migs = [_]Migration{.{ .id = "0001_widgets", .change = M.change }};
    try runMigrations(a, std.testing.io, &d, &migs);

    // The forward change created the table.
    var st = try d.prepare("SELECT 1 FROM \"widgets\" LIMIT 0;");
    st.finalize();
}

test "runMigrations honors .transactional = false (no wrapping tx)" {
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    const a = std.testing.allocator;

    // VACUUM cannot run inside a transaction. It succeeds ONLY because a `.transactional = false`
    // migration is applied without the wrapping BEGIN/COMMIT.
    const M = struct {
        fn up(m: *Migrator) anyerror!void {
            try m.exec("VACUUM;");
        }
    };
    try runMigrations(a, std.testing.io, &d, &[_]Migration{.{ .id = "0001_vac", .up = M.up, .transactional = false }});

    // The SAME op as a default (transactional) migration fails: VACUUM inside a tx is rejected —
    // proving the opt-out is what let it run above.
    if (runMigrations(a, std.testing.io, &d, &[_]Migration{.{ .id = "0002_vac", .up = M.up }})) |_| {
        return error.TestExpectedTxVacuumToFail;
    } else |_| {}
}

test "runMigrations: legacy { id, up } is unaffected (backward-compat)" {
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    const a = std.testing.allocator;

    const M = struct {
        var calls: usize = 0;
        fn up(m: *Migrator) anyerror!void {
            calls += 1;
            try m.execLowered("CREATE TABLE IF NOT EXISTS \"legacy_demo\" (\"x\" TEXT);");
        }
    };
    M.calls = 0;
    // A default (transactional=true) up-only migration applies once, inside a wrapping tx, exactly
    // as before the change/down/transactional fields existed.
    const migs = [_]Migration{.{ .id = "0001_legacy", .up = M.up }};
    try runMigrations(a, std.testing.io, &d, &migs);
    try runMigrations(a, std.testing.io, &d, &migs);
    try std.testing.expectEqual(@as(usize, 1), M.calls);
    var st = try d.prepare("SELECT 1 FROM \"legacy_demo\" LIMIT 0;");
    st.finalize();
}

test "appliedConsumerMigrations returns applied prov: rows in apply (id) order" {
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    const a = std.testing.allocator;

    const M = struct {
        fn up(m: *Migrator) anyerror!void {
            try m.execLowered("SELECT 1;"); // trivial, effect-free
        }
    };
    // Apply three in order; the ledger's autoinc id preserves apply order regardless of name.
    const migs = [_]Migration{
        .{ .id = "0003_c", .up = M.up },
        .{ .id = "0001_a", .up = M.up },
        .{ .id = "0002_b", .up = M.up },
    };
    try runMigrations(a, std.testing.io, &d, &migs);

    const applied = try appliedConsumerMigrations(a, &d);
    defer freeAppliedMigrations(a, applied);
    try std.testing.expectEqual(@as(usize, 3), applied.len);
    // Apply order, NOT declared/alphabetical: 0003_c was recorded first.
    try std.testing.expectEqualStrings("prov:0003_c", applied[0].name);
    try std.testing.expectEqualStrings("prov:0001_a", applied[1].name);
    try std.testing.expectEqualStrings("prov:0002_b", applied[2].name);
    try std.testing.expect(applied[0].applied_at.len > 0);
}

test "migrationStatus computes applied / pending / orphaned buckets" {
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    const a = std.testing.allocator;

    const M = struct {
        fn up(m: *Migrator) anyerror!void {
            try m.execLowered("SELECT 1;");
        }
    };
    // Apply only the first of two declared migrations.
    try runMigrations(a, std.testing.io, &d, &[_]Migration{.{ .id = "0001_a", .up = M.up }});
    // Inject an orphaned ledger row: a prov: migration NOT in the compiled-in set.
    try d.exec("INSERT INTO \"_migrations\" (\"name\",\"applied_at\") VALUES ('prov:9999_gone', datetime('now'));");

    // Declared set: 0001_a (applied) + 0002_b (pending). 9999_gone is orphaned.
    const declared = [_]Migration{
        .{ .id = "0001_a", .up = M.up },
        .{ .id = "0002_b", .up = M.up },
    };
    const status = try migrationStatus(a, &d, &declared);
    defer status.deinit(a);

    try std.testing.expectEqual(@as(usize, 1), status.applied_count);
    try std.testing.expectEqual(@as(usize, 1), status.pending_count);
    try std.testing.expectEqual(@as(usize, 2), status.declared.len);
    // Declared order preserved: [0] applied, [1] pending.
    try std.testing.expectEqualStrings("0001_a", status.declared[0].id);
    try std.testing.expect(status.declared[0].applied_at != null);
    try std.testing.expectEqualStrings("0002_b", status.declared[1].id);
    try std.testing.expect(status.declared[1].applied_at == null);
    // The orphan is bucketed separately, with its bare id (prov: stripped).
    try std.testing.expectEqual(@as(usize, 1), status.orphaned.len);
    try std.testing.expectEqualStrings("9999_gone", status.orphaned[0].name);
}

test "migrationStatus: empty declared set with no ledger rows is all-zero" {
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    const a = std.testing.allocator;
    const status = try migrationStatus(a, &d, &[_]Migration{});
    defer status.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), status.applied_count);
    try std.testing.expectEqual(@as(usize, 0), status.pending_count);
    try std.testing.expectEqual(@as(usize, 0), status.orphaned.len);
    try std.testing.expectEqual(@as(usize, 0), status.declared.len);
}

// --- rollback (B2) test helpers ---

fn tableExistsDb(d: *db.Db, alloc: std.mem.Allocator, name: []const u8) !bool {
    const qtbl = try ddl.quoteIdent(alloc, name);
    defer alloc.free(qtbl);
    const sql = try std.fmt.allocPrintSentinel(alloc, "SELECT 1 FROM {s} LIMIT 0;", .{qtbl}, 0);
    defer alloc.free(sql);
    var st = d.prepare(sql) catch return false;
    st.finalize();
    return true;
}

fn ledgerHas(d: *db.Db, alloc: std.mem.Allocator, name: []const u8) !bool {
    const sql = try std.fmt.allocPrintSentinel(alloc, "SELECT 1 FROM \"_migrations\" WHERE \"name\" = '{s}';", .{name}, 0);
    defer alloc.free(sql);
    var st = try d.prepare(sql);
    defer st.finalize();
    return try st.step();
}

test "rollbackMigrations: reverses createTable + a separate addColumn (newest-first); ledger cleared; re-applies" {
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    const a = std.testing.allocator;

    // Two migrations: create the table, then add a column in a LATER migration. Rolling both back
    // newest-first reverses the addColumn (dropColumn) before the createTable (dropTable) — the
    // correct order comes from processing migrations newest-first (intra-change op order is NOT
    // reversed by the DSL, so dependent ops live in separate migrations).
    const M = struct {
        fn createT(m: *Migrator) anyerror!void {
            try m.createTable("gadgets", &[_]Migrator.Col{.{ .name = "id", .type = .integer, .pk = true, .null = false }});
        }
        fn addCol(m: *Migrator) anyerror!void {
            try m.addColumn("gadgets", .{ .name = "label", .type = .text });
        }
    };
    const migs = [_]Migration{
        .{ .id = "0001_gadgets", .change = M.createT },
        .{ .id = "0002_label", .change = M.addCol },
    };
    try runMigrations(a, std.testing.io, &d, &migs);
    try std.testing.expect(try tableExistsDb(&d, a, "gadgets"));
    try std.testing.expect(try ledgerHas(&d, a, "prov:0002_label"));

    const outcome = try rollbackMigrations(a, std.testing.io, &d, &migs, 2);
    defer outcome.deinit(a);
    try std.testing.expect(outcome == .ok);
    try std.testing.expectEqual(@as(usize, 2), outcome.ok.len);
    try std.testing.expectEqualStrings("0002_label", outcome.ok[0]);
    try std.testing.expectEqualStrings("0001_gadgets", outcome.ok[1]);
    // Table gone, both ledger rows gone.
    try std.testing.expect(!try tableExistsDb(&d, a, "gadgets"));
    try std.testing.expect(!try ledgerHas(&d, a, "prov:0001_gadgets"));
    try std.testing.expect(!try ledgerHas(&d, a, "prov:0002_label"));

    // Forward-apply again works (idempotent ledger): the table comes back.
    try runMigrations(a, std.testing.io, &d, &migs);
    try std.testing.expect(try tableExistsDb(&d, a, "gadgets"));
}

test "rollbackMigrations: rollback N reverses the N newest, newest-first; the rest remain" {
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    const a = std.testing.allocator;

    const M = struct {
        fn a_(m: *Migrator) anyerror!void {
            try m.createTable("t_a", &[_]Migrator.Col{.{ .name = "id", .type = .integer, .pk = true, .null = false }});
        }
        fn b_(m: *Migrator) anyerror!void {
            try m.createTable("t_b", &[_]Migrator.Col{.{ .name = "id", .type = .integer, .pk = true, .null = false }});
        }
        fn c_(m: *Migrator) anyerror!void {
            try m.createTable("t_c", &[_]Migrator.Col{.{ .name = "id", .type = .integer, .pk = true, .null = false }});
        }
    };
    const migs = [_]Migration{
        .{ .id = "0001_a", .change = M.a_ },
        .{ .id = "0002_b", .change = M.b_ },
        .{ .id = "0003_c", .change = M.c_ },
    };
    try runMigrations(a, std.testing.io, &d, &migs);

    const outcome = try rollbackMigrations(a, std.testing.io, &d, &migs, 2);
    defer outcome.deinit(a);
    try std.testing.expect(outcome == .ok);
    // Newest first: 0003_c then 0002_b.
    try std.testing.expectEqual(@as(usize, 2), outcome.ok.len);
    try std.testing.expectEqualStrings("0003_c", outcome.ok[0]);
    try std.testing.expectEqualStrings("0002_b", outcome.ok[1]);
    // The two newest tables are gone; the oldest remains.
    try std.testing.expect(try tableExistsDb(&d, a, "t_a"));
    try std.testing.expect(!try tableExistsDb(&d, a, "t_b"));
    try std.testing.expect(!try tableExistsDb(&d, a, "t_c"));
    // Ledger reflects only 0001_a still applied.
    try std.testing.expect(try ledgerHas(&d, a, "prov:0001_a"));
    try std.testing.expect(!try ledgerHas(&d, a, "prov:0002_b"));
    try std.testing.expect(!try ledgerHas(&d, a, "prov:0003_c"));
}

test "rollbackMigrations: N exceeding applied count rolls back all applied (min(N, applied))" {
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    const a = std.testing.allocator;

    const M = struct {
        fn change(m: *Migrator) anyerror!void {
            try m.createTable("solo", &[_]Migrator.Col{.{ .name = "id", .type = .integer, .pk = true, .null = false }});
        }
    };
    const migs = [_]Migration{.{ .id = "0001_solo", .change = M.change }};
    try runMigrations(a, std.testing.io, &d, &migs);

    const outcome = try rollbackMigrations(a, std.testing.io, &d, &migs, 99);
    defer outcome.deinit(a);
    try std.testing.expect(outcome == .ok);
    try std.testing.expectEqual(@as(usize, 1), outcome.ok.len);
    try std.testing.expect(!try tableExistsDb(&d, a, "solo"));
}

test "rollbackMigrations: a lone `up` migration is refused up front, changing nothing" {
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    const a = std.testing.allocator;

    const M = struct {
        fn up(m: *Migrator) anyerror!void {
            try m.execLowered("CREATE TABLE \"only_up\" (\"x\" TEXT);");
        }
    };
    const migs = [_]Migration{.{ .id = "0001_only_up", .up = M.up }};
    try runMigrations(a, std.testing.io, &d, &migs);

    const outcome = try rollbackMigrations(a, std.testing.io, &d, &migs, 1);
    defer outcome.deinit(a);
    try std.testing.expect(outcome == .irreversible);
    try std.testing.expectEqualStrings("0001_only_up", outcome.irreversible.id);
    // Pre-flight refusal: nothing was reversed before the offender.
    try std.testing.expectEqual(@as(usize, 0), outcome.irreversible.reversed.len);
    // Nothing changed: table intact, ledger row intact.
    try std.testing.expect(try tableExistsDb(&d, a, "only_up"));
    try std.testing.expect(try ledgerHas(&d, a, "prov:0001_only_up"));
}

test "rollbackMigrations: a `change` reversing into raw() is refused; its tx undoes the partial reverse" {
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    const a = std.testing.allocator;

    // Forward: create a table, then a raw statement. Reverse re-runs the change inverted — it drops
    // the table (partial) then hits raw(), which has no inverse → the tx must restore the table.
    const M = struct {
        fn change(m: *Migrator) anyerror!void {
            try m.createTable("mixed", &[_]Migrator.Col{.{ .name = "id", .type = .integer, .pk = true, .null = false }});
            try m.raw(.{ .sqlite = "SELECT 1;", .postgres = "SELECT 1;" });
        }
    };
    const migs = [_]Migration{.{ .id = "0001_mixed", .change = M.change }};
    try runMigrations(a, std.testing.io, &d, &migs);

    const outcome = try rollbackMigrations(a, std.testing.io, &d, &migs, 1);
    defer outcome.deinit(a);
    try std.testing.expect(outcome == .irreversible);
    try std.testing.expectEqualStrings("0001_mixed", outcome.irreversible.id);
    // The offender is the only (and newest) migration, so nothing was reversed before it.
    try std.testing.expectEqual(@as(usize, 0), outcome.irreversible.reversed.len);
    // Tx rolled the partial reverse back: table and ledger row survive.
    try std.testing.expect(try tableExistsDb(&d, a, "mixed"));
    try std.testing.expect(try ledgerHas(&d, a, "prov:0001_mixed"));
}

test "rollbackMigrations: an orphaned ledger row is refused and its row left intact" {
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    const a = std.testing.allocator;

    const M = struct {
        fn change(m: *Migrator) anyerror!void {
            try m.createTable("orphan_t", &[_]Migrator.Col{.{ .name = "id", .type = .integer, .pk = true, .null = false }});
        }
    };
    // Apply under one id, then attempt rollback with a compiled-in set that no longer contains it.
    try runMigrations(a, std.testing.io, &d, &[_]Migration{.{ .id = "0001_gone", .change = M.change }});
    const now_declared = [_]Migration{}; // the migration was deleted from source
    const outcome = try rollbackMigrations(a, std.testing.io, &d, &now_declared, 1);
    defer outcome.deinit(a);
    try std.testing.expect(outcome == .orphaned);
    try std.testing.expectEqualStrings("0001_gone", outcome.orphaned.id);
    // Orphan is a pre-flight refusal: nothing was reversed.
    try std.testing.expectEqual(@as(usize, 0), outcome.orphaned.reversed.len);
    // The orphaned ledger row is NOT deleted.
    try std.testing.expect(try ledgerHas(&d, a, "prov:0001_gone"));
}

test "rollbackMigrations: a mid-batch irreversible commits the newer reversal, reports it, and stops" {
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    const a = std.testing.allocator;

    // Three migrations. The NEWEST (0003) reverses cleanly (createTable → dropTable). An OLDER one
    // (0002) reverses into raw() — irreversible, only knowable by running. `rollback 3` must:
    //   - reverse+commit 0003 (its table + ledger row gone),
    //   - hit 0002, roll its partial reverse back via the tx, and stop,
    //   - report .irreversible naming 0002 AND listing 0003 as already reversed,
    //   - leave 0002 and 0001 untouched.
    const M = struct {
        fn one(m: *Migrator) anyerror!void {
            try m.createTable("mb_one", &[_]Migrator.Col{.{ .name = "id", .type = .integer, .pk = true, .null = false }});
        }
        fn two(m: *Migrator) anyerror!void {
            try m.createTable("mb_two", &[_]Migrator.Col{.{ .name = "id", .type = .integer, .pk = true, .null = false }});
            try m.raw(.{ .sqlite = "SELECT 1;", .postgres = "SELECT 1;" });
        }
        fn three(m: *Migrator) anyerror!void {
            try m.createTable("mb_three", &[_]Migrator.Col{.{ .name = "id", .type = .integer, .pk = true, .null = false }});
        }
    };
    const migs = [_]Migration{
        .{ .id = "0001_one", .change = M.one },
        .{ .id = "0002_two", .change = M.two },
        .{ .id = "0003_three", .change = M.three },
    };
    try runMigrations(a, std.testing.io, &d, &migs);

    const outcome = try rollbackMigrations(a, std.testing.io, &d, &migs, 3);
    defer outcome.deinit(a);
    try std.testing.expect(outcome == .irreversible);
    try std.testing.expectEqualStrings("0002_two", outcome.irreversible.id);
    // The newest was reversed+committed BEFORE the offender — and it is reported.
    try std.testing.expectEqual(@as(usize, 1), outcome.irreversible.reversed.len);
    try std.testing.expectEqualStrings("0003_three", outcome.irreversible.reversed[0]);
    // 0003 is really gone (table + ledger row).
    try std.testing.expect(!try tableExistsDb(&d, a, "mb_three"));
    try std.testing.expect(!try ledgerHas(&d, a, "prov:0003_three"));
    // The offender (0002) and the older (0001) are untouched: tables + ledger rows intact.
    try std.testing.expect(try tableExistsDb(&d, a, "mb_two"));
    try std.testing.expect(try ledgerHas(&d, a, "prov:0002_two"));
    try std.testing.expect(try tableExistsDb(&d, a, "mb_one"));
    try std.testing.expect(try ledgerHas(&d, a, "prov:0001_one"));
}

test "rollbackMigrations: system migrations are never touched" {
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    const a = std.testing.allocator;

    // Count system (non-prov) ledger rows before.
    var count_st = try d.prepare("SELECT count(*) FROM \"_migrations\" WHERE \"name\" NOT LIKE 'prov:%';");
    try std.testing.expect(try count_st.step());
    const sys_before = count_st.columnInt(0);
    count_st.finalize();
    try std.testing.expect(sys_before > 0);

    const M = struct {
        fn change(m: *Migrator) anyerror!void {
            try m.createTable("consumer_t", &[_]Migrator.Col{.{ .name = "id", .type = .integer, .pk = true, .null = false }});
        }
    };
    const migs = [_]Migration{.{ .id = "0001_consumer", .change = M.change }};
    try runMigrations(a, std.testing.io, &d, &migs);

    // Rolling back "everything" (huge N) reverses only the consumer migration.
    const outcome = try rollbackMigrations(a, std.testing.io, &d, &migs, 1000);
    defer outcome.deinit(a);
    try std.testing.expect(outcome == .ok);
    try std.testing.expectEqual(@as(usize, 1), outcome.ok.len);

    var count_after = try d.prepare("SELECT count(*) FROM \"_migrations\" WHERE \"name\" NOT LIKE 'prov:%';");
    try std.testing.expect(try count_after.step());
    try std.testing.expectEqual(sys_before, count_after.columnInt(0));
    count_after.finalize();
    // No prov rows remain.
    try std.testing.expect(!try ledgerHas(&d, a, "prov:0001_consumer"));
}

test "rollbackMigrations: nothing applied rolls back nothing (empty ok)" {
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    const a = std.testing.allocator;
    const outcome = try rollbackMigrations(a, std.testing.io, &d, &[_]Migration{}, 1);
    defer outcome.deinit(a);
    try std.testing.expect(outcome == .ok);
    try std.testing.expectEqual(@as(usize, 0), outcome.ok.len);
}

test "buildCollection lowers .auth.methods into collection options" {
    const specs = comptime buildCollections(.{
        .accounts = .{ .type = .auth, .fields = .{}, .auth = .{ .methods = .{ .magic_link = .{} } } },
    });
    try std.testing.expectEqual(@as(usize, 1), specs.len);
    const accounts = specs[0];
    try std.testing.expectEqualStrings("accounts", accounts.name);
    try std.testing.expect(accounts.options.auth.methods.magic_link != null);
    try std.testing.expect(accounts.options.auth.methods.password == null);
}

test "buildCollection lowers a per-method comptime rate_limit (.default / .off / .{ .custom })" {
    const specs = comptime buildCollections(.{
        .accounts = .{
            .type = .auth,
            .fields = .{},
            .auth = .{
                .methods = .{
                    // The struct form must lower without `@tagName`-on-a-struct failing.
                    .magic_link = .{ .rate_limit = .{ .custom = .{ .max = 5, .window_s = 60 } } },
                    // The enum-literal forms coexist.
                    .otp = .{ .rate_limit = .off },
                    .password = .{ .rate_limit = .default },
                },
            },
        },
    });
    const ml = specs[0].options.auth.methods.magic_link.?;
    try std.testing.expect(ml.rate_limit == .custom);
    try std.testing.expectEqual(@as(u32, 5), ml.rate_limit.custom.max);
    try std.testing.expectEqual(@as(i64, 60), ml.rate_limit.custom.window_s);
    const otp = specs[0].options.auth.methods.otp.?;
    try std.testing.expect(otp.rate_limit == .off);
    const pw = specs[0].options.auth.methods.password.?;
    try std.testing.expect(pw.rate_limit == .default);
    // NOTE: the negative cases (a misshaped struct without `.custom`, or an unknown enum
    // literal) are `@compileError`s and so cannot be exercised by a unit test.
}

test "buildCollection plumbs magic_link redirect_default/redirect_allow" {
    const specs = comptime buildCollections(.{
        .accounts = .{ .type = .auth, .fields = .{}, .auth = .{ .methods = .{ .magic_link = .{
            .redirect_default = "/club/welcome",
            .redirect_allow = .{ "/club/", "/dashboard" },
        } } } },
    });
    const ml = specs[0].options.auth.methods.magic_link.?;
    try std.testing.expectEqualStrings("/club/welcome", ml.redirect_default);
    try std.testing.expectEqual(@as(usize, 2), ml.redirect_allow.len);
    try std.testing.expectEqualStrings("/club/", ml.redirect_allow[0]);
    try std.testing.expectEqualStrings("/dashboard", ml.redirect_allow[1]);
}

test "buildCollection lowers .indexes with collation and partial predicate" {
    const cols = comptime buildCollections(.{
        .users = .{
            .type = .auth,
            .fields = .{.{ .name = "name", .type = .text }},
            .indexes = .{
                .{ .name = "idx_users_email", .fields = .{"email"}, .unique = true, .collation = .nocase },
                .{ .name = "idx_named", .fields = .{"name"}, .where = "name != ''" },
            },
        },
    });
    const u = cols[0];
    try std.testing.expectEqual(@as(usize, 2), u.indexes.len);
    try std.testing.expectEqualStrings("idx_users_email", u.indexes[0].name);
    try std.testing.expect(u.indexes[0].unique);
    try std.testing.expectEqual(schema.Collation.nocase, u.indexes[0].collation);
    try std.testing.expectEqualStrings("email", u.indexes[0].fields[0]);
    try std.testing.expectEqual(@as(?[]const u8, null), u.indexes[0].where);
    try std.testing.expect(!u.indexes[1].unique);
    try std.testing.expectEqual(schema.Collation.binary, u.indexes[1].collation);
    try std.testing.expectEqualStrings("name != ''", u.indexes[1].where.?);
}

test "buildCollection lowers .auth.oauth2 providers" {
    const specs = comptime buildCollections(.{
        .users = .{ .type = .auth, .fields = .{}, .auth = .{ .oauth2 = .{
            .enabled = true,
            .providers = .{
                .{ .name = "google", .redirectUrls = .{"https://app.example/cb"} },
                .{ .name = "github", .enabled = false, .clientId = "baked-id" },
            },
        } } },
    });
    const o = specs[0].options.auth.oauth2;
    try std.testing.expect(o.enabled);
    try std.testing.expectEqual(@as(usize, 2), o.providers.len);
    try std.testing.expectEqualStrings("google", o.providers[0].name);
    try std.testing.expectEqual(@as(usize, 1), o.providers[0].redirectUrls.len);
    try std.testing.expectEqualStrings("https://app.example/cb", o.providers[0].redirectUrls[0]);
    try std.testing.expect(o.providers[0].enabled); // struct default true
    try std.testing.expect(!o.providers[1].enabled);
    try std.testing.expectEqualStrings("baked-id", o.providers[1].clientId);
    // comptime literal carries NO secret
    try std.testing.expectEqualStrings("", o.providers[0].clientSecret);
}

test "injectOAuthSecrets sources clientId/secret from env and encrypts the secret" {
    const a = std.testing.allocator;

    const Getter = struct {
        fn get(_: @This(), key: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, key, "ZIGBASE_OAUTH_GOOGLE_CLIENT_ID")) return "gid-123";
            if (std.mem.eql(u8, key, "ZIGBASE_OAUTH_GOOGLE_CLIENT_SECRET")) return "raw-secret";
            return null;
        }
    };
    const provs = [_]schema.OAuth2Provider{.{ .name = "google", .redirectUrls = &.{"https://x/cb"} }};
    const cols = [_]schema.Collection{.{
        .id = "",
        .name = "users",
        .type = .auth,
        .fields = &.{},
        .options = .{ .auth = .{ .oauth2 = .{ .enabled = true, .providers = &provs } } },
    }};

    const out = try injectOAuthSecrets(a, std.testing.io, "app-secret-32-bytes-long-xxxxxxx", Getter{}, &cols);
    const np = out[0].options.auth.oauth2.providers;
    // Only clientId/clientSecret were actually duped (sourced from env, then encrypted); name and
    // redirectUrls remain borrowed from `provs`/the literal above — the outer `out`/`np` arrays are
    // injectOAuthSecrets' own fresh allocations.
    defer {
        a.free(np[0].clientId);
        a.free(np[0].clientSecret);
        a.free(np);
        a.free(out);
    }
    const p = np[0];
    try std.testing.expectEqualStrings("gid-123", p.clientId);
    try std.testing.expect(secrets.isEncrypted(p.clientSecret));
    // round-trips back to the raw env value
    const pt = try secrets.decryptSecret(a, "app-secret-32-bytes-long-xxxxxxx", p.clientSecret);
    defer a.free(pt);
    try std.testing.expectEqualStrings("raw-secret", pt);
}

test "injectOAuthSecrets leaves providers untouched when env is absent" {
    const a = std.testing.allocator;
    const Getter = struct {
        fn get(_: @This(), _: []const u8) ?[]const u8 {
            return null;
        }
    };
    const provs = [_]schema.OAuth2Provider{.{ .name = "google" }};
    const cols = [_]schema.Collection{.{
        .id = "",
        .name = "users",
        .type = .auth,
        .fields = &.{},
        .options = .{ .auth = .{ .oauth2 = .{ .enabled = true, .providers = &provs } } },
    }};
    const out = try injectOAuthSecrets(a, std.testing.io, "app-secret", Getter{}, &cols);
    // Neither clientId nor clientSecret was ever set (env absent, no literal secret), so `np`
    // holds only the "" defaults copied through from `provs` — nothing owned beyond the two
    // fresh outer arrays injectOAuthSecrets itself allocated.
    const np = out[0].options.auth.oauth2.providers;
    defer {
        a.free(np);
        a.free(out);
    }
    const p = np[0];
    try std.testing.expectEqualStrings("", p.clientId);
    try std.testing.expectEqualStrings("", p.clientSecret);
}

test "injectOAuthSecrets encrypts a plaintext clientSecret baked into the literal (no env)" {
    const a = std.testing.allocator;
    const Getter = struct {
        fn get(_: @This(), _: []const u8) ?[]const u8 {
            return null;
        }
    };
    // A provider with a plaintext clientSecret in the comptime literal and NO env var set:
    // the secret must still be encrypted before it could be persisted (parity with the admin path).
    const provs = [_]schema.OAuth2Provider{.{ .name = "google", .clientSecret = "literal-secret" }};
    const cols = [_]schema.Collection{.{
        .id = "",
        .name = "users",
        .type = .auth,
        .fields = &.{},
        .options = .{ .auth = .{ .oauth2 = .{ .enabled = true, .providers = &provs } } },
    }};
    const out = try injectOAuthSecrets(a, std.testing.io, "app-secret-32-bytes-long-xxxxxxx", Getter{}, &cols);
    // Only clientSecret ended up owned (the literal plaintext got encrypted in place); clientId
    // stayed at its "" default (env absent) and name is borrowed from `provs`.
    const np = out[0].options.auth.oauth2.providers;
    defer {
        a.free(np[0].clientSecret);
        a.free(np);
        a.free(out);
    }
    const p = np[0];
    try std.testing.expect(secrets.isEncrypted(p.clientSecret));
    const pt = try secrets.decryptSecret(a, "app-secret-32-bytes-long-xxxxxxx", p.clientSecret);
    defer a.free(pt);
    try std.testing.expectEqualStrings("literal-secret", pt);
}

test "injectOAuthSecrets passes non-oauth collections through" {
    const a = std.testing.allocator;
    const Getter = struct {
        fn get(_: @This(), _: []const u8) ?[]const u8 {
            return null;
        }
    };
    const cols = [_]schema.Collection{.{ .id = "", .name = "posts", .fields = &.{} }};
    const out = try injectOAuthSecrets(a, std.testing.io, "app-secret", Getter{}, &cols);
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqualStrings("posts", out[0].name);
}

// Stub transport for resolveDiscoveryProviders tests: returns a canned discovery document
// (or a failing status) regardless of URL, mirroring oauth/client.zig's StubTransport pattern.
const DiscoveryStubTransport = struct {
    status: u16 = 200,
    body: []const u8 =
        \\{
        \\  "issuer": "https://acme.okta.com",
        \\  "authorization_endpoint": "https://acme.okta.com/oauth2/v1/authorize",
        \\  "token_endpoint": "https://acme.okta.com/oauth2/v1/token",
        \\  "userinfo_endpoint": "https://acme.okta.com/oauth2/v1/userinfo"
        \\}
    ,

    fn call(ctx: *anyopaque, alloc: std.mem.Allocator, method: oauth_client.Method, url: []const u8, headers: []const oauth_client.Header, req_body: ?[]const u8) oauth_client.TransportError!oauth_client.Response {
        _ = alloc;
        _ = method;
        _ = url;
        _ = headers;
        _ = req_body;
        const self: *DiscoveryStubTransport = @ptrCast(@alignCast(ctx));
        // Returned as-is (not duped): comptime/caller-owned string data, matching the Transport
        // contract that `discovery.resolve` never frees `resp.body` itself (see its own comment)
        // — mirrors `oauth/client.zig`'s StubTransport precedent. Duping here would leak (nothing
        // downstream ever frees resp.body).
        return .{ .status = self.status, .body = self.body };
    }

    fn transport(self: *DiscoveryStubTransport) oauth_client.Transport {
        return .{ .ctx = self, .call = call };
    }
};

test "resolveDiscoveryProviders fills endpoints for a discovery provider" {
    const a = std.testing.allocator;
    var stub = DiscoveryStubTransport{};
    const provs = [_]schema.OAuth2Provider{.{ .name = "okta", .discoveryURL = "https://acme.okta.com/.well-known/openid-configuration" }};
    const cols = [_]schema.Collection{.{
        .id = "",
        .name = "users",
        .type = .auth,
        .fields = &.{},
        .options = .{ .auth = .{ .oauth2 = .{ .enabled = true, .providers = &provs } } },
    }};
    const out = try resolveDiscoveryProviders(a, stub.transport(), &cols);
    const np = out[0].options.auth.oauth2.providers;
    // The one provider has a discoveryURL, so its authURL/tokenURL/userinfoURL are fresh owned
    // dupes (parseDocument's contract — see discovery.zig); name/discoveryURL stay borrowed.
    defer {
        a.free(np[0].authURL.?);
        a.free(np[0].tokenURL.?);
        a.free(np[0].userinfoURL.?);
        a.free(np);
        a.free(out);
    }
    const p = np[0];
    try std.testing.expectEqualStrings("https://acme.okta.com/oauth2/v1/authorize", p.authURL.?);
    try std.testing.expectEqualStrings("https://acme.okta.com/oauth2/v1/token", p.tokenURL.?);
    try std.testing.expectEqualStrings("https://acme.okta.com/oauth2/v1/userinfo", p.userinfoURL.?);
}

test "resolveDiscoveryProviders propagates a discovery failure" {
    const a = std.testing.allocator;
    var stub = DiscoveryStubTransport{ .status = 500, .body = "boom" };
    const provs = [_]schema.OAuth2Provider{.{ .name = "okta", .discoveryURL = "https://acme.okta.com/.well-known/openid-configuration" }};
    const cols = [_]schema.Collection{.{
        .id = "",
        .name = "users",
        .type = .auth,
        .fields = &.{},
        .options = .{ .auth = .{ .oauth2 = .{ .enabled = true, .providers = &provs } } },
    }};
    try std.testing.expectError(error.DiscoveryFetchFailed, resolveDiscoveryProviders(a, stub.transport(), &cols));
}

test "resolveDiscoveryProviders returns the same slice when no provider uses discovery" {
    const a = std.testing.allocator;
    var stub = DiscoveryStubTransport{};
    const provs = [_]schema.OAuth2Provider{.{ .name = "google" }};
    const cols = [_]schema.Collection{.{
        .id = "",
        .name = "users",
        .type = .auth,
        .fields = &.{},
        .options = .{ .auth = .{ .oauth2 = .{ .enabled = true, .providers = &provs } } },
    }};
    const out = try resolveDiscoveryProviders(a, stub.transport(), &cols);
    try std.testing.expectEqual(@as(usize, @intFromPtr(&cols)), @as(usize, @intFromPtr(out.ptr)));
}
