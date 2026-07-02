---
title: Relationship abilities
description: Per-collection, per-action authorization by the principal's relationship to the row — declaring abilities, ctx.can, and the abilities endpoint.
order: 3
group: features
---

# Relationship abilities

Access rules authorize a record by evaluating its own columns. **Abilities** go further: they
authorize a CRUD action by the principal's *relationship* to the row — "you may edit a project if
you are an `editor` (or higher) of the account it belongs to" — without hand-writing that
membership join in every rule. This guide covers declaring abilities, how they compose with rules
and tenancy, checking them from code, and the introspection endpoint.

## Rules vs abilities

A rule expression evaluates the row's own columns (`status = "published"`, `owner = @request.auth.id`).
An ability instead authorizes by the principal's **relationship** to the row — their membership and
role in the account the row belongs to. Abilities are composed alongside rules, not instead of them:
both must pass.

## Declare an ability

Abilities are declared at the top level of `App(.{ … })`, keyed by collection name, with a per-action
relationship rule:

```zig
const App = zigbase.App(.{
    .tenancy = .{ .enabled = true, .auth_collection = "users",
                  .roles = .{ "viewer", "editor", "admin", "owner" } },
    .collections = .{
        .projects = .{
            .fields = .{
                .{ .name = "title",   .type = .text },
                .{ .name = "account", .type = .relation, .target = "accounts" }, // owning account
            },
            .rules = .{ .list = "@public", .view = "@public" },
        },
    },
    // A row of `projects` is authorized when the principal holds a membership (role ≥ floor) of the
    // account named by the `account` relation field.
    .abilities = .{
        .projects = .{
            .view   = .{ .relationship = .{ .via = "account" } },               // any active member
            .update = .{ .relationship = .{ .via = "account", .min_role = .editor } },
            .delete = .{ .relationship = .{ .via = "account", .min_role = .admin } },
            .create = .{ .relationship = .{ .via = "account", .min_role = .editor } },
        },
    },
});
```

`.via` must name a relation field on the collection — the field whose column holds the owning
account id. `.min_role` filters through the configured role ladder (`.tenancy.roles`); omitting it
means any active member qualifies. `list` reuses the `view` ability.

## How they compose

Each ability compiles to a bound `IN` predicate over the principal's qualifying membership
account-ids, AND-ed into the same guard stack as the access rule and the tenant scope, on every
chokepoint: `WHERE (filter) AND (rule) AND (ability) AND (tenant_field = ?) AND (ttl)`. That
includes view/create/update/delete, `expand`, realtime delivery, and the bulk **list** endpoint —
an ability forces a per-row check even when the access rule alone would allow everything, so a
`.rules.list = "@public"` collection with a view ability returns the **ability-narrowed** set (HTTP
200), not every row and not a 400.

**Fail closed.** No qualifying membership resolves to the constant-false predicate, denying the
row — never SQLite's invalid `IN ()`. A locked rule (`null`/`""`) still denies first. Account ids
are always bound parameters, never interpolated; superusers bypass abilities entirely.

**Comptime validation.** An ability naming an unknown collection, a `.via` that isn't a relation
field, or a `.min_role` outside `.tenancy.roles` is a `@compileError`. `.abilities` also requires
`.tenancy.enabled = true` — abilities authorize by account membership, which only resolves under
tenancy — so configuring abilities with tenancy disabled is a `@compileError` rather than a silent
deny-all at runtime.

## Check from code

From a custom route, `try ctx.can(.update, "projects", id)` authorizes a specific record through
the same policy (rule + ability + tenant scope) the REST chokepoints use — reach for it instead of
re-implementing the check by hand.

To introspect what the current principal may do with a record, `GET
/api/collections/:col/records/:id/abilities` returns a JSON object of booleans, e.g. `{"view":
true, "update": false, "delete": false}`. The endpoint itself requires view access (404 otherwise),
so it never leaks a record's existence — `"view"` is therefore always `true` on a 200 response.

## With tenancy

Abilities resolve through account membership, which only exists once tenancy is enabled — that's
why `.abilities` requires `.tenancy.enabled = true`. Superusers bypass abilities entirely, the same
as they bypass tenancy and rules. A collection with no `.abilities` entry composes a null
predicate, so its decisions and compiled SQL are byte-identical to the pre-abilities engine —
adding abilities elsewhere in your app never changes an unrelated collection's behavior.

## Reference

- [Abilities reference](./framework#relationship-based-row-abilities-abilities)
- [Multi-tenancy guide](./tenancy)
- [Access rules](./api#access-rules)
