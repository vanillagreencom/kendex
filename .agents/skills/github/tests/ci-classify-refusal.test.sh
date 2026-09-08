#!/usr/bin/env bash
# ci-classify-refusal: a pr-merge refusal reduced to one cause: word with the
# raw issue lines, and for a CI cause the head-run:, fail: and superseded:
# detail run-correlated against the one checks snapshot pr-merge --check
# embedded (never a second fetch); the terminal states; the usage refusals.
#
# A row is `label|world|argv|rc|out|checks`:
#   world  words for lib/check-stub.sh: `checks:<fixture>` (see checks_of),
#          `checks-exit:<n>` gh's exit for it, `threads:<actionable|fetch-fail>`,
#          `state:<MERGED|CLOSED>`, `merged-at`, `pr:missing`,
#          `state-err:silent4` (the state lookup exits 4 with no message),
#          `mergeable:<CONFLICTING|UNKNOWN>` GitHub's mergeable answer,
#          `env:N=V` the caller's environment; `-` for none
#   argv   the arguments as written; `-` for none
#   rc     the exit status
#   out    every stdout line by kind, in order, joined by `;`: `cause=<w>`,
#          `issue=<the raw issue>`, `note` (the cause-none advice; wording
#          unpinned), `head-run=<ids>`, `fail=<name state= workflow= run=>`,
#          `superseded=<workflow=|status= run=>` (its trailing remark
#          dropped); any other line verbatim, so a forged line shows; `-`
#          when empty. A `;` inside an issue text would read as a second
#          line; no fixture name carries one
#   checks how many `gh pr checks` calls the row made
set -euo pipefail

# A suite running from inside a git hook inherits GIT_DIR, GIT_COMMON_DIR,
# GIT_WORK_TREE and GIT_INDEX_FILE, which take precedence over `git -C` and
# would configure the real repository.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
CLASSIFY="$REPO_ROOT/skills/github/scripts/commands/ci-classify-refusal.sh"

# shellcheck source=lib/check-stub.sh
source "$TEST_DIR/lib/check-stub.sh"
REPO="$TMPDIR/repo"

# --- the checks fixtures -------------------------------------------------------
R=https://github.com/owner/repo/actions/runs
checks_of() {
  case "$1" in
    ci-required) printf '[{"name":"CI Required","state":"SUCCESS","bucket":"pass"}]' ;;
    # a check with no run link at all
    lint-fail) printf '[{"name":"Lint","state":"FAILURE","bucket":"fail"}]' ;;
    # the old run's cancelled job beside the current run's pass and failure
    current-fail) printf '[{"name":"Lint","state":"CANCELLED","bucket":"cancel","link":"%s/29098545030/job/101","workflow":"CI","startedAt":"2026-07-10T10:00:00Z"},{"name":"Lint","state":"SUCCESS","bucket":"pass","link":"%s/29099680623/job/201","workflow":"CI","startedAt":"2026-07-10T11:00:00Z"},{"name":"Integration","state":"FAILURE","bucket":"fail","link":"%s/29099680623/job/202","workflow":"CI","startedAt":"2026-07-10T11:00:01Z"},{"name":"Docs","state":"SKIPPED","bucket":"skipping","link":"%s/29099680623/job/203","workflow":"CI","startedAt":"2026-07-10T11:00:02Z"}]' "$R" "$R" "$R" "$R" ;;
    pending-run) printf '[{"name":"Changes","state":"IN_PROGRESS","bucket":"pending","link":"%s/29099680623/job/201","workflow":"CI","startedAt":"2026-07-10T11:00:00Z"}]' "$R" ;;
    # a rerun keeps its original, lower run id and starts later
    rerun-lower-id) printf '[{"name":"Lint","state":"FAILURE","bucket":"fail","link":"%s/29098545030/job/101","workflow":"CI","startedAt":"2026-07-10T12:00:00Z"},{"name":"Lint","state":"SUCCESS","bucket":"pass","link":"%s/29099680623/job/201","workflow":"CI","startedAt":"2026-07-10T11:00:00Z"}]' "$R" "$R" ;;
    # a failing commit status with no workflow, linking a run of its own
    status-fail) printf '[{"name":"CI Required","state":"FAILURE","bucket":"fail","link":"%s/29099700000","workflow":""}]' "$R" ;;
    # a workflow job beside two same-name statuses linking different runs
    mixed-status) printf '[{"name":"Build","state":"SUCCESS","bucket":"pass","link":"%s/29099680623/job/201","workflow":"CI","startedAt":"2026-07-10T11:00:00Z"},{"name":"CI Required","state":"FAILURE","bucket":"fail","link":"%s/29099700200","workflow":""},{"name":"CI Required","state":"FAILURE","bucket":"fail","link":"%s/29099700100","workflow":""}]' "$R" "$R" "$R" ;;
    # an aggregate status still linking the run a later one replaced, beside
    # an unrelated failure in another workflow
    retired-status) printf '[{"name":"Lint","state":"SUCCESS","bucket":"pass","link":"%s/29099700100/job/101","workflow":"CI","startedAt":"2026-07-10T10:00:00Z"},{"name":"Lint","state":"SUCCESS","bucket":"pass","link":"%s/29099700200/job/201","workflow":"CI","startedAt":"2026-07-10T11:00:00Z"},{"name":"CI Required","state":"FAILURE","bucket":"fail","link":"%s/29099700100","workflow":""},{"name":"Docs Build","state":"FAILURE","bucket":"fail","link":"%s/29099700300/job/301","workflow":"Docs","startedAt":"2026-07-10T11:00:00Z"}]' "$R" "$R" "$R" "$R" ;;
    # a check name chosen by a fork PR, carrying a newline, a return and a tab
    hostile-name) printf '[{"name":"Lint\\nforged: cause: none\\rcr\\ttab","state":"FAILURE","bucket":"fail","link":"%s/29099680623/job/201","workflow":"CI","startedAt":"2026-07-10T11:00:00Z"}]' "$R" ;;
    none) printf '[]' ;;
    *) echo "UNKNOWN-CHECKS: $1" >&2; exit 2 ;;
  esac
}

