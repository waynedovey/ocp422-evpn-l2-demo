#!/usr/bin/env bash
# Used only by 02-deploy-site-a.sh / 03-deploy-site-b.sh. Applies current working manifests.
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/_contexts.sh"
load_site_contexts
SITE="${1:?site-a or site-b required}"
MODE="${2:-full}"
case "$MODE" in full|--network-only) ;; *) echo "Usage: _deploy.sh site-a|site-b [--network-only]" >&2; exit 2 ;; esac
case "$SITE" in
  site-a) CTX="${SITE_A_CONTEXT:?Missing SITE_A_CONTEXT}"; VM=vm-site-a ;;
  site-b) CTX="${SITE_B_CONTEXT:?Missing SITE_B_CONTEXT}"; VM=vm-site-b ;;
  *) echo "Invalid site $SITE" >&2; exit 2 ;;
esac
command -v python3 >/dev/null || { echo 'python3 is required to render new VM templates' >&2; exit 1; }
# Check the destination before modifying anything.
oc --context="$CTX" whoami --show-server
printf '\nApply shared namespace and site-specific FRR peer\n'
oc --context="$CTX" apply -f "$ROOT/shared/00-namespace.yaml"
oc --context="$CTX" apply -f "$ROOT/$SITE/01-frrconfiguration.yaml"
"$ROOT/scripts/05-configure-vteps.sh" "$SITE" apply
oc --context="$CTX" apply -f "$ROOT/$SITE/02-vtep.yaml"
oc --context="$CTX" wait --for=condition=Accepted vtep/sydney-vtep --timeout=180s
oc --context="$CTX" apply -f "$ROOT/shared/03-routeadvertisements.yaml"
oc --context="$CTX" apply -f "$ROOT/shared/04-cudn.yaml"
if [[ "$MODE" == --network-only ]]; then
  echo "Applied $SITE cluster networking only; no VM was created or modified."
  exit 0
fi
if oc --context="$CTX" -n evpn-demo get vm "$VM" >/dev/null 2>&1; then
  echo "$VM already exists: leaving the proven VM and its cloud-init untouched."
else
  key="${VM_SSH_PUBLIC_KEY:-}"
  if [[ -z "$key" ]]; then
    keyfile="${VM_SSH_PUBLIC_KEY_FILE:-$HOME/.ssh/id_ed25519.pub}"
    if [[ -r "$keyfile" ]]; then key="$(head -1 "$keyfile")"; fi
  fi
  [[ "$key" =~ ^ssh-(ed25519|rsa|ecdsa)[[:space:]] ]] || {
    echo 'No valid VM public key. Export VM_SSH_PUBLIC_KEY or VM_SSH_PUBLIC_KEY_FILE.' >&2
    echo 'Existing VMs are never recreated automatically.' >&2
    exit 1
  }
  mkdir -p "$ROOT/$SITE/rendered"
  export VM_SSH_PUBLIC_KEY="$key"
  TEMPLATE="$ROOT/$SITE/05-vm-${SITE}.yaml" OUTPUT="$ROOT/$SITE/rendered/$VM.yaml" python3 - <<'PY'
from pathlib import Path
import os
src=Path(os.environ['TEMPLATE']).read_text()
key=os.environ['VM_SSH_PUBLIC_KEY']
assert '\n' not in key and '\r' not in key
assert '__SSH_PUBLIC_KEY__' in src
Path(os.environ['OUTPUT']).write_text(src.replace('__SSH_PUBLIC_KEY__',key))
PY
  oc --context="$CTX" apply -f "$ROOT/$SITE/rendered/$VM.yaml"
fi
oc --context="$CTX" get vtep sydney-vtep
oc --context="$CTX" get routeadvertisements sydney-l2-evpn
oc --context="$CTX" get clusteruserdefinednetwork sydney-l2-evpn
oc --context="$CTX" -n evpn-demo get vm,vmi
