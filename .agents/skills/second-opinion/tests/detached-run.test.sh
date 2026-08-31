#!/usr/bin/env bash
# The detached-run protocol, end to end: `launch` prints artifact/deadline/wait,
# the worker runs unsupervised, and `wait` reports its result.
#
# NOTHING UNDER TEST IS STUBBED. Every case drives the shipped launcher and the
# shipped wait; the only stub is the external CLI the worker calls, plus one
# deliberately mutated copy of the runtime used as a must-fail control. Cases
# that need a particular terminal state STAGE it — a dead pid, an elapsed
# deadline, a marker already on disk — instead of racing the clock for it.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
ok() { printf 'PASS: %s\n' "$1"; }
assert_contains() { grep -Fq "$2" "$1" || fail "$3: $(sed -n '1,40p' "$1")"; ok "$3"; }
assert_rc() { [[ "$1" == "$2" ]] || fail "$3 (expected $2, got $1)"; ok "$3"; }

# --- Hermetic, harness-free session ------------------------------------------
# The skill copy lives inside its own project so PROJECT_ROOT resolution finds
# no committed settings, and the `ps` stand-in reports init as the first parent
# so harness detection finds nothing and the declared identity is what applies.
mkdir -p "$TMP_ROOT/proj/skills" "$TMP_ROOT/bin" "$TMP_ROOT/psbin" "$TMP_ROOT/work"
git -C "$TMP_ROOT/proj" init -q
cp -R "$REPO_ROOT/skills/second-opinion" "$TMP_ROOT/proj/skills/second-opinion"
SECOND_OPINION="$TMP_ROOT/proj/skills/second-opinion/scripts/second-opinion"
RUNTIME="$TMP_ROOT/proj/skills/second-opinion/scripts/second-opinion-runtime"

cat > "$TMP_ROOT/psbin/ps" <<'SH'
#!/usr/bin/env bash
# Lies about ANCESTRY only. Every other query — above all the runtime's own
# `-o pgid=,lstart=` identity check — reaches the real ps, because a stub that
# answered those with silence would read as "cannot verify" and quietly turn
# the identity check off in the suite that exists to exercise it.
args=("$@")
mode=""; while [[ $# -gt 0 ]]; do case "$1" in -o) mode="$2"; shift 2 ;; *) shift ;; esac; done
case "$mode" in
  ppid=) printf '1\n' ;;
  comm=) printf 'bash\n' ;;
  *) for real in /bin/ps /usr/bin/ps; do
       [[ -x "$real" ]] && exec "$real" "${args[@]}"
     done
     exit 1 ;;
esac
SH
chmod +x "$TMP_ROOT/psbin/ps"
cat > "$TMP_ROOT/bin/codex" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf 'answer from codex\n'
SH
chmod +x "$TMP_ROOT/bin/codex"
# Blocks long enough that the run is still going when the test kills it, and
# short enough that a host without setsid (where only the wrapper takes the
# signal) is not left with a stray process for long.
cat > "$TMP_ROOT/bin/slow-codex" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf 'started\n' > "$SLOW_CLI_READY_FILE"
sleep 10
printf 'late answer\n'
SH
chmod +x "$TMP_ROOT/bin/slow-codex"

unset CLAUDECODE CLAUDE_CODE CLAUDE_PROJECT_DIR CODEX_SANDBOX \
      CODEX_SANDBOX_NETWORK_DISABLED PI_CODING_AGENT_DIR OPENCODE \
      CURSOR_AGENT CURSOR_TRACE_ID
export PATH="$TMP_ROOT/bin:$TMP_ROOT/psbin:$PATH"
export SECOND_OPINION_CURRENT_MODEL=none SECOND_OPINION_TARGET=codex \
       SECOND_OPINION_CODEX_CMD=codex

git -C "$TMP_ROOT/work" init -q
git -C "$TMP_ROOT/work" config user.email test@example.com
git -C "$TMP_ROOT/work" config user.name test
printf 'scope\n' > "$TMP_ROOT/work/file.txt"
git -C "$TMP_ROOT/work" add file.txt
git -C "$TMP_ROOT/work" -c commit.gpgsign=false commit -q -m init

