#!/usr/bin/env bash
# Restore ephemeral remote VTEP routes on all fourteen OCP hosts after a node reboot.
# These lab routes are not a substitute for a properly managed routed underlay.
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_contexts.sh"
load_site_contexts
: "${SITE_A_CONTEXT:?Missing Site A context}"
: "${SITE_B_CONTEXT:?Missing Site B context}"
"$SCRIPT_DIR/05-start-tunnel.sh" status >/dev/null || {
  echo 'SSH tunnel down. Run scripts/05-start-tunnel.sh start first.' >&2; exit 1;
}
"$SCRIPT_DIR/06-complete-fabric.sh" restore-underlay
for entry in "$SITE_A_CONTEXT:10.251.20.0/24" "$SITE_B_CONTEXT:10.251.10.0/24"; do
  ctx="${entry%:*}"; remote="${entry##*:}"
  echo "Restoring $remote on $ctx"
  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    oc --context="$ctx" debug "node/$node" -- chroot /host \
      ip route replace "$remote" via 10.10.10.1 dev br-ex
  done < <(oc --context="$ctx" get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
done
printf '\nRoutes reapplied. Run ./scripts/04-test.sh after reconciling the SSH tunnel and FRR.\n'
