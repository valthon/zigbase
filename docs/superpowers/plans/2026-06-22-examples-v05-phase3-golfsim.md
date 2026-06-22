# Phase 3 — golfsim example v0.5+ features

**Date:** 2026-06-22
**Status:** Ready to execute
**Depends on:** Phase 1 (E1 comptime `.indexes` wiring) — already landed in this branch.
**E3 gate:** The OAuth2 section (Task 5) is GATED ON E3 (`comptime .auth.oauth2` lowering)
and can be cut without affecting Tasks 1–4.

---

## Goal

Update `examples/golfsim` to demonstrate three auth features that are natural for a
booking/payments app:

1. **`require_verified = true`** on the `users` auth collection — guests must verify
   their email before a session is minted.
2. **OTP passwordless login** (`auto_create = false`) as a convenience for existing,
   verified accounts — first-time onboarding stays password signup + email verification.
3. **Comptime indexes** — `NOCASE` unique on `users.email` + a domain-justified partial
   index over `bookings(listing, starts_at)` backing the overlap check.
4. **(GATED ON E3) OAuth2** — "Sign in with Google" declared at comptime; client
   credentials sourced from env at provision time.

Plus: README, module doc-comment, and frontend updated to match. No `onAuth` hook here
(that belongs in plugins).

---

## Architecture

- **Backend:** `examples/golfsim/src/main.zig` — single file, `pub const App = zigbase.App(.{...})`.
  All five collections (`users`, `simulators`, `listings`, `bookings`, `reviews`) are
  provisioned at comptime via `.collections`.
- **Frontend:** `examples/golfsim/frontend/` — Astro 5 + React 19 islands.
  - `src/lib/api.ts` — all API calls (currently: login, signup, listings CRUD, bookings, reviews, realtime).
  - `src/components/Auth.tsx` — current email/password sign-in/sign-up card (replaces by OTP flow).
  - `src/components/ListingsBrowser.tsx` — home page (uses `Auth`).
  - `src/components/MyBookings.tsx` — bookings page (uses `Auth`).
  - `src/pages/index.astro`, `src/pages/bookings.astro` — Astro pages.
  - `src/layouts/Layout.astro` — shared nav.
- **Build:** `build.zig` uses `.static_files = .{ .dir = "frontend/dist" }` (comptime-hardcoded).
  Frontend build: `cd frontend && npm install && npm run build`.

---

## Tech Stack

- Zig 0.16.0 (pinned via `mise exec zig@0.16.0`). All `zig` commands are prefixed with
  `mise exec zig@0.16.0 --`.
- Astro 5 + React 19, TypeScript 5.6. Frontend tests are type-check only (`astro check`).
- Test signal: `mise exec zig@0.16.0 -- zig build test --summary all` — authoritative
  line is `Build Summary: N/N tests passed`. ALSO run `cd examples/golfsim/frontend && npm run build`
  to confirm the frontend still compiles after frontend changes.

---

## Global Constraints

- Never edit `CHANGELOG.md` directly — add a fragment to `changelog.d/`.
- Every `docs/*.md` edit must be mirrored to `site/src/content/` (Astro mirror). Run
  `cd site && npm run build` to confirm no broken links/imports.
- The golfsim example must remain the **middle rung**: more realistic than blog, less
  advanced than plugins (no custom `AuthMethod`, no `onAuth`).
- `prepareBooking`, `prepareReview`, and all five custom routes are untouched.
- The partial booking index MUST reference field names that exist in the comptime schema
  (confirmed: `listing`, `starts_at`, `status`).
- New `signup` flow must send a verification email and block login until verified.
  Use the built-in `POST /api/collections/users/request-verification` (body: `{"email":"..."}`)
  and `POST /api/collections/users/confirm-verification` (body: `{"token":"..."}`).
  The verification token arrives as a raw token in the server log (LogMailer in dev).
- OTP flow: `POST /api/collections/users/auth/otp/initiate` (body: `{"identity":"<email>"}`, 204),
  then `POST /api/collections/users/auth/otp/complete` (body: `{"identity":"<email>","code":"<6digits>"}`,
  200 `{"token":"..."}` or 400 bad/expired). Code is emailed (LogMailer prints in dev).
- `auto_create = false` on OTP: attempting to initiate for an unknown email returns an error
  (correct — OTP is for existing accounts only).

