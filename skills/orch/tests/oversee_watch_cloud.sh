#!/usr/bin/env bash
# oversee-watch over a lane whose record's host kind is claude-cloud, which
# declares channel=session, files=none and status=none: the mail pass leaves
# it out, one open pull request list per repository serves the pass, and once
# that pull request is open, a head and body that do not move for
# ORCH_WATCH_LANE_STALL_SECS is lane-stalled. The kind's line is the real
# lane-host's; GitHub is the harness's gh stub. Its start, the open pull
# request, is oversee_watch_start_stall.sh's.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
# shellcheck source=lib/oversee-watch-harness.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/oversee-watch-harness.sh"
# shellcheck source=lib/growth-state.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/growth-state.sh"

LAUNCHED=2026-08-15T10:00:00Z
LAUNCHED_EPOCH="$(date -u -d "$LAUNCHED" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$LAUNCHED" +%s)"

# One running claude-cloud record, issue-1, its mail_root the local worktree
# its launch made, which holds no status file, and WINDOW its window, none
# where it is not given. Its session_since is LAUNCHED, and the stub's branch
# heads are committed long before it. DIRECTIVE_AGE, where set, is the age in
# seconds past LAUNCHED at which lane-mail recorded a directive sent to it.
cloud_state() { # [WINDOW]
  mkdir -p "$STUB_DIR/wt/issue-1"
  jq -n --arg root "$STUB_DIR/wt/issue-1" --arg at "$LAUNCHED" --arg window "${1:-}" \
    --arg sent "${DIRECTIVE_AGE:+$((LAUNCHED_EPOCH + DIRECTIVE_AGE))}" '{issue_id: "oversee", triaged: [], lanes: [
    {item: "issue-1", window: (if $window == "" then null else $window end), host: "claude-cloud", kind: "claude-cloud", mail_root: $root, harness: "claude",
     session_id: "session_01CLOUD", account: "/cloud-account", session_since: $at, launched_at: $at, running_at: $at, status: "running"}
    + (if $sent == "" then {} else {directive_send: {at: ($sent | tonumber), result: "sent", text: "", credit: "unread"}} end)]}' > "$STUB_DIR/state.json"
}
# open_pr HEAD BODY [DRAFT] — the item branch's open pull request, or none where HEAD
# is empty.
open_pr() {
  if [[ -z "$1" ]]; then : > "$STUB_DIR/open.txt"
  else printf '7\tissue-1\tcloud lane\toctocat\t%s\t%s\towner\t%s\n' "$1" "$2" "${3:-true}" > "$STUB_DIR/open.txt"; fi
}
open_lists() { grep -c -- '^pr list --repo owner/repo --head issue-1 --state open' "$STUB_DIR/gh.calls" || true; }
# The handoff reads of issue-1's workflow state, which a files=none lane has
# none of on this disk.
handoff_reads() { grep -c -- 'handoff-standing issue-1' "$STUB_DIR/workflow-state.args" 2>/dev/null || true; }
# The lane-mail every pass reads through, logging each call's argv.
MAIL_LOG_BIN="$TMP_ROOT/mail-log"
cat > "$MAIL_LOG_BIN" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$STUB_DIR/mail.calls"
exec "$REPO_ROOT/skills/mailbox/scripts/lane-mail" "\$@"
EOF
chmod +x "$MAIL_LOG_BIN"
# The cloud close as lane-close answers it for a stop=none record: it logs
# its argv to the case's lane-close.args and keeps the session.
CLOSE_BIN="$TMP_ROOT/cloud-close"
cat > "$CLOSE_BIN" <<'EOF'
#!/usr/bin/env bash
if [[ " $* " == *" --terminal-state "* ]]; then printf 'open\n'; exit 0; fi
printf '%s\n' "$*" >> "$STUB_DIR/lane-close.args"
printf 'lane-close: host-kept kind=claude-cloud session=session_01CLOUD\n'
EOF
chmod +x "$CLOSE_BIN"
# watch AGE [ENV=VAL...] — one pass at LAUNCHED + AGE seconds; EVENTS holds its
# EVENT lines joined by `|`, the heartbeat left out, and RC its status.
watch() {
  local age="$1" out
  shift
  printf '%s\n' "$((LAUNCHED_EPOCH + age))" > "$STUB_DIR/now.epoch"
  out="$(WATCH_BIN="${CLOUD_WATCH:-${WATCH_BIN:-}}" run_watch OVERSEE_WATCH_LANE_MAIL="$MAIL_LOG_BIN" OVERSEE_WATCH_LANE_CLOSE="$CLOSE_BIN" ORCH_WATCH_LANE_STALL_SECS=1800 "$@" -- \
    --max-loops 1 --state "$STUB_DIR/state.json" 2>"$STUB_DIR/err" </dev/null)" && RC=0 || RC=$?
  EVENTS="$(grep '^EVENT ' <<<"$out" | grep -v '^EVENT heartbeat' | paste -sd '|' - || true)"
}

