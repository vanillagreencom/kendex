#!/usr/bin/env bash
# Regression tests for orchestration/scripts/flightdeck-mode.
#
# Verifies the managed-mode detection surface used by merge-pr.md § 5
# to scope cleanup to the current issue's artifacts.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
SCRIPT="$REPO_ROOT/skills/orchestration/scripts/flightdeck-mode"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

assert_eq() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$name" "$want" "$got"
  fi
}

assert_exit() {
  local code="$1" want="$2" name="$3"
  if [[ "$code" == "$want" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected exit: %s\n        got exit:      %s\n' "$name" "$want" "$code"
  fi
}

# Build a minimal git repo with an orchestration workflow-state file so
# we can exercise scope resolution from disk.
REPO="$TMP_ROOT/repo"
mkdir -p "$REPO/tmp"
git -C "$(dirname "$REPO")" init -q "$(basename "$REPO")"
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name Test
git -C "$REPO" checkout -q -b issue-99
git -C "$REPO" commit -q --allow-empty -m init

cat >"$REPO/tmp/workflow-state-PROJ-99.json" <<EOF
{
  "issue_id": "PROJ-99",
  "agent": "rust",
  "worktree": "$REPO",
  "branch": "issue-99",
  "team_name": "proj-99"
}
EOF

run() {
  # Run flightdeck-mode in REPO with a clean env (no inherited
  # FLIGHTDECK_* variables from the caller's tmux session).
  (
    cd "$REPO"
    env -u FLIGHTDECK_CHILD_PANE \
        -u FLIGHTDECK_MANAGED \
        -u FLIGHTDECK_STATE_DIR \
        -u ORCH_STATE_DIR \
        -u TMUX \
        "$SCRIPT" "$@"
  )
}

run_with() {
  local key="$1" val="$2"
  shift 2
  (
    cd "$REPO"
    env -u FLIGHTDECK_CHILD_PANE \
        -u FLIGHTDECK_MANAGED \
        -u FLIGHTDECK_STATE_DIR \
        -u ORCH_STATE_DIR \
        -u TMUX \
        "$key=$val" \
        "$SCRIPT" "$@"
  )
}

echo "=== flightdeck-mode detection ==="

set +e
run check >/dev/null 2>&1
code=$?
set -e
assert_exit "$code" "1" "no signals -> check exits 1"

set +e
run_with FLIGHTDECK_CHILD_PANE 1 check >/dev/null 2>&1
code=$?
set -e
assert_exit "$code" "0" "FLIGHTDECK_CHILD_PANE=1 -> check exits 0"

set +e
run_with FLIGHTDECK_MANAGED 1 check >/dev/null 2>&1
code=$?
set -e
assert_exit "$code" "0" "FLIGHTDECK_MANAGED=1 -> check exits 0"

echo "=== flightdeck-mode scope resolution ==="

# workflow-state authoritative for issue id / worktree / branch
out=$(run current-issue)
assert_eq "$out" "PROJ-99" "current-issue reads workflow-state"

out=$(run current-branch)
assert_eq "$out" "issue-99" "current-branch reads workflow-state"

out=$(run current-worktree)
assert_eq "$out" "$REPO" "current-worktree reads workflow-state"

# scope-json shape sanity
out=$(run scope-json | jq -r '.managed')
assert_eq "$out" "false" "scope-json managed=false without signal"
out=$(run_with FLIGHTDECK_CHILD_PANE 1 scope-json | jq -r '.managed')
assert_eq "$out" "true" "scope-json managed=true with child-pane env"
out=$(run scope-json | jq -r '.issue_id')
assert_eq "$out" "PROJ-99" "scope-json carries scoped issue id"

echo "=== flightdeck-mode match-branch guard ==="

set +e
run match-branch issue-99 >/dev/null 2>&1
code=$?
set -e
assert_exit "$code" "0" "match-branch accepts scoped branch"

set +e
run match-branch orch/method-20260427T141609 >/dev/null 2>&1
code=$?
set -e
assert_exit "$code" "1" "match-branch refuses unrelated branch (the issue #18 scenario)"

set +e
run match-branch '' >/dev/null 2>&1
code=$?
set -e
assert_exit "$code" "2" "match-branch with empty arg exits 2"

echo "=== flightdeck-mode match-worktree guard ==="

set +e
run match-worktree "$REPO" >/dev/null 2>&1
code=$?
set -e
assert_exit "$code" "0" "match-worktree accepts scoped worktree"

set +e
run match-worktree "$TMP_ROOT" >/dev/null 2>&1
code=$?
set -e
assert_exit "$code" "1" "match-worktree refuses unrelated path"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
