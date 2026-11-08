# Secure AKS environment (CIS Microsoft Azure Foundations Benchmark v1.4)

This repo holds Bicep templates and a GitHub Actions workflow. They deploy a private Azure Kubernetes Service (AKS) cluster into an **existing** resource group. The cluster is reachable from the Internet **only** through an Application Gateway with WAF.

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

## What you provide

| Input | Required | Default | Notes |
|---|---|---|---|
| `resource_group` | yes | — | Must already exist. Its **name** is the naming prefix and its **region** is used for every resource. |
| `system_node_vm_size` | yes | `Standard_D4ds_v5` | System pool SKU |
| `system_node_count` | yes | `3` | System pool node count (1–100) |
| `user_node_vm_size` | no | same as system | Workload pool SKU |
| `user_node_count` | yes | `2` | Workload pool node count (0–1000) |

Everything else has a secure default in [`infra/main.bicep`](infra/main.bicep). That includes address spaces, admin groups, an HTTPS certificate, flow logs and log retention. Override any of them with `-p name=value` or in [`infra/main.bicepparam`](infra/main.bicepparam).

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

The two vNets are separate and peered. Each is sized at roughly the smallest supported size, with room to grow:

| vNet / subnet | Size | Rationale |
|---|---|---|
| AKS vNet | `/22` | Room for extra node pools or subnets |
| Node subnet | `/24` | Azure CNI **Overlay**: pods use `10.244.0.0/16`, so the subnet only holds node IPs (251 nodes) |
| Ingress subnet | `/28` | Internal load balancer frontends only (smallest Azure subnet) |
| Private endpoint subnet | `/28` | Key Vault and future private endpoints |
| App Gateway vNet | `/24` | |
| App Gateway subnet | `/25` | 123 usable IPs ≥ max autoscale (10) with large headroom. Microsoft recommends `/24` if you plan to scale toward 125 instances, so override `agwSubnetPrefix` to use it. |

Services use `172.16.0.0/16`. All ranges are parameters, so change them if they overlap your network.

### No direct Internet ingress to AKS

* The API server is private (`enablePrivateCluster`, no public FQDN). Local accounts are disabled and Entra ID with Azure RBAC is enforced.
* Egress goes through a **NAT Gateway** (`outboundType: userAssignedNATGateway`), so AKS creates **no public load balancer**.
* The Azure Policy *"Kubernetes clusters should use internal load balancers"* is assigned with **deny**. A `Service` that would get a public IP is rejected.
* `<rg>-nsg-aks` denies inbound traffic from `Internet`. It allows traffic from the App Gateway subnet on 80/443 only, and denies everything else from the App Gateway vNet.
* App Gateway WAF_v2 runs in **Prevention** mode with Microsoft Default Rule Set 2.1, Bot Manager, TLS 1.2+ (`AppGwSslPolicy20220101S`) and HTTP/2. Its backend pool is the static internal load balancer IP `10.0.1.4` in the ingress subnet.

### Egress limited by an editable NSG

Outbound rules for the AKS subnets live in [`infra/config/aks-egress-rules.json`](infra/config/aks-egress-rules.json). Edit that file and redeploy to change them. Changes made in the portal are overwritten on the next deployment.

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
| 6 Networking (6.4 – 6.6) | Flow logs captured, retention > 90 days, Network Watcher enabled | Optional VNet flow logs (successor to NSG flow logs) in the regional Network Watcher, 365-day retention, Traffic Analytics (`enableVnetFlowLogs=true`) |
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

* **Pull requests**: Bicep build and lint only. No Azure access.
* **Run workflow** (manual): `lint` → `preview` (validate + what-if, shown in the run summary) → `deploy` (only when `action=deploy`; gated by the `azure-production` environment).
* `deploy_sample_app=true` deploys [`k8s/sample-app.yaml`](k8s/sample-app.yaml) through `az aks command invoke`, because the API server is private. The step then waits for App Gateway backend health and sends a request through the WAF.

### 1. Create an identity with OIDC federation (no secrets)

```bash
RG=rg-shop-prod
REPO=<owner>/<repo>
SUB=$(az account show --query id -o tsv)

APP_ID=$(az ad app create --display-name "gh-${RG}-deployer" --query appId -o tsv)
az ad sp create --id "$APP_ID"

for ENV in azure-preview azure-production; do
  az ad app federated-credential create --id "$APP_ID" --parameters "{
    \"name\": \"gh-${ENV}\",
    \"issuer\": \"https://token.actions.githubusercontent.com\",
    \"subject\": \"repo:${REPO}:environment:${ENV}\",
    \"audiences\": [\"api://AzureADTokenExchange\"]
  }"
done
```

