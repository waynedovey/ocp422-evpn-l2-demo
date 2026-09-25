#!/usr/bin/env bash
set -euo pipefail

# Read saved login contexts if they have not been exported manually.
source "$(dirname -- "${BASH_SOURCE[0]}")/_contexts.sh"
load_site_contexts
: "${SITE_A_CONTEXT:?Run ./scripts/00-login.sh or export SITE_A_CONTEXT}"
: "${SITE_B_CONTEXT:?Run ./scripts/00-login.sh or export SITE_B_CONTEXT}"

check_cluster() {
  local ctx="$1"
  local name="$2"
  echo
  echo "===== $name ($ctx) ====="
  echo -n "Version: "
  oc --context="$ctx" get clusterversion version -o jsonpath='{.status.desired.version}{"\n"}'
  echo -n "Platform: "
  oc --context="$ctx" get infrastructure cluster -o jsonpath='{.status.platformStatus.type}{"\n"}'
  echo -n "Network type: "
  oc --context="$ctx" get network.operator cluster -o jsonpath='{.spec.defaultNetwork.type}{"\n"}'
  echo -n "FRR provider: "
  oc --context="$ctx" get network.operator cluster -o jsonpath='{.spec.additionalRoutingCapabilities.providers}{"\n"}' || true
  echo -n "Route advertisements: "
  oc --context="$ctx" get network.operator cluster -o jsonpath='{.spec.defaultNetwork.ovnKubernetesConfig.routeAdvertisements}{"\n"}' || true
  echo -n "routingViaHost: "
  oc --context="$ctx" get network.operator cluster -o jsonpath='{.spec.defaultNetwork.ovnKubernetesConfig.gatewayConfig.routingViaHost}{"\n"}' || true
  echo -n "ipForwarding: "
  oc --context="$ctx" get network.operator cluster -o jsonpath='{.spec.defaultNetwork.ovnKubernetesConfig.gatewayConfig.ipForwarding}{"\n"}' || true

  for crd in clusteruserdefinednetworks.k8s.ovn.org vteps.k8s.ovn.org routeadvertisements.k8s.ovn.org frrconfigurations.frrk8s.metallb.io virtualmachines.kubevirt.io; do
    if oc --context="$ctx" get crd "$crd" >/dev/null 2>&1; then
      echo "OK CRD: $crd"
    else
      echo "MISSING CRD: $crd"
    fi
  done
}

check_cluster "$SITE_A_CONTEXT" "site-a-sydney-cluster-kcp74"
check_cluster "$SITE_B_CONTEXT" "site-b-sydney-cluster-9r9gz"
