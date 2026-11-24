#!/usr/bin/env bash
# Docker Engine with the buildx and compose plugins, from Docker's apt
# repository (not Ubuntu's docker.io).
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

add_apt_repo docker https://download.docker.com/linux/ubuntu/gpg \
  https://download.docker.com/linux/ubuntu "$VERSION_CODENAME" stable
apt_get update

docker_ce=$(apt_version docker-ce "$DOCKER_VERSION")
docker_cli=$(apt_version docker-ce-cli "$DOCKER_VERSION")
containerd=$(apt_version containerd.io "$CONTAINERD_VERSION")
buildx=$(apt_version docker-buildx-plugin "$BUILDX_VERSION")
compose=$(apt_version docker-compose-plugin "$COMPOSE_VERSION")

log "installing Docker $DOCKER_VERSION"
apt_install \
  "docker-ce=$docker_ce" "docker-ce-cli=$docker_cli" "containerd.io=$containerd" \
  "docker-buildx-plugin=$buildx" "docker-compose-plugin=$compose"
systemctl enable docker.service containerd.service

log "adding runner to the docker group"
usermod -aG docker runner

log "done"
