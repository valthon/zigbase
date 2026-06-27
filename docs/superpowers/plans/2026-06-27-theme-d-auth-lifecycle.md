# Plan — Theme D: Auth Lifecycle & Session Management

Spec: `docs/superpowers/specs/2026-06-27-theme-d-auth-lifecycle-design.md`.
TDD throughout: write a failing test, see it fail, implement, see it pass, commit.

## Task 1 — `session.zig` (factored cookie policy, #86 foundation)
- New `src/session.zig`: `auth_cookie`, `csrf_cookie`, `sessionCookies(secure, token, csrf, max_age) [2]http.Cookie`, `clearedCookies(secure) [2]http.Cookie`.
- Unit tests in `session.zig`: cleared cookies have max_age<0, correct names, http_only per cookie, secure follows arg, same_site=.strict; set cookies carry token/csrf/max_age.
- Register `src/session.zig` in `root.zig` test block.
- Refactor `api/auth.zig:issue()` and `authLogout()` to use `session.*`. Existing auth tests must stay green.

## Task 2 — `ctx.auth().clearSession()` + `zigbase.auth.clearSession` (#86)
- `ctx.zig`: add `AuthApi` namespace (`ctx.auth()`), `clearSession()` returns arena-dup of `session.clearedCookies(app.cookie_secure)`.
- `auth_helpers.zig`: `clearSession(ctx: *Ctx) ![]const http.Cookie` delegating to `ctx.auth().clearSession()`.
- Tests: `ctx.auth().clearSession()` returns 2 arena cookies matching `authLogout`'s policy.

## Task 3 — `beforeAuthSuccess` event + dispatch wiring (#80, types)
- `events.zig`: add `AuthSuccessEvent`, `AuthSuccessHandler`, `Dispatch.before_auth_success`.
- `framework.zig`: add `beforeAuthSuccess` to allowed cfg keys + wire `d.before_auth_success`.
- `root.zig`: export `AuthSuccessEvent`, `AuthSuccessHandler`.
- Test: `App(.{ .beforeAuthSuccess = h })` sets the dispatch slot; absent → null.

## Task 4 — `fireBeforeAuthSuccess` helper + transactional consume (#80, behavior)
- `api/auth.zig`: `fireBeforeAuthSuccess(req, conn, col_name, rid, method, rec) !?http.Response` — builds a bound `*Ctx` (rctx.auth=rec, collection set), runs the hook; on error returns `cx.errorResponse(e)` (caller rolls back); null = proceed; no dispatch/handler → null.
- `api/auth_methods.zig` `complete` `.record` branch: acquire writer → fetch record → verification gate → `BEGIN IMMEDIATE` → `fireBeforeAuthSuccess` (rollback+return on Some) → `issueSessionExt(rec)` → `COMMIT` (rollback on error).
- `api/magic_link_consume.zig`: wrap verify+consume+gate+hook+issue in `BEGIN IMMEDIATE … COMMIT`; rollback on every early return; aborting hook leaves token un-consumed.
- Tests (in `api/auth_methods.zig`):
  - password `complete` with a writing `beforeAuthSuccess` → 200, side-write committed, correct method tag.
  - aborting `beforeAuthSuccess` (`ctx.fail`/`error.Forbidden`) → no session (403, 0 cookies) AND side-write rolled back.
- Test (in `api/magic_link_consume.zig`): aborting hook → 4xx and token still consumable on retry; passing hook → 302 + replay rejected.

## Task 5 — Docs + example + changelog
- `docs/framework.md` + `site/src/content/docs/framework.md`: hooks table row, auth-lifecycle subsection, `clearSession`/`ctx.auth()` doc, logout one-liner.
- `examples/golfsim`: add `beforeAuthSuccess` claim hook + logout route via `ctx.auth().clearSession()`; keep building.
- `changelog.d/theme-d-auth-lifecycle.md` (`### Features`).
- `cd site && npm run build`; build golfsim.

## Verify gate
- `zig build test --summary all` → `Build Summary: N/N tests passed`.
- `python -m pytest tests/admin -q` → all pass.

## PR
- Push `feat/theme-d-auth-lifecycle`; `gh pr create --base main` referencing #80 + #86.
