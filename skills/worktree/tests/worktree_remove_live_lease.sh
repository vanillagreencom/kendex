#!/usr/bin/env bash
# `remove <ID>` derives a lease-release identity from the issue ID (#907) — an
# identity ANY session naming that issue can produce — so before trusting it
# the release asks whether the claiming session is still alive. The lease
# records the claiming process's pid and host: a live unrelated pid on this
# host refuses the removal (`remove --force` overrides), while a dead pid or
# an ancestor of the removing process proceeds exactly as before.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKTREE_PACKAGE_DIR="$(cd "$TEST_DIR/.." && pwd)"
WORKTREE_SCRIPT="$WORKTREE_PACKAGE_DIR/scripts/worktree"
GUARD_SCRIPT="$WORKTREE_PACKAGE_DIR/scripts/worktree-session-guard"

TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
SLEEPER_PID=""
cleanup() {
  [[ -n "$SLEEPER_PID" ]] && kill "$SLEEPER_PID" 2>/dev/null
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }

assert_eq() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" == "$want" ]]; then
    pass "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$name" "$want" "$got"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" name="$3"
  if grep -qF -- "$needle" <<<"$haystack"; then
    pass "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        wanted substring: %s\n        in: %s\n' "$name" "$needle" "$haystack"
  fi
}

assert_path_exists() {
  [[ -e "$1" ]] && pass "$2" || fail "$2 (missing: $1)"
}

assert_path_absent() {
  [[ ! -e "$1" ]] && pass "$2" || fail "$2 (still exists: $1)"
}

# Exit code of `guard status`: 0 ours, 3 no lock, 4 non-guard lock, 75 foreign.
guard_status_code() {
  local wt="$1" repo="$2" rc=0
  shift 2
  "$GUARD_SCRIPT" status "$wt" --repo "$repo" "$@" >/dev/null 2>&1 || rc=$?
  printf '%s' "$rc"
}

make_repo() {
  local repo="$1"
  mkdir -p "$repo"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name Test
  git -C "$repo" config commit.gpgsign false
  printf 'base\n' > "$repo/file.txt"
  git -C "$repo" add file.txt
  git -C "$repo" commit -q -m base
}

# The guard records the claiming process's own pid, which is transient. The
# scenario under test is a lease whose recorded pid belongs to a still-running
# session, so the pid is rewritten in place in the registration's lock file —
# the same file `git worktree lock --reason` wrote the lease to.
plant_lease_pid() {
  local lock_file="$1" pid="$2"
  sed "s/ pid=[0-9]* / pid=$pid /" "$lock_file" > "$lock_file.planted"
  mv "$lock_file.planted" "$lock_file"
}

echo "=== a live foreign session's issue-keyed lease refuses remove <ID> ==="

ROOT="$TMP_ROOT/live"
make_repo "$ROOT/main"
git -C "$ROOT/main" worktree add -q -b issue-live "$ROOT/trees/issue-live" main
LIVE_WT="$ROOT/trees/issue-live"
"$GUARD_SCRIPT" claim "$LIVE_WT" --owner issue-live >/dev/null
sleep 300 &
SLEEPER_PID=$!
plant_lease_pid "$ROOT/main/.git/worktrees/issue-live/locked" "$SLEEPER_PID"

set +e
live_out=$(cd "$ROOT/main" && env -u VSTACK_SESSION_OWNER -u HT_SESSION_OWNER \
  "$WORKTREE_SCRIPT" remove issue-live 2>"$ROOT/live.err")
live_code=$?
set -e
live_err="$(cat "$ROOT/live.err")"
assert_eq "$live_code" "1" "remove <ID> under a live foreign lease exits nonzero"
assert_contains "$live_err" "claimed by a live session" \
  "the refusal says the claiming session is still running"
assert_contains "$live_err" "(owner=issue-live pid=$SLEEPER_PID)" \
  "the refusal names the owner and the live pid"
assert_contains "$live_err" "remove \"issue-live\" --force" \
  "the refusal names the --force way out"
assert_contains "$live_err" "release \"$LIVE_WT\" --owner \"issue-live\"" \
  "the refusal names the guard's own release command"