---

## Onboarding UX Design (informs Tasks 3–4)

```
NEW USER:
  1. Sign up (email + password)  → POST /api/collections/users/records  → 200
  2. Login immediately fails     → POST /api/collections/users/auth-with-password → 403 "Email not verified."
     (Frontend detects 403 + shows "Check your email" state)
  3. Server mails verification token (LogMailer: token in server log)
     Frontend also calls POST /api/collections/users/request-verification after signup
     to trigger the email explicitly (belt + suspenders; the token arrives either way
     because admin-created users might not trigger it automatically)
  4. User pastes token into "Verify your account" input
     → POST /api/collections/users/confirm-verification → 200 {"verified":true}
  5. User logs in with password → 200, session minted
     OR uses OTP from now on:
     → POST initiate → email code → paste code → 200, session minted

RETURNING VERIFIED USER:
  Option A — Password: email + password → POST auth-with-password → session
  Option B — OTP: email → initiate → paste 6-digit code → session
```

Note: the `Auth.tsx` component becomes a multi-step flow. Keep it self-contained (no
new page/route) — use React `useState` to manage the step.

---

## Task 1 — Backend: `require_verified` + OTP on `users` collection

**What:** Add `.auth.require_verified = true` and `.auth.methods.otp = .{ .auto_create = false }`
to the `users` collection declaration in `src/main.zig`. Password method is still enabled
(it is the default, always present unless explicitly disabled; the framework does not need
an explicit `.password = .{}` unless rate-limiting is customized).

**File:** `examples/golfsim/src/main.zig`

Locate the `.users` collection literal (lines ~505–514 currently). Change it to:

```zig
.users = .{
    .type = .auth,
    .fields = .{
        .{ .name = "name", .type = .text, .max = 100 },
    },
    // require_verified: guests must verify their email before a session is minted.
    // Justified for a booking/payments app — unverified accounts cannot hold slots.
    // OTP offers a one-step passwordless login convenience for existing, verified accounts.
    // First-time onboarding: password signup + email verification (see Auth.tsx).
    // NOTE: .password = .{} must be explicit — specifying .methods at all opts OUT of the
    // implicit password default. Omitting it would disable /auth-with-password entirely.
    .auth = .{
        .require_verified = true,
        .methods = .{
            .password = .{},                        // keep password login (required for post-verify signin)
            .otp = .{ .auto_create = false },        // OTP for existing, verified accounts only
        },
    },
    // Public profiles + open signup.
    .rules = .{ .list = "@public", .view = "@public", .create = "@public", .update = "@request.auth.id = id", .delete = "@request.auth.id = id" },
},
```

**Tests (unit — in `src/main.zig` or `provision.zig`):**

There are no dedicated unit tests in `main.zig` (it is a pure wiring file). The
Phase 1 provision tests already cover `require_verified` and OTP lowering. This task's
correctness is validated at integration level by the frontend onboarding flow + the
build passing (`zig build` for the example).

**Verify:** Run `cd examples/golfsim && mise exec zig@0.16.0 -- zig build` — must succeed.

---

## Task 2 — Backend: Comptime indexes

**What:** Add `.indexes` to `users` (NOCASE unique on `email`) and `bookings` (partial
index backing the overlap/availability queries).

**File:** `examples/golfsim/src/main.zig`

**Index 1 — `idx_users_email_nocase`** on `users`:
- Unique, NOCASE collation, covers `email`.
- Justification: prevents `Bob@x.com` vs `bob@x.com` duplicate accounts (the same
  need as blog, doubly important with `require_verified` since a collision would block
  both from verifying).

**Index 2 — `idx_bookings_listing_time_active`** on `bookings`:
- Partial, covers `(listing, starts_at)`, `WHERE status != 'cancelled'`.
- Justification: the `prepareBooking` hook already runs
  `"listing = \"...\" && status != \"cancelled\" && starts_at < \"...\" && ends_at > \""` as its overlap check.
  The availability route (`listingAvailability`) uses `"listing = \"...\" && status != \"cancelled\""`.
  Both queries filter on `listing` + `status` first, then range on time — a composite
  index over `(listing, starts_at)` with the `status != 'cancelled'` predicate
  eliminates the cancelled-booking rows from the index entirely, making availability
  checks O(active bookings per listing) rather than O(all bookings per listing).
  This is a genuine, domain-justified partial index — not a toy example.
