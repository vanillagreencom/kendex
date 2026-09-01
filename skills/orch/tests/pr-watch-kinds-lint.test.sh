#!/usr/bin/env bash
# The kind checks compare `workflows/oversee.md`'s pr-watch handler list with
# the kinds `review-gate/scripts/pr-watch.sh --help` documents, in both
# directions. The flag checks read the `--heal` line of that same `--help` and
# the parser arm that accepts the flag. Both lists are read at run time and
# neither is written down here. review-gate absent skips; installed with an
# unusable reducer fails.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/md.sh"

REVIEW_GATE_DIR="$SKILLS_ROOT/review-gate"
PR_WATCH="$REVIEW_GATE_DIR/scripts/pr-watch.sh"
OVERSEE="$SKILL_DIR/workflows/oversee.md"

echo "=== orch pr-watch kind coverage lint ==="

if [ ! -d "$REVIEW_GATE_DIR" ]; then
  echo "  skip  review-gate is not installed ($REVIEW_GATE_DIR); nothing to compare"
  md_report
  exit $?
fi
reducer_usable() { [ -x "$PR_WATCH" ]; }
check "the installed review-gate's reducer is readable at $PR_WATCH" reducer_usable
reducer_usable || { md_report; exit $?; }

# The kinds the reducer documents: the `Attention kinds:` block of its --help,
# one kind per line at exactly two spaces of indent. Continuation lines are
# indented deeper and never match.
kinds() {
  "$PR_WATCH" --help 2>/dev/null \
    | sed -n '/^Attention kinds:/,/^$/p' \
    | sed -n 's/^  \([a-z][a-z-]*\) \+[^ ].*/\1/p' \
    | sort -u
}

# The kinds the document handles: every `  - ` bullet of the pr-watch handler
# list, reading only the part before the arrow. Past the arrow is the overseer's
# action, which names settings and details that are not kinds.
handlers() {
  sed -n '/^- `pr-watch` →/,/^- [^ ]/p' "$1" \
    | sed -n 's/^  - \(.*\)$/\1/p' \
    | sed 's/→.*//' \
    | grep -o '`[a-z][a-z-]*`' \
    | tr -d '`' \
    | sort -u
}

# Reported as names, not counts.
uncovered() { # doc — documented kinds with no handler bullet
  comm -23 <(kinds) <(handlers "$1")
}
unknown() { # doc — handler bullets naming no documented kind
  comm -13 <(kinds) <(handlers "$1")
}

every_kind_handled() {
  local missing
  missing="$(uncovered "$1")"
  [ -z "$missing" ] && return 0
  printf '        kinds with no handler bullet: %s\n' "$(tr '\n' ' ' <<<"$missing")"
  return 1
}
every_handler_real() {
  local extra
  extra="$(unknown "$1")"
  [ -z "$extra" ] && return 0
  printf '        handler bullets naming no documented kind: %s\n' "$(tr '\n' ' ' <<<"$extra")"
  return 1
}

check "every pr-watch kind has a handler bullet in oversee.md" every_kind_handled "$OVERSEE"
check "every handler bullet names a kind pr-watch --help documents" every_handler_real "$OVERSEE"

# Controls. The planted run's own diagnostic is dropped: it is the expected
# answer here, not a finding.
reds() { ! "$@" >/dev/null 2>&1; }

DROPPED="$MD_TMP/oversee-dropped.md"
one_kind="$(kinds | head -1)"
grep -v "^  - \`$one_kind\`" "$OVERSEE" > "$DROPPED"
check "control: a deleted handler bullet reds the coverage direction" \
  reds every_kind_handled "$DROPPED"

BOGUS="$MD_TMP/oversee-bogus.md"
awk '{ print }
  /^- `pr-watch` →/ { print "  - `no-such-kind` → invented for the control" }' \
  "$OVERSEE" > "$BOGUS"
check "control: an invented handler bullet reds the vocabulary direction" \
  reds every_handler_real "$BOGUS"

# The flag oversee-watch passes, read in both halves. The parser arm is
# anchored to its case-arm shape: a comment line holding the same literal is
# not an arm.
heal_documented() { "$1" --help 2>/dev/null | grep -q -- '^  --heal '; }
heal_parsed() { grep -qE '^[[:space:]]*--heal\)' "$1"; }
check "pr-watch still documents the --heal flag oversee-watch passes" \
  heal_documented "$PR_WATCH"
check "pr-watch still parses the --heal flag oversee-watch passes" \
  heal_parsed "$PR_WATCH"

# Controls for both halves, planted INERT rather than deleted: the failure that
# reaches production is a rename that leaves the old spelling behind in prose.
FLAG_DIR="$MD_TMP/scripts"
mkdir -p "$FLAG_DIR"
ln -s "$REVIEW_GATE_DIR/scripts/lib" "$FLAG_DIR/lib"

RENAMED_ARM="$FLAG_DIR/pr-watch-renamed-arm.sh"
awk '/^[[:space:]]*--heal\)/ { print "    # the old --heal) arm, renamed"
                               sub(/--heal\)/, "--healx)") }
     { print }' "$PR_WATCH" > "$RENAMED_ARM"
chmod +x "$RENAMED_ARM"
check "control: a renamed arm whose literal survives in a comment reds the parser check" \
  reds heal_parsed "$RENAMED_ARM"
check "control: that same rename leaves the usage check green" \
  heal_documented "$RENAMED_ARM"

RENAMED_USAGE="$FLAG_DIR/pr-watch-renamed-usage.sh"
awk '{ sub(/^  --heal /, "  --healx ") } { print }' "$PR_WATCH" > "$RENAMED_USAGE"
chmod +x "$RENAMED_USAGE"
check "control: a renamed usage line reds the usage check" \
  reds heal_documented "$RENAMED_USAGE"
check "control: that same rename leaves the parser check green" \
  heal_parsed "$RENAMED_USAGE"

md_report
