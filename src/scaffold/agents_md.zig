//! The generated `AGENTS.md` for a CONSUMER project (and its one-line `CLAUDE.md`).
//!
//! Trap-oriented, not a feature tour: every section is something that silently
//! does the wrong thing if you assume the obvious. Contributor traps for the
//! ZigBase repo itself (changelog fragments, the root.zig test block, the
//! browser suite) belong in this repo's own CLAUDE.md, NOT here.
//!
//! It describes CURRENT behavior only — `commands_named` below, and the scan test
//! that checks against it, are the guard rail against this text drifting ahead of
//! (or behind) the shipped binary again.

pub const Mode = enum { box, framework };

/// The full `AGENTS.md` body for `mode`.
pub fn text(comptime mode: Mode) []const u8 {
    return header ++ shared_traps ++ switch (mode) {
        .box => box_traps ++ box_layout ++ box_commands,
        .framework => framework_traps ++ framework_layout ++ framework_commands,
    } ++ footer;
}

/// `CLAUDE.md` just includes `AGENTS.md`, so there is one file to maintain.
pub const claude_md = "@AGENTS.md\n";

const header =
    \\# AGENTS.md — working on this ZigBase backend
    \\
    \\This project's backend is [ZigBase](https://github.com/valthon/zigbase): a
    \\single-binary backend (REST + WebSocket + an admin UI at `/_/`). This file is
    \\for coding agents; humans are welcome too.
    \\
    \\It lists what bites, not what exists. The feature tour is at
    \\<https://valthon.github.io/zigbase/docs/agents>.
    \\
    \\
;

const shared_traps =
    \\## Trap 1 — access rules are LOCKED by default, and `""` does not mean "public"
    \\
    \\Every collection has five rules: `list`, `view`, `create`, `update`, `delete`.
    \\
    \\| Rule value | Who can do it |
    \\| --- | --- |
    \\| absent, `null`, or `""` | **Superusers only.** A blank rule is LOCKED, not open. |
    \\| `"@public"` | Everyone, including unauthenticated callers. **The only allow-all value.** |
    \\| any other string | A filter expression evaluated per record, e.g. `"@request.auth.id = owner"` |
    \\
    \\Three consequences that catch people:
    \\
    \\- **Clearing a rule locks it.** Emptying the field in the admin UI is not
    \\  "make it public"; it is "superusers only".
    \\- **A rule that fails to parse fails CLOSED** — HTTP 500, and the write never
    \\  runs. There is no permissive fallback.
    \\- **Every `@public` rule is logged as a warning at startup.** Read those lines
    \\  before shipping: each one is a door you opened on purpose.
    \\
    \\## Trap 2 — plain-HTTP local dev needs `--insecure-cookies`
    \\
    \\Auth cookies are `Secure` by default. A browser on `http://127.0.0.1` refuses
    \\to store them **silently**: the admin UI at `/_/` bounces straight back to the
    \\login form with no error message and nothing useful in the log.
    \\
    \\```sh
    \\zigbase serve --insecure-cookies --data-dir ./zb_data
    \\```
    \\
    \\Never pass it to anything reachable off the machine.
    \\
    \\## Trap 3 — loopback bind, and the data dir is credentials
    \\
    \\- `serve` binds `127.0.0.1`. Inside a container that means nothing outside the
    \\  container can reach it — pass `--http-host 0.0.0.0` **there and only there**
    \\  (the official Docker image already sets it via `ZIGBASE_HTTP_HOST`).
    \\- The data dir (default `./zb_data`) holds the SQLite database, uploaded
    \\  files, **and `.jwt_secret`**, which is generated on first run and reused
    \\  forever after. Delete the data dir and every issued token becomes invalid.
    \\  In Docker it must be a mounted volume or every restart logs everyone out.
    \\- `zb_data/` is in `.gitignore`. Keep it there — `.jwt_secret` is a secret.
    \\- In a detected AI-agent environment, `serve` **backgrounds itself** by default
    \\  (set `ZIGBASE_SERVE_BACKGROUND` to something other than `1` to disable). Use
    \\  `serve status`, `serve logs`, and `serve stop` to manage that session — do not
    \\  wait on a foreground process that was never going to print again.
    \\
    \\## Trap 4 — one error envelope, and `code` is what you branch on
    \\
    \\Every endpoint — built-in (records, collections, auth, files) and your own
    \\typed routes alike — answers errors with the same four keys:
    \\
    \\```json
    \\{ "status": 404, "code": "not_found", "message": "Not found.", "data": {} }
    \\```
    \\
    \\- `status` — the integer HTTP status.
    \\- `code` — a **frozen, machine-readable string**. This is what you branch on.
    \\- `message` — human text for logs and UIs. **Not contract — never string-match it.**
    \\- `data` — per-field validation failures, keyed by field name:
    \\  `{ "<field>": { "code": "validation_…", "message": "…" } }`.
    \\
    \\`zigbase explain-code` lists every code; `zigbase explain-code not_found`
    \\explains one. Add `--json` to either for a single JSON object.
    \\
    \\## Trap 5 — list and pagination shapes
    \\
    \\Every list endpoint returns an **object**, never a bare array:
    \\
    \\```json
    \\{ "items": [], "page": 1, "perPage": 30, "totalItems": 0, "totalPages": 0 }
    \\```
    \\
    \\Cursor pagination uses `?cursor=…&limit=…` and answers `nextCursor` /
    \\`hasNext`. A side-effecting endpoint that returns no body answers **204**, not
    \\`200 {}` — do not treat a 204 as a failure to parse JSON.
    \\
    \\## Trap 6 — realtime re-checks rules per record
    \\
    \\A WebSocket subscriber does not receive everything written to a collection.
    \\Each event is re-authorized against that collection's `view` rule for that
    \\specific subscriber, and delete events are authorized against a **pre-delete
    \\snapshot**. A record you can see in the admin UI may legitimately never arrive
    \\on a client socket. If an expected event does not show up, check the view rule
    \\before checking the socket.
    \\
    \\
