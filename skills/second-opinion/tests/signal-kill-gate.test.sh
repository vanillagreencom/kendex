#!/usr/bin/env bash
# Regression test for the second-opinion signal-kill gate (KEN-1061).
#
# An external killer — a reaper, a sweeper, an operator — taking the review CLI
# used to fold into EXIT_CLI_FAILED (5), so a killed reviewer read exactly like
# one that refused, and a caller burned more runs before noticing its reviewer
# was being taken away. A CLI that died to a signal — on the first run or on
# the recovery retry — now exits EXIT_CLI_KILLED (6) with the signal named in
# the report and the .failed.json record. Only 128+N for a signal N the shell
# can name is a kill; any other non-zero status stays a plain failure (5).
# challenge/quick stay outside the no-verdict contract: generic exit 1, with
# the kill still named in the error. The multi-lane contract is
# signal-kill-lanes.test.sh's.
#
# Drives the real script with fake target CLIs that die to real signals.

set -euo pipefail

# Declare this session as having no model (none), so the cross-model
# guard neither depends on nor is defeated by the harness running the tests.
export SECOND_OPINION_CURRENT_MODEL=none

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SECOND_OPINION="$REPO_ROOT/skills/second-opinion/scripts/second-opinion"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# --- Deterministic harness-free session -------------------------------------
# Same neutralization as the sibling suites: a `ps` stand-in that reports init
# as the first parent, and the harness environment markers dropped, so the
# declared identity above is what the script uses wherever these tests run.
_PSBIN="$TMP_ROOT/psbin"
mkdir -p "$_PSBIN"
cat > "$_PSBIN/ps" <<'PSSH'
#!/usr/bin/env bash
mode=""; while [[ $# -gt 0 ]]; do case "$1" in -o) mode="$2"; shift 2 ;; *) shift ;; esac; done
case "$mode" in ppid=) printf '1\n' ;; comm=) printf 'bash\n' ;; esac
PSSH
chmod +x "$_PSBIN/ps"
PATH="$_PSBIN:$PATH"
export PATH
unset CLAUDECODE CLAUDE_CODE CLAUDE_PROJECT_DIR CODEX_SANDBOX \
      CODEX_SANDBOX_NETWORK_DISABLED PI_CODING_AGENT_DIR OPENCODE \
      CURSOR_AGENT CURSOR_TRACE_ID

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1" >&2; }

assert_eq() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" == "$want" ]]; then
    pass "$name"
  else
    fail "$name"
    printf '        expected: %s\n        got:      %s\n' "$want" "$got" >&2
  fi
}

assert_file_exists() {
  local file="$1" name="$2"
  if [[ -f "$file" ]]; then
    pass "$name"
  else
    fail "$name"
    printf '        expected file to exist: %s\n' "$file" >&2
  fi
}

assert_file_absent() {
  local file="$1" name="$2"
  if [[ ! -e "$file" ]]; then
    pass "$name"
  else
    fail "$name"
    printf '        expected file to NOT exist: %s\n' "$file" >&2
  fi
}

assert_file_contains() {
  local file="$1" needle="$2" name="$3"
  if [[ -f "$file" ]] && grep -Fq -e "$needle" "$file"; then
    pass "$name"
  else
    fail "$name"
    printf '        expected file %s to contain: %s\n' "$file" "$needle" >&2
    if [[ -f "$file" ]]; then
      echo "        --- file contents ---" >&2
      sed -n '1,40p' "$file" >&2
    else
      echo "        (file does not exist)" >&2
    fi
  fi
}

assert_jq() {
  local file="$1" expr="$2" want="$3" name="$4" got
  got="$(jq -r "$expr" "$file" 2>/dev/null || echo "JQ_ERROR")"
  assert_eq "$got" "$want" "$name"
}

