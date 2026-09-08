#!/usr/bin/env bash
# A missing shared authentication helper must fail before any auth request.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
mkdir -p "$SCRATCH/skills/orch/scripts/lib"
cp "$ROOT/skills/orch/scripts/lib/gh-auth.sh" "$SCRATCH/skills/orch/scripts/lib/"
rc=0
bash -c 'source "$1"' bash "$SCRATCH/skills/orch/scripts/lib/gh-auth.sh" >"$SCRATCH/out" 2>"$SCRATCH/err" || rc=$?
[[ "$rc" -eq 1 && ! -s "$SCRATCH/out" ]]
[[ "$(sed -n '1p' "$SCRATCH/err")" == "gh-auth: helper-missing path=$SCRATCH/skills/orch/scripts/lib/../../../github/scripts/lib/gh-auth.sh" ]]
printf 'gh-auth messages: pass\n'
