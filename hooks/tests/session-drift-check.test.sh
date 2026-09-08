#!/usr/bin/env bash
# Tests for the session-drift-check hook.
#
# The hook is a thin adapter over `kendex check --quiet`, and its stdout is
# the session-start context channel, so the exact text is the contract. The
# mapping rows drive it with a fake `kendex` on PATH that replays a scripted
# exit code and output, so no real install is consulted.
#
# A row is `label|fake rc|fake out|stdout`:
#   fake rc   the exit status the fake kendex returns
#   fake out  the fake's output by word (fake_out maps it); `-` for none
#   stdout    the hook's exact stdout, `\n` for a newline and `{out}` for the
#             fake's output; `-` when empty
# Every row also asserts the hook's exit 0 and the argv `check --quiet`.
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
ARGS_LOG="$TMP_ROOT/kendex.args"
CWD_LOG="$TMP_ROOT/kendex.cwd"

# Fake kendex: records its argv and cwd, prints $FAKE_OUT to stderr (the real
# human report goes to stderr), exits $FAKE_RC.
cat >"$BIN_DIR/kendex" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_ARGS_LOG"
pwd >>"$FAKE_CWD_LOG"
if [ -n "${FAKE_OUT:-}" ]; then
  printf '%s\n' "$FAKE_OUT" >&2
fi
exit "${FAKE_RC:-0}"
EOF
chmod +x "$BIN_DIR/kendex"

REPORT=$'kendex drift — project scope:\n  1 outdated — run `kendex refresh` to update:\n    ! orch (skill)'

# The fake's output by word.
fake_out() {
  case "$1" in
    -) : ;;
    report) printf '%s' "$REPORT" ;;
    unevaluated) printf '%s' $'not yet evaluated:\n  33 package(s) changed upstream and are not yet re-evaluated' ;;
    could-not-check) printf '%s' $'could not check:\n  manifest: expected a table' ;;
    error-inside-a-line) printf '%s' $'could not check:\n  source github.com/x/y unreachable since 2026-08-01: error: cannot lock ref' ;;
    Error-line) printf '%s' 'Error: loading lock file' ;;
    usage-error) printf '%s' $'error: unexpected argument \'--bogus\' found\n\nUsage: kendex check --quiet' ;;
    fatal) printf '%s' 'kendex: fatal' ;;
    *) printf 'unknown fake output word: %s\n' "$1" >&2; exit 1 ;;
  esac
}

