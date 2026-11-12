# syntax=docker/dockerfile:1.7
# =============================================================================
# brokersre-ib-gateway: IB Gateway + IBC, built for unattended, observable operation.
#
# One parametrised Dockerfile for both IBKR channels (stable/latest); every input is pinned in
# versions.json and verified by SHA-256 here (IBKR publishes no checksums, so a build fails
# loudly if IBKR's unversioned URL ever serves different bytes). Derived from
# gnzsnz/ib-gateway-docker (MIT) and restructured: no sudo, read-only root filesystem,
# HEALTHCHECK, IBC command server on loopback, structured JSON stdout, tini as PID 1.
#
# apt package versions are deliberately not pinned (DL3008): Ubuntu security updates would
# otherwise force a version bump on every rebuild; the runtime stage runs `apt-get upgrade`,
# so the monthly rebuild picks them up (base packages included) and Trivy gates the result.
# hadolint global ignore=DL3008
# =============================================================================
ARG UBUNTU_DIGEST=sha256:6a06111c3b0a8600feadb270aec771dc239bf407b25625f93f44ab00e11f4d3c

# -----------------------------------------------------------------------------
# Stage 1: download, verify and unpack IB Gateway and IBC (nothing from here but the
# installed trees reaches the final image).
# -----------------------------------------------------------------------------
FROM ubuntu:26.04@${UBUNTU_DIGEST} AS setup
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ARG IB_GATEWAY_CHANNEL=stable
ARG IB_GATEWAY_VERSION
ARG IB_GATEWAY_SHA256_X64
ARG IB_GATEWAY_SHA256_ARM
ARG IB_GATEWAY_URL_BASE=https://download2.interactivebrokers.com/installers/ibgateway
ARG IBC_VERSION
ARG IBC_RELEASE_TAG
ARG IBC_SHA256
ARG IBC_RELEASE_BASE=https://github.com/RocketEdge/ibc/releases/download
ARG JAVA_HEAP_MB=768
ARG TARGETARCH
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl unzip \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /tmp/setup
# Optional pre-fetched installer (CI puts the private-archive copy here when IBKR's channel
# URL has already moved on); the directory is empty in a normal build.
COPY downloads/ /tmp/downloads/
COPY scripts/fetch-installer.sh /tmp/setup/fetch-installer.sh
RUN chmod +x /tmp/setup/fetch-installer.sh && /tmp/setup/fetch-installer.sh /tmp/setup/ibgateway.sh
RUN chmod +x /tmp/setup/ibgateway.sh \
 && /tmp/setup/ibgateway.sh -q -dir "/home/ibgateway/Jts/ibgateway/${IB_GATEWAY_VERSION}" \
 && install_dir="/home/ibgateway/Jts/ibgateway/${IB_GATEWAY_VERSION}" \
 && if [ -d "${install_dir}/jre" ]; then echo "${install_dir}/jre" > "${install_dir}/.install4j/inst_jre.cfg"; fi \
 && sed -i "s/-Xmx768m/-Xmx${JAVA_HEAP_MB}m/" "${install_dir}/ibgateway.vmoptions" \
 && rm -f /tmp/setup/ibgateway.sh
