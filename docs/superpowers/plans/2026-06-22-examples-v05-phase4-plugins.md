# Phase 4 — plugins example: advanced auth surface + onAuth + collation index

**Date:** 2026-06-22  
**Branch:** `feat/examples-v05-phase4-plugins` (branch from origin/main after Phase 1 lands)  
**Spec:** `docs/superpowers/specs/2026-06-22-examples-v05-features-design.md` § "plugins"  
**Depends on:** Phase 1 (E1 comptime `.indexes` wiring + E2 `public_url`)

---

## Global Constraints

| Constraint | Detail |
|---|---|
| Zig version | `mise exec zig@0.16.0 -- zig build` (pinned via `mise.toml`) |
| Test command | `mise exec zig@0.16.0 -- zig build test --summary all` — authoritative signal is `Build Summary: N/N tests passed` |
| Frontend build | `cd examples/plugins/frontend && npm install && npm run build` BEFORE `zig build` — `frontend/dist` must exist at build time |
| Public API only | ALL example code imports only `@import("zigbase")` — no reaching into `src/*.zig` internals |
| Changelog | Add `changelog.d/examples-v05-phase4-plugins.md` (never edit `CHANGELOG.md`) |
| Docs/site sync | Any `docs/*.md` change must be mirrored into `site/src/content/`; run `cd site && npm run build` to verify |
| Examples in CI | CI builds all three examples; `plugins` frontend `npm run build` is a prerequisite in CI |
| Provisioning caveat | auth config + indexes are applied only on FIRST collection creation (fresh DB). Examples always run against a fresh DB, so this is fine; noted in comments not fixed |

---

## Re-export Feasibility Verdict (BLOCKING CHECK — READ FIRST)

### What IS re-exported in `src/root.zig` (lines 58–61):
```zig
pub const AuthMethod = @import("auth/method.zig").AuthMethod;   // zigbase.AuthMethod
pub const AuthCtx    = @import("auth/method.zig").AuthCtx;      // zigbase.AuthCtx
pub const InitiateResult = @import("auth/method.zig").InitiateResult; // zigbase.InitiateResult
pub const Resolution = @import("auth/method.zig").Resolution;   // zigbase.Resolution
```
These four types — needed to WRITE a custom `AuthMethod` plugin — are fully public. ✓

### What is NOT re-exported at the top level:
```zig
// events.zig defines AuthEvent and AuthHandler at lines 176–183
pub const AuthEvent = struct { ... };
pub const AuthHandler = *const fn (ev: *AuthEvent) void;
```
`root.zig` re-exports `RecordEvent`, `ErrorEvent`, `RouteEvent`, `JobEvent` individually, but does **not** re-export `AuthEvent` or `AuthHandler`. They are reachable only as `zigbase.events.AuthEvent` and `zigbase.events.AuthHandler`.

### Action Required (Task 0 — BLOCKING PREREQUISITE):

**Add two lines to `src/root.zig`** (after line 19 where `JobEvent` is re-exported):
```zig
pub const AuthEvent = events.AuthEvent;
pub const AuthHandler = events.AuthHandler;
```
Without this, the `handleAuth` function in `examples/plugins/src/main.zig` would need to write `*zigbase.events.AuthEvent` — technically valid but inconsistent with every other event type's naming pattern. The fix is a two-line change to `root.zig`; add a unit-test assertion to verify the re-export is reachable.

**This task must land in Phase 1 or as a standalone micro-PR before Phase 4 work begins.**

---

## Frontend Reconnaissance Summary

**Stack:** Astro 5 + React 19 (`.tsx` components), TypeScript. Single-page app served same-origin from the binary via `embedStaticDir`. Build output: `frontend/dist/`. No runtime JS bundler dependency.

**Current structure:**
- `frontend/src/pages/index.astro` — shell page, mounts `<Browser client:load />`
- `frontend/src/components/Browser.tsx` — single React component: fetches authors/posts/comments, renders three cards (authors list, published posts, approved comments)
- `frontend/src/lib/api.ts` — typed fetch helpers: `listAuthors`, `listPosts`, `listComments`
- `frontend/src/styles/global.css` — CSS

**Where comment-login UI goes:**  
The `comments` card in `Browser.tsx` is the natural home. It gains a sub-component or inline expansion:
- An "Add a comment" section beneath the approved-comments list
- If not logged in: shows a "Sign in with magic link" email form; on submit, calls `POST /api/collections/commenters/auth/magic_link/initiate` and shows "Check your email"
- If logged in (session cookie): shows the comment compose form; on submit, calls `POST /api/collections/comments/records` with the commenter relation auto-populated from `@request.auth.id` in the access rule
- Login state detection: a `GET /api/collections/commenters/auth` or a `GET /api/collections/comments/records` 401 check; simplest is `GET /api/collections/commenters/records/me` → if 200, logged in