# Run the hook with a SessionStart payload on stdin (source from $HOOK_SOURCE,
# default startup). Extra VAR=value args are passed through the environment.
# Captures stdout in $out and exit in $rc.
run_hook() {
  : >"$ARGS_LOG"
  : >"$CWD_LOG"
  set +e
  env -u CLAUDE_PROJECT_DIR -u KENDEX_DRIFT_HOOK \
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

# Text as one line: every newline written as `\n`.
escape_nl() {
  local text="$1"
  printf '%s' "${text//$'\n'/\\n}"
}

calls() {
  local text
  text="$(paste -s -d ';' "$ARGS_LOG")"
  [[ "$text" != "" ]] && printf '%s' "$text" || printf -- '-'
}

# One mapping row: the hook's exit, the fake's argv and the whole stdout,
# trailing newlines kept.
run_row() { # fake-rc fake-out-word
  local rc=0 fake text
  fake="$(fake_out "$2")"
  : >"$ARGS_LOG"
  : >"$CWD_LOG"
  env -u CLAUDE_PROJECT_DIR -u KENDEX_DRIFT_HOOK \
    PATH="$BIN_DIR:$PATH" FAKE_ARGS_LOG="$ARGS_LOG" FAKE_CWD_LOG="$CWD_LOG" \
    FAKE_RC="$1" FAKE_OUT="$fake" \
    bash "$HOOK" <<<'{"session_id":"s","hook_event_name":"SessionStart","source":"startup"}' \
    >"$TMP_ROOT/stdout" 2>/dev/null || rc=$?
  text="$(cat "$TMP_ROOT/stdout"; printf x)"
  text="${text%x}"
  [[ "$text" != "" ]] && text="$(escape_nl "$text")" || text='-'
  printf 'rc=%s calls=%s out=%s' "$rc" "$(calls)" "$text"
}

run_table() {
  local title="$1" rows="$2" label fake_rc fake_word stdout want got row field before=$((PASS + FAIL))
  echo "=== $title ==="
  while IFS= read -r row; do
    [[ "$row" != "" ]] || continue
    IFS='|' read -r label fake_rc fake_word stdout <<<"$row"
    for field in "$label" "$fake_rc" "$fake_word" "$stdout"; do
      [[ "$field" != "" ]] || { printf 'a row with an empty field asserts nothing: %s\n' "$row" >&2; exit 1; }
    done
    got="$(run_row "$fake_rc" "$fake_word")"
    # A rendering aid for writing rows; the run is refused after the loop.
    if [[ "${HOOKS_TABLE_PROBE:-}" == 1 ]]; then
      printf '%s => %s\n' "$label" "$got"
      continue
    fi
    want="${stdout//\{out\}/$(escape_nl "$(fake_out "$fake_word")")}"
    assert_eq "$got" "rc=0 calls=check --quiet out=$want" "$label"
  done <<<"$rows"
  [[ "$((PASS + FAIL))" -gt "$before" ]] || { echo "no row was asserted (a probe run renders rows instead)" >&2; exit 2; }
}

# The empty-output arm belongs to exit 2 alone: a signal or a timeout kills
# the check before it says anything, and the exit 3 row keeps the colon over
# a blank line, the same text the embedded and Pi hooks print.
run_table "the kendex check exit to stdout mapping" "\
a clean install prints nothing|0|-|-
drift found: the report verbatim|1|report|{out}\n
not yet evaluated: the report verbatim, never as a failure|1|unevaluated|{out}\n
could not check: incomplete, carrying the check's own diagnostic|2|could-not-check|kendex check incomplete (exit 2); some drift status unknown:\n{out}\n
an error: inside a report line is still a completed report|2|error-inside-a-line|kendex check incomplete (exit 2); some drift status unknown:\n{out}\n
exit 2 with no output is a failure to run, not an empty partial report|2|-|kendex check could not run (exit 2); drift status unknown\n
an Error: line at exit 2 is a failure to run, carrying kendex's own diagnostic|2|Error-line|kendex check could not run (exit 2); drift status unknown:\n{out}\n
a usage error: at exit 2 is a failure to run, never partial|2|usage-error|kendex check could not run (exit 2); drift status unknown:\n{out}\n
exit 3 names the failure and exit code and carries the output|3|fatal|kendex check could not run (exit 3); drift status unknown:\n{out}\n
exit 3 with no output keeps the shape every rendering prints|3|-|kendex check could not run (exit 3); drift status unknown:\n\n
"

echo "session-drift-check: unreadable stdin"
# Strict mode must not let a failed payload read abort the session start.
# A `cat` stub that fails stands in for a harness that hands the hook no
# readable stdin.
FAILCAT_BIN="$TMP_ROOT/failcat"
mkdir -p "$FAILCAT_BIN"
printf '#!/usr/bin/env bash\nexit 1\n' >"$FAILCAT_BIN/cat"
chmod +x "$FAILCAT_BIN/cat"
set +e
out="$(env -u CLAUDE_PROJECT_DIR -u KENDEX_DRIFT_HOOK \
  PATH="$FAILCAT_BIN:$BIN_DIR:$PATH" FAKE_ARGS_LOG="$ARGS_LOG" FAKE_CWD_LOG="$CWD_LOG" \
  FAKE_RC=1 FAKE_OUT="$REPORT" bash "$HOOK" </dev/null 2>/dev/null)"
rc=$?
set -e
assert_eq "$rc" 0 "exits 0 when the payload read fails"
assert_eq "$out" "$REPORT" "still relays the report when the payload read fails"

echo "session-drift-check: environment switches"
capture FAKE_RC=1 FAKE_OUT="$REPORT" KENDEX_DRIFT_HOOK=off
assert_eq "$out" "" "KENDEX_DRIFT_HOOK=off silences the hook"
assert_eq "$(cat "$ARGS_LOG")" "" "KENDEX_DRIFT_HOOK=off never invokes kendex"

echo "session-drift-check: project directory"
mkdir -p "$TMP_ROOT/proj"
capture FAKE_RC=0 CLAUDE_PROJECT_DIR="$TMP_ROOT/proj"
assert_eq "$(cd "$TMP_ROOT/proj" && pwd -P)" "$(cd "$(cat "$CWD_LOG")" && pwd -P)" "runs kendex inside CLAUDE_PROJECT_DIR"

echo "session-drift-check: start reasons"
for src in resume compact; do
  HOOK_SOURCE=$src capture FAKE_RC=1 FAKE_OUT="$REPORT"
  assert_eq "$rc" 0 "source=$src exits 0"
  assert_eq "$out" "" "source=$src prints nothing"
  assert_eq "$(cat "$ARGS_LOG")" "" "source=$src never invokes kendex"
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
  out="$(env -u CLAUDE_PROJECT_DIR -u KENDEX_DRIFT_HOOK \
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

echo "session-drift-check: a payload it cannot read"
# jq is the only reader. An unread payload cannot be shown to be a fresh start,
# so the report is skipped with the reason rather than repeated on every
# compact — and a session still starts either way.
NOJQ_BIN="$TMP_ROOT/nojq"
mkdir -p "$NOJQ_BIN"
for tool in bash cat command printf grep sed head env pwd; do
  real="$(command -v "$tool" 2>/dev/null || true)"
  [ -n "$real" ] && [ -f "$real" ] && ln -sf "$real" "$NOJQ_BIN/$tool"
done
ln -sf "$BIN_DIR/kendex" "$NOJQ_BIN/kendex"
# PATH exactly, not prefixed: run_raw appends the caller's own PATH, which
# leaves jq reachable and makes a no-jq claim untestable.
run_exact_path() { # payload PATH
  : >"$ARGS_LOG"
  : >"$CWD_LOG"
  set +e
  out="$(env -i HOME="$HOME" PATH="$2" FAKE_ARGS_LOG="$ARGS_LOG" FAKE_CWD_LOG="$CWD_LOG" \
    FAKE_RC=1 FAKE_OUT="$REPORT" "$(command -v bash)" "$HOOK" <<<"$1" 2>/dev/null)"
  rc=$?
  set -e
}
run_exact_path '{"session_id":"s","hook_event_name":"SessionStart","source":"startup"}' "$NOJQ_BIN"
assert_eq "$rc" 0 "without jq the session still starts"
assert_eq "$out" "kendex drift check skipped: jq is not on PATH to read the session payload" \
  "without jq the skip names jq rather than reading as a clean install"
assert_eq "$(cat "$ARGS_LOG")" "" "without jq the check never runs"

# A payload jq REFUSES takes the same lane: the failure exit is not "no such
# key", so it must not read as a fresh start.
run_raw '{"source":"resume"' "$BIN_DIR"
assert_eq "$rc" 0 "a payload jq cannot parse still exits 0"
assert_eq "$out" "kendex drift check skipped: the session payload is not valid JSON" \
  "…and the skip names the payload rather than reading as a fresh start"
assert_eq "$(cat "$ARGS_LOG")" "" "and the check never runs for it"

echo "session-drift-check: unusable project directory"
capture FAKE_RC=1 FAKE_OUT="$REPORT" CLAUDE_PROJECT_DIR="$TMP_ROOT/does-not-exist"
assert_eq "$rc" 0 "missing project dir exits 0"
assert_contains "$out" "kendex check could not run: project directory $TMP_ROOT/does-not-exist is not accessible" \
  "missing project dir says drift status is unknown rather than reading as clean"
assert_eq "$(cat "$ARGS_LOG")" "" "missing project dir never invokes kendex"

echo "session-drift-check: dash-leading project directory"
# A relative project dir starting with `-` is a path, not a `cd` option.
mkdir -p "$TMP_ROOT/-dash"
: >"$ARGS_LOG"
: >"$CWD_LOG"
set +e
out="$(cd "$TMP_ROOT" && env -u KENDEX_DRIFT_HOOK \
  PATH="$BIN_DIR:$PATH" FAKE_ARGS_LOG="$ARGS_LOG" FAKE_CWD_LOG="$CWD_LOG" \
  CLAUDE_PROJECT_DIR=-dash FAKE_RC=0 bash "$HOOK" <<<'{"source":"startup"}' 2>/dev/null)"
rc=$?
set -e
assert_eq "$rc" 0 "dash-leading project dir exits 0"
assert_eq "$out" "" "dash-leading project dir is entered, not parsed as an option"
assert_eq "$(cat "$ARGS_LOG")" "check --quiet" "dash-leading project dir still runs the check"
assert_eq "$(cd "$TMP_ROOT/-dash" && pwd -P)" "$(cd "$(cat "$CWD_LOG")" && pwd -P)" \
  "runs kendex inside the dash-leading project dir"

echo "session-drift-check: unexpected failure"
# Inject an unguarded failure into a COPY of the shipped hook. The strict-mode
# abort it triggers must still reach the agent as a diagnostic — a session that
# printed nothing would read as a clean install.
BROKEN_HOOK="$TMP_ROOT/broken-hook.sh"
awk '{ print } /^INPUT=/ { print "false" }' "$HOOK" >"$BROKEN_HOOK"
set +e
out="$(env -u CLAUDE_PROJECT_DIR -u KENDEX_DRIFT_HOOK \
  PATH="$BIN_DIR:$PATH" FAKE_ARGS_LOG="$ARGS_LOG" FAKE_CWD_LOG="$CWD_LOG" \
  FAKE_RC=0 bash "$BROKEN_HOOK" <<<'{"source":"startup"}' 2>/dev/null)"
rc=$?
set -e
assert_eq "$rc" 0 "an unexpected failure still exits 0"
assert_contains "$out" "kendex check could not run:" "an unexpected failure is reported, not swallowed"
assert_contains "$out" "drift status unknown" "an unexpected failure says drift status is unknown"

echo "session-drift-check: no kendex on PATH"
NOKENDEX_BIN="$TMP_ROOT/nokendex"
mkdir -p "$NOKENDEX_BIN"
for tool in bash cat command printf grep sed head jq; do
  real="$(command -v "$tool" 2>/dev/null || true)"
  [ -n "$real" ] && [ -f "$real" ] && ln -sf "$real" "$NOKENDEX_BIN/$tool"
done
set +e
out="$(env -i HOME="$HOME" PATH="$NOKENDEX_BIN" "$(command -v bash)" "$HOOK" <<<'{}' 2>/dev/null)"
rc=$?
set -e
assert_eq "$rc" 0 "exits 0 without a kendex binary"
assert_eq "$out" "kendex drift check skipped: kendex is not on PATH" "says why it skipped without a kendex binary"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
