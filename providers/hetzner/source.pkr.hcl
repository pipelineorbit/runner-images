# Hetzner Cloud: builds a snapshot. See README.md in this folder.
# The plugin reads the API token from HCLOUD_TOKEN.

variable "hetzner_base_image" {
  type        = string
  default     = ""
  description = "Base image name or ID. Empty means ubuntu-<ubuntu_version>, for example ubuntu-26.04."
}

variable "hetzner_location" {
  type        = string
  default     = "hel1"
  description = "Location of the builder server."
}

variable "hetzner_server_type" {
  type        = string
  default     = ""
  description = "Builder server type. Empty means ccx13 for x86_64 and cax11 for arm64. Servers started from the snapshot need a disk at least as big as this type's."
}

locals {
  hetzner_base_image  = coalesce(var.hetzner_base_image, "ubuntu-${var.ubuntu_version}")
  hetzner_server_type = coalesce(var.hetzner_server_type, var.arch == "arm64" ? "cax11" : "ccx13")
}

source "hcloud" "ubuntu" {
  image        = local.hetzner_base_image
  location     = var.hetzner_location
  server_type  = local.hetzner_server_type
  ssh_username = "root"

  # Server names must be valid hostnames, so no dots or underscores.
  server_name = "packer-${regex_replace(local.image_name, "[._]", "-")}"
  # ci/cleanup finds what a cancelled build left behind by these labels.
  server_labels   = { purpose = "image-builder", version = var.image_version, arch = var.arch }
  ssh_keys_labels = { purpose = "image-builder", version = var.image_version, arch = var.arch }

  snapshot_name   = local.image_name
  snapshot_labels = local.image_metadata
}