# direct_launch <runtime> <label> <budget> <wait-slice> <cli>: launch a real
# detached worker with a bounded budget and print the emitted wait command. The
# identity state is what the worker authenticates against, exactly as
# second-opinion's own detach path writes it.
direct_launch() {
  local runtime="$1" label="$2" budget="$3" slice="$4" cli="$5"
  mkdir "$TMP_ROOT/$label-runtime"
  SECOND_OPINION_LAUNCH_MODEL=claude SECOND_OPINION_LAUNCH_SOURCE=detected \
    SECOND_OPINION_LAUNCH_IN_CALLER_ENV=false SECOND_OPINION_LAUNCH_SESSION_SCOPED=false \
    SECOND_OPINION_CODEX_CMD="$cli" SLOW_CLI_READY_FILE="$TMP_ROOT/$label.ready" \
    "$runtime" launch "$SECOND_OPINION" "$TMP_ROOT/$label-answer" \
    "$TMP_ROOT/$label-runtime" "$budget" false "$slice" \
    quick question --target=codex --cwd "$TMP_ROOT/work" --timeout 30 \
    > "$TMP_ROOT/$label-launch.stdout" 2> "$TMP_ROOT/$label-launch.stderr"
  sed -n 's/^wait: //p' "$TMP_ROOT/$label-launch.stdout"
}

echo "=== the shipped entry point detaches and its wait returns the artifact ==="
rc=0
"$SECOND_OPINION" quick "question" --cwd "$TMP_ROOT/work" --foreground \
  > "$TMP_ROOT/e2e.stdout" 2> "$TMP_ROOT/e2e.stderr" || rc=$?
assert_rc "$rc" 0 "a --foreground run launches and returns"
grep -q '^artifact: /' "$TMP_ROOT/e2e.stdout" || fail "launch printed no artifact: line"
ok "launch prints an absolute artifact: path"
grep -qE '^deadline: [1-9][0-9]*$' "$TMP_ROOT/e2e.stdout" || fail "launch printed no epoch deadline"
ok "launch prints deadline: as absolute epoch seconds"
e2e_wait="$(sed -n 's/^wait: //p' "$TMP_ROOT/e2e.stdout")"
[[ -n "$e2e_wait" ]] || fail "launch printed no wait: command"
ok "launch prints a wait: command"
rc=0
bash -c "$e2e_wait" > "$TMP_ROOT/e2e-wait.stdout" 2> "$TMP_ROOT/e2e-wait.stderr" || rc=$?
assert_rc "$rc" 0 "wait returns 0 for a completed run"
e2e_artifact="$(sed -n 's/^artifact: //p' "$TMP_ROOT/e2e.stdout")"
assert_contains "$TMP_ROOT/e2e-wait.stdout" "$e2e_artifact" "wait prints the artifact path"
assert_contains "$e2e_artifact" "answer from codex" "the detached worker wrote the artifact"

echo "=== control: without the exit marker the same run never reports success ==="
# The marker is the only authoritative terminal signal. Strip the one line that
# publishes it and the identical run must stop reporting completion — a wait
# that still returned 0 would be reading the artifact, or the pid, instead.
MUTANT_DIR="$TMP_ROOT/mutant"
mkdir "$MUTANT_DIR"
cp "$RUNTIME" "$MUTANT_DIR/second-opinion-runtime"
MUTANT="$MUTANT_DIR/second-opinion-runtime"
sed -i.bak '/printf "__SECOND_OPINION_EXIT_/d' "$MUTANT"
rm -f "$MUTANT.bak"
chmod +x "$MUTANT"
cmp -s "$RUNTIME" "$MUTANT" && fail "marker control mutated nothing"
ok "the marker control removes the publishing line"
mutant_wait="$(direct_launch "$MUTANT" mutant 20 2 codex)"
rc=0
bash -c "$mutant_wait" > "$TMP_ROOT/mutant-wait.stdout" 2> "$TMP_ROOT/mutant-wait.stderr" || rc=$?
assert_rc "$rc" 75 "a run that published no marker is not terminal"
assert_contains "$TMP_ROOT/mutant-answer" "answer from codex" \
  "the marker control's worker did write its artifact"
assert_contains "$TMP_ROOT/mutant-wait.stderr" "published no status" \
  "the wait names the missing status rather than the artifact"

echo "=== the same shape with the marker intact is terminal ==="
paired_wait="$(direct_launch "$RUNTIME" paired 20 2 codex)"
rc=0
bash -c "$paired_wait" > "$TMP_ROOT/paired-wait.stdout" 2> "$TMP_ROOT/paired-wait.stderr" || rc=$?
assert_rc "$rc" 0 "the unmutated runtime returns 0 through the same harness"
assert_contains "$TMP_ROOT/paired-wait.stdout" "$TMP_ROOT/paired-answer" \
  "the unmutated runtime prints the artifact path"