### 2. Grant roles (scoped to the resource group)

The template creates role assignments and policy assignments, so Contributor alone is not enough:

```bash
SCOPE=/subscriptions/$SUB/resourceGroups/$RG
az role assignment create --assignee "$APP_ID" --role "Contributor"                                 --scope "$SCOPE"
az role assignment create --assignee "$APP_ID" --role "Role Based Access Control Administrator"    --scope "$SCOPE"
az role assignment create --assignee "$APP_ID" --role "Resource Policy Contributor"                --scope "$SCOPE"
# Only if enableVnetFlowLogs=true:
az role assignment create --assignee "$APP_ID" --role "Network Contributor" \
  --scope /subscriptions/$SUB/resourceGroups/NetworkWatcherRG
```

You can constrain `Role Based Access Control Administrator` with a condition that limits it to the roles this template assigns: Network Contributor, Key Vault Secrets User, and Azure Kubernetes Service RBAC Cluster Admin.

### 3. One-time subscription prerequisites

```bash
az feature register --namespace Microsoft.Compute --name EncryptionAtHost
for ns in Microsoft.ContainerService Microsoft.Network Microsoft.KeyVault Microsoft.OperationalInsights \
          Microsoft.Insights Microsoft.Compute Microsoft.Storage Microsoft.PolicyInsights Microsoft.Security; do
  az provider register -n $ns
done
```

If the `EncryptionAtHost` feature isn't registered, the workflow logs a warning and deploys **without** encryption at host.

### 4. Configure GitHub

* **Secrets**: `AZURE_CLIENT_ID` (= `$APP_ID`), `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`
* **Environments**: `azure-preview` and `azure-production`. Add required reviewers on `azure-production`.

Then run **Actions → Deploy secure AKS environment → Run workflow**.

## Operating the private cluster

```bash
# Run kubectl through the ARM control plane; no network line of sight needed:
az aks command invoke -g $RG -n $RG-aks --command "kubectl get nodes -o wide"
```

For interactive access, add a jumpbox or Azure Bastion in a peered vNet, or use a self-hosted runner inside the vNet. Admins come from `aksAdminGroupObjectIds`, which are Entra ID groups granted *Azure Kubernetes Service RBAC Cluster Admin*.

## Exposing your applications

App Gateway forwards to the internal load balancer IP `ingressPrivateIp` (default `10.0.1.4`). Expose your ingress controller with a `Service` annotated like this:

```yaml
metadata:
  annotations:
    service.beta.kubernetes.io/azure-load-balancer-internal: "true"
    service.beta.kubernetes.io/azure-load-balancer-internal-subnet: "<rg>-snet-aks-ingress"
    service.beta.kubernetes.io/azure-load-balancer-ipv4: "10.0.1.4"
spec:
  type: LoadBalancer
```

The App Gateway forwards the client's `Host` header, so host-based ingress rules keep working. The health probe calls `GET /` with host `127.0.0.1` and expects 200–399. Adjust the probe in `infra/modules/appgateway.bicep` if your ingress returns 404 for unknown hosts.

### HTTPS

1. Import a PFX certificate into the environment's Key Vault. The vault is private, so do this from inside the vNet, or temporarily allow your IP.
2. Redeploy with `appGatewayCertificateKvUri=https://<vault>.vault.azure.net/secrets/<cert-name>`. Use the versionless URI so the certificate rotates automatically.

The App Gateway identity `<rg>-id-agw` already has `Key Vault Secrets User` on the vault. The deployment adds an HTTPS listener and a permanent HTTP→HTTPS redirect.

## Repository layout

```
infra/
  main.bicep                    # orchestration, naming, parameters
  main.bicepparam               # example parameters for local deploys
  config/aks-egress-rules.json  # editable AKS egress NSG rules
  modules/
    network.bicep               # vNets, subnets, NSGs, NAT GW, peering
    aks.bicep                   # private AKS cluster, Container Insights, RBAC
    appgateway.bicep            # WAF policy + App Gateway WAF_v2
    keyvault.bicep              # Key Vault, private endpoint, private DNS
    monitoring.bicep            # Log Analytics workspace
    policy.bicep                # Azure Policy assignments (internal LB, pod security)
    flowlogs.bicep              # optional VNet flow logs
k8s/sample-app.yaml             # smoke-test app on the internal LB
.github/workflows/deploy-aks.yml
```

## Local deployment

```bash
az deployment group what-if  -g rg-shop-prod -f infra/main.bicep -p infra/main.bicepparam
az deployment group create   -g rg-shop-prod -f infra/main.bicep -p infra/main.bicepparam
```
