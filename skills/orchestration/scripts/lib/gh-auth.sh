#!/usr/bin/env bash
# Shared auth helper for orchestration scripts that shell out to `gh`.
#
# Source this file; do not execute it directly.
#
# orchestration_sanitize_gh_env
#   Detect when GH_TOKEN/GITHUB_TOKEN are set but cause `gh` to fail auth,
#   while `gh` keyring auth would succeed with those variables unset. In
#   that case, emit a warning and unset both so subsequent `gh` calls in
#   the same shell fall back to the keyring.
#
#   No-op when:
#     - `gh` is not on PATH
#     - Neither GH_TOKEN nor GITHUB_TOKEN is set
#     - The current `gh auth status` already succeeds
#
#   Always returns 0. Callers that need a hard auth gate should re-check
#   `gh auth status` afterward and handle failure themselves.

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
