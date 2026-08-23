# Deploying ZigBase

ZigBase is one foreground server process plus durable state. A production deployment must keep
that process supervised, keep its data and JWT signing secret across replacements, terminate TLS in
front of it, and prove the resulting configuration with `zigbase doctor --production`.

This guide covers a bare Linux host, Docker Compose, Fly.io, and Railway. For image construction,
tags, and non-root volume ownership, see [docker.md](docker.md). For foreground/background
development sessions and doctor's full output contract, see [serve.md](serve.md).

## Production invariants

Keep these true on every platform:

1. **Run `serve` in the foreground.** systemd, Docker, Fly, and Railway are the supervisor. Do not
   put `serve --background` inside another supervisor.
2. **Persist the whole data directory.** SQLite's database, uploaded files, and the generated
   `.jwt_secret` live below `ZIGBASE_DATA_DIR`. Losing only the secret logs every user out; losing
   the rest loses application state. A custom non-root image must create `/data` owned by its
   runtime uid/gid before declaring or mounting the volume; see [docker.md](docker.md).
3. **Use one SQLite writer process.** A mounted disk is not a replicated database. Run one ZigBase
   instance with SQLite. Move to the PostgreSQL backend before adding application replicas; see
   [postgres.md](postgres.md).
4. **Terminate TLS before public traffic.** Leave secure cookies enabled. Set
   `ZIGBASE_PUBLIC_URL=https://…` so user-facing links use the external origin.
5. **Trust proxy headers only behind a trusted proxy.** `ZIGBASE_TRUST_PROXY=true` makes rate-limit
   identity use `X-Forwarded-For`/`X-Real-IP`. Never enable it on a process callers can also reach
   directly.
6. **Configure real mail delivery.** Without SMTP or sendmail, verification and reset tokens are
   logged for development. `doctor --production` treats that as an error.
7. **Pin releases.** Use an exact binary or image version. `latest` is convenient for local
   evaluation, not a reproducible rollout.
8. **Back up and restore-test.** A snapshot you have never restored is only a hope.

Before exposing traffic, run:

```sh
zigbase doctor --production --json --data-dir /var/lib/zigbase
```

Doctor emits NDJSON findings followed by one summary. Exit `0` is fully clean, `1` means at least
one error, and `2` means warnings only. A strict deployment gate accepts only `0`:

```sh
zigbase doctor --production --data-dir /var/lib/zigbase && deploy
```

If your policy deliberately accepts reviewed warnings, accept `0` and `2` explicitly—never every
non-`1` value:

```sh
zigbase doctor --production --data-dir /var/lib/zigbase
case $? in 0|2) deploy ;; *) exit 1 ;; esac
```

Review every current check: persisted JWT secret, public-rule inventory, secure cookies, host
binding, trusted-proxy coherence, mail delivery, applied migrations, writable data directory, and
remaining legacy password hashes. Check ids are frozen; prose is not.

## Secrets and environment

At minimum, set the public origin and mail delivery. Either persist the generated `.jwt_secret`
inside the data directory or supply a stable secret of at least 32 bytes through the platform's
secret store:

```sh
ZIGBASE_PUBLIC_URL=https://app.example.com
ZIGBASE_JWT_SECRET=replace-with-a-random-secret-at-least-32-bytes
ZIGBASE_SMTP_HOST=smtp.example.com
ZIGBASE_SMTP_PORT=587
ZIGBASE_SMTP_TLS=starttls
ZIGBASE_SMTP_USERNAME=app@example.com
ZIGBASE_SMTP_PASSWORD=replace-me
ZIGBASE_SMTP_FROM=app@example.com
```

Do not commit the real file. Restrict it to the service account. Generate secrets with an operating
system password manager or CSPRNG; do not derive them from the app name or user password.

If you rotate `ZIGBASE_JWT_SECRET`, existing access tokens stop verifying. Treat that as an
intentional all-sessions logout and schedule it accordingly.

## Bare Linux with systemd

