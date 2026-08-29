#!/usr/bin/env bash
# Regression lint for kendex#970. The `escalated_items` workflow-state bucket
# used to conflate two dev outcomes — items dev was BLOCKED on and items dev
# deliberately SKIPPED — distinguishable only via free-text `reason`. Downstream,
# review-pr § 9 fed the bucket wholesale into audit input as `origin:
# "escalated"` ("blockers dev couldn't fix"), so under
# ORCH_DECISION_MODE=auto-recommended skipped low-priority residue was filed as
# if it were unfixable blockers.
#
# The fix threads the dev round's typed per-item decision through the
# state-write boundary as an `outcome` field ("blocked"|"skipped") and maps it
# to distinct audit origins (blocked/absent → "escalated", skipped →
# "skipped"). This lint pins the tokens that chain carries in the instruction
# docs — the `outcome` field and, in the schema, one table row per outcome
# binding it to its origin. A relation needs one pin that spans both halves:
# two independent token greps would stay green with the mapping inverted.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
PM_SCHEMA="$SKILL_DIR/../project-management/schemas/audit-issues-input.md"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }

echo "=== orch escalated_items outcome lint (kendex#970) ==="

# --- a: the state write carries the typed outcome ---------------------------
# The dev-fix escalated entry must include the outcome field so the
# Blocked/Skipped distinction survives the state-write boundary. The entry is
# written to a file and bound into the write, so the field sits in the entry
# shape and the write is the command that appends it.
DEV_FIX="$SKILL_DIR/workflows/dev-fix.md"
if grep -qE '^\s*\{"description":.*"outcome":' "$DEV_FIX" \
   && grep -qE 'workflow-state update \[ISSUE_ID\].*\.escalated_items \+=' "$DEV_FIX"; then
  pass "dev-fix escalated entry carries the \"outcome\" field into its write"
else
  fail "dev-fix escalated entry lost the \"outcome\" field or its write"
fi

# --- b: audit-input builders carry the skipped mapping and the schema route -
# `"skipped"` → `origin: "skipped"` is ONE contiguous literal, so it binds the
# outcome to the origin. The blocked branch is not: the workflows spell it
# `"blocked"` or no `outcome` field → `origin: "escalated"`, and any pin short
# of that whole run of text leaves the two halves independent. Two independent
# token pins never establish a relation between the tokens. So the blocked
# branch is unpinned in the workflows; what is pinned is that each builder
# routes to the schema that owns the mapping, where § d reads the table.
for wf in review-pr review; do
  doc="$SKILL_DIR/workflows/$wf.md"
  if grep -q '`"skipped"` → `origin: "skipped"`' "$doc" \
     && grep -q 'schemas/audit-issues-input.md' "$doc"; then
    pass "$wf.md maps skipped → skipped and routes to the schema"
  else
    fail "$wf.md lost the skipped mapping or the schema route"
  fi
done

# The legacy rule — an entry WITHOUT an `outcome` field maps to origin
# "escalated" — now has its own row in the schema table § d reads. It stays
# uncovered in review-pr.md and review.md, where both builders state it in
# prose that no token tracks.

# --- d: the audit-input schema carries the mapping as a table ---------------
# One row per outcome, so each row binds its outcome to its origin. Scoped to
# the mapping section and gated on the header and delimiter: row-shaped text
# elsewhere in the file must not satisfy it, and rows with no table above them
# are not a table.
if grep -q 'suggestion|escalated|skipped|planned|discovered' "$PM_SCHEMA"; then
  pass "audit-issues-input origin enum includes skipped"
else
  fail "audit-issues-input origin enum lost skipped"
fi

# Sliced on the section HEADING, not on the bold lead-in above the table: a
# lead-in is a sentence fragment, and a prose boundary makes the check
# prose-dependent however structural the needle inside it is.
map_table() {
  awk '/^## Building from Review Findings/ { on = 1; next }
       on && /^## / { on = 0 }
       on' "$1"
}
MAP="$(map_table "$PM_SCHEMA")"
MAP_ROWS=(
  '| `"blocked"` | `"escalated"` |'
  '| absent | `"escalated"` |'
  '| `"skipped"` | `"skipped"` |'
)
missing_row=""
for row in "${MAP_ROWS[@]}"; do
  grep -qF -- "$row" <<<"$MAP" || missing_row="$missing_row $row"
done
if ! grep -qF -- '| `outcome` | `origin` |' <<<"$MAP"; then
  fail "the outcome → origin mapping lost its table header"
elif ! grep -qE '^\|-+\|-+\|$' <<<"$MAP"; then
  fail "the outcome → origin mapping lost its table delimiter"
elif [[ -n "$missing_row" ]]; then
  fail "the outcome → origin mapping lost a row:$missing_row"
else
  pass "audit-issues-input maps each outcome to its origin, one row each"
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
