# Examples v0.5+ — Phase 2: Blog Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Update the blog example to exercise the Phase 1 framework enablers: wire in the built-in `magic_link` auth method (with `public_url` config for a clickable emailed link), add a `NOCASE` unique index on `users.email` via comptime `.indexes`, and update the Astro + React frontend with a magic-link login form and logged-in-state rendering. No new custom routes — blog must remain a valid showcase of a **stock pre-compiled zigbase** binary configured entirely through the comptime schema and env vars.

**Architecture:**
- `examples/blog/src/main.zig` — add `.auth.methods.magic_link` + `.indexes` to the `users` collection. Update the module doc-comment.
- `examples/blog/frontend/src/lib/api.ts` — add `initiateLogin(email)` and `getMe()` functions; keep existing password helpers for backward compatibility.
- `examples/blog/frontend/src/components/Editor.tsx` — replace the email+password form with a magic-link login form (email → POST initiate → "check your email" state); add cookie-session detection; keep the post-write form.
- `examples/blog/frontend/src/layouts/Layout.astro` — add a `<AuthStatus client:load />` island to the nav for logged-in-state display.
- `examples/blog/frontend/src/components/AuthStatus.tsx` (new) — lightweight React island: calls `getMe()` on mount, shows "Signed in as X | Log out" or nothing.
- `examples/blog/README.md` — add magic-link section, `ZIGBASE_PUBLIC_URL` docs (fake `blog.test` URL explanation), and the email index.

**`public_url` decision:** The spec requires `public_url = "http://blog.test/"` — a deliberately fake URL — so the emailed link is a real clickable URL against the framework's built-in consume endpoint. The cleanest approach for a stock binary is **env var only**: document `ZIGBASE_PUBLIC_URL=http://blog.test/` in the README run command and in a comment in `main.zig`, so users see the fake URL immediately. The README must clearly state that `blog.test` does not resolve and that to actually click the link a user overrides `ZIGBASE_PUBLIC_URL=http://127.0.0.1:8090` (or their own host). No code change is needed in `main.zig` for `public_url` — it is consumed purely at runtime by the framework.

**Session model for magic-link:** After clicking the consume link the server sets `zb_auth` and `zb_csrf` cookies and 302-redirects to `/`. The frontend does NOT need a token-handling page. Session detection on the landing page is via a `GET /api/collections/users/auth/me` call (returns 200 + `{record: {id, email, ...}}` when a valid session cookie is present, 401 otherwise). `Editor.tsx` calls `getMe()` on mount to check authed state; `AuthStatus.tsx` does the same to display the user's email. The existing `localStorage` JWT path in `api.ts` is preserved for the password-auth flow (existing tests rely on it), but the `authed` state check in `Editor.tsx` is extended to also accept a cookie session returned by `getMe()`.

**Tech Stack:** Zig 0.16.0 (pinned via mise), Astro 5, React 19 islands. No new npm dependencies.

**Prerequisites:** Phase 1 (E1 comptime `.indexes`, E2 `public_url` config) must be merged before this PR. All tasks below assume those framework changes are present.

## Global Constraints

- Zig is pinned: run every Zig command as `mise exec zig@0.16.0 -- zig …`.
- Authoritative unit-test signal is the `Build Summary: N/N tests passed` line — use `mise exec zig@0.16.0 -- zig build test --summary all`. Ignore the spurious trailing `failed command: …` line.
- After any frontend change: `cd examples/blog/frontend && npm run build` to verify the Astro build passes.
- NEVER edit `CHANGELOG.md` or its site mirror directly — add a `changelog.d/<slug>.md` fragment.
- Any `docs/*.md` change must be mirrored into `site/src/content/docs/…`; build the site with `cd site && npm run build` when docs change.
- `main` is protected: land via PR + green CI; merge with `gh pr merge --merge` (no squash, no auto-merge). `gh pr edit` is broken here — use `gh api -X PATCH`.
- Work happens on branch `worktree-examples-v05-features` (already checked out in this worktree).
- Do NOT add new custom routes to the blog binary — blog must remain a stock-binary demo.
- Hook function bodies, existing pagination config, custom routes (`ping`, `posts/:slug`) and cron job are untouched.

