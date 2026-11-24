#!/usr/bin/env bash
# Builds runner images with Packer and, with `release`, tests and publishes them.
#
#   ./build.sh validate [provider]          check formatting, then validate all providers (or one)
#   ./build.sh build <provider> [args...]   build an image; extra args go to `packer build`
#   ./build.sh release <provider>           build an image, test it on a new server, label it
#                                           stable and delete old stable images
#   ./build.sh cleanup <provider> [version] delete what a failed or cancelled build left behind
#
# The provider's credentials come from its environment variables, listed in
# providers/<provider>/ci/credentials. If the provider has a ci/prepare script,
# build and release run it before Packer. Settings are Packer variables: set
# them as PKR_VAR_<name> environment variables (or -var name=value with build).
# This script sets image_version (today's date + ".0") and commit (git HEAD)
# unless PKR_VAR_image_version or PKR_VAR_commit is set. release keeps the
# newest KEEP_STABLE_IMAGES (default 2) stable images, and deletes everything
# it created if any step fails.
#
# Packer reads a single directory, so this copies packer/*.pkr.hcl and
# providers/*/source.pkr.hcl into output/packer/ and runs Packer from the
# repository root. The rest goes to output/ too: manifest.json and build.log,
# and from release smoke.log, release.json and summary.md.
set -euo pipefail
cd "$(dirname "$0")"

die() {
  echo "build.sh: $*" >&2
  exit 1
}

