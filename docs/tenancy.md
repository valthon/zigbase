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