---

### Task 1: Zig — wire `magic_link` + `NOCASE` email index into `users` collection

**Files:**
- Modify: `examples/blog/src/main.zig`

**What to change:**

1. Update the module doc-comment at the top of the file (`//!` block, lines 1–18) to mention magic-link auth and the email index.
2. Add `.auth` and `.indexes` to the `users` collection literal inside `App(.{ .collections = .{ .users = .{ ... } } })`.

The `users` collection block currently ends at:
```zig
            .users = .{
                .type = .auth,
                .fields = .{
                    .{ .name = "name", .type = .text, .max = 100 },
                },
                .rules = .{ .list = "@public", .view = "@public", .create = "@public", .update = "@request.auth.id = id", .delete = "@request.auth.id = id" },
            },
```

Replace it with (preserve existing fields and rules exactly, add `.auth` and `.indexes`):

```zig
            .users = .{
                .type = .auth,
                .fields = .{
                    .{ .name = "name", .type = .text, .max = 100 },
                },
                .rules = .{ .list = "@public", .view = "@public", .create = "@public", .update = "@request.auth.id = id", .delete = "@request.auth.id = id" },
                // Built-in magic-link login: POST initiate → link emailed (or logged in dev) →
                // GET consume sets session cookie + redirects to "/". No password required.
                // auto_create = true: a first-time visitor signing in gets an account automatically.
                // Set ZIGBASE_PUBLIC_URL=http://blog.test/ (fake; override to your host to click
                // the link) so the emailed link is a real clickable URL instead of a raw token.
                .auth = .{
                    .methods = .{
                        .magic_link = .{
                            .ttl_s = 3600,
                            .auto_create = true,
                            .redirect_default = "/",
                        },
                    },
                },
                // NOCASE unique index on email: prevents duplicate accounts differing only in
                // case (e.g. Bob@x.com and bob@x.com would otherwise be two separate users).
                .indexes = .{
                    .{ .name = "users_email_nocase", .fields = .{"email"}, .unique = true, .collation = .nocase },
                },
            },
```

3. Update the module doc-comment to add two new bullet lines under the existing `//!` description. Add after the existing `//! Hooks on "posts":` block:

```
//! Auth:
//!   - Built-in magic_link on users (auto_create, ttl 1 h, redirects to "/")
//!   - Set ZIGBASE_PUBLIC_URL for a clickable link (see README)
//!
//! Index:
//!   - NOCASE unique on users.email (prevents Bob@x.com / bob@x.com duplicates)
```

- [ ] **Step 1: Edit `examples/blog/src/main.zig`** — apply the doc-comment additions and the `users` collection changes as described above. Do NOT touch any hooks, routes, cron config, posts collection, or pagination config.

- [ ] **Step 2: Verify the blog binary builds cleanly**

```sh
cd examples/blog && mise exec zig@0.16.0 -- zig build 2>&1
```

Expected: no errors. The binary `examples/blog/zig-out/bin/blog` is emitted.

- [ ] **Step 3: Verify framework unit tests still pass**

From the repo root:
```sh
mise exec zig@0.16.0 -- zig build test --summary all 2>&1
```

Expected: `Build Summary: N/N tests passed` (N ≥ existing count). No regressions.

- [ ] **Commit:** `feat(examples/blog): add magic_link auth + NOCASE email index to users`

---

### Task 2: Frontend — add `initiateLogin` and `getMe` to `api.ts`

**Files:**
- Modify: `examples/blog/frontend/src/lib/api.ts`

**Context:** `api.ts` currently holds a `login(email, password)` function (line 45) that POSTs to `/api/collections/users/auth-with-password` and stores the JWT in localStorage. The magic-link flow is different: initiate returns 204 (no body), the actual session is established by the server via cookie after the user clicks the link. A `getMe()` call detects the cookie session after the redirect.

**What to add** (append to the file after `subscribePosts`, or insert before it for logical grouping):