# --- Fake target CLIs ---------------------------------------------------------
mkdir -p "$TMP_ROOT/bin"
# Dies to the signal named in STUB_KILL_SIGNAL after emitting its last words —
# the external-killer shape as seen from inside the CLI's own process group.
cat > "$TMP_ROOT/bin/kill-self" <<'SH'
#!/usr/bin/env bash
n=$(cat "$STUB_COUNTER" 2>/dev/null || echo 0)
[[ -n "$n" ]] || n=0
printf '%s' $((n + 1)) > "$STUB_COUNTER"
cat > /dev/null
[[ -n "${STUB_STDERR:-}" ]] && printf '%s\n' "$STUB_STDERR" >&2
kill -s "${STUB_KILL_SIGNAL:-TERM}" $$
SH
chmod +x "$TMP_ROOT/bin/kill-self"
# Answers cleanly — the surviving lane in the multi-lane scenarios.
cat > "$TMP_ROOT/bin/lane-good" <<'SH'
#!/usr/bin/env bash
cat > /dev/null
printf '%s\n' '{"agent":"external-claude","timestamp":"2026-01-01T00:00:00Z","verdict":"pass","summary":"clean","blockers":[],"suggestions":[],"questions":[],"qa_metadata":{}}'
SH
chmod +x "$TMP_ROOT/bin/lane-good"

# --- Throwaway git repo for --cwd --------------------------------------------
WORK="$TMP_ROOT/work"
mkdir -p "$WORK"
git -C "$WORK" init -q
git -C "$WORK" config user.email test@example.com
git -C "$WORK" config user.name test
printf 'hello\n' > "$WORK/file.txt"
git -C "$WORK" add file.txt
git -C "$WORK" -c commit.gpgsign=false commit -q -m init
printf 'world\n' >> "$WORK/file.txt"

COUNTER="$TMP_ROOT/counter"
mkdir -p "$TMP_ROOT/out"

# --- Scenario 1: a SIGTERM'd CLI exits 6 and names the signal ----------------
echo "=== scenario 1: signal death exits EXIT_CLI_KILLED (6), record says killed ==="
s1_out="$TMP_ROOT/out/review1.json"
s1_err="$TMP_ROOT/s1.stderr"
printf '0' > "$COUNTER"
rc1=0
set +e
PATH="$TMP_ROOT/bin:$PATH" \
  SECOND_OPINION_TARGET=claude \
  SECOND_OPINION_CLAUDE_CMD="$TMP_ROOT/bin/kill-self" \
  STUB_COUNTER="$COUNTER" STUB_KILL_SIGNAL=TERM STUB_STDERR="killed from outside" \
  "$SECOND_OPINION" review --range HEAD --cwd "$WORK" --output "$s1_out" \
    >/dev/null 2>"$s1_err"
rc1=$?
set -e
assert_eq "$rc1" "6" "a signal death exits EXIT_CLI_KILLED (6), distinct from 5"
assert_file_absent "$s1_out" "a signal death writes no --output artifact"
assert_file_exists "$s1_out.failed.json" "a signal death preserves <output>.failed.json"
assert_file_contains "$s1_out.failed.json" "killed by SIGTERM" "the record names the killing signal"
assert_file_contains "$s1_out.failed.json" "was killed before producing a review" "the record says killed, not failed"
assert_file_contains "$s1_err" "was killed by SIGTERM (exit 143)" "stderr names the signal and the raw status"
assert_file_contains "$s1_err" "killed from outside" "the CLI's own last words still surface as the cause"
assert_eq "$(cat "$COUNTER")" "1" "a kill does not proceed to the recovery retry"

# --- Scenario 2: SIGKILL classifies the same way ------------------------------
echo "=== scenario 2: SIGKILL is a kill too ==="
s2_out="$TMP_ROOT/out/review2.json"
s2_err="$TMP_ROOT/s2.stderr"
printf '0' > "$COUNTER"
rc2=0
set +e
PATH="$TMP_ROOT/bin:$PATH" \
  SECOND_OPINION_TARGET=claude \
  SECOND_OPINION_CLAUDE_CMD="$TMP_ROOT/bin/kill-self" \
  STUB_COUNTER="$COUNTER" STUB_KILL_SIGNAL=KILL \
  "$SECOND_OPINION" review --range HEAD --cwd "$WORK" --output "$s2_out" \
    >/dev/null 2>"$s2_err"
rc2=$?
set -e
assert_eq "$rc2" "6" "SIGKILL exits EXIT_CLI_KILLED (6)"
assert_file_contains "$s2_err" "was killed by SIGKILL (exit 137)" "SIGKILL is named"

