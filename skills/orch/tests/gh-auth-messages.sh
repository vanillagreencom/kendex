#!/usr/bin/env bash
# A missing shared authentication helper must fail before any auth request.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
# shellcheck source=lib/assertions.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/assertions.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
mkdir -p "$SCRATCH/skills/orch/scripts/lib"
cp "$ROOT/skills/orch/scripts/lib/gh-auth.sh" "$SCRATCH/skills/orch/scripts/lib/"
rc=0
bash -c 'source "$1"' bash "$SCRATCH/skills/orch/scripts/lib/gh-auth.sh" >"$SCRATCH/out" 2>"$SCRATCH/err" || rc=$?
assert_eq "$rc" "1" "a missing shared helper fails at source time" "$SCRATCH/err"
assert_eq "$(wc -c <"$SCRATCH/out" | tr -d ' ')" "0" "and prints nothing on stdout"
assert_eq "$(sed -n '1p' "$SCRATCH/err")" "gh-auth: helper-missing path=$SCRATCH/skills/orch/scripts/lib/../../../github/scripts/lib/gh-auth.sh" \
  "its first stderr line names the missing helper"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
