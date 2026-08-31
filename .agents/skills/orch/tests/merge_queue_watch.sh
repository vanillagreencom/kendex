#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCH="$(cd "$TEST_DIR/.." && pwd)"
TMP_ROOT="$(mktemp -d)"; TMP="$TMP_ROOT/watch path"
mkdir "$TMP"
trap 'rm -rf "$TMP_ROOT"' EXIT
PASS=0 FAIL=0
ok() { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
eq() { if [[ "$1" == "$2" ]]; then ok "$3"; else bad "$3 (expected $2, got $1)"; fi; }
wait_file() { local i; for ((i=0;i<100;i++)); do [[ -s "$1" ]] && return 0; sleep 0.05; done; return 1; }
wait_exists() { local i; for ((i=0;i<100;i++)); do [[ -e "$1" ]] && return 0; sleep 0.05; done; return 1; }
wait_state() { local i; for ((i=0;i<200;i++)); do [[ "$(jq -r .status "$1")" == "$2" ]] && return 0; sleep 0.05; done; return 1; }
running() { local state; state=$(ps -p "$1" -o stat= 2>/dev/null) || return 1; state="${state//[[:space:]]/}"; [[ -n "$state" && "$state" != Z* ]]; }
inode() { stat -c %i "$1" 2>/dev/null || stat -f %i "$1"; }

MAIN="$TMP/main" WT="$TMP/worktree" BIN="$TMP/bin" SCRIPTS="$TMP/orch/scripts"
REAL_SETSID=$(command -v setsid || true)
REAL_CHMOD=$(command -v chmod)
REAL_FLOCK=$(command -v flock)
REAL_PS=$(command -v ps)
REAL_MKFIFO=$(command -v mkfifo)
mkdir -p "$MAIN" "$BIN" "$SCRIPTS/lib"
git -C "$MAIN" init -q
git -C "$MAIN" config user.email test@example.com
git -C "$MAIN" config user.name Test
touch "$MAIN/seed"; printf 'tmp/\n' > "$MAIN/.gitignore"
git -C "$MAIN" add seed .gitignore; git -C "$MAIN" commit -qm seed
git -C "$MAIN" branch watch-test
git -C "$MAIN" worktree add -q "$WT" watch-test
ln -s "$(cd "$ORCH/.." && pwd)/github" "$TMP/github"
printf 'GH_BOT_TOKEN=ghp_project\n' > "$MAIN/.env.local"
mkdir -p "$MAIN/.agents/skills/worktree/scripts"
cat > "$MAIN/.agents/skills/worktree/scripts/worktree" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == path ]]; then printf '%s\n' "$WATCH_WORKTREE"; exit 0; fi
[[ "$1" == remove && "$2" == KEN-829 ]]
if [[ -f "$WATCH_CLEANUP_PAUSE.enabled" ]]; then touch "$WATCH_CLEANUP_PAUSE.entered"; while [[ ! -f "$WATCH_CLEANUP_PAUSE.release" ]]; do sleep 0.05; done; fi
[[ ! -f "$WATCH_CLEANUP_FAIL" ]] || { echo 'cleanup refused' >&2; exit 9; }
if [[ -f "$WATCH_CLEANUP_INTERRUPT" ]]; then rm -f "$WATCH_CLEANUP_INTERRUPT"; kill -KILL "$PPID"; exit 137; fi
git -C "$WATCH_MAIN" worktree remove --force "$WATCH_WORKTREE"
EOF
chmod +x "$MAIN/.agents/skills/worktree/scripts/worktree"
cp "$ORCH/scripts/merge-queue-watch" "$ORCH/scripts/workflow-state" "$ORCH/scripts/orch-env" "$SCRIPTS/"
cp "$ORCH/scripts/lib/merge-queue-supervisor.sh" "$SCRIPTS/lib/"
cp "$ORCH/scripts/lib/merge-queue-state.sh" "$SCRIPTS/lib/"
cp "$ORCH/scripts/lib/kendex-env.sh" "$SCRIPTS/lib/"

MODE="$TMP/mode" RELEASE="$TMP/release" HEAD_FILE="$TMP/head"
HEAD_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
HEAD_INPUT=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
HEAD_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
printf '%s\n' "$HEAD_A" > "$HEAD_FILE"
cat > "$SCRIPTS/queue-wait" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$PWD" == "$WATCH_MAIN" ]] || { printf '{"status":"error","verdict":"unknown","error":"wrong cwd"}\n'; exit 3; }
[[ -f .env.local ]] || { printf '{"status":"error","verdict":"unknown","error":"main env missing"}\n'; exit 3; }
source .env.local
[[ "$GH_BOT_TOKEN" == ghp_project && "$GH_REPO" == owner/repo ]] || { printf '{"status":"error","verdict":"unknown","error":"detached auth scope missing"}\n'; exit 3; }
printf '%s\n' "$PWD|$GH_REPO|$GH_BOT_TOKEN" >> "$WATCH_WORKER_LOG"
printf '%s\n' "$$" > "$WATCH_WORKER_PID"
printf '%s\n' "${MERGE_QUEUE_SUPERVISOR_TOKEN:-unset}" > "$WATCH_WORKER_TOKEN"
while [[ ! -f "$WATCH_RELEASE" ]]; do sleep 0.05; done
mode=$(cat < "$WATCH_MODE")
case "$mode" in
  merged) printf '{"status":"complete","verdict":"merged"}\n' ;;
  conflicting) printf '{"status":"complete","verdict":"conflicting","cause":"base_conflict"}\n'; exit 1 ;;
  ejected) printf '{"status":"complete","verdict":"ejected","cause":"merge_group_failed"}\n'; exit 1 ;;
  disarmed) printf '{"status":"complete","verdict":"disarmed","cause":"auto_merge_cleared"}\n'; exit 1 ;;
  dequeued) printf '{"status":"complete","verdict":"dequeued","cause":"late_findings"}\n'; exit 1 ;;
  dequeue_failed) printf '{"status":"error","verdict":"dequeued","cause":"late_findings_dequeue_failed","error":"disable failed"}\n'; exit 1 ;;
  stalled) printf '{"status":"timeout","verdict":"queued","cause":"stalled"}\n'; exit 1 ;;
  progressing) printf '{"status":"timeout","verdict":"queued","cause":"still_progressing"}\n'; exit 1 ;;
  not_queued) printf '{"status":"timeout","verdict":"not_queued","cause":"never_armed"}\n'; exit 1 ;;
  closed) printf '{"status":"complete","verdict":"closed","cause":"closed_without_merge"}\n'; exit 1 ;;
  unknown) printf '{"status":"error","verdict":"unknown","error":"api failed"}\n'; exit 1 ;;
  malformed) printf 'not json\n'; exit 7 ;;
  *) exit 9 ;;
esac
EOF
chmod +x "$SCRIPTS/merge-queue-watch" "$SCRIPTS/workflow-state" "$SCRIPTS/orch-env" "$SCRIPTS/queue-wait"
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-} ${2:-}" == "pr view" ]]; then
  [[ "${GH_REPO:-}" == owner/repo ]] || { echo "wrong repo: ${GH_REPO:-unset}" >&2; exit 1; }
  [[ "${GH_TOKEN:-}" == ghp_project ]] || { echo 'no shared project token' >&2; exit 1; }
  printf '%s\n' "${GH_TOKEN:-none}" >> "$WATCH_AUTH_LOG"
  if [[ -f "$WATCH_GH_PAUSE.enabled" ]]; then touch "$WATCH_GH_PAUSE.entered"; while [[ ! -f "$WATCH_GH_PAUSE.release" ]]; do sleep 0.05; done; fi
  head=$(cat < "$WATCH_HEAD_FILE")
  mode=$(cat < "$WATCH_MODE")
  case "$mode" in merged) state=MERGED ;; closed) state=CLOSED ;; *) state=OPEN ;; esac
  if [[ "$*" == *"--jq"* ]]; then printf '%s\n' "$head"; fi
  if [[ "$*" != *"--jq"* ]]; then printf '{"headRefOid":"%s","state":"%s"}\n' "$head" "$state"; fi
  exit 0
fi
if [[ "${1:-} ${2:-}" == "auth status" || "${1:-} ${2:-}" == "api user" ]]; then
  [[ "${GH_TOKEN:-}" == ghp_project ]] || exit 1
  echo authenticated; exit 0
fi
echo "unexpected gh: $*" >&2
exit 1
EOF
chmod +x "$BIN/gh"
if [[ -n "$REAL_SETSID" ]]; then
cat > "$BIN/setsid" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ ! -f "$WATCH_SETSID_FAIL" ]] || exit 41
if [[ -f "$WATCH_SETSID_DELAY.enabled" ]]; then
  "$WATCH_REAL_SETSID" -f bash -c 'touch "$WATCH_SETSID_DELAY.entered"; while [[ ! -f "$WATCH_SETSID_DELAY.release" ]]; do sleep 0.05; done; exec "$@"' bash "$WATCH_REAL_SETSID" "$@"
  exit 0
fi
if [[ -f "$WATCH_SETUP_GATE.enabled" ]]; then touch "$WATCH_SETUP_GATE.entered"; while [[ ! -f "$WATCH_SETUP_GATE.release" ]]; do sleep 0.05; done; fi
exec "$WATCH_REAL_SETSID" "$@"
EOF
chmod +x "$BIN/setsid"
fi
cat > "$BIN/chmod" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ -f "$WATCH_SUPERVISOR_PID_GATE.enabled" && "${*: -1}" == */supervisor.pid ]]; then
  touch "$WATCH_SUPERVISOR_PID_GATE.entered"
  while [[ ! -f "$WATCH_SUPERVISOR_PID_GATE.release" ]]; do sleep 0.05; done
