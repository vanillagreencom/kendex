#!/usr/bin/env bash
# The two dev-side rules from the same audit as orch's Step 0: grep for a twin
# before writing one, and no migration or compat code.
#
# What each replaced. The twin rule was "never re-implement a judgment another
# component owns — delegate", which names a judgment and carries no step that
# would find one; a grep is a step an agent can run. The migration rule was a
# product baseline in `docs/ARCHITECTURE.md` with no agent-facing half: the dev
# bullet adds the action (write no reader for an older version's artifact) and
# the verdict (a finding asking for one is declined), and cites that baseline
# rather than restating it. The scope rule's "mechanical enablers" exception had
# no closed list, so such a reader rode in as an enabler.
#
# WHAT THIS COVERS is structure, which is all a token pin can establish
# (`review-bots.md`, the markdown-contract bullet): the deferrals to Step 0 in
# both sections that state the introduced-or-armed exception, the link that
# makes Step 0 reachable and its resolution, the baseline the migration bullet
# cites, and the absence of the delegation sentence the twin rule replaced.
#
# WHAT IT DOES NOT COVER, and none is asked for: the rules themselves. That an
# agent greps before adding a function, that a second copy in any language or
# in prose is a twin, that an issue ordering one is escalated, that no reader
# is written for an older version's artifact and such a finding is declined,
# and that the enabler list is closed are behavioral claims living only in
# prose. Prose negates and qualifies around any literal, so pinning those
# sentences would report coverage of a bullet rewritten to say the opposite.
# Deleting the twin bullet outright is likewise outside what this decides: the
# `absent` rule below only refuses the sentence it replaced coming back.
#
# The markdown reader is `skills/orch/tests/lib/md.sh`, shared rather than
# copied here — a second copy of it would be the twin the rule above bans. It
# resolves SKILL_DIR to orch, so this suite reassigns SKILL_DIR to dev
# immediately after sourcing and every rule reads the same variable its
# neighbours use.
set -euo pipefail

_dev_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
_md_lib="$_dev_dir/../orch/tests/lib/md.sh"
[ -f "$_md_lib" ] || {
  printf 'FAIL: orch is a required dependency of dev and its md lib is missing: %s\n' "$_md_lib" >&2
  exit 1
}
source "$_md_lib"
SKILL_DIR="$_dev_dir"

DEV="$SKILL_DIR/SKILL.md"
RULES="## Engineering Rules"
ROUND="## Round Contract"
DISP_LINK='../orch/references/finding-disposition.md'

echo "=== dev engineering-rules lint ==="

# Both statements of the introduced-or-armed exception defer to Step 0, so
# neither says the opposite of the excluded classes, and the scope rule carries
# the link that makes the step reachable from here.
rule "the scope rule defers to Step 0 and links it" "$DEV" "$RULES" \
  'Step 0' "$DISP_LINK"
rule "the round contract defers to Step 0" "$DEV" "$ROUND" 'Step 0'

# The migration rule's home is the product baseline; this bullet cites it
# rather than restating the judgment.
rule "the migration rule cites its baseline" "$DEV" "$RULES" \
  'docs/ARCHITECTURE.md'

# The sentence the twin rule replaced, refused rather than left beside it.
absent "no rule states the twin test as a judgment to recognise" "$DEV" "$RULES" \
  'Never re-implement a judgment another component owns' \
  '- Never re-implement a judgment another component owns — delegate.'

# The link resolves. A rule deferring to a step behind a dead link states
# nothing an agent can follow. `check` carries no automatic control, so the
# planted one below is this check's teeth.
resolves() { [ -f "$SKILL_DIR/$1" ]; }
check "the Step 0 link resolves to a file" resolves "$DISP_LINK"
check "the link check flags a target that is not there" \
  test -z "$(resolves "${DISP_LINK%.md}-renamed.md" && echo held)"

md_report
