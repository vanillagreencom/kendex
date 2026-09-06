#!/usr/bin/env bash
# Tracker-side controls for oversee-watch triage events: what an unseen team
# item emits, what acknowledges it, what the check refuses to run on, and the
# `--since` form it accepts. One run, one comparison: `watch EXPECT` reads
# exactly the facts EXPECT names, so a case fails on the fact it names.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
# shellcheck source=lib/oversee-watch-harness.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/oversee-watch-harness.sh"

SINCE=2026-08-15T09:00:00Z
HEARTBEAT1="EVENT+heartbeat+loops=1+interval=0s+since=$SINCE"
STATE_FILE_NAME="owner_repo__2026-08-15T09_00_00Z"

# run [ENV=VAL ...] -- ARGS... — one watch run; OUT, RC and ERR (a file) are
# what `watch` reads. `--since` is supplied unless ARGS carry their own.
RUN_SEQ=0
run() {
  local args=("$@") a since=yes
  for a in "$@"; do [[ "$a" == --since* ]] && since=no; done
  [[ "$since" == no ]] || args+=(--since "$SINCE")
  ERR="$TMP_ROOT/run-$((++RUN_SEQ)).err"
  OUT="$(run_watch "${args[@]}" 2>"$ERR")" && RC=0 || RC=$?
}

# watch EXPECT — prints the run's value of every `name=` field EXPECT names,
# in EXPECT's order (in a needle `+` reads as a space and %e as `=`; %B is the
# stub bin directory, %R the case's repository root, %S the stub directory):
#   rc               exit status
#   first            the first stdout line, or `none`
#   events           how many `EVENT triage` lines stdout carries
#   out~<text>       whether stdout carries <text>
#   stdout           `empty` or `lines`
#   stderr~<text>    whether stderr carries <text>
#   notes~<text>     how many stderr lines carry <text>
#   tracker~<text>   whether the tracker stub was called with <text>
#   tracker          `read` or `unread`
#   wsargs~<text>    whether the workflow-state stub was called with <text>
#   state~<text>     whether the per-repo baseline file carries <text> (`%t`
#                    reads as a tab)
#   state_files      how many files the state directory holds
watch() {
  local got="" token name value needle state_file="$STATE_DIR/$STATE_FILE_NAME"
  for token in $1; do
    name="${token%%=*}"
    needle="${name#*~}"; needle="${needle//+/ }"; needle="${needle//%e/=}"; needle="${needle//%B/$TMP_ROOT/bin}"
    needle="${needle//%R/$CASE_REPO_ROOT}"; needle="${needle//%S/$STUB_DIR}"; needle="${needle//%t/$'\t'}"
    case "$name" in
      rc) value="$RC" ;;
      first) value="$(head -n 1 <<<"$OUT")"; value="${value:-none}"; value="${value// /+}" ;;
      events) value="$(grep -c '^EVENT triage ' <<<"$OUT" || true)" ;;
      out~*) value="$(grep -qF -- "$needle" <<<"$OUT" && echo true || echo false)" ;;
      stdout) value="$([[ -n "$OUT" ]] && echo lines || echo empty)" ;;
      stderr~*) value="$(grep -qF -- "$needle" "$ERR" && echo true || echo false)" ;;
      notes~*) value="$(grep -cF -- "$needle" "$ERR" || true)" ;;
      tracker~*) value="$([[ -e "$STUB_DIR/tracker.args" ]] && grep -qF -- "$needle" "$STUB_DIR/tracker.args" && echo true || echo false)" ;;
      tracker) value="$([[ -e "$STUB_DIR/tracker.args" ]] && echo read || echo unread)" ;;
      wsargs~*) value="$([[ -e "$STUB_DIR/workflow-state.args" ]] && grep -qF -- "$needle" "$STUB_DIR/workflow-state.args" && echo true || echo false)" ;;
      state~*) value="$([[ -e "$state_file" ]] && grep -qF -- "$needle" "$state_file" && echo true || echo false)" ;;
      state_files) value="$(find "$STATE_DIR" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d '[:space:]')" ;;
      *) echo "watch: unknown field $name" >&2; exit 1 ;;
    esac
    got="$got $name=$value"
  done
  printf '%s' "${got# }"
}

