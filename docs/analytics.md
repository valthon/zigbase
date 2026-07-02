> 📖 This documentation is also published, web-native, at <https://valthon.github.io/zigbase/docs/analytics> — the site is the canonical reading experience.

# Product analytics

ZigBase has built-in product analytics: capture immutable events from any hook, route, or job
with a single call, roll them up into summary tables on a schedule, and read both back through a
tenant-scoped, fail-closed API. No `.analytics` config is required to start capturing — rollups
are an opt-in layer on top.

## Track an event

From any hook, route, or job, append one immutable event to the built-in `_events` collection:

```zig
fn afterSignup(ctx: *zigbase.Ctx, ev: *zigbase.RecordEvent) anyerror!void {
    try ctx.track("user.signup", .{ .plan = "pro" });
}
```

The `actor` / `actor_collection` (the authenticated principal), the `account` (the request's
active tenant scope, `""` when tenancy is off), and the `occurred_at` timestamp are all resolved
**server-side** — a client cannot forge any of them. `payload` is any JSON-serializable value,
stored as opaque JSON text (a `[]const u8` is taken as raw JSON). It is a single cheap INSERT;
inside a hook / `ctx.tx` it reuses the in-transaction connection. Events are immutable appends —
there is no update or delete.

## Roll events up

Declare named rollups; each registers one job on the existing scheduler that aggregates
`_events` into a `_rollup_<name>` summary table:

```zig
const App = zigbase.App(.{
    .analytics = .{
        .rollups = .{
            .signups_daily = .{
                .event = "user.signup",
                .every = .{ .interval = .hourly },          // a cron/interval Schedule
                .group_by = .{ .account = true, .time_bucket = .day },
                .metric = .count,
            },
        },
    },
});
```

`.group_by` keys: `.account` / `.actor` (bools) and `.time_bucket` (`.none` / `.day` / `.hour`).
`.metric` is `.count` (default). Aggregation is **incremental and idempotent**: a persisted
watermark (in `_kv`) tracks the monotonic `_events.rowid` already aggregated, and each run
aggregates the disjoint window `watermark < rowid <= max_rowid`. Because the watermark is the
rowid (not the timestamp) and the job holds the exclusive writer for the pass, a run **neither
double-counts nor drops** — even an event inserted in the same wall-clock second as a prior run
still has a strictly-greater rowid and is counted next pass. Summary-table / column identifiers
are gated through `schema.isValidIdentifier`. Misconfiguration fails **loudly at compile time** —
an unknown `.group_by`/`.metric`, a missing or empty `.event`, or a rollup name that is not a
valid identifier is a `@compileError`.

## Read it back

Both endpoints are **authenticated and fail closed**:

- `GET /api/analytics/events?name=&actor=&since=&limit=` — the raw activity feed (newest first).
  Filters: `name` (exact event name), `actor` (exact principal id), `since` (an ISO-8601 lower
  bound on `occurred_at`), `limit` (default 50, max 200).
- `GET /api/analytics/rollups/:name?from=&to=` — a rollup's summary rows. `:name` must be a
  **declared** rollup (else `404`, no table-name oracle). Filters: `from` / `to` bound the
  `bucket` value. Each row is `{ bucket, account, actor, value, computed_at }`; columns absent
  from the rollup's `group_by` are the empty string. The summary table is created on the first
  scheduled run — until then the endpoint returns `{ "items": [] }`.

A **superuser** sees everything; a **member** sees only their **active account's** data (resolved
from a verified `_memberships` row, the same path the records chokepoints use); with tenancy
**disabled** the feed is scoped to the caller's own events and a (global) rollup is
**superuser-only** (`403`). A member can never read another account's events or rollups; an
anonymous request gets `401` (the rollups handler authenticates **before** the rollup-name
lookup, so 401-vs-404 never leaks which rollup names exist).

> **Visibility is account-level, not role-level.** Any *active member* of an account — whatever
> their role — can read the **entire** account's event feed (including other members' events and
> payloads) and all of its rollup buckets. The trust boundary is the tenant, not the role; there
> is deliberately no intra-account role gating. Treat event payloads as readable by every member
> of the account.

## Using it standalone

No `.analytics` config is needed for capture. With no `.analytics` config the `_events` table is
still seeded (harmless) but no rollup job is scheduled, and `ctx.track` works standalone —
rollups are the opt-in layer.

## Reference

- [Product analytics reference](./framework.md#product-analytics-analytics--ctxtrack)
- [Analytics API](./api.md#analytics)
