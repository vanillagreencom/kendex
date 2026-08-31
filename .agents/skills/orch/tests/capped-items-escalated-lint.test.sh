#!/usr/bin/env bash
# When review-pr § 4 hit the cycle cap, the verification pass's outstanding
# blockers routed to § 5 without ever landing in `fixed_items` or
# `escalated_items`. § 8's decline derivation ("in a json_paths artifact but in
# neither bucket → declined") then reported live blockers as declined with
# `reason: not recorded` and dropped them from the filing candidates — nothing
# filed them.
#
# Pinned here are IDENTIFIERS and their placement: the two state buckets, the
# jq drop keyed on both fields, the `--slurpfile` binding, `outcome`/`blocked`,
# the two `source` values, the panel keys, and the order of the `At The Cap`
# and `Fix Delegation` headings. A rule stated only in a sentence is left
# uncovered rather than covered in appearance — the § 7 convergence predicate
# (one re-check, not two; blockers and `category == "fix"` suggestions in,
# `category == "issue"` out) shares every literal with the disposition sentence
# below it, so no token separates them, and the `escalated_items` schema row's
# cycle-cap provenance carries no token present only when that clause is.
#
# NARROWER SURFACE THAN THE PREDECESSOR, deliberately: it also read
# `scripts/workflow-state` to mirror the cap refusal's tokens.
# `workflow-state-cycle-cap.sh` asserts them on the message the script actually
# emits, which is what proves the refusal reachable; a doc-side copy proves
# only that two files agree.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/md.sh"

WF="$SKILL_DIR/workflows/review-pr.md"
CAP="### At The Cap"
EXIT7="### Converged"
QA="## 7. Handle QA Items"

echo "=== review-pr capped-items escalated lint ==="

# The cap decides before any delegation: with Fix Delegation first, reaching
# the cap still runs one more fix round, and the items escalated afterwards
# predate that round's diff.
order "§ 4 runs the cap check ahead of Fix Delegation" "$WF" \
  '^### At The Cap$' '^### Fix Delegation$'

# One command drops the superseded entry and records the new one. Two commands
# leave a window where the item is in neither bucket, which § 8 reads as
# declined; no drop at all leaves it in both, printed as FIXED against a stale
# sha and as ESCALATED at once. The drop is keyed on both fields, § 8's key.
rule_fenced "the cap write records into escalated_items" "$WF" "$CAP" \
  '.escalated_items = ((.escalated_items // []) + ['
rule_fenced "the cap write drops the superseded fixed_items entry on both fields" "$WF" "$CAP" \
  '.fixed_items = ((.fixed_items // []) | map(select(' '$item.location' '$item.description'
rule_fenced "the cap write binds the finding from its artifact" "$WF" "$CAP" '--slurpfile art'
rule_fenced "the capped entry is typed blocked" "$WF" "$CAP" 'outcome: "blocked"'
rule_fenced "the capped entry carries its source" "$WF" "$CAP" '--arg src' 'source: $src'
rule "the cap names both provenances" "$WF" "$CAP" '`pr-review`' '`qa-review`'
rule "the cap excludes what § 4 declined" "$WF" "$CAP" '§ 4 declined' 'escalated_items'

# A location like fs.rs::write_all's guard ends a quoted shell word early, so
# the command breaks before any binding can help.
absent "the cap write pastes no placeholder into a quoted word" "$WF" "$CAP" \
  "--arg [a-z]+ '\[" "  --arg src '[SOURCE]'"

# § 7 runs no cap check, so its convergence exit is the only place a QA blocker
# whose fix did not hold gets recorded, and the reason it records is its own.
rule_fenced "the QA exit records into escalated_items" "$WF" "$EXIT7" \
  '.escalated_items = ((.escalated_items // []) + ['
rule_fenced "the QA exit drops the superseded fixed_items entry" "$WF" "$EXIT7" \
  '.fixed_items = ((.fixed_items // []) | map(select('
rule_fenced "the QA exit binds the finding from its artifact" "$WF" "$EXIT7" '--slurpfile art'
rule_fenced "the QA exit records its own reason, not the cap's" "$WF" "$EXIT7" \
  'reason: "QA loop converged with the item unresolved"'

# A verification pass is not a fix cycle. Written to the gated key it is
# refused once the internal budget is spent, and the round reaches § 5 with an
# unseen fix diff.
rule "a QA verification pass takes an ungated key" "$WF" "$QA" 'verification_panel'
rule "a QA re-check takes its own panel key" "$WF" "$QA" 'qa_recheck_panel'

# Every path out of QA reaches the one predicate. § 6's all-pass branch used to
# return to § 8 around whatever § 7 required, and § 7 carried a **Skip if**
# doing the same. A route reads `→ § 8`; a bare mention is a cross-reference.
absent "§ 5 reaches the predicate instead of returning to § 8" "$WF" "## 5. Verdict Pass" \
  '→ § 8' 'All pass → § 8.'
absent "§ 6 reaches the predicate instead of returning to § 8" "$WF" "## 6. QA Checks" \
  '→ § 8' 'No signals → § 8.'
absent "§ 7 carries no early return around its predicate" "$WF" "$QA" \
  '\*\*Skip if\*\*' '**Skip if** the QA artifacts are empty.'

md_report
