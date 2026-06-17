//! Emit-helpers: one fn per TS fragment, each appending to a *std.ArrayList(u8).
//! Every fragment mirrors clients/typescript/test/fixtures/blog.gen.ts.
const std = @import("std");
const schema = @import("../schema.zig");
const tt = @import("ts_type.zig");
const ident = @import("identifiers.zig");

/// Growable byte buffer backing every emit helper.
const W = std.ArrayList(u8);

fn put(alloc: std.mem.Allocator, w: *W, s: []const u8) !void {
    try w.appendSlice(alloc, s);
}
/// Format helper — callers must pass an arena allocator; the helper allocs a
/// temporary string from it and copies the bytes into `w`.
fn putf(alloc: std.mem.Allocator, w: *W, comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(alloc, fmt, args);
    try w.appendSlice(alloc, s);
}
/// Emit `s` as a TS double-quoted string literal (quotes included), escaping the
/// characters that would otherwise produce invalid TypeScript. Used for emitting
/// user-controlled values (e.g. select values, which the schema only validates as
/// non-empty); field/collection names go through the identifier guard instead and
/// don't need escaping.
fn putTsString(alloc: std.mem.Allocator, w: *W, s: []const u8) !void {
    try w.append(alloc, '"');
    for (s) |ch| switch (ch) {
        '\\' => try w.appendSlice(alloc, "\\\\"),
        '"' => try w.appendSlice(alloc, "\\\""),
        '\n' => try w.appendSlice(alloc, "\\n"),
        '\r' => try w.appendSlice(alloc, "\\r"),
        '\t' => try w.appendSlice(alloc, "\\t"),
        else => try w.append(alloc, ch),
    };
    try w.append(alloc, '"');
}

/// Returns true for the synthesized read-only system field names that are NOT
/// user-declared fields: id, created, updated.  Used in emitRecord / emitMeta
/// to avoid duplicating the fields that are always appended at the end.
fn isReadOnlySystem(name: []const u8) bool {
    return std.mem.eql(u8, name, "id") or
        std.mem.eql(u8, name, "created") or
        std.mem.eql(u8, name, "updated");
}

/// Returns true for the three visible auth fields that emitWhere / emitFields
/// synthesize at the top for .auth collections.  Guards against double-emission
/// when a caller passes a collection whose .fields already contain these names
/// (e.g. after injectAuthFields).
fn isAuthSynthesized(name: []const u8) bool {
    return std.mem.eql(u8, name, "email") or
        std.mem.eql(u8, name, "username") or
        std.mem.eql(u8, name, "verified");
}

/// Returns true for the system fields that emitWhere / emitFields synthesize
/// after user-declared fields.  Guards against double-emission when a user
/// field is named id, created, or updated (unusual but possible).
fn isSystemFieldName(name: []const u8) bool {
    return std.mem.eql(u8, name, "id") or
        std.mem.eql(u8, name, "created") or
        std.mem.eql(u8, name, "updated");
}

/// Returns true if any non-hidden user field in c.fields has the given name.
/// Used to decide whether to skip synthesizing a system field that the user
/// already declared (dedup logic for emitWhere / emitFields).
fn userFieldExists(c: schema.Collection, name: []const u8) bool {
    for (c.fields) |f| {
        if (!f.hidden and std.mem.eql(u8, f.name, name)) return true;
    }
    return false;
}

