const std = @import("std");

/// The frozen error-code registry. A tag name here IS the wire string emitted as
/// the envelope's `code` (and as a field error's `code`), so `@tagName` needs no
/// mapping table. See `src/error-codes.frozen` for the stability contract.
///
/// `message` text is explicitly NOT contract — consumers match on these codes.
pub const Code = enum {
    // top-level envelope codes (one per ApiError constructor)
    bad_request,
    collections_frozen,
    conflict,
    email_not_verified,
    forbidden,
    gone,
    internal,
    not_found,
    payload_too_large,
    too_many_requests,
    unauthorized,
    validation_failed,
    // field-level codes (emitted into `data.<field>.code`)
    validation_date,
    validation_duplicate_name,
    validation_encrypted_index,
    validation_encrypted_type,
    validation_encrypted_unique,
    validation_invalid_email,
    validation_invalid_identity_field,
    validation_invalid_name,
    validation_invalid_scale,
    validation_invalid_tenant_field,
    validation_invalid_ttl_field,
    validation_max,
    validation_min,
    validation_not_found,
    validation_number,
    validation_overflow,
    validation_pattern,
    validation_relation,
    validation_required,
    validation_reserved_name,
    validation_reserved_suffix,
    validation_searchable_encrypted,
    validation_searchable_type,
    validation_select,
    validation_too_precise,
    validation_type,
    validation_value,
};

/// The wire string for `c`. Built-in emission sites call this instead of writing
/// a raw literal, so a typo is a COMPILE error checked against the frozen ledger.
/// Consumer code (`ctx.invalid`, `ctx.jsonError`) may still pass its own string —
/// ZigBase never assigns meaning to a code it did not register.
pub inline fn s(c: Code) []const u8 {
    return @tagName(c);
}

/// Parse a wire string back into a registered `Code`; null for anything unregistered.
pub fn parse(text: []const u8) ?Code {
    return std.meta.stringToEnum(Code, text);
}

pub const Info = struct {
    /// One line, no trailing period. Shown by `zigbase explain-code` with no argument.
    summary: []const u8,
    /// The long form: what produced this code and what the caller should change.
    /// May be multi-line.
    explanation: []const u8,
};

