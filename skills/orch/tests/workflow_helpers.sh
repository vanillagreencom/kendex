#!/usr/bin/env bash
# Contract tests for the orch runtime helpers and the structural guarantees the
# workflows depend on.
#
# This suite pins BEHAVIOR and CROSS-FILE CONTRACTS, never wording: helper
# outputs, the two ordering contracts a gated repo would deadlock without, the
# round-closure mechanics every dev delegation must carry, the frozen CLI the
# reviewer skill calls, and reference integrity across the skill. Prose is free
# to be rewritten; a broken contract fails here.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SKILL_DIR/../.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }

assert_eq() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" == "$want" ]]; then
    pass "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$name" "$want" "$got"
  fi
}

assert_file_contains() {
  local file="$1" pattern="$2" name="$3"
  if grep -Fq -- "$pattern" "$file"; then pass "$name"; else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        missing pattern: %s\n        file: %s\n' "$name" "$pattern" "$file"
  fi
}

orch_docs() {
  printf '%s\n' "$SKILL_DIR/SKILL.md" "$SKILL_DIR/README.md" "$SKILL_DIR/DEVELOPMENT.md"
  find "$SKILL_DIR/workflows" "$SKILL_DIR/references" "$SKILL_DIR/schemas" -type f -name '*.md'
}

echo "=== orch helper behavior ==="

state_dir="$TMP_ROOT/state"
WS="$SKILL_DIR/scripts/workflow-state"
ORCH_STATE_DIR="$state_dir" "$WS" init issue-353 --worktree "$REPO_ROOT" --branch issue-353 >/dev/null

exists_json="$(ORCH_STATE_DIR="$state_dir" "$WS" exists --json issue-353)"
assert_eq "$(jq -r '.exists' <<<"$exists_json")" "true" "workflow-state exists --json reports existing state"
assert_eq "$(jq -r '.issue_id' <<<"$exists_json")" "issue-353" "workflow-state exists --json includes issue id"
missing_json="$(ORCH_STATE_DIR="$state_dir" "$WS" exists --json issue-404)"
assert_eq "$(jq -r '.exists' <<<"$missing_json")" "false" "workflow-state exists --json reports missing state"

# Round-id identity: the token is the ONLY thing binding an artifact to its
# delegation, so rapid consecutive mints must all differ. A regression to a
# non-injective form (e.g. concatenated $RANDOM$RANDOM) is caught here.
rid1="$(ORCH_STATE_DIR="$state_dir" "$WS" new-round-id issue-353 dev_round_id)"
rid2="$(ORCH_STATE_DIR="$state_dir" "$WS" new-round-id issue-353 dev_round_id)"
stored_rid="$(ORCH_STATE_DIR="$state_dir" "$WS" get issue-353 '.dev_round_id')"
assert_eq "$([[ -n "$rid1" ]] && echo yes)" "yes" "new-round-id prints a non-empty token"
assert_eq "$([[ "$rid1" != "$rid2" ]] && echo uniq)" "uniq" "new-round-id mints a distinct token each call"
assert_eq "$stored_rid" "$rid2" "new-round-id stores the latest token at the field"
assert_eq "$([[ "$rid2" =~ ^[A-Za-z0-9._-]+$ ]] && echo ok)" "ok" "new-round-id token is path-safe"
r_a="$(ORCH_STATE_DIR="$state_dir" "$WS" new-round-id issue-353 dev_round_id)"
r_b="$(ORCH_STATE_DIR="$state_dir" "$WS" new-round-id issue-353 dev_round_id)"
r_c="$(ORCH_STATE_DIR="$state_dir" "$WS" new-round-id issue-353 dev_round_id)"
r_d="$(ORCH_STATE_DIR="$state_dir" "$WS" new-round-id issue-353 dev_round_id)"
assert_eq "$(printf '%s\n' "$r_a" "$r_b" "$r_c" "$r_d" | sort -u | wc -l | tr -d ' ')" "4" \
  "four rapid consecutive mints are all distinct"

assert_eq "$(WORKTREE_DEFAULT_BRANCH=trunk "$SKILL_DIR/scripts/resolve-base-branch" "$REPO_ROOT")" "trunk" \
  "resolve-base-branch honors WORKTREE_DEFAULT_BRANCH"

