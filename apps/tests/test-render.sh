#!/bin/bash
# Offline tests for apps/deploy-app.sh (no Azure access): input validation and
# rendered manifests. Run from the repository root: apps/tests/test-render.sh
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
SCRIPT=apps/deploy-app.sh
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fails=0

ok()   { echo "PASS  $1"; }
bad()  { echo "FAIL  $1"; fails=$((fails + 1)); }
yaml() { python3 -c 'import sys,yaml; list(yaml.safe_load_all(open(sys.argv[1])))' "$1"; }
q()    { python3 - "$@"; }  # python assertion helper reading rendered YAML

expect_ok() { # name, env...
  local name="$1"; shift
  if env "$@" OUT_DIR="$TMP/$name" "$SCRIPT" render >"$TMP/$name.log" 2>&1; then ok "$name renders"; else bad "$name renders"; cat "$TMP/$name.log"; fi
}
expect_fail() { # name, pattern, env...
  local name="$1" pattern="$2"; shift 2
  if env "$@" OUT_DIR="$TMP/$name" "$SCRIPT" validate >"$TMP/$name.log" 2>&1; then
    bad "$name is rejected"
  elif grep -q "$pattern" "$TMP/$name.log"; then ok "$name is rejected"
  else bad "$name is rejected with '$pattern'"; cat "$TMP/$name.log"; fi
}

# ---- image mode, defaults
expect_ok image-defaults SERVICE_NAME=orders-api SOURCE=image IMAGE=myacr.azurecr.io/shop/orders:1.4.2
for f in namespace workload route; do yaml "$TMP/image-defaults/$f.yaml" && ok "image-defaults $f.yaml is YAML" || bad "image-defaults $f.yaml is YAML"; done
q "$TMP/image-defaults" <<'PY' && ok "image-defaults content" || bad "image-defaults content"
import sys, yaml, os
d = sys.argv[1]
docs = {f: [x for x in yaml.safe_load_all(open(os.path.join(d, f + ".yaml"))) if x] for f in ("namespace", "workload", "route")}
by = {(x["kind"], x["metadata"]["name"]): x for f in docs.values() for x in f}
ns = by[("Namespace", "orders-api")]
assert ns["metadata"]["labels"]["agc-routes"] == "allowed"
dep = by[("Deployment", "orders-api")]
pod = dep["spec"]["template"]["spec"]; c = pod["containers"][0]
assert dep["metadata"]["namespace"] == "orders-api" and dep["spec"]["replicas"] == 2
assert pod["automountServiceAccountToken"] is False and pod["securityContext"]["runAsNonRoot"] is True
assert c["image"] == "myacr.azurecr.io/shop/orders:1.4.2" and c["ports"][0]["containerPort"] == 8080
assert c["securityContext"]["allowPrivilegeEscalation"] is False and c["securityContext"]["capabilities"]["drop"] == ["ALL"]
assert c["envFrom"][0]["secretRef"] == {"name": "orders-api-postgres", "optional": True}
assert "env" not in c
svc = by[("Service", "orders-api")]
assert svc["spec"]["type"] == "ClusterIP" and svc["spec"]["ports"][0]["port"] == 80
assert by[("PodDisruptionBudget", "orders-api")]["spec"]["maxUnavailable"] == 1
rt = by[("HTTPRoute", "orders-api")]["spec"]
assert rt["parentRefs"][0] == {"name": "agc-gateway", "namespace": "ingress", "sectionName": "http"}
assert rt["rules"][0]["matches"][0]["path"] == {"type": "PathPrefix", "value": "/orders-api"}
assert rt["rules"][0]["filters"][0]["urlRewrite"]["path"]["replacePrefixMatch"] == "/"
assert rt["rules"][0]["backendRefs"][0] == {"name": "orders-api", "port": 80}
assert "hostnames" not in rt
hc = by[("HealthCheckPolicy", "orders-api")]["spec"]
assert hc["targetRef"] == {"group": "", "kind": "Service", "name": "orders-api", "namespace": "orders-api"} and hc["default"]["http"]["path"] == "/"
np = by[("NetworkPolicy", "allow-http-to-orders-api")]["spec"]
assert np["podSelector"]["matchLabels"]["app.kubernetes.io/instance"] == "orders-api" and np["ingress"][0]["ports"][0]["port"] == 8080
assert by[("NetworkPolicy", "default-deny-ingress")]["spec"]["podSelector"] == {}
PY

