# Secure AKS environment (CIS Microsoft Azure Foundations Benchmark v1.4)

This repo holds Terraform (azurerm provider 5.x) and a GitHub Actions workflow. They deploy a private Azure Kubernetes Service (AKS) cluster into an **existing** resource group. The cluster is reachable from the Internet **only** through an Application Gateway with WAF.

```
                     Internet
                        │  80/443 only (NSG)
                        ▼
 ┌──────── <rg>-vnet-agw 10.1.0.0/24 ────────┐
 │  <rg>-snet-agw 10.1.0.0/25                 │
 │  <rg>-agw  (WAF_v2, Prevention, DRS 2.1)   │
 └───────────────────┬────────────────────────┘
                     │ vNet peering (NSG: AGW subnet → 80/443 only)
 ┌───────────────────▼──── <rg>-vnet-aks 10.0.0.0/22 ────────────────────────┐
 │ <rg>-snet-aks-ingress 10.0.1.0/28   internal LB 10.0.1.4 (backend pool)   │
 │ <rg>-snet-aks-nodes   10.0.0.0/24   <rg>-aks (private API server)         │
 │ <rg>-snet-pe          10.0.1.16/28  Key Vault private endpoint            │
 └───────────────────┬────────────────────────────────────────────────────────┘
                     │ egress filtered by <rg>-nsg-aks (config/aks-egress-rules.json)
                     ▼
               <rg>-natgw (outbound only) ──► allowed Azure service tags
```

> 📐 **Diagrams:** see [`docs/architecture.md`](docs/architecture.md). It has a request flow, allowed and blocked traffic paths, a detailed network diagram with every security control marked (S1–S24), the deployment pipeline flow, and full NSG rule tables.

## What you provide

