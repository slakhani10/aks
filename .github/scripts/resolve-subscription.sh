#!/bin/bash
# Resolves an Azure subscription NAME or ID to its ID (prints the ID).
# The signed-in identity (GitHub OIDC service principal) must have access to it.
# Usage: resolve-subscription.sh "<subscription name or id>"
set -euo pipefail

SUBSCRIPTION="${1:-}"
if [ -z "$SUBSCRIPTION" ]; then
  echo "::error::No subscription given" >&2
  exit 1
fi

if ! ID=$(az account show --subscription "$SUBSCRIPTION" --query id -o tsv 2>/dev/null) || [ -z "$ID" ]; then
  # `az account show` only knows subscriptions loaded at login; refresh once.
  az account list --refresh -o none 2>/dev/null || true
  ID=$(az account show --subscription "$SUBSCRIPTION" --query id -o tsv 2>/dev/null || true)
fi

if [ -z "$ID" ]; then
  echo "::error::Subscription '$SUBSCRIPTION' was not found, or the workflow identity has no role in it. Grant the service principal access (see README → Central private DNS zones)." >&2
  exit 1
fi
echo "$ID"
