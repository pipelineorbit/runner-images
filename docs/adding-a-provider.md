# Adding a provider

A provider is one folder, `providers/<name>/`. It says where to build and how to save and manage the image. It never installs or configures anything in the image: that's the job of the shared provisioning in [`images/ubuntu`](../images/ubuntu), which runs unchanged on every provider.

Outside its folder, a provider is registered in three places, one line each:

| File | Line |
|---|---|
| [`packer/plugins.pkr.hcl`](../packer/plugins.pkr.hcl) | the Packer plugin in `required_plugins` |
| [`packer/build.pkr.hcl`](../packer/build.pkr.hcl) | `"source.<plugin>.ubuntu"` in the `sources` list |
| [`.github/workflows/build-image.yml`](../.github/workflows/build-image.yml) | the provider's name in the `provider` matrix |

Packer can't find sources or plugins by itself: a `build` block has to name each source, and `packer init` only installs plugins listed in `required_plugins`. `./build.sh` checks the `sources` line and tells you if it's missing. A provider that needs [a step of its own on the image](#steps-on-the-image-for-one-provider) also adds a provisioner to `packer/build.pkr.hcl`.

## The provider interface

### `source.pkr.hcl`

One Packer `source` block named `<plugin>.ubuntu`, plus the provider's own variables. [`build.sh`](../build.sh) copies it next to the files in `packer/`, so it can use the shared variables and locals from [`packer/variables.pkr.hcl`](../packer/variables.pkr.hcl).

- **Base image:** Ubuntu `var.ubuntu_version` for `var.arch`, with cloud-init enabled. The build stops if the release or architecture doesn't match.
- **Builder:** a server type for `var.arch`. Pick the smallest you plan to run if the provider ties the image to the builder's disk size.
- **Login:** SSH as `root` or as a user with passwordless sudo. The shared cleanup deletes that user (Packer's `build.User`) before the image is saved, unless it's `root`.
- **Name and metadata:** name the image `local.image_name` and store all of `local.image_metadata` (`image`, `arch`, `version`, `commit`, `channel=candidate`) in the provider's labels or tags.
- **Builder labels:** label the builder server, and its SSH key if the provider has key objects, with `purpose=image-builder`, `version` and `arch`, so `ci/cleanup` can find them if a build is killed.
- **Variables:** prefix them with the provider's name (`hetzner_location`, `scaleway_zone`). Defaults go in this file.
- **Credentials:** only from the provider's standard environment variables, read by the plugin, or from the provider's CLI login. Never from a file or a Packer variable in the repository.

### Steps on the image for one provider

The shared provisioning knows nothing about providers. If the provider's base image or builder leaves something behind that a server started from the image must not have, put a script in the provider's folder and add a `shell` provisioner for it to [`packer/build.pkr.hcl`](../packer/build.pkr.hcl), before the final cleanup, with `only = ["<plugin>.ubuntu"]`. Azure does this to reset its guest agent ([`providers/azure/deprovision.sh`](../providers/azure/deprovision.sh)). Such a script only undoes; anything the image should contain belongs in `images/ubuntu`.

### `ci/`

Executable Bash scripts that `build.sh release` (and you, locally) call by path. Each one uses `set -euo pipefail`, prints only its result on stdout, writes messages to stderr, and exits non-zero on errors. They read the same settings as the build from `PKR_VAR_*` environment variables (at least `PKR_VAR_ubuntu_version` and `PKR_VAR_arch`, with the defaults from `packer/variables.pkr.hcl`).

| Script | Prints | What it does |
|---|---|---|
| `find-image <version>` | `<image-id> <size-gb>` | Finds the newest image with that version, for this Ubuntu version and arch. Fails if there is none. The size is what the provider bills (`-` if unknown); CI shows it in the job summary. |
| `create-test-server <image-id> <ssh-pubkey-file>` | `<server-id> <ip>` | Starts a server from the image. It must accept the key for the `runner` user, added through cloud-init user data, which also tests that user data works. Label the server (and any temporary key) with `purpose=image-smoke-test` and the image's `version` and `arch`, for `cleanup`. If creation fails, it deletes the server itself. |
| `delete-server <server-id>` | | Deletes the server. Succeeds if it's already gone. |
| `promote <image-id>` | | Sets the image's `channel` to `stable`. |
| `prune <keep>` | | Deletes this Ubuntu version and arch's `stable` images except the newest `<keep>`. Anything else the image uses (such as volume snapshots) goes too. |
| `delete-image <image-id>` | | Deletes the image and what it uses. Succeeds if it's already gone. |
| `cleanup <version>` | | Deletes what a build or release of that version left behind for this Ubuntu version and arch: builder and test servers, their SSH keys, and images not promoted to `stable`. It finds them by their labels and must not touch anything else, such as runner servers labelled with an image version. `build.sh release` runs it when a step fails, and the action again after a cancelled job. Succeeds if there's nothing to delete. |
| `prepare` (optional) | | Runs before Packer in `build.sh build` and `release`. Creates what the build needs and the plugin doesn't create, if it's missing, so the first build in an empty account works: [Azure's](../providers/azure/ci/prepare) creates a gallery and a network. Must be safe to run again. |

`ci/credentials` lists the environment variables that hold the provider's credentials, one per line. A name ending in `?` is optional. CI copies the secrets with those names from the provider's GitHub environment, and `./build.sh validate` gives the required ones a placeholder value, because `packer validate` only checks that they're set. A `ci/lib.sh` for code the scripts share is fine.

A provider that logs in with GitHub's OIDC token instead of a long-lived secret (common on AWS, Google Cloud and Azure) does it in `ci/lib.sh`, so every script logs in by itself, and needs no change to the workflow: the build job may request OIDC tokens (`id-token: write`). If the plugin can use the provider's CLI login, log the CLI in there, as [Azure's](../providers/azure/ci/lib.sh) does, and run `prepare` before Packer.

### `README.md`

Covers credentials (and the GitHub environment and its secrets), default location and server type, limits such as disk-size rules, prices, how image metadata is stored, and how to build and test locally. [Hetzner's](../providers/hetzner/README.md) is a template; [Azure's](../providers/azure/README.md) adds an OIDC login and resources that `prepare` creates.

## Checklist

1. Create `providers/<name>/source.pkr.hcl` as described above.
2. Add the plugin to `packer/plugins.pkr.hcl` and `"source.<plugin>.ubuntu"` to the `sources` in `packer/build.pkr.hcl`.
3. Write `ci/credentials` and the seven `ci/` scripts, and `ci/prepare` if the build needs something to exist first. Make the scripts executable.
4. Write `README.md`.
5. Run `./build.sh validate` and the [lint commands](../README.md#checks).
6. Export the credentials, then run `./build.sh release <name>`: it builds, tests, promotes and prunes, the same as CI and the action.
7. Check that the smoke test passes and that the image's labels or tags are right. Then check that `cleanup` deletes what a failed build leaves: run `./build.sh build <name>` and then `./build.sh cleanup <name>`, and confirm nothing is left.
8. Create a GitHub environment named after the provider, with a secret for each name in `ci/credentials`, limited to the `main` branch.
9. Add the provider's name to the `provider` matrix in `.github/workflows/build-image.yml`, then run the workflow manually with that provider.

## Worked example: Scaleway

This checks the design against [Scaleway](https://www.scaleway.com/en/virtual-instances/) Instances without building anything. Result: **Scaleway fits without changes to `packer/` (other than the two registration lines) or `images/`**.

| Requirement | How it works on Scaleway | Blocker? |
|---|---|---|
| Plugin [`github.com/scaleway/scaleway`](https://developer.hashicorp.com/packer/integrations/scaleway/scaleway) | `source "scaleway" "ubuntu"`. Its required settings map to provider variables: `image` to `scaleway_base_image`, `zone` to `scaleway_zone` (for example `fr-par-1`), `commercial_type` to `scaleway_commercial_type`. `project_id` and the keys come from `SCW_DEFAULT_PROJECT_ID`, `SCW_ACCESS_KEY` and `SCW_SECRET_KEY`, which the plugin reads itself, so `ci/credentials` lists those three. | No |
| Base image | Scaleway names images by codename (`ubuntu_resolute` is Ubuntu 26.04), not by version. A small map from `ubuntu_version` to label in `source.pkr.hcl` gives the default, like Hetzner's `ubuntu-<version>`. | No |
| Tags are plain strings, not key/value pairs | Store `local.image_metadata` as `key=value` strings (`image=ubuntu26`, `channel=candidate`) in the plugin's `tags`, and the builder's labels in its `server_tags`. `find-image`, `prune` and `cleanup` filter on those strings; `promote` replaces `channel=candidate` with `channel=stable` in the image's tag list. The shared metadata is a plain map, so each provider picks its own form. | No |
| The builder doesn't delete old images | `prune` deletes them, as on Hetzner. A Scaleway image refers to volume snapshots that aren't deleted with it, so `prune`, `delete-image` and `cleanup` delete those too (`scw instance image delete <id> with-snapshots=true`); otherwise they keep costing money. | No |
| cloud-init user data | Scaleway passes user data in the `cloud-init` key (`scw instance server create ... cloud-init=@user-data.yaml`), and its Ubuntu images run cloud-init with the Scaleway datasource. The image's cloud-init settings (swap, no network hotplug) don't depend on a datasource. `create-test-server` sends the same user data as Hetzner's. | No |
| x86 and arm64 | `ubuntu_resolute` exists for `x86_64` and `arm64`, the same names as the `arch` variable. Commercial types differ (for example `PRO2-*` or `DEV1-*` for x86, `COPARM1-*` for arm64), so the default `scaleway_commercial_type` depends on `arch`, as Hetzner's server type does. | No |

Things to settle during the first real Scaleway build:

- **Root volume:** set the type and size with the plugin's `root_volume`. Servers started from the image need a root volume at least that big, much like Hetzner's disk-size rule.
- **Credential files:** besides the environment, the plugin also reads `~/.config/scw/config.yaml`. Environment variables take precedence and CI has no such file. Locally, `./build.sh build` insists that the variables are set.
- **Prices:** Scaleway bills image snapshots by size. Report the right size from `find-image`.