- Field names confirmed from the comptime schema: `listing`, `starts_at`, `status`.

Add `.indexes` to both collections in the `pub const App = zigbase.App(.{...})` literal:

```zig
.users = .{
    // ... (auth, fields, rules from Task 1) ...
    .indexes = .{
        .{ .name = "idx_users_email_nocase", .fields = .{"email"}, .unique = true, .collation = .nocase },
    },
},
```

```zig
.bookings = .{
    // ... (fields, rules unchanged) ...
    .indexes = .{
        .{
            .name = "idx_bookings_listing_time_active",
            .fields = .{ "listing", "starts_at" },
            // Only index active (non-cancelled) bookings: shrinks the index and
            // makes overlap checks + availability queries O(active bookings).
            .where = "status != 'cancelled'",
        },
    },
},
```

**Verify:** `cd examples/golfsim && mise exec zig@0.16.0 -- zig build` — must succeed.
No new unit tests needed here (the Phase 1 `buildIndexes` + DDL tests already cover this
syntax; this is a consumer that exercises the wired feature).

---

## Task 3 — Frontend: `api.ts` — add OTP + verification helpers

**What:** Extend `examples/golfsim/frontend/src/lib/api.ts` with:

1. **`requestVerification(email: string): Promise<void>`** — wraps
   `POST /api/collections/users/request-verification` body `{"email":"<email>"}` → 204.
2. **`confirmVerification(token: string): Promise<void>`** — wraps
   `POST /api/collections/users/confirm-verification` body `{"token":"<token>"}` → 200 `{"verified":true}`.
3. **`otpInitiate(email: string): Promise<void>`** — wraps
   `POST /api/collections/users/auth/otp/initiate` body `{"identity":"<email>"}` → 204.
4. **`otpComplete(email: string, code: string): Promise<void>`** — wraps
   `POST /api/collections/users/auth/otp/complete` body `{"identity":"<email>","code":"<code>"}` → 200 `{"token":"..."}`;
   saves token to localStorage (same as `login`).

Update `signup` to call `requestVerification` after creating the account (so the
verification email is triggered immediately after signup, even if the server already
sent one):

```ts
export async function signup(email: string, password: string): Promise<void> {
  await req('/api/collections/users/records', {
    method: 'POST',
    body: JSON.stringify({ email, password, passwordConfirm: password }),
  });
  // Immediately trigger the verification email. The server sends one automatically
  // on creation; this is belt-and-suspenders to ensure the user gets it.
  await requestVerification(email);
  // Do NOT auto-login: require_verified will 403 until the user confirms.
}
```

Update `login` to handle the 403 `"Email not verified."` response distinctly:

```ts
export async function login(email: string, password: string): Promise<void> {
  const r = await fetch('/api/collections/users/auth-with-password', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ identity: email, password }),
  });
  if (!r.ok) {
    const err = await r.json().catch(() => null);
    const msg = err?.message ?? `HTTP ${r.status}`;
    // Surface the unverified case distinctly so the UI can show the verify step.
    if (r.status === 403 && msg.includes('not verified')) throw new EmailNotVerifiedError(email);
    throw new Error(msg);
  }
  const out = await r.json();
  if (typeof localStorage !== 'undefined') localStorage.setItem(TOKEN_KEY, out.token);
}

export class EmailNotVerifiedError extends Error {
  constructor(public readonly email: string) {
    super('Email not verified. Check your inbox for a verification token.');
  }
}
```

Add complete implementations for all four new functions. The `otpComplete` function
stores `out.token` in localStorage and calls `localStorage.setItem(TOKEN_KEY, out.token)`.

**Verify:** `cd examples/golfsim/frontend && npm run build` — TypeScript must compile
without errors.

---

## Task 4 — Frontend: `Auth.tsx` — multi-step flow

**What:** Replace the current `Auth.tsx` (a simple email/password form) with a
multi-step React component that covers:

- **Step: `"signin"`** (default) — email field + two buttons: "Log in with password" and
  "Send one-time code". Also a "Sign up instead" toggle.
- **Step: `"signup"`** — email + password fields + "Create account" button. On success →
  step `"verify"`.