**WebAuthn UI recommendation: DOCUMENT, DO NOT BUILD.**  
Passkey registration/authentication requires `navigator.credentials.create()` / `.get()` WebAuthn browser APIs, binary CBOR encoding, and a multi-round-trip ceremony. Building correct, accessible passkey UI is a substantial frontend project. The example already showcases webauthn at the Zig/schema level (`authors` collection with `.auth.methods.webauthn = ...`). The plan: add a `<!-- WebAuthn: passkey registration for authors -->\n<!-- See README for the ceremony. API endpoints: POST /api/collections/authors/auth/webauthn/register/begin, /finish -->` code comment in the frontend, and a clear README section explaining the endpoints and pointing to the spec. This keeps the example honest (the feature IS wired up) without the disproportionate frontend cost.

---

## Task List

### Task 0 — Add `AuthEvent` / `AuthHandler` re-exports to `src/root.zig` *(BLOCKING)*

**File:** `src/root.zig`

**Change:** After line 19 (`pub const JobEvent = events.JobEvent;`), add:
```zig
pub const AuthEvent = events.AuthEvent;
pub const AuthHandler = events.AuthHandler;
```

**Test (add to `src/root.zig` test block — already references `events.zig`):**  
Compile-time proof: add an assertion in `src/events.zig` (or a short `test` in `src/root.zig`'s test block) that `@import("zigbase").AuthEvent` is the same type as `events.AuthEvent`. The simplest approach is a `test` in `events.zig`:
```zig
test "AuthEvent and AuthHandler are exported at zigbase.AuthEvent/AuthHandler" {
    // Reachability check: if this compiles, root.zig re-exports them.
    // (Not a runtime assertion; the test body intentionally does nothing.)
    const _: type = @import("../root.zig").AuthEvent;
    const _: type = @import("../root.zig").AuthHandler;
}
```

**Why this is Phase 1 work:** It is a framework change (not example code), it fits cleanly in the Phase 1 PR alongside the other `root.zig` surface work, and Phase 4 is blocked on it.

---

### Task 1 — `authors` collection: base → auth, webauthn + api_token

**File:** `examples/plugins/src/main.zig`

**Current schema:**
```zig
.authors = .{
    .type = .base,
    .fields = .{
        .{ .name = "name", .type = .text, .required = true },
        .{ .name = "contact_email", .type = .email },
        .{ .name = "bio", .type = .text, .max = 500 },
    },
    .rules = .{ .list = "@public", .view = "@public" },
},
```

**New schema (replace the entire `authors` entry):**
```zig
.authors = .{
    // Auth collection: system fields (email, password_hash, verified, …) are
    // injected automatically by the auth type. Keep contact_email/bio as user fields.
    // NOTE: "email" is a reserved system field name on auth collections; keep
    // contact_email as the human-readable contact address and use the system email
    // field as the login identity.
    .type = .auth,
    .fields = .{
        .{ .name = "name", .type = .text, .required = true },
        // contact_email is distinct from the system `email` login field.
        .{ .name = "contact_email", .type = .email },
        .{ .name = "bio", .type = .text, .max = 500 },
    },
    // Per-collection auth method policy:
    //   webauthn — passkey login for human authors (rp_id/rp_name/origin for localhost dev).
    //   custom   — list of registered custom-plugin slugs; "api_token" enables
    //              the ApiTokenMethod plugin (registered app-level via .auth_methods).
    .auth = .{
        .methods = .{
            .webauthn = .{
                .rp_id = "localhost",
                .rp_name = "ZigBase Plugins Example",
                .origin = "http://localhost:8090",
            },
            .custom = .{"api_token"},
        },
    },
    // Authors are publicly readable; write rules stay locked (default = null = superuser only).
    .rules = .{ .list = "@public", .view = "@public" },
    // Comptime index: NOCASE on contact_email so lookups are case-insensitive.
    // Contrast: migration 0002 indexes plugin_audit_log.note (a migration-owned table)
    // because that table's column names are under our control. For managed collections,
    // comptime .indexes is the right tool — columns are human-named (field.name), not
    // id-named (see D2 fix).
    .indexes = .{
        .{ .name = "idx_authors_contact_email", .fields = .{"contact_email"}, .collation = .nocase },
    },
},
```

**Tests:** No unit tests for schema literals; compile is the test. Verify with `zig build test --summary all`.

---

### Task 2 — Add `commenters` auth collection (magic_link)

**File:** `examples/plugins/src/main.zig`

**Add as a new top-level entry in `.collections` (after `authors`, before `posts`):**
```zig
.commenters = .{
    // Lightweight passwordless auth collection for casual readers who want to comment.
    // magic_link with auto_create = true: a new reader's account is created on first login
    // (no separate sign-up step). ttl_s = 900 (15 minutes) is generous for a demo.
    .type = .auth,
    .fields = .{
        .{ .name = "display_name", .type = .text, .max = 80 },
    },
    .auth = .{
        .methods = .{
            .magic_link = .{ .ttl_s = 900, .auto_create = true },
        },
    },
    // Publicly listable (so the frontend can render commenter display_name),
    // but only authed commenters can view their own full record.
    .rules = .{
        .list = "@public",
        .view = "@request.auth.id != \"\"",
    },
},
```

**Note:** `public_url` (E2) must be configured at runtime via `ZIGBASE_PUBLIC_URL` for the magic-link email to contain a real clickable URL. The README documents this.

---

### Task 3 — Update `comments` collection: replace `author_name` with `commenter` relation, gate create

**File:** `examples/plugins/src/main.zig`

**Replace the `comments` collection entry:**
```zig
.comments = .{
    .type = .base,
    .fields = .{
        .{ .name = "body", .type = .text, .required = true, .max = 2000 },
        // Relation to the parent post (cascade-delete propagates post removal).
        .{ .name = "post", .type = .relation, .target = "posts", .cascadeDelete = true },
        // Relation to the authenticated commenter — replaces the old free-text author_name.
        // A comment cannot be submitted without an authed commenter identity.
        .{ .name = "commenter", .type = .relation, .target = "commenters" },
        .{ .name = "approved", .type = .bool },
    },
    // Approved comments are publicly readable.
    // create requires an authed commenter (not a superuser check — any logged-in
    // commenter may submit). Moderation (approved=true) is done by superusers/authors.
    .rules = .{
        .list = "approved = true",
        .view = "approved = true",
        // Gate: requester must have a valid session (any collection).
        .create = "@request.auth.id != \"\"",
    },
},
```

---

### Task 4 — Implement `ApiTokenMethod` custom auth plugin

**File:** `examples/plugins/src/main.zig` (add as a new top-level `const` before the `main` function)

```zig
// ---------------------------------------------------------------------------
// Custom AuthMethod plugin: "api_token"
//
// Demonstrates the zigbase.AuthMethod plugin contract. An author authenticates
// by sending their API token (a shared secret stored in the record's `bio` field
// for simplicity — a real app would use a dedicated hashed-token field) in the
// request body as `{ "token": "..." }`.
//
// Plugin contract (mirrors AuditStorage / AuditMailer):
//   create(gpa, io, cfg) !Self       — construct; gpa/cfg available if needed.
//   method(*Self) zigbase.AuthMethod — return the vtable the auth dispatch calls.
//   deinit(*Self) void               — release any resources.
//
// The framework validates this contract at comptime via assertAuthMethodContract.
// Registered app-level via `.auth_methods = .{ApiTokenMethod}` and enabled on
// the `authors` collection via `.auth.methods.custom = .{"api_token"}`.
//
// AuthCtx helpers used here (all via public zigbase.AuthCtx):
//   ac.findByIdentity(conn, identity)    — looks up record_id by the auth identity
//                                          (system `email` field for auth collections).
//   ac.rateLimit(scope, ident)           — returns ?Response; non-null means limited.
//   ac.reader() / ac.writer()            — RAII DB-access handles.
//
// Resolution variants:
//   .record = id_string  — framework mints a session + fires onAuth(.custom).
//   .fail = { .status, .message }  — framework returns the status code + body.
// ---------------------------------------------------------------------------
const ApiTokenMethod = struct {
    pub fn create(
        gpa: std.mem.Allocator,
        io: std.Io,
        cfg: zigbase.Config,
    ) !ApiTokenMethod {
        _ = gpa;
        _ = io;
        _ = cfg;
        return .{};
    }

    pub fn method(self: *ApiTokenMethod) zigbase.AuthMethod {
        return .{
            .slug = "api_token",
            .ctx = self,
            .vtable = &vtable,
        };
    }

    pub fn deinit(self: *ApiTokenMethod) void {
        _ = self;
    }

    const vtable = zigbase.AuthMethod.VTable{
        .initiate = initiate,
        .complete = complete,
    };

    // initiate: called by POST /api/collections/authors/auth/api_token/initiate.
    // For a simple token-exchange method, initiate is a no-op (we do everything in complete).
    fn initiate(ctx: *anyopaque, ac: *zigbase.AuthCtx) anyerror!zigbase.InitiateResult {
        _ = ctx;
        _ = ac;
        return .{ .status = 200, .body = "{\"flow\":\"direct\"}" };
    }

    // complete: called by POST /api/collections/authors/auth/api_token/complete.
    // Expects JSON body: { "identity": "<email>", "token": "<api_token>" }
    // The "token" is compared to the record's `bio` field (demo simplification).
    fn complete(ctx: *anyopaque, ac: *zigbase.AuthCtx) anyerror!zigbase.Resolution {
        _ = ctx;

        // Rate-limit by IP before any DB access.
        if (try ac.rateLimit("api_token", "ip")) |_| {
            return .{ .fail = .{ .status = 429, .message = "rate limited" } };
        }

        // Parse the JSON body for identity + token.
        const body = ac.ctx.body() orelse return .{ .fail = .{
            .status = 400,
            .message = "missing body",
        } };
        const parsed = std.json.parseFromSlice(
            struct { identity: []const u8, token: []const u8 },
            ac.ctx.allocator,
            body,
            .{},
        ) catch return .{ .fail = .{ .status = 400, .message = "invalid JSON" } };
        defer parsed.deinit();

        // Look up the record by identity (system email field).
        var r = try ac.reader();
        defer r.deinit();
        const record_id = try ac.findByIdentity(&r.conn, parsed.value.identity) orelse
            return .{ .fail = .{ .status = 401, .message = "unknown identity" } };

        // Fetch the record to verify the token against `bio` (demo: bio IS the token).
        const rec = try r.data().findById("authors", record_id) orelse
            return .{ .fail = .{ .status = 401, .message = "record not found" } };
        const stored_token = switch (rec.object.get("bio") orelse .null) {
            .string => |s| s,
            else => "",
        };
        if (!std.mem.eql(u8, stored_token, parsed.value.token)) {
            return .{ .fail = .{ .status = 401, .message = "invalid token" } };
        }

        std.log.info("[api_token] authenticated author id={s}", .{record_id});
        return .{ .record = record_id };
    }
};
```

**Notes:**
- `ac.ctx.body()` — `AuthCtx.ctx` is `*http.RequestCtx`; confirm `.body()` is available on `http.RequestCtx`. If not, use `ac.ctx.req.body` or equivalent. Investigate `src/http.zig` at implementation time.
- The `bio` = token design is intentionally a demo shortcut — comment in the code explains this.
- `r.data().findById` — `r.data()` returns `Data`; `findById(collection, id)` is confirmed public via `zigbase.Data`.

---

### Task 5 — Add `onAuth` hook handler

**File:** `examples/plugins/src/main.zig`

**Add before `main`:**
```zig
// ---------------------------------------------------------------------------
// onAuth hook — fires after every successful session mint across all collections.
//
// This binary issues sessions for THREE collections via FOUR distinct methods:
//   authors    → webauthn (passkey)
//   authors    → custom / api_token (programmatic)
//   commenters → magic_link (emailed link)
//
// The `method` field is a `zigbase.events.AuthMethod` enum (imported as
// `zigbase.AuthEvent.method`'s type). Access it via the fully-qualified path:
//   `zigbase.events.AuthMethod` or the top-level re-export `zigbase.AuthEvent`
//   (see root.zig lines added in Task 0).
//
// `ev.record` is ?std.json.Value — null only for OAuth2 provider-unknown paths.
// ---------------------------------------------------------------------------
fn handleAuth(ev: *zigbase.AuthEvent) void {
    const method_name = switch (ev.method) {
        .password   => "password",
        .oauth2     => "oauth2",
        .magic_link => "magic_link",
        .otp        => "otp",
        .webauthn   => "webauthn",
        .custom     => "custom",
    };
    const record_id = if (ev.record) |r|
        (r.object.get("id") orelse .null).string
    else
        "(unknown)";
    std.log.info("[onAuth] collection={s} method={s} record={s}", .{
        ev.collection, method_name, record_id,
    });
}
```

---

### Task 6 — Wire everything into `App(.{...})`

**File:** `examples/plugins/src/main.zig` — the `App(...)` call in `main`.

**Updated `App(.{})` config (complete, replacing the current one):**
```zig
return zigbase.App(.{
    // 1. Custom storage plugin — unchanged.
    .storage = AuditStorage,

    // 2. Custom mailer plugin — unchanged.
    .mailer = AuditMailer,

    // 3. App-level custom auth method registry.
    //    ApiTokenMethod is the plugin type; it is enabled on the `authors` collection
    //    via `.auth.methods.custom = .{"api_token"}` in the comptime schema.
    .auth_methods = .{ApiTokenMethod},

    // 4. Comptime schema — see Tasks 1–3 for field-by-field changes.
    .collections = .{
        .authors   = .{ ... },   // Task 1
        .commenters = .{ ... },  // Task 2
        .posts     = .{ ... },   // unchanged except relation resolves fine
        .comments  = .{ ... },   // Task 3
    },
    .enable_typegen = true,

    // 5. Explicit migrations — unchanged from current (comments in 0002 updated per D2).
    .migrations = &[_]zigbase.Migration{
        .{ .id = "0001_create_audit_log", .up = createAuditLog },
        .{ .id = "0002_index_audit_note", .up = addAuditNoteIndex },
    },

    // 6. onError handler — unchanged.
    .onError = handleError,

    // 7. onAuth hook — new: fires after any successful session across all collections.
    .onAuth = handleAuth,

    // 8. Cron job — unchanged.
    .cron = .{
        .{
            .name = "audit-sweep",
            .schedule = zigbase.schedule.Schedule{ .cron = "* * * * *" },
            .handler = auditSweepJob,
        },
    },

    // 9. Pool levers — unchanged.
    .pools = .{ .readers = 4, .jobs = 1, .cache_kib = 512 },

    // 10. Embedded static frontend — unchanged.
    .static_files = .{ .embedded = &@import("static_assets").files },
}).runCli(init);
```

---

### Task 7 — Fix migration 0002 comment (D2)

**File:** `examples/plugins/src/main.zig`

**Replace the `CRITICAL LESSON` block in the doc-comment of `addAuditNoteIndex` (lines 321–332):**

Old (FALSE):
```
//     CRITICAL LESSON — raw SQL migrations and comptime collections:
//       A migration is hand-written SQL, so it can only safely reference columns
//       whose names it KNOWS. The comptime `.collections` provisioner names each
//       collection's SQLite columns by its STABLE FIELD ID (an 8-char hex string
//       from `stableFieldId`), NOT by the human-readable field name. So a posts
//       row's "status" lives in a column like "a1b2c3d4" — there is no literal
//       `status` column, and `CREATE INDEX ... ON posts (status)` fails with
//       ExecFailed, aborting startup. The safe target for a raw migration is a
//       table the MIGRATION ITSELF owns (here `plugin_audit_log`, whose column
//       names we chose), where the names are known. (To index a provisioned
//       column you would have to resolve its field id first.)
```

New (CORRECT):
```
//     WHEN TO USE RAW SQL MIGRATIONS vs. COMPTIME .indexes:
//       For comptime-managed collections, use `.indexes` in the collection literal —
//       those are lowered at provision time and reference columns by their human
//       field name (e.g. `contact_email`). The `stableFieldId` is an internal
//       rebuild-matching key, never used as a SQL column name. So `CREATE INDEX ...
//       ON posts (status)` DOES work in a raw migration if you own the query.
//
//       The reason THIS migration targets `plugin_audit_log` — a migration-owned
//       table — is that the migration is demonstrating the escape-hatch pattern
//       for non-additive DDL on tables the migration itself creates. For a
//       comptime-managed collection, prefer `.indexes = .{ ... }` in the collection
//       spec (see the `authors` collection for a working example).
```

---

### Task 8 — Frontend: commenter magic-link login flow

**Files to modify:**
- `examples/plugins/frontend/src/lib/api.ts`
- `examples/plugins/frontend/src/components/Browser.tsx`
- Optionally extract: `examples/plugins/frontend/src/components/CommentSection.tsx`

#### 8a. `api.ts` additions

Add the following after the existing exports:
```typescript
// ---- Auth: commenters magic-link -------------------------------------------

export type Commenter = { id: string; display_name?: string };

/** Attempt to get the currently-logged-in commenter from the server session. */
export async function getMe(): Promise<Commenter | null> {
  const r = await fetch('/api/collections/commenters/records/me');
  if (r.status === 401 || r.status === 403) return null;
  if (!r.ok) throw new Error(`HTTP ${r.status}`);
  return r.json();
}

/** Initiate magic-link login: POST the email, server sends the link. */
export async function initiateLogin(email: string): Promise<void> {
  const r = await fetch('/api/collections/commenters/auth/magic_link/initiate', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ identity: email }),
  });
  if (!r.ok) {
    const err = await r.json().catch(() => null);
    throw new Error(err?.message ?? `HTTP ${r.status}`);
  }
}

