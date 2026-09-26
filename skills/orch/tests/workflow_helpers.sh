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
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SKILL_DIR/../.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# shellcheck source=lib/assertions.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/assertions.sh"

# Plants one literal substitution in a copy of a workflow doc and asserts the
# contract PREDICATE, green on the real doc, goes red on the copy. OLD must
# occur on exactly one line, and the copy must differ from the source.
DOC_MUTANT_SEQ=0
assert_doc_mutant_fails() {
  local predicate="$1" source="$2" old="$3" new="$4" label="$5" mutant count
  DOC_MUTANT_SEQ=$((DOC_MUTANT_SEQ + 1))
  mutant="$TMP_ROOT/doc-mutant-$DOC_MUTANT_SEQ.md"
  count="$(grep -Fc -- "$old" "$source" || true)"
  assert_eq "$count" "1" "control: $label has one mutation target"
  if [[ -L "$source" ]]; then
    fail "control: $label mutation source must not be a symlink"
    return 0
  fi
  # Literal, through the environment and index/substr: sub() reads its
  # pattern as a regex, and these rules carry brackets and backticks.
  MUT_OLD="$old" MUT_NEW="$new" awk '
    {
      old = ENVIRON["MUT_OLD"]
      at = index($0, old)
      if (at) { $0 = substr($0, 1, at - 1) ENVIRON["MUT_NEW"] substr($0, at + length(old)) }
      print
    }' "$source" >"$mutant"
  assert_eq "$(cmp -s "$mutant" "$source" && echo same || echo differs)" "differs" \
    "control: the mutant for $label changes the file"
  if "$predicate" "$mutant"; then
    fail "must-fail: $label must fail its contract"
  else
    pass "must-fail: $label fails its contract"
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

ORCH_STATE_DIR="$state_dir" "$WS" init issue-404 --branch issue-404 >/dev/null
stop_comment="$TMP_ROOT/post-pr-stop.md"
assert_eq "$(ORCH_STATE_DIR="$state_dir" "$WS" post-pr-stop record issue-404 review-round-cap review 'one unresolved review thread' "$stop_comment")" "recorded" "post-pr-stop records and renders a named stop"
assert_file_contains "$stop_comment" 'one unresolved review thread' "post-pr-stop renders stored remaining work"
assert_eq "$(ORCH_STATE_DIR="$state_dir" "$WS" post-pr-stop record-if-empty issue-404 merge-gates-unmet merge 'CI pending' "$stop_comment")" "kept" "record-if-empty preserves a precise stop"
assert_eq "$(ORCH_STATE_DIR="$state_dir" "$WS" get issue-404 '.post_pr_stop.name')" "review-round-cap" \
  "record-if-empty keeps the precise stop name"
ORCH_STATE_DIR="$state_dir" "$WS" update issue-404 '.post_pr_stop = null'
assert_eq "$(ORCH_STATE_DIR="$state_dir" "$WS" get issue-404 '.post_pr_stop')" "null" "continuation clears the stop"
ORCH_STATE_DIR="$state_dir" REVIEW_MAX_EXTERNAL_ROUNDS=2 "$WS" head-budget take issue-404 review-wait head-a >/dev/null
assert_eq "$(ORCH_STATE_DIR="$state_dir" REVIEW_MAX_EXTERNAL_ROUNDS=2 "$WS" head-budget take issue-404 review-wait head-a)" "continue 2/2" "review budget increments atomically"
assert_eq "$(ORCH_STATE_DIR="$state_dir" REVIEW_MAX_EXTERNAL_ROUNDS=2 "$WS" head-budget take issue-404 review-wait head-a)" "at-cap 2/2" "review budget persists its cap"
assert_eq "$(ORCH_STATE_DIR="$state_dir" REVIEW_MAX_EXTERNAL_ROUNDS=2 "$WS" head-budget take issue-404 review-wait head-b)" "continue 1/2" \
  "review-wait budget resets on a changed head"
ORCH_STATE_DIR="$state_dir" "$WS" update issue-404 '.post_pr_budgets.review_wait = null'
assert_eq "$(ORCH_STATE_DIR="$state_dir" "$WS" get issue-404 '.post_pr_budgets.review_wait')" "null" "accepted review evidence clears its budget"
ORCH_STATE_DIR="$state_dir" CI_FIX_MAX_CYCLES=1 "$WS" head-budget take issue-404 ci-fix ci-head-a >/dev/null
assert_eq "$(ORCH_STATE_DIR="$state_dir" CI_FIX_MAX_CYCLES=1 "$WS" head-budget take issue-404 ci-fix ci-head-a)" "at-cap 1/1" "ci-fix persists its cap"
# Every ci-fix cycle pushes its fix, so the next take always presents a new head.
# A head-keyed reset here would return continue forever and CI_FIX_MAX_CYCLES
# would bound nothing; the cap must survive the changed head. The two takes below
# are the two cycles of a cap of 2, each on the head its own push produced.
ORCH_STATE_DIR="$state_dir" "$WS" update issue-404 '.post_pr_budgets.ci_fix = null'
assert_eq "$(ORCH_STATE_DIR="$state_dir" CI_FIX_MAX_CYCLES=2 "$WS" head-budget take issue-404 ci-fix ci-head-a)" "continue 1/2" \
  "ci-fix spends its first cycle"
assert_eq "$(ORCH_STATE_DIR="$state_dir" CI_FIX_MAX_CYCLES=2 "$WS" head-budget take issue-404 ci-fix ci-head-b)" "continue 2/2" \
  "ci-fix counts a cycle on the head its own push produced"
assert_eq "$(ORCH_STATE_DIR="$state_dir" CI_FIX_MAX_CYCLES=2 "$WS" head-budget take issue-404 ci-fix ci-head-c)" "at-cap 2/2" \
  "ci-fix reaches its cap across cycles that each push a new head"
ORCH_STATE_DIR="$state_dir" "$WS" update issue-404 '.post_pr_budgets.ci_fix = null'
assert_eq "$(ORCH_STATE_DIR="$state_dir" CI_FIX_MAX_CYCLES=2 "$WS" head-budget take issue-404 ci-fix ci-head-d)" "continue 1/2" \
  "a passing CI run clearing ci_fix is what resets the ci-fix budget"

# Round-id identity: the token is the ONLY thing binding an artifact to its
# delegation, so rapid consecutive mints must all differ. A failure to a
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

# A local key is the state key of work with no issue id and no PR, so rapid
# mints must differ, carry the local- shape branch-size-check reads as naming
# no issue, and leave no state behind: the minting workflow inits its own.
local_state_dir="$TMP_ROOT/local-key-state"
mkdir -p "$local_state_dir"
k_a="$("$WS" --state-dir "$local_state_dir" new-local-key)"
k_b="$("$WS" --state-dir "$local_state_dir" new-local-key)"
assert_eq "$([[ "$k_a" =~ ^local-[0-9]+-[0-9]+-[0-9]+$ ]] && echo ok)" "ok" "new-local-key mints a local-<epoch>-<pid>-<random> key"
assert_eq "$([[ "$k_a" != "$k_b" ]] && echo uniq)" "uniq" "new-local-key mints a distinct key each call"
assert_eq "$(find "$local_state_dir" -type f | wc -l | tr -d ' ')" "0" "new-local-key writes no state"
set +e
local_key_err="$("$WS" new-local-key stray 2>&1 >/dev/null)"
local_key_rc=$?
set -e
assert_eq "$local_key_rc,${local_key_err%%$'\n'*}" "2,workflow-state: unknown-option arg1=stray" \
  "new-local-key refuses an argument, since it takes no key"

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
# One owner of the canonical spelling: a bare id the pattern accepts in either
# case reaches the same answer the branch match does, so a launched brief, a
# mailbox path and a workflow-state key cannot name one item two ways.
assert_eq "$("$GC" issue-canonical cc-536 'cc-[0-9]+')" "CC-536" "git-context canonicalizes a bare id against a lowercase pattern"
canonical_rc=0
"$GC" issue-canonical 12ab 'cc-[0-9]+' >/dev/null 2>"$TMP_ROOT/canonical.err" || canonical_rc=$?
assert_eq "$canonical_rc" "1" "git-context rejects a bare id no case of the pattern matches"
assert_eq "$(sed -n '1p' "$TMP_ROOT/canonical.err")" "git-context: issue-uncanonical id=12ab" \
  "and names the rejected id"

# Every caller composes paths on common-root, so a value relative to the
# directory it was asked about would name somewhere else entirely. Git answers
# `../..` from below a checkout top, and that climb is made from the physical
# directory: through a symlink to a nested one, a logical climb starts at the
# link's own place and lands outside the checkout. The control restores the
# unresolved answer.
deep_repo="$TMP_ROOT/deep-repo"
mkdir -p "$deep_repo/sub/deeper"
git init -q "$deep_repo"
deep_top="$(cd "$deep_repo" && pwd -P)"
assert_eq "$("$GC" common-root "$deep_repo/sub/deeper")" "$deep_top" \
  "git-context resolves a directory below a checkout top to that checkout"
assert_eq "$(cd "$deep_repo/sub/deeper" && "$GC" common-root .)" "$deep_top" \
  "and does the same asked from inside it"
deep_link="$TMP_ROOT/deep-link"
ln -s "$deep_repo/sub/deeper" "$deep_link"
assert_eq "$("$GC" common-root "$deep_link")" "$deep_top" \
  "and resolves a symlink to a nested directory to the checkout it is inside"
relative_gc="$TMP_ROOT/git-context-relative"
sed 's@\*/\.git) (cd -P -- "\$worktree" && cd -P -- "\$(dirname -- "\$git_common_dir")" && pwd -P) ;;@*/.git) dirname "$git_common_dir" ;;@' \
  "$GC" > "$relative_gc"
chmod +x "$relative_gc"
assert_eq "$(cmp -s "$relative_gc" "$GC" && echo same || echo differs)" "differs" \
  "control: the relative mutant really restores the unresolved answer"
assert_eq "$("$relative_gc" common-root "$deep_repo/sub/deeper")" "../.." \
  "control: unresolved, the answer is a path against the caller's own directory"

# The comment-triage baseline is an RFC-3339 UTC instant compared against
# GitHub timestamps; a locale-shaped or local-zone value would silently
# mis-filter every re-triage pass.
iso_ts="$("$GC" timestamp iso)"
assert_eq "$([[ "$iso_ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] && echo ok)" "ok" \
  "git-context timestamp iso prints an RFC-3339 UTC instant"