;

const box_traps =
    \\## Trap 7 — schema changes go through `zigbase schema apply`, not a hand-rolled POST
    \\
    \\This project has no Zig build step, but the same binary that runs `serve` also runs
    \\schema commands. `docker compose exec zigbase /zigbase schema apply` diffs a JSON
    \\document against the live schema and executes exactly the difference — through the
    \\SAME validation + DDL path the collections REST API uses, no second implementation.
    \\It is idempotent (re-applying an already-applied document reports `applied: []`), and
    \\it refuses the WHOLE document if any access rule fails to parse, so a typo can never
    \\land half a schema.
    \\
    \\```sh
    \\docker compose exec zigbase /zigbase schema apply /schema/collections.json
    \\docker compose exec zigbase /zigbase schema check-rules --data-dir /data
    \\```
    \\
    \\`check-rules` is the full-depth pass: `apply` only checks that a rule PARSES, while
    \\`check-rules` resolves it against the live schema and catches a rule naming a field
    \\that does not exist. It exits **2 when it has only warnings**, and every `@public`
    \\rule is a warning — so the starting schema exits 2 on a clean run. Exit 1 is the one
    \\that means a rule is broken.
    \\
    \\`schema/collections.json` (bind-mounted read-only at `/schema` — see
    \\docker-compose.yml) is this project's source of truth. Keep it updated when you
    \\change the schema through the admin UI — `zigbase schema dump` writes the live
    \\schema back out in the same document shape — or the next fresh environment will
    \\not match this one.
    \\
    \\A server already running against this data dir picks the change up on its own
    \\within about five seconds (it polls a schema-generation marker and then drops its
    \\collection cache). Requests in that window still see the old schema, so restart it
    \\if the change must be visible immediately. See
    \\<https://valthon.github.io/zigbase/docs/migration-tools> §2/§7 for the mechanism.
    \\
    \\
;

