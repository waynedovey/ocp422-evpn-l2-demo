#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
while IFS= read -r -d '' script; do bash -n "$script"; done < <(find "$ROOT/scripts" "$ROOT/tests" -type f -name '*.sh' -print0)
echo 'PASS: all Bash scripts pass bash -n'
python3 "$ROOT/tests/test-static.py"
"$ROOT/tests/test-bgp-gate.sh"
"$ROOT/tests/test-login.sh"
echo 'PASS: complete offline test suite'
