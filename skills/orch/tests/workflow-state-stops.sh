#!/usr/bin/env bash
# `workflow-state`'s three post-PR decisions the workflows run: whether an
# item's record stands (`exists --json`), the stop a pull request is told
# (`post-pr-stop record` and `record-if-empty`), and the CI-fix cap across
# heads (`head-budget take <item> ci-fix <head>`).
#
# Rows on the store's three decisions until the runtime's `state` family holds
# them. Each row's comment names the failure a real run reaches through it.
# Inputs: skills/agent-runtime/, skills/agent-runtime/scripts/, skills/change-scope/references/,
# skills/change-scope/scripts/, skills/communication/references/reports.md, skills/mailbox/scripts/,
# skills/orch/runtime/, skills/orch/scripts/, skills/orch/tests/.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# shellcheck source=lib/assertions.sh
source "$TEST_DIR/lib/assertions.sh"

WS="$TEST_DIR/../scripts/workflow-state"
state_dir="$TMP_ROOT/state"
ws() { ORCH_STATE_DIR="$state_dir" "$WS" "$@"; }

echo
echo "--- workflow-state: exists, the stop, the ci-fix cap ---"

# review-pr.md and submit-pr.md read `exists --json` before `init`. A false
# answer on a standing record re-initializes the item and drops its state; a
# true answer on a missing record skips the init and every later verb refuses.
# The issue id travels with the answer.
ws init issue-353 --worktree "$TMP_ROOT" --branch issue-353 >/dev/null
exists_json="$(ws exists --json issue-353)"
assert_eq "$(jq -r '.exists' <<<"$exists_json")" "true" "exists --json reports a standing record"
assert_eq "$(jq -r '.issue_id' <<<"$exists_json")" "issue-353" "exists --json carries the issue id"
missing_json="$(ws exists --json issue-404)"
assert_eq "$(jq -r '.exists' <<<"$missing_json")" "false" "exists --json reports a missing record"

# ci-fix.md, merge-pr.md and merge-pr-restack.md record a named stop and post
# the rendered file to the pull request; start-worktree.md records its generic
# stop only where none stands. A record that leaves the remaining work out of
# the file posts a stop that says nothing; a record-if-empty that overwrites
# buries the precise stop under the generic one; one that never records leaves
# the pull request untold.
ws init issue-404 --branch issue-404 >/dev/null
stop_comment="$TMP_ROOT/post-pr-stop.md"
assert_eq "$(ws post-pr-stop record issue-404 review-round-cap review 'one unresolved review thread' "$stop_comment")" "recorded" "post-pr-stop record answers recorded"
assert_file_contains "$stop_comment" 'one unresolved review thread' "post-pr-stop record renders the remaining work into the comment file"
assert_eq "$(ws post-pr-stop record-if-empty issue-404 merge-gates-unmet merge 'CI pending' "$stop_comment")" "kept" "record-if-empty keeps a standing stop"
assert_eq "$(ws get issue-404 '.post_pr_stop.name')" "review-round-cap" "record-if-empty leaves the precise stop's name"
ws update issue-404 '.post_pr_stop = null'
assert_eq "$(ws post-pr-stop record-if-empty issue-404 merge-gates-unmet merge 'CI pending' "$stop_comment")" "recorded" "record-if-empty records where no stop stands"

# ci-fix.md takes the budget every cycle, each on the head its own push
# produced, so a head-keyed reset returns `continue` forever and
# CI_FIX_MAX_CYCLES bounds nothing. The one release is the passing run's clear
# of the budget.
CI_FIX_MAX_CYCLES=1 ws head-budget take issue-404 ci-fix ci-head-a >/dev/null
assert_eq "$(CI_FIX_MAX_CYCLES=1 ws head-budget take issue-404 ci-fix ci-head-a)" "at-cap 1/1" "ci-fix persists its cap on one head"
ws update issue-404 '.post_pr_budgets.ci_fix = null'
assert_eq "$(CI_FIX_MAX_CYCLES=2 ws head-budget take issue-404 ci-fix ci-head-a)" "continue 1/2" "ci-fix spends its first cycle"
assert_eq "$(CI_FIX_MAX_CYCLES=2 ws head-budget take issue-404 ci-fix ci-head-b)" "continue 2/2" "ci-fix counts a cycle on the head its own push produced"
assert_eq "$(CI_FIX_MAX_CYCLES=2 ws head-budget take issue-404 ci-fix ci-head-c)" "at-cap 2/2" "ci-fix reaches its cap across cycles that each push a new head"
ws update issue-404 '.post_pr_budgets.ci_fix = null'
assert_eq "$(CI_FIX_MAX_CYCLES=2 ws head-budget take issue-404 ci-fix ci-head-d)" "continue 1/2" "a passing CI run's clear of ci_fix resets the budget"

printf '\npass: %s fail: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
