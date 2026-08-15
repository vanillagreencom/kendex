#!/usr/bin/env bash
# Tests for the session-drift-check hook.
#
# The hook is a thin adapter over `vstack check --quiet`: exit 0 → silence,
# exit 1 → the report verbatim on stdout, anything else → a "could not run"
# line plus the output. These cases drive it with a fake `vstack` on PATH that
# replays a scripted exit code and output, so no real install is consulted.
#
# HOOK_UNDER_TEST overrides the script under test so the must-fail controls
# (a no-op hook, an always-print hook) can be run against these same
# assertions.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${HOOK_UNDER_TEST:-$(cd "$TEST_DIR/.." && pwd)/session-drift-check.sh}"

PASS=0
FAIL=0
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

BIN_DIR="$TMP_ROOT/bin"
mkdir -p "$BIN_DIR"
ARGS_LOG="$TMP_ROOT/vstack.args"
CWD_LOG="$TMP_ROOT/vstack.cwd"

# Fake vstack: records its argv and cwd, prints $FAKE_OUT to stderr (the real
# human report goes to stderr), exits $FAKE_RC.
cat >"$BIN_DIR/vstack" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_ARGS_LOG"
pwd >>"$FAKE_CWD_LOG"
if [ -n "${FAKE_OUT:-}" ]; then
  printf '%s\n' "$FAKE_OUT" >&2
fi
exit "${FAKE_RC:-0}"
EOF
chmod +x "$BIN_DIR/vstack"

# Run the hook with a SessionStart payload on stdin. Extra VAR=value args are
# passed through the environment. Captures stdout in $out and exit in $rc.
run_hook() {
  : >"$ARGS_LOG"
  : >"$CWD_LOG"
  set +e
  env -u CLAUDE_PROJECT_DIR -u VSTACK_DRIFT_HOOK -u VSTACK_DRIFT_HOOK_AVAILABLE \
    PATH="$BIN_DIR:$PATH" FAKE_ARGS_LOG="$ARGS_LOG" FAKE_CWD_LOG="$CWD_LOG" "$@" \
    bash "$HOOK" <<<'{"session_id":"s","hook_event_name":"SessionStart","source":"startup"}' \
    2>/dev/null
  rc=$?
  set -e
}

capture() {
  out="$(run_hook "$@"; echo "rc=$rc")"
  rc="${out##*rc=}"
  out="${out%rc=*}"
}

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

assert_contains() {
  local got="$1" needle="$2" name="$3"
  if [[ "$got" == *"$needle"* ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected to contain: %s\n        got:      %s\n' "$name" "$needle" "$got"
  fi
}

echo "session-drift-check: clean install"
capture FAKE_RC=0 FAKE_OUT=""
assert_eq "$rc" 0 "exits 0 on a clean install"
assert_eq "$out" "" "prints nothing on a clean install"
assert_eq "$(cat "$ARGS_LOG")" "check --quiet" "invokes vstack check --quiet"

echo "session-drift-check: drift found"
REPORT=$'vstack drift — project scope:\n  1 outdated — run `vstack refresh` to update:\n    ! orch (skill)'
capture FAKE_RC=1 FAKE_OUT="$REPORT"
assert_eq "$rc" 0 "exits 0 so drift never blocks the session"
assert_eq "$out" "$REPORT"$'\n' "relays the report verbatim on stdout"

echo "session-drift-check: check failed"
capture FAKE_RC=2 FAKE_OUT="Error: loading lock file"
assert_eq "$rc" 0 "exits 0 when the check itself fails"
assert_contains "$out" "vstack check could not run (exit 2)" "names the failure and exit code"
assert_contains "$out" "Error: loading lock file" "carries the check's own diagnostic"

echo "session-drift-check: environment switches"
capture FAKE_RC=1 FAKE_OUT="$REPORT" VSTACK_DRIFT_HOOK=off
assert_eq "$out" "" "VSTACK_DRIFT_HOOK=off silences the hook"
assert_eq "$(cat "$ARGS_LOG")" "" "VSTACK_DRIFT_HOOK=off never invokes vstack"
capture FAKE_RC=0 VSTACK_DRIFT_HOOK_AVAILABLE=off
assert_eq "$(cat "$ARGS_LOG")" "check --quiet --no-available" "VSTACK_DRIFT_HOOK_AVAILABLE=off passes --no-available"

echo "session-drift-check: project directory"
mkdir -p "$TMP_ROOT/proj"
capture FAKE_RC=0 CLAUDE_PROJECT_DIR="$TMP_ROOT/proj"
assert_eq "$(cd "$TMP_ROOT/proj" && pwd -P)" "$(cd "$(cat "$CWD_LOG")" && pwd -P)" "runs vstack inside CLAUDE_PROJECT_DIR"

echo "session-drift-check: no vstack on PATH"
NOVSTACK_BIN="$TMP_ROOT/novstack"
mkdir -p "$NOVSTACK_BIN"
for tool in bash cat command printf; do
  real="$(command -v "$tool" 2>/dev/null || true)"
  [ -n "$real" ] && [ -f "$real" ] && ln -sf "$real" "$NOVSTACK_BIN/$tool"
done
set +e
out="$(env -i HOME="$HOME" PATH="$NOVSTACK_BIN" "$(command -v bash)" "$HOOK" <<<'{}' 2>/dev/null)"
rc=$?
set -e
assert_eq "$rc" 0 "exits 0 without a vstack binary"
assert_eq "$out" "" "prints nothing without a vstack binary"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
