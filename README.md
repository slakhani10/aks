# Secure AKS environment (CIS Microsoft Azure Foundations Benchmark v1.4)

This repo holds Terraform (azurerm provider 5.x) and GitHub Actions workflows. They deploy a private Azure Kubernetes Service (AKS) cluster into an **existing** resource group. The cluster is reachable from the Internet **only** through **Application Gateway for Containers (AGfC) with WAF**.

```
                         Internet
                            │  80/443 only (NSG on the AGfC subnet)
                            ▼
              <rg>-agc-fe  (AGfC frontend, Azure-managed FQDN)
              WAF policy <rg>-wafpol: Prevention, DRS 2.1 + Bot Manager
                            │
 ┌──────────────────────────▼────── <rg>-vnet-aks 10.0.0.0/22 ─────────────────────────┐
 │ <rg>-snet-agc         10.0.2.0/24   AGfC association (delegated), NSG <rg>-nsg-agc   │
 │        │ directly to pod IPs (CNI Overlay)  - NSG: AGfC subnet → pods only          │
 │        ▼                                                                             │
 │ <rg>-snet-aks-nodes   10.0.0.0/24   <rg>-aks (private API server), ALB Controller   │
 │ <rg>-snet-pe          10.0.1.16/28  Key Vault private endpoint                       │
 └──────────────────────────┬───────────────────────────────────────────────────────────┘
                            │ egress filtered by <rg>-nsg-aks (config/aks-egress-rules.json)
                            ▼
                  <rg>-natgw (outbound only) ──► allowed Azure service tags
```

> 📐 **Diagrams:** see [`docs/architecture.md`](docs/architecture.md). It has a request flow, allowed and blocked traffic paths, a detailed network diagram with every security control marked, the deployment pipeline flow, and full NSG rule tables.

## What you provide

