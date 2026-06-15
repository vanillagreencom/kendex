#!/usr/bin/env bash
# Shared GitHub auth helpers for vstack skill scripts.
#
# Source this file; do not execute it directly.

vstack_github_is_resolved_token() {
  local token="${1:-}"
  [[ -n "$token" && "$token" != op://* ]] || return 1
  [[ "$token" =~ ^gh[pours]_ ]] || [[ "$token" =~ ^github_pat_ ]]
}

vstack_github_run_bounded() {
  local seconds="$1"
  shift

  if command -v timeout >/dev/null 2>&1; then
    timeout "${seconds}s" "$@"
  else
    "$@"
  fi
}

vstack_github_run_bounded_capture() {
  local seconds="$1"
  local stdout_file="$2"
  local stderr_file="$3"
  shift 3

  vstack_github_run_bounded "$seconds" "$@" >"$stdout_file" 2>"$stderr_file"
}

vstack_github_has_env_token() {
  [[ -n "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]]
}

vstack_github_token_auth_status() {
  vstack_github_has_env_token || return 1
  local auth_timeout="${VSTACK_GITHUB_AUTH_TIMEOUT:-10}"
  vstack_github_run_bounded "$auth_timeout" gh api user --jq '.login' >/dev/null 2>&1
}

vstack_github_token_auth_status_capture() {
  local auth_timeout="$1"
  local stdout_file="$2"
  local stderr_file="$3"

  vstack_github_has_env_token || return 1
  vstack_github_run_bounded_capture "$auth_timeout" "$stdout_file" "$stderr_file" gh api user --jq '.login'
}

vstack_github_auth_status() {
  local auth_timeout="${VSTACK_GITHUB_AUTH_TIMEOUT:-10}"

  if vstack_github_has_env_token; then
    vstack_github_token_auth_status
    return $?
  fi

  vstack_github_run_bounded "$auth_timeout" gh auth status >/dev/null 2>&1
}

vstack_github_auth_status_capture() {
  local auth_timeout="$1"
  local stdout_file="$2"
  local stderr_file="$3"

  if vstack_github_has_env_token; then
    vstack_github_token_auth_status_capture "$auth_timeout" "$stdout_file" "$stderr_file"
    return $?
  fi

  vstack_github_run_bounded_capture "$auth_timeout" "$stdout_file" "$stderr_file" gh auth status
}

vstack_github_keyring_auth_status() {
  local auth_timeout="${VSTACK_GITHUB_AUTH_TIMEOUT:-10}"
  vstack_github_run_bounded "$auth_timeout" env -u GH_TOKEN -u GITHUB_TOKEN gh auth status >/dev/null 2>&1
}

vstack_github_resolve_op_reference_to_var() {
  local ref="${1:?vstack_github_resolve_op_reference: ref required}"
  local label="${2:-GitHub token}"
  local out_var="${3:?vstack_github_resolve_op_reference: output var required}"
  local op_timeout="${VSTACK_GITHUB_OP_TIMEOUT:-10}"
  local op_output="" op_status=0

  if ! command -v op >/dev/null 2>&1; then
    export VSTACK_GITHUB_TOKEN_ERROR_TYPE="token_resolution_unavailable"
    export VSTACK_GITHUB_TOKEN_ERROR="${label} is a 1Password reference but 'op' CLI is not available"
    return 1
  fi

  if command -v timeout >/dev/null 2>&1; then
    op_output=$(timeout "${op_timeout}s" op read "$ref" 2>&1) || op_status=$?
  else
    op_output=$(op read "$ref" 2>&1) || op_status=$?
  fi

  if [[ "$op_status" -eq 0 && -n "$op_output" ]]; then
    printf -v "$out_var" '%s' "$op_output"
    return 0
  fi

  case "$op_status" in
    124)
      export VSTACK_GITHUB_TOKEN_ERROR_TYPE="token_resolution_timeout"
      export VSTACK_GITHUB_TOKEN_ERROR="Timed out resolving ${label} 1Password reference after ${op_timeout}s"
      ;;
    *)
      export VSTACK_GITHUB_TOKEN_ERROR_TYPE="token_resolution_failed"
      export VSTACK_GITHUB_TOKEN_ERROR="Failed to resolve ${label} 1Password reference"
      ;;
  esac
  if [[ -n "$op_output" ]]; then
    export VSTACK_GITHUB_TOKEN_ERROR_DETAIL="$(printf '%s' "$op_output" | head -c 500 | tr '\n' ' ')"
  fi
  return 1
}

vstack_github_sanitize_gh_env() {
  command -v gh >/dev/null 2>&1 || return 0
  [[ -z "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]] && return 0
  local auth_status=0
  if vstack_github_auth_status; then
    return 0
  else
    auth_status=$?
  fi
  [[ "$auth_status" -eq 124 ]] && return 0
  if [[ "${VSTACK_GITHUB_SELECTED_TOKEN_SOURCE:-}" == "GH_BOT_TOKEN" ]]; then
    return 0
  fi
  if vstack_github_keyring_auth_status; then
    echo "Warning: GH_TOKEN/GITHUB_TOKEN failed gh auth; unsetting them and using gh keyring auth." >&2
    unset GH_TOKEN GITHUB_TOKEN
    export VSTACK_GITHUB_AUTH_FALLBACK="keyring"
  fi
  return 0
}

vstack_github_select_auth_token() {
  local mode="${1:-default}"
  local -a order
  local var_name token

  case "$mode" in
    bot) order=(GH_BOT_TOKEN GH_TOKEN GITHUB_TOKEN) ;;
    bot-only) order=(GH_BOT_TOKEN) ;;
    router) order=(GH_TOKEN GH_BOT_TOKEN GITHUB_TOKEN) ;;
    user) order=(GH_TOKEN GITHUB_TOKEN) ;;
    *) order=(GH_TOKEN GITHUB_TOKEN GH_BOT_TOKEN) ;;
  esac

  for var_name in "${order[@]}"; do
    token="${!var_name:-}"
    if vstack_github_is_resolved_token "$token"; then
      printf '%s' "$token"
      return 0
    fi
  done

  for var_name in "${order[@]}"; do
    token="${!var_name:-}"
    if [[ "$token" == op://* ]]; then
      printf '%s' "$token"
      return 0
    fi
  done

  return 1
}

vstack_github_apply_selected_auth_token() {
  local mode="${1:-default}"
  local -a order
  local var_name token="" selected_var="" resolved=""

  unset VSTACK_GITHUB_SELECTED_TOKEN_SOURCE
  case "$mode" in
    bot) order=(GH_BOT_TOKEN GH_TOKEN GITHUB_TOKEN) ;;
    bot-only) order=(GH_BOT_TOKEN) ;;
    router) order=(GH_TOKEN GH_BOT_TOKEN GITHUB_TOKEN) ;;
    user) order=(GH_TOKEN GITHUB_TOKEN) ;;
    *) order=(GH_TOKEN GITHUB_TOKEN GH_BOT_TOKEN) ;;
  esac

  for var_name in "${order[@]}"; do
    token="${!var_name:-}"
    if vstack_github_is_resolved_token "$token"; then
      selected_var="$var_name"
      break
    fi
    token=""
  done

  if [[ -z "$token" ]]; then
    for var_name in "${order[@]}"; do
      token="${!var_name:-}"
      if [[ "$token" == op://* ]]; then
        selected_var="$var_name"
        break
      fi
      token=""
    done
  fi

  [[ -n "$token" ]] || return 1

  if [[ "$token" == op://* ]]; then
    if ! vstack_github_resolve_op_reference_to_var "$token" "GitHub token" resolved; then
      unset GH_TOKEN GITHUB_TOKEN
      return 1
    fi
    token="$resolved"
  fi

  if vstack_github_is_resolved_token "$token"; then
    export GH_TOKEN="$token"
    unset GITHUB_TOKEN
    export VSTACK_GITHUB_SELECTED_TOKEN_SOURCE="$selected_var"
    return 0
  fi

  return 1
}

vstack_github_load_project_env_preserving_caller() {
  local project_root="$1"
  [[ -n "$project_root" ]] || return 0

  local caller_gh_token_set="${GH_TOKEN+x}"
  local caller_gh_token="${GH_TOKEN:-}"
  local caller_github_token_set="${GITHUB_TOKEN+x}"
  local caller_github_token="${GITHUB_TOKEN:-}"
  local caller_gh_bot_token_set="${GH_BOT_TOKEN+x}"
  local caller_gh_bot_token="${GH_BOT_TOKEN:-}"
  local lib_dir

  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=vstack-env.sh
  source "$lib_dir/vstack-env.sh"
  vstack_load_project_env "$project_root"

  if [[ -n "$caller_gh_token_set" ]]; then
    export GH_TOKEN="$caller_gh_token"
  fi
  if [[ -n "$caller_github_token_set" ]]; then
    export GITHUB_TOKEN="$caller_github_token"
  fi
  if [[ -n "$caller_gh_bot_token_set" ]]; then
    export GH_BOT_TOKEN="$caller_gh_bot_token"
  fi
}

vstack_github_load_token() {
  local project_root="${1:?vstack_github_load_token: project_root required}"
  local mode="${2:-default}"
  local token=""
  local resolved=""

  token="$(vstack_github_select_auth_token "$mode" || true)"
  if [[ -z "$token" || "$token" == op://* ]]; then
    token=$(
      set +u
      local lib_dir
      lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
      # shellcheck source=vstack-env.sh
      source "$lib_dir/vstack-env.sh" >/dev/null 2>&1 || true
      vstack_load_project_env "$project_root" >/dev/null 2>&1 || true
      vstack_github_select_auth_token "$mode" || true
    )
  fi

  [[ -n "$token" ]] || return 1
  if [[ "$token" == op://* ]]; then
    if vstack_github_resolve_op_reference_to_var "$token" "GitHub token" resolved; then
      token="$resolved"
    else
      return 1
    fi
  fi

  vstack_github_is_resolved_token "$token" || return 1
  printf '%s' "$token"
}