check() {
  [[ -n "$2" ]] || { printf 'check: a case with no expect asserts nothing: %s\n' "$1" >&2; exit 1; }
  assert_eq "$(watch "$2")" "$2" "$1" "$ERR"
}

tracker_items() { printf '%s\n' "$1" > "$STUB_DIR/tracker.out"; }
verdicts() { printf '{"triaged":%s}\n' "$1" > "$STUB_DIR/oversee-state.json"; }

echo "=== oversee-watch triage ==="

# A standing lane prompt first, so the state-file count below is taken on a
# run that has a lane fingerprint persisted already; a second file class would
# exist by then if lane-asking kept its own.
new_case triage_new
printf '1786957201\n' > "$STUB_DIR/now.epoch"
printf '3\n' > "$STUB_DIR/tracker.want-created-since"
printf 'Do you want to proceed?\n   ❯ 1. Yes\n     2. No\n' > "$STUB_DIR/pane-gh-2.txt"
tracker_items '[]'
run -- --max-loops 1 gh-1 gh-2
check "a standing lane prompt wakes the watch before any tracker item" "first=EVENT+lane-asking+gh-2"

# Items created after --since are one event each, in one wake, read from the
# live list for the fleet's team over a created-since day window; printing an
# event does not acknowledge it, and the fingerprints share the one per-repo
# baseline.
tracker_items '[{"id":"KEN-1200","created_at":"2026-08-15T10:00:00.000Z"},{"id":"KEN-1202","created_at":"2026-08-15T10:30:00.000Z"},{"id":"KEN-1204","created_at":"2026-08-15T11:30:00.000Z"},{"id":"KEN-1199","created_at":"2026-08-15T08:59:59.000Z"}]'
run -- gh-1 gh-2
check "three items after --since are three triage events in one wake, the earlier item not among them, read from the team's created-since list, none acknowledged by printing" \
  "rc=0 first=EVENT+triage+KEN-1200 events=3 out~EVENT+triage+KEN-1202=true out~EVENT+triage+KEN-1204=true out~KEN-1199=false tracker~issues+list+--team+kendex+--created-since+=true tracker~d+--max+--format%esafe=true state~triage%tKEN-1200=false state~lane-asking%tgh-2%t=true state_files=1"
run -- --max-loops 1
check "an unacknowledged item repeats on the next run" "first=EVENT+triage+KEN-1200"

# A kept or canceled verdict acknowledges the item into the watcher baseline,
# read from the oversee state under the project tmp directory; a pending
# verdict does neither.
verdicts '[{"issue":"KEN-1200","verdict":"kept"},{"issue":"KEN-1202","verdict":"canceled"},{"issue":"KEN-1204","verdict":"pending"}]'
run -- --max-loops 1
check "kept and canceled verdicts rebuild the baseline, pending stays out and repeats, the read anchored to the project tmp directory" \
  "first=EVENT+triage+KEN-1204 state~triage%tKEN-1200=true state~triage%tKEN-1202=true state~triage%tKEN-1204=false wsargs~--state-dir+%R/tmp+get+oversee=true"
verdicts '[{"issue":"KEN-1200","verdict":"kept"},{"issue":"KEN-1202","verdict":"canceled"},{"issue":"KEN-1204","verdict":"kept"}]'
run -- --max-loops 1
check "terminal verdicts close every repeated event" "first=$HEARTBEAT1"
tracker_items '[{"id":"KEN-1201","created_at":"2026-08-15T11:00:00.000Z"},{"id":"KEN-1200","created_at":"2026-08-15T10:00:00.000Z"}]'
run --
check "a later item fires on the next run and the acknowledged one stays deduplicated" "first=EVENT+triage+KEN-1201 out~EVENT+triage+KEN-1200=false"