timestamp_rc=0
"$GC" timestamp bogus >/dev/null 2>"$TMP_ROOT/timestamp.err" || timestamp_rc=$?
assert_eq "$timestamp_rc" "2" "git-context rejects an unknown timestamp format"
assert_eq "$(sed -n '1p' "$TMP_ROOT/timestamp.err")" "git-context: timestamp-format format=bogus" \
  "git-context identifies the rejected format"

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
# fast-forwards THAT branch, exits 0, and leaves the base where it was.
merge_workflow="$SKILL_DIR/workflows/merge-pr.md"
sync_base="$SKILL_DIR/scripts/sync-base"
assert_file_contains "$merge_workflow" 'scripts/sync-base [MAIN_REPO_ROOT]' \
  "merge-pr delegates base synchronization to sync-base"
assert_file_contains "$sync_base" 'worktree list --porcelain' \
  "sync-base resolves which checkout owns the base branch before advancing it"
assert_file_contains "$sync_base" 'refs/remotes/origin/$BASE_BRANCH:refs/heads/$BASE_BRANCH' \
  "sync-base keeps the by-name ref update for an unowned base branch"
assert_file_contains "$merge_workflow" '| Base sync |' \
  "merge-pr never omits the Base sync row, so a stale base cannot pass unreported"

