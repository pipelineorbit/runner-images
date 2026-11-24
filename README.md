# runner-images

Lean, reproducible VM images for self-hosted, ephemeral GitHub Actions runners.

The images are built with [Packer](https://developer.hashicorp.com/packer). The software and system configuration live in one set of provisioning scripts that every provider shares. Each cloud provider only adds a small folder that says where to build, how to save the image and how to manage it. [Hetzner Cloud](https://www.hetzner.com/cloud) is the first provider; others can be added without touching the shared scripts.

## Goals

- **Small.** A few GB instead of the ~50 GB GitHub-hosted image, so snapshots are cheap and servers start fast.
- **Generic.** Provider-specific code stays in its own folder. The software list, versions and system tuning are shared.
- **Pinned and repeatable.** Tool versions live in one file, so every change to the image is a reviewable diff.
- **Ephemeral-first.** Each server runs one job, then is rebuilt from the image or deleted, so no job sees what an earlier one left behind. Runners register with just-in-time (JIT) configuration, so no long-lived registration token is stored on the image.

## What goes in the image

Ubuntu 26.04 LTS, the release `ubuntu-latest` uses, for x86_64. Ubuntu 24.04 and arm64 are settings, not separate copies, but neither has been built yet.

| Group | Contents |
|---|---|
| Base | git, git-lfs, curl, wget, jq, zip/unzip, tar, zstd, xz, rsync, openssh-client, build-essential, pkg-config, python3 (venv, pip) |
| Runner | [actions/runner](https://github.com/actions/runner) in `/home/runner/actions-runner`, with its system dependencies |
| Containers | Docker Engine with the buildx and compose plugins, from Docker's apt repository |
| Cloud CLIs | GitHub CLI, AWS CLI v2, Google Cloud CLI (core only), Azure CLI |
| Language runtimes | None. Workflows use `actions/setup-*`, which install into the tool cache, `/opt/hostedtoolcache`. |

System configuration:

- a `runner` user (UID 1001, as on GitHub-hosted runners) with passwordless sudo, in the `docker` group
- unattended-upgrades, the apt-daily timers and motd-news turned off and needrestart removed, so nothing locks apt or restarts services during a job; rebuilding the image brings security updates instead
- snapd removed
- `ImageOS`, `ImageVersion`, `RUNNER_TOOL_CACHE` and `AGENT_TOOLSDIRECTORY` in `/etc/environment`
- a 4 GB swap file, created by cloud-init on first boot
- `/tmp` on disk, like GitHub-hosted runners (see [/tmp on disk or in RAM](#tmp-on-disk-or-in-ram))
- cloud-init's network hotplug turned off: Docker's interfaces would trigger it, and it fails on them
- `/etc/runner-image/manifest.json`: version, commit, build date, base image and the version of every tool
- `runner-jit.service`, which starts the runner when a launcher provides a JIT config (see [Start a runner](#start-a-runner))
- cleaned before saving (machine ID, SSH host keys, cloud-init state, logs), so every server starts with its own identity; cloud-init sets up SSH keys, the hostname and user data on first boot

The image uses about 4.4 GB of disk; a Hetzner snapshot of it is 1.24 GB.

## Quick start

You need [Packer](https://developer.hashicorp.com/packer/install) 1.11 or later, `jq`, `curl`, an SSH client and a Hetzner Cloud API token.

```sh
export HCLOUD_TOKEN=...
./build.sh release hetzner
```

This builds a snapshot (3 to 4 minutes), tests it on a new server, labels it `channel=stable` and deletes all but the newest 2 stable images. If any step fails, it deletes everything it created.

## Use it in your pipeline

Build the image in your own cloud account, from your own pipeline and on your own schedule. A run needs only the provider's name and the provider's credentials as environment variables; everything else is pinned in this repository.

### GitHub Actions

This repository is an action:

```yaml
name: Runner image

on:
  schedule:
    - cron: "0 4 * * 1" # weekly, for security updates and new runner versions
  workflow_dispatch:

permissions:
  contents: read

jobs:
  image:
    runs-on: ubuntu-latest
    timeout-minutes: 90
    steps:
      - uses: pipelineorbit/runner-images@main
        with:
          provider: hetzner
        env:
          HCLOUD_TOKEN: ${{ secrets.HCLOUD_TOKEN }}
          # Optional provider settings, for example:
          # PKR_VAR_hetzner_location: fsn1
```

| Input | Default | |
|---|---|---|
| `provider` | required | a folder in [`providers/`](providers); its README lists the credentials |
| `ubuntu-version` | `26.04` | Ubuntu LTS release |
| `arch` | `x86_64` | `x86_64` or `arm64` |
| `keep` | `2` | how many stable images to keep |
| `packer-version` | pinned | Packer version to install |

The outputs are `image-id` (empty if the release failed), `version`, `image-size` and `output-dir`, the directory with `manifest.json`, `build.log`, `smoke.log`, `release.json` and `summary.md`. The summary also goes to the job summary. Any other setting is an environment variable, as for `build.sh`: the `PKR_VAR_<name>` variables in [Build locally](#build-locally) and the provider's README.

The action runs [`build.sh release`](#build-locally). It needs `jq`, `curl`, `git` and `ssh`, which `ubuntu-latest` has, and the runner must reach the test server over SSH. If a step fails, or the job is cancelled, it deletes everything the build created.

### Other CI systems

Run the same command the action runs:

```sh
git clone --depth 1 https://github.com/pipelineorbit/runner-images
HCLOUD_TOKEN=... runner-images/build.sh release hetzner
```

`build.sh` exits non-zero if the release failed, after deleting what it created. If the job is killed before it can, run `build.sh cleanup <provider> <version>` with the version from the log.

### Staying up to date

`@main` always has the latest tested versions. If you pin a commit instead, so you can review what runs with your cloud credentials, update it at least monthly: the runner version is pinned in this repository, and GitHub stops sending jobs to a runner 63 days after a newer runner is released. `build.sh release` warns when the pinned runner is more than 21 days behind.

## Start a runner

The launcher (not part of this repository) creates a server from a `stable` image and passes a [JIT runner config](https://docs.github.com/en/rest/actions/self-hosted-runners#create-configuration-for-a-just-in-time-runner-for-a-repository) as cloud-init user data:

```yaml
#cloud-config
write_files:
  - path: /etc/runner-image/jitconfig
    permissions: "0600"
    content: <encoded_jit_config from the API>
  # Optional: power off after the job.
  - path: /etc/runner-image/poweroff-after-job
    content: ""
```

At boot, `runner-jit.service` waits for cloud-init to finish, reads and deletes `/etc/runner-image/jitconfig`, and runs the runner once as the `runner` user. If `/etc/runner-image/poweroff-after-job` exists, it then powers the server off, so the launcher knows it can delete it. Without a JIT config the service does nothing. The image never contains a registration token and never reads a provider's metadata service.

### Reusing a server

Instead of deleting a server after its job, a launcher can rebuild it from the image, which wipes its disk. On providers that bill by the hour, this saves paying for a new server for every job. The rebuilt server needs the next job's JIT config, which it can get in two ways:

- **In the rebuild's user data,** as above. This is no faster than starting a new server, because the provider writes the image to the disk and the server boots again.
- **Over SSH.** Rebuild right after the job, with user data that has no JIT config, so the server boots and waits. When the next job is queued, start the runner:

  ```sh
  ssh root@<server> 'umask 077 && cat > /etc/runner-image/jitconfig && systemctl start runner-jit.service' <<<"$encoded_jit_config"
  ```

  The config travels on stdin, so it doesn't show up in process lists. The runner picks up the job a few seconds later.

Always pass user data when rebuilding: a provider may otherwise apply the previous user data again, including a JIT config that was already used. Each rebuild also creates new SSH host keys, so the launcher has to trust a new host key every time. [providers/hetzner](providers/hetzner/README.md#reusing-a-server) has measured times.

## Build locally

```sh
./build.sh validate [provider]           # packer fmt -check and packer validate, all providers by default
./build.sh build <provider> [args...]    # build only, leaving a candidate image; extra arguments go to `packer build`
./build.sh release <provider>            # build, test, promote and prune: what CI and the action run
./build.sh cleanup <provider> [version]  # delete what a failed or killed build of that version left behind
```

Packer reads a single directory, so `build.sh` copies `packer/*.pkr.hcl` and every `providers/*/source.pkr.hcl` into `output/packer/` and runs Packer there. It selects the provider with `-only='*.<plugin>.*'`. The build writes `output/manifest.json` and `output/build.log`; `release` adds `smoke.log`, `release.json` and `summary.md`, and keeps the newest `KEEP_STABLE_IMAGES` (default 2) stable images.

Settings are Packer variables. Pass them as `-var name=value` (with `build`) or set `PKR_VAR_<name>`:

| Variable | Default | |
|---|---|---|
| `ubuntu_version` | `26.04` | Ubuntu LTS release |
| `arch` | `x86_64` | `x86_64` or `arm64` |
| `swap_size_gb` | `4` | `0` for no swap |
| `tmp_mode` | `disk` | `disk` or `tmpfs` |
| `image_version` | today + `.0` | `YYYYMMDD.N`; the action uses the run number as N |
| `commit` | `git rev-parse HEAD` | with `-dirty` if the working tree has changes |

Providers add their own variables, such as `hetzner_location`; see their READMEs.

### Checks

CI runs these on every pull request:

```sh
./build.sh validate
shellcheck $(grep -rlE '^#!/usr/bin/env bash' --exclude-dir=.git --exclude-dir=output .)
actionlint
```

## How CI works

[`.github/workflows/build-image.yml`](.github/workflows/build-image.yml) runs on pull requests, on pushes to `main` that change `packer/`, `images/`, `providers/`, `build.sh` or `action.yml`, weekly, and manually (choose the provider, Ubuntu version and arch).

- **Validate** (every run): `packer fmt -check`, `packer validate` for every provider, shellcheck and actionlint. Pull requests stop here and never see a secret.
- **Runner version**: fails the weekly run if the pinned runner is more than 21 days behind (see [Versions](#versions)).
- **Build**, one matrix leg per provider. Each leg runs in a GitHub environment named after the provider, which holds that provider's secrets only. It uses the action in this repository (`uses: ./`), so CI runs exactly what other repositories run. `build.sh release` calls `providers/<name>/ci/*` for everything provider-specific:
  1. build the image (version `YYYYMMDD.<run number>`)
  2. start a test server with a one-off SSH key, wait for SSH and run [`smoke.sh`](images/ubuntu/tests/smoke.sh) as `runner`
  3. delete the test server
  4. promote the image to `stable` and delete all but the newest 2 stable images

  If any step fails, the provider's `cleanup` deletes everything this build created, found by its labels; the action runs it again even when the job was cancelled. The manifest and logs are uploaded as artifacts.

The job summary shows the result, image ID and size, build time, how long the test server took to accept SSH, and the smoke test output.

To add CI for a new provider, create a GitHub environment with its name and secrets, then add the name to the matrix.

## Providers

A provider is one folder in [`providers/`](providers) with a Packer source, seven lifecycle scripts and a README. All provisioning is shared. [docs/adding-a-provider.md](docs/adding-a-provider.md) describes the interface, has a checklist, and checks the design against Scaleway.

| Provider | Image |
|---|---|
| [Hetzner Cloud](providers/hetzner/README.md) | snapshot, labelled |

## Versions

[`images/ubuntu/versions.env`](images/ubuntu/versions.env) pins the actions runner, AWS CLI, Docker Engine and its plugins, Google Cloud CLI and Azure CLI. Apt packages are pinned by upstream version (for example Docker `29.10.0`), and the scripts pick the matching package for the Ubuntu release. The build fails if an installed version differs from its pin.

Not pinned, with the reason in `versions.env`: the GitHub CLI, because its apt repository only keeps the latest release, and Ubuntu's own packages, because the archive only keeps the newest version and each build should get the latest security fixes. The manifest records their versions.

[Renovate](https://docs.renovatebot.com/) ([`renovate.json`](renovate.json)) opens a pull request when a pinned version, a Packer plugin, Packer or a GitHub Action has a new release.

**The runner must stay current.** GitHub stops assigning jobs to a self-hosted runner [63 days after a newer runner version becomes available](https://docs.github.com/en/actions/reference/runners/self-hosted-runners#runner-software-updates-on-self-hosted-runners), and at once if a critical security update requires it. (Older advice says 30 days.) [`check-runner-version.sh`](images/ubuntu/check-runner-version.sh) counts from the release date of the first version after the pinned one, which is never later than the date it became available, and the weekly build fails once that is more than 21 days ago. That leaves weeks to merge Renovate's runner update and rebuild. For a version's exact cut-off dates, ask the API: `gh api repos/<owner>/<repo>/actions/runners/deprecations/<version>` (needs admin access, so CI's token can't).

The AWS CLI zip is checked against AWS's signing key in [`files/aws-cli.asc`](images/ubuntu/files/aws-cli.asc), which expires on 2027-07-01. Replace it with the key from the [AWS CLI install guide](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) when AWS publishes a new one.

## /tmp on disk or in RAM

Ubuntu 26.04 mounts `/tmp` as tmpfs, in RAM (up to half of it). GitHub-hosted runners keep `/tmp` on disk, so that is the default here (`tmp_mode = "disk"`).

- **disk:** `/tmp` can hold as much as the disk. Jobs that unpack large archives or build images in `/tmp` behave as on GitHub-hosted runners.
- **tmpfs:** faster, but what a job writes to `/tmp` uses memory, shared with the job itself; a few GB in `/tmp` on an 8 GB server can make a build run out of memory. Use it on servers with plenty of RAM and jobs that keep `/tmp` small.

## Layout

```
build.sh                    builds, tests and releases images: Packer on packer/ plus every provider's source
action.yml                  the GitHub Action other repositories use; runs build.sh release
packer/
  plugins.pkr.hcl           Packer plugins, one per provider
  variables.pkr.hcl         shared variables and image metadata
  build.pkr.hcl             the one build: every provider's source, the shared provisioning
images/ubuntu/
  versions.env              pinned tool versions
  check-runner-version.sh   fails if the pinned runner is too old
  provision/                scripts that install and configure everything, run in order
  files/                    systemd unit, sudoers file, helper scripts, AWS CLI key
  tests/                    smoke test, run on a server started from a new image
providers/
  hetzner/                  Hetzner Cloud: Packer source, ci/ scripts, README
docs/adding-a-provider.md   the provider interface and checklist
.github/workflows/          build-image.yml
renovate.json               version updates
```

## License

[MIT](./LICENSE)
