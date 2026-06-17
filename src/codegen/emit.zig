//! Emit-helpers: one fn per TS fragment, each appending to a *std.ArrayList(u8).
//! Every fragment mirrors clients/typescript/test/fixtures/blog.gen.ts.
const std = @import("std");
const schema = @import("../schema.zig");
const tt = @import("ts_type.zig");
const ident = @import("identifiers.zig");

const W = std.ArrayList(u8);

fn put(alloc: std.mem.Allocator, w: *W, s: []const u8) !void {
    try w.appendSlice(alloc, s);
}
fn putf(alloc: std.mem.Allocator, w: *W, comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(alloc, fmt, args);
    try w.appendSlice(alloc, s);
}

/// Returns true for the synthesized read-only system field names that are NOT
/// user-declared fields: id, created, updated.  Used in emitRecord / emitMeta
/// to avoid duplicating the fields that are always appended at the end.
fn isReadOnlySystem(name: []const u8) bool {
    return std.mem.eql(u8, name, "id") or
        std.mem.eql(u8, name, "created") or
        std.mem.eql(u8, name, "updated");
}

/// The visible synthesized auth fields for an auth collection record.
/// Always emits email + username + verified (B3: unconditional synthesis —
/// buildCollections does not propagate identityFields at comptime, so we cannot
/// gate username; the dating snapshot is the authority for the full set).
fn appendVisibleAuthFields(alloc: std.mem.Allocator, list: *std.ArrayList(schema.Field)) !void {
    try list.append(alloc, .{ .id = "_email", .name = "email", .options = .{ .email = .{} } });
    try list.append(alloc, .{ .id = "_username", .name = "username", .options = .{ .text = .{} } });
    try list.append(alloc, .{ .id = "_verified", .name = "verified", .options = .{ .@"bool" = .{} } });
}

/// The record fields, in emission order: id, (auth visible fields), user fields,
/// created, updated.  User-declared fields named id/created/updated are deduplicated
/// (isReadOnlySystem) since we always append them at the end.
fn recordFields(alloc: std.mem.Allocator, c: schema.Collection) ![]schema.Field {
    var list: std.ArrayList(schema.Field) = .empty;
    try list.append(alloc, .{ .id = "_id", .name = "id", .options = .{ .text = .{} } });
    if (c.type == .auth) try appendVisibleAuthFields(alloc, &list);
    for (c.fields) |f| {
        if (f.hidden) continue;
        if (isReadOnlySystem(f.name)) continue; // dedup: created/updated always appended below
        try list.append(alloc, f);
    }
    try list.append(alloc, .{ .id = "_created", .name = "created", .options = .{ .autodate = .{} } });
    try list.append(alloc, .{ .id = "_updated", .name = "updated", .options = .{ .autodate = .{} } });
    return list.toOwnedSlice(alloc);
}

// ---------------------------------------------------------------------------
// Select unions
// ---------------------------------------------------------------------------

pub fn emitSelectUnions(alloc: std.mem.Allocator, w: *W, c: schema.Collection) !void {
    for (c.fields) |f| {
        if (f.options != .select) continue;
        const uname = try tt.selectUnionName(alloc, c.name, f.name);
        try putf(alloc, w, "export type {s} = ", .{uname});
        for (f.options.select.values, 0..) |v, i| {
            if (i != 0) try put(alloc, w, " | ");
            try putf(alloc, w, "\"{s}\"", .{v});
        }
        try put(alloc, w, ";\n");
    }
}

// ---------------------------------------------------------------------------
// Record interface
// ---------------------------------------------------------------------------

pub fn emitRecord(alloc: std.mem.Allocator, w: *W, c: schema.Collection) !void {
    const rec = try ident.recordName(alloc, c.name);
    try putf(alloc, w, "export interface {s} {{\n", .{rec});
    for (try recordFields(alloc, c)) |f| {
        const ty = try tt.tsTypeOf(alloc, c.name, f);
        try putf(alloc, w, "  {s}: {s};\n", .{ f.name, ty });
    }
    try put(alloc, w, "}\n");
}

