#!/usr/bin/env bash
# oversee-watch's start-stalled report: a running lane record whose status
# file, tmp/lane-status-<item>.md under its mail_root, is still missing
# ORCH_WATCH_START_STALL_SECS after the record went running, its running_at, on
# every harness, a hosted one read through `lane-host cat`. A lane whose host
# kind declares files=none, a Claude cloud session, writes no file: its own
# open pull request on the item branch is its start. Reported once, then every
# ORCH_OVERSEER_MARK_REPEAT passes while it stands. The file also covers
# lane-long, check_lane_long: one report per age interval for a running or
# parked lane, including across watch restarts, relaunches and handoffs.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
# shellcheck source=lib/oversee-watch-harness.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/oversee-watch-harness.sh"
# mutant_scripts and mutate_file, the two halves of the control below.
# shellcheck source=lib/growth-state.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/growth-state.sh"

FIXTURE_HOST="$REPO_ROOT/skills/orch/tests/fixtures/lane-host"
LAUNCHED=2026-08-15T10:00:00Z
LAUNCHED_EPOCH="$(date -u -d "$LAUNCHED" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$LAUNCHED" +%s)"

# launched ITEM ROOT [HARNESS] [HOST] [RUNNING_AFTER] — one running lane record
# with no window, so the pass reads no pane for it, launched at LAUNCHED on
# ROOT. RUNNING_AFTER, in seconds past LAUNCHED, stamps its running_at, the
# time a prepared launch or a relaunch recorded it running; with none the
# record carries no running_at, as one written before the stamp.
launched() {
  local running=""
  [[ -z "${5:-}" ]] || running="$(date -u -d "@$((LAUNCHED_EPOCH + $5))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -r "$((LAUNCHED_EPOCH + $5))" +%Y-%m-%dT%H:%M:%SZ)"
  jq -cn --arg item "$1" --arg root "$2" --arg harness "${3:-claude}" --arg host "${4:-}" --arg at "$LAUNCHED" --arg running "$running" \
    '{item: $item, window: null, host: (if $host == "" then null else $host end), mail_root: $root,
      harness: $harness, launched_at: $at, status: "running"} + (if $running == "" then {} else {running_at: $running} end)'
}
write_state() { # RECORD...
  printf '%s\n' "$@" | jq -s '{issue_id: "oversee", triaged: [], lanes: .}' > "$STUB_DIR/state.json"
}
# A lane worktree on this disk, with its mailbox directory and, where STATUS
# is `status`, the status file its workflow writes.
worktree() { # ITEM [status]
  local root="$STUB_DIR/wt/$1"
  mkdir -p "$root/tmp/lane-mail/$1"
  [[ "${2:-}" != status ]] || printf 'step: dev round 1\n' > "$root/tmp/lane-status-$1.md"
  printf '%s\n' "$root"
}
# watch AGE [ENV=VAL...] — one pass at LAUNCHED + AGE seconds; EVENTS holds its
# EVENT lines joined by `|`, the heartbeat left out. An empty
# ORCH_WATCH_LANE_AGE_SECS drops the harness's neutral lane-long bound for the
# watch's own default.
watch() {
  local age="$1"
  shift
  printf '%s\n' "$((LAUNCHED_EPOCH + age))" > "$STUB_DIR/now.epoch"
  EVENTS="$(run_watch ORCH_WATCH_LANE_AGE_SECS "$@" -- --max-loops 1 --state "$STUB_DIR/state.json" 2>"$STUB_DIR/err" </dev/null \
    | grep '^EVENT ' | grep -v '^EVENT heartbeat' | paste -sd '|' - || true)"
}

echo "=== a lane with no status file past the window is reported, on every harness ==="
new_case start_stalled
ROOT_1="$(worktree issue-1)"
ROOT_2="$(worktree issue-2 status)"
ROOT_3="$(worktree issue-3)"
write_state "$(launched issue-1 "$ROOT_1" pi)" "$(launched issue-2 "$ROOT_2" claude)" "$(launched issue-3 "$ROOT_3" codex)"
# AGE|WANT: under the window nothing, past it each file-less lane once, the
# lane with its file never.
for row in "599|" "600|EVENT start-stalled issue-1 age=600|EVENT start-stalled issue-3 age=600" "660|"; do
  IFS='|' read -r age want <<<"$row"
  want="${row#*|}"
  watch "$age"
  assert_eq "events=$EVENTS" "events=$want" "a pass ${age}s after launch at the default window of 600 reports '${want:-nothing}'" "$STUB_DIR/err"
done

echo "=== a standing stall comes back every ORCH_OVERSEER_MARK_REPEAT passes ==="
new_case start_stall_repeat
ROOT_1="$(worktree issue-1)"
write_state "$(launched issue-1 "$ROOT_1" pi)"
for row in "700|EVENT start-stalled issue-1 age=700" "760|" "820|EVENT start-stalled issue-1 age=820"; do
  IFS='|' read -r age want <<<"$row"
  watch "$age" ORCH_OVERSEER_MARK_REPEAT=2
  assert_eq "events=$EVENTS" "events=$want" "at ORCH_OVERSEER_MARK_REPEAT=2 the pass ${age}s after launch reports '${want:-nothing}'" "$STUB_DIR/err"
done

echo "=== the window runs from when the record went running ==="
# A prepared launch went running 1000 seconds after its launch: the host's
# preparation is not the lane's start, so nothing is due until 600 seconds
# after that.
new_case start_stall_prepared
ROOT_1="$(worktree issue-1)"
write_state "$(launched issue-1 "$ROOT_1" pi "" 1000)"
for row in "1599|" "1600|EVENT start-stalled issue-1 age=600"; do
  IFS='|' read -r age want <<<"$row"
  want="${row#*|}"
  watch "$age"
  assert_eq "events=$EVENTS" "events=$want" "a record that went running 1000s after launch reports '${want:-nothing}' ${age}s after launch" "$STUB_DIR/err"