# --- Scenario 3: a plain CLI failure is NOT a kill (control) ------------------
echo "=== scenario 3: control — a non-zero exit below 128 still exits 5 ==="
s3_out="$TMP_ROOT/out/review3.json"
s3_err="$TMP_ROOT/s3.stderr"
cat > "$TMP_ROOT/bin/fail-plain" <<'SH'
#!/usr/bin/env bash
cat > /dev/null
echo "quota exhausted" >&2
exit 1
SH
chmod +x "$TMP_ROOT/bin/fail-plain"
rc3=0
set +e
PATH="$TMP_ROOT/bin:$PATH" \
  SECOND_OPINION_TARGET=claude \
  SECOND_OPINION_CLAUDE_CMD="$TMP_ROOT/bin/fail-plain" \
  "$SECOND_OPINION" review --range HEAD --cwd "$WORK" --output "$s3_out" \
    >/dev/null 2>"$s3_err"
rc3=$?
set -e
assert_eq "$rc3" "5" "a plain failure keeps EXIT_CLI_FAILED (5)"
assert_file_contains "$s3_out.failed.json" "failed before producing a review" "the plain-failure record says failed, not killed"

# --- Scenario 4: challenge/quick keep the generic 1, kill still named ---------
echo "=== scenario 4: a quick-mode kill keeps exit 1 and names the kill ==="
s4_out="$TMP_ROOT/out/quick4.txt"
s4_err="$TMP_ROOT/s4.stderr"
printf '0' > "$COUNTER"
rc4=0
set +e
PATH="$TMP_ROOT/bin:$PATH" \
  SECOND_OPINION_TARGET=claude \
  SECOND_OPINION_CLAUDE_CMD="$TMP_ROOT/bin/kill-self" \
  STUB_COUNTER="$COUNTER" STUB_KILL_SIGNAL=TERM \
  "$SECOND_OPINION" quick "is this safe?" --cwd "$WORK" --output "$s4_out" \
    >/dev/null 2>"$s4_err"
rc4=$?
set -e
assert_eq "$rc4" "1" "a quick-mode kill keeps the generic exit 1"
assert_file_contains "$s4_err" "was killed by SIGTERM" "the quick-mode error still names the kill"
assert_file_absent "$s4_out.failed.json" "quick mode still writes no .failed.json"

# --- Scenario 5: the recovery retry is killed -> the same kill, exit 6 --------
echo "=== scenario 5: a kill during the recovery retry exits 6 and names the retry ==="
# Prose on the first call (no JSON, so the one-shot retry fires), then dies to
# STUB_KILL_SIGNAL on the second: the retry is a second full CLI run under the
# same killer exposure.
cat > "$TMP_ROOT/bin/prose-then-kill" <<'SH'
#!/usr/bin/env bash
n=$(cat "$STUB_COUNTER" 2>/dev/null || echo 0)
[[ -n "$n" ]] || n=0
printf '%s' $((n + 1)) > "$STUB_COUNTER"
cat > /dev/null
if [[ $n -eq 0 ]]; then
  echo "I already delivered the JSON above."
  exit 0
fi
kill -s "${STUB_KILL_SIGNAL:-TERM}" $$
SH
chmod +x "$TMP_ROOT/bin/prose-then-kill"
s5_out="$TMP_ROOT/out/review5.json"
s5_err="$TMP_ROOT/s5.stderr"
printf '0' > "$COUNTER"
rc5=0
set +e
PATH="$TMP_ROOT/bin:$PATH" \
  SECOND_OPINION_TARGET=claude \
  SECOND_OPINION_CLAUDE_CMD="$TMP_ROOT/bin/prose-then-kill" \
  STUB_COUNTER="$COUNTER" STUB_KILL_SIGNAL=TERM \
  "$SECOND_OPINION" review --range HEAD --cwd "$WORK" --output "$s5_out" \
    >/dev/null 2>"$s5_err"
