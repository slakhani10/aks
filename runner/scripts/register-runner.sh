#!/bin/bash
# Registers the GitHub Actions runner staged by cloud-init and installs it as a
# systemd service. Executed ON THE VM by the deploy-runner workflow through
# `az vm run-command invoke`, so the short-lived registration token never enters
# Terraform state, the VM model or the plan artifact.
#
# Arguments: <repo_url> <registration_token> <runner_name> <labels>
# Idempotent: exits successfully if the runner is already configured.
set -euo pipefail

REPO_URL="$1"
TOKEN="$2"
RUNNER_NAME="$3"
LABELS="$4"
RUNNER_DIR="${RUNNER_DIR:-/opt/actions-runner}"

# cloud-init installs the Azure CLI and stages the runner on first boot.
cloud-init status --wait >/dev/null || true
if [ ! -x "$RUNNER_DIR/config.sh" ]; then
  echo "ERROR: $RUNNER_DIR/config.sh not found - cloud-init did not finish. See /var/log/cloud-init-output.log" >&2
  exit 1
fi

cd "$RUNNER_DIR"

if [ -f .runner ]; then
  echo "Runner already registered as $(jq -r .agentName .runner 2>/dev/null || echo unknown); ensuring the service is running."
else
  sudo -u runner ./config.sh --unattended \
    --url "$REPO_URL" \
    --token "$TOKEN" \
    --name "$RUNNER_NAME" \
    --labels "$LABELS" \
    --work _work \
    --replace
  ./svc.sh install runner
fi

./svc.sh start || true
./svc.sh status | head -n 20

# The workflow looks for this marker: run-command reports success even when the
# script fails, so its absence is treated as a failed registration.
SERVICE_NAME=$(cat .service) # written by svc.sh install
if systemctl is-active --quiet "$SERVICE_NAME"; then
  echo "RUNNER_READY"
else
  echo "ERROR: service $SERVICE_NAME is not active" >&2
  exit 1
fi
