# Packer plugins for every provider: add one entry per provider.
# Renovate (renovate.json) opens a PR when a plugin has a new release.
packer {
  required_version = ">= 1.11.0"

  required_plugins {
    hcloud = {
      source  = "github.com/hetznercloud/hcloud"
      version = "1.8.2"
    }
    azure = {
      source  = "github.com/hashicorp/azure"
      version = "2.6.5"
    }
  }
}
