# Auth Lifecycle Hooks (register / logout / refresh / password-change)

**Status:** Design approved 2026-06-27. Implements issue #98 (Theme D follow-up).
Builds directly on the Theme D `beforeAuthSuccess` machinery
(`2026-06-27-theme-d-auth-lifecycle-design.md`).

## Background

Theme D (#80, PR #91) shipped one writable, transactional, abortable auth hook —
`beforeAuthSuccess` — firing on the unified `complete` endpoint and magic-link
`consume`, plus the notify-only `onAuth` (post-issue). The remaining lifecycle
phases (register / logout / refresh / password-change) were **designed but
deferred** in that spec's "Lifecycle/session framing" table.

This spec extends that into a uniform before/after lifecycle for the four
deferred phases, reusing the exact `beforeAuthSuccess` discipline: a `*Ctx`
bound to the in-transaction writer where a write txn exists; before-hooks are
abortable and **fail closed** (any error → `ROLLBACK` where applicable, the
primary action is blocked); after-hooks are notify-only (errors → the framework
error backstop, the action already happened).

`beforeAuthSuccess` and `onAuth` are **unchanged** — same dispatch slots, same
firing sites, same semantics.

## Config surface

A new **top-level** `.auth` config group (sibling of `beforeAuthSuccess` /
`onAuth`):

```zig
zigbase.App(.{
    .auth = .{
        .beforeRegister       = fn(*Ctx, *AuthLifecycleEvent) anyerror!void,
        .afterRegister        = fn(*Ctx, *AuthLifecycleEvent) anyerror!void,
        .beforeLogout         = ...,
        .afterLogout          = ...,
        .beforeRefresh        = ...,
        .afterRefresh         = ...,
        .beforePasswordChange = ...,
        .afterPasswordChange  = ...,
    },
    // unchanged:
    .beforeAuthSuccess = fn(*Ctx, *AuthSuccessEvent) anyerror!void,
    .onAuth            = fn(*AuthEvent) void,
});
```

**Why a top-level `.auth` group and not `.hooks = .{ .auth = ... }`:** `.hooks`
is keyed by **collection name** (plus the `any` wildcard), so a group named
`auth` there would collide with (and be indistinguishable from) a real auth
collection literally named `auth`. A dedicated top-level `.auth` group avoids
that ambiguity and reads as a peer of the existing `.beforeAuthSuccess`/`.onAuth`
keys.

**Comptime validation (typo = `@compileError`):** `"auth"` is added to the App
cfg allowed-keys guard. The `.auth` group is validated by
`events.validateAuthLifecycleHooks` (mirrors `validateHooks`): every sub-field
name must be one of the eight canonical phase names, and each value must coerce
to `AuthLifecycleHandler` — so `.beforeRegsiter = fn` or a wrong-typed handler
is a loud compile error, never a silently-dead hook.

## Event shape

One uniform event + handler type (phase discriminates), mirroring `RecordEvent`:

```zig
// events.zig
pub const AuthLifecyclePhase = enum {
    before_register, after_register,
    before_logout, after_logout,
    before_refresh, after_refresh,
    before_password_change, after_password_change,
};

pub const AuthLifecycleEvent = struct {
    app: *App,
    /// The auth collection name (e.g. "users").
    collection: []const u8,
    /// The principal's record id. "" for before_register (no id yet) and for an
    /// unauthenticated logout.
    record_id: []const u8,
    phase: AuthLifecyclePhase,
    /// before_register: the writable to-be-created record data (mutate via the
    ///   hook's ctx.arena, like a before_create RecordEvent).
    /// after_register: the persisted record (with id).
    /// password-change / refresh: the existing record snapshot (read).
    /// logout: null (no record is loaded for the cheap path).
    record: ?*std.json.Value,
};
pub const AuthLifecycleHandler = *const fn (ctx: *Ctx, ev: *AuthLifecycleEvent) anyerror!void;
```

A single generated dispatcher (`buildAuthLifecycleDispatcher`, mirroring
`buildRecordDispatcher`) routes by phase to the registered handler; it occupies
**one** `Dispatch.auth_lifecycle` slot. The firing site decides abort vs notify
semantics (before = propagate/abort, after = swallow→backstop), exactly like
`emitRecord`.

## Phases, seams, and semantics

| Phase | Endpoint / seam | Write txn present? | before: writable | before: transactional | before: abortable (fail-closed) |
|-------|-----------------|--------------------|------------------|-----------------------|---------------------------------|
| register | `api/records.zig:create`, gated `col.type == .auth` | yes (create's `BEGIN IMMEDIATE`) | yes (mutate record data, bound conn) | yes (rolls back the INSERT) | yes → rollback, no account created |
| logout | `api/auth.zig:authLogout` | no | yes (bound writer) | no (nothing to roll back) | yes → mapped response, cookies **not** cleared |
| refresh | `api/auth.zig:authRefresh` | yes (new `BEGIN IMMEDIATE` added) | yes (bound conn) | yes | yes → rollback, no new session |
| password-change | `api/auth.zig:confirmPasswordReset` | yes (new `BEGIN IMMEDIATE` added) | yes (bound conn) | yes (rolls back token-consume + pw update) | yes → rollback, password unchanged, token un-consumed |

After-hooks for all four: post-commit (or post-action for logout), notify-only,
errors routed to `events.dispatchError` (never propagate — the action is done).

### register
Fires only for **auth** collections. `beforeRegister` runs inside the create
transaction, after the generic `before_create` record hook and before the row
INSERT; aborting it rolls back the whole create (fail closed) and returns the
`Ctx`-mapped response (`ctx.fail(status,msg)` / `error.Forbidden`→403 / else 500).
`afterRegister` runs post-commit alongside `after_create`, with the persisted
record (id populated). Use case: gate sign-ups (`beforeRegister`), seed a related
profile row atomically via `ctx.records()` (`beforeRegister`, in-txn) or
fire-and-forget side effects (`afterRegister`).

### logout
`authLogout` has no DB write. When an `auth_lifecycle` handler is registered, the
handler acquires the writer and best-effort-authenticates the caller to populate
`record_id`/`collection` (anonymous → `record_id=""`). `beforeLogout` is writable
(bound writer) and abortable — an error returns the mapped response and the
session cookies are **not** cleared; there is no transaction so nothing rolls
back (documented). `afterLogout` fires after the cleared-cookie response is
prepared. When no handler is registered the cheap original code path is kept (no
writer acquired).

### refresh
`authRefresh` now wraps fire-before → issue → emit in `BEGIN IMMEDIATE … COMMIT`
(it previously held the writer untransacted and emitted `onAuth` inline). It
switches to `issueSessionNoEmit` + post-commit `emitAuth` so `onAuth` fires after
a durable commit — matching the `complete`/`consume` discipline. `beforeRefresh`
runs in-txn before issuance; aborting rolls back and blocks the new session.
`afterRefresh` runs post-commit. (`beforeAuthSuccess` is intentionally **not**
added to refresh — that remains deferred per the Theme D spec.)

### password-change
`confirmPasswordReset` now wraps token-consume → before → update in
`BEGIN IMMEDIATE … COMMIT`. `beforePasswordChange` runs after the token is
consumed and before the password UPDATE, with the existing record snapshot;
aborting rolls back both the token consumption (link stays usable) and the
password change (fail closed). `afterPasswordChange` fires post-commit.

## Deferred (designed, not wired)

- **Self-service password change via `PATCH /records`.** A generic auth-record
  update is not unambiguously a "password change" (it may touch any field), so no
  dedicated lifecycle seam is added there. Consumers gate/observe it today via
  the record `beforeUpdate`/`afterUpdate` hooks on the auth collection.
- **Firing `beforeAuthSuccess` on the legacy `/auth-with-password` and
  `/auth-refresh` endpoints.** Unchanged from Theme D (still deferred).
- **`ctx.auth()` refresh / rotate / list-active / revoke verbs.** Unchanged from
  Theme D (still deferred — stateless JWT sessions have no server-side store).
- **register before/after on a non-`records.zig` path.** Registration is account
  creation via the records engine; there is no separate register endpoint, so the
  seam lives in `records.create`.

## Testing (TDD)

Unit (Zig), added to the relevant files' `test {}` (discovered via `root.zig`):

- **Fires at the right point:** each of the eight hooks fires once with the
  correct `phase`, `collection`, and `record_id` on its endpoint.
- **Abort rolls back / fails closed:**
  - `beforeRegister` abort → no account row, mapped status, no session.
  - `beforeRefresh` abort → no new session, side-write rolled back.
  - `beforePasswordChange` abort → password unchanged AND reset token un-consumed
    (retry still works), mapped status.
  - `beforeLogout` abort → cookies not cleared, mapped status.
- **after-hooks are notify-only:** an erroring after-hook does not fail the
  request (routed to the backstop).
- **Comptime typo rejection:** a `buildAuthLifecycleDispatcher` over a bad field
  name is a `@compileError` (asserted via a documented commented-out negative
  case + the validation unit test on the happy path).
- **Existing `beforeAuthSuccess`/`onAuth` tests stay green** (unchanged behavior).

Browser/pytest (`tests/admin/`): the admin register/login/logout/password paths
must still pass — `authLogout`/`authRefresh`/`confirmPasswordReset` are on the
real auth surface. The admin app registers no lifecycle hooks (all null → cheap
paths preserved).

## Docs & changelog

- `docs/framework.md` + `site/src/content/docs/framework.md` mirror: document the
  `.auth` lifecycle group, the event shape, and the abortable/transactional
  matrix in the hooks section.
- `examples/golfsim`: demonstrate one hook (`afterRegister` seeding, or
  `beforeRegister` gating) keeping the example building.
- `changelog.d/auth-lifecycle-hooks.md`: `### Features`.

## Decision record

- New config group is the top-level **`.auth`** struct (not under `.hooks`).
- One event type `AuthLifecycleEvent` + `phase` enum; one `Dispatch.auth_lifecycle`
  slot fed by `buildAuthLifecycleDispatcher`.
- before-hooks reuse the `Ctx` error model and fail closed; after-hooks are
  notify-only (backstop on error).
- refresh and password-change gain a `BEGIN IMMEDIATE … COMMIT` so their
  before-hook side-writes are atomic; refresh switches `onAuth` emission to
  post-commit (a strict improvement, still exactly once).
- logout keeps a no-writer fast path when no lifecycle hook is registered.
