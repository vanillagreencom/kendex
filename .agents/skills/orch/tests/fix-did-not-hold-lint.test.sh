#!/usr/bin/env bash
# Every re-review prompt suppressed anything the delegation listed as Fixed,
# with no exception. A reviewer that obeyed stayed silent about a finding whose
# recorded fix failed, so the machinery that supersedes the stale `fixed_items`
# entry never got the input it needs and § 8 kept publishing a live blocker as
# fixed against a dead sha.
#
# What that machinery needs is pinned here, all of it an identifier: the
# supersede key is exact equality of the RECORDED entry's location and
# description, so each delegation's expansion must PRINT both fields for the
# reviewer to copy; the sha it cites has to render, so the expansion carries
# the `dropped:<sha>` marker case beside `[COMMIT_SHA]`; and each dev-fix
# outcome write clears the item from BOTH buckets on that same key before
# appending its own entry, binding the entry through a file so the finding's
# own text never enters a shell word.
#
# NARROWER SURFACE THAN THE PREDECESSOR, deliberately: it also read
# `../reviewer/SKILL.md`. What it read there was the suppression rule itself,
# one sentence at each of three sites — review-pr's re-review delegation, its
# QA delegation, and the reviewer package's own § Re-Review Rounds — and every
# element that once stood for it here (`do NOT re-report`, `unless`,
# `verbatim`, `suppressed`, `list`) is a word of that sentence. With the
# sentence pins gone the reviewer file carries no identifier this suite could
# read, so it is off the surface rather than scanned for nothing. review-bots.md bans sentence-pinning lints on
# markdown, and a rephrase that keeps the contract must not redden a suite. The
# expansions below are the half of the contract a token can carry, and the half
# a reviewer cannot obey without.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/md.sh"

PR="$SKILL_DIR/workflows/review-pr.md"
DEV_FIX="$SKILL_DIR/workflows/dev-fix.md"
SCHEMA="$SKILL_DIR/schemas/workflow-state.md"
LAUNCH="### 2.2 Launch And Delegate"
QA="## 6. QA Checks"
DELEGATE="## 2. Delegate"

echo "=== re-report a fix that did not hold lint ==="

# A list printing only the description asks the reviewer to copy a field it was
# never shown, and a fix that moved the finding then supersedes nothing. § 4
# excludes an escalated item from a fix round on the same pair, so the reviewer
# that must recognise one needs both fields too.
rule "the re-review Fixed list prints the supersede key" "$PR" "$LAUNCH" \
  '- Fixed:' '[LOCATION]' '[DESCRIPTION]'
rule "the re-review Fixed list guards the dropped-marker sha" "$PR" "$LAUNCH" \
  '[COMMIT_SHA]' 'dropped:<sha>'
rule "the re-review Escalated list prints the same key" "$PR" "$LAUNCH" \
  '- Escalated:' '[LOCATION]' '[DESCRIPTION]'
rule "the QA Fixed list prints the supersede key" "$PR" "$QA" \
  '- Fixed since last review:' '[LOCATION]' '[DESCRIPTION]'
rule "the QA Fixed list guards the dropped-marker sha" "$PR" "$QA" \
  '[COMMIT_SHA]' 'dropped:<sha>'
rule "the QA Escalated list prints the same key" "$PR" "$QA" \
  '- Escalated (accepted):' '[LOCATION]' '[DESCRIPTION]'

# An item comes back for a second disposition two ways: a re-reported fix that
# did not hold, and an escalated item a later round fixes. Either way a bucket
# still lists it against a dead sha, so each write clears BOTH before appending
# its own. Clearing only the opposite bucket prints the item under FIXED and
# ESCALATED at once.
rule_fenced "the fixed write supersedes in both buckets from a bound entry" \
  "$DEV_FIX" "$DELEGATE" '.fixed_items += [$e]' \
  '.fixed_items = ((.fixed_items // [])' '.escalated_items = ((.escalated_items // [])' \
  '$e.location' '$e.description' '--slurpfile item'
rule_fenced "the escalated write supersedes in both buckets from a bound entry" \
  "$DEV_FIX" "$DELEGATE" '.escalated_items += [$e]' \
  '.fixed_items = ((.fixed_items // [])' '.escalated_items = ((.escalated_items // [])' \
  '$e.location' '$e.description' '--slurpfile item'

# A bare append records without superseding, and a pasted entry breaks on the
# text findings actually carry: a double quote invalidates a JSON argument, an
# apostrophe ends the shell word, and the failed write leaves the stale entry
# standing with nothing recorded. Both argument forms get their own rule, so
# each control plants the shape it forbids rather than the one a shared
# pattern already matched.
absent "no outcome write appends into a bucket" "$DEV_FIX" "$DELEGATE" \
  'workflow-state append \[ISSUE_ID\] (fixed|escalated)_items' \
  '.agents/skills/orch/scripts/workflow-state append [ISSUE_ID] fixed_items "$entry"'
absent "no outcome write pastes the entry as a string argument" "$DEV_FIX" "$DELEGATE" \
  'workflow-state update \[ISSUE_ID\][^`]*--arg ' \
  '.agents/skills/orch/scripts/workflow-state update [ISSUE_ID] --arg e "[ENTRY]" ".fixed_items += [$e]"'
absent "no outcome write pastes the entry as a JSON argument" "$DEV_FIX" "$DELEGATE" \
  'workflow-state update \[ISSUE_ID\][^`]*--argjson ' \
  '.agents/skills/orch/scripts/workflow-state update [ISSUE_ID] --argjson e "[ENTRY]" ".fixed_items += [$e]"'

rule "the schema states the one-bucket invariant" "$SCHEMA" "" 'never in both buckets'

md_report