fi
exec "$WATCH_REAL_CHMOD" "$@"
EOF
chmod +x "$BIN/chmod"
cat > "$BIN/flock" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ -f "$WATCH_FAIL_FLOCK_GATE.enabled" && "${1:-}" == -w ]]; then
  rm -f -- "$WATCH_FAIL_FLOCK_GATE.enabled"
  touch "$WATCH_FAIL_FLOCK_GATE.entered"
  while [[ ! -f "$WATCH_FAIL_FLOCK_GATE.release" ]]; do sleep 0.05; done
fi
exec "$WATCH_REAL_FLOCK" "$@"
EOF
chmod +x "$BIN/flock"
cat > "$BIN/ps" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${WATCH_PS_ZOMBIE_PID:-}" && "$*" == "-p $WATCH_PS_ZOMBIE_PID -o stat=" ]]; then printf 'Z\n'; exit 0; fi
if [[ "${MERGE_QUEUE_FORCE_PS_IDENTITY:-0}" == 1 ]]; then printf '%s\n' "$*" >> "$WATCH_PS_LOG"; fi
if [[ -f "$WATCH_SUPERVISOR_PID_GATE.enabled" ]]; then
  calls=0; [[ ! -f "$WATCH_SUPERVISOR_PID_GATE.calls" ]] || calls=$(cat < "$WATCH_SUPERVISOR_PID_GATE.calls")
  calls=$((calls+1)); printf '%s\n' "$calls" > "$WATCH_SUPERVISOR_PID_GATE.calls"
  if [[ "$calls" -eq 1 && -n "${WATCH_SUPERVISOR_PID_GATE_STATE:-}" ]]; then
    jq -r .status "$WATCH_SUPERVISOR_PID_GATE_STATE" > "$WATCH_SUPERVISOR_PID_GATE.observed-status"
  fi
  [[ "$calls" -lt 2 ]] || touch "$WATCH_SUPERVISOR_PID_GATE.release"
fi
exec "$WATCH_REAL_PS" "$@"
EOF
chmod +x "$BIN/ps"
cat > "$BIN/mkfifo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ -f "$WATCH_REGISTRATION_GATE.enabled" && "$*" == *"/events"* ]]; then
  touch "$WATCH_REGISTRATION_GATE.entered"
  while [[ ! -f "$WATCH_REGISTRATION_GATE.release" ]]; do sleep 0.05; done
fi
exec "$WATCH_REAL_MKFIFO" "$@"
EOF
chmod +x "$BIN/mkfifo"
export PATH="$BIN:$PATH" WATCH_MODE="$MODE" WATCH_RELEASE="$RELEASE" WATCH_HEAD_FILE="$HEAD_FILE" WATCH_MAIN="$MAIN" WATCH_WORKTREE="$WT"
export WATCH_GH_PAUSE="$TMP/gh-pause" WATCH_SETUP_GATE="$TMP/setup-gate" WATCH_REAL_SETSID="$REAL_SETSID" WATCH_CLEANUP_FAIL="$TMP/cleanup-fail" WATCH_CLEANUP_INTERRUPT="$TMP/cleanup-interrupt"
export WATCH_SETSID_FAIL="$TMP/setsid-fail" WATCH_SETSID_DELAY="$TMP/setsid-delay" WATCH_CLEANUP_PAUSE="$TMP/cleanup-pause" WATCH_AUTH_LOG="$TMP/auth.log" WATCH_WORKER_LOG="$TMP/worker.log" WATCH_WORKER_PID="$TMP/worker.pid" WATCH_WORKER_TOKEN="$TMP/worker.token" WATCH_REAL_CHMOD="$REAL_CHMOD" WATCH_REAL_FLOCK="$REAL_FLOCK" WATCH_FAIL_FLOCK_GATE="$TMP/fail-flock-gate" WATCH_REAL_PS="$REAL_PS" WATCH_PS_LOG="$TMP/ps.log" WATCH_SUPERVISOR_PID_GATE="$TMP/supervisor-pid-gate" WATCH_REAL_MKFIFO="$REAL_MKFIFO" WATCH_REGISTRATION_GATE="$TMP/registration-gate" GH_REPO=wrong/repository GITHUB_REPOSITORY=wrong/repository
touch "$WATCH_PS_LOG"
unset GH_TOKEN GITHUB_TOKEN GH_BOT_TOKEN
init_out=$("$SCRIPTS/merge-queue-watch" init --worktree "$WT" --issue KEN-829 --branch watch-test)
eq "$(jq -r .exists <<<"$init_out")" true "standalone init creates workflow state"

