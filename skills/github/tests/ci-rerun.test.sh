#!/usr/bin/env bash
# ci-rerun: one `gh run rerun` of the pull request's current failed run, and
# only when its failed log names a transient runner failure.
#
# Each row names the defect it catches. The log of the first row clears two
# 64KB pipe buffers inside the scanned window and one more past it, the
# marker on its first line: under `gh | head -200` head's close SIGPIPEs gh,
# pipefail reports the 141, and the retry is dead for every log big enough
# to need it. The window itself is pinned by the row that plants the marker
# just past it. Unreadable reads answer their own cause and act on nothing:
# an unread log, an unread rollup and an unread required set are each a
# `no-rerun`, never `not-transient`, and never a rerun. A failed required
# workflow names its bound run itself: the rows with every visible job green
# hold that the rollup is not what chooses it.
#
# Run: bash skills/github/tests/ci-rerun.test.sh
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CMD="$TEST_DIR/../scripts/commands/ci-rerun.sh"
TMP_ROOT="$(mktemp -d)" || { echo "ci-rerun.test: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "ci-rerun.test: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "ci-rerun.test: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

PASS=0
FAIL=0

assert_eq() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$name" "$want" "$got"
  fi
}

assert_le() {
  local bound="$1" got="$2" name="$3"
  if [[ "$got" =~ ^[0-9]+$ ]] && [ "$bound" -le "$got" ]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        wanted: >= %s\n        got:    %s\n' "$name" "$bound" "$got"
  fi
}

# shellcheck source=lib/gh-stub.sh
. "$TEST_DIR/lib/gh-stub.sh"
GH_STUB_DIR="$TMP_ROOT/gh-stub" gh_stub_install "$TMP_ROOT/bin"

# --- the logs ---------------------------------------------------------------
# A runner-acquisition failure reports on the first line; 400 lines of ~1KB
# padding put two pipe buffers inside the 200-line window and one more past
# it. Both sizes are asserted, not assumed.
transient_log="$TMP_ROOT/transient.log"
{
  printf 'The job was not acquired: rate limit exceeded, retrying in 30s\n'
  padding="$(printf 'x%.0s' {1..950})"
  for _i in $(seq 1 400); do
    printf '2026-09-02T10:00:00Z  compiling crate %s\n' "$padding"
  done
} >"$transient_log"
window_bytes=$(head -n 200 "$transient_log" | wc -c | tr -d ' ')
tail_bytes=$(($(wc -c <"$transient_log" | tr -d ' ') - window_bytes))
assert_le 131072 "$window_bytes" "two pipe buffers fit inside the scanned window"
assert_le 65536 "$tail_bytes" "one pipe buffer fits inside the log past the window"

# The same log with the marker moved to line 201: one past the window.
late_log="$TMP_ROOT/late.log"
{
  sed -n '2,201p' "$transient_log"
  sed -n '1p' "$transient_log"
} >"$late_log"
assert_eq "$(grep -n 'rate limit' "$late_log" | cut -d: -f1)" "201" "the late marker sits on line 201"

# A failed log naming the change, not the runner.
real_log="$TMP_ROOT/real.log"
printf 'error[E0425]: cannot find value `x` in this scope\ntest result: FAILED. 1 failed\n' >"$real_log"

# --- the heads --------------------------------------------------------------
R=https://github.com/owner/repo/actions/runs
check() { # NAME STATE BUCKET WORKFLOW STARTED LINK
  printf '{"name":"%s","state":"%s","bucket":"%s","workflow":"%s","startedAt":"%s","link":"%s"}' "$@"
}
# the required `build` job red on run 123
red_build="[$(check build FAILURE fail CI 2026-07-26T10:00:00Z "$R/123/job/1")]"
# an optional `nightly guard` red beside a green required build
red_optional="[$(check build SUCCESS pass CI 2026-07-26T10:00:00Z "$R/123/job/1"),$(check 'nightly guard' FAILURE fail Nightly 2026-07-26T10:01:00Z "$R/124/job/2")]"
# run 100's red build superseded by run 200's green one, later started
red_superseded="[$(check build FAILURE fail CI 2026-07-26T10:00:00Z "$R/100/job/1"),$(check build SUCCESS pass CI 2026-07-26T10:30:00Z "$R/200/job/2")]"
# every visible job green, the required workflow's `request` job on run 500
# among them: the rollup of a required workflow that failed past its jobs
green_with_required_job="[$(check build SUCCESS pass CI 2026-07-26T10:00:00Z "$R/123/job/1"),$(check request SUCCESS pass Required 2026-07-26T10:01:00Z "$R/500/job/501")]"

