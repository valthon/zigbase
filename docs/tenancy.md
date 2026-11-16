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

## Unique fields are per tenant

On a tenant-owned **base** collection, a field marked `unique` is unique **within each tenant**, not
across the table. The engine enforces it as a composite `UNIQUE (<tenant_field>, <field>)`
constraint, so tenant A can create a `slug` of `acme-corp` while tenant B already holds one, and
A's second `acme-corp` is still refused with `409`. A table-wide constraint would have answered
`409` whenever *any* tenant held the value: one request per guess would tell a member of one
tenant what another tenant has stored, and any tenant could claim a value for good.

The tenant field itself, if you mark it `unique`, stays unique across the table (there is nothing
to scope it by).

When a value really must be unique across every tenant, say so with an explicit unique index:

```zig
.slugs = .{
    .fields = .{
        .{ .name = "slug",    .type = .text, .required = true, .unique = true }, // per tenant
        .{ .name = "account", .type = .text },
    },
    .tenant_field = "account",
    // Table-wide: a 409 here does reveal that some tenant holds the value. Choose it knowingly.
    .indexes = .{ .{ .name = "idx_slugs_slug_global", .fields = .{"slug"}, .unique = true } },
},
```

Existing deployments are converged at startup. A tenant-owned base table created by an earlier
release still carries the table-wide constraint; on the next start the server replaces it with the
per-tenant one, for collections declared in `.collections` and for collections created through
the collections API alike. Dropping a unique constraint only loosens it and the per-tenant
constraint holds wherever the table-wide one did. SQLite refuses unsupported physical schema
drift before rebuilding (see below).
PostgreSQL swaps the constraints in place. SQLite cannot drop a column constraint, so it rebuilds
the table once, keeping every row and re-creating any index or trigger a migration had put on it.
The same rules apply when a collection becomes tenant-owned later, or stops being one: changing
its `tenant_field` moves its unique fields to the matching enforcement.

Tenant-scoped import upserts (`--upsert-key` on a tenant-scoped unique field) match the
**tenant field plus the key**, and require a non-empty tenant string on every input row.
A value held only by another tenant creates a new row; it never updates or moves that row.

SQLite refuses a rebuild if physical columns or table constraints cannot be reproduced from
collection metadata. The boot error names the column or unsupported clause. For example, a
migration-added `internal_note` column must be incorporated into collection metadata (or handled
by an explicit migration) before restarting. This applies when adding or changing `tenant_field`
too. Migration-owned indexes and triggers are restored transactionally; if restoration fails,
the rebuild rolls back.

Index and trigger ownership is determined by comparing stored SQL with the SQL generated for
the old collection definition, collapsing whitespace outside quoted values and comments. Engine objects
(including tenant and identity indexes and search triggers) are regenerated from the new
definition; other objects retain their migration SQL, even when they use an engine-style name.
A migration object that mentions a renamed or dropped column causes a 400 response naming the
object and column before destructive DDL. A collision with a new engine object, or a migration
reference to a search table (including FTS shadow tables) being removed, also refuses the update.
Incoming foreign keys targeting non-`id` columns, and external views or triggers referring to the
rebuilt table or its search tables, require an explicit migration and are refused before DDL.
An attached TEMP trigger also refuses a rebuild before DDL; migrate it explicitly on the
same connection first. SQLite object-name collisions are checked without case sensitivity across the entire database,
including indexes attached to other tables. Migrate those objects explicitly first; ambiguous SQL identifier references are treated
conservatively as dependencies.

Auth collections are excluded from unique-scope convergence at startup and on API updates.
Their uniqueness behavior is unchanged from before this change: configured `identityFields`
receive global partial unique indexes over non-empty values, and declared unique fields stay
global. With the default `["email"]` identity, this change adds no username uniqueness;
existing duplicate non-empty usernames remain accepted. Adding `tenant_field` does not opt
an auth collection into per-tenant uniqueness.

OpenAPI exposes `x-zigbase-unique-scope` (`tenant` or `global`) beside `x-zigbase-unique`;
tenant scope also includes `x-zigbase-unique-tenant-field`. The admin schema editor shows
“per tenant (<field>)” or “global” beside the uniqueness checkbox. Explicit indexes may impose
additional uniqueness constraints independently of these field hints.

## Escaping the scope

Superusers bypass tenancy entirely, consistent with the rest of the access-rule engine. For admin
tooling that must legitimately span accounts — an ops dashboard, a maintenance job —
`zigbase.crossTenant(rctx)` returns a context with the override enabled. It is the *explicit,
never-silent* way to widen scope; nothing crosses tenant boundaries implicitly.

## Reference

- [Multi-tenancy reference](./framework.md#multi-tenancy--account-scoped-collections-tenancy--tenant_field)
- [Relationship abilities](./abilities.md)
- [Access rules](./api.md#access-rules)