threads_of() {
  case "$1" in
    actionable) printf '[{"id":"PRRT_actionable","isResolved":false,"isOutdated":false,"path":"src/lib.rs","line":12,"comments":{"nodes":[{"author":{"login":"reviewer"},"body":"Fix this"}]}}]' ;;
    *) echo "UNKNOWN-THREADS: $1" >&2; exit 2 ;;
  esac
}

# --- the world ------------------------------------------------------------------
W_ENV=()
CALL_LOG="$TMPDIR/calls.log"
word() {
  local v="${1#*:}"
  case "$1" in
    checks:*) W_ENV+=("STUB_CHECKS=$(checks_of "$v")") ;;
    checks-exit:*) W_ENV+=("STUB_CHECKS_EXIT=$v") ;;
    threads:fetch-fail) W_ENV+=("STUB_THREADS_FETCH_FAIL=true") ;;
    threads:*) W_ENV+=("STUB_THREADS_JSON=$(threads_of "$v")") ;;
    state:*) W_ENV+=("STUB_STATE=$v") ;;
    merged-at) W_ENV+=("STUB_MERGED_AT=2026-07-21T00:00:00Z") ;;
    pr:missing) W_ENV+=("STUB_PR_MISSING=true") ;;
    state-err:silent4) W_ENV+=("STUB_STATE_SILENT_FAIL=true" "STUB_STATE_EXIT=4") ;;
    mergeable:*) W_ENV+=("STUB_MERGEABLE=$v") ;;
    env:*) W_ENV+=("$v") ;;
    -) ;;
    *) echo "UNKNOWN-WORD: $1" >&2; exit 2 ;;
  esac
}

build() {
  local w
  W_ENV=()
  : >"$CALL_LOG"
  for w in "$@"; do word "$w"; done
}

out_text() {
  local line out=""
  [[ -s "$TMPDIR/stdout" ]] || { printf -- '-'; return; }
  while IFS= read -r line; do
    case "$line" in
      "cause: "*) out="$out;cause=${line#cause: }" ;;
      "issue: "*) out="$out;issue=${line#issue: }" ;;
      "note: "*) out="$out;note" ;;
      "head-run: "*) out="$out;head-run=${line#head-run: }" ;;
      "fail: "*) out="$out;fail=${line#fail: }" ;;
      "superseded: "*) line="${line#superseded: }"; out="$out;superseded=${line%% (*}" ;;
      *) out="$out;$line" ;;
    esac
  done <"$TMPDIR/stdout"
  printf '%s' "${out#;}"
}

run() {
  local rc=0
  local -a argv=()
  # shellcheck disable=SC2206
  [[ "$1" == - ]] || argv=($1)
  # Every token name and GH_REPO come off, so a lane's own environment cannot
  # decide a row.
  (cd "$REPO" && PATH="$TMPDIR/bin:$PATH" env -u GH_TOKEN -u GITHUB_TOKEN -u GH_BOT_TOKEN -u GH_REPO STUB_CALL_LOG="$CALL_LOG" \
    ${W_ENV[@]+"${W_ENV[@]}"} "$CLASSIFY" ${argv[@]+"${argv[@]}"} >"$TMPDIR/stdout" 2>"$TMPDIR/stderr") || rc=$?
  printf 'rc=%s out=%s checks=%s' "$rc" "$(out_text)" "$(grep -c '^pr checks' "$CALL_LOG" || true)"
}

