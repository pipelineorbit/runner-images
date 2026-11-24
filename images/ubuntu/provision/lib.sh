#!/usr/bin/env bash
# Shared helpers for the provision scripts, which start with:
#
#   source "$(dirname "$0")/lib.sh"
#
# The scripts run as root on the builder, from a copy of images/ubuntu, with
# the settings from packer/build.pkr.hcl in the environment (ARCH,
# IMAGE_VERSION, ...). Nothing in them may depend on the cloud provider.

set -Eeuo pipefail
# Also stop on errors inside $(...), not just in the script itself.
shopt -s inherit_errexit

IMAGE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC2034 # used by the scripts that source this file
FILES=$IMAGE_DIR/files
# shellcheck source=../versions.env
source "$IMAGE_DIR/versions.env"
# shellcheck source=/dev/null
source /etc/os-release
export DEBIAN_FRONTEND=noninteractive

log() { echo "[$(basename "$0") $(date -u +%H:%M:%S)] $*"; }
die() {
  log "ERROR: $*" >&2
  exit 1
}
trap 'log "FAILED (exit $?) at line $LINENO: $BASH_COMMAND" >&2' ERR

# retry <command...>: runs the command up to 5 times, waiting 5, 10, 20 and 40
# seconds between attempts. For anything that uses the network.
retry() {
  local attempt=1 delay=5
  until "$@"; do
    if ((attempt == 5)); then
      log "giving up after $attempt attempts: $*"
      return 1
    fi
    log "attempt $attempt failed, retrying in ${delay}s: $*"
    sleep "$delay"
    attempt=$((attempt + 1))
    delay=$((delay * 2))
  done
}

# download <url> <file>
download() {
  retry curl -fsSL --connect-timeout 20 -o "$2" "$1"
}

# verify_sha256 <file> <expected sha256>
verify_sha256() {
  local actual
  actual=$(sha256sum "$1" | awk '{ print $1 }')
  [[ $actual == "$2" ]] || die "SHA-256 of $1 is $actual, expected $2"
  log "checksum OK: $(basename "$1")"
}

# verify_signature <armored public key> <key fingerprint> <signature> <file>:
# checks a detached PGP signature made by the key with that fingerprint.
verify_signature() {
  local key=$1 fingerprint=$2 signature=$3 file=$4 gnupghome status
  gnupghome=$(mktemp -d)
  gpg --homedir "$gnupghome" --batch --dearmor --output "$gnupghome/key.gpg" "$key"
  status=$(gpgv --keyring "$gnupghome/key.gpg" --status-fd 1 "$signature" "$file" 2>/dev/null || true)
  rm -rf "$gnupghome"
  grep "^\[GNUPG:\] VALIDSIG " <<<"$status" | grep -q "$fingerprint" ||
    die "$file has no valid signature from key $fingerprint"
  log "signature OK: $(basename "$file")"
}

# arch_name deb|uname|runner: the image architecture (ARCH: x86_64 or arm64)
# as Debian, the kernel and actions/runner name it.
arch_name() {
  case "$1:$ARCH" in
    deb:x86_64) echo amd64 ;;
    deb:arm64) echo arm64 ;;
    uname:x86_64) echo x86_64 ;;
    uname:arm64) echo aarch64 ;;
    runner:x86_64) echo x64 ;;
    runner:arm64) echo arm64 ;;
    *) die "no $1 name for ARCH=$ARCH" ;;
  esac
}

# apt_get <args...>: apt-get without prompts. It waits for the dpkg lock (a boot
# job may hold it) and retries, because most failures are network errors.
apt_get() {
  retry apt-get -q \
    -o DPkg::Lock::Timeout=300 \
    -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confold \
    "$@"
}

# apt_install <package[=version]...>
apt_install() {
  apt_get install -y --no-install-recommends "$@"
}

# apt_purge <package...>: removes those of the packages that are installed.
apt_purge() {
  local package installed=()
  for package in "$@"; do
    if dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'ok installed'; then
      installed+=("$package")
    fi
  done
  if ((${#installed[@]} > 0)); then
    apt_get purge -y --auto-remove "${installed[@]}"
  fi
}

# apt_version <package> <upstream version>: prints the full apt version of the
# package with that upstream version, for example
#   apt_version docker-ce 29.10.0  ->  5:29.10.0-1~ubuntu.26.04~resolute
apt_version() {
  local version
  # awk reads all of madison's output: stopping early would kill it with SIGPIPE.
  version=$(apt-cache madison "$1" | awk -F'|' -v want="$2" '{
    v = $2; gsub(/ /, "", v)
    up = v; sub(/^[0-9]+:/, "", up); sub(/-[^-]*$/, "", up)
    if (up == want && found == "") found = v
  } END { print found }')
  [[ -n $version ]] || die "$1 $2 is not available from the apt repositories"
  echo "$version"
}

# add_apt_repo <name> <key url> <uri> <suite> <components>: adds a third-party
# apt repository. Its key goes to /etc/apt/keyrings and is only trusted for it.
add_apt_repo() {
  local name=$1 key_url=$2 uri=$3 suite=$4 components=$5 key tmp
  tmp=$(mktemp)
  download "$key_url" "$tmp"
  # apt needs .asc for ASCII-armored keys and .gpg for binary ones.
  if grep -q -- '-----BEGIN PGP PUBLIC KEY BLOCK-----' "$tmp"; then
    key=/etc/apt/keyrings/$name.asc
  else
    key=/etc/apt/keyrings/$name.gpg
  fi
  install -d -m 0755 /etc/apt/keyrings
  install -m 0644 "$tmp" "$key"
  rm -f "$tmp"
  cat >"/etc/apt/sources.list.d/$name.sources" <<EOF
Types: deb
URIs: $uri
Suites: $suite
Components: $components
Architectures: $(arch_name deb)
Signed-By: $key
EOF
  log "added apt repository $name: $uri $suite"
}