echo "=== one pass: no mailbox or state read, one open pull request list ==="
new_case cloud_pass
cloud_state
open_pr abc111 "## Lane status"
watch 700
assert_eq "events=$EVENTS calls=$(grep -c -- '--item issue-1' "$STUB_DIR/mail.calls" || true) overseer=$(grep -q -- '--item overseer' "$STUB_DIR/mail.calls" && echo read || echo unread) lists=$(open_lists) handoff=$(handoff_reads)" \
  "events= calls=0 overseer=read lists=1 handoff=0" \
  "a session lane's mailbox and workflow state are read nowhere, and the start and stall checks share one list" "$STUB_DIR/err"

echo "=== a cloud record's window is no lane the pane passes judge ==="
# The window holds the session's local client, which the stub's server does
# not list, so a pane pass reading it would report it gone.
new_case cloud_window
cloud_state main:issue-1
open_pr abc111 "## Lane status"
watch 700
assert_eq "events=$EVENTS" "events=" "a status=none record with a window raises no pane event" "$STUB_DIR/err"

echo "=== an open pull request that does not move is lane-stalled ==="
# STEP rows per case: AGE|HEAD|BODY|WANT, one pass each, the first seeding the row.
# With no pull request head, BODY is the branch head or an unread fixture.
stall_case() { # NAME ROW...
  local row age head body want
  new_case "$1"
  shift
  cloud_state
  for row in "$@"; do
    IFS='|' read -r age head body want <<<"$row"
    open_pr "$head" "$body"
    rm -f "$STUB_DIR/branch-head" "$STUB_DIR/branch-unread" "$STUB_DIR/branch-response.json"
    if [[ -z "$head" ]]; then
      case "$body" in
        unread) : > "$STUB_DIR/branch-unread" ;;
        invalid) printf '{"data":{"repository":{"ref":{"target":{"oid":"unknown"}}}}}\n' > "$STUB_DIR/branch-response.json" ;;
        missing-repository) printf '{"data":{"repository":null}}\n' > "$STUB_DIR/branch-response.json" ;;
        *) [[ -z "$body" ]] || printf '%s\n' "$body" > "$STUB_DIR/branch-head" ;;
      esac
    fi
    watch "$age" ORCH_OVERSEER_MARK_REPEAT=3
    assert_eq "events=$EVENTS" "events=$want" "$CASE_LABEL: pass at ${age}s" "$STUB_DIR/err"
  done
}
CASE_LABEL="head and body unchanged" stall_case stall_still \
  "100|abc111|## Lane status working||" "1899|abc111|## Lane status working||" \
  "1900|abc111|## Lane status working|EVENT lane-stalled issue-1 age=1800" \
  "1960|abc111|## Lane status working||" "2020|abc111|## Lane status working||" \
  "2080|abc111|## Lane status working|EVENT lane-stalled issue-1 age=1980"
CASE_LABEL="the body changes" stall_case stall_body \
  "100|abc111|## Lane status working||" "1900|abc111|## Lane status pushed fix||"
CASE_LABEL="the head changes" stall_case stall_head \
  "100|abc111|## Lane status working||" "1900|abc222|## Lane status working||"
