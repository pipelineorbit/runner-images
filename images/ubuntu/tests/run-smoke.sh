#!/usr/bin/env bash
# run-smoke.sh <server ip> <ssh private key>
#
# Waits until the server accepts SSH as runner, then runs smoke.sh there.
# Prints ssh_ready_seconds=<n>: the time from SERVER_CREATED_AT (Unix time,
# set it just before creating the server) until SSH worked.
set -euo pipefail

ip=$1
key=$2
created_at=${SERVER_CREATED_AT:-$(date +%s)}

known_hosts=$(mktemp)
trap 'rm -f "$known_hosts"' EXIT
ssh_runner() {
  ssh -i "$key" -o BatchMode=yes -o ConnectTimeout=5 -o LogLevel=ERROR \
    -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$known_hosts" \
    "runner@$ip" "$@"
}

deadline=$(($(date +%s) + 600))
until ssh_runner true 2>/dev/null; do
  if (($(date +%s) > deadline)); then
    echo "runner@$ip did not accept SSH within 10 minutes" >&2
    exit 1
  fi
  sleep 2
done
echo "ssh_ready_seconds=$(($(date +%s) - created_at))"

ssh_runner bash -s <"$(dirname "$0")/smoke.sh"
