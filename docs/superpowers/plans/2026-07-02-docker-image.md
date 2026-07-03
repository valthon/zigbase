# ZigBase Official Docker Image — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Ship an official, multi-arch `ghcr.io/valthon/zigbase` Docker image built from the *existing* release-tarball binaries (no in-image Zig compilation), so Windows-hardware users and Docker-first self-hosters have a supported path now that native Windows is permanently out of scope. Zero-arg `docker run` must produce a working server reachable from the host.

**Design note (baked into this plan — no separate spec exists):**

- **Base image: `gcr.io/distroless/static-debian12` (nonroot variant), not `scratch`.** The binary is static musl (`x86_64/aarch64-linux-musl`, confirmed via `scripts/release.sh`'s `TARGETS`), so it needs no libc at runtime — but ZigBase makes outbound TLS connections (SMTP/STARTTLS/implicit `src/mail/mailer.zig`, Postgres `sslmode=require` `src/backend/postgres/conn.zig`, OAuth2 token exchange `src/oauth/client.zig`, Sentry reporting `src/sentry.zig`) all via `std.crypto.tls.Client`, which loads the **system CA bundle from disk** (`Certificate.Bundle.rescan`, confirmed in `mailer.zig` — no vendored/embedded bundle exists anywhere in `src/`). `scratch` ships no `/etc/ssl/certs` at all, so TLS verification would hard-fail for every outbound integration (SES-over-SMTP, managed Postgres, OIDC providers, Sentry) the moment an operator configures one. `distroless/static-debian12` ships `/etc/ssl/certs/ca-certificates.crt` + `/etc/passwd` (for a numeric nonroot UID) with nothing else — same attack-surface story as scratch, zero shell/package-manager, but TLS actually works out of the box. Alpine is rejected: it adds a shell + apk + musl libc we don't need (the binary is already statically linked) purely for debuggability, at the cost of a meaningfully larger image and more CVE surface than distroless.
- **Data volume: `/data`, `ZIGBASE_DATA_DIR=/data` baked into the image env, `VOLUME ["/data"]` declared.** Matches the existing `--data-dir` / `ZIGBASE_DATA_DIR` convention (`src/config.zig` default `./zb_data`; env-var precedence confirmed in `README.md`'s Configuration table) without requiring the operator to pass a flag. Runs as a **fixed non-root UID `65532`** (distroless's own `nonroot` user/UID, avoids inventing a new one) — the entrypoint task must `chown`-equivalent via a writable volume owned by that UID at container-create time (documented in the compose example: `docker run -v zigbase_data:/data …` auto-creates the named volume owned by root, so the Dockerfile must ensure `/data` exists with correct ownership at build time; a bind-mount from the host needs the host directory pre-chowned to `65532` — call this out explicitly in the docs, it is the #1 self-host support-request footgun for any non-root container image).
- **Host binding: the image MUST set `ZIGBASE_HTTP_HOST=0.0.0.0`.** Confirmed in `src/config.zig`: `http_host: []const u8 = "127.0.0.1"` (loopback-only default, secure-by-default per `README.md`'s Security section) — inside a container this is fatal (nothing outside the container network namespace can reach loopback), and it is an easy footgun to ship silently broken. Bake `ENV ZIGBASE_HTTP_HOST=0.0.0.0` into the Dockerfile; the docs must explain *why* this is safe here (the container boundary + explicit `-p` port publishing is the real access-control gate, replacing the loopback default) and that Docker users still choose what to publish via `-p`.
- **`--insecure-cookies` / `ZIGBASE_COOKIE_SECURE`: NOT baked into the image** (must stay secure-by-default — `cookie_secure: bool = true` in `src/config.zig`). Document it as a compose/run-time opt-in (`-e ZIGBASE_COOKIE_SECURE=false`) for plain-HTTP local/LAN use, with the same warning already in `README.md`'s Security section (use only for local dev or behind TLS-terminating reverse proxy).
- **Healthcheck: `HEALTHCHECK` invokes the `zigbase` binary itself, not curl/wget.** `GET /api/health` exists (`src/api/health.zig`, returns `{"status":"ok","backend":"sqlite"|"postgres"}`) but distroless has no shell, no curl, no wget — so a raw `curl`-based `HEALTHCHECK` (the usual Docker idiom) is impossible without adding a second binary. Adding a whole new `zigbase healthcheck` CLI subcommand (parser entry in `src/cli.zig`, a `HelpTopic` variant, wiring in `framework.zig`'s `runCli`) is more surface than this feature needs and would require its own tests/docs churn disproportionate to a Docker packaging task. Given the CLI is argv/flag-based with no existing "curl a URL and exit 0/1" primitive, and `docker run --health-cmd` needs an in-image executable: **use Docker Compose–level / orchestrator-level health checks against `GET /api/health`** (documented in the compose example and `docs/docker.md`) instead of an in-image `HEALTHCHECK` instruction. This is called out explicitly as a scoped-out decision — flagged to the repo owner in Task 6 for confirmation, since it is a judgment call rather than a hard technical blocker (a tiny healthcheck subcommand remains a clean follow-up if operators ask for native `HEALTHCHECK` support).
- **Tag scheme:** `latest` (tracks the newest `vX.Y.Z` release), `X.Y.Z` (exact), `X.Y` and `X` (rolling minor/major aliases) — the standard Docker convention, generated via `docker/metadata-action`'s semver pattern so no hand-rolled tag math is needed.
- **Registry: GHCR (`ghcr.io/valthon/zigbase`) only.** Uses the workflow-scoped `GITHUB_TOKEN` with `packages: write` — zero new secrets, consistent with the repo's existing npm-OIDC "no new secrets where possible" posture (`release.yml`'s `id-token: write` comment). Docker Hub is explicitly deferred (would need a new `DOCKERHUB_TOKEN` secret + org setup — out of scope here).
- **Build mechanism: `docker buildx build --platform linux/amd64,linux/arm64` from the two already-built musl tarball binaries — NO Zig compilation happens in the image build.** The Dockerfile's `FROM` for each arch is `distroless/static-debian12`, and the binary is `COPY`-ed in from a build context assembled by a workflow step that downloads/extracts the matching release tarball per arch (mirrors the existing `github-release` job's `actions/download-artifact` pattern in `release.yml`, reusing the same `build` job artifacts — `zigbase-linux-x64` / `zigbase-linux-arm64` — so the Docker job adds zero new compile time to the release pipeline). `buildx` (not a separate `manifest-tool` step) is used because it natively produces and pushes the multi-arch manifest list in one `build --push` invocation when given per-platform `--build-context`/staged binaries, which is simpler to wire into GitHub Actions than manually assembling a manifest afterward.
- **Trigger: on the same `v[0-9]*` tag push as `release.yml`, as a new job appended to `.github/workflows/release.yml`** (not a separate `docker.yml`) — it depends on (`needs:`) the existing `build` job so it reuses those artifacts instead of rebuilding, keeping "build once, ship everywhere" (the file's own header comment already states this principle for GitHub+npm; Docker becomes the third destination of the same build). A separate workflow file was considered and rejected: it would either duplicate the build-matrix or require a workflow-to-workflow artifact handoff, both more moving parts than one more job in the existing release graph.
- **`docker run` with zero args → `serve`.** The image's `ENTRYPOINT ["/zigbase"]` with `CMD ["serve"]` — matches the binary's own no-args behavior being `help` (`src/cli.zig`: `if (args.len == 0) return .{ .help = .top }`), so the image explicitly supplies `serve` as the default subcommand rather than relying on (or changing) the binary's bare-argv default.

**Architecture:** Task 1 writes the Dockerfile + `.dockerignore`. Task 2 extends `.github/workflows/release.yml` with a `docker` job. Task 3 adds a `docker-compose.yml` example + `docs/docker.md` (+ site mirror). Task 4 updates cross-cutting docs/site touchpoints (`README.md`, `KNOWN_LIMITATIONS.md`, `site/src/pages/compare.astro`, `site/src/pages/download.astro`, `site/src/config/sidebar.ts`). Task 5 adds the changelog fragment and runs local verification (`docker build` + `docker run` + `curl /api/health`, with a build-only CI fallback noted if the executing environment lacks a Docker daemon). Task 6 is a self-review pass reconciling every design-note decision against what was actually built.

**Tech Stack:** Docker / `docker buildx` (multi-arch, `docker/setup-qemu-action` + `docker/setup-buildx-action` + `docker/metadata-action` + `docker/login-action` from the Actions marketplace — no new secrets, only `GITHUB_TOKEN`), GitHub Actions (extending `.github/workflows/release.yml`), Astro (site docs mirror + `compare.astro`/`download.astro`), the existing `changelog.d/` fragment convention.

## Global Constraints

- **Baseline:** `origin/main` @ `0ae3289` (this worktree's local `main` is 45 commits behind `origin/main` — branch new work from `origin/main`, not the stale local `main`).
- **No in-image compilation, ever.** The Docker build step only downloads/extracts the already-built `x86_64-linux-musl` / `aarch64-linux-musl` tarballs produced by the existing `build` matrix job in `release.yml` and `COPY`s the binary in. Zig never runs inside `docker build`.
- **The image must default to a *working* zero-arg `docker run`:** binds `0.0.0.0` (not the binary's loopback default), runs `serve`, writes to `/data` as a non-root UID that a named/bind volume can be pre-provisioned for. Any deviation from "it just works" must be called out explicitly in `docs/docker.md`, not silently left to the operator to discover.
- **Secure-by-default is preserved.** The image does NOT bake in `ZIGBASE_COOKIE_SECURE=false` / `--insecure-cookies`, does NOT bake in a fixed `ZIGBASE_JWT_SECRET`, and does NOT relax any other secure-by-default in `src/config.zig`. Only the loopback bind is overridden (container-boundary justification documented above), because that default makes the container unreachable rather than insecure.
- **Never edit `CHANGELOG.md`** or `site/src/content/docs/changelog.md` directly. This work adds ONE fragment `changelog.d/docker-image.md` with a `### Features` section (Task 5).
- **Docs mirrors:** `docs/docker.md` (new) must be mirrored verbatim (module-relative link adjustments only) to `site/src/content/docs/docker.md` (new), added to `site/src/config/sidebar.ts`'s `guides` group, and `cd site && npm run build` must pass before the final task completes (per `keep-published-docs-and-examples-in-sync` — every doc change ships both copies in the same PR).
- **No `build.zig.zon` / server version bump in this plan.** The Docker image tags itself from whatever `vX.Y.Z` tag triggers the release — no Zig source changes are needed to add Docker support, so there is nothing to version-bump here.
- **GHCR package visibility:** the workflow must explicitly set the pushed package to public-readable is a *manual one-time step on ghcr.io after first publish* (GHCR defaults new packages to private, tied to the pushing repo) — call this out as a post-merge manual action in Task 2's step list, not something the workflow YAML can do unattended without a PAT with package-admin scope (which is out of scope — "zero new secrets" per the design note).
- **`docker` CLI availability for local verification is not guaranteed in the execution environment.** Task 5 checks for `docker version` first; if absent, it substitutes a `hadolint`/Dockerfile-lint-only local check and states in its own step list that full `build → run → curl` verification is deferred to the CI `docker` job (which always has a Docker daemon on `ubuntu-latest` runners) — this is not a plan gap, it's a documented fallback path executed at plan-run time.
- Commit after each task with the message given in the task. All paths below are relative to the repo root.

---

### Task 1: Dockerfile + `.dockerignore`

**Files:**
- Create: `Dockerfile`
- Create: `.dockerignore`

**Interfaces:**
- Produces: a two-stage-free (no compile stage — see Global Constraints) Dockerfile that expects a pre-built `zigbase` binary at a `BINARY` build-arg path in the build context, `COPY`s it in, and sets the runtime env/user/volume/entrypoint per the design note.

- [ ] Read `scripts/package-tarball.sh` and `.github/workflows/release.yml`'s `build`/`github-release` jobs (already fetched above) to confirm the exact per-arch binary artifact names (`zigbase-linux-x64`, `zigbase-linux-arm64`) this Dockerfile's build context will receive.
- [ ] Create `Dockerfile` at repo root:
  ```dockerfile
  # syntax=docker/dockerfile:1
  #
  # Official ZigBase image. Ships the ALREADY-BUILT static-musl release binary —
  # this Dockerfile never invokes Zig or compiles anything. The CI workflow
  # (.github/workflows/release.yml, `docker` job) stages the correct-arch binary
  # at ./context/<arch>/zigbase before `docker buildx build` runs; local manual
  # builds must do the same (see docs/docker.md).
  #
  # Base: distroless static (not `scratch`) — ZigBase makes outbound TLS calls
  # (SMTP/STARTTLS, Postgres sslmode=require, OAuth2 token exchange, Sentry) via
  # std.crypto.tls.Client, which loads the SYSTEM CA bundle from disk at runtime
  # (src/mail/mailer.zig: Certificate.Bundle.rescan). `scratch` ships no
  # /etc/ssl/certs and would make every outbound TLS call fail closed the moment
  # an operator configures SMTP/Postgres/OAuth/Sentry. distroless/static-debian12
  # ships the CA bundle + a numeric nonroot user and nothing else — same minimal
  # attack surface as scratch, but TLS actually works.
  FROM gcr.io/distroless/static-debian12:nonroot

  # ZIGBASE_HTTP_HOST=0.0.0.0 overrides the binary's secure-by-default loopback
  # bind (src/config.zig: http_host default "127.0.0.1"). Inside a container that
  # default is unreachable from outside the container network namespace — the
  # container boundary + the operator's own `-p`/network config is the real
  # access-control gate here, replacing the loopback default's role on bare metal.
  ENV ZIGBASE_HTTP_HOST=0.0.0.0 \
      ZIGBASE_HTTP_PORT=8090 \
      ZIGBASE_DATA_DIR=/data

  # distroless/static-debian12:nonroot already provides uid/gid 65532 ("nonroot").
  # /data is declared as a volume so `docker run -v zigbase_data:/data` (a named
  # volume, auto-created and owned by root by the Docker engine) or a pre-chowned
  # bind mount both work; see docs/docker.md for the bind-mount chown caveat.
  COPY --chown=65532:65532 zigbase /zigbase
  VOLUME ["/data"]
  WORKDIR /data
  USER 65532:65532

  EXPOSE 8090

  ENTRYPOINT ["/zigbase"]
  CMD ["serve"]
  ```
- [ ] Create `.dockerignore` at repo root (keeps the build context small; the Docker build context for CI is a staged directory containing only the binary, but a developer running `docker build .` from the repo root should not accidentally send the whole tree):
  ```
  .git
  .github
  zig-out
  zig-cache
  .zig-cache
  node_modules
  site/dist
  site/node_modules
  clients/typescript/node_modules
  examples/*/zig-out
  examples/*/zig-cache
  examples/*/frontend/node_modules
  examples/*/frontend/dist
  *.tar.gz
  ```
- [ ] `git add -A && git commit -m "docker: add official Dockerfile (distroless/static, non-root, no in-image compile)"`

---

### Task 2: CI — multi-arch build + push to GHCR on release tag

**Files:**
- Modify: `.github/workflows/release.yml` (append a new `docker` job)

**Interfaces:**
- Produces: on any `v[0-9]*` tag push, after `build` succeeds, a multi-arch (`linux/amd64`,`linux/arm64`) image pushed to `ghcr.io/valthon/zigbase` tagged `latest`, `X.Y.Z`, `X.Y`, `X`.

- [ ] Read `.github/workflows/release.yml`'s `build` and `github-release` jobs once more to confirm artifact names (`zigbase-linux-x64` → `x86_64-linux-musl`, `zigbase-linux-arm64` → `aarch64-linux-musl`) and the `permissions:` block at the top of the file.
- [ ] Add `packages: write` to the top-level `permissions:` block (currently `contents: write` + `id-token: write`):
  ```yaml
  permissions:
    contents: write   # create the GitHub release
    id-token: write   # npm OIDC trusted publishing + provenance
    packages: write   # push the Docker image to GHCR
  ```
- [ ] Append a new job after `github-release` (same `if: startsWith(github.ref_name, 'v')` guard; depends on `build` only — independent of `github-release`/`publish-npm`, so it can run in parallel with them):
  ```yaml
  docker:
    if: startsWith(github.ref_name, 'v')
    needs: build
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - name: Assert tag matches build.zig.zon
        run: scripts/assert-version.sh "${GITHUB_REF_NAME#v}"
      - uses: actions/download-artifact@v8
        with: { name: zigbase-linux-x64, path: docker-ctx/linux/amd64 }
      - uses: actions/download-artifact@v8
        with: { name: zigbase-linux-arm64, path: docker-ctx/linux/arm64 }
      - name: chmod binaries
        run: chmod +x docker-ctx/linux/amd64/zigbase docker-ctx/linux/arm64/zigbase
      - uses: docker/setup-qemu-action@v3
      - uses: docker/setup-buildx-action@v3
      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - name: Docker metadata (tags: latest, X.Y.Z, X.Y, X)
        id: meta
        uses: docker/metadata-action@v5
        with:
          images: ghcr.io/valthon/zigbase
          tags: |
            type=semver,pattern={{version}},value=${{ github.ref_name }}
            type=semver,pattern={{major}}.{{minor}},value=${{ github.ref_name }}
            type=semver,pattern={{major}},value=${{ github.ref_name }}
            type=raw,value=latest
      - name: Build + push multi-arch image
        uses: docker/build-push-action@v6
        with:
          context: .
          file: Dockerfile
          platforms: linux/amd64,linux/arm64
          push: true
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}
          build-contexts: |
            linux/amd64=docker-ctx/linux/amd64
            linux/arm64=docker-ctx/linux/arm64
  ```
  Note: `build-push-action`'s `build-contexts` maps a named context per platform is not how buildx's `--platform` flag composes with a single `COPY zigbase /zigbase` — buildx does NOT automatically select a differently-staged binary per target platform from named build-contexts keyed by platform string. **Read `docker buildx build --platform` + `COPY --from=` multi-platform documentation before finalizing this step**; the robust pattern is a Dockerfile with `ARG TARGETARCH` and `COPY docker-ctx/linux/${TARGETARCH}/zigbase /zigbase`, driven by a single build context directory containing both `linux/amd64/zigbase` and `linux/arm64/zigbase` subpaths (Docker's automatic `TARGETARCH` build-arg resolves to `amd64`/`arm64` per platform during a multi-platform `buildx build`). Adjust the Dockerfile's `COPY` line from Task 1 to `COPY --chown=65532:65532 ${TARGETARCH}/zigbase /zigbase` with `ARG TARGETARCH` declared above it, and simplify this job's build-push-action `with:` to a single `context: docker-ctx` (containing `amd64/` and `arm64/` subdirs, renamed from the `linux/amd64`/`linux/arm64` download paths above) instead of the `build-contexts:` map. Verify this resolves correctly in the CI run (Task 5's verification step) before considering this task done — this is the one part of the plan with real execution-order risk, flag any deviation in the Task 6 self-review.
- [ ] Add a one-line comment to the top of `release.yml` (in the existing header comment block) noting the new destination: `#   Also builds + pushes ghcr.io/valthon/zigbase (multi-arch) on the same v* tag.`
- [ ] **Manual one-time step (not automatable without a new PAT/secret — document, don't implement):** after the first successful push, an org owner must visit the package settings on `ghcr.io/valthon/zigbase` and set visibility to Public (GHCR defaults new packages to private). Note this in `docs/docker.md` (Task 3) and mention it needs doing once in this task's completion note.
- [ ] `git add -A && git commit -m "ci(release): build + push multi-arch ghcr.io/valthon/zigbase image on release tag"`

---

### Task 3: `docker-compose.yml` example + `docs/docker.md` (+ site mirror)

**Files:**
- Create: `docker-compose.yml` (repo root — a runnable quick-start example)
- Create: `docs/docker.md`
- Create: `site/src/content/docs/docker.md` (mirror)
- Modify: `site/src/config/sidebar.ts` (add `docker` entry to the `guides` group)

**Interfaces:** none produced — documentation + a runnable example.

- [ ] Read `docs/postgres.md` and `site/src/content/docs/postgres.md` in full to match frontmatter shape (`title`/`description`/`order`/`group`), the `docs/*.md` "also published" banner line format, and heading/tone conventions for a new feature/guide doc.
- [ ] Create `docker-compose.yml` at repo root:
  ```yaml
  # Quick-start compose file for the official ZigBase image. See docs/docker.md
  # for the full guide (data-volume ownership, TLS/reverse-proxy notes, healthcheck).
  services:
    zigbase:
      image: ghcr.io/valthon/zigbase:latest
      restart: unless-stopped
      ports:
        - "8090:8090"
      volumes:
        - zigbase_data:/data
      environment:
        # Plain-HTTP local/LAN use only — auth cookies are Secure by default.
        # Remove this (or set back to true) once you're behind TLS.
        ZIGBASE_COOKIE_SECURE: "false"
      healthcheck:
        # distroless has no shell/curl; compose's healthcheck still needs a
        # command, so this checks liveness via /proc instead of the HTTP API.
        # For a real HTTP health probe, front this with a reverse proxy (e.g.
        # Traefik/Caddy) that can itself curl GET /api/health, or use your
        # orchestrator's HTTP probe type (e.g. Kubernetes httpGet) directly
        # against the container — see docs/docker.md#healthchecks.
        test: ["CMD", "/zigbase", "version"]
        interval: 30s
        timeout: 5s
        retries: 3

  volumes:
    zigbase_data:
  ```
- [ ] Create `docs/docker.md`:
  ```markdown
  > 📖 This documentation is also published, web-native, at <https://valthon.github.io/zigbase/docs/docker> — the site is the canonical reading experience.

  # Docker

  ZigBase has no native Windows build (the embedded HTTP server depends on facil.io/zap,
  Linux/macOS only). The official Docker image, `ghcr.io/valthon/zigbase`, is the supported
  path for Windows-hardware users and for anyone who prefers a Docker-first self-host
  workflow on Linux/macOS too. It ships the same static-musl binary as the
  [release tarballs](/docs/overview) — no in-image compilation, no extra runtime deps.

  ## Quick start

  \`\`\`sh
  docker run -d --name zigbase -p 8090:8090 -v zigbase_data:/data ghcr.io/valthon/zigbase:latest
  \`\`\`

  Zero arguments beyond the standard `docker run` flags — the image's default command is
  `serve`. Open <http://localhost:8090/_/> and create a superuser:

  \`\`\`sh
  docker exec zigbase /zigbase superuser create --email you@example.com --password 'change-me' --data-dir /data
  \`\`\`

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

  ### Bind-mount ownership

  \`\`\`sh
  mkdir -p ./zb_data && sudo chown 65532:65532 ./zb_data
  docker run -d -p 8090:8090 -v "$(pwd)/zb_data:/data" ghcr.io/valthon/zigbase:latest
  \`\`\`

  Skip this and use a named volume (`-v zigbase_data:/data`) instead if you don't need the
  data directory visible on the host filesystem — Docker creates and owns named volumes
  correctly without a manual `chown`.

  ## Plain-HTTP / local / LAN use

  Auth cookies are `Secure` by default (HTTPS-only), same as the bare-metal binary. For a
  plain-HTTP local or LAN deployment, set `ZIGBASE_COOKIE_SECURE=false` (equivalent to the
  bare-metal `--insecure-cookies` flag):

  \`\`\`sh
  docker run -d -p 8090:8090 -v zigbase_data:/data \
    -e ZIGBASE_COOKIE_SECURE=false \
    ghcr.io/valthon/zigbase:latest
  \`\`\`

  Put a TLS-terminating reverse proxy (Caddy, Traefik, nginx) in front for anything beyond
  local/LAN use, and drop `ZIGBASE_COOKIE_SECURE=false` once you do.

  ## Configuration

  Every environment variable in the [Configuration reference](/docs/configuration) applies
  unchanged — pass them with `-e` / compose's `environment:`. The two the image itself sets
  (`ZIGBASE_HTTP_HOST=0.0.0.0`, `ZIGBASE_DATA_DIR=/data`) can be overridden the same way if
  you have a reason to (e.g. mounting the data dir somewhere else inside the container).

  ## Healthchecks

  `GET /api/health` (see [API reference](/docs/api)) is the right endpoint to probe, but the
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
  - `X.Y.Z` — an exact release, e.g. `ghcr.io/valthon/zigbase:0.13.0`.
  - `X.Y` / `X` — rolling aliases that track the newest patch/minor within that line.

  Pin to `X.Y.Z` for reproducible deployments.

  ## What's NOT in the image

  No shell, no package manager, no Zig toolchain, no build tools — you cannot `docker exec
  … sh` into it. Use `docker exec … /zigbase <subcommand>` for `superuser create`,
  `migrate`, etc. If you need a debugging shell, `docker cp` files out or run the same
  binary from a [release tarball](/docs/overview) locally instead.

  ## See also

  - [Configuration](/docs/configuration) — the full environment-variable reference.
  - [Security](/docs/api#security) and the README's Security section — what's safe to
    change and what isn't.
  - [Known limitations](/docs/known-limitations) — no native Windows build; Docker is the
    supported path there.
  ```
- [ ] Copy `docs/docker.md` to `site/src/content/docs/docker.md`, replacing the top banner line with frontmatter (matching `postgres.md`'s pattern) and adjusting internal doc links to the site's relative `./`-form as the existing mirrors do (diff `docs/postgres.md` vs `site/src/content/docs/postgres.md` first to confirm the exact link-rewriting convention used):
  ```yaml
  ---
  title: Docker
  description: The official ghcr.io/valthon/zigbase image — quick start, data-volume ownership, non-root user, network bind, healthchecks, and tags.
  order: 5
  group: guides
  ---
  ```
- [ ] In `site/src/config/sidebar.ts`, add `{ slug: 'docker', label: 'Docker' }` to the `guides` group's `entries` array (after `configuration`).
- [ ] `git add -A && git commit -m "docs: add Docker guide (docs/docker.md + site mirror) and a docker-compose.yml quick-start"`

---

### Task 4: Cross-cutting docs/site touchpoints

**Files:**
- Modify: `README.md` (add a short Docker subsection, likely under or near "Quickstart")
- Modify: `KNOWN_LIMITATIONS.md` (update the "No Windows build" line to point at Docker)
- Modify: `site/src/pages/compare.astro` (Platforms row)
- Modify: `site/src/pages/download.astro` (add a Docker section alongside "Release binaries" / "Build from source")

**Interfaces:** none produced — documentation only.

- [ ] In `README.md`, add a "## Docker" section after "## Quickstart (run the binary)" (before "## Features"):
  ```markdown
  ## Docker

  \`\`\`sh
  docker run -d -p 8090:8090 -v zigbase_data:/data ghcr.io/valthon/zigbase:latest
  \`\`\`

  The official image (`ghcr.io/valthon/zigbase`) ships the same static binary as the release
  tarballs. It's the supported path on Windows hosts (no native Windows build — see
  [Known limitations](KNOWN_LIMITATIONS.md)) and for Docker-first self-hosters generally.
  See [docs/docker.md](docs/docker.md) for the data-volume/non-root/healthcheck details.
  ```
- [ ] In `KNOWN_LIMITATIONS.md`, update the Windows line:
  ```markdown
  - **No Windows build** — Linux and macOS only (the embedded HTTP server depends on facil.io/zap). The official Docker image (`ghcr.io/valthon/zigbase`, see [docs/docker.md](docs/docker.md)) is the supported path on Windows hosts.
  ```
- [ ] In `site/src/pages/compare.astro`, update the `zigbase` value for the `dimension: 'Platforms'` row (currently `'<strong>Linux &amp; macOS only — no Windows</strong>'`):
  ```js
  zigbase: '<strong>Linux &amp; macOS binaries · Docker</strong> (no native Windows)',
  ```
  Re-read the surrounding prose (the "Choose PocketBase if you want Windows support" paragraph, ~line 236) after this edit — confirm it doesn't need a companion tweak now that Docker narrows the gap (it may still be accurate as-is since Docker isn't *native* Windows support; use judgment, don't over-edit copy this task doesn't own).
- [ ] In `site/src/pages/download.astro`, add a new `<section class="dl__section">` between "Release binaries" and "Build from source" (or after "Build from source" — read the full file first to place it where it reads best in the existing binaries → source → library flow):
  ```astro
  <section class="dl__section" aria-labelledby="docker">
    <h2 id="docker">Docker</h2>
    <p>
      The official image ships the same binary as the release tarballs above — no
      Windows build required.
    </p>
    <pre class="dl__code"><code>docker run -d -p 8090:8090 -v zigbase_data:/data ghcr.io/valthon/zigbase:{REL}</code></pre>
    <p class="dl__links">
      <code>latest</code>, <code>{'{'}X.Y.Z{'}'}</code>, and rolling <code>{'{'}X.Y{'}'}</code>/<code>{'{'}X{'}'}</code>
      tags are published to <a href="https://github.com/valthon/zigbase/pkgs/container/zigbase" target="_blank" rel="noopener noreferrer">ghcr.io/valthon/zigbase</a>.
      See the <a href="/docs/docker">Docker guide</a> for the data-volume and non-root-user details.
    </p>
  </section>
  ```
  Confirm `{REL}` (already defined at the top of the file as `ZIGBASE_VERSION_TAG`) renders as `vX.Y.Z` and adjust the docker tag in the example to strip the leading `v` if GHCR tags are published without it (per Task 2's `metadata-action` semver pattern, which strips the `v` prefix by default) — reconcile this discrepancy by testing the rendered output, don't guess.
- [ ] Build the site to confirm no Astro errors: `cd site && mise exec node@24 -- npm run build`.
- [ ] `git add -A && git commit -m "docs: cross-link the Docker image from README, KNOWN_LIMITATIONS, compare.astro, download.astro"`

---

### Task 5: Changelog fragment + local verification

**Files:**
- Create: `changelog.d/docker-image.md`

**Interfaces:** none produced.

- [ ] Create `changelog.d/docker-image.md`:
  ```markdown
  ### Features

  - Official multi-arch Docker image, `ghcr.io/valthon/zigbase` — built from the existing static-musl release binaries (no in-image compilation), `distroless/static` base, non-root by default. The supported deployment path for Windows-hardware users, since ZigBase has no native Windows build. See `docs/docker.md`.
  ```
- [ ] Check whether a Docker daemon is available in this environment: `docker version`. **If available:**
  1. `docker build -t zigbase:local-test --build-arg TARGETARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/') .` — actually, per Task 1/2's design, the Dockerfile expects the binary already staged in the build context (not fetched by the Dockerfile itself); first build the binary and stage it: `mise exec zig@0.16.0 -- zig build -Dtarget=$(uname -m | sed 's/x86_64/x86_64-linux-musl/;s/aarch64/aarch64-linux-musl/') -Doptimize=ReleaseSafe -Dcpu=baseline && mkdir -p /tmp/docker-ctx/$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/') && cp zig-out/bin/zigbase /tmp/docker-ctx/$(...)/zigbase`, then `docker build -t zigbase:local-test --build-context linux=/tmp/docker-ctx .` (reconcile the exact context wiring with whatever `ARG TARGETARCH` / `COPY` form Task 2 actually landed on — single-arch local build only needs one binary, so simplify as needed; the goal is proving the Dockerfile is syntactically and semantically correct, not exercising the full multi-arch matrix, which only CI can do).
  2. `docker run -d --name zigbase-verify -p 18090:8090 -v zigbase_verify_data:/data zigbase:local-test`
  3. `sleep 2 && curl -sf http://localhost:18090/api/health` → expect `{"status":"ok","backend":"sqlite"}`.
  4. `docker exec zigbase-verify /zigbase version` → expect version output, confirming the binary runs as the non-root user with no shell dependency.
  5. `docker rm -f zigbase-verify && docker volume rm zigbase_verify_data`.
  **If `docker version` fails (no daemon in this environment):** skip build/run verification here and note in the commit body that full `build → run → curl /api/health` verification is deferred to the CI `docker` job added in Task 2 (which runs on `ubuntu-latest` with a Docker daemon always available) — this is not a gap, `ubuntu-latest` GitHub-hosted runners always have Docker preinstalled, so the CI job itself IS the verification the first time a `vX.Y.Z` tag is pushed. Do a syntax-only check instead: `docker build --check .` if buildx supports it locally, or at minimum a manual read-through of the Dockerfile for the `ARG`/`COPY`/`ENV` ordering.
  Also lint the Dockerfile if `hadolint` is available (`mise` does not pin it; treat as optional): `hadolint Dockerfile`.
  Run once more, from repo root: `mise exec zig@0.16.0 -- zig build test --summary all` to confirm this plan's doc/YAML/Dockerfile-only changes haven't broken the existing Zig test suite (expected: no change in pass count, since no `.zig` file was touched).
  - [ ] `git add -A && git commit -m "changelog: add docker-image fragment; verify Dockerfile builds and serves /api/health"`

---

### Task 6: Self-review — reconcile design-note decisions against what shipped

**Files:** none (review-only task; may produce small fixups to Tasks 1–5's files if a discrepancy is found).

- [ ] Re-read the finished `Dockerfile`, `.github/workflows/release.yml`'s new `docker` job, `docker-compose.yml`, `docs/docker.md`, and this plan's design note side-by-side. Confirm each of the following is actually true of what was built, not just what was planned — fix any drift found:
  1. **Base image** — `distroless/static-debian12:nonroot` is used, not `scratch` or `alpine`; the CA-bundle rationale is stated in both the Dockerfile comment and `docs/docker.md`.
  2. **Non-root** — the image runs as uid `65532` unconditionally; `docker-compose.yml` and `docs/docker.md` both cover bind-mount ownership.
  3. **Network bind** — `ZIGBASE_HTTP_HOST=0.0.0.0` is baked into the image `ENV`, and `docs/docker.md` explains why this override is safe in a container context specifically (not a blanket "we turned off a security default").
  4. **`--insecure-cookies` posture** — confirm the image does NOT bake in `ZIGBASE_COOKIE_SECURE=false`; it's opt-in via `-e`/compose, matching bare-metal's `--insecure-cookies` semantics exactly.
  5. **Healthcheck** — confirm the final decision (orchestrator-native HTTP probe against `/api/health`, no in-image `HEALTHCHECK` instruction, `docker-compose.yml`'s `/zigbase version` as a lightweight liveness-only fallback) is consistently represented across the Dockerfile (no `HEALTHCHECK` line), `docker-compose.yml`, and `docs/docker.md` — no file should imply a `curl`-based in-image healthcheck exists.
  6. **Tags** — `latest`/`X.Y.Z`/`X.Y`/`X` all present in the `metadata-action` config; `download.astro`'s copy matches whatever prefix convention (`v`-stripped or not) the metadata-action patterns actually produce — verify this wasn't left as a guess from Task 4.
  7. **Registry / secrets** — confirm no new repo secret was introduced anywhere (only `secrets.GITHUB_TOKEN`, already available); the GHCR-public-visibility manual step is documented as a one-time follow-up, not silently skipped.
  8. **Multi-arch mechanism** — confirm the `TARGETARCH`-driven `COPY` resolution flagged as higher-risk in Task 2 was actually resolved correctly (re-read the final Dockerfile `ARG`/`COPY` lines against the final workflow YAML's context-staging step; if CI verification (a real tag push) hasn't happened yet because this is pre-merge, say so explicitly here rather than asserting untested confidence).
  9. **Trigger** — the `docker` job lives inside `release.yml` on the `v[0-9]*` tag, depends on `build`, not a new standalone workflow file.
  10. **Zero-arg `docker run`** — `ENTRYPOINT`/`CMD` produce `serve` by default; this was exercised in Task 5's verification (or explicitly deferred to CI per Task 5's fallback branch, not silently unverified).
- [ ] Confirm every doc/site file touched has its required mirror: `docs/docker.md` ↔ `site/src/content/docs/docker.md`, `sidebar.ts` entry present, `site && npm run build` was actually run and passed (re-run if any Task 3/4 edit happened after the last build check).
- [ ] Write a short summary (in the final commit body or as a comment for the PR description — not a new file) listing: the base image + why, the healthcheck decision + why it's a judgment call flagged for the repo owner, the tag scheme, the workflow trigger choice, and the one manual post-merge step (GHCR package visibility).
- [ ] Final verification pass, in order:
  1. `mise exec zig@0.16.0 -- zig build test --summary all` → `Build Summary: … passed` (expected unchanged — no `.zig` files touched by this plan).
  2. `cd site && mise exec node@24 -- npm run build` → success.
  3. If a Docker daemon is available: repeat Task 5's build → run → `curl /api/health` → teardown sequence once more end-to-end as a final sanity check.
  4. `git log --oneline -6` → six commits (Tasks 1–5 plus this task, or fewer if Task 6 made no code changes and only reviewed).
- [ ] `git add -A && git commit -m "docker: self-review fixups" --allow-empty` (only if no fixups were needed; otherwise the fixup diff carries a descriptive message instead of this generic one).

---

## Self-review: design-note decision map

- **Base image:** `distroless/static-debian12:nonroot` — decided in the design note, implemented in Task 1, cross-checked in Task 6 item 1. Rationale: static musl binary needs no libc, but outbound TLS (`src/mail/mailer.zig`'s `Certificate.Bundle.rescan`, plus Postgres/OAuth2/Sentry TLS clients) needs the system CA bundle that `scratch` lacks and `distroless/static` ships.
- **Data volume:** `/data`, `ZIGBASE_DATA_DIR=/data`, `VOLUME` declared, fixed uid `65532`, bind-mount chown caveat documented — Task 1 (Dockerfile), Task 3 (`docker-compose.yml` + `docs/docker.md`), Task 6 item 2.
- **Network bind:** `ZIGBASE_HTTP_HOST=0.0.0.0` baked in with an explicit "why this is still safe" explanation (container boundary replaces loopback's role) — Task 1, Task 3 (`docs/docker.md`), Task 6 item 3. Grounded in `src/config.zig`'s confirmed loopback default.
- **`--insecure-cookies`:** left as a runtime opt-in, never baked into the image — Task 1 (absent from `ENV`), Task 3 (`docker-compose.yml` demonstrates the opt-in + `docs/docker.md` explains it), Task 6 item 4.
- **Tag scheme:** `latest`/`X.Y.Z`/`X.Y`/`X` via `docker/metadata-action` — Task 2, cross-checked against `download.astro`'s copy in Task 4, verified in Task 6 item 6.
- **Registry:** GHCR only, `GITHUB_TOKEN`, no new secrets, one manual visibility step documented — Task 2, Task 6 item 7.
- **Multi-arch mechanism:** `buildx` + staged binaries from the existing `build` job's artifacts, `TARGETARCH`-driven `COPY`, no in-image compilation — Task 1, Task 2 (flagged as the plan's highest execution-order risk), Task 6 item 8.
- **Healthcheck:** no in-image `HEALTHCHECK` (distroless has no curl/shell); orchestrator-native HTTP probes against `/api/health` recommended; `docker-compose.yml` uses a lightweight `/zigbase version` liveness-only fallback; explicitly flagged as a judgment call for the repo owner rather than a closed decision — design note, Task 3 (`docs/docker.md` "Healthchecks" section + compose comment), Task 6 item 5.
- **Trigger:** appended `docker` job inside `.github/workflows/release.yml` on the existing `v[0-9]*` tag push, `needs: build` (reuses artifacts, no rebuild) — design note, Task 2, Task 6 item 9.
- **Zero-arg `docker run`:** `ENTRYPOINT ["/zigbase"]` + `CMD ["serve"]` — Task 1, verified (or explicitly deferred with reason) in Task 5, re-confirmed in Task 6 item 10.
- **Docs/site sync:** `docs/docker.md` + site mirror + sidebar entry (Task 3); README, `KNOWN_LIMITATIONS.md`, `compare.astro`, `download.astro` (Task 4); changelog fragment (Task 5); full cross-check (Task 6) — per the repo's standing "keep docs and site in sync every PR" requirement.
- **Local verification story:** Docker-available branch does a real `build → run → curl /api/health → teardown`; Docker-unavailable branch does a syntax/lint-only check and explicitly defers full verification to the CI `docker` job, which always has a Docker daemon on `ubuntu-latest` — Task 5, both branches documented rather than one silently assumed.
