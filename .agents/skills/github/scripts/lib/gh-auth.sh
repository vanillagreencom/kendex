#!/usr/bin/env bash
# Shared GitHub auth helpers for kendex skill scripts.
#
# Source this file; do not execute it directly.

kendex_github_is_resolved_token() {
  local token="${1:-}"
  [[ -n "$token" && "$token" != op://* ]] || return 1
  [[ "$token" =~ ^gh[pours]_ ]] || [[ "$token" =~ ^github_pat_ ]]
}

_GH_AUTH_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bounded.sh
source "$_GH_AUTH_LIB_DIR/bounded.sh"
unset _GH_AUTH_LIB_DIR

kendex_github_has_env_token() {
  [[ -n "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]]
}

kendex_github_token_auth_status() {
  kendex_github_has_env_token || return 1
  local auth_timeout="${KENDEX_GITHUB_AUTH_TIMEOUT:-10}"
  kendex_github_run_bounded "$auth_timeout" gh api user --jq '.login' >/dev/null 2>&1
}

kendex_github_token_auth_status_capture() {
  local auth_timeout="$1"
  local stdout_file="$2"
  local stderr_file="$3"

  kendex_github_has_env_token || return 1
  kendex_github_run_bounded_capture "$auth_timeout" "$stdout_file" "$stderr_file" gh api user --jq '.login'
}

kendex_github_auth_status() {
  local auth_timeout="${KENDEX_GITHUB_AUTH_TIMEOUT:-10}"

  if kendex_github_has_env_token; then
    kendex_github_token_auth_status
    return $?
  fi

  kendex_github_run_bounded "$auth_timeout" gh auth status >/dev/null 2>&1
}

kendex_github_auth_status_capture() {
  local auth_timeout="$1"
  local stdout_file="$2"
  local stderr_file="$3"

  if kendex_github_has_env_token; then
    kendex_github_token_auth_status_capture "$auth_timeout" "$stdout_file" "$stderr_file"
    return $?
  fi

  kendex_github_run_bounded_capture "$auth_timeout" "$stdout_file" "$stderr_file" gh auth status
}

kendex_github_keyring_auth_status() {
  local auth_timeout="${KENDEX_GITHUB_AUTH_TIMEOUT:-10}"
  kendex_github_run_bounded "$auth_timeout" env -u GH_TOKEN -u GITHUB_TOKEN gh auth status >/dev/null 2>&1
}

kendex_github_resolve_op_reference_to_var() {
  local ref="${1:?kendex_github_resolve_op_reference: ref required}"
  local label="${2:-GitHub token}"
  local out_var="${3:?kendex_github_resolve_op_reference: output var required}"
  local op_timeout="${KENDEX_GITHUB_OP_TIMEOUT:-10}"
  local op_output="" op_status=0

  if ! command -v op >/dev/null 2>&1; then
    export KENDEX_GITHUB_TOKEN_ERROR_TYPE="token_resolution_unavailable"
    export KENDEX_GITHUB_TOKEN_ERROR="${label} is a 1Password reference but 'op' CLI is not available"
    return 1
  fi

  op_output=$(kendex_github_run_bounded "$op_timeout" op read "$ref" 2>&1) || op_status=$?

  if [[ "$op_status" -eq 0 && -n "$op_output" ]]; then
    printf -v "$out_var" '%s' "$op_output"
    return 0
  fi

  case "$op_status" in
    124)
      export KENDEX_GITHUB_TOKEN_ERROR_TYPE="token_resolution_timeout"
      export KENDEX_GITHUB_TOKEN_ERROR="Timed out resolving ${label} 1Password reference after ${op_timeout}s"
      ;;
    *)
      export KENDEX_GITHUB_TOKEN_ERROR_TYPE="token_resolution_failed"
      export KENDEX_GITHUB_TOKEN_ERROR="Failed to resolve ${label} 1Password reference"
      ;;
  esac
  if [[ -n "$op_output" ]]; then
    export KENDEX_GITHUB_TOKEN_ERROR_DETAIL="$(printf '%s' "$op_output" | head -c 500 | tr '\n' ' ')"
  fi
  return 1
}

kendex_github_sanitize_gh_env() {
  command -v gh >/dev/null 2>&1 || return 0
  [[ -z "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]] && return 0
  local auth_status=0
  if kendex_github_auth_status; then
    return 0
  else
    auth_status=$?
  fi
  [[ "$auth_status" -eq 124 ]] && return 0
  if [[ "${KENDEX_GITHUB_SELECTED_TOKEN_SOURCE:-}" == "GH_BOT_TOKEN" ]]; then
    return 0
  fi
  if kendex_github_keyring_auth_status; then
    echo "Warning: GH_TOKEN/GITHUB_TOKEN failed gh auth; unsetting them and using gh keyring auth." >&2
    unset GH_TOKEN GITHUB_TOKEN
    export KENDEX_GITHUB_AUTH_FALLBACK="keyring"
  fi
  return 0
}

kendex_github_select_auth_token() {
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
    if kendex_github_is_resolved_token "$token"; then
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

kendex_github_apply_selected_auth_token() {
  local mode="${1:-default}"
  local -a order
  local var_name token="" selected_var="" resolved=""

  unset KENDEX_GITHUB_SELECTED_TOKEN_SOURCE
  case "$mode" in
    bot) order=(GH_BOT_TOKEN GH_TOKEN GITHUB_TOKEN) ;;
    bot-only) order=(GH_BOT_TOKEN) ;;
    router) order=(GH_TOKEN GH_BOT_TOKEN GITHUB_TOKEN) ;;
    user) order=(GH_TOKEN GITHUB_TOKEN) ;;
    *) order=(GH_TOKEN GITHUB_TOKEN GH_BOT_TOKEN) ;;
  esac

  for var_name in "${order[@]}"; do
    token="${!var_name:-}"
    if kendex_github_is_resolved_token "$token"; then
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
    if ! kendex_github_resolve_op_reference_to_var "$token" "GitHub token" resolved; then
      unset GH_TOKEN GITHUB_TOKEN
      return 1
    fi
    token="$resolved"
  fi

  if kendex_github_is_resolved_token "$token"; then
    export GH_TOKEN="$token"
    unset GITHUB_TOKEN
    export KENDEX_GITHUB_SELECTED_TOKEN_SOURCE="$selected_var"
    return 0
  fi

  return 1
}

