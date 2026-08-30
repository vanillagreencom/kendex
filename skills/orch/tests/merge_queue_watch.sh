#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCH="$(cd "$TEST_DIR/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0 FAIL=0
ok() { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
eq() { if [[ "$1" == "$2" ]]; then ok "$3"; else bad "$3 (expected $2, got $1)"; fi; }
wait_file() { local i; for ((i=0;i<100;i++)); do [[ -s "$1" ]] && return 0; sleep 0.05; done; return 1; }
wait_exists() { local i; for ((i=0;i<100;i++)); do [[ -e "$1" ]] && return 0; sleep 0.05; done; return 1; }

MAIN="$TMP/main" WT="$TMP/worktree" BIN="$TMP/bin" SCRIPTS="$TMP/orch/scripts"
REAL_SETSID=$(command -v setsid || true)
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
if [[ -f "$WATCH_SETUP_GATE.enabled" ]]; then touch "$WATCH_SETUP_GATE.entered"; while [[ ! -f "$WATCH_SETUP_GATE.release" ]]; do sleep 0.05; done; fi
exec "$WATCH_REAL_SETSID" "$@"
EOF
chmod +x "$BIN/setsid"
fi
export PATH="$BIN:$PATH" WATCH_MODE="$MODE" WATCH_RELEASE="$RELEASE" WATCH_HEAD_FILE="$HEAD_FILE" WATCH_MAIN="$MAIN" WATCH_WORKTREE="$WT"
export WATCH_GH_PAUSE="$TMP/gh-pause" WATCH_SETUP_GATE="$TMP/setup-gate" WATCH_REAL_SETSID="$REAL_SETSID" WATCH_CLEANUP_FAIL="$TMP/cleanup-fail" WATCH_CLEANUP_INTERRUPT="$TMP/cleanup-interrupt"
export WATCH_SETSID_FAIL="$TMP/setsid-fail" WATCH_CLEANUP_PAUSE="$TMP/cleanup-pause" WATCH_AUTH_LOG="$TMP/auth.log" WATCH_WORKER_LOG="$TMP/worker.log" GH_REPO=wrong/repository GITHUB_REPOSITORY=wrong/repository
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
  for ((i=0;i<100;i++)); do kill -0 "$pid" 2>/dev/null || break; sleep 0.05; done
  if kill -0 "$pid" 2>/dev/null; then kill -TERM "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; bad "launch returns before worker release"; return 1; fi
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
if kill -0 "$supervisor" 2>/dev/null; then ok "supervisor survives the launch command boundary"; else bad "supervisor died at command boundary"; fi
touch "$RELEASE"; wait_file "$artifact" || bad "merged verdict was not published"
eq "$(jq -r .watch_id "$artifact")" "$watch" "artifact binds watch id"
eq "$(jq -r .expected_head "$artifact")" "$HEAD_A" "artifact binds expected head"
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
jq '.status="launching"|.setup_deadline=0|.deadline=((now|floor)+600)' "$state_path" > "$TMP/orphan.json"
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
jq '.status="launching"|.setup_deadline=((now|floor)+10)|.deadline=((now|floor)+600)' "$state_path" > "$TMP/completed-launch.json"
chmod 600 "$TMP/completed-launch.json"; mv "$TMP/completed-launch.json" "$state_path"
jq -n --arg watch "$watch" --arg head "$HEAD_A" '{schema_version:1,status:"complete",verdict:"merged",repository:"owner/repo",pr_number:42,expected_head:$head,observed_head:"",watch_id:$watch}' > "$artifact"
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
if ! kill -0 "$supervisor" 2>/dev/null; then ok "overdue verified supervisor is terminated"; else bad "overdue supervisor survived consume"; fi

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
launch_bounded "$watch"
eq "$("$SCRIPTS/merge-queue-watch" inspect --root "$MAIN" --issue KEN-829 | jq -r .status)" watching "same watch retries after setup repair"
"$SCRIPTS/merge-queue-watch" fail --root "$MAIN" --issue KEN-829 --watch-id "$watch" --cause operator_abandoned >/dev/null

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
