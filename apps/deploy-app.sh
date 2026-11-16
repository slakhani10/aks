#!/bin/bash
# =============================================================================
# Deploy an application to the secure AKS environment and publish it through
# App Gateway for Containers (WAF) - see apps/README.md.
#
# Usage: apps/deploy-app.sh <command>
#   validate         check the inputs only (no Azure access)
#   render           write the Kubernetes manifests to $OUT_DIR (no Azure access)
#   grant-acr        give the cluster's kubelet identity AcrPull on the image's ACR
#   apply            render + apply in the private cluster (az aks command invoke)
#   wait             wait for the rollout and for the HTTPRoute to be accepted
#   verify           call the app through the AGfC frontend and probe the WAF
#   postgres-secret  create/update the <service>-postgres Secret (PG_* env vars)
#   delete           remove the application from the cluster
#   diagnostics      print route / pod state (for failed runs)
#
# Inputs (environment variables):
#   RESOURCE_GROUP   environment resource group (apply/wait/verify/delete/...)
#   SERVICE_NAME     Kubernetes Service name; also names the Deployment, route, ...
#   SOURCE           image | manifest
#   IMAGE            image mode: registry/repository:tag (or @sha256:digest)
#                    manifest mode: optional, replaces ${IMAGE} in the manifest
#   MANIFEST         manifest mode: path of a YAML file (Deployment + Service ...)
#   CONTAINER_PORT   port the container listens on (default 8080)
#   ROUTE_PATH       public path prefix (default /<service>); "/" = whole site
#   SETTINGS         optional JSON object with further settings (see README)
#   OUT_DIR          where rendered files go (default ./out/<service>)
#   AGC_FQDN         verify: the AGfC frontend FQDN (default: looked up in Azure)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INVOKE="${SCRIPT_DIR}/../.github/scripts/aks-invoke.sh"

die()  { echo "::error::$*" >&2; exit 1; }
warn() { echo "::warning::$*" >&2; }
note() { echo "::notice::$*"; }

RESERVED_NAMESPACES="default kube-system kube-public kube-node-lease ingress azure-alb-system gatekeeper-system aks-command azure-arc azure-extensions-usage-system"
DISALLOWED_KINDS="Namespace ClusterRole ClusterRoleBinding CustomResourceDefinition MutatingWebhookConfiguration ValidatingWebhookConfiguration PersistentVolume StorageClass Gateway GatewayClass PriorityClass"

# ------------------------------------------------------------------ inputs --
load_inputs() {
  SERVICE_NAME="${SERVICE_NAME:-}"
  SOURCE="${SOURCE:-image}"
  IMAGE="${IMAGE:-}"
  MANIFEST="${MANIFEST:-}"
  CONTAINER_PORT="${CONTAINER_PORT:-8080}"
  SETTINGS="${SETTINGS:-}"
  [ -n "$SETTINGS" ] || SETTINGS='{}'

  echo "$SETTINGS" | jq -e 'type == "object"' >/dev/null 2>&1 \
    || die "settings must be a JSON object, e.g. {\"replicas\": 3}"

  # Unknown keys are almost always typos - fail instead of silently ignoring them.
  local known='["namespace","replicas","service_port","hostname","health_path","strip_path_prefix","cpu_request","memory_request","cpu_limit","memory_limit","env","run_as_non_root","read_only_root_filesystem","postgres"]'
  local unknown
  unknown=$(echo "$SETTINGS" | jq -r --argjson k "$known" 'keys - $k | join(", ")')
  [ -z "$unknown" ] || die "Unknown settings: $unknown. Allowed: $(echo "$known" | jq -r 'join(", ")')"

  s() { echo "$SETTINGS" | jq -r --arg d "$2" "if has(\"$1\") and .$1 != null then .$1 | tostring else \$d end"; }
  NAMESPACE=$(s namespace "$SERVICE_NAME")
  REPLICAS=$(s replicas 2)
  SERVICE_PORT=$(s service_port 80)
  APP_HOSTNAME=$(s hostname "")
  HEALTH_PATH=$(s health_path "/")
  STRIP_PREFIX=$(s strip_path_prefix true)
  CPU_REQUEST=$(s cpu_request 100m)
  MEMORY_REQUEST=$(s memory_request 128Mi)
  CPU_LIMIT=$(s cpu_limit 500m)
  MEMORY_LIMIT=$(s memory_limit 512Mi)
  RUN_AS_NON_ROOT=$(s run_as_non_root true)
  READ_ONLY_ROOT=$(s read_only_root_filesystem false)
  ENV_JSON=$(echo "$SETTINGS" | jq -c '.env // {}')

  ROUTE_PATH="${ROUTE_PATH:-}"
  [ -n "$ROUTE_PATH" ] || ROUTE_PATH="/${SERVICE_NAME}"
  OUT_DIR="${OUT_DIR:-./out/${SERVICE_NAME}}"
  LABELS_SELECTOR="app.kubernetes.io/instance=${SERVICE_NAME},app.kubernetes.io/managed-by=deploy-app"
}

