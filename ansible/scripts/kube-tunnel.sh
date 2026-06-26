#!/usr/bin/env bash
# SSH tunnel from this control node to the K3s API on the master.
# Run in a dedicated terminal and LEAVE IT OPEN; use kubectl in another terminal.
# Auto-detects a dropped connection and exits cleanly so you know to restart.
set -euo pipefail

INVENTORY="$(dirname "$0")/../inventory/hosts.ini"
MASTER_IP="$(awk '/^k3s-master/{print $2}' "$INVENTORY" | cut -d= -f2)"
KEY="$HOME/.ssh/gaire-platform-admin"

if [[ -z "$MASTER_IP" ]]; then
  echo "ERROR: couldn't read master IP from $INVENTORY — is the cluster built?" >&2
  exit 1
fi

echo "Tunnel: localhost:6443 -> ${MASTER_IP} (k3s API). Ctrl-C to close."
echo "If this exits on its own, the connection dropped — just re-run it."

ssh -i "$KEY" -N \
  -o StrictHostKeyChecking=accept-new \
  -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=15 \
  -o ServerAliveCountMax=3 \
  -L 6443:127.0.0.1:6443 \
  "azureuser@${MASTER_IP}"

# Only reached when ssh exits (dropped or Ctrl-C)
echo ""
echo ">>> TUNNEL CLOSED. kubectl will fail until you re-run this script. <<<"
