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

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

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
  bad "the probe PATH resolves no flock" "flock is still reachable"
else
  ok "the probe PATH resolves no flock"
fi

echo
echo "--- workflow-state with no flock on PATH ---"

SD="$TMP_ROOT/state"
PATH="$NOFLOCK" "$WS" --state-dir "$SD" init KEN-LOCK --worktree "$REPO_ROOT" --branch ken-lock >/dev/null
rc=0
PATH="$NOFLOCK" "$WS" --state-dir "$SD" set KEN-LOCK phase implementing >/dev/null 2>"$TMP_ROOT/set.err" || rc=$?
[[ "$rc" -eq 0 ]] && ok "a set lands with no flock on PATH" \
  || bad "a set lands with no flock on PATH" "rc=$rc $(cat "$TMP_ROOT/set.err")"
got="$(PATH="$NOFLOCK" "$WS" --state-dir "$SD" get KEN-LOCK .phase)"
[[ "$got" == "implementing" ]] && ok "and the value it wrote is the one read back" \
  || bad "and the value it wrote is the one read back" "got=$got"

# The mutex directory is released, not leaked: a second write on the same file
# would otherwise wait its whole timeout and then refuse.
rc=0
PATH="$NOFLOCK" "$WS" --state-dir "$SD" set KEN-LOCK phase reviewing >/dev/null 2>"$TMP_ROOT/set2.err" || rc=$?
[[ "$rc" -eq 0 ]] && ok "a second write is not blocked by the first one's mutex" \
  || bad "a second write is not blocked by the first one's mutex" "rc=$rc $(cat "$TMP_ROOT/set2.err")"

# Serialization is the point of the lock, so it is measured: two appends racing
# on one file must both survive. Without one the loser's element is lost to the
# winner's read-modify-write.
RACE_SD="$TMP_ROOT/race"
PATH="$NOFLOCK" "$WS" --state-dir "$RACE_SD" init KEN-RACE --worktree "$REPO_ROOT" --branch ken-race >/dev/null
GO="$TMP_ROOT/go"
for racer in 1 2; do
  (
    until [[ -e "$GO" ]]; do :; done
    PATH="$NOFLOCK" "$WS" --state-dir "$RACE_SD" append KEN-RACE fixed_items "item-$racer" >/dev/null 2>&1
  ) &
done
sleep 0.4
: >"$GO"
wait
count="$(PATH="$NOFLOCK" "$WS" --state-dir "$RACE_SD" get KEN-RACE '.fixed_items | length')"
[[ "$count" == "2" ]] && ok "two racing appends both survive under the mkdir mutex" \
  || bad "two racing appends both survive under the mkdir mutex" "count=$count"

# The control: a copy whose lock helper only ever calls flock must refuse every
# write on this PATH, so the assertions above are about the mutex arm and not
# about a write that would land unlocked anyway.
BROKEN="$TMP_ROOT/broken"
mkdir -p "$BROKEN/scripts/lib"
cp "$WS" "$BROKEN/scripts/workflow-state"
cp "$REPO_ROOT"/skills/orch/scripts/lib/*.sh "$BROKEN/scripts/lib/"
chmod +x "$BROKEN/scripts/workflow-state"
perl -pi -e 's/^  if command -v flock >\/dev\/null 2>&1; then$/  if true; then/' "$BROKEN/scripts/lib/file-lock.sh"
if grep -q '^  if true; then$' "$BROKEN/scripts/lib/file-lock.sh"; then
  ok "control: the mutant really removes the mkdir arm"
else
  bad "control: the mutant really removes the mkdir arm" "file-lock.sh unchanged"
fi
BSD="$TMP_ROOT/broken-state"
PATH="$NOFLOCK" "$BROKEN/scripts/workflow-state" --state-dir "$BSD" init KEN-BROKEN --worktree "$REPO_ROOT" --branch ken-broken >/dev/null 2>&1 || true
rc=0
PATH="$NOFLOCK" "$BROKEN/scripts/workflow-state" --state-dir "$BSD" set KEN-BROKEN phase implementing >/dev/null 2>&1 || rc=$?
[[ "$rc" -ne 0 ]] && ok "control: with only the flock arm every write refuses on this PATH" \
  || bad "control: with only the flock arm every write refuses on this PATH" "rc=$rc"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