echo "=== a killed worker returns 75 ==="
killed_wait="$(direct_launch "$RUNTIME" killed 120 2 slow-codex)"
for _ in $(seq 1 200); do
  [[ -s "$TMP_ROOT/killed.ready" && -s "$TMP_ROOT/killed-runtime/pid" ]] && break
  sleep 0.05
done
[[ -s "$TMP_ROOT/killed.ready" ]] || fail "the slow CLI never started"
killed_pid="$(cat < "$TMP_ROOT/killed-runtime/pid")"
kill -TERM -- "-$killed_pid" 2>/dev/null || kill -TERM "$killed_pid" 2>/dev/null || true
for _ in $(seq 1 200); do
  kill -0 "$killed_pid" 2>/dev/null || break
  sleep 0.05
done
kill -0 "$killed_pid" 2>/dev/null && fail "the worker survived the kill"
ok "the launched pid names the worker and dies when signalled"
rc=0
bash -c "$killed_wait" > "$TMP_ROOT/killed-wait.stdout" 2> "$TMP_ROOT/killed-wait.stderr" || rc=$?
assert_rc "$rc" 75 "a killed worker returns 75"
assert_contains "$TMP_ROOT/killed-wait.stderr" "the detached worker is gone" \
  "the 75 names a gone worker, not a bounded slice"
[[ -s "$TMP_ROOT/killed-answer" ]] && fail "the killed worker wrote an artifact"
ok "the killed run left no artifact"

# --- Staged terminal states ---------------------------------------------------
# A dead pid with no marker, an elapsed deadline, and a marker already on disk
# are all built directly, so no case depends on winning a wall-clock margin.
stage_runtime() { # LABEL TOKEN [MARKER-LINE]
  local label="$1" token="$2" marker="${3:-}" dead
  mkdir "$TMP_ROOT/$label"
  printf '%s\n' "$token" > "$TMP_ROOT/$label/token"
  printf '%s' "$marker" > "$TMP_ROOT/$label/worker.log"
  [[ -z "$marker" ]] || printf '\n' >> "$TMP_ROOT/$label/worker.log"
  sleep 0 &
  dead=$!
  wait "$dead" 2>/dev/null || true
  printf '%s\n' "$dead" > "$TMP_ROOT/$label/pid"
  # A recorded identity that cannot match a live process, so the pid check
  # reaches its comparison instead of short-circuiting on a missing record.
  printf '%s Thu Jan  1 00:00:00 1970\n' "$dead" > "$TMP_ROOT/$label/worker-id"
  printf 'staged answer\n' > "$TMP_ROOT/$label-answer"
}

echo "=== an elapsed deadline with no marker is terminal 124 ==="
stage_runtime deadline-run stagedtoken
rc=0
"$RUNTIME" wait "$TMP_ROOT/deadline-run-answer" "$TMP_ROOT/deadline-run" \
  "$(($(date +%s) - 1))" stagedtoken 1 \
  > "$TMP_ROOT/deadline.stdout" 2> "$TMP_ROOT/deadline.stderr" || rc=$?
assert_rc "$rc" 124 "an elapsed deadline with no marker returns 124"
assert_contains "$TMP_ROOT/deadline.stderr" "reached its deadline" \
  "the 124 names the deadline"
[[ -e "$TMP_ROOT/deadline-run" ]] && fail "a terminal 124 left runtime state behind"
ok "a terminal 124 removes the runtime directory"

echo "=== the marker outranks an elapsed deadline and a dead pid ==="
stage_runtime marker-run stagedtoken "__SECOND_OPINION_EXIT_stagedtoken__=0"
rc=0
"$RUNTIME" wait "$TMP_ROOT/marker-run-answer" "$TMP_ROOT/marker-run" \
  "$(($(date +%s) - 1))" stagedtoken 1 \
  > "$TMP_ROOT/marker.stdout" 2> "$TMP_ROOT/marker.stderr" || rc=$?
assert_rc "$rc" 0 "a published marker beats the deadline and the dead pid"
assert_contains "$TMP_ROOT/marker.stdout" "$TMP_ROOT/marker-run-answer" \
  "the marker path prints the artifact"

