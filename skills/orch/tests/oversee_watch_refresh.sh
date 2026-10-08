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
for run in 200 201 202 203 204 205 206 207 208 209 210 211; do
  printf 'Refresh\tRefresh consumer\t2026-09-30T08:00:00Z refresh-error=read value=class\n' > "$STUB_DIR/refresh-log.$run.txt"
done
# NAME|NEWER RUN|OLDER RUN|PASS CAP|HEARTBEATS|REPORT|STALE NOTICE|UNFILTERED
# HEAD. A run is ID:CONCLUSION[:ATTEMPT], created at hour ID-190, attempt 1
# unless named. GitHub lists the newest completed run first; an absent run
# models fewer than two. A page older than the newest run already read is
# stale, as is an empty page once a run has been read. A re-run keeps its id
# and takes an attempt. A pair that would open an incident is checked against
# the unfiltered list, whose newest completed run is the page's own (page) or a
# later run's id; a blank head means that list is not read. A later head is
# recorded as read and unjudged: an older page is stale, and one reaching it
# is judged.
for row in \
  'no-runs|absent|absent|1|1|||' \
  'one-failure|201:failure|absent|1|1|||' \
  'two-failures|202:failure|201:failure|2|0|initial||page' \
  'unchanged-pair|202:failure|201:failure|1|1|||' \
  'stale-page|201:failure|200:failure|1|1||repo=owner/repo newest=202 read=201|' \
  'empty-page|absent|absent|1|1||repo=owner/repo newest=202 read=none|' \
  'mark-repeat|202:failure|201:failure|1|0|repeat||' \
  'newest-success|203:success|202:failure|1|1|||' \
  'stale-after-success|202:failure|201:failure|1|1||repo=owner/repo newest=203 read=202|' \
  'one-failure-after-success|204:failure|203:success|1|1|||' \
  'new-pair-after-success|205:failure|204:failure|1|0|initial||page' \
  'cancelled-run|206:cancelled|205:failure|1|1|||' \
  'new-pair-after-cancel|208:failure|207:failure|1|0|initial||page' \
  'rerun-success|208:success:2|207:failure|1|1|||' \
  'pre-rerun-page|208:failure|207:failure|1|1||repo=owner/repo newest=208 read=208|' \
  'stale-pair-after-success|210:failure|209:failure|1|1||repo=owner/repo newest=211 read=210|211' \
  'pair-after-rerun|210:failure|209:failure|1|1||repo=owner/repo newest=211 read=210|' \
  'pair-reaches-unjudged|211:failure|210:failure|1|0|initial||page'; do
  IFS='|' read -r name newer older loops heartbeats report stale head <<<"$row"
  jq -cn --arg newer "$newer" --arg older "$older" '
    [$newer, $older] | map(select(. != "absent") | split(":")
      | {databaseId: (.[0] | tonumber), attempt: (.[2] // "1" | tonumber), conclusion: .[1]}
      | . + {createdAt: "2026-09-30T\(.databaseId - 190):00:00Z"})' > "$STUB_DIR/refresh.owner_repo.json"
  rm -f -- "${STUB_DIR:?}/refresh-all.owner_repo.json"
  [[ "$head" == page || -z "$head" ]] \
    || jq -c --argjson id "$head" '[{databaseId: $id, attempt: 1, status: "completed", createdAt: "2026-09-30T\($id - 190):00:00Z"}] + map(. + {status: "completed"})' \
      "$STUB_DIR/refresh.owner_repo.json" > "$STUB_DIR/refresh-all.owner_repo.json"
  want=''
  [[ -z "$report" ]] \
    || want="EVENT refresh-failing owner/repo runs=2 last=${newer%%:*} since=2026-09-30T$(( ${older%%:*} - 190 )):00:00Z report=$report cause=refresh-error=read value=class"
  refresh_watch --max-loops "$loops"
  LISTS="$(grep -c '^run list --repo owner/repo --workflow kendex-refresh.yml --status completed --limit 2 --json databaseId,attempt,conclusion,createdAt$' "$STUB_DIR/gh.calls" || true)"
  assert_eq "rc=$REFRESH_RC lists=$LISTS all=$REFRESH_ALL_LISTS heartbeats=$REFRESH_HEARTBEATS events=$REFRESH_EVENTS stale=$REFRESH_STALE" "rc=0 lists=1 all=$(( ${#head} > 0 )) heartbeats=$heartbeats events=$want stale=$stale" "$name" "$STUB_DIR/err"
done

# Keep the pair from the fixture above, but change its diagnostic. Tabs in
# gh's prefix are removed.
printf 'Refresh\tRefresh consumer\t2026-09-30T20:00:01Z kendex-hook-commit-guards: failed | check=changelog\nother output\n' > "$STUB_DIR/refresh-log.211.txt"
refresh_watch
CHANGED='EVENT refresh-failing owner/repo runs=2 last=211 since=2026-09-30T20:00:00Z report=repeat cause=kendex-hook-commit-guards: failed | check=changelog'
assert_eq "rc=$REFRESH_RC events=$REFRESH_EVENTS" "rc=0 events=$CHANGED" "a changed cause is news before the repeat interval" "$STUB_DIR/err"
refresh_watch
assert_eq "rc=$REFRESH_RC events=$REFRESH_EVENTS" 'rc=0 events=' "a cause containing a pipe remains quiet on the next pass" "$STUB_DIR/err"

# A watch with no run read yet judges the pair against the run list without
# --status. NAME|THAT LIST|REPORT|STALE NOTICE|UNREAD NOTICES. A run is
# ID:STATUS[:ATTEMPT], created at hour ID-194, attempt 1 unless named; a list
# that is not runs is its raw JSON. The pair's newer run is 202 attempt 1.
for row in \
  'unrecorded-confirmed|202:completed 201:completed|initial||0' \
  'unrecorded-running-ahead|203:in_progress 202:completed|initial||0' \
  'unrecorded-newer-completed|204:completed 202:completed||repo=owner/repo newest=204 read=202|0' \
  'unrecorded-attempt|202:completed:2 201:completed||repo=owner/repo newest=202 read=202|0' \
  'unrecorded-pair-absent|||repo=owner/repo newest=none read=202|0' \
  'unrecorded-list-unread|unread|||1' \
  'unrecorded-list-invalid|{}|||1'; do
  IFS='|' read -r name all report stale notices <<<"$row"
  new_case "$name"
  printf '[{"databaseId":202,"attempt":1,"conclusion":"failure","createdAt":"2026-09-30T08:00:00Z"},{"databaseId":201,"attempt":1,"conclusion":"failure","createdAt":"2026-09-30T07:00:00Z"}]\n' > "$STUB_DIR/refresh.owner_repo.json"
  printf 'refresh-error=read value=class\n' > "$STUB_DIR/refresh-log.202.txt"
  case "$all" in
    unread) printf 'HTTP 502: bad gateway\n' > "$STUB_DIR/refresh-all.owner_repo.err" ;;
    '{}') printf '%s\n' "$all" > "$STUB_DIR/refresh-all.owner_repo.json" ;;
    *) jq -cn --arg runs "$all" '
        $runs | split(" ") | map(select(. != "") | split(":")
          | {databaseId: (.[0] | tonumber), status: .[1], attempt: (.[2] // "1" | tonumber)}
          | . + {createdAt: "2026-09-30T\(.databaseId - 194 | "0\(.)" | .[-2:]):00:00Z"})' > "$STUB_DIR/refresh-all.owner_repo.json" ;;
  esac
  want=''
  [[ -z "$report" ]] || want="${EVENT/report=initial/report=$report}"
  refresh_watch
  ALL="$(grep -c '^run list --repo owner/repo --workflow kendex-refresh.yml --limit 20 --json databaseId,attempt,createdAt,status$' "$STUB_DIR/gh.calls" || true)"
  assert_eq "rc=$REFRESH_RC all=$ALL notices=$REFRESH_NOTICES events=$REFRESH_EVENTS stale=$REFRESH_STALE" "rc=0 all=1 notices=$notices events=$want stale=$stale" "$name" "$STUB_DIR/err"
done

# A row the watch wrote before it recorded the newest run, <passes>|<cause>,
# reads as a standing incident: the next pass of the same pair is quiet, and
# the row takes the newest run.
new_case refresh_unrecorded_row
printf '[{"databaseId":202,"attempt":1,"conclusion":"failure","createdAt":"2026-09-30T08:00:00Z"},{"databaseId":201,"attempt":1,"conclusion":"failure","createdAt":"2026-09-30T07:00:00Z"}]\n' > "$STUB_DIR/refresh.owner_repo.json"
printf 'refresh-error=read value=class\n' > "$STUB_DIR/refresh-log.202.txt"
mkdir -p "$STATE_DIR"
printf 'refresh-failing\towner/repo\t0|refresh-error=read value=class\n' > "$STATE_DIR/owner_repo__none"
refresh_watch
ROW="$(awk -F'\t' '$1 == "refresh-failing" { print $3 }' "$STATE_DIR/owner_repo__none")"
assert_eq "rc=$REFRESH_RC all=$REFRESH_ALL_LISTS events=$REFRESH_EVENTS row=$ROW" 'rc=0 all=1 events= row=["2026-09-30T08:00:00Z",202,1]|1|refresh-error=read value=class' "an unrecorded standing row continues its incident" "$STUB_DIR/err"

# Each row is a GitHub read outcome. A failing dependency emits one notice
# and neither ends the watch nor invents a successful refresh.
for row in \
  'repository-unread|runs|HTTP 404: Not Found (https://api.github.com/repos/owner/repo)|1|' \
  'service-unread|runs|HTTP 502: bad gateway|1|' \
  'invalid-json|json|not-json|1|' \
  'invalid-shape|json|{}|1|' \
  'log-unread|log|HTTP 410: logs expired|1|unread' \
  'no-diagnostic|text|unrelated failed-step output|0|unread' \
  'hook-warning|text|R\tS\tT warning: kendex-hook-carrier-missing: hook=a\nR\tS\tT other output|0|kendex-hook-carrier-missing: hook=a' \
  'failed-over-warnings|text|R\tS\tT warning: kendex-hook-carrier-missing a\nR\tS\tT FAIL check=c value=v\nR\tS\tT failed: doc-drift-check: not found\nR\tS\tT kendex-hook-carrier-missing b\nR\tS\tT Error: refresh failed: 1 problem(s)|0|failed: doc-drift-check: not found' \
  'fail-check-over-warnings|text|R\tS\tT kendex-hook-excluded: hook=a\nR\tS\tT ok check=b value=c\nR\tS\tT FAIL check=workflow-edited value=.github/workflows/w.yml\nR\tS\tT   FAIL check=indented value=x\nR\tS\tT Error: refresh failed: 1 problem(s)\nR\tS\tT kendex-hook-excluded: hook=d|0|FAIL check=workflow-edited value=.github/workflows/w.yml' \
  'error-over-warnings|text|R\tS\tT Error: first\nR\tS\tT refresh-error=dirty value=x\nR\tS\tT Error: refresh failed: 1 problem(s)\nR\tS\tT kendex-hook-carrier-missing b|0|Error: refresh failed: 1 problem(s)' \
  'refresh-error-over-warnings|text|R\tS\tT refresh-error=dirty value=x\nR\tS\tT kendex-hook-carrier-missing b|0|refresh-error=dirty value=x'; do
  IFS='|' read -r name kind input notices cause <<<"$row"
  new_case "$name"
  printf '[{"databaseId":202,"attempt":1,"conclusion":"failure","createdAt":"2026-09-30T08:00:00Z"},{"databaseId":201,"attempt":1,"conclusion":"failure","createdAt":"2026-09-30T07:00:00Z"}]\n' > "$STUB_DIR/refresh.owner_repo.json"
  case "$kind" in
    runs) printf '%s\n' "$input" > "$STUB_DIR/refresh.owner_repo.err" ;;
    json) printf '%s\n' "$input" > "$STUB_DIR/refresh.owner_repo.json" ;;
    log) printf '%s\n' "$input" > "$STUB_DIR/refresh-log.202.err" ;;
    text) printf '%b\n' "$input" > "$STUB_DIR/refresh-log.202.txt" ;;
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
  printf '[{"databaseId":202,"attempt":1,"conclusion":"failure","createdAt":"2026-09-30T08:00:00Z"},{"databaseId":201,"attempt":1,"conclusion":"failure","createdAt":"2026-09-30T07:00:00Z"}]\n' > "$STUB_DIR/refresh.owner_repo.json"
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
printf '[{"databaseId":202,"attempt":1,"conclusion":"failure","createdAt":"2026-09-30T08:00:00Z"},{"databaseId":201,"attempt":1,"conclusion":"failure","createdAt":"2026-09-30T07:00:00Z"}]\n' > "$STUB_DIR/refresh.other_repo.json"
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
  printf '[{"databaseId":202,"attempt":1,"conclusion":"failure","createdAt":"2026-09-30T08:00:00Z"},{"databaseId":201,"attempt":1,"conclusion":"failure","createdAt":"2026-09-30T07:00:00Z"}]\n' > "$STUB_DIR/refresh.owner_repo.json"
  printf 'refresh-error=read value=class\n' > "$STUB_DIR/refresh-log.202.txt"
  WATCH_BIN="$MUTANT_WATCH" refresh_watch
  CONTROL_RC=0
  ( assert_eq "$REFRESH_EVENTS" "$EVENT" 'positive event oracle'; [[ "$FAIL" -eq 0 ]] ) > "$STUB_DIR/control.out" || CONTROL_RC=$?
  assert_eq "watch=$REFRESH_RC oracle=$CONTROL_RC" 'watch=0 oracle=1' "control: the positive event assertion rejects $name" "$STUB_DIR/err"
