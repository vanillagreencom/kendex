#!/usr/bin/env bash
# Keep the pre-2.0 entry point through the compatibility window.
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
report="$script_dir/../../github-repository-settings/scripts/validate-standard.sh"
printf '%s\n' 'review-gate-warning=deprecated-path replacement=.agents/skills/github-repository-settings/scripts/validate-standard.sh' >&2
if [ ! -x "$report" ]; then
  printf 'review-gate-error=standard-report-load value=%q\n' "$report" >&2
  exit 2
fi
exec "$report" --legacy-invocation "$@"
