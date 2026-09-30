#!/usr/bin/env bash
# The real watch reads GitHub's completed-run JSON and failed-step logs through
# the shared fixture. Its persistent row spans separate watch invocations.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
# shellcheck source=lib/oversee-watch-harness.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/oversee-watch-harness.sh"

EVENT='EVENT refresh-failing owner/repo runs=2 last=202 since=2026-09-30T07:00:00Z report=initial cause=refresh-error=read value=class'
REPEAT="${EVENT/report=initial/report=repeat}"

new_case refresh_timeline
printf 'Refresh\tRefresh consumer\t2026-09-30T08:00:00Z refresh-error=read value=class\n' > "$STUB_DIR/refresh-log.202.txt"
# NAME|NEWER CONCLUSION|OLDER CONCLUSION|PASS CAP|HEARTBEATS|EXPECTED EVENT. GitHub lists the
# newest completed run first. An absent row models fewer than two runs.
for row in \
  'no-runs|absent|absent|1|1|' \
  'one-failure|failure|absent|1|1|' \
  "two-failures|failure|failure|2|0|$EVENT" \
  'unchanged-pair|failure|failure|1|1|' \
  "mark-repeat|failure|failure|1|0|$REPEAT" \
  'newest-success|success|failure|1|1|' \
  'one-failure-after-success|failure|success|1|1|' \
  "new-pair-after-success|failure|failure|1|0|$EVENT" \
  'cancelled-run|cancelled|failure|1|1|' \
  "new-pair-after-cancel|failure|failure|1|0|$EVENT"; do
  IFS='|' read -r name newer older loops heartbeats want <<<"$row"
  jq -cn --arg newer "$newer" --arg older "$older" '
    [{databaseId: 202, conclusion: $newer, createdAt: "2026-09-30T08:00:00Z"},
     {databaseId: 201, conclusion: $older, createdAt: "2026-09-30T07:00:00Z"}]
    | map(select(.conclusion != "absent"))' > "$STUB_DIR/refresh.owner_repo.json"
  refresh_watch --max-loops "$loops"
  LISTS="$(grep -c '^run list --repo owner/repo --workflow kendex-refresh.yml --status completed --limit 2 --json databaseId,conclusion,createdAt$' "$STUB_DIR/gh.calls" || true)"
  assert_eq "rc=$REFRESH_RC lists=$LISTS heartbeats=$REFRESH_HEARTBEATS events=$REFRESH_EVENTS" "rc=0 lists=1 heartbeats=$heartbeats events=$want" "$name" "$STUB_DIR/err"
done

# Keep the pair from the fixture above, but change its last diagnostic. Tabs
# in gh's prefix are removed, and the last matching diagnostic wins.
printf '[{"databaseId":202,"conclusion":"failure","createdAt":"2026-09-30T08:00:00Z"},{"databaseId":201,"conclusion":"failure","createdAt":"2026-09-30T07:00:00Z"}]\n' > "$STUB_DIR/refresh.owner_repo.json"
printf 'Refresh\tRefresh consumer\t2026-09-30T08:00:00Z refresh-error=old\nRefresh\tRefresh consumer\t2026-09-30T08:00:01Z kendex-hook-commit-guards: failed | check=changelog\nother output\n' > "$STUB_DIR/refresh-log.202.txt"
refresh_watch
CHANGED='EVENT refresh-failing owner/repo runs=2 last=202 since=2026-09-30T07:00:00Z report=repeat cause=kendex-hook-commit-guards: failed | check=changelog'
assert_eq "rc=$REFRESH_RC events=$REFRESH_EVENTS" "rc=0 events=$CHANGED" "a changed cause is news before the repeat interval" "$STUB_DIR/err"
refresh_watch
assert_eq "rc=$REFRESH_RC events=$REFRESH_EVENTS" 'rc=0 events=' "a cause containing a pipe remains quiet on the next pass" "$STUB_DIR/err"

