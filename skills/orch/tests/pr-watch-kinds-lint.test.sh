#!/usr/bin/env bash
# The kind checks compare `workflows/oversee.md`'s pr-watch handler list with
# the kinds `review-gate/scripts/pr-watch.sh --help` documents, in both
# directions, and hold each kind to exactly one rule. The flag checks read the `--heal` line of that same `--help` and
# the parser arm that accepts the flag. Both lists are read at run time and
# neither is written down here.
#
# Every check runs once per tree: the sources under skills/ and the committed
# render under .agents/skills/, which is the copy the shipped watcher reads.
# One invocation covers both, and the roots it checked are named in the output.
# Per tree, review-gate absent skips; installed with an unusable reducer fails.
#
# A bullet's LABEL is its leading code spans, comma-separated — not every span
# before the arrow. A kind named in a bullet's condition is that bullet's
# subject, not its handler: harvesting it would let the standalone handler for
# that kind be deleted with both directions still green.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/md.sh"

# Both trees, resolved from wherever this copy sits.
case "$SKILLS_ROOT" in
  */.agents/skills) TREE_ROOT="$(cd "$SKILLS_ROOT/../.." && pwd)" ;;
  *) TREE_ROOT="$(cd "$SKILLS_ROOT/.." && pwd)" ;;
esac
ROOTS=("$TREE_ROOT/skills" "$TREE_ROOT/.agents/skills")

echo "=== orch pr-watch kind coverage lint ==="

# The kinds the reducer documents: the `Attention kinds:` block of its --help,
# one kind per line at exactly two spaces of indent. Continuation lines are
# indented deeper and never match.
kinds() { # pr-watch
  "$1" --help 2>/dev/null \
    | sed -n '/^Attention kinds:/,/^$/p' \
    | sed -n 's/^  \([a-z][a-z-]*\) \{1,\}[^ ].*/\1/p' \
    | sort -u
}

# The kinds the document handles: the leading code spans of every `  - ` bullet
# in the pr-watch handler list, one comma-separated run per bullet. Everything
# past that run is condition and action text. Emitted with duplicates intact —
# the contract is one rule per kind, and a label leading two bullets is what
# `sort -u` would hide.
handler_labels() { # doc
  sed -n '/^- `pr-watch` →/,/^- [^ ]/p' "$1" \
    | sed -n 's/^  - //p' \
    | grep -oE '^`[a-z][a-z-]*`(, `[a-z][a-z-]*`)*' \
    | grep -o '`[a-z][a-z-]*`' \
    | tr -d '`'
}
handlers() { handler_labels "$1" | sort -u; }

# Reported as names, not counts.
every_kind_handled() { # pr-watch doc
  local missing
  missing="$(comm -23 <(kinds "$1") <(handlers "$2"))"
  [ -z "$missing" ] && return 0
  printf '        kinds with no handler bullet: %s\n' "$(tr '\n' ' ' <<<"$missing")"
  return 1
}
# Coverage is a set question and cannot see multiplicity: two bullets sharing a
# label leave the kind covered by whichever survives, so deleting the general
# rule for it passes every set comparison. One rule per kind is checked here.
one_rule_per_kind() { # doc
  local dupes
  dupes="$(handler_labels "$1" | sort | uniq -d)"
  [ -z "$dupes" ] && return 0
  printf '        labels leading more than one bullet: %s\n' "$(tr '\n' ' ' <<<"$dupes")"
  return 1
}
every_handler_real() { # pr-watch doc
  local extra
  extra="$(comm -13 <(kinds "$1") <(handlers "$2"))"
  [ -z "$extra" ] && return 0
  printf '        handler bullets naming no documented kind: %s\n' "$(tr '\n' ' ' <<<"$extra")"
  return 1
}

# The flag oversee-watch passes, read in both halves. The parser arm is
# anchored to its case-arm shape: a comment line holding the same literal is
# not an arm.
heal_documented() { "$1" --help 2>/dev/null | grep -q -- '^  --heal '; }
heal_parsed() { grep -qE '^[[:space:]]*--heal\)' "$1"; }

# The planted run's own diagnostic is dropped: it is the expected answer here,
# not a finding.
reds() { ! "$@" >/dev/null 2>&1; }

reducer_usable() { [ -x "$1" ]; }

