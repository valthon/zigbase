### Features
- Built-in key→value/settings store (#87): `ctx.kv().get/set/delete` (and the curated `data.kvGet`/`kvSet`/`kvDelete`/`kvList`) over a new internal `_kv` table — small server-managed values with no collection, schema, or access rules. Superuser-managed and not public by default.
- Typed feature flags (#88): `ctx.flag(name) -> bool` and `ctx.setFlag(name, enabled)`, a typed boolean view over the same KV store (`"true"`/`"1"` truthy, unset = false).
- Superuser-only settings HTTP API: `GET /api/settings`, `GET/PUT/DELETE /api/settings/:key` for managing KV/settings values.
