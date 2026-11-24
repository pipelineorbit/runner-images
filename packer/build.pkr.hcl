# The one build. It lists every provider's source and runs the same
# provisioning on whichever source is selected:
#
#   packer build -only='*.<plugin>.*' ...    (./build.sh build <provider> does this)
#
# Relative paths are relative to the repository root, where build.sh runs Packer.
build {
  name = "runner"

  # One entry per provider. Each source is defined in providers/<name>/source.pkr.hcl.
  sources = [
    "source.hcloud.ubuntu",
    "source.azure-arm.ubuntu",
  ]

  # Upload images/ubuntu (scripts, files, versions.env) to /var/tmp/ubuntu.
  provisioner "file" {
    source      = "images/ubuntu"
    destination = "/var/tmp"
  }

  # Install and configure everything, as root, in this order.
  provisioner "shell" {
    env = {
      IMAGE_VERSION  = var.image_version
      IMAGE_COMMIT   = var.commit
      IMAGE_OS       = local.image_os
      IMAGE_BUILDER  = source.type
      UBUNTU_VERSION = var.ubuntu_version
      ARCH           = var.arch
      SWAP_SIZE_GB   = "${var.swap_size_gb}"
      TMP_MODE       = var.tmp_mode
    }
    execute_command = "chmod +x {{ .Path }}; sudo env {{ .Vars }} {{ .Path }}"
    inline = [
      "cd /var/tmp/ubuntu/provision",
      "bash 00-base.sh",
      "bash 10-runner-user.sh",
      "bash 20-docker.sh",
      "bash 30-cloud-clis.sh",
      "bash 40-runner.sh",
      "bash 50-system-tuning.sh",
      "bash 60-boot-hook.sh",
      "bash 90-manifest.sh",
    ]
  }

  # Keep a copy of the manifest. CI uploads it together with the build log.
  provisioner "file" {
    direction   = "download"
    source      = "/etc/runner-image/manifest.json"
    destination = "output/manifest.json"
  }

  # Steps for one provider's builds only, kept in that provider's folder:
  # undoing what its base image or builder leaves behind. Nothing installed here.
  provisioner "shell" {
    only            = ["azure-arm.ubuntu"]
    execute_command = "chmod +x {{ .Path }}; sudo env {{ .Vars }} {{ .Path }}"
    script          = "providers/azure/deprovision.sh"
  }

  # Last: remove everything that servers started from the image must not share,
  # including the user Packer logged in as, unless that's root. The script goes
  # in /var/tmp/ubuntu, which it deletes, and Packer doesn't log in again to
  # delete it (skip_clean): the user it would log in as is gone.
  provisioner "shell" {
    env = {
      BUILD_USER = build.User
    }
    execute_command = "chmod +x {{ .Path }}; sudo env {{ .Vars }} {{ .Path }}"
    remote_folder   = "/var/tmp/ubuntu"
    skip_clean      = true
    inline = [
      "bash /var/tmp/ubuntu/provision/99-cleanup.sh",
      "rm -rf /var/tmp/ubuntu",
    ]
  }
}