# Each row is a GitHub read outcome. A failing dependency emits one notice
# and neither ends the watch nor invents a successful refresh.
for row in \
  'repository-unread|runs|HTTP 404: Not Found (https://api.github.com/repos/owner/repo)|1|' \
  'service-unread|runs|HTTP 502: bad gateway|1|' \
  'invalid-json|json|not-json|1|' \
  'invalid-shape|json|{}|1|' \
  'log-unread|log|HTTP 410: logs expired|1|unread' \
  'no-diagnostic|text|unrelated failed-step output|0|unread'; do
  IFS='|' read -r name kind input notices cause <<<"$row"
  new_case "$name"
  printf '[{"databaseId":202,"conclusion":"failure","createdAt":"2026-09-30T08:00:00Z"},{"databaseId":201,"conclusion":"failure","createdAt":"2026-09-30T07:00:00Z"}]\n' > "$STUB_DIR/refresh.owner_repo.json"
  case "$kind" in
    runs) printf '%s\n' "$input" > "$STUB_DIR/refresh.owner_repo.err" ;;
    json) printf '%s\n' "$input" > "$STUB_DIR/refresh.owner_repo.json" ;;
    log) printf '%s\n' "$input" > "$STUB_DIR/refresh-log.202.err" ;;
    text) printf '%s\n' "$input" > "$STUB_DIR/refresh-log.202.txt" ;;
  esac
  refresh_watch
  NOTICES="$(grep -c '^oversee-watch: refresh-unread ' "$STUB_DIR/err" || true)"
  want=''
  [[ -z "$cause" ]] || want="${EVENT%cause=*}cause=$cause"
  assert_eq "rc=$REFRESH_RC notices=$NOTICES events=$REFRESH_EVENTS" "rc=0 notices=$notices events=$want" "$name" "$STUB_DIR/err"
done

# gh rewrites access failures and missing workflows to the same diagnostic.
# Seed a standing pair, then prove only a successful complete absence read
# clears it. The workflow-present row includes a later API page.
for row in \
  "missing-workflow|{\"workflows\":[]}|0|$EVENT" \
  'workflow-access-unread|denied|1|' \
  'workflow-present|{"workflows":[]} {"workflows":[{"path":".github/workflows/kendex-refresh.yml"}]}|1|' \
  'workflow-list-invalid|{}|1|'; do
  IFS='|' read -r name workflows notices restored <<<"$row"
  new_case "$name"
  printf '[{"databaseId":202,"conclusion":"failure","createdAt":"2026-09-30T08:00:00Z"},{"databaseId":201,"conclusion":"failure","createdAt":"2026-09-30T07:00:00Z"}]\n' > "$STUB_DIR/refresh.owner_repo.json"
  printf 'refresh-error=read value=class\n' > "$STUB_DIR/refresh-log.202.txt"
  refresh_watch
  assert_eq "$REFRESH_EVENTS" "$EVENT" "$name starts with a standing pair" "$STUB_DIR/err"
  printf 'HTTP 404: workflow kendex-refresh.yml not found on the default branch (https://api.github.com/repos/owner/repo/actions/workflows/kendex-refresh.yml)\n' > "$STUB_DIR/refresh.owner_repo.err"
  if [[ "$workflows" == denied ]]; then
    printf 'HTTP 404: Not Found (https://api.github.com/repos/owner/repo/actions/workflows)\n' > "$STUB_DIR/workflows.owner_repo.err"
  else
    printf '%s\n' "$workflows" > "$STUB_DIR/workflows.owner_repo.json"
  fi
  refresh_watch
  assert_eq "rc=$REFRESH_RC lists=$REFRESH_LISTS notices=$REFRESH_NOTICES events=$REFRESH_EVENTS" "rc=0 lists=1 notices=$notices events=" "$name" "$STUB_DIR/err"
  rm -- "$STUB_DIR/refresh.owner_repo.err"
  refresh_watch
  assert_eq "rc=$REFRESH_RC events=$REFRESH_EVENTS" "rc=0 events=$restored" "$name restores only a confirmed absent pair" "$STUB_DIR/err"
done

