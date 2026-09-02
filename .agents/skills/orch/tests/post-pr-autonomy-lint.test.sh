#!/usr/bin/env bash
# Automatic post-PR choices continue to their budget, then record one stop.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/md.sh"

SETTINGS="$SKILL_DIR/kendex.settings.toml.example" COMMENTS="$SKILL_DIR/workflows/review-pr-comments.md" SUBMIT="$SKILL_DIR/workflows/submit-pr.md" START="$SKILL_DIR/workflows/start-worktree.md" MERGE="$SKILL_DIR/workflows/merge-pr.md" CI="$SKILL_DIR/workflows/ci-fix.md"
echo "=== orch post-PR autonomy lint ==="
route_rule() {
  local name="$1" file="$2" expected="$3" inverse="$4" scratch="$MD_TMP/route-$PASS-$FAIL.md"
  grep -qxF -- "$expected" "$file" || { fail "$name: route is missing"; return; }
  pass "$name"
  awk -v old="$expected" -v new="$inverse" '{ if ($0 == old) print new; else print }' "$file" > "$scratch"
  ! cmp -s "$file" "$scratch" && ! grep -qxF -- "$expected" "$scratch" || { fail "$name: inverse control did not make the route guard red"; return; }
  pass "$name: inverse control"
}
rule "decision mode defaults to automatic continuation" "$SETTINGS" "" 'ORCH_DECISION_MODE = "auto-recommended"'
rule "merge consent defaults to automatic after gates" "$SETTINGS" "" 'ORCH_MERGE_AUTONOMY = "auto"'
rule "reviewer silence defaults to proceed" "$SETTINGS" "" 'PR_REVIEW_ON_TIMEOUT = "proceed"'
rule "the skill owns the named-stop record" "$SKILL_DIR/SKILL.md" "## The Cycle" '**Post-PR autonomy.**' '`workflow-state post-pr-stop record`' '`ORCH_MERGE_AUTONOMY` controls merge consent only'
rule_fenced "comment triage reads the decision mode" "$COMMENTS" "" 'orch-env ORCH_DECISION_MODE auto-recommended'
route_rule "decision mode controls managed comment triage" "$COMMENTS" 'Decision route: `auto-recommended` -> `continue-to-§8`; `ask` -> `return-pending-choice`.' 'Decision route: `auto-recommended` -> `return-pending-choice`; `ask` -> `continue-to-§8`.'
rule_fenced "submission reads the decision mode" "$SUBMIT" "" 'orch-env ORCH_DECISION_MODE auto-recommended'
route_rule "submission spends review retries before its cap" "$SUBMIT" '   Decision route: `auto-recommended` + `retry-budget` -> `restart-review-wait`; `auto-recommended` + `retry-cap` -> `record-review-round-cap`; `ask` -> `present-review-choice`.' '   Decision route: `auto-recommended` + `retry-budget` -> `record-review-round-cap`; `auto-recommended` + `retry-cap` -> `restart-review-wait`; `ask` -> `present-review-choice`.'
route_rule "start-worktree preserves the final stop before summaries" "$START" 'Stop route: `upstream-stop` -> `preserve`; `no-upstream-stop` -> `record-merge-gates-unmet`; `final-stop` -> `render-summaries`.' 'Stop route: `upstream-stop` -> `record-merge-gates-unmet`; `no-upstream-stop` -> `preserve`; `final-stop` -> `render-summaries`.'
rule_fenced "merge reads the decision mode" "$MERGE" "" 'orch-env ORCH_DECISION_MODE auto-recommended'
rule "merge retry exhaustion has a named stop" "$MERGE" "## 3. Check Merge Readiness" '`merge-check-blocked`'
rule_fenced "ci-fix reads the decision mode" "$CI" "## 3. Classify And Route" 'orch-env ORCH_DECISION_MODE auto-recommended'
route_rule "ci-fix spends retries before its cap" "$CI" 'Decision route: `auto-recommended` + `retry-budget` -> `restart-ci-fix`; `auto-recommended` + `retry-cap` -> `record-ci-fix-cap`; `ask` -> `present-ci-fix-choice`.' 'Decision route: `auto-recommended` + `retry-budget` -> `record-ci-fix-cap`; `auto-recommended` + `retry-cap` -> `restart-ci-fix`; `ask` -> `present-ci-fix-choice`.'
rule "kendex never receives the admin merge offer" "$SUBMIT" "### 2.1 Consumer Admin-Merge Offer" '`vanillagreencom/kendex`'
rule "automatic decisions never select admin merge" "$SUBMIT" "### 2.1 Consumer Admin-Merge Offer" '`ORCH_DECISION_MODE` never selects admin merge'
rule "merge accepts only a recorded admin decision" "$MERGE" "" '`admin_merge_authorized`' '`submit-pr.md` § 2.1' 'PR body'
retired_opened='not merely open''ed'
retired_wait='Stop and wait for the us''er'
forbid "the retired brief-level stop prompt stays gone" \
  "$retired_opened|$retired_wait" \
  "$retired_wait." "$SKILL_DIR/workflows"/*.md "$SKILL_DIR/scripts/open-terminal"

md_report