done
# A relaunch renews running_at: the stall reported above does not carry over,
# and a fresh window runs from the relaunch, so the next line is a second
# stall.
write_state "$(launched issue-1 "$ROOT_1" pi "" 2000)"
for row in "2599|" "2600|EVENT start-stalled issue-1 age=600"; do
  IFS='|' read -r age want <<<"$row"
  want="${row#*|}"
  watch "$age"
  assert_eq "events=$EVENTS" "events=$want" "after a relaunch at 2000s the pass ${age}s after launch reports '${want:-nothing}'" "$STUB_DIR/err"
done

echo "=== a status file that once stood is never a late start ==="
new_case start_stall_seen
ROOT_1="$(worktree issue-1 status)"
write_state "$(launched issue-1 "$ROOT_1" pi)"
watch 60
rm -f -- "${ROOT_1:?}/tmp/lane-status-issue-1.md"
watch 700
assert_eq "events=$EVENTS" "events=" "a lane whose close-out removed its status file after it stood reports nothing" "$STUB_DIR/err"
rm -rf -- "${ROOT_1:?}"
write_state "$(launched issue-1 "$ROOT_1" pi)" "$(launched issue-4 "$STUB_DIR/wt/issue-4" pi)"
watch 760
assert_eq "events=$EVENTS" "events=" "a local root that is no directory is a removed worktree, never a late start" "$STUB_DIR/err"

echo "=== a hosted lane's status file is read through lane-host ==="
new_case start_stall_hosted
REMOTE_DISK="$STUB_DIR/remote"
mkdir -p "$REMOTE_DISK/srv/lane/issue-5/tmp/lane-mail/issue-5" "$REMOTE_DISK/srv/lane/issue-6/tmp/lane-mail/issue-6"
printf 'gitdir: /srv/clone/.git/worktrees/issue-5\n' > "$REMOTE_DISK/srv/lane/issue-5/.git"
printf 'gitdir: /srv/clone/.git/worktrees/issue-6\n' > "$REMOTE_DISK/srv/lane/issue-6/.git"
printf 'step: dev round 1\n' > "$REMOTE_DISK/srv/lane/issue-6/tmp/lane-status-issue-6.md"
write_state "$(launched issue-5 /srv/lane/issue-5 pi "$FIXTURE_HOST")" "$(launched issue-6 /srv/lane/issue-6 claude "$FIXTURE_HOST")"
HOSTED_ENV=(ORCH_LANE_HOST="$FIXTURE_HOST" LANE_HOST_STUB_LOG="$STUB_DIR/host.log" LANE_HOST_STUB_DIR="$REMOTE_DISK")
watch 700 "${HOSTED_ENV[@]}"
assert_eq "events=$EVENTS" "events=EVENT start-stalled issue-5 age=700" \
  "a hosted lane with no status file on its host is reported, one with the file is not" "$STUB_DIR/err"
# A read the host failed settles nothing: noted, and no event on a guess.
watch 1300 "${HOSTED_ENV[@]}" LANE_HOST_STUB_CAT_STATUS=5 LANE_HOST_STUB_CAT_ITEM=issue-5 \
  LANE_HOST_STUB_CAT_PATH=/srv/lane/issue-5/tmp/lane-status-issue-5.md
assert_eq "events=$EVENTS unread=$(grep -c '^oversee-watch: start-stall-unread item=issue-5 exit=2$' "$STUB_DIR/err" || true)" \
  "events= unread=1" "a failed hosted read is noted and reports no stall" "$STUB_DIR/err"
# lane-long reads a hosted lane's Step line through lane-host too.
watch 12600 "${HOSTED_ENV[@]}"
assert_eq "events=$EVENTS" "events=EVENT lane-long issue-5 age=12600 review_rounds=unread fix_receipts=unread validation_runs=unread restacks=unread repeated_class_rounds=unread stage=none|EVENT lane-long issue-6 age=12600 review_rounds=unread fix_receipts=unread validation_runs=unread restacks=unread repeated_class_rounds=unread stage=dev round 1" \
  "a hosted lane past the lane-long bound carries the Step line its host holds, or none" "$STUB_DIR/err"
# A hosted read that failed is unread, never none: issue-6's host holds a Step
# line, which a read that went through would carry.
new_case lane_long_hosted_unread
REMOTE_DISK="$STUB_DIR/remote"
mkdir -p "$REMOTE_DISK/srv/lane/issue-6/tmp/lane-mail/issue-6"
printf 'gitdir: /srv/clone/.git/worktrees/issue-6\n' > "$REMOTE_DISK/srv/lane/issue-6/.git"
printf 'step: dev round 1\n' > "$REMOTE_DISK/srv/lane/issue-6/tmp/lane-status-issue-6.md"
write_state "$(launched issue-6 /srv/lane/issue-6 claude "$FIXTURE_HOST")"
HOSTED_ENV=(ORCH_LANE_HOST="$FIXTURE_HOST" LANE_HOST_STUB_LOG="$STUB_DIR/host.log" LANE_HOST_STUB_DIR="$REMOTE_DISK")
watch 12600 "${HOSTED_ENV[@]}" LANE_HOST_STUB_CAT_STATUS=5 LANE_HOST_STUB_CAT_ITEM=issue-6 \
  LANE_HOST_STUB_CAT_PATH=/srv/lane/issue-6/tmp/lane-status-issue-6.md
assert_eq "events=$EVENTS" "events=EVENT lane-long issue-6 age=12600 review_rounds=unread fix_receipts=unread validation_runs=unread restacks=unread repeated_class_rounds=unread stage=unread" \
  "a hosted lane whose status read failed is lane-long with stage=unread" "$STUB_DIR/err"