done

# A failed workflow list must not become a successful absence read.
GUARD_WATCH="$(mutant_scripts refresh-guard/orch oversee-watch)/oversee-watch" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/refresh-guard/github"
mutate_file "$GUARD_WATCH" "      --jq '.workflows[].path' 2>\"\$3\")\"" "      --jq '.workflows[].path' 2>\"\$3\" || true)\""
new_case refresh_guard_control
printf '[{"databaseId":202,"attempt":1,"conclusion":"failure","createdAt":"2026-09-30T08:00:00Z"},{"databaseId":201,"attempt":1,"conclusion":"failure","createdAt":"2026-09-30T07:00:00Z"}]\n' > "$STUB_DIR/refresh.owner_repo.json"
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
mutate_file "$WAKE_WATCH" '    rows="$(lane_row_set refresh-failing "$rows" "$repo" "$run|$passes' '    PASS_EVENT=0; rows="$(lane_row_set refresh-failing "$rows" "$repo" "$run|$passes'
new_case refresh_wake_control
printf '[{"databaseId":202,"attempt":1,"conclusion":"failure","createdAt":"2026-09-30T08:00:00Z"},{"databaseId":201,"attempt":1,"conclusion":"failure","createdAt":"2026-09-30T07:00:00Z"}]\n' > "$STUB_DIR/refresh.owner_repo.json"
printf 'refresh-error=read value=class\n' > "$STUB_DIR/refresh-log.202.txt"
WATCH_BIN="$WAKE_WATCH" refresh_watch --max-loops 2
CONTROL_RC=0
( assert_eq "rc=$REFRESH_RC lists=$REFRESH_LISTS heartbeats=$REFRESH_HEARTBEATS events=$REFRESH_EVENTS" "rc=0 lists=1 heartbeats=0 events=$EVENT" 'two-failures oracle'; [[ "$FAIL" -eq 0 ]] ) > "$STUB_DIR/control.out" || CONTROL_RC=$?
assert_eq "watch=$REFRESH_RC oracle=$CONTROL_RC" 'watch=0 oracle=1' "control: the wake assertion rejects a disabled refresh event flag" "$STUB_DIR/err"