# A nonexistent path is never laundered into the `main` fallback — it fails
# closed. The fallback still serves a VALID repo whose origin/HEAD is
# unresolvable (covered in tests/resolve-base-branch.sh).
set +e
fallback_branch="$("$SKILL_DIR/scripts/resolve-base-branch" "$TMP_ROOT/not-a-git-repo" 2>/dev/null)"
fallback_code=$?
set -e
assert_eq "$fallback_code" "1" "resolve-base-branch fails closed on a nonexistent path"
assert_eq "$fallback_branch" "" "and prints no base branch for it"

issue_repo="$TMP_ROOT/issue-repo"
git init -q "$issue_repo"
git -C "$issue_repo" checkout -q -b cc-536
GC="$SKILL_DIR/scripts/git-context"
assert_eq "$("$GC" issue-from-branch "$issue_repo")" "CC-536" "git-context uppercases lower-case Linear branch ids"
git -C "$issue_repo" checkout -q --orphan issue-369
assert_eq "$("$GC" issue-from-branch "$issue_repo")" "issue-369" "git-context keeps GitHub issue branch ids lowercase"

# The comment-triage baseline is an RFC-3339 UTC instant compared against
# GitHub timestamps; a locale-shaped or local-zone value would silently
# mis-filter every re-triage pass.
iso_ts="$("$GC" timestamp iso)"
assert_eq "$([[ "$iso_ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] && echo ok)" "ok" \
  "git-context timestamp iso prints an RFC-3339 UTC instant"
assert_eq "$("$GC" timestamp bogus 2>/dev/null; echo $?)" "2" "git-context rejects an unknown timestamp format"

echo
echo "=== ordering contracts ==="

# Review-before-CI, in both places it is load-bearing. An approval-gated repo
# starts CI only once a review verdict exists for the head, so verifying CI
# first deadlocks it or reads an intentionally red gate run as a fix failure.
# Compare section positions rather than asserting any sentence.
submit_workflow="$SKILL_DIR/workflows/submit-pr.md"
gate_line="$(grep -n -m1 '^## 4\. Review Gate' "$submit_workflow" | cut -d: -f1)"
ci_line="$(grep -n -m1 '^## 5\. Verify CI' "$submit_workflow" | cut -d: -f1)"
if [[ -n "$gate_line" && -n "$ci_line" && "$gate_line" -lt "$ci_line" ]]; then
  pass "submit-pr orders the review gate (§ 4) before CI verify (§ 5)"
else
  fail "submit-pr must order the review gate before CI verify (got gate=$gate_line ci=$ci_line)"
fi

ci_fix_workflow="$SKILL_DIR/workflows/ci-fix.md"
ci_fix_gate="$(grep -n -m1 -F 'approval-wait [PR_NUMBER] 15 300 --json --mode [GATE_MODE]' "$ci_fix_workflow" | cut -d: -f1)"
ci_fix_wait="$(grep -n -m1 -F 'scripts/ci-wait [PR_NUMBER]' "$ci_fix_workflow" | cut -d: -f1)"
if [[ -n "$ci_fix_gate" && -n "$ci_fix_wait" && "$ci_fix_gate" -lt "$ci_fix_wait" ]]; then
  pass "ci-fix re-confirms the review gate before waiting on CI"
else
  fail "ci-fix must re-confirm the review gate before ci-wait (got gate=$ci_fix_gate wait=$ci_fix_wait)"
fi

# Post-merge base sync: `merge --ff-only` advances whatever branch the target
# checkout has on HEAD, so a main checkout sitting on a foreign branch
# fast-forwards THAT branch, exits 0, and leaves the base where it was. The
# routing that makes ownership explicit is the whole fix, and it is prose — it
# has no script to fail loudly when it is dropped.
merge_workflow="$SKILL_DIR/workflows/merge-pr.md"
assert_file_contains "$merge_workflow" 'rev-parse --abbrev-ref HEAD' \
  "merge-pr resolves which checkout owns the base branch before advancing it"
