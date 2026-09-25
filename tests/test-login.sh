#!/usr/bin/env bash
# Offline tests: use a fake oc executable; never touch real clusters.
set -euo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TMP_DIR"' EXIT
mkdir -p "$TMP_DIR/repo" "$TMP_DIR/fake-bin"
cp -R "$ROOT_DIR/scripts" "$TMP_DIR/repo/"

cat > "$TMP_DIR/fake-bin/oc" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$MOCK_OC_LOG"
case "${1:-}" in
  login)
    case "${2:-}" in
      https://site-a.example:6443)
        printf 'site-a-user/site-a\n' > "$MOCK_OC_CONTEXT"
        printf 'https://site-a.example:6443\n' > "$MOCK_OC_SERVER"
        ;;
      https://site-b.example:6443)
        if [[ "${MOCK_FAIL_SITE_B:-}" == 1 ]]; then exit 1; fi
        if [[ "${MOCK_SAME_CONTEXT:-}" == 1 ]]; then
          printf 'site-a-user/site-a\n' > "$MOCK_OC_CONTEXT"
        else
          printf 'site-b-user/site-b\n' > "$MOCK_OC_CONTEXT"
        fi
        if [[ "${MOCK_SAME_SERVER:-}" == 1 ]]; then
          printf 'https://site-a.example:6443\n' > "$MOCK_OC_SERVER"
        else
          printf 'https://site-b.example:6443\n' > "$MOCK_OC_SERVER"
        fi
        ;;
      *) echo 'Unexpected mock server' >&2; exit 2 ;;
    esac
    ;;
  config)
    case "${2:-}" in
      current-context) cat "$MOCK_OC_CONTEXT" ;;
      view) cat "$MOCK_OC_SERVER" ;;
      *) exit 2 ;;
    esac
    ;;
  get)
    printf 'apiVersion: v1\n' ;;
  --context=*)
    # The preflight script uses context-scoped get requests.
    printf 'OK\n' ;;
  *) exit 2 ;;
esac
MOCK
chmod +x "$TMP_DIR/fake-bin/oc"
export PATH="$TMP_DIR/fake-bin:$PATH"
export MOCK_OC_LOG="$TMP_DIR/oc.log"
export MOCK_OC_CONTEXT="$TMP_DIR/current-context"
export MOCK_OC_SERVER="$TMP_DIR/current-server"
export SITE_A_API_URL='https://site-a.example:6443'
export SITE_B_API_URL='https://site-b.example:6443'

cd "$TMP_DIR/repo"
./scripts/00-login.sh > "$TMP_DIR/login.out"
test -f .site-contexts.env
! grep -Ei '(password|token|secret)' .site-contexts.env | grep -Ev '^#' >/dev/null
# shellcheck disable=SC1091
source .site-contexts.env
[[ "$SITE_A_CONTEXT" == 'site-a-user/site-a' ]]
[[ "$SITE_B_CONTEXT" == 'site-b-user/site-b' ]]

# Saved contexts must work without exported values, even after Site B login
# made Site B the global current context.
unset SITE_A_CONTEXT SITE_B_CONTEXT
: > "$MOCK_OC_LOG"
./scripts/00-preflight.sh > "$TMP_DIR/preflight.out"
grep -q -- '--context=site-a-user/site-a get clusterversion' "$MOCK_OC_LOG"
grep -q -- '--context=site-b-user/site-b get clusterversion' "$MOCK_OC_LOG"

# Explicitly exported variables override the saved file.
: > "$MOCK_OC_LOG"
SITE_A_CONTEXT='manually-selected-site-a' ./scripts/00-preflight.sh > /dev/null
grep -q -- '--context=manually-selected-site-a get clusterversion' "$MOCK_OC_LOG"
grep -q -- '--context=site-b-user/site-b get clusterversion' "$MOCK_OC_LOG"

# Site names resolve to their saved contexts in the cluster-settings script.
: > "$MOCK_OC_LOG"
./scripts/01-enable-cluster-networking.sh site-b > /dev/null
grep -q -- '--context=site-b-user/site-b get network.operator' "$MOCK_OC_LOG"

# A duplicate context or server must be rejected without replacing the file.
cp .site-contexts.env "$TMP_DIR/saved.env"
if MOCK_SAME_SERVER=1 ./scripts/00-login.sh > /dev/null 2>&1; then
  echo 'FAIL: duplicate servers were accepted' >&2; exit 1
fi
cmp .site-contexts.env "$TMP_DIR/saved.env"
if MOCK_SAME_CONTEXT=1 ./scripts/00-login.sh > /dev/null 2>&1; then
  echo 'FAIL: duplicate contexts were accepted' >&2; exit 1
fi
cmp .site-contexts.env "$TMP_DIR/saved.env"
if MOCK_FAIL_SITE_B=1 ./scripts/00-login.sh > /dev/null 2>&1; then
  echo 'FAIL: failed login was accepted' >&2; exit 1
fi
cmp .site-contexts.env "$TMP_DIR/saved.env"
printf '%s\n' 'PASS: login captures distinct contexts and saves only context names' \
  'PASS: preflight auto-loads saved contexts; exported contexts override' \
  'PASS: site-aware cluster settings target the saved context' \
  'PASS: duplicate logins and failed Site B login preserve existing config'