# The multi-repository oracle checks the request, not the stub's permissive
# choice of a log file. Omitting --repo must turn that oracle red.
REPO_WATCH="$(mutant_scripts refresh-repo/orch oversee-watch)/oversee-watch" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/refresh-repo/github"
mutate_file "$REPO_WATCH" 'log="$(gh run view "$newest" --repo "$repo" --log-failed' 'log="$(gh run view "$newest" --log-failed'
new_case refresh_repo_control
printf '[{"databaseId":202,"attempt":1,"conclusion":"failure","createdAt":"2026-09-30T08:00:00Z"},{"databaseId":201,"attempt":1,"conclusion":"failure","createdAt":"2026-09-30T07:00:00Z"}]\n' > "$STUB_DIR/refresh.other_repo.json"
printf 'refresh-error=read value=class\n' > "$STUB_DIR/refresh-log.202.txt"
printf 'HTTP 502: bad gateway\n' > "$STUB_DIR/refresh.owner_repo.err"
WATCH_BIN="$REPO_WATCH" refresh_watch --repo owner/repo --repo other/repo
CONTROL_RC=0
( assert_eq "rc=$REFRESH_RC lists=$REFRESH_LISTS log=$REFRESH_LOG_REQUESTS events=$REFRESH_EVENTS" "rc=0 lists=2 log=run view 202 --repo other/repo --log-failed events=${EVENT/owner\/repo/other/repo}" 'multi-repository oracle'; [[ "$FAIL" -eq 0 ]] ) > "$STUB_DIR/control.out" || CONTROL_RC=$?
assert_eq "watch=$REFRESH_RC oracle=$CONTROL_RC" 'watch=0 oracle=1' "control: the log assertion rejects an omitted repository" "$STUB_DIR/err"