Install an exact release binary as `/usr/local/bin/zigbase`. The unit below uses a dynamic service
user and asks systemd to create `/var/lib/zigbase` with ownership that follows that user:

```ini
# /etc/systemd/system/zigbase.service
[Unit]
Description=ZigBase backend
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
DynamicUser=yes
StateDirectory=zigbase
StateDirectoryMode=0700
EnvironmentFile=/etc/zigbase/zigbase.env
ExecStart=/usr/local/bin/zigbase serve --data-dir /var/lib/zigbase --http-host 127.0.0.1 --http-port 8090
Restart=on-failure
RestartSec=3s
TimeoutStopSec=30s
KillSignal=SIGTERM

NoNewPrivileges=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectSystem=strict
ProtectHome=yes
ProtectControlGroups=yes
ProtectKernelModules=yes
ProtectKernelTunables=yes
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
RestrictSUIDSGID=yes
LockPersonality=yes
CapabilityBoundingSet=
AmbientCapabilities=

[Install]
WantedBy=multi-user.target
```

Create `/etc/zigbase/zigbase.env` as root, mode `0600`, then validate and start:

```sh
sudo install -d -m 0755 /etc/zigbase
sudo install -m 0600 /path/to/zigbase.env /etc/zigbase/zigbase.env
sudo systemd-analyze verify /etc/systemd/system/zigbase.service
sudo systemctl daemon-reload
sudo systemctl enable --now zigbase
sudo systemctl status zigbase
sudo journalctl -u zigbase -f
```

The process binds only to loopback. Put Caddy, nginx, HAProxy, or another TLS proxy on the public
interface. With Caddy:

```text
app.example.com {
    reverse_proxy 127.0.0.1:8090
}
```

Caddy supplies and renews TLS certificates and sends the forwarded client headers ZigBase expects.
Set `ZIGBASE_TRUST_PROXY=true` only because the ZigBase socket remains loopback-only. Keep
`ZIGBASE_COOKIE_SECURE=true` (the default) and set
`ZIGBASE_PUBLIC_URL=https://app.example.com`.

`--http-host` is a real constraint on the socket, not a label: an address this machine does not
have — a typo, an address belonging to another box — fails at boot naming the address, rather
than falling back to a wider bind. If you bind one specific interface rather than loopback, order
the unit after that interface exists (the unit above already does: `After=network-online.target`).
Confirm the bind rather than trusting the log line: `ss -ltnp | grep zigbase`.

After changing the environment file or binary, use `systemctl restart zigbase`; `reload` has no
special configuration semantics. Check the journal and both health endpoints after every restart.

## Docker Compose

The repository's `docker-compose.yml` is a local quick start. A production Compose deployment
should pin a release, omit the local plain-HTTP cookie override, and keep the named volume:

```yaml
services:
  zigbase:
    image: ghcr.io/valthon/zigbase:0.13.0
    restart: unless-stopped
    stop_grace_period: 30s
    ports:
      - "127.0.0.1:8090:8090"
    volumes:
      - zigbase_data:/data
    env_file:
      - ./zigbase.env
    healthcheck:
      test: ["CMD", "/zigbase", "version"]
      interval: 30s
      timeout: 5s
      retries: 3

volumes:
  zigbase_data:
```

The official distroless image has no shell or HTTP client. `/zigbase version` proves process
liveness, not HTTP readiness. Probe `GET /api/health` from the reverse proxy, orchestrator, or host.
Bind the published port to loopback when the TLS proxy is on the same host; do not publish a second
direct path around the proxy while trusting its headers.

Apply configuration changes by recreating the service, not `docker compose restart`—a restart does
not apply changed environment or Compose configuration:

```sh
docker compose pull
docker compose up -d --force-recreate
docker compose ps
curl --fail https://app.example.com/api/health
curl --fail https://app.example.com/api/meta
```

## Fly.io

Fly's Machine root filesystem is ephemeral; SQLite needs a Fly Volume mounted at `/data`. Volumes
are local to one Machine and are not automatically replicated, so keep a SQLite deployment at one
Machine. Fly's proxy terminates TLS and can perform an HTTP readiness check.

