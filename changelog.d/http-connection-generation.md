### Fixes

- Prevent stale HTTP connection events from closing a replacement connection after the operating system reuses its descriptor, avoiding connection resets and truncated pages during browser navigation.