```ts
/**
 * Initiate a magic-link login. Always resolves (server returns 204 — enumeration-safe).
 * The server emails (or logs in dev) a link to the consume endpoint.
 * Set ZIGBASE_PUBLIC_URL on the server so the link is a full clickable URL.
 */
export async function initiateLogin(email: string): Promise<void> {
  await fetch('/api/collections/users/auth/magic_link/initiate', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ identity: email }),
  });
  // 204 — no body, always resolves regardless of whether the email exists (enumeration-safe).
}

/**
 * Return the current user record if a session cookie is active (set by the
 * magic-link consume redirect), or null if unauthenticated.
 * Credentials: 'include' so the zb_auth cookie is sent.
 */
export type Me = { id: string; email: string; name?: string };
export async function getMe(): Promise<Me | null> {
  try {
    const r = await fetch('/api/collections/users/auth/me', { credentials: 'include' });
    if (!r.ok) return null;
    const out = await r.json();
    return (out?.record as Me) ?? null;
  } catch {
    return null;
  }
}
```

- [ ] **Step 1: Edit `examples/blog/frontend/src/lib/api.ts`** — append the two new exports (`initiateLogin` and `getMe` + `Me` type) after `subscribePosts`. Do NOT modify any existing exports.

- [ ] **Step 2: Verify TypeScript compiles** (Astro build):

```sh
cd examples/blog/frontend && npm run build 2>&1
```

Expected: build succeeds with no TypeScript errors.

- [ ] **Commit:** `feat(examples/blog): add initiateLogin + getMe to api.ts`

---

### Task 3: Frontend — replace password form with magic-link form in `Editor.tsx`

**Files:**
- Modify: `examples/blog/frontend/src/components/Editor.tsx`

**Context:** `Editor.tsx` currently (lines 1–50) shows a `!authed` branch with email + password fields and "Log in" / "Sign up" buttons that call `login(email, password)`. The magic-link flow replaces this with: email field → "Send magic link" button → `initiateLogin(email)` → show "Check your email" message. Logged-in state is now detected in two ways: (a) existing localStorage JWT (`token() !== null`, for users who previously used password login), (b) a cookie session after magic-link consume (`getMe()` on mount).

The post-writing form (the `authed` branch, lines 32–49) is left exactly as-is.

**Full new `Editor.tsx`** (replace completely — the authed branch body is identical, only the state management and unauthed branch change):