prepare() {
  rm -f "$RELEASE"
  printf '%s\n' "$1" > "$MODE"
  "$SCRIPTS/merge-queue-watch" prepare --worktree "$WT" --issue KEN-829 \
    --repo owner/repo --pr 42 --head "$HEAD_INPUT" --root "$MAIN" --gate-mode "${2:-off}" --recovery-count "${3:-0}"
}
launch_bounded() {
  local watch="$1" out="$TMP/launch.out" err="$TMP/launch.err" pid i rc=0
  "$SCRIPTS/merge-queue-watch" launch --root "$MAIN" --issue KEN-829 --watch-id "$watch" --poll 1 --max-wait 10 >"$out" 2>"$err" &
  pid=$!
  for ((i=0;i<100;i++)); do running "$pid" || break; sleep 0.05; done
  if running "$pid"; then kill -TERM "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; bad "launch returns before worker release"; return 1; fi
  wait "$pid" || rc=$?
  eq "$rc" 0 "launch returns before worker release"
  [[ "$rc" -eq 0 ]] || sed 's/^/        /' "$err"
}
verdict_case() {
  local mode="$1" expected="$2" prep watch artifact result
  prep=$(prepare "$mode"); watch=$(jq -r .watch_id <<<"$prep"); artifact=$(jq -r .artifact_path <<<"$prep")
  launch_bounded "$watch"; touch "$RELEASE"; wait_file "$artifact" || bad "$mode verdict missing"
  result=$("$SCRIPTS/merge-queue-watch" consume --root "$MAIN" --issue KEN-829)
  eq "$(jq -r .action <<<"$result")" "$expected" "$mode maps to $expected"
  if [[ "$mode" == dequeue_failed ]]; then
    eq "$(jq -r .verdict_cause <<<"$result")" late_findings_dequeue_failed "dequeue failure keeps its cause"
    eq "$(jq -r .error <<<"$result")" 'disable failed' "dequeue failure keeps producer error"
  fi
  "$SCRIPTS/merge-queue-watch" fail --root "$MAIN" --issue KEN-829 --watch-id "$watch" --cause operator_abandoned >/dev/null
}
echo "=== durable merge queue lifecycle ==="
prep=$(prepare merged); watch=$(jq -r .watch_id <<<"$prep"); artifact=$(jq -r .artifact_path <<<"$prep")
eq "$(jq -r .head_sha <<<"$prep")" "$HEAD_A" "prepare records exact head before arming"
pointer=$("$SCRIPTS/workflow-state" --state-dir "$WT/tmp" get KEN-829 .merge_queue_watch)
eq "$(jq -r .watch_id <<<"$pointer")" "$watch" "workflow state points at exact watch"
launch_bounded "$watch"
grep -Fxq "$MAIN|owner/repo|ghp_project" "$WATCH_WORKER_LOG" && ok "detached waiter enters persisted main repo with its project auth and repo scope" || bad "detached waiter lost main repo auth or scope"
if [[ ! -e "$artifact" ]]; then ok "no verdict exists before worker release"; else bad "partial verdict appeared"; fi
supervisor=$("$SCRIPTS/merge-queue-watch" inspect --root "$MAIN" --issue KEN-829 | jq -r .supervisor_pid)
if running "$supervisor"; then ok "supervisor survives the launch command boundary"; else bad "supervisor died at command boundary"; fi
touch "$RELEASE"; wait_file "$artifact" || bad "merged verdict was not published"
eq "$(jq -r .watch_id "$artifact")" "$watch" "artifact binds watch id"
eq "$(jq -r .expected_head "$artifact")" "$HEAD_A" "artifact binds expected head"
eq "$(jq -r .launch_attempt_id "$artifact")" "$("$SCRIPTS/merge-queue-watch" inspect --root "$MAIN" --issue KEN-829 | jq -r .launch_attempt_id)" "artifact binds launch attempt"
event_out=$("$SCRIPTS/merge-queue-watch" event --root "$MAIN" --issue KEN-829)
if [[ "$event_out" == ready* ]]; then ok "fleet event wakes the owner once verdict exists"; else bad "fleet event missing"; fi
event_again=$("$SCRIPTS/merge-queue-watch" event --root "$MAIN" --issue KEN-829)
eq "$event_again" "$event_out" "fleet wake remains level-triggered until consume"
result=$("$SCRIPTS/merge-queue-watch" consume --root "$MAIN" --issue KEN-829)
eq "$(jq -r .action <<<"$result")" postmerge "merged verdict claims postmerge action"
grep -Fxq ghp_project "$WATCH_AUTH_LOG" && ok "live PR reads use the shared project token ladder" || bad "live PR read bypassed project token"
replay=$("$SCRIPTS/merge-queue-watch" consume --root "$MAIN" --issue KEN-829)
eq "$(jq -r .action <<<"$replay")" resume_postmerge "claimed postmerge replays as an explicit resume phase"
"$SCRIPTS/merge-queue-watch" merge-pr-complete --root "$MAIN" --issue KEN-829 --watch-id "$watch" >/dev/null
eq "$("$SCRIPTS/merge-queue-watch" inspect --root "$MAIN" --issue KEN-829 | jq -r .status)" awaiting_lane_postmerge "merge-pr completion waits for lane acknowledgment"
replay=$("$SCRIPTS/merge-queue-watch" consume --root "$MAIN" --issue KEN-829)
eq "$(jq -r .action <<<"$replay")" lane_postmerge "awaiting phase cannot replay merge-pr poststeps"
set +e
"$SCRIPTS/merge-queue-watch" acknowledge --root "$MAIN" --issue KEN-829 --watch-id "$watch" --result pass >/dev/null 2>&1
early_ack_rc=$?
set -e
if [[ "$early_ack_rc" -ne 0 ]]; then ok "pass acknowledgment refuses before cleanup"; else bad "pass acknowledgment completed before cleanup"; fi
printf 'first postmerge stopped\n' > "$TMP/first.err"
"$SCRIPTS/merge-queue-watch" acknowledge --root "$MAIN" --issue KEN-829 --watch-id "$watch" --result fail --diagnostic-file "$TMP/first.err" >/dev/null
prep=$(prepare ejected review 0); watch=$(jq -r .watch_id <<<"$prep"); artifact=$(jq -r .artifact_path <<<"$prep")
launch_bounded "$watch"; touch "$RELEASE"; wait_file "$artifact" || bad "ejected verdict missing"
result=$("$SCRIPTS/merge-queue-watch" consume --root "$MAIN" --issue KEN-829)
eq "$(jq -r .action <<<"$result")" recovery "ejected verdict claims recovery"
eq "$(jq -r .recovery_count <<<"$result")" 1 "recovery claim increments durable count"
eq "$(jq -r .gate_mode <<<"$result")" review "recovery keeps gate mode across boundary"
replay=$("$SCRIPTS/merge-queue-watch" consume --root "$MAIN" --issue KEN-829)
eq "$(jq -r .action <<<"$replay")" resume_recovery "claimed recovery cannot replay the initial action"
set +e
prepare ejected off 0 >/dev/null 2>"$TMP/reset.err"
reset_rc=$?
set -e
if [[ "$reset_rc" -ne 0 ]]; then ok "next generation cannot reset gate mode or recovery count"; else bad "recovery context reset was accepted"; fi
prep=$(prepare ejected review 1); watch=$(jq -r .watch_id <<<"$prep"); artifact=$(jq -r .artifact_path <<<"$prep")
launch_bounded "$watch"; touch "$RELEASE"; wait_file "$artifact" || bad "cap verdict missing"
result=$(CI_FIX_MAX_CYCLES=1 "$SCRIPTS/merge-queue-watch" consume --root "$MAIN" --issue KEN-829)
eq "$(jq -r .status <<<"$result")" failed "recovery cap terminalizes state"
verdict_case disarmed recovery
verdict_case conflicting restack
verdict_case dequeued triage
verdict_case dequeue_failed manual_dequeue
verdict_case stalled recovery
verdict_case progressing rewatch
verdict_case not_queued rearm
prep=$(prepare dequeue_failed); watch=$(jq -r .watch_id <<<"$prep"); artifact=$(jq -r .artifact_path <<<"$prep")
launch_bounded "$watch"; touch "$RELEASE"; wait_file "$artifact" || bad "dequeue-race verdict missing"
printf 'merged\n' > "$MODE"
result=$("$SCRIPTS/merge-queue-watch" consume --root "$MAIN" --issue KEN-829)
eq "$(jq -r .action <<<"$result")" postmerge "live merged race outranks manual dequeue"
eq "$(jq -r .verdict_cause <<<"$result")" merged_race "merged dequeue race records its route"
"$SCRIPTS/merge-queue-watch" merge-pr-complete --root "$MAIN" --issue KEN-829 --watch-id "$watch" >/dev/null
printf 'race control complete\n' > "$TMP/race.err"
"$SCRIPTS/merge-queue-watch" acknowledge --root "$MAIN" --issue KEN-829 --watch-id "$watch" --result fail --diagnostic-file "$TMP/race.err" >/dev/null
prep=$(prepare merged); watch=$(jq -r .watch_id <<<"$prep"); artifact=$(jq -r .artifact_path <<<"$prep")
launch_bounded "$watch"; touch "$RELEASE"; wait_file "$artifact" || bad "head-mismatch verdict missing"
printf '%s\n' "$HEAD_B" > "$HEAD_FILE"
result=$("$SCRIPTS/merge-queue-watch" consume --root "$MAIN" --issue KEN-829)
eq "$(jq -r .status <<<"$result")" failed "live head mismatch blocks merged poststeps"
eq "$(jq -r .verdict_cause <<<"$result")" head_mismatch "head mismatch names the routing cause"
eq "$(jq -r .diagnostic.cause <<<"$result")" merged "head mismatch preserves the producer verdict"
printf '%s\n' "$HEAD_A" > "$HEAD_FILE"
prep=$(prepare malformed); watch=$(jq -r .watch_id <<<"$prep"); artifact=$(jq -r .artifact_path <<<"$prep")
launch_bounded "$watch"; touch "$RELEASE"; wait_file "$artifact" || bad "malformed-worker error artifact missing"
result=$("$SCRIPTS/merge-queue-watch" consume --root "$MAIN" --issue KEN-829)
eq "$(jq -r .status <<<"$result")" failed "unknown worker output terminalizes failed"
eq "$(jq -r .worker_exit_code <<<"$result")" 7 "unknown output preserves worker exit"
if [[ "$(jq -r .diagnostic_path <<<"$result")" == /* ]]; then ok "unknown output preserves absolute producer diagnostics"; else bad "unknown output lost diagnostics"; fi
prep=$(prepare closed); watch=$(jq -r .watch_id <<<"$prep"); artifact=$(jq -r .artifact_path <<<"$prep")
launch_bounded "$watch"; touch "$RELEASE"; wait_file "$artifact" || bad "closed verdict missing"
result=$("$SCRIPTS/merge-queue-watch" consume --root "$MAIN" --issue KEN-829)
eq "$(jq -r .status <<<"$result")" abandoned "closed verdict terminalizes abandoned"
prep=$(prepare merged); watch=$(jq -r .watch_id <<<"$prep")
result=$("$SCRIPTS/merge-queue-watch" consume --root "$MAIN" --issue KEN-829)
eq "$(jq -r .diagnostic.cause <<<"$result")" watch_lost "missing stale artifact fails closed"
prep=$(prepare merged); watch=$(jq -r .watch_id <<<"$prep")
"$SCRIPTS/merge-queue-watch" fail --root "$MAIN" --issue KEN-829 --watch-id "$watch" --cause arm_failed >/dev/null
set +e
"$SCRIPTS/merge-queue-watch" launch --root "$MAIN" --issue KEN-829 --watch-id "$watch" >/dev/null 2>&1
revive_rc=$?
set -e
if [[ "$revive_rc" -ne 0 ]]; then ok "failed prepared state cannot be revived by launch"; else bad "launch revived failed state"; fi
prep=$(prepare merged); watch=$(jq -r .watch_id <<<"$prep")
touch "$WATCH_GH_PAUSE.enabled"
"$SCRIPTS/merge-queue-watch" direct-merged --root "$MAIN" --issue KEN-829 --watch-id "$watch" >"$TMP/direct.out" 2>"$TMP/direct.err" & direct_pid=$!
wait_exists "$WATCH_GH_PAUSE.entered" || bad "direct merge did not enter validation gate"
"$SCRIPTS/merge-queue-watch" fail --root "$MAIN" --issue KEN-829 --watch-id "$watch" --cause arm_failed >/dev/null
touch "$WATCH_GH_PAUSE.release"
set +e; wait "$direct_pid"; direct_rc=$?; set -e
if [[ "$direct_rc" -ne 0 ]]; then ok "fail wins against an in-flight direct merge claim"; else bad "direct merge revived failed state"; fi
rm -f "$WATCH_GH_PAUSE.enabled" "$WATCH_GH_PAUSE.entered" "$WATCH_GH_PAUSE.release"
if [[ -n "$REAL_SETSID" ]]; then
  prep=$(prepare merged); watch=$(jq -r .watch_id <<<"$prep")
  touch "$WATCH_SETUP_GATE.enabled"
  "$SCRIPTS/merge-queue-watch" launch --root "$MAIN" --issue KEN-829 --watch-id "$watch" --poll 1 --max-wait 10 >"$TMP/gated-launch.out" 2>"$TMP/gated-launch.err" & gated_pid=$!
  wait_exists "$WATCH_SETUP_GATE.entered" || bad "launch did not enter setup gate"
  set +e; early_event=$("$SCRIPTS/merge-queue-watch" event --root "$MAIN" --issue KEN-829); early_rc=$?; set -e
  if [[ "$early_rc" -ne 0 && -z "$early_event" ]]; then ok "fleet event ignores owned launch setup"; else bad "fleet event raced launch setup"; fi
  touch "$WATCH_SETUP_GATE.release"; wait "$gated_pid"
  eq "$("$SCRIPTS/merge-queue-watch" inspect --root "$MAIN" --issue KEN-829 | jq -r .status)" watching "launch owns setup through watching transition"
  "$SCRIPTS/merge-queue-watch" fail --root "$MAIN" --issue KEN-829 --watch-id "$watch" --cause operator_abandoned >/dev/null
  rm -f "$WATCH_SETUP_GATE.enabled" "$WATCH_SETUP_GATE.entered" "$WATCH_SETUP_GATE.release"
  prep=$(prepare merged); watch=$(jq -r .watch_id <<<"$prep")
  touch "$WATCH_SETSID_FAIL"
  set +e; "$SCRIPTS/merge-queue-watch" launch --root "$MAIN" --issue KEN-829 --watch-id "$watch" >/dev/null 2>&1; setsid_rc=$?; set -e
  [[ "$setsid_rc" -ne 0 ]] && ok "detached launcher failure exits nonzero" || bad "detached launcher failure reported success"
  replay=$("$SCRIPTS/merge-queue-watch" consume --root "$MAIN" --issue KEN-829)
  eq "$(jq -r .action <<<"$replay")" resume_launch "post-arm launcher failure remains recoverable"
  rm -f "$WATCH_SETSID_FAIL"
  launch_bounded "$watch"
  "$SCRIPTS/merge-queue-watch" fail --root "$MAIN" --issue KEN-829 --watch-id "$watch" --cause operator_abandoned >/dev/null
else
  ok "launch setup race control skipped without setsid"
fi
prep=$(prepare merged); watch=$(jq -r .watch_id <<<"$prep")
state_path=$("$SCRIPTS/workflow-state" --state-dir "$WT/tmp" get KEN-829 .merge_queue_watch.state_path)
jq --arg attempt "$watch-attempt-1" --arg token "$watch-attempt-1-test" '.launch_attempt=1|.launch_attempt_id=$attempt|.supervisor_token=$token|.status="launching"|.setup_deadline=0|.deadline=((now|floor)+600)' "$state_path" > "$TMP/orphan.json"
chmod 600 "$TMP/orphan.json"; mv "$TMP/orphan.json" "$state_path"
result=$("$SCRIPTS/merge-queue-watch" consume --root "$MAIN" --issue KEN-829)
eq "$(jq -r .action <<<"$result")" resume_launch "orphaned launching state wakes into launch recovery"
"$SCRIPTS/merge-queue-watch" fail --root "$MAIN" --issue KEN-829 --watch-id "$watch" --cause operator_abandoned >/dev/null

prep=$(prepare merged); watch=$(jq -r .watch_id <<<"$prep")
launch_bounded "$watch"
state_path=$("$SCRIPTS/workflow-state" --state-dir "$WT/tmp" get KEN-829 .merge_queue_watch.state_path)
jq '.status="launching"|.setup_deadline=((now|floor)+10)' "$state_path" > "$TMP/live-launch.json"
chmod 600 "$TMP/live-launch.json"; mv "$TMP/live-launch.json" "$state_path"
result=$("$SCRIPTS/merge-queue-watch" consume --root "$MAIN" --issue KEN-829)
eq "$(jq -r .action <<<"$result")" pending "live supervisor stays pending inside setup race window"
eq "$("$SCRIPTS/merge-queue-watch" inspect --root "$MAIN" --issue KEN-829 | jq -r .status)" launching "consumer does not steal an active launch transition"
jq '.setup_deadline=0' "$state_path" > "$TMP/live-launch-expired.json"
chmod 600 "$TMP/live-launch-expired.json"; mv "$TMP/live-launch-expired.json" "$state_path"
event_out=$("$SCRIPTS/merge-queue-watch" event --root "$MAIN" --issue KEN-829)
[[ "$event_out" == ready* ]] && ok "expired orphaned launch wakes despite live supervisor" || bad "expired orphaned launch did not wake"
result=$("$SCRIPTS/merge-queue-watch" consume --root "$MAIN" --issue KEN-829)
eq "$(jq -r .action <<<"$result")" pending "expired orphaned launch adopts the live supervisor"
eq "$("$SCRIPTS/merge-queue-watch" inspect --root "$MAIN" --issue KEN-829 | jq -r .status)" watching "orphaned live supervisor becomes watching"
"$SCRIPTS/merge-queue-watch" fail --root "$MAIN" --issue KEN-829 --watch-id "$watch" --cause operator_abandoned >/dev/null

prep=$(prepare merged); watch=$(jq -r .watch_id <<<"$prep"); artifact=$(jq -r .artifact_path <<<"$prep")
state_path=$("$SCRIPTS/workflow-state" --state-dir "$WT/tmp" get KEN-829 .merge_queue_watch.state_path)
jq --arg attempt "$watch-attempt-1" --arg token "$watch-attempt-1-test" '.launch_attempt=1|.launch_attempt_id=$attempt|.supervisor_token=$token|.status="launching"|.setup_deadline=((now|floor)+10)|.deadline=((now|floor)+600)' "$state_path" > "$TMP/completed-launch.json"
chmod 600 "$TMP/completed-launch.json"; mv "$TMP/completed-launch.json" "$state_path"
jq -n --arg watch "$watch" --arg attempt "$watch-attempt-1" --arg head "$HEAD_A" '{schema_version:1,status:"complete",verdict:"merged",repository:"owner/repo",pr_number:42,expected_head:$head,watch_id:$watch,launch_attempt_id:$attempt}' > "$artifact"
result=$("$SCRIPTS/merge-queue-watch" consume --root "$MAIN" --issue KEN-829)
eq "$(jq -r .action <<<"$result")" postmerge "completed artifact outranks launching setup state"
"$SCRIPTS/merge-queue-watch" merge-pr-complete --root "$MAIN" --issue KEN-829 --watch-id "$watch" >/dev/null
printf 'launch artifact control complete\n' > "$TMP/launch-artifact.err"
"$SCRIPTS/merge-queue-watch" acknowledge --root "$MAIN" --issue KEN-829 --watch-id "$watch" --result fail --diagnostic-file "$TMP/launch-artifact.err" >/dev/null

prep=$(prepare merged); watch=$(jq -r .watch_id <<<"$prep")
launch_bounded "$watch"; supervisor=$("$SCRIPTS/merge-queue-watch" inspect --root "$MAIN" --issue KEN-829 | jq -r .supervisor_pid)
state_path=$("$SCRIPTS/workflow-state" --state-dir "$WT/tmp" get KEN-829 .merge_queue_watch.state_path)
jq '.deadline=0' "$state_path" > "$TMP/expired.json"; chmod 600 "$TMP/expired.json"; mv "$TMP/expired.json" "$state_path"
result=$("$SCRIPTS/merge-queue-watch" consume --root "$MAIN" --issue KEN-829)
eq "$(jq -r .diagnostic.cause <<<"$result")" watch_lost "overdue live supervisor fails closed"
if ! running "$supervisor"; then ok "overdue verified supervisor is terminated"; else bad "overdue supervisor survived consume"; fi

prep=$(prepare merged); watch=$(jq -r .watch_id <<<"$prep"); artifact=$(jq -r .artifact_path <<<"$prep")
launch_bounded "$watch"; supervisor=$("$SCRIPTS/merge-queue-watch" inspect --root "$MAIN" --issue KEN-829 | jq -r .supervisor_pid)
kill -TERM "$supervisor"; wait_file "$artifact" || bad "signaled supervisor did not publish error"
printf 'ejected\n' > "$MODE"
result=$("$SCRIPTS/merge-queue-watch" consume --root "$MAIN" --issue KEN-829)
eq "$(jq -r .status <<<"$result")" failed "supervisor signal becomes terminal failed"
if [[ "$(jq -r .diagnostic_path "$artifact")" == /* ]]; then ok "signal artifact preserves absolute diagnostics"; else bad "signal artifact diagnostic path is not absolute"; fi

prep=$(prepare merged); watch=$(jq -r .watch_id <<<"$prep")
mv "$SCRIPTS/queue-wait" "$SCRIPTS/queue-wait.off"
set +e
setup_error=$("$SCRIPTS/merge-queue-watch" launch --root "$MAIN" --issue KEN-829 --watch-id "$watch" 2>&1)
setup_rc=$?
set -e
mv "$SCRIPTS/queue-wait.off" "$SCRIPTS/queue-wait"
if [[ "$setup_rc" -ne 0 ]]; then ok "setup failure exits nonzero"; else bad "setup failure exited zero"; fi
if [[ "$setup_error" == *"$SCRIPTS/queue-wait"* && "$setup_error" == *"diagnostics:"* ]]; then ok "setup failure preserves absolute diagnostics"; else bad "setup failure diagnostic is incomplete"; fi
eq "$("$SCRIPTS/merge-queue-watch" inspect --root "$MAIN" --issue KEN-829 | jq -r .status)" launch_failed "setup failure remains an active lifecycle"
replay=$("$SCRIPTS/merge-queue-watch" consume --root "$MAIN" --issue KEN-829)
eq "$(jq -r .action <<<"$replay")" resume_launch "setup failure cannot hand back before launch recovery"
registered_runtime=$("$SCRIPTS/merge-queue-watch" inspect --root "$MAIN" --issue KEN-829 | jq -r .runtime_dir); touch "$registered_runtime/registered-marker"
launch_bounded "$watch"
[[ -e "$registered_runtime/registered-marker" ]] && ok "registered attempt runtime is never reclaimed" || bad "retry reclaimed registered attempt runtime"
eq "$("$SCRIPTS/merge-queue-watch" inspect --root "$MAIN" --issue KEN-829 | jq -r .status)" watching "same watch retries after setup repair"
"$SCRIPTS/merge-queue-watch" fail --root "$MAIN" --issue KEN-829 --watch-id "$watch" --cause operator_abandoned >/dev/null

prep=$(prepare ejected); watch=$(jq -r .watch_id <<<"$prep"); artifact=$(jq -r .artifact_path <<<"$prep")
state_path=$("$SCRIPTS/workflow-state" --state-dir "$WT/tmp" get KEN-829 .merge_queue_watch.state_path)
rm -f -- "$WATCH_SUPERVISOR_PID_GATE.entered" "$WATCH_SUPERVISOR_PID_GATE.release" "$WATCH_SUPERVISOR_PID_GATE.calls" "$WATCH_SUPERVISOR_PID_GATE.observed-status"
touch "$WATCH_SUPERVISOR_PID_GATE.enabled"
export WATCH_SUPERVISOR_PID_GATE_STATE="$state_path"
export MERGE_QUEUE_FORCE_PS_IDENTITY=1
set +e
"$SCRIPTS/merge-queue-watch" launch --root "$MAIN" --issue KEN-829 --watch-id "$watch" --poll 1 --max-wait 10 >/dev/null 2>&1
setup_rc=$?
set -e
unset MERGE_QUEUE_FORCE_PS_IDENTITY
unset WATCH_SUPERVISOR_PID_GATE_STATE
wait_exists "$WATCH_SUPERVISOR_PID_GATE.entered" && ok "supervisor setup entered the explicit delay gate" || bad "supervisor setup bypassed the explicit delay gate"
wait_exists "$WATCH_SUPERVISOR_PID_GATE.release" && ok "teardown released the delayed supervisor" || bad "teardown never released the delayed supervisor"
eq "$(cat < "$WATCH_SUPERVISOR_PID_GATE.observed-status")" launch_failed "launch failure claims state before supervisor teardown"
rm -f -- "$WATCH_SUPERVISOR_PID_GATE.enabled" "$WATCH_SUPERVISOR_PID_GATE.entered" "$WATCH_SUPERVISOR_PID_GATE.release" "$WATCH_SUPERVISOR_PID_GATE.calls" "$WATCH_SUPERVISOR_PID_GATE.observed-status"
if [[ "$setup_rc" -ne 0 ]]; then ok "supervisor failure before ready exits nonzero"; else bad "supervisor failure before ready exited zero"; fi
eq "$(jq -r .verdict "$artifact")" unknown "dead supervisor publishes its setup failure"
old_inode=$(inode "$artifact")
retry_state=$("$SCRIPTS/merge-queue-watch" inspect --root "$MAIN" --issue KEN-829); runtime_root=$(jq -r .runtime_root <<<"$retry_state"); outside_runtime="$(dirname "$(dirname "$runtime_root")")/outside-attempt-2"; mismatch_runtime="$runtime_root/other-watch-attempt-2"
mkdir "$outside_runtime" "$mismatch_runtime"; touch "$outside_runtime/sentinel" "$mismatch_runtime/sentinel"
set +e; "$SCRIPTS/merge-queue-watch" launch --root "$MAIN" --issue KEN-829 --watch-id ../../outside --poll 1 --max-wait 10 >/dev/null 2>&1; traversal_rc=$?; "$SCRIPTS/merge-queue-watch" launch --root "$MAIN" --issue KEN-829 --watch-id other-watch --poll 1 --max-wait 10 >/dev/null 2>&1; mismatch_rc=$?; set -e
[[ "$traversal_rc" -ne 0 && -e "$outside_runtime/sentinel" ]] && ok "traversal watch id cannot change an external attempt path" || bad "traversal watch id changed an external attempt path"
[[ "$mismatch_rc" -ne 0 && -e "$mismatch_runtime/sentinel" ]] && ok "mismatched watch id cannot change an attempt path" || bad "mismatched watch id changed an attempt path"
reserved_runtime="$runtime_root/$watch-attempt-2"; mkdir "$reserved_runtime"; touch "$reserved_runtime/interrupted-marker"
launch_bounded "$watch"
[[ ! -e "$reserved_runtime/interrupted-marker" ]] && ok "retry reclaims only unregistered attempt runtime" || bad "interrupted reservation wedged retry"
retry_artifact=$("$SCRIPTS/merge-queue-watch" inspect --root "$MAIN" --issue KEN-829 | jq -r .artifact_path)
[[ "$retry_artifact" != "$artifact" ]] && ok "retry reserves a fresh artifact identity" || bad "retry reused the dead supervisor artifact"
touch "$RELEASE"; wait_file "$retry_artifact" || bad "retried supervisor verdict missing"
eq "$(jq -r .verdict "$retry_artifact")" ejected "retry publishes the new supervisor verdict"
eq "$(jq -r .verdict "$artifact")" unknown "retry preserves the dead supervisor artifact"
[[ "$(inode "$retry_artifact")" != "$old_inode" ]] && ok "retry artifact has its own inode" || bad "retry artifact reused the dead supervisor output inode"
result=$("$SCRIPTS/merge-queue-watch" consume --root "$MAIN" --issue KEN-829)
eq "$(jq -r .action <<<"$result")" recovery "consume routes the retried supervisor verdict"
"$SCRIPTS/merge-queue-watch" fail --root "$MAIN" --issue KEN-829 --watch-id "$watch" --cause operator_abandoned >/dev/null

prep=$(prepare ejected); watch=$(jq -r .watch_id <<<"$prep"); artifact=$(jq -r .artifact_path <<<"$prep")
launch_bounded "$watch"; touch "$RELEASE"; wait_file "$artifact" || bad "stale-consume fixture verdict missing"
touch "$WATCH_GH_PAUSE.enabled"
"$SCRIPTS/merge-queue-watch" consume --root "$MAIN" --issue KEN-829 >"$TMP/stale-consume.out" 2>"$TMP/stale-consume.err" & stale_consume_pid=$!
wait_exists "$WATCH_GH_PAUSE.entered" || bad "consume did not capture the old launch attempt"
state_path=$("$SCRIPTS/workflow-state" --state-dir "$WT/tmp" get KEN-829 .merge_queue_watch.state_path)
jq '.status="launch_failed"|.action="launch"|.supervisor_pid=null' "$state_path" > "$TMP/stale-consume-state.json"
chmod 600 "$TMP/stale-consume-state.json"; mv "$TMP/stale-consume-state.json" "$state_path"
launch_bounded "$watch"
replacement_artifact=$("$SCRIPTS/merge-queue-watch" inspect --root "$MAIN" --issue KEN-829 | jq -r .artifact_path)
touch "$WATCH_GH_PAUSE.release"
set +e; wait "$stale_consume_pid"; stale_consume_rc=$?; set -e
[[ "$stale_consume_rc" -ne 0 ]] && ok "stale consume cannot claim the replacement attempt" || bad "stale consume claimed across the launch-attempt fence"
eq "$("$SCRIPTS/merge-queue-watch" inspect --root "$MAIN" --issue KEN-829 | jq -r .status)" watching "stale consume leaves the replacement attempt active"
wait_file "$replacement_artifact" || bad "replacement verdict missing after stale consume"
result=$("$SCRIPTS/merge-queue-watch" consume --root "$MAIN" --issue KEN-829)
eq "$(jq -r .action <<<"$result")" recovery "replacement verdict survives stale consume"
"$SCRIPTS/merge-queue-watch" fail --root "$MAIN" --issue KEN-829 --watch-id "$watch" --cause operator_abandoned >/dev/null
rm -f -- "$WATCH_GH_PAUSE.enabled" "$WATCH_GH_PAUSE.entered" "$WATCH_GH_PAUSE.release"

old_release="$TMP/publication-old-release"; new_release="$TMP/publication-new-release"
rm -f -- "$old_release" "$new_release"
export WATCH_RELEASE="$old_release"
prep=$(prepare ejected); watch=$(jq -r .watch_id <<<"$prep"); artifact=$(jq -r .artifact_path <<<"$prep")
launch_bounded "$watch"
state_path=$("$SCRIPTS/workflow-state" --state-dir "$WT/tmp" get KEN-829 .merge_queue_watch.state_path)
jq '.status="launch_failed"|.action="launch"|.supervisor_pid=null' "$state_path" > "$TMP/publication-state.json"
chmod 600 "$TMP/publication-state.json"; mv "$TMP/publication-state.json" "$state_path"
export WATCH_RELEASE="$new_release"
launch_bounded "$watch"
publication_replacement=$("$SCRIPTS/merge-queue-watch" inspect --root "$MAIN" --issue KEN-829 | jq -r .artifact_path)
touch "$new_release"; wait_file "$publication_replacement" || bad "publication-fence replacement verdict missing"
touch "$old_release"; sleep 0.5
[[ ! -e "$artifact" ]] && ok "stale started supervisor cannot publish after replacement" || bad "publication fence admitted the stale started supervisor"
eq "$(jq -r .verdict "$publication_replacement")" ejected "stale publication leaves the replacement verdict intact"
result=$("$SCRIPTS/merge-queue-watch" consume --root "$MAIN" --issue KEN-829)
eq "$(jq -r .action <<<"$result")" recovery "replacement verdict survives stale publication"
"$SCRIPTS/merge-queue-watch" fail --root "$MAIN" --issue KEN-829 --watch-id "$watch" --cause operator_abandoned >/dev/null
export WATCH_RELEASE="$RELEASE"

if [[ -n "$REAL_SETSID" ]]; then
  prep=$(prepare ejected); watch=$(jq -r .watch_id <<<"$prep"); artifact=$(jq -r .artifact_path <<<"$prep")
  delayed_runtime=$("$SCRIPTS/merge-queue-watch" inspect --root "$MAIN" --issue KEN-829 | jq -r .runtime_dir)
  touch "$WATCH_SETSID_DELAY.enabled"
  set +e; "$SCRIPTS/merge-queue-watch" launch --root "$MAIN" --issue KEN-829 --watch-id "$watch" --poll 1 --max-wait 10 >/dev/null 2>&1; delayed_rc=$?; set -e
  [[ "$delayed_rc" -ne 0 ]] && ok "pre-PID supervisor delay enters launch recovery" || bad "pre-PID supervisor delay reported success"
  wait_exists "$WATCH_SETSID_DELAY.entered" || bad "pre-PID supervisor did not enter its delay gate"
  rm -f -- "$WATCH_SETSID_DELAY.enabled"
  launch_bounded "$watch"
  delayed_replacement_artifact=$("$SCRIPTS/merge-queue-watch" inspect --root "$MAIN" --issue KEN-829 | jq -r .artifact_path)
  delayed_replacement_runtime=$("$SCRIPTS/merge-queue-watch" inspect --root "$MAIN" --issue KEN-829 | jq -r .runtime_dir)
  [[ "$delayed_replacement_runtime" != "$delayed_runtime" ]] && ok "replacement attempt has its own runtime directory" || bad "replacement reused the delayed supervisor runtime"
  touch "$RELEASE"
  wait_file "$delayed_replacement_artifact" || bad "replacement verdict missing after delayed supervisor release"
  worker_count=$(wc -l < "$WATCH_WORKER_LOG")
  printf 'malformed\n' > "$MODE"
  touch "$WATCH_SETSID_DELAY.release"
  sleep 0.5
  eq "$(wc -l < "$WATCH_WORKER_LOG")" "$worker_count" "unregistered delayed supervisor cannot start a worker"
  [[ ! -e "$artifact" ]] && ok "unregistered delayed supervisor cannot publish into retry files" || bad "unregistered delayed supervisor published after retry"
  eq "$(jq -r .verdict "$delayed_replacement_artifact")" ejected "unregistered delayed supervisor cannot rewrite the replacement verdict"
  printf 'ejected\n' > "$MODE"
  result=$("$SCRIPTS/merge-queue-watch" consume --root "$MAIN" --issue KEN-829)
  eq "$(jq -r .action <<<"$result")" recovery "replacement verdict wins after delayed supervisor release"
  "$SCRIPTS/merge-queue-watch" fail --root "$MAIN" --issue KEN-829 --watch-id "$watch" --cause operator_abandoned >/dev/null
  rm -f -- "$WATCH_SETSID_DELAY.entered" "$WATCH_SETSID_DELAY.release"
else
  ok "pre-PID supervisor fence skipped without setsid"
fi

prep=$(prepare ejected); watch=$(jq -r .watch_id <<<"$prep")
launch_bounded "$watch"
state_path=$("$SCRIPTS/workflow-state" --state-dir "$WT/tmp" get KEN-829 .merge_queue_watch.state_path)
old_attempt=$(jq -r .launch_attempt_id "$state_path"); old_runtime=$(jq -r .runtime_dir "$state_path"); old_artifact=$(jq -r .artifact_path "$state_path")
old_supervisor=$(jq -r .supervisor_pid "$state_path")
touch "$WATCH_FAIL_FLOCK_GATE.enabled"
"$SCRIPTS/merge-queue-watch" fail --root "$MAIN" --issue KEN-829 --watch-id "$watch" --cause operator_abandoned >"$TMP/fail-race.out" 2>"$TMP/fail-race.err" & fail_race_pid=$!
wait_exists "$WATCH_FAIL_FLOCK_GATE.entered" || bad "fail command did not pause after generation capture"
jq '.status="launch_failed"|.action="launch"|.supervisor_pid=null' "$state_path" > "$TMP/fail-race-state.json"
chmod 600 "$TMP/fail-race-state.json"; mv "$TMP/fail-race-state.json" "$state_path"
launch_bounded "$watch"
replacement_supervisor=$("$SCRIPTS/merge-queue-watch" inspect --root "$MAIN" --issue KEN-829 | jq -r .supervisor_pid)
replacement_artifact=$("$SCRIPTS/merge-queue-watch" inspect --root "$MAIN" --issue KEN-829 | jq -r .artifact_path)
touch "$WATCH_FAIL_FLOCK_GATE.release"
set +e; wait "$fail_race_pid"; fail_race_rc=$?; set -e
[[ "$fail_race_rc" -ne 0 ]] && ok "stale fail refuses after retry registration" || bad "stale fail reported success across retry"
eq "$("$SCRIPTS/merge-queue-watch" inspect --root "$MAIN" --issue KEN-829 | jq -r .status)" watching "stale fail leaves replacement state active"
running "$replacement_supervisor" && ok "stale fail does not signal replacement supervisor" || bad "stale fail signaled replacement supervisor"
running "$old_supervisor" && ok "stale fail does not confuse captured supervisor identity" || bad "stale fail signaled its captured supervisor after claim loss"
touch "$RELEASE"; wait_file "$replacement_artifact" || bad "replacement verdict missing after stale fail"
result=$("$SCRIPTS/merge-queue-watch" consume --root "$MAIN" --issue KEN-829)
eq "$(jq -r .action <<<"$result")" recovery "replacement verdict survives stale fail"
"$SCRIPTS/merge-queue-watch" fail --root "$MAIN" --issue KEN-829 --watch-id "$watch" --cause operator_abandoned >/dev/null
rm -f -- "$WATCH_FAIL_FLOCK_GATE.entered" "$WATCH_FAIL_FLOCK_GATE.release"

prep=$(prepare ejected); watch=$(jq -r .watch_id <<<"$prep")
launch_bounded "$watch"
state_path=$("$SCRIPTS/workflow-state" --state-dir "$WT/tmp" get KEN-829 .merge_queue_watch.state_path)
attempt=$(jq -r .launch_attempt_id "$state_path"); runtime=$(jq -r .runtime_dir "$state_path"); artifact=$(jq -r .artifact_path "$state_path")
bash -c 'while :; do sleep 1; done' "$SCRIPTS/merge-queue-watch" __supervise "$state_path" "$watch" "${attempt}0" "$runtime" "$artifact" 999 "$SCRIPTS/queue-wait" 1 10 & similar_attempt_pid=$!
jq --argjson pid "$similar_attempt_pid" '.supervisor_pid=$pid' "$state_path" > "$TMP/similar-attempt-state.json"
chmod 600 "$TMP/similar-attempt-state.json"; mv "$TMP/similar-attempt-state.json" "$state_path"
"$SCRIPTS/merge-queue-watch" fail --root "$MAIN" --issue KEN-829 --watch-id "$watch" --cause operator_abandoned >/dev/null
running "$similar_attempt_pid" && ok "attempt identity compares argv fields exactly" || bad "attempt-1 matched and signaled attempt-10"
kill "$similar_attempt_pid" 2>/dev/null || true; wait "$similar_attempt_pid" 2>/dev/null || true
touch "$RELEASE"

prep=$(prepare ejected); watch=$(jq -r .watch_id <<<"$prep")
launch_bounded "$watch"
state_path=$("$SCRIPTS/workflow-state" --state-dir "$WT/tmp" get KEN-829 .merge_queue_watch.state_path)
fallback_supervisor=$(jq -r .supervisor_pid "$state_path")
ps_calls=$(wc -l < "$WATCH_PS_LOG")
export MERGE_QUEUE_FORCE_PS_IDENTITY=1
"$SCRIPTS/merge-queue-watch" fail --root "$MAIN" --issue KEN-829 --watch-id "$watch" --cause operator_abandoned >/dev/null
[[ "$(wc -l < "$WATCH_PS_LOG")" -gt "$ps_calls" ]] && ok "forced whitespace identity check invokes ps" || bad "forced whitespace identity check bypassed ps"
if ! running "$fallback_supervisor"; then ok "ps environment identity supports repository paths with spaces"; else bad "ps fallback rejected a valid supervisor under a whitespace path"; fi
unset MERGE_QUEUE_FORCE_PS_IDENTITY
touch "$RELEASE"

prep=$(prepare ejected); watch=$(jq -r .watch_id <<<"$prep")
launch_bounded "$watch"
state_path=$("$SCRIPTS/workflow-state" --state-dir "$WT/tmp" get KEN-829 .merge_queue_watch.state_path)
attempt=$(jq -r .launch_attempt_id "$state_path"); runtime=$(jq -r .runtime_dir "$state_path"); artifact=$(jq -r .artifact_path "$state_path"); identity=$(jq -r .supervisor_token "$state_path")
env "MERGE_QUEUE_SUPERVISOR_TOKEN=${identity}0" bash -c 'while :; do sleep 1; done' "$SCRIPTS/merge-queue-watch" __supervise "$state_path" "$watch" "$attempt" "$runtime" "$artifact" 999 "$SCRIPTS/queue-wait" 1 10 & similar_identity_pid=$!
jq --argjson pid "$similar_identity_pid" '.supervisor_pid=$pid' "$state_path" > "$TMP/similar-identity-state.json"
chmod 600 "$TMP/similar-identity-state.json"; mv "$TMP/similar-identity-state.json" "$state_path"
ps_calls=$(wc -l < "$WATCH_PS_LOG")
export MERGE_QUEUE_FORCE_PS_IDENTITY=1
"$SCRIPTS/merge-queue-watch" fail --root "$MAIN" --issue KEN-829 --watch-id "$watch" --cause operator_abandoned >/dev/null
[[ "$(wc -l < "$WATCH_PS_LOG")" -gt "$ps_calls" ]] && ok "forced similar-generation check invokes ps" || bad "forced similar-generation check bypassed ps"
running "$similar_identity_pid" && ok "ps environment identity rejects a similar generation" || bad "ps fallback matched a similar generation token"
unset MERGE_QUEUE_FORCE_PS_IDENTITY
kill "$similar_identity_pid" 2>/dev/null || true; wait "$similar_identity_pid" 2>/dev/null || true
touch "$RELEASE"

prep=$(prepare ejected); watch=$(jq -r .watch_id <<<"$prep")
launch_bounded "$watch"
state_path=$("$SCRIPTS/workflow-state" --state-dir "$WT/tmp" get KEN-829 .merge_queue_watch.state_path)
attempt=$(jq -r .launch_attempt_id "$state_path"); runtime=$(jq -r .runtime_dir "$state_path"); artifact=$(jq -r .artifact_path "$state_path"); identity=$(jq -r .supervisor_token "$state_path")
identity_changed="$TMP/identity-changed"
env "WATCH_IDENTITY_CHANGED=$identity_changed" "MERGE_QUEUE_SUPERVISOR_TOKEN=$identity" bash -c 'trap '\''touch "$WATCH_IDENTITY_CHANGED"; exec env -u MERGE_QUEUE_SUPERVISOR_TOKEN sleep 30'\'' TERM; while :; do sleep 1; done' "$SCRIPTS/merge-queue-watch" __supervise "$state_path" "$watch" "$attempt" "$runtime" "$artifact" 999 "$SCRIPTS/queue-wait" 1 10 & changed_identity_pid=$!
jq --argjson pid "$changed_identity_pid" '.supervisor_pid=$pid' "$state_path" > "$TMP/changed-identity-state.json"
chmod 600 "$TMP/changed-identity-state.json"; mv "$TMP/changed-identity-state.json" "$state_path"
ps_calls=$(wc -l < "$WATCH_PS_LOG")
export MERGE_QUEUE_FORCE_PS_IDENTITY=1
"$SCRIPTS/merge-queue-watch" fail --root "$MAIN" --issue KEN-829 --watch-id "$watch" --cause operator_abandoned >/dev/null
[[ "$(wc -l < "$WATCH_PS_LOG")" -gt "$ps_calls" ]] && ok "forced identity-change check invokes ps" || bad "forced identity-change check bypassed ps"
wait_exists "$identity_changed" && ok "teardown sent TERM to the captured identity" || bad "teardown never signaled the captured identity"
running "$changed_identity_pid" && ok "teardown stops when the PID changes identity" || bad "teardown escalated KILL after identity changed"
unset MERGE_QUEUE_FORCE_PS_IDENTITY
kill "$changed_identity_pid" 2>/dev/null || true; wait "$changed_identity_pid" 2>/dev/null || true
touch "$RELEASE"

prep=$(prepare ejected); watch=$(jq -r .watch_id <<<"$prep")
launch_bounded "$watch"
state_path=$("$SCRIPTS/workflow-state" --state-dir "$WT/tmp" get KEN-829 .merge_queue_watch.state_path)
worker_pid=$(cat < "$WATCH_WORKER_PID")
eq "$(cat < "$WATCH_WORKER_TOKEN")" unset "queue-wait worker does not inherit supervisor identity"
jq --argjson pid "$worker_pid" '.supervisor_pid=$pid' "$state_path" > "$TMP/worker-pid-state.json"
chmod 600 "$TMP/worker-pid-state.json"; mv "$TMP/worker-pid-state.json" "$state_path"
export MERGE_QUEUE_FORCE_PS_IDENTITY=1
"$SCRIPTS/merge-queue-watch" fail --root "$MAIN" --issue KEN-829 --watch-id "$watch" --cause operator_abandoned >/dev/null
running "$worker_pid" && ok "reused worker PID cannot identify as supervisor" || bad "supervisor teardown signaled queue-wait descendant"
unset MERGE_QUEUE_FORCE_PS_IDENTITY
touch "$RELEASE"

prep=$(prepare ejected); watch=$(jq -r .watch_id <<<"$prep")
launch_bounded "$watch"
state_path=$("$SCRIPTS/workflow-state" --state-dir "$WT/tmp" get KEN-829 .merge_queue_watch.state_path)
identity=$(jq -r .supervisor_token "$state_path")
env "MERGE_QUEUE_SUPERVISOR_TOKEN=$identity" bash -c 'while :; do sleep 1; done' "$SCRIPTS/queue-wait" 42 1 10 --json & wrong_command_pid=$!
jq --argjson pid "$wrong_command_pid" '.supervisor_pid=$pid' "$state_path" > "$TMP/wrong-command-state.json"
chmod 600 "$TMP/wrong-command-state.json"; mv "$TMP/wrong-command-state.json" "$state_path"
export MERGE_QUEUE_FORCE_PS_IDENTITY=1
"$SCRIPTS/merge-queue-watch" fail --root "$MAIN" --issue KEN-829 --watch-id "$watch" --cause operator_abandoned >/dev/null
running "$wrong_command_pid" && ok "ps fallback requires supervisor command identity" || bad "ps fallback accepted non-supervisor command"
unset MERGE_QUEUE_FORCE_PS_IDENTITY
kill "$wrong_command_pid" 2>/dev/null || true; wait "$wrong_command_pid" 2>/dev/null || true
touch "$RELEASE"

prep=$(prepare ejected); watch=$(jq -r .watch_id <<<"$prep")
state_path=$("$SCRIPTS/workflow-state" --state-dir "$WT/tmp" get KEN-829 .merge_queue_watch.state_path)
registration_runtime=$(jq -r .runtime_dir "$state_path"); worker_count=$(wc -l < "$WATCH_WORKER_LOG")
rm -f -- "$WATCH_REGISTRATION_GATE.entered" "$WATCH_REGISTRATION_GATE.release"
touch "$WATCH_REGISTRATION_GATE.enabled"
"$SCRIPTS/merge-queue-watch" launch --root "$MAIN" --issue KEN-829 --watch-id "$watch" --poll 1 --max-wait 10 >"$TMP/registration-launch.out" 2>"$TMP/registration-launch.err" & registration_launch_pid=$!
wait_exists "$WATCH_REGISTRATION_GATE.entered" || bad "supervisor did not pause before PID registration"
wait_state "$state_path" launch_failed || bad "launch failure did not claim before PID registration"
touch "$WATCH_REGISTRATION_GATE.release"
set +e; wait "$registration_launch_pid"; registration_launch_rc=$?; set -e
[[ "$registration_launch_rc" -ne 0 ]] && ok "post-check registration remains a launch failure" || bad "post-check registration revived launch"
sleep 0.3
eq "$(wc -l < "$WATCH_WORKER_LOG")" "$worker_count" "supervisor rechecks state after PID publication"
registration_pid=$(cat < "$registration_runtime/supervisor.pid")
if ! running "$registration_pid"; then ok "late-registering supervisor exits before deadline"; else bad "late-registering supervisor survived its failed generation"; fi
touch "$RELEASE"
"$SCRIPTS/merge-queue-watch" fail --root "$MAIN" --issue KEN-829 --watch-id "$watch" --cause operator_abandoned >/dev/null
rm -f -- "$WATCH_REGISTRATION_GATE.enabled" "$WATCH_REGISTRATION_GATE.entered" "$WATCH_REGISTRATION_GATE.release"

prep=$(prepare ejected); watch=$(jq -r .watch_id <<<"$prep")
launch_bounded "$watch"
state_path=$("$SCRIPTS/workflow-state" --state-dir "$WT/tmp" get KEN-829 .merge_queue_watch.state_path)
bash -c 'while :; do sleep 1; done' zombie-decoy & zombie_pid=$!
export WATCH_PS_ZOMBIE_PID="$zombie_pid"
jq --argjson pid "$zombie_pid" '.supervisor_pid=$pid' "$state_path" > "$TMP/zombie.json"
chmod 600 "$TMP/zombie.json"; mv "$TMP/zombie.json" "$state_path"
result=$("$SCRIPTS/merge-queue-watch" consume --root "$MAIN" --issue KEN-829)
eq "$(jq -r .status <<<"$result")" failed "production liveness treats zombie state as exited"
if ! running "$zombie_pid"; then ok "test liveness helper treats zombie state as exited"; else bad "test liveness helper accepted zombie state"; fi
unset WATCH_PS_ZOMBIE_PID
kill "$zombie_pid" 2>/dev/null || true; wait "$zombie_pid" 2>/dev/null || true
touch "$RELEASE"

prep=$(prepare merged); watch=$(jq -r .watch_id <<<"$prep")
"$SCRIPTS/merge-queue-watch" direct-merged --root "$MAIN" --issue KEN-829 --watch-id "$watch" >/dev/null
"$SCRIPTS/merge-queue-watch" merge-pr-complete --root "$MAIN" --issue KEN-829 --watch-id "$watch" >/dev/null
printf 'install verification failed\n' > "$TMP/postmerge.err"
"$SCRIPTS/merge-queue-watch" acknowledge --root "$MAIN" --issue KEN-829 --watch-id "$watch" --result fail --diagnostic-file "$TMP/postmerge.err" >/dev/null
eq "$("$SCRIPTS/merge-queue-watch" inspect --root "$MAIN" --issue KEN-829 | jq -r .status)" failed "failed lane acknowledgment terminalizes failed"

prep=$(prepare disarmed); watch=$(jq -r .watch_id <<<"$prep")
set +e
"$SCRIPTS/merge-queue-watch" direct-merged --root "$MAIN" --issue KEN-829 --watch-id "$watch" >/dev/null 2>&1
invalid_direct_rc=$?
set -e
if [[ "$invalid_direct_rc" -ne 0 ]]; then ok "direct merge validation fails closed at the process boundary"; else bad "direct merge validation exited zero"; fi

prep=$(prepare merged); watch=$(jq -r .watch_id <<<"$prep")
"$SCRIPTS/merge-queue-watch" direct-merged --root "$MAIN" --issue KEN-829 --watch-id "$watch" >/dev/null
"$SCRIPTS/merge-queue-watch" merge-pr-complete --root "$MAIN" --issue KEN-829 --watch-id "$watch" >/dev/null
touch "$WATCH_CLEANUP_FAIL"
touch "$WATCH_CLEANUP_PAUSE.enabled"
"$SCRIPTS/merge-queue-watch" cleanup --root "$MAIN" --issue KEN-829 --watch-id "$watch" >/dev/null 2>"$TMP/cleanup.err" & cleanup_pid=$!
wait_exists "$WATCH_CLEANUP_PAUSE.entered" || bad "cleanup owner did not reach helper"
set +e; "$SCRIPTS/merge-queue-watch" cleanup --root "$MAIN" --issue KEN-829 --watch-id "$watch" >/dev/null 2>"$TMP/cleanup-race.err"; cleanup_race_rc=$?; set -e
[[ "$cleanup_race_rc" -ne 0 ]] && ok "concurrent cleanup refuses the live owner" || bad "concurrent cleanup stole the live claim"
touch "$WATCH_CLEANUP_PAUSE.release"
set +e; wait "$cleanup_pid"; cleanup_rc=$?; set -e
if [[ "$cleanup_rc" -ne 0 ]]; then ok "cleanup failure returns nonzero"; else bad "cleanup failure exited zero"; fi
eq "$("$SCRIPTS/merge-queue-watch" inspect --root "$MAIN" --issue KEN-829 | jq -r .cleanup.status)" failed "cleanup failure remains resumable for failed acknowledgment"
"$SCRIPTS/merge-queue-watch" acknowledge --root "$MAIN" --issue KEN-829 --watch-id "$watch" --result fail --diagnostic-file "$TMP/cleanup.err" >/dev/null
rm -f "$WATCH_CLEANUP_FAIL" "$WATCH_CLEANUP_PAUSE.enabled" "$WATCH_CLEANUP_PAUSE.entered" "$WATCH_CLEANUP_PAUSE.release"

prep=$(prepare merged); watch=$(jq -r .watch_id <<<"$prep")
"$SCRIPTS/merge-queue-watch" direct-merged --root "$MAIN" --issue KEN-829 --watch-id "$watch" >/dev/null
"$SCRIPTS/merge-queue-watch" merge-pr-complete --root "$MAIN" --issue KEN-829 --watch-id "$watch" >/dev/null
(git -C "$WT" switch -qc foreign-cleanup)
"$SCRIPTS/merge-queue-watch" cleanup --root "$MAIN" --issue KEN-829 --watch-id "$watch" >/dev/null
state=$("$SCRIPTS/merge-queue-watch" inspect --root "$MAIN" --issue KEN-829)
eq "$(jq -r .cleanup.disposition <<<"$state")" kept "cleanup keeps a worktree whose branch changed"
[[ -d "$WT" ]] && ok "foreign-branch worktree remains present" || bad "foreign-branch worktree was removed"
"$SCRIPTS/merge-queue-watch" acknowledge --root "$MAIN" --issue KEN-829 --watch-id "$watch" --result pass >/dev/null
git -C "$WT" switch -q watch-test
git -C "$MAIN" branch -D foreign-cleanup >/dev/null

git -C "$WT" switch -qc prepare-time-branch
prep=$(prepare merged); watch=$(jq -r .watch_id <<<"$prep")
eq "$(jq -r .pr_branch <<<"$prep")" watch-test "prepare binds cleanup to the recorded PR branch, not the prepare-time checkout"
"$SCRIPTS/merge-queue-watch" direct-merged --root "$MAIN" --issue KEN-829 --watch-id "$watch" >/dev/null
"$SCRIPTS/merge-queue-watch" merge-pr-complete --root "$MAIN" --issue KEN-829 --watch-id "$watch" >/dev/null
"$SCRIPTS/merge-queue-watch" cleanup --root "$MAIN" --issue KEN-829 --watch-id "$watch" >/dev/null
state=$("$SCRIPTS/merge-queue-watch" inspect --root "$MAIN" --issue KEN-829)
eq "$(jq -r .cleanup.disposition <<<"$state")" kept "cleanup keeps a worktree prepared on a non-PR branch"
[[ -d "$WT" ]] && ok "non-PR-branch worktree survives cleanup" || bad "cleanup removed a worktree the workflow says to keep"
"$SCRIPTS/merge-queue-watch" acknowledge --root "$MAIN" --issue KEN-829 --watch-id "$watch" --result pass >/dev/null
git -C "$WT" switch -q watch-test
git -C "$MAIN" branch -D prepare-time-branch >/dev/null

prep=$(prepare merged); watch=$(jq -r .watch_id <<<"$prep")
"$SCRIPTS/merge-queue-watch" direct-merged --root "$MAIN" --issue KEN-829 --watch-id "$watch" >/dev/null
"$SCRIPTS/merge-queue-watch" merge-pr-complete --root "$MAIN" --issue KEN-829 --watch-id "$watch" >/dev/null
touch "$WT/uncommitted"
"$SCRIPTS/merge-queue-watch" cleanup --root "$MAIN" --issue KEN-829 --watch-id "$watch" >/dev/null
state=$("$SCRIPTS/merge-queue-watch" inspect --root "$MAIN" --issue KEN-829)
eq "$(jq -r .cleanup.disposition <<<"$state")" kept "cleanup keeps a worktree that became dirty"
[[ -f "$WT/uncommitted" ]] && ok "dirty worktree data survives cleanup" || bad "dirty worktree data was removed"
"$SCRIPTS/merge-queue-watch" acknowledge --root "$MAIN" --issue KEN-829 --watch-id "$watch" --result pass >/dev/null
rm -f "$WT/uncommitted"

prep=$(prepare merged); watch=$(jq -r .watch_id <<<"$prep")
"$SCRIPTS/merge-queue-watch" direct-merged --root "$MAIN" --issue KEN-829 --watch-id "$watch" >/dev/null
"$SCRIPTS/merge-queue-watch" merge-pr-complete --root "$MAIN" --issue KEN-829 --watch-id "$watch" >/dev/null
touch "$WATCH_CLEANUP_INTERRUPT"
set +e; "$SCRIPTS/merge-queue-watch" cleanup --root "$MAIN" --issue KEN-829 --watch-id "$watch" >/dev/null 2>&1; interrupted_rc=$?; set -e
[[ "$interrupted_rc" -ne 0 ]] && ok "interrupted cleanup exits before completion" || bad "interrupted cleanup reported success"
state=$("$SCRIPTS/merge-queue-watch" inspect --root "$MAIN" --issue KEN-829)
eq "$(jq -r .status <<<"$state")" cleanup_pending "interruption leaves a durable cleanup claim"
replay=$("$SCRIPTS/merge-queue-watch" consume --root "$MAIN" --issue KEN-829)
eq "$(jq -r .action <<<"$replay")" resume_cleanup "cleanup_pending routes to an explicit resume"
(cd "$WT" && "$SCRIPTS/merge-queue-watch" cleanup --root "$MAIN" --issue KEN-829 --watch-id "$watch" >/dev/null)
eq "$("$SCRIPTS/merge-queue-watch" inspect --root "$MAIN" --issue KEN-829 | jq -r .cleanup.resume_count)" 1 "resumed cleanup records its takeover"
if [[ ! -d "$WT" ]]; then ok "resumed cleanup safely removes the lane's original cwd"; else bad "resumed cleanup left the issue worktree"; fi
eq "$("$SCRIPTS/merge-queue-watch" inspect --root "$MAIN" --issue KEN-829 | jq -r .status)" cleanup_complete "resumed cleanup completes before final acknowledgment"
replay=$("$SCRIPTS/merge-queue-watch" consume --root "$MAIN" --issue KEN-829)
eq "$(jq -r .action <<<"$replay")" acknowledge "cleanup completion resumes only acknowledgment"
"$SCRIPTS/merge-queue-watch" acknowledge --root "$MAIN" --issue KEN-829 --watch-id "$watch" --result pass >/dev/null
eq "$("$SCRIPTS/merge-queue-watch" inspect --root "$MAIN" --issue KEN-829 | jq -r .status)" complete "lane acknowledgment survives worktree cleanup"
replay=$("$SCRIPTS/merge-queue-watch" consume --root "$MAIN" --issue KEN-829)
eq "$(jq -r .action <<<"$replay")" complete "completed lifecycle consumes as no-op"

"$SCRIPTS/merge-queue-watch" init --worktree "$MAIN" --issue pr-42 --branch master >/dev/null
prep=$("$SCRIPTS/merge-queue-watch" prepare --worktree "$MAIN" --issue pr-42 --repo owner/repo --pr 42 --head "$HEAD_A" --root "$MAIN" --gate-mode off --recovery-count 0 --cleanup-worktree false)
watch=$(jq -r .watch_id <<<"$prep")
eq "$(jq -r .issue_id <<<"$prep")" pr-42 "issue-less standalone lifecycle uses the stable PR fallback key"
"$SCRIPTS/merge-queue-watch" direct-merged --root "$MAIN" --issue pr-42 --watch-id "$watch" >/dev/null
"$SCRIPTS/merge-queue-watch" merge-pr-complete --root "$MAIN" --issue pr-42 --watch-id "$watch" >/dev/null
"$SCRIPTS/merge-queue-watch" cleanup --root "$MAIN" --issue pr-42 --watch-id "$watch" >/dev/null
"$SCRIPTS/merge-queue-watch" acknowledge --root "$MAIN" --issue pr-42 --watch-id "$watch" --result pass >/dev/null
if [[ -d "$MAIN/.git" ]]; then ok "standalone lifecycle never treats main as issue worktree"; else bad "standalone cleanup removed main repository"; fi

portable_watch() { ! grep -Eq '\$\{[^}]+,,\}' "$1"; }
if portable_watch "$ORCH/scripts/merge-queue-watch"; then ok "head normalization stays compatible with Bash 3.2"; else bad "Bash 4 lowercase expansion remains"; fi
cp "$ORCH/scripts/merge-queue-watch" "$TMP/nonportable-watch"
count=$(grep -Fc "head=\$(printf '%s' \"\$head\" | tr '[:upper:]' '[:lower:]')" "$TMP/nonportable-watch")
[[ "$count" -eq 1 ]] || { bad "portability mutation fixture count"; exit 1; }
sed -i.bak 's/head=$(printf '\''%s'\'' "$head" | tr '\''\[:upper:\]'\'' '\''\[:lower:\]'\'')/head="${head,,}"/' "$TMP/nonportable-watch"
rm -f "$TMP/nonportable-watch.bak"
if portable_watch "$TMP/nonportable-watch"; then bad "Bash 4 lowercase mutant survived"; else ok "Bash 4 lowercase mutant is killed"; fi

printf 'merge-queue-watch: %d pass, %d fail\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
