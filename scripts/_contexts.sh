#!/usr/bin/env bash
# Source from repo scripts. Explicit environment variables take precedence
# over the locally saved contexts from 00-login.sh.
load_site_contexts() {
  local scripts_dir root_dir previous_a previous_b
  scripts_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  root_dir="$(cd -- "$scripts_dir/.." && pwd)"
  previous_a="${SITE_A_CONTEXT:-}"
  previous_b="${SITE_B_CONTEXT:-}"

  if [[ ( -z "$previous_a" || -z "$previous_b" ) && -f "$root_dir/.site-contexts.env" ]]; then
    # The file is generated locally, excludes credentials, and is gitignored.
    # shellcheck disable=SC1090
    source "$root_dir/.site-contexts.env"
  fi

  SITE_A_CONTEXT="${previous_a:-${SITE_A_CONTEXT:-}}"
  SITE_B_CONTEXT="${previous_b:-${SITE_B_CONTEXT:-}}"
  export SITE_A_CONTEXT SITE_B_CONTEXT
}