Create the app and one volume in the chosen region:

```sh
fly launch --no-deploy
fly volumes create zigbase_data --region iad --size 1
fly scale count 1
```

A minimal `fly.toml` for the official image:

```toml
app = "replace-with-your-app"
primary_region = "iad"

[build]
  image = "ghcr.io/valthon/zigbase:0.13.0"

[env]
  ZIGBASE_HTTP_HOST = "0.0.0.0"
  ZIGBASE_HTTP_PORT = "8090"
  ZIGBASE_DATA_DIR = "/data"
  ZIGBASE_COOKIE_SECURE = "true"
  ZIGBASE_PUBLIC_URL = "https://replace-with-your-app.fly.dev"

[mounts]
  source = "zigbase_data"
  destination = "/data"
  snapshot_retention = 14

[http_service]
  internal_port = 8090
  force_https = true
  auto_stop_machines = "off"
  min_machines_running = 1

  [[http_service.checks]]
    grace_period = "10s"
    interval = "15s"
    method = "GET"
    path = "/api/health"
    timeout = "5s"
```

This recipe deliberately leaves `ZIGBASE_TRUST_PROXY` disabled so the production doctor gate is
clean while the listener binds `0.0.0.0`. ZigBase will see Fly's proxy address rather than the
original client IP for IP-derived rate-limit keys. If that tradeoff is unacceptable, use an
application-defined rate-limit key; do not enable forwarded-header trust on a publicly reachable
socket merely to recover client IPs.

Set secrets outside `fly.toml`, then deploy:

```sh
fly secrets set \
  ZIGBASE_JWT_SECRET='replace-with-at-least-32-random-bytes' \
  ZIGBASE_SMTP_PASSWORD='replace-me'
fly deploy
fly checks list
fly logs
curl --fail https://replace-with-your-app.fly.dev/api/meta
```