assert_file_contains "$merge_workflow" 'refs/remotes/origin/[BASE_BRANCH]:refs/heads/[BASE_BRANCH]' \
  "merge-pr keeps the by-name fetch refspec route for a foreign-HEAD checkout"
assert_file_contains "$merge_workflow" 'The `Base sync` row is never omitted' \
  "merge-pr never omits the Base sync row, so a stale base cannot pass unreported"

# A push that rebases rewrites every stored fix SHA. Without reconciliation the
# PR body cites commits that no longer exist.
assert_file_contains "$submit_workflow" 'Rebase-map reconciliation (required)' \
  "submit-pr keeps the rebase-map reconciliation step"

# The lease is what stops two sessions working the same tree.
assert_file_contains "$SKILL_DIR/workflows/start-worktree.md" \
  'worktree-session-guard claim [WORKTREE_PATH] --owner [ISSUE_ID]' \
  "start-worktree keeps the session-guard claim step"

echo
echo "=== round-closure contract ==="

# Every workflow that delegates a dev round mints a fresh round token. That
# mint is the fail-closed guarantee on its own: a previous round's receipt
# carries the previous token, so it can never satisfy this round — including on
# the ci-fix path, whose agent writes no artifact at all.
for wf in dev-start dev-fix review-pr-comments ci-fix; do
  doc="$SKILL_DIR/workflows/$wf.md"
  assert_file_contains "$doc" 'new-round-id [ISSUE_ID] dev_round_id' "$wf mints a fresh round id before delegating"
done

# Every path that delegates a writer into the worktree takes possession first.
# The round token alone binds an artifact to its delegation; it does not stop a
# second session editing the same tree underneath the round.
for wf in dev-start dev-fix review-pr-comments ci-fix; do
  doc="$SKILL_DIR/workflows/$wf.md"
  assert_file_contains "$doc" 'worktree-claim --worktree [WORKTREE_PATH] --issue [ISSUE_ID]' \
    "$wf claims the worktree before delegating"
done

# The lease generation cannot separate two orchestrators that read the same
# stored token, so the always-loaded docs must not promise that it refuses any
# second writer — the script's own header carries the real limit.
for phrase in 'exit 75 refuses a second writer' 'rather than adding a second writer'; do
  if grep -Fq -- "$phrase" "$SKILL_DIR/SKILL.md"; then
    fail "SKILL.md promises more exclusion than worktree-claim delivers: $phrase"
  else
    pass "SKILL.md does not over-claim the possession gate: $phrase"
  fi
done
# Paired with the absence checks: deleting the rows entirely would satisfy them
# while losing the contract, so the accurate condition must be present in both
# places that state it.
assert_eq "$(grep -c 'already claimed under a different lease generation' "$SKILL_DIR/SKILL.md")" "2" \
  "SKILL.md states the real refusal condition in both the scripts table and Round Closure"

# The delegated agent re-verifies the same lease, so a delegation that lands in
# a tree another session has taken fails closed instead of clobbering it. The
# orch side must therefore pass the token, and the dev side must check it.
for wf in dev-start dev-fix review-pr-comments ci-fix; do
  doc="$SKILL_DIR/workflows/$wf.md"
  assert_file_contains "$doc" 'Worktree Lease: [WORKTREE_LEASE]' \
    "$wf carries the lease token into the delegation"
done
for wf in dev-implement dev-fix; do
  doc="$REPO_ROOT/skills/dev/workflows/$wf.md"
  assert_file_contains "$doc" \
    'worktree-claim --worktree [WORKTREE_PATH] --issue [ARTIFACT_KEY] --expect-gen [WORKTREE_LEASE]' \
    "dev $wf verifies the delegated lease before touching the worktree"
done
# ci-fix delegates a free-form prompt rather than a dev workflow, so the
# verification has to be a step of that prompt or its agent never runs one.
assert_file_contains "$SKILL_DIR/workflows/ci-fix.md" \
  'worktree-claim --worktree [WORKTREE_PATH] --issue [ISSUE_ID] --expect-gen [WORKTREE_LEASE]' \
  "ci-fix makes lease verification a step of its delegation"

