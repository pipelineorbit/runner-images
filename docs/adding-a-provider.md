# Adding a provider

A provider is one folder, `providers/<name>/`. It says where to build and how to save and manage the image. It never installs or configures anything in the image: that's the job of the shared provisioning in [`images/ubuntu`](../images/ubuntu), which runs unchanged on every provider.

Outside its folder, a provider is registered in three places, one line each:

| File | Line |
|---|---|
| [`packer/plugins.pkr.hcl`](../packer/plugins.pkr.hcl) | the Packer plugin in `required_plugins` |
| [`packer/build.pkr.hcl`](../packer/build.pkr.hcl) | `"source.<plugin>.ubuntu"` in the `sources` list |
| [`.github/workflows/build-image.yml`](../.github/workflows/build-image.yml) | the provider's name in the `provider` matrix |

Packer can't find sources or plugins by itself: a `build` block has to name each source, and `packer init` only installs plugins listed in `required_plugins`. `./build.sh` checks the `sources` line and tells you if it's missing.

## The provider interface

### `source.pkr.hcl`

One Packer `source` block named `<plugin>.ubuntu`, plus the provider's own variables. [`build.sh`](../build.sh) copies it next to the files in `packer/`, so it can use the shared variables and locals from [`packer/variables.pkr.hcl`](../packer/variables.pkr.hcl).

- **Base image:** Ubuntu `var.ubuntu_version` for `var.arch`, with cloud-init enabled. The build stops if the release or architecture doesn't match.
- **Builder:** a server type for `var.arch`. Pick the smallest you plan to run if the provider ties the image to the builder's disk size.
- **Login:** SSH as `root` or as a user with passwordless sudo.
- **Name and metadata:** name the image `local.image_name` and store all of `local.image_metadata` (`image`, `arch`, `version`, `commit`, `channel=candidate`) in the provider's labels or tags.
- **Variables:** prefix them with the provider's name (`hetzner_location`, `scaleway_zone`). Defaults go in this file.
- **Credentials:** only from the provider's standard environment variables, read by the plugin. Never from a file or a Packer variable in the repository.

### `ci/`

Executable Bash scripts that CI (and you, locally) call by path. Each one uses `set -euo pipefail`, prints only its result on stdout, writes messages to stderr, and exits non-zero on errors. They read the same settings as the build from `PKR_VAR_*` environment variables (at least `PKR_VAR_ubuntu_version` and `PKR_VAR_arch`, with the defaults from `packer/variables.pkr.hcl`).

| Script | Prints | What it does |
|---|---|---|
| `find-image <version>` | `<image-id> <size-gb>` | Finds the newest image with that version, for this Ubuntu version and arch. Fails if there is none. The size is what the provider bills (`-` if unknown); CI shows it in the job summary. |
| `create-test-server <image-id> <ssh-pubkey-file>` | `<server-id> <ip>` | Starts a server from the image. It must accept the key for the `runner` user, added through cloud-init user data, which also tests that user data works. If creation fails, it deletes the server itself. |
| `delete-server <server-id>` | | Deletes the server. Succeeds if it's already gone. |
| `promote <image-id>` | | Sets the image's `channel` to `stable`. |
| `prune <keep>` | | Deletes this Ubuntu version and arch's `stable` images except the newest `<keep>`. Anything else the image uses (such as volume snapshots) goes too. |
| `delete-image <image-id>` | | Deletes the image and what it uses. Succeeds if it's already gone. |

`ci/credentials` lists the environment variables that hold the provider's credentials, one per line. CI copies the secrets with those names from the provider's GitHub environment, and `./build.sh validate` gives them a placeholder value, because `packer validate` only checks that they're set. A `ci/lib.sh` for code the scripts share is fine.

### `README.md`