# refresh_rule_passes NAME runs one stale-page rule's passes on WATCH_BIN in a
# fresh case and leaves the last pass's outcome in OUTCOME.
refresh_rule_passes() {
  new_case "refresh_rule_$1"
  printf 'refresh-error=read value=class\n' > "$STUB_DIR/refresh-log.202.txt"
  case "$1" in
    record-stale)
      printf '[{"databaseId":203,"attempt":1,"conclusion":"success","createdAt":"2026-09-30T09:00:00Z"},{"databaseId":202,"attempt":1,"conclusion":"failure","createdAt":"2026-09-30T08:00:00Z"}]\n' > "$STUB_DIR/refresh.owner_repo.json"
      refresh_watch
      printf '[{"databaseId":202,"attempt":1,"conclusion":"failure","createdAt":"2026-09-30T08:00:00Z"},{"databaseId":201,"attempt":1,"conclusion":"failure","createdAt":"2026-09-30T07:00:00Z"}]\n' > "$STUB_DIR/refresh.owner_repo.json"
      refresh_watch ;;
    rerun-attempt)
      for newer in success:1 failure:2; do
        printf '[{"databaseId":202,"attempt":%s,"conclusion":"%s","createdAt":"2026-09-30T08:00:00Z"},{"databaseId":201,"attempt":1,"conclusion":"failure","createdAt":"2026-09-30T07:00:00Z"}]\n' "${newer#*:}" "${newer%:*}" > "$STUB_DIR/refresh.owner_repo.json"
        refresh_watch
      done ;;
    rerun-page)
      for newer in failure success failure; do
        printf '[{"databaseId":202,"attempt":1,"conclusion":"%s","createdAt":"2026-09-30T08:00:00Z"},{"databaseId":201,"attempt":1,"conclusion":"failure","createdAt":"2026-09-30T07:00:00Z"}]\n' "$newer" > "$STUB_DIR/refresh.owner_repo.json"
        refresh_watch
      done ;;
    recorded-pair-stale)
      printf '[{"databaseId":203,"attempt":1,"conclusion":"success","createdAt":"2026-09-30T09:00:00Z"},{"databaseId":202,"attempt":1,"conclusion":"failure","createdAt":"2026-09-30T08:00:00Z"}]\n' > "$STUB_DIR/refresh.owner_repo.json"
      refresh_watch
      printf '[{"databaseId":205,"attempt":1,"conclusion":"failure","createdAt":"2026-09-30T11:00:00Z"},{"databaseId":204,"attempt":1,"conclusion":"failure","createdAt":"2026-09-30T10:00:00Z"}]\n' > "$STUB_DIR/refresh.owner_repo.json"
      printf '[{"databaseId":206,"attempt":1,"status":"completed","createdAt":"2026-09-30T12:00:00Z"},{"databaseId":205,"attempt":1,"status":"completed","createdAt":"2026-09-30T11:00:00Z"}]\n' > "$STUB_DIR/refresh-all.owner_repo.json"
      refresh_watch ;;
    unrecorded-stale)
      printf '[{"databaseId":202,"attempt":1,"conclusion":"failure","createdAt":"2026-09-30T08:00:00Z"},{"databaseId":201,"attempt":1,"conclusion":"failure","createdAt":"2026-09-30T07:00:00Z"}]\n' > "$STUB_DIR/refresh.owner_repo.json"
      printf '[{"databaseId":204,"attempt":1,"status":"completed","createdAt":"2026-09-30T10:00:00Z"},{"databaseId":202,"attempt":1,"status":"completed","createdAt":"2026-09-30T08:00:00Z"}]\n' > "$STUB_DIR/refresh-all.owner_repo.json"
      refresh_watch ;;
    unfiltered-record | unjudged-record)
      printf '[{"databaseId":202,"attempt":1,"conclusion":"failure","createdAt":"2026-09-30T08:00:00Z"},{"databaseId":201,"attempt":1,"conclusion":"failure","createdAt":"2026-09-30T07:00:00Z"}]\n' > "$STUB_DIR/refresh.owner_repo.json"
      printf '[{"databaseId":203,"attempt":1,"status":"completed","createdAt":"2026-09-30T09:00:00Z"},{"databaseId":202,"attempt":1,"status":"completed","createdAt":"2026-09-30T08:00:00Z"}]\n' > "$STUB_DIR/refresh-all.owner_repo.json"
      refresh_watch
      rm -- "${STUB_DIR:?}/refresh-all.owner_repo.json"
      refresh_watch
      if [[ "$1" == unjudged-record ]]; then
        printf 'refresh-error=read value=class\n' > "$STUB_DIR/refresh-log.203.txt"
        printf '[{"databaseId":203,"attempt":1,"conclusion":"failure","createdAt":"2026-09-30T09:00:00Z"},{"databaseId":202,"attempt":1,"conclusion":"failure","createdAt":"2026-09-30T08:00:00Z"}]\n' > "$STUB_DIR/refresh.owner_repo.json"
        refresh_watch
      fi ;;
    unfiltered-older-head)
      printf 'refresh-error=read value=class\n' > "$STUB_DIR/refresh-log.201.txt"
      printf '[{"databaseId":201,"attempt":1,"status":"completed","createdAt":"2026-09-30T07:00:00Z"},{"databaseId":200,"attempt":1,"status":"completed","createdAt":"2026-09-30T06:00:00Z"}]\n' > "$STUB_DIR/refresh-all.owner_repo.json"
      printf '[{"databaseId":202,"attempt":1,"conclusion":"failure","createdAt":"2026-09-30T08:00:00Z"},{"databaseId":201,"attempt":1,"conclusion":"failure","createdAt":"2026-09-30T07:00:00Z"}]\n' > "$STUB_DIR/refresh.owner_repo.json"
      refresh_watch
      printf '[{"databaseId":201,"attempt":1,"conclusion":"failure","createdAt":"2026-09-30T07:00:00Z"},{"databaseId":200,"attempt":1,"conclusion":"failure","createdAt":"2026-09-30T06:00:00Z"}]\n' > "$STUB_DIR/refresh.owner_repo.json"
      refresh_watch ;;
    unrecorded-row)
      printf '[{"databaseId":202,"attempt":1,"conclusion":"failure","createdAt":"2026-09-30T08:00:00Z"},{"databaseId":201,"attempt":1,"conclusion":"failure","createdAt":"2026-09-30T07:00:00Z"}]\n' > "$STUB_DIR/refresh.owner_repo.json"
      mkdir -p "$STATE_DIR"
      printf 'refresh-failing\towner/repo\t0|refresh-error=read value=class\n' > "$STATE_DIR/owner_repo__none"
      refresh_watch ;;
    *) echo "refresh_rule_passes: rule=unknown value=[$1]" >&2; exit 1 ;;
  esac
  OUTCOME="rc=$REFRESH_RC events=$REFRESH_EVENTS stale=$REFRESH_STALE"
}