# The three artifact-accepting paths must actually run the round-scoped check;
# accepting on git state alone would take an unfinished round as complete.
for wf in dev-start dev-fix review-pr-comments; do
  doc="$SKILL_DIR/workflows/$wf.md"
  assert_file_contains "$doc" 'dev-artifact-check --worktree [WORKTREE_PATH] --issue [ISSUE_ID] --round-id' \
    "$wf accepts on the round-scoped artifact check"
done

# Fix rounds additionally persist the delegated item set, so a respawned agent
# can recover its items and the acceptance check has an on-disk expected set.
for wf in dev-fix review-pr-comments; do
  doc="$SKILL_DIR/workflows/$wf.md"
  if grep -Fq 'dev-round-write' "$doc" && grep -Fq -- '--expect-items-from-round' "$doc"; then
    pass "$wf persists the delegated item set and checks against it"
  else
    fail "$wf lost the delegated-item-set persistence or its check"
  fi
done

# The gate resolution is implemented once, in approval-wait. A workflow that
# re-derives it from the raw settings keys will drift from the engine switch.
for wf in submit-pr merge-pr ci-fix; do
  doc="$SKILL_DIR/workflows/$wf.md"
  assert_file_contains "$doc" 'approval-wait --resolve-mode' "$wf resolves the gate mode through approval-wait"
  if grep -Fq 'orch-env PR_APPROVAL_GATE' "$doc" || grep -Fq 'orch-env PR_REVIEW_GATE' "$doc"; then
    fail "$wf re-derives the gate mode from settings instead of --resolve-mode"
  else
    pass "$wf does not re-derive the gate mode from settings"
  fi
done

echo
echo "=== frozen cross-skill contracts ==="

# The reviewer skill calls this exact CLI shape. It is frozen: reviewer files
# are owned elsewhere, so a signature change here silently breaks every review.
reviewer_skill="$REPO_ROOT/skills/reviewer/SKILL.md"
if [[ -f "$reviewer_skill" ]]; then
  assert_file_contains "$reviewer_skill" '.agents/skills/orch/scripts/review-artifact-check [WORKTREE_PATH] [AGENT] 0' \
    "reviewer skill calls the frozen review-artifact-check positional contract"
else
  # Skipping on absence would retire the only check on this frozen signature the
  # moment the file is renamed or moved — exactly when it needs asserting.
  fail "reviewer skill not found at $reviewer_skill — the frozen review-artifact-check pin cannot be checked"
fi
for script in review-artifact-check dev-return-write resolve-base-branch ci-wait worktree-claim; do
  if [[ -x "$SKILL_DIR/scripts/$script" ]]; then
    pass "cross-skill dependency scripts/$script exists and is executable"
  else
    fail "cross-skill dependency scripts/$script is missing or not executable"
  fi
done

echo
echo "=== reference integrity ==="

# Every orch asset an orch doc names must exist. This replaces dozens of
# individual prose pins: it catches a deleted script, a renamed workflow, and a
# typo'd reference, while leaving the surrounding wording free.
SKILLS_ROOT="$(cd "$SKILL_DIR/.." && pwd)"

