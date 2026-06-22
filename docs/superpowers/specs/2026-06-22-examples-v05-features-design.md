# Update the three examples to exercise v0.5+ features

**Date:** 2026-06-22
**Status:** Proposed (awaiting review)

## Goal

The three example apps (`blog`, `golfsim`, `plugins`) currently use **none** of the
features introduced in or since v0.5.0. This spec brings each example up to date,
respecting the deliberate complexity ladder, and fixes two blocking defects found
while investigating.

Features in scope (v0.5.0 + `[Unreleased]`):

- Per-collection auth methods: `magic_link`, `otp`, `webauthn` (comptime `.auth.methods`)
- App-level `.auth_methods` (custom `AuthMethod` plugin type)
- `require_verified` per-collection auth gate
- OAuth2 first-class (`.auth.oauth2` providers)
- `onAuth` hook + `AuthEvent.method`
- `zigbase.auth` consumer surface (`mintLinkToken` opaque payload, `issueSession`)
- Comptime index `collation` (`.nocase`) + partial `where` predicate
- `CommandMailer` (env-selected) — **docs only**, see Non-Goals
- `ZIGBASE_FAKE_NOW` dev clock — **out of scope** (Debug-gated test seam, no consumer API)

## Two defects this work must fix first

### D1 — `.indexes` is documented but silently ignored (blocking)

`docs/framework.md` §Indexes (and the v0.5 changelog) document a `.indexes` key on
comptime collection literals with `.collation`/`.where`. PR #61 wired the
`schema.Index` type and the DDL emit (`src/ddl.zig`) but **never touched
`src/provision.zig`**. `buildCollection` (`provision.zig:91–140`) lowers only
`type/fields/rules/auth`; an `.indexes` key in a collection literal is silently
dropped (no `@compileError`, no index created). No example can demonstrate comptime
index collation until this is wired up.

**Fix:** add comptime lowering of `.indexes` in `buildCollection`.

### D2 — "provisioned columns are id-named" is false (doc bug)

CLAUDE.md and the `plugins` example's migration comments state that provisioned
collection columns are named by an 8-char stable field id, so a raw migration can't
`CREATE INDEX ON posts(status)`. **This is not how the code behaves.** Evidence:

- `stableFieldId` is consumed only at `provision.zig:210` to set `field.id`; that id
  is used only to match columns across additive rebuilds (`ddl.rebuildPlan` matches
  `old`/`new` fields by `.id`). It is never used as a SQL column name.
- `ddl.createTableSql` / `columnDef` / `createIndexSql` / the query joiner all render
  columns from the human `field.name`.
- `collections.zig:279` proves it: a collection created with fields `title`/`price`
  yields physical columns literally named `title`/`price` (`pragma_table_info`).

**Consequence for this work:** comptime `.indexes` entries reference fields by their
human name, with **no name→id mapping** required (for both system fields like `email`
and user fields like `slug`).

**Fix:** correct the false claim in CLAUDE.md, `docs/framework.md` (+ site mirror),
and the `plugins` example migration comments. The migration example stays valid (it
indexes a migration-*owned* side table, `plugin_audit_log`), but its *rationale* is
rewritten: migrations are for tables the migration owns / non-additive DDL — not
because managed columns are unaddressable.

## Framework enablers (finalized after deep investigation)

The examples cannot demonstrate the target features with the framework as-is. Three
framework enablers are prerequisites (each also a legitimate fix of a documented or
half-built capability):

- **E1 — comptime `.indexes` lowering** (was D1). See next section.
- **E2 — `public_url` → clickable magic-link email.** The built-in magic_link emails a
  *raw token* (`magic_link.zig:61-65`); verification/reset emails do the same — there is
  no base-URL mechanism anywhere (`config.zig` has no `*_url` field). Add `public_url`
  to `config.Config` + `ZIGBASE_PUBLIC_URL` env. In `magic_link.initiate`, when
  `ac.app.cfg.public_url` is non-empty, build the email body as a clickable link to the
  existing GET consume endpoint:
  `<public_url>/api/collections/<col>/auth/magic_link/consume?token=<tok>&redirect=<redirect_default>`;
  fall back to the raw token when unset (backward compatible). No schema change. This is
  what lets a **stock pre-compiled binary** (blog) offer real magic-link login by config
  alone — no custom routes.
