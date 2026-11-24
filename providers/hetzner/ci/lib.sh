#!/usr/bin/env bash
# Shared setup for the Hetzner CI scripts in this folder. Each script reads the
# same settings as the Packer build: PKR_VAR_ubuntu_version, PKR_VAR_arch,
# PKR_VAR_hetzner_location and PKR_VAR_hetzner_server_type, with the same defaults.
set -euo pipefail

die() {
  echo "$(basename "$0"): $*" >&2
  exit 1
}

[[ -n ${HCLOUD_TOKEN:-} ]] || die "HCLOUD_TOKEN is not set (see providers/hetzner/README.md)"

# The hcloud CLI, downloaded into ~/.cache if it isn't installed (GitHub-hosted
# runners don't have it).
# renovate: datasource=github-releases depName=hetznercloud/cli extractVersion=^v(?<version>.+)$
HCLOUD_CLI_VERSION=1.70.2
if ! command -v hcloud >/dev/null; then
  dir="${XDG_CACHE_HOME:-$HOME/.cache}/hcloud-$HCLOUD_CLI_VERSION"
  if [[ ! -x $dir/hcloud ]]; then
    case "$(uname -m)" in
      x86_64) cpu=amd64 ;;
      aarch64 | arm64) cpu=arm64 ;;
      *) die "no hcloud CLI for $(uname -m)" ;;
    esac
    file="hcloud-$(uname -s | tr '[:upper:]' '[:lower:]')-$cpu.tar.gz"
    url="https://github.com/hetznercloud/cli/releases/download/v$HCLOUD_CLI_VERSION"
    mkdir -p "$dir"
    curl -fsSL --retry 3 -o "$dir/$file" "$url/$file"
    expected=$(curl -fsSL --retry 3 "$url/checksums.txt" | awk -v f="$file" '$2 == f { print $1 }')
    actual=$( (sha256sum "$dir/$file" 2>/dev/null || shasum -a 256 "$dir/$file") | awk '{ print $1 }')
    [[ -n $expected && $actual == "$expected" ]] || die "checksum mismatch for $file"
    tar -xzf "$dir/$file" -C "$dir" hcloud
    rm -f "$dir/$file"
  fi
  PATH="$dir:$PATH"
fi

ubuntu_version=${PKR_VAR_ubuntu_version:-26.04}
arch=${PKR_VAR_arch:-x86_64}
# Labels shared by all snapshots of this image, for example image=ubuntu26,arch=x86_64.
# shellcheck disable=SC2034 # used by the scripts that source this file
family="image=ubuntu${ubuntu_version%%.*},arch=$arch"
