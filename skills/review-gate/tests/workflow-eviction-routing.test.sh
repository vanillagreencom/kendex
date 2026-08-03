#!/usr/bin/env bash
# Pins the eviction-safe event routing of the review-gate writer workflows
# (#1039). Both rerun workflows (shipped template + vstack's live
# self-adoption copy) enter the repo-wide `review-gate-writer` concurrency
# group at the WORKFLOW level, before any job-level filter; with
# cancel-in-progress:false GitHub keeps ONE pending run per group and
# REPLACES it, so an arriving run EVICTS whatever writer was pending. The
# invariants pinned here make that replacement lossless:
#
#   w1. every writer workflow shares the single group with
#       cancel-in-progress: false (the out-of-order-writer race guard)
#   w2. `status` events are NOT filtered at the job level — a skipped
#       status job would still evict the pending writer while converging
#       nothing
#   w3. status-shaped runs route to ALL_OPEN_PRS=1 (sweep-style full
#       convergence: surviving in the slot subsumes whatever was evicted)
#   w4. PR-specific events keep the single-PR fast path
#   w5. the `status` trigger stays declared — the gate's own status posts
#       re-trigger a full-convergence pass, which is the healing mechanism
#       for writers evicted by PR-specific runs
#   w6. the scaffold keeps its check_run / issue_comment trust guards, and
#       a trusted check_run with no resolvable open PR falls back to
#       all-PRs mode instead of exiting having evicted for nothing
#   w7. both sweep workflows delegate enumeration to the shared script's
#       all-PRs mode — no duplicated open-PR listing in workflow YAML; the
#       script is the single source of truth for it
#
# The live copies are legitimately ADAPTED from the templates (script path,
# trusted reviewer names, dropped triggers), so this test pins the shared
# routing invariants rather than byte equality. The live-copy half runs only
# in the vstack repo layout; vendored consumer copies check the templates.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "$TEST_DIR/.." && pwd)"
TEMPLATES="$SKILL_ROOT/templates"

PASS=0
FAIL=0

assert_grep() {
  local file="$1" pattern="$2" name="$3"
  if grep -qF -- "$pattern" "$file"; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        missing in %s: %s\n' "$name" "$file" "$pattern"
  fi
}

assert_not_grep() {
  local file="$1" pattern="$2" name="$3"
  if grep -qF -- "$pattern" "$file"; then
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        must not appear in %s: %s\n' "$name" "$file" "$pattern"
  else
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  fi
}

check_rerun() {
  local file="$1" label="$2"
  assert_grep "$file" 'group: review-gate-writer' "w1[$label]: shared writer group"
  assert_grep "$file" 'cancel-in-progress: false' "w1[$label]: replace, never cancel the executing writer"
  assert_not_grep "$file" "github.event_name != 'status'" "w2[$label]: no job-level status filter (a skipped run still evicts)"
  assert_grep "$file" '"status" ]' "w3[$label]: status-shaped runs are routed by event name"
  assert_grep "$file" 'ALL_OPEN_PRS=1' "w3[$label]: eviction-prone shapes converge all open PRs"
  assert_grep "$file" 'export PR_NUMBER' "w4[$label]: single-PR fast path preserved"
  assert_grep "$file" 'status: {}' "w5[$label]: status trigger declared (self-healing re-trigger)"
}

check_sweep() {
  local file="$1" label="$2"
  assert_grep "$file" 'group: review-gate-writer' "w1[$label]: shared writer group"
  assert_grep "$file" 'cancel-in-progress: false' "w1[$label]: replace, never cancel"
  assert_grep "$file" 'ALL_OPEN_PRS=1' "w7[$label]: sweep delegates to the script's all-PRs mode"
  assert_not_grep "$file" 'pulls?state=open' "w7[$label]: no duplicated enumeration in workflow YAML"
}

echo "=== shipped templates ==="
check_rerun "$TEMPLATES/approval-rerun.yml" "template"
assert_grep "$TEMPLATES/approval-rerun.yml" 'github.event.check_run.name ==' "w6[template]: check_run trust guard retained"
assert_grep "$TEMPLATES/approval-rerun.yml" 'github.event.comment.user.login ==' "w6[template]: issue_comment trust guard retained"
assert_grep "$TEMPLATES/approval-rerun.yml" 'converging all open PRs instead' "w6[template]: no-open-PR check_run falls back to all-PRs mode"
check_sweep "$TEMPLATES/approval-sweep.yml" "template"

echo "=== shared script owns the enumeration ==="
assert_grep "$SKILL_ROOT/scripts/approval-refire.sh" 'pulls?state=open' "w7[script]: open-PR enumeration lives in approval-refire.sh"
assert_grep "$SKILL_ROOT/scripts/approval-refire.sh" 'ALL_OPEN_PRS' "w7[script]: all-PRs mode exists"

# Live self-adoption copies: only present in the vstack repo layout.
LIVE_DIR="$(cd "$SKILL_ROOT/../.." && pwd)/.github/workflows"
if [ -f "$LIVE_DIR/approval-rerun.yml" ] && [ -d "$SKILL_ROOT/../../skills/review-gate" ]; then
  echo "=== live self-adoption copies ==="
  check_rerun "$LIVE_DIR/approval-rerun.yml" "live"
  check_sweep "$LIVE_DIR/approval-sweep.yml" "live"
else
  echo "=== live copies not present (vendored layout); templates-only run ==="
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