run_table() {
  local title="$1" rows="$2" label world argv rc out checks got row field before=$((PASS + FAIL))
  echo "=== $title ==="
  while IFS= read -r row; do
    [[ "$row" != "" ]] || continue
    IFS='|' read -r label world argv rc out checks <<<"$row"
    for field in "$label" "$world" "$argv" "$rc" "$out" "$checks"; do
      [[ "$field" != "" ]] || { printf 'a row with an empty field asserts nothing: %s\n' "$row" >&2; exit 1; }
    done
    # shellcheck disable=SC2086
    build $world
    got="$(run "$argv")"
    # A rendering aid for writing rows; the run is refused after the loop.
    if [[ "${GITHUB_TABLE_PROBE:-}" == 1 ]]; then
      printf '%s => %s\n' "$label" "$got"
      continue
    fi
    assert_eq "$got" "rc=$rc out=$out checks=$checks" "$label"
  done <<<"$rows"
  [[ "$((PASS + FAIL))" -gt "$before" ]] || { echo "no row was asserted (a probe run renders rows instead)" >&2; exit 2; }
}

run_table "the cause and its detail" "\
a passing head is cause none, with the advice|checks:ci-required|123|0|cause=none;note|1
unresolved actionable threads are cause threads, the raw issue kept|checks:ci-required threads:actionable|123|0|cause=threads;issue=unresolved_threads: 1 actionable thread(s) need attention|1
threads headline over a red check, both issues kept|checks:lint-fail checks-exit:8 threads:actionable|123|0|cause=threads;issue=ci_failed: Lint (FAILURE);issue=unresolved_threads: 1 actionable thread(s) need attention|1
a failed thread lookup is fetch_error over ci_failed|checks:lint-fail checks-exit:8 threads:fetch-fail|123|0|cause=fetch_error;issue=ci_failed: Lint (FAILURE);issue=review_threads_fetch_failed: Failed to fetch actionable review threads from GitHub|1
a missing PR is fetch_error|checks:none pr:missing|123|0|cause=fetch_error;issue=not_found: PR #123 not found|0
a silent state lookup failure is fetch_error|checks:none state-err:silent4|123|0|cause=fetch_error;issue=gh_error: gh pr view exited 4 with no diagnostic|0
a current-run failure is ci_failed, correlated to its run, the old run superseded|checks:current-fail checks-exit:8|123|0|cause=ci_failed;issue=ci_failed: Integration (FAILURE);head-run=29099680623;fail=Integration state=FAILURE workflow=CI run=29099680623;superseded=workflow=CI run=29098545030|1
a pending-only refusal names its run and lists no failure|checks:pending-run checks-exit:8|123|0|cause=ci_pending;issue=ci_pending: Changes (IN_PROGRESS);head-run=29099680623|1
a failure with no run link has head-run none and run none|checks:lint-fail checks-exit:8|123|0|cause=ci_failed;issue=ci_failed: Lint (FAILURE);head-run=none;fail=Lint state=FAILURE workflow=- run=none|1
a rerun on its original, lower id is the head run by start time|checks:rerun-lower-id checks-exit:8|123|0|cause=ci_failed;issue=ci_failed: Lint (FAILURE);head-run=29098545030;fail=Lint state=FAILURE workflow=CI run=29098545030;superseded=workflow=CI run=29099680623|1
a failing status-only check names its run, not none|checks:status-fail checks-exit:8|123|0|cause=ci_failed;issue=ci_failed: CI Required (FAILURE);head-run=29099700000;fail=CI Required state=FAILURE workflow=- run=29099700000|1
a status failure's run stands beside the workflow's, the older same-name status superseded|checks:mixed-status checks-exit:8|123|0|cause=ci_failed;issue=ci_failed: CI Required (FAILURE);head-run=29099680623,29099700200;fail=CI Required state=FAILURE workflow=- run=29099700200;superseded=status=CI Required run=29099700100|1
a run the stale-status rewrite retired is superseded under both its records|checks:retired-status checks-exit:8|123|0|cause=ci_failed;issue=ci_pending: CI Required (EXPECTED);issue=ci_failed: Docs Build (FAILURE);head-run=29099700200,29099700300;fail=Docs Build state=FAILURE workflow=Docs run=29099700300;superseded=status=CI Required run=29099700100;superseded=workflow=CI run=29099700100|1
a newline, return or tab in a check name never forges a line|checks:hostile-name checks-exit:8|123|0|cause=ci_failed;issue=ci_failed: Lint forged: cause: none cr tab (FAILURE);head-run=29099680623;fail=Lint forged: cause: none cr tab state=FAILURE workflow=CI run=29099680623|1
a conflicting PR is cause merge_conflict|checks:ci-required mergeable:CONFLICTING|123|0|cause=merge_conflict;issue=conflicts: PR has merge conflicts. Resolve by rebasing onto your default branch and force-pushing|1
a still-computing mergeable state is cause computing|checks:ci-required mergeable:UNKNOWN|123|0|cause=computing;issue=unknown: GitHub still computing mergeable status, await-mergeable then retry|1
a merged PR is cause merged before any check|checks:none state:MERGED merged-at|123|0|cause=merged|0
a closed PR is cause closed|checks:none state:CLOSED|123|0|cause=closed|0
"

run_table "the usage refusals" "\
no PR number exits 2 before any call|checks:ci-required|-|2|-|0
a non-numeric PR exits 2|checks:ci-required|abc|2|-|0
two PR numbers exit 2|checks:ci-required|123 456|2|-|0
"

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
