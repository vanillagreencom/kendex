#!/usr/bin/env bash
# scope_current_run, the one run-scoping for orch ci-wait and the GitHub
# commands: which checks of a head survive the scoping (the current run of
# each workflow ranked by when it last executed, tiebroken by run id, falling
# back to run id alone while a run is pending or undated; run-less checks
# deduped by name on startedAt; an aggregate status pointing at a superseded
# run held EXPECTED) and which run ids head_runs then names. That no caller
# carries its own copy of the function or of the jq taxonomy is tools/guard's
# lane, not a row here.
#
# A row is `label|checks|scoped|runs`:
#   checks  a fixture name (see checks_of): the head's checks as gh renders them
#   scoped  every check the scoping keeps, in its order, as
#           `<name>:<state>:<run id or ->` joined by `,`
#   runs    head_runs over the scoped list, joined by `,`; `-` when empty
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
# shellcheck source=../scripts/lib/ci-run-correlation.sh
source "$REPO_ROOT/skills/github/scripts/lib/ci-run-correlation.sh"
PASS=0
FAIL=0

assert_eq() {
  local got="$1" want="$2" label="$3"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$label"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        want: %s\n        got:  %s\n' "$label" "$want" "$got"
  fi
}

# --- the heads ----------------------------------------------------------------------
R=https://x/actions/runs
checks_of() {
  case "$1" in
    # an approval-gated repository dispatching an all-skipped no-op run after
    # the substantive one, with the higher id
    later-noop) printf '[{"name":"build","state":"SUCCESS","bucket":"pass","workflow":"CI","startedAt":"2026-07-26T10:00:00Z","link":"%s/100/job/1"},{"name":"build","state":"SKIPPED","bucket":"skipping","workflow":"CI","startedAt":"2026-07-26T10:06:00Z","link":"%s/200/job/2"}]' "$R" "$R" ;;
    # two checks with no run id at all, the same name, nine minutes apart
    run-less) printf '[{"name":"external","state":"SUCCESS","bucket":"pass","workflow":"","startedAt":"2026-07-26T10:00:00Z","link":""},{"name":"external","state":"FAILURE","bucket":"fail","workflow":"","startedAt":"2026-07-26T10:09:00Z","link":""}]' ;;
    two-workflows) printf '[{"name":"a","state":"SUCCESS","bucket":"pass","workflow":"CI","startedAt":"2026-07-26T10:00:00Z","link":"%s/100/job/1"},{"name":"b","state":"SUCCESS","bucket":"pass","workflow":"Guard","startedAt":"2026-07-26T10:00:00Z","link":"%s/50/job/2"}]' "$R" "$R" ;;
    # a rerun keeps its original run id, so the successful rerun has the
    # lower id and the later startedAt beside a cancelled run
    rerun) printf '[{"name":"build","state":"SUCCESS","bucket":"pass","workflow":"CI","startedAt":"2026-07-26T12:22:11Z","link":"%s/30201726860/job/1"},{"name":"CI Gate Publisher","state":"SUCCESS","bucket":"pass","workflow":"CI","startedAt":"2026-07-26T12:23:26Z","link":"%s/30201726860/job/2"},{"name":"CI Required","state":"SUCCESS","bucket":"pass","workflow":"","startedAt":"2026-07-26T12:28:48Z","link":"%s/30201726860"},{"name":"CI Gate Publisher","state":"FAILURE","bucket":"fail","workflow":"CI","startedAt":"2026-07-26T12:21:56Z","link":"%s/30201902682/job/9"},{"name":"build","state":"CANCELLED","bucket":"cancel","workflow":"CI","startedAt":"2026-07-26T12:21:45Z","link":"%s/30201902682/job/10"}]' "$R" "$R" "$R" "$R" "$R" ;;
    # a newer run still queued carries Go's zero timestamp
    queued-newer) printf '[{"name":"build","state":"SUCCESS","bucket":"pass","workflow":"CI","startedAt":"2026-07-26T10:00:00Z","link":"%s/100/job/1"},{"name":"build","state":"QUEUED","bucket":"pending","workflow":"CI","startedAt":"0001-01-01T00:00:00Z","link":"%s/200/job/2"}]' "$R" "$R" ;;
    # a newer run still pending, dated earlier than the finished one
    pending-earlier) printf '[{"name":"build","state":"SUCCESS","bucket":"pass","workflow":"CI","startedAt":"2026-07-26T10:00:00Z","link":"%s/100/job/1"},{"name":"build","state":"IN_PROGRESS","bucket":"pending","workflow":"CI","startedAt":"2026-07-26T09:00:00Z","link":"%s/200/job/2"}]' "$R" "$R" ;;
    # a finished newer run whose timestamp gh never filled in
    undated-newer) printf '[{"name":"build","state":"SUCCESS","bucket":"pass","workflow":"CI","startedAt":"2026-07-26T10:00:00Z","link":"%s/100/job/1"},{"name":"build","state":"SUCCESS","bucket":"pass","workflow":"CI","startedAt":"0001-01-01T00:00:00Z","link":"%s/200/job/2"}]' "$R" "$R" ;;
    later-failure) printf '[{"name":"build","state":"SUCCESS","bucket":"pass","workflow":"CI","startedAt":"2026-07-26T10:00:00Z","link":"%s/100/job/1"},{"name":"build","state":"FAILURE","bucket":"fail","workflow":"CI","startedAt":"2026-07-26T10:30:00Z","link":"%s/200/job/2"}]' "$R" "$R" ;;
    # an aggregate status still pointing at the run a later one superseded
    stale-aggregate) printf '[{"name":"build","state":"SUCCESS","bucket":"pass","workflow":"CI","startedAt":"2026-07-26T10:00:00Z","link":"%s/100/job/1"},{"name":"CI Required","state":"SUCCESS","bucket":"pass","workflow":"","startedAt":"2026-07-26T10:01:00Z","link":"%s/100"},{"name":"build","state":"SUCCESS","bucket":"pass","workflow":"CI","startedAt":"2026-07-26T10:30:00Z","link":"%s/200/job/2"}]' "$R" "$R" "$R" ;;
    # the same aggregate, the later run having failed
    stale-aggregate-failed) printf '[{"name":"build","state":"SUCCESS","bucket":"pass","workflow":"CI","startedAt":"2026-07-26T10:00:00Z","link":"%s/100/job/1"},{"name":"CI Required","state":"SUCCESS","bucket":"pass","workflow":"","startedAt":"2026-07-26T10:01:00Z","link":"%s/100"},{"name":"build","state":"FAILURE","bucket":"fail","workflow":"CI","startedAt":"2026-07-26T10:30:00Z","link":"%s/200/job/2"}]' "$R" "$R" "$R" ;;
    # a custom commit status linking a run of its own beside the workflow's
    status-run) printf '[{"name":"build","state":"SUCCESS","bucket":"pass","workflow":"CI","startedAt":"2026-07-26T10:00:00Z","link":"%s/100/job/1"},{"name":"CI Required","state":"FAILURE","bucket":"fail","workflow":"","link":"%s/200"}]' "$R" "$R" ;;
    # a workflow whose only run is an approval no-op
    all-skipped) printf '[{"name":"build","state":"SKIPPED","bucket":"skipping","workflow":"CI","startedAt":"2026-07-26T10:00:00Z","link":"%s/100/job/1"}]' "$R" ;;
    # a custom status linking a job (not the run) of the superseded run
    status-job-link) printf '[{"name":"build","state":"SUCCESS","bucket":"pass","workflow":"CI","startedAt":"2026-07-26T10:00:00Z","link":"%s/100/job/1"},{"name":"build","state":"SUCCESS","bucket":"pass","workflow":"CI","startedAt":"2026-07-26T10:30:00Z","link":"%s/200/job/2"},{"name":"CI Required","state":"SUCCESS","bucket":"pass","workflow":"","startedAt":"2026-07-26T10:01:00Z","link":"%s/100/job/9"}]' "$R" "$R" "$R" ;;
    # a run-less check beside a run-linked one
    runless-beside-job) printf '[{"name":"build","state":"SUCCESS","bucket":"pass","workflow":"CI","startedAt":"2026-07-26T10:00:00Z","link":"%s/100/job/1"},{"name":"external","state":"SUCCESS","bucket":"pass","workflow":"","startedAt":"2026-07-26T10:05:00Z","link":""}]' "$R" ;;
    *) echo "UNKNOWN-CHECKS: $1" >&2; exit 2 ;;
  esac
}

