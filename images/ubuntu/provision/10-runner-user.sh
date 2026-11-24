#!/usr/bin/env bash
# The runner user, with passwordless sudo, and the tool cache that
# actions/setup-* install language runtimes into.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

if id runner &>/dev/null; then
  log "user runner already exists"
else
  # UID 1001 matches the runner user on GitHub-hosted runners.
  log "creating user runner"
  useradd --create-home --uid 1001 --user-group --shell /bin/bash runner
fi

log "giving runner passwordless sudo"
visudo -cf "$FILES/sudoers-runner"
install -m 0440 -o root -g root "$FILES/sudoers-runner" /etc/sudoers.d/runner
visudo -c

log "creating the tool cache /opt/hostedtoolcache"
install -d -m 0755 -o runner -g runner /opt/hostedtoolcache

log "done"
