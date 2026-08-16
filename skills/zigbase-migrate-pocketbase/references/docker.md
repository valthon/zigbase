> 📖 This documentation is also published, web-native, at <https://valthon.github.io/zigbase/docs/docker> — the site is the canonical reading experience.

# Docker

ZigBase has no native Windows build (the embedded HTTP server depends on facil.io/zap,
Linux/macOS only). The official Docker image, `ghcr.io/valthon/zigbase`, is the supported
path for Windows-hardware users and for anyone who prefers a Docker-first self-host
workflow on Linux/macOS too. It ships the same static-musl binary as the
[release tarballs](../README.md#quickstart-run-the-binary) — no in-image compilation, no extra runtime deps.

## Quick start

```sh
docker run -d --name zigbase -p 8090:8090 -v zigbase_data:/data ghcr.io/valthon/zigbase:latest
```

Zero arguments beyond the standard `docker run` flags — the image's default command is
`serve`. Open <http://localhost:8090/_/> and create a superuser:

```sh
docker exec zigbase /zigbase superuser create --email you@example.com --password 'change-me' --data-dir /data
```

A `docker-compose.yml` quick-start lives at the repo root; `docker compose up` brings up
the same thing with a named volume pre-wired.

## Image details

- **Base:** `gcr.io/distroless/static-debian12:nonroot` — no shell, no package manager,
  just the CA bundle and a numeric non-root user (uid/gid `65532`). The binary is already
  statically linked (musl); distroless is chosen over `scratch` specifically because
  ZigBase's outbound TLS clients (SMTP/STARTTLS mail delivery, a Postgres backend with
  `sslmode=require`, OAuth2 token exchange, Sentry error reporting) load the **system CA
  bundle from disk** at connect time — `scratch` has none, and every one of those
  integrations would fail TLS verification. If you don't use any of those integrations
  this doesn't affect you either way, but distroless costs nothing over scratch here.
- **User:** runs as non-root uid `65532` always. There is no way to run the container as
  root.
- **Data directory:** `/data`, baked in as `ZIGBASE_DATA_DIR=/data` and declared as a
  `VOLUME`. Mount a named volume (`-v zigbase_data:/data`, auto-created and owned
  correctly by Docker) or a bind mount — **a bind mount from the host must be
  pre-created and `chown 65532:65532`'d**, or the container will fail to write `data.db`
  (this is the most common non-root-container support question; see below).
- **Network bind:** the image sets `ZIGBASE_HTTP_HOST=0.0.0.0`, overriding the binary's
  own secure-by-default loopback bind (`127.0.0.1` on bare metal). Inside a container this
  override is necessary — otherwise nothing outside the container's network namespace
  could reach it — and it does not weaken security: the container boundary plus whatever
  you pass to `-p`/`--network` is the real access-control surface here, same as it would
  be for any other containerized server.

### Custom application images

A framework-mode application that builds its own non-root image must reproduce the runtime
contract the official image supplies. Before switching to uid/gid `65532`, create `/data` with
that ownership; otherwise a new named volume is mounted as root-owned and ZigBase cannot create
`data.db`:

```dockerfile
RUN install -d -o 65532 -g 65532 /data
ENV ZIGBASE_DATA_DIR=/data \
    ZIGBASE_HTTP_HOST=0.0.0.0 \
    ZIGBASE_SERVE_BACKGROUND=0
USER 65532:65532
VOLUME ["/data"]
ENTRYPOINT ["/usr/local/bin/my-app"]
CMD ["serve"]
```

The explicit foreground setting prevents an inherited coding-agent environment from detaching
the process inside Docker. Verify the assembled image—not only the build stage—with a named volume,
an HTTP readiness probe, and `doctor --production`.

### Bind-mount ownership

```sh
mkdir -p ./zb_data && sudo chown 65532:65532 ./zb_data
docker run -d -p 8090:8090 -v "$(pwd)/zb_data:/data" ghcr.io/valthon/zigbase:latest
```

Skip this and use a named volume (`-v zigbase_data:/data`) instead if you don't need the
data directory visible on the host filesystem — Docker creates and owns named volumes
correctly without a manual `chown`.

## Plain-HTTP / local / LAN use

Auth cookies are `Secure` by default (HTTPS-only), same as the bare-metal binary. For a
plain-HTTP local or LAN deployment, set `ZIGBASE_COOKIE_SECURE=false` (equivalent to the
bare-metal `--insecure-cookies` flag):

```sh
docker run -d -p 8090:8090 -v zigbase_data:/data \
  -e ZIGBASE_COOKIE_SECURE=false \
  ghcr.io/valthon/zigbase:latest
```

Put a TLS-terminating reverse proxy (Caddy, Traefik, nginx) in front for anything beyond
local/LAN use, and drop `ZIGBASE_COOKIE_SECURE=false` once you do.

## Configuration

Every environment variable in the [Configuration reference](https://valthon.github.io/zigbase/docs/configuration) applies
unchanged — pass them with `-e` / compose's `environment:`. The two the image itself sets
(`ZIGBASE_HTTP_HOST=0.0.0.0`, `ZIGBASE_DATA_DIR=/data`) can be overridden the same way if
you have a reason to (e.g. mounting the data dir somewhere else inside the container).

## Healthchecks

`GET /api/health` (see [API reference](./api.md)) is the right endpoint to probe, but the
distroless base has no shell/curl/wget to run a classic `HEALTHCHECK CMD curl …`
instruction from inside the image. Two supported options:

- **Orchestrator-native HTTP probes** (Kubernetes `httpGet` readiness/liveness probes,
  ECS/Nomad HTTP health checks) — point them at `GET /api/health` on the published port
  directly; they run outside the container and don't need a shell inside it.
- **A reverse proxy in front** (Caddy/Traefik) that itself health-checks the upstream via
  HTTP and can expose its own `HEALTHCHECK`.

The bundled `docker-compose.yml` example uses `/zigbase version` (an in-image, no-shell
liveness check) as a lightweight default — it confirms the binary starts and runs, but it
is **not** an HTTP readiness check. Prefer an orchestrator-native HTTP probe against
`/api/health` for production.

## Tags

- `latest` — newest tagged release.
- `X.Y.Z` — an exact release, e.g. `ghcr.io/valthon/zigbase:0.9.0`.
- `X.Y` / `X` — rolling aliases that track the newest patch/minor within that line.

Pin to `X.Y.Z` for reproducible deployments. Images are published to `ghcr.io/valthon/zigbase`
(GitHub Container Registry) on each tagged release. **Maintainer note:** GHCR creates a newly
pushed package as **private** by default — after the first release push, a repo owner must
flip its visibility to Public once (package Settings → Change visibility) before `docker pull`
works for anonymous/public users.

## What's NOT in the image

No shell, no package manager, no Zig toolchain, no build tools — you cannot `docker exec
… sh` into it. Use `docker exec … /zigbase <subcommand>` for `superuser create`,
`migrate`, etc. If you need a debugging shell, `docker cp` files out or run the same
binary from a [release tarball](../README.md#quickstart-run-the-binary) locally instead.

## See also

- [Deployment](deployment.md) — production Compose, TLS proxies, Fly/Railway, backups, upgrades, and rollback.
- [Configuration](https://valthon.github.io/zigbase/docs/configuration) — the full environment-variable reference.
- The [README's Security section](../README.md#security) — what's safe to change and what
  isn't.
- [Known limitations](../KNOWN_LIMITATIONS.md) — no native Windows build; Docker is the
  supported path there.