if grep -qF "Removed:" <<<"$live_out"; then
  fail "a refused remove does not report a removal"
else
  pass "a refused remove does not report a removal"
fi
assert_path_exists "$LIVE_WT" "the live session's worktree survives"
assert_eq "$(guard_status_code "$LIVE_WT" "$ROOT/main" --owner issue-live)" "0" \
  "the live session's lease survives"

echo "=== remove <ID> --force overrides only the liveness refusal ==="

set +e
force_out=$(cd "$ROOT/main" && env -u VSTACK_SESSION_OWNER -u HT_SESSION_OWNER \
  "$WORKTREE_SCRIPT" remove issue-live --force 2>"$ROOT/force.err")
force_code=$?
set -e
assert_eq "$force_code" "0" "remove --force under a live foreign lease exits 0"
assert_contains "$force_out" "Removed: $LIVE_WT" "remove --force reports the removal"
assert_contains "$(cat "$ROOT/force.err")" "Released session guard lease (owner=issue-live)" \
  "remove --force releases the lease rather than bypassing the guard"
assert_path_absent "$LIVE_WT" "the worktree is gone after --force"
kill "$SLEEPER_PID" 2>/dev/null || true
wait "$SLEEPER_PID" 2>/dev/null || true
SLEEPER_PID=""

echo "=== a dead recorded pid proceeds as before ==="

DEAD_ROOT="$TMP_ROOT/dead"
make_repo "$DEAD_ROOT/main"
git -C "$DEAD_ROOT/main" worktree add -q -b issue-dead "$DEAD_ROOT/trees/issue-dead" main
DEAD_WT="$DEAD_ROOT/trees/issue-dead"
"$GUARD_SCRIPT" claim "$DEAD_WT" --owner issue-dead >/dev/null
sleep 300 &
DEAD_PID=$!
kill "$DEAD_PID"
wait "$DEAD_PID" 2>/dev/null || true
plant_lease_pid "$DEAD_ROOT/main/.git/worktrees/issue-dead/locked" "$DEAD_PID"

set +e
dead_out=$(cd "$DEAD_ROOT/main" && env -u VSTACK_SESSION_OWNER -u HT_SESSION_OWNER \
  "$WORKTREE_SCRIPT" remove issue-dead 2>"$DEAD_ROOT/dead.err")
dead_code=$?
set -e
assert_eq "$dead_code" "0" "remove <ID> with a dead recorded pid exits 0"
assert_contains "$dead_out" "Removed: $DEAD_WT" "the dead-pid removal reports the removal"
assert_contains "$(cat "$DEAD_ROOT/dead.err")" "Released session guard lease (owner=issue-dead)" \
  "the dead-pid lease is released as the issue identity"
assert_path_absent "$DEAD_WT" "the dead-pid worktree is gone"

echo "=== a recorded pid on our own ancestor chain proceeds ==="

ANC_ROOT="$TMP_ROOT/ancestor"
make_repo "$ANC_ROOT/main"
git -C "$ANC_ROOT/main" worktree add -q -b issue-anc "$ANC_ROOT/trees/issue-anc" main
ANC_WT="$ANC_ROOT/trees/issue-anc"
"$GUARD_SCRIPT" claim "$ANC_WT" --owner issue-anc >/dev/null
# This test shell is an ancestor of the remove invocation below, standing in
# for the claiming session that later removes its own worktree.
plant_lease_pid "$ANC_ROOT/main/.git/worktrees/issue-anc/locked" "$$"

set +e
anc_out=$(cd "$ANC_ROOT/main" && env -u VSTACK_SESSION_OWNER -u HT_SESSION_OWNER \
  "$WORKTREE_SCRIPT" remove issue-anc 2>"$ANC_ROOT/anc.err")
anc_code=$?
set -e
assert_eq "$anc_code" "0" "remove <ID> with a live ancestor pid exits 0"
assert_contains "$anc_out" "Removed: $ANC_WT" "the ancestor-pid removal reports the removal"
assert_contains "$(cat "$ANC_ROOT/anc.err")" "Released session guard lease (owner=issue-anc)" \
  "the ancestor-pid lease is released as the issue identity"
assert_path_absent "$ANC_WT" "the ancestor-pid worktree is gone"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
