> 📖 This documentation is also published, web-native, at <https://valthon.github.io/zigbase/docs/search> — the site is the canonical reading experience.

# Full-text & vector search

ZigBase has first-class search on the list endpoint: ranked `?search=` queries over fields you
mark `searchable`, plus an opt-in `-Dvector` build for embedding KNN. Search is never a
separate, unscoped query — it composes with the same `filter` + rules + tenant scoping as every
other list request, so it can never widen visibility.

## Make a field searchable

Mark one or more `text`/`editor` fields `.searchable` in the schema:

```zig
.posts = .{ .fields = .{
    .{ .name = "title", .type = .text,   .searchable = true },
    .{ .name = "body",  .type = .editor, .searchable = true },
} },
```

ZigBase provisions the index automatically — no migration needed — at startup for comptime
collections, and in the same transaction as the schema change when a collection is created,
updated or deleted through the collections API or the admin UI. Making a field searchable
backfills the index from the existing rows; adding, removing or renaming a searchable field
rebuilds it. Replacing a searchable field with a new field ID also rebuilds the index, even
when its name stays the same; the replacement discards that field's old values. Turning
search off or deleting the collection drops the index. If the index cannot be
built (for example a conflicting object named `<col>_fts`), the whole schema change fails
and nothing is applied. On **SQLite** (the
default backend) that's an [FTS5](https://www.sqlite.org/fts5.html) **external-content** index
per searchable collection (`"<col>_fts"`, `content='<col>'`) plus `INSERT`/`UPDATE`/`DELETE`
triggers that keep it in lock-step with the base table — no doubled storage. On **Postgres**
it's a `STORED` `tsvector` **generated column** (`to_tsvector('simple', …)` over the searchable
columns) plus a **GIN index**. `searchable` is mutually exclusive with `encrypted` — ciphertext
is not searchable.

Startup reconciles only search objects whose catalog definitions prove they belong to
ZigBase. A conflicting application table, column, index, trigger, or dependent object
causes `Conflict` before search DDL; its data is preserved, even when the collection
has no searchable fields. Proven engine indexes still support searchable-field changes,
removal, and missing-index repair. Reconciliation is transactional.

Additive provisioning validates existing search objects before changing fields,
then reconciles search after the new columns exist. The search reconciliation is
transactional; this does not make the entire collection provision operation atomic.
PostgreSQL resolves search tables only in the current schema, matching the registry
schema when a registry exists. A conflicting temporary validation-probe relation
is rejected without replacing it. Because runtime trigger functions can refer to
generated columns without catalog dependencies, PostgreSQL refuses to remove or
replace a search column while the table has user triggers. Unchanged search and
missing-GIN-index repair remain supported; explicitly migrate affected triggers
before changing the searchable field set.
SQLite external-content search operands must still exist as text-storage columns
in the physical base table; a missing or non-text operand requires explicit repair
before its search objects can be adopted or removed.

Reserve `<col>_fts` and its suffixed object names for the engine. PostgreSQL ownership
also requires the engine's `zbfts:` column comment and matching generated expression.
Legacy unmarked columns are no longer automatically deleted: inspect and back up the
object, then explicitly migrate or rename conflicting application objects before retrying
startup. Do not attach an ownership marker to an unverified column.

## Build requirement (`-Dfts5`, default on)

SQLite FTS5 is compiled in **by default** — it's a core feature, not an experiment. Lean custom
builds that never declare a `.searchable` field can drop it with `-Dfts5=false` (~250-400 KB
smaller binary); every FTS5 code path in `src/search/fts.zig` folds to comptime-dead. With
`-Dfts5=false`, a `?search=` request answers a clean **400** (`"Full-text search is not enabled
in this build."`), and — more importantly — **the server refuses to start** if the comptime
schema declares any `.searchable` field on the SQLite backend, with an actionable startup error,
rather than silently skipping the index and surfacing a 500 on the first search. For the same
reason the collections API answers **400** to a create or update that would make a field
searchable in such a build, and changes nothing. Postgres
full-text search (the `tsvector`/GIN path above) is a server-native feature and is **not** gated
by this flag.

## Query it

Query with `search` (or its alias `q`):

```text
GET /api/collections/posts/records?search=zig%20database
GET /api/collections/posts/records?q=alpha%20OR%20beta&filter=published=true
```

