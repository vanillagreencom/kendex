#!/usr/bin/env bash
# A configured claim path that is a file must not appear to be an empty store.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
touch "$SCRATCH/claims"
source "$ROOT/skills/orch/scripts/lib/lane-claims.sh"
rc=0
lane_claims_read "$SCRATCH/claims" >"$SCRATCH/out" 2>"$SCRATCH/err" || rc=$?
[[ "$rc" -eq 2 && ! -s "$SCRATCH/out" ]]
[[ "$(sed -n '1p' "$SCRATCH/err")" == "lane-claims: not-directory dir=$SCRATCH/claims" ]]
printf 'lane-claims messages: pass\n'