// ---------------------------------------------------------------------------
// Create / Update payloads
// ---------------------------------------------------------------------------

/// In *Create, file fields become `File | Blob` (single) or `(File | Blob)[]` (multi).
fn createFieldType(alloc: std.mem.Allocator, col: []const u8, f: schema.Field) ![]const u8 {
    if (tt.kindOf(f) == .file_name) {
        if (f.isMultiValue()) return "(File | Blob)[]";
        return "File | Blob";
    }
    return tt.tsTypeOf(alloc, col, f);
}

pub fn emitCreate(alloc: std.mem.Allocator, w: *W, c: schema.Collection) !void {
    const cn = try ident.createName(alloc, c.name);
    try putf(alloc, w, "export interface {s} {{\n", .{cn});
    if (c.type == .auth) {
        try put(alloc, w, "  email: string;\n  password: string;\n  passwordConfirm: string;\n");
    }
    // Required user fields first (no '?'), then optionals.
    for (c.fields) |f| {
        if (f.hidden or isReadOnlySystem(f.name) or !f.required) continue;
        try putf(alloc, w, "  {s}: {s};\n", .{ f.name, try createFieldType(alloc, c.name, f) });
    }
    for (c.fields) |f| {
        if (f.hidden or isReadOnlySystem(f.name) or f.required) continue;
        try putf(alloc, w, "  {s}?: {s};\n", .{ f.name, try createFieldType(alloc, c.name, f) });
    }
    try put(alloc, w, "}\n");
}

pub fn emitUpdate(alloc: std.mem.Allocator, w: *W, c: schema.Collection) !void {
    const un = try ident.updateName(alloc, c.name);
    const cn = try ident.createName(alloc, c.name);
    if (c.type == .auth) {
        try putf(alloc, w, "export type {s} = Partial<Omit<{s}, \"password\" | \"passwordConfirm\">>;\n", .{ un, cn });
    } else {
        try putf(alloc, w, "export type {s} = Partial<{s}>;\n", .{ un, cn });
    }
}

// ---------------------------------------------------------------------------
// Where types
// ---------------------------------------------------------------------------

fn collectionExists(cols: []const schema.Collection, name: []const u8) bool {
    for (cols) |c| if (std.mem.eql(u8, c.name, name)) return true;
    return false;
}

pub fn emitWhere(alloc: std.mem.Allocator, w: *W, cols: []const schema.Collection, c: schema.Collection) !void {
    const wn = try ident.whereName(alloc, c.name);
    try putf(alloc, w, "export interface {s} {{\n", .{wn});
    // Auth synthesized: email + username + verified always (B3: unconditional synthesis).
    if (c.type == .auth) {
        try put(alloc, w, "  email?: StringOps | string;\n");
        try put(alloc, w, "  username?: StringOps | string;\n");
        try put(alloc, w, "  verified?: boolean;\n");
    }
    // User-declared fields.  We do NOT apply isReadOnlySystem here: c.fields contains
    // only user-declared fields; schema validation prevents real id/created/updated
    // clashes, and unit-test fixtures may declare a `created` autodate (filterable).
    for (c.fields) |f| {
        if (f.hidden) continue;
        switch (tt.kindOf(f)) {
            .file_name => continue, // file fields omitted from where
            .string => try putf(alloc, w, "  {s}?: StringOps | string;\n", .{f.name}),
            .number => try putf(alloc, w, "  {s}?: NumberOps | number;\n", .{f.name}),
            .boolean => try putf(alloc, w, "  {s}?: boolean;\n", .{f.name}),
            .unknown => try putf(alloc, w, "  {s}?: unknown;\n", .{f.name}),
            .select_union => {
                const u = try tt.selectUnionName(alloc, c.name, f.name);
                try putf(alloc, w, "  {s}?: EnumOps<{s}> | {s};\n", .{ f.name, u, u });
            },
            .relation_id => {
                const target = f.options.relation.targetCollectionId;
                if (!f.isMultiValue() and collectionExists(cols, target)) {
                    const tw = try ident.whereName(alloc, target);
                    try putf(alloc, w, "  {s}?: string | RelOps | {s};\n", .{ f.name, tw });
                } else {
                    try putf(alloc, w, "  {s}?: string | RelOps;\n", .{f.name});
                }
            },
        }
    }
    try putf(alloc, w, "  AND?: {s}[];\n  OR?: {s}[];\n}}\n", .{ wn, wn });
}