# The lane's terminal condition is the removal, so § 5 reads [WORKTREE_PATH]
# back before § 6 writes the summary. The anchor is that read, not the
# `worktree remove` call: the call has always been § 5's last step, so a
# document with no read of the path satisfies the ordering while leaving the
# lane free to report done at its prompt with its worktree standing. What the
# summary's worktree line then says is not pinned; § 6's own prose carries it.
removal_precedes_summary() { # doc
  local removal summary
  removal="$(grep -n -m1 -F 'ls -d -- "[WORKTREE_PATH]"' "$1" | cut -d: -f1)"
  summary="$(grep -n -m1 -F '## 6. Present Results' "$1" | cut -d: -f1)"
  [[ -n "$removal" && -n "$summary" && "$removal" -lt "$summary" ]]
}
if removal_precedes_summary "$merge_workflow"; then
  pass "merge-pr reads the worktree path back before § 6 writes the summary"
else
  fail "merge-pr must read [WORKTREE_PATH] back before § 6 writes the summary"
fi
# The must-fail control: a copy the summary heading is reachable first in.
summary_first="$TMP_ROOT/merge-pr-summary-first.md"
{ printf '## 6. Present Results\n'; cat "$merge_workflow"; } >"$summary_first"
if removal_precedes_summary "$summary_first"; then
  fail "must-fail: a summary heading above that read has to fail the ordering check"
