# ZigBase site "0.9.0 refresh" — design spec

Baseline: repo `main` @ `e71eac5` (release 0.9.0). All paths relative to repo root.
Everything factual below was verified against `site/src/content/docs/changelog.md § [0.9.0]`,
`framework.md`, `api.md`, and `configuration.md` at that commit.

## 1. Goal

Server 0.9.0 shipped ten headline features — PostgreSQL backend (+ `migrate-db`,
LISTEN/NOTIFY multi-instance realtime, pgvector), multi-tenancy, relationship abilities,
full-text + vector search, product analytics, an email subsystem, background job queues,
outbound webhooks, a realtime broadcast API, and CAPTCHA — and the marketing surface shows
none of them. The hero still says "one SQLite-backed executable"; none of the new features
has a discoverable docs entry point (the reference material exists inside the 2,948-line
framework.md and api.md but has no sidebar presence).

This refresh: (a) repositions the landing page around the dual-backend story while keeping
the embeddable-Zig-framework angle prominent, (b) adds eight teaching-oriented guide pages
in a new sidebar group that link into framework.md/api.md for exhaustive reference,
(c) de-stales overview.md, (d) adds an honest comparison page, (e) ships an OG image so
social cards stop rendering blank.

## 2. Non-goals

- **Playground** — deferred (locked decision).
- **Blog infrastructure and a "what's new in 0.9.0" page** — recommend **against** even the
  single static page. The changelog page already carries the release narrative with exact
  caveats; the refreshed landing page carries the marketing version. A one-off news page is
  a third copy that goes stale the day 0.10.0 ships and has no home in the IA. If release
  announcements are wanted later, that is a real blog decision, not a page snuck into docs.
- **CSS system redesign** — all new components use the existing tokens
  (`site/src/styles/tokens.css`: accent `#f7a41d`, dark via `data-theme` +
  `prefers-color-scheme`) and the established section patterns (container, `__head`,
  auto-fit grids). No Tailwind, no new dependencies for the site build.
- **framework.md / api.md content changes** — locked decision: guides link *into* them
  one-way; the reference pages are not edited (so their imperfect historical mirror drift
  is not disturbed).

## 3. Landing page (`site/src/pages/index.astro` + `site/src/components/landing/`)

Section order becomes: Hero → Features → CodeSample → **DualBackend (new)** →
ReadyOutOfBox → QuickStart → AdminShowcase → ExamplesShowcase → SdkShowcase → WhyZigBase.
The new section sits right after CodeSample so the flow reads: what it is → how it feels →
how it grows → what's in the box.

### 3.1 Hero (`Hero.astro`) — proposed copy (verbatim)

- **Badge** (version stays derived from `ZIGBASE_VERSION_TAG`; never hardcode):
  `⚡ {version} · Apache-2.0 · Linux & macOS`
  (Adding the platform tag is deliberate honesty — no Windows build exists.)
- **Title** (keeps the existing two-line structure; `hero__accent` spans marked with **bold**):
  - Line 1: `Open-source backend in a **single binary**.`
  - Sub-line: `**SQLite** to start. **Postgres** when you grow. Same code.`
- **Subhead**:
  > Collections and access rules, auth from passwords to passkeys, realtime, full-text
  > search, multi-tenancy, background jobs, transactional email, and an embedded admin
  > UI — one executable, no runtime dependencies. Flip one build flag and the same app
  > runs on PostgreSQL. And it's an embeddable **Zig framework**: extend the server with
  > comptime hooks, routes, and jobs, checked at compile time.
- CTAs and the `zig fetch --save` install line are unchanged.

Honesty check: "flip one build flag" matches the documented `-Dpostgres=true` +
`ZIGBASE_DB_URL` story; the TLS-verification and migrate-db caveats live one click away in
the Postgres guide and the DualBackend section footnote — the hero doesn't claim
"production-hardened Postgres TLS" or similar.

### 3.2 Features grid (`Features.astro`) — 15 cards → 21, reorganized

