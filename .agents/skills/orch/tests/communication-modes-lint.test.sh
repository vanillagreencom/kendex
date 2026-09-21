#!/usr/bin/env bash
# One file states which questions reach the user and how each is worded, and
# nothing outside it narrows or widens that set.
#
# Prose carries no pin: md.sh pins identifiers and their placement, so a claim
# stated in a sentence alone is uncovered here by contract, not by omission.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/md.sh"

MODES="$SKILL_DIR/references/communication-modes.md"
EVENTS="$SKILL_DIR/references/oversee-events.md"
DISPOSITION="$SKILL_DIR/references/finding-disposition.md"
SUBMIT="$SKILL_DIR/workflows/submit-pr.md"
DEV_FIX="$SKILL_DIR/workflows/dev-fix.md"
REVIEW="$SKILL_DIR/workflows/review.md"
REVIEW_PR="$SKILL_DIR/workflows/review-pr.md"
# The audit lives in a sibling skill, and md.sh resolves SKILL_DIR to orch.
AUDIT="$SKILLS_ROOT/project-management/workflows/audit-issues.md"
OVERSEE="$SKILL_DIR/workflows/oversee.md"
SETTINGS="$SKILL_DIR/kendex.settings.toml.example"

echo "=== orch communication modes lint ==="

# --- The mode and what it composes -----------------------------------------
rule_fenced "the mode is read through the settings ladder" "$MODES" "" \
  'orch-env ORCH_USER_MODE ceo'
rule "ceo composes the post-PR decision mode" "$MODES" "## Composition" \
  '`ORCH_DECISION_MODE`' '`auto-recommended`'
rule "ceo composes merge consent" "$MODES" "## Composition" \
  '`ORCH_MERGE_AUTONOMY`' '`auto`'
rule "ceo composes issue creation" "$MODES" "## Composition" \
  '`PM_CREATE_AUTONOMY`' '`auto`'
# The composition changes an effective answer at this call site alone, so a gate
# reading the variable directly would strand it.
rule_fenced "the audit gate reads the key through the ladder" "$AUDIT" \
  "## 6. Approve Creations and Cancellations" 'orch-env PM_CREATE_AUTONOMY ask'

# --- The ask set, which is the owner's standing ruling ----------------------
rule "scope expansion asks" "$MODES" "## Ask set" 'Scope expansion beyond the issue'
rule "a destructive action asks" "$MODES" "## Ask set" 'A destructive action'
rule "a product change asks" "$MODES" "## Ask set" \
  'A change to user experience, workflow, outcome, cost or risk'
rule "an action outside this repository asks" "$MODES" "## Ask set" \
  'outside this repository'
rule "a composed auto records the audit's decisions instead of asking" "$MODES" \
  "## Ask set" '§ Recording' '`PM_CREATE_AUTONOMY`' '`auto`'

# --- The two templates ------------------------------------------------------
rule "engineer keeps the package's option-list wording" "$MODES" \
  "## The engineer question template" '[OPTION_A] | [OPTION_B]' 'recommended'
rule "every decision lands in one fleet-log record" "$MODES" "## Recording" \
  'One `ruling` record in the fleet log'

