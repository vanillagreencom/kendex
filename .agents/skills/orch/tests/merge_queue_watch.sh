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

MAIN="$TMP/main" WT="$TMP/worktree" BIN="$TMP/bin" SCRIPTS="$TMP/orch/scripts"
mkdir -p "$MAIN" "$BIN" "$SCRIPTS/lib"
git -C "$MAIN" init -q
git -C "$MAIN" config user.email test@example.com
git -C "$MAIN" config user.name Test
touch "$MAIN/seed"; git -C "$MAIN" add seed; git -C "$MAIN" commit -qm seed
git -C "$MAIN" branch watch-test
git -C "$MAIN" worktree add -q "$WT" watch-test
cp "$ORCH/scripts/merge-queue-watch" "$ORCH/scripts/workflow-state" "$ORCH/scripts/orch-env" "$SCRIPTS/"
cp "$ORCH/scripts/lib/merge-queue-supervisor.sh" "$SCRIPTS/lib/"
cp "$ORCH/scripts/lib/kendex-env.sh" "$SCRIPTS/lib/"

MODE="$TMP/mode" RELEASE="$TMP/release" HEAD_FILE="$TMP/head"
HEAD_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
HEAD_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
printf '%s\n' "$HEAD_A" > "$HEAD_FILE"
cat > "$SCRIPTS/queue-wait" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
while [[ ! -f "$WATCH_RELEASE" ]]; do sleep 0.05; done
mode=$(cat < "$WATCH_MODE")
case "$mode" in
  merged) printf '{"status":"complete","verdict":"merged"}\n' ;;
  ejected) printf '{"status":"complete","verdict":"ejected","cause":"merge_group_failed"}\n'; exit 1 ;;
  disarmed) printf '{"status":"complete","verdict":"disarmed","cause":"auto_merge_cleared"}\n'; exit 1 ;;
  dequeued) printf '{"status":"complete","verdict":"dequeued","cause":"late_findings"}\n'; exit 1 ;;
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
  head=$(cat < "$WATCH_HEAD_FILE")
  mode=$(cat < "$WATCH_MODE")
  case "$mode" in merged) state=MERGED ;; closed) state=CLOSED ;; *) state=OPEN ;; esac
  if [[ "$*" == *"--jq"* ]]; then printf '%s\n' "$head"; fi
  if [[ "$*" != *"--jq"* ]]; then printf '{"headRefOid":"%s","state":"%s"}\n' "$head" "$state"; fi
  exit 0
fi
echo "unexpected gh: $*" >&2
exit 1
EOF
chmod +x "$BIN/gh"
export PATH="$BIN:$PATH" WATCH_MODE="$MODE" WATCH_RELEASE="$RELEASE" WATCH_HEAD_FILE="$HEAD_FILE"
"$SCRIPTS/workflow-state" --state-dir "$WT/tmp" init KEN-829 --worktree "$WT" --branch watch-test >/dev/null

prepare() {
  rm -f "$RELEASE"
  printf '%s\n' "$1" > "$MODE"
  "$SCRIPTS/merge-queue-watch" prepare --worktree "$WT" --issue KEN-829 \
    --repo owner/repo --pr 42 --head "$HEAD_A" --root "$MAIN" --gate-mode "${2:-off}" --recovery-count "${3:-0}"
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
  "$SCRIPTS/merge-queue-watch" fail --root "$MAIN" --issue KEN-829 --watch-id "$watch" --cause operator_abandoned >/dev/null
}
echo "=== durable merge queue lifecycle ==="
prep=$(prepare merged); watch=$(jq -r .watch_id <<<"$prep"); artifact=$(jq -r .artifact_path <<<"$prep")
eq "$(jq -r .head_sha <<<"$prep")" "$HEAD_A" "prepare records exact head before arming"
pointer=$("$SCRIPTS/workflow-state" --state-dir "$WT/tmp" get KEN-829 .merge_queue_watch)
eq "$(jq -r .watch_id <<<"$pointer")" "$watch" "workflow state points at exact watch"
launch_bounded "$watch"
if [[ ! -e "$artifact" ]]; then ok "no verdict exists before worker release"; else bad "partial verdict appeared"; fi
supervisor=$("$SCRIPTS/merge-queue-watch" inspect --root "$MAIN" --issue KEN-829 | jq -r .supervisor_pid)
if kill -0 "$supervisor" 2>/dev/null; then ok "supervisor survives the launch command boundary"; else bad "supervisor died at command boundary"; fi
touch "$RELEASE"; wait_file "$artifact" || bad "merged verdict was not published"
eq "$(jq -r .watch_id "$artifact")" "$watch" "artifact binds watch id"
eq "$(jq -r .expected_head "$artifact")" "$HEAD_A" "artifact binds expected head"
event_out=$("$SCRIPTS/merge-queue-watch" event --root "$MAIN" --issue KEN-829)
if [[ "$event_out" == ready* ]]; then ok "fleet event wakes the owner once verdict exists"; else bad "fleet event missing"; fi
result=$("$SCRIPTS/merge-queue-watch" consume --root "$MAIN" --issue KEN-829)
eq "$(jq -r .action <<<"$result")" postmerge "merged verdict claims postmerge action"
"$SCRIPTS/merge-queue-watch" merge-pr-complete --root "$MAIN" --issue KEN-829 --watch-id "$watch" >/dev/null
eq "$("$SCRIPTS/merge-queue-watch" inspect --root "$MAIN" --issue KEN-829 | jq -r .status)" awaiting_lane_postmerge "merge-pr completion waits for lane acknowledgment"
"$SCRIPTS/merge-queue-watch" acknowledge --root "$MAIN" --issue KEN-829 --watch-id "$watch" --result pass >/dev/null

