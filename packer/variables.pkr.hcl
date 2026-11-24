# Shared variables. Provider variables live in providers/<name>/source.pkr.hcl
# and start with the provider's name (<name>_location, <name>_server_type, ...).
# Set them with -var name=value or the PKR_VAR_<name> environment variable.

variable "image_version" {
  type        = string
  description = "Image version, YYYYMMDD.N. build.sh sets it (CI uses the run number as N)."

  validation {
    condition     = can(regex("^[0-9]{8}\\.[0-9]+$", var.image_version))
    error_message = "The image_version must look like YYYYMMDD.N, for example 20261124.1."
  }
}

variable "commit" {
  type        = string
  default     = "unknown"
  description = "Git commit the image is built from. build.sh sets it."
}

variable "ubuntu_version" {
  type        = string
  default     = "26.04"
  description = "Ubuntu LTS release. The provider's base image must be this release."

  validation {
    condition     = can(regex("^[0-9]{2}\\.04$", var.ubuntu_version))
    error_message = "The ubuntu_version must be an LTS release such as 26.04."
  }
}

variable "arch" {
  type        = string
  default     = "x86_64"
  description = "CPU architecture: x86_64 or arm64. The provider picks a matching builder."

  validation {
    condition     = contains(["x86_64", "arm64"], var.arch)
    error_message = "The arch must be x86_64 or arm64."
  }
}

variable "swap_size_gb" {
  type        = number
  default     = 4
  description = "Size of the swap file that cloud-init creates on first boot. 0 means no swap."

  validation {
    condition     = var.swap_size_gb >= 0 && floor(var.swap_size_gb) == var.swap_size_gb
    error_message = "The swap_size_gb must be a whole number of GB, 0 or more."
  }
}

variable "tmp_mode" {
  type        = string
  default     = "disk"
  description = "Where /tmp lives: disk (like GitHub-hosted runners) or tmpfs (in RAM, the Ubuntu 26.04 default)."

  validation {
    condition     = contains(["disk", "tmpfs"], var.tmp_mode)
    error_message = "The tmp_mode must be disk or tmpfs."
  }
}

locals {
  # ubuntu26 for 26.04. Also the value of ImageOS on the image.
  image_os = "ubuntu${split(".", var.ubuntu_version)[0]}"

  # Name of the saved image, for example runner-ubuntu26-x86_64-20261124.1.
  image_name = "runner-${local.image_os}-${var.arch}-${var.image_version}"

  # Image metadata. Every provider stores exactly these keys, as labels or as
  # key=value tags. CI promotes a candidate to stable once it passes the smoke test.
  image_metadata = {
    image   = local.image_os
    arch    = var.arch
    version = var.image_version
    commit  = var.commit
    channel = "candidate"
  }
}
