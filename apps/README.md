# Deploying applications to the secure AKS environment

This folder deploys **applications** onto an environment created by [**Deploy secure AKS environment**](../README.md). It publishes them on the Internet only through **App Gateway for Containers with WAF**. When an app needs one, it also creates a **private PostgreSQL flexible server**.

| Path | What it is |
|---|---|
| [`deploy-app.sh`](deploy-app.sh) | The deployment script. It validates the inputs, renders hardened manifests (or takes yours), adds the gateway route, health probe and network policies, and applies everything in the **private** cluster via `az aks command invoke` |
| [`postgres/`](postgres) | Terraform for the optional PostgreSQL server and its private endpoint (one state per app) |
| [`examples/`](examples) | An example manifest and a `settings` file with every option |
| [`tests/test-render.sh`](tests/test-render.sh) | Offline tests of the script (validation and rendered YAML) |
| [`../.github/workflows/deploy-app.yml`](../.github/workflows/deploy-app.yml) | The **Deploy application** workflow (manual or `workflow_call`) |

## What a deployment looks like

```
Internet ──HTTP──> AGfC frontend ──WAF (DRS 2.1, Prevention)──> HTTPRoute <route_path>
                    <rg>-agc-fe                                  │  (namespace labelled agc-routes=allowed)
                                                                 ▼
                                             Service <service_name> (ClusterIP)
                                                                 │  NetworkPolicy: only the container port
                                                                 ▼
                                             Pods (non-root, no privilege escalation, caps dropped)
                                                                 │  envFrom Secret <service_name>-postgres
                                                                 ▼ TCP 5432, TLS required
                         private endpoint in <rg>-snet-pe ──> PostgreSQL flexible server (public access disabled)
                         <server>.postgres.database.azure.com -> privatelink.postgres.database.azure.com -> private IP
```

Each run creates or updates these objects:

| Object | Purpose |
|---|---|
| `Namespace` (default = `service_name`) | Label `agc-routes: allowed` lets its routes attach to the platform Gateway; Kubernetes pod security **baseline** enforced (`restricted` warnings) on top of Azure Policy |
| `ServiceAccount`, `Deployment`, `Service` (ClusterIP), `PodDisruptionBudget` | Image mode only. Hardened pod spec: `runAsNonRoot`, `seccomp RuntimeDefault`, no service account token, `allowPrivilegeEscalation: false`, `drop: ALL`, resource requests and limits, readiness and liveness probes, spread over nodes. The PDB uses `maxUnavailable: 1`, so node drains never block |
| `HTTPRoute` | Attached to `agc-gateway` (namespace `ingress`) on `route_path`, optional `hostname`. By default the prefix is stripped before the request reaches the pod (`/orders/api` → `/api`) |
| `HealthCheckPolicy` | Tells AGfC how to probe the pods (`health_path`, 200–399 = healthy) |
| `NetworkPolicy` ×2 | Default-deny ingress for the namespace, then allow only the container port |
| `Secret <service_name>-postgres` | Only with `postgres = create`: `PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER`, `PGPASSWORD`, `PGSSLMODE=require`, `DATABASE_URL` |

Then the workflow:
1. waits for the rollout and for the route to be `Accepted` / `ResolvedRefs`;
2. calls the app through the public frontend;
3. sends an SQL-injection probe that the **WAF must block** (HTTP 403).

The run summary shows the public URL and the applied manifests.

## Run it

**Actions → Deploy application → Run workflow**

