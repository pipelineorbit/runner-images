#!/usr/bin/env bash
# Cloud CLIs: GitHub CLI, Google Cloud CLI and Azure CLI from their vendors'
# apt repositories, and AWS CLI v2 from AWS's signed zip.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

# Key that signs the AWS CLI zips: files/aws-cli.asc, copied from
# https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html
# It expires on 2027-07-01; replace the file when AWS publishes a new one.
AWS_CLI_KEY_FINGERPRINT=FB5DB77FD5C118B80511ADA8A6310ACC4672475C

add_apt_repo github-cli https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  https://cli.github.com/packages stable main
add_apt_repo google-cloud-cli https://packages.cloud.google.com/apt/doc/apt-key.gpg \
  https://packages.cloud.google.com/apt cloud-sdk main
add_apt_repo azure-cli https://packages.microsoft.com/keys/microsoft.asc \
  https://packages.microsoft.com/repos/azure-cli/ "$VERSION_CODENAME" main
apt_get update

gcloud=$(apt_version google-cloud-cli "$GCLOUD_VERSION")
az=$(apt_version azure-cli "$AZURE_CLI_VERSION")

# google-cloud-cli is the core CLI; no extra components are installed.
log "installing gh (latest), google-cloud-cli $GCLOUD_VERSION and azure-cli $AZURE_CLI_VERSION"
apt_install gh "google-cloud-cli=$gcloud" "azure-cli=$az"

if [[ $(aws --version 2>/dev/null) == "aws-cli/$AWS_CLI_VERSION "* ]]; then
  log "AWS CLI $AWS_CLI_VERSION is already installed"
else
  log "installing AWS CLI $AWS_CLI_VERSION"
  tmp=$(mktemp -d)
  url="https://awscli.amazonaws.com/awscli-exe-linux-$(arch_name uname)-$AWS_CLI_VERSION.zip"
  download "$url" "$tmp/awscli.zip"
  download "$url.sig" "$tmp/awscli.zip.sig"
  verify_signature "$FILES/aws-cli.asc" "$AWS_CLI_KEY_FINGERPRINT" "$tmp/awscli.zip.sig" "$tmp/awscli.zip"
  unzip -q "$tmp/awscli.zip" -d "$tmp"
  "$tmp/aws/install" --update --install-dir /usr/local/aws-cli --bin-dir /usr/local/bin
  rm -rf "$tmp"
fi

log "done"