Covers credentials (and the GitHub environment and its secrets), default location and server type, limits such as disk-size rules, prices, how image metadata is stored, and how to build and test locally. [Hetzner's](../providers/hetzner/README.md) is a template.

## Checklist

1. Create `providers/<name>/source.pkr.hcl` as described above.
2. Add the plugin to `packer/plugins.pkr.hcl` and `"source.<plugin>.ubuntu"` to the `sources` in `packer/build.pkr.hcl`.
3. Write `ci/credentials` and the six `ci/` scripts. Make the scripts executable.
4. Write `README.md`.
5. Run `./build.sh validate` and the [lint commands](../README.md#checks).
6. Export the credentials, then build and test locally with the steps in the README's [Build locally](../README.md#build-locally).
7. Check that the smoke test passes, that the image's labels or tags are right, and that `prune` and `delete-image` leave nothing behind.
8. Create a GitHub environment named after the provider, with a secret for each name in `ci/credentials`, limited to the `main` branch.
9. Add the provider's name to the `provider` matrix in `.github/workflows/build-image.yml`, then run the workflow manually with that provider.

If the provider can only be reached with short-lived credentials from OIDC (common on AWS, Google Cloud and Azure), the workflow needs a login step for it, and that's more than one line. Long-lived keys in the environment work without workflow changes.

## Worked example: Scaleway

This checks the design against [Scaleway](https://www.scaleway.com/en/virtual-instances/) Instances without building anything. Result: **Scaleway fits without changes to `packer/` (other than the two registration lines) or `images/`**.

| Requirement | How it works on Scaleway | Blocker? |
|---|---|---|
| Plugin [`github.com/scaleway/scaleway`](https://developer.hashicorp.com/packer/integrations/scaleway/scaleway) | `source "scaleway" "ubuntu"`. Its required settings map to provider variables: `image` to `scaleway_base_image`, `zone` to `scaleway_zone` (for example `fr-par-1`), `commercial_type` to `scaleway_commercial_type`. `project_id` and the keys come from `SCW_DEFAULT_PROJECT_ID`, `SCW_ACCESS_KEY` and `SCW_SECRET_KEY`, which the plugin reads itself, so `ci/credentials` lists those three. | No |
| Base image | Scaleway names images by codename (`ubuntu_resolute` is Ubuntu 26.04), not by version. A small map from `ubuntu_version` to label in `source.pkr.hcl` gives the default, like Hetzner's `ubuntu-<version>`. | No |
| Tags are plain strings, not key/value pairs | Store `local.image_metadata` as `key=value` strings (`image=ubuntu26`, `channel=candidate`) in the plugin's `tags`. `find-image` and `prune` filter on those strings; `promote` replaces `channel=candidate` with `channel=stable` in the image's tag list. The shared metadata is a plain map, so each provider picks its own form. | No |
| The builder doesn't delete old images | `prune` deletes them, as on Hetzner. A Scaleway image refers to volume snapshots that aren't deleted with it, so `prune` and `delete-image` delete those too (`scw instance image delete <id> with-snapshots=true`); otherwise they keep costing money. | No |
| cloud-init user data | Scaleway passes user data in the `cloud-init` key (`scw instance server create ... cloud-init=@user-data.yaml`), and its Ubuntu images run cloud-init with the Scaleway datasource. The image's cloud-init settings (swap, no network hotplug) don't depend on a datasource. `create-test-server` sends the same user data as Hetzner's. | No |
| x86 and arm64 | `ubuntu_resolute` exists for `x86_64` and `arm64`, the same names as the `arch` variable. Commercial types differ (for example `PRO2-*` or `DEV1-*` for x86, `COPARM1-*` for arm64), so the default `scaleway_commercial_type` depends on `arch`, as Hetzner's server type does. | No |

Things to settle during the first real Scaleway build:

- **Root volume:** set the type and size with the plugin's `root_volume`. Servers started from the image need a root volume at least that big, much like Hetzner's disk-size rule.
- **Credential files:** besides the environment, the plugin also reads `~/.config/scw/config.yaml`. Environment variables take precedence and CI has no such file. Locally, `./build.sh build` insists that the variables are set.
- **Prices:** Scaleway bills image snapshots by size. Report the right size from `find-image`.