- **Step: `"verify"`** — "Check your email for a verification token." + a token input +
  "Verify" button. On success → step `"signin"` with a success message ("Account verified.
  Sign in to continue."). Also a "Resend" link (calls `requestVerification` again).
- **Step: `"otp_sent"`** — "We sent a 6-digit code to `<email>`." + code input +
  "Confirm code" button. On success → calls `onAuthed()`.
- **Error display:** show `error` string below the active step's button(s).
- **Unverified-email detection:** when `login` throws `EmailNotVerifiedError`, switch to
  step `"verify"` (pre-filling the email) with a message "Your email is not yet verified."

Keep the component self-contained in `Auth.tsx`; do not add new pages or routes.
The `onAuthed: () => void` prop interface is unchanged (both `ListingsBrowser` and
`MyBookings` pass `onAuthed={() => setAuthed(true)}`).

**Sketch (not verbatim — implementer fills in JSX):**

```tsx
type Step = 'signin' | 'signup' | 'verify' | 'otp_sent';

export default function Auth({ onAuthed }: { onAuthed: () => void }) {
  const [step, setStep] = useState<Step>('signin');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [verifyToken, setVerifyToken] = useState('');
  const [otpCode, setOtpCode] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [info, setInfo] = useState<string | null>(null);  // success / info messages

  // ... handlers: handleLoginPassword, handleSignup, handleVerify,
  //               handleSendOtp, handleOtpComplete ...
}
```

The `otp_sent` step should also show the user's email and a note that the code is
valid for 5 minutes (the default OTP TTL is 300 s).

For the sign-in step, add a subtle "New here? Sign up" link/button that sets `step → 'signup'`.
For the sign-up step, add a "Already have an account? Sign in" link.

**Verify:** `cd examples/golfsim/frontend && npm run build` — must succeed (TypeScript
type-check via `astro check` is also run by `npm run build` if the astro.config includes
the check integration; if not, a `npx astro check` confirms types).

---

## Task 5 — GATED ON E3: OAuth2 "Sign in with Google"

> **This entire task is BLOCKED until Phase 1b (E3) lands.** E3 adds comptime `.auth.oauth2`
> lowering and provisioning-time env-secret injection. Do NOT implement this task until
> E3 is merged and available in the working branch.

**What (when E3 is available):**

Add a Google OAuth2 provider to `users` in `src/main.zig`:

```zig
.users = .{
    .type = .auth,
    .fields = .{ .{ .name = "name", .type = .text, .max = 100 } },
    .auth = .{
        .require_verified = true,
        .methods = .{ .password = .{}, .otp = .{ .auto_create = false } },
        // OAuth2: clientId/secret sourced from env at provision time.
        // Google-verified emails → verified=true; can book immediately.
        .oauth2 = .{
            .enabled = true,
            .providers = .{
                .{
                    .name = "google",
                    .clientId = "",   // sourced from ZIGBASE_OAUTH_GOOGLE_CLIENT_ID at provision
                    .clientSecret = "", // sourced from ZIGBASE_OAUTH_GOOGLE_CLIENT_SECRET (encrypted on persist)
                    .redirectUrls = .{ "http://localhost:8090/api/oauth2/google/callback" },
                    .enabled = true,
                },
            },
        },
    },
    .rules = .{ .list = "@public", .view = "@public", .create = "@public", .update = "@request.auth.id = id", .delete = "@request.auth.id = id" },
    .indexes = .{
        .{ .name = "idx_users_email_nocase", .fields = .{"email"}, .unique = true, .collation = .nocase },
    },
},
```

**Frontend (when E3 is available):**

Add a "Sign in with Google" button to the `signin` step in `Auth.tsx`:

```tsx
<button onClick={handleGoogleSignIn} disabled={busy}>Sign in with Google</button>
```

The `handleGoogleSignIn` handler redirects to the built-in OAuth2 initiate endpoint:
`window.location.href = '/api/collections/users/auth/oauth2/google/authorize'`
(the server handles the PKCE/redirect dance; on return, the callback sets the cookie and
redirects to `/` — the SPA then picks up the session from localStorage or a `/me` check).

Alternatively, implement the PKCE flow entirely in JS using the built-in
`GET /api/collections/users/auth/oauth2/google/authorize` + callback endpoints.
Consult E3's companion docs for the exact redirect/callback contract.

**README note (when E3 is available):**

> Google OAuth2 requires real `ZIGBASE_OAUTH_GOOGLE_CLIENT_ID` and
> `ZIGBASE_OAUTH_GOOGLE_CLIENT_SECRET` env vars. Provider-verified Google accounts are
> created `verified=true` and can book immediately. This flow is NOT exercised in CI
> (it requires live Google credentials). To test locally: set the env vars to a Google
> OAuth2 client you have created in GCP, set the redirect URL to
> `http://localhost:8090/api/oauth2/google/callback`, and restart the binary.

---

## Task 6 — README + module doc-comment

**Files:**
- `examples/golfsim/README.md`
- `examples/golfsim/src/main.zig` (the `//!` top-of-file doc-comment)

**README changes (add a new "Auth & onboarding" section, insert after the existing
Collections table and before Building and running):**

```md
## Auth & onboarding

`golfsim` uses `require_verified = true` on the `users` collection: a guest must
have a verified email before a session is minted. This is appropriate for a
booking/payments app — unverified accounts cannot hold time slots.

### Onboarding flow (new users)

1. **Sign up** — email + password via the login card on the home page.
   (API: `POST /api/collections/users/records`)
2. **Verify email** — a verification token is emailed (dev: printed to the server log
   by the default LogMailer). Paste it into the "Verify your account" input.
   (API: `POST /api/collections/users/confirm-verification`)
3. **Sign in** — password login now succeeds, or use OTP for future logins.

### OTP passwordless login (returning verified users)

Once verified, users may sign in with a one-time code instead of their password:

1. Enter email → "Send one-time code".
   (API: `POST /api/collections/users/auth/otp/initiate`)
2. Enter the 6-digit code from the email (dev: server log). Valid for 5 minutes.
   (API: `POST /api/collections/users/auth/otp/complete`)

`auto_create = false` means OTP will NOT create new accounts — it is a convenience
for existing, verified users only. First-time onboarding always uses password signup.

### Comptime indexes

Two indexes are provisioned at startup via comptime `.indexes`:

- **`idx_users_email_nocase`** — unique, `COLLATE NOCASE` on `users.email`. Prevents
  `Bob@x.com` and `bob@x.com` from being treated as distinct accounts.
- **`idx_bookings_listing_time_active`** — composite `(listing, starts_at)` with
  `WHERE status != 'cancelled'`. Backs the double-booking overlap check
  (`prepareBooking`) and the availability route — only active bookings are indexed,
  so availability queries are O(active bookings per listing).

### OAuth2 (GATED ON E3 — not yet available)

A "Sign in with Google" option is planned but depends on the E3 framework enabler
(comptime `.auth.oauth2` lowering). When available, it will be enabled with real
`ZIGBASE_OAUTH_GOOGLE_CLIENT_ID` / `ZIGBASE_OAUTH_GOOGLE_CLIENT_SECRET` env vars.
Google-verified accounts are created `verified=true` and can book immediately.
```

**Module doc-comment (`src/main.zig` top):**

Update the numbered list in the `//!` block. After item 7 (onFileUpload logger) and
before the collection overview paragraph, add items describing the auth features:

```
//!   9. `require_verified = true` on `users`: email verification is required before
//!      a session is minted — guests cannot hold booking slots with unverified accounts.
//!  10. OTP passwordless login (`auto_create = false`): a one-step login convenience
//!      for existing, verified accounts. First-time onboarding uses password signup +
//!      the `request-verification` / `confirm-verification` flow.
//!  11. Two comptime indexes: `NOCASE` unique on `users.email` (prevents case-variant
//!      duplicate accounts) and a partial composite index on `bookings(listing, starts_at)
//!      WHERE status != 'cancelled'` backing overlap/availability queries.
```

---

## Task 7 — Changelog fragment

**File:** `changelog.d/examples-golfsim-v05.md`

```md
### Features

- `golfsim` example: `require_verified = true` on the `users` auth collection — guests must verify their email before a session is minted (booking/payments justification).
- `golfsim` example: OTP passwordless login (`auto_create = false`) for existing verified accounts; first-time onboarding remains password signup + email verification.
- `golfsim` example: comptime indexes — `NOCASE` unique on `users.email` (prevents case-variant duplicate accounts) and a partial composite index on `bookings(listing, starts_at) WHERE status != 'cancelled'` (backs the double-booking overlap check and availability route).
- `golfsim` frontend: multi-step `Auth` component covering password sign-in, OTP initiate/complete, signup, and email-verification flows.
```

(If the E3/OAuth2 task is implemented, add a line: `- golfsim example: OAuth2 "Sign in with Google" via comptime \`.auth.oauth2\`; client credentials sourced from \`ZIGBASE_OAUTH_GOOGLE_CLIENT_ID\` / \`ZIGBASE_OAUTH_GOOGLE_CLIENT_SECRET\` at provision time.`)