BRANCH_HEAD=1111111111111111111111111111111111111111
PUSHED_HEAD=2222222222222222222222222222222222222222
MOVED_HEAD=3333333333333333333333333333333333333333
# Before its pull request opens, a lane its push started is bounded on the
# branch head as the pull request's head is above: a move after a report
# starts a fresh window, whose first stall is reported at once.
CASE_LABEL="a pushed branch that stops moving with no pull request" stall_case start_pushed_still \
  "100||$BRANCH_HEAD|" "300||$PUSHED_HEAD|" "2099||$PUSHED_HEAD|" \
  "2100||$PUSHED_HEAD|EVENT lane-stalled issue-1 age=1800" "2160||$PUSHED_HEAD|" "2220||$PUSHED_HEAD|" \
  "2280||$PUSHED_HEAD|EVENT lane-stalled issue-1 age=1980" "2340||$MOVED_HEAD|" \
  "4140||$MOVED_HEAD|EVENT lane-stalled issue-1 age=1800"
CASE_LABEL="a pushed branch that moves again with no pull request" stall_case start_pushed_moving \
  "100||$BRANCH_HEAD|" "300||$PUSHED_HEAD|" "2000||$MOVED_HEAD|" "2100||$MOVED_HEAD|"

echo "=== a directive left unanswered past ORCH_CLOUD_STALL_MINUTES closes the lane ==="
# The record's directive went out at DIRECTIVE_AGE; the default bound is 30
# minutes. A close runs the harness's lane-close stub, whose argv the closes
# row reads.
CLOSED="EVENT lane-closed issue-1|EVENT cloud-stall-closed issue-1 directive_age=1800"
closes() { awk 'END { print NR + 0 }' "$STUB_DIR/lane-close.args" 2>/dev/null || echo 0; }
# LABEL|NAME|DIRECTIVE_AGE|rows as stall_case takes them
for row in \
  "a stalled pull request with no push since the directive|stall_bound|2000|100,abc111,b,;1900,abc111,b,EVENT lane-stalled issue-1 age=1800;3799,abc111,b,;3800,abc111,b,$CLOSED" \
  "a head pushed after the directive|stall_bound_moved|2000|100,abc111,b,;1900,abc111,b,EVENT lane-stalled issue-1 age=1800;2100,abc222,b,;3800,abc222,b,;3900,abc222,b,EVENT lane-stalled issue-1 age=1800" \
  "a lane that never opened its pull request|start_bound|700|600,,,EVENT start-stalled issue-1 age=600;2499,,,;2500,,,$CLOSED" \
  "an unchanged branch without a pull request|start_bound_unchanged|700|600,,$BRANCH_HEAD,EVENT start-stalled issue-1 age=600;2500,,$BRANCH_HEAD,$CLOSED" \
  "a first push after the startup directive starts the lane|start_bound_first_push|700|600,,,EVENT start-stalled issue-1 age=600;2500,,$PUSHED_HEAD,;2560,,$PUSHED_HEAD,;2620,,$PUSHED_HEAD," \
  "a directive after the first push left unanswered|start_bound_pushed_directive|4300|600,,,EVENT start-stalled issue-1 age=600;2500,,$PUSHED_HEAD,;4300,,$PUSHED_HEAD,EVENT lane-stalled issue-1 age=1800;6099,,$PUSHED_HEAD,;6100,,$PUSHED_HEAD,$CLOSED" \
  "a push answering a directive sent after the first push|start_bound_pushed_answered|2600|600,,,EVENT start-stalled issue-1 age=600;2500,,$PUSHED_HEAD,;2700,,$MOVED_HEAD,;4400,,$MOVED_HEAD," \
  "a changed branch without a pull request|start_bound_changed|700|600,,$BRANCH_HEAD,EVENT start-stalled issue-1 age=600;2500,,$PUSHED_HEAD," \
  "a branch first observed after the directive bound|start_bound_first_read|700|2500,,$PUSHED_HEAD,EVENT start-stalled issue-1 age=2500" \
  "an unread branch after the startup directive|start_bound_unread|700|600,,,EVENT start-stalled issue-1 age=600;2500,,unread," \
  "an invalid branch head after the startup directive|start_bound_invalid_head|700|600,,,EVENT start-stalled issue-1 age=600;2500,,invalid," \
  "an unread repository after the startup directive|start_bound_missing_repo|700|600,,,EVENT start-stalled issue-1 age=600;2500,,missing-repository,"; do
  IFS='|' read -r label name sent steps <<<"$row"
  IFS=';' read -r -a passes <<<"$steps"
  stall_rows=()
  for step in "${passes[@]}"; do
    IFS=',' read -r age head body want <<<"$step"
    stall_rows+=("$age|$head|$body|$want")
  done
  DIRECTIVE_AGE="$sent" CASE_LABEL="$label" stall_case "$name" "${stall_rows[@]}"
  want_closes=0
  [[ "$steps" != *cloud-stall-closed* ]] || want_closes=1
  assert_eq "closes=$(closes) args=$(head -n 1 "$STUB_DIR/lane-close.args" 2>/dev/null || true)" \
    "closes=$want_closes args=$([[ "$want_closes" -eq 0 ]] || printf -- '--state-dir %s issue-1' "$STUB_DIR")" \
    "$label: lane-close runs only past the bound" "$STUB_DIR/err"
