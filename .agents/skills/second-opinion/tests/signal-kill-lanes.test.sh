#!/usr/bin/env bash
# Regression test for the second-opinion signal-kill gate across review lanes
# (KEN-1061). The single-lane contract is signal-kill-gate.test.sh's.
#
# A multi-lane run records a lane taken by a signal as status "killed" in
# qa_metadata.lanes — whether the lane's CLI died to the signal (the lane child
# classifies it and exits 6) or the lane child itself did (the parent's wait
# reaps 128+N) — and when every lane fails the run takes the aggregate 4 over 6
# over 5: an unusable answer outranks a kill, a kill outranks a plain failure.
#
# Drives a hermetic copy of the skill (kendex#580) with fake target CLIs that
# die to real signals or kill their own lane. Every stub the fixture spawns is
# waited for before the fixture tree goes, so nothing outlives the suite.

set -euo pipefail

# Declare this session as having no model (none), so the cross-model
# guard neither depends on nor is defeated by the harness running the tests.
export SECOND_OPINION_CURRENT_MODEL=none

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TMP_ROOT="$(mktemp -d)"
# Lane-killing stubs record their pids here; the EXIT trap waits for them so
# no stub — nor the timeout/group-run chain above it — outlives the fixture.
STUB_PIDS="$TMP_ROOT/stub.pids"
wait_stubs() {
  local pid
  [[ -f "$STUB_PIDS" ]] || return 0
  while read -r pid; do
    [[ -n "$pid" ]] || continue
    for _ in $(seq 100); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
  done < "$STUB_PIDS"
}
trap 'wait_stubs; rm -rf "$TMP_ROOT"' EXIT

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