/** Submit a comment. Requires an active session (cookie). */
export async function createComment(postId: string, body: string): Promise<void> {
  const r = await fetch('/api/collections/comments/records', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ post: postId, body }),
  });
  if (!r.ok) {
    const err = await r.json().catch(() => null);
    throw new Error(err?.message ?? `HTTP ${r.status}`);
  }
}
```

**Note on `commenter` relation in `createComment`:** The `create` rule is `@request.auth.id != ""`, meaning the framework gates on any active session. The `commenter` relation field on the record should be set to `@request.auth.id` automatically if we include it in the body, or it can be omitted and filled server-side via a `beforeCreate` hook if needed. Simplest approach: include `commenter: undefined` (omit it) and let the access rule gate. In a real app you would include `commenter: @request.auth.id` via the API — but REST clients can't reference `@request.auth.id` directly. **Implementation note:** The frontend should send `commenter` as an empty string or let the server's `beforeCreate` hook populate it from the session. Add a `beforeCreate` hook on `comments` in `main.zig` (Task 8d) that sets `ev.record.object.put("commenter", .{ .string = ev.ctx.auth_id orelse "" })`.

#### 8b. `Browser.tsx` additions

Replace the comment section card. Extract the login/comment UI into a `CommentSection` component either inline or as a new file. Here is the full inline replacement for the comments section in `Browser.tsx`:

```tsx
// State additions to Browser():
const [me, setMe] = useState<Commenter | null | 'loading'>('loading');
const [loginEmail, setLoginEmail] = useState('');
const [loginState, setLoginState] = useState<'idle' | 'sent' | 'error'>('idle');
const [commentBody, setCommentBody] = useState('');
const [commentPost, setCommentPost] = useState('');
const [submitState, setSubmitState] = useState<'idle' | 'ok' | 'error'>('idle');
const [submitError, setSubmitError] = useState<string | null>(null);

