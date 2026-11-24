# runner-images

Lean, reproducible VM images for self-hosted, ephemeral GitHub Actions runners.

The images are built with [Packer](https://developer.hashicorp.com/packer). The software and system configuration live in one set of provisioning scripts that every provider shares. Each cloud provider only adds a small folder that says where to build, how to save the image and how to manage it. [Hetzner Cloud](https://www.hetzner.com/cloud) is the first provider; others can be added without touching the shared scripts.

## Goals

- **Small.** A few GB instead of the ~50 GB GitHub-hosted image, so snapshots are cheap and servers start fast.
- **Generic.** Provider-specific code stays in its own folder. The software list, versions and system tuning are shared.
- **Pinned and repeatable.** Tool versions live in one file, so every change to the image is a reviewable diff.
- **Ephemeral-first.** Each server runs one job and is then deleted. Runners register with just-in-time (JIT) configuration, so no long-lived registration token is stored on the image.

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

You need [Packer](https://developer.hashicorp.com/packer/install) 1.11 or later, `jq`, an SSH client and a Hetzner Cloud API token.

```sh
export HCLOUD_TOKEN=...
./build.sh build hetzner
```

This builds a snapshot labelled `channel=candidate` in 3 to 4 minutes. Test it and promote it to `stable` as described in [providers/hetzner](providers/hetzner/README.md#build-locally).

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

## Build locally

```sh
./build.sh validate [provider]          # packer fmt -check and packer validate, all providers by default
./build.sh build <provider> [args...]   # build; extra arguments go to `packer build`
```

Packer reads a single directory, so `build.sh` copies `packer/*.pkr.hcl` and every `providers/*/source.pkr.hcl` into `output/packer/` and runs Packer there. It selects the provider with `-only='*.<plugin>.*'`. The build writes `output/manifest.json` and `output/build.log`.

Settings are Packer variables. Pass them as `-var name=value` or set `PKR_VAR_<name>`:

| Variable | Default | |
|---|---|---|
| `ubuntu_version` | `26.04` | Ubuntu LTS release |
| `arch` | `x86_64` | `x86_64` or `arm64` |
| `swap_size_gb` | `4` | `0` for no swap |
| `tmp_mode` | `disk` | `disk` or `tmpfs` |
| `image_version` | today + `.0` | `YYYYMMDD.N`; CI uses the run number as N |
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

[`.github/workflows/build-image.yml`](.github/workflows/build-image.yml) runs on pull requests, on pushes to `main` that change `packer/`, `images/` or `providers/`, weekly, and manually (choose the provider, Ubuntu version and arch).

- **Validate** (every run): `packer fmt -check`, `packer validate` for every provider, shellcheck and actionlint. Pull requests stop here and never see a secret.
- **Runner version**: fails the weekly run if the pinned runner is more than 21 days behind (see [Versions](#versions)).
- **Build**, one matrix leg per provider. Each leg runs in a GitHub environment named after the provider, which holds that provider's secrets only. It calls `providers/<name>/ci/*` for everything provider-specific:
  1. validate and build the image (version `YYYYMMDD.<run number>`)
  2. upload `manifest.json` and the build log as artifacts
  3. start a test server with a one-off SSH key, wait for SSH and run [`smoke.sh`](images/ubuntu/tests/smoke.sh) as `runner`
  4. delete the test server, whatever happened
  5. if everything passed, promote the image to `stable` and delete all but the newest 2 stable images; otherwise delete the new image

The job summary shows the version, image ID and size, build time, how long the test server took to accept SSH, and the smoke test result.

To add CI for a new provider, create a GitHub environment with its name and secrets, then add the name to the matrix.

## Providers

A provider is one folder in [`providers/`](providers) with a Packer source, six lifecycle scripts and a README. All provisioning is shared. [docs/adding-a-provider.md](docs/adding-a-provider.md) describes the interface, has a checklist, and checks the design against Scaleway.

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
build.sh                    runs Packer on packer/ plus every provider's source
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
