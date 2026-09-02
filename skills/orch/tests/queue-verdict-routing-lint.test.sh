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
# Every check runs once per tree: the sources under skills/ and the committed
# render under .agents/skills/, which is the copy a lane reads — the file-scoped
# checks included, registered per tree rather than against this suite's own
# location: `tools/guard` enforces render presence, not byte equality.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/md.sh"

case "$SKILLS_ROOT" in
  */.agents/skills) TREE_ROOT="$(cd "$SKILLS_ROOT/../.." && pwd)" ;;
  *) TREE_ROOT="$(cd "$SKILLS_ROOT/.." && pwd)" ;;
esac
ROOTS=("$TREE_ROOT/skills" "$TREE_ROOT/.agents/skills")

echo "=== orch queue-wait verdict routing lint ==="

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

# The lane waits in the FOREGROUND. A handoff lane sitting at its prompt has no
# next boundary, so a verdict published behind it waits for a human.
#
# The unit judged is the fenced BLOCK, not the line. A line predicate can only
# ever close the spellings that fit on one line: a launcher can sit above the
# call behind a backslash, and a subshell can close below it with `) > F &`,
# and neither of those lines carries the waiter's name for a line harvest to
# find. Judging the block makes that family unrepresentable rather than
# enumerated — the block holding the waiter must hold ONE executable line, and
# that line must BE the blocking call — so there is nowhere for a launcher, a
# redirection, a backgrounding or a wrapper to sit that the check does not
# read. Comment-only and blank lines are not executable and `fenced` already
# drops them.
#
# The poll and budget positionals are admitted and required. Their VALUES are
# not pinned — the ceiling that sizes them belongs to the harness and the floor
# to QUEUE_WAIT_ARM_GRACE, neither of which is this file's to transcribe — but
# their presence is: the default budget outlives any foreground call an agent
# harness will hold, so a call that drops them is killed with nothing routable
# on stdout.
BLOCKING_CALL='^[[:space:]]*(\[MAIN_REPO_ROOT\]/)?\.agents/skills/orch/scripts/queue-wait \[PR_NUMBER\] [0-9]+ [0-9]+ --json[[:space:]]*$'

# waiter_blocks DOC — every executable line of every fenced block naming the
# waiter, as "blockid<TAB>lineno<TAB>text". A block is named by its opening
# fence's line number, so lines of one block share a first field.
waiter_blocks() { # doc
  local rows ids
  rows="$(fenced "$1")"
  ids="$(grep -F '/queue-wait' <<<"$rows" | cut -f1 | sort -u || true)"
  [ -n "$ids" ] || return 0
  awk -F'\t' -v ids="$ids" '
    BEGIN { n = split(ids, a, "\n"); for (i = 1; i <= n; i++) if (a[i] != "") keep[a[i]] = 1 }
    ($1 in keep)' <<<"$rows"
}
lane_wait_is_foreground() { # doc
  local rows blocks lines
  rows="$(waiter_blocks "$1")"
  blocks="$(awk -F'\t' '{ print $1 }' <<<"$rows" | sort -u | awk 'NF' | wc -l)"
  if [ "$blocks" -ne 1 ]; then
    printf '        %s fenced block(s) name the waiter; the lane runs exactly one:\n' "$blocks"
    cut -f3- <<<"$rows" | sed 's/^/          /'
    return 1
  fi
  lines="$(awk 'NF' <<<"$rows" | wc -l)"
  if [ "$lines" -ne 1 ]; then
    printf '        the waiter block holds %s executable lines; the call stands alone:\n' "$lines"
    cut -f3- <<<"$rows" | sed 's/^/          /'
    return 1
  fi
  grep -qE "$BLOCKING_CALL" <<<"$(cut -f3- <<<"$rows")" && return 0
  printf '        the waiter call is not the bare blocking form: %s\n' "$(cut -f3- <<<"$rows")"
  return 1
}

# The mutant's own control: a sed that matched nothing would leave an identical
# copy, and three green "reds" assertions would then be reporting a mutation
# that never happened.
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
  check "$label: queue-wait --help's verdict enum is the set its code emits" \
    enum_matches_code "$qw"
  check "$label: every verdict's route is one row, not several" \
    one_row_per_verdict "$doc"
  check "$label: the lane's queue wait is a blocking foreground call" \
    lane_wait_is_foreground "$doc"
  # `worktree remove` runs `git worktree remove --force` and then `rm -rf`, so
  # it issues no dirty-tree refusal of its own: step 6's own re-read is the
  # only thing between a build artifact and its deletion. Step 4 judged the
  # tree two steps earlier, so its check does not stand in for this one.
  rule_fenced "$label: the removal step re-reads the tree before removing it" \
    "$doc" "## 5. Execute The Merge" \
    'status' '--porcelain' '[WT_PATH]'
  # Both merge attempts name the head the gate approved. Without the flag the
  # call arms whatever head GitHub reports at that moment, which is the head a
  # push landed after the approval.
  rule_fenced "$label: the direct merge is exact-head guarded" \
    "$doc" "## 5. Execute The Merge" \
    '[--force]' 'pr-merge' '--expected-head' '[PREPARED_HEAD]'
  rule_fenced "$label: the auto-merge arm is exact-head guarded" \
    "$doc" "## 5. Execute The Merge" \
    '--auto' 'pr-merge' '--expected-head' '[PREPARED_HEAD]'
  # Absolute, because the lane is standing in the tree being removed.
  rule_fenced "$label: the worktree removal runs from the main repository" \
    "$doc" "## 5. Execute The Merge" \
    '[MAIN_REPO_ROOT]/' 'worktree remove' '[ISSUE]'
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

