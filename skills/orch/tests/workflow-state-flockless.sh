#!/usr/bin/env bash
# workflow-state's writes on a host with no flock(1).
#
# Every mutating subcommand runs its read-decide-write under a lock, because
# two `set` calls racing on one state file both read, both write, and the
# later write drops the earlier transition. flock is util-linux and stock
# macOS ships none, where the bare `flock -w 10 200` this used to run resolved
# to nothing, the `||` arm fired, and every write refused with "could not
# acquire lock" — so on that platform workflow-state did not work at all.
# scripts/lib/file-lock.sh carries the lock with a mkdir mutex there.
#
# The probe PATH is the real one minus flock rather than a list of the tools
# workflow-state uses, so it stays true as the script changes.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

WS="$REPO_ROOT/skills/orch/scripts/workflow-state"

# shellcheck source=lib/assertions.sh
source "$TEST_DIR/lib/assertions.sh"
# mutant_scripts and mutate_file, the two halves of the control below.
# shellcheck source=lib/growth-state.sh
source "$TEST_DIR/lib/growth-state.sh"

NOFLOCK="$TMP_ROOT/path-without-flock"
mkdir -p "$NOFLOCK"
(
  IFS=:
  for d in $PATH; do
    [[ -d "$d" ]] || continue
    ln -s "$d"/* "$NOFLOCK"/ 2>/dev/null || true
  done
)
rm -f -- "$NOFLOCK/flock"
# Without this every case below passes vacuously through the flock branch.
if PATH="$NOFLOCK" command -v flock >/dev/null 2>&1; then
  fail "the probe PATH resolves no flock" "flock is still reachable"
else
  pass "the probe PATH resolves no flock"
fi

echo
echo "--- workflow-state with no flock on PATH ---"

SD="$TMP_ROOT/state"
PATH="$NOFLOCK" "$WS" --state-dir "$SD" init KEN-LOCK --worktree "$REPO_ROOT" --branch ken-lock >/dev/null
rc=0
PATH="$NOFLOCK" "$WS" --state-dir "$SD" set KEN-LOCK phase implementing >/dev/null 2>"$TMP_ROOT/set.err" || rc=$?
[[ "$rc" -eq 0 ]] && pass "a set lands with no flock on PATH" \
  || fail "a set lands with no flock on PATH" "rc=$rc $(cat "$TMP_ROOT/set.err")"
got="$(PATH="$NOFLOCK" "$WS" --state-dir "$SD" get KEN-LOCK .phase)"
[[ "$got" == "implementing" ]] && pass "and the value it wrote is the one read back" \
  || fail "and the value it wrote is the one read back" "got=$got"

# The mutex directory is released, not leaked: a second write on the same file
# would otherwise wait its whole timeout and then refuse.
rc=0
PATH="$NOFLOCK" "$WS" --state-dir "$SD" set KEN-LOCK phase reviewing >/dev/null 2>"$TMP_ROOT/set2.err" || rc=$?
[[ "$rc" -eq 0 ]] && pass "a second write is not blocked by the first one's mutex" \
  || fail "a second write is not blocked by the first one's mutex" "rc=$rc $(cat "$TMP_ROOT/set2.err")"

# A final member count cannot tell a failed child from a lost successful write.
# Retain each actual result before judging the shared state.
racing_appends() { # WRITER NAME
  local writer="$1" race_sd="$TMP_ROOT/$2" go="$TMP_ROOT/$2.go"
  local racer rc members read_rc=0 evidence_rc=0 pids=() statuses=()
  PATH="$NOFLOCK" "$writer" --state-dir "$race_sd" init KEN-RACE --worktree "$REPO_ROOT" --branch ken-race >/dev/null || return 1
  for racer in 1 2; do
    (
      until [[ -e "$go" ]]; do :; done
      PATH="$NOFLOCK" "$writer" --state-dir "$race_sd" append KEN-RACE fixed_items "item-$racer" \
        >"$race_sd/racer-$racer.out" 2>"$race_sd/racer-$racer.err"
    ) &
    pids+=("$!")
  done
  sleep 0.4
  : >"$go"
  for racer in 1 2; do
    rc=0
    wait "${pids[racer-1]}" || rc=$?
    statuses+=("$rc")
    printf '%s\n' "$rc" >"$race_sd/racer-$racer.rc" || evidence_rc=1
    printf 'racer=%s pid=%s status=%s\n' "$racer" "${pids[racer-1]}" "$rc"
  done
  members="$(PATH="$NOFLOCK" "$writer" --state-dir "$race_sd" get KEN-RACE '.fixed_items | sort | @json' \
    2>"$race_sd/read.err")" || read_rc=$?
  printf '%s\n' "$members" >"$race_sd/members" || evidence_rc=1
  printf 'members=%s read-status=%s\n' "$members" "$read_rc"
  if [[ "${statuses[0]}" == 0 && "${statuses[1]}" == 0 && "$read_rc" == 0 && "$evidence_rc" == 0 && "$members" == '["item-1","item-2"]' ]]; then
    return 0
  fi
  for racer in 1 2; do
    printf 'racer=%s stdout:\n' "$racer"
    cat "$race_sd/racer-$racer.out"
    dump_stderr "$race_sd/racer-$racer.err"
  done
  dump_stderr "$race_sd/read.err"
  return 1
}

racing_appends "$WS" race && pass "two successful racing appends both survive under the mkdir mutex" \
  || fail "two successful racing appends both survive under the mkdir mutex"

# Both real writes land, then one child fails: checking only the final members
# would credit success to this failed operation.
LATE_FAILURE="$(mutant_scripts late-failure workflow-state)" || exit 1
mutate_file "$LATE_FAILURE/workflow-state" 'append)    shift; cmd_append "$@" ;;' \
  'append)    shift; cmd_append "$@"; if [[ "$3" == item-1 ]]; then exit 73; fi ;;'
rc=0
racing_appends "$LATE_FAILURE/workflow-state" late-failure-state || rc=$?
assert_eq "$(cat "$TMP_ROOT/late-failure-state/racer-1.rc") $(cat "$TMP_ROOT/late-failure-state/racer-2.rc")" \
  "73 0" "control: one real append fails after writing while its peer succeeds"
assert_eq "$(cat "$TMP_ROOT/late-failure-state/members")" '["item-1","item-2"]' \
  "control: both real updates survive despite the failed child"
assert_eq "$rc" 1 "control: a failed child is rejected even when both updates survive"

# The control: a copy whose lock helper only ever calls flock must refuse every
# write on this PATH, so the assertions above are about the mutex arm and not
# about a write that would land unlocked anyway.
BROKEN="$(mutant_scripts broken lib/file-lock.sh)" || exit 1
mutate_file "$BROKEN/lib/file-lock.sh" 'if command -v flock >/dev/null 2>&1; then' 'if true; then'
BSD="$TMP_ROOT/broken-state"
PATH="$NOFLOCK" "$BROKEN/../../orch/scripts/workflow-state" --state-dir "$BSD" init KEN-BROKEN --worktree "$REPO_ROOT" --branch ken-broken >/dev/null 2>&1 || true
rc=0
PATH="$NOFLOCK" "$BROKEN/../../orch/scripts/workflow-state" --state-dir "$BSD" set KEN-BROKEN phase implementing >/dev/null 2>&1 || rc=$?
[[ "$rc" -ne 0 ]] && pass "control: with only the flock arm every write refuses on this PATH" \
  || fail "control: with only the flock arm every write refuses on this PATH" "rc=$rc"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