// ---------------------------------------------------------------------------
// Relations + expand keys
// ---------------------------------------------------------------------------

fn hasRelations(c: schema.Collection) bool {
    for (c.fields) |f| if (f.options == .relation) return true;
    return false;
}

pub fn emitRelations(alloc: std.mem.Allocator, w: *W, cols: []const schema.Collection, c: schema.Collection) !void {
    if (!hasRelations(c)) return;
    const rn = try ident.relationsName(alloc, c.name);
    try putf(alloc, w, "export type {s} = {{ ", .{rn});
    var first = true;
    for (c.fields) |f| {
        if (f.options != .relation) continue;
        if (!collectionExists(cols, f.options.relation.targetCollectionId)) continue;
        const tr = try ident.recordName(alloc, f.options.relation.targetCollectionId);
        if (!first) try put(alloc, w, "; ");
        first = false;
        if (f.isMultiValue()) {
            try putf(alloc, w, "{s}: {s}[]", .{ f.name, tr });
        } else {
            try putf(alloc, w, "{s}: {s}", .{ f.name, tr });
        }
    }
    try put(alloc, w, " };\n");
}

pub fn emitExpandKeys(alloc: std.mem.Allocator, w: *W, c: schema.Collection) !void {
    if (!hasRelations(c)) return;
    const en = try ident.expandName(alloc, c.name);
    try putf(alloc, w, "export type {s} = ", .{en});
    var first = true;
    for (c.fields) |f| {
        if (f.options != .relation) continue;
        if (!first) try put(alloc, w, " | ");
        first = false;
        try putf(alloc, w, "\"{s}\"", .{f.name});
    }
    try put(alloc, w, ";\n");
}

// ---------------------------------------------------------------------------
// Fluent accessor fields interface
// ---------------------------------------------------------------------------

pub fn emitFields(alloc: std.mem.Allocator, w: *W, c: schema.Collection) !void {
    const fn_ = try ident.fieldsName(alloc, c.name);
    try putf(alloc, w, "export interface {s} {{\n", .{fn_});
    // Auth: always emit all three visible fields (B3: unconditional synthesis).
    if (c.type == .auth) {
        try put(alloc, w, "  email: TypedFieldExpr<string>;\n");
        try put(alloc, w, "  username: TypedFieldExpr<string>;\n");
        try put(alloc, w, "  verified: TypedFieldExpr<boolean>;\n");
    }
    // User-declared fields.  No isReadOnlySystem filter here for same reason as
    // emitWhere: user fields don't include system fields; schema validation guards
    // against naming conflicts.
    for (c.fields) |f| {
        if (f.hidden or tt.kindOf(f) == .file_name) continue;
        const base = try tt.tsBaseTypeOf(alloc, c.name, f);
        try putf(alloc, w, "  {s}: TypedFieldExpr<{s}>;\n", .{ f.name, base });
    }
    try put(alloc, w, "}\n");
}

// ---------------------------------------------------------------------------
// Concrete service interfaces
// ---------------------------------------------------------------------------