# The base's requirement evidence for --required-only: a ruleset naming
# `build`, classic protection carrying the same context.
stage_required_build() {
  gh_stub_answer pr-view main
  gh_stub_answer 'api:rules/branches' 'ctx:build'
  gh_stub_answer 'api:/branches/main' '{"protection":{"required_status_checks":{"contexts":["build"]}}}'
}

# A required workflow bound to run 500 on the head: the ruleset requires
# the workflow at WORKFLOW_PATH from org/source, and its one run on the
# head ended with CONCLUSION. Every read
# required_contexts makes to bind that run is staged; the api selectors are
# staged most specific first, since the stub takes the first whose text the
# call carries.
HEAD=d049a699ebe08c6b639fdc19855a7152ae768084
SOURCE_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
WORKFLOW_PATH=.github/workflows/request-copilot-review.yml
stage_required_workflow() { # CONCLUSION
  gh_stub_answer 'pr-view:baseRefName' main
  gh_stub_answer 'pr-view:headRefOid' "$HEAD"
  gh_stub_answer 'api:rules/branches' "$(printf 'ctx:build\nworkflow:{"path":"%s","repository_id":999}' "$WORKFLOW_PATH")"
  gh_stub_answer 'api:/branches/main' '{"protection":{"required_status_checks":{"contexts":["build"]}}}'
  gh_stub_answer 'api:actions/runs' "$(jq -cn --arg head "$HEAD" --arg path "$WORKFLOW_PATH" --arg conclusion "$1" \
    '[{total_count: 1, workflow_runs: [{id: 500, workflow_id: 500, path: $path, head_sha: $head, repository: {id: 123}, check_suite_id: 500, check_suite_node_id: "suite-500", status: "completed", conclusion: $conclusion, run_attempt: 1, updated_at: "2026-07-26T10:02:00Z"}]}]')"
  gh_stub_answer 'api:repos/org/source/commits' "$SOURCE_SHA"
  gh_stub_answer 'api:repos/org/source' '{"id":999,"full_name":"org/source","default_branch":"main"}'
  gh_stub_answer 'api:repos/owner/repo --jq .id' 123
  gh_stub_answer api-graphql "$(jq -cn --arg path "$WORKFLOW_PATH" --arg sha "$SOURCE_SHA" \
    '{data: {nodes: [{id: "suite-500", databaseId: 500, workflowRun: {databaseId: 500, runAttempt: 1, file: {path: $path, repositoryName: "org/source", repositoryFileUrl: ("https://github.com/org/source/blob/" + $sha + "/" + $path), viewerCanReadRepository: true}}}]}}')"
}
# The failed job log of that workflow's runner.
runner_log="$TMP_ROOT/runner.log"
printf 'runner error: network timeout\n' >"$runner_log"

# --- the runs ---------------------------------------------------------------
run_verb() { # ARGS... — stdout to $OUT, stderr to $ERR, status to $RC
  RC=0
  (PATH="$TMP_ROOT/bin:$PATH" bash "$CMD" "$@" >"$TMP_ROOT/out" 2>"$TMP_ROOT/err") || RC=$?
  OUT="$(cat "$TMP_ROOT/out")"
  ERR="$(cat "$TMP_ROOT/err")"
}
rerun_calls() { gh_stub_calls | grep -c '^run rerun ' || true; }
view_calls() { gh_stub_calls | grep -c '^run view ' || true; }
checks_calls() { gh_stub_calls | grep -c '^pr checks ' || true; }

