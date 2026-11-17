# syntax=docker/dockerfile:1.7
# =============================================================================
# The build helper of scripts/build-image.sh and scripts/build-image.ps1 (ADR 0018).
#
# Purpose: one set of tools for every host, so the only host requirement of a build is Docker.
# The helper runs scripts/resolve-installer.sh (mounted from the repository, never copied in)
# to resolve, download, verify and cache IBKR's installer, and, for the PowerShell wrapper on a
# host without bash, tests/container/run.sh --only ibc-smoke through the Docker socket.
#
# Contents: the official Docker CLI image (CLI, buildx and compose plugins, Alpine), pinned by
# digest, plus bash, curl, jq, GNU coreutils, GNU tar and gzip. Built locally by the wrappers
# as brokersre-ib-gateway-build-helper:local (cached by Docker after the first build); nothing
# from it reaches the gateway image.
#
# apk package versions are not pinned (DL3018), for the reason the gateway image does not pin
# apt versions (.hadolint.yaml): Alpine drops superseded versions from its index, so a pin
# would break the build on the next security update. The base digest is the pin.
# =============================================================================
FROM docker:29.10.0-cli@sha256:34507eb5069d8be82c95dd3b6987d4250fd5fee49b82e2509b7d7a7030740d6d
# hadolint ignore=DL3018
RUN apk add --no-cache bash curl jq coreutils tar gzip
ENTRYPOINT []
CMD ["bash"]