prep=$(prepare ejected review 0); watch=$(jq -r .watch_id <<<"$prep"); artifact=$(jq -r .artifact_path <<<"$prep")
launch_bounded "$watch"; touch "$RELEASE"; wait_file "$artifact" || bad "ejected verdict missing"
result=$("$SCRIPTS/merge-queue-watch" consume --root "$MAIN" --issue KEN-829)
eq "$(jq -r .action <<<"$result")" recovery "ejected verdict claims recovery"
eq "$(jq -r .recovery_count <<<"$result")" 1 "recovery claim increments durable count"
eq "$(jq -r .gate_mode <<<"$result")" review "recovery keeps gate mode across boundary"
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
verdict_case dequeued triage
verdict_case stalled recovery
verdict_case progressing rewatch
verdict_case not_queued rearm

prep=$(prepare merged); watch=$(jq -r .watch_id <<<"$prep"); artifact=$(jq -r .artifact_path <<<"$prep")
launch_bounded "$watch"; touch "$RELEASE"; wait_file "$artifact" || bad "head-mismatch verdict missing"
printf '%s\n' "$HEAD_B" > "$HEAD_FILE"
result=$("$SCRIPTS/merge-queue-watch" consume --root "$MAIN" --issue KEN-829)
eq "$(jq -r .status <<<"$result")" failed "live head mismatch blocks merged poststeps"
eq "$(jq -r .diagnostic.cause <<<"$result")" head_mismatch "head mismatch names its cause"
printf '%s\n' "$HEAD_A" > "$HEAD_FILE"

prep=$(prepare malformed); watch=$(jq -r .watch_id <<<"$prep"); artifact=$(jq -r .artifact_path <<<"$prep")
launch_bounded "$watch"; touch "$RELEASE"; wait_file "$artifact" || bad "malformed-worker error artifact missing"
result=$("$SCRIPTS/merge-queue-watch" consume --root "$MAIN" --issue KEN-829)
eq "$(jq -r .status <<<"$result")" failed "unknown worker output terminalizes failed"

prep=$(prepare closed); watch=$(jq -r .watch_id <<<"$prep"); artifact=$(jq -r .artifact_path <<<"$prep")
launch_bounded "$watch"; touch "$RELEASE"; wait_file "$artifact" || bad "closed verdict missing"
result=$("$SCRIPTS/merge-queue-watch" consume --root "$MAIN" --issue KEN-829)
eq "$(jq -r .status <<<"$result")" abandoned "closed verdict terminalizes abandoned"

prep=$(prepare merged); watch=$(jq -r .watch_id <<<"$prep")
result=$("$SCRIPTS/merge-queue-watch" consume --root "$MAIN" --issue KEN-829)
eq "$(jq -r .diagnostic.cause <<<"$result")" watch_lost "missing stale artifact fails closed"

prep=$(prepare merged); watch=$(jq -r .watch_id <<<"$prep"); artifact=$(jq -r .artifact_path <<<"$prep")
launch_bounded "$watch"; supervisor=$("$SCRIPTS/merge-queue-watch" inspect --root "$MAIN" --issue KEN-829 | jq -r .supervisor_pid)
kill -TERM "$supervisor"; wait_file "$artifact" || bad "signaled supervisor did not publish error"
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
eq "$("$SCRIPTS/merge-queue-watch" inspect --root "$MAIN" --issue KEN-829 | jq -r .status)" failed "setup failure terminalizes durable state"

prep=$(prepare merged); watch=$(jq -r .watch_id <<<"$prep")
"$SCRIPTS/merge-queue-watch" direct-merged --root "$MAIN" --issue KEN-829 --watch-id "$watch" >/dev/null
"$SCRIPTS/merge-queue-watch" merge-pr-complete --root "$MAIN" --issue KEN-829 --watch-id "$watch" >/dev/null
printf 'install verification failed\n' > "$TMP/postmerge.err"
"$SCRIPTS/merge-queue-watch" acknowledge --root "$MAIN" --issue KEN-829 --watch-id "$watch" --result fail --diagnostic-file "$TMP/postmerge.err" >/dev/null
eq "$("$SCRIPTS/merge-queue-watch" inspect --root "$MAIN" --issue KEN-829 | jq -r .status)" failed "failed lane acknowledgment terminalizes failed"

prep=$(prepare merged); watch=$(jq -r .watch_id <<<"$prep")
"$SCRIPTS/merge-queue-watch" direct-merged --root "$MAIN" --issue KEN-829 --watch-id "$watch" >/dev/null
"$SCRIPTS/merge-queue-watch" merge-pr-complete --root "$MAIN" --issue KEN-829 --watch-id "$watch" >/dev/null
git -C "$MAIN" worktree remove --force "$WT"
"$SCRIPTS/merge-queue-watch" acknowledge --root "$MAIN" --issue KEN-829 --watch-id "$watch" --result pass >/dev/null
eq "$("$SCRIPTS/merge-queue-watch" inspect --root "$MAIN" --issue KEN-829 | jq -r .status)" complete "lane acknowledgment survives worktree cleanup"

printf 'merge-queue-watch: %d pass, %d fail\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