checked=0
for root in "${ROOTS[@]}"; do
  gate="$root/review-gate"
  pw="$gate/scripts/pr-watch.sh"
  doc="$root/orch/workflows/oversee.md"
  label="${root#$TREE_ROOT/}"
  if [ ! -d "$root" ] || [ ! -d "$gate" ]; then
    echo "  skip  $label: review-gate is not installed there; nothing to compare"
    continue
  fi
  check "$label: the installed review-gate's reducer is readable at $pw" \
    reducer_usable "$pw"
  reducer_usable "$pw" || continue
  checked=$((checked + 1))

  check "$label: every pr-watch kind has a handler bullet in oversee.md" \
    every_kind_handled "$pw" "$doc"
  check "$label: every handler bullet names a kind pr-watch --help documents" \
    every_handler_real "$pw" "$doc"
  check "$label: every kind's rule is one bullet, not several" \
    one_rule_per_kind "$doc"
  check "$label: pr-watch still documents the --heal flag oversee-watch passes" \
    heal_documented "$pw"
  check "$label: pr-watch still parses the --heal flag oversee-watch passes" \
    heal_parsed "$pw"
done

if [ "$checked" -eq 0 ]; then
  echo "  note  no tree carried a usable reducer; nothing was compared"
  md_report
  exit $?
fi

# Controls, planted against the first usable tree — the grammar and the two
# directions are the same for every tree, so proving them once proves them.
for root in "${ROOTS[@]}"; do
  [ -x "$root/review-gate/scripts/pr-watch.sh" ] || continue
  CTL_PW="$root/review-gate/scripts/pr-watch.sh"
  CTL_DOC="$root/orch/workflows/oversee.md"
  break
done

DROPPED="$MD_TMP/oversee-dropped.md"
one_kind="$(kinds "$CTL_PW" | head -1)"
grep -v "^  - \`$one_kind\`" "$CTL_DOC" > "$DROPPED"
check "control: a deleted handler bullet reds the coverage direction" \
  reds every_kind_handled "$CTL_PW" "$DROPPED"

# The label grammar's own control. `error` is named twice — once as the subject
# of the gate-stale-beside-error bullet and once as its own handler — so a
# grammar harvesting every span before the arrow keeps both directions green
# after the STANDALONE handler is deleted, and ordinary read failures lose
# their rule with nothing red.
NO_ERROR="$MD_TMP/oversee-no-error.md"
grep -v '^  - `error` →' "$CTL_DOC" > "$NO_ERROR"
check "control: deleting the standalone error handler reds the coverage direction" \
  reds every_kind_handled "$CTL_PW" "$NO_ERROR"

# gate-stale is the kind whose rule was split across two bullets, where the set
# comparisons went on passing with the general rule deleted.
NO_STALE="$MD_TMP/oversee-no-gate-stale.md"
grep -v '^  - `gate-stale`' "$CTL_DOC" > "$NO_STALE"
check "control: deleting the gate-stale rule reds the coverage direction" \
  reds every_kind_handled "$CTL_PW" "$NO_STALE"

DUPED="$MD_TMP/oversee-duped.md"
awk '{ print }
  /^  - `gate-stale` →/ { print "  - `gate-stale` beside anything → a second rule for one kind" }' \
  "$CTL_DOC" > "$DUPED"
check "control: a label leading two bullets reds the one-rule direction" \
  reds one_rule_per_kind "$DUPED"
check "control: that same duplicate leaves the coverage direction green" \
  every_kind_handled "$CTL_PW" "$DUPED"

BOGUS="$MD_TMP/oversee-bogus.md"
awk '{ print }
  /^- `pr-watch` →/ { print "  - `no-such-kind` → invented for the control" }' \
  "$CTL_DOC" > "$BOGUS"
check "control: an invented handler bullet reds the vocabulary direction" \
  reds every_handler_real "$CTL_PW" "$BOGUS"

# Controls for both flag halves, planted INERT rather than deleted: the failure
# that reaches production is a rename that leaves the old spelling behind in
# prose.
FLAG_DIR="$MD_TMP/scripts"
mkdir -p "$FLAG_DIR"
ln -s "$(dirname "$CTL_PW")/lib" "$FLAG_DIR/lib"

RENAMED_ARM="$FLAG_DIR/pr-watch-renamed-arm.sh"
awk '/^[[:space:]]*--heal\)/ { print "    # the old --heal) arm, renamed"
                               sub(/--heal\)/, "--healx)") }
     { print }' "$CTL_PW" > "$RENAMED_ARM"
chmod +x "$RENAMED_ARM"
check "control: a renamed arm whose literal survives in a comment reds the parser check" \
  reds heal_parsed "$RENAMED_ARM"
check "control: that same rename leaves the usage check green" \
  heal_documented "$RENAMED_ARM"

RENAMED_USAGE="$FLAG_DIR/pr-watch-renamed-usage.sh"
awk '{ sub(/^  --heal /, "  --healx ") } { print }' "$CTL_PW" > "$RENAMED_USAGE"
chmod +x "$RENAMED_USAGE"
check "control: a renamed usage line reds the usage check" \
  reds heal_documented "$RENAMED_USAGE"
check "control: that same rename leaves the parser check green" \
  heal_parsed "$RENAMED_USAGE"

md_report
