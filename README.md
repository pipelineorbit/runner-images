# runner-images

Lean, reproducible VM images for self-hosted, ephemeral GitHub Actions runners.

The images are built with [Packer](https://developer.hashicorp.com/packer). The software and system configuration live in one set of provisioning scripts that every provider shares. Each cloud provider only adds a small Packer source that says where to build and how to save the image. [Hetzner Cloud](https://www.hetzner.com/cloud) is the first provider; others can be added without touching the shared scripts.

> Status: early. Nothing is built yet.

## Goals

- **Small.** A few GB instead of the ~50 GB GitHub-hosted image, so snapshots are cheap and servers start fast.
- **Generic.** Provider-specific code stays in its own folder. The software list, versions and system tuning are shared.
- **Pinned and repeatable.** Tool versions live in one file, so every change to the image is a reviewable diff.
- **Ephemeral-first.** Each server runs one job and is then rebuilt or deleted. Runners register with just-in-time (JIT) configuration, so no long-lived registration token is stored on the image.

## What goes in the image

| Group | Contents |
|---|---|
| Base | git, git-lfs, curl, wget, jq, zip/unzip, tar, zstd, xz, rsync, openssh-client, build-essential, pkg-config, python3 (venv, pip) |
| Runner | [actions/runner](https://github.com/actions/runner) pre-extracted, with its system dependencies |
| Containers | Docker Engine (Docker's apt repository), buildx and compose plugins |
| Cloud CLIs | GitHub CLI, AWS CLI v2, Google Cloud CLI, Azure CLI |
| Language runtimes | Not preinstalled. Workflows use `actions/setup-*` with a tool cache at `/opt/hostedtoolcache`. |

System configuration:
- a `runner` user with passwordless sudo, in the `docker` group
- unattended upgrades and the apt timers turned off, so apt isn't locked during jobs; the regular rebuilds bring in security updates instead
- `ImageOS` and `ImageVersion` set
- a swap file
- cleanup before the image is saved, so every server starts with a unique identity

## Planned layout

```
images/ubuntu/
  provision/          shared scripts that install and configure everything
  versions.env        pinned tool versions
  tests/              smoke tests run against a server started from a new image
providers/
  hetzner/            Packer source for Hetzner Cloud (snapshots)
  <provider>/         one folder per extra provider
.github/workflows/    scheduled and on-change image builds
```
