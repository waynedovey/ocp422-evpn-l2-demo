#!/usr/bin/env bash
set -euo pipefail
# Accept a site name (loads contexts saved by 00-login.sh), or an explicit
# oc context for backwards compatibility.
source "$(dirname -- "${BASH_SOURCE[0]}")/_contexts.sh"
load_site_contexts
case "${1:-}" in
  site-a) CTX="${SITE_A_CONTEXT:?Run ./scripts/00-login.sh or export SITE_A_CONTEXT}" ;;
  site-b) CTX="${SITE_B_CONTEXT:?Run ./scripts/00-login.sh or export SITE_B_CONTEXT}" ;;
  '') echo "Usage: $0 <site-a|site-b|oc-context>" >&2; exit 2 ;;
  *) CTX="$1" ;;
esac

echo "Backing up Network.operator for $CTX"
oc --context="$CTX" get network.operator cluster -o yaml > "network-operator-backup-${CTX//\//_}.yaml"

echo "Enabling FRR, route advertisements, routingViaHost and global IP forwarding"
oc --context="$CTX" patch network.operator.openshift.io cluster --type=merge -p='{
  "spec": {
    "additionalRoutingCapabilities": {"providers": ["FRR"]},
    "defaultNetwork": {
      "ovnKubernetesConfig": {
        "routeAdvertisements": "Enabled",
        "gatewayConfig": {
          "routingViaHost": true,
          "ipForwarding": "Global"
        }
      }
    }
  }
}'

echo "Current network operator state:"
oc --context="$CTX" get co network
