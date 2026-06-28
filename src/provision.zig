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
const rules = @import("rules.zig");
const regex = @import("regex.zig");
const datetime = @import("datetime.zig");
const secrets = @import("oauth/secrets.zig");

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
/// keys handled in `buildField` (name/type/required/unique/hidden/encrypted). Kept in
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
        .@"bool" => &.{},
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
        const common = [_][]const u8{ "name", "type", "required", "unique", "hidden", "encrypted" };
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
        rejectUnknownKeys(spec, &.{ "type", "fields", "rules", "auth", "indexes", "ttl_field" }, "collection '" ++ name ++ "'");

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
            rejectUnknownKeys(spec.auth, &.{ "methods", "require_verified", "oauth2" }, "collection '" ++ name ++ "' .auth");
            const A = @TypeOf(spec.auth);
            if (@hasField(A, "methods")) {
                col.options.auth.methods = buildMethodsOptions(spec.auth.methods);
            }
            if (@hasField(A, "require_verified")) {
                col.options.auth.require_verified = spec.auth.require_verified;
            }
            if (@hasField(A, "oauth2")) {
                col.options.auth.oauth2 = buildOAuth2Options(spec.auth.oauth2);
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

fn buildRateLimitOpt(comptime rl: anytype) schema.RateLimitOpt {
    const T = @TypeOf(rl);
    // The struct form `.{ .custom = .{ .max = …, .window_s = … } }`: an anonymous struct
    // (NOT an enum/union), so `@tagName` would fail — match on the `custom` field instead.
    if (T != @TypeOf(.enum_literal)) {
        if (@hasField(T, "custom")) {
            const cv = rl.custom;
            return .{ .custom = .{ .max = cv.max, .window_s = cv.window_s } };
        }
        // A struct without a `custom` field is a misshaped config (e.g. forgetting the
        // `.custom` wrapper: `.{ .max = 5, .window_s = 60 }`). Fail at comptime rather than
        // silently applying `.default`.
        @compileError("rate_limit: unrecognized struct shape; expected " ++
            ".rate_limit = .{ .custom = .{ .max = N, .window_s = S } } " ++
            "(or the enum-literals .default / .off)");
    }
    // The enum-literal form `.default` / `.off`. An unknown literal (e.g. `.on`, a typo) is
    // a comptime error, not a silent `.default`.
    const tag = @tagName(rl);
    if (std.mem.eql(u8, tag, "off")) return .off;
    if (std.mem.eql(u8, tag, "default")) return .default;
    @compileError("rate_limit: unknown value '." ++ tag ++ "'; expected " ++
        ".default, .off, or .{ .custom = .{ .max = N, .window_s = S } }");
}

fn buildMethodsOptions(comptime m: anytype) schema.MethodsOptions {
    const M = @TypeOf(m);
    var out = schema.MethodsOptions{};
    // Each optional built-in method field in the comptime literal is an anonymous
    // struct (not a typed optional), so we use @hasField to detect presence and
    // treat it as "enabled with those settings".
    if (@hasField(M, "password")) {
        const pw = m.password;
        var p = schema.PasswordMethodOpts{};
        if (@hasField(@TypeOf(pw), "rate_limit")) p.rate_limit = buildRateLimitOpt(pw.rate_limit);
        out.password = p;
    }
    if (@hasField(M, "magic_link")) {
        const ml = m.magic_link;
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
        var p = schema.OtpMethodOpts{};
        if (@hasField(@TypeOf(otp), "length")) p.length = otp.length;
        if (@hasField(@TypeOf(otp), "ttl_s")) p.ttl_s = otp.ttl_s;
        if (@hasField(@TypeOf(otp), "auto_create")) p.auto_create = otp.auto_create;
        if (@hasField(@TypeOf(otp), "rate_limit")) p.rate_limit = buildRateLimitOpt(otp.rate_limit);
        out.otp = p;
    }
    if (@hasField(M, "webauthn")) {
        const wa = m.webauthn;
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

fn buildOAuth2Options(comptime o: anytype) schema.OAuth2Options {
    comptime {
        const O = @TypeOf(o);
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
        return out;
    }
}

fn buildField(comptime col_name: []const u8, comptime f: anytype) schema.Field {
    comptime {
        const F = @TypeOf(f);
        if (!@hasField(F, "name")) @compileError("a field in collection '" ++ col_name ++ "' is missing .name");
        const fname: []const u8 = f.name;
        if (schema.isSystemFieldName(fname)) @compileError("collection '" ++ col_name ++ "': field name '" ++ fname ++ "' is reserved by the engine (id/created/updated/email/username/passwordHash/tokenKey/verified); pick another name");
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
            .@"bool" => .{ .@"bool" = .{} },
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
                .pointer => out[i] = elem, // bare slug string
                .@"struct" => {
                    if (!@hasField(@TypeOf(elem), "slug"))
                        @compileError(".auth.methods.custom struct entry must have a .slug field");
                    const slug: []const u8 = elem.slug;
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
/// Note: the `alloc` passed to `up` is a short-lived arena scoped to the
/// `runMigrations` call — anything allocated from it is freed before
/// `runMigrations` returns. Do not store pointers derived from `alloc` in
/// state that outlives the call; use a separate long-lived allocator for
/// persistent data.
pub const Migration = struct {
    id: []const u8,
    up: *const fn (alloc: std.mem.Allocator, io: std.Io, w: *db.Db) anyerror!void,
};

// ---------------------------------------------------------------------------
// Runtime provisioner
// ---------------------------------------------------------------------------

pub const ProvisionError = error{ UnknownRelationTarget, RelationTargetMissing } ||
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

pub fn applySpecs(
    alloc: std.mem.Allocator,
    io: std.Io,
    w: *db.Db,
    specs: []const schema.Collection,
) ProvisionError!void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

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

    const existing = try collections.get(alloc, w, spec.name);
    if (existing == null) {
        _ = try collections.create(alloc, io, w, spec);
        std.log.info("provision: created collection '{s}'", .{spec.name});
        return;
    }
    const live = existing.?;

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
        // present in both: detect a non-additive change (type or sql storage class)
        if (lf.?.fieldType() != sf.fieldType() or !std.mem.eql(u8, lf.?.sqlType(), sf.sqlType())) {
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
    newdef.listRule = spec.listRule orelse live.listRule;
    newdef.viewRule = spec.viewRule orelse live.viewRule;
    newdef.createRule = spec.createRule orelse live.createRule;
    newdef.updateRule = spec.updateRule orelse live.updateRule;
    newdef.deleteRule = spec.deleteRule orelse live.deleteRule;
    // Carry the (possibly newly-set) ttl_field; keep the rest of live.options
    // (e.g. persisted OAuth secrets) untouched by NOT copying spec.options wholesale.
    newdef.options.ttl_field = spec.options.ttl_field;
    _ = try collections.update(alloc, io, w, live.id, newdef);
    std.log.info("provision: collection '{s}' added {d} field(s)", .{ spec.name, additions.items.len });
}

/// Return a copy of `col` where each single-relation field's targetCollectionId
/// (a target NAME on input) is replaced by the live target collection's id, so the
/// persisted metadata matches what the runtime API produces. Errors clearly if the
/// target is missing.
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
                const target = (try collections.get(alloc, w, r.targetCollectionId)) orelse {
                    std.log.warn("provision: relation target '{s}' not found while provisioning '{s}' — refusing to provision", .{ r.targetCollectionId, col.name });
                    return error.RelationTargetMissing;
                };
                var nr = r;
                nr.targetCollectionId = target.id;
                fields[i].options = .{ .relation = nr };
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

    for (migs) |m| {
        const name = try std.fmt.allocPrint(a, "prov:{s}", .{m.id});
        if (try migrationApplied(w, name)) continue;
        try w.begin();
        errdefer w.rollback() catch {};
        try m.up(a, io, w);
        try recordMigration(w, name);
        try w.commit();
        std.log.info("provision: applied migration '{s}'", .{m.id});
    }
}

fn migrationApplied(w: *db.Db, name: []const u8) db.DbError!bool {
    var st = try w.prepare("SELECT 1 FROM \"_migrations\" WHERE \"name\" = ?1;");
    defer st.finalize();
    try st.bindText(1, name);
    return try st.step();
}

fn recordMigration(w: *db.Db, name: []const u8) db.DbError!void {
    var st = try w.prepare("INSERT INTO \"_migrations\" (\"name\", \"applied_at\") VALUES (?1, datetime('now'));");
    defer st.finalize();
    try st.bindText(1, name);
    _ = try st.step();
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
                .{ .name = "flag", .type = .@"bool" },
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
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const lf = [_]schema.Field{.{ .id = "r", .name = "owner", .options = .{ .relation = .{ .targetCollectionId = "users", .maxSelect = 1 } } }};
    const specs = [_]schema.Collection{
        .{ .id = "", .name = "listings", .fields = &lf },
        .{ .id = "", .name = "users", .fields = &.{} },
    };
    const order = try topoOrder(a, &specs);
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
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

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
    const listings = (try collections.get(a, &d, "listings")).?;
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
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

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
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // v1: a collection with a date field but NO ttl_field.
    const fields = [_]schema.Field{
        .{ .id = "f_tok", .name = "token", .options = .{ .text = .{} } },
        .{ .id = "f_exp", .name = "expires_at", .options = .{ .date = .{} } },
    };
    const s1 = [_]schema.Collection{.{ .id = "", .name = "sessions", .fields = &fields }};
    try applySpecs(a, std.testing.io, &d, &s1);
    try d.exec("INSERT INTO \"sessions\" (\"id\",\"created\",\"updated\",\"token\",\"expires_at\") VALUES ('s1','','','t','2000-01-01T00:00:00Z');");

    // Before: ttl_field not set, GC reaps nothing.
    try std.testing.expect((try collections.get(a, &d, "sessions")).?.options.ttl_field == null);
    try std.testing.expectEqual(@as(usize, 0), try @import("records.zig").gcExpiredRecords(a, &d));

    // v2: same fields, now declaring .ttl_field — must be persisted by re-provisioning.
    const s2 = [_]schema.Collection{.{ .id = "", .name = "sessions", .fields = &fields, .options = .{ .ttl_field = "expires_at" } }};
    try applySpecs(a, std.testing.io, &d, &s2);

    // The persisted options blob now carries the ttl_field...
    const live = (try collections.get(a, &d, "sessions")).?;
    try std.testing.expect(live.options.ttl_field != null);
    try std.testing.expectEqualStrings("expires_at", live.options.ttl_field.?);

    // ...and the GC now reaps the expired row.
    try std.testing.expectEqual(@as(usize, 1), try @import("records.zig").gcExpiredRecords(a, &d));
    var st = try d.prepare("SELECT COUNT(*) FROM \"sessions\";");
    defer st.finalize();
    _ = try st.step();
    try std.testing.expectEqual(@as(i64, 0), st.columnInt(0));
}

test "applySpecs logs+skips a destructive type change (does not destroy data)" {
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

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
    try std.testing.expectEqual(schema.FieldType.text, schema.fieldByName(live, "n").?.fieldType());
}

test "applySpecs rejects an unknown relation target" {
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const lf = [_]schema.Field{.{ .id = "f_o", .name = "owner", .options = .{ .relation = .{ .targetCollectionId = "ghosts", .maxSelect = 1 } } }};
    const specs = [_]schema.Collection{.{ .id = "", .name = "listings", .fields = &lf }};
    try std.testing.expectError(error.UnknownRelationTarget, applySpecs(a, std.testing.io, &d, &specs));
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
                .{ .name = "read", .type = .@"bool" },
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
                .{ .name = "active", .type = .@"bool" },
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
    try std.testing.expectEqual(schema.FieldType.@"bool", messages.fields[4].fieldType());

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
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const M = struct {
        var calls: usize = 0;
        fn up(_: std.mem.Allocator, _: std.Io, w: *db.Db) anyerror!void {
            calls += 1;
            try w.exec("CREATE TABLE IF NOT EXISTS \"prov_demo\" (\"x\" TEXT);");
        }
    };
    M.calls = 0;
    const migs = [_]Migration{.{ .id = "0001_demo", .up = M.up }};
    try runMigrations(a, std.testing.io, &d, &migs);
    try runMigrations(a, std.testing.io, &d, &migs);
    try std.testing.expectEqual(@as(usize, 1), M.calls);
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
        .accounts = .{ .type = .auth, .fields = .{}, .auth = .{ .methods = .{
            // The struct form must lower without `@tagName`-on-a-struct failing.
            .magic_link = .{ .rate_limit = .{ .custom = .{ .max = 5, .window_s = 60 } } },
            // The enum-literal forms coexist.
            .otp = .{ .rate_limit = .off },
            .password = .{ .rate_limit = .default },
        } } },
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
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Getter = struct {
        fn get(_: @This(), key: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, key, "ZIGBASE_OAUTH_GOOGLE_CLIENT_ID")) return "gid-123";
            if (std.mem.eql(u8, key, "ZIGBASE_OAUTH_GOOGLE_CLIENT_SECRET")) return "raw-secret";
            return null;
        }
    };
    const provs = [_]schema.OAuth2Provider{.{ .name = "google", .redirectUrls = &.{"https://x/cb"} }};
    const cols = [_]schema.Collection{.{
        .id = "", .name = "users", .type = .auth, .fields = &.{},
        .options = .{ .auth = .{ .oauth2 = .{ .enabled = true, .providers = &provs } } },
    }};

    const out = try injectOAuthSecrets(a, std.testing.io, "app-secret-32-bytes-long-xxxxxxx", Getter{}, &cols);
    const p = out[0].options.auth.oauth2.providers[0];
    try std.testing.expectEqualStrings("gid-123", p.clientId);
    try std.testing.expect(secrets.isEncrypted(p.clientSecret));
    // round-trips back to the raw env value
    const pt = try secrets.decryptSecret(a, "app-secret-32-bytes-long-xxxxxxx", p.clientSecret);
    try std.testing.expectEqualStrings("raw-secret", pt);
}

test "injectOAuthSecrets leaves providers untouched when env is absent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Getter = struct {
        fn get(_: @This(), _: []const u8) ?[]const u8 { return null; }
    };
    const provs = [_]schema.OAuth2Provider{.{ .name = "google" }};
    const cols = [_]schema.Collection{.{
        .id = "", .name = "users", .type = .auth, .fields = &.{},
        .options = .{ .auth = .{ .oauth2 = .{ .enabled = true, .providers = &provs } } },
    }};
    const out = try injectOAuthSecrets(a, std.testing.io, "app-secret", Getter{}, &cols);
    const p = out[0].options.auth.oauth2.providers[0];
    try std.testing.expectEqualStrings("", p.clientId);
    try std.testing.expectEqualStrings("", p.clientSecret);
}

test "injectOAuthSecrets encrypts a plaintext clientSecret baked into the literal (no env)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Getter = struct {
        fn get(_: @This(), _: []const u8) ?[]const u8 { return null; }
    };
    // A provider with a plaintext clientSecret in the comptime literal and NO env var set:
    // the secret must still be encrypted before it could be persisted (parity with the admin path).
    const provs = [_]schema.OAuth2Provider{.{ .name = "google", .clientSecret = "literal-secret" }};
    const cols = [_]schema.Collection{.{
        .id = "", .name = "users", .type = .auth, .fields = &.{},
        .options = .{ .auth = .{ .oauth2 = .{ .enabled = true, .providers = &provs } } },
    }};
    const out = try injectOAuthSecrets(a, std.testing.io, "app-secret-32-bytes-long-xxxxxxx", Getter{}, &cols);
    const p = out[0].options.auth.oauth2.providers[0];
    try std.testing.expect(secrets.isEncrypted(p.clientSecret));
    const pt = try secrets.decryptSecret(a, "app-secret-32-bytes-long-xxxxxxx", p.clientSecret);
    try std.testing.expectEqualStrings("literal-secret", pt);
}

test "injectOAuthSecrets passes non-oauth collections through" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Getter = struct {
        fn get(_: @This(), _: []const u8) ?[]const u8 { return null; }
    };
    const cols = [_]schema.Collection{.{ .id = "", .name = "posts", .fields = &.{} }};
    const out = try injectOAuthSecrets(a, std.testing.io, "app-secret", Getter{}, &cols);
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqualStrings("posts", out[0].name);
}