const framework_traps =
    \\## Trap 7 — your module must link libc, and `addTo` is why you will not forget
    \\
    \\ZigBase requires libc (it carries the SQLite C amalgamation and zap). The
    \\helper wires the `"zigbase"` import and the libc requirement together in one
    \\call, so your build never depends on remembering it by hand:
    \\
    \\```zig
    \\const zigbase = @import("zigbase"); // the dependency's build.zig
    \\const dep = b.dependency("zigbase", .{ .target = target, .optimize = optimize });
    \\zigbase.addTo(dep, app_mod); // adds the import AND sets link_libc
    \\```
    \\
    \\## Trap 8 — schema provisioning is ADDITIVE ONLY
    \\
    \\The comptime `.collections` literal is provisioned at startup: missing
    \\collections are created and new fields are added. **Renames, drops, and type
    \\changes are detected, logged, and then skipped** — the server starts happily
    \\and your change did not happen. Those need an explicit `.migrations` entry.
    \\Read the startup log after any schema edit.
    \\
    \\## Trap 9 — hook allocations belong to the request arena
    \\
    \\Inside a record hook, anything you attach to the record must be allocated with
    \\`ev.arena.a` — the request-scoped allocator that owns `ev.record`. Using
    \\`ev.app.allocator` there leaks or dangles.
    \\
    \\`before*` hooks run **inside the write transaction**: writes you make through
    \\`ctx.records()` commit or roll back atomically with the write that triggered
    \\them. Side effects that must only happen on success (email, webhooks, external
    \\calls) belong in an `after*` hook.
    \\
    \\## Trap 10 — a green `zig build test` is not a green deployment
    \\
    \\`zigbase.testing` boots your app in-process and injects requests through the
    \\real router, rules, auth, and hooks. It does **not** bind a socket. So it never
    \\exercises: the HTTP server itself, TLS or a reverse proxy, CORS, WebSocket
    \\upgrades, static-file serving, or your frontend. Those need a real
    \\`serve` and a real client. Test both layers; do not assume one implies the
    \\other.
    \\
    \\Two build notes while you are here: the Zig toolchain is pinned to **0.16.0
    \\exactly** (another 0.16.x may not work), and config mistakes in `App(.{...})`
    \\are `@compileError`s that print the valid keys — read the error text, it names
    \\the fix. Your spawned-server tests run whatever binary you built last — if
    \\you build with different flags in between, rebuild before running them.
    \\
    \\## Trap 11 — structured logging needs one line in YOUR root file
    \\
    \\`--log-format json` and `--log-level debug|info|warn|error` (also
    \\`ZIGBASE_LOG_FORMAT` / `ZIGBASE_LOG_LEVEL`) control request-log encoding, but
    \\they do **not** automatically cover your own `std.log.*` calls: `std_options`
    \\is resolved from the **root source file** of the compilation, so ZigBase
    \\cannot set it for you. Put this in `src/main.zig`, above `pub const App`:
    \\
    \\```zig
    \\pub const std_options = zigbase.std_options;
    \\```
    \\
    \\Skip it and your own log lines stay in Zig's default text format, mixed in
    \\with JSON access lines under `--log-format json`.
    \\
    \\
;

const box_layout =
    \\## Layout
    \\
    \\| Path | What it is |
    \\| --- | --- |
    \\| `docker-compose.yml` | The local server. `docker compose up` starts it. |
    \\| `schema/collections.json` | The collection definitions this project starts from. |
    \\| `zb_data/` | Database, uploads, `.jwt_secret`. Runtime state — never edit, never commit. |
    \\
    \\
;

const framework_layout =
    \\## Layout
    \\
    \\| Path | What it is |
    \\| --- | --- |
    \\| `src/main.zig` | The whole app: `pub const App = zigbase.App(.{…})` plus its tests. |
    \\| `build.zig` | Wires the dependency via `zigbase.addTo` and the test step via `zigbase.addTest`. |
    \\| `build.zig.zon` | Package manifest. The `zigbase` dependency is written by `zig fetch --save`. |
    \\| `zb_data/` | Database, uploads, `.jwt_secret`. Runtime state — never edit, never commit. |
    \\| `zig-out/`, `.zig-cache/` | Build output. Never edit, never commit. |
    \\
    \\
;

const box_commands =
    \\## Checking work
    \\
    \\| Command | What it does |
    \\| --- | --- |
    \\| `docker compose up` | Start the server on <http://127.0.0.1:8090> |
    \\| `docker compose exec zigbase /zigbase superuser create --email you@example.com --password '…' --data-dir /data` | Create the admin account (needed before `/_/` is usable) |
    \\| `docker compose exec zigbase /zigbase schema apply /schema/collections.json` | Apply the schema (idempotent) |
    \\| `docker compose exec zigbase /zigbase schema check-rules --data-dir /data` | Lint access rules against the live schema — exit 0 clean, 1 a rule failed to parse, **2 warnings only** (every `@public` rule warns, so the starting schema exits 2 by design) |
    \\| `docker compose exec zigbase /zigbase openapi --data-dir /data --out /data/openapi.json` | Export deterministic collection OpenAPI without starting or mutating the server |
    \\| `curl -s http://127.0.0.1:8090/api/health` | Liveness |
    \\| `curl -s http://127.0.0.1:8090/api/meta` | Capabilities + endpoints this build exposes (public, no auth) |
    \\| `docker compose exec zigbase /zigbase doctor --production --data-dir /data` | Preflight before shipping — exit 0 clean, 1 error, 2 warnings-only |
    \\| `zigbase explain-code CODE`, e.g. `zigbase explain-code not_found` | Explain an API error `code` |
    \\| `zigbase help`, `zigbase <cmd> --help` | The authoritative flag list — trust it over this file |
    \\
    \\
