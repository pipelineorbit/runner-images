#!/usr/bin/env bash
# Runs last, just before the provider saves the image. Removes caches, logs and
# everything that must differ between servers. On first boot cloud-init creates
# new SSH host keys, sets the hostname, applies user data and writes the network
# config, and systemd creates a new machine ID.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

log "cleaning apt"
apt_get autoremove -y --purge
apt-get clean
rm -rf /var/lib/apt/lists/*

log "resetting cloud-init so it runs again on the next boot"
cloud-init clean --logs --seed

log "removing the machine ID, SSH host keys, login keys and DHCP leases"
# An empty machine-id (not "uninitialized") gets a new ID without systemd's
# first-boot handling, which could re-enable units this image turned off.
truncate -s 0 /etc/machine-id
rm -f /var/lib/systemd/random-seed /etc/ssh/ssh_host_*
# The key the provider added for the build must not open servers made from the image.
rm -f /root/.ssh/authorized_keys /home/runner/.ssh/authorized_keys
rm -rf /var/lib/dhcp/* /var/lib/dhcpcd/*

log "clearing shell history, caches and logs written during the build"
rm -rf /root/.bash_history /home/runner/.bash_history \
  /root/.cache /root/.config/gcloud /root/.azure \
  /home/runner/actions-runner/_diag
# cloud-init installed this on the build server; it decides again on each new one.
rm -f /etc/udev/rules.d/90-cloud-init-hook-hotplug.rules

log "emptying logs"
journalctl --rotate
journalctl --vacuum-time=1s
find /var/log -type f \( -name '*.gz' -o -name '*.[0-9]' -o -name '*.old' \) -delete
find /var/log -path /var/log/journal -prune -o -type f -exec truncate -s 0 {} +

# Free blocks the provider doesn't have to store.
fstrim --all || true

log "disk used: $(df -h / | awk 'NR == 2 { print $3 }')"
sync
log "done"