echo "=== a lane whose kind writes no file starts with its own pull request ==="
# One claude-cloud record per case, its mail_root a local worktree holding no
# status file. OPEN is the item branch's open pull request line, the head
# owner last: none, the lane's own, or a fork's on the same branch name.
OWN_PR=$'7\tissue-7\tcloud lane\toctocat\tabc111\t## Lane status'
FORK_PR=$'8\tissue-7\tfork lane\tforker\tdef222\t## Lane status\tforker'
cloud_start() { # NAME OPEN [WATCH_BIN]
  new_case "$1"
  write_state "$(launched issue-7 "$(worktree issue-7)" claude claude-cloud)"
  printf '%s\n' "$2" > "$STUB_DIR/open.txt"
  WATCH_BIN="${3:-}" watch 700
}
# NAME|OPEN|WANT
for row in "start_stall_cloud_none||EVENT start-stalled issue-7 age=700" "start_stall_cloud_own|$OWN_PR|" \
  "start_stall_cloud_fork|$FORK_PR|EVENT start-stalled issue-7 age=700"; do
  IFS='|' read -r name open want <<<"$row"
  cloud_start "$name" "$open"
  assert_eq "events=$EVENTS" "events=$want" "$name: a files=none lane's start is its own open pull request" "$STUB_DIR/err"
done

echo "=== lane-long repeats at age intervals across a relaunch and a handoff ==="
# issue-1 was launched at LAUNCHED; issue-2 an hour later and recorded running
# an hour after that, so it crosses at the last pass only when aged from its
# launched_at, not its running_at; issue-3 is parked.
new_case lane_long
ROOT_1="$(worktree issue-1 status)"
ROOT_2="$(worktree issue-2 status)"
long_state() { # STATUS_1 [RUNNING_AFTER_1]
  write_state "$(launched issue-1 "$ROOT_1" claude "" "${2:-}" | jq -c --arg s "$1" '.status = $s')" \
    "$(launched issue-2 "$ROOT_2" claude "" 7200 | jq -c '.launched_at = "2026-08-15T11:00:00Z"')" \
    "$(launched issue-3 /srv/lane/issue-3 claude | jq -c '.status = "parked" | .parked = {pr: 9, repo: "owner/repo", head: "abc", at: "2026-08-15T10:30:00Z"}')"
}
# STATUS_1|RUNNING_AFTER_1|AGE|WANT: a pass under the bound, the pass that
# crosses it, later passes, the stopped record a handoff leaves, and the
# relaunch that renews running_at but keeps launched_at.
for row in "running||12599|" \
  "running||12600|EVENT lane-long issue-3 age=12600 review_rounds=unread fix_receipts=unread validation_runs=unread restacks=unread repeated_class_rounds=unread stage=parked|EVENT lane-long issue-1 age=12600 review_rounds=unread fix_receipts=unread validation_runs=unread restacks=unread repeated_class_rounds=unread stage=dev round 1" \
  "running||12660|" "stopped||15000|" "running|15060|15100|" "running|15060|16199|" \
  "running|15060|16200|EVENT lane-long issue-2 age=12600 review_rounds=unread fix_receipts=unread validation_runs=unread restacks=unread repeated_class_rounds=unread stage=dev round 1" \
  "running|15060|25199|" \
  "running|15060|25200|EVENT lane-long issue-3 age=25200 review_rounds=unread fix_receipts=unread validation_runs=unread restacks=unread repeated_class_rounds=unread stage=parked|EVENT lane-long issue-1 age=25200 review_rounds=unread fix_receipts=unread validation_runs=unread restacks=unread repeated_class_rounds=unread stage=dev round 1" \
  "running|25300|25360|" \
  "running|25300|28800|EVENT lane-long issue-2 age=25200 review_rounds=unread fix_receipts=unread validation_runs=unread restacks=unread repeated_class_rounds=unread stage=dev round 1" \
  "running|25300|37799|" \
  "running|25300|37800|EVENT lane-long issue-3 age=37800 review_rounds=unread fix_receipts=unread validation_runs=unread restacks=unread repeated_class_rounds=unread stage=parked|EVENT lane-long issue-1 age=37800 review_rounds=unread fix_receipts=unread validation_runs=unread restacks=unread repeated_class_rounds=unread stage=dev round 1" \
  "running|25300|63000|EVENT lane-long issue-3 age=63000 review_rounds=unread fix_receipts=unread validation_runs=unread restacks=unread repeated_class_rounds=unread stage=parked|EVENT lane-long issue-1 age=63000 review_rounds=unread fix_receipts=unread validation_runs=unread restacks=unread repeated_class_rounds=unread stage=dev round 1|EVENT lane-long issue-2 age=59400 review_rounds=unread fix_receipts=unread validation_runs=unread restacks=unread repeated_class_rounds=unread stage=dev round 1" \
  "running|25300|63060|"; do
  IFS='|' read -r status running age want <<<"$row"
  want="${row#*|*|*|}"
  long_state "$status" "$running"
  watch "$age"
  assert_eq "events=$EVENTS" "events=$want" "a $status issue-1 record ${age}s after launch reports '${want:-nothing}'" "$STUB_DIR/err"
done

echo "=== lane-long uses the shared default at the threshold ==="
default_long_case() { # NAME [WATCH_BIN]
  new_case "$1"
  write_state "$(launched issue-1 "$(worktree issue-1 status)" claude)"
  WATCH_BIN="${2:-}" watch 12601
}
assert_default_long() {
  assert_eq "events=$EVENTS" "events=EVENT lane-long issue-1 age=12601 review_rounds=unread fix_receipts=unread validation_runs=unread restacks=unread repeated_class_rounds=unread stage=dev round 1" \
    "the unset default reports a lane aged 12601s" "$STUB_DIR/err"
}
new_case lane_long_below_default
write_state "$(launched issue-1 "$(worktree issue-1 status)" claude)"
watch 12599
assert_eq "events=$EVENTS" "events=" "the unset default does not report a lane aged 12599s" "$STUB_DIR/err"
default_long_case lane_long_above_default
assert_default_long

