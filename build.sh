#!/usr/bin/env bash
# Runs Packer on the shared build in packer/ plus every provider's source.
#
#   ./build.sh validate [provider]         check formatting, then validate all providers (or one)
#   ./build.sh build <provider> [args...]  build an image; extra args go to `packer build`
#
# Packer reads a single directory, so this copies packer/*.pkr.hcl and
# providers/*/source.pkr.hcl into output/packer/ and runs Packer from the
# repository root. Packer variables come from -var flags or PKR_VAR_<name>
# environment variables. This script sets image_version (today's date + ".0")
# and commit (git HEAD) unless PKR_VAR_image_version or PKR_VAR_commit is set.
set -euo pipefail
cd "$(dirname "$0")"

die() {
  echo "build.sh: $*" >&2
  exit 1
}

usage() {
  sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

# Prints a provider's Packer plugin, taken from the `source "<plugin>" "ubuntu"`
# line in its source.pkr.hcl, after checking the provider is complete and the
# build lists its source.
plugin_of() {
  local file="providers/$1/source.pkr.hcl" plugin
  [[ -f $file ]] || die "unknown provider '$1': $file not found"
  [[ -f providers/$1/ci/credentials ]] || die "providers/$1/ci/credentials not found"
  plugin=$(sed -n 's/^source "\([a-z0-9_-]*\)" "ubuntu" {$/\1/p' "$file")
  [[ -n $plugin ]] || die "$file must define source \"<plugin>\" \"ubuntu\""
  grep -q "\"source\.$plugin\.ubuntu\"" packer/build.pkr.hcl ||
    die "add \"source.$plugin.ubuntu\" to the sources in packer/build.pkr.hcl"
  echo "$plugin"
}

# Prints the names of the environment variables that hold a provider's credentials.
credentials_of() {
  grep -v -e '^#' -e '^[[:space:]]*$' "providers/$1/ci/credentials"
}

# Copies the shared files and every provider's source into output/packer.
assemble() {
  local dir
  rm -rf output/packer
  mkdir -p output/packer
  cp packer/*.pkr.hcl output/packer/
  for dir in providers/*/; do
    cp "$dir/source.pkr.hcl" "output/packer/source-$(basename "$dir").pkr.hcl"
  done
  packer init output/packer
}

export PKR_VAR_image_version="${PKR_VAR_image_version:-$(date -u +%Y%m%d).0}"
if [[ -z ${PKR_VAR_commit:-} ]]; then
  PKR_VAR_commit=$(git rev-parse HEAD 2>/dev/null || echo unknown)
  if [[ -n $(git status --porcelain 2>/dev/null) ]]; then
    PKR_VAR_commit+="-dirty"
  fi
  export PKR_VAR_commit
fi

command=${1:-}
[[ $# -gt 0 ]] && shift

case "$command" in
  validate)
    providers=${1:-$(cd providers && echo */ | tr -d /)}
    packer fmt -check -diff -recursive packer providers
    assemble

    # `packer validate` needs credentials to be set, but not to be real.
    cmd=(env)
    for provider in $providers; do
      plugin_of "$provider" >/dev/null
      for name in $(credentials_of "$provider"); do
        [[ -n $(printenv "$name") ]] || cmd+=("$name=placeholder-for-validate")
      done
    done
    cmd+=(packer validate)
    [[ -z ${1:-} ]] || cmd+=("-only=*.$(plugin_of "$1").*")
    "${cmd[@]}" output/packer
    ;;

  build)
    [[ -n ${1:-} ]] || usage
    provider=$1
    shift
    plugin=$(plugin_of "$provider")
    for name in $(credentials_of "$provider"); do
      [[ -n $(printenv "$name") ]] || die "$name is not set (see providers/$provider/README.md)"
    done
    assemble
    rm -f output/manifest.json output/build.log

    echo "Building $provider image $PKR_VAR_image_version from ${PKR_VAR_commit:0:12}"
    SECONDS=0
    packer build -timestamp-ui -only="*.$plugin.*" "$@" output/packer 2>&1 | tee output/build.log
    printf 'Build took %dm %02ds\n' $((SECONDS / 60)) $((SECONDS % 60)) | tee -a output/build.log
    ;;

  *) usage ;;
esac
