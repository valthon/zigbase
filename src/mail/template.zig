//! Minimal, safe email template engine (#154). There is no general template engine in
//! ZigBase; this is a deliberately SMALL renderer scoped to transactional mail. It has no
//! arbitrary code evaluation, no loops, and no conditionals — only variable interpolation,
//! named partials, and a shared layout. Everything is pure (no I/O), so it is fully
//! unit-testable by asserting the produced bytes.
//!
//! SECURITY: interpolation is HTML-ESCAPED BY DEFAULT. `{{ name }}` escapes `& < > " '` so a
//! value that contains markup can never inject into the HTML part. Raw, un-escaped output is an
//! EXPLICIT opt-in via the triple-brace `{{{ name }}}` marker (use only for values you produced
//! and trust — e.g. a pre-rendered partial). The plain-text part is rendered WITHOUT escaping
//! (there is no markup to escape in text/plain), via `renderText`.
//!
//! Syntax:
//!   {{ name }}      — HTML-escaped interpolation of variable `name` (unknown → empty string).
//!   {{{ name }}}    — RAW interpolation (no escaping). Explicit opt-in.
//!   {{> partial }}  — include the named partial (recursively rendered with the same vars).
//!   {{!  comment }} — a comment; emits nothing.
//! Whitespace inside the braces is trimmed, so `{{name}}` and `{{ name }}` are equivalent.
//!
//! Layout: `renderInLayout` renders `body_template`, then renders `layout` with a synthetic
//! `body` variable bound to the (raw) rendered child — so a layout writes `{{{ body }}}` where
//! the page content goes. The child is already escaped per its own markers, so the layout uses
//! the raw marker for it.

const std = @import("std");

/// One template variable binding. `value` is interpolated verbatim where the template names
/// `key` (escaped for `{{ }}`, raw for `{{{ }}}`).
pub const Var = struct { key: []const u8, value: []const u8 };

/// A named partial: `{{> name }}` expands to `source`, rendered with the same vars/partials.
pub const Partial = struct { name: []const u8, source: []const u8 };

pub const RenderError = error{
    /// A `{{ ... }}` tag was opened but never closed with `}}`.
    UnterminatedTag,
    /// `{{> name }}` referenced a partial that is not in the provided set.
    UnknownPartial,
    /// Partial recursion exceeded `max_depth` (a cycle, or pathological nesting).
    PartialTooDeep,
} || std.mem.Allocator.Error;

/// Hard cap on partial-include recursion depth (cycle guard).
pub const max_depth = 16;

/// HTML-escape `s` into `w`, replacing the five significant characters. Public so providers /
/// callers can escape an interpolated value the same way the engine does.
pub fn escapeHtml(w: *std.ArrayList(u8), alloc: std.mem.Allocator, s: []const u8) std.mem.Allocator.Error!void {
    for (s) |c| switch (c) {
        '&' => try w.appendSlice(alloc, "&amp;"),
        '<' => try w.appendSlice(alloc, "&lt;"),
        '>' => try w.appendSlice(alloc, "&gt;"),
        '"' => try w.appendSlice(alloc, "&quot;"),
        '\'' => try w.appendSlice(alloc, "&#39;"),
        else => try w.append(alloc, c),
    };
}

fn lookup(vars: []const Var, key: []const u8) ?[]const u8 {
    for (vars) |v| if (std.mem.eql(u8, v.key, key)) return v.value;
    return null;
}

fn partialSource(partials: []const Partial, name: []const u8) ?[]const u8 {
    for (partials) |p| if (std.mem.eql(u8, p.name, name)) return p.source;
    return null;
}

/// Render `template` (HTML) with `vars` + `partials`, HTML-escaping `{{ }}` interpolations.
/// Returns an arena/caller-owned byte slice.
pub fn renderHtml(alloc: std.mem.Allocator, template: []const u8, vars: []const Var, partials: []const Partial) RenderError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try renderInto(&out, alloc, template, vars, partials, true, 0);
    return out.toOwnedSlice(alloc);
}

/// Render `template` as PLAIN TEXT with `vars` + `partials`. No HTML escaping (text/plain has no
/// markup); the `{{{ }}}` raw marker and `{{ }}` produce identical output here.
pub fn renderText(alloc: std.mem.Allocator, template: []const u8, vars: []const Var, partials: []const Partial) RenderError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try renderInto(&out, alloc, template, vars, partials, false, 0);
    return out.toOwnedSlice(alloc);
}

/// Render `body_template` then wrap it in `layout` (the layout references the child via the
/// `body` variable, typically `{{{ body }}}`). `escape_html` selects HTML vs text rendering for
/// BOTH the body and the layout. Any extra `vars` are visible to both.
pub fn renderInLayout(
    alloc: std.mem.Allocator,
    layout: []const u8,
    body_template: []const u8,
    vars: []const Var,
    partials: []const Partial,
    escape_html: bool,
) RenderError![]u8 {
    const body = if (escape_html)
        try renderHtml(alloc, body_template, vars, partials)
    else
        try renderText(alloc, body_template, vars, partials);
    defer alloc.free(body);

    // Bind the rendered child to `body`. The child is already escaped per its own markers, so the
    // layout should reference it raw (`{{{ body }}}`).
    var merged = try alloc.alloc(Var, vars.len + 1);
    defer alloc.free(merged);
    @memcpy(merged[0..vars.len], vars);
    merged[vars.len] = .{ .key = "body", .value = body };

    return if (escape_html)
        renderHtml(alloc, layout, merged, partials)
    else
        renderText(alloc, layout, merged, partials);
}