echo "=== lane-long counts existing review and patch records ==="
# The two fix writers append one {cause, commit} per fixed finding. Several
# entries in one commit remain one patch round, including repeated causes.
rounds_case() { # NAME STATE [WATCH_BIN] [MODE]
  local root
  new_case "$1"
  root="$(worktree issue-1 status)"
  [[ -z "$2" ]] || printf '%s\n' "$2" > "$root/tmp/workflow-state-issue-1.json"
  case "${4:-}" in
    fileless)
      write_state "$(launched issue-1 "$root" claude claude-cloud)"
      printf '7\tissue-1\tcloud lane\toctocat\tabc111\t## Lane status\n' > "$STUB_DIR/open.txt" ;;
    parked) write_state "$(launched issue-1 "$root" claude | jq -c '.status = "parked" | .parked = {pr:9,repo:"owner/repo",head:"abc",at:"2026-08-15T10:30:00Z"}')" ;;
    *) write_state "$(launched issue-1 "$root" claude)" ;;
  esac
  WATCH_BIN="${3:-}" watch 12601
}
REPEATED_STATE='{"pr_comment_review":{"iterations":2,"patched_causes":[{"cause":"unchecked read","commit":"aaa111"},{"cause":"unchecked read","commit":"bbb222"}]}}'
LOCATION_STATE='{"pr_comment_review":{"iterations":2,"patched_causes":[{"cause":"unchecked read","commit":"aaa111","location":" src/x.rs (`f`) "},{"cause":"stale count","commit":"bbb222","location":"src/x.rs (`f`)"}]}}'
COUNTS_STATE='{"first_panel":{},"rereview_cycles":1,"cycles":7,"pr_comment_review":{"iterations":3,"patched_causes":[{"cause":"a","commit":"aaa111"},{"cause":"a","commit":"bbb222"}]},"stages":[{"kind":"implement"},{"kind":"fix"},{"kind":"fix"},{"kind":"fix"},{"kind":"review"}],"validate_rounds":[{"kind":"implement"},{"kind":"fix"},{"kind":"restack"},{"kind":"restack"}],"restack_skips":[{},{}]}'
NO_STAGES_STATE="$(jq -c 'del(.stages)' <<<"$COUNTS_STATE")"
# NAME|STATE|REVIEW|FIXES|VALIDATIONS|RESTACKS|REPEATED
for row in \
  "separate_counts|$COUNTS_STATE|5|3|2|4|1" \
  "no_stages|$NO_STAGES_STATE|5|unread|2|4|1" \
  "fileless|$COUNTS_STATE|unread|unread|unread|unread|unread" \
  "parked|$COUNTS_STATE|unread|unread|unread|unread|unread" \
  'no_validation_lists|{"stages":[]}|0|0|0|0|unread' \
  'absent_state||unread|unread|unread|unread|unread' \
  "two_bot_rounds|$REPEATED_STATE|2|unread|0|0|1" \
  "different_causes_one_location|$LOCATION_STATE|2|unread|0|0|1" \
  'one_location_one_commit|{"pr_comment_review":{"iterations":1,"patched_causes":[{"cause":"a","commit":"aaa111","location":"src/x.rs (`f`)"},{"cause":"b","commit":"aaa111","location":"src/x.rs (`f`)"}]}}|1|unread|0|0|0' \
  'ht_2098|{"pr_comment_review":{"iterations":2,"patched_causes":[{"cause":"a","commit":"8f27054b","location":"src/x.rs (`f`)"},{"cause":"b","commit":"e4ed9beb","location":"src/x.rs (`f`)"},{"cause":"c","commit":"70110a24","location":"src/x.rs (`f`)"},{"cause":"d","commit":"d48cc623","location":"src/x.rs (`f`)"}]}}|2|unread|0|0|3' \
  'unknown_locations|{"pr_comment_review":{"iterations":2,"patched_causes":[{"cause":"a","commit":"aaa111","location":"general"},{"cause":"b","commit":"bbb222","location":"general"}]}}|2|unread|0|0|0' \
  'new_symbol|{"pr_comment_review":{"iterations":2,"patched_causes":[{"cause":"a","commit":"aaa111","location":"src/x.rs (`f`)"},{"cause":"b","commit":"bbb222","location":"src/x.rs (`g`)"}]}}|2|unread|0|0|0' \
  'internal_and_bot|{"first_panel":{"agents":["reviewer-error"]},"rereview_cycles":1,"pr_comment_review":{"iterations":2,"patched_causes":[{"cause":"unchecked read","commit":"aaa111"},{"cause":"unchecked read","commit":"bbb222"}]}}|4|unread|0|0|1' \
  'no_classes|{"first_panel":{"agents":["reviewer-error"]},"rereview_cycles":1,"pr_comment_review":{"iterations":2}}|4|unread|0|0|unread' \
  'same_commit|{"pr_comment_review":{"iterations":1,"patched_causes":[{"cause":"unchecked read","commit":"aaa111"},{"cause":"unchecked read","commit":"aaa111"}]}}|1|unread|0|0|0' \
  'two_classes_one_round|{"pr_comment_review":{"iterations":2,"patched_causes":[{"cause":"unchecked read","commit":"aaa111"},{"cause":"stale count","commit":"aaa111"},{"cause":"unchecked read","commit":"bbb222"},{"cause":"stale count","commit":"bbb222"}]}}|2|unread|0|0|1' \
  'initial_state|{"rereview_cycles":0,"pr_comment_review":{"iterations":0,"patched_causes":[]}}|0|unread|0|0|unread' \
  'unread_state|{|unread|unread|unread|unread|unread' \
  'invalid_rounds|{"rereview_cycles":"unknown"}|unread|unread|unread|unread|unread' ; do
  IFS='|' read -r name state review fixes validations restacks repeated <<<"$row"
  stage='dev round 1'
  case "$name" in fileless) stage=none ;; parked) stage=parked ;; esac
  rounds_case "lane_long_$name" "$state" "" "$name"
  assert_eq "events=$EVENTS" "events=EVENT lane-long issue-1 age=12601 review_rounds=$review fix_receipts=$fixes validation_runs=$validations restacks=$restacks repeated_class_rounds=$repeated stage=$stage" \
    "$name: lane-long carries the recorded counts" "$STUB_DIR/err"
  case "$name" in unread_state|invalid_rounds)
    assert_file_contains "$STUB_DIR/err" 'oversee-watch: lane-long-rounds-unread item=issue-1' "$name: the unread count has a keyed notice" ;;
  esac