else
  pass "must-fail: a summary heading above that read fails the ordering check"
fi

# A push that rebases rewrites every stored fix SHA. Without reconciliation the
# PR body cites commits that does not exist; worktree-push owns that remap.
assert_file_contains "$submit_workflow" 'scripts/worktree-push --worktree' \
  "submit-pr pushes through the SHA-reconciling worktree-push wrapper"
start_workflow="$SKILL_DIR/workflows/start-worktree.md"
assert_file_contains "$start_workflow" 'post_pr_stop: .post_pr_stop' \
  "start-worktree reads the final stop into the session summary"
# No check that submit-pr states the unreconciled pre-rebase SHA publication
# ban. That rule lives only in prose and the wrapper pin above carries the
# mechanism instead.

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

# Approval-wait owns gate-mode resolution for workflows that wait on a
# reviewer. The micro route reads its class exemption from review-policy.
#
# Under an ACTIVE class policy the resolver refuses a call with no range, so a
# --resolve-mode call whose endpoints nothing binds is a step that cannot run.
# Every workflow that resolves a mode therefore reads the pull request's own
# endpoints first, in the call below, and every --resolve-mode line it carries
# names both flags.
for wf in submit-pr merge-pr ci-fix; do
  doc="$SKILL_DIR/workflows/$wf.md"
  assert_file_contains "$doc" 'approval-wait --resolve-mode' "$wf resolves the gate mode through approval-wait"
  assert_file_contains "$doc" "gh pr view [PR_NUMBER] --json baseRefOid,headRefOid --jq '[.baseRefOid,.headRefOid]|@tsv'" \
    "$wf binds the endpoints the resolver needs"
  # The invocation spelling carries the script path; the preamble's prose
  # mention of the flag is not a step and is not counted.
  resolve_lines="$(grep -c -- 'scripts/approval-wait --resolve-mode' "$doc" || true)"
  ranged_lines="$(grep -c -- 'scripts/approval-wait --resolve-mode --base ' "$doc" || true)"
  if [ "$resolve_lines" -gt 0 ] && [ "$resolve_lines" -eq "$ranged_lines" ]; then
    pass "$wf passes a range on every one of its $resolve_lines --resolve-mode calls"
  else
    fail "$wf has $resolve_lines --resolve-mode call(s) and $ranged_lines carrying a range"
  fi
  if grep -Fq 'orch-env PR_APPROVAL_GATE' "$doc" || grep -Fq 'orch-env PR_REVIEW_GATE' "$doc"; then
    fail "$wf re-derives the gate mode from settings instead of --resolve-mode"
  else
    pass "$wf does not re-derive the gate mode from settings"
  fi
done