RUN curl -fsSL "${IBC_RELEASE_BASE}/${IBC_RELEASE_TAG}/IBCLinux-${IBC_VERSION}.zip" -o /tmp/setup/ibc.zip \
 && echo "${IBC_SHA256}  /tmp/setup/ibc.zip" | sha256sum -c - \
 && mkdir -p /opt/ibc \
 && unzip -q /tmp/setup/ibc.zip -d /opt/ibc \
 && chmod -R u+x /opt/ibc/*.sh /opt/ibc/scripts/*.sh \
 && rm -f /tmp/setup/ibc.zip

# -----------------------------------------------------------------------------
# Stage 2: runtime image.
# -----------------------------------------------------------------------------
FROM ubuntu:26.04@${UBUNTU_DIGEST}
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ARG IB_GATEWAY_CHANNEL=stable
ARG IB_GATEWAY_VERSION
ARG IBC_VERSION
ARG IBC_RELEASE_TAG
ARG TARGETARCH
ENV DEBIAN_FRONTEND=noninteractive
# No sudo, no SSH, no telnet: the Gateway user owns only the paths it must write.
# `apt-get upgrade` first: packages that ship inside the pinned ubuntu digest (apt itself,
# libapt-pkg, ...) are otherwise never patched, because installing other packages does not
# upgrade them and Docker Hub rebuilds ubuntu:26.04 only every few weeks. Without it the
# monthly OS-patch rebuild cannot clear a base CVE (2026-11-09: apt CVE-2026-109518, HIGH,
# fixed in 3.2.1ubuntu0.1, failed the Trivy gate while the base digest was still current).
RUN apt-get update \
 && apt-get upgrade -y --no-install-recommends \
 && apt-get install -y --no-install-recommends \
      tini xvfb x11vnc socat gettext-base ca-certificates jq procps iproute2 \
      libatk-bridge2.0-0 libatk1.0-0 libatspi2.0-0 libc6 libcairo2 libcups2 libdbus-1-3 \
      libdrm2 libexpat1 libgbm1 libglib2.0-0 libgtk-3-0 libnspr4 libnss3 libpango-1.0-0 \
      libx11-6 libxcb1 libxcomposite1 libxdamage1 libxext6 libxfixes3 libxkbcommon0 \
      libxrandr2 fonts-liberation libasound2t64 libxtst6 xdg-utils \
 && if [ "${TARGETARCH}" = "arm64" ]; then apt-get install -y --no-install-recommends openjdk-25-jre; fi \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/* \
 && if id ubuntu >/dev/null 2>&1; then userdel -r ubuntu; fi \
 && groupadd --gid 1000 ibgateway \
 && useradd --uid 1000 --gid 1000 --create-home --shell /bin/bash ibgateway \
 && mkdir -p /var/log/ibgateway /run/brokersre /tmp/.X11-unix /usr/share/doc/ibc \
 && chmod 1777 /tmp/.X11-unix \
 && chown -R 1000:1000 /var/log/ibgateway /run/brokersre
COPY --from=setup --chown=1000:1000 /home/ibgateway /home/ibgateway
COPY --from=setup --chown=1000:1000 /opt/ibc /opt/ibc
COPY rootfs/ /
RUN chmod 0755 /usr/local/bin/*.sh /usr/local/lib/brokersre/*.sh \
 && ln -s /usr/local/lib/brokersre/ibc-cmd.sh /usr/local/bin/ibc-cmd \
 && install -m 0644 /opt/ibc/LICENSE.txt /usr/share/doc/ibc/LICENSE.txt \
 && mkdir -p /home/ibgateway/Jts/settings \
 && chown -R 1000:1000 /home/ibgateway/Jts/settings \
 && if [ "${TARGETARCH}" = "arm64" ] && [ ! -d "/home/ibgateway/Jts/ibgateway/${IB_GATEWAY_VERSION}/jre" ]; then \
      echo "/usr/lib/jvm/java-25-openjdk-arm64" > "/home/ibgateway/Jts/ibgateway/${IB_GATEWAY_VERSION}/.install4j/inst_jre.cfg"; \
    fi

ENV HOME=/home/ibgateway \
    IB_GATEWAY_VERSION=${IB_GATEWAY_VERSION} \
    IB_GATEWAY_CHANNEL=${IB_GATEWAY_CHANNEL} \
    IBC_VERSION=${IBC_VERSION} \
    IBC_RELEASE_TAG=${IBC_RELEASE_TAG} \
    TWS_PATH=/home/ibgateway/Jts \
    TWS_SETTINGS_PATH=/home/ibgateway/Jts/settings \
    IBC_PATH=/opt/ibc \
    LOG_DIR=/var/log/ibgateway \
    RUN_DIR=/run/brokersre \
    TRADING_MODE=paper \
    READ_ONLY_API=yes \
    TWOFA_TIMEOUT_ACTION=restart \
    RELOGIN_AFTER_TWOFA_TIMEOUT=yes \
    TWOFA_EXIT_INTERVAL=60 \
    EXISTING_SESSION_DETECTED_ACTION=primary \
    TWS_ACCEPT_INCOMING=reject \
    ALLOW_BLIND_TRADING=no \
    BYPASS_WARNING=yes \
    IBC_COMMAND_SERVER_PORT=7462 \
    IBC_SUPPRESS_INFO_MESSAGES=no \
    IBC_LAUNCH=yes \
    CUSTOM_CONFIG=no \
    TIME_ZONE=Etc/UTC \
    DISPLAY=:1

USER 1000:1000
WORKDIR /home/ibgateway
VOLUME ["/home/ibgateway/Jts/settings", "/var/log/ibgateway"]
# 4003/4004: socat relay of the live/paper API port for the strategy host; 5900: optional VNC.
EXPOSE 4003 4004 5900
HEALTHCHECK --interval=15s --timeout=5s --start-period=300s --retries=3 \
  CMD ["/usr/local/lib/brokersre/healthcheck.sh"]
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]

LABEL org.opencontainers.image.title="brokersre-ib-gateway" \
      org.opencontainers.image.description="IB Gateway ${IB_GATEWAY_VERSION} (${IB_GATEWAY_CHANNEL}) with IBC ${IBC_VERSION}, built for unattended, observable operation. Not affiliated with Interactive Brokers." \
      org.opencontainers.image.source="https://github.com/RocketEdge/brokersre-ib-gateway" \
      org.opencontainers.image.url="https://github.com/RocketEdge/brokersre-ib-gateway/pkgs/container/brokersre-ib-gateway" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.vendor="RocketEdge.com Pte. Ltd." \
      org.opencontainers.image.version="${IB_GATEWAY_VERSION}-${IB_GATEWAY_CHANNEL}" \
      org.opencontainers.image.base.name="docker.io/library/ubuntu:26.04" \
      com.rocketedge.brokersre.ibkr.channel="${IB_GATEWAY_CHANNEL}" \
      com.rocketedge.brokersre.ibc.version="${IBC_VERSION}" \
      com.rocketedge.brokersre.ibc.release="${IBC_RELEASE_TAG}"
