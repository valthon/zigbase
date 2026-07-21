//! Pure-Zig Kotlin client generator: collections -> a ZbaseGen.kt that
//! instantiates the runtime in
//! clients/kotlin/src/main/kotlin/io/github/valthon/zigbase/typed/*.kt into
//! concrete `@Serializable` data classes, select enums, and Create/Update
//! payload models. The Kotlin counterpart of gen_python.generate; shares the
//! acquisition layer and the guard bar (guards.checkIdentifiers), and branches
//! only in emission. NB: that guard bar is TS-derived (TS identifier validity +
//! the TS typed-core reserved-name set), applied to every language as a
//! conservative lowest common denominator — NOT a language-neutral check. The
//! Kotlin-specific keyword/member sanitizing that keeps THIS output legal lives
//! in emit_kotlin.zig.
//!
//! Task 5 emitted the DATA half only (records/enums/payloads). Task 6 adds
//! the BEHAVIOR half: fluent field builders, per-collection metadata, typed
//! services, typed realtime, and the `ZbClient` façade + `createClient`
//! factory — the Kotlin counterparts of emit_python's
//! emitFields/emitMeta/emitService/emitRealtime/emitClient. Kotlin has no
//! sync/async fork (see emit_kotlin.zig's module doc), so there is only ONE
//! service/client emitted per collection/client, unlike Python's sync+async
//! pair.
const std = @import("std");
const schema = @import("../schema.zig");
const events = @import("../events.zig");
const features = @import("../features.zig");
const emit = @import("emit_kotlin.zig");
const guards = @import("guards.zig");
const gen_client = @import("gen_client.zig");

const W = std.ArrayList(u8);

/// The `io.github.valthon.zigbase.typed.TYPED_CORE_VERSION` value this
/// emitter targets — a human/tooling compatibility marker in the generated
/// header, matching the literal in
/// clients/kotlin/src/main/kotlin/io/github/valthon/zigbase/typed/Meta.kt.
/// Not read across the language boundary at build time; keep the two in sync
/// by hand (mirrors gen_python.zig's own TYPED_CORE_VERSION constant).
const TYPED_CORE_VERSION = "0.1.0";

/// Validates a `--package` value: a non-empty, dot-separated sequence of Kotlin
/// identifier segments (each segment starts with a letter or `_`, then
/// letters/digits/`_`). The value is emitted verbatim into the generated
/// `package` line, so anything else — newlines, `;`, `{`, quotes — would inject
/// arbitrary source into the output. Rejects leading/trailing/consecutive dots
/// and digit-leading segments too.
fn validatePackageName(name: []const u8) !void {
    if (name.len == 0) return error.EmptyPackageName;
    var seg_start = true;
    for (name) |c| {
        if (c == '.') {
            if (seg_start) return error.InvalidPackageName;
            seg_start = true;
            continue;
        }
        const ok = switch (c) {
            'a'...'z', 'A'...'Z', '_' => true,
            '0'...'9' => !seg_start,
            else => false,
        };
        if (!ok) return error.InvalidPackageName;
        seg_start = false;
    }
    if (seg_start) return error.InvalidPackageName;
}

