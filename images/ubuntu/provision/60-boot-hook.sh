#!/usr/bin/env bash
# Boot hook: runner-jit.service starts the runner when a launcher has written a
# just-in-time config to /etc/runner-image/jitconfig, and does nothing
# otherwise. The image never contains a registration token.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

log "installing runner-jit.service"
install -d -m 0755 /etc/runner-image /usr/local/libexec/runner-image
install -m 0755 "$FILES/runner-jit" /usr/local/libexec/runner-image/runner-jit
install -m 0644 "$FILES/runner-jit.service" /etc/systemd/system/runner-jit.service
systemctl daemon-reload
systemctl enable runner-jit.service

log "done"
