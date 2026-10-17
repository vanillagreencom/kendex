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
# hides nor clears it, and a red push beside it reports apart.
NIGHT_JOBS='["Skill suites shard (orch-oversee, macos-latest)"]'
NIGHT_EVENT="EVENT main-push-failing owner/repo workflow=skill-tests.yml event=schedule run=302 jobs=$NIGHT_JOBS cause=$CAUSE"
night_history() { # SCHEDULE_CONCLUSION PUSH_CONCLUSION
  jq -cn --arg night "$1" --arg push "$2" '[
    {databaseId: 303, headBranch: "main", event: "push", status: "completed", conclusion: $push},
    {databaseId: 302, headBranch: "main", event: "schedule", status: "completed", conclusion: $night}
  ]' > "$STUB_DIR/main-push.owner_repo.json"
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
  "night-red-after-recovery|failure|failure|$NIGHT_EVENT"; do
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

# The removed budget reader must make no workflow-history or full-log read.
# A private current-watch mutation makes the forbidden history request.
for code in current mutant; do
  TARGET="$(mutant_scripts "main-push-cut-$code/orch" oversee-watch)/oversee-watch" || exit 1
  ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/main-push-cut-$code/github"
  if [[ "$code" == mutant ]]; then
    mutate_file "$TARGET" $'        IFS=\'|\' read -r run conclusion <<<"$runs"\n' \
      $'        gh api --paginate "repos/$repo/actions/workflows/skill-tests.yml/runs?per_page=100" --slurp > /dev/null 2>"$errf" || :\n        IFS=\'|\' read -r run conclusion <<<"$runs"\n'
  fi
  new_case "main_push_cut_$code"
  printf '[{"databaseId":202,"headBranch":"main","event":"push","status":"completed","conclusion":"success"}]\n' >"$STUB_DIR/main-push.owner_repo.json"
  WATCH_BIN="$TARGET" main_watch
  READS="$(awk '/^api .*actions\/workflows\/skill-tests.yml\/runs/ || /^run view .* --log$/ {n++} END {print n+0}' "$STUB_DIR/gh.calls")"
  if [[ "$code" == current ]]; then
    assert_eq "rc=$MAIN_RC reads=$READS events=$MAIN_EVENTS" 'rc=0 reads=0 events=' 'green main judgment makes no budget reads' "$STUB_DIR/err"
  else
    CONTROL_RC=0
    ( assert_eq "rc=$MAIN_RC reads=$READS events=$MAIN_EVENTS" 'rc=0 reads=0 events=' 'cut budget-read oracle'; [[ "$FAIL" -eq 0 ]] ) >"$STUB_DIR/control.out" || CONTROL_RC=$?
    assert_eq "watch=$MAIN_RC reads=$READS oracle=$CONTROL_RC" 'watch=0 reads=2 oracle=1' 'restored history read fails the budget-read oracle' "$STUB_DIR/err"
  fi
done

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
  'one-row|      row_key="$repo:$workflow"|      row_key="$repo"|rc=0 first=1 second=2'; do
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

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
