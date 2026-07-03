# syntax=docker/dockerfile:1
#
# Official ZigBase image. Ships the ALREADY-BUILT static-musl release binary —
# this Dockerfile never invokes Zig or compiles anything. The CI workflow
# (.github/workflows/release.yml, `docker` job) stages both arches' binaries in
# a single build context (./docker-ctx/amd64/zigbase, ./docker-ctx/arm64/zigbase)
# before `docker buildx build --platform linux/amd64,linux/arm64` runs; buildx
# sets the TARGETARCH build-arg to "amd64"/"arm64" per target platform, and the
# COPY below picks the matching subdirectory. Local manual builds must stage the
# same layout (see docs/docker.md).
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
#
# ARG TARGETARCH is set automatically by buildx during a multi-platform build
# (resolves to "amd64" or "arm64" per --platform target); the build context
# must contain a matching ${TARGETARCH}/zigbase subpath for each platform built.
ARG TARGETARCH
COPY --chown=65532:65532 ${TARGETARCH}/zigbase /zigbase
VOLUME ["/data"]
WORKDIR /data
USER 65532:65532

EXPOSE 8090

ENTRYPOINT ["/zigbase"]
CMD ["serve"]