done

echo "=== lane-long reads hosted state and skips a parked disk ==="
new_case lane_long_hosted_rounds
REMOTE_DISK="$STUB_DIR/remote"
mkdir -p "$REMOTE_DISK/srv/lane/issue-1/tmp/lane-mail/issue-1" "$REMOTE_DISK/srv/clone/tmp"
printf 'gitdir: /srv/clone/.git/worktrees/issue-1\n' > "$REMOTE_DISK/srv/lane/issue-1/.git"
printf 'Step: review\n' > "$REMOTE_DISK/srv/lane/issue-1/tmp/lane-status-issue-1.md"
printf '%s\n' "$REPEATED_STATE" > "$REMOTE_DISK/srv/clone/tmp/workflow-state-issue-1.json"
write_state "$(launched issue-1 /srv/lane/issue-1 claude "$FIXTURE_HOST")"
HOSTED_ENV=(ORCH_LANE_HOST="$FIXTURE_HOST" LANE_HOST_STUB_LOG="$STUB_DIR/host.log" LANE_HOST_STUB_DIR="$REMOTE_DISK")
watch 12601 "${HOSTED_ENV[@]}"
assert_eq "events=$EVENTS" "events=EVENT lane-long issue-1 age=12601 review_rounds=2 fix_receipts=unread validation_runs=0 restacks=0 repeated_class_rounds=1 stage=review" \
  "the hosted lane reads its clone's state" "$STUB_DIR/err"
new_case lane_long_parked_rounds
: > "$STUB_DIR/host.log"
HOSTED_ENV=(ORCH_LANE_HOST="$FIXTURE_HOST" LANE_HOST_STUB_LOG="$STUB_DIR/host.log" LANE_HOST_STUB_DIR="$REMOTE_DISK")
write_state "$(launched issue-1 /srv/lane/issue-1 claude "$FIXTURE_HOST" | jq -c '.status = "parked" | .parked = {pr:9,repo:"owner/repo",head:"abc",at:"2026-08-15T10:30:00Z"}')"
watch 12601 "${HOSTED_ENV[@]}"
assert_eq "events=$EVENTS" "events=EVENT lane-long issue-1 age=12601 review_rounds=unread fix_receipts=unread validation_runs=unread restacks=unread repeated_class_rounds=unread stage=parked" \
  "a parked lane carries unavailable counts" "$STUB_DIR/err"
assert_eq "reads=$(grep -c '^cat ' "$STUB_DIR/host.log" || true)" "reads=0" "a parked lane reads no stopped disk" "$STUB_DIR/err"

echo "=== a fresh launch renews lane-long age even while the item keeps its row ==="
new_case lane_long_fresh
ROOT_1="$(worktree issue-1 status)"
write_state "$(launched issue-1 "$ROOT_1" claude)"
watch 12600
write_state "$(launched issue-1 "$ROOT_1" claude | jq -c '.launched_at = "2026-08-15T13:30:00Z"')"
for row in "25199|" "25200|EVENT lane-long issue-1 age=12600 review_rounds=unread fix_receipts=unread validation_runs=unread restacks=unread repeated_class_rounds=unread stage=dev round 1" "28860|"; do
  IFS='|' read -r age want <<<"$row"
  watch "$age"
  assert_eq "events=$EVENTS" "events=$want" "a fresh launch reports only when its own age crosses the bound" "$STUB_DIR/err"
done

echo "=== epoch-only rows from the older watch count as the first interval ==="
new_case lane_long_legacy
ROOT_1="$(worktree issue-1 status)"
write_state "$(launched issue-1 "$ROOT_1" claude)"
mkdir -p "$STATE_DIR"
printf 'lane-long\tissue-1\t%s\n' "$LAUNCHED_EPOCH" > "$STATE_DIR/owner_repo__none"
for row in "12660|" "25199|" "25200|EVENT lane-long issue-1 age=25200 review_rounds=unread fix_receipts=unread validation_runs=unread restacks=unread repeated_class_rounds=unread stage=dev round 1" "28860|" \
  "37800|EVENT lane-long issue-1 age=37800 review_rounds=unread fix_receipts=unread validation_runs=unread restacks=unread repeated_class_rounds=unread stage=dev round 1"; do
  IFS='|' read -r age want <<<"$row"
  watch "$age"
  assert_eq "events=$EVENTS" "events=$want" "an older row suppresses interval one and permits later intervals" "$STUB_DIR/err"
done