// Add to the useEffect:
getMe().then(setMe).catch(() => setMe(null));
// (run in the same Promise.all or a separate effect — both work; separate is simpler)

// Replace the comments <section> in the return:
<section className="card">
  <h2>Approved comments ({comments.length})</h2>
  {comments.length === 0
    ? <p className="muted">None yet &mdash; approved comments appear here.</p>
    : <ul>{comments.map((c) => (
        <li key={c.id}>
          <span className="muted">
            {c.expand?.commenter?.display_name ?? 'anonymous'}:{' '}
          </span>
          {c.body}
        </li>
      ))}</ul>}

  <h3>Add a comment</h3>
  {me === 'loading' ? (
    <p className="muted">Checking login&hellip;</p>
  ) : me === null ? (
    /* Not logged in: show magic-link email form */
    loginState === 'sent' ? (
      <p className="muted">Check your email for a login link. (In local dev, look in the server log.)</p>
    ) : (
      <form onSubmit={async (e) => {
        e.preventDefault();
        try { await initiateLogin(loginEmail); setLoginState('sent'); }
        catch (err: any) { setLoginState('error'); }
      }}>
        <input
          type="email"
          placeholder="your@email.com"
          value={loginEmail}
          onChange={(e) => setLoginEmail(e.target.value)}
          required
        />
        <button type="submit">Send login link</button>
        {loginState === 'error' && <p className="error">Login failed. Try again.</p>}
      </form>
    )
  ) : (
    /* Logged in: show comment compose form */
    submitState === 'ok' ? (
      <p className="muted">Comment submitted &mdash; pending approval.</p>
    ) : (
      <form onSubmit={async (e) => {
        e.preventDefault();
        try {
          await createComment(commentPost, commentBody);
          setSubmitState('ok');
          setCommentBody('');
        } catch (err: any) {
          setSubmitState('error');
          setSubmitError(err.message);
        }
      }}>
        <select value={commentPost} onChange={(e) => setCommentPost(e.target.value)} required>
          <option value="">Select a post…</option>
          {(posts ?? []).map((p) => <option key={p.id} value={p.id}>{p.title}</option>)}
        </select>
        <textarea
          placeholder="Your comment…"
          value={commentBody}
          onChange={(e) => setCommentBody(e.target.value)}
          required
        />
        <button type="submit">Submit</button>
        {submitState === 'error' && <p className="error">{submitError}</p>}
      </form>
    )
  )}
