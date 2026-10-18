#!/usr/bin/env bash
# Surface: oversee-watch failed-run and budget events, consumed by oversee-events.md.
# Inputs: scripts/oversee-watch, scripts/lib/oversee-watch-text.sh and lib/oversee-watch-harness.sh.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
# shellcheck source=lib/oversee-watch-harness.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/oversee-watch-harness.sh"

main_watch() { # [VAR=VALUE...] — environment for this pass
  MAIN_RC=0
  : > "$STUB_DIR/gh.calls"
  run_watch "$@" -- --max-loops 1 >"$STUB_DIR/out" 2>"$STUB_DIR/err" </dev/null || MAIN_RC=$?
  MAIN_EVENTS="$(awk '/^EVENT main-push-failing /' "$STUB_DIR/out")"
  MAIN_ABSENT="$(awk '/^EVENT main-workflow-absent /' "$STUB_DIR/out")"
  MAIN_NOTICES="$(awk '/^oversee-watch: main-push-unread / { n++ } END { print n+0 }' "$STUB_DIR/err")"
}

new_case main_push_timeline
JOBS='["Skill suites shard (guards-commit, macos-latest)","Skill suites shard (orch-oversee, macos-latest)"]'
CAUSE='suite=oversee_watch seconds=1 pass=4 fail=1'
EVENT="EVENT main-push-failing owner/repo workflow=skill-tests.yml event=push run=202 jobs=$JOBS cause=$CAUSE"
# Separate invocations share the real watch's incident record. The newer
# non-main, non-push and unfinished runs must not hide the completed main push.
for row in \
  'green|201|success|base|' \
  "new-failure|202|failure|base|$EVENT" \
  'unchanged-failure|202|failure|reverse|' \
  'later-run-same-failures|203|failure|base|' \
  'reordered-suites|203|failure|suite-reverse|' \
  'later-run-new-duration|203|failure|duration|' \
  'deadline-started|203|failure|deadline-started|' \
  'deadline-unstarted|203|failure|deadline-unstarted|' \
  'suite-timeout|203|failure|timeout|' \
  'suite-timeout-new-bound|203|failure|timeout-later|' \
  'raw-failure|203|failure|raw|' \
  'raw-failure-changed|203|failure|raw-later|' \
  "added-suite|203|failure|added|EVENT main-push-failing owner/repo workflow=skill-tests.yml event=push run=203 jobs=$JOBS cause=$CAUSE" \
  "removed-suite|203|failure|base|EVENT main-push-failing owner/repo workflow=skill-tests.yml event=push run=203 jobs=$JOBS cause=$CAUSE" \
  "changed-jobs|204|failure|changed|EVENT main-push-failing owner/repo workflow=skill-tests.yml event=push run=204 jobs=[\"Other job\"] cause=$CAUSE" \
  "path-suites|204|failure|paths|EVENT main-push-failing owner/repo workflow=skill-tests.yml event=push run=204 jobs=$JOBS cause=FAILED: skills/orch/tests/oversee_watch_main_push.sh" \
  'reordered-paths|204|failure|paths-reverse|' \
  "added-path|204|failure|paths-added|EVENT main-push-failing owner/repo workflow=skill-tests.yml event=push run=204 jobs=$JOBS cause=FAILED: skills/orch/tests/oversee_watch_main_push.sh" \
  "removed-path|204|failure|paths|EVENT main-push-failing owner/repo workflow=skill-tests.yml event=push run=204 jobs=$JOBS cause=FAILED: skills/orch/tests/oversee_watch_main_push.sh" \
  "jobs-only|204|failure|jobs-only|EVENT main-push-failing owner/repo workflow=skill-tests.yml event=push run=204 jobs=$JOBS cause=run-all.sh: run-deadline suite=oversee_watch started=yes" \
  'jobs-only-new-diagnostic|204|failure|jobs-only-later|' \
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
    changed) names='["Other job"]' ;;
    *) names="$JOBS" ;;
  esac
  jq -cn --argjson names "$names" '{jobs: (($names | map({name: ., conclusion: "failure"})) + [{name: "Green job", conclusion: "success"}, {name: "Skipped job", conclusion: "skipped"}])}' > "$STUB_DIR/main-jobs.$run.json"
  printf 'Job\tSuite\t2026-10-08T08:00:00Z suite=green seconds=1 pass=4 fail=0\nJob\tSuite\t2026-10-08T08:00:00Z %s\nJob\tSuite\t2026-10-08T08:00:00Z suite=later seconds=1 pass=0 fail=1\n' "$CAUSE" > "$STUB_DIR/main-log.$run.txt"
  case "$job_case" in
    duration) printf 'suite=oversee_watch seconds=7 pass=5 fail=1\nsuite=later seconds=9 pass=8 fail=2\n' > "$STUB_DIR/main-log.$run.txt" ;;
    suite-reverse) printf 'suite=later seconds=1 pass=0 fail=1\n%s\n' "$CAUSE" > "$STUB_DIR/main-log.$run.txt" ;;
    added) printf 'suite=added seconds=1 pass=0 fail=1\n' >> "$STUB_DIR/main-log.$run.txt" ;;
    # run-all.sh always reports the stopped suite in its summary. Its raw
    # bound and started flag can vary while the failed-suite set stays fixed.
    deadline-started | deadline-unstarted | timeout | timeout-later | raw | raw-later)
      case "$job_case" in
        deadline-started) diagnostic='run-all.sh: run-deadline suite=oversee_watch started=yes' ;;
        deadline-unstarted) diagnostic='run-all.sh: run-deadline suite=oversee_watch started=no' ;;
        timeout) diagnostic='run-all.sh: suite-timeout suite=oversee_watch seconds=1' ;;
        timeout-later) diagnostic='run-all.sh: suite-timeout suite=oversee_watch seconds=7' ;;
        # The shared assertion library's fail() reports the failed check.
        raw) diagnostic='FAIL  first check' ;;
        raw-later) diagnostic='FAIL  another check' ;;
      esac
      printf '%s\n%s\nsuite=later seconds=1 pass=0 fail=1\n' "$diagnostic" "$CAUSE" > "$STUB_DIR/main-log.$run.txt"
      ;;
    paths | paths-added)
      printf 'FAILED: skills/orch/tests/oversee_watch_main_push.sh\nFAILED: skills/orch/tests/oversee_watch.sh\n' > "$STUB_DIR/main-log.$run.txt"
      [[ "$job_case" != paths-added ]] || printf 'FAILED: skills/orch/tests/oversee_watch_refresh.sh\n' >> "$STUB_DIR/main-log.$run.txt"
      ;;
    paths-reverse) printf 'FAILED: skills/orch/tests/oversee_watch.sh\nFAILED: skills/orch/tests/oversee_watch_main_push.sh\n' > "$STUB_DIR/main-log.$run.txt" ;;
    jobs-only) printf 'run-all.sh: run-deadline suite=oversee_watch started=yes\n' > "$STUB_DIR/main-log.$run.txt" ;;
    jobs-only-later) printf 'FAIL  another check\n' > "$STUB_DIR/main-log.$run.txt" ;;
  esac
  main_watch
  assert_eq "rc=$MAIN_RC events=$MAIN_EVENTS" "rc=0 events=$expected" "$name" "$STUB_DIR/err"
