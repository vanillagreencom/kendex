#!/usr/bin/env bash
# A partial skill installation must identify the missing GitHub helper.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
# shellcheck source=lib/assertions.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/assertions.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
mkdir -p "$SCRATCH/skills/orch/scripts"
cp "$ROOT/skills/orch/scripts/pr-view-json" "$SCRATCH/skills/orch/scripts/"
rc=0
"$SCRATCH/skills/orch/scripts/pr-view-json" >"$SCRATCH/out" 2>"$SCRATCH/err" || rc=$?
assert_eq "$rc" "1" "a missing GitHub helper exits 1" "$SCRATCH/err"
assert_eq "$(wc -c <"$SCRATCH/out" | tr -d ' ')" "0" "and prints nothing on stdout"
assert_eq "$(sed -n '1p' "$SCRATCH/err")" "pr-view-json: helper-missing github=$SCRATCH/skills/github/scripts/github.sh" \
  "its first stderr line names the missing helper"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
