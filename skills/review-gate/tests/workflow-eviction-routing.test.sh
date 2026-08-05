#!/usr/bin/env bash
# Pins the eviction-safe event routing of the review-gate writer workflows
# (#1039). Both rerun workflows (shipped template + vstack's live
# self-adoption copy) claim the repo-wide `review-gate-writer` concurrency
# group at the JOB level — job concurrency is claimed only after the
# job-level `if:` evaluates, so a guard-skipped run never touches the
# writer slot. With cancel-in-progress:false GitHub keeps ONE pending run
# per group and REPLACES it, so an arriving EXECUTING run EVICTS whatever
# writer was pending. The invariants pinned here make that replacement
# lossless:
#
#   w1. every writer workflow claims the single shared group at JOB level
#       with cancel-in-progress: false (the out-of-order-writer race
#       guard); a workflow-level group would let guard-skipped runs evict
#   w2. the `status` arm filters on STATE only (success — clean-analysis
#       evidence is only ever a `success` status; pending/failure converge
#       nothing) and never on CONTEXT NAME (names are repo-specific ADAPT
#       values; a list that misses a reviewer's context strands that
#       reviewer's clean path — the #1039 stuck gate). With the group at
#       job level the filter is priced on API cost, not eviction.
#   w3. EVERY executing run routes to ALL_OPEN_PRS=1 (sweep-style full
#       convergence: surviving in the slot subsumes whatever was evicted).
#       No single-PR fast path exists: the workflows run on GITHUB_TOKEN,
#       and GitHub suppresses workflow runs for token-authored events, so
#       the gate's own posts can never re-trigger a healing pass — the run
#       that evicted a writer must do everything itself. No invariant here
#       may depend on token-authored recursion.
#   w5. the `status` trigger stays declared — legacy-status reviewer
#       evidence has no other re-fire signal
#   w6. the scaffold keeps its check_run / issue_comment trust guards
#       (volume control; a guard-skipped run claims no slot and evicts
#       nothing, so the guards cost only run starts)
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

