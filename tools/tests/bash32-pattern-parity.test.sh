#!/usr/bin/env bash
# The bash32 pattern set is carried, verbatim, by every suite in this repo
# that scans shell source for Bash 4 syntax. The copies are the design, not an
# accident: skills install independently, so a judge living inside one skill
# is absent from every install that skips it, and nothing outside a skill's
# own directory ships with it. This suite is what makes copies safe.
#
# It does three things the copies cannot do for themselves:
#
#   1. holds every copy byte-identical, so improving one improves all;
#   2. proves the set's teeth once, against the text a real suite ships —
#      parity is what lets one proof stand for every copy;
#   3. pins the roster, so a new bash32-portability suite must join the set
#      or be excluded on purpose, and an excluded one cannot drift back in.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"

BEGIN='# --- shared bash32 pattern set: begin'
END='# --- shared bash32 pattern set: end'
Q="'"

# Every file that carries the block. A suite outside this list carrying it, or
# one in it without it, fails below.
CARRIERS="skills/github/tests/bot_review_status.sh
skills/growth-guards/tests/bash32-portability.test.sh
skills/harness-ci/tests/bash32-portability.test.sh
skills/orch/tests/bash32-portability.test.sh
skills/preflight/tests/bash32-portability.test.sh
skills/project-management/tests/bash32-portability.test.sh
skills/review-gate/tests/bash32-portability.test.sh
skills/size-ratchet/tests/bash32-portability.test.sh
skills/worktree/tests/bash32-portability.test.sh"

# And the suite that must NOT carry it. skills/linear asserts the opposite
# contract — linear.sh requires Bash 4+ and says so in --help — so the shared
# set would forbid the runtime that skill demands. It shares the filename with
# the others and nothing else.
EXCLUDED="skills/linear/tests/bash32-portability.test.sh"

PASS=0
FAIL=0
ok() {
  PASS=$((PASS + 1))
  printf '  ok    %s\n' "$1"
}
bad() {
  FAIL=$((FAIL + 1))
  printf '  FAIL  %s\n' "$1"
  [ $# -lt 2 ] || printf '        %s\n' "$2"
}
verdict() {
  echo
  printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ]
}

# extract FILE — the block's body on stdout, both markers excluded. Nonzero
# unless the file holds exactly one well-formed block, so a missing or
# duplicated marker is never read as an empty block matching every other
# empty block.
extract() {
  awk -v begin="$BEGIN" -v end="$END" '
    $0 == begin { if (opened) malformed = 1; opened++; inside = 1; next }
    $0 == end   { if (!inside) malformed = 1; inside = 0; closed++; next }
    inside      { print }
    END { if (malformed || opened != 1 || closed != 1 || inside) exit 1 }
  ' "$1"
}

# --- 1. every carrier present, and identical -------------------------------

reference=""
reference_file=""
for f in $CARRIERS; do
  if [ ! -f "$f" ]; then
    bad "$f is listed as a carrier but does not exist"
    continue
  fi
  body=""
  if ! body="$(extract "$f")"; then
    bad "$f holds no single well-formed shared bash32 pattern set" \
      "expected one $BEGIN ... $END pair"
    continue
  fi
  if [ -z "$reference" ]; then
    reference="$body"
    reference_file="$f"
    ok "$f carries the block"
  elif [ "$body" = "$reference" ]; then
    ok "$f matches $reference_file"
  else
    bad "$f has drifted from $reference_file" \
      "$(diff <(printf '%s\n' "$reference") <(printf '%s\n' "$body") | head -20)"
  fi
done
if [ -z "$reference" ]; then
  bad "no carrier yielded a block, so nothing below was compared or proven"
  verdict
  exit
fi

# The comparison has teeth: one changed byte must read as drift.
if [ "$(printf '%s\n' "$reference" | sed '$s/$/x/')" = "$reference" ]; then
  bad "a one-byte change did not read as drift, so the parity check above proves nothing"
else
  ok "a one-byte change reads as drift"
fi

# --- 2. the roster is closed -----------------------------------------------

for f in $(git ls-files -- 'skills/*/tests/bash32-portability.test.sh' | LC_ALL=C sort); do
  listed=no
  for c in $CARRIERS $EXCLUDED; do
    [ "$c" = "$f" ] && listed=yes
  done
  if [ "$listed" = yes ]; then
    ok "$f is on the roster"
  else
    bad "$f is a bash32-portability suite this file has never heard of" \
      "add it to CARRIERS, or to EXCLUDED with the reason it asserts something else"
  fi
done