new_case refresh_repositories
printf '[{"databaseId":202,"conclusion":"failure","createdAt":"2026-09-30T08:00:00Z"},{"databaseId":201,"conclusion":"failure","createdAt":"2026-09-30T07:00:00Z"}]\n' > "$STUB_DIR/refresh.other_repo.json"
printf 'refresh-error=read value=class\n' > "$STUB_DIR/refresh-log.202.txt"
printf 'HTTP 502: bad gateway\n' > "$STUB_DIR/refresh.owner_repo.err"
refresh_watch --repo owner/repo --repo other/repo
assert_eq "rc=$REFRESH_RC lists=$REFRESH_LISTS log=$REFRESH_LOG_REQUESTS events=$REFRESH_EVENTS" "rc=0 lists=2 log=run view 202 --repo other/repo --log-failed events=${EVENT/owner\/repo/other/repo}" "one unread repository does not hide another repository's failures" "$STUB_DIR/err"

# A failed list read leaves the row intact and does not advance its repeat
# clock. Restore the read and the next good pass is still quiet.
printf 'HTTP 502: bad gateway\n' > "$STUB_DIR/refresh.other_repo.err"
refresh_watch --repo owner/repo --repo other/repo
rm -- "$STUB_DIR/refresh.other_repo.err"
refresh_watch --repo owner/repo --repo other/repo
assert_eq "rc=$REFRESH_RC events=$REFRESH_EVENTS" 'rc=0 events=' "an unread list does not reset or advance a standing pair" "$STUB_DIR/err"
refresh_watch --repo owner/repo --repo other/repo
assert_eq "rc=$REFRESH_RC events=$REFRESH_EVENTS" "rc=0 events=${REPEAT/owner\/repo/other/repo}" "the standing pair repeats after two good long passes" "$STUB_DIR/err"

# Each private mutant still reads the real completed-run list. The positive
# event oracle rejects an unreachable threshold or an initial event marked repeat.
for mutation in \
  'threshold|if length == 2 and all(.[]; .conclusion == "failure") then|if length == 3 and all(.[]; .conclusion == "failure") then' \
  'initial-marker|      report=initial|      report=repeat'; do
  IFS='|' read -r name old replacement <<<"$mutation"
  MUTANT_WATCH="$(mutant_scripts "refresh-mutant-$name/orch" oversee-watch)/oversee-watch" || exit 1
  ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/refresh-mutant-$name/github"
  mutate_file "$MUTANT_WATCH" "$old" "$replacement"
  new_case "refresh_control_$name"
  printf '[{"databaseId":202,"conclusion":"failure","createdAt":"2026-09-30T08:00:00Z"},{"databaseId":201,"conclusion":"failure","createdAt":"2026-09-30T07:00:00Z"}]\n' > "$STUB_DIR/refresh.owner_repo.json"
  printf 'refresh-error=read value=class\n' > "$STUB_DIR/refresh-log.202.txt"
  WATCH_BIN="$MUTANT_WATCH" refresh_watch
  CONTROL_RC=0
  ( assert_eq "$REFRESH_EVENTS" "$EVENT" 'positive event oracle'; [[ "$FAIL" -eq 0 ]] ) > "$STUB_DIR/control.out" || CONTROL_RC=$?
  assert_eq "watch=$REFRESH_RC oracle=$CONTROL_RC" 'watch=0 oracle=1' "control: the positive event assertion rejects $name" "$STUB_DIR/err"
done

# A failed workflow list must not become a successful absence read.
GUARD_WATCH="$(mutant_scripts refresh-guard/orch oversee-watch)/oversee-watch" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/refresh-guard/github"
mutate_file "$GUARD_WATCH" "          --jq '.workflows[].path' 2>\"\$errf\")\"" "          --jq '.workflows[].path' 2>\"\$errf\" || true)\""
new_case refresh_guard_control
printf '[{"databaseId":202,"conclusion":"failure","createdAt":"2026-09-30T08:00:00Z"},{"databaseId":201,"conclusion":"failure","createdAt":"2026-09-30T07:00:00Z"}]\n' > "$STUB_DIR/refresh.owner_repo.json"
printf 'refresh-error=read value=class\n' > "$STUB_DIR/refresh-log.202.txt"
refresh_watch
printf 'HTTP 404: workflow kendex-refresh.yml not found on the default branch (https://api.github.com/repos/owner/repo/actions/workflows/kendex-refresh.yml)\n' > "$STUB_DIR/refresh.owner_repo.err"
printf 'HTTP 404: Not Found (https://api.github.com/repos/owner/repo/actions/workflows)\n' > "$STUB_DIR/workflows.owner_repo.err"
WATCH_BIN="$GUARD_WATCH" refresh_watch
NOTICES="$REFRESH_NOTICES"
rm -- "$STUB_DIR/refresh.owner_repo.err"
refresh_watch
CONTROL_RC=0
( assert_eq "notices=$NOTICES restored=$REFRESH_EVENTS" 'notices=1 restored=' 'workflow access oracle'; [[ "$FAIL" -eq 0 ]] ) > "$STUB_DIR/control.out" || CONTROL_RC=$?
assert_eq "watch=$REFRESH_RC oracle=$CONTROL_RC" 'watch=0 oracle=1' "control: the access assertion rejects a masked workflow-list failure" "$STUB_DIR/err"

