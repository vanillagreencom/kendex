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
  MAIN_NOTICES="$(awk '/^oversee-watch: main-push-unread / { n++ } END { print n+0 }' "$STUB_DIR/err")"
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
  'reordered-suites|203|failure|suite-reverse|' \
  'later-run-new-duration|203|failure|duration|' \
  "added-suite|203|failure|added|EVENT main-push-failing owner/repo workflow=skill-tests.yml run=203 jobs=$JOBS cause=$CAUSE" \
  "removed-suite|203|failure|base|EVENT main-push-failing owner/repo workflow=skill-tests.yml run=203 jobs=$JOBS cause=$CAUSE" \
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
    duration | suite-reverse | added) names="$JOBS" ;;
    changed) names='["Other job"]' ;;
  esac
  jq -cn --argjson names "$names" '{jobs: (($names | map({name: ., conclusion: "failure"})) + [{name: "Green job", conclusion: "success"}, {name: "Skipped job", conclusion: "skipped"}])}' > "$STUB_DIR/main-jobs.$run.json"
  printf 'Job\tSuite\t2026-10-08T08:00:00Z suite=green seconds=1 pass=4 fail=0\nJob\tSuite\t2026-10-08T08:00:00Z %s\nJob\tSuite\t2026-10-08T08:00:00Z suite=later seconds=1 pass=0 fail=1\n' "$CAUSE" > "$STUB_DIR/main-log.$run.txt"
  case "$job_case" in
    duration) printf 'suite=oversee_watch seconds=7 pass=5 fail=1\nsuite=later seconds=9 pass=8 fail=2\n' > "$STUB_DIR/main-log.$run.txt" ;;
    suite-reverse) printf 'suite=later seconds=1 pass=0 fail=1\n%s\n' "$CAUSE" > "$STUB_DIR/main-log.$run.txt" ;;
    added) printf 'suite=added seconds=1 pass=0 fail=1\n' >> "$STUB_DIR/main-log.$run.txt" ;;
  esac
  main_watch
  assert_eq "rc=$MAIN_RC events=$MAIN_EVENTS" "rc=0 events=$expected" "$name" "$STUB_DIR/err"
done

# An unread dependency must preserve the standing failure. Its restoration
# must stay quiet rather than creating another incident.
for read_kind in runs jobs log; do
  case "$read_kind" in
    runs) unread="$STUB_DIR/main-push.owner_repo.err" ;;
    jobs) unread="$STUB_DIR/main-jobs.202.err" ;;
    log) unread="$STUB_DIR/main-log.202.err" ;;
  esac
  printf 'HTTP 502: bad gateway\n' > "$unread"
  main_watch
  assert_eq "rc=$MAIN_RC notices=$MAIN_NOTICES events=$MAIN_EVENTS" 'rc=0 notices=1 events=' "unread $read_kind" "$STUB_DIR/err"
  rm -- "$unread"
  main_watch
  assert_eq "rc=$MAIN_RC events=$MAIN_EVENTS" 'rc=0 events=' "restored $read_kind preserves incident" "$STUB_DIR/err"
done

# Missing first logs report the red jobs promptly. Recovered evidence becomes
# the baseline for later changes, including another attempt of the same run.
new_case main_push_initial_unread
printf '[{"databaseId":202,"headBranch":"main","event":"push","status":"completed","conclusion":"failure"}]\n' > "$STUB_DIR/main-push.owner_repo.json"
jq -cn --argjson names "$JOBS" '{jobs: ($names | map({name: ., conclusion: "failure"}))}' > "$STUB_DIR/main-jobs.202.json"
printf '%s\n' "$CAUSE" > "$STUB_DIR/main-log.202.txt"
for row in \
  "first-unread|unread|1|EVENT main-push-failing owner/repo workflow=skill-tests.yml run=202 jobs=$JOBS cause=unread" \
  'still-unread|unread|1|' \
  'logs-recovered|read|0|' \
  'same-recovered-logs|read|0|' \
  "changed-same-run|changed|0|$EVENT" \
  'reordered-same-run|reverse|0|'; do
  IFS='|' read -r name log_case notices expected <<<"$row"
  rm -f -- "$STUB_DIR/main-log.202.err"
  case "$log_case" in
    unread) printf 'HTTP 502: bad gateway\n' > "$STUB_DIR/main-log.202.err" ;;
    changed) printf 'suite=later seconds=1 pass=0 fail=1\n' >> "$STUB_DIR/main-log.202.txt" ;;
    reverse) printf 'suite=later seconds=1 pass=0 fail=1\n%s\n' "$CAUSE" > "$STUB_DIR/main-log.202.txt" ;;
  esac
  main_watch
  assert_eq "rc=$MAIN_RC notices=$MAIN_NOTICES events=$MAIN_EVENTS" "rc=0 notices=$notices events=$expected" "$name" "$STUB_DIR/err"
