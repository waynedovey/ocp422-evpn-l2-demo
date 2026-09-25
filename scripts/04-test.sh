#!/usr/bin/env bash
# Non-destructive acceptance checks for the demonstrated two-site EVPN lab.
# Full mode creates temporary oc debug pods; strict mode checks remote MAC advertisements.
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_contexts.sh"
load_site_contexts
: "${SITE_A_CONTEXT:?Run scripts/00-login.sh or export SITE_A_CONTEXT}"
: "${SITE_B_CONTEXT:?Run scripts/00-login.sh or export SITE_B_CONTEXT}"
command -v jq >/dev/null || { echo 'Missing jq' >&2; exit 1; }
MODE="${1:---basic}"
case "$MODE" in --basic|--full|--strict) ;; *) echo "Usage: $0 [--basic|--full|--strict]" >&2; exit 2 ;; esac
failed=0
check_bgp() {
  local summary="$1" peer="$2"
  printf '%s\n' "$summary" | awk -v peer="$peer" '$1==peer && $10 ~ /^[0-9]+$/ && $4+0>0 && $5+0>0 {ok=1} END{exit !ok}'
}
get_node_frr_pod() {
  local ctx="$1" node="$2"
  oc --context="$ctx" -n openshift-frr-k8s get pods -o json |
    jq -r --arg node "$node" '.items[] | select(.spec.nodeName==$node) | select(any(.spec.containers[]?; .name=="frr")) | .metadata.name' | head -1
}
check_site() {
  local name="$1" ctx="$2" node="$3" vm="$4" expected_vtep="$5" expected_remote_mac="$6"
  local vtep_ok cudn_ok ra_ok vmi_json pod summary vni routes ip mac
  echo
  echo "===== $name: accepted resources and live VM ====="
  oc --context="$ctx" get vtep sydney-vtep
  oc --context="$ctx" get routeadvertisements sydney-l2-evpn
  oc --context="$ctx" get clusteruserdefinednetwork sydney-l2-evpn
  oc --context="$ctx" -n evpn-demo get vmi "$vm" -o wide
  vtep_ok="$(oc --context="$ctx" get vtep sydney-vtep -o json | jq -r '[.status.conditions[]? | select(.type=="Accepted" and .status=="True")] | length')"
  cudn_ok="$(oc --context="$ctx" get clusteruserdefinednetwork sydney-l2-evpn -o json | jq -r '[.status.conditions[]? | select((.type=="TransportAccepted" or .type=="NetworkCreated" or .type=="NetworkAllocationSucceeded") and .status=="True")] | length')"
  ra_ok="$(oc --context="$ctx" get routeadvertisements sydney-l2-evpn -o json | jq -r '[.status.conditions[]? | select(.type=="Accepted" and .status=="True")] | length')"
  [[ "$vtep_ok" -ge 1 && "$cudn_ok" -eq 3 && "$ra_ok" -ge 1 ]] || { echo "FAIL: resource conditions vtep=$vtep_ok cudn=$cudn_ok ra=$ra_ok" >&2; failed=1; }
  vmi_json="$(oc --context="$ctx" -n evpn-demo get vmi "$vm" -o json)"
  ip="$(printf '%s' "$vmi_json" | jq -r '.status.interfaces[0].ipAddress // ""')"
  mac="$(printf '%s' "$vmi_json" | jq -r '.status.interfaces[0].mac // ""')"
  [[ -n "$ip" && "$ip" != null ]] || { echo "FAIL: $vm has no reported IP" >&2; failed=1; }
  echo "Observed guest: $vm IP=$ip MAC=$mac (do not assume DHCP will always assign the same IP on a fresh install)"
  pod="$(get_node_frr_pod "$ctx" "$node")"
  [[ -n "$pod" ]] || { echo "FAIL: FRR pod missing on $node" >&2; failed=1; return 0; }
  echo "===== $name: node FRR $pod ====="
  summary="$(oc --context="$ctx" -n openshift-frr-k8s exec "$pod" -c frr -- vtysh -c 'show bgp l2vpn evpn summary')"
  printf '%s\n' "$summary"
  if check_bgp "$summary" '10.10.10.1'; then echo "PASS: $name local EVPN eBGP established"; else echo "FAIL: $name EVPN eBGP not established" >&2; failed=1; fi
  vni="$(oc --context="$ctx" -n openshift-frr-k8s exec "$pod" -c frr -- vtysh -c 'show evpn vni')"
  printf '%s\n' "$vni"
  echo "$vni" | grep -qE '^5050[[:space:]]+L2' || { echo "FAIL: VNI 5050 missing on $node" >&2; failed=1; }
  routes="$(oc --context="$ctx" -n openshift-frr-k8s exec "$pod" -c frr -- vtysh -c 'show bgp l2vpn evpn')"
  if grep -Fqi "$expected_remote_mac" <<< "$routes"; then
    echo "PASS: $name has remote VM MAC $expected_remote_mac"
  else
    echo "PENDING: $name has not yet displayed remote VM MAC $expected_remote_mac. Generate traffic between the guests and rerun --strict."
    if [[ "$MODE" == --strict ]]; then failed=1; fi
  fi
  # Warn about stale local VTEP allocation without requiring debug pods.
  expected_annotation="$(oc --context="$ctx" get node "$node" -o json | jq -r '.metadata.annotations["k8s.ovn.org/vteps"] | fromjson | .["sydney-vtep"].ips[0] // ""')"
  [[ "$expected_annotation" == "$expected_vtep" ]] || { echo "FAIL: $node VTEP=$expected_annotation (wanted $expected_vtep)" >&2; failed=1; }
}
check_site 'SITE A' "$SITE_A_CONTEXT" worker-cluster-kcp74-2 vm-site-a 10.251.10.15 0a:58:0a:fa:32:04
check_site 'SITE B' "$SITE_B_CONTEXT" worker-cluster-9r9gz-1 vm-site-b 10.251.20.24 0a:58:0a:fa:32:03
if [[ "$MODE" != --basic ]]; then
  echo
  echo '===== Active cross-site underlay probes ====='
  if oc --context="$SITE_A_CONTEXT" debug node/worker-cluster-kcp74-2 -- chroot /host ping -I 10.251.10.15 -c 3 -W 2 10.251.20.24; then
    echo 'PASS: A -> B VTEP'
  else echo 'FAIL: A -> B VTEP' >&2; failed=1; fi
  if oc --context="$SITE_B_CONTEXT" debug node/worker-cluster-9r9gz-1 -- chroot /host ping -I 10.251.20.24 -c 3 -W 2 10.251.10.15; then
    echo 'PASS: B -> A VTEP'
  else echo 'FAIL: B -> A VTEP' >&2; failed=1; fi
fi
printf '\n===== GUEST-LEVEL ACCEPTANCE (observed working workshop IPs) =====\n'
echo "virtctl --context=\"$SITE_A_CONTEXT\" -n evpn-demo console vm-site-a"
echo 'Inside vm-site-a: ping -c 4 10.250.50.4 && ip neigh'
echo 'Expected neighbor: 10.250.50.4 lladdr 0a:58:0a:fa:32:04 REACHABLE'
echo 'If VMs were recreated, first query their current IPs; DHCP .3/.4 is not guaranteed.'
if [[ $failed -ne 0 ]]; then echo 'Some checks failed or are pending' >&2; exit 1; fi
echo 'PASS: all selected automated checks passed. Guest ICMP is a separate manual acceptance test.'