run() {
  local out
  out="$(checks_of "$1" | scope_current_run)"
  printf 'scoped=%s runs=%s' \
    "$(jq -r '[.[] | .name + ":" + .state + ":" + (((.link // "") | capture("/runs/(?<r>[0-9]+)")? | .r) // "-")] | join(",")' <<<"$out")" \
    "$(jq -r "$CI_RUN_JQ_DEFS"'head_runs | if length == 0 then "-" else join(",") end' <<<"$out")"
}

run_table() {
  local title="$1" rows="$2" label checks scoped runs got row field before=$((PASS + FAIL))
  echo "=== $title ==="
  while IFS= read -r row; do
    [[ "$row" != "" ]] || continue
    IFS='|' read -r label checks scoped runs <<<"$row"
    for field in "$label" "$checks" "$scoped" "$runs"; do
      [[ "$field" != "" ]] || { printf 'a row with an empty field asserts nothing: %s\n' "$row" >&2; exit 1; }
    done
    got="$(run "$checks")"
    # A rendering aid for writing rows; the run is refused after the loop.
    if [[ "${GITHUB_TABLE_PROBE:-}" == 1 ]]; then
      printf '%s => %s\n' "$label" "$got"
      continue
    fi
    assert_eq "$got" "scoped=$scoped runs=$runs" "$label"
  done <<<"$rows"
  [[ "$((PASS + FAIL))" -gt "$before" ]] || { echo "no row was asserted (a probe run renders rows instead)" >&2; exit 2; }
}

