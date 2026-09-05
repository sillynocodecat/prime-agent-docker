# Prime Agent container image (amd64 only).
#
# Stages:
#   uv       the official distroless uv image; only /uv is copied out
#   fetch    downloads podman-remote and third-party license texts, digest-pinned
#   builder  fetches the pinned upstream source by commit, applies the container
#            patch, runs the upstream + container tests, builds, packs, prunes
#            and stages /opt/prime-agent; then bakes the Python kernel there
#   runtime  the published filesystem: Debian slim + Node, verified runtime
#            packages, the staged tree, rootfs/, ENV contract, labels
#   verify   FROM runtime; runs the kernel and runtime smoke checks and is
#            discarded, so no test script or scratch file ships
#   final    FROM runtime + the verify report, which forces `verify` to run
#
# Every version below is pinned; CI bumps them deliberately. Only the base Node
# image and Debian packages float (the weekly security rebuild refreshes them).
# The Dockerfile uses no engine-specific syntax: it builds identically with
# `docker build` (BuildKit) and `podman build`.

ARG NODE_IMAGE=docker.io/library/node:22-trixie-slim
ARG UV_IMAGE=ghcr.io/astral-sh/uv:0.12.9

ARG PRIME_AGENT_VERSION=0.9.2
ARG PRIME_AGENT_REVISION=9c54a35dac3a2ad17910074d66664859ea175666
ARG UV_VERSION=0.12.9
ARG UV_LICENSE_MIT_SHA256=860e3d7a86b84e6a7012c7a635fc64df475cebc6cce34dfeb73a5982ec58176c
ARG UV_LICENSE_APACHE_SHA256=c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4
ARG PODMAN_VERSION=6.1.1
ARG PODMAN_REMOTE_AMD64_SHA256=31ff7c653fc19e652e648f45406c5b72925defdf8fc73af698ce2512e87ee502
ARG PODMAN_LICENSE_SHA256=62fb8a3a9621dc2388174caaabe9c2317b694bb9a1d46c98bcf5655b68f51be3
# The workflow owns the final source URL; the default matches the chosen owner.
ARG IMAGE_SOURCE=https://github.com/sillynocodecat/prime-agent-docker

# ---------------------------------------------------------------------------
FROM ${UV_IMAGE} AS uv

