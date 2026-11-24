#!/usr/bin/env bash
# System settings for servers that run one job each: environment variables,
# swap, /tmp, and no background services that compete with jobs.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

# set_env <name> <value>: sets a variable in /etc/environment, which SSH
# sessions and runner-jit.service read.
set_env() {
  if grep -q "^$1=" /etc/environment; then
    sed -i "s|^$1=.*|$1=$2|" /etc/environment
  else
    echo "$1=$2" >>/etc/environment
  fi
}

log "setting ImageOS, ImageVersion and the tool cache in /etc/environment"
set_env ImageOS "$IMAGE_OS"
set_env ImageVersion "$IMAGE_VERSION"
set_env RUNNER_TOOL_CACHE /opt/hostedtoolcache
set_env AGENT_TOOLSDIRECTORY /opt/hostedtoolcache

# cloud-init settings for every new server. Network config is applied only on
# a new server, not on hotplug events: Docker adds interfaces (docker0, one per
# container) and cloud-init's hotplug handler fails on them.
log "cloud-init: no network hotplug, swap ${SWAP_SIZE_GB} GB"
cloud_config=/etc/cloud/cloud.cfg.d/90-runner-image.cfg
cat >"$cloud_config" <<EOF
# From images/ubuntu/provision/50-system-tuning.sh
updates:
  network:
    when: [boot-new-instance]
EOF
if ((SWAP_SIZE_GB > 0)); then
  # cloud-init creates the swap file on first boot, so the image doesn't carry
  # gigabytes of zeros.
  cat >>"$cloud_config" <<EOF
swap:
  filename: /swapfile
  size: ${SWAP_SIZE_GB}G
EOF
fi

# Ubuntu 26.04 mounts /tmp as tmpfs, in RAM. GitHub-hosted runners keep it on
# disk. See "/tmp on disk or in RAM" in README.md.
log "/tmp: $TMP_MODE from the next boot"
case "$TMP_MODE" in
  disk) systemctl mask tmp.mount ;;
  tmpfs) systemctl unmask tmp.mount ;;
  *) die "TMP_MODE must be disk or tmpfs, not $TMP_MODE" ;;
esac

# No tool in the image needs snaps.
log "removing snapd"
apt_purge snapd lxd-installer
rm -rf /snap /var/snap /var/lib/snapd /var/cache/snapd /root/snap
cat >/etc/apt/preferences.d/no-snapd.pref <<EOF
# snapd was removed from this image; don't let a package pull it back in.
Package: snapd
Pin: release a=*
Pin-Priority: -10
EOF

# motd-news fetches news from the internet in the background.
log "turning off motd-news"
systemctl mask --now motd-news.timer motd-news.service
if [[ -f /etc/default/motd-news ]]; then
  sed -i 's/^ENABLED=.*/ENABLED=0/' /etc/default/motd-news
fi

log "done"
