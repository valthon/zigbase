# Theme R triage — controller decisions (2026-07-02, from the five audit reports)

Owner delegated triage ("review the reports yourself and proceed"). Decisions below; audit
reports in this directory are the evidence base (audit-binary-size, audit-runtime-efficiency,
audit-facilio-duplication, audit-gating-consistency, audit-api-ergonomics).

## Stream R1 — performance & efficiency (no framework.zig ownership)

| # | Fix | Source | Sizing |
|---|-----|--------|--------|
| R1-1 | regex.zig Builder init fix (the 3.03 MB all-zero rodata template; binary 7.6→4.6 MB) | binary #1 | 8 lines + verification |
| R1-2 | Bounded worker pool for memory queues + route app.submit through it; joined at shutdown; overflow policy documented | runtime F1+F2 | ~250-340 lines |
| R1-3 | Realtime delete sandbox: create only the target table (+_tenancy prereqs when scoped), not the 28-migration suite | runtime F3 | ~30-60 lines |
| R1-4 | Versioned collection-metadata cache (name→parsed Collection, invalidated on collection DDL); used by REST record path + realtime fan-out | runtime F4+F7 | ~120-180 lines |
| R1-5 | Admin SPA embedded JS gets ETag/304 via the existing CRC32 pattern | facil.io bonus | small |
| R1-6 | Fix the false "facil.io decodes the path" comment (static_files.zig:68) + add the why-comment on query/params.zig's owned parser | facil.io #3/#5 | trivial |

DEFERRED (next sharpening round): ctx.track batching (F8 — durability semantics deserve a design
note, not an overnight change); scheduler idle condvar (F6 — sub-1% CPU, low value); ReleaseSmall
(keep ReleaseSafe — safety checks in production are part of the identity; note in build docs).

## Stream R2 — gating, config & API consistency (owns framework.zig/build.zig/docs)

| # | Fix | Source | Notes |
|---|-----|--------|-------|
| R2-1 | Evict demo feature flags from src/main.zig into a fixture app | gating #5 | embarrassing; S |
| R2-2 | `.admin` disable key (comptime) | gating #3 | S |
| R2-3 | Comptime-assemble `builtin_routes` from config (analytics/senders/mail-webhook/tenancy/WebAuthn routes only when configured) | gating #1 | M; the invariant fix |
| R2-4 | Selectable auth-method builtins (WebAuthn's ~3.2k LOC becomes opt-out-able for consumers) | gating #2 | M |
| R2-5 | Gate builtin_job_regs (mail/webhook job kinds registered only when reachable) | gating #4 | S-M |
| R2-6 | `-Dfts5` build flag, DEFAULT ON (custom lean builds may drop ~250-400 KB) | binary #2 | S |
| R2-7 | E1: `.migrations` accepts bare tuples (widening, non-breaking) | api E1 | S |
| R2-8 | E2: regenerate framework.md config-key table + add table↔allowed-tuple parity test | api E2 | S |
| R2-9 | E4+E7: `GET /api/collections` + `/api/settings` → `{items}`; analytics list adopts house cursor/limit params; oauth providers `{providers}`→`{items}` (N6) | api E4/E7/N6 | breaking-small; SDK + admin SPA updated same PR |
| R2-10 | E5: side-effect success bodies → uniform 204 (confirm-verification, confirm-password-reset, webauthn register/finish) + SDK | api E5 | sets the convention for E/F streams |
| R2-11 | E6: `/auth/magic_link/consume` → `magic-link` (hard cutover, tokens short-lived) | api E6 | S |
| R2-12 | E8/E9/E10: `RecordEvent.ctx`→`ev.rctx`; delete vestigial RouteEvent; drop `RecordEvent.app` (+examples updated) | api E8-10 | breaking, mechanical |
| R2-13 | E11+E12+N12: fix README OAUTH_STATE_SERVER default (security doc bug); add ZIGBASE_DB_URL/PUBLIC_URL/SENDMAIL_COMMAND to README+help; single-source env table w/ parity test | api E11/E12/N12 | E11 first — one line |
| R2-14 | N1: delete legacy `.jobs.pool_size` fallback | api N1 | trivial breaking |
| R2-15 | E3: auth config grouping `.auth = .{ .hooks, .methods, .captcha, .session }` — SEQUENCED LAST in R2; R2 branch merges AFTER auth-2 (F) and rebases | api E3 | M, breaking |
| R2-16 | Docs: config-plane assignment rule sentence (comptime=structure / env=deploy-varying / build flag=binary cost); laziness contract per key ("unset ⇒ not in your binary"); the no-unconditional-fn-pointer invariant; CLAUDE.md gains the sharpening-rhythm note | api cross-cutting + gating policy | docs |

DECISIONS on contested items: OAuth provider struct stays camelCase as a documented exception
(N5) — auth-2's `discoveryURL` ships consistent with existing fields; NO rename mid-stream.
migrate-db rename (N13): declined — recent name, low confusion evidence. `.mail` naming (N2),
static config grouping (N4): deferred to next sharpening round (D stream is adding static keys
now; group later in one move). All 11 bikeshed items: declined per the audit.

## Cross-stream conventions injected into other SP3 streams (E13)
- Email-2's unsubscribe POST + Auth-2's session endpoints: side-effect success = **204**; any
  list shape = `{items}`; pagination = house cursor/limit params. (Sent to those plan writers.)

## Merge-order recommendation (for tomorrow's review)
R1 and Docker: anytime. A/E/F: anytime after CI. C and D: coordinate serving-path overlap.
R2: LAST (touches framework.zig config surface broadly + E3 depends on auth-2 landing).