validate() {
  load_inputs
  local dns_label='^[a-z]([-a-z0-9]{0,38}[a-z0-9])?$'

  [[ "$SERVICE_NAME" =~ $dns_label ]] \
    || die "service_name '$SERVICE_NAME' must be a lowercase DNS label: letters, digits and '-', starting with a letter, at most 40 characters."
  [[ "$NAMESPACE" =~ ^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$ ]] || die "namespace '$NAMESPACE' is not a valid DNS label."
  for r in $RESERVED_NAMESPACES; do
    [ "$NAMESPACE" != "$r" ] || die "namespace '$NAMESPACE' is reserved for the platform."
  done
  case "$NAMESPACE" in kube-*|azure-*) die "namespace '$NAMESPACE' is reserved for the platform." ;; esac

  for p in "CONTAINER_PORT:$CONTAINER_PORT" "service_port:$SERVICE_PORT"; do
    local n="${p%%:*}" v="${p#*:}"
    [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -ge 1 ] && [ "$v" -le 65535 ] || die "$n must be a port number (1-65535), got '$v'."
  done
  [[ "$REPLICAS" =~ ^[0-9]+$ ]] && [ "$REPLICAS" -ge 1 ] && [ "$REPLICAS" -le 50 ] || die "replicas must be 1-50, got '$REPLICAS'."

  [[ "$ROUTE_PATH" =~ ^/[A-Za-z0-9._~/-]*$ ]] && [[ "$ROUTE_PATH" != *..* ]] \
    || die "route_path must start with '/' and contain only letters, digits and . _ ~ / - (got '$ROUTE_PATH')."
  [[ "$HEALTH_PATH" =~ ^/[A-Za-z0-9._~/?=\&-]*$ ]] || die "health_path must start with '/' (got '$HEALTH_PATH')."
  if [ -n "$APP_HOSTNAME" ]; then
    [[ "$APP_HOSTNAME" =~ ^(\*\.)?([a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]] \
      || die "hostname '$APP_HOSTNAME' is not a valid lowercase DNS name."
  fi
  for b in "strip_path_prefix:$STRIP_PREFIX" "run_as_non_root:$RUN_AS_NON_ROOT" "read_only_root_filesystem:$READ_ONLY_ROOT"; do
    [[ "${b#*:}" =~ ^(true|false)$ ]] || die "${b%%:*} must be true or false."
  done
  for q in "cpu_request:$CPU_REQUEST" "cpu_limit:$CPU_LIMIT" "memory_request:$MEMORY_REQUEST" "memory_limit:$MEMORY_LIMIT"; do
    [[ "${q#*:}" =~ ^[0-9]+(\.[0-9]+)?(m|k|Ki|M|Mi|G|Gi)?$ ]] || die "${q%%:*} '${q#*:}' is not a Kubernetes quantity (e.g. 250m, 256Mi)."
  done
  echo "$ENV_JSON" | jq -e 'type == "object" and all(keys[]; test("^[A-Za-z_][A-Za-z0-9_]*$")) and all(.[]; type != "object" and type != "array")' >/dev/null \
    || die "settings.env must be an object of NAME: value pairs (names: letters, digits, _)."
  local pg_unknown
  pg_unknown=$(echo "$SETTINGS" | jq -r '(.postgres // {}) | if type != "object" then "settings.postgres must be an object" else
      keys - ["sku_name","version","storage_mb","backup_retention_days","geo_redundant_backup","database_name"] | join(", ") end')
  [ -z "$pg_unknown" ] || die "Unknown settings.postgres keys: $pg_unknown. Allowed: sku_name, version, storage_mb, backup_retention_days, geo_redundant_backup, database_name."
  if echo "$ENV_JSON" | jq -e 'keys | map(test("(?i)(password|secret|token|key)")) | any' >/dev/null; then
    warn "settings.env looks like it contains a secret. Workflow inputs are visible in the run log - keep secrets in Key Vault (Secrets Store CSI driver) instead."
  fi

  case "$SOURCE" in
    image)
      [ -n "$IMAGE" ] || die "source 'image' needs an image (registry/repository:tag)."
      ;;
    manifest)
      [ -n "$MANIFEST" ] || die "source 'manifest' needs a manifest path."
      [[ "$MANIFEST" != /* && "$MANIFEST" != *..* ]] || die "manifest must be a path inside the repository (no absolute paths or '..')."
      [ -f "$MANIFEST" ] || die "manifest '$MANIFEST' not found."
      validate_manifest
      ;;
    *) die "source must be 'image' or 'manifest', got '$SOURCE'." ;;
  esac

  if [ -n "$IMAGE" ]; then
    [[ "$IMAGE" =~ ^[a-z0-9]([-a-z0-9.]*[a-z0-9])?(:[0-9]+)?/[a-z0-9._/-]+(:[A-Za-z0-9._-]{1,128}|@sha256:[a-f0-9]{64})$ ]] \
      || die "image '$IMAGE' must be <registry>/<repository>:<tag> or @sha256:<digest> (registry host included, e.g. myacr.azurecr.io/shop/api:1.4.2)."
    [[ "$IMAGE" != *:latest ]] || die "Use an immutable tag or digest instead of ':latest' so deployments are repeatable."
    case "${IMAGE%%/*}" in
      *.azurecr.io|mcr.microsoft.com) ;;
      *) warn "Image registry '${IMAGE%%/*}' is not Azure Container Registry or MCR. AKS egress only allows Azure service ranges, so pulls from other registries (e.g. Docker Hub) are blocked - import the image into your ACR (az acr import)." ;;
    esac
  fi
  [ "$RUN_AS_NON_ROOT" = "true" ] || warn "run_as_non_root=false: the container may run as root (allowed by the pod security baseline, but not recommended)."
}

# Light checks of a user-supplied manifest: no cluster-wide or platform objects,
# no Services exposed outside the cluster, and the named Service must exist.
validate_manifest() {
  local kinds
  kinds=$(grep -E '^kind:[[:space:]]*[A-Za-z]+' "$MANIFEST" | awk '{print $2}' | sort -u)
  [ -n "$kinds" ] || die "manifest '$MANIFEST' contains no Kubernetes objects."
  for k in $kinds; do
    for bad in $DISALLOWED_KINDS; do
      [ "$k" != "$bad" ] || die "manifest contains a '$k': cluster-wide and platform objects are managed by the platform, not by applications."
    done
  done
  if grep -Eq '^[[:space:]]*type:[[:space:]]*"?(LoadBalancer|NodePort)"?' "$MANIFEST"; then
    die "manifest exposes a Service as LoadBalancer/NodePort. Use type ClusterIP: traffic must enter through App Gateway for Containers (WAF)."
  fi
  if grep -q '\${IMAGE}' "$MANIFEST" && [ -z "$IMAGE" ]; then
    die "manifest contains \${IMAGE} but no image was given."
  fi
  if grep -Eq '^[[:space:]]*(hostNetwork|hostPID|hostIPC|privileged):[[:space:]]*true' "$MANIFEST"; then
    die "manifest requests host namespaces or privileged containers, which the pod security baseline denies."
  fi
  if command -v python3 >/dev/null && python3 -c 'import yaml' 2>/dev/null; then
    python3 - "$MANIFEST" "$SERVICE_NAME" "$SERVICE_PORT" <<'PY' || exit 1
import sys, yaml
path, name, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
docs = [d for d in yaml.safe_load_all(open(path)) if d]
svcs = [d for d in docs if d.get("kind") == "Service" and d.get("metadata", {}).get("name") == name]
if not svcs:
    sys.exit(f"::error::manifest has no Service named '{name}' (service_name must match the Service the route points at)")
ports = [p.get("port") for p in svcs[0].get("spec", {}).get("ports", [])]
if port not in ports:
    sys.exit(f"::error::Service '{name}' exposes ports {ports}, but service_port is {port} (set settings.service_port)")
PY
  else
    grep -Eq "^[[:space:]]*name:[[:space:]]*\"?${SERVICE_NAME}\"?[[:space:]]*$" "$MANIFEST" \
      || die "manifest has no object named '$SERVICE_NAME' (service_name must match its Service)."
  fi
}

# ------------------------------------------------------------------ render --
labels() { # $1 = indentation
  local i="$1"
  printf '%sapp.kubernetes.io/name: %s\n%sapp.kubernetes.io/instance: %s\n%sapp.kubernetes.io/managed-by: deploy-app\n' \
    "$i" "$SERVICE_NAME" "$i" "$SERVICE_NAME" "$i"
}

render() {
  validate
  mkdir -p "$OUT_DIR"
  rm -f "$OUT_DIR"/*.yaml

  # Namespace: labelled so its routes may attach to the platform Gateway, and
  # with the pod security baseline enforced by Kubernetes as well as Azure Policy.
  cat > "$OUT_DIR/namespace.yaml" <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${NAMESPACE}
  labels:
    agc-routes: allowed
    app.kubernetes.io/managed-by: deploy-app
    pod-security.kubernetes.io/enforce: baseline
    pod-security.kubernetes.io/warn: restricted
EOF

  if [ "$SOURCE" = "image" ]; then
    render_workload
  else
    # User manifest; ${IMAGE} is replaced when an image was given (CI pipelines).
    if [ -n "$IMAGE" ]; then
      IMAGE="$IMAGE" awk '{ gsub(/\$\{IMAGE\}/, ENVIRON["IMAGE"]); print }' "$MANIFEST" > "$OUT_DIR/workload.yaml"
    else
      cp "$MANIFEST" "$OUT_DIR/workload.yaml"
    fi
    if grep -q '\${IMAGE}' "$OUT_DIR/workload.yaml"; then
      die "manifest contains \${IMAGE} but no image was given."
    fi
  fi

  render_route
  echo "Rendered to $OUT_DIR: $(cd "$OUT_DIR" && ls *.yaml | tr '\n' ' ')"
}

render_workload() {
  local env_block="" ro_volumes="" ro_mounts=""
  if [ "$(echo "$ENV_JSON" | jq 'length')" -gt 0 ]; then
    # Values are JSON-encoded strings, which are valid YAML scalars.
    env_block="          env:
$(echo "$ENV_JSON" | jq -r 'to_entries[] | "            - name: \(.key)\n              value: \(.value | tostring | @json)"')"
  fi
  if [ "$READ_ONLY_ROOT" = "true" ]; then
    ro_mounts="          volumeMounts:
            - name: tmp
              mountPath: /tmp"
    ro_volumes="      volumes:
        - name: tmp
          emptyDir: {}"
  fi

  {
    cat <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${SERVICE_NAME}
  namespace: ${NAMESPACE}
  labels:
$(labels "    ")
automountServiceAccountToken: false
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${SERVICE_NAME}
  namespace: ${NAMESPACE}
  labels:
$(labels "    ")
spec:
  replicas: ${REPLICAS}
  revisionHistoryLimit: 5
  selector:
    matchLabels:
      app.kubernetes.io/instance: ${SERVICE_NAME}
  template:
    metadata:
      labels:
$(labels "        ")
    spec:
      serviceAccountName: ${SERVICE_NAME}
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: ${RUN_AS_NON_ROOT}
        seccompProfile:
          type: RuntimeDefault
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              app.kubernetes.io/instance: ${SERVICE_NAME}
      containers:
        - name: ${SERVICE_NAME}
          image: "${IMAGE}"
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: ${CONTAINER_PORT}
          # Connection settings of the optional PostgreSQL database (PGHOST,
          # PGDATABASE, PGUSER, PGPASSWORD, PGSSLMODE, DATABASE_URL).
          envFrom:
            - secretRef:
                name: ${SERVICE_NAME}-postgres
                optional: true
EOF
    [ -z "$env_block" ] || echo "$env_block"
    cat <<EOF
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: ${READ_ONLY_ROOT}
            capabilities:
              drop: ["ALL"]
          readinessProbe:
            httpGet:
              path: "${HEALTH_PATH}"
              port: http
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: "${HEALTH_PATH}"
              port: http
            initialDelaySeconds: 30
            periodSeconds: 20
            failureThreshold: 3
          resources:
            requests:
              cpu: ${CPU_REQUEST}
              memory: ${MEMORY_REQUEST}
            limits:
              cpu: ${CPU_LIMIT}
              memory: ${MEMORY_LIMIT}
EOF
    [ -z "$ro_mounts" ] || echo "$ro_mounts"
    [ -z "$ro_volumes" ] || echo "$ro_volumes"
    cat <<EOF
---
apiVersion: v1
kind: Service
metadata:
  name: ${SERVICE_NAME}
  namespace: ${NAMESPACE}
  labels:
$(labels "    ")
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/instance: ${SERVICE_NAME}
  ports:
    - name: http
      port: ${SERVICE_PORT}
      targetPort: http
EOF
    # maxUnavailable (not minAvailable) never blocks node drains completely.
    if [ "$REPLICAS" -ge 2 ]; then
      cat <<EOF
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: ${SERVICE_NAME}
  namespace: ${NAMESPACE}
  labels:
$(labels "    ")
spec:
  maxUnavailable: 1
  selector:
    matchLabels:
      app.kubernetes.io/instance: ${SERVICE_NAME}
EOF
    fi
  } > "$OUT_DIR/workload.yaml"
}

render_route() {
  local hostnames="" filters="" pod_selector
  [ -z "$APP_HOSTNAME" ] || hostnames="  hostnames:
    - \"${APP_HOSTNAME}\""
  if [ "$STRIP_PREFIX" = "true" ] && [ "$ROUTE_PATH" != "/" ]; then
    # /orders/api/x -> /api/x at the pod, so the app needn't know its public prefix.
    filters="      filters:
        - type: URLRewrite
          urlRewrite:
            path:
              type: ReplacePrefixMatch
              replacePrefixMatch: /"
  fi
  if [ "$SOURCE" = "image" ]; then
    pod_selector="    matchLabels:
      app.kubernetes.io/instance: ${SERVICE_NAME}"
  else
    pod_selector="    {} # manifest mode: all pods of the namespace, on the container port only"
  fi

  {
    cat <<EOF
# Published on the platform Gateway (Internet -> AGfC frontend -> WAF -> pods).
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: ${SERVICE_NAME}
  namespace: ${NAMESPACE}
  labels:
$(labels "    ")
spec:
  parentRefs:
    - name: agc-gateway
      namespace: ingress
      sectionName: http
EOF
    [ -z "$hostnames" ] || echo "$hostnames"
    cat <<EOF
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: "${ROUTE_PATH}"
EOF
    [ -z "$filters" ] || echo "$filters"
    cat <<EOF
      backendRefs:
        - name: ${SERVICE_NAME}
          port: ${SERVICE_PORT}
---
# How AGfC decides a pod can take traffic.
apiVersion: alb.networking.azure.io/v1
kind: HealthCheckPolicy
metadata:
  name: ${SERVICE_NAME}
  namespace: ${NAMESPACE}
  labels:
$(labels "    ")
spec:
  targetRef:
    group: ""
    kind: Service
    name: ${SERVICE_NAME}
    namespace: ${NAMESPACE}
  default:
    interval: 5s
    timeout: 3s
    healthyThreshold: 1
    unhealthyThreshold: 3
    http:
      path: "${HEALTH_PATH}"
      match:
        statusCodes:
          - start: 200
            end: 399
    useTLS: false
---
# Zero-trust inside the cluster: deny all ingress in the namespace, then allow
# only the application port (AGfC connects to the pod port directly).
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/managed-by: deploy-app
spec:
  podSelector: {}
  policyTypes: ["Ingress"]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-http-to-${SERVICE_NAME}
  namespace: ${NAMESPACE}
  labels:
$(labels "    ")
spec:
  podSelector:
${pod_selector}
  policyTypes: ["Ingress"]
  ingress:
    - ports:
        - protocol: TCP
          port: ${CONTAINER_PORT}
EOF
  } > "$OUT_DIR/route.yaml"
}

# ------------------------------------------------------------ Azure / AKS --
aks_name() {
  [ -n "${RESOURCE_GROUP:-}" ] || die "RESOURCE_GROUP is required."
  echo "$(echo "$RESOURCE_GROUP" | tr '[:upper:]' '[:lower:]')-aks"
}

invoke() { "$INVOKE" "$RESOURCE_GROUP" "$(aks_name)" "$@"; }

grant_acr() {
  load_inputs
  [ -n "$IMAGE" ] || { echo "No image - nothing to grant."; return 0; }
  local host="${IMAGE%%/*}"
  [[ "$host" == *.azurecr.io ]] || { echo "Image is not in Azure Container Registry - nothing to grant."; return 0; }
  local acr="${host%%.azurecr.io}" kubelet acr_id
  kubelet=$(az aks show -g "$RESOURCE_GROUP" -n "$(aks_name)" --query identityProfile.kubeletidentity.objectId -o tsv)
  if ! acr_id=$(az acr show -n "$acr" --query id -o tsv 2>/dev/null) || [ -z "$acr_id" ]; then
    warn "Can't read registry '$acr' (another subscription, or no Reader role). Make sure the cluster can pull from it: az role assignment create --assignee-object-id $kubelet --assignee-principal-type ServicePrincipal --role AcrPull --scope <registry resource ID>"
    return 0
  fi
  if [ -n "$(az role assignment list --assignee "$kubelet" --role AcrPull --scope "$acr_id" --query '[0].id' -o tsv 2>/dev/null)" ]; then
    echo "Kubelet identity already has AcrPull on $acr."
  elif az role assignment create --assignee-object-id "$kubelet" --assignee-principal-type ServicePrincipal \
         --role AcrPull --scope "$acr_id" -o none 2>/dev/null; then
    note "Granted AcrPull on $acr to the cluster's kubelet identity."
  else
    warn "Could not grant AcrPull on $acr (the deployment identity needs User Access Administrator or RBAC Administrator on the registry). Ask the registry owner to run: az role assignment create --assignee-object-id $kubelet --assignee-principal-type ServicePrincipal --role AcrPull --scope $acr_id"
  fi
  local public
  public=$(az acr show -n "$acr" --query publicNetworkAccess -o tsv 2>/dev/null || true)
  [ "$public" != "Disabled" ] || note "Registry $acr is private: it needs a private endpoint the cluster can reach (privatelink.azurecr.io zone is already linked to the AKS vNet)."
}

apply() {
  render
  local workload_cmd="kubectl apply -f workload.yaml"
  [ "$SOURCE" = "image" ] || workload_cmd="kubectl apply -n ${NAMESPACE} -f workload.yaml"
  # The pod security baseline (Azure Policy, deny) rejects non-compliant pods here.
  invoke "kubectl apply -f namespace.yaml && ${workload_cmd} && kubectl apply -f route.yaml" \
    "$OUT_DIR/namespace.yaml" "$OUT_DIR/workload.yaml" "$OUT_DIR/route.yaml"
}

wait_ready() {
  load_inputs
  local rollout
  if [ "$SOURCE" = "image" ]; then
    rollout="kubectl -n ${NAMESPACE} rollout status deploy/${SERVICE_NAME} --timeout=45s"
  else
    rollout="kubectl -n ${NAMESPACE} wait --for=condition=Available deploy --all --timeout=45s"
  fi
  echo "Waiting for the workload ..."
  AKS_INVOKE_ATTEMPTS="${AKS_INVOKE_ATTEMPTS:-12}" AKS_INVOKE_DELAY="${AKS_INVOKE_DELAY:-15}" invoke \
    "${rollout} && kubectl -n ${NAMESPACE} get deploy,svc,endpoints,pods -o wide"

  echo "Waiting for the HTTPRoute to be accepted by the gateway ..."
  AKS_INVOKE_ATTEMPTS="${AKS_INVOKE_ATTEMPTS:-12}" AKS_INVOKE_DELAY="${AKS_INVOKE_DELAY:-15}" invoke \
    "a=\$(kubectl -n ${NAMESPACE} get httproute ${SERVICE_NAME} -o jsonpath='{.status.parents[0].conditions[?(@.type==\"Accepted\")].status}'); \
     r=\$(kubectl -n ${NAMESPACE} get httproute ${SERVICE_NAME} -o jsonpath='{.status.parents[0].conditions[?(@.type==\"ResolvedRefs\")].status}'); \
     echo \"Accepted=\$a ResolvedRefs=\$r\"; [ \"\$a\" = True ] && [ \"\$r\" = True ]"
}

agc_fqdn() {
  if [ -n "${AGC_FQDN:-}" ]; then echo "$AGC_FQDN"; return; fi
  local prefix
  prefix=$(echo "$RESOURCE_GROUP" | tr '[:upper:]' '[:lower:]')
  az network alb frontend show -g "$RESOURCE_GROUP" --alb-name "${prefix}-agc" -n "${prefix}-agc-fe" --query fqdn -o tsv
}

# Public URL path of the health endpoint.
public_health_path() {
  if [ "$STRIP_PREFIX" = "true" ] && [ "$ROUTE_PATH" != "/" ]; then
    echo "${ROUTE_PATH%/}${HEALTH_PATH}"
  elif [[ "$HEALTH_PATH" == "$ROUTE_PATH"* ]] || [ "$ROUTE_PATH" = "/" ]; then
    echo "$HEALTH_PATH"
  else
    echo ""   # health endpoint is outside the public prefix
  fi
}

verify() {
  load_inputs
  local fqdn path url host_args=() code
  fqdn=$(agc_fqdn)
  path=$(public_health_path)
  [ -n "$APP_HOSTNAME" ] && host_args=(-H "Host: ${APP_HOSTNAME/\*/www}")
  if [ -n "$path" ]; then url="http://${fqdn}${path}"; else url="http://${fqdn}${ROUTE_PATH}"; fi
  [[ "$url" == *\?* ]] && sep="&" || sep="?"

  # Route programming can take a few minutes after the HTTPRoute is accepted.
  for _ in $(seq 1 "${VERIFY_ATTEMPTS:-20}"); do
    code=$(curl -s -o /dev/null -m 10 -w "%{http_code}" "${host_args[@]}" "$url" || true)
    echo "GET $url ${APP_HOSTNAME:+(Host: $APP_HOSTNAME)} -> HTTP $code"
    if { [ -n "$path" ] && [[ "$code" =~ ^[23] ]]; } || { [ -z "$path" ] && [[ "$code" =~ ^[234] ]] && [ "$code" != "404" ]; }; then
      code=$(curl -s -o /dev/null -m 10 -w "%{http_code}" "${host_args[@]}" "${url}${sep}id=1%27%20OR%20%271%27=%271" || true)
      echo "SQL-injection probe -> HTTP $code (expected 403 from the WAF)"
      [ "$code" = "403" ] || die "The WAF did not block the test attack on $url."
      echo "APP_URL=http://${APP_HOSTNAME:-$fqdn}${ROUTE_PATH}"
      return 0
    fi
    sleep "${VERIFY_DELAY:-30}"
  done
  die "$url did not answer successfully through App Gateway for Containers (see diagnostics)."
}

postgres_secret() {
  load_inputs
  : "${PG_HOST:?PG_HOST required}" "${PG_DATABASE:?PG_DATABASE required}" "${PG_USER:?PG_USER required}" "${PG_PASSWORD:?PG_PASSWORD required}"
  local dir
  dir=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf '$dir'" RETURN
  jq -n --arg ns "$NAMESPACE" --arg name "${SERVICE_NAME}-postgres" --arg app "$SERVICE_NAME" \
        --arg host "$PG_HOST" --arg db "$PG_DATABASE" --arg user "$PG_USER" --arg pw "$PG_PASSWORD" '{
    apiVersion: "v1", kind: "Secret", type: "Opaque",
    metadata: { name: $name, namespace: $ns,
                labels: { "app.kubernetes.io/instance": $app, "app.kubernetes.io/managed-by": "deploy-app" } },
    stringData: { PGHOST: $host, PGPORT: "5432", PGDATABASE: $db, PGUSER: $user, PGPASSWORD: $pw,
                  PGSSLMODE: "require",
                  DATABASE_URL: "postgresql://\($user):\($pw)@\($host):5432/\($db)?sslmode=require" }
  }' > "$dir/postgres-secret.json"
  render >/dev/null
  # Server-side apply: no last-applied-configuration annotation holding the password.
  invoke "kubectl apply -f namespace.yaml && kubectl apply --server-side --force-conflicts -f postgres-secret.json" \
    "$OUT_DIR/namespace.yaml" "$dir/postgres-secret.json"
}