echo "=== lane-long reads the Step line bare or as a list item ==="
# step_case NAME LINE [WATCH_BIN] — one lane past the bound whose status file
# holds a heading and LINE; STAGE is the stage its lane-long event carries.
step_case() {
  local root
  new_case "$1"
  root="$(worktree issue-1)"
  printf '# issue-1 lane status\n\n%s\n- PR: none\n' "$2" > "$root/tmp/lane-status-issue-1.md"
  write_state "$(launched issue-1 "$root" claude)"
  WATCH_BIN="${3:-}" watch 12600
  STAGE="${EVENTS#EVENT lane-long issue-1 age=12600 review_rounds=unread fix_receipts=unread validation_runs=unread restacks=unread repeated_class_rounds=unread stage=}"
}
# NAME|LINE|STAGE
for row in "step_bare|Step: range validation|range validation" "step_dash|- Step: range validation|range validation" \
  "step_star|* step: range validation|range validation" "step_absent|- Stage: range validation|none"; do
  IFS='|' read -r name line want <<<"$row"
  step_case "lane_long_$name" "$line"
  assert_eq "stage=$STAGE" "stage=$want" "$name: '$line' reads stage=$want" "$STUB_DIR/err"
done
# Controls: a reader that takes only a bare line reads the list item as none,
# and one that takes only a list item reads the bare line as none.
# NAME|PATTERN|LINE
for row in "bare_only|/^step:/|- Step: range validation" "list_only|/^[-*][ \\t]+step:/|Step: range validation"; do
  IFS='|' read -r name pattern line <<<"$row"
  STEP_WATCH="$(mutant_scripts "lane-step-$name/orch" lib/watch-host-kinds.sh)/oversee-watch" || exit 1
  ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/lane-step-$name/github"
  mutate_file "${STEP_WATCH%/*}/lib/watch-host-kinds.sh" '/^([-*][ \t]+)?step:/' "$pattern"
  step_case "lane_step_${name}_mutant" "$line" "$STEP_WATCH"
  assert_eq "stage=$STAGE" "stage=none" "control: a $name reader reads '$line' as none" "$STUB_DIR/err"
done

echo "=== the window is a setting ==="
new_case start_stall_bound
ROOT_1="$(worktree issue-1)"
write_state "$(launched issue-1 "$ROOT_1" pi)"
watch 61 ORCH_WATCH_START_STALL_SECS=60
assert_eq "events=$EVENTS" "events=EVENT start-stalled issue-1 age=61" "ORCH_WATCH_START_STALL_SECS sets the window" "$STUB_DIR/err"
watch 120 ORCH_WATCH_START_STALL_SECS=060
assert_eq "refused=$(grep -c '^oversee-watch: start-stall-secs-invalid value=060$' "$STUB_DIR/err" || true)" "refused=1" \
  "a window that is not a positive whole number refuses the watch" "$STUB_DIR/err"
watch 120 ORCH_WATCH_LANE_STALL_SECS=060
LANE_STALL_REFUSED="$(grep -c '^oversee-watch: lane-stall-secs-invalid value=060$' "$STUB_DIR/err" || true)"
assert_eq "refused=$LANE_STALL_REFUSED" "refused=1" \
  "a lane-stalled window that is not a positive whole number refuses the watch" "$STUB_DIR/err"
new_case lane_long_bound
write_state "$(launched issue-1 "$(worktree issue-1 status)" pi)"
watch 61 ORCH_WATCH_LANE_AGE_SECS=60
assert_eq "events=$EVENTS" "events=EVENT lane-long issue-1 age=61 review_rounds=unread fix_receipts=unread validation_runs=unread restacks=unread repeated_class_rounds=unread stage=dev round 1" "ORCH_WATCH_LANE_AGE_SECS sets the bound" "$STUB_DIR/err"
watch 120 ORCH_WATCH_LANE_AGE_SECS=060
assert_eq "refused=$(grep -c '^oversee-watch: lane-age-secs-invalid value=060$' "$STUB_DIR/err" || true)" "refused=1" \
  "a lane-long bound that is not a positive whole number refuses the watch" "$STUB_DIR/err"

echo "=== must-fail control ==="
# Restoring the old default must redden the same above-threshold assertion.
OLD_DEFAULT_WATCH="$(mutant_scripts lane-long-old-default/orch oversee-watch)/oversee-watch" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/lane-long-old-default/github"
# shellcheck disable=SC2016
mutate_file "$OLD_DEFAULT_WATCH" 'LANE_AGE_SECS="${ORCH_WATCH_LANE_AGE_SECS:-12600}"' 'LANE_AGE_SECS="${ORCH_WATCH_LANE_AGE_SECS:-14400}"'
default_long_case lane_long_old_default "$OLD_DEFAULT_WATCH"
if (FAIL=0; assert_default_long; [[ "$FAIL" -eq 0 ]]) > "$STUB_DIR/control.out"; then
  fail "control: the old default did not redden the above-threshold row"
else
  assert_file_contains "$STUB_DIR/control.out" 'got:      events=' "control: the old default reddens the above-threshold row"
fi
COUNTS_WATCH="$(mutant_scripts lane-long-counts/orch lib/lane-gitfile.sh)/oversee-watch" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/lane-long-counts/github"
# shellcheck disable=SC2016
mutate_file "${COUNTS_WATCH%/*}/lib/lane-gitfile.sh" '($history.repeated | unique | length)' '(($history.repeated | unique | length) * 0)'
rounds_case lane_long_counts_mutant "$REPEATED_STATE" "$COUNTS_WATCH"
if (FAIL=0; assert_eq "events=$EVENTS" "events=EVENT lane-long issue-1 age=12601 review_rounds=2 fix_receipts=unread validation_runs=0 restacks=0 repeated_class_rounds=1 stage=dev round 1" counts-control "$STUB_DIR/err"; [[ "$FAIL" -eq 0 ]]) > "$STUB_DIR/control.out"; then
  fail "control: removing repeated rounds did not redden their event row"
else
  assert_file_contains "$STUB_DIR/control.out" 'got:      events=EVENT lane-long issue-1 age=12601 review_rounds=2 fix_receipts=unread validation_runs=0 restacks=0 repeated_class_rounds=0' \
    "control: removing repeated rounds reddens their event row"
