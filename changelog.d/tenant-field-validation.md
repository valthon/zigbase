### Security

- The runtime collections API now validates `tenant_field` (and `ttl_field`): it must be a valid
  identifier that names an existing field, rejected with an actionable error otherwise. Previously
  a superuser could set an invalid or dangling `tenant_field` via the admin API; because
  `tenancy.scopeApplies` treats an invalid identifier as "scoping does not apply", the tenant-owned
  collection would then be served **un-scoped** — a cross-tenant row leak. The comptime
  `.collections` path already enforced this; the runtime API now mirrors it, keeping the fail-open
  state unreachable.
