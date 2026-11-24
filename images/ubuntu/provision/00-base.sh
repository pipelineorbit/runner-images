#!/usr/bin/env bash
# Base system: checks the builder is the requested Ubuntu release and
# architecture, turns off automatic apt updates, installs all updates and the
# base tools.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

log "waiting for cloud-init to finish the first boot"
cloud-init status --wait >/dev/null || log "cloud-init status exited with $? (continuing)"

[[ $VERSION_ID == "$UBUNTU_VERSION" ]] ||
  die "the base image is Ubuntu $VERSION_ID, but ubuntu_version is $UBUNTU_VERSION"
[[ $(dpkg --print-architecture) == "$(arch_name deb)" ]] ||
  die "the builder is $(dpkg --print-architecture), but arch is $ARCH (pick a matching server type)"

# Jobs must never find apt locked by a background update. Security fixes come
# from rebuilding the image instead. Doing this first also keeps the timers out
# of the way during the build. needrestart goes too: after an apt install it can
# restart services, Docker included, in the middle of a job.
log "turning off unattended-upgrades and the apt-daily timers, removing needrestart"
systemctl mask --now apt-daily.timer apt-daily-upgrade.timer apt-daily.service apt-daily-upgrade.service
apt_purge unattended-upgrades needrestart

log "installing updates"
apt_get update
apt_get full-upgrade -y --no-install-recommends

log "installing base packages"
apt_install \
  git git-lfs curl wget jq zip unzip tar zstd xz-utils rsync openssh-client \
  ca-certificates gnupg build-essential pkg-config python3 python3-venv python3-pip

log "done"
