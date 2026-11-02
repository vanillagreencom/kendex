#!/usr/bin/env bash
# The github router has no `ci-wait` command: the CI wait is the runtime's
# `verify-pr`, and the orch script `.agents/skills/orch/scripts/ci-wait` runs
# only as `queue-wait`'s failed-check probe. A doc naming `ci-wait` bare, with
# no path, lets an orchestrator relaying it beside `github.sh` commands
# resolve it to the wrong wrapper. dev and github are required orch
# dependencies, so both trees are present wherever orch is installed and
# both are scanned.
#
# The three CI waits are pinned beside that: each is a fenced `verify-pr`
# request over the required set alone; each reruns a transient runner
# failure once per head through the github skill's `ci-rerun`, the item's
# `ci_rerun` record written before the verb is asked (a record written
# after the act, or not at all, is a rerun that can fire twice on one head);
# and submit-pr's § 5 table routes a conflicting pull request before any
# wait, the row the merge-state read's `CONFLICTING` lands on.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/md.sh"

echo "=== orch/dev/github ci-wait routing lint ==="

# The surface is every markdown file in the three skills, two levels deep: a
# README, a DEVELOPMENT note or a schema can relay a bad route as readily as a
# workflow can, and this lint's claim is about any doc. Built by `find` rather
# than by a glob list so a directory is covered the day it appears; a `find`
# that returns nothing leaves the list empty, which `forbid` refuses.
DOCS=()
while IFS= read -r -d '' doc; do
  DOCS+=("$doc")
done < <(find "$SKILL_DIR" "$SKILLS_ROOT/dev" "$SKILLS_ROOT/github" \
  -maxdepth 2 -type f -name '*.md' -not -path '*/tests/*' -print0 | LC_ALL=C sort -z)

# Whitespace is matched by class, not by one literal space: a run of spaces or
# a tab between the router and the subcommand is the same bad route.
forbid "no doc routes ci-wait through github.sh" \
  'github\.sh[[:space:]]+(-C[[:space:]]+[^[:space:]]+[[:space:]]+)?ci[-_]?wait' \
  'Wait for CI with `github.sh  ci-wait 296 --json`.' \
  ${DOCS+"${DOCS[@]}"}

# These are predicates md.sh has no rule form for — an order of two command
# lines — so they report through `pass`/`fail`, which is what a suite
# reaching its own verdict is given.
check() { # NAME CMD...
  local name="$1"; shift
  if "$@"; then pass "$name"; else fail "$name"; fi
}
# The planted copy's own diagnostic is the expected answer here, not a finding.
reds() { ! "$@" >/dev/null 2>&1; }

READ_RE="workflow-state get \[[A-Z_]+\] '\.ci_rerun\.head"
RECORD_RE='workflow-state set \[[A-Z_]+\] ci_rerun '
ASK_RE='ci-rerun \[PR_NUMBER\] --required-only'

# first_line RE FILE — the number of the first line matching RE, or nothing.
first_line() { # RE FILE
  grep -n -m 1 -E "$1" "$2" | cut -d: -f1 || true
}

# record_before_ask FILE — the first `ci_rerun` record line stands before the
# first `ci-rerun` ask line. A missing line on either side is a failure, not
# an order.
record_before_ask() { # FILE
  local record ask
  record="$(first_line "$RECORD_RE" "$1")"
  ask="$(first_line "$ASK_RE" "$1")"
  [ -n "$record" ] && [ -n "$ask" ] && [ "$record" -lt "$ask" ]
}

# read_before_record FILE — the first `.ci_rerun.head` read stands before the
# first record line: the read is what makes the rule once per head, and a
# wait that records without it reruns every red of a head already rerun.
read_before_record() { # FILE
  local head_read record
  head_read="$(first_line "$READ_RE" "$1")"
  record="$(first_line "$RECORD_RE" "$1")"
  [ -n "$head_read" ] && [ -n "$record" ] && [ "$head_read" -lt "$record" ]
}

# The three CI waits are `verify-pr` requests; register the required-set
# token first so the shared fenced-rule control drops it and proves that no
# merge caller can omit it. Each wait then records the rerun on the item and
# asks the github skill for one required-only rerun, in that order.
for workflow in workflows/ci-fix.md workflows/submit-pr.md references/merge-attempt.md; do
  rule_fenced "$workflow verifies only required CI" \
    "$SKILL_DIR/$workflow" "" 'required_only: true' '"verify-pr"'
  rule_fenced "$workflow records the rerun on the item" \
    "$SKILL_DIR/$workflow" "" 'workflow-state set' "ci_rerun '{\"head\""
  rule_fenced "$workflow asks the github skill for one required-only rerun" \
    "$SKILL_DIR/$workflow" "" 'ci-rerun' '--required-only'
  check "$workflow writes the rerun record before the verb acts" \
    record_before_ask "$SKILL_DIR/$workflow"
done

# The once rule is the read: § 5.1 reads the head already rerun before it
# records and asks, and the verb keeps no count of its own. The two other
# waits defer to § 5.1's read by pointer and carry no read line, so the
# read is pinned where it runs.
rule_fenced "submit-pr.md § 5.1 reads the recorded rerun head" \
  "$SKILL_DIR/workflows/submit-pr.md" "### 5.1 CI Failure Recovery" 'workflow-state get' '.ci_rerun.head'
check "submit-pr.md reads the recorded head before it writes the record" \
  read_before_record "$SKILL_DIR/workflows/submit-pr.md"

# A conflicting pull request is routed before the wait: § 5's table carries
# the row the merge-state read lands on. The row is a route the lane takes,
# not a sentence.
rule "submit-pr.md § 5 routes a conflicting pull request" \
  "$SKILL_DIR/workflows/submit-pr.md" "## 5. Verify CI" '| `conflict` |'

# The control for the order predicate: the record line moved after the ask
# line, in a scratch copy of the first wait, must read as a record written
# after the act. A copy that matched nothing would equal the original, and the
# `reds` below would report a mutation that never happened; on a tree with no
# record line the rows above are already red and the plant reports itself.
CTL="$SKILL_DIR/workflows/submit-pr.md"
LATE="$MD_TMP/submit-pr-record-late.md"
grep -v -E "$RECORD_RE" "$CTL" >"$LATE" || true
grep -E "$RECORD_RE" "$CTL" >>"$LATE" || true
planted() { # FILE
  cmp -s "$CTL" "$1" || return 0
  printf '        nothing was planted in %s\n' "$1"
  return 1
}
check "control: the record line really moved" planted "$LATE"
check "control: a record written after the act reds the order check" \
  reds record_before_ask "$LATE"

# The control for the read predicate: the `.ci_rerun.head` read deleted from
# a scratch copy must read as a wait that records without reading, the
# rerun fired on every red of the head.
UNREAD="$MD_TMP/submit-pr-head-unread.md"
grep -v -E "$READ_RE" "$CTL" >"$UNREAD" || true
check "control: the read line really went" planted "$UNREAD"
check "control: a record written without the head read reds the read check" \
  reds read_before_record "$UNREAD"

md_report
