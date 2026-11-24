#!/usr/bin/env bash
# Writes /etc/runner-image/manifest.json: what the image is, how it was built,
# and the version of every tool. Packer also downloads a copy for CI.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

manifest=/etc/runner-image/manifest.json
tool_versions=/usr/local/libexec/runner-image/tool-versions
install -d -m 0755 /etc/runner-image /usr/local/libexec/runner-image
install -m 0755 "$FILES/tool-versions" "$tool_versions"

log "reading tool versions"
tools=$("$tool_versions")
echo "$tools"

# pinned <tool> <version>: fails the build if a pinned tool has another version.
pinned() {
  local actual
  actual=$(awk -v tool="$1" '$1 == tool { print $2 }' <<<"$tools")
  [[ $actual == "$2" ]] || die "$1 is $actual, but versions.env pins $2"
}
pinned actions-runner "$RUNNER_VERSION"
pinned aws-cli "$AWS_CLI_VERSION"
pinned docker "$DOCKER_VERSION"
pinned containerd "$CONTAINERD_VERSION"
pinned docker-buildx "$BUILDX_VERSION"
pinned docker-compose "$COMPOSE_VERSION"
pinned gcloud "$GCLOUD_VERSION"
pinned azure-cli "$AZURE_CLI_VERSION"

# The smoke test checks that servers started from the image don't share these
# with the build server.
host_keys=$(for key in /etc/ssh/ssh_host_*_key.pub; do ssh-keygen -lf "$key" | awk '{ print $2 }'; done)

log "writing $manifest"
jq -n \
  --arg image "$IMAGE_OS" \
  --arg version "$IMAGE_VERSION" \
  --arg commit "$IMAGE_COMMIT" \
  --arg build_date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg base_image "$PRETTY_NAME, kernel $(uname -r)" \
  --arg ubuntu_version "$UBUNTU_VERSION" \
  --arg arch "$ARCH" \
  --arg builder "$IMAGE_BUILDER" \
  --argjson swap_size_gb "$SWAP_SIZE_GB" \
  --arg tmp_mode "$TMP_MODE" \
  --arg hostname "$(hostname)" \
  --arg machine_id "$(cat /etc/machine-id)" \
  --arg host_keys "$host_keys" \
  --arg tools "$tools" \
  '{
    image: $image,
    version: $version,
    commit: $commit,
    build_date: $build_date,
    base_image: $base_image,
    ubuntu_version: $ubuntu_version,
    arch: $arch,
    builder: $builder,
    config: { swap_size_gb: $swap_size_gb, tmp_mode: $tmp_mode },
    build_host: {
      hostname: $hostname,
      machine_id: $machine_id,
      ssh_host_keys: ($host_keys | split("\n") | map(select(. != "")))
    },
    tools: ($tools | split("\n") | map(select(. != "") | split(" ") | { (.[0]): .[1] }) | add)
  }' >"$manifest"
chmod 0644 "$manifest"

log "done"