```tsx
import { useState, useEffect } from 'react';
import { login, signup, createPost, token, logout, initiateLogin, getMe, type Me } from '../lib/api';

export default function Editor() {
  // authed is true when a localStorage JWT OR a cookie session is present.
  const [authed, setAuthed] = useState(() => typeof localStorage !== 'undefined' && token() !== null);
  const [me, setMe] = useState<Me | null>(null);
  // login flow state
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [linkSent, setLinkSent] = useState(false);
  // write flow state
  const [title, setTitle] = useState('');
  const [body, setBody] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [done, setDone] = useState<string | null>(null);

  // On mount: check for a cookie session (set by the magic-link consume redirect).
  useEffect(() => {
    if (authed) return; // already authed via localStorage token — no need to call getMe
    getMe().then((m) => {
      if (m) { setMe(m); setAuthed(true); }
    });
  }, []);

  async function run(fn: () => Promise<void>) {
    setBusy(true); setError(null);
    try { await fn(); } catch (e: unknown) { setError(e instanceof Error ? e.message : String(e)); } finally { setBusy(false); }
  }

  if (!authed) {
    if (linkSent) {
      return (
        <div className="card">
          <h2>Check your email</h2>
          <p>
            A sign-in link has been sent to <strong>{email}</strong>.
            Click it to log in — no password needed.
          </p>
          <p className="muted">
            In local dev the link appears in the server log (look for{' '}
            <code>magic_link</code>). The link uses the host configured by{' '}
            <code>ZIGBASE_PUBLIC_URL</code>.
          </p>
          <button className="muted" onClick={() => setLinkSent(false)}>← Back</button>
        </div>
      );
    }

    return (
      <div className="card">
        <h2>Sign in to write</h2>
        {/* Magic-link flow (primary) */}
        <input placeholder="email" value={email} onChange={(e) => setEmail(e.target.value)} />
        <button
          disabled={busy || !email}
          onClick={() => run(async () => {
            await initiateLogin(email);
            setLinkSent(true);
          })}
        >
          Send magic link
        </button>
        {/* Password fallback (secondary, collapsed by default) */}
        <details style={{ marginTop: '0.75rem' }}>
          <summary className="muted" style={{ cursor: 'pointer' }}>Sign in with password instead</summary>
          <div style={{ marginTop: '0.5rem' }}>
            <input placeholder="password (8+ chars)" type="password" value={password} onChange={(e) => setPassword(e.target.value)} />
            <button disabled={busy} onClick={() => run(async () => { await login(email, password); setAuthed(true); })}>Log in</button>{' '}
            <button disabled={busy} onClick={() => run(async () => { await signup(email, password); setAuthed(true); })}>Sign up</button>
          </div>
        </details>
        {error && <p className="error">{error}</p>}
      </div>
    );
  }

  return (
    <div className="card">
      <h2>New post <button className="muted" onClick={() => { logout(); setAuthed(false); setMe(null); }}>log out</button></h2>
      <input placeholder="Title" value={title} onChange={(e) => setTitle(e.target.value)} />
      <textarea placeholder="Write your post…" rows={10} value={body} onChange={(e) => setBody(e.target.value)} />
      <button
        disabled={busy || !title}
        onClick={() => run(async () => {
          const post = await createPost(title, body);
          setDone(post.slug); setTitle(''); setBody('');
        })}
      >
        Publish
      </button>
      {done && <p>Published! <a href={`/post?slug=${encodeURIComponent(done)}`}>View it</a> (slug was derived by the server-side hook).</p>}
      {error && <p className="error">{error}</p>}
    </div>
  );
}
```

Key design decisions encoded here:
- Magic-link is the **primary** path (top-level button); password login is **secondary** (collapsed `<details>`). This preserves backward compatibility for existing accounts.
- `linkSent` state shows a "Check your email" message after initiate — no further frontend action needed (the server consume endpoint handles the redirect + cookie).
- `useEffect` on mount calls `getMe()` to detect a cookie session (from a magic-link consume redirect landing on `/write`). If `authed` is already true (localStorage token), `getMe()` is skipped.
- The `me` state is stored but not rendered in `Editor` itself — that display lives in `AuthStatus.tsx` (Task 4).
- The log-out button clears localStorage token and resets `me` to null; the cookie is cleared server-side if the framework provides a logout endpoint (else the cookie simply expires).

- [ ] **Step 1: Edit `examples/blog/frontend/src/components/Editor.tsx`** — replace the entire file content with the new version above.

- [ ] **Step 2: Verify TypeScript + Astro build**:

```sh
cd examples/blog/frontend && npm run build 2>&1
```

Expected: build succeeds. No TypeScript errors on the new `initiateLogin`/`getMe`/`Me` imports (added in Task 2).

- [ ] **Commit:** `feat(examples/blog): magic-link login form + cookie-session detection in Editor`

---

### Task 4: Frontend — `AuthStatus.tsx` island for nav logged-in state

**Files:**
- Create: `examples/blog/frontend/src/components/AuthStatus.tsx`
- Modify: `examples/blog/frontend/src/layouts/Layout.astro`

**Context:** `Layout.astro` currently has a static nav with links to `/`, `/write`, and `/_/`. After a magic-link consume redirect to `/`, the user is logged in (cookie) but the nav still shows nothing. Adding a small React island to the nav lets us display "Signed in as X | Log out" without making the whole layout server-rendered.

The island must be very lightweight — it just calls `getMe()` once on mount.

**New `AuthStatus.tsx`:**