;

const framework_commands =
    \\## Checking work
    \\
    \\| Command | What it does |
    \\| --- | --- |
    \\| `zig build test` | In-process tests through the real pipeline (`zigbase.testing`) |
    \\| `zig build` | Compile; config mistakes surface here as `@compileError`s |
    \\| `zig build run -- serve --insecure-cookies` | Run locally; admin UI at <http://127.0.0.1:8090/_/> |
    \\| `zig build run -- superuser create --email you@example.com --password '…'` | Create the admin account |
    \\| `zig build run -- migrate status` | Which migrations have been applied |
    \\| `zig build run -- doctor --production` | Preflight before shipping — exit 0 clean, 1 error, 2 warnings-only |
    \\| `zig build run -- serve --background`, then `zig build run -- serve status` / `serve logs -f` / `serve stop` | A background dev session you can poll instead of blocking a terminal on |
    \\| `zig build run -- explain-code CODE` | Explain an API error `code` |
    \\| `zig build run -- schema dump` | The live collection model, as a schema document |
    \\| `zig build run -- openapi --out openapi.json` | Live collections plus this binary's declared consumer routes as OpenAPI 3.1.2 JSON |
    \\| `zig build run -- help` | The authoritative flag list — trust it over this file |
    \\
    \\
;

const footer =
    \\## Where the docs are
    \\
    \\Start at <https://valthon.github.io/zigbase/docs/agents> — it is the ~2k-token
    \\entry point that tells you which of the longer guides to load. Machine-readable
    \\indexes: <https://valthon.github.io/zigbase/llms.txt> and
    \\<https://valthon.github.io/zigbase/docs-index.json>.
    \\OpenAPI export: <https://valthon.github.io/zigbase/docs/openapi>.
    \\
    \\Refresh this file by deleting it and running `zigbase agents-md` (it never
    \\overwrites an existing file), or diff it against `zigbase agents-md --stdout`.
    \\A binary built with `-Ddev-tools=false` won't have this command (nor `init` or
    \\`typegen`) — that's a consumer's own custom build, never how we publish zigbase.
    \\
;

const std = @import("std");

test "box and framework AGENTS.md carry the right traps" {
    const box = text(.box);
    const fw = text(.framework);

    // Shared traps appear in both.
    for ([_][]const u8{
        "@public",
        "--insecure-cookies",
        "127.0.0.1",
        ".jwt_secret",
        "\"items\"",
        "openapi",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, box, needle) != null);
        try std.testing.expect(std.mem.indexOf(u8, fw, needle) != null);
    }

    // Framework-only traps stay out of the box-mode file.
    for ([_][]const u8{ "link_libc", "ev.arena.a", "zig build test" }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, fw, needle) != null);
        try std.testing.expect(std.mem.indexOf(u8, box, needle) == null);
    }

    // Box-only content stays out of the framework file.
    try std.testing.expect(std.mem.indexOf(u8, box, "docker compose up") != null);
    try std.testing.expect(std.mem.indexOf(u8, fw, "docker compose up") == null);
}

/// Every `zigbase <verb>` (or, in the framework-mode text, `zig build run -- <verb>`)
/// the generated docs may name — including two-word entries (`"serve status"`) for
/// the handful of verbs that have real subcommands. The tests below assert the
/// generated text names nothing outside this set, and tests/admin/test_init.py
/// asserts the shipped binary really has each one — so a scaffold can never tell an
/// agent to run a command (or subcommand) that does not exist. (This replaces SP-2's
/// temporary ban on then-unshipped SP-1/SP-3/SP-5 surface: those commands ship now,
/// and "named implies exists" is the invariant that does not go stale.)
pub const commands_named = [_][]const u8{
    "serve",       "doctor",             "explain-code",
    "superuser",   "agents-md",          "help",
    "migrate",     "schema",             "serve status",
    "serve stop",  "serve logs",         "superuser create",
    "schema dump", "migrate status",     "schema apply",
    "openapi",     "schema check-rules",
};