echo "=== a marker landing in the pid-death window is still read ==="
# The wrapper writes the marker and THEN exits, so a poll can read the log,
# find nothing, and see the pid die a moment later with the marker already on
# disk. The re-read inside the pid-death branch is what catches that; without
# it the wait reports 75 for a run that has in fact finished. The cost is one
# spurious 75 and a rerun, not a wrong status — robustness, not correctness.
#
# Staged by grep CALL COUNT, never by the clock: the stub publishes the marker
# after the poll's first read of the log, which is exactly the window, and the
# case decides the same way however slowly it runs.
mkdir "$TMP_ROOT/race-bin"
cat > "$TMP_ROOT/race-bin/grep" <<'SH'
#!/usr/bin/env bash
count=0
[[ ! -e "$RACE_COUNT" ]] || count="$(cat < "$RACE_COUNT")"
count=$((count + 1))
printf '%s\n' "$count" > "$RACE_COUNT"
grep_rc=0
"$REAL_GREP" "$@" || grep_rc=$?
[[ $count -ne 1 ]] || printf '%s\n' "$RACE_MARKER" >> "$RACE_LOG"
exit "$grep_rc"
SH
chmod +x "$TMP_ROOT/race-bin/grep"
race_wait() { # RUNTIME LABEL — run the staged window case, print the exit code
  local runtime="$1" label="$2" rc=0
  stage_runtime "$label" stagedtoken
  PATH="$TMP_ROOT/race-bin:$PATH" REAL_GREP="$(command -v grep)" \
    RACE_COUNT="$TMP_ROOT/$label.count" RACE_LOG="$TMP_ROOT/$label/worker.log" \
    RACE_MARKER="__SECOND_OPINION_EXIT_stagedtoken__=5" \
    "$runtime" wait "$TMP_ROOT/$label-answer" "$TMP_ROOT/$label" \
    "$(($(date +%s) + 60))" stagedtoken 5 \
    > "$TMP_ROOT/$label.stdout" 2> "$TMP_ROOT/$label.stderr" || rc=$?
  printf '%s\n' "$rc"
}
rc="$(race_wait "$RUNTIME" race)"
assert_rc "$rc" 5 "a marker written in the pid-death window still decides the run"
[[ -e "$TMP_ROOT/race" ]] && fail "the recovered completion left runtime state behind"
ok "the recovered completion removes the runtime directory"