# ---- image mode, all settings
DIGEST=$(printf "a%.0s" {1..64})
expect_ok image-settings SERVICE_NAME=orders SOURCE=image "IMAGE=myacr.azurecr.io/shop/orders@sha256:$DIGEST" \
  CONTAINER_PORT=5000 ROUTE_PATH=/ SETTINGS="$(cat apps/examples/settings.example.json)"
q "$TMP/image-settings" <<'PY' && ok "image-settings content" || bad "image-settings content"
import sys, yaml, os
d = sys.argv[1]
by = {(x["kind"], x["metadata"]["name"]): x for f in ("namespace", "workload", "route") for x in yaml.safe_load_all(open(os.path.join(d, f + ".yaml"))) if x}
dep = by[("Deployment", "orders")]; pod = dep["spec"]["template"]["spec"]; c = pod["containers"][0]
assert dep["metadata"]["namespace"] == "shop" and dep["spec"]["replicas"] == 3
assert c["env"] == [{"name": "ASPNETCORE_ENVIRONMENT", "value": "Production"}, {"name": "FEATURE_X", "value": "true"}]
assert c["readinessProbe"]["httpGet"]["path"] == "/healthz"
assert c["resources"]["limits"] == {"cpu": 1, "memory": "1Gi"} or c["resources"]["limits"] == {"cpu": "1", "memory": "1Gi"}
assert c["securityContext"]["readOnlyRootFilesystem"] is True and c["volumeMounts"][0]["mountPath"] == "/tmp"
assert pod["volumes"][0]["emptyDir"] == {}
rt = by[("HTTPRoute", "orders")]["spec"]
assert rt["hostnames"] == ["orders.contoso.com"] and "filters" not in rt["rules"][0]
assert rt["rules"][0]["matches"][0]["path"]["value"] == "/"
assert by[("HealthCheckPolicy", "orders")]["spec"]["default"]["http"]["path"] == "/healthz"
PY

# ---- single replica: no PDB
expect_ok one-replica SERVICE_NAME=solo SOURCE=image IMAGE=mcr.microsoft.com/dotnet/samples:aspnetapp SETTINGS='{"replicas":1}'
grep -q PodDisruptionBudget "$TMP/one-replica/workload.yaml" && bad "one replica has no PDB" || ok "one replica has no PDB"

# ---- manifest mode
expect_ok manifest SERVICE_NAME=hello-manifest SOURCE=manifest MANIFEST=apps/examples/hello-manifest.yaml IMAGE=myacr.azurecr.io/hello:2.0
grep -q 'image: myacr.azurecr.io/hello:2.0' "$TMP/manifest/workload.yaml" && ok "manifest \${IMAGE} replaced" || bad "manifest \${IMAGE} replaced"
q "$TMP/manifest" <<'PY' && ok "manifest route content" || bad "manifest route content"
import sys, yaml, os
by = {(x["kind"], x["metadata"]["name"]): x for x in yaml.safe_load_all(open(os.path.join(sys.argv[1], "route.yaml"))) if x}
assert by[("HTTPRoute", "hello-manifest")]["spec"]["rules"][0]["backendRefs"][0] == {"name": "hello-manifest", "port": 80}
assert by[("NetworkPolicy", "allow-http-to-hello-manifest")]["spec"]["podSelector"] == {}
PY
expect_fail manifest-no-image "no image was given" SERVICE_NAME=hello-manifest SOURCE=manifest MANIFEST=apps/examples/hello-manifest.yaml
if env SERVICE_NAME=hello-manifest SOURCE=manifest MANIFEST=apps/examples/hello-manifest.yaml OUT_DIR="$TMP/mni" "$SCRIPT" render >"$TMP/mni.log" 2>&1; then bad "manifest without image fails at render"; else grep -q "no image was given" "$TMP/mni.log" && ok "manifest without image fails at render" || bad "manifest without image fails at render"; fi

# ---- rejected inputs
cat > "$TMP/lb.yaml" <<'Y'
apiVersion: v1
kind: Service
metadata:
  name: web
