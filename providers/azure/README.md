# Azure

Builds the image as an image version in an [Azure Compute Gallery](https://learn.microsoft.com/en-us/azure/virtual-machines/azure-compute-gallery) with the [Azure Packer plugin](https://developer.hashicorp.com/packer/integrations/hashicorp/azure) (`github.com/hashicorp/azure`, builder `azure-arm`).

| File | Purpose |
|---|---|
| [`source.pkr.hcl`](./source.pkr.hcl) | The `azure-arm.ubuntu` Packer source and its `azure_*` variables. |
| [`deprovision.sh`](./deprovision.sh) | Resets Azure's guest agent on the builder before the image is saved (see [The image](#the-image)). The shared build runs it on Azure builds only. |
| [`ci/`](./ci) | The lifecycle scripts CI calls ([interface](../../docs/adding-a-provider.md#the-provider-interface)), plus `prepare`, which runs before each build. They use the [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) (`az`), which GitHub-hosted runners have. |

## What it creates

Everything goes in one resource group, `runner-images` by default, in that group's region:

| Resource | Name | Kept |
|---|---|---|
| Gallery | `runner_images` | yes |
| Image definition, one per Ubuntu release and arch | `runner-ubuntu26-x86_64` | yes |
| Image version, one per build | `20261124.1.0` | the newest 2 stable ones |
| Virtual network and subnet `builders` (10.0.0.0/24) | `runner-images` | yes |
| Builder VM, with a network interface, public IP, security group and OS disk | `pkrvm…`, disk `packer-runner-ubuntu26-x86-64-20261124-1-osdisk` | during the build |
| Test VM, with the same | `smoke-runner-ubuntu26-x86-64-20261124-1` | during the smoke test |

[`ci/prepare`](./ci/prepare) creates the resource group (in `azure_location`), the gallery, the image definition and the network if they don't exist. Packer creates the builder VM and deletes it after the build, and Packer needs the rest to exist first.

If your organization's Azure Policy requires something of new resource groups, such as an `owner` tag, create the group yourself with what it needs; `prepare` then uses it as it is:

```sh
az group create --name runner-images --location westus3 --tags owner=<you>
```

The subnet is private (no [default outbound access](https://learn.microsoft.com/en-us/azure/virtual-network/ip-services/default-outbound-access)), which some policies require for new subnets: each VM reaches the internet through its own public IP.

## Credentials

Everything uses the Azure CLI's login, and builds in the subscription in `AZURE_SUBSCRIPTION_ID`. The scripts pass the subscription to every `az` command, so your CLI's default subscription doesn't matter and doesn't change.

- **Locally:** `az login`, then `export AZURE_SUBSCRIPTION_ID=<subscription ID>`.
- **In GitHub Actions:** log in with the job's OIDC token, so no secret is stored anywhere. Set `AZURE_CLIENT_ID` and `AZURE_TENANT_ID` as well, and give the job `permissions: id-token: write`; [`ci/lib.sh`](./ci/lib.sh) then logs in as that identity at the start of every script. (Azure can't renew this kind of login, and its token expires after about an hour, so each script logs in again.)
- **Any other CI system:** log in the Azure CLI before running `build.sh`, for example with `az login --service-principal`, and leave `AZURE_CLIENT_ID` unset.

To set up OIDC, create a user-assigned managed identity that trusts your workflow's GitHub OIDC token, and let it manage the resource group. The federated credential's subject must match the token's exactly. With `environment: azure` in the job, as below and in this repository's CI, it's `repo:<owner>/<repo>:environment:azure`, or `repo:<owner>@<owner ID>/<repo>@<repo ID>:environment:azure` for repositories created after July 15, 2026 ([immutable subject claims](https://docs.github.com/en/actions/reference/security/oidc)). This prints the second form's first part:

```sh
gh api repos/<owner>/<repo> --jq '"repo:\(.owner.login)@\(.owner.id)/\(.name)@\(.id)"'
```

```sh
az group create --name runner-images --location westus3
az identity create --resource-group runner-images --name runner-images-ci
az identity federated-credential create --resource-group runner-images --identity-name runner-images-ci \
  --name github --issuer https://token.actions.githubusercontent.com \
  --audiences api://AzureADTokenExchange --subject "<subject>"
az role assignment create --role Contributor --assignee-principal-type ServicePrincipal \
  --assignee-object-id "$(az identity show --resource-group runner-images --name runner-images-ci --query principalId -o tsv)" \
  --scope "$(az group show --name runner-images --query id -o tsv)"
az identity show --resource-group runner-images --name runner-images-ci --query "{AZURE_CLIENT_ID: clientId, AZURE_TENANT_ID: tenantId}"
```

Contributor on the resource group is all a build needs. Creating the role assignment takes Owner or User Access Administrator on the group. An app registration with a federated credential works the same way. If the login fails with `AADSTS700213: No matching federated identity record found for presented assertion subject '...'`, the error shows the subject to use.

Then pass the three values to the action:

```yaml
jobs:
  image:
    runs-on: ubuntu-latest
    timeout-minutes: 90
    environment: azure
    permissions:
      contents: read
      id-token: write
    steps:
      - uses: pipelineorbit/runner-images@main
        with:
          provider: azure
        env:
          AZURE_CLIENT_ID: ${{ secrets.AZURE_CLIENT_ID }}
          AZURE_TENANT_ID: ${{ secrets.AZURE_TENANT_ID }}
          AZURE_SUBSCRIPTION_ID: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
          # Optional settings, for example:
          # PKR_VAR_azure_location: northeurope
```

The login is stored in `~/.azure`, as `azure/login` stores it. On a self-hosted runner that other jobs share, set `AZURE_CONFIG_DIR: ${{ runner.temp }}/azure` in the same `env` to keep it out of the runner user's home.

**In this repository's CI:** create a GitHub environment named `azure` (repository **Settings** > **Environments**) with the secrets `AZURE_CLIENT_ID`, `AZURE_TENANT_ID` and `AZURE_SUBSCRIPTION_ID`, and allow only `main` under **Deployment branches and tags**. The federated credential's subject is `repo:pipelineorbit@235633802/runner-images@1470073433:environment:azure`. [`ci/credentials`](./ci/credentials) lists the secret names; the two marked `?` are optional, because `build.sh` doesn't need them with a CLI login.

## Settings

| Variable | Default | Notes |
|---|---|---|
| `azure_subscription_id` | `$AZURE_SUBSCRIPTION_ID` | Set `AZURE_SUBSCRIPTION_ID` rather than this: the CI scripts read that. |
| `azure_resource_group` | `runner-images` | See [What it creates](#what-it-creates). |
| `azure_location` | `westus3` | Region of the resource group, if `prepare` creates it. Everything else goes in the group's region. |
| `azure_gallery` | `runner_images` | Gallery names can't contain hyphens. |
| `azure_base_image` | `Canonical:ubuntu-26_04-lts:server`, or `server-arm64` for arm64 | Base image as `publisher:offer:sku`. The default follows `ubuntu_version`. |
| `azure_vm_size` | `Standard_D2s_v5` for x86_64, `Standard_D2ps_v6` for arm64 | Builder and test VM size. |

Set them like any Packer variable, for example `PKR_VAR_azure_location=northeurope`. The CI scripts read the same `PKR_VAR_*` variables, so the test VM matches the builder.

`Standard_D2s_v5` has 2 vCPUs and 8 GB of RAM. The arm64 default is a Cobalt 100 size, because Azure's older Arm sizes (Dpsv5) don't support Trusted Launch, which the smoke test uses. arm64 hasn't been built on Azure yet.

**Check that your subscription can use the size in your region.** Azure restricts some sizes per subscription and region: when this provider was written, the test subscription couldn't use any of these 2-vCPU sizes in `eastus` or `centralus`, but could use all of them in `westus3`. An empty list means you can:

```sh
az vm list-skus --location westus3 --size Standard_D2s_v5 --all --query "[].restrictions" -o json
```

## Image metadata

Image versions have three numbers, so the build's version `20261124.1` becomes image version `20261124.1.0` in the definition `runner-ubuntu26-<arch>`. Its tags hold the same metadata as other providers' labels:

| Tag | Example |
|---|---|
| `image` | `ubuntu26` |
| `arch` | `x86_64` or `arm64` |
| `version` | `20261124.1` |
| `commit` | the Git commit it was built from |
| `channel` | `candidate`, then `stable` once it passed the smoke test |

A candidate is excluded from the definition's latest version. [`ci/promote`](./ci/promote) includes it, so a VM created from the image definition's ID, without a version, starts from the newest stable image. Azure picks the highest version number, not the newest date:

```sh
az vm create ... --image /subscriptions/<subscription ID>/resourceGroups/runner-images/providers/Microsoft.Compute/galleries/runner_images/images/runner-ubuntu26-x86_64
```

To list the stable versions:

```sh
az sig image-version list --resource-group runner-images --gallery-name runner_images \
  --gallery-image-definition runner-ubuntu26-x86_64 \
  --query "[?tags.channel=='stable'].{version: name, published: publishingProfile.publishedDate}" -o table
```

The builder VM and its network interface, public IP, security group and OS disk are tagged `purpose=image-builder`, the test VM and its resources `purpose=image-smoke-test`, both also with the build's `version` and `arch`. Packer copies the builder's tags to the image version too; `promote` removes its `purpose` tag. When a release fails, [`ci/cleanup`](./ci/cleanup) deletes the tagged resources, the OS disks also by name (Azure creates them along with their VM, so they might not get its tags), and the image version if it's not stable. It never touches resources without these tags or names. If a run is killed before it can clean up, run `./build.sh cleanup azure <version>`.

## The image

Packer logs in to the builder as `packer`, because Azure doesn't allow logging in as root, and the shared cleanup deletes that user before the image is saved. Before that, [`deprovision.sh`](./deprovision.sh) runs `waagent -force -deprovision`: Azure's guest agent, part of Canonical's Azure image, keeps the state of the VM it provisioned in `/var/lib/waagent`, including that VM's certificates and private keys. Without this, the image would carry the builder's keys, and the agent on every new VM would log that it was "created from an image that was not properly deprovisioned".

The image uses 5.2 GB of disk, more than on other providers: Canonical's Azure image has Azure's kernel and guest agent. That image also tells apt to install x86-64-v3 builds of packages (`APT::Architecture-Variants "amd64v3"`), so the image needs a CPU with AVX2 (Intel Haswell, AMD Excavator or newer), as Azure's current sizes have.

## Starting runners

Pass the cloud-config from [Start a runner](../../README.md#start-a-runner) as the VM's **custom data** (`az vm create --custom-data`, `osProfile.customData`): cloud-init reads custom data on Azure, not user data (`--user-data`). Azure also requires an admin user with an SSH key or password, which cloud-init creates with passwordless sudo. The image has no other login user than `runner`.

The runner needs outbound internet access to reach GitHub. In a private subnet, such as the `builders` subnet that `prepare` creates, give the VM a public IP (its security group doesn't need to allow anything in) or the subnet a NAT gateway.

The image definition allows Trusted Launch (Secure Boot and a vTPM, Azure's default for new VMs), accelerated networking, and SCSI or NVMe disks. The smoke test runs on a Trusted Launch VM.

## Costs

Pay-as-you-go prices in `westus3` from the [Azure Retail Prices API](https://learn.microsoft.com/en-us/rest/api/cost-management/retail-prices/azure-retail-prices) in November 2026; check Azure's pricing pages for current ones.

- **Image versions:** the gallery itself is free. Each image version is billed like a Standard HDD snapshot, $0.05 per GB per month, of the space the image occupies, for each replica (one, in the build region). Azure doesn't report that size, so `find-image` prints `-`; the image uses 5.2 GB of disk, so about $0.26 a month per version.
- **VMs:** `Standard_D2s_v5` costs $0.096 an hour and `Standard_D2ps_v6` $0.0702, plus $0.005 an hour for a Standard public IP. A build runs one builder and one test VM, each for a few minutes. The builder's 30 GB Premium SSD costs about $4.80 a month, prorated over those minutes.
- The network and security groups are free.

## Start-up time

Measured in `westus3` on `Standard_D2s_v5` with Trusted Launch in November 2026:

| | Seconds |
|---|---|
| `az vm create` returned (it waits until the VM is provisioned), 3 runs | 74–77 |
| SSH accepted connections, counted from `az vm create`, 2 runs | 83–90 |
| A JIT runner picked up its job, counted from `az vm create`, 1 run | 75 |

For the JIT run, the VM was created from the image definition, so Azure picked the newest stable version, with the JIT config in custom data. The runner had already connected when `az vm create` returned. On Hetzner the same test took about 36 seconds.

## Build time

A build takes about 23 minutes, and `release` about 30. The builder accepts SSH about a minute after Packer starts, and provisioning takes under 4 minutes, as on other providers. Most of the rest is Azure writing the image version from the builder's disk: 17 minutes. Promoting the version takes about 3 minutes, because Azure updates its replicas.

## Build locally

You need [Packer](https://developer.hashicorp.com/packer/install), `jq`, `curl`, an SSH client and the Azure CLI.

```sh
az login
export AZURE_SUBSCRIPTION_ID=<subscription ID>
./build.sh release azure        # build, test on a new VM, promote, prune
```

To go step by step, for example to look at an image before promoting it, run the pieces yourself:

```sh
./build.sh build azure          # prints the version, for example 20261124.0

ci=providers/azure/ci
read -r image size < <($ci/find-image 20261124.0)
ssh-keygen -t ed25519 -N '' -f output/smoke_key
start=$(date +%s)
read -r server ip < <($ci/create-test-server "$image" output/smoke_key.pub)
SERVER_CREATED_AT=$start images/ubuntu/tests/run-smoke.sh "$ip" output/smoke_key
$ci/delete-server "$server"

$ci/promote "$image" && $ci/prune 2           # if the smoke test passed
$ci/cleanup 20261124.0                        # if it didn't
```

Packer stops if the image version already exists. Local builds use version `<today>.0` unless you set `PKR_VAR_image_version`, so for a second local build on the same day, set a new version, or run `cleanup` first if the earlier one isn't stable.