Fly health checks affect deployment/routing but do not replace continuous monitoring, and a failed
check does not by itself restart a Machine. Fly takes scheduled volume snapshots, but volumes are
single-host storage and snapshots are not an application-level availability design. Choose a
retention matching your recovery objective, export an independent backup, and rehearse restore.
See Fly's current [volume](https://fly.io/docs/volumes/overview/) and
[health-check](https://fly.io/docs/reference/health-checks/) documentation before rollout.

## Railway

Attach a Railway Volume to the service at `/data`; volumes are mounted only at runtime. Railway
mounts volumes as root, while the official image normally runs as uid `65532`. Railway currently
documents `RAILWAY_RUN_UID=0` as its workaround for non-root images with attached volumes, so set
that service variable or publish a derived image whose startup can repair ownership before dropping
privileges. Recheck this platform-specific tradeoff against Railway's current volume documentation.

Railway injects `PORT` for routing and deployment health checks, while ZigBase reads
`ZIGBASE_HTTP_PORT`. Set both to the same fixed port:

```text
PORT=8090
ZIGBASE_HTTP_PORT=8090
ZIGBASE_HTTP_HOST=0.0.0.0
ZIGBASE_DATA_DIR=/data
ZIGBASE_COOKIE_SECURE=true
ZIGBASE_PUBLIC_URL=https://${{RAILWAY_PUBLIC_DOMAIN}}
RAILWAY_RUN_UID=0
```

As with Fly, this leaves forwarded-header trust disabled because the service socket is not
loopback-only; `doctor --production` would otherwise report `trust-proxy-consistency` as an error.
IP-derived rate limits therefore see Railway's proxy address. Prefer an application-defined key
when per-client enforcement is required.

Add the stable JWT secret and mail credentials as Railway secret variables. Configure the service
to use `ghcr.io/valthon/zigbase:0.13.0`, attach the volume, and set the healthcheck path to
`/api/health`. Railway waits for HTTP 200 before activating a deployment, but currently uses that
check only during deployment—not as continuous monitoring.

A service with an attached volume has a brief redeploy interruption because Railway will not mount
one volume into old and new deployments simultaneously. Plan for that boundary or move state to
PostgreSQL before requiring multiple replicas/zero-downtime application replacement. Railway
volumes support manual and scheduled backups; configure a schedule and test a restore in a separate
environment before relying on it. Review Railway's current [volume](https://docs.railway.com/volumes),
[backup](https://docs.railway.com/volumes/backups), and
[healthcheck](https://docs.railway.com/deployments/healthchecks) documentation.

## Backups and restore rehearsal

For SQLite, the simplest portable consistent backup is a short maintenance stop followed by a copy
of the entire data directory. This captures `data.db`, its WAL state after clean shutdown, uploaded
files, and `.jwt_secret` together:

```sh
sudo systemctl stop zigbase
sudo tar --xattrs --acls -C /var/lib -czf /srv/backups/zigbase-$(date -u +%Y%m%dT%H%M%SZ).tar.gz zigbase
sudo systemctl start zigbase
```

With Docker, stop the service and back up the named volume through a trusted host-side procedure or
use a storage snapshot. With Fly/Railway, use platform volume snapshots plus an independent export
whose retention is not tied to deleting the application. PostgreSQL deployments use the database
provider's native backup/PITR tooling; uploaded local files still need their own backup unless files
use S3-compatible storage.

Rehearse restore into a different directory or non-production service:

1. provision the exact ZigBase version that created the backup;
2. restore the complete data directory with correct ownership;
3. start on a non-public port/origin;
4. run health, meta, `migrate status`, and `doctor --production`;
5. authenticate a test user and read an uploaded file; and
6. record the measured recovery time and any manual step.

Never test restore by overwriting the only production copy.

## Upgrades and rollback

Read the release notes and pin the target version. Before changing the binary or image:

```sh
zigbase migrate status --json --data-dir /var/lib/zigbase
zigbase doctor --production --json --data-dir /var/lib/zigbase
```

Take a restorable backup, then replace one supervised process. After startup, verify logs, health,
metadata, migrations, sign-in, one write, and one file/realtime path the application depends on.

Rolling the binary back does not automatically reverse a schema/data migration. If the new release
made an incompatible change, stop writes and restore the pre-upgrade data backup together with the
old binary. Practice this before a high-risk upgrade. For a declarative schema change, run
`zigbase schema apply schema.json --dry-run` first and require explicit approval for destructive
changes.

## Post-deploy checklist

- [ ] Exact ZigBase version is pinned and recorded.
- [ ] One SQLite process, or PostgreSQL is configured for multiple replicas.
- [ ] Data directory and JWT secret survive a process/container replacement.
- [ ] Public traffic uses HTTPS; secure cookies remain enabled.
- [ ] No direct route bypasses a proxy while `ZIGBASE_TRUST_PROXY=true`.
- [ ] `ZIGBASE_PUBLIC_URL` matches the external HTTPS origin.
- [ ] Verification/reset email reaches a real inbox.
- [ ] Every `@public` rule is reviewed and inventoried.
- [ ] Migrations are applied; schema dry-run shows the intended change only.
- [ ] `doctor --production` meets the deployment's strict/tolerant policy.
- [ ] `/api/health` and `/api/meta` work through the public path.
- [ ] Logs and an external continuous-availability check are configured.
- [ ] Backup schedule, independent retention, restore owner, and measured restore time are known.
- [ ] Rollback names the old binary/image and the matching pre-upgrade data copy.

## See also

- [docker.md](docker.md) — official image, uid/gid, bind mounts, tags, and healthcheck limits.
- [serve.md](serve.md) — server lifecycle and the full doctor check/exit contract.
- [observability.md](observability.md) — structured logs, error codes, and machine-readable output.
- [postgres.md](postgres.md) — PostgreSQL, multi-instance realtime, TLS, and SQLite migration.
- [migration-tools.md](migration-tools.md) — schema transplant, data/password import, and parity replay.
