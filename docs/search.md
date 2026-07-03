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

At startup ZigBase provisions the index automatically — no migration needed. On **SQLite** (the
default backend) that's an [FTS5](https://www.sqlite.org/fts5.html) **external-content** index
per searchable collection (`"<col>_fts"`, `content='<col>'`) plus `INSERT`/`UPDATE`/`DELETE`
triggers that keep it in lock-step with the base table — no doubled storage. On **Postgres**
it's a `STORED` `tsvector` **generated column** (`to_tsvector('simple', …)` over the searchable
columns) plus a **GIN index**. `searchable` is mutually exclusive with `encrypted` — ciphertext
is not searchable.

## Build requirement (`-Dfts5`, default on)

SQLite FTS5 is compiled in **by default** — it's a core feature, not an experiment. Lean custom
builds that never declare a `.searchable` field can drop it with `-Dfts5=false` (~250-400 KB
smaller binary); every FTS5 code path in `src/search/fts.zig` folds to comptime-dead. With
`-Dfts5=false`, a `?search=` request answers a clean **400** (`"Full-text search is not enabled
in this build."`), and — more importantly — **the server refuses to start** if the comptime
schema declares any `.searchable` field on the SQLite backend, with an actionable startup error,
rather than silently skipping the index and surfacing a 500 on the first search. Postgres
full-text search (the `tsvector`/GIN path above) is a server-native feature and is **not** gated
by this flag.

## Query it

Query with `search` (or its alias `q`):

```text
GET /api/collections/posts/records?search=zig%20database
GET /api/collections/posts/records?q=alpha%20OR%20beta&filter=published=true
```

Results are ranked by relevance in offset mode — `bm25` on SQLite, `ts_rank(…) DESC` on Postgres.
The exact relevance order can differ between the two ranking functions (FTS5 `bm25`
length-normalizes; `ts_rank` does not), but the matched set is equivalent. On SQLite, terms
support the basic FTS5 operators (`AND`, `OR`, `NOT`, and a trailing `*` for prefix search); on
Postgres, `plainto_tsquery` parses the plain term and does not honor those operators. A `search`
whose terms reduce to nothing (e.g. operator-only, `?search=AND`) matches **no rows** rather than
returning the whole collection. A `search` on a collection with no `searchable` field returns
**400**. The `_fts` collection-name suffix is reserved (it backs the per-collection shadow
tables).

## Compose with filters and rules

The search predicate is AND-ed into the *same* composed `WHERE` as your `filter`, the list rule,
abilities, and tenant scope — **search can never widen visibility**. A search of a tenant-owned
or ability-guarded collection returns only the rows the caller may already view. The whole term
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