| Input | Required | Default | Notes |
|---|---|---|---|
| `resource_group` | yes | — | Must already exist. Its **name** is the naming prefix and its **region** is used for every resource. |
| `system_node_vm_size` | yes | `Standard_D4ds_v5` | System pool SKU |
| `system_node_count` | yes | `3` | System pool node count (1–100) |
| `user_node_vm_size` | no | same as system | Workload pool SKU |
| `user_node_count` | yes | `2` | Workload pool node count (0–1000) |
| `aks_vnet_cidr` | yes | `10.0.0.0/22` | AKS vNet range, `/16`–`/23`. Subnets are derived from it (see below). |
| `agw_vnet_cidr` | yes | `10.1.0.0/24` | App Gateway vNet range, `/16`–`/25` |
| `runner` | yes | `github-hosted` | `self-hosted` runs Plan/Apply on the [private runner](#private-github-runner-optional-deploy-first) and peers its vNet |
| `pod_cidr` | no | `10.244.0.0/16` | Overlay pod range, `/12`–`/20`. In the workflow: repository variable `AKS_POD_CIDR`. |
| `service_cidr` | no | `172.16.0.0/16` | Kubernetes service range, `/12`–`/24`; DNS service = 10th address. In the workflow: repository variable `AKS_SERVICE_CIDR`. |

Everything else has a secure default in [`terraform/variables.tf`](terraform/variables.tf). That includes admin groups, an HTTPS certificate, flow logs and log retention. Override any of them in a `terraform.tfvars` file (see [`terraform/terraform.tfvars.example`](terraform/terraform.tfvars.example)) or as `TF_VAR_<name>` environment variables.

### Resulting names (resource group `rg-shop-prod` in `eastus2`)

| Resource | Name |
|---|---|
| AKS cluster / node RG | `rg-shop-prod-aks` / `rg-shop-prod-aks-nodes` |
| vNets | `rg-shop-prod-vnet-aks`, `rg-shop-prod-vnet-agw` |
| Subnets | `rg-shop-prod-snet-aks-nodes`, `-snet-aks-ingress`, `-snet-pe`, `-snet-agw` |
| NSGs | `rg-shop-prod-nsg-aks`, `rg-shop-prod-nsg-agw` |
| App Gateway / WAF policy / PIP | `rg-shop-prod-agw`, `rg-shop-prod-wafpol`, `rg-shop-prod-pip-agw` |
| NAT Gateway / PIP | `rg-shop-prod-natgw`, `rg-shop-prod-pip-natgw` |
| Log Analytics | `rg-shop-prod-log` |
| Key Vault | `rgshopprodkv<hash>` (alphanumeric + unique suffix: the name must be globally unique and ≤24 chars) |
| Identities | `rg-shop-prod-id-aks`, `rg-shop-prod-id-agw` |

## Network design and sizing

The two vNets are separate and peered. You only pass the two vNet ranges; the subnets are carved out of them automatically, so they can never be misaligned. The defaults are roughly the smallest supported sizes, with room to grow:

| vNet / subnet | Derived as | Default | Rationale |
|---|---|---|---|
| AKS vNet | `aks_vnet_cidr` | `10.0.0.0/22` | `/23` minimum; anything beyond it is free for extra node pools or subnets |
| Node subnet | 1st `/24` | `10.0.0.0/24` | Azure CNI **Overlay**: pods use `pod_cidr`, so the subnet only holds node IPs (251 nodes) |
| Ingress subnet | 1st `/28` of the 2nd `/24` | `10.0.1.0/28` | Internal load balancer frontends only (smallest Azure subnet); App Gateway targets its `.4` address |
| Private endpoint subnet | next `/28` | `10.0.1.16/28` | Key Vault and future private endpoints |
| App Gateway vNet | `agw_vnet_cidr` | `10.1.0.0/24` | `/25` minimum |
| App Gateway subnet | 1st `/25` | `10.1.0.0/25` | 123 usable IPs ≥ max autoscale (10) with large headroom. Microsoft recommends a `/24` subnet if you plan to scale toward 125 instances, which needs an `agw_vnet_cidr` of `/23` or larger and a one-line change in `terraform/network.tf`. |

Rules enforced at `terraform plan` time:
* Each range must be a valid IPv4 network (e.g. `10.0.0.0/22`, not `10.0.1.0/22`) within the allowed sizes.
* The AKS vNet, App Gateway vNet, pod and service ranges must not overlap each other. The plan fails with a message naming the overlapping pair.

You still need to make sure the ranges don't overlap networks outside this deployment that you peer or route to.

## Tags

Every resource that supports tags gets a copy of the **resource group's tags**. This includes both node pools; AKS also propagates the cluster's tags to the resources it creates in the node resource group. Change a tag on the resource group and the next `apply` updates all resources.

To add tags that aren't on the resource group, set `additional_tags`. If a key exists in both, the resource group's value wins. Some resource types can't hold tags in Azure: subnets, NSG rules, peerings, role and policy assignments, and diagnostic settings.

### No direct Internet ingress to AKS

* The API server is private (`enablePrivateCluster`, no public FQDN). Local accounts are disabled and Entra ID with Azure RBAC is enforced.
* Egress goes through a **NAT Gateway** (`outboundType: userAssignedNATGateway`), so AKS creates **no public load balancer**.
* The Azure Policy *"Kubernetes clusters should use internal load balancers"* is assigned with **deny**. A `Service` that would get a public IP is rejected.
* `<rg>-nsg-aks` denies inbound traffic from `Internet`. It allows traffic from the App Gateway subnet on 80/443 only, and denies everything else from the App Gateway vNet.
* App Gateway WAF_v2 runs in **Prevention** mode with Microsoft Default Rule Set 2.1, Bot Manager, TLS 1.2+ (`AppGwSslPolicy20220101S`) and HTTP/2. Its backend pool is the static internal load balancer IP `10.0.1.4` in the ingress subnet.

### Egress limited by an editable NSG

Outbound rules for the AKS subnets live in [`terraform/config/aks-egress-rules.json`](terraform/config/aks-egress-rules.json). Each entry becomes its own `azurerm_network_security_rule`. Edit that file and re-run the workflow to change them. Terraform reports changes made in the portal as drift and reverts them on the next apply.

Default policy:

| Priority | Destination (service tag) | Port | Action |
|---|---|---|---|
| 100 | AzureActiveDirectory | 443 | Allow |
| 110 | MicrosoftContainerRegistry | 443 | Allow |
| 120 | AzureFrontDoor.FirstParty | 443 | Allow |
| 130 | AzureMonitor | 443 | Allow |
| 140 | AzureCloud | 443 | Allow (catch-all for Azure-hosted AKS dependencies) |
| 4000 | Internet | * | **Deny** |

Traffic inside the vNet (private endpoints, peered App Gateway) and Azure DNS are not affected.

> ⚠️ **Limits of NSG-based egress control.** AKS outbound dependencies are defined as FQDNs. Microsoft documents that NSGs cannot express them exactly ([docs](https://learn.microsoft.com/azure/aks/outbound-rules-control-egress)). The `AzureCloud:443` rule keeps cluster creation, upgrades and scaling working. It still blocks all non-Azure Internet destinations, such as Docker Hub, GitHub and arbitrary sites. For FQDN-level control, put Azure Firewall in front, or use a [network-isolated cluster](https://learn.microsoft.com/azure/aks/concepts-network-isolated) with a private ACR, and then tighten or remove `Allow-AzureCloud-443`. To pull images from a registry outside Azure, add an allow rule above priority 4000.

## CIS Microsoft Azure Foundations Benchmark v1.4: control mapping

| CIS section | Recommendation | Implementation |
|---|---|---|
| 3 Storage (3.1) | Secure transfer required | Flow-log storage account: `supportsHttpsTrafficOnly` |
| 3 Storage | Public access disabled, default network deny, TLS 1.2 | `allowBlobPublicAccess=false`, `publicNetworkAccess=Disabled`, `defaultAction=Deny`, `minimumTlsVersion=TLS1_2`, infrastructure encryption |
| 5 Logging & Monitoring | Diagnostic settings that capture the appropriate categories | AKS control plane (incl. `kube-audit-admin`, `guard`), App Gateway (access + firewall), NSGs, public IPs and Key Vault all send to `<rg>-log` |
| 5 Logging & Monitoring | Key Vault logging enabled | Key Vault `allLogs` (AuditEvent) to Log Analytics |
| 6 Networking (6.1 / 6.2) | RDP / SSH access from the Internet is restricted | Both NSGs deny inbound Internet except 80/443 to the App Gateway; nodes have no public IPs |
| 6 Networking (6.4 – 6.6) | Flow logs captured, retention > 90 days, Network Watcher enabled | Optional VNet flow logs (successor to NSG flow logs) in the regional Network Watcher, 365-day retention, Traffic Analytics (`enable_vnet_flow_logs = true`) |
| 7 Virtual Machines | Disks encrypted | Managed disks encrypted at rest by the platform, plus **encryption at host** on all node pools |
| 8 Other (Key Vault) | Key Vault recoverable | Soft delete (90 days) and purge protection |
| 8 Other (Key Vault) | RBAC for Key Vault | `enableRbacAuthorization=true`; least-privilege `Key Vault Secrets User` for the CSI driver and the App Gateway |
| 8 Other (Key Vault) | Private endpoints for Key Vault | Public network access disabled; private endpoint and `privatelink.vaultcore.azure.net` linked to both vNets |
| 8 Other (AKS) | RBAC enabled on AKS | Kubernetes RBAC with Entra ID and **Azure RBAC**, local accounts disabled |
| 2 Defender for Cloud | Defender for Containers | Defender sensor enabled on the cluster (`securityProfile.defender`); the plan itself is enabled per subscription (see below) |

Other hardening beyond the benchmark: private API server, Cilium network policy, workload identity and OIDC issuer, Key Vault CSI driver with rotation, Azure Policy add-on with the **pod security baseline** initiative (deny), automatic patch and node-image upgrades, image cleaner, Azure Linux node OS, a tainted system pool, and Container Insights through managed identity.

### Out of scope (subscription- or tenant-level controls)

A resource-group deployment cannot set these, so configure them once per subscription:

* CIS 1.x: Entra ID settings (MFA, guest access, security defaults)
* CIS 2.x: Enable the Defender plans (Containers, Key Vault, Storage, ARM, DNS) and security contacts
* CIS 5.1.1–5.1.3: Subscription activity log diagnostic setting
* CIS 5.2.x: Activity log alerts for policy, NSG and security-solution changes

## GitHub Actions setup

Workflow: [`.github/workflows/deploy-aks.yml`](.github/workflows/deploy-aks.yml)

* **Pull requests**: `terraform fmt -check`, `terraform validate` and `terraform test` (mocked provider). No Azure access.
* **Run workflow** (manual): `lint` → `plan` (plan shown in the run summary) → `apply`.
  * `action=plan` stops after the plan.
  * `action=apply` applies the **exact saved plan** after approval on the `azure-production` environment.
  * `action=destroy` plans and applies a destroy through the same approval gate.
* State is stored per resource group (`<rg>.tfstate`) in an Azure Storage container, using Entra ID auth and blob-lease locking.
* `deploy_sample_app=true` deploys [`k8s/sample-app.yaml`](k8s/sample-app.yaml) through `az aks command invoke`, because the API server is private. The step then waits for App Gateway backend health and sends a request through the WAF.

### 1. Create an identity with OIDC federation (no secrets)

```bash
RG=rg-shop-prod
REPO=<owner>/<repo>
SUB=$(az account show --query id -o tsv)

APP_ID=$(az ad app create --display-name "gh-${RG}-deployer" --query appId -o tsv)
az ad sp create --id "$APP_ID"
ENV=azure-preview
  az ad app federated-credential create --id "$APP_ID" --parameters "{
    \"name\": \"gh-${ENV}\",
    \"issuer\": \"https://token.actions.githubusercontent.com\",
    \"subject\": \"repo:${REPO}:environment:${ENV}\",
    \"audiences\": [\"api://AzureADTokenExchange\"]
  }"
ENV=azure-production
  az ad app federated-credential create --id "$APP_ID" --parameters "{
    \"name\": \"gh-${ENV}\",
    \"issuer\": \"https://token.actions.githubusercontent.com\",
    \"subject\": \"repo:${REPO}:environment:${ENV}\",
    \"audiences\": [\"api://AzureADTokenExchange\"]
  }"
```

### 2. Create the Terraform state storage (once)

```bash
STATE_RG=rg-tfstate
STATE_SA=<globally-unique-name>
az group create -n $STATE_RG -l <region>
az storage account create -n $STATE_SA -g $STATE_RG --sku Standard_LRS --min-tls-version TLS1_2 \
  --allow-blob-public-access false --allow-shared-key-access false --https-only true
az storage container create -n tfstate --account-name $STATE_SA --auth-mode login
az storage account blob-service-properties update -n $STATE_SA -g $STATE_RG \
  --enable-versioning true --enable-delete-retention true --delete-retention-days 30
az role assignment create --assignee "$APP_ID" --role "Storage Blob Data Contributor" \
  --scope $(az storage account show -n $STATE_SA -g $STATE_RG --query id -o tsv)/blobServices/default/containers/tfstate
```

### 3. Grant roles (scoped to the resource group)

The configuration creates role assignments and policy assignments, so Contributor alone is not enough:

```bash
SCOPE=/subscriptions/$SUB/resourceGroups/$RG
az role assignment create --assignee "$APP_ID" --role "Contributor"                                 --scope "$SCOPE"
az role assignment create --assignee "$APP_ID" --role "Role Based Access Control Administrator"    --scope "$SCOPE"
az role assignment create --assignee "$APP_ID" --role "Resource Policy Contributor"                --scope "$SCOPE"
# Only if enable_vnet_flow_logs = true:
az role assignment create --assignee "$APP_ID" --role "Network Contributor" \
  --scope /subscriptions/$SUB/resourceGroups/NetworkWatcherRG
```

You can constrain `Role Based Access Control Administrator` with a condition that limits it to the roles this configuration assigns: Network Contributor, Private DNS Zone Contributor, Key Vault Secrets User, and Azure Kubernetes Service RBAC Cluster Admin.

**Let Terraform recover soft-deleted Key Vaults (recommended).** After a `destroy`, the Key Vault stays soft-deleted for 90 days under the same name. The provider is configured to *recover* it on the next `apply` (`recover_soft_deleted_key_vaults = true`), which keeps its secrets and lets purge protection stay on. To see deleted vaults, though, the deployment identity needs `Microsoft.KeyVault/locations/deletedVaults/read`, which exists only at **subscription** scope. Without it, `apply` fails with `409 … A vault with the same name already exists in deleted state`. This custom role grants only that read permission:

```bash
az role definition create --role-definition "{
  \"Name\": \"Key Vault Deleted Vault Reader\",
  \"Description\": \"Lets Terraform find soft-deleted Key Vaults so it can recover them.\",
  \"Actions\": [\"Microsoft.KeyVault/locations/deletedVaults/read\"],
  \"AssignableScopes\": [\"/subscriptions/$SUB\"]
}"
az role assignment create --assignee "$APP_ID" --role "Key Vault Deleted Vault Reader" --scope "/subscriptions/$SUB"
```

### 4. One-time subscription prerequisites

```bash
az feature register --namespace Microsoft.Compute --name EncryptionAtHost
for ns in Microsoft.ContainerService Microsoft.Network Microsoft.KeyVault Microsoft.OperationalInsights \
          Microsoft.Insights Microsoft.Compute Microsoft.Storage Microsoft.PolicyInsights Microsoft.Security; do
  az provider register -n $ns
done
```

If the `EncryptionAtHost` feature isn't registered, the workflow logs a warning and deploys **without** encryption at host.

Terraform runs with `resource_provider_registrations = "none"`, because an identity scoped to a resource group cannot register providers. That's why the providers are registered here.

### 5. Configure GitHub

* **Secrets**: `AZURE_CLIENT_ID` (= `$APP_ID`), `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`
* **Variables**: `TFSTATE_RESOURCE_GROUP`, `TFSTATE_STORAGE_ACCOUNT`, `TFSTATE_CONTAINER` (optional, default `tfstate`), and optionally `AKS_POD_CIDR` / `AKS_SERVICE_CIDR`
* **Environments**: `azure-preview` and `azure-production`. Add required reviewers on `azure-production`.

Then run **Actions → Deploy secure AKS environment → Run workflow**.

## Private GitHub runner (optional, deploy first)

[`runner/`](runner) is a separate Terraform root, deployed by [`.github/workflows/deploy-runner.yml`](.github/workflows/deploy-runner.yml). It creates self-hosted GitHub Actions runner VMs inside a private vNet in the **same resource group**. Run it **before** the AKS workflow when you want the AKS Plan/Apply jobs to run inside your network instead of on GitHub-hosted runners.

```
<rg>-vnet-runner 10.2.0.0/26 ──peering (created by the AKS deployment)──► <rg>-vnet-aks
└─ <rg>-snet-runner 10.2.0.0/28                                          ├─ private API server (443)
   NSG <rg>-nsg-runner: deny ALL inbound                                 └─ Key Vault private endpoint (443)
   egress: 443/80 to Internet via <rg>-natgw-runner, everything else denied
   <rg>-runner-01 … Ubuntu 24.04, no public IP, Trusted Launch, encryption at host
```

| Workflow input | Default | Notes |
|---|---|---|
| `resource_group` | — | The same existing resource group as the AKS environment |
| `runner_vnet_cidr` | `10.2.0.0/26` | `/16`–`/28`. The runner subnet is the first `/28` (11 IPs). It must not overlap the AKS, App Gateway, pod or service ranges; the AKS plan fails if it does. |
| `runner_vm_size` | `Standard_D2s_v5` | Needs Gen2 / Trusted Launch support |
| `runner_count` | `1` | 1–11 VMs: `<rg>-runner-01`, `-02`, … |
| `action` | `plan` | `apply` deploys and registers the runners; `destroy` deletes the VMs and unregisters them from GitHub |

**Security design**
* No public IP and an NSG that denies all inbound traffic, so nothing on the Internet (or in peered vNets) can connect to the runner. Break-glass access is `az vm run-command invoke` or the serial console; no SSH is exposed.
* Outbound only through a NAT Gateway, limited by [`runner/config/runner-egress-rules.json`](runner/config/runner-egress-rules.json) to HTTPS (GitHub, Azure, Terraform registry) and HTTP (Ubuntu mirrors). Everything else to the Internet is denied. As with AKS, NSGs can't filter by FQDN; for that, put Azure Firewall in front.
* Trusted Launch (secure boot + vTPM), encryption at host, platform-managed OS patching, password login disabled, and the runner service runs as an unprivileged `runner` user.
* The runner VMs have **no Azure identity or roles**. Jobs still sign in to Azure with the same GitHub OIDC credentials as GitHub-hosted runners.
* **Registration token never stored.** Terraform only stages the runner software (cloud-init). The workflow then asks GitHub for a 1-hour registration token and registers each VM through `az vm run-command`, so the token is never in Terraform state, the plan artifact or the VM model.

**What the AKS deployment adds when `runner = self-hosted`**

The workflow sets `runner_vnet_name = <rg>-vnet-runner`, and the AKS Terraform then:
* peers the AKS and runner vNets (no forwarded traffic, no gateway transit);
* allows the runner vNet into the AKS vNet on **TCP 443 only** (private API server, Key Vault private endpoint) and denies everything else from it;
* links the private API server's DNS zone (`privatelink.<region>.azmk8s.io`, kept in your resource group) and the Key Vault DNS zone to the runner vNet. From the runner, `kubectl` works against the private API, and you can import certificates into the private Key Vault.

Keep `runner` the same on every AKS run. Switching back to `github-hosted` removes the peering and DNS links again.

### Setup

1. **Secret `RUNNER_ADMIN_TOKEN`**: a fine-grained personal access token (or GitHub App token) for this repository with **Administration: Read and write**. It is only used to request registration tokens and to unregister runners on destroy.
2. The OIDC app, state storage, role assignments and environments from the AKS setup above are reused. The runner's state is stored as `<rg>-runner.tfstate`.
3. Run **Actions → Deploy private GitHub runner** with `action = apply`. The run waits until every runner shows **online** under Settings → Actions → Runners.
4. Run **Deploy secure AKS environment** with `runner = self-hosted`.

> ⚠️ Self-hosted runners execute workflow code inside your network. Keep this repository **private**, or make sure pull requests from forks can't run on these runners. The workflows here only target the self-hosted runner from manual `workflow_dispatch` runs; pull-request jobs stay on GitHub-hosted runners.

## Operating the private cluster

```bash
# Run kubectl through the ARM control plane; no network line of sight needed:
az aks command invoke -g $RG -n $RG-aks --command "kubectl get nodes -o wide"
```

For interactive access from inside the network, use the [private GitHub runner](#private-github-runner-optional-deploy-first), or add a jumpbox / Azure Bastion in a peered vNet. Admins come from `aks_admin_group_object_ids`, which are Entra ID groups granted *Azure Kubernetes Service RBAC Cluster Admin*.

## Exposing your applications

App Gateway forwards to the internal load balancer IP in the `ingress_private_ip` output (default `10.0.1.4`). Expose your ingress controller with a `Service` annotated like this:

```yaml
metadata:
  annotations:
    service.beta.kubernetes.io/azure-load-balancer-internal: "true"
    service.beta.kubernetes.io/azure-load-balancer-internal-subnet: "<rg>-snet-aks-ingress"
    service.beta.kubernetes.io/azure-load-balancer-ipv4: "10.0.1.4"
spec:
  type: LoadBalancer
```

The App Gateway forwards the client's `Host` header, so host-based ingress rules keep working. The health probe calls `GET /` with host `127.0.0.1` and expects 200–399. Adjust the probe in `terraform/appgateway.tf` if your ingress returns 404 for unknown hosts.

### HTTPS

1. Import a PFX certificate into the environment's Key Vault. The vault is private, so do this from inside the network (for example a workflow job on the [private runner](#private-github-runner-optional-deploy-first)), or temporarily allow your IP.
2. Re-apply with `app_gateway_certificate_kv_uri = "https://<vault>.vault.azure.net/secrets/<cert-name>"`. Use the versionless URI so the certificate rotates automatically.

The App Gateway identity `<rg>-id-agw` already has `Key Vault Secrets User` on the vault. The deployment adds an HTTPS listener and a permanent HTTP→HTTPS redirect.

## Repository layout

```
terraform/
  providers.tf                  # azurerm provider + azurerm (Entra ID auth) backend
  variables.tf                  # inputs and secure defaults
  main.tf                       # naming, locals, Log Analytics workspace
  network.tf                    # vNets, subnets, NSGs + rules, NAT GW, peering
  aks.tf                        # private AKS cluster, user pool, Container Insights, RBAC
  appgateway.tf                 # WAF policy + App Gateway WAF_v2
  keyvault.tf                   # Key Vault, private endpoint, private DNS, RBAC
  policy.tf                     # Azure Policy assignments (internal LB, pod security)
  flowlogs.tf                   # optional VNet flow logs
  outputs.tf
  config/aks-egress-rules.json  # editable AKS egress NSG rules
  terraform.tfvars.example
  tests/                        # offline `terraform test` suite (mocked provider)
  .terraform.lock.hcl           # pinned provider version (azurerm 5.13.0)
runner/                         # separate Terraform root: private GitHub runner
  main.tf                       # runner vNet, NSG, NAT GW, VMs (Trusted Launch)
  variables.tf  outputs.tf  providers.tf
  cloud-init.yaml.tftpl         # installs Azure CLI + tools, stages the runner
  scripts/register-runner.sh    # run on the VM via az vm run-command
  config/runner-egress-rules.json
  tests/                        # offline `terraform test` suite
k8s/sample-app.yaml             # smoke-test app on the internal LB
.github/workflows/deploy-aks.yml
.github/workflows/deploy-runner.yml
```

## Local usage

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # set resource_group_name etc.
az login
export ARM_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
terraform init \
  -backend-config="resource_group_name=$STATE_RG" \
  -backend-config="storage_account_name=$STATE_SA" \
  -backend-config="container_name=tfstate" \
  -backend-config="key=rg-shop-prod.tfstate"
terraform plan -out tfplan
terraform apply tfplan
```

The committed lock file has provider hashes for `linux_amd64`, the platform GitHub runners use. On macOS or Windows, add yours first:

```bash
terraform providers lock -platform=linux_amd64 -platform=darwin_arm64 -platform=windows_amd64
```
