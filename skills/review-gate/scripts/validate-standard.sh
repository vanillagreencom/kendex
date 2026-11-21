#!/usr/bin/env bash
# Keep the pre-2.0 entry point through the compatibility window.
set -euo pipefail
# Resolve the skills directory before the kernel follows a linked package:
# a sibling delivered as a copy sits beside the link, not beside its target.
skills_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -L)"
report="$skills_dir/github-repository-settings/scripts/validate-standard.sh"
printf '%s\n' 'review-gate-warning=deprecated-path replacement=.agents/skills/github-repository-settings/scripts/validate-standard.sh' >&2
if [ ! -x "$report" ]; then
  printf 'review-gate-error=standard-report-load value=%q\n' "$report" >&2
  exit 2
fi
exec "$report" --legacy-invocation "$@"