/// The two literal prefixes after which a command token is expected: the CLI
/// invocation itself, and — because the framework-mode "Checking work" table tells
/// an agent to run everything through the build system — `zig build run --`. An
/// agent copies THOSE rows verbatim, so a typo there is exactly what this guard
/// must not miss.
const command_prefixes = [_][]const u8{ "zigbase ", "zig build run -- " };

/// Reads a command token (ASCII letters and `-`) starting at `start`.
fn readToken(haystack: []const u8, start: usize) []const u8 {
    var end = start;
    while (end < haystack.len and (std.ascii.isAlphabetic(haystack[end]) or haystack[end] == '-')) : (end += 1) {}
    return haystack[start..end];
}

/// True iff `cmd` is exactly the two-word entry `"first second"`.
fn matchesTwoWord(cmd: []const u8, first: []const u8, second: []const u8) bool {
    if (cmd.len != first.len + 1 + second.len) return false;
    if (!std.mem.eql(u8, cmd[0..first.len], first)) return false;
    if (cmd[first.len] != ' ') return false;
    return std.mem.eql(u8, cmd[first.len + 1 ..], second);
}

/// True iff `commands_named` has any two-word entry whose first word is `first`
/// (i.e. `first` is a verb that has real subcommands an agent might typo).
fn hasTwoWordContinuation(first: []const u8) bool {
    for (commands_named) |cmd| {
        if (cmd.len > first.len and cmd[first.len] == ' ' and std.mem.eql(u8, cmd[0..first.len], first)) return true;
    }
    return false;
}

/// Scans `haystack` for either literal in `command_prefixes` and returns the first
/// following command token — or, for verbs with real subcommands (`serve`,
/// `superuser`, `schema`, `migrate`), the first following SECOND token — that is NOT
/// in `commands_named`, or `null` if every occurrence names a real command (and, for
/// those verbs, a real subcommand). A following token that does not start with a
/// lowercase ASCII letter is skipped — it is prose or a URL, not a command:
/// `@import("zigbase")`, `/zigbase` (a container path), `zigbase <cmd>` (a
/// placeholder), a markdown link target, `zigbase explain-code CODE`, etc.
pub fn findUnknownCommand(haystack: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (true) {
        // Earliest occurrence, at or after i, of any recognized prefix.
        var best_pos: ?usize = null;
        var best_end: usize = 0;
        for (command_prefixes) |prefix| {
            if (std.mem.indexOfPos(u8, haystack, i, prefix)) |pos| {
                if (best_pos == null or pos < best_pos.?) {
                    best_pos = pos;
                    best_end = pos + prefix.len;
                }
            }
        }
        if (best_pos == null) break;
        const start = best_end;
        i = start;
        if (start >= haystack.len) break;
        if (!std.ascii.isLower(haystack[start])) continue;

        const token1 = readToken(haystack, start);
        i = start + token1.len;

        var token1_known = false;
        for (commands_named) |cmd| {
            if (std.mem.eql(u8, cmd, token1)) {
                token1_known = true;
                break;
            }
        }
        if (!token1_known) return token1;

        // Verbs with real subcommands must also have their second word checked —
        // a typo there (`serve statuss`) is invisible to a first-token-only scan.
        if (hasTwoWordContinuation(token1) and i < haystack.len and haystack[i] == ' ') {
            const second_start = i + 1;
            if (second_start < haystack.len and std.ascii.isLower(haystack[second_start])) {
                const token2 = readToken(haystack, second_start);
                var combo_known = false;
                for (commands_named) |cmd| {
                    if (matchesTwoWord(cmd, token1, token2)) {
                        combo_known = true;
                        break;
                    }
                }
                if (!combo_known) return token2;
                i = second_start + token2.len;
            }
        }
    }
    return null;
}

test "generated AGENTS.md names only commands the binary really has" {
    for ([_][]const u8{ text(.box), text(.framework) }) |t| {
        if (findUnknownCommand(t)) |bad| {
            std.debug.print("AGENTS.md names unknown command '{s}'\n", .{bad});
            try std.testing.expect(false);
        }
    }
}

test "CLAUDE.md is the one-line include" {
    try std.testing.expectEqualStrings("@AGENTS.md\n", claude_md);
}
