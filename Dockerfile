# syntax=docker/dockerfile:1
# The openOMSI dedicated server in a container (docs/DOCKER.md). Two ways to put the program in:
#
#   docker build -t openomsi-server .
#       compiles this checkout (BINARY=source, the default), for this machine's own architecture
#       (a quarter of an hour or so; the final link prints nothing for several minutes)
#   docker build --build-arg BINARY=release --build-arg OPENOMSI_VERSION=0.1.1541 -t openomsi-server .
#       takes that release's Linux server download from GitHub (what the published image holds)
#
# The image has no game content: the original OMSI 2 is mounted at /omsi2 when it runs, and
# /data is the server's folder (server.cfg, mods, the game's own data).

ARG BINARY=source
ARG OPENOMSI_VERSION=
ARG OPENOMSI_REPO=openOMSI-Project/openOMSI

# ---- the program compiled from this checkout ----
FROM rust:1-trixie AS bin-source
ARG OPENOMSI_VERSION
ARG CARGO_BUILD_JOBS=
ARG TARGETARCH
RUN apt-get update \
 && apt-get install -y --no-install-recommends pkg-config libasound2-dev libudev-dev \
 && rm -rf /var/lib/apt/lists/*
# (build.rs stamps the commit and whether the tree is changed: a Windows checkout's line ends
# are not a change, and the files belong to another user here)
RUN git config --global --add safe.directory '*' \
 && git config --global core.autocrlf input
WORKDIR /src
COPY . .
# OPENOMSI_VERSION, when given, is the version the program says; else it is worked out as
# scripts/version.sh does (VERSION and the commits since it changed, from .git), as the build
# scripts pass it. CARGO_BUILD_JOBS keeps a small Docker VM from running out of memory.
# Steam's library goes beside the x86-64 program, which does not start without it.
RUN --mount=type=cache,id=omsi-cargo-registry,target=/usr/local/cargo/registry \
    --mount=type=cache,id=omsi-cargo-git,target=/usr/local/cargo/git \
    --mount=type=cache,id=omsi-target-${TARGETARCH},target=/src/target \
    set -eu; \
    [ -n "${CARGO_BUILD_JOBS:-}" ] || unset CARGO_BUILD_JOBS; \
    if [ -z "${OPENOMSI_VERSION:-}" ]; then \
      base=$(tr -d ' \r\n' < VERSION); \
      last=$(git log -1 --format=%H -- VERSION 2>/dev/null || true); \
      n=0; \
      if [ -n "$last" ]; then n=$(git rev-list --count "$last..HEAD"); fi; \
      OPENOMSI_VERSION="$base.$n"; \
    fi; \
    export OPENOMSI_VERSION; \
    echo "building openOMSI $OPENOMSI_VERSION"; \
    cargo build --locked --release -p omsi-app -p omsi-launcher-core; \
    mkdir -p /out; \
    cp target/release/openomsi target/release/openomsi-launcher LICENSE /out/; \
    if [ "$TARGETARCH" = amd64 ]; then cp assets/steam_redist/libsteam_api.so /out/; fi

# ---- the program from a published release (downloaded on the build machine, no emulation) ----
FROM --platform=$BUILDPLATFORM debian:trixie-slim AS bin-release
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ARG OPENOMSI_VERSION
ARG OPENOMSI_REPO
ARG TARGETARCH
# the SHA-256 GitHub lists for the files (optional; the workflow passes them)
ARG SHA256_SERVER_X64=
ARG SHA256_SERVER_ARM64=
ARG SHA256_CLIENT_X64=
ARG SHA256_CLIENT_ARM64=
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl unzip \
 && rm -rf /var/lib/apt/lists/*
# the server download has the program and Steam's library; openomsi-launcher (the mod
# installer for a terminal) is only in the game's Linux download, so it comes from there
RUN set -eu; \
    v="${OPENOMSI_VERSION#v}"; \
    if [ -z "$v" ]; then echo "BINARY=release needs --build-arg OPENOMSI_VERSION=<version>, e.g. 0.1.1541" >&2; exit 1; fi; \
    case "$TARGETARCH" in \
      amd64) arch=x64; server_sum="$SHA256_SERVER_X64"; client_sum="$SHA256_CLIENT_X64" ;; \
      arm64) arch=arm64; server_sum="$SHA256_SERVER_ARM64"; client_sum="$SHA256_CLIENT_ARM64" ;; \
      *) echo "openOMSI has no Linux server for $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    base="https://github.com/$OPENOMSI_REPO/releases/download/v$v"; \
    get=/tmp/get; \
    mkdir -p "$get" /out; \
    curl -fsSL --retry 3 -o "$get/server.zip" "$base/openOMSI-$v-server-linux-$arch.zip"; \
    curl -fsSL --retry 3 -o "$get/game.zip" "$base/openOMSI-$v-linux-$arch.zip"; \
    if [ -n "$server_sum" ]; then echo "${server_sum#sha256:}  $get/server.zip" | sha256sum -c -; fi; \
    if [ -n "$client_sum" ]; then echo "${client_sum#sha256:}  $get/game.zip" | sha256sum -c -; fi; \
    unzip -q "$get/server.zip" -d "$get/server"; \
    unzip -q "$get/game.zip" openomsi-launcher -d "$get/game"; \
    cp "$get/server/openomsi" "$get/server/LICENSE" "$get/game/openomsi-launcher" /out/; \
    if [ -f "$get/server/libsteam_api.so" ]; then cp "$get/server/libsteam_api.so" /out/; fi; \
    chmod 755 /out/openomsi /out/openomsi-launcher; \
    rm -rf "$get"

# (a stage of this file, not an image to pin)
# hadolint ignore=DL3006
FROM bin-${BINARY} AS bin

# ---- the server ----
FROM debian:trixie-slim AS runtime
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
# libasound2 and libudev1: the program links them (sound and game controllers, both unused by
# a server, but the loader wants them); tzdata: a real_time clock follows TZ; ca-certificates:
# cloudflared, the quick tunnel; curl: the health check and the admin helper; tini: PID 1,
# which hands docker stop's signal on (the server's own handler only comes once its map is in)
RUN apt-get update \
 && apt-get install -y --no-install-recommends libasound2t64 libudev1 tzdata ca-certificates curl tini \
 && rm -rf /var/lib/apt/lists/*
# the server runs as user 1000; /data belongs to it, so a new named volume does too
RUN groupadd --gid 1000 openomsi \
 && useradd --uid 1000 --gid 1000 --home-dir /data --no-create-home --shell /usr/sbin/nologin openomsi \
 && mkdir -p /data /omsi2 \
 && chown 1000:1000 /data
COPY --from=bin /out/ /opt/openomsi/
COPY docker/entrypoint.sh /opt/openomsi/docker-entrypoint.sh
COPY docker/omsi-health docker/omsi-admin docker/omsi-status /opt/openomsi/
# (a Windows checkout may have given the scripts CRLF line ends)
RUN for f in docker-entrypoint.sh omsi-health omsi-admin omsi-status; do \
      sed -i 's/\r$//' "/opt/openomsi/$f" && chmod 755 "/opt/openomsi/$f"; \
    done
# Checks while building: every library the programs need is here, the program starts, and the
# server.cfg it writes with every key and its meaning (before it looks for OMSI 2 and, finding
# none, stops with exit code 1) becomes the template for /data/server.cfg. Never done when the
# container starts: with OMSI 2 mounted the program would find it and host a session.
RUN set -eu; \
    for b in /opt/openomsi/openomsi /opt/openomsi/openomsi-launcher; do \
      libs=$(ldd "$b"); \
      if printf '%s\n' "$libs" | grep 'not found'; then echo "$b: libraries missing" >&2; exit 1; fi; \
    done; \
    /opt/openomsi/openomsi --version; \
    mkdir -p /tmp/gen; \
    rc=0; \
    env -i HOME=/tmp/gen PATH=/usr/bin:/bin timeout 120 /opt/openomsi/openomsi --root /nonexistent --server /tmp/gen/server.cfg >/tmp/gen/log 2>&1 || rc=$?; \
    if [ "$rc" -ne 1 ] || ! grep -q '^web_port' /tmp/gen/server.cfg; then \
      cat /tmp/gen/log >&2; \
      echo "the program did not write its default server.cfg as expected (exit code $rc)" >&2; \
      exit 1; \
    fi; \
    mv /tmp/gen/server.cfg /opt/openomsi/server.cfg.default; \
    rm -rf /tmp/gen

ENV HOME=/data \
    OMSI_ROOT=/omsi2 \
    OMSI_CONTENT=/data/content \
    OMSI_INSTANCE=server \
    TZ=Etc/UTC \
    PATH=/opt/openomsi:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
WORKDIR /data
USER 1000:1000
# the game (UDP), the server's mods for players who join by address (TCP, the same port), and
# the web port: status, icon, players joining over WebSockets, mods for them
EXPOSE 27015/udp 27015/tcp 27025/tcp
# healthy: the web port answers and the main loop turns (it only starts once the map is in,
# which can take minutes on a big map or a slow disk)
HEALTHCHECK --start-period=15m --start-interval=10s --interval=30s --timeout=10s --retries=3 CMD ["omsi-health"]
LABEL org.opencontainers.image.title="openOMSI dedicated server" \
      org.opencontainers.image.description="The openOMSI dedicated server; mount your own OMSI 2 at /omsi2" \
      org.opencontainers.image.licenses="MIT"
ENTRYPOINT ["tini", "-s", "-g", "--", "/opt/openomsi/docker-entrypoint.sh"]