done
new_case cloud_bound_invalid
cloud_state
open_pr abc111 b
watch 100 ORCH_CLOUD_STALL_MINUTES=0
assert_eq "rc=$RC refused=$(grep -c '^oversee-watch: cloud-stall-minutes-invalid value=0' "$STUB_DIR/err" || true)" "rc=2 refused=1" \
  "a bound of zero minutes is refused"

echo "=== ready and credit readings report a state without waiting for age ==="
# The watch's EVENT consumer is the overseer, which routes landing and relaunch
# from the state word. All readings share the same lane, pass and assertions.
cloud_credit() { # READING
  local credit='null' account=/cloud-account
  case "$1" in
    locked) credit='{"remaining_dollars":10,"locked_reason":"budget"}' ;;
    zero) credit='{"remaining_dollars":0,"locked_reason":null}' ;;
    negative) credit='{"remaining_dollars":-1,"locked_reason":null}' ;;
    room) credit='{"remaining_dollars":10,"locked_reason":null}' ;;
    unknown) credit='{"remaining_dollars":null,"locked_reason":null}' ;;
    no-row) account=/other-account ;;
    failed) printf '1\n' > "$STUB_DIR/lanes.rc" ;;
    no-credit) ;;
  esac
  jq -nc --arg account "$account" --argjson credit "$credit" '[{
    config_dir: $account, alias: "cloud", harness: "claude", measured_through: "claude-cloud",
    status: "ok", verdict: "unmeasured", credits: $credit}]' > "$STUB_DIR/lanes.json"
}
state_case() { # NAME CREDIT DIRECTIVE_AGE STEPS
  local name="$1" credit="$2" sent="$3" steps="$4" step age head body draft want
  local passes=()
  new_case "$name"
  DIRECTIVE_AGE="$sent" cloud_state
  cloud_credit "$credit"
  IFS=';' read -r -a passes <<<"$steps"
  for step in "${passes[@]}"; do
    IFS=',' read -r age head body draft want <<<"$step"
    open_pr "$head" "$body" "$draft"
    : > "$STUB_DIR/lanes.args"
    : > "$STUB_DIR/gh.calls"
    watch "$age" ORCH_OVERSEER_MARK_REPEAT=3
    assert_eq "rc=$RC events=$EVENTS" "rc=0 events=$want" "$name: state at ${age}s" "$STUB_DIR/err"
    assert_eq "$(cat "$STUB_DIR/lanes.args")" "list --json" "$name: one shared account read" "$STUB_DIR/err"
    assert_eq "lists=$(open_lists) closes=$(closes)" "lists=1 closes=0" "$name: one PR read and no close" "$STUB_DIR/err"
  done
}
FINISHED='EVENT lane-stalled issue-1 age=100 state=finished'
CREDIT='EVENT lane-stalled issue-1 age=0 state=out-of-credit'
for row in \
  "ready_unchanged|room||100,abc111,b,true,;200,abc111,b,false,$FINISHED" \
  "ready_head|room||100,abc111,b,true,;200,abc222,b,false,EVENT lane-stalled issue-1 age=0 state=finished" \
  "ready_body|room||100,abc111,b,true,;200,abc111,c,false,EVENT lane-stalled issue-1 age=0 state=finished" \
  "ready_old_directive|room|200|100,abc111,b,true,;2200,abc111,b,false,EVENT lane-stalled issue-1 age=2100 state=finished" \
  "ready_repeat|room||100,abc111,b,true,;200,abc111,b,false,$FINISHED;260,abc222,c,false,;320,abc222,c,false,;380,abc222,c,false,EVENT lane-stalled issue-1 age=120 state=finished" \
  "credit_locked|locked||100,abc111,b,true,$CREDIT" \
  "credit_zero|zero||100,abc111,b,true,$CREDIT" \
  "credit_negative|negative||100,abc111,b,true,$CREDIT" \
  "credit_room|room||100,abc111,b,true,;1900,abc111,b,true,EVENT lane-stalled issue-1 age=1800" \
  "credit_no_row|no-row||100,abc111,b,true,;1900,abc111,b,true,EVENT lane-stalled issue-1 age=1800" \
  "credit_no_body|no-credit||100,abc111,b,true,;1900,abc111,b,true,EVENT lane-stalled issue-1 age=1800" \
  "credit_failed|failed||100,abc111,b,true,;1900,abc111,b,true,EVENT lane-stalled issue-1 age=1800" \
  "credit_unknown|unknown||100,abc111,b,true,;1900,abc111,b,true,EVENT lane-stalled issue-1 age=1800" \
  "draft_unknown|locked||100,abc111,b,unknown,;1900,abc111,b,unknown,EVENT lane-stalled issue-1 age=1800" \
  "credit_repeat|zero||100,abc111,b,true,$CREDIT;160,abc111,b,true,;220,abc111,b,true,;280,abc111,b,true,EVENT lane-stalled issue-1 age=180 state=out-of-credit" \
  "credit_to_finished|zero||100,abc111,b,true,$CREDIT;160,abc111,b,true,;200,abc111,b,false,$FINISHED;260,abc111,b,false,"; do
  IFS='|' read -r name credit sent steps <<<"$row"
  state_case "$name" "$credit" "$sent" "$steps"