rc5=$?
set -e
assert_eq "$(cat "$COUNTER")" "2" "the recovery retry ran"
assert_eq "$rc5" "6" "a kill during the retry exits EXIT_CLI_KILLED (6), not the generic 1"
assert_file_absent "$s5_out" "a retry kill writes no --output artifact"
assert_file_contains "$s5_out.failed.json" "killed by SIGTERM (exit 143) during the recovery retry" \
  "the record names the signal and the retry"
assert_file_exists "$s5_out.raw.txt" "the raw first response stays preserved"

# --- Scenario 6: control — a retry that exits 1 keeps the generic exit 1 ------
echo "=== scenario 6: control — a plain retry failure keeps exit 1 ==="
cat > "$TMP_ROOT/bin/prose-then-fail" <<'SH'
#!/usr/bin/env bash
n=$(cat "$STUB_COUNTER" 2>/dev/null || echo 0)
[[ -n "$n" ]] || n=0
printf '%s' $((n + 1)) > "$STUB_COUNTER"
cat > /dev/null
[[ $n -eq 0 ]] || exit 1
echo "I already delivered the JSON above."
SH
chmod +x "$TMP_ROOT/bin/prose-then-fail"
s6_out="$TMP_ROOT/out/review6.json"
s6_err="$TMP_ROOT/s6.stderr"
printf '0' > "$COUNTER"
rc6=0
set +e
PATH="$TMP_ROOT/bin:$PATH" \
  SECOND_OPINION_TARGET=claude \
  SECOND_OPINION_CLAUDE_CMD="$TMP_ROOT/bin/prose-then-fail" \
  STUB_COUNTER="$COUNTER" \
  "$SECOND_OPINION" review --range HEAD --cwd "$WORK" --output "$s6_out" \
    >/dev/null 2>"$s6_err"
rc6=$?
set -e
assert_eq "$rc6" "1" "a retry that exits 1 keeps the generic exit 1"
assert_file_contains "$s6_err" "Failed to extract JSON from claude response after retry" \
  "a plain retry failure is reported as before"
assert_file_absent "$s6_out.failed.json" "a plain retry failure writes no .failed.json"

# --- Scenario 7: the edges of the kill band -----------------------------------
echo "=== scenario 7: only a nameable 128+N is a kill; 255 and 160 stay plain failures ==="
cat > "$TMP_ROOT/bin/exit-status" <<'SH'
#!/usr/bin/env bash
cat > /dev/null
exit "$STUB_EXIT"
SH
chmod +x "$TMP_ROOT/bin/exit-status"
# run_exit <status> <output> <stderr>
run_exit() {
  local rc=0
  set +e
  PATH="$TMP_ROOT/bin:$PATH" SECOND_OPINION_TARGET=claude \
    SECOND_OPINION_CLAUDE_CMD="$TMP_ROOT/bin/exit-status" STUB_EXIT="$1" \
    "$SECOND_OPINION" review --range HEAD --cwd "$WORK" --output "$2" >/dev/null 2>"$3"
  rc=$?
  set -e
  return "$rc"
}
rc255=0
run_exit 255 "$TMP_ROOT/out/e255.json" "$TMP_ROOT/e255.stderr" || rc255=$?
assert_eq "$rc255" "5" "exit 255 (no signal 127) stays EXIT_CLI_FAILED (5)"
assert_file_contains "$TMP_ROOT/e255.stderr" "exited with code 255" "exit 255 is reported as a plain exit"
rc160=0
run_exit 160 "$TMP_ROOT/out/e160.json" "$TMP_ROOT/e160.stderr" || rc160=$?
assert_eq "$rc160" "5" "exit 160 (signal 32, which kill -l cannot name) stays 5"
if [[ -n "$(kill -l 64 2>/dev/null)" ]]; then
  rc192=0
  run_exit 192 "$TMP_ROOT/out/e192.json" "$TMP_ROOT/e192.stderr" || rc192=$?
  assert_eq "$rc192" "6" "exit 192 (signal 64, SIG$(kill -l 64)) is a kill"
  assert_file_contains "$TMP_ROOT/e192.stderr" "was killed by SIG$(kill -l 64) (exit 192)" \
    "the top of the band names its signal"
else
  echo "  skip  exit 192: this shell names no signal 64"
fi

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
