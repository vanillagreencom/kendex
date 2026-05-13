#!/usr/bin/env bash
# Shared auth helpers for orchestration scripts that shell out to `gh`.
#
# Source this file; do not execute it directly.
#
# Two functions are exposed. Together they form the auth-resolution ladder
# used by ci-wait and bot-review-wait:
#
#   1. orchestration_sanitize_gh_env
#      Detect when GH_TOKEN/GITHUB_TOKEN are set but cause `gh` to fail
#      auth, while `gh` keyring auth would succeed with those variables
#      unset. In that case, emit a warning and unset both so subsequent
#      `gh` calls in the same shell fall back to the keyring.
#
#      No-op when `gh` is missing, when no env tokens are set, or when
#      the current `gh auth status` already succeeds. Always returns 0.
#
#   2. orchestration_load_env_bot_token <project_root>
#      Look for `GH_BOT_TOKEN` in `<project_root>/.env.local` then
#      `<project_root>/.env` (`.env.local` wins). Resolve `op://`
#      references via `op read` when available. If the resolved value
#      looks like a GitHub token, export it as GH_TOKEN and return 0.
#      Returns 1 if nothing valid was found.
#
#      Implemented as a subshell `source` so unrelated `.env` variables
#      do not leak into the caller. Mirrors skills/github/scripts/github.sh.

orchestration_sanitize_gh_env() {
  command -v gh >/dev/null 2>&1 || return 0
  [[ -z "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]] && return 0
  if gh auth status >/dev/null 2>&1; then
    return 0
  fi
  if env -u GH_TOKEN -u GITHUB_TOKEN gh auth status >/dev/null 2>&1; then
    echo "Warning: GH_TOKEN/GITHUB_TOKEN failed gh auth; unsetting them and using gh keyring auth." >&2
    unset GH_TOKEN GITHUB_TOKEN
  fi
  return 0
}

orchestration_load_env_bot_token() {
  local project_root="${1:?orchestration_load_env_bot_token: project_root required}"
  local env_file resolved bot_token
  for env_file in "$project_root/.env.local" "$project_root/.env"; do
    [[ -f "$env_file" ]] || continue
    bot_token=$(
      set +u
      # shellcheck disable=SC1090
      source "$env_file" >/dev/null 2>&1 || true
      printf '%s' "${GH_BOT_TOKEN:-}"
    )
    [[ -n "$bot_token" ]] || continue
    if [[ "$bot_token" == op://* ]] && command -v op >/dev/null 2>&1; then
      resolved=$(op read "$bot_token" 2>/dev/null || true)
      [[ -n "$resolved" ]] && bot_token="$resolved"
    fi
    if [[ "$bot_token" =~ ^gh[pors]_ ]] || [[ "$bot_token" =~ ^github_pat_ ]]; then
      export GH_TOKEN="$bot_token"
      return 0
    fi
  done
  return 1
}