delete_app() {
  load_inputs
  if [ "$NAMESPACE" = "$SERVICE_NAME" ]; then
    # Dedicated namespace: removing it removes everything the app owns.
    invoke "kubectl delete namespace ${NAMESPACE} --ignore-not-found --wait=false"
  else
    local extra=""
    if [ "$SOURCE" = "manifest" ] && [ -f "${MANIFEST:-}" ]; then
      render >/dev/null
      extra="kubectl delete -n ${NAMESPACE} -f workload.yaml --ignore-not-found; "
    fi
    invoke "${extra}kubectl -n ${NAMESPACE} delete deploy,svc,sa,pdb,httproute,healthcheckpolicy,networkpolicy,secret \
      -l ${LABELS_SELECTOR} --ignore-not-found" ${extra:+"$OUT_DIR/workload.yaml"}
  fi
}

diagnostics() {
  load_inputs
  AKS_INVOKE_ATTEMPTS=1 invoke "\
    kubectl -n ${NAMESPACE} get httproute,healthcheckpolicy,svc,endpoints,pods -o wide; \
    kubectl -n ${NAMESPACE} describe httproute ${SERVICE_NAME} | tail -n 30; \
    kubectl -n ${NAMESPACE} get events --sort-by=.lastTimestamp | tail -n 25; \
    kubectl -n ${NAMESPACE} logs -l app.kubernetes.io/instance=${SERVICE_NAME} --tail=30 --all-containers || true" || true
}

case "${1:-}" in
  validate)        validate; echo "Inputs are valid." ;;
  render)          render ;;
  grant-acr)       grant_acr ;;
  apply)           apply ;;
  wait)            wait_ready ;;
  verify)          verify ;;
  postgres-secret) postgres_secret ;;
  delete)          delete_app ;;
  diagnostics)     diagnostics ;;
  *) sed -n '2,30p' "$0"; exit 2 ;;
esac