run_table "the run scoping" "\
a later all-skipped run does not supersede the substantive one|later-noop|build:SUCCESS:100|100
run-less checks dedupe by name, the latest startedAt winning|run-less|external:FAILURE:-|-
distinct workflows are never collapsed into one another|two-workflows|a:SUCCESS:100,b:SUCCESS:50|50,100
a rerun on its original, lower id outranks a cancelled higher one by execution time, and the aggregate it backs stays green|rerun|build:SUCCESS:30201726860,CI Gate Publisher:SUCCESS:30201726860,CI Required:SUCCESS:30201726860|30201726860
a queued newer run with no timestamp still wins, by run id|queued-newer|build:QUEUED:200|200
a pending newer run dated before the finished one still wins, by run id|pending-earlier|build:IN_PROGRESS:200|200
a finished newer run gh left undated still wins, by run id|undated-newer|build:SUCCESS:200|200
a later failing run stays terminal|later-failure|build:FAILURE:200|200
an aggregate pointing at a superseded run is held EXPECTED and its run leaves head_runs|stale-aggregate|build:SUCCESS:200,CI Required:EXPECTED:100|200
an aggregate is not held behind a later run that failed: the failure stands beside it|stale-aggregate-failed|build:FAILURE:200,CI Required:SUCCESS:100|100,200
a status linking a run of its own names it beside the workflow's|status-run|build:SUCCESS:100,CI Required:FAILURE:200|100,200
the only run of a workflow being an all-skipped no-op still scopes to it|all-skipped|build:SKIPPED:100|100
a status linking a job of a superseded run is not an aggregate and is never held|status-job-link|build:SUCCESS:200,CI Required:SUCCESS:100|100,200
a run-less check is kept after the run's own, never ahead of it|runless-beside-job|build:SUCCESS:100,external:SUCCESS:-|100
"

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