- **E3 — comptime `.auth.oauth2` lowering + provisioning-time secret injection.**
  `optionsToJson`/`optionsFromJson` already round-trip oauth2, so lowering is a small
  `buildOAuth2Options` (parallel to `buildMethodsOptions`) + a `buildCollection` branch.
  BUT: (a) `clientSecret` encryption lives only in the API path
  (`api/collections.zig:prepareOAuthConfig` → `oauth/secrets.encryptSecret`), not in the
  provisioning `collections.create` path; (b) a comptime literal cannot hold a runtime
  secret. So provisioning must source the provider's `clientId`/`clientSecret` from env
  at create time (e.g. `ZIGBASE_OAUTH_<NAME>_CLIENT_ID` / `_SECRET`) and encrypt the
  secret before persisting. **This is the heaviest item, cannot be exercised in CI, and
  is sequenced last so it can be cut without affecting anything else.**

**Provisioning caveat (pre-existing, documented not fixed):** `ensureCollection`
(`provision.zig:454-532`) applies comptime `options.auth` and `.indexes` only on **first
creation**, and early-returns when no field was added. Examples run against a fresh DB,
so create() applies the full spec — fine here. Changing auth/index config on an *existing*
collection won't reconcile; noted as a separate follow-up, out of scope.

## Framework change E1: wire `.indexes` into `buildCollection`

In `src/provision.zig`, add an optional `.indexes` branch to `buildCollection` and a
comptime `buildIndexes` helper that lowers a tuple of index literals to
`[]const schema.Index`:

```zig
// inside buildCollection, after the .auth branch:
if (@hasField(S, "indexes")) col.indexes = buildIndexes(name, spec.indexes);
```

`buildIndexes` semantics (mirroring the documented shape and `schema.Index` defaults):

- `.name` (required) and each `.fields` entry validated via `schema.isValidIdentifier`
  → `@compileError` on a bad identifier (consistent with field/collection validation).
- `.unique` default `false`, `.collation` default `.binary`, `.where` default `null`.
- `.fields` is a tuple of string literals coerced to `[]const []const u8`
  (reuse the existing `strTupleToSlice` helper).

Provisioning already carries indexes through: `ensureCollection` sets
`newdef.indexes = spec.indexes` (`provision.zig:524`) and `collections.create`
emits them (`collections.zig:55`). Branch-quota note: `buildCollections` already
raises the eval-branch quota to 1,000,000, so additional index lowering is covered.

**Tests:** unit tests asserting (a) a collection literal with `.indexes` lowers to the
expected `schema.Index` slice (name/fields/unique/collation/where), (b) the emitted
DDL via `createIndexSql` contains `COLLATE NOCASE` / `WHERE …`, (c) a bad index field
identifier is a compile error (negative test documented, not compiled). Add the new
test references to `src/root.zig`'s test block only if a new file is introduced (none
planned — tests live in `provision.zig`).

## Per-example changes

### blog — strictly stock (built-in features + config only; NO new custom routes)

Decided in review: blog must work on a **stock pre-compiled zigbase** — use ONLY the
built-in magic_link, add NO custom routes. This is why E2 (public_url) exists: the
built-in must be able to email a real link by config alone.

- **Built-in `magic_link`** via `users.auth.methods.magic_link` (`.ttl_s`,
  `.auto_create = true`, `.redirect_default = "/"`). Default LogMailer prints the email.
- **`public_url = "http://blog.test/"`** (a deliberately FAKE URL, set via
  `ZIGBASE_PUBLIC_URL` and/or documented config) so the emailed link is a real,
  clickable consume URL. README must state plainly that `blog.test` is fake — to
  actually click it, a user overrides `ZIGBASE_PUBLIC_URL` to their own host in their
  own copy.
- **`NOCASE` unique index on `users.email`** via the new comptime `.indexes`
  (prevents `Bob@x.com` vs `bob@x.com` duplicate signups).
