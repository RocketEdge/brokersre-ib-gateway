#!/usr/bin/env bash
# install.sh files | bootstrap   (run from the checkout: /opt/ibgateway/pack/azure/vm/install.sh)
#
# Purpose   Install this commit's host files, and on first boot the container engine.
#   files      Copy the scripts of this directory to /usr/local/sbin, the stack unit to
#              /etc/systemd/system and daemon.json to /etc/docker, then reload systemd.
#              Idempotent; never restarts Docker or the stack. apply-config.sh runs it after
#              every checkout, which is how a fix to these scripts reaches an existing VM.
#   bootstrap  First boot (ibgw-bootstrap.service, see azure/cloud-init/gateway.yaml):
#              files, Docker Engine and the compose plugin from Docker's apt repository,
#              apply-config.sh --initial, then enable and start ibgw-stack.service.
#              Idempotent: safe to run again after a failure at any step.
# Errors    Any failure stops with a non-zero exit code and the failing command's message;
#           the bootstrap unit retries with a growing delay.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
docker_key_fingerprint=9DC858229FC7DD38854AE2D88D81803C0EBFCD88

# install_files: this commit's scripts, unit and daemon configuration into the system paths.
install_files() {
  install -m 0755 -D "${here}/fetch-secrets.sh" /usr/local/sbin/fetch-secrets.sh
  install -m 0755 "${here}/ibgw-compose.sh" /usr/local/sbin/ibgw-compose.sh
  install -m 0755 "${here}/apply-config.sh" /usr/local/sbin/apply-config.sh
  install -m 0644 "${here}/ibgw-stack.service" /etc/systemd/system/ibgw-stack.service
  # Read by the daemon at its next start; Docker is deliberately not restarted here.
  install -m 0644 -D "${here}/daemon.json" /etc/docker/daemon.json
  systemctl daemon-reload
}

# install_docker: Docker Engine and the compose plugin from Docker's own apt repository. The
# repository key is accepted only with Docker's published fingerprint.
install_docker() {
  if docker compose version >/dev/null 2>&1; then return 0; fi
  export DEBIAN_FRONTEND=noninteractive
  install -m 0755 -d /etc/apt/keyrings
  curl --silent --show-error --fail --location --retry 5 --retry-delay 3 --max-time 60 \
    https://download.docker.com/linux/ubuntu/gpg --output /etc/apt/keyrings/docker.asc
  if ! gpg --show-keys --with-colons /etc/apt/keyrings/docker.asc | grep -q "^fpr:.*:${docker_key_fingerprint}:$"; then
    echo "install: the Docker repository key does not have the expected fingerprint" >&2
    rm -f /etc/apt/keyrings/docker.asc
    return 1
  fi
  chmod 0644 /etc/apt/keyrings/docker.asc
  # shellcheck disable=SC1091  # present on every Ubuntu system
  . /etc/os-release
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu %s stable\n' \
    "$(dpkg --print-architecture)" "${UBUNTU_CODENAME:-${VERSION_CODENAME}}" >/etc/apt/sources.list.d/docker.list
  apt-get update
  apt-get install --yes --no-install-recommends docker-ce docker-ce-cli containerd.io docker-compose-plugin
}

case "${1:-}" in
  files)
    install_files
    ;;
  bootstrap)
    install_files
    install_docker
    /usr/local/sbin/apply-config.sh --initial
    systemctl enable chrony.service ibgw-stack.service
    systemctl start --no-block ibgw-stack.service
    ;;
  *)
    echo "usage: install.sh files|bootstrap" >&2
    exit 64
    ;;
esac