/// Returns true if the collection has at least one SINGLE-value file field.
/// The per-collection `fileUrl(record, field)` convenience (and its `<Rec>FileField`
/// union) only handles single-value file fields — a multi-value file field is
/// `string[]` on the record, which can't be passed as a single filename. Multi-value
/// file URLs go through the base `zb.files.getUrl(record, filename)` surface instead.
fn hasSingleFileFields(c: schema.Collection) bool {
    for (c.fields) |f| if (tt.kindOf(f) == .file_name and !f.isMultiValue()) return true;
    return false;
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
            try putTsString(alloc, w, v);
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
    // For auth collections we skip any field already synthesized above (email /
    // username / verified) so that callers who pass injectAuthFields output do not
    // produce duplicate lines.
    // We also skip user fields named id/created/updated since we synthesize those
    // system fields explicitly below (isSystemFieldName dedup).
    for (c.fields) |f| {
        if (f.hidden) continue;
        if (c.type == .auth and isAuthSynthesized(f.name)) continue;
        if (isSystemFieldName(f.name)) continue; // synthesized below as system fields
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
    // Synthesize system fields id/created/updated (always filterable).
    // These are unconditionally appended; the loop above already skips any
    // user-declared field with the same name so there is no duplication.
    try put(alloc, w, "  id?: StringOps | string;\n");
    try put(alloc, w, "  created?: StringOps | string;\n");
    try put(alloc, w, "  updated?: StringOps | string;\n");
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
    // For auth collections we skip fields already synthesized above (email /
    // username / verified) to avoid double-emission when the caller passes
    // injectAuthFields output.
    // We also skip user fields named id/created/updated since we synthesize those
    // system fields explicitly below (isSystemFieldName dedup).
    for (c.fields) |f| {
        if (f.hidden or tt.kindOf(f) == .file_name) continue;
        if (c.type == .auth and isAuthSynthesized(f.name)) continue;
        if (isSystemFieldName(f.name)) continue; // synthesized below as system fields
        const base = try tt.tsBaseTypeOf(alloc, c.name, f);
        try putf(alloc, w, "  {s}: TypedFieldExpr<{s}>;\n", .{ f.name, base });
    }
    // Synthesize system fields id/created/updated (always filterable via fluent builder).
    // The loop above already skips any user-declared field with the same name.
    try put(alloc, w, "  id: TypedFieldExpr<string>;\n");
    try put(alloc, w, "  created: TypedFieldExpr<string>;\n");
    try put(alloc, w, "  updated: TypedFieldExpr<string>;\n");
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
    if (hasSingleFileFields(c)) {
        const ff = try ident.recordName(alloc, c.name);
        try putf(alloc, w,
            \\  fileUrl(record: {0s}, field: {0s}FileField, opts?: FileUrlOptions): string;
            \\
        , .{ff});
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
    // meta.fields = id (always first) + auth visible (email+username+verified, unconditional) +
    //               user fields (non-hidden, non-read-only-system) +
    //               created + updated (always appended).
    var metaFields: std.ArrayList(schema.Field) = .empty;
    try metaFields.append(alloc, .{ .id = "_id", .name = "id", .options = .{ .text = .{} } });
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
            \\import type { FilesService, FileUrlOptions } from "../../../src/files.js";
            \\import {
            \\  makeRecordService,
            \\  makeTypedRealtime,
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
            \\import type { ListResult, CursorPage, FilesService, FileUrlOptions } from "@zigbase/client";
            \\import {
            \\  makeRecordService,
            \\  makeTypedRealtime,
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
    // Per-collection file-field unions (e.g. `export type PostFileField = "cover";`).
    // These type the `field` parameter of the per-collection `fileUrl` method on
    // each concrete *Service interface.
    for (cols) |c| {
        // Only single-value file fields get a FileField union: the per-collection
        // fileUrl convenience can't address a multi-value (string[]) file field.
        if (!hasSingleFileFields(c)) continue;
        const rec = try ident.recordName(alloc, c.name);
        try putf(alloc, w, "export type {s}FileField = ", .{rec});
        var first = true;
        for (c.fields) |f| {
            if (tt.kindOf(f) != .file_name or f.isMultiValue()) continue;
            if (!first) try put(alloc, w, " | ");
            first = false;
            try putf(alloc, w, "\"{s}\"", .{f.name});
        }
        try put(alloc, w, ";\n");
    }
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

test "emitSelectUnions escapes special chars in select values" {
    // Fix 1: select values are arbitrary []const u8 (schema only checks non-emptiness),
    // so a value containing `"` or `\` must be escaped to stay valid TypeScript.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fields = [_]schema.Field{
        .{ .id = "s", .name = "kind", .options = .{ .select = .{ .values = &.{ "a\"b", "c\\d" }, .maxSelect = 1 } } },
    };
    const col = schema.Collection{ .id = "", .name = "things", .fields = &fields };
    var w: std.ArrayList(u8) = .empty;
    try emitSelectUnions(a, &w, col);
    const out = w.items;
    // Escaped forms present.
    try std.testing.expect(contains(out, "\"a\\\"b\""));
    try std.testing.expect(contains(out, "\"c\\\\d\""));
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

test "emitWhere matches PostWhere (nested relation, multi id-only, file omitted, system fields synthesized)" {
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
    // System fields synthesized (user-declared `created` in blogPosts() is skipped from
    // the user loop to avoid duplication; only one `created?` line appears).
    try std.testing.expect(contains(out, "id?: StringOps | string;"));
    try std.testing.expect(contains(out, "created?: StringOps | string;"));
    try std.testing.expect(contains(out, "updated?: StringOps | string;"));
    // Each system field appears exactly once (no duplication from user `created` field).
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(out, "id?"));
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(out, "created?"));
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(out, "updated?"));
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
    // Fix A: file-bearing collections gain a per-collection fileUrl method.
    try std.testing.expect(contains(out, "fileUrl(record: Post, field: PostFileField, opts?: FileUrlOptions): string;"));
}

test "emitService (no files) does NOT include fileUrl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const no_file_col = schema.Collection{
        .id = "",
        .name = "tags",
        .fields = &.{.{ .id = "a", .name = "label", .required = true, .options = .{ .text = .{} } }},
    };
    var w: std.ArrayList(u8) = .empty;
    try emitService(a, &w, no_file_col);
    try std.testing.expect(!contains(w.items, "fileUrl"));
}

