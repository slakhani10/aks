#!/bin/bash
# Runs a shell command inside the PRIVATE AKS cluster through the ARM control plane
# (`az aks command invoke`), so no network line of sight to the API server is needed.
#
# Usage: aks-invoke.sh <resource-group> <cluster> <command> [file ...]
#   Files are uploaded next to the command (reference them by base name).
# Retries while a fresh Azure RBAC assignment propagates; prints the in-cluster
# output and exits with the in-cluster command's exit code.
set -euo pipefail

RG="$1"; CLUSTER="$2"; COMMAND="$3"; shift 3
FILE_ARGS=()
for f in "$@"; do FILE_ARGS+=(--file "$f"); done

ATTEMPTS="${AKS_INVOKE_ATTEMPTS:-6}"
for attempt in $(seq 1 "$ATTEMPTS"); do
  if result=$(az aks command invoke -g "$RG" -n "$CLUSTER" --command "$COMMAND" "${FILE_ARGS[@]}" -o json); then
    echo "$result" | jq -r '.logs'
    code=$(echo "$result" | jq -r '.exitCode')
    if [ "$code" = "0" ]; then
      exit 0
    fi
    echo "In-cluster command exited with $code (attempt $attempt/$ATTEMPTS)"
  else
    echo "az aks command invoke failed (attempt $attempt/$ATTEMPTS)"
  fi
  [ "$attempt" -lt "$ATTEMPTS" ] && sleep 30
done
exit 1
