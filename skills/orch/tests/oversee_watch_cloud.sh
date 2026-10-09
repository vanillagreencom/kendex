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
# where it is not given. DIRECTIVE_AGE, where set, is the age in seconds past
# LAUNCHED at which lane-mail recorded a directive sent to it.
cloud_state() { # [WINDOW]
  mkdir -p "$STUB_DIR/wt/issue-1"
  jq -n --arg root "$STUB_DIR/wt/issue-1" --arg at "$LAUNCHED" --arg window "${1:-}" \
    --arg sent "${DIRECTIVE_AGE:+$((LAUNCHED_EPOCH + DIRECTIVE_AGE))}" '{issue_id: "oversee", triaged: [], lanes: [
    {item: "issue-1", window: (if $window == "" then null else $window end), host: "claude-cloud", kind: "claude-cloud", mail_root: $root, harness: "claude",
     session_id: "session_01CLOUD", account: "/cloud-account", launched_at: $at, running_at: $at, status: "running"}
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
exec "$REPO_ROOT/skills/orch/scripts/lane-mail" "\$@"
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

echo "=== a directive left unanswered past ORCH_CLOUD_STALL_MINUTES closes the lane ==="
# The record's directive went out at DIRECTIVE_AGE; the default bound is 30
# minutes. A close runs the harness's lane-close stub, whose argv the closes
# row reads.
CLOSED="EVENT lane-closed issue-1|EVENT cloud-stall-closed issue-1 directive_age=1800"
BRANCH_HEAD=1111111111111111111111111111111111111111
PUSHED_HEAD=2222222222222222222222222222222222222222
closes() { awk 'END { print NR + 0 }' "$STUB_DIR/lane-close.args" 2>/dev/null || echo 0; }
# LABEL|NAME|DIRECTIVE_AGE|rows as stall_case takes them
for row in \
  "a stalled pull request with no push since the directive|stall_bound|2000|100,abc111,b,;1900,abc111,b,EVENT lane-stalled issue-1 age=1800;3799,abc111,b,;3800,abc111,b,$CLOSED" \
  "a head pushed after the directive|stall_bound_moved|2000|100,abc111,b,;1900,abc111,b,EVENT lane-stalled issue-1 age=1800;2100,abc222,b,;3800,abc222,b,;3900,abc222,b,EVENT lane-stalled issue-1 age=1800" \
  "a lane that never opened its pull request|start_bound|700|600,,,EVENT start-stalled issue-1 age=600;2499,,,;2500,,,$CLOSED" \
  "an unchanged branch without a pull request|start_bound_unchanged|700|600,,$BRANCH_HEAD,EVENT start-stalled issue-1 age=600;2500,,$BRANCH_HEAD,$CLOSED" \
  "a first push after the startup directive whose pull request creation fails|start_bound_first_push|700|600,,,EVENT start-stalled issue-1 age=600;2500,,$PUSHED_HEAD,;2560,,$PUSHED_HEAD,;2620,,$PUSHED_HEAD,EVENT start-stalled issue-1 age=2620" \
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
  "ready_both|room||100,abc111,b,true,;200,abc222,c,false,EVENT lane-stalled issue-1 age=0 state=finished" \
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

echo "=== controls ==="
# cloud_mutant NAME SCRIPT OLD NEW — a copy of the scripts with one rule of
# SCRIPT removed, the github skill beside it as the harness's mutants lay it.
cloud_mutant() {
  local dir scripts
  dir="$TMP_ROOT/$1"
  scripts="$(mutant_scripts "$1/orch" "$2")" || exit 1
  ln -s "$REPO_ROOT/skills/github" "$dir/github"
  mutate_file "$scripts/$2" "$3" "$4"
  CLOUD_WATCH="$scripts/oversee-watch"
}
# shellcheck disable=SC2016  # the script's own text, never expanded here.
cloud_mutant mail-session oversee-watch '    item_in "$item" ${MAILLESS[@]+"${MAILLESS[@]}"} || mail_items+=("$item")' '    mail_items+=("$item")'
new_case cloud_mail_mutant
cloud_state
open_pr abc111 "## Lane status"
watch 700
assert_eq "red=$([[ "$(grep -c -- '--item issue-1' "$STUB_DIR/mail.calls" || true)" -gt 0 ]] && echo yes || echo no)" "red=yes" \
  "control: a mail pass reading a channel=session lane fails the mail row" "$STUB_DIR/err"
# shellcheck disable=SC2016
cloud_mutant handoff-fileless oversee-watch '    ! item_in "$item" ${FILELESS[@]+"${FILELESS[@]}"} || continue' '    :'
new_case cloud_handoff_mutant
cloud_state
open_pr abc111 "## Lane status"
watch 700
assert_eq "red=$([[ "$(handoff_reads)" -gt 0 ]] && echo yes || echo no)" "red=yes" \
  "control: a handoff check reading a files=none lane's state fails the state row" "$STUB_DIR/err"
# shellcheck disable=SC2016
cloud_mutant window-statusless oversee-watch '[[ -z "$window" ]] || item_in "$item" ${STATUSLESS[@]+"${STATUSLESS[@]}"} || LANES+=("$window")' '[[ -z "$window" ]] || LANES+=("$window")'
new_case cloud_window_mutant
cloud_state main:issue-1
open_pr abc111 "## Lane status"
watch 700
assert_eq "events=$EVENTS" "events=EVENT window-gone main:issue-1" \
  "control: a status=none window carried into the pane passes fails the window row" "$STUB_DIR/err"
# shellcheck disable=SC2016
cloud_mutant list-once lib/watch-host-kinds.sh '    [[ "${entry%%|*}" == "$1" ]] || continue' '    continue'
new_case cloud_list_mutant
cloud_state
open_pr abc111 "## Lane status"
watch 700
assert_eq "lists=$(open_lists)" "lists=2" "control: a pass that lists again for its second caller fails the one-list row" "$STUB_DIR/err"
# shellcheck disable=SC2016
cloud_mutant stall-digest lib/watch-host-kinds.sh '    if [[ "$prior" != "$OPEN_PR_HEAD|$digest|"* ]]; then' '    if [[ "${prior%%|*}" != "$OPEN_PR_HEAD" ]]; then'
CASE_LABEL="control: without the body digest a changed body" stall_case stall_body_mutant \
  "100|abc111|## Lane status working||" "1900|abc111|## Lane status pushed fix|EVENT lane-stalled issue-1 age=1800"
# shellcheck disable=SC2016
cloud_mutant stall-head lib/watch-host-kinds.sh '    if [[ "$prior" != "$OPEN_PR_HEAD|$digest|"* ]]; then' '    if [[ "${prior#*|}" != "$digest|"* ]]; then'
CASE_LABEL="control: without the head compare a new head" stall_case stall_head_mutant \
  "100|abc111|## Lane status working||" "1900|abc222|## Lane status working|EVENT lane-stalled issue-1 age=1800"
# shellcheck disable=SC2016
cloud_mutant stall-repeat lib/watch-host-kinds.sh '    if (( passes == 0 )); then' '    if true; then'
CASE_LABEL="control: reported every pass, the quiet pass after a report" stall_case stall_repeat_mutant \
  "100|abc111|## Lane status working||" "1900|abc111|## Lane status working|EVENT lane-stalled issue-1 age=1800" \
  "1960|abc111|## Lane status working|EVENT lane-stalled issue-1 age=1860"
# shellcheck disable=SC2016
cloud_mutant bound-none lib/watch-host-kinds.sh '  [[ -n "$at" ]] && (( at >= $2 && PASS_NOW - at >= CLOUD_STALL_SECS )) || return 1' '  return 1'
DIRECTIVE_AGE=2000 CASE_LABEL="control: without the bound the unanswered lane is left running" stall_case stall_bound_mutant \
  "100|abc111|b|" "1900|abc111|b|EVENT lane-stalled issue-1 age=1800" "3800|abc111|b|"
assert_eq "closes=$(closes)" "closes=0" "control: without the bound no lane-close runs" "$STUB_DIR/err"
# shellcheck disable=SC2016
cloud_mutant bound-since lib/watch-host-kinds.sh '(( at >= $2 && PASS_NOW' '(( PASS_NOW'
DIRECTIVE_AGE=2000 CASE_LABEL="control: a directive older than the last push" stall_case stall_bound_since_mutant \
  "100|abc111|b|" "1900|abc111|b|EVENT lane-stalled issue-1 age=1800" "2100|abc222|b|"   "3900|abc222|b|EVENT lane-closed issue-1|EVENT cloud-stall-closed issue-1 directive_age=1900"
# shellcheck disable=SC2016
cloud_mutant start-bound-progress oversee-watch 'cloud_stall_close "$item" "$since"' 'cloud_stall_close "$item" "$running"'
DIRECTIVE_AGE=700 CASE_LABEL="control: launch time hides a first push after the directive" stall_case start_bound_progress_mutant \
  "600|||EVENT start-stalled issue-1 age=600" "2500||$PUSHED_HEAD|$CLOSED"
assert_eq "closes=$(closes)" "closes=1" "control: the first-push row rejects closure on launch time" "$STUB_DIR/err"
# shellcheck disable=SC2016
cloud_mutant start-bound-unread lib/watch-host-kinds.sh 'ow_message branch-read-failed "item=$1" "repo=$repo" >&2; cat -- "$WORK_DIR/pr.err" >&2; rc=2; break' 'ow_message branch-read-failed "item=$1" "repo=$repo" >&2; cat -- "$WORK_DIR/pr.err" >&2; rc=1; break'
DIRECTIVE_AGE=700 CASE_LABEL="control: an unread branch treated as absent closes the lane" stall_case start_bound_unread_mutant \
  "600|||EVENT start-stalled issue-1 age=600" "2500||unread|$CLOSED"
assert_eq "closes=$(closes)" "closes=1" "control: the unread row rejects closing without branch evidence" "$STUB_DIR/err"
# shellcheck disable=SC2016
cloud_mutant ready-field lib/watch-host-kinds.sh 'headRefName,headRepositoryOwner,headRefOid,body,isDraft' 'headRefName,headRepositoryOwner,headRefOid,body'
state_case ready_field_mutant room '' '100,abc111,b,true,;200,abc111,b,false,'
assert_eq "red=$([[ "$EVENTS" != "$FINISHED" ]] && echo yes || echo no)" "red=yes" \
  "control: omitting isDraft fails the ready row" "$STUB_DIR/err"
# shellcheck disable=SC2016
cloud_mutant credit-judgment lib/watch-host-kinds.sh '| if length > 0 then "out-of-credit" else "" end' '| if false then "out-of-credit" else "" end'
state_case credit_judgment_mutant zero '' '100,abc111,b,true,'
assert_eq "red=$([[ "$EVENTS" != "$CREDIT" ]] && echo yes || echo no)" "red=yes" \
  "control: skipping the credit judgment fails the exhausted row" "$STUB_DIR/err"
# shellcheck disable=SC2016
cloud_mutant finished-close lib/watch-host-kinds.sh '[[ "$state" != finished ]] && (( age >= LANE_STALL_SECS ))' '(( age >= LANE_STALL_SECS ))'
new_case finished_close_mutant
DIRECTIVE_AGE=200 cloud_state
open_pr abc111 b
watch 100
open_pr abc111 b false
watch 2200
assert_eq "events=$EVENTS" "events=EVENT lane-closed issue-1|EVENT cloud-stall-closed issue-1 directive_age=2000" \
  "control: closing a finished lane fails the old-directive row" "$STUB_DIR/err"
unset CLOUD_WATCH

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