# The merged short-circuit is only a short-circuit while it precedes the reads
# it skips: below them, a resolution that refuses for want of an orphaned head
# stands between a completed merge and its cleanup.
already_merged_line="$(grep -n -F '`[ALREADY_MERGED]=true` skips to step 2' "$merge_workflow" | cut -d: -f1 || true)"
resolve_line="$(grep -n -F 'approval-wait --resolve-mode --base [PREPARED_BASE]' "$merge_workflow" | cut -d: -f1 || true)"
if [[ -n "$already_merged_line" && -n "$resolve_line" && "$already_merged_line" -lt "$resolve_line" ]]; then
  pass "merge-pr sends an already-merged PR to step 2 before it resolves a mode"
else
  fail "merge-pr must short-circuit an already-merged PR above the gate-mode resolution (short-circuit=${already_merged_line:-absent}, resolve=${resolve_line:-absent})"
fi

# A waiver is only pinned while the rows that apply it say which head it was
# resolved for. Both gate rows name the recorded head, and the mode is written
# beside that head in one write, so no future mode can be recorded without one.
submit_workflow="$SKILL_DIR/workflows/submit-pr.md"
pinned_waiver_is_closed() { # submit-doc
  grep -Fq '`exempt` at the live endpoints: neither term applies' "$1" &&
    grep -Fq '`exempt` at the live endpoints, and `off`: not applicable' "$1" &&
    grep -Fq 'workflow-state set [ISSUE_ID] pr_review.head_sha [HEAD_SHA]' "$1" &&
    grep -Fq 'Gates 3 and 4 waive on that fresh answer alone' "$1" &&
    grep -Fq 'The recorded pair says what the last resolution saw and gates nothing' "$1"
}

if pinned_waiver_is_closed "$submit_workflow"; then
  pass "submit-pr waives gates 3 and 4 on a live resolution, not on the recorded pair"
else
  fail "submit-pr must waive gates 3 and 4 on a live resolution, not on the recorded pair"
fi

assert_doc_mutant_fails pinned_waiver_is_closed "$submit_workflow" \
  'The recorded pair says what the last resolution saw and gates nothing' \
  'The recorded pair decides gates 3 and 4.' \
  "a waiver decided from the record"

micro_head_is_pinned() { # merge-doc
  grep -Fq 'A `[MICRO_ENTRY]` run continues only where the mode resolved above is `exempt` AND `[MICRO_HEAD]` equals `[PREPARED_HEAD]`' "$1" &&
    grep -Fq 'Any other answer arms nothing and escapes by micro.md condition 9' "$1"
}

if micro_head_is_pinned "$merge_workflow"; then
  pass "merge-pr continues a micro entry only on a fresh exempt answer at the classified head"
else
  fail "merge-pr must continue a micro entry only on a fresh exempt answer at the classified head"
fi

assert_doc_mutant_fails micro_head_is_pinned "$merge_workflow" \
  'A `[MICRO_ENTRY]` run continues only where the mode resolved above is `exempt` AND `[MICRO_HEAD]` equals `[PREPARED_HEAD]`' \
  'A `[MICRO_ENTRY]` run continues' \
  "a micro entry continued on a stale answer"

micro_workflow="$SKILL_DIR/workflows/micro.md"
micro_policy_is_closed() { # micro-doc
  grep -Fq 'env -u GH_REPO -u GITHUB_REPOSITORY [MAIN_REPO_ROOT]/.agents/skills/github/scripts/github.sh -C [MAIN_REPO_ROOT] pr-view [PR_NUMBER] --json baseRefOid,headRefOid' "$1" &&
    grep -Fq 'review-gate/scripts/review-policy --event pull_request --base [BASE_SHA] --head [HEAD_SHA] --repo [WT_PATH]' "$1" &&
    grep -Fq 'The exact answer `change_class=micro review_evidence=none policy=active` continues.' "$1" &&
    grep -Fq 'independent of the repository'"'"'s `approval` or `review` gate mode' "$1" &&
    grep -Fq 'an inactive policy, an unresolved class, another class, or another evidence policy escapes' "$1" &&
    grep -Fq 'Require a valid readiness object for an open pull request.' "$1" &&
    grep -Fq 'binding `[MICRO_ENTRY]` to `true` and `[MICRO_HEAD]` to `[HEAD_SHA]`.' "$1" &&
    grep -Fq '9. merge-pr.md § 5 step 1 refuses: the mode it resolves over the prepared endpoints is not `exempt`, or `[PREPARED_HEAD]` is not `[MICRO_HEAD]`.' "$1" &&
    ! grep -Fq 'approval-wait --resolve-mode' "$1"
}