pub fn emitService(alloc: std.mem.Allocator, w: *W, c: schema.Collection) !void {
    const svc = try ident.serviceName(alloc, c.name);
    const rec = try ident.recordName(alloc, c.name);
    const wn = try ident.whereName(alloc, c.name);
    const fld = try ident.fieldsName(alloc, c.name);
    try putf(alloc, w, "export interface {s} {{\n", .{svc});
    if (hasRelations(c)) {
        const exp = try ident.expandName(alloc, c.name);
        const rel = try ident.relationsName(alloc, c.name);
        try putf(alloc, w,
            \\  getOne<K extends {0s} = never>(
            \\    id: string,
            \\    opts?: {{ expand?: K[]; fields?: string; signal?: AbortSignal }},
            \\  ): Promise<WithExpand<{1s}, {2s}, K>>;
            \\  getList<K extends {0s} = never>(opts?: {{
            \\    where?: {3s};
            \\    sort?: string;
            \\    expand?: K[];
            \\    page?: number;
            \\    limit?: number;
            \\    fields?: string;
            \\    signal?: AbortSignal;
            \\  }}): Promise<ListResult<WithExpand<{1s}, {2s}, K>>>;
            \\  getFirstListItem<K extends {0s} = never>(opts?: {{
            \\    where?: {3s};
            \\    sort?: string;
            \\    expand?: K[];
            \\  }}): Promise<WithExpand<{1s}, {2s}, K>>;
            \\  getPage(opts?: {{
            \\    where?: {3s};
            \\    sort?: string;
            \\    limit?: number;
            \\    cursor?: string;
            \\    withTotal?: boolean;
            \\  }}): Promise<CursorPage<{1s}>>;
            \\  iterate(opts?: {{ where?: {3s}; sort?: string }}): AsyncIterableIterator<{1s}>;
            \\  getFullList(opts?: {{ where?: {3s}; sort?: string }}): Promise<{1s}[]>;
            \\  create<K extends {0s} = never>(
            \\    data: {4s},
            \\    opts?: {{ expand?: K[]; fields?: string; signal?: AbortSignal; requestKey?: string }},
            \\  ): Promise<WithExpand<{1s}, {2s}, K>>;
            \\  update<K extends {0s} = never>(
            \\    id: string,
            \\    data: {5s},
            \\    opts?: {{ expand?: K[]; fields?: string; signal?: AbortSignal; requestKey?: string }},
            \\  ): Promise<WithExpand<{1s}, {2s}, K>>;
            \\  delete(id: string): Promise<void>;
            \\  filter(fn: (f: {6s}) => Expr): string;
            \\
        , .{ exp, rec, rel, wn, try ident.createName(alloc, c.name), try ident.updateName(alloc, c.name), fld });
    } else {
        try putf(alloc, w,
            \\  getOne(id: string, opts?: {{ fields?: string }}): Promise<{0s}>;
            \\  getList(opts?: {{ where?: {1s}; sort?: string; page?: number; limit?: number }}): Promise<ListResult<{0s}>>;
            \\  getFirstListItem(opts?: {{ where?: {1s} }}): Promise<{0s}>;
            \\  getPage(opts?: {{ where?: {1s}; limit?: number; cursor?: string }}): Promise<CursorPage<{0s}>>;
            \\  create(
            \\    data: {2s},
            \\    opts?: {{ fields?: string; signal?: AbortSignal; requestKey?: string }},
            \\  ): Promise<{0s}>;
            \\  update(
            \\    id: string,
            \\    data: {3s},
            \\    opts?: {{ fields?: string; signal?: AbortSignal; requestKey?: string }},
            \\  ): Promise<{0s}>;
            \\  delete(id: string): Promise<void>;
            \\  filter(fn: (f: {4s}) => Expr): string;
            \\
        , .{ rec, wn, try ident.createName(alloc, c.name), try ident.updateName(alloc, c.name), fld });
    }
    if (c.type == .auth) {
        try putf(alloc, w,
            \\  authWithPassword(
            \\    identity: string,
            \\    password: string,
            \\  ): Promise<{{ token: string; record: {s} }}>;
            \\
        , .{rec});
    }
    try put(alloc, w, "}\n");
}

