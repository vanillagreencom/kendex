#!/usr/bin/env bash
# Orch compatibility wrappers around the shared GitHub auth helpers.
#
# Source this file; do not execute it directly.

_ORCH_GH_AUTH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ORCH_SHARED_GH_AUTH="$_ORCH_GH_AUTH_DIR/../../../github/scripts/lib/gh-auth.sh"
if [[ ! -f "$_ORCH_SHARED_GH_AUTH" ]]; then
  echo "orch gh-auth: shared GitHub auth helper not found at $_ORCH_SHARED_GH_AUTH" >&2
  return 1 2>/dev/null || exit 1
fi
# shellcheck source=../../../github/scripts/lib/gh-auth.sh
source "$_ORCH_SHARED_GH_AUTH"
unset _ORCH_GH_AUTH_DIR _ORCH_SHARED_GH_AUTH

orch_sanitize_gh_env() {
  vstack_github_sanitize_gh_env
}

orch_github_auth_status() {
  vstack_github_auth_status
}

orch_github_auth_status_capture() {
  vstack_github_auth_status_capture "$@"
}

orch_github_keyring_auth_status() {
  vstack_github_keyring_auth_status
}

orch_is_resolved_github_token() {
  vstack_github_is_resolved_token "$@"
}

orch_select_github_auth_token() {
  vstack_github_select_auth_token default
}

orch_load_env_bot_token() {
  local project_root="${1:?orch_load_env_bot_token: project_root required}"
  local token
  token="$(vstack_github_load_token "$project_root" default || true)"
  [[ -n "$token" ]] || return 1
  export GH_TOKEN="$token"
  return 0
}