done

# An unread dependency must preserve the standing failure. Its restoration
# must stay quiet rather than creating another incident. An unread run list
# fails the push and the nightly read alike, one notice each.
for read_kind in runs jobs log; do
  case "$read_kind" in
    runs) unread="$STUB_DIR/main-push.owner_repo.err" notices=2 ;;
    jobs) unread="$STUB_DIR/main-jobs.202.err" notices=1 ;;
    log) unread="$STUB_DIR/main-log.202.err" notices=1 ;;
  esac
  printf 'HTTP 502: bad gateway\n' > "$unread"
  main_watch
  assert_eq "rc=$MAIN_RC notices=$MAIN_NOTICES events=$MAIN_EVENTS" "rc=0 notices=$notices events=" "unread $read_kind" "$STUB_DIR/err"
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
  "first-unread|unread|1|EVENT main-push-failing owner/repo workflow=skill-tests.yml event=push run=202 jobs=$JOBS cause=unread" \
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

# gh's rewritten 404 alone does not prove that the workflow is absent. The
# push and the nightly read each print their own notice. An unread workflow
# list also leaves ci.yml, absent here, unproved: two more notices.
for row in \
  "absent|{\"workflows\":[]}|0|$EVENT" \
  'present-unread|{"workflows":[]} {"workflows":[{"path":".github/workflows/skill-tests.yml"}]}|2|' \
  'workflow-list-unread|denied|4|' \
  'workflow-list-invalid|{}|4|'; do
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

# A run list the pass read from the same repository proves access, so ci.yml's
# rewritten 404 there proves it absent without a workflow-list read. The
# control drops that proof and reads the list once per event.
for code in current mutant; do
  TARGET="$REPO_ROOT/skills/orch/scripts/oversee-watch"
  if [[ "$code" == mutant ]]; then
    TARGET="$(mutant_scripts main-witness-$code/orch oversee-watch)/oversee-watch" || exit 1
    ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/main-witness-$code/github"
    mutate_file "$TARGET" '      if { [[ "$read_repos" == *" $repo "* ]] &&' '      if { false &&'
  fi
  new_case "main_push_witness_$code"
  printf '[{"databaseId":201,"headBranch":"main","event":"push","status":"completed","conclusion":"success"}]\n' >"$STUB_DIR/main-push.owner_repo.json"
  WATCH_BIN="$TARGET" main_watch
  LISTS="$(grep -c '^api --paginate repos/owner/repo/actions/workflows' "$STUB_DIR/gh.calls" || true)"
  expected='rc=0 notices=0 lists=0'
  [[ "$code" == current ]] || expected='rc=0 notices=0 lists=2'
  assert_eq "rc=$MAIN_RC notices=$MAIN_NOTICES lists=$LISTS" "$expected" "absent ci.yml beside a read skill-tests.yml: $code" "$STUB_DIR/err"
done

# These producers are the workflow's FAILED: loop and GitHub's timed_out,
# cancelled and startup_failure conclusions. A red push or night must produce
# a failing event through the real watch. The scheduled run alone runs the
# platform roster, so a night cut short (a job past its timeout-minutes ends
# cancelled) or never started reports too, its cancelled jobs named; a
# cancelled push does not.
for row in \
  'timed-out|push|timed_out|timed_out|suite=oversee_watch seconds=1 pass=4 fail=1|yes' \
  'failed-suite-line|push|failure|failure|FAILED: skills/orch/tests/oversee_watch_main_push.sh|yes' \
  'night-cancelled|schedule|cancelled|cancelled|suite=oversee_watch seconds=1 pass=4 fail=1|yes' \
  'night-startup-failure|schedule|startup_failure||suite=oversee_watch seconds=1 pass=4 fail=1|yes' \
  'push-cancelled|push|cancelled|cancelled|suite=oversee_watch seconds=1 pass=4 fail=1|no'; do
  IFS='|' read -r name event conclusion job_conclusion cause reports <<<"$row"
  new_case "$name"
  jq -cn --arg event "$event" --arg conclusion "$conclusion" '[{databaseId: 202, headBranch: "main", event: $event, status: "completed", conclusion: $conclusion}]' > "$STUB_DIR/main-push.owner_repo.json"
  jq -cn --arg conclusion "$job_conclusion" '{jobs: (if $conclusion == "" then [] else [{name: "Skill suites job", conclusion: $conclusion}, {name: "Skipped job", conclusion: "skipped"}] end)}' > "$STUB_DIR/main-jobs.202.json"
  printf 'Job\tSuite\t2026-10-08T08:00:00Z %s\n' "$cause" > "$STUB_DIR/main-log.202.txt"
  main_watch
  expected=''
  if [[ "$reports" == yes ]]; then
    jobs='["Skill suites job"]'
    [[ -n "$job_conclusion" ]] || jobs='[]'
    expected="EVENT main-push-failing owner/repo workflow=skill-tests.yml event=$event run=202 jobs=$jobs cause=$cause"
  fi
  assert_eq "rc=$MAIN_RC events=$MAIN_EVENTS" "rc=0 events=$expected" "$name" "$STUB_DIR/err"
done