// ---------------------------------------------------------------------------
// Realtime alias
// ---------------------------------------------------------------------------

pub fn emitRealtimeAlias(alloc: std.mem.Allocator, w: *W, c: schema.Collection) !void {
    const rt = try ident.realtimeAliasName(alloc, c.name);
    const rec = try ident.recordName(alloc, c.name);
    const wn = try ident.whereName(alloc, c.name);
    try putf(alloc, w, "export type {s} = RawTypedRealtime<{s}, {s}>;\n", .{ rt, rec, wn });
}

// ---------------------------------------------------------------------------
// Per-collection metadata const
// ---------------------------------------------------------------------------

pub fn emitMeta(alloc: std.mem.Allocator, w: *W, c: schema.Collection) !void {
    const mc = try ident.metaConst(alloc, c.name);
    try putf(alloc, w, "export const {s}: CollectionMeta = {{\n  name: \"{s}\",\n  fields: {{\n", .{ mc, c.name });
    // meta.fields = auth visible (email+username+verified, unconditional) +
    //               user fields (non-hidden, non-read-only-system) +
    //               created + updated (always appended).
    var metaFields: std.ArrayList(schema.Field) = .empty;
    if (c.type == .auth) try appendVisibleAuthFields(alloc, &metaFields);
    for (c.fields) |f| {
        if (f.hidden or isReadOnlySystem(f.name)) continue;
        try metaFields.append(alloc, f);
    }
    try metaFields.append(alloc, .{ .id = "_created", .name = "created", .options = .{ .autodate = .{} } });
    try metaFields.append(alloc, .{ .id = "_updated", .name = "updated", .options = .{ .autodate = .{} } });
    for (metaFields.items) |f| {
        const tag = @tagName(std.meta.activeTag(f.options));
        if (f.isMultiValue()) {
            try putf(alloc, w, "    {s}: {{ type: \"{s}\", multi: true }},\n", .{ f.name, tag });
        } else {
            try putf(alloc, w, "    {s}: {{ type: \"{s}\" }},\n", .{ f.name, tag });
        }
    }
    try put(alloc, w, "  },\n  fileFields: [");
    var first = true;
    for (c.fields) |f| {
        if (tt.kindOf(f) != .file_name) continue;
        if (!first) try put(alloc, w, ", ");
        first = false;
        try putf(alloc, w, "\"{s}\"", .{f.name});
    }
    try put(alloc, w, "],\n  expandable: [");
    first = true;
    for (c.fields) |f| {
        if (f.options != .relation) continue;
        if (!first) try put(alloc, w, ", ");
        first = false;
        try putf(alloc, w, "\"{s}\"", .{f.name});
    }
    try putf(alloc, w, "],\n  isAuth: {s},\n}};\n", .{if (c.type == .auth) "true" else "false"});
}

// ---------------------------------------------------------------------------
// Imports
// ---------------------------------------------------------------------------