test "emitService + emitTypedFiles restrict FileField/fileUrl to single-value file fields" {
    // Fix 2: a collection with a single-value AND a multi-value file field must
    // expose only the single-value one in <Rec>FileField, and still get fileUrl.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fields = [_]schema.Field{
        .{ .id = "av", .name = "avatar", .options = .{ .file = .{ .maxSelect = 1 } } }, // single
        .{ .id = "ph", .name = "photos", .options = .{ .file = .{ .maxSelect = 5 } } }, // multi
    };
    const col = schema.Collection{ .id = "", .name = "members", .fields = &fields };
    // (a) FileField union lists ONLY the single-value field.
    {
        const cols = [_]schema.Collection{col};
        var w: std.ArrayList(u8) = .empty;
        try emitTypedFiles(a, &w, &cols);
        const out = w.items;
        try std.testing.expect(contains(out, "export type MemberFileField = \"avatar\";"));
        try std.testing.expect(!contains(out, "photos"));
    }
    // fileUrl IS emitted (single-value file field present).
    {
        var w: std.ArrayList(u8) = .empty;
        try emitService(a, &w, col);
        try std.testing.expect(contains(w.items, "fileUrl(record: Member, field: MemberFileField, opts?: FileUrlOptions): string;"));
    }
}

test "emitService + emitTypedFiles skip FileField/fileUrl for multi-value-only file fields" {
    // Fix 2: a collection whose ONLY file field is multi-value gets NO FileField
    // union and NO fileUrl method (the record field is string[], not a filename).
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fields = [_]schema.Field{
        .{ .id = "ph", .name = "photos", .options = .{ .file = .{ .maxSelect = 5 } } }, // multi only
    };
    const col = schema.Collection{ .id = "", .name = "galleries", .fields = &fields };
    {
        const cols = [_]schema.Collection{col};
        var w: std.ArrayList(u8) = .empty;
        try emitTypedFiles(a, &w, &cols);
        try std.testing.expect(!contains(w.items, "GalleryFileField"));
        try std.testing.expect(w.items.len == 0);
    }
    {
        var w: std.ArrayList(u8) = .empty;
        try emitService(a, &w, col);
        try std.testing.expect(!contains(w.items, "fileUrl"));
    }
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
    // Fix B: id is now always first in meta.fields so compileWhere recognises it.
    try std.testing.expect(contains(out, "id: { type: \"text\" },"));
    try std.testing.expect(contains(out, "tags: { type: \"relation\", multi: true },"));
    try std.testing.expect(contains(out, "fileFields: [\"cover\"],"));
    try std.testing.expect(contains(out, "expandable: [\"author\", \"tags\"],"));
    try std.testing.expect(contains(out, "isAuth: false,"));
    // id appears exactly once (no duplication).
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(out, "id: { type:"));
}

test "emitRealtimeAlias matches the generic alias" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var w: std.ArrayList(u8) = .empty;
    try emitRealtimeAlias(a, &w, blogPosts());
    try std.testing.expect(contains(w.items, "export type PostsRealtime = RawTypedRealtime<Post, PostWhere>;"));
}

fn countOccurrences(hay: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, hay, pos, needle)) |idx| {
        count += 1;
        pos = idx + needle.len;
    }
    return count;
}

