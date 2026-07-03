### Breaking
- Postgres backend (`-Dpostgres` builds): the default `sslmode` for `postgres://` URLs is now **`verify-full`** — the server certificate chain AND hostname are verified against the system root store (or `sslrootcert=<pem-path>`). A server without TLS (e.g. a docker-compose dev database) now fails **at startup** with an error naming the one-parameter fix: append `?sslmode=disable` (plaintext) or `?sslmode=require` (encrypted, unverified) to `ZIGBASE_DB_URL`. Explicitly configured modes below `verify-full` keep working and log one startup warning.

### Security
- Postgres TLS supports real server-certificate verification: `sslmode=verify-ca` / `verify-full` are accepted (previously rejected at parse time), a new `sslrootcert=<path|system>` URL parameter selects the CA bundle (built once at startup, shared by all pooled connections, fail-fast on a missing/empty bundle), certificate validity is checked against real wall-clock time, and handshake failures surface actionable startup errors (untrusted chain, hostname mismatch, expired / not-yet-valid certificate, server refused TLS) that never include the connection URL.

### Fixes
- Postgres backend (`-Dpostgres` builds): a `postgres://` URL whose host is a DNS name (e.g. `localhost`, `db.internal`) now resolves through the OS resolver (`/etc/hosts` + `resolv.conf`) instead of failing to connect — previously only IP-literal hosts (`127.0.0.1`, `::1`) worked, so `verify-full` against a hostname could never complete its handshake.
