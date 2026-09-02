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
# The lane waits in the FOREGROUND, and the rules holding that are md.sh's own
# `forbid_fenced`, not a predicate of this file. A handoff lane sitting at its
# prompt has no next boundary, so a verdict published behind it waits for a
# human. Each of the three is stated as a negative — the deviation, never the
# list of spellings that reach it — which is what lets a line scan reach the
# multiline shapes: a launcher continued with a backslash and a subshell
# closing `) > F &` are both caught without the check having to find the waiter
# on the offending line.
#
# What NONE of them reaches is a second, non-detaching command sharing the
# waiter's fenced block. `forbid_fenced` reads lines, md.sh's public surface
# exposes no block reader, and reaching into the underscore-private one is not
# this suite's to do. Every extra line that could take the wait out of the
# foreground is caught by the first rule; a plain extra command there is
# untidy and not a defect, and this file claims no more than that.
#
# Every check runs once per tree: the sources under skills/ and the committed
# render under .agents/skills/, which is the copy a lane reads — the
# file-scoped rules included, registered per tree rather than against this
# suite's own location: `tools/guard` enforces render presence, not byte
# equality.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/md.sh"

case "$SKILLS_ROOT" in
  */.agents/skills) TREE_ROOT="$(cd "$SKILLS_ROOT/../.." && pwd)" ;;
  *) TREE_ROOT="$(cd "$SKILLS_ROOT/.." && pwd)" ;;
esac
ROOTS=("$TREE_ROOT/skills" "$TREE_ROOT/.agents/skills")

echo "=== orch queue-wait verdict routing lint ==="

# The set comparisons below are predicates md.sh has no rule form for — they
# compare two lists read at run time — so they report through `pass`/`fail`,
# which is what a suite reaching its own verdict is given.
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

# § 5 alone, written out so the fenced scans below can be scoped to it: the
# clearing rule is the merge section's, and §§ 1-4's reads are outside this
# change. `forbid_fenced` takes files, not headings, so the section becomes a
# file. The name carries the tree it came from, because a diagnostic naming
# the scratch has to say which copy was read.
section_five() { # doc label
  local out="$MD_TMP/${2//\//-}-merge-pr-section-5.md"
  awk '/^## 5\./ { s = 1 } /^## 6\./ { s = 0 } s' "$1" > "$out"
  printf '%s' "$out"
}

# Anything that takes a command out of the foreground, off one line, or off
# stdout. One property rather than a list of spellings: a launcher word, a
# trailing `&`, a trailing backslash, a line that only opens a subshell, and a
# waiter call redirected anywhere. The first four never mention the waiter,
# which is the point — they reach the multiline shapes a test looking for the
# waiter's own line cannot see.
DETACHED_RE='(^|[[:space:]])(setsid|nohup|disown)[[:space:]]|[^&]&[[:space:]]*$|\\[[:space:]]*$|^[[:space:]]*\([[:space:]]*$|/queue-wait[^>]*>'

# Every command in the workflow that reaches GitHub opens with both repository
# variables cleared: gh honours them over cwd and over `-C`, so an inherited
# value points a read at another repository and a mutation at that
# repository's same-numbered PR. Expressed as the complement of the required
# opener, so a call added later is covered without being listed. The first
# branch is a first-word mismatch against `env`, four alternatives because the
# word is three characters; the second catches an `env` that clears only one
# of the pair.
GH_CMD='(gh[[:space:]]|[^[:space:]]*github\.sh[[:space:]]|[^[:space:]]*/queue-wait[[:space:]])'
UNBOUND_RE="^[[:space:]]*([^e[:space:]]|e[^n]|en[^v]|env[^[:space:]]).*$GH_CMD|^[[:space:]]*env[[:space:]]+(-u[[:space:]]+(GH_REPO|GITHUB_REPOSITORY)[[:space:]]+)?$GH_CMD"

# The waiter runs exactly as written, which `rule_fenced` cannot say: it asks
# only that one line CONTAIN its tokens, so a wrapper before the command and a
# dropped positional both satisfy it. Three deviations, none of them a
# launcher name: nothing between the clearing and the waiter path, both
# positionals present, and nothing after `--json`. With the budget gone the
# call runs to queue-wait's own default, which no agent harness holds long
# enough to reach a verdict — the defect that cost two rounds.
#
# What this does NOT reach is a second, non-detaching command sharing the
# waiter's fenced block, because `forbid_fenced` reads lines and not blocks.
# Every shape of that kind which could detach the wait — a continued launcher,
# a subshell, a backgrounded sibling — is caught by DETACHED_RE instead; an
# ordinary extra command there is untidy and not a defect.
WAITER_SHAPE_RE='GITHUB_REPOSITORY[[:space:]]+[^[:space:][].*/queue-wait|/queue-wait[[:space:]]+\[PR_NUMBER\][[:space:]]+--json|/queue-wait.*--json[[:space:]]*[^[:space:]]'

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

  # The lane's own wait, and the whole detach family around it.
  # The repository binding rides the same line: `queue-wait` resolves its
  # target with a bare `gh repo view`, and its late-findings guard disarms and
  # dequeues, so an inherited GH_REPO would send those mutations at another
  # repository's same-numbered PR. Every other gh call in this step clears the
  # pair; this one is the mutating waiter.
  rule_fenced "$label: the lane blocks on a budgeted queue-wait, repo bound" \
    "$doc" "## 5. Execute The Merge" \
    '/queue-wait' '[PR_NUMBER]' '--json' '-u GH_REPO' '-u GITHUB_REPOSITORY'
  forbid_fenced "$label: no command in the workflow leaves the foreground" \
    "$DETACHED_RE" \
    'setsid queue-wait [PR_NUMBER] --json > [VERDICT_FILE] &' \
    "$doc"
  five="$(section_five "$doc" "$label")"
  forbid_fenced "$label: every § 5 command reaching GitHub clears both repo variables" \
    "$UNBOUND_RE" \
    '[MAIN_REPO_ROOT]/.agents/skills/github/scripts/github.sh -C [MAIN_REPO_ROOT] pr-threads [PR_NUMBER] --unresolved' \
    "$five"
  forbid_fenced "$label: the queue wait runs exactly as written" \
    "$WAITER_SHAPE_RE" \
    'env -u GH_REPO -u GITHUB_REPOSITORY [MAIN_REPO_ROOT]/.agents/skills/orch/scripts/queue-wait [PR_NUMBER] --json' \
    "$five"

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

# Controls for the set comparisons, planted against the first usable tree — the
# grammar and the two directions are the same for every tree, so proving them
# once proves them. The md.sh rules above carry their own controls.
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
