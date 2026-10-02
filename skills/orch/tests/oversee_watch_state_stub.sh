#!/usr/bin/env bash
# Tests for the workflow-state stub of lib/oversee-watch-harness.sh: an
# `oversee` call copies the case's fleet state into one shared scratch
# directory, runs the real CLI there and copies it back, and the lock around
# that copy keeps a call that overlaps another from losing either one's write.
# The oversee-watch long pass and its mail passes call the stub at once, so a
# copy without the lock hands a suite a fleet state some pass never wrote.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

# shellcheck source=lib/oversee-watch-harness.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/oversee-watch-harness.sh"

echo "=== oversee-watch harness: the workflow-state stub's fleet-state copy ==="

# A workflow-state that runs the real CLI and, under HOLD, keeps its caller
# between that run and the stub's copy back until the case writes `release`:
# the window the lock must keep a second call out of. The real CLI reads no
# private env file: this suite runs in the checkout, not a fixture repository.
HOLD_CLI_DIR="$TMP_ROOT/hold-cli"
mkdir -p "$HOLD_CLI_DIR"
cat > "$HOLD_CLI_DIR/workflow-state" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
"$HELD_REAL_CLI" --no-private-env "$@" || exit
[[ -n "${HOLD:-}" ]] || exit 0
: > "$STUB_DIR/held"
for _ in $(seq 1 300); do
  [[ ! -e "$STUB_DIR/release" ]] || exit 0
  sleep 0.1
done
echo "hold-cli: release=missing" >&2
exit 1
EOF
chmod +x "$HOLD_CLI_DIR/workflow-state"

# wait_for FILE — up to 30 s for FILE to appear; the held call writes it.
wait_for() { # FILE
  local _
  for _ in $(seq 1 300); do
    [[ ! -e "$1" ]] || return 0
    sleep 0.1
  done
  echo "oversee_watch_state_stub: wait=timeout file=$1" >&2
  exit 1
}

# overlap NAME STUB — call A sets .a and is held after its run, before its
# copy back; call B sets .b meanwhile. B is given 5 s, a real wait: with the
# lock B cannot finish while A holds it, so the wait runs out and only then
# is A released; without it B finishes at once. OVERLAP is the fleet state
# both calls leave, as {a, b}.
overlap() { # NAME STUB
  local stub="$2" a b _
  new_case "$1"
  STUB_DIR="$STUB_DIR" HELD_REAL_CLI="$REPO_ROOT/skills/orch/scripts/workflow-state" \
    REAL_WORKFLOW_STATE="$HOLD_CLI_DIR/workflow-state" HOLD=1 \
    "$stub" update oversee '.a = 1' >/dev/null 2>"$STUB_DIR/a.err" &
  a=$!
  wait_for "$STUB_DIR/held"
  STUB_DIR="$STUB_DIR" HELD_REAL_CLI="$REPO_ROOT/skills/orch/scripts/workflow-state" \
    REAL_WORKFLOW_STATE="$HOLD_CLI_DIR/workflow-state" \
    "$stub" update oversee '.b = 1' >/dev/null 2>"$STUB_DIR/b.err" &
  b=$!
  for _ in $(seq 1 50); do
    kill -0 "$b" 2>/dev/null || break
    sleep 0.1
  done
  : > "$STUB_DIR/release"
  wait "$a" || { cat -- "$STUB_DIR/a.err" >&2; echo "oversee_watch_state_stub: call=a failed" >&2; exit 1; }
  wait "$b" || { cat -- "$STUB_DIR/b.err" >&2; echo "oversee_watch_state_stub: call=b failed" >&2; exit 1; }
  OVERLAP="$(jq -c '{a, b}' "$STUB_DIR/oversee-state.json")"
}

overlap locked "$TMP_ROOT/bin/workflow-state-stub.sh"
assert_eq "$OVERLAP" '{"a":1,"b":1}' "a call that overlaps another's copy waits for it, and both writes stand"

# --- control ----------------------------------------------------------------
# The lock not taken: B's copy in overwrites A's run in the shared directory,
# and A's copy back then writes B's state over the fleet state.
cp -- "$TMP_ROOT/bin/workflow-state-stub.sh" "$TMP_ROOT/stub-unlocked.sh"
mutate_file "$TMP_ROOT/stub-unlocked.sh" '  orch_take_lock 9 "$STUB_DIR/oversee-state.lock" 30 || exit 2' '  :'
overlap unlocked "$TMP_ROOT/stub-unlocked.sh"
assert_eq "$([[ "$OVERLAP" != '{"a":1,"b":1}' ]] && echo red)" "red" \
  "control: without the lock an overlapping call loses a write"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