Decision: the grid **grows to 21** with one merge and two fold-ins, ordered so the 0.9.0
headliners occupy the first two visual rows. Merges: "Auth + OAuth2" absorbs "Auth
lifecycle hooks" (one card, was two); the realtime broadcast API folds into the Realtime
card; CAPTCHA folds into the rate-limiting card. New cards need icons — reuse the existing
inline-SVG stroke style (`stroke-width="1.8"`, 24×24 viewBox); suggested motifs noted.

Final card list, in order (title — one-liner; ✱ = new, △ = updated copy):

1. ✱ **SQLite or PostgreSQL** — "Embedded SQLite by default. Build with `-Dpostgres` and
   point `ZIGBASE_DB_URL` at a `postgres://` URL — same app, same API. `zigbase migrate-db`
   copies an existing instance across, schema and data." (icon: two stacked DB cylinders)
2. **Collections & schema** — unchanged.
3. ✱ **Multi-tenancy** — "Account-scoped collections: every read, write, and realtime
   delivery is bound to the request's active account, fail-closed. Built-in accounts,
   memberships, invitations, and roles." (icon: building/users)
4. ✱ **Relationship abilities** — "Authorize by the caller's relationship to the row —
   `.{ .via = \"account\", .min_role = .editor }` — comptime-validated, fail-closed, and
   composed into list queries." (icon: linked nodes)
5. ✱ **Full-text & vector search** — "Mark a field `.searchable` and query `?search=` with
   ranked results and `AND`/`OR`/`NOT`/prefix operators — FTS5 on SQLite, `tsvector` on
   Postgres. Opt-in `-Dvector` adds KNN via sqlite-vec / pgvector." (icon: magnifier)
6. ✱ **Background jobs & webhooks** — "Durable or in-memory queues with priorities and
   retries; enqueue from anywhere with `ctx.enqueue()`. `ctx.webhook()` delivers signed,
   idempotent webhooks with capped backoff." (icon: stacked queue arrows)
7. ✱ **Transactional email** — "Multipart HTML+text templates, SES / Postmark / SMTP
   providers, verified per-account senders, bounce suppression — and a capture mailer for
   asserting mail in tests." (icon: envelope)
8. ✱ **Product analytics** — "`ctx.track()` appends immutable events — actor, tenant, and
   timestamp stamped server-side. Declarative rollups aggregate them on the scheduler;
   tenant-scoped read API." (icon: bar chart)
9. △ **Realtime** — "Subscribe to record changes over WebSocket, and broadcast on custom
   channels from routes and jobs. On Postgres, events fan out across app instances via
   LISTEN/NOTIFY."
10. △ **Auth + OAuth2** (absorbs "Auth lifecycle hooks") — "argon2id passwords, magic-link,
    OTP, and WebAuthn passkeys; OAuth2 with PKCE and account linking. Hook
    `beforeAuthSuccess` / `beforeRegister` transactionally with the session."
11. **File storage** — unchanged.
12. △ **Single static binary** — "One executable, no runtime dependencies — the Postgres
    driver is pure Zig (no libpq, no OpenSSL)." (drops "SQLite-backed")
13. **Embeddable Zig framework** — unchanged.
14. **Static file serving** — unchanged.
15. **Typed TypeScript SDK** — unchanged.
16. **Session management** — unchanged.
17. △ **Rate limiting & CAPTCHA** — existing copy + "…and `ctx.verifyCaptcha()` for
    reCAPTCHA, hCaptcha, and Turnstile."
18. **Field encryption** — unchanged.
19. **TTL & KV store** — unchanged.
20. **Ctx capability layer** — △ append "…including `track`, `enqueue`, `mail`, and
    `webhook`."
21. **Deterministic testing** — unchanged.

### 3.3 New section: `DualBackend.astro` (the Postgres story)

Decision: a **new dedicated section**, not folded into an existing one — the dual-backend
story is the release's positioning centerpiece and deserves its own beat; folding it into
WhyZigBase would bury it below the fold. Structure mirrors ReadyOutOfBox (surface
background, `__head`, then content). Content:

- **H2:** `Start on SQLite. Grow to Postgres. Change nothing.`
- **Lede:** `The default deployment is one file on embedded SQLite — easy to run, easy to
  back up. When one box isn't enough, the same application runs on PostgreSQL: opt in at
  build time, point at a URL, and move your data with one command.`