fi
LOCATION_WATCH="$(mutant_scripts lane-long-location/orch lib/lane-gitfile.sh)/oversee-watch" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/lane-long-location/github"
# shellcheck disable=SC2016
mutate_file "${LOCATION_WATCH%/*}/lib/lane-gitfile.sh" 'and .location == $location' 'and false'
rounds_case lane_long_location_mutant "$LOCATION_STATE" "$LOCATION_WATCH"
if (FAIL=0; assert_eq "events=$EVENTS" "events=EVENT lane-long issue-1 age=12601 review_rounds=2 fix_receipts=unread validation_runs=0 restacks=0 repeated_class_rounds=1 stage=dev round 1" location-control "$STUB_DIR/err"; [[ "$FAIL" -eq 0 ]]) > "$STUB_DIR/control.out"; then
  fail "control: removing location matches did not redden their event row"
else
  assert_file_contains "$STUB_DIR/control.out" 'got:      events=EVENT lane-long issue-1 age=12601 review_rounds=2 fix_receipts=unread validation_runs=0 restacks=0 repeated_class_rounds=0' \
    "control: removing location matches reddens their event row"
fi
# Each mutation changes the shared reader the event consumes.
for name in fixes skips unread; do
  case "$name" in
    fixes) old='[.stages[] | select(.kind == "fix")] | length' new='.cycles' ;;
    skips) old='(.restack_skips // [] | length)' new='0' ;;
    unread) old='LANE_REVIEW_ROUNDS=unread' new='LANE_REVIEW_ROUNDS=0' ;;
  esac
  ROUND_WATCH="$(mutant_scripts "lane-round-$name/orch" lib/lane-gitfile.sh)/oversee-watch" || exit 1
  ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/lane-round-$name/github"
  mutate_file "${ROUND_WATCH%/*}/lib/lane-gitfile.sh" "$old" "$new"
  state="$COUNTS_STATE"
  expected='review_rounds=5 fix_receipts=3 validation_runs=2 restacks=4 repeated_class_rounds=1'
  if [[ "$name" == unread ]]; then
    state=''
    expected='review_rounds=unread fix_receipts=unread validation_runs=unread restacks=unread repeated_class_rounds=unread'
  fi
  rounds_case "lane_round_${name}_mutant" "$state" "$ROUND_WATCH"
  if (FAIL=0; assert_eq "events=$EVENTS" "events=EVENT lane-long issue-1 age=12601 $expected stage=dev round 1" round-control "$STUB_DIR/err"; [[ "$FAIL" -eq 0 ]]) > "$STUB_DIR/control.out"; then
    fail "control: $name did not redden the event count row"
  else
    assert_file_contains "$STUB_DIR/control.out" 'got:      events=EVENT lane-long issue-1' "control: $name reddens the event count row"
  fi
done
# The status file never looked for: a lane that wrote its file is reported
# stalled all the same.
MUTANT_DIR="$TMP_ROOT/start-stall-mutant"
MUTANT_WATCH="$(mutant_scripts start-stall-mutant/orch oversee-watch)/oversee-watch" || exit 1
ln -s "$REPO_ROOT/skills/github" "$MUTANT_DIR/github"
mutate_file "$MUTANT_WATCH" '      [[ -e "$path" ]] || rc=1' '      rc=1'
new_case start_stall_mutant
ROOT_2="$(worktree issue-2 status)"
write_state "$(launched issue-2 "$ROOT_2" claude)"
WATCH_BIN="$MUTANT_WATCH" watch 700
assert_eq "events=$EVENTS" "events=EVENT start-stalled issue-2 age=700" \
  "control: without the status-file test a lane that wrote its file is reported stalled" "$STUB_DIR/err"

# The window anchored on launched_at again: a prepared lane's preparation is
# counted as its own stall.
ANCHOR_DIR="$TMP_ROOT/start-stall-anchor"
ANCHOR_WATCH="$(mutant_scripts start-stall-anchor/orch oversee-watch)/oversee-watch" || exit 1
ln -s "$REPO_ROOT/skills/github" "$ANCHOR_DIR/github"
mutate_file "$ANCHOR_WATCH" '((.running_at // .launched_at) | if' '(.launched_at | if'
new_case start_stall_anchor_mutant
ROOT_1="$(worktree issue-1)"
write_state "$(launched issue-1 "$ROOT_1" pi "" 1000)"
WATCH_BIN="$ANCHOR_WATCH" watch 1599
assert_eq "events=$EVENTS" "events=EVENT start-stalled issue-1 age=1599" \
  "control: anchored on launched_at a lane that went running 599s ago is reported stalled" "$STUB_DIR/err"

# A files=none lane read as one with a status file, which has no root to read
# it under: a lane with no pull request is never reported.
FILELESS_DIR="$TMP_ROOT/start-stall-fileless"
FILELESS_WATCH="$(mutant_scripts start-stall-fileless/orch oversee-watch)/oversee-watch" || exit 1
ln -s "$REPO_ROOT/skills/github" "$FILELESS_DIR/github"
# shellcheck disable=SC2016  # the script's own text, never expanded here.
mutate_file "$FILELESS_WATCH" $'    if item_in "$item" ${FILELESS[@]+"${FILELESS[@]}"}; then\n      item_open_pr' $'    if false; then\n      item_open_pr'
cloud_start start_stall_fileless_mutant "" "$FILELESS_WATCH"
assert_eq "events=$EVENTS" "events=" \
  "control: read for a status file, a files=none lane with no pull request is never reported" "$STUB_DIR/err"