echo "=== a transient marker in a large failed log reruns the current failed required run once ==="
gh_stub_reset
stage_required_build
gh_stub_answer pr-checks "$red_build"
gh_stub_answer run-view "$(cat "$transient_log")"
gh_stub_answer run-rerun ''
run_verb 42 --required-only --repo owner/repo
assert_eq "$RC" "0" "the verb exits 0"
assert_eq "$OUT" "rerun run=123 pattern=rate limit" "the keyed line names the run and the pattern"
assert_eq "$(rerun_calls)" "1" "exactly one rerun is asked"
assert_eq "$(gh_stub_calls | grep '^run rerun ')" "run rerun 123 --repo owner/repo --failed" "the rerun names the run, the repository and --failed"

echo "=== a red check the base does not require is not rerun under --required-only ==="
gh_stub_reset
stage_required_build
gh_stub_answer pr-checks "$red_optional"
gh_stub_answer run-view "$(cat "$transient_log")"
gh_stub_answer run-rerun ''
run_verb 42 --required-only
assert_eq "$RC $OUT" "0 no-rerun cause=no-failed-run" "an optional red is no failed required run"
assert_eq "$(view_calls)" "0" "no log is read"
assert_eq "$(rerun_calls)" "0" "nothing is rerun"

echo "=== without --required-only every red counts ==="
gh_stub_reset
gh_stub_answer pr-checks "$red_optional"
gh_stub_answer run-view "$(cat "$transient_log")"
gh_stub_answer run-rerun ''
run_verb 42
assert_eq "$RC $OUT" "0 rerun run=124 pattern=rate limit" "the optional red is rerun"

echo "=== a gh failure reading the log is not transient: nothing is rerun ==="
gh_stub_reset
gh_stub_answer pr-checks "$red_build"
gh_stub_fail run-view 1 'HTTP 500: the log is unavailable'
gh_stub_answer run-rerun ''
run_verb 42
assert_eq "$RC $OUT" "0 no-rerun cause=log-unread" "an unread log is log-unread, not not-transient"
assert_eq "$(rerun_calls)" "0" "nothing is rerun"
assert_eq "$(grep -c 'ci-rerun: log-unread run=123: HTTP 500' <<<"$ERR")" "1" "stderr names the run and gh's line"

echo "=== a failed log naming no pattern is not transient ==="
gh_stub_reset
gh_stub_answer pr-checks "$red_build"
gh_stub_answer run-view "$(cat "$real_log")"
gh_stub_answer run-rerun ''
run_verb 42
assert_eq "$RC $OUT" "0 no-rerun cause=not-transient" "a real failure is not rerun"
assert_eq "$(rerun_calls)" "0" "nothing is rerun"

echo "=== a marker past the first 200 lines is outside the window ==="
gh_stub_reset
gh_stub_answer pr-checks "$red_build"
gh_stub_answer run-view "$(cat "$late_log")"
gh_stub_answer run-rerun ''
run_verb 42
assert_eq "$RC $OUT" "0 no-rerun cause=not-transient" "line 201 is not read"
assert_eq "$(rerun_calls)" "0" "nothing is rerun"

echo "=== a red check of a superseded run is not rerun ==="
gh_stub_reset
gh_stub_answer pr-checks "$red_superseded"
gh_stub_answer run-view "$(cat "$transient_log")"
gh_stub_answer run-rerun ''
run_verb 42
assert_eq "$RC $OUT" "0 no-rerun cause=no-failed-run" "the current run is green"
assert_eq "$(rerun_calls)" "0" "nothing is rerun"

