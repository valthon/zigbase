> 📖 This documentation is also published, web-native, at <https://valthon.github.io/zigbase/docs/postgres> — the site is the canonical reading experience.

# PostgreSQL backend

ZigBase defaults to embedded SQLite — the single-binary story. When you need several app
instances sharing one database, or you'd rather operate a managed Postgres than a file on disk,
an opt-in pure-Zig **PostgreSQL backend** is available behind a build flag. This guide covers
building it in, pointing a server at a Postgres URL, moving existing SQLite data over, and the
cross-instance realtime and vector-search behavior that come with it.

```sh
zig build -Dpostgres=true
export ZIGBASE_DB_URL="postgres://user:pass@host:5432/db?sslmode=require"
./zig-out/bin/zigbase serve
```

## When to reach for Postgres

SQLite remains the default and the only backend in a stock build — it's the right choice for a
single-process deployment and needs no external service. Reach for Postgres when you're running
**multiple app instances against one shared database**: a managed Postgres gives you the
operational story (backups, replicas, connection pooling) a fleet of processes needs, and
ZigBase's realtime layer automatically fans record-change events across instances over Postgres
`LISTEN`/`NOTIFY` when it's the active backend — no extra configuration. If you're running a
single process, SQLite stays simpler and just as capable.

## Build with -Dpostgres

The PostgreSQL backend is off by default and compiled in with:

```sh
zig build -Dpostgres=true
```

The driver is **pure Zig** — TLS via `std.crypto.tls.Client`, SCRAM-SHA-256 via `std.crypto` —
so there is no libpq, no C, and no OpenSSL to link. When the flag is off, the entire
`src/backend/postgres/` subtree is comptime-unreachable, so the default build links zero new
symbols and stays byte-identical.

**Release tarballs are stock SQLite-only builds.** The published GitHub release artifacts are
built without `-Dpostgres` — to run ZigBase on Postgres you build from source with the flag
above.

## Point at a database

With a `-Dpostgres` binary, set `ZIGBASE_DB_URL` to a `postgres://` URL to select Postgres at
startup; any other value (or an unset var) keeps SQLite:

```sh
export ZIGBASE_DB_URL="postgres://user:pass@host:5432/db?sslmode=require"
```

The backend is chosen once, by connection string alone: switch via configuration, no code changes.

> **Caveat — TLS does not yet verify the server.** `sslmode=require` encrypts the connection but
> does **not** verify the server certificate or hostname (`verify-ca`/`verify-full` are rejected).
> Run the Postgres backend only over a trusted network path for now; certificate verification is
> a tracked follow-up. This is new in 0.9.0.

A **stock (`-Dpostgres=false`) binary** handed a `postgres://` `ZIGBASE_DB_URL` does not silently
write to local SQLite instead — it logs a prominent warning and falls back to SQLite, so a
misconfigured deployment is visible rather than quietly misdirecting data.

See the full environment-variable reference at
<https://valthon.github.io/zigbase/docs/configuration#database-backend-experimental>.

## Migrate an existing SQLite instance

Once you have a `-Dpostgres` binary, the `migrate-db` subcommand copies an existing SQLite-backed
instance — schema **and** data — into a fresh PostgreSQL database:

```sh
zigbase migrate-db \
  --from ./data.db \
  --to "postgres://user:pass@db.example.com:5432/zigbase?sslmode=require"
```

It provisions the equivalent schema on the target (including collections created at runtime, not
just comptime ones), then **bulk-loads every row atomically** — the whole load runs in one
transaction, so a mid-migration failure rolls the target back to a clean, empty-of-data state
rather than leaving it half-populated. `.encrypted` field envelopes are copied byte-for-byte with
no key needed — encrypted cells are backend-neutral `vN:<base64>` TEXT envelopes, and `migrate-db`
never decrypts or re-encrypts them, so the same `ZIGBASE_FIELD_KEY` that read the SQLite data
reads it on Postgres afterward. `.searchable` metadata is preserved too, so Postgres full-text
search works against the migrated data the first time you `zigbase serve` against it.