# Extract the rerun job's `if:` condition — single-line (`if: expr`) or
# block-scalar (`if: >-` + indented lines) form — with comments stripped.
# The w2 terms are asserted against THIS text only: a comment or another
# job mentioning the success term must not satisfy the check, and any
# `github.event.context` reference in the condition (equality OR
# contains()) must fail it.
rerun_job_if() {
  local file="$1"
  awk '
    /^[[:space:]]*#/ { next }
    /^  rerun:[[:space:]]*$/ { injob = 1; next }
    injob && /^  [^[:space:]]/ { injob = 0 }
    injob && /^    if:/ {
      line = $0
      sub(/^    if:[[:space:]]*/, "", line)
      sub(/[[:space:]]#.*$/, "", line)
      if (line !~ /^(>-?|\|-?)?[[:space:]]*$/) print line
      inif = 1; next
    }
    inif && /^      / { line = $0; sub(/[[:space:]]#.*$/, "", line); print line; next }
    inif { inif = 0 }
  ' "$file"
}

check_rerun() {
  local file="$1" label="$2"
  assert_grep "$file" 'group: review-gate-writer' "w1[$label]: shared writer group"
  assert_grep "$file" 'cancel-in-progress: false' "w1[$label]: replace, never cancel the executing writer"
  assert_job_level_group "$file" "$label" "rerun"
  # A guard-skipped run never claims the job-level writer group, so status
  # terms are priced on API cost, not eviction. The generic success-state
  # term is REQUIRED (pending/failure statuses converge nothing and would
  # act before a verdict exists); a CONTEXT-NAME term is FORBIDDEN (names
  # are repo-specific ADAPT values, and a list that misses a reviewer's
  # context strands that reviewer's clean path — the #1039 stuck gate).
  # Both terms are checked inside the rerun job's own if: condition.
  local rerun_if
  rerun_if="$(rerun_job_if "$file")"
  if [ -z "$rerun_if" ]; then
    FAIL=$((FAIL + 1))
    printf '  FAIL  w2[%s]: rerun job has no if: condition\n' "$label"
  else
    if printf '%s\n' "$rerun_if" | grep -qF "github.event.state == 'success'"; then
      PASS=$((PASS + 1))
      printf '  ok    w2[%s]: rerun if: filters status arm to success states\n' "$label"
    else
      FAIL=$((FAIL + 1))
      printf '  FAIL  w2[%s]: rerun if: missing the success-state status term\n' "$label"
    fi
    if printf '%s\n' "$rerun_if" | grep -q 'github\.event\.context'; then
      FAIL=$((FAIL + 1))
      printf '  FAIL  w2[%s]: rerun if: references github.event.context — no context-name filter on the status arm (#1039)\n' "$label"
    else
      PASS=$((PASS + 1))
      printf '  ok    w2[%s]: no context-name reference in the rerun if: (#1039)\n' "$label"
    fi
  fi
  assert_grep "$file" 'export ALL_OPEN_PRS=1' "w3[$label]: every executing run converges all open PRs"
  assert_not_grep "$file" 'GITHUB_EVENT_NAME' "w3[$label]: no event-shape routing — every executing run takes the all-PRs path (the bootstrap fallback is the only PR-scoped branch)"
  assert_not_grep "$file" 'trailing all-PRs pass' "w3[$label]: no comment may claim a self-triggered trailing pass"
  assert_grep "$file" 'suppresses' "w3[$label]: comments state the token-authored suppression rule"
  assert_grep "$file" 'status: {}' "w5[$label]: status trigger declared (legacy-status evidence re-fire)"
}

# Scoped exactly like rerun_job_if above: track membership in the NAMED
# job's own mapping only, so a `group: review-gate-writer` that sits under a
# sibling job (same file, same indentation shape) cannot satisfy the check.
# Returns success iff the group is inside a `concurrency:` block that is
# itself a direct field of that job (not a different job, not a nested step).
job_level_group_present() {
  local file="$1" job="$2"
  awk -v job="$job" '
    /^[[:space:]]*(#|$)/ { next }
    { match($0, /[^[:space:]]/); ind = RSTART - 1 }
    $0 ~ ("^  " job ":[[:space:]]*$") { injob = 1; next }
    injob && ind <= 2 { injob = 0 }
    injob && inblk && ind <= cind { inblk = 0 }
    injob && inblk && /^[[:space:]]*group:[[:space:]]*review-gate-writer[[:space:]]*$/ { found = 1 }
    injob && /^[[:space:]]+concurrency:[[:space:]]*$/ { inblk = 1; cind = ind }
    END { exit !found }
  ' "$file"
}

# The writer group must be claimed at JOB level, and specifically inside the
# WRITER job itself: job concurrency is claimed only after the job-level
# `if:` evaluates, so a trust-guard-skipped run never evicts a pending
# writer. A top-level group would re-open that hole — and so would a
# job-level group that sits on some OTHER job in the same file, since that
# job's concurrency claim has nothing to do with this workflow's guarded
# run.
assert_job_level_group() {
  local file="$1" label="$2" job="$3"
  if grep -q '^concurrency:' "$file"; then
    FAIL=$((FAIL + 1))
    printf '  FAIL  w1[%s]: workflow-level concurrency block present (must sit at JOB level)\n' "$label"
  elif ! job_level_group_present "$file" "$job"; then
    FAIL=$((FAIL + 1))
    printf '  FAIL  w1[%s]: the review-gate-writer group is not inside the %s job'"'"'s own concurrency block\n' "$label" "$job"
  else
    PASS=$((PASS + 1))
    printf '  ok    w1[%s]: concurrency group sits at job level\n' "$label"
  fi
}

check_sweep() {
  local file="$1" label="$2"
  assert_grep "$file" 'group: review-gate-writer' "w1[$label]: shared writer group"
  assert_grep "$file" 'cancel-in-progress: false' "w1[$label]: replace, never cancel"
  assert_job_level_group "$file" "$label" "sweep"
  assert_grep "$file" 'ALL_OPEN_PRS=1' "w7[$label]: sweep delegates to the script's all-PRs mode"
  assert_not_grep "$file" 'pulls?state=open' "w7[$label]: no duplicated enumeration in workflow YAML"
}

echo "=== shipped templates ==="
check_rerun "$TEMPLATES/approval-rerun.yml" "template"
assert_grep "$TEMPLATES/approval-rerun.yml" 'github.event.check_run.name ==' "w6[template]: check_run trust guard retained"
assert_grep "$TEMPLATES/approval-rerun.yml" 'github.event.comment.user.login ==' "w6[template]: issue_comment trust guard retained"
assert_not_grep "$TEMPLATES/approval-rerun.yml" 'converging all open PRs instead' "w6[template]: no residual single-PR resolution branches"
check_sweep "$TEMPLATES/approval-sweep.yml" "template"

echo "=== w1 must reject a sibling job's concurrency block (regression teeth) ==="
# Move the rerun job's concurrency block to a fabricated sibling `decoy:`
# job in an otherwise-untouched copy of the template. The old scan (any
# indented `group: review-gate-writer` anywhere in the file) passed this;
# job_level_group_present must reject it because the group no longer
# belongs to the `rerun` job's own mapping.
SIBLING_FIXTURE="$(mktemp)"
awk '
  /^  rerun:[[:space:]]*$/ {
    print
    print "  decoy:"
    print "    concurrency:"
    print "      group: review-gate-writer"
    print "      cancel-in-progress: false"
    next
  }
  /^    concurrency:[[:space:]]*$/ { skip = 1; next }
  skip && /^      / { next }
  { skip = 0 }
  { print }
' "$TEMPLATES/approval-rerun.yml" > "$SIBLING_FIXTURE"

if job_level_group_present "$SIBLING_FIXTURE" "rerun"; then
  FAIL=$((FAIL + 1))
  printf '  FAIL  w1[negative]: sibling job'"'"'s group must not satisfy the rerun job'"'"'s own check\n'
else
  PASS=$((PASS + 1))
  printf '  ok    w1[negative]: sibling-job concurrency group correctly rejected\n'
fi
if job_level_group_present "$SIBLING_FIXTURE" "decoy"; then
  PASS=$((PASS + 1))
  printf '  ok    w1[negative]: sanity check — the decoy job'"'"'s own group is still detected\n'
else
  FAIL=$((FAIL + 1))
  printf '  FAIL  w1[negative]: sanity check failed — job_level_group_present missed a group inside its own job\n'
fi
rm -f "$SIBLING_FIXTURE"

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