</section>
```

**Import additions at top of `Browser.tsx`:**
```typescript
import { getMe, initiateLogin, createComment, type Commenter } from '../lib/api';
```

**`Comment` type update** in `api.ts` — replace `author_name` with commenter expand:
```typescript
export type Comment = {
  id: string;
  body: string;
  post: string;
  commenter: string;
  expand?: { commenter?: Commenter };
};
```

Update `listComments` to include expand:
```typescript
export async function listComments(): Promise<Comment[]> {
  return (await req('/api/collections/comments/records?sort=-created&per_page=10&expand=commenter')).items;
}
```

#### 8c. WebAuthn UI — document, do not build

Add to `index.astro` or a comment in `Browser.tsx`:
```html
<!-- WebAuthn (passkey) login for authors is wired at the server level.
     API endpoints:
       POST /api/collections/authors/auth/webauthn/register/begin   → challenge
       POST /api/collections/authors/auth/webauthn/register/finish  → credential
       POST /api/collections/authors/auth/webauthn/authenticate/begin  → challenge
       POST /api/collections/authors/auth/webauthn/authenticate/finish → session
     See examples/plugins/README.md for the passkey ceremony outline.
     Building a full WebAuthn UI requires navigator.credentials.create/get and
     CBOR encoding — see the README for links. -->
