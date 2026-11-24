#!/usr/bin/env bash
# Fails when RUNNER_VERSION in versions.env is more than MAX_DAYS (default 21)
# days behind. GitHub stops assigning jobs to a runner 63 days after a newer
# version becomes available, and at once if a critical security fix needs it.
# A version becomes available on or after its release date, so counting from the
# first release after the pinned one is the safe side. Set GITHUB_TOKEN to avoid
# GitHub API rate limits, and ANNOTATION=warning to report it as a GitHub Actions
# warning instead of an error.
set -euo pipefail

max_days=${MAX_DAYS:-21}
# shellcheck source=versions.env
source "$(dirname "$0")/versions.env"

github_api() {
  if [[ -n ${GITHUB_TOKEN:-} ]]; then
    curl -fsSL -H "Authorization: Bearer $GITHUB_TOKEN" "https://api.github.com/$1"
  else
    curl -fsSL "https://api.github.com/$1"
  fi
}

# Published releases newer than the pinned one, oldest first: "<tag> <date>".
newer=$(github_api "repos/actions/runner/releases?per_page=100" | jq -r --arg pin "$RUNNER_VERSION" '
  def version: ltrimstr("v") | split(".") | map(tonumber? // 0);
  [.[] | select((.draft or .prerelease) | not) | select((.tag_name | version) > ($pin | version))]
  | sort_by(.published_at) | .[] | "\(.tag_name) \(.published_at)"')

if [[ -z $newer ]]; then
  echo "actions/runner $RUNNER_VERSION is the latest release."
  exit 0
fi

read -r first published <<<"$(head -n 1 <<<"$newer")"
latest=$(tail -n 1 <<<"$newer" | cut -d ' ' -f 1)
days=$(jq -n --arg date "$published" '(now - ($date | fromdateiso8601)) / 86400 | floor')
message="actions/runner $RUNNER_VERSION is $days days behind: $first was released on ${published%%T*} (latest is $latest)."

if ((days > max_days)); then
  echo "::${ANNOTATION:-error} title=Runner version is too old::$message GitHub stops assigning jobs to runners 63 days after a newer version becomes available. Update RUNNER_VERSION in images/ubuntu/versions.env."
  exit 1
fi
echo "$message The limit is $max_days days."
