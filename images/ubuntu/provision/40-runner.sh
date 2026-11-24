#!/usr/bin/env bash
# The GitHub Actions runner, unpacked in /home/runner/actions-runner with the
# system packages it needs. It is not registered: runner-jit.service starts it
# at boot with a just-in-time config (60-boot-hook.sh).
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

dir=/home/runner/actions-runner
tarball="actions-runner-linux-$(arch_name runner)-$RUNNER_VERSION.tar.gz"
release="https://github.com/actions/runner/releases/download/v$RUNNER_VERSION"

current=""
if [[ -x $dir/bin/Runner.Listener ]]; then
  # As runner: the runner writes a log to its _diag directory, which must stay runner's.
  current=$(runuser -u runner -- "$dir/bin/Runner.Listener" --version 2>/dev/null || true)
fi

if [[ $current == "$RUNNER_VERSION" ]]; then
  log "runner $RUNNER_VERSION is already installed"
else
  log "installing runner $RUNNER_VERSION"
  tmp=$(mktemp -d)
  # GitHub records a SHA-256 digest for every release asset.
  download "https://api.github.com/repos/actions/runner/releases/tags/v$RUNNER_VERSION" "$tmp/release.json"
  digest=$(jq -r --arg name "$tarball" '.assets[] | select(.name == $name) | .digest // empty' "$tmp/release.json")
  [[ $digest == sha256:* ]] || die "the v$RUNNER_VERSION release has no SHA-256 digest for $tarball"
  download "$release/$tarball" "$tmp/$tarball"
  verify_sha256 "$tmp/$tarball" "${digest#sha256:}"

  rm -rf "$dir"
  install -d -m 0755 -o runner -g runner "$dir"
  tar -xzf "$tmp/$tarball" -C "$dir"
  chown -R runner:runner "$dir"
  rm -rf "$tmp"
fi

log "installing the runner's system dependencies"
retry "$dir/bin/installdependencies.sh"

log "done"