| Input | Example | Notes |
|---|---|---|
| `resource_group` | `rg-shop-prod` | The environment's resource group |
| `service_name` | `orders-api` | Kubernetes Service name: lowercase DNS label, ≤ 40 characters. Also names the Deployment, route, database and private endpoint |
| `source` | `image` / `manifest` | See below |
| `image` | `myacr.azurecr.io/shop/orders:1.4.2` | `<registry>/<repo>:<tag>` or `@sha256:<digest>`. `:latest` is rejected. Optional in manifest mode, where it replaces `${IMAGE}` |
| `manifest` | `apps/examples/hello-manifest.yaml` | Manifest mode: a YAML file in this repository |
| `container_port` | `8080` | Port the container listens on (also opened by the NetworkPolicy) |
| `route_path` | empty | Public path prefix. Empty = `/<service_name>`, `/` = the whole site (only one app per host can own `/`) |
| `postgres` | `none` / `create` | `create` = private PostgreSQL server for this app (see [PostgreSQL](#postgresql)) |
| `settings` | `{"replicas": 3}` | Optional JSON with everything else (see below) |
| `action` | `deploy` | `deploy`, `delete-app` (keeps the database), `delete-app-and-database` (**destroys** the database) |

The app is then reachable at `http://<agc-frontend-fqdn><route_path>`. For your own domain, set `settings.hostname` and point a DNS CNAME at the frontend FQDN (output `agc_frontend_fqdn` of the environment).

### `source = image`: deploy a container image

The workflow generates the Deployment, Service, PDB and ServiceAccount from the inputs and `settings`. It is the quickest way to ship an image from a registry.

* **Azure Container Registry** (`*.azurecr.io`): the workflow gives the cluster's kubelet identity **AcrPull** on the registry. This needs a role-assignment right on the registry: **Role Based Access Control Administrator** or **User Access Administrator**. If the workflow lacks it, the run prints the exact command for the registry owner.
* **Private ACR** (public network access disabled): create a private endpoint for the registry in the `<rg>-snet-pe` subnet, using the `privatelink.azurecr.io` zone. The environment already links that zone to the AKS vNet (output `private_dns_zone_ids.acr`).
* **Other registries** (Docker Hub, ...) are blocked by the AKS egress NSG, which only allows Azure service ranges. Import such images first: `az acr import -n myacr --source docker.io/library/nginx:1.27 --image nginx:1.27`.

### `source = manifest`: apply your own YAML

Use this for anything the generator doesn't cover, such as several containers, init containers, ConfigMaps, StatefulSets or CronJobs. The rules, which the script checks:

* leave `metadata.namespace` out, because objects are applied into the app namespace;
* include a **ClusterIP Service named `service_name`** exposing `settings.service_port` (default 80). The route points at it;
* no `Namespace`, cluster-wide objects (ClusterRole/Binding, CRDs, webhooks, PVs, StorageClasses), `Gateway`s, `LoadBalancer`/`NodePort` Services, or privileged / host-namespace pods;
* `${IMAGE}` is replaced by the `image` input, so a build pipeline can pass a new tag each time;
* the workflow adds the HTTPRoute, HealthCheckPolicy and NetworkPolicies. Here the NetworkPolicy opens `container_port` for all pods of the namespace.

See [`examples/hello-manifest.yaml`](examples/hello-manifest.yaml).

### `settings` (optional JSON)

| Key | Default | Meaning |
|---|---|---|
| `namespace` | `service_name` | Namespace. Platform namespaces (`kube-*`, `azure-*`, `ingress`, `default`, ...) are refused. A **dedicated** namespace (the default) is deleted as a whole by `delete-app` |
| `replicas` | `2` | 1–50 (image mode) |
| `service_port` | `80` | Port of the Service (image mode: created; manifest mode: must exist) |
| `hostname` | none | Host name for the route, e.g. `orders.contoso.com` (CNAME it to the AGfC frontend) |
| `health_path` | `/` | Readiness/liveness probe and AGfC health probe path, as the app sees it |
| `strip_path_prefix` | `true` | Rewrite `route_path` to `/` before the request reaches the pod |
| `cpu_request` / `memory_request` | `100m` / `128Mi` | Requests |
| `cpu_limit` / `memory_limit` | `500m` / `512Mi` | Limits |
| `env` | `{}` | Plain environment variables, `{"NAME": "value"}`. **No secrets**: workflow inputs are visible in the run. Use Key Vault and the Secrets Store CSI driver for those |
| `run_as_non_root` | `true` | Set `false` only for images that must run as root |
| `read_only_root_filesystem` | `false` | `true` adds a writable `emptyDir` at `/tmp` |
| `postgres` | see below | Database sizing (only with `postgres = create`) |

A full example is in [`examples/settings.example.json`](examples/settings.example.json). Unknown keys fail the run, so typos don't slip through.

## PostgreSQL

`postgres = create` runs [`postgres/`](postgres) (Terraform state `<rg>-app-<service>-postgres.tfstate`) before deploying the app.

* **Azure Database for PostgreSQL flexible server** `<rg>-<service>-pg-<hash>`, with **public network access disabled** and no VNet injection.
* **Private endpoint** `<rg>-pe-<service>-pg` in the environment's private endpoint subnet `<rg>-snet-pe`, inside the AKS vNet. It is registered in the `privatelink.postgres.database.azure.com` zone, local or central, which the environment links to the AKS and runner vNets.
* **CIS-aligned parameters** (CIS Azure 1.4 §4.3, flexible-server equivalents): `require_secure_transport=on`, `log_checkpoints`, `log_connections`, `log_disconnections`, `connection_throttle.enable=on`, `logfiles.retention_days=7`. Diagnostics go to the environment's Log Analytics workspace.
* A database named after the service (`-` → `_`).
* **Credentials:** a generated 32-character admin password. It is stored only in the Terraform state (private, Entra-ID-only storage) and in the Kubernetes Secret `<service>-postgres`, applied server-side so no `last-applied` annotation keeps a copy. The password is masked in logs.
* **Entra ID authentication** is enabled. To make an Entra **group** the server's Entra administrator, set the repository variables `POSTGRES_ENTRA_ADMIN_GROUP_ID` and `POSTGRES_ENTRA_ADMIN_GROUP_NAME`.

`settings.postgres` (all optional):

| Key | Default | |
|---|---|---|
| `sku_name` | `B_Standard_B1ms` | e.g. `GP_Standard_D2ds_v5` for production |
| `version` | `16` | 13–17 |
| `storage_mb` | `32768` | Can only grow; auto-grow is on |
| `backup_retention_days` | `7` | 7–35 |
| `geo_redundant_backup` | `false` | Fixed at creation |
| `database_name` | `service_name` with `_` | |

**Who can reach it:**
* pods in the cluster, on 5432 (the NSG's VirtualNetwork rule);
* the private GitHub runner, on 5432 to the PE subnet only (NSG rule `Allow-Runner-PostgreSQL-Inbound`), for migrations;
* nothing from the Internet.

Re-running `deploy` is idempotent. A changed `settings.postgres` (bigger SKU, more storage) is applied in place, and the Secret is refreshed. `delete-app` leaves the server in place; `delete-app-and-database` destroys it, including its backups.

> ℹ️ The private endpoint subnet is a `/28`, which gives **11 usable addresses**. The Key Vault uses 1, each PostgreSQL server 1, and each ACR endpoint 2 or more. For more than about 8 databases, use a larger private endpoint subnet.

## One-time prerequisites

These come on top of the [environment setup](../README.md):

* **Resource provider:** `az provider register --namespace Microsoft.DBforPostgreSQL` (once per subscription, only for databases).
* **Permissions:** the deployment identity already has what it needs in the environment's resource group (Contributor, Azure Kubernetes Service RBAC Cluster Admin for `command invoke`). With central DNS zones, it also needs Private DNS Zone Contributor on the central zones' resource group, the same as for the Key Vault endpoint.
* **ACR:** RBAC Administrator or User Access Administrator on the registries whose images you deploy (for the AcrPull grant), or have the registry owner grant AcrPull to the cluster's kubelet identity once. If you constrained the deployment identity's *Role Based Access Control Administrator* role with a condition (see the main README), add **AcrPull** to the roles it may assign.
* **Environment version:** the environment must have been deployed with a version that outputs `private_dns_zone_ids`. If not, re-run **Deploy secure AKS environment** with `action = apply`.

## Programmatic use

**From a build workflow:**

```yaml
jobs:
  build:
    # ... docker build && docker push myacr.azurecr.io/shop/orders:${{ github.sha }}
  deploy:
    needs: build
    uses: ./.github/workflows/deploy-app.yml
    secrets: inherit
    with:
      resource_group: rg-shop-prod
      service_name: orders-api
      image: myacr.azurecr.io/shop/orders:${{ github.sha }}
      container_port: "8080"
      postgres: create
      settings: '{"replicas": 3, "health_path": "/healthz"}'
```

The called workflow exposes the output `app_url`. The calling workflow needs `permissions: id-token: write`.

**With the script directly** (Azure CLI logged in, with rights on the cluster):

```bash
export RESOURCE_GROUP=rg-shop-prod SERVICE_NAME=orders-api SOURCE=image \
       IMAGE=myacr.azurecr.io/shop/orders:1.4.2 CONTAINER_PORT=8080 \
       SETTINGS='{"replicas":3,"health_path":"/healthz"}'
apps/deploy-app.sh render   # offline: writes ./out/orders-api/*.yaml for review
apps/deploy-app.sh apply    # applies them in the private cluster
apps/deploy-app.sh wait && apps/deploy-app.sh verify
apps/deploy-app.sh delete
```

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `admission webhook "validation.gatekeeper.sh" denied` | The pod violates the pod security baseline (Azure Policy): privileged, host namespaces, added capabilities, ... |
| Pods `ImagePullBackOff` | Missing AcrPull, registry not reachable (private ACR without endpoint), or a non-Azure registry blocked by egress rules |
| Route not `Accepted` | Namespace not labelled `agc-routes: allowed` (the workflow labels it), or a hostname or path conflicting with another route |
| WAF verification gets 502/503 | Health probe failing: check `health_path` and that the app answers 2xx/3xx there |
| `run_as_non_root` errors (`container has runAsNonRoot and image will run as root`) | The image runs as root. Use a non-root image (preferred) or set `"run_as_non_root": false` |
| App works but DB connection times out | Server not in the linked zone, or endpoint not approved. Check `nslookup <server>.postgres.database.azure.com` from a pod resolves to a `10.x` address |

The workflow prints routes, events and logs automatically when a deployment fails.