Results are ranked by relevance in offset mode, highest first, with equal scores ordered by
record `id`. Cursor mode keeps its keyset order (relevance does not apply there). See
[Ranking](#ranking) for the formulas. On SQLite, terms
support the basic FTS5 operators (`AND`, `OR`, `NOT`, and a trailing `*` for prefix search); on
Postgres, `plainto_tsquery` parses the plain term and does not honor those operators. A `search`
whose terms reduce to nothing (e.g. operator-only, `?search=AND`) matches **no rows** rather than
returning the whole collection. A `search` on a collection with no `searchable` field returns
**400**. The `_fts` collection-name suffix is reserved (it backs the per-collection shadow
tables).

## Ranking

Every score is computed from **the row's own text and the query only** — never from other rows of
the collection. That matters for multi-tenant apps: one search index (the SQLite FTS5 shadow
table, or the Postgres column) holds every tenant's rows, so a corpus-wide score such as FTS5's
`bm25` (inverse document frequency, average row length) would let one tenant's result *order*
depend on text other tenants stored. A member could then rank two of their own records and learn,
one bit per query, whether another tenant's text contains a word. ZigBase does not use such a score.

- **SQLite** ranks with `zb_rank`, an FTS5 auxiliary function ZigBase registers on each connection
  that runs a search:

  ```text
  score = ( Σ_p  tf_p / (tf_p + 1) ) / log2(1 + L)
  ```

  `p` ranges over the query's terms (each token is one FTS5 phrase; a prefix term `abc*` counts
  its matching tokens), `tf_p` is how many times term `p` occurs in the row (0 when the row matches
  through another `OR` branch), and `L` is the row's token count across its searchable fields.
  Each term's contribution saturates (1 hit → 0.5, 2 → 0.67, 3 → 0.75), so a row matching more
  distinct terms outranks one repeating a single term at comparable length. At equal length, more
  hits rank higher; at equal hits, a shorter (denser) row ranks higher. All searchable fields
  weigh the same.
- **Postgres** ranks with `ts_rank(<tsvector>, plainto_tsquery('simple', <term>)) DESC`, which
  also reads only the row's own `tsvector`.

Both backends score each row from that row alone, but their scores are not numerically equal: `ts_rank` (default normalization) does not divide by row length, and for a
multi-word query it weighs how close the words are to each other. Rows can therefore tie on one
backend and not the other, or swap places. Both backends break ties by `id`, so the order never
depends on insertion order or on other rows. The matched rows can differ too: only SQLite
interprets the FTS5 operators (`OR`, `NOT`, a prefix `*`), which PostgreSQL's `plainto_tsquery`
treats as plain words or drops, and SQLite's `unicode61` tokenizer folds diacritics (`café`
matches `cafe`) where PostgreSQL's `simple` configuration does not.

One documented residual remains: on SQLite, `MATCH` still walks every tenant's postings for the
query terms before the tenant predicate filters them, so a search's *latency* (never its order or
results) can grow with how many of other tenants' rows match.

## Compose with filters and rules

The search predicate is AND-ed into the *same* composed `WHERE` as your `filter`, the list rule,
abilities, and tenant scope — **search can never widen visibility**. A search of a tenant-owned
or ability-guarded collection returns only the rows the caller may already view, and their order
does not depend on rows the caller cannot see ([Ranking](#ranking)). The whole term
is passed as a **bound parameter** (never interpolated) and lowered to a guaranteed-valid query,
so a malformed input is harmless — it can never become a SQL error or injection. This composed
scoping is identical on both backends.

## Vector search (opt-in)

Vector search is **not** compiled into the default binary. The single `-Dvector=true` flag
enables KNN on **both** backends — on SQLite it vendors and links
[`sqlite-vec`](https://github.com/asg017/sqlite-vec) (registered on every connection); on
Postgres it emits the [pgvector](https://github.com/pgvector/pgvector) lowering. It enables KNN
ordering over a field that stores a JSON embedding array:

```text
GET /api/collections/docs/records?vector=embedding:cosine:[0.12,0.04,...]
GET /api/collections/docs/records?vector=embedding:l2:[0.12,0.04,...]&filter=lang="en"
```

The form is `<field>[:cosine|:l2]:<json-embedding>` (cosine is the default metric); rows are
ordered nearest-first. The embedding is validated (a non-empty JSON array of finite numbers) and
bound; a malformed or dimension-mismatched embedding returns a clean **400**. Vector search runs
in offset mode (cursor paging is rejected with 400). **In the default build a `vector` query
returns 400** (`"Vector search is not enabled in this build."`), and the binary is
byte-for-byte unaffected. The same composed-`WHERE` scoping (filter + list rule + abilities +
tenant) applies to vector queries exactly as it does to `?search=` — identically on both
backends.

## Reference

- [Search API](./api.md#search)
- [Field types & the searchable flag](./fields.md)
- [Schema in code (§8)](./framework.md#8-define-your-schema-in-code-collections--migrations)
- [PostgreSQL guide — pgvector](./postgres.md)