- **Three numbered steps**, each with a one-line code block (`--font-mono` pre, reuse
  QuickStart's step styling):
  1. *Ship day one* — `./zigbase serve   # embedded SQLite, WAL, one file`
  2. *Opt in to Postgres* — `zig build -Dpostgres=true` + `export ZIGBASE_DB_URL="postgres://…?sslmode=require"`
  3. *Move your data* — `zigbase migrate-db --from ./data.db --to "postgres://…"`
- **Three proof bullets** below the steps:
  - `Multi-instance realtime` — "Run several stateless app instances against one database;
    record events fan out to every instance over LISTEN/NOTIFY — never carrying row data."
  - `Pure-Zig driver` — "No libpq, no OpenSSL. The default SQLite build links zero new
    symbols."
  - `Full parity` — "CRUD, filter/sort/expand/search, access rules + abilities + tenancy,
    analytics, encryption, and typed codegen — verified against a live Postgres in CI."
- **Caveat footnote** (small, `--color-muted`, required for honesty):
  `Postgres support is opt-in and new in 0.9.0: transport is TLS-encrypted but server
  certificates are not yet verified (verify-full is a tracked follow-up) — run it over a
  trusted network path. Details in the` [PostgreSQL guide](docs/postgres) `.`
- CTA link: `Read the PostgreSQL guide →` → `{base}docs/postgres`.

### 3.4 CodeSample (`CodeSample.astro`)

Keep the two existing tabs (the slugify hook is good teaching; REST tab unchanged). Add a
**third tab** `{ id: 'ctx', label: 'Ship real features' }` showcasing the 0.9.0 Ctx
surface. Proposed snippet (implementation must verify it compiles against framework.md
§5b/§7b — signatures below were taken from framework.md at e71eac5):

```zig
fn onSignup(ctx: *zigbase.Ctx, ev: *zigbase.RecordEvent) anyerror!void {
    _ = ev;
    // Immutable analytics event — actor, tenant, timestamp stamped server-side.
    try ctx.track("user.signup", .{ .plan = "free" });

    // Welcome email via the durable "emails" queue (SES/Postmark/SMTP behind one vtable).
    try ctx.mail().enqueue(.{
        .to = "user@example.com",
        .subject = "Welcome!",
        .html = "<h1>You're in.</h1>",
    }, .{ .queue = "emails" });

    // Signed outbound webhook with retry/backoff and an idempotency key.
    try ctx.webhook("https://hooks.example.com/zigbase", .{ .event = "signup" }, .{});
}
```

Section header copy update: `One backend, two ways in` stays; sub-line becomes
`Extend the server in typed Zig, or talk to it over a plain REST API — the same
collections, the same access rules, on SQLite or Postgres.`

### 3.5 ReadyOutOfBox (`ReadyOutOfBox.astro`) — 11 modules → 15

New modules link to the new guide pages (finally giving `href`s better targets than the
current everything-points-at-framework pattern). Additions (title — body — href):

- **PostgreSQL backend** — "Opt-in `-Dpostgres` build: same app on Postgres, multi-instance
  realtime, `migrate-db` to move existing data." — `docs/postgres`
- **Multi-tenancy** — "Account-scoped reads, writes, and realtime; built-in accounts,
  memberships, invitations, and role checks." — `docs/tenancy`
- **Full-text search** — "`.searchable` fields, ranked `?search=` queries with operators;
  opt-in vector KNN." — `docs/search`
- **Jobs, webhooks & email** — "Durable queues with retries, signed outbound webhooks, and
  a templated multi-provider email subsystem." — `docs/jobs-and-webhooks`

Updated existing modules: "Realtime subscriptions" body appends "…plus signal/broadcast on
custom channels" and its href moves to `docs/realtime-broadcast`; "Extensible in Zig"
unchanged. Total 15 modules — the grid (`minmax(17rem,1fr)`) handles it. (Analytics and
abilities stay Features-grid-only to keep this section a "modules" list, not a feature
dump.)

### 3.6 WhyZigBase (`WhyZigBase.astro`) — 7 bullets, 2 rewritten, 1 added (→ 8)

- **"SQLite-backed"** bullet becomes **"Embedded database, real database"**: "All data in
  one SQLite file with WAL by default — easy to back up, easy to reason about. The same
  code runs on PostgreSQL (opt-in) when you outgrow one box."
- **"Safe by default"** bullet: append "Tenancy, abilities, and search scoping are
  fail-closed — a misconfiguration denies, never leaks."
- New bullet **"A scale path, not a rewrite"**: "`zigbase migrate-db` moves a live SQLite
  instance to Postgres — schema, data, ids, timestamps, and encrypted-field envelopes
  byte-for-byte."
- Other bullets (One static binary, Comptime framework, Tiny footprint, Full auth stack,
  Deterministic testing) unchanged.

### 3.7 Base.astro default description

Update the default `description` to: `ZigBase is an open-source, single-binary backend —
collections, auth, realtime, search, multi-tenancy, jobs, email, admin UI — on SQLite or
PostgreSQL, and an embeddable Zig framework.` (Also used by OG/Twitter meta.)

QuickStart, AdminShowcase, ExamplesShowcase, SdkShowcase: **unchanged**.

## 4. Docs IA

### 4.1 New sidebar group

Add group `features` (label **"Feature guides"**) between `guides` and `reference`. Two
files must change together:

- `site/src/config/sidebar.ts` — extend the `SidebarGroup['id']` union to
  `'getting-started' | 'guides' | 'features' | 'reference'` and insert the group with the
  eight entries below.
- `site/src/content.config.ts` — extend the zod enum:
  `group: z.enum(['getting-started', 'guides', 'features', 'reference'])`.

### 4.2 New guide pages — final set (8)

Each is authored twice per the mirror convention (§8): `docs/<slug>.md` (source of truth)
and `site/src/content/docs/<slug>.md` (published). Frontmatter on the site copy only:

| slug | title | order | description (frontmatter) |
|---|---|---|---|
| postgres | PostgreSQL backend | 1 | Run ZigBase on PostgreSQL — the -Dpostgres build, ZIGBASE_DB_URL, multi-instance realtime, migrating from SQLite with migrate-db, and pgvector. |
| tenancy | Multi-tenancy | 2 | Account-scoped collections — enabling tenancy, tenant_field, accounts/memberships/invitations, roles, and the @request.account rule macros. |
| abilities | Relationship abilities | 3 | Per-collection, per-action authorization by the principal's relationship to the row — declaring abilities, ctx.can, and the abilities endpoint. |
| search | Full-text & vector search | 4 | Ranked ?search= queries on searchable fields, operators, how search composes with filters and rules, and opt-in -Dvector KNN. |
| analytics | Product analytics | 5 | Capturing immutable events with ctx.track, declarative rollups, and the tenant-scoped analytics read API. |
| email | Email | 6 | Sending application mail — templates, SES/Postmark/SMTP providers, verified senders, bounce suppression, and asserting mail in tests. |
| jobs-and-webhooks | Jobs & webhooks | 7 | Background queues, workers, and job kinds — plus signed outbound webhooks with retry, backoff, and idempotency keys. |
| realtime-broadcast | Realtime broadcast | 8 | Pushing to custom WebSocket channels from routes and jobs — signal vs broadcast, and gating subscriptions with canSubscribe. |

**CAPTCHA** does not get a page: it becomes a new recipe in `docs/recipes.md` +
`site/src/content/docs/recipes.md` ("Gate a public form with CAPTCHA" — `App(.{ .captcha
= … })`, `ctx.verifyCaptcha(provider, token)`, dev-bypass when the secret is empty),
linking to framework.md's `### ctx.verifyCaptcha()` section for the full option table.

### 4.3 Per-page outlines (H2 level)

Every guide opens with a 2–3 sentence "what and why", a **runnable** minimal snippet
within the first screen, and closes with a `## Reference` H2 of deep links (§4.4). All
snippets must be checked against framework.md/api.md at e71eac5 during implementation.

**postgres** — the flagship deploy guide:
`## When to reach for Postgres` (multi-instance, managed DB ops; SQLite default stays
first-class) · `## Build with -Dpostgres` (build from source; note: **release tarballs are
stock SQLite-only — verify against scripts/release.sh before shipping, and say so
explicitly either way**) · `## Point at a database` (ZIGBASE_DB_URL, sslmode; **caveat
box: TLS encrypts but does not yet verify server certs — trusted network path only**;
stock-binary warning behavior) · `## Migrate an existing SQLite instance` (migrate-db
walkthrough; atomic bulk load; encrypted envelopes copied byte-for-byte, no key needed;
**caveat: FK suspension needs a superuser target; non-superuser falls back to
lightly-tested topological ordering**) · `## Realtime across instances` (LISTEN/NOTIFY,
opaque tokens, zero config) · `## Vector search with pgvector` (same -Dvector flag and
?vector= API) · `## Writing cross-backend migrations` (Migrator, execLowered, dialect.kind
— teaching summary of framework.md §8) · `## Reference`.

**tenancy**: `## What tenancy gives you` · `## Enable it` (`.tenancy`, `.auth_collection`,
per-collection `.tenant_field`) · `## Accounts, memberships, invitations` (built-ins,
role order, `POST /api/accounts/:id/activate`) · `## Selecting the active account`
(X-Account-Id header, zb_account cookie, fail-closed verification) · `## Rules with
@request.account` (`.id`/`.role`/`.ids` macros, worked rule) · `## Escaping the scope`
(superuser bypass, `zigbase.crossTenant`) · `## Reference`.

**abilities**: `## Rules vs abilities` (expressions on the row vs relationships to the
row) · `## Declare an ability` (the `.via`/`.min_role` example) · `## How they compose`
(guard stack, LIST narrowing, fail-closed, comptime validation) · `## Check from code`
(`ctx.can`, `GET …/records/:id/abilities`) · `## With tenancy` · `## Reference`.

**search**: `## Make a field searchable` (`.searchable = true`, auto-provisioning: FTS5 /
tsvector+GIN) · `## Query it` (`?search=`, ranking, AND/OR/NOT/prefix, operator-only →
no rows) · `## Compose with filters and rules` (scoped intersection, always-bound terms)
· `## Vector search (opt-in)` (`-Dvector`, `?vector=field:cosine|l2:[…]`, sqlite-vec /
pgvector, fail-closed 400 when not compiled in) · `## Reference`.

**analytics**: `## Track an event` (ctx.track; server-stamped actor/tenant/time; JSON
payload) · `## Roll events up` (`.analytics.rollups`, scheduler-driven incremental
aggregation) · `## Read it back` (`GET /api/analytics/events`, `/rollups/:name`,
tenant-scoped fail-closed) · `## Using it standalone` (no config needed) · `## Reference`
(→ framework.md `### Product analytics`, api.md `## Analytics`).

**email**: `## Send your first message` (ctx.mail().send, multipart text+HTML) ·
`## Templates` (escaped-by-default engine, partials, layout) · `## Providers` (SES,
Postmark, SMTP/Command, per-message From) · `## Deliver in the background` (enqueue /
deliverLater on the queue engine) · `## Senders & suppression` (verified per-account
senders, bounce/complaint webhook; enforcement flags default **off**) · `## Test it`
(CaptureMailer, no network) · `## Reference`.

**jobs-and-webhooks**: `## Queues, workers, jobs` (the three config keys; implicit
default queue/worker) · `## Enqueue work` (ctx.enqueue, payload deserialization) ·
`## Durability & retries` (memory vs durable, at-least-once, visibility timeout,
crash-reclaim, GC) · `## Outbound webhooks` (ctx.webhook; HMAC signing, Idempotency-Key,
capped backoff honoring Retry-After, TLS verification stays on) · `## Built-in job kinds`
(mail, webhook) · `## Reference`.

**realtime-broadcast**: `## Beyond record subscriptions` · `## signal vs broadcast`
(payload-less re-fetch trigger — the default for private state — vs payload delivery in an
enveloped `broadcast` frame) · `## Gate subscriptions` (`.realtime.canSubscribe`; custom
topics can never reach record channels) · `## From the client` (same subscribe protocol;
SDK snippet using `subscribeTopic` from @zigbase/client 0.3.0) · `## Reference`.

**Sequencing dependency:** the broadcast wire format is changing server-side (enveloped
frames, per the SDK gap-closure spec — pre-1.0 breaking change) and the client API
(`subscribeTopic`) ships in @zigbase/client 0.3.0. Write this guide against the
post-envelope framework.md at implementation time, after (or in coordination with) the SDK
workstream's server change — do not document the 0.9.0 verbatim contract.

### 4.4 framework.md-linking convention

Each guide's closing `## Reference` is a short link list into the reference pages using
their real anchors (verified present at e71eac5), e.g. postgres →
`framework#8-define-your-schema-in-code-collections--migrations` (cross-backend
migrations), tenancy → framework's `### Multi-tenancy — account-scoped collections`,
email → `### ctx.mail() — send application mail` + api.md
`## Email — verified senders & bounce webhook`. Inline, guides may link mid-prose with
"full option table: [framework reference](./framework#…)" — but guides never duplicate
option tables; they teach one happy path plus the caveats.

## 5. overview.md refresh (site-only — **no repo `docs/overview.md` exists**; verified)

- Opening paragraph: replace "…all in one statically-linked executable backed by SQLite"
  with "…all in one statically-linked executable — embedded SQLite by default, PostgreSQL
  opt-in — written in **Zig 0.16**."
- `## Features` list: keep existing entries; update **Realtime** (add broadcast +
  multi-instance note → `./realtime-broadcast`), **Email** (rewrite for the new subsystem
  → `./email`); add entries, each one line + link: **PostgreSQL backend (opt-in)**
  (→ `./postgres`), **Multi-tenancy** (→ `./tenancy`), **Relationship abilities**
  (→ `./abilities`), **Full-text & vector search** (→ `./search`), **Product analytics**
  (→ `./analytics`), **Background jobs & queues** (→ `./jobs-and-webhooks`), **Outbound
  webhooks** (same link), **CAPTCHA** (→ `./recipes` anchor).
- `## When to use ZigBase`: rewrite the "runs on SQLite" sentence to present the two-stage
  story; append to the limitations sentence: "…and the PostgreSQL backend is new in 0.9.0
  (TLS is encrypted but not yet certificate-verified)."
- `## Where to go next`: add "**[PostgreSQL](./postgres)** — take the same app to Postgres
  when you outgrow one box."

## 6. Comparison page

**Amendment (2026-07-02, owner request): add TrailBase (trailbase.io) as a fourth
competitor column** — the closest-in-kind comparison (single-binary, SQLite-based,
PocketBase-inspired, Rust with a V8/ES JS runtime for extensions). Every TrailBase cell
is ⚠-verify: research trailbase.io and its docs at implementation time; do not assert
from memory. The "choose X if…" closing paragraphs gain a TrailBase entry (likely:
"choose TrailBase if you want a Rust core with a TypeScript extension runtime").

**Placement decision: site-only**, at `site/src/pages/compare.astro` (precedent:
`download.astro` is already a site-only page outside the docs collection). Justification:
it describes *competitors'* current state, which drifts on a different clock than
versioned product docs; keeping it out of `docs/` avoids a mirror obligation and keeps
repo docs purely product-factual. Add `Compare` to the Nav links (Docs · Examples ·
Compare · Download) and a small "How ZigBase compares →" link under WhyZigBase.
The page carries a visible "Last reviewed: <date>" line and this stance up top: *"This
comparison is maintained by the ZigBase project. We've tried to be fair; corrections
welcome via GitHub issue."* **Ships only after user review (locked decision).**

Structure: intro ("different tools for different constraints — ZigBase is not a hosted
platform and doesn't want to be"), the table, then three short "choose X if…" paragraphs
(including honest "choose PocketBase if you want Windows or a JS extension surface;
choose Supabase/Firebase if you want a managed platform").

Proposed table (rows = dimensions; ⚠ = verify against competitors' current docs before
shipping — competitor cells reflect knowledge as of early 2026 and MUST be re-checked):

| Dimension | ZigBase | PocketBase | Supabase | Firebase |
|---|---|---|---|---|
| Model | Self-hosted single binary | Self-hosted single binary | Hosted platform; self-host possible (multi-service) | Hosted only |
| Database | Embedded SQLite; PostgreSQL opt-in (new in 0.9.0) | Embedded SQLite | PostgreSQL | Proprietary (Firestore) |
| Scale path | Same binary/code SQLite → Postgres; `migrate-db` mover; multi-instance realtime on PG | Single node (SQLite) ⚠ | Postgres-native scaling | Managed |
| Extension model | Compiled, typed Zig (comptime-checked hooks/routes/jobs) | Go framework or embedded JS (jsvm) hooks ⚠ | SQL/RLS + Deno edge functions | JS Cloud Functions |
| Auth | Password, magic-link, OTP, passkeys/WebAuthn, OAuth2+PKCE | Password, OTP/MFA, OAuth2 ⚠ (passkeys?) | Full GoTrue incl. SAML SSO ⚠ | Broad incl. phone auth |
| Authorization | Rules + relationship abilities + first-class multi-tenancy, fail-closed | Rule expressions | Postgres RLS | Security rules |
| Realtime | WebSocket record subs + custom broadcast; cross-instance on PG | SSE record subs ⚠ | CDC + broadcast + presence | Native listeners |
| Search | Built-in FTS (+ opt-in vector) | Filter queries only ⚠ | PG FTS + pgvector | None native (external) ⚠ |
| Jobs/queues | Built-in durable queues, retries, webhooks | Cron ⚠ | pg_cron / queues ⚠ | Cloud Tasks/Scheduler |
| Email | Built-in templates + SES/Postmark/SMTP, suppression | SMTP ⚠ | SMTP (auth mail) ⚠ | Via extensions ⚠ |
| Analytics | Built-in event capture + rollups | — ⚠ | — (external) ⚠ | Google Analytics |
| Admin UI | Embedded SPA at `/_/` | Embedded | Hosted studio | Console |
| Client SDKs | TypeScript (typed codegen) | JS + Dart ⚠ | Many | Many |
| Platforms | **Linux & macOS only — no Windows** | Linux/macOS/Windows | n/a (hosted) / Docker | n/a |
| Maturity | **Pre-1.0** (0.9.0); PG backend new, TLS not yet cert-verified | Pre-1.0 (0.2x) ⚠ | GA hosted | GA |
| License / cost | Apache-2.0, free | MIT, free | Apache-2.0 core; hosted tiers | Proprietary, usage-billed |

ZigBase self-caveats are stated in-table (bolded), not hidden: pre-1.0, no Windows, no
hosted offering, young ecosystem, extension requires Zig.

## 7. OG image

- **Asset:** static `site/public/og.png`, 1200×630. Source SVG committed at
  `site/src/assets/og.svg` (not in `public/`, so it isn't deployed raw).
- **Design (buildable without a designer):** dark background `#0f1011` (the site's dark
  `--color-bg`); the existing `site/src/assets/logo.svg` mark at ~120px top-left with the
  "ZigBase" wordmark; centered title in the system-sans stack, white `#e8e8e8`:
  `Open-source backend in a single binary`; second line in accent `#f7a41d`:
  `SQLite to start. Postgres when you grow.`; bottom-left small mono line in muted
  `#a0a4ab`: `Apache-2.0 · Linux & macOS · valthon.github.io/zigbase`. **No version
  number** — a static PNG must not go stale per release.
- **Generation:** hand-author the SVG, rasterize once and commit the PNG:
  `rsvg-convert -w 1200 -h 630 site/src/assets/og.svg -o site/public/og.png` (or
  `npx --yes sharp-cli -i og.svg -o og.png resize 1200 630`). No build-time dependency.
- **Wiring (`site/src/layouts/Base.astro`):** OG URLs must be absolute; reuse the existing
  `Astro.site` pattern:
  ```astro
  const ogImage = new URL(`${base}og.png`, Astro.site).href;
  ```
  ```html
  <meta property="og:image" content={ogImage} />
  <meta property="og:image:width" content="1200" />
  <meta property="og:image:height" content="630" />
  <meta property="og:image:alt" content="ZigBase — open-source backend in a single binary. SQLite to start, Postgres when you grow." />
  <meta name="twitter:image" content={ogImage} />
  ```
  `twitter:card` is already `summary_large_image` — correct, keep.

## 8. Mirror-sync obligations

**Verified actual convention (it is NOT byte-identical today):** site copies carry
frontmatter (`title/description/order/group`), omit the repo files' "📖 This documentation
is also published…" banner blockquote, use extensionless relative links (`./tutorial`)
where repo files use `tutorial.md`, occasionally add explicit `{#anchor}` heading ids, and
are re-wrapped at a wider width. **For all NEW pages this spec mandates a tighter rule:**
bodies are line-for-line identical except (1) site-only frontmatter block, (2) repo-only
published-banner blockquote (pointing at `https://valthon.github.io/zigbase/docs/<slug>`),
(3) link suffix form (`.md` in repo ↔ extensionless on site). Same wrapping, so
`diff <(tail -n +8 site-copy) <(tail -n +3 repo-copy)` reduces to link-suffix lines only.

Files touched, as pairs / singles:

| Repo (`docs/`) | Site (`site/src/content/docs/`) | Status |
|---|---|---|
| `docs/postgres.md` | `postgres.md` | new pair (×8: postgres, tenancy, abilities, search, analytics, email, jobs-and-webhooks, realtime-broadcast) |
| `docs/recipes.md` | `recipes.md` | edited pair (CAPTCHA recipe) |
| — | `overview.md` | site-only edit (no repo counterpart exists) |
| — | `site/src/pages/compare.astro`, `index.astro`, `landing/*.astro` (Hero, Features, CodeSample, **DualBackend new**, ReadyOutOfBox, WhyZigBase), `Nav.astro`, `layouts/Base.astro`, `config/sidebar.ts`, `content.config.ts`, `public/og.png`, `assets/og.svg` | site-only |
| `changelog.d/site-0-9-refresh.md` | — | fragment: `### Internal` (site/docs refresh) — never edit CHANGELOG.md directly |

Follow-ups discovered while auditing (flag, decide in review whether in-scope):
**`README.md` line 7 still says "backed by SQLite"** — same staleness as the hero; and
`framework.md`/`api.md` remain untouched by design (locked decision 1).

## 9. Testing & verification

1. **Build gate:** `cd site && npm run build` must pass (this also validates the new
   `group` enum, all frontmatter, and every content-collection page renders). Broken
   internal links: spot-check by grepping `dist/` for the eight new
   `docs/<slug>.html` files and for `href` targets of the new landing links.
2. **Snippet accuracy:** every code sample in the guides and CodeSample's new tab is
   diffed against the corresponding framework.md/api.md section at HEAD before merge
   (guides teach real APIs; nothing invented). The Zig snippets aren't compiled by the
   site build — this is a manual review step, called out in the PR description.
3. **Visual checks:** `npx astro preview` (or `npm run preview`) — verify light + dark
   (toggle sets `data-theme`), mobile nav with the added Compare link, the 21-card grid at
   narrow widths (`minmax(16rem,1fr)` auto-fit), and the new DualBackend section at both
   themes.
4. **OG validation:** grep the built HTML —
   `grep -o '<meta property="og:image"[^>]*>' site/dist/index.html` — and confirm an
   absolute `https://valthon.github.io/zigbase/og.png` URL; `file site/public/og.png`
   confirms 1200×630. Post-deploy, run the page through opengraph.xyz or the social
   debuggers once.
5. **Sidebar integrity:** every slug in `sidebar.ts` has a content file and vice versa
   (the build fails on schema mismatch; the orphan direction is a manual check).
6. **Mirror check:** run the §8 `diff` recipe on each of the 9 doc pairs.
7. **Fact gate before shipping compare.astro:** re-verify every ⚠ cell against current
   competitor docs; page ships only after the user reviews the copy (locked decision 2).
8. PR checklist (`.github/pull_request_template.md`) filled honestly; no Zig code changes,
   so `zig build test` / browser suite are N/A — state that rather than checking blindly.