new_case triage_empty
tracker_items '[]'
run -- --max-loops 1
check "control: an empty tracker list reaches the heartbeat with no triage event" "first=$HEARTBEAT1 events=0"

# A fleet with no tracker team is not a broken install: triage is skipped and
# named once, whether the name is absent or exported empty, and every other
# check --since serves keeps running, merged included. The first case exits on
# the merged event before the triage check; the second reaches it with a live
# tracker and an unseen item, and the tracker goes unread.
new_case triage_skipped_without_team
tracker_items '[{"id":"KEN-1200","created_at":"2026-08-15T10:00:00.000Z"}]'
printf '[{"number":5,"headRefName":"issue-5","mergedAt":"2026-08-15T10:00:00Z"}]\n' > "$STUB_DIR/merged.json"
run LINEAR_TEAM -- --max-loops 1 --item issue-5
check "an unset LINEAR_TEAM keeps the watch running and --since still serves the merged check" \
  "rc=0 first=EVENT+merged+5+issue-5 stderr~LINEAR_TEAM+is+unset+or+empty=true"
new_case triage_no_team_reaches_the_triage_check
tracker_items '[{"id":"KEN-1200","created_at":"2026-08-15T10:00:00.000Z"}]'
run LINEAR_TEAM -- --max-loops 1
check "with no team the run reaches the triage check, emits nothing for the unseen item and leaves the tracker unread" \
  "first=$HEARTBEAT1 events=0 tracker=unread"
new_case triage_skipped_by_an_empty_export
tracker_items '[{"id":"KEN-1200","created_at":"2026-08-15T10:00:00.000Z"}]'
run LINEAR_TEAM= -- --max-loops 1
check "an exported-empty LINEAR_TEAM takes the skip path the absent name takes" "rc=0 notes~skipping+the+team+triage+check=1"
new_case triage_skipped_without_team_or_tracker
run LINEAR_TEAM OVERSEE_WATCH_TRACKER="$TMP_ROOT/bin/absent-tracker" -- --max-loops 2
check "no team disarms the gate a missing tracker CLI would close, and the skip note prints once over two passes" \
  "rc=0 first=EVENT+heartbeat+loops=2+interval=0s+since=$SINCE notes~skipping+the+team+triage+check=1"

# The verdict read's state directory: an inherited one is cleared by the
# harness, a relative configured one joins the project root, an absolute one
# is kept.
for row in \
  "the common harness clears an inherited state directory|ORCH_STATE_DIR=leaked|wsargs~--state-dir+%R/tmp+get+oversee=true" \
  "a relative configured state directory joins the project root|ORCH_STATE_DIR=custom/state|wsargs~--state-dir+%R/custom/state+get+oversee=true" \
  "an absolute configured state directory is preserved|ORCH_STATE_DIR=%S/absolute-state|wsargs~--state-dir+%S/absolute-state+get+oversee=true"; do
  IFS='|' read -r label env expect <<<"$row"
  new_case triage_state_dir
  env="${env//%S/$STUB_DIR}"
  if [[ "$env" == ORCH_STATE_DIR=leaked ]]; then
    ORCH_STATE_DIR=leaked run -- --max-loops 1
  else
    run "$env" -- --max-loops 1
  fi
  check "$label" "$expect"
done