pub fn emitImports(alloc: std.mem.Allocator, w: *W, in_repo: bool) !void {
    if (in_repo) {
        try put(alloc, w,
            \\import { createClient as baseCreateClient, type Client } from "../../../src/index.js";
            \\import { withRealtime, type RealtimeEnabledClient } from "../../../src/realtime-entry.js";
            \\import type { ListResult } from "../../../src/records.js";
            \\import type { CursorPage } from "../../../src/cursor.js";
            \\import type { FileUrlOptions } from "../../../src/files.js";
            \\import {
            \\  makeRecordService,
            \\  makeTypedRealtime,
            \\  makeTypedFiles,
            \\  type CollectionMeta,
            \\  type WithExpand,
            \\  type StringOps,
            \\  type NumberOps,
            \\  type EnumOps,
            \\  type RelOps,
            \\  type Expr,
            \\  type FieldExpr,
            \\  type TypedFieldExpr,
            \\  type RelationResolver,
            \\  type RawTypedRealtime,
            \\} from "../../../src/typed/index.js";
            \\
        );
    } else {
        try put(alloc, w,
            \\import { createClient as baseCreateClient, type Client } from "@zigbase/client";
            \\import { withRealtime, type RealtimeEnabledClient } from "@zigbase/client/realtime";
            \\import type { ListResult, CursorPage, FileUrlOptions } from "@zigbase/client";
            \\import {
            \\  makeRecordService,
            \\  makeTypedRealtime,
            \\  makeTypedFiles,
            \\  type CollectionMeta,
            \\  type WithExpand,
            \\  type StringOps,
            \\  type NumberOps,
            \\  type EnumOps,
            \\  type RelOps,
            \\  type Expr,
            \\  type FieldExpr,
            \\  type TypedFieldExpr,
            \\  type RelationResolver,
            \\  type RawTypedRealtime,
            \\} from "@zigbase/client/typed";
            \\
        );
    }
}

// ---------------------------------------------------------------------------
// Relation resolver
// ---------------------------------------------------------------------------

pub fn emitRelationResolver(alloc: std.mem.Allocator, w: *W, cols: []const schema.Collection) !void {
    try put(alloc, w, "const relationResolver: RelationResolver = (collection, field) => {\n");
    for (cols) |c| {
        for (c.fields) |f| {
            if (f.options != .relation) continue;
            const target = f.options.relation.targetCollectionId;
            if (!collectionExists(cols, target)) continue;
            const tmeta = try ident.metaConst(alloc, target);
            try putf(alloc, w, "  if (collection === \"{s}\" && field === \"{s}\") return {s};\n", .{ c.name, f.name, tmeta });
        }
    }
    try put(alloc, w, "  return undefined;\n};\n");
}

// ---------------------------------------------------------------------------
// Typed files surface
// ---------------------------------------------------------------------------

pub fn emitTypedFiles(alloc: std.mem.Allocator, w: *W, cols: []const schema.Collection) !void {
    // Step 1: Per-collection file-field unions (e.g. `export type PostFileField = "cover";`).
    for (cols) |c| {
        var any = false;
        for (c.fields) |f| if (tt.kindOf(f) == .file_name) {
            any = true;
        };
        if (!any) continue;
        const rec = try ident.recordName(alloc, c.name);
        try putf(alloc, w, "export type {s}FileField = ", .{rec});
        var first = true;
        for (c.fields) |f| {
            if (tt.kindOf(f) != .file_name) continue;
            if (!first) try put(alloc, w, " | ");
            first = false;
            try putf(alloc, w, "\"{s}\"", .{f.name});
        }
        try put(alloc, w, ";\n");
    }

    // Step 2: TypedFiles interface — one `url` overload per file-bearing collection.
    try put(alloc, w, "\nexport interface TypedFiles {\n");
    for (cols) |c| {
        var any = false;
        for (c.fields) |f| if (tt.kindOf(f) == .file_name) {
            any = true;
        };
        if (!any) continue;
        const rec = try ident.recordName(alloc, c.name);
        try putf(alloc, w,
            "  url(record: {0s}, field: {0s}FileField, opts?: FileUrlOptions): string;\n",
            .{rec});
    }
    try put(alloc, w, "}\n");

    // Step 3: makeFilesSurface(typedFiles) — factory closure that reads
    // `record[field]` and calls `typedFiles.fileUrl(...)`.
    try put(alloc, w, "\nfunction makeFilesSurface(typedFiles: ReturnType<typeof makeTypedFiles>): TypedFiles {\n  return {\n");
    for (cols) |c| {
        var any = false;
        for (c.fields) |f| if (tt.kindOf(f) == .file_name) {
            any = true;
        };
        if (!any) continue;
        try putf(alloc, w,
            \\    url(record, field, opts) {{
            \\      const filename = (record as unknown as Record<string, string>)[field] ?? "";
            \\      return typedFiles.fileUrl(
            \\        {{ id: (record as {{ id: string }}).id, collectionName: "{s}" }},
            \\        filename,
            \\        opts,
            \\      );
            \\    }},
            \\
        , .{c.name});
    }
    try put(alloc, w, "  };\n}\n");
}