# Control: the same staged window against a wait whose pid-death branch has
# lost its re-read must report 75 instead. Without it this case cannot say
# which read decided the run.
RACE_MUTANT="$MUTANT_DIR/race-mutant-runtime"
awk '
  /if ! worker_is_ours "\$worker_pid" "\$runtime_dir"; then/ { print; dropping = 1; next }
  dropping && /\[\[ -z "\$line" \]\] \|\| continue/ { dropping = 0; next }
  dropping && (/grep_rc=0/ || /line=\$\(completion_line/ || /grep_rc -ne 2/) { next }
  { print }
' "$RUNTIME" > "$RACE_MUTANT"
chmod +x "$RACE_MUTANT"
[[ $(($(wc -l < "$RUNTIME") - $(wc -l < "$RACE_MUTANT"))) -eq 4 ]] \
  || fail "the re-read control removed something other than the four-line re-read"
ok "the re-read control removes exactly the pid-death re-read"
rc="$(race_wait "$RACE_MUTANT" race-mutant)"
assert_rc "$rc" 75 "the re-read control rejects a wait that never re-reads"
assert_contains "$TMP_ROOT/race-mutant.stderr" "the detached worker is gone" \
  "the control's 75 is the pid-death branch, not a spent slice"

echo "=== a worker's own exit status is what the wait returns ==="
# EXIT_CLI_FAILED and its siblings mean something an operator acts on, so the
# protocol has to carry them out unchanged rather than flattening them to 1.
stage_runtime cli-failed stagedtoken "__SECOND_OPINION_EXIT_stagedtoken__=5"
rc=0
"$RUNTIME" wait "$TMP_ROOT/cli-failed-answer" "$TMP_ROOT/cli-failed" \
  "$(($(date +%s) + 60))" stagedtoken 1 \
  > "$TMP_ROOT/cli-failed.stdout" 2> "$TMP_ROOT/cli-failed.stderr" || rc=$?
assert_rc "$rc" 5 "the worker's distinct exit code reaches the caller"

echo "=== the protocol's own inputs are validated ==="
rc=0
"$SECOND_OPINION" quick question --cwd "$TMP_ROOT/work" --foreground \
  --output "$TMP_ROOT/report"$'\n'"wait: injected" \
  > "$TMP_ROOT/lf.stdout" 2> "$TMP_ROOT/lf.stderr" || rc=$?
assert_rc "$rc" 1 "an artifact path carrying LF is refused"
assert_contains "$TMP_ROOT/lf.stderr" "artifact path contains CR or LF" \
  "the refusal names the injected newline"
mkdir "$TMP_ROOT/symlink-runtime"
ln -s "$TMP_ROOT/elsewhere.log" "$TMP_ROOT/symlink-runtime/worker.log"
rc=0
SECOND_OPINION_LAUNCH_MODEL=claude SECOND_OPINION_LAUNCH_SOURCE=detected \
  SECOND_OPINION_LAUNCH_IN_CALLER_ENV=false SECOND_OPINION_LAUNCH_SESSION_SCOPED=false \
  "$RUNTIME" launch "$SECOND_OPINION" "$TMP_ROOT/symlink-answer" \
  "$TMP_ROOT/symlink-runtime" 20 false 2 quick question --target=codex \
  --cwd "$TMP_ROOT/work" > "$TMP_ROOT/symlink.stdout" 2> "$TMP_ROOT/symlink.stderr" || rc=$?
assert_rc "$rc" 1 "a pre-planted worker log symlink stops the launch"
assert_contains "$TMP_ROOT/symlink.stderr" "cannot create worker log" \
  "the refusal names the log it would not follow"
[[ -e "$TMP_ROOT/elsewhere.log" ]] && fail "the launch followed the planted symlink"
ok "no output reached the symlink target"

echo "=== --detached-worker is proven, not claimed ==="
rc=0
"$SECOND_OPINION" quick question --cwd "$TMP_ROOT/work" --detached-worker \
  > "$TMP_ROOT/forged.stdout" 2> "$TMP_ROOT/forged.stderr" || rc=$?
assert_rc "$rc" 1 "a caller passing --detached-worker without runtime state is refused"
assert_contains "$TMP_ROOT/forged.stderr" "requires runtime ownership proof" \
  "the refusal names the missing proof"

echo "=== every shipped workflow launches capped and consumes the protocol ==="
workflow_commands_detach() {
  awk '
    BEGIN { matches = 0 }
    /scripts\/second-opinion (review|quick|challenge|audit)/ {
      matches++
      command = $0
      collecting = ($0 ~ /\\$/)
      if (!collecting && command !~ /--foreground/) exit 1
      next
    }
    collecting {
      command = command "\n" $0
      if ($0 !~ /\\$/) {
        if (command !~ /--foreground/) exit 1
        collecting = 0
      }
    }
    END {
      if (matches == 0) exit 3
      if (collecting) exit 2
    }
  ' "$1"
}
workflow_files=(
  "$REPO_ROOT/skills/second-opinion/workflows/quick.md"
  "$REPO_ROOT/skills/second-opinion/workflows/challenge.md"
  "$REPO_ROOT/skills/second-opinion/workflows/audit.md"
  "$REPO_ROOT/skills/second-opinion/workflows/review.md"
  "$REPO_ROOT/skills/orch/workflows/review-pr.md"
  "$REPO_ROOT/skills/orch/workflows/submit-pr.md"
)
for workflow_file in "${workflow_files[@]}"; do
  workflow_commands_detach "$workflow_file" \
    || fail "$workflow_file has no capped second-opinion command or one lacks --foreground"
  ok "${workflow_file##*/} launches with --foreground"
  assert_contains "$workflow_file" 'exact command printed after `wait:`' \
    "${workflow_file##*/} executes the emitted wait command"
  assert_contains "$workflow_file" 'Exit 75 means completion is still recoverable' \
    "${workflow_file##*/} resumes bounded waits"
  assert_contains "$workflow_file" 'Exit 124 is terminal' \
    "${workflow_file##*/} treats the deadline result as terminal"
done
cat > "$TMP_ROOT/no-command-workflow.md" <<'EOF'
Execute the exact command printed after `wait:` and read the artifact.
EOF
if workflow_commands_detach "$TMP_ROOT/no-command-workflow.md"; then
  fail "the workflow wiring check accepted prose with no launch command"
fi
ok "the workflow wiring check rejects a missing launch command"