# ---------------------------------------------------------------------------
FROM ${NODE_IMAGE} AS fetch
ARG PODMAN_VERSION
ARG PODMAN_REMOTE_AMD64_SHA256
ARG PODMAN_LICENSE_SHA256
ARG UV_VERSION
ARG UV_LICENSE_MIT_SHA256
ARG UV_LICENSE_APACHE_SHA256
RUN export DEBIAN_FRONTEND=noninteractive \
 && apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl tar gzip \
 && rm -rf /var/lib/apt/lists/*
COPY build/fetch-third-party.sh /build/fetch-third-party.sh
RUN OUT_DIR=/out \
    PODMAN_VERSION="$PODMAN_VERSION" \
    PODMAN_REMOTE_AMD64_SHA256="$PODMAN_REMOTE_AMD64_SHA256" \
    PODMAN_LICENSE_SHA256="$PODMAN_LICENSE_SHA256" \
    UV_VERSION="$UV_VERSION" \
    UV_LICENSE_MIT_SHA256="$UV_LICENSE_MIT_SHA256" \
    UV_LICENSE_APACHE_SHA256="$UV_LICENSE_APACHE_SHA256" \
    bash /build/fetch-third-party.sh

# ---------------------------------------------------------------------------
FROM ${NODE_IMAGE} AS builder
ARG PRIME_AGENT_VERSION
ARG PRIME_AGENT_REVISION
# Build-only tools: the source archive needs curl/tar/gzip, the container patch
# needs patch. No compiler or Python toolchain: every native module in the
# lockfile installs from a prebuild (proven in the §1 probes).
RUN export DEBIAN_FRONTEND=noninteractive \
 && apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl tar gzip patch \
 && rm -rf /var/lib/apt/lists/*
COPY --from=uv /uv /usr/local/bin/uv
# Only the builder's own inputs: a change to the runtime smoke scripts or the
# CI assets must not invalidate the cached npm ci / test / build layers.
COPY prime-agent-container.patch build/build-prime-agent.sh build/bootstrap-kernel.mjs /build/
COPY build/tests/ /build/tests/
# Validates the version/revision, downloads by commit, checks the declared
# package versions, applies the patch with zero fuzz, runs the tests, builds,
# packs, prunes, stages /opt/prime-agent and verifies the staged tree.
RUN PRIME_AGENT_VERSION="$PRIME_AGENT_VERSION" \
    PRIME_AGENT_REVISION="$PRIME_AGENT_REVISION" \
    bash /build/build-prime-agent.sh
# The kernel is bootstrapped at its final /opt/prime-agent paths so the
# editable skill installs and the bootstrap hashes stay valid after this stage
# is discarded. PRIME_AGENT_KERNEL_PYTHON must stay unset (it would disable
# Python-backed skill installs).
ENV UV_PYTHON_INSTALL_DIR=/opt/prime-agent/python \
    PRIME_AGENT_KERNEL_VENV=/opt/prime-agent/kernel-venv
RUN node /build/bootstrap-kernel.mjs

# ---------------------------------------------------------------------------
FROM ${NODE_IMAGE} AS runtime
ARG PRIME_AGENT_VERSION
ARG PRIME_AGENT_REVISION
ARG NODE_IMAGE
ARG IMAGE_SOURCE
# Runtime packages only, each justified in PLAN.md: iproute2 supplies `ss` for
# upstream daemon discovery, tzdata backs five-field cron schedules under TZ,
# fd-find installs as `fdfind`. DEBIAN_FRONTEND is scoped to this RUN.
RUN export DEBIAN_FRONTEND=noninteractive \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates bash curl git openssh-client ripgrep fd-find procps iproute2 tzdata tar gzip \
 && rm -rf /var/lib/apt/lists/* \
 && if ! command -v fd >/dev/null 2>&1; then ln -s /usr/bin/fdfind /usr/local/bin/fd; fi \
 && fd --version \
 && git config --system --add safe.directory /work \
 && mkdir -p /work /data /etc/prime-agent \
 && mkdir -p /usr/share/licenses/prime-agent /usr/share/licenses/prime-agent-docker
COPY --from=uv /uv /usr/local/bin/uv
COPY --from=fetch /out/bin/podman-remote /usr/local/bin/podman-remote
COPY --from=fetch /out/licenses/ /usr/share/licenses/
COPY --from=builder /opt/prime-agent /opt/prime-agent
COPY --from=builder /opt/prime-agent/LICENSE /usr/share/licenses/prime-agent/LICENSE
COPY THIRD_PARTY_NOTICES.md /usr/share/licenses/prime-agent-docker/THIRD_PARTY_NOTICES.md
# Container-owned files: the CLI wrapper (client-lease mode) and the service
# controller that is the image entrypoint.
COPY rootfs/ /
RUN chmod 0755 /usr/local/bin/prime-agent /usr/local/bin/podman-remote /usr/local/bin/uv \
 && chmod 0644 /usr/local/lib/prime-agent-container/service.mjs \
 && node --check /usr/local/lib/prime-agent-container/service.mjs

# Image environment contract (PLAN.md "Runtime image"). The host launcher
# re-asserts PATH/HOME/TMPDIR after any user env-file; TZ is supplied by the
# launcher at container creation.
ENV PATH=/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin \
    HOME=/root \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TMPDIR=/tmp \
    TMP=/tmp \
    TEMP=/tmp \
    PRIME_AGENT_CODING_AGENT_DIR=/data \
    PRIME_AGENT_KERNEL_VENV=/opt/prime-agent/kernel-venv \
    UV_PYTHON_INSTALL_DIR=/opt/prime-agent/python \
    PRIME_AGENT_CONTAINER_CONFIG_DIR=/etc/prime-agent \
    PRIME_AGENT_BUILD_ID=${PRIME_AGENT_REVISION} \
    PRIME_AGENT_LAUNCHER_PATH=/usr/local/bin/prime-agent \
    PI_OAUTH_CALLBACK_HOST=0.0.0.0 \
    PI_MCP_OAUTH_CALLBACK_PORT=53700 \
    PI_SKIP_VERSION_CHECK=1

WORKDIR /work

# OAuth callback listeners: ChatGPT (1455), Anthropic (53692), MCP base port
# plus nine fallbacks (53700-53709). EXPOSE range syntax is not portable, so
# every port is enumerated; the launcher publishes them on host loopback.
EXPOSE 1455/tcp 53692/tcp \
       53700/tcp 53701/tcp 53702/tcp 53703/tcp 53704/tcp \
       53705/tcp 53706/tcp 53707/tcp 53708/tcp 53709/tcp

# No org.opencontainers.image.licenses: the repository declares no license.
# version/revision describe the packaged Prime Agent release.
LABEL org.opencontainers.image.title="prime-agent-docker" \
      org.opencontainers.image.description="Prime Agent ${PRIME_AGENT_VERSION} as a self-managing Docker/Podman appliance: staged source build, baked Python kernel, lifecycle service entrypoint" \
      org.opencontainers.image.source="${IMAGE_SOURCE}" \
      org.opencontainers.image.url="${IMAGE_SOURCE}" \
      org.opencontainers.image.version="${PRIME_AGENT_VERSION}" \
      org.opencontainers.image.revision="${PRIME_AGENT_REVISION}" \
      org.opencontainers.image.base.name="${NODE_IMAGE}" \
      io.github.sillynocodecat.prime-agent-docker.runtime-schema="1" \
      io.github.sillynocodecat.prime-agent-docker.upstream-version="${PRIME_AGENT_VERSION}" \
      io.github.sillynocodecat.prime-agent-docker.upstream-revision="${PRIME_AGENT_REVISION}"

# The service controller is the entrypoint; the real CLI stays available for
# `exec` through /usr/local/bin/prime-agent. Running this image without the
# launcher contract (tmpfs at /run/prime-agent-container and /tmp) exits 70.
ENTRYPOINT ["/usr/local/bin/node", "/usr/local/lib/prime-agent-container/service.mjs"]

# ---------------------------------------------------------------------------
FROM runtime AS verify
ARG PRIME_AGENT_VERSION
ARG PRIME_AGENT_REVISION
ARG UV_VERSION
ARG PODMAN_VERSION
COPY build/verify-kernel.mjs build/verify-lifecycle-json.mjs build/smoke-runtime.sh /verify/
# Kernel: baked venv imports, no second bootstrap offline (decoy uv), and the
# first-start scenario with catalog-gated skills hidden. Lifecycle: the real
# daemon's public JSON must still satisfy the service controller's interpreters
# (drift in a new upstream release fails the build here). Then every runtime
# smoke check; the report is the only artifact that reaches the final image.
RUN node /verify/verify-kernel.mjs \
 && node /verify/verify-kernel.mjs --first-start \
 && PRIME_AGENT_VERSION="$PRIME_AGENT_VERSION" node /verify/verify-lifecycle-json.mjs \
 && REPORT=/verified/report.txt \
    PRIME_AGENT_VERSION="$PRIME_AGENT_VERSION" \
    PRIME_AGENT_REVISION="$PRIME_AGENT_REVISION" \
    UV_VERSION="$UV_VERSION" \
    PODMAN_VERSION="$PODMAN_VERSION" \
    bash /verify/smoke-runtime.sh

# ---------------------------------------------------------------------------
FROM runtime AS final
COPY --from=verify /verified/report.txt /usr/share/doc/prime-agent-docker/build-report.txt