/// Exhaustive on purpose: no `else` arm. A new `Code` field without a matching arm
/// here is a COMPILE ERROR — that is the whole enforcement behind "every registered
/// code is documented".
pub fn info(c: Code) Info {
    return switch (c) {
        .bad_request => .{
            .summary = "the request was malformed or semantically invalid",
            .explanation =
            \\A catch-all for requests that fail validation ZigBase doesn't attach to a
            \\specific field — malformed query parameters, an unparseable filter/sort
            \\expression, a bad cursor, or another request-shape problem the handler
            \\rejected before doing any work.
            \\
            \\Read `message` for the specific cause and fix the request; this code is
            \\not retried automatically.
            ,
        },
        .collections_frozen => .{
            .summary = "runtime collection DDL is disabled by `.collections_frozen`",
            .explanation =
            \\This deployment was built with `App(.{ .collections_frozen = true })`,
            \\so POST/PATCH/DELETE on /api/collections are categorically rejected —
            \\schema evolves through a `.migrations` entry plus a redeploy, not over
            \\REST. Reads (GET /api/collections) still work.
            \\
            \\Detect this BEFORE attempting DDL: GET /api/meta reports
            \\`capabilities.collectionsFrozen`. Never string-match this response's
            \\message text.
            ,
        },
        .conflict => .{
            .summary = "the request conflicts with the current state of the resource",
            .explanation =
            \\Emitted for state conflicts that aren't a validation failure on any one
            \\field — e.g. a unique-constraint collision surfaced above the field
            \\level, or an operation that can't proceed given the resource's current
            \\state.
            \\
            \\Re-read the resource's current state before retrying; a blind retry of
            \\the same request will conflict again.
            ,
        },
        .email_not_verified => .{
            .summary = "the account exists and the credentials are valid, but its email is unverified",
            .explanation =
            \\A 403 on an auth request whose credentials were ACCEPTED — the only thing
            \\standing between the caller and a session is email verification. It is a
            \\distinct state from `forbidden`, which means "not permitted, full stop":
            \\here the client should switch to its verify-email flow (request a fresh
            \\verification link and retry the login afterwards), not report a denial.
            \\
            \\This code exists so a client never has to match on the message text to
            \\tell the two apart — the pattern the frozen registry exists to remove.
            ,
        },
        .forbidden => .{
            .summary = "the caller is authenticated but not permitted",
            .explanation =
            \\The request carried valid credentials, but the collection's access rule
            \\(`listRule`/`viewRule`/`createRule`/`updateRule`/`deleteRule`) evaluated
            \\to false for this caller and record, or a superuser-only endpoint was
            \\hit by a non-superuser.
            \\
            \\This is not retryable with the same credentials — the caller needs a
            \\different identity or the rule needs to change.
            ,
        },
        .gone => .{
            .summary = "the resource existed but is no longer available (e.g. an expired cursor)",
            .explanation =
            \\Distinct from `not_found`: the server knows the resource once existed
            \\(a pagination cursor that has expired or no longer matches the current
            \\result set is the primary case) rather than never having existed or
            \\being deliberately hidden.
            \\
            \\Restart the operation from scratch — e.g. re-list from the first page
            \\to mint a fresh cursor — rather than retrying the same request.
            ,
        },
        .internal => .{
            .summary = "an unexpected server-side failure; no detail is leaked",
            .explanation =
            \\Something failed on the server side that isn't a client-caused,
            \\actionable error — an allocation failure, an unexpected database error,
            \\a bug. `message` is deliberately generic so internals never leak into
            \\the response.
            \\
            \\Also the default for any HTTP status this registry doesn't otherwise
            \\map (see `forStatus`) — receiving `internal` for a request that "should"
            \\have a specific code is itself a signal to check the server logs.
            ,
        },
        .not_found => .{
            .summary = "no such resource, or the caller may not know whether it exists",
            .explanation =
            \\Covers both a genuinely absent resource and a resource the caller isn't
            \\permitted to know about — ZigBase deliberately does not distinguish
            \\"doesn't exist" from "exists but you can't see it" in the response, to
            \\avoid leaking existence via status code.
            \\
            \\Don't infer permission state from this code; if the caller believes the
            \\resource should exist, that's an authorization question, not a retry.
            ,
        },
        .payload_too_large => .{
            .summary = "the uploaded body exceeded the configured maximum size",
            .explanation =
            \\A 413. The request body — in practice a file upload — is larger than the
            \\deployment's `maxUploadSize`. This is a CLIENT-side condition and is fixed
            \\by sending less data, not by retrying the same request: retrying an
            \\unchanged body will fail identically.
            \\
            \\Read the limit before uploading from GET /api/meta (`limits.maxUploadSize`,
            \\in bytes) and split or shrink the payload to fit. Do not confuse this with
            \\`internal`: this code exists precisely so a size rejection is never
            \\mistaken for a server fault.
            ,
        },
        .too_many_requests => .{
            .summary = "the caller exceeded a rate limit and should back off",
            .explanation =
            \\Emitted by the auth rate limiter (login, OTP verify/resend, magic-link,
            \\password reset, and similar sensitive endpoints) when a scope+identity
            \\pair has made too many attempts in the current window.
            \\
            \\Back off and retry later; hammering the endpoint immediately will keep
            \\failing. There is no `Retry-After` contract yet — treat this as
            \\"slow down", not a precise deadline.
            ,
        },
        .unauthorized => .{
            .summary = "no valid credentials were presented",
            .explanation =
            \\The request reached an endpoint that requires authentication and either
            \\presented no credentials, an expired/malformed token, or one that failed
            \\verification.
            \\
            \\The caller must (re-)authenticate before retrying — a rule change won't
            \\help here, unlike `forbidden`.
            ,
        },
        .validation_failed => .{
            .summary = "one or more fields failed validation; see `data`",
            .explanation =
            \\The top-level envelope code for `ApiError.validation`, used whenever any
            \\field-level `validation_*` code is present. `data.<field>.code` carries
            \\the specific reason per field — read those, not just this top-level code.
            \\
            \\Fix every field listed in `data` and resubmit; ZigBase reports all
            \\failing fields in one response rather than one at a time.
            ,
        },
        .validation_date => .{
            .summary = "a date value, or a field's configured date bound, is not a valid date",
            .explanation =
            \\Emitted both when a record's date-typed field value fails to parse, and
            \\when a collection's own `min`/`max` date-bound field configuration is
            \\unparseable or `min` is after `max`.
            \\
            \\As a request error: send a value in the format the field expects. As a
            \\schema error: fix the field's `min`/`max` configuration on the
            \\collection.
            ,
        },
        .validation_duplicate_name => .{
            .summary = "a field name is duplicated on the collection",
            .explanation =
            \\Two fields on the same collection schema share a name. Field names must
            \\be unique within a collection; rename one of the colliding fields in the
            \\schema being submitted.
            ,
        },
        .validation_encrypted_index => .{
            .summary = "an encrypted field cannot be indexed",
            .explanation =
            \\An index references a field that has `.encrypted = true`. Encrypted
            \\column values are ciphertext at rest, so an index over them can't
            \\support equality/range lookups — drop the field from the index, or turn
            \\off encryption for it.
            ,
        },
        .validation_encrypted_type => .{
            .summary = "only text, editor, and json fields can be encrypted",
            .explanation =
            \\`.encrypted = true` was set on a field whose type isn't text, editor, or
            \\json. Change the field's type to one of those, or remove the encrypted
            \\flag.
            ,
        },
        .validation_encrypted_unique => .{
            .summary = "an encrypted field cannot be unique",
            .explanation =
            \\`.encrypted = true` and `.unique = true` were set on the same field.
            \\Uniqueness needs to compare plaintext values, which an encrypted column
            \\can't do at the database layer — drop one of the two flags.
            ,
        },
        .validation_invalid_email => .{
            .summary = "the value is not a valid email address",
            .explanation =
            \\An email-typed field's value failed email-format validation (this also
            \\rejects header-injection payloads like embedded CRLFs). Send a
            \\well-formed single email address.
            ,
        },
        .validation_invalid_identity_field => .{
            .summary = "the identity field configuration is not a valid identifier",
            .explanation =
            \\A collection's `identityFields` entry does not name a valid field
            \\identifier. Fix the collection's `identityFields` configuration to
            \\reference real, validly-named fields.
            ,
        },
        .validation_invalid_name => .{
            .summary = "a collection, field, or index name is not a valid identifier",
            .explanation =
            \\Names must start with a letter and contain only letters, digits, and
            \\underscores — this covers the collection name itself, a field name, an
            \\index name, or a field named inside an index. Rename to a valid
            \\identifier.
            ,
        },
        .validation_invalid_scale => .{
            .summary = "a fixed-point number field's scale is out of range",
            .explanation =
            \\A `fixed` (fixed-point decimal) field must declare a scale between 1 and
            \\8 digits. Set the field's scale to a value in that range.
            ,
        },
        .validation_invalid_tenant_field => .{
            .summary = "the tenant_field configuration is not a valid identifier naming an existing TEXT field",
            .explanation =
            \\A collection's `tenant_field` (the field holding the owning account id
            \\for multi-tenant isolation) must be a valid identifier naming an
            \\existing TEXT-storage field on the collection. Fix `tenant_field` to
            \\point at such a field.
            ,
        },
        .validation_invalid_ttl_field => .{
            .summary = "the ttl_field configuration is not a valid identifier naming an existing date/autodate field",
            .explanation =
            \\A collection's `ttl_field` (used for time-based expiry) must be a valid
            \\identifier naming an existing date or autodate field on the collection.
            \\Fix `ttl_field` to point at such a field.
            ,
        },
        .validation_max => .{
            .summary = "a value is above the field's maximum, or longer than its maximum length",
            .explanation =
            \\Emitted for numeric `max`, string/length `max`, and date `max` constraints
            \\on a field — the accompanying message distinguishes them. Send a value that
            \\satisfies the constraint declared on the collection's field.
            \\
            \\NOT emitted for "too many values" on a select or relation field: those are
            \\`validation_select` and `validation_relation` respectively.
            \\
            \\Read the current constraint from GET /api/collections/<name>.
            ,
        },
        .validation_min => .{
            .summary = "a value is below the field's minimum, or shorter than its minimum length",
            .explanation =
            \\Emitted for numeric `min`, string/length `min`, and date `min` constraints
            \\on a field — the accompanying message distinguishes them ("Value is below
            \\the minimum." / "Value is too short." / "Date is before the minimum.").
            \\Send a value that satisfies the constraint declared on the field.
            \\
            \\Read the current constraint from GET /api/collections/<name>.
            ,
        },
        .validation_not_found => .{
            .summary = "a relation field references a record that does not exist",
            .explanation =
            \\A relation-typed field's value is an id that doesn't resolve to a record
            \\in the target collection (or the caller can't see it). Send an id of a
            \\record that actually exists in the target collection.
            ,
        },
        .validation_number => .{
            .summary = "the value is not a well-formed number",
            .explanation =
            \\Coercion of an incoming value into a numeric field failed because the
            \\text isn't a parseable number (`error.BadNumber`). Send a numeric value
            \\in a standard numeric format.
            ,
        },
        .validation_overflow => .{
            .summary = "the value overflows the field's numeric range",
            .explanation =
            \\Coercion of an incoming value into a numeric field failed because the
            \\value is out of range for the field's integer width (`error.Overflow`).
            \\Send a value that fits the field's declared numeric type.
            ,
        },
        .validation_pattern => .{
            .summary = "the value does not match the field's required pattern, or the pattern itself is invalid",
            .explanation =
            \\Emitted both when a text field's value fails its configured regex
            \\pattern, and when the collection schema's own pattern string doesn't
            \\compile as a valid regular expression.
            \\
            \\As a request error: send a value matching the field's pattern. As a
            \\schema error: fix the pattern in the field definition.
            ,
        },
        .validation_relation => .{
            .summary = "a relation field has too many values, or points at a target that cannot be resolved",
            .explanation =
            \\Emitted when a multi-valued relation field's value count exceeds its
            \\configured maximum ("Too many relations."), and when the field's target
            \\collection cannot be resolved while handling the request ("Relation
            \\target missing.").
            \\
            \\Send fewer related ids, or fix the relation's target collection so it
            \\resolves. A relation field whose SCHEMA omits `targetCollectionId`
            \\entirely reports `validation_required`, not this code.
            ,
        },
        .validation_required => .{
            .summary = "a required value is missing",
            .explanation =
            \\Emitted both for a record field with `.required = true` and no value,
            \\and for schema-level required configuration (a `select` field needs at
            \\least one allowed value; a `relation` field needs a
            \\`targetCollectionId`).
            \\
            \\As a request error: supply the missing field value. As a schema error:
            \\fill in the missing field configuration.
            ,
        },
        .validation_reserved_name => .{
            .summary = "a field name is reserved and cannot be used",
            .explanation =
            \\The field name collides with a name ZigBase reserves for its own use
            \\(e.g. built-in columns). Rename the field to something not on the
            \\reserved list.
            ,
        },
        .validation_reserved_suffix => .{
            .summary = "a collection name ends with a reserved suffix",
            .explanation =
            \\Collection names may not end with `_fts` — that suffix is reserved for
            \\ZigBase's generated full-text-search index tables. Rename the
            \\collection.
            ,
        },
        .validation_searchable_encrypted => .{
            .summary = "an encrypted field cannot be searchable",
            .explanation =
            \\`.encrypted = true` and `.searchable = true` were set on the same field.
            \\Full-text search needs plaintext to index, which an encrypted column
            \\can't provide — drop one of the two flags.
            ,
        },
        .validation_searchable_type => .{
            .summary = "only text and editor fields can be searchable",
            .explanation =
            \\`.searchable = true` was set on a field whose type isn't text or editor.
            \\Change the field's type to one of those, or remove the searchable flag.
            ,
        },
        .validation_select => .{
            .summary = "a select field's value is not in its allowed set, or has too many values",
            .explanation =
            \\Emitted both when a select field's value isn't one of the collection's
            \\configured options, and when a multi-valued select field's value count
            \\exceeds its configured maximum.
            \\
            \\Send a value (or values) drawn from the field's configured option set,
            \\within its configured count limit.
            ,
        },
        .validation_too_precise => .{
            .summary = "the value has more decimal precision than the field allows",
            .explanation =
            \\Coercion of an incoming value into a fixed-point (`fixed`) numeric field
            \\failed because it carries more fractional digits than the field's
            \\declared scale (`error.TooPrecise`). Round the value to the field's
            \\configured scale before sending it.
            ,
        },
        .validation_type => .{
            .summary = "the value's type does not match the field's declared type",
            .explanation =
            \\Coercion of an incoming value into a typed field failed because the
            \\JSON value's type is fundamentally incompatible with the field's type
            \\(`error.TypeMismatch`) — e.g. an object sent for a numeric field. Send a
            \\value of the type the field declares.
            ,
        },
        .validation_value => .{
            .summary = "the value could not be coerced into the field's type",
            .explanation =
            \\The catch-all outcome of value coercion (`records.zig`'s mapping):
            \\any coercion failure not specifically classified as too-precise,
            \\type-mismatch, overflow, or a bad number falls back to this code. Check
            \\`message` for detail and send a value the field's type can accept.
            ,
        },
    };
}

/// The envelope code for a bare HTTP status, used where an error reaches the
/// renderer without one (e.g. `ctx.fail(status, message)`). Deliberately
/// conservative: anything unmapped is `internal`, never an invented code.
pub fn forStatus(status: u16) Code {
    return switch (status) {
        400 => .bad_request,
        401 => .unauthorized,
        403 => .forbidden,
        404 => .not_found,
        409 => .conflict,
        410 => .gone,
        413 => .payload_too_large,
        429 => .too_many_requests,
        else => .internal,
    };
}

const frozen = @embedFile("error-codes.frozen");

fn frozenSection(comptime header: []const u8) []const u8 {
    const start_marker = "[" ++ header ++ "]";
    const start = std.mem.indexOf(u8, frozen, start_marker).? + start_marker.len;
    const rest = frozen[start..];
    const end = std.mem.indexOf(u8, rest, "\n[") orelse rest.len;
    return rest[0..end];
}

/// Split a `[SECTION]` slice into its non-blank, non-comment lines. The returned
/// list owns its backing array — the caller must `deinit(gpa)` it. The elements
/// are NOT owned: they are slices into the comptime `@embedFile` data, which
/// outlives every caller. `errdefer` covers a partial list on append failure.
fn frozenLines(section: []const u8, gpa: std.mem.Allocator) !std.ArrayListUnmanaged([]const u8) {
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer list.deinit(gpa);
    var it = std.mem.splitScalar(u8, section, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        try list.append(gpa, line);
    }
    return list;
}

test "error_codes: every Code appears in error-codes.frozen [ACTIVE]" {
    const gpa = std.testing.allocator;
    var active = try frozenLines(frozenSection("ACTIVE"), gpa);
    defer active.deinit(gpa);
    inline for (@typeInfo(Code).@"enum".fields) |field| {
        var found = false;
        for (active.items) |line| {
            if (std.mem.eql(u8, line, field.name)) {
                found = true;
                break;
            }
        }
        if (!found) std.debug.print("Code.{s} has no matching line in [ACTIVE]\n", .{field.name});
        try std.testing.expect(found);
    }
}

test "error_codes: every [ACTIVE] line is a Code" {
    const gpa = std.testing.allocator;
    var active = try frozenLines(frozenSection("ACTIVE"), gpa);
    defer active.deinit(gpa);
    for (active.items) |line| {
        const matched = parse(line) != null;
        if (!matched) std.debug.print("[ACTIVE] line '{s}' matches no Code field\n", .{line});
        try std.testing.expect(matched);
    }
}

test "error_codes: no Code reuses a [RETIRED] name" {
    const gpa = std.testing.allocator;
    var retired = try frozenLines(frozenSection("RETIRED"), gpa);
    defer retired.deinit(gpa);
    inline for (@typeInfo(Code).@"enum".fields) |field| {
        for (retired.items) |line| {
            if (std.mem.eql(u8, line, field.name)) {
                std.debug.print("Code.{s} reuses a RETIRED name — pick a new one\n", .{field.name});
                try std.testing.expect(false);
            }
        }
    }
}

test "error_codes: [ACTIVE] is alphabetically sorted with no duplicates" {
    const gpa = std.testing.allocator;
    var active = try frozenLines(frozenSection("ACTIVE"), gpa);
    defer active.deinit(gpa);
    for (active.items[1..], 1..) |line, i| {
        const prev = active.items[i - 1];
        if (std.mem.eql(u8, prev, line)) {
            std.debug.print("[ACTIVE] duplicate line '{s}'\n", .{line});
            try std.testing.expect(false);
        }
        if (std.mem.order(u8, prev, line) != .lt) {
            std.debug.print("[ACTIVE] not sorted: '{s}' should follow '{s}'\n", .{ prev, line });
            try std.testing.expect(false);
        }
    }
}

test "error_codes: every Code has a non-empty summary and explanation" {
    inline for (@typeInfo(Code).@"enum".fields) |field| {
        const i = info(@as(Code, @enumFromInt(field.value)));
        try std.testing.expect(i.summary.len > 0);
        try std.testing.expect(i.explanation.len > 0);
    }
}

test "error_codes: s() round-trips through parse()" {
    inline for (@typeInfo(Code).@"enum".fields) |field| {
        const c: Code = @enumFromInt(field.value);
        try std.testing.expectEqual(@as(?Code, c), parse(s(c)));
    }
    try std.testing.expectEqual(@as(?Code, null), parse("definitely_not_a_code"));
}

test "error_codes: forStatus maps every constructor's status" {
    try std.testing.expectEqual(Code.bad_request, forStatus(400));
    try std.testing.expectEqual(Code.unauthorized, forStatus(401));
    try std.testing.expectEqual(Code.forbidden, forStatus(403));
    try std.testing.expectEqual(Code.not_found, forStatus(404));
    try std.testing.expectEqual(Code.conflict, forStatus(409));
    try std.testing.expectEqual(Code.gone, forStatus(410));
    // 413 must NOT fall through to `internal`: an upload rejected for size is the
    // caller's to fix by sending less, and reporting it as a server fault sends an
    // agent into a pointless retry loop. Regression guard for that exact conflation.
    try std.testing.expectEqual(Code.payload_too_large, forStatus(413));
    try std.testing.expectEqual(Code.too_many_requests, forStatus(429));
    // Anything unmapped — including every 5xx — is `internal`, never a guess.
    try std.testing.expectEqual(Code.internal, forStatus(500));
    try std.testing.expectEqual(Code.internal, forStatus(418));
}
