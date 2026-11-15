> 📖 This documentation is also published, web-native, at <https://valthon.github.io/zigbase/docs/tenancy> — the site is the canonical reading experience.

# Multi-tenancy

ZigBase has built-in **account-scoped multi-tenancy**: mark a collection as tenant-owned and every
read, write, and realtime delivery of it is automatically narrowed to the request's active account
— you do not hand-write `account = @request.account.id` on every rule, and a client can never read
or write across tenants. This guide covers enabling it, the built-in accounts/memberships/
invitations collections, how the active account is resolved, the `@request.account` rule macros,
and the explicit escape hatch for cross-tenant tooling.

```zig
zigbase.App(.{
    .tenancy = .{
        .enabled = true,
        .resolver = .header,          // read the active account from X-Account-Id / the zb_account cookie
        .auth_collection = "users",   // the auth collection whose records are members
        .roles = .{ "viewer", "editor", "admin", "owner" }, // optional; this is the default ladder
    },
    .collections = .{
        .projects = .{
            .fields = .{
                .{ .name = "title",   .type = .text },
                .{ .name = "account", .type = .text },   // holds the owning account id
            },
            .tenant_field = "account",                   // <- makes `projects` tenant-owned
            .rules = .{ .list = "@public", .view = "@public" },
        },
    },
});
```

## What tenancy gives you

Every read, write, and realtime delivery of a tenant-owned collection is bound to the request's
active account, fail-closed — no matching account context means no visibility into that
collection's rows, full stop. You do not write `account = @request.account.id` on every rule by
hand; the tenant scope is composed into the guard stack automatically. A client can never read or
write across tenants, even through a `@public` rule, an `expand`, or a realtime subscription.

Tenants still share **capacity**, and two documented side channels follow from it. Neither reveals
content, record ids or which tenant wrote:

- **Realtime backfill retention** (opt-in, `-Drealtime-backfill=true` or `-Ddurable-realtime=true`).
  Retained invalidations are bounded per collection (local store) or globally (durable journal), not
  per tenant. One tenant's write volume can evict the entries another tenant's checkpoint depends on,
  and that tenant's next `GET /api/realtime/backfill` answers `409 resetRequired`; the `409` tells it
  the collection (local) or the journal (durable) received more than its retention budget since its
  checkpoint (or, durable only, that retention expired). A tenant can force these resets at will by writing past the budget.
- **Response time.** A backfill request authorizes every retained entry it scans, including other
  tenants', so its latency grows with their write volume.

