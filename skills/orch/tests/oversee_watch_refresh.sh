#!/usr/bin/env bash
# The real watch reads GitHub's completed-run JSON and failed-step logs through
# the shared fixture. Its persistent row spans separate watch invocations.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
# shellcheck source=lib/oversee-watch-harness.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/oversee-watch-harness.sh"

EVENT='EVENT refresh-failing owner/repo runs=2 last=202 since=2026-09-30T07:00:00Z cause=refresh-error=read value=class'

new_case refresh_timeline
printf 'Refresh\tRefresh consumer\t2026-09-30T08:00:00Z refresh-error=read value=class\n' > "$STUB_DIR/refresh-log.202.txt"
# NAME|NEWER CONCLUSION|OLDER CONCLUSION|EXPECTED EVENT. GitHub lists the
# newest completed run first. An absent row models fewer than two runs.
for row in \
  'no-runs|absent|absent|' \
  'one-failure|failure|absent|' \
  "two-failures|failure|failure|$EVENT" \
  'unchanged-pair|failure|failure|' \
  "mark-repeat|failure|failure|$EVENT" \
  'newest-success|success|failure|' \
  'one-failure-after-success|failure|success|' \
  "new-pair-after-success|failure|failure|$EVENT" \
  'cancelled-run|cancelled|failure|' \
  "new-pair-after-cancel|failure|failure|$EVENT"; do
  IFS='|' read -r name newer older want <<<"$row"
  jq -cn --arg newer "$newer" --arg older "$older" '
    [{databaseId: 202, conclusion: $newer, createdAt: "2026-09-30T08:00:00Z"},
     {databaseId: 201, conclusion: $older, createdAt: "2026-09-30T07:00:00Z"}]
    | map(select(.conclusion != "absent"))' > "$STUB_DIR/refresh.owner_repo.json"
  : > "$STUB_DIR/gh.calls"
  refresh_watch
  LISTS="$(grep -c '^run list --repo owner/repo --workflow kendex-refresh.yml --status completed --limit 2 --json databaseId,conclusion,createdAt$' "$STUB_DIR/gh.calls" || true)"
  assert_eq "rc=$REFRESH_RC lists=$LISTS events=$REFRESH_EVENTS" "rc=0 lists=1 events=$want" "$name" "$STUB_DIR/err"
done

# Keep the pair from the fixture above, but change its last diagnostic. Tabs
# in gh's prefix are removed, and the last matching diagnostic wins.
printf '[{"databaseId":202,"conclusion":"failure","createdAt":"2026-09-30T08:00:00Z"},{"databaseId":201,"conclusion":"failure","createdAt":"2026-09-30T07:00:00Z"}]\n' > "$STUB_DIR/refresh.owner_repo.json"
printf 'Refresh\tRefresh consumer\t2026-09-30T08:00:00Z refresh-error=old\nRefresh\tRefresh consumer\t2026-09-30T08:00:01Z kendex-hook-commit-guards: failed | check=changelog\nother output\n' > "$STUB_DIR/refresh-log.202.txt"
refresh_watch
CHANGED='EVENT refresh-failing owner/repo runs=2 last=202 since=2026-09-30T07:00:00Z cause=kendex-hook-commit-guards: failed | check=changelog'
assert_eq "rc=$REFRESH_RC events=$REFRESH_EVENTS" "rc=0 events=$CHANGED" "a changed cause is news before the repeat interval" "$STUB_DIR/err"
refresh_watch
assert_eq "rc=$REFRESH_RC events=$REFRESH_EVENTS" 'rc=0 events=' "a cause containing a pipe remains quiet on the next pass" "$STUB_DIR/err"

# Each row is a GitHub read outcome. A failing dependency emits one notice
# and neither ends the watch nor invents a successful refresh.
for row in \
  'missing-workflow|runs|HTTP 404: workflow kendex-refresh.yml not found on the default branch (https://api.github.com/repos/owner/repo/actions/workflows/kendex-refresh.yml)|0|' \
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

new_case refresh_repositories
printf '[{"databaseId":202,"conclusion":"failure","createdAt":"2026-09-30T08:00:00Z"},{"databaseId":201,"conclusion":"failure","createdAt":"2026-09-30T07:00:00Z"}]\n' > "$STUB_DIR/refresh.other_repo.json"
printf 'refresh-error=read value=class\n' > "$STUB_DIR/refresh-log.202.txt"
printf 'HTTP 502: bad gateway\n' > "$STUB_DIR/refresh.owner_repo.err"
refresh_watch --repo owner/repo --repo other/repo
LISTS="$(grep -c '^run list ' "$STUB_DIR/gh.calls" || true)"
assert_eq "rc=$REFRESH_RC lists=$LISTS events=$REFRESH_EVENTS" "rc=0 lists=2 events=${EVENT/owner\/repo/other\/repo}" "one unread repository does not hide another repository's failures" "$STUB_DIR/err"

# A failed list read leaves the row intact and does not advance its repeat
# clock. Restore the read and the next good pass is still quiet.
printf 'HTTP 502: bad gateway\n' > "$STUB_DIR/refresh.other_repo.err"
refresh_watch --repo owner/repo --repo other/repo
rm -- "$STUB_DIR/refresh.other_repo.err"
refresh_watch --repo owner/repo --repo other/repo
assert_eq "rc=$REFRESH_RC events=$REFRESH_EVENTS" 'rc=0 events=' "an unread list does not reset or advance a standing pair" "$STUB_DIR/err"
refresh_watch --repo owner/repo --repo other/repo
assert_eq "rc=$REFRESH_RC events=$REFRESH_EVENTS" "rc=0 events=${EVENT/owner\/repo/other\/repo}" "the standing pair repeats after two good long passes" "$STUB_DIR/err"

# Must-fail control: requiring three runs from a two-run read makes the same
# positive event assertion red. The private mutant still reads the real list.
MUTANT_WATCH="$(mutant_scripts refresh-mutant/orch oversee-watch)/oversee-watch" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/refresh-mutant/github"
mutate_file "$MUTANT_WATCH" 'if length == 2 and all(.[]; .conclusion == "failure") then' 'if length == 3 and all(.[]; .conclusion == "failure") then'
new_case refresh_control
printf '[{"databaseId":202,"conclusion":"failure","createdAt":"2026-09-30T08:00:00Z"},{"databaseId":201,"conclusion":"failure","createdAt":"2026-09-30T07:00:00Z"}]\n' > "$STUB_DIR/refresh.owner_repo.json"
printf 'refresh-error=read value=class\n' > "$STUB_DIR/refresh-log.202.txt"
WATCH_BIN="$MUTANT_WATCH" refresh_watch
CONTROL_RC=0
( assert_eq "$REFRESH_EVENTS" "$EVENT" 'positive event oracle'; [[ "$FAIL" -eq 0 ]] ) > "$STUB_DIR/control.out" || CONTROL_RC=$?
assert_eq "watch=$REFRESH_RC oracle=$CONTROL_RC" 'watch=0 oracle=1' "control: the positive event assertion rejects an unreachable failure threshold" "$STUB_DIR/err"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
