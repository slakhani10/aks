# Architecture & security diagrams

These diagrams describe what [`terraform/`](../terraform) deploys. Addresses shown are the **defaults**; every subnet is derived from the `aks_vnet_cidr` input, so substitute your own ranges (see [README → Network design](../README.md#network-design-and-sizing)). `<rg>` is the resource group name, used as the naming prefix.

PNG exports of every diagram are in [`docs/images/`](images/) for use outside GitHub.

Security controls are tagged **S1–S27** in the diagrams and explained in the [security specification catalogue](#security-specification-catalogue) at the end.

* [1. End-user request flow](#1-end-user-request-flow)
* [2. Allowed vs. blocked traffic paths](#2-allowed-vs-blocked-traffic-paths)
* [3. Detailed network diagram](#3-detailed-network-diagram)
* [4. Deployment & operations flow](#4-deployment--operations-flow)
* [5. Private GitHub runner (optional)](#5-private-github-runner-optional)
* [NSG rule reference](#nsg-rule-reference)
* [Security specification catalogue](#security-specification-catalogue)

---

## 1. End-user request flow

How a single user request reaches a pod. Every hop has at least one control that can reject the request.

```mermaid
sequenceDiagram
    autonumber
    actor U as End user (Internet)
    participant FE as AGfC frontend<br/>#lt;rg#gt;-agc-fe<br/>Azure-managed FQDN
    participant AGC as App Gateway for Containers<br/>#lt;rg#gt;-agc<br/>snet-agc 10.0.2.0/24
    participant WAF as WAF policy<br/>#lt;rg#gt;-wafpol
    participant POD as Pod (sample-app)<br/>overlay IP 10.244.x.x

    U->>FE: HTTP :80 / HTTPS :443 (only listener ports)
    Note over U,FE: S1 nsg-agc: only Internet → 80/443 (+ AzureLoadBalancer)<br/>everything else Deny-All-Inbound (prio 4096)
    FE->>AGC: listener on Gateway ingress/agc-gateway
    Note over AGC: S3 TLS 1.2/1.3 only (HTTPS listener)<br/>S4 only routes from namespaces labelled agc-routes=allowed

    AGC->>WAF: S2 inspect: Prevention mode<br/>Microsoft DRS 2.1 + Bot Manager 1.0
    alt request matches a WAF rule
        WAF-->>U: 403 Forbidden (logged to Log Analytics, S20)
    else clean request
        AGC->>POD: HTTPRoute → Service → pod IP :8080 (direct, overlay routing)
        Note over AGC,POD: S8 nsg-aks: AGfC subnet may reach pod range only<br/>S12 Cilium network policy: default-deny + allow :8080<br/>S13 pod security baseline (Azure Policy)
        POD-->>AGC: response
        AGC-->>U: response (+ x-forwarded-for / x-request-id headers)
    end
```

> AGfC health-probes the pods directly; a pod only receives traffic once its readiness probe passes. No Kubernetes `Service` is ever exposed on a load balancer.

---

## 2. Allowed vs. blocked traffic paths

Every way traffic could try to enter or leave the environment, and the control that decides it.

```mermaid
flowchart LR
    classDef allow fill:#e6f4ea,stroke:#1e8e3e,color:#0d3b1e
    classDef deny fill:#fce8e6,stroke:#d93025,color:#5c1410
    classDef ctrl fill:#e8f0fe,stroke:#1a73e8,color:#0b2a5c
    classDef src fill:#f1f3f4,stroke:#5f6368,color:#202124

    INET([Internet user / attacker]):::src
    POD([Pod or node in AKS]):::src
    OPS([Operator / pipeline]):::src

    INET -->|HTTP/HTTPS to the AGfC frontend| C1{{"S1 nsg-agc 80/443<br/>S2 WAF Prevention<br/>S4 route admission"}}:::ctrl
    C1 -->|clean request| A1["ALLOWED<br/>AGfC → pod IP (overlay)"]:::allow
    C1 -->|attack / other ports| D1["BLOCKED<br/>403 from WAF or dropped by NSG"]:::deny

    INET -->|direct to nodes or pods| C2{{"S9 no public IPs<br/>S8 nsg-aks Deny-Internet-Inbound"}}:::ctrl
    C2 --> D2["BLOCKED<br/>nothing in the vNet is Internet-addressable"]:::deny

    INET -->|Kubernetes API server| C3{{"S14 private cluster<br/>no public FQDN"}}:::ctrl
    C3 --> D3["BLOCKED"]:::deny

    POD -->|create Service type LoadBalancer with public IP| C4{{"S11 Azure Policy<br/>internal load balancers only (deny)"}}:::ctrl
    C4 --> D4["BLOCKED<br/>admission denied by Gatekeeper"]:::deny

    POD -->|HTTPRoute from an unlabelled namespace| C5{{"S4 Gateway allowedRoutes<br/>selector agc-routes=allowed"}}:::ctrl
    C5 --> D5["NOT PUBLISHED"]:::deny

    POD -->|443 to Azure service tags| C6{{"S10 nsg-aks egress rules 100-140"}}:::ctrl
    C6 --> A6["ALLOWED<br/>via NAT Gateway static public IP"]:::allow

    POD -->|any other Internet destination| C7{{"S10 Deny-Internet-Outbound"}}:::ctrl
    C7 --> D7["BLOCKED"]:::deny

    POD -->|Key Vault secrets| C8{{"S16 private endpoint<br/>S17 RBAC"}}:::ctrl
    C8 --> A8["ALLOWED<br/>stays inside the vNet"]:::allow

    OPS -->|kubectl / helm| C9{{"S15 Entra ID + Azure RBAC<br/>local accounts disabled"}}:::ctrl
    C9 -->|az aks command invoke or private runner| A9["ALLOWED<br/>for RBAC cluster admins"]:::allow
    C9 -->|static kubeconfig / local admin| D9["BLOCKED"]:::deny
```

---

## 3. Detailed network diagram

```mermaid
%%{init: {"flowchart": {"wrappingWidth": 360}}}%%
flowchart TB
    classDef pub fill:#fef7e0,stroke:#f9ab00,color:#3c2a00
    classDef sec fill:#e8f0fe,stroke:#1a73e8,color:#0b2a5c
    classDef nsg fill:#fce8e6,stroke:#d93025,color:#5c1410
    classDef res fill:#ffffff,stroke:#5f6368,color:#202124
    classDef mon fill:#f3e8fd,stroke:#9334e6,color:#2d0a4e
    classDef ext fill:#f1f3f4,stroke:#5f6368,color:#202124

    USER(["End users · Internet"]):::ext
    FE["#lt;rg#gt;-agc-fe · AGfC frontend<br/>Azure-managed FQDN · ports 80/443"]:::pub

    subgraph RG["Resource group #lt;rg#gt; (S24)"]
        direction TB

        subgraph VNET["S6 · vnet-aks 10.0.0.0/22"]
            direction TB
            subgraph SNAGC["snet-agc 10.0.2.0/24"]
                direction TB
                NSGAGC{{"S1 #lt;rg#gt;-nsg-agc<br/>in: Internet 80/443, AzureLB<br/>deny all else · out: pods"}}:::nsg
                AGC["#lt;rg#gt;-agc · App Gateway for Containers<br/>delegated association #lt;rg#gt;-agc-assoc<br/>S2 WAF #lt;rg#gt;-wafpol: Prevention · DRS 2.1 · Bot Manager<br/>security policy #lt;rg#gt;-agc-waf"]:::sec
            end
            subgraph SNNODES["snet-aks-nodes 10.0.0.0/24"]
                direction TB
                NSGAKS{{"S8 S10 #lt;rg#gt;-nsg-aks<br/>in: AGfC subnet → pods only<br/>out: 443 to Azure tags · deny Internet"}}:::nsg
                AKS["#lt;rg#gt;-aks · Standard tier<br/>S14 private API · S15 Entra ID + Azure RBAC<br/>CNI Overlay · pods 10.244.0.0/16 · svc 172.16.0.0/16<br/>S12 Cilium network policy"]:::sec
                POOLS["system + user node pools · AzureLinux<br/>S9 no public IPs · S18 encryption at host<br/>S21 auto patch + node-image upgrades"]:::res
                ALB["S5 ALB Controller (azure-alb-system)<br/>workload identity #lt;rg#gt;-id-alb<br/>S4 Gateway ingress/agc-gateway"]:::sec
                ADDONS["S13 Azure Policy · S19 Defender<br/>Container Insights · Key Vault CSI"]:::sec
            end
            subgraph SNPE["snet-pe 10.0.1.16/28"]
                PEKV["#lt;rg#gt;-pe-kv<br/>S16 private endpoint"]:::sec
            end
            FREE["free: 10.0.1.0/28 · 10.0.1.32/27… · 10.0.3.0/24"]:::res
        end

        NATGW["#lt;rg#gt;-natgw + pip<br/>S9 outbound-only static IP"]:::pub

        subgraph SHARED["Shared services"]
            direction LR
            KV["Key Vault<br/>S16 public access disabled<br/>S17 RBAC · soft delete"]:::sec
            LAW["#lt;rg#gt;-log · Log Analytics<br/>S20 AKS, AGfC access + WAF, KV, NSG<br/>S22 VNet flow logs (optional)"]:::mon
        end

        POLICY["Azure Policy · RG scope<br/>S11 internal LBs only · S13 pod baseline"]:::sec
    end

    AZSVC[("Azure service tags · 443")]:::ext
    BLOCKED[("Other Internet destinations")]:::nsg

    USER ==>|"80/443"| FE
    FE ==> AGC
    AGC ==>|"S8 direct to pod IPs"| POOLS
    ALB -.->|"programs routes + WAF (config API)"| AGC
    AKS --- POOLS
    AKS --- ADDONS
    AKS --- ALB
    POOLS -->|"S10 allow 443"| NATGW
    NATGW --> AZSVC
    POOLS -.-x|"S10 deny"| BLOCKED
    POOLS -.->|"CSI secrets"| PEKV
    PEKV -.-> KV
    POLICY -.-> ADDONS
```

### Address plan (defaults)

In the network diagram, subnet and vNet titles omit the `<rg>-` prefix for space; full names are below.

| Network | CIDR | Derived from | Contents | NSG |
|---|---|---|---|---|
| `<rg>-vnet-aks` | `10.0.0.0/22` | `aks_vnet_cidr` | the environment's only vNet | |
| `<rg>-snet-aks-nodes` | `10.0.0.0/24` | 1st `/24` | Node NICs (251 nodes), NAT Gateway attached | `<rg>-nsg-aks` |
| `<rg>-snet-pe` | `10.0.1.16/28` | `/28` in the 2nd `/24` | Key Vault private endpoint | `<rg>-nsg-aks` |
| `<rg>-snet-agc` | `10.0.2.0/24` | 3rd `/24` | App Gateway for Containers association (delegated, exactly `/24`) | `<rg>-nsg-agc` |
| free | `10.0.1.0/28`, `10.0.1.32/27`…, `10.0.3.0/24` | | growth | |
| Pod overlay | `10.244.0.0/16` | `pod_cidr` | Pod IPs; AGfC proxies to these directly | n/a (Cilium policy) |
| Services | `172.16.0.0/16` | `service_cidr` | ClusterIPs; DNS `172.16.0.10` | n/a |

The plan fails if the AKS vNet, pod and service ranges (and the runner vNet, when connected) overlap.

---

## 4. Deployment & operations flow

How changes reach Azure. No long-lived credentials exist anywhere in the pipeline.

```mermaid
flowchart TB
    classDef gh fill:#f1f3f4,stroke:#24292f,color:#24292f
    classDef sec fill:#e8f0fe,stroke:#1a73e8,color:#0b2a5c
    classDef az fill:#e6f4ea,stroke:#1e8e3e,color:#0d3b1e
    classDef gate fill:#fef7e0,stroke:#f9ab00,color:#3c2a00

    PR["Pull request"]:::gh --> LINT["lint job<br/>terraform fmt · validate · test (mocked provider)<br/>no Azure access"]:::gh
    RUN["Run workflow<br/>resource_group, VM sizes, node counts,<br/>aks_vnet_cidr, action, runner"]:::gh --> LINT
    LINT --> PLAN

    subgraph PREVIEW["env: azure-preview"]
        PLAN["plan job<br/>checks RG exists · EncryptionAtHost feature<br/>terraform plan → saved tfplan artifact (1 day)"]:::gh
    end

    PLAN -->|"action = plan"| STOP([stop: plan in run summary])
    PLAN -->|"action = apply / destroy"| GATE{{"S23 required reviewers<br/>environment: azure-production"}}:::gate

    subgraph PROD["env: azure-production"]
        APPLY["apply job<br/>terraform apply of the exact reviewed plan"]:::gh
        PLATFORM["platform step (every apply)<br/>helm: ALB Controller (workload identity)<br/>kubectl: Gateway + WebApplicationFirewallPolicy<br/>wait until Gateway is Programmed"]:::gh
        SMOKE["optional smoke test<br/>sample app + HTTPRoute<br/>curl frontend → 200 · SQLi probe → 403"]:::gh
    end
    GATE --> APPLY --> PLATFORM --> SMOKE

    OIDC["S23 GitHub OIDC token<br/>subject = repo:#lt;owner/repo#gt;:environment:#lt;env#gt;"]:::sec
    ENTRA["Entra ID app registration<br/>federated credentials only, no client secret"]:::sec
    ARM["Azure Resource Manager<br/>RG-scoped roles: Contributor,<br/>RBAC Administrator, Resource Policy Contributor"]:::az
    STATE[("Terraform state<br/>Storage blob #lt;rg#gt;.tfstate<br/>Entra ID auth, blob-lease locking")]:::az
    CLUSTER["#lt;rg#gt;-aks private API<br/>reached only through ARM run-command"]:::az

    PLAN -.-> OIDC
    APPLY -.-> OIDC
    OIDC -.->|"token exchange"| ENTRA
    ENTRA -.-> ARM
    PLAN -.->|read| STATE
    APPLY -.->|read/write| STATE
    APPLY -.-> ARM
    PLATFORM -.->|"AKS RBAC Cluster Admin (deployer)"| CLUSTER
    SMOKE -.-> CLUSTER
```

---

## 5. Private GitHub runner (optional)

Created by [`runner/`](../runner) and [`deploy-runner.yml`](../.github/workflows/deploy-runner.yml) **before** the AKS workflow. When the AKS workflow runs with `runner = self-hosted`, its Plan/Apply jobs run here, and the AKS deployment adds the peering, NSG rules and DNS links shown in blue.

```mermaid
%%{init: {"flowchart": {"wrappingWidth": 360}}}%%
flowchart LR
    classDef sec fill:#e8f0fe,stroke:#1a73e8,color:#0b2a5c
    classDef nsg fill:#fce8e6,stroke:#d93025,color:#5c1410
    classDef res fill:#ffffff,stroke:#5f6368,color:#202124
    classDef pub fill:#fef7e0,stroke:#f9ab00,color:#3c2a00
    classDef ext fill:#f1f3f4,stroke:#5f6368,color:#202124

    GH(["GitHub · github.com"]):::ext
    INET(["Internet"]):::ext

    subgraph RG["Resource group #lt;rg#gt;"]
        direction LR
        subgraph RVNET["vnet-runner 10.2.0.0/26"]
            subgraph RSUB["snet-runner 10.2.0.0/28"]
                RNSG{{"#lt;rg#gt;-nsg-runner<br/>in: deny all<br/>out: 443/80 Internet only"}}:::nsg
                VM["S25 #lt;rg#gt;-runner-01 … Ubuntu 24.04<br/>no public IP · Trusted Launch<br/>encryption at host · auto-patching<br/>runner service as unprivileged user"]:::sec
            end
        end
        NAT["#lt;rg#gt;-natgw-runner<br/>outbound-only static IP"]:::pub
        subgraph AVNET["vnet-aks 10.0.0.0/22"]
            API["Private AKS API server :443"]:::sec
            PEKV["Key Vault private endpoint :443"]:::sec
        end
        DNS["Private DNS zones<br/>privatelink.#lt;region#gt;.azmk8s.io<br/>privatelink.vaultcore.azure.net"]:::res
    end

    VM -->|"HTTPS long-poll for jobs<br/>(outbound only)"| NAT --> GH
    NAT -.->|"other ports denied by NSG"| INET
    VM ==>|"S27 peering · TCP 443 only"| API
    VM ==> PEKV
    DNS -.->|"linked to runner vNet"| RVNET
```

**Registration flow (S26):** `terraform apply` creates the VMs, and cloud-init installs the Azure CLI and tools and stages the runner. The workflow then requests a 1-hour registration token from the GitHub API with `RUNNER_ADMIN_TOKEN` and runs [`register-runner.sh`](../runner/scripts/register-runner.sh) on each VM through `az vm run-command`. Finally, it waits until GitHub reports every runner **online**. The runner only makes outbound connections to GitHub; nothing connects to it.

---

## NSG rule reference

### `<rg>-nsg-agc` (App Gateway for Containers subnet)

| Prio | Name | Direction | Source | Destination | Ports | Action |
|---|---|---|---|---|---|---|
| 100 | Allow-Internet-HTTP-HTTPS-Inbound | In | Internet | * | TCP 80, 443 | Allow (frontend listeners) |
| 110 | Allow-AzureLoadBalancer-Inbound | In | AzureLoadBalancer | * | * | Allow (required by AGfC) |
| 4096 | Deny-All-Inbound | In | * | * | * | **Deny** |
| 100 | Allow-To-Pods-Outbound | Out | * | Pod range | TCP * | Allow (proxy + health probes) |

NSG rules on the AGfC subnet are fully enforced for associations created after April 23, 2026. Terraform attaches the NSG before it creates the association.

### `<rg>-nsg-aks` (node and private endpoint subnets)

| Prio | Name | Direction | Source | Destination | Ports | Action |
|---|---|---|---|---|---|---|
| 100 | Allow-AGC-To-Pods-Inbound | In | AGfC subnet | Pod range | TCP * | Allow |
| 110 | Deny-AGC-Other-Inbound | In | AGfC subnet | * | * | **Deny** |
| 120 | Allow-Runner-HTTPS-Inbound ¹ | In | Runner vNet | AKS vNet | TCP 443 | Allow |
| 130 | Deny-Runner-Other-Inbound ¹ | In | Runner vNet | * | * | **Deny** |
| 4000 | Deny-Internet-Inbound | In | Internet | * | * | **Deny** |
| 100 | Allow-AzureActiveDirectory-443 | Out | * | AzureActiveDirectory | TCP 443 | Allow |
| 110 | Allow-MicrosoftContainerRegistry-443 | Out | * | MicrosoftContainerRegistry | TCP 443 | Allow |
| 120 | Allow-AzureFrontDoorFirstParty-443 | Out | * | AzureFrontDoor.FirstParty | TCP 443 | Allow |
| 130 | Allow-AzureMonitor-443 | Out | * | AzureMonitor | TCP 443 | Allow |
| 140 | Allow-AzureCloud-443 | Out | * | AzureCloud | TCP 443 | Allow |
| 4000 | Deny-Internet-Outbound | Out | * | Internet | * | **Deny** |

¹ Only present when the AKS deployment is connected to the private runner (`runner_vnet_name` set).

The outbound rules come from [`terraform/config/aks-egress-rules.json`](../terraform/config/aks-egress-rules.json). Azure's built-in rules (AllowVnetInBound/OutBound, AllowAzureLoadBalancerInBound, priority 65000+) still apply. They keep node-to-node, peered and private endpoint traffic working.

### `<rg>-nsg-runner` (private runner subnet)

| Prio | Name | Direction | Source | Destination | Ports | Action |
|---|---|---|---|---|---|---|
| 4096 | Deny-All-Inbound | In | * | * | * | **Deny** |
| 100 | Allow-Internet-HTTPS | Out | * | Internet | TCP 443 | Allow |
| 110 | Allow-Internet-HTTP | Out | * | Internet | TCP 80 | Allow (Ubuntu mirrors) |
| 4000 | Deny-Internet-Outbound | Out | * | Internet | * | **Deny** |

The outbound rules come from [`runner/config/runner-egress-rules.json`](../runner/config/runner-egress-rules.json).

---

## Security specification catalogue

| ID | Control | Where | Configuration | CIS Azure 1.4 section |
|---|---|---|---|---|
| S1 | AGfC subnet NSG | `<rg>-nsg-agc` | Internet → 80/443 and AzureLoadBalancer only; deny-all inbound at 4096; outbound to the pod range | 6 Networking |
| S2 | Web Application Firewall | `<rg>-wafpol` + `<rg>-agc-waf` + `WebApplicationFirewallPolicy` | Prevention mode; Microsoft DRS 2.1 + Bot Manager 1.0; applied to every listener/route of the Gateway. Needs both the Azure security policy and the in-cluster policy; the workflow applies both and verifies a SQL-injection probe gets 403 | Defense in depth |
| S3 | TLS | AGfC listeners | TLS 1.2 and 1.3 only (not configurable lower); HTTPS listener from a Kubernetes TLS Secret, optionally synced from Key Vault | 3 / 9 (TLS ≥ 1.2) |
| S4 | Route admission | Gateway `ingress/agc-gateway` | `allowedRoutes` only from namespaces labelled `agc-routes: allowed`; no `Ingress`/`LoadBalancer` publishing | Defense in depth |
| S5 | ALB Controller identity | `<rg>-id-alb` | Workload identity federated to `azure-alb-system:alb-controller-sa` only; no secrets; *AppGw for Containers Configuration Manager* on the RG + *Network Contributor* on the AGfC subnet only | 1 IAM (least privilege) |
| S6 | Subnet isolation | `<rg>-vnet-aks` | One vNet (required by AGfC with CNI Overlay); AGfC in its own delegated subnet that holds nothing else; every subnet has an NSG | 6 Networking |
| S7 | Direct-to-pod ingress | AGfC + CNI Overlay | AGfC proxies straight to pod IPs; no node ports, no load-balancer Services, no in-cluster ingress proxy to patch | Defense in depth |
| S8 | AKS inbound NSG | `<rg>-nsg-aks` | Only the AGfC subnet → pod range; everything else from the AGfC subnet denied; Internet denied | 6.1 / 6.2 (no RDP/SSH from Internet) |
| S9 | No public IPs on nodes, controlled egress | node subnet | `node_public_ip_enabled = false`; `default_outbound_access_enabled = false`; NAT Gateway (`outboundType userAssignedNATGateway`), so no public LB is created | 6 Networking |
| S10 | Egress allow-list | `<rg>-nsg-aks` + JSON | 443 to five Azure service tags; deny Internet at 4000; editable | 6 Networking |
| S11 | Internal load balancers only | Azure Policy | Built-in `3fc4dc25…` with effect **deny** | Defense in depth |
| S12 | Pod network policy | AKS | Cilium dataplane + network policy; sample app uses namespace default-deny | Defense in depth |
| S13 | Pod security baseline | Azure Policy | Built-in initiative `a8640138…` with effect **deny** (system namespaces excluded) | Defense in depth |
| S14 | Private API server | AKS | `private_cluster_enabled`, no public FQDN; private DNS zone `privatelink.<region>.azmk8s.io` in the resource group, linked to the AKS vNet (and the runner vNet when connected) | 8 (AKS) |
| S15 | Identity & RBAC | AKS | Entra ID integration, Azure RBAC for Kubernetes, local accounts disabled; admins via Entra groups | 8 (RBAC on AKS) |
| S16 | Private Key Vault | Key Vault + `<rg>-pe-kv` | Public network access disabled; private endpoint; private DNS linked to the AKS vNet (and the runner vNet when connected) | 8 (Key Vault private endpoints) |
| S17 | Key Vault hardening | Key Vault | RBAC authorization; soft delete 90 days; purge protection; least-privilege roles | 8 (recoverable, RBAC) |
| S18 | Encryption at host | node pools | Temp disks and caches encrypted; managed disks encrypted at rest by the platform | 7 Virtual Machines |
| S19 | Threat detection | AKS | Defender for Containers sensor; Container Insights via managed identity | 2 Defender for Cloud |
| S20 | Central logging | `<rg>-log` | Diagnostic settings: AKS control plane incl. `kube-audit-admin` and `guard`, AGfC access and WAF logs, Key Vault audit, NSG events, NAT public IP | 5 Logging & Monitoring |
| S21 | Patch management | AKS | `automatic_upgrade_channel = patch`; `node_os_upgrade_channel = NodeImage`; image cleaner every 7 days; AzureLinux OS | 7 Virtual Machines |
| S22 | Network flow logs | Network Watcher | Optional VNet flow logs, 365-day retention, Traffic Analytics; hardened storage account | 6.4 – 6.6 |
| S23 | Secretless, gated pipeline | GitHub Actions | OIDC federation (no client secrets); RG-scoped roles; saved-plan apply behind required reviewers | 1 IAM (least privilege) |
| S24 | Consistent tagging | all taggable resources | Resource group tags copied verbatim; AKS propagates them to its node resource group | Governance |
| S25 | Private self-hosted runner | `runner/` | No public IP, all inbound denied, egress only 443/80 via NAT Gateway; Trusted Launch, encryption at host, platform patching, no password login; no Azure identity on the VM | 6 Networking · 7 Virtual Machines |
| S26 | Secret-free runner registration | `deploy-runner.yml` | 1-hour GitHub registration token requested per run and passed via `az vm run-command`; never in Terraform state, plan artifacts or the VM model | 1 IAM |
| S27 | Least-privilege runner reach | AKS NSG + peering | Runner vNet → AKS vNet on TCP 443 only (API server, Key Vault endpoint); everything else from the runner vNet denied; private DNS zones linked so names resolve privately | 6 Networking |