// Construct an auth collection whose .fields slice ALREADY contains email /
// username / verified (as injectAuthFields would produce).  Both emitWhere and
// emitFields must emit each of those names exactly once.
test "emitWhere / emitFields dedup injected auth fields — each appears exactly once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Simulate injectAuthFields output: the three visible auth fields prepended,
    // plus an ordinary user field.
    const injected_fields = [_]schema.Field{
        .{ .id = "_email", .name = "email", .options = .{ .email = .{} } },
        .{ .id = "_username", .name = "username", .options = .{ .text = .{} } },
        .{ .id = "_verified", .name = "verified", .options = .{ .@"bool" = .{} } },
        .{ .id = "f1", .name = "bio", .options = .{ .text = .{} } },
    };
    const injected_auth = schema.Collection{
        .id = "uc",
        .name = "users",
        .type = .auth,
        .fields = &injected_fields,
    };

    // --- emitWhere ---
    {
        const cols = [_]schema.Collection{injected_auth};
        var w: std.ArrayList(u8) = .empty;
        try emitWhere(a, &w, &cols, injected_auth);
        const out = w.items;
        // Each auth synthesized field must appear exactly once.
        try std.testing.expectEqual(@as(usize, 1), countOccurrences(out, "email?"));
        try std.testing.expectEqual(@as(usize, 1), countOccurrences(out, "username?"));
        try std.testing.expectEqual(@as(usize, 1), countOccurrences(out, "verified?"));
        // The regular user field is still present.
        try std.testing.expect(contains(out, "bio?: StringOps | string;"));
        // Fix B: system fields synthesized once.
        try std.testing.expectEqual(@as(usize, 1), countOccurrences(out, "id?"));
        try std.testing.expectEqual(@as(usize, 1), countOccurrences(out, "created?"));
        try std.testing.expectEqual(@as(usize, 1), countOccurrences(out, "updated?"));
    }

    // --- emitFields ---
    {
        var w: std.ArrayList(u8) = .empty;
        try emitFields(a, &w, injected_auth);
        const out = w.items;
        try std.testing.expectEqual(@as(usize, 1), countOccurrences(out, "email:"));
        try std.testing.expectEqual(@as(usize, 1), countOccurrences(out, "username:"));
        try std.testing.expectEqual(@as(usize, 1), countOccurrences(out, "verified:"));
        try std.testing.expect(contains(out, "bio: TypedFieldExpr<string>;"));
        // Fix B: system fields always synthesized.
        try std.testing.expect(contains(out, "id: TypedFieldExpr<string>;"));
        try std.testing.expect(contains(out, "created: TypedFieldExpr<string>;"));
        try std.testing.expect(contains(out, "updated: TypedFieldExpr<string>;"));
    }

    // --- non-injected auth collection still emits all three exactly once ---
    const clean_auth = schema.Collection{
        .id = "uc2",
        .name = "members",
        .type = .auth,
        .fields = &.{},
    };
    {
        const cols = [_]schema.Collection{clean_auth};
        var w: std.ArrayList(u8) = .empty;
        try emitWhere(a, &w, &cols, clean_auth);
        const out = w.items;
        try std.testing.expectEqual(@as(usize, 1), countOccurrences(out, "email?"));
        try std.testing.expectEqual(@as(usize, 1), countOccurrences(out, "username?"));
        try std.testing.expectEqual(@as(usize, 1), countOccurrences(out, "verified?"));
        // Fix B: system fields synthesized once.
        try std.testing.expectEqual(@as(usize, 1), countOccurrences(out, "id?"));
        try std.testing.expectEqual(@as(usize, 1), countOccurrences(out, "created?"));
        try std.testing.expectEqual(@as(usize, 1), countOccurrences(out, "updated?"));
    }
    {
        var w: std.ArrayList(u8) = .empty;
        try emitFields(a, &w, clean_auth);
        const out = w.items;
        try std.testing.expectEqual(@as(usize, 1), countOccurrences(out, "email:"));
        try std.testing.expectEqual(@as(usize, 1), countOccurrences(out, "username:"));
        try std.testing.expectEqual(@as(usize, 1), countOccurrences(out, "verified:"));
        // Fix B: system fields synthesized once.
        try std.testing.expectEqual(@as(usize, 1), countOccurrences(out, "id:"));
        try std.testing.expectEqual(@as(usize, 1), countOccurrences(out, "created:"));
        try std.testing.expectEqual(@as(usize, 1), countOccurrences(out, "updated:"));
    }
}

test "emitTypedFiles emits only FileField unions (no global TypedFiles / makeFilesSurface)" {
    // Fix A: emitTypedFiles now only emits per-collection FileField unions.
    // The global TypedFiles interface and makeFilesSurface have been removed;
    // fileUrl is grafted per-collection in emitService + gen_client.zig's
    // emitClientFactory.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cols = [_]schema.Collection{blogPosts()};
    var w: std.ArrayList(u8) = .empty;
    try emitTypedFiles(a, &w, &cols);
    const out = w.items;
    // Per-collection file-field union is still emitted.
    try std.testing.expect(contains(out, "export type PostFileField = \"cover\";"));
    // Global TypedFiles interface and dispatch helper are GONE.
    try std.testing.expect(!contains(out, "export interface TypedFiles"));
    try std.testing.expect(!contains(out, "makeFilesSurface"));
    try std.testing.expect(!contains(out, "_colMap"));
}

test "emitTypedFiles skips collections without file fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tags_col = schema.Collection{
        .id = "",
        .name = "tags",
        .fields = &.{.{ .id = "a", .name = "label", .options = .{ .text = .{} } }},
    };
    const cols = [_]schema.Collection{tags_col};
    var w: std.ArrayList(u8) = .empty;
    try emitTypedFiles(a, &w, &cols);
    // No FileField union for a collection with no file fields.
    try std.testing.expect(!contains(w.items, "TagFileField"));
    try std.testing.expect(w.items.len == 0);
}
