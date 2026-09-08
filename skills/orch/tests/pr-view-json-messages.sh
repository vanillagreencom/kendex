#!/usr/bin/env bash
# A partial skill installation must identify the missing GitHub helper.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
mkdir -p "$SCRATCH/skills/orch/scripts"
cp "$ROOT/skills/orch/scripts/pr-view-json" "$SCRATCH/skills/orch/scripts/"
rc=0
"$SCRATCH/skills/orch/scripts/pr-view-json" >"$SCRATCH/out" 2>"$SCRATCH/err" || rc=$?
[[ "$rc" -eq 1 && ! -s "$SCRATCH/out" ]]
[[ "$(sed -n '1p' "$SCRATCH/err")" == "pr-view-json: helper-missing github=$SCRATCH/skills/github/scripts/github.sh" ]]
printf 'pr-view-json messages: pass\n'
