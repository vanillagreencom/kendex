#!/usr/bin/env bash
# Holds the reviewer-test deadline in ../workflows/review-pr.md § 3.2 at or
# above one ../../reviewer/scripts/mutation-stability run at that script's
# defaults. reviewer-test runs that pairing, and the § 3.2 sweep marks an agent
# still outstanding at its deadline unresponsive, so a deadline below the run's
# worst case marks a working reviewer unresponsive mid-run.
#
# Both sides are read from their own files on every run. The worst case is
# (N + C) x TIMEOUT: N and TIMEOUT from mutation-stability's one defaults
# assignment line, C the timeout-bounded calls (run_command, run_test) that
# start a line at column 0, which is every call outside a function body and
# outside the stability loop, whose own call is the N. The deadline is the
# `<M> minutes for \`reviewer-test\`` figure in § 3.2, or, with none, the
# `<M> minutes for every other agent` figure the sweep then applies.
#
# The call count stays open to under-counting: a top-level call that does not
# start its line, such as one inside an `if` at column 0, is missed. The
# over-count direction is held by the indented-call row below.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/md.sh"

DOC="$SKILL_DIR/workflows/review-pr.md"
SCRIPT="$SKILLS_ROOT/reviewer/scripts/mutation-stability"

echo "=== reviewer-test deadline covers one mutation-stability run ==="