# A red nightly run is an incident of its own: a green push after it neither
# hides nor clears it, and a red push beside it reports apart. A read that
# lists no scheduled run leaves the standing night in place, so the same red
# night after it raises nothing new.
NIGHT_JOBS='["Skill suites shard (orch-oversee, macos-latest)"]'
NIGHT_EVENT="EVENT main-push-failing owner/repo workflow=skill-tests.yml event=schedule run=302 jobs=$NIGHT_JOBS cause=$CAUSE"
night_history() { # SCHEDULE_CONCLUSION (none: no scheduled run) PUSH_CONCLUSION
  jq -cn --arg night "$1" --arg push "$2" '[
    {databaseId: 303, headBranch: "main", event: "push", status: "completed", conclusion: $push},
    {databaseId: 302, headBranch: "main", event: "schedule", status: "completed", conclusion: $night}
  ] | map(select(.event == "push" or $night != "none"))' > "$STUB_DIR/main-push.owner_repo.json"
  jq -cn --argjson names "$NIGHT_JOBS" '{jobs: ($names | map({name: ., conclusion: "failure"}))}' > "$STUB_DIR/main-jobs.302.json"
  jq -cn --argjson names "$JOBS" '{jobs: ($names | map({name: ., conclusion: "failure"}))}' > "$STUB_DIR/main-jobs.303.json"
  printf '%s\n' "$CAUSE" > "$STUB_DIR/main-log.302.txt"
  printf '%s\n' "$CAUSE" > "$STUB_DIR/main-log.303.txt"
}
new_case main_schedule
for row in \
  "night-red|failure|success|$NIGHT_EVENT" \
  'night-standing-under-green-push|failure|success|' \
  "push-red-beside-night|failure|failure|EVENT main-push-failing owner/repo workflow=skill-tests.yml event=push run=303 jobs=$JOBS cause=$CAUSE" \
  'night-green|success|failure|' \
  "night-red-after-recovery|failure|failure|$NIGHT_EVENT" \
  'night-unlisted|none|failure|' \
  'night-standing-after-unlisted|failure|failure|'; do
  IFS='|' read -r name night push expected <<<"$row"
  night_history "$night" "$push"
  main_watch
  assert_eq "rc=$MAIN_RC events=$MAIN_EVENTS" "rc=0 events=$expected" "$name" "$STUB_DIR/err"
done
# A watch reading the push alone misses the red night the row above reports.
NIGHT_MUTANT="$(mutant_scripts main-night/orch oversee-watch)/oversee-watch" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/main-night/github"
mutate_file "$NIGHT_MUTANT" '      for event in push schedule; do' '      for event in push; do'
new_case main_schedule_control
night_history failure success
WATCH_BIN="$NIGHT_MUTANT" main_watch
assert_eq "rc=$MAIN_RC events=$MAIN_EVENTS" 'rc=0 events=' 'control: a push-only watch misses the red night' "$STUB_DIR/err"
# A watch that clears the night on an empty list reports the same red night
# again.
UNLISTED_MUTANT="$(mutant_scripts main-unlisted/orch oversee-watch)/oversee-watch" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/main-unlisted/github"
mutate_file "$UNLISTED_MUTANT" '    [[ "$run" != none ]] || continue' '    :'
new_case main_schedule_unlisted_control
for night in failure none failure; do
  night_history "$night" success
  WATCH_BIN="$UNLISTED_MUTANT" main_watch
done
assert_eq "rc=$MAIN_RC events=$MAIN_EVENTS" "rc=0 events=$NIGHT_EVENT" 'control: clearing on an empty list reports the standing night again' "$STUB_DIR/err"

# Admit raw diagnostics in a private watch. The unchanged-suite oracle must
# reject its duplicate event while the mutant still completes the check.
MUTANT="$(mutant_scripts main-control/orch oversee-watch)/oversee-watch" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/main-control/github"
mutate_file "$MUTANT" '          else empty end) | unique' '          else . end) | unique'
new_case main_push_control
printf '[{"databaseId":202,"headBranch":"main","event":"push","status":"completed","conclusion":"failure"}]\n' > "$STUB_DIR/main-push.owner_repo.json"
jq -cn --argjson names "$JOBS" '{jobs: ($names | map({name: ., conclusion: "failure"}))}' > "$STUB_DIR/main-jobs.202.json"
printf 'run-all.sh: run-deadline suite=oversee_watch started=yes\n%s\n' "$CAUSE" > "$STUB_DIR/main-log.202.txt"
WATCH_BIN="$MUTANT" main_watch
assert_eq "rc=$MAIN_RC events=$MAIN_EVENTS" "rc=0 events=EVENT main-push-failing owner/repo workflow=skill-tests.yml event=push run=202 jobs=$JOBS cause=run-all.sh: run-deadline suite=oversee_watch started=yes" 'control reaches the check and preserves its first raw cause' "$STUB_DIR/err"
printf 'run-all.sh: run-deadline suite=oversee_watch started=no\n%s\n' "$CAUSE" > "$STUB_DIR/main-log.202.txt"
WATCH_BIN="$MUTANT" main_watch
CONTROL_RC=0
( assert_eq "rc=$MAIN_RC events=$MAIN_EVENTS" 'rc=0 events=' 'unchanged-suite event oracle'; [[ "$FAIL" -eq 0 ]] ) > "$STUB_DIR/control.out" || CONTROL_RC=$?
assert_eq "watch=$MAIN_RC oracle=$CONTROL_RC" 'watch=0 oracle=1' 'control rejects raw diagnostics in failure identity' "$STUB_DIR/err"

# The harness-ci template's ci.yml runs on main only on a push and on its
# nightly schedule. A red one is its own incident beside skill-tests.yml's:
# a newer pull-request or dispatch run on main never hides it, and either
# workflow's recovery leaves the other's incident standing.
new_case main_ci_nightly
NIGHTLY_JOBS='["macOS lane"]'
NIGHTLY_CAUSE='FAILED: tests/macos.sh'
NIGHTLY="EVENT main-push-failing owner/repo workflow=ci.yml event=schedule run=302 jobs=$NIGHTLY_JOBS cause=$NIGHTLY_CAUSE"
jq -cn --argjson names "$NIGHTLY_JOBS" '{jobs: ($names | map({name: ., conclusion: "failure"}))}' > "$STUB_DIR/main-jobs.302.json"
printf '%s\n' "$NIGHTLY_CAUSE" > "$STUB_DIR/main-log.302.txt"
jq -cn --argjson names "$JOBS" '{jobs: ($names | map({name: ., conclusion: "failure"}))}' > "$STUB_DIR/main-jobs.202.json"
printf '%s\n' "$CAUSE" > "$STUB_DIR/main-log.202.txt"
for row in \
  "nightly-red|failure|success|$NIGHTLY" \
  'nightly-still-red|failure|success|' \
  "both-red|failure|failure|$EVENT" \
  'nightly-recovered|success|failure|' \
  "nightly-red-again|failure|failure|$NIGHTLY" \
  'both-green|success|success|'; do
  IFS='|' read -r name nightly push expected <<<"$row"
  nightly_run=302 push_run=202
  [[ "$nightly" == failure ]] || nightly_run=303
  [[ "$push" == failure ]] || push_run=203
  jq -cn --argjson id "$nightly_run" --arg conclusion "$nightly" '[
    {databaseId: 399, headBranch: "main", event: "workflow_dispatch", status: "completed", conclusion: "success"},
    {databaseId: 398, headBranch: "main", event: "pull_request", status: "completed", conclusion: "success"},
    {databaseId: $id, headBranch: "main", event: "schedule", status: "completed", conclusion: $conclusion}
  ]' > "$STUB_DIR/main-ci.owner_repo.json"
  jq -cn --argjson id "$push_run" --arg conclusion "$push" \
    '[{databaseId: $id, headBranch: "main", event: "push", status: "completed", conclusion: $conclusion}]' \
    > "$STUB_DIR/main-push.owner_repo.json"
  main_watch
  assert_eq "rc=$MAIN_RC events=$MAIN_EVENTS" "rc=0 events=$expected" "$name" "$STUB_DIR/err"
