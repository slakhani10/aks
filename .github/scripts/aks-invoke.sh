#!/bin/bash
# Runs a shell command inside the PRIVATE AKS cluster through the ARM control plane
# (`az aks command invoke`), so no network line of sight to the API server is needed.
#
# Usage: aks-invoke.sh <resource-group> <cluster> <command> [file ...]
#   Files are uploaded next to the command (reference them by base name).
#
# Keep each command SHORT (about a minute). command invoke runs it in a small,
# short-lived pod and is not meant for long blocking operations; long waits come back
# without an exit code. To wait for something, pass a short check and let this
# script poll it:
#   AKS_INVOKE_ATTEMPTS  number of tries          (default 6)
#   AKS_INVOKE_DELAY     seconds between tries     (default 30)
# Retrying also covers a fresh Azure RBAC assignment that is still propagating.
# Exits 0 on the first successful run, otherwise 1.
set -euo pipefail

RG="$1"; CLUSTER="$2"; COMMAND="$3"; shift 3
FILE_ARGS=()
for f in "$@"; do FILE_ARGS+=(--file "$f"); done

ATTEMPTS="${AKS_INVOKE_ATTEMPTS:-6}"
DELAY="${AKS_INVOKE_DELAY:-30}"

ERR_FILE=$(mktemp)
trap 'rm -f "$ERR_FILE"' EXIT

for attempt in $(seq 1 "$ATTEMPTS"); do
  # stdout = JSON result; stderr (CLI warnings/errors) kept apart so jq can parse.
  if result=$(az aks command invoke -g "$RG" -n "$CLUSTER" --command "$COMMAND" "${FILE_ARGS[@]}" -o json 2>"$ERR_FILE"); then
    field() { echo "$result" | jq -r "$1" 2>/dev/null || echo "$2"; }
    field '.logs // empty' ""
    code=$(field '.exitCode // "none"' none)
    if [ "$code" = "0" ]; then
      exit 0
    fi
    # No exit code means the run itself did not complete (e.g. timed out or the
    # command pod could not start): show Azure's explanation.
    echo "Attempt $attempt/$ATTEMPTS: exit code $code, state $(field '.provisioningState // "unknown"' unknown), reason: $(field '.reason // "none"' none)"
  else
    echo "Attempt $attempt/$ATTEMPTS: az aks command invoke failed:"
    tail -n 5 "$ERR_FILE"
  fi
  if [ "$attempt" -lt "$ATTEMPTS" ]; then sleep "$DELAY"; fi
done
exit 1
