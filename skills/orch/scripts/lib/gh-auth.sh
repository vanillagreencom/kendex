#!/usr/bin/env bash
# Orch compatibility wrappers around the shared GitHub auth helpers.
#
# Source this file; do not execute it directly.


# Callers preserve positional values for this diagnostic catalog.
gh_auth_message() {
  local _message_key="$1"
  shift
  case "$_message_key" in
    helper-missing)
      printf 'gh-auth: helper-missing path=%s\n' "$_ORCH_SHARED_GH_AUTH"
      printf '%s\n' "orch gh-auth: shared GitHub auth helper not found at $_ORCH_SHARED_GH_AUTH"
      ;;
  esac
}

_ORCH_GH_AUTH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ORCH_SHARED_GH_AUTH="$_ORCH_GH_AUTH_DIR/../../../github/scripts/lib/gh-auth.sh"
if [[ ! -f "$_ORCH_SHARED_GH_AUTH" ]]; then
  gh_auth_message helper-missing "$@" >&2
  return 1 2>/dev/null || exit 1
fi
# shellcheck source=../../../github/scripts/lib/gh-auth.sh
source "$_ORCH_SHARED_GH_AUTH"
unset _ORCH_GH_AUTH_DIR _ORCH_SHARED_GH_AUTH

# Fleet supplies both overseer token files. Check their current target before
# opening it: a FIFO would block the watch or approval. Bound the whole read,
# including trailing newlines, so an interrupted fleet write cannot fill memory.
orch_token_file_read() { # FILE
  local file="${1:-}" token="" mode="" cause="" status=0 LC_ALL=C
  local parent path permissions=077 refused_file="$file"
  parent="${file%/*}"
  [[ "$parent" != "$file" ]] || parent=.
  [[ -n "$parent" ]] || parent=/
  if [[ -z "$file" ]]; then cause=unset
  elif [[ ! -f "$file" ]]; then cause=not-regular
  else
    # Fleet writes in member homes. A writable parent permits replacement even
    # when the token file itself is private; directory read and search are safe.
    for path in "$file" "$parent"; do
      refused_file="$path"
      if [[ ! -O "$path" ]]; then cause=not-owned; break; fi
      mode="$(stat -L -c '%a' -- "$path" 2>/dev/null || stat -L -f '%Lp' -- "$path" 2>/dev/null)" || cause=malformed
      case "$mode" in
        ""|*[!0-7]*) cause=malformed ;;
        *) (( (8#$mode & permissions) == 0 )) || cause="mode-$mode" ;;
      esac
      [[ -z "$cause" ]] || break
      permissions=022
    done
  fi
  if [[ -z "$cause" ]]; then
    refused_file="$file"
    # An empty delimiter reads through LF and stops at NUL, EOF or the cap.
    # Only EOF is accepted. Strip all final LF bytes as command substitution did.
    { IFS= read -r -n 4096 -d '' token || status=$?; } 2>/dev/null < "$file" || cause=malformed
    if [[ "${#token}" -eq 4096 ]]; then cause=too-long
    elif [[ "$status" -ne 1 ]]; then cause=malformed
    fi
    if [[ -z "$cause" ]]; then
      while [[ "$token" == *$'\n' ]]; do token="${token%$'\n'}"; done
      [[ -n "$token" && "$token" != *[[:space:]]* ]] || cause=malformed
    fi
  fi
  if [[ -n "$cause" ]]; then
    printf 'orch_token_file_read: refused file=%s cause=%s\n' "$refused_file" "$cause" >&2
    return 1
  fi
  printf '%s' "$token"
}

orch_sanitize_gh_env() {
  kendex_github_sanitize_gh_env
}

# 124 is gh killed at its bound, nothing against an env token: the first call
# through an egress proxy can be the slow one, so the token is asked once more
# before any caller's fallback drops it.
orch_github_auth_status() {
  local status=0
  kendex_github_auth_status || status=$?
  if [[ "$status" -eq 124 ]] && kendex_github_has_env_token; then
    kendex_github_auth_status
    return
  fi
  return "$status"
}

orch_github_auth_status_capture() {
  kendex_github_auth_status_capture "$@"
}

orch_github_keyring_auth_status() {
  kendex_github_keyring_auth_status
}

orch_is_resolved_github_token() {
  kendex_github_is_resolved_token "$@"
}

orch_select_github_auth_token() {
  kendex_github_select_auth_token default
}

orch_load_env_bot_token() {
  local project_root="${1:?orch_load_env_bot_token: project_root required}"
  local token
  token="$(kendex_github_load_token "$project_root" default || true)"
  [[ -n "$token" ]] || return 1
  export GH_TOKEN="$token"
  return 0
}