if micro_policy_is_closed "$micro_workflow"; then
  pass "micro continues only on its active no-review class policy"
else
  fail "micro must escape when its no-review class policy cannot be proved"
fi

assert_doc_mutant_fails micro_policy_is_closed "$micro_workflow" \
  'The exact answer `change_class=micro review_evidence=none policy=active` continues.' \
  'Any answer carrying `change_class=micro` continues.' \
  "accepting an unresolved evidence policy"

micro_dirty_transfer_is_owned() { # micro-doc
  local route=""
  if ! route=$(awk '
    /^- \*\*From the main checkout at conditions 2 through 4\*\*/ { inside = 1 }
    /^- \*\*From the main checkout at conditions 5 through 8\*\*/ { inside = 0 }
    inside { print }
  ' "$1"); then
    return 1
  fi
  [[ -n "$route" ]] &&
    grep -Fq 'can be dirty' <<<"$route" &&
    grep -Fq 'moves staged, unstaged and untracked changes with the branch' <<<"$route" &&
    grep -Fq 'worktree create [ISSUE_ID] --transfer [BRANCH]' <<<"$route"
}

assert_file_contains "$micro_workflow" 'pr-merge [PR_NUMBER] --check' \
  "micro asks the canonical merge gate to enforce required checks and merge conflicts"

if micro_dirty_transfer_is_owned "$micro_workflow"; then
  pass "micro routes dirty main-checkout escapes 2 through 4 through transfer"
else
  fail "micro must route dirty main-checkout escapes 2 through 4 through transfer"
fi

assert_doc_mutant_fails micro_dirty_transfer_is_owned "$micro_workflow" \
  'the branch is local-only and can be dirty. Transfer it through the worktree owner'"'"'s guarded path, which restores the main checkout to its default branch and moves staged, unstaged and untracked changes with the branch. Run `/orch [BRIEF] [ISSUE_ID]` from the path it prints:' \
  'the branch must be clean. Leave dirty changes in the main checkout and transfer only the branch. Run `/orch [BRIEF] [ISSUE_ID]` from the path it prints:' \
  "leaving dirty edits in main"

# On a hosted fleet the overseer's main-checkout route runs on the control VM,
# which runs none of the toolchain the rest of the route starts: the refusal
# stands between START and STOP, scoped to that route, ahead of the first
# tracker read, handoff resume or route step, so nothing is resumed,
# activated or created first.
refuses_control_host() { # FILE KEY START STOP
  local head=""
  if ! head=$(START="$3" STOP="$4" awk '
    !inside && $0 ~ ENVIRON["START"] { inside = 1; print; next }
    inside && $0 ~ ENVIRON["STOP"] { exit }
    inside { print }
  ' "$1"); then
    return 1
  fi
  [[ -n "$head" ]] &&
    grep -Fxq '**Main checkout only.** Read the lane host before anything else:' <<<"$head" &&
    grep -Fxq '.agents/skills/orch/scripts/lane-host resolve' <<<"$head" &&
    grep -Fq 'Any answer but `local` refuses the run here' <<<"$head" &&
    grep -Fq "\`$2 host=[HOST]\`" <<<"$head" &&
    grep -Fq 'launch the item as a hosted lane through [oversee.md](oversee.md) § 3 Lane directive, Placement' <<<"$head"
}
micro_refuses_control_host() { refuses_control_host "$1" micro-control-host '^## 1\. ' 'linear\.sh|^## 2\.'; } # micro-doc
start_workflow="$SKILL_DIR/workflows/start.md"
# start.md's head runs to its first section, so the refusal precedes § 0's
# handoff resume and its `handoff.resumed_at` stamp.
start_refuses_control_host() { refuses_control_host "$1" start-control-host '^# ' '^## '; } # start-doc

if micro_refuses_control_host "$micro_workflow"; then
  pass "micro refuses the main-checkout route on a resolved remote lane host"
else
  fail "micro must refuse the main-checkout route on a resolved remote lane host"
fi
if start_refuses_control_host "$start_workflow"; then
  pass "start refuses the main-checkout route on a resolved remote lane host"
else
  fail "start must refuse the main-checkout route on a resolved remote lane host"
fi

assert_doc_mutant_fails micro_refuses_control_host "$micro_workflow" \
  'Any answer but `local` refuses the run here, with nothing read, activated or changed;' \
  'Any answer continues the run;' \
  "a micro run continuing on a remote lane host"
assert_doc_mutant_fails start_refuses_control_host "$start_workflow" \
  'Any answer but `local` refuses the run here, with no handoff resumed and nothing read, activated or created;' \
  'Any answer continues the run;' \
  "a start run continuing on a remote lane host"

# A guard sees only the top-level call, so every script that reads a listed
# `setting` through orch-env and runs it needs its own `path` line in the
# control-host list. The readers are derived from the scripts, never listed.
toolchain_conf="$SKILL_DIR/references/control-host-toolchain.conf"
SETTING_RUNNERS_FOUND=0
setting_runners_listed() { # CONF
  local keys="" key runners="" runner rc=0 listed=0
  SETTING_RUNNERS_FOUND=0
  keys="$(awk '$1 == "setting" { print $2 }' "$1")" || return 2
  for key in $keys; do
    rc=0
    runners="$(grep -rlE "orch-env\"?[[:space:]]+$key([^A-Za-z0-9_]|\$)" "$REPO_ROOT"/skills/*/scripts)" || rc=$?
    [[ "$rc" -le 1 ]] || return 2
    for runner in $runners; do
      SETTING_RUNNERS_FOUND=$((SETTING_RUNNERS_FOUND + 1))
      grep -Fxq "path .agents/${runner#"$REPO_ROOT"/}" "$1" || listed=1
    done
  done
  return "$listed"
}

if setting_runners_listed "$toolchain_conf"; then
  pass "every script running a listed setting has its own path line"
else
  fail "every script running a listed setting must have its own path line"
fi
if [[ "$SETTING_RUNNERS_FOUND" -ge 2 ]]; then
  pass "the setting-runner scan finds the orch-env readers"
else
  fail "the setting-runner scan found $SETTING_RUNNERS_FOUND orch-env readers (floor 2): its extraction is broken"
fi
assert_doc_mutant_fails setting_runners_listed "$toolchain_conf" \
  'path .agents/skills/orch/scripts/post-merge' \
  '# post-merge dropped' \
  "a listed setting whose runner has no path line"

echo
echo "=== frozen cross-skill contracts ==="

# The reviewer skill calls this exact CLI shape. It is frozen: reviewer files
# are owned elsewhere, so a signature change here silently breaks every review.
reviewer_skill="$REPO_ROOT/skills/reviewer/SKILL.md"
if [[ -f "$reviewer_skill" ]]; then
  assert_file_contains "$reviewer_skill" '.agents/skills/orch/scripts/review-artifact-check --file [ARTIFACT_PATH] [WORKTREE_PATH]' \
    "reviewer skill self-validates through the frozen review-artifact-check --file contract"
else
  # Skipping on absence would retire the only check on this frozen signature the
  # moment the file is renamed or moved — exactly when it needs asserting.
  fail "reviewer skill not found at $reviewer_skill — the frozen review-artifact-check pin cannot be checked"
fi
for script in review-artifact-check dev-return-write resolve-base-branch ci-wait; do
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
refs="$(scan_refs ${ORCH_DOCS[@]+"${ORCH_DOCS[@]}"})"
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
control_broken="$(scan_refs ${ORCH_DOCS[@]+"${ORCH_DOCS[@]}"} "$control_doc" | collect_broken)"
if grep -Fqx "$control_ref" <<<"$control_broken"; then
  pass "the reference pipeline reports a planted broken reference (teeth)"
else
  fail "the reference pipeline MISSED a planted broken reference (no teeth)"
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