- **Frontend (Astro/React):** a login view (email → built-in `initiate` → "Check your
  email" state). The emailed link points at the server's GET consume endpoint, which
  sets the cookie and 302-redirects back into the app — so the frontend needs a login
  form and logged-in-state rendering, but NOT a token-handling completion page (the
  server consume endpoint handles it). README explains that in local dev the link is in
  the server log and uses the fake `blog.test` host.
- README + module doc-comment: document the flow, the fake URL, and the index. blog's
  existing custom routes (`ping`, `posts/:slug`) are untouched; no new ones added.

### golfsim — only features that make it a better golf-sim rental app

Coherent auth design (the three selected features interact, so onboarding is explicit):

- **`require_verified = true`** on `users`: a guest must have a verified email before a
  session is minted — justified for a booking/payments app.
- **`otp` passwordless login** with **`auto_create = false`**: OTP is a login
  convenience for *existing, verified* accounts (it does not bypass verification, since
  `require_verified` gates completion — `auth_methods.zig:163`). First-time onboarding
  remains password signup + email verification. (Using `otp` here also gives
  cross-example variety: blog=magic_link, golfsim=otp, plugins=webauthn.)
- **OAuth2 "Sign in with Google"** via the new comptime `users.auth.oauth2` (E3): the
  `google` provider is declared at comptime (name/redirectUrls/enabled); its
  `clientId`/`clientSecret` are sourced from env at provision time
  (`ZIGBASE_OAUTH_GOOGLE_CLIENT_ID` / `ZIGBASE_OAUTH_GOOGLE_CLIENT_SECRET`) and the
  secret is encrypted on persist. Provider-verified emails create `verified = true`
  (v0.5 security behavior), so Google users can book immediately. Documented as "works
  only with real credentials; not exercised in CI." **This depends on E3 and is the
  cuttable piece** — if E3 is dropped, golfsim ships with require_verified + otp only.
- **Comptime indexes:** `NOCASE` unique on `users.email`; a partial/conditional index
  justified by the domain (e.g. an index over `bookings(listing, starts_at)
  WHERE status != 'cancelled'` to back the overlap/availability queries the
  `prepareBooking` hook already runs).
- README + module doc-comment: document the verified-then-passwordless flow, the Google
  env vars, and the indexes. Keep `onAuth` OUT of golfsim (not selected; it lives in
  plugins).

### plugins — showcase the advanced surface (justification not required)

Decided in review: expand the schema to **two auth collections with different methods**,
demonstrating per-collection auth-method policy plus the custom plugin and `onAuth`
disambiguation. Trusted content creators (`authors`) authenticate strongly/programmatically;
casual `commenters` authenticate with a lightweight passwordless flow.

- **`authors` becomes an auth collection** (currently base: `name`/`contact_email`/`bio`).
  `.type = .auth` with `.auth.methods = .{ .webauthn = .{ rp_id/rp_name/origin },
  .custom = .{"api_token"} }` — passkeys for humans, an API-token custom method for
  programmatic posting. The existing `posts.author → authors` relation is unaffected
  (relation targets may be auth collections). Keep `contact_email`/`bio` as user fields
  (the system `email` is injected by the auth type). This is a base→auth change on a
  fresh example DB (auth system fields are injected at create) — fine for an example.
- **New `commenters` auth collection** with `.auth.methods = .{ .magic_link = .{ ttl_s,
  auto_create = true } }` — a casual reader signs in via an emailed link to comment.
- **Custom `AuthMethod` plugin** (`api_token`) via app-level `.auth_methods`, enabled on
  `authors` through `.auth.methods.custom`. Implements `create`/`method`/`deinit`, uses
  `AuthCtx` (`findByIdentity`, `rateLimit`, optionally `mintLinkToken` with the opaque
  `payload`), returns a `Resolution` (`.record` / `.fail`). Exercises the `zigbase.auth`
  consumer surface and the `.custom` `AuthEvent.method` tag.
- **`comments` gated on an authed commenter:** replace the free-text `author_name` with a
  `commenter` relation → `commenters`; `create` rule requires an authed commenter
  (`@request.auth.id != ""`); keep `approved` moderation (authors/superusers approve).
- **`onAuth` hook** (`.onAuth = handleAuth`) logging collection + method — shows the same
  binary issuing sessions for two collections via three different methods (webauthn,
  api_token, magic_link), complementing the existing `onError` handler.
- **Comptime `.indexes` with `.collation`/`.where`** on a managed collection (e.g.
  `NOCASE` on `authors.contact_email`), explicitly contrasted in comments with the
  existing raw-SQL migration index on the migration-owned `plugin_audit_log` table.
- Rewrite the migration 0002 comment (D2): correct the column-naming rationale.
- Frontend: extend the embedded plugins frontend to exercise at least the `commenters`
  magic-link comment flow (and surface logged-in state); webauthn registration UI is
  optional — confirm scope during planning (passkey ceremonies need browser WebAuthn
  APIs and can be left documented if the frontend cost is high).

## Non-Goals

- **`CommandMailer` example code.** It is selected at runtime by `DefaultMailerPlugin`
  via `ZIGBASE_SENDMAIL_COMMAND`, not as a comptime `.mailer` type, so there is no
  example *code* to add. Covered by a short README/deploy note (golfsim or plugins).
- **`ZIGBASE_FAKE_NOW`.** Debug-gated test seam with no consumer-facing API; not example
  material.
- **Making auth methods runtime-configurable on the stock binary.** All auth-method
  config is comptime. A binary-only (no-Zig) user cannot enable magic_link/otp/webauthn
  at runtime. That is a larger framework project, explicitly out of scope here; noted as
  a follow-up.
- **Admin SPA changes / new browser tests for the auth flows.** This work touches no
  admin-UI code. Examples are validated by CI building them; framework wiring by unit
  tests. (If review wants e2e coverage of an example auth flow, that is a separate task.)

## Cross-cutting requirements (per CLAUDE.md)

- **Changelog fragments** (never edit `CHANGELOG.md`): a `changelog.d/<slug>.md` with
  `### Features` for the comptime `.indexes` wiring (consumer-visible) and `### Fixed`
  for D1/D2; example/doc-only updates go under `### Internal`.
- **Docs/site sync:** any `docs/*.md` edit (framework.md D2 fix, any new index/auth
  prose) mirrored into `site/src/content/`; build `cd site && npm run build`.
- **Example READMEs** updated alongside each example's `main.zig`.
- **Build/verify:** `zig build test --summary all` (authoritative `N/N tests passed`
  line); build all three examples (`plugins` needs `npm run build` of its frontend
  first). No admin-UI change → the browser suite is not required, but `golfsim`/`blog`
  frontends must still build.

## Delivery phases (separate PRs — fragments keep the changelog conflict-free)

Scope spans the framework and three example apps; deliver as sequenced PRs rather than
one mega-change. Each PR builds, tests, ships changelog fragment(s), and syncs docs/site.

- **Phase 1 — Framework foundation (this plan's detailed tasks):**
  - E1: wire comptime `.indexes` into `buildCollection` (+ tests).
  - E2: `public_url` config + clickable magic-link email (+ tests).
  - D2 doc fix: correct the "id-named columns" claim in CLAUDE.md, `docs/framework.md`
    (+ site mirror) and (later, with the plugins PR) the plugins migration comments.
  - Changelog fragment: `### Features` (comptime `.indexes`, `public_url` magic-link
    links) + `### Fixed` (D2 doc correction).
  - Independently shippable; unblocks the example PRs.
- **Phase 2 — blog** (depends on E1, E2): built-in magic_link + `public_url` +
  `NOCASE` email index + frontend login/logged-in state + README.
- **Phase 3 — golfsim** (depends on E1; OAuth2 depends on E3): require_verified + otp +
  indexes + frontend + README. OAuth2 added only if E3 lands.
- **Phase 4 — plugins** (depends on E1): authors→auth (webauthn + custom `api_token`) +
  commenters (magic_link) + comments gating + onAuth + comptime collation index +
  migration-comment D2 fix + frontend + README.
- **Phase 1b (optional, cuttable) — E3 comptime OAuth2** + provisioning env-secret
  injection/encryption. Heaviest item, no CI coverage. If cut, Phase 3 drops OAuth2.

Phases 2–4 are mutually independent once Phase 1 lands and can proceed in parallel.
This document specs all phases; the companion implementation plan details Phase 1 fully
(it is the prerequisite); Phases 2–4 get their own plans (they require frontend
investigation of each example's `frontend/` at execution time).
