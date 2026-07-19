### Security

- Client-supplied `?filter=` and `?sort=` can no longer reference hidden fields (`passwordHash`, `tokenKey`, `token_epoch`, or any field marked `hidden`). Previously such a query on a non-locked collection turned row presence/absence into a boolean oracle, allowing character-by-character extraction of a per-user server secret the API never serializes. The query builder now rejects hidden fields in client input the same way it already rejects encrypted ones (closed, with a `400`), matching the read layer's visibility rule exactly so no serialized column is affected. Trusted, operator-authored access rules may still gate on a hidden field — a rule is a server-side `WHERE` clause whose truth is never returned to the client, so it is no oracle.

### Performance

- List-endpoint `?expand=` now resolves each relation target's schema once per page and reuses each `(collection, id)` view-authorization decision across rows, instead of re-loading and re-parsing the target collection and re-authorizing on every returned record. This removes redundant `_collections` reads/parses and duplicate rule queries on `GET …/records?expand=…`, most impactful on the Postgres backend where each was a network round trip.
