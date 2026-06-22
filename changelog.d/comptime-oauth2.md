### Features

- Comptime OAuth2 providers: declare `.auth.oauth2 = .{ .enabled = true, .providers = .{ .{ .name = "google", .redirectUrls = .{…} } } }` on an auth collection in `.collections`. The runtime `clientId`/`clientSecret` are sourced from `ZIGBASE_OAUTH_<NAME>_CLIENT_ID` / `ZIGBASE_OAUTH_<NAME>_CLIENT_SECRET` at provisioning time and the secret is encrypted (AES-256-GCM) before it is persisted — secrets never live in the binary. (Applied on first creation only; rotate via the admin API.)