> **Caveat — FK suspension needs a superuser target role.** The loader tries to suspend foreign-key
> enforcement on the target for the duration of the load, which requires a Postgres superuser role.
> A non-superuser target role falls back to a lightly-tested topological load ordering instead —
> prefer a superuser target role for this one-time migration where you can.

A non-empty target is refused unless you pass `--force`, and the command reports per-table row
counts measured on the target, failing loudly (and rolling back) if any count doesn't match the
source.

## Realtime across instances

Realtime delivery is normally in-process: a write publishes to a pub/sub bus inside the writing
instance. When several instances share one Postgres database, ZigBase additionally fans
record-change events across instances over Postgres `LISTEN`/`NOTIFY` — a write on instance A
reaches subscribers connected to instances B and C. This is **automatic** when Postgres is the
active backend, with no configuration: each instance runs a dedicated listener connection that
**auto-reconnects with backoff** (logging loudly) if it drops during a restart or failover, and
runs its own per-subscriber `viewRule`/ability/tenant authorization before delivering.

The notification payload carries **no row data** — only `{origin, collection, action, id}`.
Create/update events re-fetch the live row on the receiving instance; a delete carries an opaque
random token that keys the deleted row's snapshot in a small server-side table
(`_rt_delete_snapshots`), which the receiver reads back over its own connection. This is
deliberate: putting the deleted row in the `NOTIFY` payload would broadcast its column data —
including the decrypted plaintext of `.encrypted` fields — to any DB role that can `LISTEN`, so
the snapshot stays at-rest (ciphertext) in the side table and never transits the wire. On SQLite
(single-process) nothing changes — there is no cross-process step and no side table.

## Vector search with pgvector

Vector/nearest-neighbor search is the same opt-in feature on both backends, gated by a single
build flag:

```sh
zig build -Dvector=true
```

```text
GET /api/collections/docs/records?vector=embedding:cosine:[0.12,0.04,...]
```

On SQLite this vendors and links `sqlite-vec`; on Postgres it emits the equivalent
[pgvector](https://github.com/pgvector/pgvector) lowering and runs `CREATE EXTENSION IF NOT
EXISTS vector` at startup, so the target PostgreSQL needs pgvector available (e.g. the
`pgvector/pgvector:pgNN` image). If the connecting role lacks privilege to create the extension,
install it once as a superuser (`CREATE EXTENSION vector;`) — startup then logs a warning and
continues rather than aborting. In a build without `-Dvector`, a `?vector=` query fails closed
with a clean **400** on either backend.

## Writing cross-backend migrations

`*zigbase.Migrator` is pass-the-dialect, not an SQL transpiler. The common case is
`m.execLowered(sql)`: write the statement in the SQLite flavor and the dialect lowers the
portable SQLite-isms (`INTEGER`→`BIGINT`, `INSERT OR IGNORE`→`ON CONFLICT DO NOTHING`, and so on)
on Postgres, while SQLite runs it byte-identical:

```zig
pub fn up(m: *zigbase.Migrator) !void {
    try m.execLowered("ALTER TABLE \"posts\" ADD COLUMN \"views\" INTEGER NOT NULL DEFAULT 0;");
}
```

For the rare statement that genuinely differs per backend, `m.exec(sql)` runs raw backend-specific
SQL verbatim (you own dialect correctness — SQLite-only SQL fails loud at startup on Postgres),
and `m.dialect.kind` (`.sqlite` / `.postgres`) or `m.rawFor(.postgres, sql)` let a migration branch
explicitly. A SQLite-only consumer that never builds with `-Dpostgres` keeps working unchanged.

## Reference

- [Cross-backend migrations](./framework.md#cross-backend-migrations-sqlite-and-postgres)
- [migrate-db](./framework.md#migrating-an-existing-sqlite-instance-to-postgres-migrate-db)
- [Multi-instance realtime](./framework.md#multi-instance-realtime-postgres)
- [Schema in code (§8)](./framework.md#8-define-your-schema-in-code-collections--migrations)
- [Search & vector queries](./api.md#search)
- [Configuration — database backend](https://valthon.github.io/zigbase/docs/configuration#database-backend-experimental)
