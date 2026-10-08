#!/usr/bin/env bash
# Surface: oversee-watch main-push-failing protocol consumed by oversee-events.md.
# Inputs: scripts/oversee-watch, scripts/lib/oversee-watch-text.sh and lib/oversee-watch-harness.sh.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
# shellcheck source=lib/oversee-watch-harness.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/oversee-watch-harness.sh"

main_watch() {
  MAIN_RC=0
  : > "$STUB_DIR/gh.calls"
  run_watch -- --max-loops 1 >"$STUB_DIR/out" 2>"$STUB_DIR/err" </dev/null || MAIN_RC=$?
  MAIN_EVENTS="$(awk '/^EVENT main-push-failing /' "$STUB_DIR/out")"
}

new_case main_push_timeline
JOBS='["Skill suites shard (guards-commit, macos-latest)","Skill suites shard (orch-oversee, macos-latest)"]'
CAUSE='suite=oversee_watch seconds=1 pass=4 fail=1'
EVENT="EVENT main-push-failing owner/repo workflow=skill-tests.yml run=202 jobs=$JOBS cause=$CAUSE"
# Separate invocations share the real watch's incident record. The newer
# non-main, non-push and unfinished runs must not hide the completed main push.
for row in \
  'green|201|success|base|' \
  "new-failure|202|failure|base|$EVENT" \
  'unchanged-failure|202|failure|reverse|' \
  'later-run-same-failures|203|failure|base|' \
  'later-run-new-duration|203|failure|duration|' \
  "changed-jobs|204|failure|changed|EVENT main-push-failing owner/repo workflow=skill-tests.yml run=204 jobs=[\"Other job\"] cause=$CAUSE" \
  'recovered|205|success|base|' \
  "failure-after-recovery|202|failure|base|$EVENT"; do
  IFS='|' read -r name run conclusion job_case expected <<<"$row"
  jq -cn --argjson id "$run" --arg conclusion "$conclusion" '[
    {databaseId: 999, headBranch: "feature", event: "push", status: "completed", conclusion: "failure"},
    {databaseId: 998, headBranch: "main", event: "pull_request", status: "completed", conclusion: "failure"},
    {databaseId: 997, headBranch: "main", event: "push", status: "in_progress", conclusion: ""},
    {databaseId: $id, headBranch: "main", event: "push", status: "completed", conclusion: $conclusion},
    {databaseId: 100, headBranch: "main", event: "push", status: "completed", conclusion: "failure"}
  ]' > "$STUB_DIR/main-push.owner_repo.json"
  case "$job_case" in
    base) names="$JOBS" ;;
    reverse) names='["Skill suites shard (orch-oversee, macos-latest)","Skill suites shard (guards-commit, macos-latest)"]' ;;
    duration) names="$JOBS" ;;
    changed) names='["Other job"]' ;;
  esac
  jq -cn --argjson names "$names" '{jobs: (($names | map({name: ., conclusion: "failure"})) + [{name: "Green job", conclusion: "success"}, {name: "Skipped job", conclusion: "skipped"}])}' > "$STUB_DIR/main-jobs.$run.json"
  printf 'Job\tSuite\t2026-10-08T08:00:00Z suite=green seconds=1 pass=4 fail=0\nJob\tSuite\t2026-10-08T08:00:00Z %s\nJob\tSuite\t2026-10-08T08:00:00Z suite=later seconds=1 pass=0 fail=1\n' "$CAUSE" > "$STUB_DIR/main-log.$run.txt"
  [[ "$job_case" != duration ]] || printf 'Job\tSuite\t2026-10-08T08:00:00Z suite=oversee_watch seconds=7 pass=5 fail=1\n' > "$STUB_DIR/main-log.$run.txt"
  main_watch
  assert_eq "rc=$MAIN_RC events=$MAIN_EVENTS" "rc=0 events=$expected" "$name" "$STUB_DIR/err"
done

# An unread dependency must preserve the standing failure. Its restoration
# must stay quiet rather than creating another incident.
for read_kind in runs jobs; do
  case "$read_kind" in
    runs) unread="$STUB_DIR/main-push.owner_repo.err" ;;
    jobs) unread="$STUB_DIR/main-jobs.202.err" ;;
  esac
  printf 'HTTP 502: bad gateway\n' > "$unread"
  main_watch
  assert_eq "rc=$MAIN_RC events=$MAIN_EVENTS" 'rc=0 events=' "unread $read_kind" "$STUB_DIR/err"
  rm -- "$unread"
  main_watch
  assert_eq "rc=$MAIN_RC events=$MAIN_EVENTS" 'rc=0 events=' "restored $read_kind preserves incident" "$STUB_DIR/err"
done

# Retain the check call but make it unreachable. The same event oracle must
# fail while the mutant watch completes, proving the production path matters.
MUTANT="$(mutant_scripts main-control/orch oversee-watch)/oversee-watch" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/main-control/github"
mutate_file "$MUTANT" '    check_main_push' '    if false; then check_main_push; fi'
new_case main_push_control
printf '[{"databaseId":202,"headBranch":"main","event":"push","status":"completed","conclusion":"failure"}]\n' > "$STUB_DIR/main-push.owner_repo.json"
jq -cn --argjson names "$JOBS" '{jobs: ($names | map({name: ., conclusion: "failure"}))}' > "$STUB_DIR/main-jobs.202.json"
printf '%s\n' "$CAUSE" > "$STUB_DIR/main-log.202.txt"
WATCH_BIN="$MUTANT" main_watch
CONTROL_RC=0
( assert_eq "$MAIN_EVENTS" "$EVENT" 'positive main-push event oracle'; [[ "$FAIL" -eq 0 ]] ) > "$STUB_DIR/control.out" || CONTROL_RC=$?
assert_eq "watch=$MAIN_RC oracle=$CONTROL_RC" 'watch=0 oracle=1' 'control rejects an unreachable main-push check' "$STUB_DIR/err"

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