---

## Task 8 — Docs/site sync

After any prose change to `docs/framework.md` (none required by this phase specifically —
the auth methods and indexes sections were updated in Phase 1 and the index column-naming
correction was also Phase 1), verify the site mirror is current:

```sh
cd site && npm run build
```

If Phase 3 adds no new prose to `docs/framework.md`, just confirm the site build is clean.
If the golfsim README or any new auth pattern merits a cross-reference in framework.md, add
it and mirror to `site/src/content/docs/framework.md`.

---

## Execution order

1. Task 1 (backend: `require_verified` + OTP on `users`)
2. Task 2 (backend: comptime indexes)
3. `cd examples/golfsim && mise exec zig@0.16.0 -- zig build` — confirm backend builds
4. Task 3 (frontend `api.ts` additions + signup/login updates)
5. Task 4 (frontend `Auth.tsx` multi-step flow)
6. `cd examples/golfsim/frontend && npm install && npm run build` — confirm frontend builds
7. Task 6 (README + module doc-comment)
8. Task 7 (changelog fragment)
9. Task 8 (site build check)
10. Task 5 (GATED — defer until E3 lands)

---

## Verification checklist

- [ ] `mise exec zig@0.16.0 -- zig build test --summary all` — `Build Summary: N/N tests passed`
- [ ] `cd examples/golfsim && mise exec zig@0.16.0 -- zig build` — example builds
- [ ] `cd examples/golfsim/frontend && npm install && npm run build` — Astro + TS build succeeds
- [ ] `cd site && npm run build` — site build clean
- [ ] `changelog.d/examples-golfsim-v05.md` exists and passes the fragment validator
  (`scripts/assemble-changelog.sh --dry-run` without errors)