# required_contexts answers `state=failed` with the bound run for a required
# workflow that failed past its registered jobs, so the rollup shows nothing
# red; a verb choosing from the rollup alone would answer `no-failed-run`
# without reading the failed run's log, sending the lane to ci-fix while its
# one rerun is owed, and the head record written before the ask would
# foreclose that rerun for the head. The reader's bound run is taken first
# (the required branch); the rollup is not consulted for it.
echo "=== a failed required workflow is rerun from its bound run though every visible job is green ==="
gh_stub_reset
stage_required_workflow failure
gh_stub_answer pr-checks "$green_with_required_job"
gh_stub_answer run-view "$(cat "$runner_log")"
gh_stub_answer run-rerun ''
run_verb 42 --required-only --repo owner/repo
assert_eq "$RC $OUT" "0 rerun run=500 pattern=network timeout" "the bound run is rerun on its runner failure"
assert_eq "$(rerun_calls)" "1" "exactly one rerun is asked"
assert_eq "$(gh_stub_calls | grep '^run rerun ')" "run rerun 500 --repo owner/repo --failed" "the rerun names the bound run, the repository and --failed"
assert_eq "$(checks_calls)" "0" "the rollup is not read to choose the bound run"

echo "=== a failed required workflow whose log names no pattern is not rerun ==="
gh_stub_reset
stage_required_workflow failure
gh_stub_answer pr-checks "$green_with_required_job"
gh_stub_answer run-view "$(cat "$real_log")"
gh_stub_answer run-rerun ''
run_verb 42 --required-only --repo owner/repo
assert_eq "$RC $OUT" "0 no-rerun cause=not-transient" "the bound run's real failure is not rerun"
assert_eq "$(rerun_calls)" "0" "nothing is rerun"

echo "=== an unreadable rollup reruns nothing and says so ==="
gh_stub_reset
gh_stub_fail pr-checks 1 'HTTP 502'
gh_stub_answer run-view "$(cat "$transient_log")"
gh_stub_answer run-rerun ''
run_verb 42
assert_eq "$RC $OUT" "0 no-rerun cause=checks-unread" "an unread rollup is checks-unread"
assert_eq "$(rerun_calls)" "0" "nothing is rerun"

echo "=== an unreadable required set reruns nothing under --required-only ==="
gh_stub_reset
gh_stub_answer pr-view main
gh_stub_answer 'api:rules/branches' 'unreadable:workflows'
gh_stub_answer 'api:/branches/main' '{"protection":{"required_status_checks":{"contexts":["build"]}}}'
gh_stub_answer pr-checks "$red_build"
gh_stub_answer run-view "$(cat "$transient_log")"
gh_stub_answer run-rerun ''
run_verb 42 --required-only
assert_eq "$RC $OUT" "0 no-rerun cause=requirements-unread" "an unread required set is requirements-unread"
assert_eq "$(rerun_calls)" "0" "nothing is rerun"

echo "=== gh refusing the rerun exits 1 with its line ==="
gh_stub_reset
gh_stub_answer pr-checks "$red_build"
gh_stub_answer run-view "$(cat "$transient_log")"
gh_stub_fail run-rerun 1 'HTTP 403: Resource not accessible by integration'
run_verb 42
assert_eq "$RC" "1" "the refusal exits 1"
assert_eq "$OUT" "" "no keyed line is printed"
assert_eq "$(jq -r '.error' <<<"$ERR")" "gh run rerun 123 refused: HTTP 403: Resource not accessible by integration" "stderr carries the JSON error with gh's line"

echo "=== usage ==="
gh_stub_reset
run_verb 42 --json
assert_eq "$RC" "2" "an unknown option is a usage error"
assert_eq "$ERR" "Error: Unknown option: --json" "and is named"
run_verb
assert_eq "$RC" "2" "a missing PR number is a usage error"
run_verb --help
assert_eq "$RC" "0" "--help answers"
assert_eq "$(grep -c '^Usage: ci-rerun <PR_NUMBER> \[--required-only\] \[--repo OWNER/REPO\]$' <<<"$OUT")" "1" "--help prints the usage line"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