done

# Control: one incident row per repository and event, shared by both
# workflows, fails the row above while the watch still completes.
nightly_case() { # NAME WATCH — `first=<ci.yml events> second=<events>` over two passes
  local first
  new_case "main_ci_control_$1"
  jq -cn --argjson names "$NIGHTLY_JOBS" '{jobs: ($names | map({name: ., conclusion: "failure"}))}' > "$STUB_DIR/main-jobs.302.json"
  printf '%s\n' "$NIGHTLY_CAUSE" > "$STUB_DIR/main-log.302.txt"
  jq -cn --argjson names "$JOBS" '{jobs: ($names | map({name: ., conclusion: "failure"}))}' > "$STUB_DIR/main-jobs.202.json"
  printf '%s\n' "$CAUSE" > "$STUB_DIR/main-log.202.txt"
  printf '[{"databaseId":399,"headBranch":"main","event":"workflow_dispatch","status":"completed","conclusion":"success"},{"databaseId":302,"headBranch":"main","event":"schedule","status":"completed","conclusion":"failure"}]\n' > "$STUB_DIR/main-ci.owner_repo.json"
  printf '[{"databaseId":202,"headBranch":"main","event":"push","status":"completed","conclusion":"failure"}]\n' > "$STUB_DIR/main-push.owner_repo.json"
  WATCH_BIN="$2" main_watch
  first="$(grep -c 'workflow=ci.yml' <<<"$MAIN_EVENTS" || true)"
  WATCH_BIN="$2" main_watch
  printf 'rc=%s first=%s second=%s' "$MAIN_RC" "$first" "$(grep -c . <<<"$MAIN_EVENTS" || true)"
}
# NAME|NEEDLE|REPLACEMENT|ANSWER: the current watch reports the red nightly
# run once; each control completes and answers otherwise.
for row in \
  'current|-|-|rc=0 first=1 second=0' \
  'one-row|    row_key="$repo:$workflow"|    row_key="$repo"|rc=0 first=1 second=2'; do
  IFS='|' read -r name old new expected <<<"$row"
  TARGET="$REPO_ROOT/skills/orch/scripts/oversee-watch"
  if [[ "$name" != current ]]; then
    TARGET="$(mutant_scripts "main-ci-$name/orch" oversee-watch)/oversee-watch" || exit 1
    ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/main-ci-$name/github"
    mutate_file "$TARGET" "$old" "$new"
  fi
  assert_eq "$(nightly_case "$name" "$TARGET")" "$expected" "nightly control $name" "$STUB_DIR/err"
done

# A standing skill-tests.yml incident recorded under the repository alone,
# before the workflow key, keeps its record and raises no second event.
new_case main_push_legacy_row
printf '[{"databaseId":202,"headBranch":"main","event":"push","status":"completed","conclusion":"failure"}]\n' > "$STUB_DIR/main-push.owner_repo.json"
jq -cn --argjson names "$JOBS" '{jobs: ($names | map({name: ., conclusion: "failure"}))}' > "$STUB_DIR/main-jobs.202.json"
printf '%s\n' "$CAUSE" > "$STUB_DIR/main-log.202.txt"
main_watch
assert_eq "$MAIN_EVENTS" "$EVENT" 'legacy-row seed' "$STUB_DIR/err"
legacy_files="$(grep -rlF $'main-push-failing\towner/repo:skill-tests.yml\t' "$STATE_DIR")" || legacy_files=""
[[ -n "$legacy_files" ]] || { echo "no main-push-failing row under $STATE_DIR" >&2; exit 1; }
while IFS= read -r file; do
  sed -i.bak $'s|^main-push-failing\towner/repo:skill-tests.yml\t|main-push-failing\towner/repo\t|' "$file"
  rm -f -- "$file.bak"
done <<<"$legacy_files"
[[ -z "$(grep -rlF 'owner/repo:skill-tests.yml' "$STATE_DIR")" ]] || { echo "the legacy rewrite left the keyed row" >&2; exit 1; }
main_watch
assert_eq "rc=$MAIN_RC events=$MAIN_EVENTS" 'rc=0 events=' 'a legacy row stays quiet' "$STUB_DIR/err"

