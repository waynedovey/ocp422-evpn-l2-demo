#!/usr/bin/env bash
# Two-site OCP 4.22 EVPN lab completion helper (validated v4 fabric and switch).
# Workshop-specific lab helper. Not production hardened; requires active SSH tun7.
set -Eeuo pipefail

# Load saved contexts from this repo before using the proven defaults.
source "$(dirname -- "${BASH_SOURCE[0]}")/_contexts.sh"
load_site_contexts
STAGE="${1:-plan}"
A_CTX="${SITE_A_CONTEXT:-default/api-cluster-kcp74-dyn-redhatworkshops-io:6443/admin}"
B_CTX="${SITE_B_CONTEXT:-default/api-cluster-9r9gz-dyn-redhatworkshops-io:6443/admin}"
A_HOST=ssh.ocpv02.rhdp.net; A_PORT=31482
B_HOST=ssh.ocpv08.rhdp.net; B_PORT=31156
A_FRC=sydney-evpn-site-a; B_FRC=sydney-evpn-site-b
VTEP=sydney-vtep; VTEP_IF=evpn-vtep0
STAMP="$(date +%Y%m%d-%H%M%S)"

log() { printf '\n== %s ==\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
remote_a() { ssh -n -o BatchMode=yes -p "$A_PORT" "lab-user@$A_HOST" "$@"; }
remote_b() { ssh -n -o BatchMode=yes -p "$B_PORT" "lab-user@$B_HOST" "$@"; }
oc_a() { oc --context="$A_CTX" "$@"; }
oc_b() { oc --context="$B_CTX" "$@"; }

preflight() {
  for cmd in oc jq ssh scp; do command -v "$cmd" >/dev/null || fail "Missing command: $cmd"; done
  log 'Verify cluster contexts'
  oc_a whoami --show-server | grep -F cluster-kcp74 || fail 'Site A context mismatch'
  oc_b whoami --show-server | grep -F cluster-9r9gz || fail 'Site B context mismatch'
  log 'Verify bastion tunnel'
  remote_a 'test "$(cat /sys/class/net/tun7/operstate)" = unknown || test "$(cat /sys/class/net/tun7/operstate)" = up; ping -I tun7 -c 2 -W 2 10.254.254.2 >/dev/null' || fail 'Restore the A-to-B SSH tunnel first'
  remote_b 'ping -I tun7 -c 2 -W 2 10.254.254.1 >/dev/null' || fail 'B-to-A SSH tunnel ping failed'
  log 'Both tunnel directions respond'
}

# TSV: node name, 10.10.10.X underlay IP, old/current VTEP IP.
node_records() {
  local context="$1"
  oc --context="$context" get nodes -o json | jq -r --arg v "$VTEP" '
    .items[] as $n |
    ($n.metadata.annotations["k8s.ovn.org/vteps"] // "{}" | fromjson | .[$v].ips[0] // "") as $vtep |
    (([$n.status.addresses[]? | select(.type=="InternalIP") | .address] +
      [($n.metadata.annotations["k8s.ovn.org/host-cidrs"] // "[]" | fromjson[] | split("/")[0])]) |
     map(select(startswith("10.10.10."))) | unique | .[0] // "") as $ip |
    [$n.metadata.name,$ip,$vtep] | @tsv'
}

nncp_records() {
  local context="$1"
  oc --context="$context" get nncp -o json | jq -r --arg iface "$VTEP_IF" '
    .items[] as $p |
    $p.spec.desiredState.interfaces | to_entries[] |
    select(.value.name==$iface) |
    [$p.metadata.name,(.key|tostring),(.value.ipv4.address[0].ip // "")] | @tsv'
}

check_inventory() {
  local ctx="$1" site="$2" rows nodes policies
  rows="$(node_records "$ctx")"
  nodes="$(oc --context="$ctx" get nodes -o json | jq '.items|length')"
  [[ -n "$rows" ]] || fail "$site node inventory empty"
  [[ "$(printf '%s\n' "$rows" | wc -l | tr -d ' ')" -eq "$nodes" ]] || fail "$site incomplete node records"
  while IFS=$'\t' read -r node ip vtep; do
    [[ "$ip" =~ ^10\.10\.10\.[0-9]+$ ]] || fail "$site: cannot find 10.10.10.X for $node (host-cidrs/InternalIP)"
    [[ "$vtep" =~ ^(172\.31\.250|10\.251\.(10|20))\.[0-9]+$ ]] || fail "$site: unexpected VTEP for $node: $vtep"
  done <<< "$rows"
  policies="$(nncp_records "$ctx")"
  [[ -n "$policies" ]] || fail "$site: no NNCP with interface $VTEP_IF; inspect the real NNCP names before switch"
  [[ "$(printf '%s\n' "$policies" | wc -l | tr -d ' ')" -eq "$nodes" ]] || fail "$site: NNCP count differs from node count"
}

plan() {
  preflight
  for site in A B; do
    if [[ "$site" == A ]]; then ctx="$A_CTX"; else ctx="$B_CTX"; fi
    check_inventory "$ctx" "$site"
    log "Site $site node/VTEP mapping"
    node_records "$ctx" | column -t -s $'\t'
    log "Site $site VTEP NNCP mappings"
    nncp_records "$ctx" | column -t -s $'\t'
    log "Site $site existing FRR neighbor and VTEP CR"
    oc --context="$ctx" -n openshift-frr-k8s get frrconfiguration "sydney-evpn-site-$(tr '[:upper:]' '[:lower:]' <<< "$site")" -o json | jq '.spec.bgp.routers'
    oc --context="$ctx" get vtep "$VTEP" -o json | jq '{spec:.spec,status:.status.conditions}'
  done
  log 'Plan passed. The fabric stage backs up and configures bastion FRR. The switch stage readdresses NNCPs and updates OpenShift BGP peers.'
}

write_frr() {
  local site="$1" file="$2" router peer local_as peer_as router_id
  if [[ "$site" == A ]]; then
    router_id=10.254.254.1; peer=10.254.254.2; local_as=65001
  else
    router_id=10.254.254.2; peer=10.254.254.1; local_as=65002
  fi
  cat > "$file" <<EOF
frr version 8.5
frr defaults traditional
hostname evpn-bastion-$site
log syslog informational
service integrated-vtysh-config
!
router bgp 65000
 bgp router-id $router_id
 no bgp default ipv4-unicast
 no bgp ebgp-requires-policy
 bgp listen limit 32
 neighbor OCP peer-group
 neighbor OCP remote-as $local_as
 bgp listen range 10.10.10.0/24 peer-group OCP
 neighbor $peer remote-as 65000
 neighbor $peer update-source $router_id
 neighbor OCP attribute-unchanged next-hop
 neighbor OCP send-community both
 neighbor $peer send-community both
 !
 address-family l2vpn evpn
  neighbor OCP activate
  neighbor $peer activate
 exit-address-family
!
line vty
!
EOF
}

# Read-only FRR parser validation (uploads candidate configs to /tmp; no daemon changes).
# FRR 8.5's vtysh parser may silently return to BGP_NODE if an AF command
# is recognized only at BGP scope. Keep send-community and attribute-unchanged
# at BGP scope; enter EVPN AF only for 'neighbor ... activate'.
# Do not apply until dry-run parses on both actual bastions.
check_frr_configs() {
  local workdir="$1" site host port remote_file candidate
  for site in A B; do
    if [[ "$site" == A ]]; then host="$A_HOST"; port="$A_PORT"; candidate="$workdir/a.conf"
    else host="$B_HOST"; port="$B_PORT"; candidate="$workdir/b.conf"; fi
    remote_file="/tmp/evpn-frr-$site.conf"
    log "Site $site: dry-run candidate FRR config on actual RHEL 9 bastion"
    scp -q -o BatchMode=yes -P "$port" "$candidate" "lab-user@$host:$remote_file"
    if ! ssh -n -o BatchMode=yes -p "$port" "lab-user@$host"       "sudo -n vtysh -C -f '$remote_file'"; then
      echo "FRR dry-run failed on site $site. Checking bgpd daemon parser independently:" >&2
      ssh -n -o BatchMode=yes -p "$port" "lab-user@$host" \
        "if test -x /usr/lib/frr/bgpd; then sudo -n /usr/lib/frr/bgpd -C -f '$remote_file'; fi" >&2 || true
      echo "Configuration failed FRR validation. Check the first unsupported command and the parent CLI mode." >&2
      echo "Generated config and line numbers:" >&2
      ssh -n -o BatchMode=yes -p "$port" "lab-user@$host" "nl -ba '$remote_file' | tail -35" >&2 || true
      fail "No FRR daemon was modified. Do NOT run fabric or switch until the config parses."
    fi
  done
  log 'Both FRR configurations passed vtysh dry-run on their respective bastions'
}

frr_check() {
  preflight
  local workdir
  workdir="$(mktemp -d)"; trap 'rm -rf "${workdir:-}"' EXIT
  write_frr A "$workdir/a.conf"; write_frr B "$workdir/b.conf"
  check_frr_configs "$workdir"
}

install_frr() {
  local site="$1" host="$2" port="$3" file="$4"
  log "Site $site: copy and syntax-check FRR config"
  scp -q -o BatchMode=yes -P "$port" "$file" "lab-user@$host:/tmp/evpn-frr-$site.conf"
  ssh -n -o BatchMode=yes -p "$port" "lab-user@$host" "
    set -e
    sudo -n vtysh -C -f /tmp/evpn-frr-$site.conf
    sudo -n cp -a /etc/frr/daemons /etc/frr/daemons.pre-evpn-$STAMP
    if test -e /etc/frr/frr.conf; then sudo -n cp -a /etc/frr/frr.conf /etc/frr/frr.conf.pre-evpn-$STAMP; fi
    sudo -n sed -i 's/^bgpd=no$/bgpd=yes/' /etc/frr/daemons
    sudo -n install -m 640 -o frr -g frr /tmp/evpn-frr-$site.conf /etc/frr/frr.conf
    sudo -n systemctl enable --now frr
    sudo -n systemctl restart frr
    sudo -n vtysh -c 'show bgp l2vpn evpn summary'
  "
}

# Add only the dedicated VTEP subnets to the existing drop-by-default FORWARD chain.
nft_rules() {
  local site="$1" p1 p2 r1 r2
  if [[ "$site" == A ]]; then p1=10.251.10.0/24; p2=10.251.20.0/24
  else p1=10.251.20.0/24; p2=10.251.10.0/24
  fi
  local server=$A_HOST port=$A_PORT
  if [[ "$site" == B ]]; then server=$B_HOST; port=$B_PORT; fi
  ssh -n -o BatchMode=yes -p "$port" "lab-user@$server" "
    set -e
    sudo -n nft list chain inet filter forward >/dev/null
    sudo -n nft list chain inet filter forward | grep -Fq 'ip saddr $p1 ip daddr $p2' ||
      sudo -n nft insert rule inet filter forward iifname eth1 oifname tun7 ip saddr $p1 ip daddr $p2 counter accept
    sudo -n nft list chain inet filter forward | grep -Fq 'ip saddr $p2 ip daddr $p1' ||
      sudo -n nft insert rule inet filter forward iifname tun7 oifname eth1 ip saddr $p2 ip daddr $p1 counter accept
  "
}

fabric() {
  preflight
  check_inventory "$A_CTX" A
  check_inventory "$B_CTX" B
  local workdir
  workdir="$(mktemp -d)"; trap 'rm -rf "${workdir:-}"' EXIT
  write_frr A "$workdir/a.conf"; write_frr B "$workdir/b.conf"
  check_frr_configs "$workdir"
  log 'Set lab TUN MTU to carry VXLAN outer packets for 1300-byte VM MTU'
  remote_a 'sudo -n ip link set tun7 mtu 1500 up; sudo -n ip route replace 10.251.20.0/24 via 10.254.254.2 dev tun7'
  remote_b 'sudo -n ip link set tun7 mtu 1500 up; sudo -n ip route replace 10.251.10.0/24 via 10.254.254.1 dev tun7'
  log 'Install per-node local VTEP /32 routes on bastions'
  while IFS=$'\t' read -r node ip old; do
    [[ "$old" =~ ^(172\.31\.250|10\.251\.10)\.([0-9]+)$ ]] || fail "Unexpected Site A VTEP: $old"
    last="${old##*.}"; remote_a "sudo -n ip route replace 10.251.10.$last/32 via $ip dev eth1"
  done < <(node_records "$A_CTX")
  while IFS=$'\t' read -r node ip old; do
    [[ "$old" =~ ^(172\.31\.250|10\.251\.20)\.([0-9]+)$ ]] || fail "Unexpected Site B VTEP: $old"
    last="${old##*.}"; remote_b "sudo -n ip route replace 10.251.20.$last/32 via $ip dev eth1"
  done < <(node_records "$B_CTX")
  log 'Allow only the two VTEP subnets through existing nftables FORWARD chains'
  nft_rules A; nft_rules B
  log 'Back up existing FRR configurations and start BGP daemons'
  install_frr A "$A_HOST" "$A_PORT" "$workdir/a.conf"
  install_frr B "$B_HOST" "$B_PORT" "$workdir/b.conf"
  log 'Check the inter-bastion iBGP EVPN peering: should show 10.254.254.1/2 Established'
  remote_a "sudo -n vtysh -c 'show bgp l2vpn evpn summary'"
  remote_b "sudo -n vtysh -c 'show bgp l2vpn evpn summary'"
}

switch_site() {
  local site="$1" ctx="$2" remote_cidr="$3" new_vtep_cidr="$4" frc="$5" old_peer="$6" site_prefix="$7"
  local node ip old nncp idx old_addr last new_addr patches
  log "$site: add temporary remote VTEP /24 routes on every node"
  while IFS=$'\t' read -r node ip old; do
    oc --context="$ctx" debug "node/$node" -- chroot /host \
      ip route replace "$remote_cidr" via 10.10.10.1 dev br-ex
  done < <(node_records "$ctx")
  log "$site: update existing NNCP interface addresses in place"
  while IFS=$'\t' read -r nncp idx old_addr; do
    [[ "$old_addr" =~ ^(172\.31\.250|$site_prefix)\.([0-9]+)$ ]] || fail "$site: unexpected NNCP address $nncp: $old_addr"
    last="${old_addr##*.}"; new_addr="$site_prefix.$last"
    if [[ "$old_addr" != "$new_addr" ]]; then
      patches="$(jq -nc --arg old "$old_addr" --arg new "$new_addr" --arg path "/spec/desiredState/interfaces/$idx/ipv4/address/0/ip" '[{op:"test",path:$path,value:$old},{op:"replace",path:$path,value:$new}]')"
      oc --context="$ctx" patch nncp "$nncp" --type=json -p "$patches"
    fi
  done < <(nncp_records "$ctx")
  log "$site: wait for node NMState policies"
  while IFS=$'\t' read -r nncp idx old_addr; do
    oc --context="$ctx" wait --for=condition=Available "nncp/$nncp" --timeout=300s
  done < <(nncp_records "$ctx")
  log "$site: point existing Unmanaged VTEP to non-overlapping site range"
  oc --context="$ctx" patch vtep "$VTEP" --type=merge -p "{\"spec\":{\"cidrs\":[\"$new_vtep_cidr\"]}}"
  oc --context="$ctx" wait --for=condition=Accepted "vtep/$VTEP" --timeout=180s
  log "$site: replace placeholder BGP peer with local bastion 10.10.10.1 AS65000"
  cur_peer="$(oc --context="$ctx" -n openshift-frr-k8s get frrconfiguration "$frc" -o json | jq -r '.spec.bgp.routers[0].neighbors[0].address')"
  if [[ "$cur_peer" == "$old_peer" ]]; then
    patches="$(jq -nc --arg old "$old_peer" '[{op:"test",path:"/spec/bgp/routers/0/neighbors/0/address",value:$old},{op:"replace",path:"/spec/bgp/routers/0/neighbors/0/address",value:"10.10.10.1"},{op:"replace",path:"/spec/bgp/routers/0/neighbors/0/asn",value:65000}]')"
    oc --context="$ctx" -n openshift-frr-k8s patch frrconfiguration "$frc" --type=json -p "$patches"
  elif [[ "$cur_peer" == '10.10.10.1' ]]; then
    echo "Site $site already peers to bastion"
  else
    fail "Site $site unexpected current peer $cur_peer, refusing to modify"
  fi
  log "$site: check generated FRR configurations and node VTEP annotations"
  oc --context="$ctx" -n openshift-frr-k8s get frrconfigurations
  oc --context="$ctx" get nodes -o json | jq -r --arg v "$VTEP" '.items[] | [.metadata.name, (.metadata.annotations["k8s.ovn.org/vteps"] // "{}" | fromjson | .[$v].ips[0] // "not-ready")] | @tsv'
  oc --context="$ctx" get clusteruserdefinednetwork sydney-l2-evpn
}

# FRR displays the *received-prefix count* (including 0) instead of the word
# Established in the State/PfxRcd column once a peer is Established. Verify
# the expected peer, numeric state/prefix count, and exchanged BGP messages.
# Unlike the former `show bgp l2vpn evpn neighbors ... | grep ...` check, this
# uses exactly the EVPN summary command already working on both lab bastions.
check_ibgp_established() {
  local site="$1" peer="$2" summary
  if [[ "$site" == A ]]; then
    summary="$(remote_a "sudo -n vtysh -c 'show bgp l2vpn evpn summary'")" || fail 'Cannot read Site A FRR EVPN summary'
  else
    summary="$(remote_b "sudo -n vtysh -c 'show bgp l2vpn evpn summary'")" || fail 'Cannot read Site B FRR EVPN summary'
  fi
  if ! printf '%s\n' "$summary" | awk -v peer="$peer" '
    $1 == peer {
      found=1
      # Standard (not wide) FRR summary columns: MsgRcvd=$4, MsgSent=$5,
      # State/PfxRcd=$10. For Established, the last is a numeric count.
      if ($10 ~ /^[0-9]+$/ && $4+0 > 0 && $5+0 > 0) ready=1
    }
    END { exit !(found && ready) }
  '; then
    printf '%s\n' "$summary" >&2
    fail "Site $site EVPN peer $peer is not Established (numeric PfxRcd required)"
  fi
  printf 'Site %s EVPN peer %s: Established (0 received prefixes is OK before switch)\n' "$site" "$peer"
}

bgp_check() {
  preflight
  log 'Check both inter-bastion EVPN sessions without changing anything'
  check_ibgp_established A 10.254.254.2
  check_ibgp_established B 10.254.254.1
}

switch() {
  preflight
  check_inventory "$A_CTX" A
  check_inventory "$B_CTX" B
  log 'Confirm inter-bastion FRR iBGP EVPN sessions exist'
  remote_a "sudo -n vtysh -c 'show bgp l2vpn evpn summary'"
  remote_b "sudo -n vtysh -c 'show bgp l2vpn evpn summary'"
  check_ibgp_established A 10.254.254.2
  check_ibgp_established B 10.254.254.1
  log 'Back up all NNCPs, VTEP and source FRRConfiguration objects locally'
  backup_dir="${HOME}/ocp422-evpn-backup-${STAMP}"
  mkdir -p "$backup_dir"
  oc_a get nncp -o yaml > "$backup_dir/site-a-nncp.yaml"
  oc_b get nncp -o yaml > "$backup_dir/site-b-nncp.yaml"
  oc_a get vtep "$VTEP" -o yaml > "$backup_dir/site-a-vtep.yaml"
  oc_b get vtep "$VTEP" -o yaml > "$backup_dir/site-b-vtep.yaml"
  oc_a -n openshift-frr-k8s get frrconfiguration "$A_FRC" -o yaml > "$backup_dir/site-a-frrconfiguration.yaml"
  oc_b -n openshift-frr-k8s get frrconfiguration "$B_FRC" -o yaml > "$backup_dir/site-b-frrconfiguration.yaml"
  printf 'Backups saved: %s\n' "$backup_dir"
  read -r -p 'This readdresses all 14 lab VTEPs and may temporarily interrupt the EVPN CUDNs. Type SWITCH to continue: ' reply
  [[ "$reply" == SWITCH ]] || fail 'No changes made by the switch stage'
  switch_site A "$A_CTX" 10.251.20.0/24 10.251.10.0/24 "$A_FRC" 192.0.2.1 10.251.10
  switch_site B "$B_CTX" 10.251.10.0/24 10.251.20.0/24 "$B_FRC" 192.0.2.2 10.251.20
  log 'Both sites switched. Run verify stage and inspect EVPN routes.'
}

verify() {
  preflight
  log 'FRR EVPN peers and routes on both bastions'
  remote_a "sudo -n vtysh -c 'show bgp l2vpn evpn summary' -c 'show bgp l2vpn evpn'"
  remote_b "sudo -n vtysh -c 'show bgp l2vpn evpn summary' -c 'show bgp l2vpn evpn'"
  for site in A B; do
    if [[ $site == A ]]; then ctx="$A_CTX"; node=worker-cluster-kcp74-2; else ctx="$B_CTX"; node=worker-cluster-9r9gz-1; fi
    log "Site $site VTEP, CUDN and VMs"
    oc --context="$ctx" get vtep "$VTEP"
    oc --context="$ctx" get clusteruserdefinednetwork sydney-l2-evpn
    oc --context="$ctx" -n evpn-demo get vmi -o wide
    pod="$(oc --context="$ctx" -n openshift-frr-k8s get pod -o json | jq -r --arg n "$node" '.items[] | select(.spec.nodeName==$n and any(.spec.containers[]?; .name=="frr")) | .metadata.name' | head -1)"
    if [[ -n "$pod" ]]; then
      oc --context="$ctx" -n openshift-frr-k8s exec "$pod" -c frr -- vtysh -c 'show bgp l2vpn evpn summary' -c 'show evpn vni'
    else
      printf 'No FRR container found on %s\n' "$node" >&2
    fi
  done
  log 'Verify actual VM-host VTEP underlay in both directions'
  if oc_a debug node/worker-cluster-kcp74-2 -- chroot /host ping -I 10.251.10.15 -c 3 -W 2 10.251.20.24; then
    echo 'SITE A VTEP -> SITE B VTEP: PASS'
  else
    echo 'SITE A VTEP -> SITE B VTEP: FAIL (inspect node routes and bastion nft counters)'
  fi
  if oc_b debug node/worker-cluster-9r9gz-1 -- chroot /host ping -I 10.251.20.24 -c 3 -W 2 10.251.10.15; then
    echo 'SITE B VTEP -> SITE A VTEP: PASS'
  else
    echo 'SITE B VTEP -> SITE A VTEP: FAIL (inspect node routes and bastion nft counters)'
  fi
  log 'If Site A learns Site B MAC 0a:58:0a:fa:32:04 and vice versa, test VM ping 10.250.50.3 -> 10.250.50.4.'
}


# Reapply ephemeral bastion routes/firewall after a reboot or tunnel restart.
# Unlike fabric(), this does NOT change FRR configuration or restart BGP.
restore_underlay() {
  preflight
  check_inventory "$A_CTX" A
  check_inventory "$B_CTX" B
  log 'Restore bastion tunnel MTU and remote VTEP routes (no FRR restart)'
  remote_a 'sudo -n ip link set tun7 mtu 1500 up; sudo -n ip route replace 10.251.20.0/24 via 10.254.254.2 dev tun7'
  remote_b 'sudo -n ip link set tun7 mtu 1500 up; sudo -n ip route replace 10.251.10.0/24 via 10.254.254.1 dev tun7'
  log 'Restore per-node local VTEP routes'
  while IFS=$'\t' read -r node ip old; do
    [[ "$old" =~ ^10\.251\.10\.[0-9]+$ ]] || fail "Site A not switched: $node $old"
    remote_a "sudo -n ip route replace $old/32 via $ip dev eth1"
  done < <(node_records "$A_CTX")
  while IFS=$'\t' read -r node ip old; do
    [[ "$old" =~ ^10\.251\.20\.[0-9]+$ ]] || fail "Site B not switched: $node $old"
    remote_b "sudo -n ip route replace $old/32 via $ip dev eth1"
  done < <(node_records "$B_CTX")
  nft_rules A; nft_rules B
  log 'Bastion routes and scoped VTEP forwarding restored; FRR was not restarted.'
}

case "$STAGE" in
  plan) plan ;;
  frr-check) frr_check ;;
  bgp-check) bgp_check ;;
  fabric) fabric ;;
  switch) switch ;;
  verify) verify ;;
  restore-underlay) restore_underlay ;;
  *) echo 'Usage: bash ocp422_evpn_finish_v4.sh {plan|frr-check|bgp-check|fabric|switch|verify|restore-underlay}' >&2; exit 2 ;;
esac