done

# gh's rewritten 404 alone does not prove that the workflow is absent.
for row in \
  "absent|{\"workflows\":[]}|0|$EVENT" \
  'present-unread|{"workflows":[]} {"workflows":[{"path":".github/workflows/skill-tests.yml"}]}|1|' \
  'workflow-list-unread|denied|1|' \
  'workflow-list-invalid|{}|1|'; do
  IFS='|' read -r name workflows notices restored <<<"$row"
  new_case "$name"
  printf '[{"databaseId":202,"headBranch":"main","event":"push","status":"completed","conclusion":"failure"}]\n' > "$STUB_DIR/main-push.owner_repo.json"
  jq -cn --argjson names "$JOBS" '{jobs: ($names | map({name: ., conclusion: "failure"}))}' > "$STUB_DIR/main-jobs.202.json"
  printf '%s\n' "$CAUSE" > "$STUB_DIR/main-log.202.txt"
  main_watch
  assert_eq "$MAIN_EVENTS" "$EVENT" "$name seeds incident" "$STUB_DIR/err"
  printf 'HTTP 404: workflow skill-tests.yml not found on the default branch (https://api.github.com/repos/owner/repo/actions/workflows/skill-tests.yml)\n' > "$STUB_DIR/main-push.owner_repo.err"
  if [[ "$workflows" == denied ]]; then
    printf 'HTTP 502: bad gateway\n' > "$STUB_DIR/workflows.owner_repo.err"
  else
    printf '%s\n' "$workflows" > "$STUB_DIR/workflows.owner_repo.json"
  fi
  main_watch
  assert_eq "rc=$MAIN_RC notices=$MAIN_NOTICES events=$MAIN_EVENTS" "rc=0 notices=$notices events=" "$name" "$STUB_DIR/err"
  main_watch
  assert_eq "rc=$MAIN_RC notices=$MAIN_NOTICES events=$MAIN_EVENTS" "rc=0 notices=$notices events=" "$name repeated pass" "$STUB_DIR/err"
  rm -- "$STUB_DIR/main-push.owner_repo.err"
  main_watch
  assert_eq "rc=$MAIN_RC events=$MAIN_EVENTS" "rc=0 events=$restored" "$name restoration" "$STUB_DIR/err"
done

# These producers are the workflow's FAILED: loop and GitHub's timed_out
# conclusion. Both must produce a failing event through the real watch.
for row in \
  'timed-out|timed_out|suite=oversee_watch seconds=1 pass=4 fail=1' \
  'failed-suite-line|failure|FAILED: skills/orch/tests/oversee_watch_main_push.sh'; do
  IFS='|' read -r name conclusion cause <<<"$row"
  new_case "$name"
  jq -cn --arg conclusion "$conclusion" '[{databaseId: 202, headBranch: "main", event: "push", status: "completed", conclusion: $conclusion}]' > "$STUB_DIR/main-push.owner_repo.json"
  jq -cn --arg conclusion "$conclusion" '{jobs: [{name: "Skill suites job", conclusion: $conclusion}]}' > "$STUB_DIR/main-jobs.202.json"
  printf 'Job\tSuite\t2026-10-08T08:00:00Z %s\n' "$cause" > "$STUB_DIR/main-log.202.txt"
  main_watch
  assert_eq "rc=$MAIN_RC events=$MAIN_EVENTS" "rc=0 events=EVENT main-push-failing owner/repo workflow=skill-tests.yml run=202 jobs=[\"Skill suites job\"] cause=$cause" "$name" "$STUB_DIR/err"
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
