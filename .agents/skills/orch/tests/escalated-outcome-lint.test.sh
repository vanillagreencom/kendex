#!/usr/bin/env bash
# The `escalated_items` bucket used to conflate two dev outcomes — items dev
# was BLOCKED on and items dev deliberately SKIPPED — distinguishable only via
# free-text `reason`. review-pr fed the bucket wholesale into audit input as
# `origin: "escalated"` ("blockers dev couldn't fix"), so under
# ORCH_DECISION_MODE=auto-recommended skipped low-priority residue was filed as
# if it were unfixable blockers.
#
# The fix threads the dev round's typed per-item decision through the
# state-write boundary as an `outcome` field and maps it to distinct audit
# origins. Pinned here: the field, the write that carries it, the route from
# each builder to the schema, and in the schema one row per outcome binding it
# to its origin — a relation needs a pin spanning both halves, since two
# independent token greps stay green with the mapping inverted.
#
# NOT pinned in review-pr.md or review.md: the mapping itself. Contiguity was
# not enough — a sentence NEGATING `"skipped"` → `origin: "skipped"` carries
# that literal too, so the check passed on a doc saying the opposite. A pin a
# negation satisfies covers nothing, and the schema's rows are the only
# coverage that rule has.
#
# Also NOT covered: that those rows form a well-formed table — a header, a
# delimiter below it, a consistent cell count. Not because the property is
# prose; it is a document-level fact with no fail-closed home here. A checker
# this suite calls must ship inside orch, and dep-radar's policy lint needs the
# identical checker but cannot reach it: no test in this repo sources another
# skill's file. A repo-level `tools/` lane is the right home. Until one exists,
# table well-formedness has no lint anywhere.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/md.sh"

DEV_FIX="$SKILL_DIR/workflows/dev-fix.md"
PM_SCHEMA="$SKILLS_ROOT/project-management/schemas/audit-issues-input.md"
MAPPING="## Building from Review Findings"

echo "=== orch escalated_items outcome lint ==="

rule "the dev-fix escalated entry carries a typed outcome" \
  "$DEV_FIX" "## 2. Delegate" '"outcome":' '"description":'
rule_fenced "the escalated write appends that entry" \
  "$DEV_FIX" "## 2. Delegate" '.escalated_items += [$e]' '--slurpfile item'

rule "review-pr routes to the schema that owns the mapping" \
  "$SKILL_DIR/workflows/review-pr.md" "" 'schemas/audit-issues-input.md'
rule "review routes to the schema that owns the mapping" \
  "$SKILL_DIR/workflows/review.md" "" 'schemas/audit-issues-input.md'

rule "the origin enum admits skipped" \
  "$PM_SCHEMA" "" '"origin":' 'escalated|skipped'
rule "a blocked outcome maps to origin escalated" \
  "$PM_SCHEMA" "$MAPPING" '| `"blocked"` |' '| `"escalated"` |'
rule "an absent outcome maps to origin escalated" \
  "$PM_SCHEMA" "$MAPPING" '| absent |' '| `"escalated"` |'
rule "a skipped outcome maps to origin skipped" \
  "$PM_SCHEMA" "$MAPPING" '| `"skipped"` |' '| `"skipped"` |'

md_report
