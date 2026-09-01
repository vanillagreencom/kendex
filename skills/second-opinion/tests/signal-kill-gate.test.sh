#!/usr/bin/env bash
# Regression test for the second-opinion signal-kill gate (KEN-1061).
#
# An external killer — a reaper, a sweeper, an operator — taking the review CLI
# used to fold into EXIT_CLI_FAILED (5), so a killed reviewer read exactly like
# one that refused. A CLI that died to a signal now exits EXIT_CLI_KILLED (6)
# with the signal named in the report and the .failed.json record, and a
# multi-lane run records a lane child that died to a signal as status "killed"
# in qa_metadata.lanes.
#
# Drives the real script with fake target CLIs that die to, or deal, real
# signals; the multi-lane case runs a hermetic copy of the skill (kendex#580).
# The lane-killing stub is waited for before the fixture tree goes, so no
# timeout/group-run chain outlives the suite.

set -euo pipefail

# Declare this session as having no model (none), so the cross-model
# guard neither depends on nor is defeated by the harness running the tests.
export SECOND_OPINION_CURRENT_MODEL=none

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SECOND_OPINION="$REPO_ROOT/skills/second-opinion/scripts/second-opinion"
TMP_ROOT="$(mktemp -d)"
STUB_PIDS="$TMP_ROOT/stub.pids"
wait_stubs() {
  local pid
  [[ -f "$STUB_PIDS" ]] || return 0
  while read -r pid; do
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

# --- Fake target CLIs ---------------------------------------------------------
mkdir -p "$TMP_ROOT/bin"
# Dies to SIGTERM after emitting its last words — the external-killer shape as
# seen from inside the CLI's own process group.
cat > "$TMP_ROOT/bin/kill-self" <<'SH'
#!/usr/bin/env bash
cat > /dev/null
echo "killed from outside" >&2
kill -s TERM $$
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
# only until that lane is gone, so its own exit can never race the
# classification and the chain above it collapses as soon as the lane is dead.
cat > "$TMP_ROOT/bin/kill-lane" <<'SH'
#!/usr/bin/env bash
cat > /dev/null
echo $$ >> "$STUB_PIDS"
pkill -TERM -f -- "$STUB_LANE_PATTERN"
for _ in $(seq 50); do pgrep -f -- "$STUB_LANE_PATTERN" >/dev/null || break; sleep 0.1; done
SH
chmod +x "$TMP_ROOT/bin/kill-lane"

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
mkdir -p "$TMP_ROOT/out"

# --- Case 1: a SIGTERM'd CLI exits 6, the report names the kill and signal ---
echo "=== case 1: a signal death exits EXIT_CLI_KILLED (6) and is reported as a kill ==="
out1="$TMP_ROOT/out/review1.json"
err1="$TMP_ROOT/case1.stderr"
rc1=0
set +e
SECOND_OPINION_TARGET=claude SECOND_OPINION_CLAUDE_CMD="$TMP_ROOT/bin/kill-self" \
  "$SECOND_OPINION" review --range HEAD --cwd "$WORK" --output "$out1" >/dev/null 2>"$err1"
rc1=$?
set -e
assert_eq "$rc1" "6" "a signal death exits EXIT_CLI_KILLED (6), distinct from EXIT_CLI_FAILED (5)"
assert_file_contains "$err1" "was killed by SIGTERM (exit 143)" "the report names the kill and its signal"
assert_file_contains "$err1" "killed from outside" "the CLI's own last words surface as the cause"
assert_file_contains "$out1.failed.json" "was killed before producing a review" "the .failed.json record says killed, not failed"
assert_file_contains "$out1.failed.json" "killed by SIGTERM" "the record names the signal"

# --- Case 2: a lane child dies to a signal -> recorded killed, nothing leaks --
echo "=== case 2: a lane child killed by a signal is recorded status killed ==="
mkdir -p "$TMP_ROOT/proj/skills"
git init -q "$TMP_ROOT/proj"
cp -R "$REPO_ROOT/skills/second-opinion" "$TMP_ROOT/proj/skills/second-opinion"
out2="$TMP_ROOT/out/multi2.json"
err2="$TMP_ROOT/case2.stderr"
rc2=0
set +e
env SECOND_OPINION_MODELS="codex claude" SECOND_OPINION_COUNT=2 \
  SECOND_OPINION_CODEX_CMD="$TMP_ROOT/bin/kill-lane" \
  SECOND_OPINION_CLAUDE_CMD="$TMP_ROOT/bin/lane-good" \
  STUB_PIDS="$STUB_PIDS" STUB_LANE_PATTERN="--output=$out2.codex.json" \
  "$TMP_ROOT/proj/skills/second-opinion/scripts/second-opinion" review --range HEAD --cwd "$WORK" \
  --output "$out2" >/dev/null 2>"$err2"
rc2=$?
set -e
assert_eq "$rc2" "0" "the surviving lane keeps the run at exit 0"
assert_eq "$(jq -r '[.qa_metadata.lanes[] | select(.target == "codex")][0].status' "$out2" 2>/dev/null)" \
  "killed" "the reaped lane is recorded status killed, not failed"
assert_file_contains "$err2" "lane killed: codex (SIGTERM, exit 143)" "the reap names the signal"
wait_stubs
if pgrep -f -- "group-run .*$TMP_ROOT/bin/kill-lane" >/dev/null; then
  fail "no group-run chain outlives the killed lane's stub"
else
  pass "no group-run chain outlives the killed lane's stub"
fi

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
