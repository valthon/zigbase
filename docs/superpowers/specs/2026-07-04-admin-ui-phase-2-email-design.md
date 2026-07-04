# Admin UI Phase 2 — Email view — Design

**Goal:** Add an **Email** management view (`/_/#/email`) to the embedded admin
SPA — the second of the four admin areas in the expansion program, after the
merged Phase 1 (foundation + Users). It surfaces the email subsystem shipped in
email-2 (#194): sender identities, the suppression list, bulk-send batches, and
the mail policy state.

**Architecture:** A new `src/admin/views/email.js` ES module on the Phase-1
foundation (browser-native ES modules, no build step; served from the
`src/admin.zig` comptime ETag'd manifest as one new row). Wired as a `#/email`
hash route + a nav item. The view is organized as three tabs — **Senders**,
**Suppressions**, **Batches** — plus a read-only mail-policy strip. It composes
existing superuser REST APIs; the only new backend is one tiny read endpoint
for the policy strip.

**Tech stack:** Preact 10 + hooks + htm (vendored `preact.js`), the Phase-1
`lib/api.js` client (extended with email helpers), `src/admin.zig` manifest,
Playwright (`tests/admin/`, run under `-n auto`). One new Zig HTTP handler
(`src/api/mail_config.zig`) + route.

## Global Constraints

- **No build step for the admin.** No Node/npm/bundler; edit `.js`, rebuild the
  binary; every asset `@embedFile`-d; modules import by absolute `/_/assets/...`
  path.
- **Superuser-only surface.** Every mail system collection (`_sender_identities`,
  `_suppressions`, `_mail_batches`, `_mail_batch_recipients`) is `system=1` with
  NULL rules (superuser-only); the admin uses its `zb_auth`+`zb_csrf` cookie
  session, which is accepted.
- **No secrets in the UI.** The policy strip shows booleans only — never the
  `webhook_secret` value or any token.
- **`data-test=` hooks** on interactive elements; a `tests/admin/test_email.py`
  Playwright file, run under `-n auto`.
- **Every view/list guards its collection-select against the same reload race
  fixed in Phase 1** (only reset rows when the selection actually changes).
- Docs/site mirror stay in sync; a `changelog.d/` fragment is added; touched
  `.zig` stays `zig fmt`-clean (CI gate). Run the FULL `tests/admin/` suite
  (`-n auto`) before finishing.

## Confirmed API surface (verified against origin/main)

All superuser; the admin cookie session works on all of these.

**Senders** — dedicated endpoints (`src/api/senders.zig`):
- `GET /api/senders` → `{ items: [ { id, email, status, verified_at } ] }` (`status` ∈ `pending|verified`).
- `POST /api/senders` `{ "email": "…" }` → mints + emails a verification token; `201` pending / `200` already-verified, returns `{ id, email, status }`. Used for **invite / re-invite**.
- `POST /api/senders/:id/verify` `{ "token": "…" }` — completes verification (the *recipient's* token flow; NOT an admin action).
- **No sender DELETE endpoint** → delete via `DELETE /api/collections/_sender_identities/records/:id` (records API, superuser). NOTE the raw record exposes `verification_token`; the UI must never render it.

**Suppressions** — records API on `_suppressions` (no dedicated endpoint):
- List: `GET /api/collections/_suppressions/records` → `{items:[{ id, email, reason, source, account, created }]}` (`reason` ∈ `hard_bounce|complaint|unsubscribe`).
- Add: `POST /api/collections/_suppressions/records` `{ email, reason, source? }`.
- Remove: `DELETE /api/collections/_suppressions/records/:id`.

**Batches** — records API on two collections (read-only; no HTTP send/cancel):
- `GET /api/collections/_mail_batches/records` → `{items:[{ id, status, total, created, … }]}` (`status` e.g. `active`).
- `GET /api/collections/_mail_batch_recipients/records?filter=…` → per-recipient `{ status ∈ pending|sent|suppressed|invalid|failed|canceled, attempts, last_error, sent_at, … }`; progress is a **client-side aggregation** of these counts per batch.

**Mail policy** — NOT exposed over HTTP today (comptime `.mail` + env). Requires the new endpoint below.

## New backend: `GET /api/mail/config` (the only new server code)

A minimal superuser read endpoint so the policy strip has data. Returns booleans
only — **no secret values**:

```json
{ "require_verified_sender": false, "check_suppression": false,
  "webhook_configured": true, "unsubscribe_configured": true }
```

- `require_verified_sender` / `check_suppression` from `app.mail` (the lowered
  `mail_cfg.Runtime`).
- `webhook_configured` = `app.mail.webhook_secret.len > 0`.
- `unsubscribe_configured` = `app.mail.unsubscribe_base_url.len > 0`.
- New handler `src/api/mail_config.zig`; route `GET /api/mail/config` added to
  `src/server.zig` under the **existing `mail_unsubscribe`/`senders` gate**
  (`@hasField(cfg,"mail")`), so it ships on the standalone binary (which sets
  `.mail = .{}`) and is omitted from mail-free embedder builds. Superuser-gated
  (return 403/404 to non-superusers, matching the mail collections' posture).
- A Zig unit test (handler returns the right booleans for a couple of configs)
  + coverage from the browser test.

## View design — `src/admin/views/email.js`

One exported `EmailView` at `#/email`; nav item `📧 Email`. A tab strip
(`data-test=email-tab-{senders,suppressions,batches}`) switches the active
sub-panel; the read-only policy strip renders above the tabs.

### Policy strip (top, read-only)
Fetches `GET /api/mail/config` once; renders four labeled booleans
(`data-test=mailcfg-{require-verified,check-suppression,webhook,unsubscribe}`)
as ✓/✗ chips. Degrades quietly if the endpoint 404s (mail-free build).

### Tab 1 — Senders
- Table from `GET /api/senders`: email, status badge (`pending`/`verified`),
  verified-at. `data-test=sender-row`.
- **Invite**: an email input + button → `POST /api/senders`; on success reloads
  the list (a re-invite of a pending address re-sends the token). `data-test=sender-invite-email` / `sender-invite`.
- **Delete**: per-row delete (confirm dialog) → `DELETE …/_sender_identities/records/:id`; reload. `data-test=sender-delete`.
- No "verify" button (verification is the recipient's emailed-token flow) — the
  status badge communicates state.

### Tab 2 — Suppressions
- Table from `_suppressions` records: email, reason chip, source, created.
  `data-test=suppression-row`. Pagination (records envelope).
- **Reason filter** (`all | hard_bounce | complaint | unsubscribe`) →
  `?filter=reason="…"` (built with `JSON.stringify`, injection-safe like the
  Phase-1 Users search). `data-test=suppression-filter`.
- **Add**: email + reason select → `POST …/_suppressions/records`
  (`source` defaults to `admin`). `data-test=suppression-add-email` / `-reason` / `-add`.
- **Remove**: per-row delete (confirm) → `DELETE …/_suppressions/records/:id`.
  `data-test=suppression-remove`.
- Unsubscribes appear here as `reason=unsubscribe` (no separate section).

### Tab 3 — Batches (read-only)
- Table from `_mail_batches` records: id (short), status, total, created.
  `data-test=batch-row`.
- **Expand a batch** → fetch `_mail_batch_recipients?filter=<batchRef>="…"` (or
  the actual FK column, confirmed in the plan) and show an aggregated progress
  line: counts per status (sent / pending / failed / suppressed / invalid /
  canceled). `data-test=batch-progress`. Read-only; no send/cancel (no endpoint).
- If the recipients FK/column name is uncertain, the plan confirms it against
  `migrations.zig` before building.

## Out of scope (documented gaps, not built)

- Sending or canceling a batch from the UI (Zig-only `sendBulk`/`cancelBatch`;
  no HTTP surface).
- A delivery-event / bounce log (webhook events collapse into `_suppressions`;
  no events table exists).
- Editing mail policy (comptime/env; the strip is display-only).
- Marking a sender verified from the admin (recipient token flow owns that).

## Testing strategy

- `tests/admin/test_email.py` (Playwright, `-n auto`): policy strip renders;
  Senders list + invite + delete; Suppressions list + reason-filter + add +
  remove; Batches list + expand-progress. Seed via the superuser records API /
  `/api/senders` using the existing `conftest` helpers.
- Zig unit test for `mail_config` handler (booleans reflect the config).
- The existing suite stays green (the view is additive; one manifest row, one
  route, one nav item).

## Risks

1. **Batch recipients FK column name** — the exact filter column linking
   `_mail_batch_recipients` → its batch must be confirmed from `migrations.zig`
   in the plan before writing the aggregation. (Low risk; it's a schema lookup.)
2. **`_sender_identities` raw record exposes `verification_token`** — the
   delete-by-records-API path reads/writes the raw row; the UI must render only
   `email`/`status` and never the token. Enforced by using `/api/senders` for
   listing (which omits the token) and records API only for the DELETE.
3. **Collection-select / tab reload races** — reuse the Phase-1 guard: only
   reset rows when the selection/tab actually changes; each tab owns its own
   fetch effect keyed on its inputs.