# ORCH_MAIN_WORKFLOWS adds a repository's own nightly workflow to the two
# every repository reads. Its red scheduled run reports as main-push-failing
# naming it; an entry for another repository, or none, reads the defaults
# alone, with the same run-list calls, and an entry for a repository the
# watch does not read reports that it reads nothing.
NAMED_JOBS='["iOS build"]'
NAMED_CAUSE='FAILED: eas build ios'
NAMED="EVENT main-push-failing owner/repo workflow=eas-build.yml event=schedule run=402 jobs=$NAMED_JOBS cause=$NAMED_CAUSE"
named_case() { # NAME WATCH [VAR=VALUE] — `rc=<status> events=<main-push-failing lines> absent=<main-workflow-absent lines>`
  new_case "main_named_$1"
  printf '[{"databaseId":201,"headBranch":"main","event":"push","status":"completed","conclusion":"success"}]\n' > "$STUB_DIR/main-push.owner_repo.json"
  printf '[{"databaseId":402,"headBranch":"main","event":"schedule","status":"completed","conclusion":"failure"}]\n' > "$STUB_DIR/main-wf.eas-build.yml.owner_repo.json"
  jq -cn --argjson names "$NAMED_JOBS" '{jobs: ($names | map({name: ., conclusion: "failure"}))}' > "$STUB_DIR/main-jobs.402.json"
  printf '%s\n' "$NAMED_CAUSE" > "$STUB_DIR/main-log.402.txt"
  WATCH_BIN="$2" main_watch ${3:+"$3"}
  awk '/^run list / { sub(/ --json .*/, ""); print }' "$STUB_DIR/gh.calls" > "$STUB_DIR/lists"
  printf 'rc=%s events=%s absent=%s' "$MAIN_RC" "$MAIN_EVENTS" "$MAIN_ABSENT"
}
KEN4217="$(mutant_scripts main-named-ken4217/orch oversee-watch)/oversee-watch" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/main-named-ken4217/github"
mutate_file "$KEN4217" '    for workflow in $workflows; do' '    for workflow in $MAIN_WORKFLOWS; do'
WATCH="$REPO_ROOT/skills/orch/scripts/oversee-watch"
named_case unset "$WATCH" >/dev/null
DEFAULT_LISTS="$(cat "$STUB_DIR/lists")"
# NAME|WATCH|SETTING|ANSWER
for row in \
  "named|$WATCH|ORCH_MAIN_WORKFLOWS=owner/repo:eas-build.yml|rc=0 events=$NAMED absent=" \
  "named-in-owner-casing|$WATCH|ORCH_MAIN_WORKFLOWS=Owner/Repo:eas-build.yml other/repo:x.yml|rc=0 events=$NAMED absent=EVENT main-workflow-absent other/repo workflow=x.yml cause=unwatched" \
  "other-repo|$WATCH|ORCH_MAIN_WORKFLOWS=other/repo:eas-build.yml|rc=0 events= absent=EVENT main-workflow-absent other/repo workflow=eas-build.yml cause=unwatched" \
  "control-ken4217-reader|$KEN4217|ORCH_MAIN_WORKFLOWS=owner/repo:eas-build.yml|rc=0 events= absent="; do
  IFS='|' read -r name target setting expected <<<"$row"
  assert_eq "$(named_case "$name" "$target" "$setting")" "$expected" "named workflow $name" "$STUB_DIR/err"
done
assert_eq "$(cat "$TMP_ROOT/cases/main_named_other-repo/lists")" "$DEFAULT_LISTS" 'an entry for another repository reads the defaults alone' "$STUB_DIR/err"

# A named workflow no run list reads is reported once per cause, across
# both event reads and later passes: cause=branch where the default branch
# lacks it, again after a read of it succeeded; cause=unwatched where its
# repository is not one the watch reads, a misspelled one included, and
# cause=branch once that repository joins. An entry the setting drops loses
# its record, so its return reports again. The control drops the record
# that holds each cause to one report.
absent_case() { # NAME WATCH — `<rc>:<causes>` per pass
  local row setting connected present out=""
  new_case "main_absent_$1"
  printf '[{"databaseId":201,"headBranch":"main","event":"push","status":"completed","conclusion":"success"}]\n' > "$STUB_DIR/main-push.owner_repo.json"
  # SETTING|CONNECTED|PRESENT (whether owner/repo holds nightly.yml)
  for row in \
    'owner/repo:nightly.yml||no' \
    'owner/repo:nightly.yml||no' \
    'owner/repo:nightly.yml||yes' \
    'owner/repo:nightly.yml||no' \
    'Owner/Rep0:nightly.yml||no' \
    'Owner/Rep0:nightly.yml||no' \
    'owner/repo:nightly.yml||no' \
    'other/repo:nightly.yml||no' \
    'other/repo:nightly.yml|other/repo|no'; do
    IFS='|' read -r setting connected present <<<"$row"
    rm -f -- "$STUB_DIR/main-wf.nightly.yml.owner_repo.json"
    [[ "$present" == no ]] || printf '[]\n' > "$STUB_DIR/main-wf.nightly.yml.owner_repo.json"
    WATCH_BIN="$2" main_watch "ORCH_MAIN_WORKFLOWS=$setting" "ORCH_CONNECTED_REPOS=$connected"
    out+="$MAIN_RC:$(sed -n 's/^EVENT main-workflow-absent [^ ]* workflow=nightly.yml cause=//p' <<<"$MAIN_ABSENT" | paste -sd, -) "
  done
  printf '%s' "$out"
}
ABSENT_MUTANT="$(mutant_scripts main-absent-once/orch oversee-watch)/oversee-watch" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/main-absent-once/github"
mutate_file "$ABSENT_MUTANT" $'  [[ "$LANE_ROW" != "$3" ]] || return 0\n' $'  :\n'
assert_eq "$(absent_case current "$WATCH")" '0:branch 0: 0: 0:branch 0:unwatched 0: 0:branch 0:unwatched 0:branch ' \
  'a named workflow no run list reads reports once per cause' "$STUB_DIR/err"
assert_eq "$(absent_case control "$ABSENT_MUTANT")" '0:branch,branch 0:branch,branch 0: 0:branch,branch 0:unwatched 0:unwatched 0:branch,branch 0:unwatched 0:branch,branch ' \
  'control: no record reports every read' "$STUB_DIR/err"

# An entry of another shape refuses the watch before any read.
new_case main_named_invalid
main_watch 'ORCH_MAIN_WORKFLOWS=owner/repo:eas-build.yml owner/repo'
assert_eq "rc=$MAIN_RC refusal=$(grep -cxF 'oversee-watch: main-workflows-invalid entry=owner/repo' "$STUB_DIR/err" || true) lists=$(grep -c '^run list' "$STUB_DIR/gh.calls" || true)" \
  'rc=2 refusal=1 lists=0' 'an entry with no workflow file is refused' "$STUB_DIR/err"

