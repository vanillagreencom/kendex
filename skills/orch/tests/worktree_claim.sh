#!/usr/bin/env bash
# Regression tests for the orchestration wrapper over the worktree lease.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
CLAIM="$REPO_ROOT/skills/orch/scripts/worktree-claim"
GUARD="$REPO_ROOT/skills/worktree/scripts/worktree-session-guard"
export WORKTREE_SESSION_GUARD="$GUARD"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
assert_eq() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" == "$want" ]]; then pass "$name"; else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$name" "$want" "$got"
  fi
}

run_out="$TMP_ROOT/run.out"
run_err="$TMP_ROOT/run.err"
RUN_RC=0
run_claim() {
  RUN_RC=0
  "$CLAIM" "$@" >"$run_out" 2>"$run_err" || RUN_RC=$?
}

main_repo="$TMP_ROOT/repo"
git init -q "$main_repo"
git -C "$main_repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m seed
wt_a="$TMP_ROOT/wt-a"
wt_b="$TMP_ROOT/wt-b"
wt_c="$TMP_ROOT/wt-c"
git -C "$main_repo" worktree add -q -b vst-1 "$wt_a"
git -C "$main_repo" worktree add -q -b vst-2 "$wt_b"
git -C "$main_repo" worktree add -q -b vst-3 "$wt_c"

echo '=== controls ==='
run_claim --worktree "$main_repo" --issue VST-1
assert_eq "$RUN_RC" "1" "main checkout is refused, proving the guard runs"
WORKTREE_SESSION_GUARD="$TMP_ROOT/missing" run_claim --worktree "$wt_a" --issue VST-1
assert_eq "$RUN_RC" "1" "an unavailable guard fails closed"

echo '=== usage ==='
run_claim --worktree "$wt_a"
assert_eq "$RUN_RC" "1" "missing issue is rejected"
run_claim --issue VST-1
assert_eq "$RUN_RC" "1" "missing worktree is rejected"
run_claim --worktree "$wt_a" --issue VST-1 --bogus
assert_eq "$RUN_RC" "1" "unknown option is rejected"
run_claim --worktree "$wt_a" --issue VST-1 --state-dir "$TMP_ROOT/state"
assert_eq "$RUN_RC" "1" "--state-dir is rejected rather than accepted and discarded"

echo '=== claim and refresh ==='
run_claim --worktree "$wt_a" --issue VST-1
assert_eq "$RUN_RC" "0" "an unleased worktree is claimed"
assert_eq "$(cat "$run_out")" "VST-1" "stdout carries the lease owner"
before="$("$GUARD" status "$wt_a" --owner VST-1 | sed -n 's/.*"heartbeat_at":"\([^"]*\)".*/\1/p')"
sleep 1
run_claim --worktree "$wt_a" --issue VST-1
assert_eq "$RUN_RC" "0" "the same owner refreshes its lease"
after="$("$GUARD" status "$wt_a" --owner VST-1 | sed -n 's/.*"heartbeat_at":"\([^"]*\)".*/\1/p')"
if [[ -n "$before" && "$after" > "$before" ]]; then pass "refresh advances the heartbeat"; else fail "refresh advances the heartbeat"; fi

echo '=== foreign holders ==='
"$GUARD" claim "$wt_b" --owner VST-2 >/dev/null
run_claim --worktree "$wt_b" --issue VST-1
assert_eq "$RUN_RC" "75" "a different lease owner is refused"
status_rc=0
"$GUARD" status "$wt_b" --owner VST-2 >/dev/null 2>&1 || status_rc=$?
assert_eq "$status_rc" "0" "the foreign lease remains in place"
git -C "$main_repo" worktree lock --reason external "$wt_c"
run_claim --worktree "$wt_c" --issue VST-3
assert_eq "$RUN_RC" "75" "a native lock outside the guard is refused"

echo '=== released lease ==='
"$GUARD" release "$wt_a" --owner VST-1 >/dev/null
run_claim --worktree "$wt_a" --issue VST-1
assert_eq "$RUN_RC" "0" "a released worktree can be claimed again"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
