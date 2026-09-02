#!/usr/bin/env bash
# Every verdict `queue-wait --json` can produce has a route in `merge-pr.md`
# § 5 step 1, and every row of that table names a verdict queue-wait can
# produce. The lane blocks on the wait and routes what it prints with nothing
# in between, so a producer verdict with no row is a lane that stops at a value
# it cannot act on, and a row naming no producer is a route nothing reaches.
#
# The producer set is read from queue-wait's CODE — the literal every
# `emit_result` and `note_candidate` call site names — not from its `--help`.
# Harvesting the help text makes this a doc-vs-doc check: change an emit site
# and leave the help alone and both directions stay green while the lane hits a
# verdict with no route and the table keeps a dead row, which is the pair of
# failures this file exists to prevent. The help's own `"verdict":` enum is
# checked against the code separately, so the claim that it is the complete set
# is enforced rather than trusted. Every list is read at run time and none is
# written down here.
#
# One row per verdict is checked separately. Coverage is a set question and
# cannot see multiplicity: split a verdict across two rows and deleting either
# one leaves both directions green.
#
# WHAT THIS FILE DOES NOT DO is pin the workflow's prose or its command lines.
# A suite asserting that a sentence or an invocation still reads a certain way
# is the shape KEN-1090 removed from md.sh, and it does not return here behind
# a local helper. The routing table is data — a set of verdict names — and that
# set is the whole of what is checked.
#
# Both trees are read: the sources under skills/ and the committed render under
# .agents/skills/, which is the copy a lane reads. `tools/guard` enforces render
# presence, not byte equality, so the render is read rather than assumed.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/md.sh"

case "$SKILLS_ROOT" in
  */.agents/skills) TREE_ROOT="$(cd "$SKILLS_ROOT/../.." && pwd)" ;;
  *) TREE_ROOT="$(cd "$SKILLS_ROOT/.." && pwd)" ;;
esac
ROOTS=("$TREE_ROOT/skills" "$TREE_ROOT/.agents/skills")

echo "=== orch queue-wait verdict routing lint ==="

# These are predicates md.sh has no rule form for — they compare two lists read
# at run time — so they report through `pass`/`fail`, which is what a suite
# reaching its own verdict is given.
check() { # NAME CMD...
  local name="$1"; shift
  if "$@"; then pass "$name"; else fail "$name"; fi
}
# The planted run's own diagnostic is the expected answer here, not a finding.
reds() { ! "$@" >/dev/null 2>&1; }

# The verdicts queue-wait can put in a result object, read off its call sites:
# the second literal of every `emit_result "<status>" "<verdict>"` and the
# first of every `note_candidate "<verdict>"`. The one emit site taking a
# variable, `emit_result "complete" "$candidate_verdict"`, matches neither
# pattern and needs no case: every value it can carry is a note_candidate
# literal, which is where a candidate verdict is named.
verdicts() { # queue-wait
  grep -oE '(emit_result "[a-z_]+" "[a-z_]+"|note_candidate "[a-z_]+")' "$1" \
    | sed -e 's/^emit_result "[a-z_]*" "//' -e 's/^note_candidate "//' -e 's/"$//' \
    | sort -u
}

# The `"verdict":` field of the JSON block in --help, which runs until the line
# the field's value ends on. The field name is stripped off the first line
# before the value tokens are harvested.
enum_verdicts() { # queue-wait
  "$1" --help 2>/dev/null \
    | sed -n '/^ *"verdict":/,/,$/p' \
    | sed '1s/^[^:]*://' \
    | grep -o '"[a-z_][a-z_]*"' \
    | tr -d '"' \
    | sort -u
}
enum_matches_code() { # queue-wait
  local diff
  diff="$(comm -3 <(verdicts "$1") <(enum_verdicts "$1"))"
  [ -z "$diff" ] && return 0
  printf '        --help enum and emit sites disagree (left code-only, right help-only):\n'
  sed 's/^/          /' <<<"$diff"
  return 1
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
routes() { route_labels "$1" | sort -u; }

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
  check "$label: queue-wait --help's verdict enum is the set its code emits" \
    enum_matches_code "$qw"
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

# A plant that matched nothing would leave an identical file, and every `reds`
# assertion below it would report a mutation that never happened.
planted() { # FILE
  cmp -s "$CTL_DOC" "$1" || return 0
  printf '        nothing was planted in %s\n' "$1"
  return 1
}

DROPPED="$MD_TMP/merge-pr-dropped.md"
one_verdict="$(verdicts "$CTL_QW" | sed -n 1p)"
grep -v "^   | \`$one_verdict\` |" "$CTL_DOC" > "$DROPPED"
check "control: the row deletion really removed a row" planted "$DROPPED"
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

# The producer control, and the reason the harvest reads the code: an emit site
# renamed with --help left alone. Harvesting the help text leaves every check
# green here while the lane hits a verdict with no route and the table keeps a
# row nothing produces. The mutant is a whole copy of the script, and its libs
# are linked so the copy still sources them.
#
# It carries its own control too: a sed that matched nothing would leave an
# identical copy, and three green `reds` assertions would then be reporting a
# mutation that never happened.
planted_one_rename() { # original mutant
  local before after
  before="$(verdicts "$1")"
  after="$(verdicts "$2")"
  [ "$before" != "$after" ] || {
    printf '        the mutant emits the same verdict set as the original\n'
    return 1
  }
  [ "$(comm -3 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | wc -l)" -eq 2 ] || {
    printf '        the mutant changed more than the one emit site\n'
    return 1
  }
}
MUT_DIR="$MD_TMP/scripts"
mkdir -p "$MUT_DIR"
ln -s "$(dirname "$CTL_QW")/lib" "$MUT_DIR/lib"
MUT_QW="$MUT_DIR/queue-wait"
sed 's/emit_result "complete" "closed"/emit_result "complete" "abandoned"/' \
  "$CTL_QW" > "$MUT_QW"
chmod +x "$MUT_QW"
check "control: the mutant renames exactly one emit site" \
  planted_one_rename "$CTL_QW" "$MUT_QW"
check "control: a renamed emit site reds the coverage direction" \
  reds every_verdict_routed "$MUT_QW" "$CTL_DOC"
check "control: that same rename reds the vocabulary direction" \
  reds every_route_real "$MUT_QW" "$CTL_DOC"
check "control: that same rename reds the enum-against-code check" \
  reds enum_matches_code "$MUT_QW"

md_report