kendex_github_load_project_env_preserving_caller() {
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
  # shellcheck source=kendex-env.sh
  source "$lib_dir/kendex-env.sh"
  local load_status=0
  kendex_load_project_env "$project_root" || load_status=$?
  if [[ "$load_status" -ne 0 ]]; then
    # A FAILED load supplies no token: the loader stops before .env.local,
    # so a value exported ahead of the bad line would beat the personal
    # override that outranks it. Its ::error stays on stderr; caller-held
    # values come back below.
    unset GH_TOKEN GITHUB_TOKEN GH_BOT_TOKEN
  fi

  if [[ -n "$caller_gh_token_set" ]]; then
    export GH_TOKEN="$caller_gh_token"
  fi
  if [[ -n "$caller_github_token_set" ]]; then
    export GITHUB_TOKEN="$caller_github_token"
  fi
  if [[ -n "$caller_gh_bot_token_set" ]]; then
    export GH_BOT_TOKEN="$caller_gh_bot_token"
  fi
  return "$load_status"
}

kendex_github_load_token() {
  local project_root="${1:?kendex_github_load_token: project_root required}"
  local mode="${2:-default}"
  local token=""
  local resolved=""

  token="$(kendex_github_select_auth_token "$mode" || true)"
  if [[ -z "$token" || "$token" == op://* ]]; then
    token=$(
      set +u
      local lib_dir
      lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
      # shellcheck source=kendex-env.sh
      # || true keeps token absence best-effort, but stderr stays open: the
      # loader can refuse a malformed settings file, and discarding its
      # ::error leaves a bare no-token failure blaming auth for a settings
      # defect. A FAILED load emits NO token (exit the subshell empty): a
      # value exported ahead of the bad line would beat the .env.local
      # override the ladder promises wins.
      source "$lib_dir/kendex-env.sh" >/dev/null || true
      kendex_load_project_env "$project_root" >/dev/null || exit 0
      kendex_github_select_auth_token "$mode" || true
    )
  fi

  [[ -n "$token" ]] || return 1
  if [[ "$token" == op://* ]]; then
    if kendex_github_resolve_op_reference_to_var "$token" "GitHub token" resolved; then
      token="$resolved"
    else
      return 1
    fi
  fi

  kendex_github_is_resolved_token "$token" || return 1
  printf '%s' "$token"
}

kendex_github_git_url_is_github_ssh() {
  local url="${1:-}"
  case "$url" in
    git@github.com:*|git@github-*:*)
      return 0
      ;;
    ssh://git@github.com/*|ssh://git@github.com:*/*|ssh://git@github-*/*|ssh://git@github-*:*)
      return 0
      ;;
  esac
  return 1
}

kendex_github_git_args_have_github_ssh_url() {
  local arg
  for arg in "$@"; do
    if kendex_github_git_url_is_github_ssh "$arg"; then
      return 0
    fi
  done
  return 1
}

kendex_github_git_work_dir_from_args() {
  local cwd="$PWD"
  local value

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -C)
        shift
        [[ $# -gt 0 ]] || break
        value="$1"
        if [[ "$value" == /* ]]; then
          cwd="$value"
        else
          cwd="$cwd/$value"
        fi
        shift
        ;;
      -C*)
        value="${1#-C}"
        if [[ "$value" == /* ]]; then
          cwd="$value"
        else
          cwd="$cwd/$value"
        fi
        shift
        ;;
      -c|--git-dir|--work-tree|--namespace)
        shift
        [[ $# -gt 0 ]] || break
        shift
        ;;
      --)
        shift
        break
        ;;
      -*)
        shift
        ;;
      *)
        break
        ;;
    esac
  done

  printf '%s\n' "$cwd"
}

kendex_github_git_repo_has_github_ssh_remote() {
  local repo="${1:-.}"
  local remotes remote url

  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || return 1
  remotes="$(git -C "$repo" remote 2>/dev/null || true)"
  [[ -n "$remotes" ]] || return 1

  while IFS= read -r remote; do
    [[ -n "$remote" ]] || continue

    while IFS= read -r url; do
      [[ -n "$url" ]] || continue
      if kendex_github_git_url_is_github_ssh "$url"; then
        return 0
      fi
    done < <(git -C "$repo" remote get-url --all "$remote" 2>/dev/null || true)

    while IFS= read -r url; do
      [[ -n "$url" ]] || continue
      if kendex_github_git_url_is_github_ssh "$url"; then
        return 0
      fi
    done < <(git -C "$repo" remote get-url --push --all "$remote" 2>/dev/null || true)
  done <<<"$remotes"

  return 1
}

kendex_github_git_should_use_https_fallback() {
  local mode="${KENDEX_GITHUB_GIT_HTTPS_FALLBACK:-auto}"
  local work_dir

  case "$mode" in
    never|false|off|0)
      return 1
      ;;
    always|true|on|1)
      return 0
      ;;
    auto|"")
      ;;
    *)
      echo "Warning: Unknown KENDEX_GITHUB_GIT_HTTPS_FALLBACK='$mode'; using auto." >&2
      ;;
  esac

  if kendex_github_git_args_have_github_ssh_url "$@"; then
    return 0
  fi

  work_dir="$(kendex_github_git_work_dir_from_args "$@")"
  kendex_github_git_repo_has_github_ssh_remote "$work_dir"
}

kendex_github_git_https_auth_available() {
  command -v gh >/dev/null 2>&1 || return 1
  kendex_github_apply_selected_auth_token router >/dev/null 2>&1 || true
  kendex_github_sanitize_gh_env || true
  kendex_github_auth_status
}

kendex_github_git_collect_https_rewrites() {
  local work_dir="$1"
  shift

  printf '%s\n' 'git@github.com:'
  printf '%s\n' 'ssh://git@github.com/'
  printf '%s\n' 'ssh://git@github.com:22/'
  printf '%s\n' 'ssh://git@github.com:443/'

  local arg remote url host
  for arg in "$@"; do
    if [[ "$arg" =~ ^git@(github[^:]*): ]]; then
      printf 'git@%s:\n' "${BASH_REMATCH[1]}"
    elif [[ "$arg" =~ ^ssh://git@(github[^/:]*)(:[0-9]+)?/ ]]; then
      host="${BASH_REMATCH[1]}"
      printf 'ssh://git@%s/\n' "$host"
      printf 'ssh://git@%s:22/\n' "$host"
      printf 'ssh://git@%s:443/\n' "$host"
    fi
  done

  if git -C "$work_dir" rev-parse --git-dir >/dev/null 2>&1; then
    while IFS= read -r remote; do
      [[ -n "$remote" ]] || continue
      while IFS= read -r url; do
        [[ -n "$url" ]] || continue
        if [[ "$url" =~ ^git@(github[^:]*): ]]; then
          printf 'git@%s:\n' "${BASH_REMATCH[1]}"
        elif [[ "$url" =~ ^ssh://git@(github[^/:]*)(:[0-9]+)?/ ]]; then
          host="${BASH_REMATCH[1]}"
          printf 'ssh://git@%s/\n' "$host"
          printf 'ssh://git@%s:22/\n' "$host"
          printf 'ssh://git@%s:443/\n' "$host"
        fi
      done < <(
        {
          git -C "$work_dir" remote get-url --all "$remote" 2>/dev/null || true
          git -C "$work_dir" remote get-url --push --all "$remote" 2>/dev/null || true
        } | awk 'NF && !seen[$0]++'
      )
    done < <(git -C "$work_dir" remote 2>/dev/null || true)
  fi
}

kendex_github_git() {
  if kendex_github_git_should_use_https_fallback "$@" && kendex_github_git_https_auth_available; then
    local work_dir rewrite
    local -a git_args
    work_dir="$(kendex_github_git_work_dir_from_args "$@")"
    git_args=(-c credential.helper= -c credential.helper='!gh auth git-credential')
    while IFS= read -r rewrite; do
      [[ -n "$rewrite" ]] || continue
      git_args+=(-c "url.https://github.com/.insteadOf=$rewrite")
    done < <(kendex_github_git_collect_https_rewrites "$work_dir" "$@" | awk 'NF && !seen[$0]++')

    git "${git_args[@]}" "$@"
    return $?
  fi

  git "$@"
}