done

echo "=== must-fail controls on a disposable copy ==="
# MUTANT/orch/scripts beside a link to skills/github, as the watch reads it.
mutant_watch() { # MUTANT OLD NEW
  local copy
  copy="$(mutant_scripts "$1/orch" oversee-watch)/oversee-watch" || exit 1
  ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/$1/github"
  mutate_file "$copy" "$2" "$3"
  MUTANT_WATCH="$copy"
}
# Bounding a pushed lane from its launch, not its last push, must redden the
# pass just short of the bound.
# shellcheck disable=SC2016
mutant_watch pushed-stall-from-launch 'if (( PASS_NOW - since >= LANE_STALL_SECS )); then' \
  'if (( PASS_NOW - running >= LANE_STALL_SECS )); then'
new_case control_pushed_stall_from_launch
cloud_state
open_pr "" ""
for age_head in "100|$BRANCH_HEAD" "300|$PUSHED_HEAD" "2099|$PUSHED_HEAD"; do
  printf '%s\n' "${age_head#*|}" > "$STUB_DIR/branch-head"
  CLOUD_WATCH="$MUTANT_WATCH" watch "${age_head%%|*}" ORCH_OVERSEER_MARK_REPEAT=3
done
assert_eq "events=$EVENTS" "events=EVENT lane-stalled issue-1 age=1799" \
  "control: a stall bound counted from launch reports the pushed lane early" "$STUB_DIR/err"
# Holding a pushed lane out of the directive close must leave the lane of
# start_bound_pushed_directive open.
# shellcheck disable=SC2016
mutant_watch pushed-no-close 'if item_in "$item" ${FILELESS[@]+"${FILELESS[@]}"} && cloud_stall_close "$item" "$since"; then' \
  'if [[ -z "$started" ]] && item_in "$item" ${FILELESS[@]+"${FILELESS[@]}"} && cloud_stall_close "$item" "$since"; then'
new_case control_pushed_no_close
DIRECTIVE_AGE=4300 cloud_state
open_pr "" ""
for age in 600 2500 4300 6099 6100; do
  (( age < 2500 )) || printf '%s\n' "$PUSHED_HEAD" > "$STUB_DIR/branch-head"
  CLOUD_WATCH="$MUTANT_WATCH" watch "$age" ORCH_OVERSEER_MARK_REPEAT=3
done
assert_eq "events=$EVENTS closes=$(closes) rc=$RC" "events= closes=0 rc=0" \
  "control: a pushed lane kept from the close stays open past its directive bound" "$STUB_DIR/err"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