```tsx
import { useState, useEffect } from 'react';
import { getMe, logout, type Me } from '../lib/api';

export default function AuthStatus() {
  const [me, setMe] = useState<Me | null>(null);
  const [checked, setChecked] = useState(false);

  useEffect(() => {
    getMe().then((m) => { setMe(m); setChecked(true); });
  }, []);

  if (!checked) return null; // avoid layout flash while fetching

  if (!me) return null; // not logged in — show nothing in the nav

  return (
    <span className="auth-status">
      ✉ {me.email}{' '}
      <button
        className="muted"
        onClick={() => { logout(); setMe(null); }}
      >
        log out
      </button>
    </span>
  );
}
```

**Modify `Layout.astro`** — import the island and add it to the nav. The nav currently (lines 14–18) is:

```astro
      <nav>
        <a class="brand" href="/">~*~ ZigBase Blog ~*~</a>
        <a href="/write">✍ Write</a>
        <a href="/_/" data-astro-reload>⚙ Admin</a>
      </nav>
```

Change it to:

```astro
      <nav>
        <a class="brand" href="/">~*~ ZigBase Blog ~*~</a>
        <a href="/write">✍ Write</a>
        <a href="/_/" data-astro-reload>⚙ Admin</a>
        <AuthStatus client:load />
      </nav>
```

And add the import at the top of the frontmatter:

```astro
---
import '../styles/global.css';
import AuthStatus from '../components/AuthStatus.tsx';
const { title = 'ZigBase Blog' } = Astro.props;
---
```

- [ ] **Step 1: Create `examples/blog/frontend/src/components/AuthStatus.tsx`** with the content above.

- [ ] **Step 2: Edit `examples/blog/frontend/src/layouts/Layout.astro`** — add the import line in the frontmatter and the `<AuthStatus client:load />` tag in the nav.

- [ ] **Step 3: Verify Astro build**:

```sh
cd examples/blog/frontend && npm run build 2>&1
```

Expected: build succeeds. `AuthStatus` island is bundled as a React component.

- [ ] **Commit:** `feat(examples/blog): AuthStatus nav island for cookie-session logged-in display`

---

### Task 5: README update

**Files:**
- Modify: `examples/blog/README.md`

**What to add/change:**

1. **Feature table** (currently ends after the Pagination row): add three new rows:

| ZigBase feature | How it's used |
|---|---|
| Built-in magic-link auth | `users.auth.methods.magic_link` — email-based passwordless login (auto_create, 1 h TTL) |
| `ZIGBASE_PUBLIC_URL` | Set to `http://blog.test/` (fake) so the emailed link is a full clickable URL; override to your host to actually click it |
| Comptime `.indexes` | `NOCASE` unique index on `users.email` — prevents case-variant duplicate accounts |

2. **New section `## Magic-link auth`** (insert after the `## Hooks` section, before `## Custom route`):

```markdown
## Magic-link auth

The blog uses the built-in magic-link method — no custom routes or backend code needed.

### How it works

1. User enters their email and clicks **Send magic link** in the write page's login form.
2. The frontend POSTs to `POST /api/collections/users/auth/magic_link/initiate` — the server always returns 204 (enumeration-safe: no indication of whether the email exists).
3. The server sends an email (or logs the link to the server console in local dev) containing a link to:
   ```
   GET <public_url>/api/collections/users/auth/magic_link/consume?token=…&redirect=/
   ```
4. The user clicks the link. The server validates the token, sets `zb_auth` and `zb_csrf` session cookies, and 302-redirects to `/`. No token-handling page is needed in the frontend.
5. On landing at `/`, the frontend detects the cookie session via `GET /api/collections/users/auth/me` and shows the logged-in state.

### `public_url` — the fake `blog.test` URL

This example sets `ZIGBASE_PUBLIC_URL=http://blog.test/` in the run command. `blog.test` is a **deliberately fake domain** that does not resolve. It makes the emailed link a proper clickable URL in the server log and in any email client — but you cannot actually navigate to it.

**To click the link in local dev**, override the env var to your own server host:

```sh
ZIGBASE_PUBLIC_URL=http://127.0.0.1:8090 ./zig-out/bin/blog serve \
  --insecure-cookies --data-dir ./zb_data --serve-static frontend/dist
```