# Refusals: a missing CLI is a broken install, a read failure or malformed
# output is unknown fleet state, an unwritable baseline cannot acknowledge, and
# --since takes one form. Each exits 2 with no event and names its cause:
# `label|env|stubs|args|expect`, stubs `;`-separated `file=content` under the
# stub directory or `dir=<name>` under the state directory.
for row in \
  "a missing tracker CLI is named with its remedy|OVERSEE_WATCH_TRACKER=%B/absent-tracker|tracker.out=[{\"id\":\"KEN-1200\",\"created_at\":\"2026-08-15T10:00:00.000Z\"}]||rc=2 stdout=empty stderr~tracker+CLI+not+found+at+%B/absent-tracker=true stderr~OVERSEE_WATCH_TRACKER=true" \
  "a missing workflow-state CLI is named with its remedy|OVERSEE_WATCH_WORKFLOW_STATE=%B/absent-workflow-state|tracker.out=[{\"id\":\"KEN-1200\",\"created_at\":\"2026-08-15T10:00:00.000Z\"}]||rc=2 stdout=empty stderr~workflow-state+CLI+not+found+at+%B/absent-workflow-state=true stderr~OVERSEE_WATCH_WORKFLOW_STATE=true" \
  "a tracker list failure keeps its real cause||tracker.rc=2;tracker.err=Linear API unavailable||rc=2 stdout=empty stderr~Linear+API+unavailable=true" \
  "malformed tracker output is named||tracker.out={}||rc=2 stdout=empty stderr~tracker+output+is+not+an+array=true" \
  "an unwritable triage baseline names the shared state file|OVERSEE_WATCH_PR_WATCH=%B/absent-pr-watch|tracker.out=[{\"id\":\"KEN-1200\",\"created_at\":\"2026-08-15T10:00:00.000Z\"}];oversee-state.json={\"triaged\":[{\"issue\":\"KEN-1200\",\"verdict\":\"kept\"}]};dir=$STATE_FILE_NAME||rc=2 stdout=empty stderr~could+not+write+the+pr-watch+state+file=true" \
  "an unreadable verdict log keeps its original cause||workflow-state.rc=2;workflow-state.err=oversee state unreadable||rc=2 stdout=empty stderr~oversee+state+unreadable=true" \
  "an invalid verdict issue id is named||oversee-state.json={\"triaged\":[{\"issue\":\"bad id\",\"verdict\":\"kept\"}]}||rc=2 stdout=empty stderr~invalid+issue+id:+'bad+id'=true" \
  "a date-only --since is refused, naming the documented form|||--since 2026-08-15|rc=2 stdout=empty stderr~UTC+timestamp+ending+in+Z=true" \
  "an offset --since is refused, naming the documented form|||--since 2026-08-15T09:00:00+00:00|rc=2 stdout=empty stderr~UTC+timestamp+ending+in+Z=true"; do
  IFS='|' read -r label env stubs args expect <<<"$row"
  new_case triage_refusal
  if [[ -n "$stubs" ]]; then
    IFS=';' read -ra items <<<"$stubs"
    for item in "${items[@]}"; do
      if [[ "$item" == dir=* ]]; then mkdir -p "$STATE_DIR/${item#dir=}"; else printf '%s\n' "${item#*=}" > "$STUB_DIR/${item%%=*}"; fi
    done
  fi
  env="${env//%B/$TMP_ROOT/bin}"
  # shellcheck disable=SC2086
  if [[ -n "$env" ]]; then run "$env" -- $args; else run -- $args; fi
  check "$label" "$expect"
done

# Triage keys and reducer keys coexist in the one first-repository baseline. A
# triage rewrite that started from empty lost the standing reducer edge, and
# the next run emitted pr-watch again.
new_case triage_preserves_pr_keys
printf '12\tabcdef01\tthreads-open\t2 unresolved\n' > "$STUB_DIR/prwatch.out"
printf '1\n' > "$STUB_DIR/prwatch.rc"
tracker_items '[{"id":"KEN-1200","created_at":"2026-08-15T10:00:00.000Z"}]'
verdicts '[{"issue":"KEN-1200","verdict":"kept"}]'
run -- --max-loops 1
check "triage reconciliation preserves the reducer key beside the verdict key" "state~12%tthreads-open=true state~triage%tKEN-1200=true"
run -- --max-loops 1
check "unchanged reducer attention stays baselined after triage" "first=$HEARTBEAT1"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
