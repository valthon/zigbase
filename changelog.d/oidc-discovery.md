### Features

- Generic OIDC discovery for OAuth providers: set `.discoveryURL = "https://…/.well-known/openid-configuration"` on a provider (mutually exclusive with explicit endpoint URLs) and the endpoints are resolved once at startup — https-only, issuer-checked, and **fail-fast** (a failed discovery refuses to start). Covers Auth0/Okta/Keycloak/Entra-custom-tenant/Zitadel-class IdPs with one config line; scopes default to `openid email profile` with the standard OIDC claim mapping.
