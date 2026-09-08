#!/usr/bin/env bash
# Stable message records are one line even when a path contains control bytes.
worktree_message() {
  local value="$2"
  value="${value//\\/\\\\}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf 'worktree-%s: %s\n' "$1" "$value"
  if [[ $# -gt 2 ]]; then printf '  %s\n' "$3"; fi
}
