#!/usr/bin/env bash
# Unit-test the proven v4 gate without any live cluster or SSH access.
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
sed -n '/^check_ibgp_established() {/,/^}/p' "$ROOT/scripts/06-complete-fabric.sh" > "$TMP/function.sh"
cat > "$TMP/case.sh" <<'TEST'
#!/usr/bin/env bash
set -Eeuo pipefail
source "$1"
fail() { echo "$*" >&2; exit 1; }
remote_a() { printf '%s\n' "$DATA"; }
remote_b() { printf '%s\n' "$DATA"; }
DATA="10.254.254.2 4 65000 15 15 0 0 0 00:12:11 0 0 N/A"
check_ibgp_established A 10.254.254.2
data="unused"
DATA="10.254.254.1 4 65000 15 15 0 0 0 00:12:11 7 7 N/A"
check_ibgp_established B 10.254.254.1
TEST
bash "$TMP/case.sh" "$TMP/function.sh" >/dev/null
# These must all fail: wrong peer, Active neighbor, zero exchanged BGP messages.
for line in \
  '10.254.254.3 4 65000 15 15 0 0 0 00:12:11 0 0 N/A' \
  '10.254.254.2 4 65000 15 15 0 0 0 never Active 0 N/A' \
  '10.254.254.2 4 65000 0 0 0 0 0 never 0 0 N/A'; do
  if DATA="$line" bash -c 'set -Eeuo pipefail; source "$1"; fail() { exit 1; }; remote_a() { printf "%s\n" "$DATA"; }; check_ibgp_established A 10.254.254.2' -- "$TMP/function.sh" > /dev/null 2>&1; then
    echo "FAIL: incorrect BGP state accepted: $line" >&2; exit 1
  fi
done
echo 'PASS: BGP gate accepts established PfxRcd 0/7 and rejects wrong peer, Active and no messages'