# The head owner never compared: a fork's pull request on the branch name
# stands in for the lane's start.
FORK_DIR="$TMP_ROOT/start-stall-fork"
FORK_WATCH="$(mutant_scripts start-stall-fork/orch lib/watch-host-kinds.sh)/oversee-watch" || exit 1
ln -s "$REPO_ROOT/skills/github" "$FORK_DIR/github"
mutate_file "${FORK_WATCH%/*}/lib/watch-host-kinds.sh" '[.[] | lane_own($branch; $owner; null)] | first' '[.[]] | first'
cloud_start start_stall_fork_mutant "$FORK_PR" "$FORK_WATCH"
assert_eq "events=$EVENTS" "events=" "control: without the owner rule a fork's pull request starts the lane" "$STUB_DIR/err"
# The lane-stalled window never validated: 060 runs the watch.
SECS_DIR="$TMP_ROOT/lane-stall-secs"
SECS_WATCH="$(mutant_scripts lane-stall-secs/orch oversee-watch)/oversee-watch" || exit 1
ln -s "$REPO_ROOT/skills/github" "$SECS_DIR/github"
# shellcheck disable=SC2016
mutate_file "$SECS_WATCH" '[[ "$LANE_STALL_SECS" =~ ^[1-9][0-9]*$ ]] || die' 'true || die'
new_case lane_stall_secs_mutant
write_state "$(launched issue-1 "$(worktree issue-1 status)" pi)"
WATCH_BIN="$SECS_WATCH" watch 120 ORCH_WATCH_LANE_STALL_SECS=060
assert_eq "refused=$(grep -c '^oversee-watch: lane-stall-secs-invalid' "$STUB_DIR/err" || true)" "refused=0" \
  "control: without its check a lane-stalled window of 060 is taken" "$STUB_DIR/err"

# The lane-long bound never validated: 060 runs the watch.
# shellcheck disable=SC2016
mutate_file "$SECS_WATCH" '[[ "$LANE_AGE_SECS" =~ ^[1-9][0-9]*$ ]] || die' 'true || die'
WATCH_BIN="$SECS_WATCH" watch 120 ORCH_WATCH_LANE_AGE_SECS=060
assert_eq "refused=$(grep -c '^oversee-watch: lane-age-secs-invalid' "$STUB_DIR/err" || true)" "refused=0" \
  "control: without its check a lane-long bound of 060 is taken" "$STUB_DIR/err"
# lane-long never keyed by its interval: every pass past the bound reports again.
ONCE_DIR="$TMP_ROOT/lane-long-once"
ONCE_WATCH="$(mutant_scripts lane-long-once/orch lib/watch-host-kinds.sh)/oversee-watch" || exit 1
ln -s "$REPO_ROOT/skills/github" "$ONCE_DIR/github"
# shellcheck disable=SC2016
mutate_file "${ONCE_WATCH%/*}/lib/watch-host-kinds.sh" '    [[ "$prior" != "$launched|$interval" ]] || continue' '    true || continue'
new_case lane_long_once_mutant
write_state "$(launched issue-1 "$(worktree issue-1 status)" claude)"
WATCH_BIN="$ONCE_WATCH" watch 12600
WATCH_BIN="$ONCE_WATCH" watch 12660
assert_eq "events=$EVENTS" "events=EVENT lane-long issue-1 age=12660 review_rounds=unread fix_receipts=unread validation_runs=unread restacks=unread repeated_class_rounds=unread stage=dev round 1" \
  "control: without the reported key a lane past the bound is lane-long on every pass" "$STUB_DIR/err"
# A fixed interval restores the older watch's once-per-launch behavior.
REPEAT_DIR="$TMP_ROOT/lane-long-repeat"
REPEAT_WATCH="$(mutant_scripts lane-long-repeat/orch lib/watch-host-kinds.sh)/oversee-watch" || exit 1
ln -s "$REPO_ROOT/skills/github" "$REPEAT_DIR/github"
# shellcheck disable=SC2016
mutate_file "${REPEAT_WATCH%/*}/lib/watch-host-kinds.sh" '    interval=$((age / LANE_AGE_SECS))' '    interval=1'
new_case lane_long_repeat_mutant
write_state "$(launched issue-1 "$(worktree issue-1 status)" claude)"
WATCH_BIN="$REPEAT_WATCH" watch 12600
WATCH_BIN="$REPEAT_WATCH" watch 25200
assert_eq "events=$EVENTS" "events=" \
  "control: a fixed interval loses the warning at the next age multiple" "$STUB_DIR/err"
# lane-long rows pruned by the running set: the stopped record a handoff
# leaves drops the row, and the relaunch reports the lane again.
GAP_DIR="$TMP_ROOT/lane-long-gap"
GAP_WATCH="$(mutant_scripts lane-long-gap/orch lib/watch-host-kinds.sh)/oversee-watch" || exit 1
ln -s "$REPO_ROOT/skills/github" "$GAP_DIR/github"
# shellcheck disable=SC2016
mutate_file "${GAP_WATCH%/*}/lib/watch-host-kinds.sh" '"$rows" ${RECORDED_ITEMS[@]+"${RECORDED_ITEMS[@]}"}' '"$rows" ${ITEMS[@]+"${ITEMS[@]}"}'
new_case lane_long_gap_mutant
ROOT_1="$(worktree issue-1 status)"
for row in "running||12600" "stopped||15000" "running|15060|15100"; do
  IFS='|' read -r status running age <<<"$row"
  write_state "$(launched issue-1 "$ROOT_1" claude "" "$running" | jq -c --arg s "$status" '.status = $s')"
  WATCH_BIN="$GAP_WATCH" watch "$age"
done
assert_eq "events=$EVENTS" "events=EVENT lane-long issue-1 age=15100 review_rounds=unread fix_receipts=unread validation_runs=unread restacks=unread repeated_class_rounds=unread stage=dev round 1" \
  "control: pruned by the running set, a relaunch after a handoff reports the lane again" "$STUB_DIR/err"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