usage() {
  sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
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

# Prints the names of the environment variables that must hold a provider's
# credentials. Names ending in ? are optional and left out.
credentials_of() {
  grep -v -e '^#' -e '^[[:space:]]*$' -e '?$' "providers/$1/ci/credentials"
}

# Fails unless all of a provider's required credentials are set.
require_credentials() {
  local name
  for name in $(credentials_of "$1"); do
    [[ -n $(printenv "$name") ]] || die "$name is not set (see providers/$1/README.md)"
  done
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

validate() {
  local providers=${1:-} provider name cmd
  [[ -n $providers ]] || providers=$(cd providers && echo */ | tr -d /)
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
}

build() {
  local provider=$1 plugin
  shift
  plugin=$(plugin_of "$provider")
  require_credentials "$provider"
  assemble
  rm -f output/manifest.json output/build.log

  # Whatever the provider needs before Packer runs, such as a gallery to publish to.
  if [[ -x providers/$provider/ci/prepare ]]; then
    echo "Preparing $provider"
    "providers/$provider/ci/prepare"
  fi

  echo "Building $provider image $PKR_VAR_image_version from ${PKR_VAR_commit:0:12}"
  SECONDS=0
  packer build -timestamp-ui -only="*.$plugin.*" "$@" output/packer 2>&1 | tee output/build.log
  printf 'Build took %dm %02ds\n' $((SECONDS / 60)) $((SECONDS % 60)) | tee -a output/build.log
}

# Set by release, read by release_finish.
release_provider="" image_id="" image_size="" promoted=""

release() {
  local provider=$1 keep=${KEEP_STABLE_IMAGES:-2} ci out server ip started
  ci="providers/$provider/ci"
  [[ $keep =~ ^[0-9]+$ ]] || die "KEEP_STABLE_IMAGES must be a whole number, not '$keep'"
  plugin_of "$provider" >/dev/null
  require_credentials "$provider"
  release_provider=$provider
  rm -f output/smoke.log output/release.json output/summary.md
  trap release_finish EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  # GitHub stops sending jobs to an old runner, so warn, but still build.
  ANNOTATION=warning images/ubuntu/check-runner-version.sh || echo "build.sh: continuing anyway" >&2

  echo "==> Building"
  build "$provider"
  out=$("$ci/find-image" "$PKR_VAR_image_version")
  read -r image_id image_size <<<"$out"

  echo "==> Testing image $image_id ($image_size GB) on a new server"
  rm -f output/smoke_key output/smoke_key.pub
  ssh-keygen -q -t ed25519 -N '' -C runner-images-smoke-test -f output/smoke_key
  started=$(date +%s)
  out=$("$ci/create-test-server" "$image_id" output/smoke_key.pub)
  read -r server ip <<<"$out"
  SERVER_CREATED_AT=$started images/ubuntu/tests/run-smoke.sh "$ip" output/smoke_key | tee output/smoke.log
  "$ci/delete-server" "$server"

  echo "==> Releasing image $image_id"
  "$ci/promote" "$image_id"
  promoted=true
  "$ci/prune" "$keep"
}

# Runs when release exits. If it failed, deletes everything this version's build
# created (the provider's cleanup finds it by its labels), then writes the summary.
release_finish() {
  local status=$?
  trap - EXIT
  trap '' INT TERM
  set +e
  if ((status != 0)); then
    echo "==> Release failed (exit $status); deleting what it created" >&2
    "providers/$release_provider/ci/cleanup" "$PKR_VAR_image_version"
  fi
  rm -f output/smoke_key output/smoke_key.pub
  write_summary "$status"
  ((status != 0)) || echo "==> Released $release_provider image $image_id ($PKR_VAR_image_version)"
  exit "$status"
}

# Writes output/release.json and output/summary.md (CI shows it as the job summary).
write_summary() {
  local status=$1 result build_time ssh_ready smoke size
  if [[ -n $promoted ]]; then
    result=stable
  elif [[ -n $image_id ]]; then
    result="failed, image deleted"
  else
    result=failed
  fi
  build_time=$(sed -n 's/^Build took //p' output/build.log 2>/dev/null)
  ssh_ready=$(sed -n 's/^ssh_ready_seconds=//p' output/smoke.log 2>/dev/null)
  smoke=$(sed -n 's/^smoke test: //p' output/smoke.log 2>/dev/null)
  # find-image prints - if the provider doesn't report the size.
  size="${image_size:-?} GB"
  [[ $image_size != - ]] || size="not reported"

  jq -n --arg provider "$release_provider" --arg version "$PKR_VAR_image_version" \
    --arg commit "$PKR_VAR_commit" --arg image_id "$image_id" --arg image_size "$image_size" \
    --arg result "$result" --arg build_time "$build_time" --arg ssh_ready "$ssh_ready" \
    --arg smoke "$smoke" --argjson status "$status" \
    '{provider: $provider, version: $version, commit: $commit, image_id: $image_id,
      image_size_gb: $image_size, result: $result, exit_status: $status, build_time: $build_time,
      ssh_ready_seconds: $ssh_ready, smoke_test: $smoke}' >output/release.json

  {
    echo "### $release_provider image $PKR_VAR_image_version"
    echo
    echo "| | |"
    echo "|---|---|"
    echo "| Result | $result |"
    echo "| Image ID | ${image_id:-none} |"
    echo "| Image size | $size |"
    echo "| Ubuntu | ${PKR_VAR_ubuntu_version:-26.04}, ${PKR_VAR_arch:-x86_64} |"
    echo "| Commit | \`${PKR_VAR_commit:0:12}\` |"
    echo "| Build time | ${build_time:-?} |"
    echo "| Test server SSH ready after | ${ssh_ready:-?} s |"
    echo "| Smoke test | ${smoke:-did not run} |"
    if [[ -s output/smoke.log ]]; then
      echo
      echo "<details><summary>Smoke test output</summary>"
      echo
      echo '```'
      cat output/smoke.log
      echo '```'
      echo "</details>"
    fi
  } >output/summary.md
}

cleanup() {
  local provider=$1 version=${2:-$PKR_VAR_image_version}
  plugin_of "$provider" >/dev/null
  require_credentials "$provider"
  echo "Deleting what $provider build $version left behind"
  "providers/$provider/ci/cleanup" "$version"
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
  validate) validate "${1:-}" ;;
  build)
    [[ $# -ge 1 ]] || usage
    build "$@"
    ;;
  release)
    [[ $# -eq 1 ]] || usage
    release "$1"
    ;;
  cleanup)
    [[ $# -ge 1 && $# -le 2 ]] || usage
    cleanup "$@"
    ;;
  *) usage ;;
esac