Backfill items, `hasNext`, page count and cursors do not depend on other tenants' writes (cursors are
encrypted; `limit` counts authorized items). See [API → Realtime](api.md#durable-record-invalidation-replay-sqlite-and-postgresql)
for the budgets and the one build-time exception (`-Dreplay-max-entries` above 4096).

## Enable it

Turn tenancy on at the top level of `App(.{ ... })`, then mark each owned collection's
owning-account column with `.tenant_field`:

```zig
zigbase.App(.{
    .tenancy = .{
        .enabled = true,
        .resolver = .header,          // read the active account from X-Account-Id / the zb_account cookie
        .auth_collection = "users",   // the auth collection whose records are members
        .roles = .{ "viewer", "editor", "admin", "owner" }, // optional; this is the default ladder
    },
    .collections = .{
        .projects = .{
            .fields = .{
                .{ .name = "title",   .type = .text },
                .{ .name = "account", .type = .text },   // holds the owning account id
            },
            .tenant_field = "account",                   // <- makes `projects` tenant-owned
            .rules = .{ .list = "@public", .view = "@public" },
        },
    },
});
```

`.tenant_field` names the column on `projects` that holds the owning account id — that's what makes
`projects` tenant-owned. Collections without `.tenant_field` are untouched by tenancy.

## Relations into a tenant-owned collection

A relation field whose **target** is tenant-owned only accepts ids of records in the request's
active account. On a create or update over HTTP, an id that belongs to another account is rejected
exactly like an id that was never minted: `400` with `validation_not_found` on that field, the same
body and the same single indexed lookup. This holds for single and multi relations, and whether or
not the collection holding the relation is itself tenant-owned. So a client cannot use the relation
check to confirm another tenant's record ids, and it cannot store a link that the other tenant's own
delete would then follow into its rows (`cascadeDelete` deletes the linking row; otherwise the link
is set to `null`).

On an **update**, only ids the request adds are checked against the active account. Ids the row
already stores in that field are accepted as they are, so a client that sends the whole record
back (an SDK save, a full-array `PATCH` of a multi relation) does not fail on a link it did not
add — it can already read those ids, so re-sending them confirms nothing. Adding a new
other-account id next to them, or switching a single relation to one, is still rejected.

The check runs on the values the write will store, **after** `before_create` / `before_update`
hooks. A hook that sets a relation to another account's record therefore gets the same `400` as a
client would. A hook that must link across accounts writes through `ctx.records()`, which carries
no request scope.

Only the target's tenant scope is applied — not its `viewRule` or abilities — so a target that is
not tenant-owned (a shared `users` collection, say) stays referenceable by id from any account.
Superusers and `crossTenant` contexts bypass the check, as do server-side writes that carry no
request scope: `ctx.records()` in hooks, routes and jobs, migrations, and imports. Links already
stored across accounts (before this check existed, or written by one of those bypasses) are left in
place; `zigbase doctor` reports them under `cross-tenant-relations`, one finding per relation field
([serve.md §8](./serve.md#8-zigbase-doctor)). A row whose tenant value is NULL or empty belongs to
no account and is not counted on either side of a link. On both SQLite and PostgreSQL, each
multi-relation field uses one aggregate statement over the source rows to count cross-tenant
links and non-empty values that cannot be examined as JSON arrays together.

## Accounts, memberships, invitations

Enabling tenancy provisions three built-in system collections (visible in `_collections`,
`system = 1`):

- `_accounts` — one row per tenant.
- `_memberships` — the principal↔account edge, carrying a `role` and `status`.
- `_invitations` — pending invites (the invite/accept/remove lifecycle ships separately from the
  tables themselves).

Roles form a total order, defaulting to `viewer < editor < admin < owner`, configurable via
`.tenancy.roles`.

For browsers, `POST /api/accounts/:id/activate` verifies membership and sets a signed, HttpOnly
`zb_account` cookie, so a SPA selects an account once instead of sending `X-Account-Id` on every
call. API clients can skip this and just send the header.

## Selecting the active account

On each request the active account is resolved from the `X-Account-Id` header (or the signed
`zb_account` cookie) and verified against an **active** `_memberships` row for the authenticated
principal — one indexed lookup, cached on the request. No membership, an invalid account id, or an
inactive membership all resolve to **no account context**, and tenant-owned data is invisible —
resolution fails closed, never open.

## Rules with @request.account

A successful resolution fills three rule macros:

- `@request.account.id` — the active account's id.
- `@request.account.role` — the principal's role within that account.
- `@request.account.ids` — the list-valued set of account ids the principal is an active member of
  (usable as the `in` operator's source).

These are illustrative — most tenant-owned collections don't need to reference them directly, since
`.tenant_field` already scopes reads and writes. A rule that does want to reference the active
account explicitly might look like:

```
viewRule = "@request.account.id != \"\" && account = @request.account.id"
```

Adapt the shape to your collection; treat this as a starting point, not a fixed template.

## Escaping the scope

Superusers bypass tenancy entirely, consistent with the rest of the access-rule engine. For admin
tooling that must legitimately span accounts — an ops dashboard, a maintenance job —
`zigbase.crossTenant(rctx)` returns a context with the override enabled. It is the *explicit,
never-silent* way to widen scope; nothing crosses tenant boundaries implicitly.

## Reference

- [Multi-tenancy reference](./framework.md#multi-tenancy--account-scoped-collections-tenancy--tenant_field)
- [Relationship abilities](./abilities.md)
- [Access rules](./api.md#access-rules)
