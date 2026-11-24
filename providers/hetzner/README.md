# Hetzner Cloud

Builds the image as a [Hetzner Cloud](https://www.hetzner.com/cloud) snapshot with the [`hcloud` Packer plugin](https://developer.hashicorp.com/packer/integrations/hetznercloud/hcloud) (`github.com/hetznercloud/hcloud`).

| File | Purpose |
|---|---|
| [`source.pkr.hcl`](./source.pkr.hcl) | The `hcloud.ubuntu` Packer source and its `hetzner_*` variables. |
| [`ci/`](./ci) | The lifecycle scripts CI calls ([interface](../../docs/adding-a-provider.md#the-provider-interface)). They use the [`hcloud` CLI](https://github.com/hetznercloud/cli) and download a pinned copy if it isn't installed. |

## Credentials

Everything reads an API token from `HCLOUD_TOKEN`; nothing reads a token from a file. Create a token with **Read & Write** access in the Hetzner Console, under your project's **Security** > **API tokens**.

- **Locally:** `export HCLOUD_TOKEN=...`
- **In your own workflow:** pass it to the action as an environment variable, `HCLOUD_TOKEN: ${{ secrets.HCLOUD_TOKEN }}` (see [Use it in your pipeline](../../README.md#use-it-in-your-pipeline)).
- **In this repository's CI:** create a GitHub environment named `hetzner` (repository **Settings** > **Environments**) with a secret `HCLOUD_TOKEN`. Under **Deployment branches and tags**, allow only `main`, so code from other branches can't use the token. [`ci/credentials`](./ci/credentials) lists the secret names CI exports for this provider.

The token can create and delete servers and snapshots in the project, so use a project that only builds runner images, or at least none whose snapshots carry the labels below. Builds only delete servers, keys and images that carry their own labels.

## Settings

| Variable | Default | Notes |
|---|---|---|
| `hetzner_base_image` | `ubuntu-<ubuntu_version>`, so `ubuntu-26.04` | A Hetzner system image name or ID. |
| `hetzner_location` | `hel1` | Builder and test server location. Snapshots aren't tied to a location. |
| `hetzner_server_type` | `ccx13` for x86_64, `cax11` for arm64 | Builder and test server type. See [Disk size](#disk-size). |

Set them like any Packer variable, for example `PKR_VAR_hetzner_location=fsn1` or `./build.sh build hetzner -var hetzner_location=fsn1`. The CI scripts read the same `PKR_VAR_*` variables, so the test server matches the builder.

`ccx13` has 2 dedicated vCPUs, 8 GB RAM and an 80 GB disk. `cax11` (Arm) has 2 vCPUs, 4 GB RAM and a 40 GB disk.

## Disk size

A server started from a snapshot needs a disk at least as big as the builder's: a snapshot built on `ccx13` (80 GB) can't start a `cx23` (40 GB). **Build on the smallest server type you plan to run.** A bigger server works; cloud-init grows the file system to fill its disk on first boot.

## Image metadata

The snapshot is named `runner-ubuntu26-<arch>-<version>`, for example `runner-ubuntu26-x86_64-20261124.1`, and has these labels:

| Label | Example |
|---|---|
| `image` | `ubuntu26` |
| `arch` | `x86_64` or `arm64` |
| `version` | `20261124.1` |
| `commit` | the Git commit it was built from |
| `channel` | `candidate`, then `stable` once it passed the smoke test |

To start a runner from the newest stable image:

```sh
hcloud image list --type snapshot --selector image=ubuntu26,arch=x86_64,channel=stable --sort created:desc
```

Builder servers are labelled `purpose=image-builder` and test servers `purpose=image-smoke-test`, both also with the build's `version` and `arch`, and so are their temporary SSH keys. When a release fails, [`ci/cleanup`](./ci/cleanup) deletes them and the candidate image by these labels; servers without a `purpose` label are never touched. If a run is killed before it can clean up (for example, the machine running it dies), run `./build.sh cleanup hetzner <version>`, or look for leftovers with `hcloud server list --selector purpose`.

## Costs

Prices from the Hetzner API in November 2026; check Hetzner's price list for current ones.

- **Snapshots:** €0.0143 per GB per month, billed on the snapshot's size (the `image_size` that `hcloud image describe` shows), not on the disk size. CI keeps two stable snapshots per architecture.
- **Servers:** billed per started hour, also while switched off, until deleted. A `ccx13` costs €0.0585 an hour in `hel1` and a `cax11` €0.0096. A build uses one builder and one test server, each for less than an hour.

## Start-up time

Servers created from Hetzner's own images use Hetzner's faster "rapid deploy" start-up. Servers created from a snapshot don't: Hetzner copies the snapshot to the server's disk first. Measured in `hel1` on `ccx13` in November 2026, from `hcloud server create` until SSH accepted connections:

| Image | `hcloud server create` returned | SSH ready |
|---|---|---|
| This snapshot (1.24 GB), 5 runs | 13–19 s | 29–46 s |
| Hetzner's `ubuntu-26.04` (rapid deploy), 1 run | 11 s | 42 s |

Most of the time is the first boot itself, so the snapshot costs only a few seconds. `run-smoke.sh` prints this time as `ssh_ready_seconds`, and CI shows it in the job summary.

## Reusing a server

`hcloud server rebuild --image <snapshot> --user-data-from-file <file> <server>` writes the snapshot to the server's disk and boots it again. The server keeps its ID, IP addresses and SSH keys and stays the same server for billing, so a rebuild doesn't start a new billed hour.

**Pass user data on every rebuild.** Without it, Hetzner applies the server's last user data again. In a test, a rebuild without user data wrote the previous job's JIT config back. The runner rejected it, because GitHub had already removed its registration, but a `poweroff-after-job` file in that user data would have switched the server off. To rebuild a server so it waits for its next job, pass user data that is just `#cloud-config`.

Measured in `hel1` on `ccx13` in November 2026, seconds until the runner received its job:

| How the runner got its JIT config | Counted from | Seconds |
|---|---|---|
| Create user data (new server), 6 runs | `hcloud server create` | 31–38 |
| Rebuild user data, 2 runs | the rebuild request | 37–46 |
| SSH, on a server rebuilt right after its previous job, 1 run | the SSH command | 8 |

The rebuild itself took 16–19 s before the server started booting. A rebuild without a job to run accepted SSH 32–35 s after the request (2 runs).

## Build size and time

The image uses 4.4 GB of disk; Hetzner stores the snapshot as 1.24 GB, about €0.02 a month. A build takes 3 to 4 minutes on `ccx13`, most of it installing packages.

## Build locally

You need [Packer](https://developer.hashicorp.com/packer/install), `jq`, `curl`, an SSH client and `HCLOUD_TOKEN`. The CI scripts download the `hcloud` CLI if you don't have it.

```sh
export HCLOUD_TOKEN=...
./build.sh release hetzner      # build, test on a new server, promote, prune
```

To go step by step, for example to look at an image before promoting it, run the pieces yourself:

```sh
./build.sh build hetzner        # prints the version, for example 20261124.0

ci=providers/hetzner/ci
read -r image size < <($ci/find-image 20261124.0)
ssh-keygen -t ed25519 -N '' -f output/smoke_key
start=$(date +%s)
read -r server ip < <($ci/create-test-server "$image" output/smoke_key.pub)
SERVER_CREATED_AT=$start images/ubuntu/tests/run-smoke.sh "$ip" output/smoke_key
$ci/delete-server "$server"

$ci/promote "$image" && $ci/prune 2           # if the smoke test passed
$ci/cleanup 20261124.0                        # if it didn't
```

Local builds use version `<today>.0` unless you set `PKR_VAR_image_version`, and record the commit as `<sha>-dirty` if the working tree has changes.