```

#### 8d. `beforeCreate` hook for comments — auto-populate `commenter` from session

**File:** `examples/plugins/src/main.zig`

Add a `beforeCreate` hook on `comments` that sets the `commenter` field to the
authenticated user's id so the frontend does not need to send it explicitly (and
so the relation is always authoritative):

```zig
fn beforeCreateComment(ev: *zigbase.RecordEvent) anyerror!void {
    // Populate `commenter` from the session identity if not provided by the client.
    // The create rule (@request.auth.id != "") already gated access, so ev.ctx
    // is guaranteed to carry a valid auth identity at this point.
    if (ev.record.object.get("commenter") == null) {
        const auth_id = ev.ctx.auth_id orelse return; // should never be null here
        try ev.record.object.put(ev.arena, "commenter", .{ .string = auth_id });
    }
}
```

Add to `App(.{})` config:
```zig
.hooks = .{
    .comments = .{ .beforeCreate = beforeCreateComment },
},
```

**Implementation note:** `ev.ctx.auth_id` — confirm the field name by checking `src/request.zig`'s `RequestContext` struct at implementation time. It may be `.auth_record_id` or similar.

---

### Task 9 — Update README

**File:** `examples/plugins/README.md`

Replace/extend the following sections:

#### Updated collections table:
```markdown
| Collection  | Type | Auth methods                   | Relations                          | Access rules |
|-------------|------|-------------------------------|------------------------------------|---|
| `authors`   | auth | webauthn (passkey) + api_token | —                                  | list/view: public |
| `commenters`| auth | magic_link (auto_create=true)  | —                                  | list: public; view: authed |
| `posts`     | base | —                              | `author → authors` (cascade-delete)| list: `status = "published"` |
| `comments`  | base | —                              | `post → posts`, `commenter → commenters` | list/view: `approved=true`; create: authed |
```

#### New section: "Auth methods in this example":
```markdown
## Auth methods in this example