- [ ] `examples/golfsim/README.md` documents `require_verified`, OTP flow, and the two indexes
- [ ] `src/main.zig` doc-comment updated with items 9–11

---

## Open questions / assumptions

1. **Signup triggers verification email automatically?** The framework creates a user via
   `POST /api/collections/users/records` without automatically sending a verification email.
   The plan calls `requestVerification` explicitly from `signup()` in `api.ts` as belt-and-suspenders.
   **Confirm:** does `Data.create` on an auth collection trigger a verification email automatically,
   or is an explicit `request-verification` call always needed? If automatic, the explicit call
   in `signup()` is harmless (re-sends) but should be documented.

2. **OTP initiate for unknown email returns what?** With `auto_create = false`, an OTP
   initiate for an address that doesn't exist in `users` should return a 4xx error (likely 400
   or 404). **Confirm the status code** so `api.ts` can surface a useful "No account found"
   message vs "Something went wrong". If it's a generic 400, the frontend should say
   "No account with that email — sign up first."

3. **Password method must be explicit when `.methods` is specified — RESOLVED.**
   `buildMethodsOptions` in `provision.zig` (line 160) only sets `out.password` when
   `@hasField(M, "password")`. Setting `.methods = .{ .otp = .{} }` without `.password = .{}`
   will NULL out the password method, disabling the `/auth-with-password` endpoint.
   **Task 1 already includes `.password = .{}` alongside `.otp`.** See the code block in Task 1.

4. **`confirm-verification` token arrives in server log?** In dev with the default LogMailer,
   the verification email body is printed to stdout. Confirm the log format includes the token
   (check `auth.zig:356`: `"Verify your email ({s}). Your verification token:\n\n{s}\n"`).
   The frontend `verify` step should instruct the user to copy the token from the server log.

5. **OTP `complete` endpoint saves token?** The plan has `otpComplete` saving `out.token`.
   Confirm the OTP complete response shape — it should be identical to `auth-with-password`
   (`{"token":"<jwt>","record":{...}}`).