// ---------------------------------------------------------------------------
// Client factory (full body implemented in Task 5; stub with correct signature)
// ---------------------------------------------------------------------------

pub fn emitClientFactory(alloc: std.mem.Allocator, w: *W, cols: []const schema.Collection, client_name: []const u8, auth_collection: []const u8) !void {
    _ = alloc;
    _ = w;
    _ = cols;
    _ = client_name;
    _ = auth_collection;
    // Full body emitted in Task 5 (gen_client.zig / main()).
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn blogPosts() schema.Collection {
    const fields = [_]schema.Field{
        .{ .id = "a", .name = "title", .required = true, .options = .{ .text = .{} } },
        .{ .id = "b", .name = "status", .options = .{ .select = .{ .values = &.{ "draft", "published" }, .maxSelect = 1 } } },
        .{ .id = "c", .name = "price", .options = .{ .number = .{} } },
        .{ .id = "d", .name = "author", .options = .{ .relation = .{ .targetCollectionId = "users", .maxSelect = 1 } } },
        .{ .id = "e", .name = "tags", .options = .{ .relation = .{ .targetCollectionId = "tags", .maxSelect = 99 } } },
        .{ .id = "f", .name = "cover", .options = .{ .file = .{ .maxSelect = 1 } } },
        .{ .id = "g", .name = "created", .options = .{ .autodate = .{} } },
    };
    return .{ .id = "", .name = "posts", .fields = &fields };
}

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

test "emitRecord matches Post shape" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var w: std.ArrayList(u8) = .empty;
    try emitRecord(a, &w, blogPosts());
    const out = w.items;
    try std.testing.expect(contains(out, "export interface Post {"));
    try std.testing.expect(contains(out, "id: string;"));
    try std.testing.expect(contains(out, "title: string;"));
    try std.testing.expect(contains(out, "status: PostStatus;"));
    try std.testing.expect(contains(out, "price: number;"));
    try std.testing.expect(contains(out, "author: string;"));
    try std.testing.expect(contains(out, "tags: string[];"));
    try std.testing.expect(contains(out, "cover: string;"));
    try std.testing.expect(contains(out, "created: string;"));
    try std.testing.expect(contains(out, "updated: string;"));
}

test "emitSelectUnions matches PostStatus" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var w: std.ArrayList(u8) = .empty;
    try emitSelectUnions(a, &w, blogPosts());
    try std.testing.expect(contains(w.items, "export type PostStatus = \"draft\" | \"published\";"));
}

test "emitCreate matches PostCreate (required first, file -> File | Blob)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var w: std.ArrayList(u8) = .empty;
    try emitCreate(a, &w, blogPosts());
    const out = w.items;
    try std.testing.expect(contains(out, "export interface PostCreate {"));
    try std.testing.expect(contains(out, "title: string;")); // required, no ?
    try std.testing.expect(contains(out, "status?: PostStatus;"));
    try std.testing.expect(contains(out, "price?: number;"));
    try std.testing.expect(contains(out, "author?: string;"));
    try std.testing.expect(contains(out, "tags?: string[];"));
    try std.testing.expect(contains(out, "cover?: File | Blob;"));
    try std.testing.expect(!contains(out, "created")); // read-only excluded
}

