### Features

- `zigbase import --external-auths` migrates OAuth/OmniAuth provider linkage alongside the
  account, so a social-login user is no longer locked out after a migration. Each auth row may
  carry `externalAuths: [{"provider":…,"providerId":…}]`; the record and its linkage are written
  in one transaction. The flag is off by default, requires an auth collection that already
  declares each named provider, refuses `_superusers`, is create-only, and treats an already-linked
  `providerId` as a hard failure rather than re-pointing an existing identity. Provider access and
  refresh tokens remain credentials and still never migrate.

### Security

- `externalAuths` is now stripped from every client payload by `auth.isServerManagedField`, so
  provider linkage — which decides *which account* an identity resolves to — can only be written
  through the operator-only offline import seam, never over HTTP.