The link then resolves on `localhost` and clicking it in the server log opens the browser and completes sign-in.

If you omit `ZIGBASE_PUBLIC_URL` entirely, the server falls back to emailing/logging the raw token; the built-in consume endpoint still works if you manually construct the URL.

### `auto_create = true`

New visitors who have never signed up get an account created automatically when they first click a magic link. Existing accounts are found by email.

### Email index

```zig
.indexes = .{
    .{ .name = "users_email_nocase", .fields = .{"email"}, .unique = true, .collation = .nocase },
},
```

The `NOCASE` collation ensures `Bob@x.com` and `bob@x.com` are treated as the same address, preventing duplicate accounts from case variants.
```

3. **Update the `## Building and running this example` section** run command to show `ZIGBASE_PUBLIC_URL`:

Current:
```sh
./zig-out/bin/blog serve --insecure-cookies --data-dir ./zb_data
```

Change to:
```sh
# Set ZIGBASE_PUBLIC_URL so the emailed magic-link is a full URL.
# blog.test is intentionally fake — override to http://127.0.0.1:8090 to click the link locally.
ZIGBASE_PUBLIC_URL=http://blog.test/ ./zig-out/bin/blog serve \
  --insecure-cookies --data-dir ./zb_data
```

Also update the `## Frontend (Astro + React islands)` run command to include it:

```sh
ZIGBASE_PUBLIC_URL=http://blog.test/ ./zig-out/bin/blog serve --insecure-cookies \
  --data-dir ./zb_data --serve-static frontend/dist
# open http://127.0.0.1:8090/
# To click the magic-link in local dev: ZIGBASE_PUBLIC_URL=http://127.0.0.1:8090 instead
```

4. **Update the frontend description paragraph** (currently "a login + 'write a post' island") to say:

```markdown
`frontend/` is an Astro site with React islands: a public post list with live
updates, post detail, a magic-link login form ("Send magic link" → "Check your
email"), and a post-write form. The nav displays logged-in state via a small
`AuthStatus` island after a magic-link consume redirect.
```

- [ ] **Step 1: Edit `examples/blog/README.md`** — apply all four changes above.

- [ ] **Step 2: Verify Zig build + frontend build still clean** (belt-and-suspenders after README edit):

```sh
cd examples/blog && mise exec zig@0.16.0 -- zig build 2>&1
cd examples/blog/frontend && npm run build 2>&1
```

- [ ] **Commit:** `docs(examples/blog): document magic-link auth, public_url, and email index`

---

### Task 6: Changelog fragment

**Files:**
- Create: `changelog.d/examples-v05-blog.md`

**Content:**

```markdown
### Features

- Blog example: adds built-in `magic_link` auth on `users` (passwordless login via
  emailed link, `auto_create = true`, 1 h TTL, server-redirects to `/`).
- Blog example: `NOCASE` unique comptime index on `users.email` via `.indexes = .{...}`
  — prevents case-variant duplicate accounts.

### Internal

- Blog example frontend: new magic-link login form in `Editor.tsx` (email → initiate
  → "Check your email" state), cookie-session detection via `getMe()`, and an
  `AuthStatus` nav island for logged-in display after consume redirect.
- Blog example README: document `ZIGBASE_PUBLIC_URL`, the fake `blog.test` URL, and
  the email index.
```

- [ ] **Step 1: Create `changelog.d/examples-v05-blog.md`** with the content above.

- [ ] **Step 2: Dry-run the fragment assembler to verify it parses correctly**:

```sh
bash scripts/assemble-changelog.sh --dry-run 2>&1
```

Expected: output shows a Features block (two bullets) and an Internal block (two bullets) under an `[Unreleased]`-style header. No errors.

- [ ] **Commit:** `chore: add changelog fragment for blog example v0.5+ update`

---

### Task 7: Final verification

- [ ] **Step 1: Full unit test suite**

```sh
mise exec zig@0.16.0 -- zig build test --summary all 2>&1
```