spec:
  type: LoadBalancer
  ports:
    - port: 80
Y
cat > "$TMP/crb.yaml" <<'Y'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: web
Y
cat > "$TMP/wrongport.yaml" <<'Y'
apiVersion: v1
kind: Service
metadata:
  name: web
spec:
  ports:
    - port: 8080
Y
expect_fail bad-name          "lowercase DNS label" SERVICE_NAME=Orders_API SOURCE=image IMAGE=myacr.azurecr.io/a:1
expect_fail reserved-ns       "reserved"            SERVICE_NAME=web SOURCE=image IMAGE=myacr.azurecr.io/a:1 SETTINGS='{"namespace":"kube-system"}'
expect_fail ingress-ns        "reserved"            SERVICE_NAME=web SOURCE=image IMAGE=myacr.azurecr.io/a:1 SETTINGS='{"namespace":"ingress"}'
expect_fail latest-tag        "latest"              SERVICE_NAME=web SOURCE=image IMAGE=myacr.azurecr.io/a:latest
expect_fail no-tag            "registry"            SERVICE_NAME=web SOURCE=image IMAGE=nginx
expect_fail bad-port          "port number"         SERVICE_NAME=web SOURCE=image IMAGE=myacr.azurecr.io/a:1 CONTAINER_PORT=70000
expect_fail bad-path          "route_path"          SERVICE_NAME=web SOURCE=image IMAGE=myacr.azurecr.io/a:1 ROUTE_PATH='/a/../b'
expect_fail typo-setting      "Unknown settings"    SERVICE_NAME=web SOURCE=image IMAGE=myacr.azurecr.io/a:1 SETTINGS='{"replica":3}'
expect_fail bad-json          "JSON object"         SERVICE_NAME=web SOURCE=image IMAGE=myacr.azurecr.io/a:1 SETTINGS='[1]'
expect_fail bad-quantity      "quantity"            SERVICE_NAME=web SOURCE=image IMAGE=myacr.azurecr.io/a:1 SETTINGS='{"memory_limit":"lots"}'
expect_fail bad-env           "settings.env"        SERVICE_NAME=web SOURCE=image IMAGE=myacr.azurecr.io/a:1 SETTINGS='{"env":{"bad-name":"x"}}'
expect_fail pg-typo           "settings.postgres"   SERVICE_NAME=web SOURCE=image IMAGE=myacr.azurecr.io/a:1 SETTINGS='{"postgres":{"sku":"x"}}'
expect_fail bad-host          "hostname"            SERVICE_NAME=web SOURCE=image IMAGE=myacr.azurecr.io/a:1 SETTINGS='{"hostname":"not a host"}'
expect_fail manifest-outside  "inside the repository" SERVICE_NAME=web SOURCE=manifest MANIFEST="$TMP/lb.yaml"
expect_fail manifest-missing  "not found"           SERVICE_NAME=web SOURCE=manifest MANIFEST=apps/examples/nope.yaml
expect_fail manifest-svc-name "no Service named"    SERVICE_NAME=other SOURCE=manifest MANIFEST=apps/examples/hello-manifest.yaml IMAGE=myacr.azurecr.io/a:1

# Manifests outside the repo are refused; copy the bad ones into a temp dir in the repo.
mkdir -p apps/tests/.tmp && trap 'rm -rf "$TMP" apps/tests/.tmp' EXIT
cp "$TMP/lb.yaml" "$TMP/crb.yaml" "$TMP/wrongport.yaml" apps/tests/.tmp/
expect_fail manifest-lb2      "LoadBalancer"        SERVICE_NAME=web SOURCE=manifest MANIFEST=apps/tests/.tmp/lb.yaml
expect_fail manifest-crb      "ClusterRoleBinding"  SERVICE_NAME=web SOURCE=manifest MANIFEST=apps/tests/.tmp/crb.yaml
expect_fail manifest-port     "service_port"        SERVICE_NAME=web SOURCE=manifest MANIFEST=apps/tests/.tmp/wrongport.yaml

echo
if [ "$fails" -eq 0 ]; then echo "All render tests passed."; else echo "$fails test(s) failed."; exit 1; fi