# Resolve a cited asset to a path, or print nothing for a form this check does
# not own (an unrecognized shape must not be reported as broken).
resolve_ref() {
  case "$1" in
    .agents/skills/*)          printf '%s/%s' "$SKILLS_ROOT" "${1#.agents/skills/}" ;;
    ../*/workflows/*|../*/schemas/*|../*/references/*)
                               printf '%s/%s' "$SKILLS_ROOT" "${1#../}" ;;
    ../workflows/*|../references/*|../schemas/*)
                               printf '%s/%s' "$SKILL_DIR" "${1#../}" ;;
    workflows/*|references/*|schemas/*)
                               printf '%s/%s' "$SKILL_DIR" "$1" ;;
  esac
}

REF_RE='\.agents/skills/[A-Za-z0-9._-]+/(scripts|workflows|references|schemas|templates)/[A-Za-z0-9._-]+|(\.\./)?([A-Za-z0-9._-]+/)?(workflows|references|schemas)/[A-Za-z0-9._-]+\.md'

# Extraction and resolution are separate steps so the teeth check below can run
# the SAME pipeline over a planted document. Checking resolve_ref on its own
# proved nothing about the regex feeding it.
# grep exits 1 on zero matches, which under `pipefail` would abort the suite
# before the floor assertion below could name the cause.
scan_refs() { printf '%s\0' "$@" | { xargs -0 grep -ohE "$REF_RE" || true; } | sort -u; }

collect_broken() {
  local ref target out=""
  while IFS= read -r ref; do
    [[ -n "$ref" ]] || continue
    target="$(resolve_ref "$ref")"
    [[ -n "$target" ]] || continue
    [[ -e "$target" ]] || out+="$ref"$'\n'
  done
  printf '%s' "$out"
}

ORCH_DOCS=()
while IFS= read -r orch_doc; do ORCH_DOCS+=("$orch_doc"); done < <(orch_docs)
refs="$(scan_refs "${ORCH_DOCS[@]}")"
ref_count="$(grep -c . <<<"$refs" || true)"
broken="$(collect_broken <<<"$refs")"

if [[ -z "$broken" ]]; then
  pass "every orch script/workflow/reference/schema named in orch docs exists"
else
  fail "orch docs name assets that do not exist:"
  printf '%s' "$broken" | sed 's/^/          /'
fi

# A pattern that stops matching turns the check above into an unconditional
# pass. The floor is deliberately far below the current count (62) so ordinary
# doc edits never trip it, while a broken pattern — which drops to near zero —
# does.
if (( ref_count >= 40 )); then
  pass "the reference scan extracted $ref_count cited assets (floor 40)"
else
  fail "the reference scan extracted only $ref_count cited assets (floor 40) — the extraction pattern matches almost nothing, so the integrity check above is vacuous"
fi

# Teeth: plant a document citing an asset that does not exist, append it to the
# scanned set, and require the pipeline to surface it. This exercises the
# extraction regex, resolve_ref, and the existence test together.
control_ref="workflows/definitely-not-a-real-workflow.md"
control_doc="$TMP_ROOT/control-ref-doc.md"
printf 'Run `%s` to continue.\n' "$control_ref" >"$control_doc"
if [[ ! -e "$SKILL_DIR/$control_ref" ]]; then
  pass "planted control: the nonexistent asset used by the teeth check is absent"
else
  fail "planted control asset unexpectedly exists"
fi
control_broken="$(scan_refs "${ORCH_DOCS[@]}" "$control_doc" | collect_broken)"
if grep -Fqx "$control_ref" <<<"$control_broken"; then
  pass "the reference pipeline reports a planted broken reference (teeth)"
else
  fail "the reference pipeline MISSED a planted broken reference (no teeth)"
fi

echo
echo "=== retired assets stay retired ==="

# Assets removed in the rewrite must leave no callers behind — a dangling
# invocation is a runtime failure in a workflow no test executes.
for retired in session-init parallel-groups review-init review-risk refix-route \
               local-review-budget list-review-agents tracker-for-issue codex-app-agent-preflight; do
  if [[ -e "$SKILL_DIR/scripts/$retired" ]]; then
    fail "retired script scripts/$retired is back on disk"
  elif orch_docs | tr '\n' '\0' | xargs -0 grep -Fq "scripts/$retired" 2>/dev/null; then
    fail "orch docs still invoke the retired scripts/$retired"
  else
    pass "retired scripts/$retired has no callers in orch docs"
  fi
done

for retired in initialize parallel-check agent-sequencing recommendation-bias fix-reconcile; do
  if [[ -e "$SKILL_DIR/workflows/$retired.md" ]]; then
    fail "retired workflows/$retired.md is back on disk"
  elif orch_docs | tr '\n' '\0' | xargs -0 grep -Fq "workflows/$retired.md" 2>/dev/null; then
    fail "orch docs still route to the retired workflows/$retired.md"
  else
    pass "retired workflows/$retired.md has no callers in orch docs"
  fi
done

# The retired bot-specific waiter and its signal-parsing model must not return:
# gating on a bot's own prose couples the merge path to each bot's dialect.
for doc in $(orch_docs); do
  if grep -Fq 'bot-review-wait' "$doc"; then
    fail "$(basename "$doc") references the retired bot-review-wait"
  fi
done
pass "no orch doc references the retired bot-review-wait"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