# The blocking call's own line, harvested rather than written down, so a
# retuned budget does not have to be edited into this suite.
CALL_LINE="$(waiter_blocks "$CTL_DOC" | cut -f3-)"

# A plant that matched nothing would leave an identical file, and every `reds`
# assertion below it would report a mutation that never happened.
planted() { # FILE
  cmp -s "$CTL_DOC" "$1" || return 0
  printf '        nothing was planted in %s\n' "$1"
  return 1
}

# One planted arm per spelling the predicate has to close. The first two are
# the shapes measured as surviving the `&`-only check; the rest are the family
# around them. Each is planted BESIDE the blocking call, which the count half
# alone would catch, and again REPLACING it, which only the shape half can.
plant() { # MODE NAME LINE — MODE `beside` appends, `instead` substitutes
  local f="$MD_TMP/merge-pr-$1-$2.md"
  if [ "$1" = beside ]; then
    awk -v line="$3" -v want="$CALL_LINE" '{ print } $0 == want { print line }' "$CTL_DOC" > "$f"
  else
    awk -v line="$3" -v want="$CALL_LINE" '{ if ($0 == want) print line; else print }' "$CTL_DOC" > "$f"
  fi
  printf '%s' "$f"
}

CALL='[MAIN_REPO_ROOT]/.agents/skills/orch/scripts/queue-wait [PR_NUMBER] 30 540 --json'
for arm in \
  "setsid|   setsid $CALL > [VERDICT_FILE]" \
  "redirect|   $CALL > [VERDICT_FILE]" \
  "nohup|   nohup $CALL > [VERDICT_FILE] &" \
  "subshell|   ( $CALL > [VERDICT_FILE] ) &" \
  "nobudget|   [MAIN_REPO_ROOT]/.agents/skills/orch/scripts/queue-wait [PR_NUMBER] --json" \
  "trailing|   $CALL  # and then some" \
; do
  name="${arm%%|*}"; line="${arm#*|}"
  for mode in beside instead; do
    case "$mode" in beside) where="beside the call" ;; *) where="in place of the call" ;; esac
    f="$(plant "$mode" "$name" "$line")"
    check "control: the $name arm was really planted $where" planted "$f"
    check "control: a $name arm $where reds the foreground check" \
      reds lane_wait_is_foreground "$f"
  done
done

# The two multiline shapes a line harvest cannot see: neither planted line
# carries the waiter's name, so both are evidence for judging the block rather
# than the line. They are controls, not the mechanism — the mechanism is that
# the block holds one executable line.
plant_around() { # NAME BEFORE AFTER
  local f="$MD_TMP/merge-pr-around-$1.md"
  awk -v before="$2" -v after="$3" -v want="$CALL_LINE" '
    $0 == want { if (before != "") print before; print; if (after != "") print after; next }
    { print }' "$CTL_DOC" > "$f"
  printf '%s' "$f"
}
CONT="$(plant_around continuation '   nohup \\' '')"
check "control: the continued launcher was really planted" planted "$CONT"
check "control: a backslash-continued launcher above the call reds" \
  reds lane_wait_is_foreground "$CONT"

WRAP="$(plant_around subshell '   (' '   ) > [VERDICT_FILE] &')"
check "control: the wrapping subshell was really planted" planted "$WRAP"
check "control: a subshell closing below the call reds" \
  reds lane_wait_is_foreground "$WRAP"

NO_WAIT="$MD_TMP/merge-pr-no-wait.md"
awk -v want="$CALL_LINE" '$0 != want' "$CTL_DOC" > "$NO_WAIT"
check "control: the deletion really removed the call" planted "$NO_WAIT"
check "control: deleting the blocking call reds the same check" \
  reds lane_wait_is_foreground "$NO_WAIT"

# The producer control, and the reason the harvest reads the code: an emit site
# renamed with --help left alone. Harvesting the help text leaves every check
# green here while the lane hits a verdict with no route and the table keeps a
# row nothing produces. The mutant is a whole copy of the script, and its libs
# are linked so the copy still sources them.
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

# The harvest's own control: a renamed table header takes the whole range with
# it, and both set comparisons then pass on nothing.
NO_TABLE="$MD_TMP/merge-pr-no-table.md"
sed 's/^   | `verdict` | Route |$/   | `outcome` | Route |/' "$CTL_DOC" > "$NO_TABLE"
check "control: a renamed table header reds the read check" \
  reds table_is_read "$NO_TABLE"

md_report