for f in $EXCLUDED; do
  if [ ! -f "$f" ]; then
    bad "$f is listed as excluded but does not exist"
  elif grep -qxF -- "$BEGIN" "$f"; then
    bad "$f took the shared bash32 pattern set" \
      "it asserts the opposite contract; the set would forbid the runtime it requires"
  else
    ok "$f stays out of the shared set"
  fi
done

# --- 3. the set's teeth, against the text the suites ship ------------------

# Running the block is the only way to test the regex the suites actually use
# rather than a retyped copy of it, so every line is first held to the shape
# the block is allowed to have: what gets evaluated is a single-quoted PATTERN
# assignment or a comment, and nothing else.
shape_ok=yes
while IFS= read -r line; do
  case "$line" in
  '#'* | '') ;;
  "PATTERN=$Q"*"$Q") ;;
  "PATTERN=\"\$PATTERN\"$Q"*"$Q") ;;
  *)
    shape_ok=no
    bad "the block holds a line that is neither a comment nor a PATTERN assignment" "$line"
    ;;
  esac
done <<EOF
$reference
EOF
[ "$shape_ok" = no ] || ok "every block line is a comment or a PATTERN assignment"

PATTERN=""
[ "$shape_ok" = no ] || eval "$reference"
if [ -z "$PATTERN" ]; then
  bad "the block left PATTERN empty, so nothing below was proven"
  verdict
  exit
fi

# Constructs that must be flagged. Each is a must-fail probe: injected into a
# scanned tree it turns that tree's suite red, which is the whole claim these
# suites make. The alternate spellings are here because they are how the
# earlier set was walked past — extra whitespace, `typeset`, flag order,
# one-character case conversion.
PROBES="$(
  cat <<'PROBES_EOF'
local -A cache
local    -A cache
local -rA cache
local -Ar cache
typeset -A cache
declare -A cache
declare -gA cache
declare -Ag cache
declare -g COUNT=1
declare -n ref=target
local -n ref=target
readonly -A cache
mapfile -t lanes < panes.txt
readarray -t lanes < panes.txt
exec {lock_fd}<"$lockfile"
exec {log_fd}>>"$logfile"
head_lower="${head,,}"
head_upper="${head^^}"
initial="${name^}"
lowered="${name,}"
first="${words[0]^}"
coproc FOO { :; }
coproc { read -r line; }
grep -q x file |& tee log
grep -q x file|& tee log
cmd &>> log
  short) run ;;&
  short) run ;&
PROBES_EOF
)"

# Lines that must NOT be flagged: a set that reds Bash 3.2-legal source is a
# set nobody can keep. The last two are real bracket expressions out of
# skills/preflight/scripts/preflight, where an unanchored |& or ;& matched.
CONTROLS="$(
  cat <<'CONTROLS_EOF'
local -r frozen=1
local -a items
declare -i count=0
declare -f helper
readonly frozen=1
typeset -r frozen=1
printf '%s\n' "${items[@]}"
echo "${first}, ${second}"
total=${#files[@]}
fallback=${value:-,}
MKTEMP_CALL_RE='(^[[:space:]]*|[;|&(`{][[:space:]]*)mktemp([^A-Za-z0-9_.-]|$)'
RUNNER_RE="(^[[:space:]]*|[;&|\`(][[:space:]]*)"
first || second &
first; second &
CONTROLS_EOF
)"

# missed PATTERN LINES — the probe lines PATTERN does not flag, one per line.
missed() {
  printf '%s\n' "$2" | grep -vE "$1"
}
# flagged PATTERN LINES — the control lines PATTERN does flag.
flagged() {
  printf '%s\n' "$2" | grep -E "$1"
}

uncaught="$(missed "$PATTERN" "$PROBES")"
if [ -n "$uncaught" ]; then
  bad "the set misses constructs it must flag" "$(printf '%s\n' "$uncaught" | head -20)"
else
  ok "every probed Bash 4 construct is flagged"
fi

false_positives="$(flagged "$PATTERN" "$CONTROLS")"
if [ -n "$false_positives" ]; then
  bad "the set flags Bash 3.2-legal source" "$(printf '%s\n' "$false_positives" | head -20)"
else
  ok "no Bash 3.2-legal control line is flagged"
fi

# Both checks above read the pattern rather than passing on their own shape: a
# set narrowed to one alternative must miss probes, and one widened to match
# anything must flag controls. Without this pair a `.` would look perfect.
if [ -z "$(missed 'mapfile' "$PROBES")" ]; then
  bad "a set narrowed to \`mapfile\` still catches every probe, so the probe check proves nothing"
else
  ok "a narrowed set misses probes"
fi
if [ -z "$(flagged '.' "$CONTROLS")" ]; then
  bad "a set matching anything flags no control, so the control check proves nothing"
else
  ok "a set matching anything flags controls"
fi

verdict
