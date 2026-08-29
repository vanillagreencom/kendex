#!/usr/bin/env bash
# Regression test for tracker-conditional QA-review context reads (#704, the
# #655 tracker-routing class reaching the reviewer skill).
# qa-review.md is a markdown contract, so this test statically verifies that
# the workflow resolves tracker context once before any tracker command, keeps
# the Linear cache reads inside an explicit Linear route, gives the GitHub
# route an exact live-read command, and carries no unconditional `linear.sh`
# in any shared section — a GitHub-tracked QA review must never emit Linear
# cache failures. Also verifies the orch caller passes tracker context in the
# QA delegation (when orch is present).
#
# What this pins is STRUCTURE — the § 1.1 heading, the two bolded routes, the
# `Tracker:` delegation field, the `TRACKER` variable, every gh and linear.sh
# command, and the delegation's Tracker line. review-bots.md: a token pin
# establishes that a structural element is present, never that a behavioral
# claim written in prose is true, so these rules have no lint: that the
# tracker resolves once before any tracker command; that an unprefixed issue
# id infers linear and an `issue-` key github; that a GitHub review runs no
# Linear command and a missing Linear cache is not an error for one; that
# neither route silently falls back to the other; and that the repository is
# omitted from the delegation line under a linear tracker.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

require_pattern() {
  local file="$1" pattern="$2" desc="$3"
  if ! grep -Eq -- "$pattern" "$file"; then
    fail "$desc missing in ${file#$SKILL_DIR/}"
  fi
}

require_fixed() {
  local file="$1" needle="$2" desc="$3"
  if ! grep -Fq -- "$needle" "$file"; then
    fail "$desc missing in ${file#$SKILL_DIR/}"
  fi
}

qa_review="$SKILL_DIR/workflows/qa-review.md"
[[ -f "$qa_review" ]] || fail "workflow not found: workflows/qa-review.md"

# --- qa-review 1.1: tracker resolution happens once, before any tracker command ---

require_pattern "$qa_review" '1\.1 Resolve Tracker' 'tracker resolution section'
require_pattern "$qa_review" '`Tracker:`' 'the delegation field the tracker is read from'
require_fixed "$qa_review" 'gh repo view --json nameWithOwner --jq .nameWithOwner' 'repository resolution for inferred github tracker'
require_pattern "$qa_review" '`TRACKER`' 'the resolved tracker variable'

# --- qa-review 1.1: GitHub reviews degrade explicitly, never silently ---


# --- qa-review 1.2: context read is tracker-conditional ---

require_pattern "$qa_review" '\*\*Linear route \(TRACKER=linear\)\*\*' 'Linear context-read route'
require_pattern "$qa_review" '\*\*GitHub route \(TRACKER=github\)\*\*' 'GitHub context-read route'
require_fixed "$qa_review" '.agents/skills/linear/scripts/linear.sh cache issues get [ISSUE_ID]' 'Linear issue cache read retained in Linear route'
require_fixed "$qa_review" '.agents/skills/linear/scripts/linear.sh cache comments list [ISSUE_ID]' 'Linear comments cache read retained in Linear route'
require_fixed "$qa_review" 'gh issue view [N] --repo [OWNER/REPO] --json number,title,body,comments,labels,url' 'GitHub live issue/comments read'

# --- qa-review: no `linear.sh` outside the Linear route (shared sections clean) ---

linear_route="$tmp/linear-route.md"
sed -n '/^\*\*Linear route (TRACKER=linear)\*\*/,/^\*\*GitHub route (TRACKER=github)\*\*/p' "$qa_review" > "$linear_route"
[[ -s "$linear_route" ]] || fail 'Linear route section could not be extracted'
grep -Fq 'linear.sh' "$linear_route" || fail 'extracted Linear route contains no linear.sh command (extraction broken)'

shared="$tmp/shared-sections.md"
sed '/^\*\*Linear route (TRACKER=linear)\*\*/,/^\*\*GitHub route (TRACKER=github)\*\*/d' "$qa_review" > "$shared"
[[ -s "$shared" ]] || fail 'shared sections could not be extracted'
if grep -Fq 'linear.sh' "$shared"; then
  fail 'unconditional linear.sh reference outside the Linear route in qa-review.md'
fi

# --- orch caller: QA delegation carries tracker context (when orch is present) ---

review_pr="$SKILL_DIR/../orch/workflows/review-pr.md"
if [[ -f "$review_pr" ]]; then
  qa_delegation="$tmp/qa-delegation.md"
  sed -n '/qa-review\.md/,/<\/delegation_format>/p' "$review_pr" > "$qa_delegation"
  [[ -s "$qa_delegation" ]] || fail 'QA delegation format could not be extracted from orch review-pr.md'
  require_fixed "$qa_delegation" 'Tracker: [TRACKER] [OWNER/REPO]' 'tracker context in orch QA delegation'
  require_pattern "$review_pr" 'TRACKER=linear' 'the linear tracker value in the orch QA delegation'
fi

echo "all pass"
