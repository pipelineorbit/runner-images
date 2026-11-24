# Azure: builds an image version in an Azure Compute Gallery. See README.md in this folder.
# The plugin uses the Azure CLI's login: `az login`, or in GitHub Actions the
# OIDC login that ci/lib.sh does. ci/prepare creates the resource group, the
# gallery and the image definition before the build if they don't exist.

variable "azure_subscription_id" {
  type        = string
  default     = env("AZURE_SUBSCRIPTION_ID")
  description = "Subscription to build in. Set AZURE_SUBSCRIPTION_ID, which the CI scripts read too."
}

variable "azure_resource_group" {
  type        = string
  default     = "runner-images"
  description = "Resource group for the gallery and the builder and test VMs. ci/prepare creates it if it doesn't exist."
}

variable "azure_location" {
  type        = string
  default     = "westus3"
  description = "Region for the resource group, if ci/prepare creates it. The gallery and every VM go in the resource group's region."
}

variable "azure_gallery" {
  type        = string
  default     = "runner_images"
  description = "Azure Compute Gallery the image is published to. ci/prepare creates it, and the image definition, if they don't exist."
}

variable "azure_base_image" {
  type        = string
  default     = ""
  description = "Base image as publisher:offer:sku. Empty means Canonical's Ubuntu image for ubuntu_version and arch, for example Canonical:ubuntu-26_04-lts:server."
}

variable "azure_vm_size" {
  type        = string
  default     = ""
  description = "Builder and test VM size. Empty means Standard_D2s_v5 for x86_64 and Standard_D2ps_v6 for arm64."
}

locals {
  azure_base_image = split(":", coalesce(var.azure_base_image,
  "Canonical:ubuntu-${replace(var.ubuntu_version, ".", "_")}-lts:${var.arch == "arm64" ? "server-arm64" : "server"}"))
  azure_vm_size = coalesce(var.azure_vm_size, var.arch == "arm64" ? "Standard_D2ps_v6" : "Standard_D2s_v5")
}

source "azure-arm" "ubuntu" {
  use_azure_cli_auth = true
  subscription_id    = var.azure_subscription_id

  image_publisher = local.azure_base_image[0]
  image_offer     = local.azure_base_image[1]
  image_sku       = local.azure_base_image[2]
  os_type         = "Linux"
  vm_size         = local.azure_vm_size
  # Azure doesn't allow logging in as root, so Packer logs in as the admin user
  # "packer". The shared cleanup deletes that user before the image is saved.

  # Build in the existing resource group and its region, so the build needs no
  # access outside it. Premium SSD for the builder's disk: much faster than the
  # default HDD, and it's deleted after the build.
  build_resource_group_name          = var.azure_resource_group
  managed_image_storage_account_type = "Premium_LRS"

  # The network ci/prepare creates, rather than a new one per build. Its subnet
  # is private, so the builder reaches the internet through its public IP, and
  # Packer reaches it over SSH: Packer adds a security group that allows SSH.
  virtual_network_name                   = "runner-images"
  virtual_network_subnet_name            = "builders"
  virtual_network_resource_group_name    = var.azure_resource_group
  private_virtual_network_with_public_ip = true

  # ci/cleanup finds what a cancelled build left behind by these tags: the VM,
  # its network interface, public IP, security group and OS disk. It also finds
  # the OS disk by its name, in case Azure didn't tag it. Packer tags the image
  # version with them too: the image metadata, and purpose until ci/promote
  # removes it.
  azure_tags        = merge(local.image_metadata, { purpose = "image-builder" })
  temp_os_disk_name = "packer-${regex_replace(local.image_name, "[._]", "-")}-osdisk"

  # One image definition per Ubuntu release and arch, for example
  # runner-ubuntu26-x86_64, with one image version per build: 20261124.1.0.
  shared_image_gallery_destination {
    resource_group = var.azure_resource_group
    gallery_name   = var.azure_gallery
    image_name     = "runner-${local.image_os}-${var.arch}"
    image_version  = "${var.image_version}.0"
  }
  # A candidate isn't the definition's latest version until ci/promote.
  shared_gallery_image_version_exclude_from_latest = true
}