# One control per stale-page rule: the real watch meets the oracle and a
# private mutant that keeps the rule's text but drops its effect does not.
# NAME|MATCHED TEXT|MUTANT TEXT|ORACLE
for row in \
  'record-stale|else "older" end) as $order|else "newer" end) as $order|rc=0 events= stale=repo=owner/repo newest=203 read=202' \
  "rerun-attempt|def run: [.createdAt, .databaseId, .attempt];|def run: [.createdAt, .databaseId, .attempt * 0];|rc=0 events=$EVENT stale=" \
  'rerun-page|-n "$standing" ]]|-n never ]]|rc=0 events= stale=' \
  'recorded-pair-stale| -z "$standing" ]]; then| -z "$standing" && -z never ]]; then|rc=0 events= stale=repo=owner/repo newest=206 read=205' \
  'unrecorded-stale|!= same ]]; then|!= same && -z never ]]; then|rc=0 events= stale=repo=owner/repo newest=204 read=202' \
  'unfiltered-record|lane_row_set refresh-failing "$rows" "$repo" "${recent#|lane_row_set refresh-failing "$rows" "$repo/never" "${recent#|rc=0 events= stale=repo=owner/repo newest=203 read=202' \
  "unjudged-record|order=unjudged|order=same|rc=0 events=${EVENT/last=202 since=2026-09-30T07/last=203 since=2026-09-30T08} stale=" \
  'unfiltered-older-head|[run, $run]|[run, run]|rc=0 events= stale=repo=owner/repo newest=202 read=201' \
  'unrecorded-row|      standing="$prior"|      standing=""|rc=0 events= stale='; do
  IFS='|' read -r name old replacement oracle <<<"$row"
  refresh_rule_passes "$name"
  assert_eq "$OUTCOME" "$oracle" "rule $name" "$STUB_DIR/err"
  MUTANT_WATCH="$(mutant_scripts "refresh-rule-$name/orch" oversee-watch)/oversee-watch" || exit 1
  ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/refresh-rule-$name/github"
  mutate_file "$MUTANT_WATCH" "$old" "$replacement"
  WATCH_BIN="$MUTANT_WATCH" refresh_rule_passes "$name"
  CONTROL_RC=0
  ( assert_eq "$OUTCOME" "$oracle" "rule $name oracle"; [[ "$FAIL" -eq 0 ]] ) > "$STUB_DIR/control.out" || CONTROL_RC=$?
  assert_eq "watch=$REFRESH_RC oracle=$CONTROL_RC" 'watch=0 oracle=1' "control: the $name oracle rejects a mutant without the rule" "$STUB_DIR/err"
done

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
