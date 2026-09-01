#!/usr/bin/env bash
# The two dev-side rules from the same audit as orch's Step 0: grep for a twin
# before writing one, and no migration or compat code.
#
# What each replaced. The twin rule was "never re-implement a judgment another
# component owns — delegate", which names a judgment and carries no step that
# would find one; a grep is a step an agent can run. The migration rule was a
# product baseline in the project's architecture doc with no agent-facing half:
# the dev bullet adds the action (write no reader for an older version's
# artifact) and the verdict (a finding asking for one is declined). The scope
# rule's "mechanical enablers" exception had no closed list, so such a reader
# rode in as an enabler.
#
# WHAT THIS COVERS, stated as the token facts it checks rather than the rules
# they belong to, because a token pin establishes that a structural element is
# present and nothing more (`review-bots.md`, the markdown-contract bullet):
#
#   * § Engineering Rules names Step 0 on a line that also carries the
#     finding-disposition link, and that link resolves to a file
#   * § Round Contract names Step 0
#   * neither section carries the delegation sentence the twin rule replaced
#
# WHAT IT DOES NOT COVER, and none is asked for, since each is a claim about
# direction or behavior that co-occurrence cannot establish: that either
# section DEFERS to Step 0 rather than overriding it; that an agent greps
# before adding a function; that a second copy in any language or in prose is
# a twin; that an issue ordering one is escalated; that no reader is written
# for an older version's artifact and such a finding is declined; and that the
# enabler list is closed. Each was mutated with every pinned token kept and
# this suite stayed green. Deleting the twin bullet outright is likewise
# outside what this decides: the `absent` rule only refuses the sentence it
# replaced coming back.
#
# The markdown reader is `skills/orch/tests/lib/md.sh`, shared rather than
# copied here — a second copy of it would be the twin the rule below bans. It
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

# Both sections that state the introduced-or-armed exception name Step 0, and
# the scope rule's line carries the link that makes the step reachable.
rule "the scope rule names Step 0 and links it" "$DEV" "$RULES" \
  'Step 0' "$DISP_LINK"
rule "the round contract names Step 0" "$DEV" "$ROUND" 'Step 0'

# The sentence the twin rule replaced, refused rather than left beside it, in
# both sections — `absent` reads only the heading it is given, so the COVERS
# bullet's "neither section" needs one registration per section.
TWIN_RE='Never re-implement a judgment another component owns'
TWIN_SAMPLE='- Never re-implement a judgment another component owns — delegate.'
absent "Engineering Rules states no twin test as a judgment to recognise" \
  "$DEV" "$RULES" "$TWIN_RE" "$TWIN_SAMPLE"
absent "the round contract states no twin test as a judgment to recognise" \
  "$DEV" "$ROUND" "$TWIN_RE" "$TWIN_SAMPLE"

# The link resolves. A rule naming a step behind a dead link states nothing an
# agent can follow. `check` carries no automatic control, so the planted one
# below is this check's teeth.
resolves() { [ -f "$SKILL_DIR/$1" ]; }
check "the Step 0 link resolves to a file" resolves "$DISP_LINK"
check "the link check flags a target that is not there" \
  test -z "$(resolves "${DISP_LINK%.md}-renamed.md" && echo held)"

md_report
