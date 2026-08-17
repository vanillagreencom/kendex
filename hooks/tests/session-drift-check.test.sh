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

# Run the hook with a SessionStart payload on stdin (source from $HOOK_SOURCE,
# default startup). Extra VAR=value args are passed through the environment.
# Captures stdout in $out and exit in $rc.
run_hook() {
  : >"$ARGS_LOG"
  : >"$CWD_LOG"
  set +e
  env -u CLAUDE_PROJECT_DIR -u VSTACK_DRIFT_HOOK -u VSTACK_DRIFT_HOOK_AVAILABLE \
    PATH="$BIN_DIR:$PATH" FAKE_ARGS_LOG="$ARGS_LOG" FAKE_CWD_LOG="$CWD_LOG" "$@" \
    bash "$HOOK" <<<"{\"session_id\":\"s\",\"hook_event_name\":\"SessionStart\",\"source\":\"${HOOK_SOURCE:-startup}\"}" \
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

echo "session-drift-check: unreadable stdin"
# Strict mode must not let a failed payload read abort the session start.
# A `cat` stub that fails stands in for a harness that hands the hook no
# readable stdin.
FAILCAT_BIN="$TMP_ROOT/failcat"
mkdir -p "$FAILCAT_BIN"
printf '#!/usr/bin/env bash\nexit 1\n' >"$FAILCAT_BIN/cat"
chmod +x "$FAILCAT_BIN/cat"
set +e
out="$(env -u CLAUDE_PROJECT_DIR -u VSTACK_DRIFT_HOOK -u VSTACK_DRIFT_HOOK_AVAILABLE \
  PATH="$FAILCAT_BIN:$BIN_DIR:$PATH" FAKE_ARGS_LOG="$ARGS_LOG" FAKE_CWD_LOG="$CWD_LOG" \
  FAKE_RC=1 FAKE_OUT="$REPORT" bash "$HOOK" </dev/null 2>/dev/null)"
rc=$?
set -e
assert_eq "$rc" 0 "exits 0 when the payload read fails"
assert_eq "$out" "$REPORT" "still relays the report when the payload read fails"

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

echo "session-drift-check: start reasons"
for src in resume compact; do
  HOOK_SOURCE=$src capture FAKE_RC=1 FAKE_OUT="$REPORT"
  assert_eq "$rc" 0 "source=$src exits 0"
  assert_eq "$out" "" "source=$src prints nothing"
  assert_eq "$(cat "$ARGS_LOG")" "" "source=$src never invokes vstack"
done
for src in startup clear; do
  HOOK_SOURCE=$src capture FAKE_RC=1 FAKE_OUT="$REPORT"
  assert_eq "$out" "$REPORT"$'\n' "source=$src relays the report"
done

echo "session-drift-check: the start reason is the payload's own top-level key"
# The payload is JSON, and only the TOP-LEVEL `source` is the start reason. A
# scan for the text takes whichever match comes first, so a nested object
# carrying the same key decided the hook's behaviour — silencing a fresh
# session's report, or replaying one on a resume.
run_raw() {
  local payload="$1"
  shift
  : >"$ARGS_LOG"
  : >"$CWD_LOG"
  set +e
  out="$(env -u CLAUDE_PROJECT_DIR -u VSTACK_DRIFT_HOOK -u VSTACK_DRIFT_HOOK_AVAILABLE \
    PATH="$1:$PATH" FAKE_ARGS_LOG="$ARGS_LOG" FAKE_CWD_LOG="$CWD_LOG" \
    FAKE_RC=1 FAKE_OUT="$REPORT" bash "$HOOK" <<<"$payload" 2>/dev/null)"
  rc=$?
  set -e
}

run_raw '{"tool_input":{"source":"resume"},"source":"startup"}' "$BIN_DIR"
assert_eq "$out" "$REPORT" "a nested source does not silence a fresh start"
assert_eq "$(cat "$ARGS_LOG")" "check --quiet" "…and the check still runs"

run_raw '{"tool_input":{"source":"startup"},"source":"resume"}' "$BIN_DIR"
assert_eq "$out" "" "a nested source does not make a resume report"
assert_eq "$(cat "$ARGS_LOG")" "" "…and the check never runs on a resume"

# A string value carrying the same characters is text, not the key.
run_raw '{"cwd":"/tmp/\"source\": \"resume\"","source":"startup"}' "$BIN_DIR"
assert_eq "$out" "$REPORT" "a quoted source inside another value is not the start reason"

echo "session-drift-check: without jq"
# The fallback scan still classifies an ordinary payload, so a machine with no
# jq keeps the report rather than losing it.
NOJQ_BIN="$TMP_ROOT/nojq"
mkdir -p "$NOJQ_BIN"
for tool in bash cat command printf grep sed head env pwd; do
  real="$(command -v "$tool" 2>/dev/null || true)"
  [ -n "$real" ] && [ -f "$real" ] && ln -sf "$real" "$NOJQ_BIN/$tool"
done
ln -sf "$BIN_DIR/vstack" "$NOJQ_BIN/vstack"
run_raw '{"session_id":"s","hook_event_name":"SessionStart","source":"startup"}' "$NOJQ_BIN"
assert_eq "$out" "$REPORT" "without jq a fresh start still relays the report"
run_raw '{"session_id":"s","hook_event_name":"SessionStart","source":"resume"}' "$NOJQ_BIN"
assert_eq "$out" "" "without jq a resume is still silent"

# A payload jq REFUSES is the other case the scan is there for: jq's own
# failure exit must hand off rather than be read as "no such key".
run_raw '{"source":"resume"' "$BIN_DIR"
assert_eq "$rc" 0 "a payload jq cannot parse still exits 0"
assert_eq "$out" "" "…and the scan classifies it rather than reading as a fresh start"

echo "session-drift-check: unusable project directory"
capture FAKE_RC=1 FAKE_OUT="$REPORT" CLAUDE_PROJECT_DIR="$TMP_ROOT/does-not-exist"
assert_eq "$rc" 0 "missing project dir exits 0"
assert_contains "$out" "vstack check could not run: project directory $TMP_ROOT/does-not-exist is not accessible" \
  "missing project dir says drift status is unknown rather than reading as clean"
assert_eq "$(cat "$ARGS_LOG")" "" "missing project dir never invokes vstack"

echo "session-drift-check: dash-leading project directory"
# A relative project dir starting with `-` is a path, not a `cd` option.
mkdir -p "$TMP_ROOT/-dash"
: >"$ARGS_LOG"
: >"$CWD_LOG"
set +e
out="$(cd "$TMP_ROOT" && env -u VSTACK_DRIFT_HOOK -u VSTACK_DRIFT_HOOK_AVAILABLE \
  PATH="$BIN_DIR:$PATH" FAKE_ARGS_LOG="$ARGS_LOG" FAKE_CWD_LOG="$CWD_LOG" \
  CLAUDE_PROJECT_DIR=-dash FAKE_RC=0 bash "$HOOK" <<<'{"source":"startup"}' 2>/dev/null)"
rc=$?
set -e
assert_eq "$rc" 0 "dash-leading project dir exits 0"
assert_eq "$out" "" "dash-leading project dir is entered, not parsed as an option"
assert_eq "$(cat "$ARGS_LOG")" "check --quiet" "dash-leading project dir still runs the check"
assert_eq "$(cd "$TMP_ROOT/-dash" && pwd -P)" "$(cd "$(cat "$CWD_LOG")" && pwd -P)" \
  "runs vstack inside the dash-leading project dir"

echo "session-drift-check: unexpected failure"
# Inject an unguarded failure into a COPY of the shipped hook. The strict-mode
# abort it triggers must still reach the agent as a diagnostic — a session that
# printed nothing would read as a clean install.
BROKEN_HOOK="$TMP_ROOT/broken-hook.sh"
awk '{ print } /^INPUT=/ { print "false" }' "$HOOK" >"$BROKEN_HOOK"
set +e
out="$(env -u CLAUDE_PROJECT_DIR -u VSTACK_DRIFT_HOOK -u VSTACK_DRIFT_HOOK_AVAILABLE \
  PATH="$BIN_DIR:$PATH" FAKE_ARGS_LOG="$ARGS_LOG" FAKE_CWD_LOG="$CWD_LOG" \
  FAKE_RC=0 bash "$BROKEN_HOOK" <<<'{"source":"startup"}' 2>/dev/null)"
rc=$?
set -e
assert_eq "$rc" 0 "an unexpected failure still exits 0"
assert_contains "$out" "vstack check could not run:" "an unexpected failure is reported, not swallowed"
assert_contains "$out" "drift status unknown" "an unexpected failure says drift status is unknown"

echo "session-drift-check: no vstack on PATH"
NOVSTACK_BIN="$TMP_ROOT/novstack"
mkdir -p "$NOVSTACK_BIN"
for tool in bash cat command printf grep sed head; do
  real="$(command -v "$tool" 2>/dev/null || true)"
  [ -n "$real" ] && [ -f "$real" ] && ln -sf "$real" "$NOVSTACK_BIN/$tool"
done
set +e
out="$(env -i HOME="$HOME" PATH="$NOVSTACK_BIN" "$(command -v bash)" "$HOOK" <<<'{}' 2>/dev/null)"
rc=$?
set -e
assert_eq "$rc" 0 "exits 0 without a vstack binary"
assert_eq "$out" "vstack drift check skipped: vstack is not on PATH" "says why it skipped without a vstack binary"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
