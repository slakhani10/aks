# Architecture & security diagrams

These diagrams describe what [`terraform/`](../terraform) deploys. Addresses shown are the **defaults**; every subnet is derived from the `aks_vnet_cidr` / `agw_vnet_cidr` inputs, so substitute your own ranges (see [README → Network design](../README.md#network-design-and-sizing)). `<rg>` is the resource group name, used as the naming prefix.

PNG exports of every diagram are in [`docs/images/`](images/) for use outside GitHub.

Security controls are tagged **S1–S24** in the diagrams and explained in the [security specification catalogue](#security-specification-catalogue) at the end.

* [1. End-user request flow](#1-end-user-request-flow)
* [2. Allowed vs. blocked traffic paths](#2-allowed-vs-blocked-traffic-paths)
* [3. Detailed network diagram](#3-detailed-network-diagram)
* [4. Deployment & operations flow](#4-deployment--operations-flow)
* [NSG rule reference](#nsg-rule-reference)
* [Security specification catalogue](#security-specification-catalogue)

---

## 1. End-user request flow

How a single user request reaches a pod. Every hop has at least one control that can reject the request.

```mermaid
sequenceDiagram
    autonumber
    actor U as End user (Internet)
    participant PIP as Public IP<br/>#lt;rg#gt;-pip-agw<br/>Standard, static
    participant AGW as App Gateway WAF_v2<br/>#lt;rg#gt;-agw<br/>snet-agw 10.1.0.0/25
    participant KV as Key Vault<br/>(private endpoint)
    participant ILB as AKS internal LB<br/>10.0.1.4<br/>snet-aks-ingress
    participant POD as Pod on user node pool<br/>snet-aks-nodes 10.0.0.0/24

    U->>PIP: HTTPS :443 (or HTTP :80)
    Note over U,PIP: S1 nsg-agw: only Internet → 80/443 allowed (prio 100)<br/>everything else Deny-All-Inbound (prio 4096)
    PIP->>AGW: forward to listener

    opt HTTP request and a TLS certificate is configured
        AGW-->>U: 301 redirect to https:// (S4)
    end

    AGW->>KV: load TLS cert with managed identity #lt;rg#gt;-id-agw (S5)
    Note over AGW,KV: Key Vault Secrets User only, via privatelink.vaultcore.azure.net
    Note over AGW: S3 TLS 1.2+ (AppGwSslPolicy20220101S), HTTP/2

    AGW->>AGW: S2 WAF inspection, Prevention mode<br/>Microsoft DRS 2.1 + Bot Manager 1.0<br/>request body check, 128 KB body / 100 MB upload limit
    alt request matches a WAF rule
        AGW-->>U: 403 Forbidden (logged to Log Analytics, S20)
    else clean request
        AGW->>ILB: HTTP :80 to 10.0.1.4 over vNet peering (S7)<br/>original Host header preserved
        Note over AGW,ILB: S8 nsg-aks: allow only snet-agw → 80/443 (prio 100)<br/>deny all other agw-vNet traffic (prio 110)<br/>deny Internet inbound (prio 4000)
        ILB->>POD: load-balance to a healthy pod
        Note over ILB,POD: S12 Cilium network policy (namespace default-deny + allow :80)<br/>S13 pod security baseline enforced by Azure Policy
        POD-->>ILB: response
        ILB-->>AGW: response
        AGW-->>U: response (TLS-encrypted when HTTPS is on)
    end
```

> Health probes: App Gateway probes `GET /` on `10.0.1.4:80` every 30 s and expects 200–399. If none of the backends is healthy, users get 502 from the gateway. Traffic never bypasses the WAF to reach the cluster.

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

    %% ---------------- Ingress ----------------
    INET -->|HTTP/HTTPS to App Gateway public IP| C1{{"S1 nsg-agw 80/443<br/>S2 WAF Prevention<br/>S3 TLS 1.2+"}}:::ctrl
    C1 -->|clean request| A1["ALLOWED<br/>App Gateway → peering → ILB 10.0.1.4 → pod"]:::allow
    C1 -->|malicious / other ports| D1["BLOCKED<br/>403 from WAF or dropped by NSG"]:::deny

    INET -->|direct to nodes or ILB| C2{{"S9 no public IPs on nodes<br/>S8 nsg-aks Deny-Internet-Inbound"}}:::ctrl
    C2 --> D2["BLOCKED<br/>nothing in the AKS vNet is Internet-addressable"]:::deny

    INET -->|Kubernetes API server| C3{{"S14 private cluster<br/>no public FQDN"}}:::ctrl
    C3 --> D3["BLOCKED<br/>API server only reachable via private endpoint"]:::deny

    POD -->|create Service type LoadBalancer with public IP| C4{{"S11 Azure Policy<br/>internal load balancers only (deny)"}}:::ctrl
    C4 --> D4["BLOCKED<br/>admission denied by Gatekeeper"]:::deny

    %% ---------------- Egress ----------------
    POD -->|443 to Azure service tags<br/>Entra ID, MCR, Front Door, Monitor, AzureCloud| C5{{"S10 nsg-aks egress rules 100-140<br/>config/aks-egress-rules.json"}}:::ctrl
    C5 --> A5["ALLOWED<br/>via NAT Gateway static public IP"]:::allow

    POD -->|any other Internet destination| C6{{"S10 nsg-aks Deny-Internet-Outbound<br/>prio 4000"}}:::ctrl
    C6 --> D6["BLOCKED"]:::deny

    POD -->|Key Vault secrets| C7{{"S16 private endpoint + private DNS<br/>S17 RBAC: Key Vault Secrets User"}}:::ctrl
    C7 --> A7["ALLOWED<br/>stays inside the vNet"]:::allow

    %% ---------------- Management ----------------
    OPS -->|kubectl| C8{{"S15 Entra ID + Azure RBAC<br/>local accounts disabled"}}:::ctrl
    C8 -->|az aks command invoke via ARM| A8["ALLOWED<br/>for RBAC cluster admins only"]:::allow
    C8 -->|static kubeconfig / local admin| D8["BLOCKED"]:::deny
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

    subgraph RG["Resource group #lt;rg#gt; (S24)"]
        direction TB

        subgraph AGWVNET["S6 · vnet-agw 10.1.0.0/24"]
            direction TB
            subgraph SNAGW["snet-agw 10.1.0.0/25"]
                direction TB
                NSGAGW{{"S1 #lt;rg#gt;-nsg-agw<br/>in: Internet 80/443<br/>GatewayManager, AzureLB<br/>deny all else"}}:::nsg
                PIPAGW["#lt;rg#gt;-pip-agw<br/>Standard static public IP"]:::pub
                AGW["#lt;rg#gt;-agw · WAF_v2 · autoscale 2-10<br/>S2 WAF Prevention · DRS 2.1 · Bot Manager<br/>S3 TLS 1.2+ · S4 HTTP→HTTPS<br/>backend 10.0.1.4:80"]:::sec
            end
            FREEAGW["10.1.0.128/25 free"]:::res
        end

        subgraph AKSVNET["S6 · vnet-aks 10.0.0.0/22"]
            direction TB
            subgraph SNING["snet-aks-ingress 10.0.1.0/28"]
                ILB["Internal LB frontend 10.0.1.4<br/>S11 public LBs denied"]:::sec
            end
            subgraph SNNODES["snet-aks-nodes 10.0.0.0/24"]
                direction TB
                NSGAKS{{"S8 S10 #lt;rg#gt;-nsg-aks<br/>in: only snet-agw 80/443<br/>out: 443 to Azure tags · deny Internet<br/>also on ingress + PE subnets"}}:::nsg
                AKS["#lt;rg#gt;-aks · Standard tier<br/>S14 private API, no public FQDN<br/>S15 Entra ID + Azure RBAC, no local accounts<br/>CNI Overlay · pods 10.244.0.0/16 · svc 172.16.0.0/16<br/>S12 Cilium network policy"]:::sec
                POOLS["system + user node pools · AzureLinux<br/>S9 no public IPs · S18 encryption at host<br/>S21 auto patch + node-image upgrades"]:::res
                ADDONS["S13 Azure Policy add-on · S19 Defender<br/>Container Insights · Key Vault CSI<br/>workload identity · image cleaner"]:::sec
            end
            subgraph SNPE["snet-pe 10.0.1.16/28"]
                PEKV["#lt;rg#gt;-pe-kv<br/>S16 private endpoint"]:::sec
            end
            FREEAKS["10.0.1.32 - 10.0.3.255 free"]:::res
        end

        NATGW["#lt;rg#gt;-natgw + #lt;rg#gt;-pip-natgw<br/>S9 outbound-only static IP"]:::pub

        subgraph SHARED["Shared#nbsp;services"]
            direction LR
            KV["Key Vault #lt;rg#gt;kv#lt;hash#gt;<br/>S16 public access disabled<br/>S17 RBAC · soft delete · purge protection"]:::sec
            DNS["Private DNS<br/>privatelink.vaultcore.azure.net<br/>linked to both vNets"]:::res
            LAW["#lt;rg#gt;-log · Log Analytics<br/>S20 diagnostics: AKS, AGW, KV, NSG, PIP<br/>S22 VNet flow logs (optional)"]:::mon
        end

        subgraph GOV["Identity#nbsp;and#nbsp;governance"]
            direction LR
            IDAGW["#lt;rg#gt;-id-agw<br/>S5 Key Vault Secrets User"]:::res
            IDAKS["#lt;rg#gt;-id-aks<br/>Network Contributor on AKS vNet"]:::res
            POLICY["Azure Policy · RG scope<br/>S11 internal LBs only · deny<br/>S13 pod security baseline · deny"]:::sec
        end
    end

    AZSVC[("Azure service tags · 443<br/>Entra ID · MCR · Front Door<br/>Azure Monitor · AzureCloud")]:::ext
    BLOCKED[("Other Internet destinations")]:::nsg

    USER ==>|"80/443"| PIPAGW
    PIPAGW ==> AGW
    AGW ==>|"S7 peering · HTTP 80"| ILB
    ILB ==> POOLS
    AKS --- POOLS
    AKS --- ADDONS

    POOLS -->|"S10 allow 443"| NATGW
    NATGW --> AZSVC
    POOLS -.-x|"S10 deny"| BLOCKED

    POOLS -.->|"CSI secrets"| PEKV
    PEKV -.-> KV
    AGW -.->|"TLS cert"| IDAGW
    IDAGW -.-> KV
    POLICY -.-> ADDONS
```

### Address plan (defaults)

In the network diagram, subnet and vNet titles omit the `<rg>-` prefix for space; full names are below.

| Network | CIDR | Derived from | Contents | NSG |
|---|---|---|---|---|
| `<rg>-vnet-agw` | `10.1.0.0/24` | `agw_vnet_cidr` | | |
| `<rg>-snet-agw` | `10.1.0.0/25` | 1st `/25` | App Gateway instances (max 10 autoscale) | `<rg>-nsg-agw` |
| `<rg>-vnet-aks` | `10.0.0.0/22` | `aks_vnet_cidr` | | |
| `<rg>-snet-aks-nodes` | `10.0.0.0/24` | 1st `/24` | Node NICs (251 nodes), NAT Gateway attached | `<rg>-nsg-aks` |
| `<rg>-snet-aks-ingress` | `10.0.1.0/28` | 1st `/28` of 2nd `/24` | Internal LB frontend `10.0.1.4` | `<rg>-nsg-aks` |
| `<rg>-snet-pe` | `10.0.1.16/28` | next `/28` | Key Vault private endpoint | `<rg>-nsg-aks` |
| Pod overlay | `10.244.0.0/16` | `pod_cidr` | Pod IPs (not routable outside the cluster) | n/a (Cilium policy) |
| Services | `172.16.0.0/16` | `service_cidr` | ClusterIPs; DNS `172.16.0.10` | n/a |

The plan fails if any of the four input ranges overlap.

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
    RUN["Run workflow<br/>resource_group, VM sizes, node counts,<br/>aks_vnet_cidr, agw_vnet_cidr, action"]:::gh --> LINT
    LINT --> PLAN

    subgraph PREVIEW["env: azure-preview"]
        PLAN["plan job<br/>checks RG exists · EncryptionAtHost feature<br/>terraform plan → saved tfplan artifact (1 day)"]:::gh
    end

    PLAN -->|"action = plan"| STOP([stop: plan in run summary])
    PLAN -->|"action = apply / destroy"| GATE{{"S23 required reviewers<br/>environment: azure-production"}}:::gate

    subgraph PROD["env: azure-production"]
        APPLY["apply job<br/>terraform apply of the exact reviewed plan"]:::gh
        SMOKE["optional smoke test<br/>az aks command invoke → kubectl apply<br/>wait for AGW backend Healthy → curl via WAF"]:::gh
    end
    GATE --> APPLY --> SMOKE

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
    SMOKE -.->|"AKS RBAC Cluster Admin (deployer)"| CLUSTER
```

---

## NSG rule reference

### `<rg>-nsg-agw` (App Gateway subnet)

| Prio | Name | Direction | Source | Destination | Ports | Action |
|---|---|---|---|---|---|---|
| 100 | Allow-Internet-HTTP-HTTPS-Inbound | In | Internet | App Gateway subnet | TCP 80, 443 | Allow |
| 110 | Allow-GatewayManager-Inbound | In | GatewayManager | * | TCP 65200-65535 | Allow (required by AGW v2) |
| 120 | Allow-AzureLoadBalancer-Inbound | In | AzureLoadBalancer | * | * | Allow (health probes) |
| 4096 | Deny-All-Inbound | In | * | * | * | **Deny** |

Outbound uses the Azure defaults, which App Gateway v2 requires.

### `<rg>-nsg-aks` (node, ingress and private endpoint subnets)

| Prio | Name | Direction | Source | Destination | Ports | Action |
|---|---|---|---|---|---|---|
| 100 | Allow-AppGateway-HTTP-HTTPS-Inbound | In | App Gateway subnet | AKS vNet | TCP 80, 443 | Allow |
| 110 | Deny-AppGateway-Other-Inbound | In | App Gateway vNet | * | * | **Deny** |
| 4000 | Deny-Internet-Inbound | In | Internet | * | * | **Deny** |
| 100 | Allow-AzureActiveDirectory-443 | Out | * | AzureActiveDirectory | TCP 443 | Allow |
| 110 | Allow-MicrosoftContainerRegistry-443 | Out | * | MicrosoftContainerRegistry | TCP 443 | Allow |
| 120 | Allow-AzureFrontDoorFirstParty-443 | Out | * | AzureFrontDoor.FirstParty | TCP 443 | Allow |
| 130 | Allow-AzureMonitor-443 | Out | * | AzureMonitor | TCP 443 | Allow |
| 140 | Allow-AzureCloud-443 | Out | * | AzureCloud | TCP 443 | Allow |
| 4000 | Deny-Internet-Outbound | Out | * | Internet | * | **Deny** |

The outbound rules come from [`terraform/config/aks-egress-rules.json`](../terraform/config/aks-egress-rules.json). Azure's built-in rules (AllowVnetInBound/OutBound, AllowAzureLoadBalancerInBound, priority 65000+) still apply. They keep intra-vNet, peered and private endpoint traffic working.

---

## Security specification catalogue

| ID | Control | Where | Configuration | CIS Azure 1.4 section |
|---|---|---|---|---|
| S1 | App Gateway subnet NSG | `<rg>-nsg-agw` | Internet → 80/443 only; platform rules; deny-all at 4096 | 6 Networking |
| S2 | Web Application Firewall | `<rg>-wafpol` | Prevention mode; Microsoft DRS 2.1 + Bot Manager 1.0; request body inspection; 128 KB body, 100 MB upload | Defense in depth |
| S3 | TLS policy | `<rg>-agw` | `AppGwSslPolicy20220101S` (TLS 1.2+ only), HTTP/2 | 3 / 9 (TLS ≥ 1.2) |
| S4 | HTTP → HTTPS redirect | `<rg>-agw` | Permanent redirect when `app_gateway_certificate_kv_uri` is set | Encryption in transit |
| S5 | Certificate access by managed identity | `<rg>-id-agw` | Key Vault Secrets User on the vault only; no secrets in config | 8 Key Vault |
| S6 | Separate vNets | `<rg>-vnet-agw`, `<rg>-vnet-aks` | Internet-facing tier isolated from the cluster network | 6 Networking |
| S7 | Restricted peering | both peerings | No forwarded traffic, no gateway transit, no remote gateways | 6 Networking |
| S8 | AKS inbound NSG | `<rg>-nsg-aks` | Only App Gateway subnet on 80/443; rest of AGW vNet denied; Internet denied | 6.1 / 6.2 (no RDP/SSH from Internet) |
| S9 | No public IPs on nodes, controlled egress | node subnet | `node_public_ip_enabled = false`; `default_outbound_access_enabled = false`; NAT Gateway (`outboundType userAssignedNATGateway`), so no public LB is created | 6 Networking |
| S10 | Egress allow-list | `<rg>-nsg-aks` + JSON | 443 to five Azure service tags; deny Internet at 4000; editable | 6 Networking |
| S11 | Internal load balancers only | Azure Policy | Built-in `3fc4dc25…` with effect **deny** | Defense in depth |
| S12 | Pod network policy | AKS | Cilium dataplane + network policy; sample app uses namespace default-deny | Defense in depth |
| S13 | Pod security baseline | Azure Policy | Built-in initiative `a8640138…` with effect **deny** (system namespaces excluded) | Defense in depth |
| S14 | Private API server | AKS | `private_cluster_enabled`, no public FQDN, system-managed private DNS zone | 8 (AKS) |
| S15 | Identity & RBAC | AKS | Entra ID integration, Azure RBAC for Kubernetes, local accounts disabled; admins via Entra groups | 8 (RBAC on AKS) |
| S16 | Private Key Vault | Key Vault + `<rg>-pe-kv` | Public network access disabled; private endpoint; private DNS linked to both vNets | 8 (Key Vault private endpoints) |
| S17 | Key Vault hardening | Key Vault | RBAC authorization; soft delete 90 days; purge protection; least-privilege roles | 8 (recoverable, RBAC) |
| S18 | Encryption at host | node pools | Temp disks and caches encrypted; managed disks encrypted at rest by the platform | 7 Virtual Machines |
| S19 | Threat detection | AKS | Defender for Containers sensor; Container Insights via managed identity | 2 Defender for Cloud |
| S20 | Central logging | `<rg>-log` | Diagnostic settings: AKS control plane incl. `kube-audit-admin` and `guard`, AGW access and firewall logs, Key Vault audit, NSG events, public IPs | 5 Logging & Monitoring |
| S21 | Patch management | AKS | `automatic_upgrade_channel = patch`; `node_os_upgrade_channel = NodeImage`; image cleaner every 7 days; AzureLinux OS | 7 Virtual Machines |
| S22 | Network flow logs | Network Watcher | Optional VNet flow logs, 365-day retention, Traffic Analytics; hardened storage account | 6.4 – 6.6 |
| S23 | Secretless, gated pipeline | GitHub Actions | OIDC federation (no client secrets); RG-scoped roles; saved-plan apply behind required reviewers | 1 IAM (least privilege) |
| S24 | Consistent tagging | all taggable resources | Resource group tags copied verbatim; AKS propagates them to its node resource group | Governance |