/// The pure Kotlin generator core: collections -> full file text.
///
/// Signature mirrors gen_python.generate/gen_dart.generate so the CLI/build
/// threading is uniform. `routes`, `custom_auth`, `flags`, `experiments`
/// (the comptime-only surfaces) are accepted for parity but not emitted in
/// Kotlin (RPC/typed custom-auth emission is out of scope for the Kotlin SDK
/// per the SP3 plan). `in_repo`/`api_prefix` are unused (the golden lives
/// inside the client package, so the package import works regardless of
/// `in_repo`; Kotlin emits no RPC methods that would need `api_prefix`).
/// `client_name`/`auth_collection` drive the `ZbClient` façade + its
/// `createClient` factory (Task 6).
///
/// `package_name` is Kotlin-specific (the other generators have no `package`
/// concept), so it is appended LAST rather than folded into the shared
/// prefix — this generator's signature legitimately diverges from
/// gen_dart.generate/gen_python.generate here.
pub fn generate(
    gpa: std.mem.Allocator,
    cols: []const schema.Collection,
    comptime routes: []const events.RouteMeta,
    comptime custom_auth: []const events.CustomAuthMeta,
    flags: []const features.FlagDef,
    experiments: []const features.ExperimentDef,
    in_repo: bool,
    auth_collection: []const u8,
    client_name: []const u8,
    api_prefix: []const u8,
    package_name: []const u8,
) ![]const u8 {
    _ = routes;
    _ = custom_auth;
    _ = flags;
    _ = experiments;
    _ = in_repo;
    _ = api_prefix;

    // All the fragment-building below is scratch: every allocPrint/emit call
    // appends into `w` and never frees its intermediate. Rather than thread a
    // free through each (many live in cross-file emit_kotlin.zig/guards.zig),
    // own the scratch here in an arena and hand the caller a single owned copy.
    var scratch_state = std.heap.ArenaAllocator.init(gpa);
    defer scratch_state.deinit();
    const alloc = scratch_state.allocator();

    // `package_name` is interpolated straight into the generated `package`
    // line, so a value with newlines/braces/semicolons would inject arbitrary
    // source into the output — validate it is a well-formed dotted identifier.
    try validatePackageName(package_name);

    var report = guards.GuardReport{ .message = "" };
    try guards.checkOperatorNames(alloc, cols, &report);
    try guards.checkIdentifiers(alloc, cols, &report);

    var w: W = .empty;
    try w.appendSlice(alloc, try std.fmt.allocPrint(alloc,
        \\// GENERATED by zigbase — do not edit.
        \\// schema-hash: {x:0>16}
        \\// typed-core-version: {s}
        \\//
        \\// A thin, schema-aware wrapper generating @Serializable data classes over
        \\// the io.github.valthon.zigbase.typed runtime. Regenerate with your server's
        \\// `typegen --lang kotlin --package <your.package>` command (or the build-time
        \\// comptime gen-client build step), then run your project's Kotlin formatter
        \\// (e.g. spotlessApply/ktlint) over it.
        \\//
        \\// Identifier mapping: a schema name that is a Kotlin keyword gets a
        \\// trailing `_` on the KOTLIN side only (field `class` -> member
        \\// `class_`); wire keys are unchanged (a `@SerialName` carries the
        \\// original wire key whenever it differs from the sanitized member).
        \\package {s}
        \\
        \\import io.github.valthon.zigbase.AuthResponse
        \\import io.github.valthon.zigbase.FileArg
        \\import io.github.valthon.zigbase.ZbRecord
        \\import io.github.valthon.zigbase.ZigbaseClient
        \\import io.github.valthon.zigbase.auth.AuthStore
        \\import io.github.valthon.zigbase.auth.MemoryAuthStore
        \\import io.github.valthon.zigbase.typed.BoolFieldExpr
        \\import io.github.valthon.zigbase.typed.CollectionMeta
        \\import io.github.valthon.zigbase.typed.EnumFieldExpr
        \\import io.github.valthon.zigbase.typed.Expr
        \\import io.github.valthon.zigbase.typed.FieldExpr
        \\import io.github.valthon.zigbase.typed.FieldMeta
        \\import io.github.valthon.zigbase.typed.FieldType
        \\import io.github.valthon.zigbase.typed.NumberFieldExpr
        \\import io.github.valthon.zigbase.typed.NumberMode
        \\import io.github.valthon.zigbase.typed.RelFieldExpr
        \\import io.github.valthon.zigbase.typed.StringFieldExpr
        \\import io.github.valthon.zigbase.typed.TypedCollection
        \\import io.github.valthon.zigbase.typed.TypedCursorPage
        \\import io.github.valthon.zigbase.typed.TypedList
        \\import io.github.valthon.zigbase.typed.TypedRealtime
        \\import io.github.valthon.zigbase.typed.coerceBoolean
        \\import io.github.valthon.zigbase.typed.coerceDouble
        \\import io.github.valthon.zigbase.typed.coerceDoubleList
        \\import io.github.valthon.zigbase.typed.coerceLong
        \\import io.github.valthon.zigbase.typed.coerceLongList
        \\import io.github.valthon.zigbase.typed.coerceString
        \\import io.github.valthon.zigbase.typed.coerceStringList
        \\import io.github.valthon.zigbase.typed.encodeFixed
        \\import io.github.valthon.zigbase.typed.encodeInt
        \\import io.github.valthon.zigbase.typed.expandMany
        \\import io.github.valthon.zigbase.typed.expandOne
        \\import io.ktor.client.HttpClient
        \\import io.ktor.http.HttpMethod
        \\import kotlinx.coroutines.flow.Flow
        \\import kotlinx.serialization.SerialName
        \\import kotlinx.serialization.Serializable
        \\import kotlinx.serialization.json.JsonElement
        \\import kotlinx.serialization.json.JsonNull
        \\import kotlinx.serialization.json.JsonObject
        \\import kotlinx.serialization.json.JsonPrimitive
        \\import kotlinx.serialization.json.buildJsonObject
        \\import kotlinx.serialization.json.put
        \\
        \\// Extracts a plain String from a raw wire value for `<Enum>.fromWire`,
        \\// treating a missing key or an explicit JSON null as "no value" (unlike
        \\// `coerceString`, whose non-null fallback would collide with a select
        \\// value that happens to be the empty string).
        \\private fun wireStringOrNull(v: JsonElement?): String? {{
        \\    val e = (if (v == null || v is JsonNull) null else v) as? JsonPrimitive ?: return null
        \\    return if (e.isString) e.content else null
        \\}}
        \\
        \\
    , .{ gen_client.schemaHash(cols), TYPED_CORE_VERSION, package_name }));

    for (cols) |c| try emit.emitSelectEnums(alloc, &w, c);
    for (cols) |c| try emit.emitRecord(alloc, &w, cols, c);

    for (cols) |c| {
        try emit.emitCreate(alloc, &w, c);
        try emit.emitUpdate(alloc, &w, c);
    }

    for (cols) |c| try emit.emitFields(alloc, &w, cols, c);
    for (cols) |c| try emit.emitMeta(alloc, &w, c);
    for (cols) |c| try emit.emitService(alloc, &w, cols, c);
    for (cols) |c| try emit.emitRealtime(alloc, &w, c);
    try emit.emitClient(alloc, &w, cols, client_name, auth_collection);

    return gpa.dupe(u8, try w.toOwnedSlice(alloc));
}

