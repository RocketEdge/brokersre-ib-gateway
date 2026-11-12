# brokersre-ib-gateway-sidecar: read-only API probe, status API, Prometheus metrics and
# human-escalation notifier for the brokersre IB Gateway image.
#
# Build (context = this directory):  docker build -t brokersre-ib-gateway-sidecar:dev sidecar
#
# Base image: python:3.14-slim (Debian trixie), pinned by the digest of its multi-arch index.
#   Why not distroless: gcr.io/distroless/python3-debian13 ships Python 3.13 (checked
#   2026-11-12), and the package requires 3.14. Why not Alpine: pydantic-core and numpy
#   (a dependency of ib_async's event library) ship manylinux wheels; musl would mean
#   compiling or trusting a second wheel family for no gain.
# uv: copied from the official image, pinned by digest; it exists in the build stage only.
# Dependabot (docker ecosystem) proposes new digests; nothing updates by itself.
ARG PYTHON_IMAGE=python:3.14-slim@sha256:9aaa474097d094040649f2162a627c0049b408f52138d980916788d80f04802f
ARG UV_IMAGE=ghcr.io/astral-sh/uv:0.13.7@sha256:96f40d3904aad8d0bd010539001d36c8e2188b981e1334471a90c4a1d93bb490

FROM ${UV_IMAGE} AS uv

# ---- build: resolve nothing, install exactly uv.lock into /opt/sidecar ----------------------
FROM ${PYTHON_IMAGE} AS build
COPY --from=uv /uv /usr/local/bin/uv
# --frozen: fail instead of re-resolving. Bytecode is compiled here because the runtime root
# file system is read-only. The virtual environment uses the image's own interpreter, which is
# at the same path in the runtime stage (same base image).
ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PYTHON_DOWNLOADS=never \
    UV_PROJECT_ENVIRONMENT=/opt/sidecar \
    UV_NO_CACHE=1
WORKDIR /src
COPY pyproject.toml uv.lock README.md ./
RUN uv sync --frozen --no-dev --no-install-project
COPY src ./src
RUN uv sync --frozen --no-dev --no-editable

# ---- runtime ------------------------------------------------------------------------------
FROM ${PYTHON_IMAGE} AS runtime

ARG VERSION=0.1.0
ARG REVISION=unknown
ARG CREATED=unknown

LABEL org.opencontainers.image.title="brokersre-ib-gateway-sidecar" \
      org.opencontainers.image.description="Optional companion of brokersre-ib-gateway: read-only API probe, /livez /readyz /status /metrics, and notifications that escalate to a human. It never places orders, never automates 2FA and never restarts the gateway. Interactive Brokers, IBKR, IB Gateway and Trader Workstation are trademarks of Interactive Brokers LLC. This project is not affiliated with, endorsed by or sponsored by Interactive Brokers." \
      org.opencontainers.image.source="https://github.com/RocketEdge/brokersre-ib-gateway" \
      org.opencontainers.image.url="https://github.com/RocketEdge/brokersre-ib-gateway/tree/main/sidecar" \
      org.opencontainers.image.documentation="https://github.com/RocketEdge/brokersre-ib-gateway/blob/main/sidecar/README.md" \
      org.opencontainers.image.vendor="RocketEdge.com" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${REVISION}" \
      org.opencontainers.image.created="${CREATED}" \
      com.rocketedge.brokersre.sidecar.status-schema="brokersre.sidecar.status.v1"

# uid 1000 like the gateway, so the shared log volume is readable. pip is removed: nothing is
# installed at run time, and an installer in the image is attack surface with CVEs of its own.
# /var/lib/sidecar is created owned by uid 1000 so a named volume mounted there is writable.
RUN groupadd --gid 1000 sidecar \
 && useradd --uid 1000 --gid 1000 --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin sidecar \
 && mkdir -p /var/lib/sidecar /var/log/ibgateway \
 && chown 1000:1000 /var/lib/sidecar \
 && python -m pip uninstall --yes pip

COPY --from=build /opt/sidecar /opt/sidecar

ENV PATH=/opt/sidecar/bin:${PATH} \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

USER 1000:1000
WORKDIR /
EXPOSE 9810

# No init process: the sidecar is PID 1, installs its own SIGTERM/SIGINT handlers, stops
# within a few seconds and starts no child process (nothing to reap).
STOPSIGNAL SIGTERM

# Liveness only: unhealthy means the sidecar itself is broken, never that the gateway is.
# Standard-library client, so each run costs a few milliseconds.
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD ["brokersre-sidecar", "healthcheck"]

ENTRYPOINT ["brokersre-sidecar"]
CMD ["run"]
