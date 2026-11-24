#!/usr/bin/env bash
# Shared setup for the Azure CI scripts in this folder. Each script reads the
# same settings as the Packer build: AZURE_SUBSCRIPTION_ID, PKR_VAR_ubuntu_version,
# PKR_VAR_arch and the PKR_VAR_azure_* variables, with the same defaults.
# shellcheck disable=SC2034 # the settings are used by the scripts that source this file
set -euo pipefail

die() {
  echo "$(basename "$0"): $*" >&2
  exit 1
}

log() {
  echo "$*" >&2
}

[[ -n ${AZURE_SUBSCRIPTION_ID:-} ]] || die "AZURE_SUBSCRIPTION_ID is not set (see providers/azure/README.md)"
command -v az >/dev/null || die "the Azure CLI (az) is not installed"

# In GitHub Actions, log in as the app in AZURE_CLIENT_ID with the job's OIDC
# token, through a federated credential, so no secret is needed. The job needs
# `permissions: id-token: write`. Each script logs in again: Azure can't renew
# this login, and its token expires after about an hour. Without AZURE_CLIENT_ID,
# the scripts and Packer use the Azure CLI's current login (az login).
if [[ -n ${AZURE_CLIENT_ID:-} && -n ${ACTIONS_ID_TOKEN_REQUEST_URL:-} ]]; then
  [[ -n ${AZURE_TENANT_ID:-} ]] || die "AZURE_CLIENT_ID is set, but AZURE_TENANT_ID is not"
  oidc_token=$(curl -fsS --retry 3 -H "Authorization: Bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
    "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api%3A%2F%2FAzureADTokenExchange" | jq -r .value)
  command az login --service-principal --username "$AZURE_CLIENT_ID" --tenant "$AZURE_TENANT_ID" \
    --federated-token "$oidc_token" --allow-no-subscriptions --output none
fi

# Every az command below goes to AZURE_SUBSCRIPTION_ID, without changing the
# CLI's default subscription.
az() {
  command az "$@" --subscription "$AZURE_SUBSCRIPTION_ID" --only-show-errors
}

# Settings, used by the scripts that source this file.
ubuntu_version=${PKR_VAR_ubuntu_version:-26.04}
arch=${PKR_VAR_arch:-x86_64}
resource_group=${PKR_VAR_azure_resource_group:-runner-images}
location=${PKR_VAR_azure_location:-westus3}
gallery=${PKR_VAR_azure_gallery:-runner_images}
image_os="ubuntu${ubuntu_version%%.*}"
# The gallery's image definition for this Ubuntu release and arch, for example runner-ubuntu26-x86_64.
definition="runner-$image_os-$arch"
# The network and subnet that builder and test VMs join, the same as in source.pkr.hcl.
network=runner-images
subnet=builders

# vm_size <arch>: the builder and test VM size, the same default as source.pkr.hcl.
vm_size() {
  if [[ -n ${PKR_VAR_azure_vm_size:-} ]]; then
    echo "$PKR_VAR_azure_vm_size"
  elif [[ $1 == arm64 ]]; then
    echo Standard_D2ps_v6
  else
    echo Standard_D2s_v5
  fi
}

# name_of <image> <arch> <version>: the image's name without dots and
# underscores, which VM names can't contain, for example
# runner-ubuntu26-x86-64-20261124-1. The builder's OS disk and the test VM are
# named after it. (The builder VM's name is random: Packer gives its public IP a
# DNS name, which must be unique in the region.)
name_of() {
  echo "runner-$1-$2-$3" | tr '._' '--'
}

# resources: every resource in the resource group, as JSON.
resources() {
  az resource list --resource-group "$resource_group" --output json
}

# delete_resources: deletes the resources whose IDs it reads on stdin. VMs go
# first, then what they used, in an order that lets each delete succeed: a
# network interface holds its public IP and security group. Other resource
# types, such as the shared network, are ignored.
delete_resources() {
  local ids type id
  ids=$(cat)
  for type in virtualMachines networkInterfaces publicIPAddresses networkSecurityGroups disks; do
    for id in $(grep -i "/$type/[^/]*$" <<<"$ids" || true); do
      log "deleting ${id#*/providers/}"
      az resource delete --ids "$id" --output none
    done
  done
}