# Reset the event flag after printing the refresh event, leaving its text and
# state intact. The two-failures oracle must reject the delayed wake.
WAKE_WATCH="$(mutant_scripts refresh-wake/orch oversee-watch)/oversee-watch" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/refresh-wake/github"
mutate_file "$WAKE_WATCH" '    rows="$(lane_row_set refresh-failing' '    PASS_EVENT=0; rows="$(lane_row_set refresh-failing'
new_case refresh_wake_control
printf '[{"databaseId":202,"conclusion":"failure","createdAt":"2026-09-30T08:00:00Z"},{"databaseId":201,"conclusion":"failure","createdAt":"2026-09-30T07:00:00Z"}]\n' > "$STUB_DIR/refresh.owner_repo.json"
printf 'refresh-error=read value=class\n' > "$STUB_DIR/refresh-log.202.txt"
WATCH_BIN="$WAKE_WATCH" refresh_watch --max-loops 2
CONTROL_RC=0
( assert_eq "rc=$REFRESH_RC lists=$REFRESH_LISTS heartbeats=$REFRESH_HEARTBEATS events=$REFRESH_EVENTS" "rc=0 lists=1 heartbeats=0 events=$EVENT" 'two-failures oracle'; [[ "$FAIL" -eq 0 ]] ) > "$STUB_DIR/control.out" || CONTROL_RC=$?
assert_eq "watch=$REFRESH_RC oracle=$CONTROL_RC" 'watch=0 oracle=1' "control: the wake assertion rejects a disabled refresh event flag" "$STUB_DIR/err"

# The multi-repository oracle checks the request, not the stub's permissive
# choice of a log file. Omitting --repo must turn that oracle red.
REPO_WATCH="$(mutant_scripts refresh-repo/orch oversee-watch)/oversee-watch" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/refresh-repo/github"
mutate_file "$REPO_WATCH" 'log="$(gh run view "$last" --repo "$repo" --log-failed' 'log="$(gh run view "$last" --log-failed'
new_case refresh_repo_control
printf '[{"databaseId":202,"conclusion":"failure","createdAt":"2026-09-30T08:00:00Z"},{"databaseId":201,"conclusion":"failure","createdAt":"2026-09-30T07:00:00Z"}]\n' > "$STUB_DIR/refresh.other_repo.json"
printf 'refresh-error=read value=class\n' > "$STUB_DIR/refresh-log.202.txt"
printf 'HTTP 502: bad gateway\n' > "$STUB_DIR/refresh.owner_repo.err"
WATCH_BIN="$REPO_WATCH" refresh_watch --repo owner/repo --repo other/repo
CONTROL_RC=0
( assert_eq "rc=$REFRESH_RC lists=$REFRESH_LISTS log=$REFRESH_LOG_REQUESTS events=$REFRESH_EVENTS" "rc=0 lists=2 log=run view 202 --repo other/repo --log-failed events=${EVENT/owner\/repo/other/repo}" 'multi-repository oracle'; [[ "$FAIL" -eq 0 ]] ) > "$STUB_DIR/control.out" || CONTROL_RC=$?
assert_eq "watch=$REFRESH_RC oracle=$CONTROL_RC" 'watch=0 oracle=1' "control: the log assertion rejects an omitted repository" "$STUB_DIR/err"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