# The ceo template is judged on its own, so a setting name or an internal term
# anywhere else in the file cannot mask one inside it. The extract is the
# fenced block under the template's heading and nothing else.
CEO_TEMPLATE="$MD_TMP/ceo-template.md"
awk '
  /^## The ceo question template$/ { seen = 1; next }
  seen && /^```/ { if (inb) exit; inb = 1; next }
  inb { print }
' "$MODES" >"$CEO_TEMPLATE"
if grep -q 'Recommended:' "$CEO_TEMPLATE" && grep -q 'Gains:' "$CEO_TEMPLATE"; then
  pass "the ceo template extract reaches the template body"
else
  fail "the ceo template extract reaches the template body — the heading or its fence moved"
fi

forbid "the ceo template names no engineering option" \
  '[Mm]odel|MODEL|[Ee]ffort|EFFORT|[Ll]ane|LANE|[Bb]ranch|BRANCH|[Rr]ebase|REBASE|[Ff]lag|FLAG|[Ss]cript|SCRIPT' \
  'A. Run it on the fast model' "$CEO_TEMPLATE"
forbid "the ceo template names no setting" \
  '`[A-Z][A-Z0-9]*_[A-Z0-9_]*`' \
  'B. Leave `ORCH_MERGE_AUTONOMY` as it is' "$CEO_TEMPLATE"

# --- Every ask gate cites the one file --------------------------------------
rule "the cycle's ask gates cite the one file" "$SKILL_DIR/SKILL.md" "## The Cycle" \
  'references/communication-modes.md' 'nothing outside that file narrows or widens the set'
rule "a held merge is relayed in that wording" "$EVENTS" "## Judgement rules" \
  'worded as [communication-modes.md](communication-modes.md) requires'
rule "deciding without the user reads the same set" "$EVENTS" "## Judgement rules" \
  '§ Ask set, which nothing here narrows or widens'
rule "the overseer handoff takes the file's shape" "$EVENTS" "## Judgement rules" \
  '§ Handoff gives'
rule "a succession refusal is reported in the file's shape" "$EVENTS" "## Judgement rules" \
  '§ Status report gives'
rule "a lane question is relayed only from that set" "$EVENTS" "## Event kinds" \
  '§ Ask set puts it'
rule "a product decision reaches the user only from that set" "$DISPOSITION" "## Filing bar" \
  '§ Ask set names'
rule "a decline is never re-asked" "$DISPOSITION" "## Filing bar" \
  '§ Ask set keeps out of the set'
rule "the admin-merge question takes the mode's wording" "$SUBMIT" \
  "### 6.2 Consumer Admin-Merge Question" '../references/communication-modes.md'
rule "the fix round reads the ask set from the one file" "$DEV_FIX" \
  "### Fix Items — [ISSUE_ID]" '../references/communication-modes.md' '§ Ask set'
rule "the internal review reads the ask set from the one file" "$REVIEW" \
  "### Review Items" '../references/communication-modes.md' '§ Ask set'
rule "the PR review reads the ask set from the one file" "$REVIEW_PR" \
  "### PR Review Items — [ISSUE_ID]" '../references/communication-modes.md' '§ Ask set'
rule_fenced "the admin-merge gate resolves the mode" "$SUBMIT" \
  "### 6.2 Consumer Admin-Merge Question" 'orch-env ORCH_USER_MODE ceo'
rule_fenced "the overseer resolves the mode before it relays" "$OVERSEE" \
  "## 3. Launch" 'orch-env ORCH_USER_MODE ceo'

# --- The setting is published where a consumer sets it ----------------------
rule "the settings table publishes the mode and its default" "$SKILL_DIR/README.md" \
  "## Settings" '`ORCH_USER_MODE`' 'references/communication-modes.md' '| `ceo` |'
rule "the settings example ships the package default" "$SETTINGS" "" \
  'ORCH_USER_MODE = "ceo"'

# --- The framing prose each gate used to carry stays gone -------------------
#
# Each phrase below stated the ask set at one gate. The set has one owner now,
# so a gate restating it is the defect this row catches.
forbid "no ask gate states the ask set for itself" \
  'only about product or experience|only when it changes the product|product direction wait' \
  'Ask the user only about product or experience.' \
  "$SKILL_DIR"/*.md "$SKILL_DIR/workflows"/*.md "$EVENTS" "$DISPOSITION" \
  "$SKILL_DIR/references/skill-rules.md"

# The same defect in one phrase, registered on its own rather than as a fourth
# alternative above. md.sh appends one sample per forbid, so an alternation
# proves only the alternative that sample matches and the rest go unexercised.
forbid "no ask gate names an always-ask set of its own" \
  'always-ask set' \
  'The always-ask set in SKILL.md still applies.' \
  "$SKILL_DIR"/*.md "$SKILL_DIR/workflows"/*.md "$EVENTS" "$DISPOSITION" \
  "$SKILL_DIR/references/skill-rules.md"

# The converted gate records two answer tokens. Filling the engineer template
# around them would emit engineer wording under every mode, so the filled shape
# is what this row catches.
forbid "the converted merge gate fills no template of its own" \
  'with `Continue through the gates` recommended' \
  'presents `Admin-merge past the unmet gate` | `Continue through the gates`, with `Continue through the gates` recommended.' \
  "$SUBMIT"

md_report
