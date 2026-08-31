#!/usr/bin/env bash
# The two dev-side rules from the same audit as orch's Step 0: grep for a twin
# before writing one, and no migration or compat code.
#
# What each replaced. The twin rule was "never re-implement a judgment another
# component owns — delegate", which names a judgment and carries no step that
# would find one; a grep for the verb is a step an agent can run. The migration
# rule was absent from every file, living only in a maintainer's memory, while
# the scope rule's "mechanical enablers" exception had no closed list and let
# readers of an older version's artifacts ride in as enablers.
#
# The exclusion list this file's deferrals point at is orch's, pinned in
# `../../orch/tests/disposition-step-zero-lint.test.sh`. That suite's markdown
# reader is sourced here rather than copied: a second copy of it would be the
# twin the rule below bans.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEV_DIR="$(cd "$TEST_DIR/.." && pwd)"
MD_LIB="$DEV_DIR/../orch/tests/lib/md.sh"
[ -f "$MD_LIB" ] || {
  printf 'FAIL: orch is a required dependency of dev and its md lib is missing: %s\n' "$MD_LIB" >&2
  exit 1
}
source "$MD_LIB"

DEV="$DEV_DIR/SKILL.md"
RULES="## Engineering Rules"
ROUND="## Round Contract"
DISP_LINK='../orch/references/finding-disposition.md'

echo "=== dev engineering-rules lint ==="

# The twin rule as a step: what to run, when to run it, and what the answer
# means. A rule stating only the conclusion is what this replaced.
rule "the twin rule orders a grep before new code" "$DEV" "$RULES" \
  'grep the repo for the verb it performs'
rule "the twin rule names when to run it" "$DEV" "$RULES" \
  'Before adding a function, parser, stub or loop'
rule "a second copy in any language is a twin" "$DEV" "$RULES" \
  'A second copy of that verb, in any language, is a twin and never delegation'
rule "an issue ordering a twin is escalated" "$DEV" "$RULES" \
  'An issue that orders a twin is escalated, not implemented'
absent "no rule states the twin test as a judgment to recognise" "$DEV" "$RULES" \
  'Never re-implement a judgment another component owns' \
  '- Never re-implement a judgment another component owns — delegate.'

# The migration rule, and the three things it has to say to be actionable: no
# such code, what a layout change costs instead, and how a finding asking for
# it is answered.
rule "no migration or compat code" "$DEV" "$RULES" 'No migration or compat code'
rule "a layout change is a changelog line and a fresh install" "$DEV" "$RULES" \
  'one changelog line and a fresh install'
rule "no reader carries an older version's artifact forward" "$DEV" "$RULES" \
  "nothing reads an artifact an older version wrote"
rule "a finding asking to carry one forward is declined" "$DEV" "$RULES" \
  'asking to carry one forward is declined'

# The enabler exception the migration rule closes: an open list is what let a
# reader of an old artifact ride in as a mechanical enabler.
rule "the enabler list is closed" "$DEV" "$RULES" 'that list and nothing else'
rule "no enabler runs at runtime" "$DEV" "$RULES" 'never code that runs at runtime'

# Both statements of the introduced-or-armed exception defer to Step 0, so
# neither says the opposite of the excluded classes.
rule "the scope rule's armed-defect exception defers to Step 0" "$DEV" "$RULES" \
  'in scope by definition unless Step 0'
rule "the scope rule names where Step 0 lives" "$DEV" "$RULES" "$DISP_LINK"
rule "the round contract's fix-whatever-the-round defers to Step 0" "$DEV" "$ROUND" \
  'unless Step 0 of the disposition flow excludes it'

# The pointer resolves. A rule that defers to a step behind a dead link states
# nothing an agent can follow. `check` carries no automatic control, so the
# planted one below is this check's teeth.
resolves() { [ -f "$DEV_DIR/$1" ]; }
check "the Step 0 pointer resolves to a file" resolves "$DISP_LINK"
check "the pointer check flags a target that is not there" \
  test -z "$(resolves "${DISP_LINK%.md}-renamed.md" && echo held)"

md_report