Expected: `Build Summary: N/N tests passed`. N must be ≥ the count before this PR (no regressions from the blog binary changes).

- [ ] **Step 2: Blog binary builds cleanly**

```sh
cd examples/blog && mise exec zig@0.16.0 -- zig build 2>&1
```

Expected: no errors.

- [ ] **Step 3: Frontend builds cleanly**

```sh
cd examples/blog/frontend && npm install && npm run build 2>&1
```

Expected: Astro build output in `frontend/dist/`, no TypeScript or build errors.

- [ ] **Step 4: Confirm other example builds are not broken** (CI will catch this; belt-and-suspenders):

```sh
cd examples/golfsim && mise exec zig@0.16.0 -- zig build 2>&1
cd examples/plugins/frontend && npm run build 2>&1
cd examples/plugins && mise exec zig@0.16.0 -- zig build 2>&1
```

Expected: all succeed (no changes to these examples in this PR).

- [ ] **Step 5: Open PR**

```sh
gh pr create \
  --title "feat(examples/blog): magic-link auth + NOCASE email index (v0.5+ Phase 2)" \
  --body "$(cat <<'EOF'
## Summary

- Wires the built-in `magic_link` auth method and a comptime `NOCASE` unique email
  index into the blog example's `users` collection (exercises Phase 1 E1 + E2 enablers).
- `ZIGBASE_PUBLIC_URL=http://blog.test/` — the fake URL makes the emailed token a
  real clickable link. README clearly explains it's fake and how to override for local
  dev.
- Frontend: replaces the password-only form in `Editor.tsx` with a magic-link primary
  flow + password-fallback `<details>` section; adds `getMe()` for cookie-session
  detection on the post-consume redirect; adds an `AuthStatus` nav island.

## Test plan

- [ ] `mise exec zig@0.16.0 -- zig build test --summary all` — all tests pass
- [ ] `cd examples/blog && mise exec zig@0.16.0 -- zig build` — blog binary builds
- [ ] `cd examples/blog/frontend && npm run build` — Astro frontend builds
- [ ] `bash scripts/assemble-changelog.sh --dry-run` — fragment parses cleanly
- [ ] Manual smoke: run with `ZIGBASE_PUBLIC_URL=http://127.0.0.1:8090`, click the logged link, verify cookie session detected in nav

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

## Open questions / assumptions to confirm before execution

1. **`/api/collections/users/auth/me` endpoint** — this plan assumes the framework exposes a `GET .../auth/me` endpoint that returns `{record: {...}}` when a valid session cookie is present and 401 otherwise. Verify this exists in `src/api/auth.zig` before Task 2. If the endpoint has a different path or response shape, adjust `getMe()` accordingly.

2. **Cookie-based `createPost` and other writes after magic-link login** — the existing `createPost` in `api.ts` calls `req()` which sends `Authorization: Bearer <token>` when a localStorage token exists. After magic-link login there is no localStorage token — authentication is cookie-only. Verify that the framework's access-rule engine honors the session cookie for record-write endpoints, not just the Bearer token. If the framework only accepts Bearer tokens for write operations, `createPost` will fail for magic-link users and the fix is to include `credentials: 'include'` in `req()` universally (or add a cookie-aware wrapper).

3. **Logout / cookie clearing** — the `logout()` function in `api.ts` only clears localStorage. For magic-link users with a cookie session, clicking "log out" in the nav / Editor will clear localStorage (no-op since they never had a token there) but the cookie will persist until expiry. Confirm whether the framework has a `POST .../auth/logout` or similar endpoint that clears the server-side session; if so, add a `logoutCookie()` function to `api.ts` that calls it and update both `Editor.tsx` and `AuthStatus.tsx` to call it.

4. **`auto_create = true` + existing password users** — if an existing user who signed up with a password uses magic-link initiate with the same email, `auto_create` will find the existing record (not create a new one). Confirm the framework's `auto_create` logic: does it `findByIdentity` first and only create if not found? This is the expected behavior but worth verifying in `src/auth/magic_link.zig`.