test "emitWhere matches PostWhere (nested relation, multi id-only, file omitted)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const users = schema.Collection{ .id = "", .name = "users", .type = .auth, .fields = &.{} };
    const tags = schema.Collection{ .id = "", .name = "tags", .fields = &.{} };
    const cols = [_]schema.Collection{ blogPosts(), users, tags };
    var w: std.ArrayList(u8) = .empty;
    try emitWhere(a, &w, &cols, blogPosts());
    const out = w.items;
    try std.testing.expect(contains(out, "export interface PostWhere {"));
    try std.testing.expect(contains(out, "title?: StringOps | string;"));
    try std.testing.expect(contains(out, "status?: EnumOps<PostStatus> | PostStatus;"));
    try std.testing.expect(contains(out, "price?: NumberOps | number;"));
    try std.testing.expect(contains(out, "author?: string | RelOps | UserWhere;"));
    try std.testing.expect(contains(out, "tags?: string | RelOps;"));
    try std.testing.expect(contains(out, "created?: StringOps | string;"));
    try std.testing.expect(contains(out, "AND?: PostWhere[];"));
    try std.testing.expect(contains(out, "OR?: PostWhere[];"));
    try std.testing.expect(!contains(out, "cover")); // file omitted from where
}

test "emitService (expandable) has the getOne<K extends PostExpand = never> shape" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var w: std.ArrayList(u8) = .empty;
    try emitService(a, &w, blogPosts());
    const out = w.items;
    try std.testing.expect(contains(out, "export interface PostsService {"));
    try std.testing.expect(contains(out, "getOne<K extends PostExpand = never>("));
    try std.testing.expect(contains(out, "Promise<WithExpand<Post, PostRelations, K>>"));
    try std.testing.expect(contains(out, "getPage(opts?: {"));
    try std.testing.expect(contains(out, "Promise<CursorPage<Post>>"));
    try std.testing.expect(contains(out, "filter(fn: (f: PostFields) => Expr): string;"));
}

test "emitMeta matches postsMeta" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var w: std.ArrayList(u8) = .empty;
    try emitMeta(a, &w, blogPosts());
    const out = w.items;
    try std.testing.expect(contains(out, "export const postsMeta: CollectionMeta = {"));
    try std.testing.expect(contains(out, "name: \"posts\","));
    try std.testing.expect(contains(out, "tags: { type: \"relation\", multi: true },"));
    try std.testing.expect(contains(out, "fileFields: [\"cover\"],"));
    try std.testing.expect(contains(out, "expandable: [\"author\", \"tags\"],"));
    try std.testing.expect(contains(out, "isAuth: false,"));
}

test "emitRealtimeAlias matches the generic alias" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var w: std.ArrayList(u8) = .empty;
    try emitRealtimeAlias(a, &w, blogPosts());
    try std.testing.expect(contains(w.items, "export type PostsRealtime = RawTypedRealtime<Post, PostWhere>;"));
}

test "emitTypedFiles emits FileField union + TypedFiles interface + makeFilesSurface" {
    // B2: emitTypedFiles must emit all three pieces so emitClientFactory's
    // `files: makeFilesSurface(typedFiles)` and the `TypedFiles` type resolve.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cols = [_]schema.Collection{blogPosts()};
    var w: std.ArrayList(u8) = .empty;
    try emitTypedFiles(a, &w, &cols);
    const out = w.items;
    // 1. file-field union
    try std.testing.expect(contains(out, "export type PostFileField = \"cover\";"));
    // 2. TypedFiles interface with url overload
    try std.testing.expect(contains(out, "export interface TypedFiles {"));
    try std.testing.expect(contains(out, "url(record: Post, field: PostFileField, opts?: FileUrlOptions): string;"));
    // 3. makeFilesSurface function + record[field] filename lookup
    try std.testing.expect(contains(out, "function makeFilesSurface("));
    try std.testing.expect(contains(out, "record as unknown as Record<string, string>)[field]"));
    try std.testing.expect(contains(out, "collectionName: \"posts\""));
}
