#!/usr/bin/env bash
# Compatibility for consumers before 2.0; remove at the next major release.
set -euo pipefail
printf '%s\n' 'kendex-install: warning=deprecated-path replacement=.agents/skills/harness-ci/scripts/install-latest.sh' >&2
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$script_dir/../../harness-ci/scripts/install-latest.sh" "$@"