# Budget records are consumed by oversee-events.md. Keep all distinct suite
# and final-job annotations from every job of a completed run.
budget_run() { # ID CREATED STATUS [EVENT BRANCH]
  jq -cn --argjson id "$1" --arg at "$2" --arg status "$3" --arg event "${4:-push}" --arg branch "${5:-main}" \
    '{id:$id,created_at:$at,status:$status,head_branch:$branch,event:$event}'
}
budget_fixture() {
  new_case "$1"
  printf '{"status":"completed"}\n' >"$STUB_DIR/budget-status.202.json"
  budget_run 202 2026-10-18T00:00:00Z completed "${2:-push}" "${3:-main}" | jq -sc . >"$STUB_DIR/budget-history.json"
  printf '[{"jobs":[{"check_run_url":"https://api.github.com/repos/owner/repo/check-runs/902"},{"check_run_url":"https://api.github.com/repos/owner/repo/check-runs/903"}]}]\n' >"$STUB_DIR/budget-jobs.202.json"
  jq -cn --arg suite "$BUDGET_SUITE" --arg job "$BUDGET_JOB" \
    '[[{annotation_level:"warning",message:$suite},{annotation_level:"warning",message:$job},
       {annotation_level:"notice",message:$suite},{annotation_level:"warning",message:"another warning"}]]' >"$STUB_DIR/budget-annotations.902.json"
  jq -cn --arg suite "$BUDGET_SUITE" '[[{annotation_level:"warning",message:$suite}]]' >"$STUB_DIR/budget-annotations.903.json"
}
budget_wide_fixture() {
  budget_fixture "$1"
  jq -cn '[range(202;302) | {id:.,created_at:"2026-10-18T00:00:00Z",status:"queued",head_branch:"main",event:"push",
    head_commit:{message:("m"*4096)}}]' >"$STUB_DIR/budget-history.json"
}
budget_watch() {
  main_watch
  BUDGET_EVENTS="$(awk '/^EVENT main-push-budget /' "$STUB_DIR/out")"
  BUDGET_CALLS="$(awk '/^api .*actions\/workflows\/skill-tests.yml\/runs/ || /^api .*actions\/runs/ || /^api .*check-runs/ { n++ } END { print n+0 }' "$STUB_DIR/gh.calls")"
  BUDGET_ROW=''
  [[ ! -f "$STATE_DIR/owner_repo__none" ]] || \
    BUDGET_ROW="$(awk -F '\t' '$1=="main-push-budget" {print $3}' "$STATE_DIR/owner_repo__none")"
}
BUDGET_SUITE='run-all-budget run=202 attempt=2 os=Linux shard=orch-state suite=slow seconds=301 bound=900 review=300 margin-percent=125'
BUDGET_JOB='run-all-budget run=202 attempt=2 os=Linux shard=orch-state suite=job seconds=333 bound=900 review=300 margin-percent=125'
BUDGET_WARNINGS="$(jq -cn --arg suite "$BUDGET_SUITE" --arg job "$BUDGET_JOB" '[$suite,$job] | sort')"
BUDGET_EVENT="EVENT main-push-budget owner/repo workflow=skill-tests.yml run=202 warnings=$BUDGET_WARNINGS"

# Skill Tests suite jobs run on merge groups, schedules and manual runs.
# Main pushes remain compatible. Queue branches encode their target base.
BUDGET_BROAD="$(mutant_scripts budget-broad/orch oversee-watch)/oversee-watch"
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/budget-broad/github"
mutate_file "$BUDGET_BROAD" 'budget_producer and .created_at >= $state.watermark' 'true and .created_at >= $state.watermark'
while IFS='|' read -r label event branch selected; do
  budget_fixture "budget_$label" "$event" "$branch"
  budget_watch
  expected='rc=0 calls=1 events='
  [[ "$selected" != yes ]] || expected="rc=0 calls=4 events=$BUDGET_EVENT"
  assert_eq "rc=$MAIN_RC calls=$BUDGET_CALLS events=$BUDGET_EVENTS" "$expected" "$label: selects the producer event and base" "$STUB_DIR/err"
  budget_watch
  assert_eq "rc=$MAIN_RC calls=$BUDGET_CALLS events=$BUDGET_EVENTS" 'rc=0 calls=1 events=' "$label: repeat stays quiet" "$STUB_DIR/err"
  if [[ "$selected" == no ]]; then
    budget_fixture "budget_control_$label" "$event" "$branch"
    WATCH_BIN="$BUDGET_BROAD" budget_watch
    CONTROL_RC=0
    ( FAIL=0
      assert_eq "rc=$MAIN_RC calls=$BUDGET_CALLS events=$BUDGET_EVENTS" "$expected" "$label oracle"
      [[ "$FAIL" -eq 0 ]]
    ) >"$STUB_DIR/control.out" || CONTROL_RC=$?
    assert_eq "$CONTROL_RC" 1 "$label: a broadened selector fails the refusal oracle" "$STUB_DIR/control.out"
  fi
done <<'ROWS'
push-main|push|main|yes
merge-main|merge_group|gh-readonly-queue/main/pr-5421-c7012cfbf29daef1a5bc63c0ccf179f23a859bc1|yes
schedule-main|schedule|main|yes
manual-main|workflow_dispatch|main|yes
manual-feature|workflow_dispatch|feature|no
merge-release|merge_group|gh-readonly-queue/release/pr-7-abc|no
merge-main-other|merge_group|gh-readonly-queue/main-other/pr-7-abc|no
pull-request|pull_request|main|no
ROWS

budget_fixture budget_once
budget_watch
assert_eq "rc=$MAIN_RC calls=$BUDGET_CALLS events=$BUDGET_EVENTS" "rc=0 calls=4 events=$BUDGET_EVENT" 'all producer evidence emits one maintenance record' "$STUB_DIR/err"
assert_eq "$BUDGET_ROW" '{"watermark":"2026-10-18T00:00:00Z","seen":[202],"pending":[]}' 'saved state is raw compact JSON'
budget_watch
assert_eq "rc=$MAIN_RC calls=$BUDGET_CALLS events=$BUDGET_EVENTS" 'rc=0 calls=1 events=' 'consumed run makes no evidence reads' "$STUB_DIR/err"
SAVED_BUDGET_ROW="$BUDGET_ROW"
for ((pass=0; pass<10; pass++)); do
  budget_watch
  assert_eq "rc=$MAIN_RC calls=$BUDGET_CALLS events=$BUDGET_EVENTS state=$BUDGET_ROW" \
    "rc=0 calls=1 events= state=$SAVED_BUDGET_ROW" 'ten passes preserve saved bytes' "$STUB_DIR/err"
done