test "generate emits a valid-looking Kotlin client for a mini blog" {
    const a = std.testing.allocator;
    const cols = [_]schema.Collection{
        .{ .id = "", .name = "users", .type = .auth, .fields = &.{
            .{ .id = "", .name = "displayName", .options = .{ .text = .{} } },
        } },
        .{ .id = "", .name = "posts", .fields = &.{
            .{ .id = "", .name = "title", .required = true, .options = .{ .text = .{} } },
            .{ .id = "", .name = "status", .options = .{ .select = .{ .values = &.{ "draft", "published" }, .maxSelect = 1 } } },
            .{ .id = "", .name = "views", .options = .{ .number = .{ .mode = .int } } },
            .{ .id = "", .name = "author", .options = .{ .relation = .{ .targetCollectionId = "users", .maxSelect = 1 } } },
            .{ .id = "", .name = "cover", .options = .{ .file = .{ .maxSelect = 1 } } },
        } },
    };
    const out = try generate(a, &cols, &.{}, &.{}, &.{}, &.{}, true, "users", "ZbClient", "/api", "io.github.valthon.zigbase.codegen.dating");
    defer a.free(out);

    // Byte-exact fragment: the enum class in full (Step 1's "byte-exact
    // expected fragment for one small collection").
    const expected_enum =
        \\@Serializable
        \\enum class PostStatus(val wire: String) {
        \\    @SerialName("draft") DRAFT("draft"),
        \\    @SerialName("published") PUBLISHED("published"),
        \\    ;
        \\
        \\    companion object {
        \\        fun fromWire(v: String?): PostStatus? = entries.firstOrNull { it.wire == v }
        \\    }
        \\}
        \\
        \\
    ;
    try std.testing.expect(std.mem.indexOf(u8, out, expected_enum) != null);

    // Spot-check the remaining key generated shapes.
    try std.testing.expect(std.mem.indexOf(u8, out, "data class Post(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "    val views: Long,\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "views = coerceLong(r[\"views\"]),") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "data class PostExpand(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "author = expandOne(r, \"author\", User::fromRecord),") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "data class PostCreate(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "data class PostUpdate(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "    val cover: FileArg? = null,\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "import io.github.valthon.zigbase.FileArg") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "import kotlinx.serialization.SerialName") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "package io.github.valthon.zigbase.codegen.dating") != null);
}

test "generate emits fields builders, meta, typed services, realtime, and the ZbClient factory" {
    const a = std.testing.allocator;
    const cols = [_]schema.Collection{
        .{ .id = "", .name = "users", .type = .auth, .fields = &.{
            .{ .id = "", .name = "displayName", .options = .{ .text = .{} } },
        } },
        .{ .id = "", .name = "posts", .fields = &.{
            .{ .id = "", .name = "title", .required = true, .options = .{ .text = .{} } },
            .{ .id = "", .name = "status", .options = .{ .select = .{ .values = &.{ "draft", "published" }, .maxSelect = 1 } } },
            .{ .id = "", .name = "views", .options = .{ .number = .{ .mode = .int } } },
            .{ .id = "", .name = "author", .options = .{ .relation = .{ .targetCollectionId = "users", .maxSelect = 1 } } },
            .{ .id = "", .name = "cover", .options = .{ .file = .{ .maxSelect = 1 } } },
        } },
    };
    const out = try generate(a, &cols, &.{}, &.{}, &.{}, &.{}, true, "users", "ZbClient", "/api", "io.github.valthon.zigbase.codegen.dating");
    defer a.free(out);

    // Byte-exact fragment: PostFields in full — covers every FieldExpr
    // subclass the generator emits (String/Enum/Number/Rel here; Bool is
    // covered by UserFields' auth-synthesized `verified` below). `cover`
    // (file) has no fluent accessor and is skipped entirely.
    const expected_fields =
        \\class PostFields(
        \\    private val prefix: String = "",
        \\) {
        \\    val title: StringFieldExpr get() = StringFieldExpr("${prefix}title")
        \\
        \\    val status: EnumFieldExpr<PostStatus> get() = EnumFieldExpr<PostStatus>("${prefix}status") { it.wire }
        \\
        \\    val views: NumberFieldExpr get() = NumberFieldExpr("${prefix}views")
        \\
        \\    val author: RelFieldExpr<UserFields> get() = RelFieldExpr<UserFields>("${prefix}author") { UserFields(it) }
        \\
        \\    val id: StringFieldExpr get() = StringFieldExpr("${prefix}id")
        \\
        \\    val created: StringFieldExpr get() = StringFieldExpr("${prefix}created")
        \\
        \\    val updated: StringFieldExpr get() = StringFieldExpr("${prefix}updated")
        \\
        \\}
        \\
        \\
    ;
    try std.testing.expect(std.mem.indexOf(u8, out, expected_fields) != null);

    // UserFields: auth-synthesized fields (email/username/verified) — the
    // BoolFieldExpr subclass the PostFields fragment above doesn't cover.
    try std.testing.expect(std.mem.indexOf(u8, out, "class UserFields(\n    private val prefix: String = \"\",\n) {\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "    val email: StringFieldExpr get() = StringFieldExpr(\"${prefix}email\")\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "    val verified: BoolFieldExpr get() = BoolFieldExpr(\"${prefix}verified\")\n") != null);
    // No fluent accessor for `displayName`'s own read-only system trailer
    // duplication, and no leaked `avatar`-style file accessor anywhere.
    try std.testing.expect(std.mem.indexOf(u8, out, "    val displayName: StringFieldExpr get() = StringFieldExpr(\"${prefix}displayName\")\n") != null);

    // postsMeta: full field map + expandable/isAuth.
    try std.testing.expect(std.mem.indexOf(u8, out, "val postsMeta =\n    CollectionMeta(\n        name = \"posts\",\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"views\" to FieldMeta(type = FieldType.NUMBER, mode = NumberMode.INTEGER),\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"cover\" to FieldMeta(type = FieldType.FILE),\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "        fileFields = listOf(\"cover\"),\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "        expandable = listOf(\"author\"),\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "        isAuth = false,\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "val usersMeta =\n    CollectionMeta(\n        name = \"users\",\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "        isAuth = true,\n") != null);

    // PostsService: constructor + the where-lambda-compiles getList pattern.
    try std.testing.expect(std.mem.indexOf(u8, out,
        \\class PostsService(
        \\    client: ZigbaseClient,
        \\) {
        \\    private val c: TypedCollection<Post> = TypedCollection(client, postsMeta, Post::fromRecord)
        \\
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, out,
        \\    suspend fun getList(
        \\        page: Int = 1,
        \\        perPage: Int = 30,
        \\        where: ((PostFields) -> Expr)? = null,
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "filter = where?.let { it(PostFields()).compile() },\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "    suspend fun create(\n        data: PostCreate,\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "    ): Post = c.create(data.toMap(), expand = expand, fields = fields)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "    fun filter(fn: (PostFields) -> Expr): String = fn(PostFields()).compile()\n") != null);

    // UsersService: the auth graft.
    try std.testing.expect(std.mem.indexOf(u8, out,
        \\    suspend fun authWithPassword(
        \\        identity: String,
        \\        password: String,
        \\    ): AuthResponse = c.collection.authWithPassword(identity, password)
        \\
    ) != null);

    // PostsService: the file-field enum + typed fileUrl (no Mapping overload
    // needed in Kotlin — see emitFileUrlMethod's doc).
    try std.testing.expect(std.mem.indexOf(u8, out,
        \\enum class PostFileField(
        \\    val wire: String,
        \\) {
        \\    COVER("cover"),
        \\}
        \\
        \\
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, out,
        \\    fun fileUrl(
        \\        record: Post,
        \\        field: PostFileField,
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "                PostFileField.COVER -> record.cover\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "ZbRecord(buildJsonObject { put(\"id\", record.id); put(\"collectionName\", \"posts\") }),\n") != null);

    // Realtime subclasses.
    try std.testing.expect(std.mem.indexOf(u8, out,
        \\class PostsRealtime(
        \\    client: ZigbaseClient,
        \\) : TypedRealtime<Post>(client, postsMeta, Post::fromRecord)
        \\
        \\
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, out,
        \\class UsersRealtime(
        \\    client: ZigbaseClient,
        \\) : TypedRealtime<User>(client, usersMeta, User::fromRecord)
        \\
        \\
    ) != null);

    // ZbClient facade + createClient factory (auth_collection defaults to "users").
    try std.testing.expect(std.mem.indexOf(u8, out,
        \\class ZbClient(
        \\    val raw: ZigbaseClient,
        \\    val owned: Boolean = false,
        \\) : AutoCloseable {
        \\    val users: UsersService by lazy { UsersService(raw) }
        \\    val posts: PostsService by lazy { PostsService(raw) }
        \\
        \\    val usersRealtime: UsersRealtime by lazy { UsersRealtime(raw) }
        \\    val postsRealtime: PostsRealtime by lazy { PostsRealtime(raw) }
        \\
        \\    val authStore: AuthStore get() = raw.authStore
        \\
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "    override fun close() {\n        if (owned) raw.close()\n    }\n}\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out,
        \\fun createClient(
        \\    url: String,
        \\    authStore: AuthStore = MemoryAuthStore(),
        \\    autoRefresh: Boolean = false,
        \\    authCollection: String? = "users",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "): ZbClient =\n    ZbClient(\n        ZigbaseClient(\n") != null);
}

test "json field type is single-nullable everywhere (record AND payload) — not JsonElement??" {
    const a = std.testing.allocator;
    const cols = [_]schema.Collection{
        .{ .id = "", .name = "widgets", .fields = &.{
            .{ .id = "", .name = "metadata", .options = .{ .json = .{} } },
        } },
    };
    const out = try generate(a, &cols, &.{}, &.{}, &.{}, &.{}, true, "", "ZbClient", "/api", "io.github.valthon.zigbase.codegen.dating");
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "val metadata: JsonElement?,\n") != null); // record (required)
    try std.testing.expect(std.mem.indexOf(u8, out, "val metadata: JsonElement? = null,\n") != null); // Create/Update (optional)
    try std.testing.expect(std.mem.indexOf(u8, out, "JsonElement??") == null);
}

test "Kotlin keywords are sanitized (wire keys unchanged)" {
    const a = std.testing.allocator;
    const cols = [_]schema.Collection{
        .{ .id = "", .name = "users", .type = .auth, .fields = &.{} },
        // `class`/`object` are Kotlin keywords; `expand` collides with the
        // generated record member.
        .{ .id = "", .name = "raw", .fields = &.{
            .{ .id = "", .name = "class", .required = true, .options = .{ .text = .{} } },
            .{ .id = "", .name = "object", .options = .{ .number = .{ .mode = .int } } },
            .{ .id = "", .name = "expand", .options = .{ .text = .{} } },
            .{ .id = "", .name = "author", .options = .{ .relation = .{ .targetCollectionId = "users", .maxSelect = 1 } } },
        } },
    };
    const out = try generate(a, &cols, &.{}, &.{}, &.{}, &.{}, true, "users", "ZbClient", "/api", "io.github.valthon.zigbase.codegen.dating");
    defer a.free(out);
    // Record members: keyword-sanitized Kotlin identifier, wire key untouched via @SerialName.
    try std.testing.expect(std.mem.indexOf(u8, out, "    val class_: String,\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "    val object_: Long,\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "    val expand_: String,\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "@SerialName(\"class\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "@SerialName(\"object\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "@SerialName(\"expand\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "class_ = coerceString(r[\"class\"]),") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "object_ = coerceLong(r[\"object\"]),") != null);
    // No unsanitized keyword member leaked.
    try std.testing.expect(std.mem.indexOf(u8, out, "val class: String") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "val object: Long") == null);
    // Payload: required field's to_map keeps the wire key.
    try std.testing.expect(std.mem.indexOf(u8, out, "m[\"class\"] = class_") != null);
}

test "select values differing only in case collide into one Kotlin enum entry — a generation error" {
    const a = std.testing.allocator;
    // "active" and "ACTIVE" both uppercase to the enum entry ACTIVE — the
    // second would silently overwrite the first's `("active")` line with
    // `("ACTIVE")` if generation didn't dedup-check before emitting.
    const cols = [_]schema.Collection{
        .{ .id = "", .name = "posts", .fields = &.{
            .{ .id = "", .name = "status", .options = .{ .select = .{ .values = &.{ "active", "ACTIVE" }, .maxSelect = 1 } } },
        } },
    };
    try std.testing.expectError(
        error.KotlinIdentCollision,
        generate(a, &cols, &.{}, &.{}, &.{}, &.{}, true, "", "ZbClient", "/api", "io.github.valthon.zigbase.codegen.dating"),
    );
}

test "two schema names mapping to one Kotlin identifier is a generation error" {
    const a = std.testing.allocator;
    const cols = [_]schema.Collection{
        .{ .id = "", .name = "posts", .fields = &.{
            .{ .id = "", .name = "class", .options = .{ .text = .{} } },
            .{ .id = "", .name = "class_", .options = .{ .text = .{} } },
        } },
    };
    try std.testing.expectError(
        error.KotlinIdentCollision,
        generate(a, &cols, &.{}, &.{}, &.{}, &.{}, true, "", "ZbClient", "/api", "io.github.valthon.zigbase.codegen.dating"),
    );
}

test "a collection with no eligible payload field emits a plain class, not an invalid zero-param data class" {
    const a = std.testing.allocator;
    // `hidden` field is excluded from BOTH Create and Update; a non-auth
    // collection whose only field is hidden has nothing left to carry.
    const cols = [_]schema.Collection{
        .{ .id = "", .name = "ghosts", .fields = &.{
            .{ .id = "", .name = "secret", .hidden = true, .options = .{ .text = .{} } },
        } },
    };
    const out = try generate(a, &cols, &.{}, &.{}, &.{}, &.{}, true, "", "ZbClient", "/api", "io.github.valthon.zigbase.codegen.dating");
    defer a.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "class GhostCreate {\n    fun toMap(): Map<String, Any?> = emptyMap()\n}\n\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "class GhostUpdate {\n    fun toMap(): Map<String, Any?> = emptyMap()\n}\n\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "data class GhostCreate(") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "data class GhostUpdate(") == null);
}

test "generate emits the caller-supplied package name, overriding the dating default" {
    const a = std.testing.allocator;
    const cols = [_]schema.Collection{
        .{ .id = "", .name = "posts", .fields = &.{
            .{ .id = "", .name = "title", .options = .{ .text = .{} } },
        } },
    };
    const out = try generate(a, &cols, &.{}, &.{}, &.{}, &.{}, true, "", "ZbClient", "/api", "com.example.app");
    defer a.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "package com.example.app") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "package io.github.valthon.zigbase.codegen.dating") == null);
}

test "generate rejects an empty or injection-y --package value" {
    const a = std.testing.allocator;
    const cols = [_]schema.Collection{
        .{ .id = "", .name = "posts", .fields = &.{
            .{ .id = "", .name = "title", .options = .{ .text = .{} } },
        } },
    };
    const gen = struct {
        fn call(al: std.mem.Allocator, c: []const schema.Collection, pkg: []const u8) ![]const u8 {
            return generate(al, c, &.{}, &.{}, &.{}, &.{}, true, "", "ZbClient", "/api", pkg);
        }
    }.call;
    try std.testing.expectError(error.EmptyPackageName, gen(a, &cols, ""));
    // Injection vectors: semicolon, newline+code, braces/quotes.
    try std.testing.expectError(error.InvalidPackageName, gen(a, &cols, "com.example;evil"));
    try std.testing.expectError(error.InvalidPackageName, gen(a, &cols, "com.example\npublic fun x() {}"));
    // Malformed dotted identifiers.
    try std.testing.expectError(error.InvalidPackageName, gen(a, &cols, ".leading"));
    try std.testing.expectError(error.InvalidPackageName, gen(a, &cols, "trailing."));
    try std.testing.expectError(error.InvalidPackageName, gen(a, &cols, "a..b"));
    try std.testing.expectError(error.InvalidPackageName, gen(a, &cols, "1abc.def"));
    // A well-formed package still generates.
    const ok = try gen(a, &cols, "com.example.app_2");
    a.free(ok);
}
