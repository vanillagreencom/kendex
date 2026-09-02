#!/usr/bin/env bash
# Every verdict `queue-wait --json` can produce has a route in `merge-pr.md`
# § 5 step 1, and every row of that table names a verdict queue-wait can
# produce. The lane reads the detached wait's verdict file and routes on it
# with nothing in between, so a producer verdict with no row is a lane that
# stops at a value it cannot act on, and a row naming no producer is a route
# nothing reaches.
#
# The producer set is read from queue-wait's `"verdict":` JSON enum rather than
# its § Verdicts prose: the enum is the complete set, `unknown` included, and
# `unknown` is the one the table must carry a refusal for. Both lists are read
# at run time and neither is written down here.
#
# One row per verdict is checked separately. Coverage is a set question and
# cannot see multiplicity: split a verdict across two rows and deleting either
# one leaves both directions green.
#
# Every check runs once per tree: the sources under skills/ and the committed
# render under .agents/skills/, which is the copy a lane reads.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/md.sh"

case "$SKILLS_ROOT" in
  */.agents/skills) TREE_ROOT="$(cd "$SKILLS_ROOT/../.." && pwd)" ;;
  *) TREE_ROOT="$(cd "$SKILLS_ROOT/.." && pwd)" ;;
esac
ROOTS=("$TREE_ROOT/skills" "$TREE_ROOT/.agents/skills")

echo "=== orch queue-wait verdict routing lint ==="

# The verdicts queue-wait can put in a result object: the `"verdict":` field of
# the JSON block in its --help, which runs until the line the field's value
# ends on. The field name is stripped off the first line before the value
# tokens are harvested.
verdicts() { # queue-wait
  "$1" --help 2>/dev/null \
    | sed -n '/^ *"verdict":/,/,$/p' \
    | sed '1s/^[^:]*://' \
    | grep -o '"[a-z_][a-z_]*"' \
    | tr -d '"' \
    | sort -u
}

# The verdicts merge-pr routes: the leading code span of every row of the
# routing table, which runs from its header line to the blank line after it.
# The header row itself is dropped — it is the range's first line. Duplicates
# are kept: one row per verdict is the contract, and `sort -u` would hide a
# split.
route_labels() { # doc
  sed -n '/^   | `verdict` | Route |/,/^$/p' "$1" \
    | sed '1d' \
    | sed -n 's/^   | `\([a-z_][a-z_]*\)` |.*/\1/p'
}
routes() { routes_of="$1"; route_labels "$routes_of" | sort -u; }

every_verdict_routed() { # queue-wait doc
  local missing
  missing="$(comm -23 <(verdicts "$1") <(routes "$2"))"
  [ -z "$missing" ] && return 0
  printf '        verdicts with no routing row: %s\n' "$(tr '\n' ' ' <<<"$missing")"
  return 1
}
every_route_real() { # queue-wait doc
  local extra
  extra="$(comm -13 <(verdicts "$1") <(routes "$2"))"
  [ -z "$extra" ] && return 0
  printf '        routing rows naming no queue-wait verdict: %s\n' "$(tr '\n' ' ' <<<"$extra")"
  return 1
}
one_row_per_verdict() { # doc
  local dupes
  dupes="$(route_labels "$1" | sort | uniq -d)"
  [ -z "$dupes" ] && return 0
  printf '        verdicts routed by more than one row: %s\n' "$(tr '\n' ' ' <<<"$dupes")"
  return 1
}
table_is_read() { # doc — an empty harvest passes both set comparisons
  [ -n "$(route_labels "$1")" ]
}

waiter_usable() { [ -x "$1" ]; }
# The planted run's own diagnostic is the expected answer here, not a finding.
reds() { ! "$@" >/dev/null 2>&1; }

checked=0
for root in "${ROOTS[@]}"; do
  qw="$root/orch/scripts/queue-wait"
  doc="$root/orch/workflows/merge-pr.md"
  label="${root#$TREE_ROOT/}"
  [ -d "$root/orch" ] || { echo "  skip  $label: orch is not installed there"; continue; }
  check "$label: queue-wait is executable at $qw" waiter_usable "$qw"
  waiter_usable "$qw" || continue
  checked=$((checked + 1))

  check "$label: the routing table was read at all" table_is_read "$doc"
  check "$label: every queue-wait verdict has a routing row in merge-pr.md" \
    every_verdict_routed "$qw" "$doc"
  check "$label: every routing row names a verdict queue-wait can produce" \
    every_route_real "$qw" "$doc"
  check "$label: every verdict's route is one row, not several" \
    one_row_per_verdict "$doc"
done

if [ "$checked" -eq 0 ]; then
  echo "  note  no tree carried a usable queue-wait; nothing was compared"
  md_report
  exit $?
fi

# Controls, planted against the first usable tree — the grammar and the two
# directions are the same for every tree, so proving them once proves them.
for root in "${ROOTS[@]}"; do
  [ -x "$root/orch/scripts/queue-wait" ] || continue
  CTL_QW="$root/orch/scripts/queue-wait"
  CTL_DOC="$root/orch/workflows/merge-pr.md"
  break
done

DROPPED="$MD_TMP/merge-pr-dropped.md"
one_verdict="$(verdicts "$CTL_QW" | head -1)"
grep -v "^   | \`$one_verdict\` |" "$CTL_DOC" > "$DROPPED"
check "control: a deleted routing row reds the coverage direction" \
  reds every_verdict_routed "$CTL_QW" "$DROPPED"

# The refusal row is the one a rewrite is likeliest to drop as redundant: it
# routes no work, only a handback.
NO_UNKNOWN="$MD_TMP/merge-pr-no-unknown.md"
grep -v '^   | `unknown` |' "$CTL_DOC" > "$NO_UNKNOWN"
check "control: deleting the unrecognized-verdict row reds the coverage direction" \
  reds every_verdict_routed "$CTL_QW" "$NO_UNKNOWN"

BOGUS="$MD_TMP/merge-pr-bogus.md"
awk '{ print }
  /^   \| `verdict` \| Route \|$/ { print "   | `no_such_verdict` | invented for the control |" }' \
  "$CTL_DOC" > "$BOGUS"
check "control: an invented routing row reds the vocabulary direction" \
  reds every_route_real "$CTL_QW" "$BOGUS"

DUPED="$MD_TMP/merge-pr-duped.md"
awk '{ print }
  /^   \| `queued` \|/ { print "   | `queued` | a second row for one verdict |" }' \
  "$CTL_DOC" > "$DUPED"
check "control: a verdict routed by two rows reds the one-row direction" \
  reds one_row_per_verdict "$DUPED"
check "control: that same duplicate leaves the coverage direction green" \
  every_verdict_routed "$CTL_QW" "$DUPED"

# The harvest's own control: a renamed table header takes the whole range with
# it, and both set comparisons then pass on nothing.
NO_TABLE="$MD_TMP/merge-pr-no-table.md"
sed 's/^   | `verdict` | Route |$/   | `outcome` | Route |/' "$CTL_DOC" > "$NO_TABLE"
check "control: a renamed table header reds the read check" \
  reds table_is_read "$NO_TABLE"

# The detached form is the one shape the lane starts; its verdict file is what
# the boundary read above resolves.
rule_fenced "the detached wait writes its verdict to the file the lane reads" \
  "$SKILL_DIR/workflows/merge-pr.md" "## 5. Execute The Merge" \
  'setsid' '/queue-wait' '[VERDICT_FILE]'

md_report