budget_wide_fixture budget_wide
for row in 'queued|1|100|' "complete|5|99|$BUDGET_EVENT" 'repeat|2|99|'; do
  IFS='|' read -r phase calls pending expected <<<"$row"
  if [[ "$phase" == complete ]]; then
    jq -c 'map(if .id==202 then .status="completed" else . end)' "$STUB_DIR/budget-history.json" >"$STUB_DIR/complete.json"
    mv "$STUB_DIR/complete.json" "$STUB_DIR/budget-history.json"
  fi
  budget_watch
  assert_eq "rc=$MAIN_RC calls=$BUDGET_CALLS pending=$(jq '.pending | length' <<<"$BUDGET_ROW") events=$BUDGET_EVENTS" \
    "rc=0 calls=$calls pending=$pending events=$expected" "$phase: large metadata stays out of command arguments and pending status reads" "$STUB_DIR/err"
done

# Both jobs and annotations can span pages. A failed final annotation page
# leaves all evidence unread until the next successful pass.
budget_fixture budget_pages
jq -c '[{jobs:[.[0].jobs[0]]},{jobs:[.[0].jobs[1]]}]' "$STUB_DIR/budget-jobs.202.json" >"$STUB_DIR/pages.json"
mv "$STUB_DIR/pages.json" "$STUB_DIR/budget-jobs.202.json"
jq -c '[.[0],.[0]]' "$STUB_DIR/budget-annotations.903.json" >"$STUB_DIR/pages.json"
mv "$STUB_DIR/pages.json" "$STUB_DIR/budget-annotations.903.json"
printf 'HTTP 502: unavailable\n' >"$STUB_DIR/budget-annotations.903.2.err"
budget_watch
assert_eq "rc=$MAIN_RC calls=$BUDGET_CALLS events=$BUDGET_EVENTS" 'rc=0 calls=6 events=' 'partial annotation pagination stays unread' "$STUB_DIR/err"
rm -- "${STUB_DIR:?}/budget-annotations.903.2.err"
budget_watch
assert_eq "rc=$MAIN_RC calls=$BUDGET_CALLS events=$BUDGET_EVENTS" "rc=0 calls=6 events=$BUDGET_EVENT" 'complete pagination retries all annotation pages' "$STUB_DIR/err"

# Old retained pages cause no per-run lookup after the creation watermark.
budget_fixture budget_retained
jq -cn '[range(1;501) | {id:.,created_at:"2026-10-17T00:00:00Z",status:"completed",head_branch:"main",event:"push"}]' >"$STUB_DIR/old.json"
jq -cs '.[0]+.[1]' "$STUB_DIR/budget-history.json" "$STUB_DIR/old.json" >"$STUB_DIR/combined.json"
mv "$STUB_DIR/combined.json" "$STUB_DIR/budget-history.json"
mkdir -p "$STATE_DIR"
printf 'main-push-budget\towner/repo:skill-tests.yml\t{"watermark":"2026-10-17T23:00:00Z","seen":[201],"pending":[]}\n' >"$STATE_DIR/owner_repo__none"
budget_watch
assert_eq "rc=$MAIN_RC calls=$BUDGET_CALLS events=$BUDGET_EVENTS" "rc=0 calls=4 events=$BUDGET_EVENT" 'retained history takes four API calls' "$STUB_DIR/err"
assert_eq "$(awk '/^api .*actions\/runs\// && !/\/202\// {print}' "$STUB_DIR/gh.calls")" '' 'retained runs cause no point lookup'

budget_fixture budget_absent
printf 'HTTP 404: workflow skill-tests.yml not found on the default branch (https://api.github.com/repos/owner/repo/actions/workflows/skill-tests.yml)\n' >"$STUB_DIR/main-push.owner_repo.err"
printf 'HTTP 404: Not Found\n' >"$STUB_DIR/budget-history.err"
budget_watch
assert_eq "rc=$MAIN_RC calls=$BUDGET_CALLS notices=$MAIN_NOTICES events=$BUDGET_EVENTS" \
  'rc=0 calls=0 notices=0 events=' 'a proven absent workflow has no budget read' "$STUB_DIR/err"

# An older active run remains pending after newer runs move the watermark.
budget_fixture budget_late
budget_run 201 2026-10-17T00:00:00Z in_progress >"$STUB_DIR/active.json"
jq -cs '.[0]+[.[1]]' "$STUB_DIR/budget-history.json" "$STUB_DIR/active.json" >"$STUB_DIR/both.json"
mv "$STUB_DIR/both.json" "$STUB_DIR/budget-history.json"
budget_watch
assert_eq "$(jq -c .pending <<<"$BUDGET_ROW")" '[201]' 'active run remains pending'
printf '{"status":"completed"}\n' >"$STUB_DIR/budget-status.201.json"
printf 'HTTP 502: a listed status needs no point read\n' >"$STUB_DIR/budget-status.201.err"
jq -c 'map(if .id==201 then .status="completed" else . end)' "$STUB_DIR/budget-history.json" >"$STUB_DIR/complete.json"
mv "$STUB_DIR/complete.json" "$STUB_DIR/budget-history.json"
cp "$STUB_DIR/budget-jobs.202.json" "$STUB_DIR/budget-jobs.201.json"
budget_watch
assert_eq "rc=$MAIN_RC calls=$BUDGET_CALLS pending=$(jq -c .pending <<<"$BUDGET_ROW") events=$BUDGET_EVENTS" \
  "rc=0 calls=4 pending=[] events=${BUDGET_EVENT/run=202 warnings=/run=201 warnings=}" 'late completion reuses its listed status after the watermark advances' "$STUB_DIR/err"

for dependency in history status jobs annotations; do
  budget_fixture "budget_retry_$dependency"
  case "$dependency" in
    history) unread="$STUB_DIR/budget-history.err" ;;
    status)
      jq -cn '[{id:403,created_at:"2026-10-18T02:00:00Z",status:"completed",head_branch:"feature",event:"push"}] +
        [range(303;402) | {id:.,created_at:"2026-10-18T01:00:00Z",status:"completed",head_branch:"feature",event:"push"}] +
        [{id:202,created_at:"2026-10-18T00:00:00Z",status:"completed",head_branch:"main",event:"push"}]' >"$STUB_DIR/budget-history.json"
      mkdir -p "$STATE_DIR"
      printf 'main-push-budget\towner/repo:skill-tests.yml\t{"watermark":"2026-10-18T02:00:00Z","seen":[403],"pending":[202]}\n' >"$STATE_DIR/owner_repo__none"
      unread="$STUB_DIR/budget-status.202.err" ;;
    jobs) unread="$STUB_DIR/budget-jobs.202.err" ;;
    annotations) unread="$STUB_DIR/budget-annotations.903.err" ;;
  esac
  printf 'HTTP 502: unavailable\n' >"$unread"
  budget_watch
  assert_eq "rc=$MAIN_RC events=$BUDGET_EVENTS" 'rc=0 events=' "$dependency read keeps partial evidence unread" "$STUB_DIR/err"
  [[ "$dependency" != jobs ]] || printf '[]\n' >"$STUB_DIR/budget-history.json"
  rm -- "${unread:?}"
  budget_watch
  assert_eq "rc=$MAIN_RC events=$BUDGET_EVENTS" "rc=0 events=$BUDGET_EVENT" "$dependency read retries unread evidence" "$STUB_DIR/err"
  budget_watch
  assert_eq "rc=$MAIN_RC events=$BUDGET_EVENTS" 'rc=0 events=' "$dependency recovery emits once" "$STUB_DIR/err"
