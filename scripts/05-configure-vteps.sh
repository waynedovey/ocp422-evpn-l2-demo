#!/usr/bin/env bash
# Validate existing VTEP NNCPs or create missing ones from the 14 checked-in lab manifests.
# Never overwrite an NNCP with a different configured VTEP IP: use the backed-up migration instead.
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/_contexts.sh"
load_site_contexts
SITE="${1:-}"
MODE="${2:-check}"
case "$SITE" in
  site-a) CTX="${SITE_A_CONTEXT:?Missing Site A context}" ;;
  site-b) CTX="${SITE_B_CONTEXT:?Missing Site B context}" ;;
  *) echo "Usage: $0 site-a|site-b [check|apply]" >&2; exit 2 ;;
esac
case "$MODE" in check|apply) ;; *) echo "Mode must be check or apply" >&2; exit 2 ;; esac
command -v jq >/dev/null || { echo 'jq is required' >&2; exit 1; }
count=0
for manifest in "$ROOT/$SITE/nncp/"*.yaml; do
  name="$(basename "$manifest" .yaml)"
  node="${name#evpn-vtep-}"
  expected="$(sed -n '/^[[:space:]]*- ip: /s/.*- ip: //p' "$manifest")"
  oc --context="$CTX" get node "$node" -o name >/dev/null || {
    echo "Missing node: $node" >&2; exit 1;
  }
  if oc --context="$CTX" get nncp "$name" -o json > /dev/null 2>&1; then
    actual="$(oc --context="$CTX" get nncp "$name" -o json | jq -r '.spec.desiredState.interfaces[]? | select(.name=="evpn-vtep0") | .ipv4.address[0].ip // empty')"
    if [[ "$expected" != "$actual" ]]; then
      echo "REFUSING to overwrite $name: actual=$actual, expected=$expected" >&2
      echo 'Use the backed-up switch procedure when migrating existing VTEPs.' >&2
      exit 1
    fi
    echo "OK existing $name: $actual"
  elif [[ "$MODE" == apply ]]; then
    oc --context="$CTX" apply -f "$manifest"
  else
    echo "MISSING $name: $expected (use apply for a fresh lab)" >&2
    exit 1
  fi
  count=$((count+1))
done
[[ $count -eq 7 ]] || { echo "Expected exactly seven NNCPs, found $count" >&2; exit 1; }
if [[ "$MODE" == apply ]]; then
  for manifest in "$ROOT/$SITE/nncp/"*.yaml; do
    name="$(basename "$manifest" .yaml)"
    oc --context="$CTX" wait --for=condition=Available "nncp/$name" --timeout=300s
  done
fi
echo "$SITE: seven expected VTEP NNCPs verified ($MODE)."
