#!/usr/bin/env bash
# Recover the established lab-only SSH Layer 3 tunnel; no remote daemon config changes.
# Prereq: Bastion B's sshd PermitTunnel point-to-point; A's id_rsa pubkey authorized on B.
set -Eeuo pipefail
SITE_A="${BASTION_A_HOST:-ssh.ocpv02.rhdp.net}"
SITE_B="${BASTION_B_HOST:-ssh.ocpv08.rhdp.net}"
PORT_A="${BASTION_A_PORT:-31482}"
PORT_B="${BASTION_B_PORT:-31156}"
MODE="${1:-status}"
ssh_a() { ssh -n -o BatchMode=yes -p "$PORT_A" "lab-user@$SITE_A" "$@"; }
ssh_b() { ssh -n -o BatchMode=yes -p "$PORT_B" "lab-user@$SITE_B" "$@"; }
status() {
  ssh_a 'hostname -f; ip -br addr show tun7; pgrep -au lab-user ssh || true; ping -I tun7 -c 2 -W 2 10.254.254.2'
  ssh_b 'hostname -f; ip -br addr show tun7; ping -I tun7 -c 2 -W 2 10.254.254.1'
}
if [[ "$MODE" == status ]]; then status; exit; fi
[[ "$MODE" == start ]] || { echo "Usage: $0 [status|start]" >&2; exit 2; }
if ssh_a 'ping -I tun7 -c 1 -W 2 10.254.254.2 >/dev/null' && ssh_b 'ping -I tun7 -c 1 -W 2 10.254.254.1 >/dev/null'; then
  echo 'SSH tunnel already working; leaving the current process untouched.'
  exit 0
fi
ssh_b 'test "$(sudo -n sshd -T | awk "/^permittunnel / { print \$2 }")" = point-to-point || { echo "Enable PermitTunnel point-to-point on Bastion B first" >&2; exit 1; }'
ssh_b 'if ! ip link show tun7 >/dev/null 2>&1; then sudo -n ip tuntap add dev tun7 mode tun user lab-user; fi; sudo -n ip addr replace 10.254.254.2 peer 10.254.254.1/32 dev tun7; sudo -n ip link set tun7 mtu 1500 up'
ssh_a 'if ! ip link show tun7 >/dev/null 2>&1; then sudo -n ip tuntap add dev tun7 mode tun user lab-user; fi; sudo -n ip addr replace 10.254.254.1 peer 10.254.254.2/32 dev tun7; sudo -n ip link set tun7 mtu 1500 up'
# Avoid silently running two competing -w processes. Run recovery only if no old tunnel exists.
ssh_a 'if ps -eo args= | grep -E "^ssh .* -w 7:7 " | grep -v grep; then echo "A stale SSH tunnel process exists; inspect it manually before restarting" >&2; exit 1; fi'
ssh_a "ssh -f -N -T -F /dev/null -i /home/lab-user/.ssh/id_rsa -o IdentitiesOnly=yes -o UserKnownHostsFile=/home/lab-user/.ssh/known_hosts -o StrictHostKeyChecking=yes -o BatchMode=yes -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o Tunnel=point-to-point -w 7:7 -p $PORT_B lab-user@$SITE_B"
status