# lane_field <artifact> <target> <jq-suffix>: one field of that lane's record.
lane_field() {
  jq -r --arg t "$2" '[.qa_metadata.lanes[] | select(.target == $t)][0]'"$3" "$1" 2>/dev/null \
    || echo JQ_ERROR
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
kill -s "${STUB_KILL_SIGNAL:-TERM}" $$
SH
chmod +x "$TMP_ROOT/bin/kill-self"
# Answers cleanly — the surviving lane.
cat > "$TMP_ROOT/bin/lane-good" <<'SH'
#!/usr/bin/env bash
cat > /dev/null
printf '%s\n' '{"agent":"external-claude","timestamp":"2026-01-01T00:00:00Z","verdict":"pass","summary":"clean","blockers":[],"suggestions":[],"questions":[],"qa_metadata":{}}'
SH
chmod +x "$TMP_ROOT/bin/lane-good"
# Kills its own lane — the lane child whose argv carries the unique --output
# path in STUB_LANE_PATTERN; nothing else on the host does — then stays alive
# until that lane is gone, so the stub's own exit can never race the
# classification, and exits as soon as it is, so the chain above it collapses.
cat > "$TMP_ROOT/bin/kill-lane" <<'SH'
#!/usr/bin/env bash
cat > /dev/null
echo $$ >> "$STUB_PIDS"
pkill -TERM -f -- "$STUB_LANE_PATTERN"
for _ in $(seq 50); do pgrep -f -- "$STUB_LANE_PATTERN" >/dev/null || break; sleep 0.1; done
SH
chmod +x "$TMP_ROOT/bin/kill-lane"
# Answers with valid JSON that has no qa_metadata: the lane answered unusably (4).
cat > "$TMP_ROOT/bin/lane-no-qa" <<'SH'
#!/usr/bin/env bash
cat > /dev/null
printf '%s\n' '{"agent":"external-claude","timestamp":"2026-01-01T00:00:00Z","verdict":"pass","summary":"clean","blockers":[],"suggestions":[],"questions":[]}'
SH
chmod +x "$TMP_ROOT/bin/lane-no-qa"
# Fails on its own terms: the lane never answered (5).
cat > "$TMP_ROOT/bin/fail-plain" <<'SH'
#!/usr/bin/env bash
cat > /dev/null
echo "quota exhausted" >&2
exit 1
SH
chmod +x "$TMP_ROOT/bin/fail-plain"
# Prose on the first call, then dies to SIGTERM on the recovery retry.
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
kill -s TERM $$
SH
chmod +x "$TMP_ROOT/bin/prose-then-kill"

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

# --- A hermetic copy of the skill (kendex#580) ---------------------------------
mkdir -p "$TMP_ROOT/proj/skills"
git init -q "$TMP_ROOT/proj"
cp -R "$REPO_ROOT/skills/second-opinion" "$TMP_ROOT/proj/skills/second-opinion"
SO_MULTI="$TMP_ROOT/proj/skills/second-opinion/scripts/second-opinion"

# run_multi <output> <codex-cmd> <claude-cmd> [extra env...]
run_multi() {
  local out="$1" codex_cmd="$2" claude_cmd="$3"
  shift 3
  local rc=0
  set +e
  env SECOND_OPINION_MODELS="codex claude" SECOND_OPINION_COUNT=2 "$@" \
    SECOND_OPINION_CLAUDE_CMD="$claude_cmd" \
    SECOND_OPINION_CODEX_CMD="$codex_cmd" \
    "$SO_MULTI" review --range HEAD --cwd "$WORK" --output "$out" \
    >/dev/null 2>"$TMP_ROOT/last.stderr"
  rc=$?
  set -e
  return "$rc"
}

# --- Scenario 1: a killed lane CLI -> lane exit 6, status "killed" ------------
echo "=== scenario 1: a lane whose CLI died to a signal is recorded killed ==="
out1="$TMP_ROOT/out/multi1.json"
printf '0' > "$COUNTER"
rc1=0
run_multi "$out1" "$TMP_ROOT/bin/kill-self" "$TMP_ROOT/bin/lane-good" \
  STUB_COUNTER="$COUNTER" STUB_KILL_SIGNAL=TERM || rc1=$?
assert_eq "$rc1" "0" "the surviving lane keeps the run at exit 0"
assert_eq "$(lane_field "$out1" codex .status)" "killed" "the killed lane is recorded killed, not failed"
assert_eq "$(lane_field "$out1" codex .exit_code)" "6" "the killed lane records EXIT_CLI_KILLED"
assert_eq "$(jq -r .qa_metadata.coverage "$out1")" "degraded" "a killed lane still degrades coverage"
assert_file_contains "$TMP_ROOT/last.stderr" "lane killed: codex" "stderr reports the lane as killed"
assert_file_contains "$TMP_ROOT/last.stderr" "killed by SIGTERM" "the killing signal is named"

# --- Scenario 2: the lane child itself is killed -> the wait reaps 128+N ------
echo "=== scenario 2: a lane child that died to a signal is recorded killed ==="
out2="$TMP_ROOT/out/multi2.json"
rc2=0
run_multi "$out2" "$TMP_ROOT/bin/kill-lane" "$TMP_ROOT/bin/lane-good" \
  STUB_PIDS="$STUB_PIDS" STUB_LANE_PATTERN="--output=$out2.codex.json" || rc2=$?
assert_eq "$rc2" "0" "the surviving lane keeps the run at exit 0"
assert_eq "$(lane_field "$out2" codex .status)" "killed" "a reaped signal death is recorded killed, not failed"
assert_eq "$(lane_field "$out2" codex .exit_code)" "143" "the reaped signal status is recorded"
assert_file_contains "$TMP_ROOT/last.stderr" "lane killed: codex (SIGTERM, exit 143)" "the reap names the signal"
wait_stubs
if pgrep -f -- "group-run .*$TMP_ROOT/bin/kill-lane" >/dev/null; then
  fail "the fixture's kill-lane chain is gone once the stub has exited"
else
  pass "the fixture's kill-lane chain is gone once the stub has exited"
fi

# --- Scenario 3: a lane killed during its recovery retry ----------------------
echo "=== scenario 3: a lane whose CLI was killed on the retry is recorded killed ==="
out3="$TMP_ROOT/out/multi3.json"
printf '0' > "$COUNTER"
rc3=0
run_multi "$out3" "$TMP_ROOT/bin/prose-then-kill" "$TMP_ROOT/bin/lane-good" \
  STUB_COUNTER="$COUNTER" || rc3=$?
assert_eq "$rc3" "0" "the surviving lane keeps the run at exit 0"
assert_eq "$(lane_field "$out3" codex .status)" "killed" "a retry kill is recorded killed, not failed"
assert_eq "$(lane_field "$out3" codex .exit_code)" "6" "a retry kill records EXIT_CLI_KILLED"

# --- Scenario 4: every lane CLI killed -> aggregate exit 6, distinct from 5 ---
echo "=== scenario 4: every lane CLI killed exits EXIT_CLI_KILLED (6) ==="
out4="$TMP_ROOT/out/multi4.json"
printf '0' > "$COUNTER"
rc4=0
run_multi "$out4" "$TMP_ROOT/bin/kill-self" "$TMP_ROOT/bin/kill-self" \
  STUB_COUNTER="$COUNTER" STUB_KILL_SIGNAL=TERM || rc4=$?
assert_eq "$rc4" "6" "every lane killed exits EXIT_CLI_KILLED (6), not 5"
assert_file_absent "$out4" "no union artifact when every lane was killed"

# --- Scenario 5: every lane child reaped by signal -> 6, every lane killed ----
echo "=== scenario 5: every lane child reaped at 128+N exits 6 ==="
out5="$TMP_ROOT/out/multi5.json"
rc5=0
run_multi "$out5" "$TMP_ROOT/bin/kill-lane" "$TMP_ROOT/bin/kill-lane" \
  STUB_PIDS="$STUB_PIDS" STUB_LANE_PATTERN="--output=${out5}[.](codex|claude)[.]json" || rc5=$?
assert_eq "$rc5" "6" "every lane child reaped by a signal exits EXIT_CLI_KILLED (6), not 5"
assert_file_absent "$out5" "no union artifact when every lane child was reaped"
assert_file_contains "$TMP_ROOT/last.stderr" "lane killed: codex (SIGTERM, exit 143)" "the codex reap is named"
assert_file_contains "$TMP_ROOT/last.stderr" "lane killed: claude (SIGTERM, exit 143)" "the claude reap is named"
wait_stubs

# --- Scenario 6: an unusable answer beside a kill -> 4 outranks 6 -------------
echo "=== scenario 6: an exit-4 lane beside a killed lane aggregates to 4 ==="
out6="$TMP_ROOT/out/multi6.json"
printf '0' > "$COUNTER"
rc6=0
run_multi "$out6" "$TMP_ROOT/bin/kill-self" "$TMP_ROOT/bin/lane-no-qa" \
  STUB_COUNTER="$COUNTER" STUB_KILL_SIGNAL=TERM || rc6=$?
assert_eq "$rc6" "4" "an unusable answer outranks a kill: aggregate is EXIT_NO_REVIEW (4)"
assert_file_contains "$TMP_ROOT/last.stderr" "lane killed: codex" "the killed lane is still reported as killed"

# --- Scenario 7: a kill beside a plain failure -> 6 outranks 5 ----------------
echo "=== scenario 7: a killed lane beside a plain-failed lane aggregates to 6 ==="
out7="$TMP_ROOT/out/multi7.json"
printf '0' > "$COUNTER"
rc7=0
run_multi "$out7" "$TMP_ROOT/bin/kill-self" "$TMP_ROOT/bin/fail-plain" \
  STUB_COUNTER="$COUNTER" STUB_KILL_SIGNAL=TERM || rc7=$?
assert_eq "$rc7" "6" "a kill outranks a plain failure: aggregate is EXIT_CLI_KILLED (6)"
assert_file_contains "$TMP_ROOT/last.stderr" "lane failed: claude (exit 5)" "the plain failure is still reported as failed"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
