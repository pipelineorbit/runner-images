#!/usr/bin/env bash
# Runs as root on the Azure builder, just before the shared cleanup
# (packer/build.pkr.hcl). Azure's guest agent, walinuxagent, keeps the state of
# the VM it provisioned in /var/lib/waagent, including that VM's certificates
# and private keys. Saved in the image, it would be on every VM started from
# it, and each one would log that it was "created from an image that was not
# properly deprovisioned". This deletes that state, as Azure's image guides
# do. The shared cleanup deletes the build user, SSH host keys and the rest.
set -euo pipefail

echo "resetting the Azure guest agent"
waagent -force -deprovision
