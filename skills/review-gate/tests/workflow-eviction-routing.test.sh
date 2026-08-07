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
# The `concurrency:` key must be a DIRECT field of the job (exactly one
# indent level below the job name) — a nested mapping under env:/steps: is
# not job concurrency and GitHub would not serialize on it — and both the
# group and cancel-in-progress: false must sit as its direct children.
# True only when the job carries exactly ONE direct concurrency block, that
# block carries exactly ONE group: and ONE cancel-in-progress: key, and both
# hold the expected values. Separate per-property scans were satisfiable by
# different duplicate concurrency: mappings in the same job (vstack#1088),
# and first-match-wins scans blessed a later-wins duplicate KEY inside the
# sole block — group: review-gate-writer followed by group: other — which
# GitHub rejects or resolves to the unsafe final value (vstack#1090). Every
# key occurrence is counted; duplicates of either key fail regardless of
# value order.
job_level_group_present() {
  local file="$1" job="$2"
  awk -v job="$job" '
    BEGIN {
      # YAML keys may be quoted ("group": / '"'"'group'"'"':) and still mean the
      # same key — quoted duplicates must count too (vstack#1092). Build the
      # optional-quote atom dynamically so this single-quoted program never
      # needs a literal apostrophe in a regex constant.
      q = sprintf("%c", 39)
      Q = "[\"" q "]?"
      conc_re   = "^[[:space:]]*" Q "concurrency" Q ":[[:space:]]*$"
      group_re  = "^[[:space:]]*" Q "group" Q ":"
      group_ok  = "^[[:space:]]*" Q "group" Q ":[[:space:]]*review-gate-writer[[:space:]]*$"
      cancel_re = "^[[:space:]]*" Q "cancel-in-progress" Q ":"
      cancel_ok = "^[[:space:]]*" Q "cancel-in-progress" Q ":[[:space:]]*false[[:space:]]*$"
    }
    /^[[:space:]]*(#|$)/ { next }
    { match($0, /[^[:space:]]/); ind = RSTART - 1 }
    $0 ~ ("^  " job ":[[:space:]]*$") { injob = 1; next }
    injob && ind <= 2 { injob = 0 }
    injob && inblk && ind <= 4 { inblk = 0 }
    injob && inblk && ind == 6 && $0 ~ group_re { gk++; if ($0 ~ group_ok) g = 1 }
    injob && inblk && ind == 6 && $0 ~ cancel_re { ck++; if ($0 ~ cancel_ok) c = 1 }
    injob && ind == 4 && $0 ~ conc_re { blocks++; inblk = 1; g = 0; c = 0; gk = 0; ck = 0 }
    END { exit !(blocks == 1 && gk == 1 && ck == 1 && g && c) }
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
    printf '  FAIL  w1[%s]: the %s job needs exactly one direct concurrency block carrying both group: review-gate-writer and cancel-in-progress: false\n' "$label" "$job"
  else
    PASS=$((PASS + 1))
    printf '  ok    w1[%s]: concurrency group + cancel-in-progress sit on the %s job itself\n' "$label" "$job"
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

echo "=== w1 must reject DUPLICATE concurrency blocks split across properties ==="
# Replace the rerun job's single concurrency block with two duplicate
# mappings — the first carrying only the group, a later one carrying only
# cancel-in-progress. GitHub cannot combine these (duplicate key: invalid
# YAML, or later-wins drops the group), so the sole-block rule must reject
# what the old per-property scans each accepted (vstack#1088).
DUP_FIXTURE="$(mktemp)"
awk '
  /^    concurrency:[[:space:]]*$/ {
    print "    concurrency:"
    print "      group: review-gate-writer"
    print "    concurrency:"
    print "      cancel-in-progress: false"
    skip = 1; next
  }
  skip && /^      / { next }
  { skip = 0 }
  { print }
' "$TEMPLATES/approval-rerun.yml" > "$DUP_FIXTURE"

if job_level_group_present "$DUP_FIXTURE" "rerun"; then
  FAIL=$((FAIL + 1))
  printf '  FAIL  w1[negative]: duplicate concurrency blocks split across group/cancel must not pass the sole-block rule\n'
else
  PASS=$((PASS + 1))
  printf '  ok    w1[negative]: duplicate split concurrency blocks correctly rejected\n'
fi
rm -f "$DUP_FIXTURE"

echo "=== w1 must reject later-wins duplicate keys INSIDE the sole block ==="
# One concurrency block, but the safe group is followed by a duplicate
# group: key with another value — GitHub rejects the duplicate key or
# later-wins replaces the writer group. First-match-wins scans blessed
# this; the exactly-one-key-per-property rule must not (vstack#1090).
INBLOCK_DUP_FIXTURE="$(mktemp)"
awk '
  /^    concurrency:[[:space:]]*$/ {
    print "    concurrency:"
    print "      group: review-gate-writer"
    print "      group: other-group"
    print "      cancel-in-progress: false"
    skip = 1; next
  }
  skip && /^      / { next }
  { skip = 0 }
  { print }
' "$TEMPLATES/approval-rerun.yml" > "$INBLOCK_DUP_FIXTURE"

if job_level_group_present "$INBLOCK_DUP_FIXTURE" "rerun"; then
  FAIL=$((FAIL + 1))
  printf '  FAIL  w1[negative]: a later-wins duplicate group: key inside the sole block must not pass\n'
else
  PASS=$((PASS + 1))
  printf '  ok    w1[negative]: in-block duplicate group: key correctly rejected\n'
fi
rm -f "$INBLOCK_DUP_FIXTURE"

echo "=== w1 must reject QUOTED duplicate keys inside the sole block ==="
# Same later-wins hazard with YAML quoted keys: "group": names the same key
# as group:, so a quoted duplicate must increment the same counter
# (vstack#1092). Fixture: safe bare pair plus a quoted duplicate group.
QUOTED_DUP_FIXTURE="$(mktemp)"
awk '
  /^    concurrency:[[:space:]]*$/ {
    print "    concurrency:"
    print "      group: review-gate-writer"
    print "      \"group\": other-group"
    print "      cancel-in-progress: false"
    skip = 1; next
  }
  skip && /^      / { next }
  { skip = 0 }
  { print }
' "$TEMPLATES/approval-rerun.yml" > "$QUOTED_DUP_FIXTURE"

if job_level_group_present "$QUOTED_DUP_FIXTURE" "rerun"; then
  FAIL=$((FAIL + 1))
  printf '  FAIL  w1[negative]: a QUOTED duplicate "group": key inside the sole block must not pass\n'
else
  PASS=$((PASS + 1))
  printf '  ok    w1[negative]: quoted duplicate group key correctly rejected\n'
fi

# Sanity: an all-quoted but otherwise-correct block still passes (quoting
# alone is not a failure — only duplication or wrong values are).
awk '
  /^    concurrency:[[:space:]]*$/ {
    print "    \"concurrency\":"
    print "      \"group\": review-gate-writer"
    print "      \"cancel-in-progress\": false"
    skip = 1; next
  }
  skip && /^      / { next }
  { skip = 0 }
  { print }
' "$TEMPLATES/approval-rerun.yml" > "$QUOTED_DUP_FIXTURE"

if job_level_group_present "$QUOTED_DUP_FIXTURE" "rerun"; then
  PASS=$((PASS + 1))
  printf '  ok    w1[negative]: sanity check — fully quoted correct block still detected\n'
else
  FAIL=$((FAIL + 1))
  printf '  FAIL  w1[negative]: sanity check failed — quoted correct block must still pass\n'
fi
rm -f "$QUOTED_DUP_FIXTURE"

echo "=== w1 must reject a NESTED concurrency mapping inside the writer job ==="
# A concurrency mapping nested under a step/env inside the rerun job is not
# job concurrency — GitHub would not serialize on it — so the direct-field
# rule must reject it even though it sits inside the right job's mapping.
NESTED_FIXTURE="$(mktemp)"
awk '
  /^    concurrency:[[:space:]]*$/ { skip = 1; next }
  skip && /^      / { next }
  { skip = 0 }
  /^    runs-on:/ {
    print "    env:"
    print "      concurrency:"
    print "        group: review-gate-writer"
    print "        cancel-in-progress: false"
  }
  { print }
' "$TEMPLATES/approval-rerun.yml" > "$NESTED_FIXTURE"

if job_level_group_present "$NESTED_FIXTURE" "rerun"; then
  FAIL=$((FAIL + 1))
  printf '  FAIL  w1[negative]: a concurrency mapping nested under env: must not satisfy the direct-field rule\n'
else
  PASS=$((PASS + 1))
  printf '  ok    w1[negative]: nested (non-job-field) concurrency mapping correctly rejected\n'
fi
rm -f "$NESTED_FIXTURE"

echo "=== shared script owns the enumeration ==="
assert_grep "$SKILL_ROOT/scripts/approval-refire.sh" 'pulls?state=open' "w7[script]: open-PR enumeration lives in approval-refire.sh"
assert_grep "$SKILL_ROOT/scripts/approval-refire.sh" 'ALL_OPEN_PRS' "w7[script]: all-PRs mode exists"

# Live self-adoption copies: only present in the vstack repo layout —
# vendored consumers keep their skill under .agents/skills/, so the
# ../../.github/workflows probe resolves outside the repo there and the
# rerun/sweep files are absent.
LIVE_DIR="$(cd "$SKILL_ROOT/../.." && pwd)/.github/workflows"
if [ -f "$LIVE_DIR/approval-rerun.yml" ]; then
  echo "=== live self-adoption copies ==="
  check_rerun "$LIVE_DIR/approval-rerun.yml" "live"
  check_sweep "$LIVE_DIR/approval-sweep.yml" "live"
else
  echo "=== live copies not present (vendored layout); templates-only run ==="
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