done

# Same-second arrivals need every boundary id, including a later page.
budget_fixture budget_boundary
mkdir -p "$STATE_DIR"
printf 'main-push-budget\towner/repo:skill-tests.yml\t{"watermark":"2026-10-18T00:00:00Z","seen":[202],"pending":[]}\n' >"$STATE_DIR/owner_repo__none"
jq -cn '[range(202;307) | {id:.,created_at:"2026-10-18T00:00:00Z",status:"completed",head_branch:"feature",event:"push"}] +
  [{id:100,created_at:"2026-10-17T00:00:00Z",status:"completed",head_branch:"main",event:"push"}]' >"$STUB_DIR/budget-history.json"
budget_watch
assert_eq "rc=$MAIN_RC calls=$BUDGET_CALLS events=$BUDGET_EVENTS boundary=$(jq '.seen | length' <<<"$BUDGET_ROW")" \
  'rc=0 calls=2 events= boundary=105' 'same-second arrivals span two history pages' "$STUB_DIR/err"
budget_watch
assert_eq "rc=$MAIN_RC calls=$BUDGET_CALLS events=$BUDGET_EVENTS pending=$(jq -c .pending <<<"$BUDGET_ROW")" \
  'rc=0 calls=2 events= pending=[]' 'all boundary ids stay consumed' "$STUB_DIR/err"

# Failed later discovery pages do not advance any reader state.
printf 'HTTP 502: unavailable\n' >"$STUB_DIR/budget-history.2.err"
BEFORE_UNREAD="$BUDGET_ROW"
budget_watch
assert_eq "rc=$MAIN_RC state=$BUDGET_ROW events=$BUDGET_EVENTS" "rc=0 state=$BEFORE_UNREAD events=" 'a later unread history page preserves the watermark' "$STUB_DIR/err"

for defect in dedup history quoting payload; do
  BUDGET_MUTANT="$(mutant_scripts "budget-$defect/orch" oversee-watch)/oversee-watch"
  ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/budget-$defect/github"
  case "$defect" in
    dedup) mutate_file "$BUDGET_MUTANT" '$state.seen | index($id) | not' '$state.seen | index($id) | true' ;;
    history) mutate_file "$BUDGET_MUTANT" 'all(.[]; .created_at >= $state.watermark)' 'all(.[]; true)' ;;
    quoting) mutate_file "$BUDGET_MUTANT" '"$row_key" "$budget_state" >/dev/null' '"$row_key" "$(jq -cn --arg raw "$budget_state" '\''$raw'\'')" >/dev/null' ;;
    payload) mutate_file "$BUDGET_MUTANT" 'map({id,status})' 'map(.)' ;;
  esac
  if [[ "$defect" == payload ]]; then budget_wide_fixture "budget_control_$defect"
  else budget_fixture "budget_control_$defect"; fi
  if [[ "$defect" == history ]]; then
    jq -cn '[range(1;501) | {id:.,created_at:"2026-10-17T00:00:00Z",status:"completed",head_branch:"main",event:"push"}]' >"$STUB_DIR/old.json"
    jq -cs '.[0]+.[1]' "$STUB_DIR/budget-history.json" "$STUB_DIR/old.json" >"$STUB_DIR/combined.json"
    mv "$STUB_DIR/combined.json" "$STUB_DIR/budget-history.json"
    mkdir -p "$STATE_DIR"
    printf 'main-push-budget\towner/repo:skill-tests.yml\t{"watermark":"2026-10-17T23:00:00Z","seen":[201],"pending":[]}\n' >"$STATE_DIR/owner_repo__none"
  fi
  if [[ "$defect" == quoting ]]; then budget_watch
  else WATCH_BIN="$BUDGET_MUTANT" budget_watch; fi
  ORIGINAL_BUDGET_ROW="$BUDGET_ROW"
  WATCH_BIN="$BUDGET_MUTANT" budget_watch
  CONTROL_RC=0
  ( FAIL=0
    assert_eq "rc=$MAIN_RC calls=$BUDGET_CALLS events=$BUDGET_EVENTS state=$BUDGET_ROW notices=$MAIN_NOTICES" \
      "rc=0 calls=1 events= state=$ORIGINAL_BUDGET_ROW notices=0" "$defect oracle"
    [[ "$FAIL" -eq 0 ]]
  ) >"$STUB_DIR/control.out" || CONTROL_RC=$?
  assert_eq "$CONTROL_RC" 1 "$defect control rejects repeated work or escaped state" "$STUB_DIR/err"
  case "$defect" in
    dedup) assert_eq "rc=$MAIN_RC calls=$BUDGET_CALLS events=$BUDGET_EVENTS" "rc=0 calls=4 events=$BUDGET_EVENT" 'dedup control repeats the same run event' "$STUB_DIR/err" ;;
    history) assert_eq "rc=$MAIN_RC calls=$BUDGET_CALLS" 'rc=0 calls=6' 'history control reads retained pages' "$STUB_DIR/err" ;;
    quoting) assert_eq "rc=$MAIN_RC notices=$MAIN_NOTICES type=$(jq -r type <<<"$BUDGET_ROW")" 'rc=0 notices=0 type=string' 'the byte oracle rejects a JSON-escaping layer without an unread notice' "$STUB_DIR/err" ;;
    payload) assert_eq "rc=$MAIN_RC calls=$BUDGET_CALLS events=$BUDGET_EVENTS" 'rc=2 calls=1 events=' 'payload control reaches the argument limit after its history read' "$STUB_DIR/err" ;;
  esac
done

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
