#!/usr/bin/env bash
# A configured claim path that is a file must not appear to be an empty store.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
# shellcheck source=lib/assertions.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/assertions.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
touch "$SCRATCH/claims"
source "$ROOT/skills/orch/scripts/lib/lane-claims.sh"
rc=0
lane_claims_read "$SCRATCH/claims" >"$SCRATCH/out" 2>"$SCRATCH/err" || rc=$?
assert_eq "$rc" "2" "a claim path that is a file is refused" "$SCRATCH/err"
assert_eq "$(wc -c <"$SCRATCH/out" | tr -d ' ')" "0" "and reads as no store at all"
assert_eq "$(sed -n '1p' "$SCRATCH/err")" "lane-claims: not-directory dir=$SCRATCH/claims" \
  "its first stderr line names the path"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
