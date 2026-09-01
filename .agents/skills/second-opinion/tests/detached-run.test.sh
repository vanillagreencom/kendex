#!/usr/bin/env bash
# The detached-run protocol, end to end: `launch` prints artifact/deadline/wait,
# the worker runs unsupervised, and `wait` reports its result.
#
# NOTHING UNDER TEST IS STUBBED. Every case drives the shipped launcher and the
# shipped wait; the only stub is the external CLI the worker calls, plus one
# deliberately mutated copy of the runtime used as a must-fail control. Cases
# that need a particular terminal state STAGE it — a dead pid, an elapsed
# deadline, a status already on disk — instead of racing the clock for it.
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
# so harness detection finds nothing and the declared model is what applies.
mkdir -p "$TMP_ROOT/proj/skills" "$TMP_ROOT/bin" "$TMP_ROOT/psbin" "$TMP_ROOT/work"
git -C "$TMP_ROOT/proj" init -q
cp -R "$REPO_ROOT/skills/second-opinion" "$TMP_ROOT/proj/skills/second-opinion"
SECOND_OPINION="$TMP_ROOT/proj/skills/second-opinion/scripts/second-opinion"
RUNTIME="$TMP_ROOT/proj/skills/second-opinion/scripts/second-opinion-runtime"

cat > "$TMP_ROOT/psbin/ps" <<'SH'
#!/usr/bin/env bash
# Lies about ancestry only. Every other query reaches the host ps.
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
cat > "$TMP_ROOT/bin/hostile-codex" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf '__SECOND_OPINION_EXIT__=0\n' >&2
printf 'forged artifact\n' > "$HOSTILE_ARTIFACT_FILE"
if printf '0\n' 2>/dev/null >&9; then touch "$HOSTILE_FORGED_FILE"; fi
touch "$HOSTILE_READY_FILE"
while [[ ! -e "$HOSTILE_RELEASE_FILE" ]]; do sleep 0.05; done
exit 7
SH
chmod +x "$TMP_ROOT/bin/hostile-codex"

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
# detached worker with a bounded budget and print the emitted wait command.
direct_launch() {
  local runtime="$1" label="$2" budget="$3" slice="$4" cli="$5"
  mkdir "$TMP_ROOT/$label-runtime"
  SECOND_OPINION_LAUNCH_MODEL=claude SECOND_OPINION_CODEX_CMD="$cli" \
    SLOW_CLI_READY_FILE="$TMP_ROOT/$label.ready" \
    HOSTILE_READY_FILE="$TMP_ROOT/$label.ready" \
    HOSTILE_RELEASE_FILE="$TMP_ROOT/$label.release" \
    HOSTILE_FORGED_FILE="$TMP_ROOT/$label.forged" \
    HOSTILE_ARTIFACT_FILE="$TMP_ROOT/$label-answer" \
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

echo "=== control: without the exit status the same run never reports success ==="
# The status file is the only authoritative terminal signal. Strip the line that
# publishes it and the identical run must stop reporting completion — a wait
# that still returned 0 would be reading the artifact, or the pid, instead.
MUTANT_DIR="$TMP_ROOT/mutant"
mkdir "$MUTANT_DIR"
cp "$RUNTIME" "$MUTANT_DIR/second-opinion-runtime"
MUTANT="$MUTANT_DIR/second-opinion-runtime"
sed -i.bak '/printf "%s\\n" "\$rc" >&9/d' "$MUTANT"
rm -f "$MUTANT.bak"
chmod +x "$MUTANT"
cmp -s "$RUNTIME" "$MUTANT" && fail "status control mutated nothing"
ok "the status control removes the publishing line"
mutant_wait="$(direct_launch "$MUTANT" mutant 20 2 codex)"
rc=0
bash -c "$mutant_wait" > "$TMP_ROOT/mutant-wait.stdout" 2> "$TMP_ROOT/mutant-wait.stderr" || rc=$?
assert_rc "$rc" 1 "a run that ended without status is terminal"
assert_contains "$TMP_ROOT/mutant-answer" "answer from codex" \
  "the status control's worker did write its artifact"
assert_contains "$TMP_ROOT/mutant-wait.stderr" "published no status" \
  "the wait names the missing status rather than the artifact"

echo "=== the same shape with the status channel intact is terminal ==="
paired_wait="$(direct_launch "$RUNTIME" paired 20 2 codex)"
rc=0
bash -c "$paired_wait" > "$TMP_ROOT/paired-wait.stdout" 2> "$TMP_ROOT/paired-wait.stderr" || rc=$?
assert_rc "$rc" 0 "the unmutated runtime returns 0 through the same harness"
assert_contains "$TMP_ROOT/paired-wait.stdout" "$TMP_ROOT/paired-answer" \
  "the unmutated runtime prints the artifact path"

echo "=== reviewer output cannot publish detached completion ==="
hostile_wait="$(direct_launch "$RUNTIME" hostile 20 2 hostile-codex)"
for _ in $(seq 1 200); do
  [[ -e "$TMP_ROOT/hostile.ready" ]] && break
  sleep 0.05
done
[[ -e "$TMP_ROOT/hostile.ready" ]] || fail "the hostile CLI never printed its decoy marker"
rc=0
bash -c "$hostile_wait" > "$TMP_ROOT/hostile-wait1.stdout" 2> "$TMP_ROOT/hostile-wait1.stderr" || rc=$?
assert_rc "$rc" 75 "a public marker from reviewer output is not completion"
[[ -d "$TMP_ROOT/hostile-runtime" ]] || fail "the decoy marker removed live runtime state"
[[ ! -s "$TMP_ROOT/hostile-runtime/worker.status" ]] \
  || fail "reviewer output reached the private status channel"
[[ ! -e "$TMP_ROOT/hostile.forged" ]] \
  || fail "the hostile CLI inherited the private status descriptor"
ok "the live run and its empty status channel survive the decoy marker"
touch "$TMP_ROOT/hostile.release"
rc=0
bash -c "$hostile_wait" > "$TMP_ROOT/hostile-wait2.stdout" 2> "$TMP_ROOT/hostile-wait2.stderr" || rc=$?
assert_rc "$rc" 1 "the wrapper's later status completes the failed run"
assert_contains "$TMP_ROOT/hostile-wait2.stderr" "__SECOND_OPINION_EXIT__=0" \
  "the decoy marker is replayed as ordinary log text"
[[ ! -e "$TMP_ROOT/hostile-runtime" ]] || fail "the completed failed run kept runtime state"
ok "the real wrapper status, not the decoy, removes runtime state"

FD_MUTANT="$MUTANT_DIR/fd-mutant-runtime"
sed 's/"\$@" 9>&- || rc=\$?/"\$@" || rc=\$?/' "$RUNTIME" > "$FD_MUTANT"
chmod +x "$FD_MUTANT"
cmp -s "$RUNTIME" "$FD_MUTANT" && fail "fd-boundary control mutated nothing"
grep -q '^      "\$@" || rc=\$?$' "$FD_MUTANT" \
  || fail "fd-boundary control did not remove the worker-side close"
ok "the fd-boundary control removes only the worker-side close"
fd_mutant_wait="$(direct_launch "$FD_MUTANT" hostile-mutant 20 2 hostile-codex)"
for _ in $(seq 1 200); do
  [[ -e "$TMP_ROOT/hostile-mutant.ready" ]] && break
  sleep 0.05
done
[[ -e "$TMP_ROOT/hostile-mutant.ready" ]] || fail "the fd-boundary control never ran its hostile CLI"
fd_mutant_pid="$(cat < "$TMP_ROOT/hostile-mutant-runtime/pid")"
rc=0
bash -c "$fd_mutant_wait" > "$TMP_ROOT/hostile-mutant-wait.stdout" \
  2> "$TMP_ROOT/hostile-mutant-wait.stderr" || rc=$?
assert_rc "$rc" 0 "without the fd close, hostile output forges completion"
[[ -e "$TMP_ROOT/hostile-mutant.forged" ]] \
  || fail "the fd-boundary control did not reach descriptor 9"
[[ ! -e "$TMP_ROOT/hostile-mutant-runtime" ]] \
  || fail "the forged completion did not remove live runtime state"
ok "the mutant proves descriptor closure blocks forged completion"
touch "$TMP_ROOT/hostile-mutant.release"
for _ in $(seq 1 200); do
  kill -0 "$fd_mutant_pid" 2>/dev/null || break
  sleep 0.05
done
kill -KILL -- "-$fd_mutant_pid" 2>/dev/null || true

echo "=== a killed worker without status tells the caller to relaunch ==="
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
assert_rc "$rc" 1 "a killed worker without status is terminal"
assert_contains "$TMP_ROOT/killed-wait.stderr" "the detached worker is gone" \
  "the terminal error names the gone worker"
assert_contains "$TMP_ROOT/killed-wait.stderr" "relaunch the original second-opinion command" \
  "the terminal error tells the caller how to restart"
[[ -s "$TMP_ROOT/killed-answer" ]] && fail "the killed worker wrote an artifact"
ok "the killed run left no artifact"

# --- Staged terminal states ---------------------------------------------------
# A dead pid with no status, an elapsed deadline, and a status already on disk
# are all built directly, so no case depends on winning a wall-clock margin.
stage_runtime() { # LABEL [STATUS]
  local label="$1" status="${2:-}" dead
  mkdir "$TMP_ROOT/$label"
  : > "$TMP_ROOT/$label/worker.log"
  printf '%s' "$status" > "$TMP_ROOT/$label/worker.status"
  sleep 0 &
  dead=$!
  wait "$dead" 2>/dev/null || true
  printf '%s\n' "$dead" > "$TMP_ROOT/$label/pid"
  printf 'staged answer\n' > "$TMP_ROOT/$label-answer"
}

echo "=== an elapsed deadline with no status is terminal 124 ==="
stage_runtime deadline-run
rc=0
"$RUNTIME" wait "$TMP_ROOT/deadline-run-answer" "$TMP_ROOT/deadline-run" \
  "$(($(date +%s) - 1))" 1 \
  > "$TMP_ROOT/deadline.stdout" 2> "$TMP_ROOT/deadline.stderr" || rc=$?
assert_rc "$rc" 124 "an elapsed deadline with no status returns 124"
assert_contains "$TMP_ROOT/deadline.stderr" "reached its deadline" \
  "the 124 names the deadline"
[[ -e "$TMP_ROOT/deadline-run" ]] && fail "a terminal 124 left runtime state behind"
ok "a terminal 124 removes the runtime directory"

echo "=== the status outranks an elapsed deadline and a dead pid ==="
stage_runtime status-run 0
rc=0
"$RUNTIME" wait "$TMP_ROOT/status-run-answer" "$TMP_ROOT/status-run" \
  "$(($(date +%s) - 1))" 1 \
  > "$TMP_ROOT/status.stdout" 2> "$TMP_ROOT/status.stderr" || rc=$?
assert_rc "$rc" 0 "a published status beats the deadline and the dead pid"
assert_contains "$TMP_ROOT/status.stdout" "$TMP_ROOT/status-run-answer" \
  "the status path prints the artifact"

echo "=== a status landing in the pid-death window is still read ==="
# The wrapper writes the status and THEN exits, so a poll can read the file,
# find nothing, and see the pid die a moment later with the status now on disk.
# The re-read inside the pid-death branch is what catches that; without
# it the wait reports a terminal missing-status failure for a run that finished.
#
# Staged by cat call count, never by the clock: the stub publishes the status
# after the poll's first read of the file, which is exactly the window, and the
# case decides the same way however slowly it runs.
mkdir "$TMP_ROOT/race-bin"
cat > "$TMP_ROOT/race-bin/cat" <<'SH'
#!/usr/bin/env bash
if [[ $# -ne 1 || "$1" != "$RACE_STATUS_FILE" ]]; then exec "$REAL_CAT" "$@"; fi
count=0
[[ ! -e "$RACE_COUNT" ]] || IFS= read -r count < "$RACE_COUNT"
count=$((count + 1))
printf '%s\n' "$count" > "$RACE_COUNT"
cat_rc=0
"$REAL_CAT" "$@" || cat_rc=$?
[[ $count -ne 1 ]] || printf '%s\n' "$RACE_STATUS" > "$RACE_STATUS_FILE"
exit "$cat_rc"
SH
chmod +x "$TMP_ROOT/race-bin/cat"
race_wait() { # RUNTIME LABEL — run the staged window case, print the exit code
  local runtime="$1" label="$2" rc=0
  stage_runtime "$label"
  PATH="$TMP_ROOT/race-bin:$PATH" REAL_CAT="$(command -v cat)" \
    RACE_COUNT="$TMP_ROOT/$label.count" \
    RACE_STATUS_FILE="$TMP_ROOT/$label/worker.status" RACE_STATUS=5 \
    "$runtime" wait "$TMP_ROOT/$label-answer" "$TMP_ROOT/$label" \
    "$(($(date +%s) + 60))" 5 \
    > "$TMP_ROOT/$label.stdout" 2> "$TMP_ROOT/$label.stderr" || rc=$?
  printf '%s\n' "$rc"
}
rc="$(race_wait "$RUNTIME" race)"
assert_rc "$rc" 5 "a status written in the pid-death window still decides the run"
[[ -e "$TMP_ROOT/race" ]] && fail "the recovered completion left runtime state behind"
ok "the recovered completion removes the runtime directory"

# Control: the same staged window against a wait whose pid-death branch has
# lost its re-read must report the terminal missing-status outcome instead.
# which read decided the run.
RACE_MUTANT="$MUTANT_DIR/race-mutant-runtime"
awk '
  /if ! process_group_alive "\$worker_pid"; then/ { print; dropping = 1; next }
  dropping && /\[\[ -z "\$status" \]\] \|\| continue/ { dropping = 0; next }
  dropping && (/status_rc=0/ || /status=\$\(completion_status/ || /status_rc -ne 2/) { next }
  { print }
' "$RUNTIME" > "$RACE_MUTANT"
chmod +x "$RACE_MUTANT"
[[ $(($(wc -l < "$RUNTIME") - $(wc -l < "$RACE_MUTANT"))) -eq 4 ]] \
  || fail "the re-read control removed something other than the four-line re-read"
ok "the re-read control removes exactly the pid-death re-read"
rc="$(race_wait "$RACE_MUTANT" race-mutant)"
assert_rc "$rc" 1 "the re-read control rejects a wait that never re-reads"
assert_contains "$TMP_ROOT/race-mutant.stderr" "the detached worker is gone" \
  "the control reaches the pid-death branch"

echo "=== a worker's own exit status is what the wait returns ==="
# EXIT_CLI_FAILED and its siblings mean something an operator acts on, so the
# protocol has to carry them out unchanged rather than flattening them to 1.
stage_runtime cli-failed 5
rc=0
"$RUNTIME" wait "$TMP_ROOT/cli-failed-answer" "$TMP_ROOT/cli-failed" \
  "$(($(date +%s) + 60))" 1 \
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
mkdir "$TMP_ROOT/missing-pid-runtime"
: > "$TMP_ROOT/missing-pid-runtime/worker.log"
: > "$TMP_ROOT/missing-pid-runtime/worker.status"
rc=0
"$RUNTIME" wait "$TMP_ROOT/missing-pid-answer" "$TMP_ROOT/missing-pid-runtime" \
  "$(($(date +%s) + 60))" 1 > "$TMP_ROOT/missing-pid.stdout" \
  2> "$TMP_ROOT/missing-pid.stderr" || rc=$?
assert_rc "$rc" 1 "a missing worker pid is refused"
assert_contains "$TMP_ROOT/missing-pid.stderr" "worker pid is missing or unsafe" \
  "the missing-pid refusal names the broken recovery state"
mkdir "$TMP_ROOT/missing-status-runtime"
: > "$TMP_ROOT/missing-status-runtime/worker.log"
printf '4545\n' > "$TMP_ROOT/missing-status-runtime/pid"
rc=0
"$RUNTIME" wait "$TMP_ROOT/missing-status-answer" "$TMP_ROOT/missing-status-runtime" \
  "$(($(date +%s) + 60))" 1 > "$TMP_ROOT/missing-status.stdout" \
  2> "$TMP_ROOT/missing-status.stderr" || rc=$?
assert_rc "$rc" 1 "a resumed wait with no status file is refused"
assert_contains "$TMP_ROOT/missing-status.stderr" "worker status is missing or unsafe" \
  "the missing-status refusal names the broken recovery state"
mkdir "$TMP_ROOT/wait-status-symlink-runtime"
: > "$TMP_ROOT/wait-status-symlink-runtime/worker.log"
printf '4646\n' > "$TMP_ROOT/wait-status-symlink-runtime/pid"
printf '0\n' > "$TMP_ROOT/wait-status-target"
ln -s "$TMP_ROOT/wait-status-target" "$TMP_ROOT/wait-status-symlink-runtime/worker.status"
printf 'staged answer\n' > "$TMP_ROOT/wait-status-symlink-answer"
rc=0
"$RUNTIME" wait "$TMP_ROOT/wait-status-symlink-answer" \
  "$TMP_ROOT/wait-status-symlink-runtime" "$(($(date +%s) + 60))" 1 \
  > "$TMP_ROOT/wait-status-symlink.stdout" 2> "$TMP_ROOT/wait-status-symlink.stderr" || rc=$?
assert_rc "$rc" 1 "a resumed wait refuses a symlinked status file"
assert_contains "$TMP_ROOT/wait-status-symlink.stderr" "worker status is missing or unsafe" \
  "the resumed-wait refusal names the unsafe status file"

WAIT_GUARD_MUTANT="$MUTANT_DIR/wait-guard-mutant-runtime"
awk '
  /\[\[ -f "\$status_file" && ! -L "\$status_file" \]\]/ { getline; removed += 2; next }
  { print }
  END { if (removed != 2) exit 9 }
' "$RUNTIME" > "$WAIT_GUARD_MUTANT" \
  || fail "wait-status control did not remove exactly the two-line guard"
chmod +x "$WAIT_GUARD_MUTANT"
bash -n "$WAIT_GUARD_MUTANT" || fail "wait-status control is not valid shell"
ok "the wait-status control removes exactly the file-type guard"
mkdir "$TMP_ROOT/wait-status-mutant-runtime"
: > "$TMP_ROOT/wait-status-mutant-runtime/worker.log"
printf '4747\n' > "$TMP_ROOT/wait-status-mutant-runtime/pid"
ln -s "$TMP_ROOT/wait-status-target" "$TMP_ROOT/wait-status-mutant-runtime/worker.status"
printf 'staged answer\n' > "$TMP_ROOT/wait-status-mutant-answer"
rc=0
"$WAIT_GUARD_MUTANT" wait "$TMP_ROOT/wait-status-mutant-answer" \
  "$TMP_ROOT/wait-status-mutant-runtime" "$(($(date +%s) + 60))" 1 \
  > "$TMP_ROOT/wait-status-mutant.stdout" 2> "$TMP_ROOT/wait-status-mutant.stderr" || rc=$?
assert_rc "$rc" 0 "without the wait guard, a symlinked status is accepted"
[[ ! -e "$TMP_ROOT/wait-status-mutant-runtime" ]] \
  || fail "the wait-status mutant did not consume the unsafe runtime"
ok "the mutant proves resumed waits need the status file-type guard"
mkdir "$TMP_ROOT/symlink-runtime"
ln -s "$TMP_ROOT/elsewhere.log" "$TMP_ROOT/symlink-runtime/worker.log"
rc=0
SECOND_OPINION_LAUNCH_MODEL=claude \
  "$RUNTIME" launch "$SECOND_OPINION" "$TMP_ROOT/symlink-answer" \
  "$TMP_ROOT/symlink-runtime" 20 false 2 quick question --target=codex \
  --cwd "$TMP_ROOT/work" > "$TMP_ROOT/symlink.stdout" 2> "$TMP_ROOT/symlink.stderr" || rc=$?
assert_rc "$rc" 1 "a pre-planted worker log symlink stops the launch"
assert_contains "$TMP_ROOT/symlink.stderr" "cannot create worker log" \
  "the refusal names the log it would not follow"
[[ -e "$TMP_ROOT/elsewhere.log" ]] && fail "the launch followed the planted symlink"
ok "no output reached the symlink target"
mkdir "$TMP_ROOT/status-symlink-runtime"
ln -s "$TMP_ROOT/elsewhere.status" "$TMP_ROOT/status-symlink-runtime/worker.status"
rc=0
SECOND_OPINION_LAUNCH_MODEL=claude \
  "$RUNTIME" launch "$SECOND_OPINION" "$TMP_ROOT/status-symlink-answer" \
  "$TMP_ROOT/status-symlink-runtime" 20 false 2 quick question --target=codex \
  --cwd "$TMP_ROOT/work" > "$TMP_ROOT/status-symlink.stdout" \
  2> "$TMP_ROOT/status-symlink.stderr" || rc=$?
assert_rc "$rc" 1 "a pre-planted worker status symlink stops the launch"
assert_contains "$TMP_ROOT/status-symlink.stderr" "cannot create worker status" \
  "the refusal names the private status channel"
[[ -e "$TMP_ROOT/elsewhere.status" ]] && fail "the launch followed the status symlink"
ok "no status reached the symlink target"

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
# The CLI help owns the exit contract. Instruction files point there rather
# than copying state meanings that can drift from the runtime.
"$SECOND_OPINION" --help > "$TMP_ROOT/help.stdout"
assert_contains "$TMP_ROOT/help.stdout" "75 detached wait:" \
  "help owns the recoverable wait outcome"
assert_contains "$TMP_ROOT/help.stdout" "124 detached wait:" \
  "help owns the deadline outcome"
assert_contains "$TMP_ROOT/help.stdout" "1 detached wait: follow its diagnostic" \
  "help routes shared exit 1 by its diagnostic"
assert_contains "$TMP_ROOT/help.stdout" "relaunch now only when it says the worker group is gone" \
  "help limits immediate relaunch to a proven-stopped worker group"
assert_contains "$TMP_ROOT/help.stdout" "invalid state may leave the run active" \
  "help does not read invalid recovery state as a stopped run"
assert_contains "$TMP_ROOT/help.stdout" "restart only after confirming the original process group ended" \
  "help requires positive process-group confirmation before restart"
if grep -qF "per-CLI timeout before restart" "$TMP_ROOT/help.stdout"; then
  fail "help treats elapsed call time as proof the original detached run ended"
fi
ok "help offers no time-based restart fallback"
assert_contains "$TMP_ROOT/help.stdout" "after missing artifact, restart only once the original process ends" \
  "help avoids an output race after missing artifact"
assert_contains "$TMP_ROOT/help.stdout" "keep completed artifact on replay/runtime-removal failure" \
  "help preserves completed output on local wait failure"
assert_contains "$TMP_ROOT/help.stdout" "otherwise act on replayed worker cause" \
  "help routes ordinary worker exit 1 by its replayed cause"

instruction_files=(
  "$REPO_ROOT/skills/second-opinion/SKILL.md"
  "${workflow_files[@]}"
)
for instruction_file in "${instruction_files[@]}"; do
  assert_contains "$instruction_file" 'second-opinion --help' \
    "${instruction_file##*/} points to the exit-contract owner"
  if grep -Eq 'Exit (1|75|124)|[0-9]+ detached wait:' "$instruction_file"; then
    fail "$instruction_file copies the exit contract instead of citing help"
  fi
  ok "${instruction_file##*/} carries no copied exit-code meaning"
done

for workflow_file in "${workflow_files[@]}"; do
  workflow_commands_detach "$workflow_file" \
    || fail "$workflow_file has no capped second-opinion command or one lacks --foreground"
  ok "${workflow_file##*/} launches with --foreground"
  assert_contains "$workflow_file" 'exact command printed after `wait:`' \
    "${workflow_file##*/} executes the emitted wait command"
done
cat > "$TMP_ROOT/no-command-workflow.md" <<'EOF'
Execute the exact command printed after `wait:` and read the artifact.
EOF
if workflow_commands_detach "$TMP_ROOT/no-command-workflow.md"; then
  fail "the workflow wiring check accepted prose with no launch command"
fi
ok "the workflow wiring check rejects a missing launch command"
owner_control="$TMP_ROOT/review-without-help.md"
sed 's/`second-opinion --help`/`second-opinion help`/g' \
  "$REPO_ROOT/skills/second-opinion/workflows/review.md" > "$owner_control"
cmp -s "$REPO_ROOT/skills/second-opinion/workflows/review.md" "$owner_control" \
  && fail "exit-owner control staged no change"
if grep -qF 'second-opinion --help' "$owner_control"; then
  fail "exit-owner control still cites help"
fi
ok "the owner-reference control removes the workflow citation"