# deadline_check DOC SCRIPT — one keyed line on stdout:
#   deadline-ok|deadline-short minutes=M required-seconds=S stability=N calls=C timeout=T
#   read-failed what=defaults|calls|section|deadline path=FILE
# read-failed names an extractor that found nothing, or more than one answer.
deadline_check() {
  local doc="$1" script="$2" defaults calls section hits minutes n t required verdict
  defaults="$(awk '
    /^[A-Z_]+=/ {
      n = ""; t = ""
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^N=[0-9]+$/) n = substr($i, 3)
        if ($i ~ /^TIMEOUT=[0-9]+$/) t = substr($i, 9)
      }
      if (n != "" && t != "") print n, t
    }' "$script")" || { echo "read-failed what=defaults path=$script"; return 0; }
  case "$defaults" in
    '' | *$'\n'*) echo "read-failed what=defaults path=$script"; return 0 ;;
  esac
  read -r n t <<<"$defaults"

  calls="$(grep -cE -- '^(run_command|run_test)[[:space:]]' "$script")" || [ "$?" -eq 1 ] ||
    { echo "read-failed what=calls path=$script"; return 0; }
  [ "$calls" -gt 0 ] || { echo "read-failed what=calls path=$script"; return 0; }

  section="$(awk '
    /^#{1,3} / { inside = ($0 ~ /^### 3\.2 /) }
    inside' "$doc")" || { echo "read-failed what=section path=$doc"; return 0; }
  [ -n "$section" ] || { echo "read-failed what=section path=$doc"; return 0; }

  hits="$(grep -oE -- '[0-9]+ minutes for `reviewer-test`' <<<"$section")" || [ "$?" -eq 1 ] ||
    { echo "read-failed what=deadline path=$doc"; return 0; }
  if [ -z "$hits" ]; then
    hits="$(grep -oE -- '[0-9]+ minutes for every other agent' <<<"$section")" || [ "$?" -eq 1 ] ||
      { echo "read-failed what=deadline path=$doc"; return 0; }
  fi
  case "$hits" in
    '' | *$'\n'*) echo "read-failed what=deadline path=$doc"; return 0 ;;
  esac
  minutes="${hits%% *}"

  required=$(( (10#$n + calls) * 10#$t ))
  verdict=deadline-short
  [ $(( 10#$minutes * 60 )) -lt "$required" ] || verdict=deadline-ok
  echo "$verdict minutes=$((10#$minutes)) required-seconds=$required stability=$((10#$n)) calls=$calls timeout=$((10#$t))"
}

# plant SRC DST OLD NEW — DST is SRC with its one OLD replaced by NEW. A
# missing, repeated or no-op match fails rather than writing an unchanged copy.
plant() {
  local text rest
  text="$(cat -- "$1")" || return 1
  case "$text" in *"$3"*) ;; *) echo "plant: match=0 path=$1" >&2; return 1 ;; esac
  rest="${text#*"$3"}"
  case "$rest" in *"$3"*) echo "plant: match=many path=$1" >&2; return 1 ;; esac
  printf '%s\n' "${text%%"$3"*}$4$rest" >"$2" || return 1
  if cmp -s -- "$1" "$2"; then echo "plant: unchanged path=$2" >&2; return 1; fi
}

LIVE="$(deadline_check "$DOC" "$SCRIPT")"
assert_contains "$LIVE" "deadline-ok " "the reviewer-test deadline covers one mutation-stability run at its defaults"

FIELDS='minutes=([0-9]+) required-seconds=([0-9]+) stability=([0-9]+) calls=([0-9]+) timeout=([0-9]+)$'
if ! [[ $LIVE =~ $FIELDS ]]; then
  fail "the live figures read, so the controls can be planted" "got: $LIVE"
  md_report
  exit 1
fi
M=${BASH_REMATCH[1]} REQ=${BASH_REMATCH[2]} N=${BASH_REMATCH[3]} C=${BASH_REMATCH[4]} T=${BASH_REMATCH[5]}

# Each control copies one side, plants a value derived from the live figures
# so it lands on the far side of the bound whatever those figures are, and
# runs the same check over the copy.
PRE="$MD_TMP/pre-branch.md"
LOW="$MD_TMP/below.md"
EDGE="$MD_TMP/edge.md"
NOSEC="$MD_TMP/no-section.md"
plant "$DOC" "$PRE" ", $M minutes for \`reviewer-test\`," ","
plant "$DOC" "$LOW" "$M minutes for \`reviewer-test\`" "$(( (REQ - 1) / 60 )) minutes for \`reviewer-test\`"
plant "$DOC" "$EDGE" "$M minutes for \`reviewer-test\`" "$(( (REQ + 59) / 60 )) minutes for \`reviewer-test\`"
plant "$DOC" "$NOSEC" "### 3.2 " "### 3.9 "

MORE_N="$MD_TMP/more-stability"
MORE_T="$MD_TMP/longer-timeout"
MORE_C="$MD_TMP/more-calls"
INDENTED="$MD_TMP/indented-calls"
NODEF="$MD_TMP/no-defaults"
plant "$SCRIPT" "$MORE_N" " N=$N " " N=$(( M * 60 / T + 1 )) "
plant "$SCRIPT" "$MORE_T" " TIMEOUT=$T " " TIMEOUT=$(( M * 60 / (N + C) + 1 )) "
plant "$SCRIPT" "$NODEF" " N=$N " " STABILITY=$N "
cp -- "$SCRIPT" "$MORE_C"
extra=$(( M * 60 / T - N - C + 1 ))
while [ "$extra" -gt 0 ]; do
  printf 'run_test "$ROOT/clean" "$ROOT/extra.log"\n' >>"$MORE_C"
  extra=$((extra - 1))
done
cp -- "$SCRIPT" "$INDENTED"
printf '%s\n' 'extra_run() {' '  run_command "$1" "$BUILD" "$2" "extra"' '}' \
  'while false; do' '  run_test "$ROOT/clean" "$ROOT/extra.log"' 'done' >>"$INDENTED"

# label|doc|script|key the check prints first
while IFS='|' read -r label doc script want; do
  got="$(deadline_check "$doc" "$script")"
  assert_eq "${got%% *}" "$want" "$label"
done <<EOF
the pre-branch text, reviewer-test under the every-other-agent figure, is short|$PRE|$SCRIPT|deadline-short
a reviewer-test figure one minute under the run is short|$LOW|$SCRIPT|deadline-short
a reviewer-test figure at the run's length in whole minutes covers it|$EDGE|$SCRIPT|deadline-ok
a stability default above the deadline's reach is short|$DOC|$MORE_N|deadline-short
a timeout default above the deadline's reach is short|$DOC|$MORE_T|deadline-short
top-level timed calls past the deadline's reach are short|$DOC|$MORE_C|deadline-short
a doc with no section 3.2 fails the read, not the bound|$NOSEC|$SCRIPT|read-failed
a script with no N default fails the read, not the bound|$DOC|$NODEF|read-failed
EOF

assert_eq "$(deadline_check "$DOC" "$INDENTED")" "$LIVE" \
  "calls inside a function body or a loop add nothing to the count"

md_report