fn renderInto(
    out: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    template: []const u8,
    vars: []const Var,
    partials: []const Partial,
    escape_html: bool,
    depth: usize,
) RenderError!void {
    if (depth > max_depth) return error.PartialTooDeep;
    var i: usize = 0;
    while (i < template.len) {
        // Find the next tag opener.
        const open = std.mem.indexOfPos(u8, template, i, "{{") orelse {
            try out.appendSlice(alloc, template[i..]);
            break;
        };
        // Emit the literal text before the tag.
        try out.appendSlice(alloc, template[i..open]);

        // Distinguish a raw `{{{ ... }}}` tag from the normal `{{ ... }}`.
        const raw = open + 2 < template.len and template[open + 2] == '{';
        const close_delim: []const u8 = if (raw) "}}}" else "}}";
        const tag_start = open + 2 + @as(usize, if (raw) 1 else 0);
        const close = std.mem.indexOfPos(u8, template, tag_start, close_delim) orelse return error.UnterminatedTag;
        const inner = std.mem.trim(u8, template[tag_start..close], " \t\r\n");
        i = close + close_delim.len;

        if (inner.len == 0) continue; // `{{}}` → nothing
        switch (inner[0]) {
            '!' => {}, // comment — emit nothing
            '>' => {
                const name = std.mem.trim(u8, inner[1..], " \t\r\n");
                const src = partialSource(partials, name) orelse return error.UnknownPartial;
                try renderInto(out, alloc, src, vars, partials, escape_html, depth + 1);
            },
            else => {
                const val = lookup(vars, inner) orelse "";
                if (escape_html and !raw) {
                    try escapeHtml(out, alloc, val);
                } else {
                    try out.appendSlice(alloc, val);
                }
            },
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "renderHtml interpolates and HTML-escapes by default" {
    const a = testing.allocator;
    const out = try renderHtml(a, "Hello {{ name }}!", &.{.{ .key = "name", .value = "<b>Ann & co</b>" }}, &.{});
    defer a.free(out);
    // The angle brackets, ampersand are all escaped — no markup injection.
    try testing.expectEqualStrings("Hello &lt;b&gt;Ann &amp; co&lt;/b&gt;!", out);
}

test "renderHtml raw marker {{{ }}} opts out of escaping" {
    const a = testing.allocator;
    const out = try renderHtml(a, "{{{ html }}}", &.{.{ .key = "html", .value = "<i>ok</i>" }}, &.{});
    defer a.free(out);
    try testing.expectEqualStrings("<i>ok</i>", out);
}

test "renderText does not escape (text/plain has no markup)" {
    const a = testing.allocator;
    const out = try renderText(a, "Hi {{ name }}", &.{.{ .key = "name", .value = "A<>&B" }}, &.{});
    defer a.free(out);
    try testing.expectEqualStrings("Hi A<>&B", out);
}

test "unknown variable renders empty; comment emits nothing; whitespace trimmed" {
    const a = testing.allocator;
    const out = try renderHtml(a, "[{{missing}}]{{! note }}[{{  x  }}]", &.{.{ .key = "x", .value = "X" }}, &.{});
    defer a.free(out);
    try testing.expectEqualStrings("[][X]", out);
}

test "partials expand with correct arg order" {
    const a = testing.allocator;
    const partials = [_]Partial{.{ .name = "greeting", .source = "Hi {{ name }}" }};
    const out = try renderHtml(a, "{{> greeting }}!", &.{.{ .key = "name", .value = "Bo" }}, &partials);
    defer a.free(out);
    try testing.expectEqualStrings("Hi Bo!", out);
}

test "unknown partial and unterminated tag are errors" {
    const a = testing.allocator;
    try testing.expectError(error.UnknownPartial, renderHtml(a, "{{> nope }}", &.{}, &.{}));
    try testing.expectError(error.UnterminatedTag, renderHtml(a, "{{ name ", &.{}, &.{}));
}

test "partial cycle is bounded (PartialTooDeep)" {
    const a = testing.allocator;
    const partials = [_]Partial{.{ .name = "loop", .source = "x{{> loop }}" }};
    try testing.expectError(error.PartialTooDeep, renderHtml(a, "{{> loop }}", &.{}, &partials));
}

test "renderInLayout wraps the child body and escapes child content" {
    const a = testing.allocator;
    const layout = "<html><body>{{{ body }}}</body></html>";
    const body = "<p>{{ msg }}</p>";
    const out = try renderInLayout(a, layout, body, &.{.{ .key = "msg", .value = "a<b" }}, &.{}, true);
    defer a.free(out);
    // Child markup (`<p>`) is literal in the template; the interpolated `msg` is escaped.
    try testing.expectEqualStrings("<html><body><p>a&lt;b</p></body></html>", out);
}