Three collections use four auth methods, all disambiguated by `onAuth`:

| Collection  | Method     | How it works |
|-------------|------------|---|
| `authors`   | `webauthn` | Passkey registration + authentication via browser WebAuthn API. See [WebAuthn endpoints](#webauthn-endpoints) below. |
| `authors`   | `api_token`| Custom plugin: `POST .../auth/api_token/complete` with `{ "identity": "...", "token": "..." }`. Token is verified against the record's `bio` field (demo only). |
| `commenters`| `magic_link`| `POST .../auth/magic_link/initiate` with `{ "identity": "..." }`. Server emails a link. Set `ZIGBASE_PUBLIC_URL` for a clickable URL; otherwise look in the server log for the raw token. |

### WebAuthn endpoints (passkeys for authors)
```text
POST /api/collections/authors/auth/webauthn/register/begin    — start registration
POST /api/collections/authors/auth/webauthn/register/finish   — complete registration
POST /api/collections/authors/auth/webauthn/authenticate/begin   — start login
POST /api/collections/authors/auth/webauthn/authenticate/finish  — complete login, mint session
```
Building a full passkey UI requires `navigator.credentials.create()` / `.get()`, CBOR encoding, and careful error handling — a substantial frontend project. The Zig/schema wiring is complete; UI implementation is left as a reader exercise. See the [WebAuthn spec](https://www.w3.org/TR/webauthn-2/) and the annotated `src/auth/webauthn/` directory.
```

#### Updated "Build & run" with ZIGBASE_PUBLIC_URL:
```markdown
```sh
cd examples/plugins
cd frontend && npm install && npm run build && cd ..
mise exec zig@0.16.0 -- zig build
# ZIGBASE_PUBLIC_URL makes magic-link emails contain a real clickable URL.
# In local dev the token also appears in the server log (look for "magic_link token=").
ZIGBASE_PUBLIC_URL=http://localhost:8090 ./zig-out/bin/plugins serve --insecure-cookies
```
```

#### Updated section 4 (migrations D2 fix):
Replace the false "stable field id" rationale with the corrected one (matching the comment fix in Task 7).

#### New section items for the numbered list (add after existing item 7):
```markdown
8. **`onAuth` hook** via `.onAuth` — logs `collection + method` for every successful
   session mint. With two auth collections and three methods in use, the log shows
   the three distinct paths: `[onAuth] collection=authors method=webauthn`, 
   `[onAuth] collection=authors method=custom`, `[onAuth] collection=commenters method=magic_link`.

9. **Custom `AuthMethod` plugin** (`ApiTokenMethod`) via `.auth_methods = .{ApiTokenMethod}`.
   Enabled on `authors` via `.auth.methods.custom = .{"api_token"}`. Implements the
   plugin contract `create(gpa, io, cfg) !Self` / `method(*Self) zigbase.AuthMethod` /
   `deinit(*Self) void`, using `zigbase.AuthCtx` helpers (`findByIdentity`, `rateLimit`,
   `reader`). Returns a `zigbase.Resolution` (`.record` or `.fail`).

10. **Comptime `.indexes`** on `authors.contact_email` with `.collation = .nocase`
    (case-insensitive lookup). This demonstrates the correct tool for indexing
    comptime-managed collections — not a raw migration, because `.indexes` knows the
    field's human name (the column IS named `contact_email`, not a hex id).
```

---

### Task 10 — Changelog fragment

**File:** `changelog.d/examples-v05-phase4-plugins.md` (create new)

```markdown
### Features
- `examples/plugins` showcases the full advanced auth surface: `authors` auth collection with WebAuthn (passkeys) + a custom `ApiTokenMethod` plugin; `commenters` auth collection with magic-link (`auto_create=true`); `onAuth` hook logging all three methods; comptime `NOCASE` collation index on `authors.contact_email`; frontend magic-link comment flow.

### Fixes
- Corrected false claim in `examples/plugins` migration 0002 comment: provisioned collection columns are human-named (field.name), not id-named. Raw migrations targeting migration-owned tables remain valid; the rationale is now accurate.

### Internal
- Re-exported `AuthEvent` and `AuthHandler` at the top level of `zigbase` (`root.zig`) for consistency with `RecordEvent`/`ErrorEvent`/`RouteEvent`/`JobEvent`.
```

---

### Task 11 — Docs/site sync

**Files:**

1. **`docs/framework.md`** — confirm the D2 correction is present (was in Phase 1; if not, add it here: remove the "id-named columns" claim, replace with the accurate "human-named columns, .indexes for managed collections, migrations for migration-owned tables" explanation).

2. **`site/src/content/docs/framework.md`** (or whatever mirrors `docs/framework.md`) — mirror any D2 correction from docs/.

3. After edits: `cd site && npm run build` to confirm the site build passes.

---

## Verification Checklist

Run in order after all tasks:

```sh
# 1. Framework unit tests (from repo root)
mise exec zig@0.16.0 -- zig build test --summary all
# Expect: Build Summary: N/N tests passed

# 2. Plugins frontend build
cd examples/plugins/frontend
npm install && npm run build
cd ..

# 3. Plugins binary build
mise exec zig@0.16.0 -- zig build
# Expect: no compile errors, binary at zig-out/bin/plugins

# 4. Smoke-run the binary
./zig-out/bin/plugins help
ZIGBASE_PUBLIC_URL=http://localhost:8090 ./zig-out/bin/plugins serve --insecure-cookies
# Verify:
#   - Collections provisioned: authors (auth), commenters (auth), posts, comments
#   - idx_authors_contact_email created (check via admin UI or sqlite3 _collections)
#   - magic_link initiate: POST /api/collections/commenters/auth/magic_link/initiate
#   - api_token complete: POST /api/collections/authors/auth/api_token/complete
#   - onAuth log lines appear: [onAuth] collection=... method=...

# 5. Site build (if docs changed)
cd site && npm run build
```

---

## Open Questions / Assumptions

1. **`ev.ctx.auth_id` field name** (Task 8d / `beforeCreateComment`): `RequestContext` in `src/request.zig` must have a field holding the authenticated record id. Check the exact field name (`auth_id`, `auth_record_id`, `identity`?) at implementation time. If `RequestContext` doesn't expose it directly on `RecordEvent.ctx`, an alternative is to use `ev.record.object.get("@request.auth.id")` from the rule context — but that's not available in hook code. Most likely path: use `ev.ctx.auth_id` or `ev.ctx.user_id`. If neither exists, the `commenter` field must be sent by the client and the access rule alone gates correctness.

2. **`ac.ctx.body()` vs field access** (Task 4, `ApiTokenMethod.complete`): `AuthCtx.ctx` is `*http.RequestCtx`. The method for reading the raw request body on `RequestCtx` must be confirmed from `src/http.zig` at implementation time. May be `.body()`, `.bodySlice()`, or a field `.req.body`. The plan uses `.body()`.

3. **`r.data()` on AuthCtx reader** (Task 4): `AuthCtx.reader()` returns `events.ReaderData` which has `.data()` → `Data`. `Data.findById(collection, id)` is confirmed public. This should work as written.

4. **Comments `commenter` auto-population**: If `RequestContext.auth_id` is not accessible in hook context, the simplest fallback is to require the frontend to send `commenter: <commenter_id>` explicitly. The frontend can get the commenter id from `getMe()`. The access rule `@request.auth.id != ""` still gates the create; the hook just makes the relation automatic. Document both approaches.

5. **`getMe()` API endpoint**: `GET /api/collections/commenters/records/me` — confirm this endpoint exists in `api/records.zig`. If not, the alternative is to store the commenter id client-side in `localStorage` after the magic-link consume redirect sets the session cookie, and populate it in the comment body. Or use `GET /api/collections/commenters/auth` (if it returns the current record for the session). Check `src/api/auth.zig` at implementation time.

6. **Provisioning caveat (acknowledged, not fixed)**: auth config and `.indexes` are only applied on first collection creation. Since examples always use a fresh DB, this is fine. Any existing local `pb_data` directory must be deleted before testing the updated schema.

7. **Task ordering**: Tasks 0 (root.zig re-export) should be in Phase 1's PR. Tasks 1–11 are the Phase 4 PR. If Task 0 was missed in Phase 1, it can be a tiny preparatory commit at the start of the Phase 4 branch.