| Input | Required | Default | Notes |
|---|---|---|---|
| `resource_group` | yes | — | Must already exist. Its **name** is the naming prefix and its **region** is used for every resource. The region must [support App Gateway for Containers](https://learn.microsoft.com/azure/application-gateway/for-containers/overview#supported-regions). |
| `system_node_vm_size` | yes | `Standard_D4ds_v5` | System pool SKU |
| `system_node_count` | yes | `3` | System pool node count (1–100) |
| `user_node_vm_size` | no | same as system | Workload pool SKU |
| `user_node_count` | yes | `2` | Workload pool node count (0–1000) |
| `aks_vnet_cidr` | yes | `10.0.0.0/22` | The environment's only vNet, `/16`–`/22`. Subnets are derived from it (see below). |
| `runner` | yes | `github-hosted` | `self-hosted` runs Plan/Apply on the [private runner](#private-github-runner-optional-deploy-first) and peers its vNet |
| `central_dns_zones` | no | empty | `<subscription>/<resource group>` of [central private DNS zones](#central-private-dns-zones-optional); empty = create the zones in this RG |
| `pod_cidr` | no | `10.244.0.0/16` | Overlay pod range, `/12`–`/20`. In the workflow: repository variable `AKS_POD_CIDR`. |
| `service_cidr` | no | `172.16.0.0/16` | Kubernetes service range, `/12`–`/24`; DNS service = 10th address. In the workflow: repository variable `AKS_SERVICE_CIDR`. |

Everything else has a secure default in [`terraform/variables.tf`](terraform/variables.tf). That includes admin groups, flow logs and log retention. Override any of them in a `terraform.tfvars` file (see [`terraform/terraform.tfvars.example`](terraform/terraform.tfvars.example)) or as `TF_VAR_<name>` environment variables.

### Resulting names (resource group `rg-shop-prod` in `eastus2`)

| Resource | Name |
|---|---|
| AKS cluster / node RG | `rg-shop-prod-aks` / `rg-shop-prod-aks-nodes` |
| vNet | `rg-shop-prod-vnet-aks` |
| Subnets | `rg-shop-prod-snet-aks-nodes`, `-snet-pe`, `-snet-agc`, `-snet-pg` |
| NSGs | `rg-shop-prod-nsg-aks`, `rg-shop-prod-nsg-agc`, `rg-shop-prod-nsg-pg` |
| App Gateway for Containers / frontend / association | `rg-shop-prod-agc`, `rg-shop-prod-agc-fe`, `rg-shop-prod-agc-assoc` |
| WAF policy / AGfC security policy | `rg-shop-prod-wafpol`, `rg-shop-prod-agc-waf` |
| NAT Gateway / PIP | `rg-shop-prod-natgw`, `rg-shop-prod-pip-natgw` |
| Log Analytics | `rg-shop-prod-log` |
| Key Vault | `rgshopprodkv<hash>` (alphanumeric + unique suffix: the name must be globally unique and ≤24 chars) |
| Identities | `rg-shop-prod-id-aks` (control plane), `rg-shop-prod-id-alb` (ALB Controller) |
| PostgreSQL server / DNS zone | `rg-shop-prod-pg-<hash>`, `rg-shop-prod.private.postgres.database.azure.com` |

## Network design and sizing

The environment uses **one vNet** with separate, NSG-protected subnets. App Gateway for Containers has to share the cluster's vNet: with Azure CNI Overlay, Microsoft [doesn't support it in a separate peered vNet in the same region](https://learn.microsoft.com/azure/application-gateway/for-containers/container-networking#cni-overlay-and-application-gateway-for-containers). Isolation comes from subnet NSGs and in-cluster Cilium network policy.

You only pass the vNet range; the subnets are carved out of it automatically, so they can never be misaligned. The defaults are roughly the smallest supported sizes, with room to grow:

| Subnet | Derived as | Default | Rationale |
|---|---|---|---|
| AKS vNet | `aks_vnet_cidr` | `10.0.0.0/22` | `/22` minimum: it must hold the node `/24` and the AGfC `/24` |
| Node subnet | 1st `/24` | `10.0.0.0/24` | Azure CNI **Overlay**: pods use `pod_cidr`, so the subnet only holds node IPs (251 nodes) |
| Private endpoint subnet | `/28` in the 2nd `/24` | `10.0.1.16/28` | Key Vault and future private endpoints |
| PostgreSQL subnet | 2nd `/27` of the 2nd `/24` | `10.0.1.64/27` | Delegated to `Microsoft.DBforPostgreSQL/flexibleServers` (VNet integration). Can't grow while the server exists; 27 usable IPs (an HA server uses 4) |
| AGfC association subnet | 3rd `/24` | `10.0.2.0/24` | App Gateway for Containers requires exactly `/24`, delegated to `Microsoft.ServiceNetworking/trafficControllers` |
| Free | | `10.0.1.0/28`, `10.0.1.32/27`, `10.0.1.96/27`…, `10.0.3.0/24` | Extra node pools or subnets |

Rules enforced at `terraform plan` time:
* Each range must be a valid IPv4 network (e.g. `10.0.0.0/22`, not `10.0.1.0/22`) within the allowed sizes.
* The AKS vNet, pod and service ranges (and the runner vNet, when connected) must not overlap each other. The plan fails with a message naming the overlapping pair.

You still need to make sure the ranges don't overlap networks outside this deployment that you peer or route to.

## Tags

Every resource that supports tags gets a copy of the **resource group's tags**. This includes both node pools; AKS also propagates the cluster's tags to the resources it creates in the node resource group. Change a tag on the resource group and the next `apply` updates all resources.

To add tags that aren't on the resource group, set `additional_tags`. If a key exists in both, the resource group's value wins. Some resource types can't hold tags in Azure: subnets, NSG rules, peerings, role and policy assignments, and diagnostic settings.

### No direct Internet ingress to AKS

* **The only entry point** is the AGfC frontend (an Azure-managed FQDN). Its listeners accept only ports 80/443, and the WAF policy (**Prevention**, Microsoft Default Rule Set 2.1 + Bot Manager 1.0) is applied to **every** listener and route on the platform Gateway.
* **WAF is enabled in two places, and both are required:**
  * the Azure security policy `<rg>-agc-waf` (Terraform);
  * the in-cluster `WebApplicationFirewallPolicy` targeting the whole Gateway ([`k8s/platform/gateway.yaml`](k8s/platform/gateway.yaml)).

  With only one of them, AGfC doesn't inspect traffic.
* `<rg>-nsg-agc` allows only Internet → 80/443 plus `AzureLoadBalancer` into the AGfC subnet, and outbound traffic to the pod range.
* `<rg>-nsg-aks` allows the AGfC subnet to reach **pod IPs only**. It denies everything else from that subnet, and all inbound traffic from `Internet`.
* No Kubernetes `Service` is exposed on a load balancer. Workloads publish an `HTTPRoute` on the platform Gateway, and only namespaces labelled `agc-routes: allowed` may attach routes.
* The API server is private (no public FQDN). Local accounts are disabled and Entra ID with Azure RBAC is enforced.
* Egress goes through a **NAT Gateway** (`outboundType: userAssignedNATGateway`), so AKS creates **no public load balancer**. The Azure Policy *"Kubernetes clusters should use internal load balancers"* (deny) rejects any `Service` that would get a public IP.
* The **ALB Controller** (the in-cluster component that programs AGfC) uses a **workload identity**, so it holds no secrets. It has only *AppGw for Containers Configuration Manager* on the resource group and *Network Contributor* on the AGfC subnet.

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

Traffic inside the vNet (private endpoints, AGfC, peered runner) and Azure DNS are not affected. The ALB Controller's endpoints (`management.azure.com`, `login.microsoftonline.com`, `*.alb.azure.com`, `mcr.microsoft.com`) are Azure-hosted and covered by these rules.

> ⚠️ **Limits of NSG-based egress control.** AKS outbound dependencies are defined as FQDNs. Microsoft documents that NSGs cannot express them exactly ([docs](https://learn.microsoft.com/azure/aks/outbound-rules-control-egress)). The `AzureCloud:443` rule keeps cluster creation, upgrades and scaling working. It still blocks all non-Azure Internet destinations, such as Docker Hub, GitHub and arbitrary sites. For FQDN-level control, put Azure Firewall in front, or use a [network-isolated cluster](https://learn.microsoft.com/azure/aks/concepts-network-isolated) with a private ACR, and then tighten or remove `Allow-AzureCloud-443`. To pull images from a registry outside Azure, add an allow rule above priority 4000.

## CIS Microsoft Azure Foundations Benchmark v1.4: control mapping

| CIS section | Recommendation | Implementation |
|---|---|---|
| 3 Storage (3.1) | Secure transfer required | Flow-log storage account: `supportsHttpsTrafficOnly` |
| 3 Storage | Public access disabled, default network deny, TLS 1.2 | `allowBlobPublicAccess=false`, `publicNetworkAccess=Disabled`, `defaultAction=Deny`, `minimumTlsVersion=TLS1_2`, infrastructure encryption |
| 5 Logging & Monitoring | Diagnostic settings that capture the appropriate categories | AKS control plane (incl. `kube-audit-admin`, `guard`), App Gateway for Containers (access + WAF logs), NSGs, public IP and Key Vault all send to `<rg>-log` |
| 5 Logging & Monitoring | Key Vault logging enabled | Key Vault `allLogs` (AuditEvent) to Log Analytics |
| 6 Networking (6.1 / 6.2) | RDP / SSH access from the Internet is restricted | Both NSGs deny inbound Internet except 80/443 to the AGfC subnet; nodes have no public IPs |
| 6 Networking (6.4 – 6.6) | Flow logs captured, retention > 90 days, Network Watcher enabled | Optional VNet flow logs (successor to NSG flow logs) in the regional Network Watcher, 365-day retention, Traffic Analytics (`enable_vnet_flow_logs = true`) |
| 7 Virtual Machines | Disks encrypted | Managed disks encrypted at rest by the platform, plus **encryption at host** on all node pools |
| 8 Other (Key Vault) | Key Vault recoverable | Soft delete (90 days) and purge protection |
| 8 Other (Key Vault) | RBAC for Key Vault | `enableRbacAuthorization=true`; least-privilege `Key Vault Secrets User` for the CSI driver |
| 8 Other (Key Vault) | Private endpoints for Key Vault | Public network access disabled; private endpoint and `privatelink.vaultcore.azure.net` linked to both vNets |
| 4 Database (4.3) | PostgreSQL: SSL enforced, log checkpoints / connections / disconnections, connection throttling, log retention > 3 days, no public access | `require_secure_transport`, `log_checkpoints`, `log_connections`, `log_disconnections`, `connection_throttle.enable` = on, `logfiles.retention_days` = 7; VNet integration with public network access disabled; Entra ID authentication; diagnostics to `<rg>-log` |
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
* Every `apply` installs or updates the **ALB Controller** (Helm chart `alb-controller`, version pinned in `ALB_CONTROLLER_VERSION`). It runs on the **system node pool** ([`k8s/platform/alb-controller-values.yaml`](k8s/platform/alb-controller-values.yaml)), so its PodDisruptionBudget can never block draining or deleting user nodes. It also applies the **platform Gateway and WAF policy** ([`k8s/platform/gateway.yaml`](k8s/platform/gateway.yaml)) through `az aks command invoke`, because the API server is private.
* `action=destroy` first removes what runs inside the cluster: the sample app, the Gateway and the ALB Controller. Only then does Terraform delete the Azure resources, so nothing in Kubernetes can block node-pool deletion.
* `deploy_sample_app=true` deploys [`k8s/sample-app.yaml`](k8s/sample-app.yaml) with an `HTTPRoute`. The workflow then waits until the AGfC frontend returns HTTP 200, and checks that the WAF blocks a SQL-injection probe with HTTP 403. On failure, a diagnostics step prints the Gateway, route, controller and pod state.

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

You can constrain `Role Based Access Control Administrator` with a condition that limits it to the roles this configuration assigns: Network Contributor, Private DNS Zone Contributor, Key Vault Secrets User, AppGw for Containers Configuration Manager, and Azure Kubernetes Service RBAC Cluster Admin.

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
          Microsoft.Insights Microsoft.Compute Microsoft.Storage Microsoft.PolicyInsights Microsoft.Security \
          Microsoft.ServiceNetworking Microsoft.NetworkFunction Microsoft.DBforPostgreSQL; do
  az provider register -n $ns
done
```

If the `EncryptionAtHost` feature isn't registered, the workflow logs a warning and deploys **without** encryption at host.

Terraform runs with `resource_provider_registrations = "none"`, because an identity scoped to a resource group cannot register providers. That's why the providers are registered here.

### 5. Configure GitHub

* **Secrets**: `AZURE_CLIENT_ID` (= `$APP_ID`), `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`
* **Variables**: `TFSTATE_RESOURCE_GROUP`, `TFSTATE_STORAGE_ACCOUNT`, `TFSTATE_CONTAINER` (optional, default `tfstate`), and optionally `AKS_POD_CIDR` / `AKS_SERVICE_CIDR` and the DNS zone names (`KV_` / `AKS_` / `ACR_` / `POSTGRES_PRIVATE_DNS_ZONE_NAME`)
* **Environments**: `azure-preview` and `azure-production`. Add required reviewers on `azure-production`.

Then run **Actions → Deploy secure AKS environment → Run workflow**.

## Private GitHub runner (optional, deploy first)

[`runner/`](runner) is a separate Terraform root, deployed by [`.github/workflows/deploy-runner.yml`](.github/workflows/deploy-runner.yml). It creates self-hosted GitHub Actions runner VMs inside a private vNet in the **same resource group**. Run it **before** the AKS workflow when you want the AKS Plan/Apply jobs to run inside your network instead of on GitHub-hosted runners.

```
<rg>-vnet-runner 10.2.0.0/26 ──peering (created by the AKS deployment)──► <rg>-vnet-aks
└─ <rg>-snet-runner 10.2.0.0/28                                          ├─ private API server (443)
   NSG <rg>-nsg-runner: deny ALL inbound                                 └─ Key Vault private endpoint (443)
   egress: 443/80 to Internet via default outbound access (no NAT Gateway), everything else denied
   <rg>-runner-01 … Ubuntu 24.04, no public IP, Trusted Launch, encryption at host
```

| Workflow input | Default | Notes |
|---|---|---|
| `resource_group` | — | The same existing resource group as the AKS environment |
| `runner_vnet_cidr` | `10.2.0.0/26` | `/16`–`/28`. The runner subnet is the first `/28` (11 IPs). It must not overlap the AKS vNet, pod or service ranges; the AKS plan fails if it does. |
| `runner_vm_size` | `Standard_D2s_v5` | Needs Gen2 / Trusted Launch support |
| `runner_count` | `1` | 1–11 VMs: `<rg>-runner-01`, `-02`, … |
| `action` | `plan` | `apply` deploys and registers the runners; `destroy` deletes the VMs and unregisters them from GitHub |

**Security design**
* No public IP and an NSG that denies all inbound traffic, so nothing on the Internet (or in peered vNets) can connect to the runner. Break-glass access is `az vm run-command invoke` or the serial console; no SSH is exposed.
* Outbound through Azure **default outbound access**: the runner subnet is not a private subnet, and there is no NAT Gateway or public IP of its own. Egress is limited by [`runner/config/runner-egress-rules.json`](runner/config/runner-egress-rules.json) to HTTPS (GitHub, Azure, Terraform registry) and HTTP (Ubuntu mirrors). Everything else to the Internet is denied. As with AKS, NSGs can't filter by FQDN; for that, put Azure Firewall in front.
  * The source IP is Microsoft-owned and **can change without notice**, so it can't be allow-listed (for example on the Terraform state storage account). Microsoft recommends an explicit outbound method (NAT Gateway, public IP or firewall) for deterministic egress.
  * Existing runner VMs only switch after a stop/deallocate. The runner workflow does this automatically on the first `apply` after the change: it detects the old NAT Gateway or private subnet, then deallocates and starts the VMs.
  * The AKS cluster keeps its NAT Gateway (`outboundType: userAssignedNATGateway`). AKS doesn't support default outbound access for nodes: it rejects a `0.0.0.0/0` route to the Internet, and the outbound type `none` requires a network-isolated cluster.
* Trusted Launch (secure boot + vTPM), encryption at host, platform-managed OS patching, password login disabled, and the runner service runs as an unprivileged `runner` user.
* The runner VMs have **no Azure identity or roles**. Jobs still sign in to Azure with the same GitHub OIDC credentials as GitHub-hosted runners.
* **Registration token never stored.** Terraform only stages the runner software (cloud-init). The workflow then asks GitHub for a 1-hour registration token and registers each VM through `az vm run-command`, so the token is never in Terraform state, the plan artifact or the VM model.

**What the AKS deployment adds when `runner = self-hosted`**

The workflow sets `runner_vnet_name = <rg>-vnet-runner`, and the AKS Terraform then:
* peers the AKS and runner vNets (no forwarded traffic, no gateway transit);
* allows the runner vNet into the AKS vNet on **TCP 443** (private API server, Key Vault / ACR private endpoints) and **TCP 5432 to the private endpoint subnet** (PostgreSQL private endpoints), and denies everything else from it;
* links the private API server's DNS zone (`privatelink.<region>.azmk8s.io`, kept in your resource group) and the Key Vault DNS zone to the runner vNet. From the runner, `kubectl` works against the private API, and you can import certificates into the private Key Vault.

Keep `runner` the same on every AKS run. Switching back to `github-hosted` removes the peering and DNS links again.

### Setup

1. **Secret `RUNNER_ADMIN_TOKEN`**: a fine-grained personal access token (or GitHub App token) for this repository with **Administration: Read and write**. It is only used to request registration tokens and to unregister runners on destroy.
2. The OIDC app, state storage, role assignments and environments from the AKS setup above are reused. The runner's state is stored as `<rg>-runner.tfstate`.
3. Run **Actions → Deploy private GitHub runner** with `action = apply`. The run waits until every runner shows **online** under Settings → Actions → Runners.
4. Run **Deploy secure AKS environment** with `runner = self-hosted`.

> ⚠️ Self-hosted runners execute workflow code inside your network. Keep this repository **private**, or make sure pull requests from forks can't run on these runners. The workflows here only target the self-hosted runner from manual `workflow_dispatch` runs; pull-request jobs stay on GitHub-hosted runners.

## PostgreSQL 16 (VNet integration)

Each environment gets an **Azure Database for PostgreSQL flexible server 16** with **private access (VNet integration)**, defined in [`terraform/postgres.tf`](terraform/postgres.tf). It has no public endpoint at all: the server is injected into its own delegated subnet in the AKS vNet.

```
<rg>-vnet-aks
├─ <rg>-snet-aks-nodes 10.0.0.0/24 ──TCP 5432──►┐  (pods leave the overlay with their node's IP)
└─ <rg>-snet-pg 10.0.1.64/27  delegated to Microsoft.DBforPostgreSQL/flexibleServers
     <rg>-pg-<hash>  PostgreSQL 16 · public network access disabled · TLS required
     NSG <rg>-nsg-pg   in : 5432 from the node subnet, the subnet itself (HA), the private runner
                            AzureLoadBalancer · everything else from VirtualNetwork denied
                       out: 5432 in-subnet · Storage 443 (WAL/backups) · Entra ID 443 · Internet denied
DNS <rg>.private.postgres.database.azure.com  (linked to the AKS vNet and the runner vNet)
```

| Setting | Default | Repository variable (workflow) |
|---|---|---|
| Create the server | `true` | `POSTGRES_ENABLED` (`false` to skip) |
| SKU | `B_Standard_B1ms` | `POSTGRES_SKU`, e.g. `GP_Standard_D2ds_v5` for production |
| Storage | `32768` MB, auto-grow | `POSTGRES_STORAGE_MB` |
| Zone-redundant HA | `false` | `POSTGRES_HA` (`true`; not on `B_` SKUs) |
| Backup retention | 7 days | `POSTGRES_BACKUP_RETENTION_DAYS` (7–35) |
| Databases | none | `POSTGRES_DATABASES`, e.g. `orders, inventory` |
| Entra ID admin group | none | `POSTGRES_ENTRA_ADMIN_GROUP_ID` + `POSTGRES_ENTRA_ADMIN_GROUP_NAME` (display name) |
| Password (break-glass) admin `pgadmin` | on | `POSTGRES_PASSWORD_AUTH` (`false` once Entra logins work; then the Entra admin group is required) |

* **Connecting:** use the output `postgres_fqdn` (`<server>.postgres.database.azure.com`). It resolves to the private IP in the AKS and runner vNets. TLS is required (`sslmode=require`).
* **Authentication:** Entra ID is always on. For workloads, the recommended path is **workload identity + Entra ID tokens**, so no password is involved. The `pgadmin` password is generated once and kept only in the Terraform state. Read it with `terraform output -raw postgres_admin_password`; the workflow never prints it.
* **Logging:** CIS server parameters (see the CIS table above). Server logs and metrics, and the subnet NSG's events, go to `<rg>-log`.
* **Backups:** automatic, 7–35 days point-in-time restore. Optionally geo-redundant (`postgres_geo_redundant_backup_enabled`, fixed at creation).
* **Limits:** a VNet-integrated server can't move to another subnet or vNet, and the subnet can't grow while it exists. Changing `aks_vnet_cidr` therefore recreates the server, **including its data**.
* **Clients outside the vNet** (on-premises, other spokes): link `<rg>.private.postgres.database.azure.com` to your DNS resolver's vNet, and allow their source ranges on 5432 in `<rg>-nsg-pg`.
* **Per-application databases:** the [Deploy application](apps/README.md) workflow can still create a separate server per app. Those use a private endpoint in `<rg>-snet-pe` rather than VNet integration.

## Central private DNS zones (optional)

By default each environment creates its own private DNS zones in its resource group:

| Zone | Used by |
|---|---|
| `privatelink.vaultcore.azure.net` | The environment's Key Vault private endpoint |
| `privatelink.<region>.azmk8s.io` | The private AKS API server |
| `privatelink.azurecr.io` | Azure Container Registry private endpoints, including the `<registry>.<region>.data` data-endpoint records |
| `privatelink.postgres.database.azure.com` | Azure Database for PostgreSQL flexible server private endpoints |

The ACR and PostgreSQL zones are **prepared for workloads**: this environment doesn't deploy a registry or a database. When you add a private endpoint for one, put it in the `pe` subnet (or any subnet that can reach it) and point its `private_dns_zone_group` at the zone ID from the Terraform output `private_dns_zone_ids` (`acr` / `postgres`). Pods and the private runner then resolve `<name>.azurecr.io` / `<name>.postgres.database.azure.com` to the private IP. Pods reach the endpoints on any port. The private runner reaches the AKS vNet on TCP 443, so it can pull from or push to a private ACR. It also reaches TCP 5432 in the `pe` subnet only (NSG rule `Allow-Runner-PostgreSQL-Inbound`), so database jobs such as migrations can run on it. Put PostgreSQL private endpoints in the `pe` subnet. The rule is left out when the PostgreSQL zone is skipped. To rename a zone, set the repository variable `ACR_PRIVATE_DNS_ZONE_NAME` / `POSTGRES_PRIVATE_DNS_ZONE_NAME`. To skip a zone, set the variable to `none`.

> ℹ️ The PostgreSQL zone is for servers with **public access + private endpoint** (the recommended Private Link model). A server with **private access (VNet integration)** is injected into a delegated subnet and needs its own zone whose name ends in `postgres.database.azure.com` and isn't the server name, for example `<rg>.private.postgres.database.azure.com`. It isn't covered here.

To use **central zones**, for example in a hub or shared-services subscription:

1. **Create the zones once** with **Deploy central private DNS zones** ([`deploy-dns-zones.yml`](.github/workflows/deploy-dns-zones.yml), Terraform [`dns-zones/`](dns-zones)).
   * Inputs: `subscription` (name or ID), an **existing** `resource_group`, and `aks_region` (empty = the RG's region).
   * It creates all four zones with the resource group's tags.
2. **Deploy the environment** with **Deploy secure AKS environment** and set the input **`central_dns_zones`** = `<subscription name or ID>/<resource group>`, for example `Hub Subscription/rg-dns-hub`. Leave it empty for local zones. The AKS Terraform ([`terraform/dns.tf`](terraform/dns.tf)) then looks up the zone IDs by name in that subscription and:
   * uses the API zone for the private cluster and grants the cluster identity *Private DNS Zone Contributor* on it;
   * registers the Key Vault private endpoint record in the Key Vault zone;
   * creates the vNet links in the DNS subscription:

| Zone | Linked vNets |
|---|---|
| `privatelink.vaultcore.azure.net` | `<rg>-vnet-aks`, `<rg>-vnet-runner` (when `runner = self-hosted`) |
| `privatelink.azurecr.io` | `<rg>-vnet-aks`, `<rg>-vnet-runner` (when `runner = self-hosted`) |
| `privatelink.postgres.database.azure.com` | `<rg>-vnet-aks`, `<rg>-vnet-runner` (when `runner = self-hosted`) |
| `privatelink.<region>.azmk8s.io` | `<rg>-vnet-runner` (when `runner = self-hosted`). AKS [links its own vNet](https://learn.microsoft.com/azure/aks/private-clusters#hub-and-spoke-with-custom-dns-for-private-aks-clusters) when it uses a custom zone; a second link would conflict. |

The zone names default to the standard ones. The API zone name must match the cluster's region, and the plan fails otherwise. To override the names, set the repository variables `KV_PRIVATE_DNS_ZONE_NAME` / `AKS_PRIVATE_DNS_ZONE_NAME` / `ACR_PRIVATE_DNS_ZONE_NAME` / `POSTGRES_PRIVATE_DNS_ZONE_NAME`. Every zone that isn't skipped must exist in the central resource group. If yours were created by an earlier version of the DNS zones workflow, re-run it with `action = apply` to add the ACR and PostgreSQL zones. Destroying the environment also removes its links; the zones themselves stay.

> ⚠️ A cluster's private DNS zone can't be changed after creation. Switching an **existing** environment between local and central zones (or to other central zones) recreates the cluster, so destroy it first. Use the same `central_dns_zones` value on every run.

**Permissions in the DNS subscription** (for the same OIDC app registration):

```bash
DNS_SCOPE=/subscriptions/<dns-subscription-id>/resourceGroups/<dns-resource-group>
az role assignment create --assignee "$APP_ID" --role "Private DNS Zone Contributor"            --scope "$DNS_SCOPE"  # zones, vNet links, record registration
az role assignment create --assignee "$APP_ID" --role "Role Based Access Control Administrator" --scope "$DNS_SCOPE"  # grants the AKS identity "Private DNS Zone Contributor" on the API zone
az provider register --subscription <dns-subscription-id> -n Microsoft.Network
az provider register --subscription <dns-subscription-id> -n Microsoft.ContainerService # required in both subscriptions
```

Subscription names are resolved to IDs with [`.github/scripts/resolve-subscription.sh`](.github/scripts/resolve-subscription.sh). The zones' Terraform state stays in the usual state storage account (`dns-zones-<subscription-id>-<rg>.tfstate`).

## Operating the private cluster

```bash
# Run kubectl through the ARM control plane; no network line of sight needed:
az aks command invoke -g $RG -n $RG-aks --command "kubectl get nodes -o wide"
```

For interactive access from inside the network, use the [private GitHub runner](#private-github-runner-optional-deploy-first), or add a jumpbox / Azure Bastion in a peered vNet. Admins come from `aks_admin_group_object_ids`, which are Entra ID groups granted *Azure Kubernetes Service RBAC Cluster Admin*.

## Exposing your applications

> **The easy way:** the **Deploy application** workflow ([`apps/`](apps/README.md)) does all of the following for you, from a container image or your own manifest. It also creates a private PostgreSQL server with a private endpoint when the app needs one. The rest of this section explains what it sets up.

Workloads are published with the Kubernetes **Gateway API**. They don't use load balancers or `Ingress` objects. The platform Gateway `ingress/agc-gateway` is bound to the Terraform-created AGfC resource and frontend, and is WAF-protected. To publish an app:

1. Label its namespace with `agc-routes: allowed`. Only labelled namespaces can attach routes to the Internet-facing Gateway.
2. Give it a `ClusterIP` Service and an `HTTPRoute` that references the Gateway:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: my-app
  namespace: my-app            # namespace labelled agc-routes: allowed
spec:
  parentRefs:
    - name: agc-gateway
      namespace: ingress
      sectionName: http
  hostnames: ["app.contoso.com"] # optional; CNAME it to the agc_frontend_fqdn output
  rules:
    - backendRefs:
        - name: my-app
          port: 80
```

AGfC proxies straight to the pod IPs and health-probes them. A readiness probe on the pods and a NetworkPolicy that allows the container port keep this working. [`k8s/sample-app.yaml`](k8s/sample-app.yaml) is a complete example. The WAF policy applies automatically, because it targets the whole Gateway. To give a single route its own WAF policy, add another `WebApplicationFirewallPolicy` targeting that `HTTPRoute`.

### HTTPS

AGfC terminates TLS from a Kubernetes `kubernetes.io/tls` Secret referenced by a Gateway listener:

1. Store the certificate in the environment's Key Vault. The vault is private, so do this from inside the network (for example a workflow job on the [private runner](#private-github-runner-optional-deploy-first)), or temporarily allow your IP.
2. Sync it into the `ingress` namespace as a TLS Secret. The Secrets Store CSI driver is already enabled; use a `SecretProviderClass` with `secretObjects`, and give it workload identity with *Key Vault Secrets User*.
3. Add an HTTPS listener to [`k8s/platform/gateway.yaml`](k8s/platform/gateway.yaml) (`port: 443`, `protocol: HTTPS`, `tls.certificateRefs`). Then redirect HTTP to HTTPS with an `HTTPRoute` `RequestRedirect` filter. AGfC accepts TLS 1.2 and 1.3 only.

### Migrating from the earlier App Gateway (WAF_v2) design

`terraform apply` removes the App Gateway, its vNet, peering and public IP, and the internal ingress subnet, and adds the AGfC resources. Before Terraform runs, the workflow deletes the old smoke-test `LoadBalancer` Service, which otherwise blocks the subnet deletion. If you created other internal `LoadBalancer` Services in `<rg>-snet-aks-ingress`, delete them first and republish them through an `HTTPRoute`.

## Repository layout

```
terraform/
  providers.tf                  # azurerm provider + azurerm (Entra ID auth) backend
  variables.tf                  # inputs and secure defaults
  main.tf                       # naming, locals, Log Analytics workspace
  network.tf                    # vNets, subnets, NSGs + rules, NAT GW, peering
  aks.tf                        # private AKS cluster, user pool, Container Insights, RBAC
  agc.tf                        # App Gateway for Containers, WAF policy + security policy, ALB Controller identity
  keyvault.tf                   # Key Vault, private endpoint, RBAC
  dns.tf                        # private DNS zones: local (default) or central zones + links (other subscription)
  policy.tf                     # Azure Policy assignments (internal LB, pod security)
  postgres.tf                   # PostgreSQL 16 flexible server, VNet integration (delegated subnet, NSG, DNS zone)
  flowlogs.tf                   # optional VNet flow logs
  outputs.tf
  config/aks-egress-rules.json  # editable AKS egress NSG rules
  terraform.tfvars.example
  tests/                        # offline `terraform test` suite (mocked provider)
  .terraform.lock.hcl           # pinned provider version (azurerm 5.13.0)
runner/                         # separate Terraform root: private GitHub runner
  main.tf                       # runner vNet, NSG, VMs (Trusted Launch); egress via default outbound access
  variables.tf  outputs.tf  providers.tf
  cloud-init.yaml.tftpl         # installs Azure CLI + tools, stages the runner
  scripts/register-runner.sh    # run on the VM via az vm run-command
  config/runner-egress-rules.json
  tests/                        # offline `terraform test` suite
dns-zones/                      # separate Terraform root: central private DNS zones
apps/                           # application deployments (own README)
  deploy-app.sh                 # renders/applies an app + HTTPRoute, health probe, NetworkPolicies
  postgres/                     # separate Terraform root: per-app PostgreSQL + private endpoint
  examples/  tests/
k8s/platform/gateway.yaml       # platform Gateway + WebApplicationFirewallPolicy (applied every apply)
k8s/sample-app.yaml             # smoke-test app (HTTPRoute on the Gateway)
.github/scripts/aks-invoke.sh   # runs kubectl/helm in the private cluster via az aks command invoke
.github/workflows/deploy-aks.yml
.github/workflows/deploy-runner.yml
.github/workflows/deploy-dns-zones.yml
.github/workflows/deploy-app.yml
.github/scripts/resolve-subscription.sh
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
