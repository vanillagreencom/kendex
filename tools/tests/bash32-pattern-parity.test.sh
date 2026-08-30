#!/usr/bin/env bash
# The bash32 pattern set is carried, verbatim, by every suite in this repo
# that scans shell source for Bash 4 syntax. The copies are the design: skills
# install independently, so a judge inside one skill is absent from every
# install that skips it. This suite is what makes copies safe. It holds every
# copy byte-identical so improving one improves all, proves the set's teeth
# once against the text a real suite ships, and pins the roster so a new suite
# must join or be excluded on purpose. It spans both trees, because a render
# is where a hand edit looks least wrong.
#
# EVERY CHECK BELOW FAILS CLOSED. A proof that cannot fail is worse than no
# proof, because ten files rest on this one. So no result is read out of an
# empty string: git, grep and awk are asked for their status, and a command
# that could not run ends the run instead of scoring a pass.
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel)" || exit 2
cd "$ROOT" || exit 2

BEGIN='# --- shared bash32 pattern set: begin'
END='# --- shared bash32 pattern set: end'
RENDER_PREFIX='.agents/'
Q="'"
NL='
'

# Every authored file that carries the block. One outside this list carrying
# it, or one in it without it, fails below.
CARRIER_SOURCES="skills/github/tests/bot_review_status.sh
skills/growth-guards/tests/bash32-portability.test.sh
skills/harness-ci/tests/bash32-portability.test.sh
skills/orch/tests/bash32-portability.test.sh
skills/preflight/tests/bash32-portability.test.sh
skills/project-management/tests/bash32-portability.test.sh
skills/review-gate/tests/bash32-portability.test.sh
skills/size-ratchet/tests/bash32-portability.test.sh
skills/worktree/tests/bash32-portability.test.sh"

# And the suite that must NOT carry it. skills/linear asserts the opposite
# contract — linear.sh requires Bash 4+ and says so in --help — so the set
# would forbid the runtime that skill demands. It shares only the filename.
EXCLUDED_SOURCES="skills/linear/tests/bash32-portability.test.sh"

# The sources this repo does not install, which therefore have no render.
# Every other source's render is required by name. Declaring the exception
# rather than asking the filesystem is the point: a roster that discovers its
# members cannot tell a render that matches from one that is gone.
UNRENDERED="skills/harness-ci/tests/bash32-portability.test.sh"

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
  printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ]
}

# One git listing, status checked, answering every later question about what
# git carries. A per-path `--error-unmatch` reads a git that could not run as
# a path that is not there.
TRACKED=""
git_status=0
TRACKED="$(git ls-files -- 'skills/*' "$RENDER_PREFIX"'skills/*')" || git_status=$?
if [ "$git_status" -ne 0 ] || [ -z "$TRACKED" ]; then
  bad "git listed no tracked skill file (exit $git_status), so nothing here was checked"
  verdict
  exit
fi
tracked() { case "$NL$TRACKED$NL" in *"$NL$1$NL"*) return 0 ;; esac; return 1; }

# expand LIST — each path, then its render unless the path is declared above.
expand() {
  local p u skip
  for p in $1; do
    printf '%s\n' "$p"
    skip=no
    for u in $UNRENDERED; do [ "$u" = "$p" ] && skip=yes; done
    [ "$skip" = yes ] || printf '%s\n' "$RENDER_PREFIX$p"
  done
}
CARRIERS="$(expand "$CARRIER_SOURCES")"
EXCLUDED="$(expand "$EXCLUDED_SOURCES")"
renders=0
for f in $CARRIERS $EXCLUDED; do
  case "$f" in "$RENDER_PREFIX"*) renders=$((renders + 1)) ;; esac
done

# extract FILE — the block's body, both markers excluded. 1 when the file
# holds no single well-formed block, 2 when awk could not read it.
extract() {
  awk -v begin="$BEGIN" -v end="$END" '
    $0 == begin { if (opened) malformed = 1; opened++; inside = 1; next }
    $0 == end   { if (!inside) malformed = 1; inside = 0; closed++; next }
    inside      { print }
    END { if (malformed || opened != 1 || closed != 1 || inside) exit 1 }
  ' "$1"
}

# --- 1. every carrier present, and identical ---
reference=""
reference_file=""
for f in $CARRIERS; do
  if [ ! -f "$f" ] || ! tracked "$f"; then
    bad "$f is on the roster but git does not carry it" \
      "deleted or renamed: restore it, or take it off the roster on purpose"
    continue
  fi
  body=""
  status=0
  body="$(extract "$f")" || status=$?
  if [ "$status" -gt 1 ]; then
    bad "the block could not be read out of $f (awk exited $status)"
    continue
  elif [ "$status" -eq 1 ]; then
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
ok "the roster required $renders rendered copies under $RENDER_PREFIX by name"

# The declared exceptions are held to being exceptions. One naming no source
# hides a typo; one whose skill is now installed leaves a render unchecked.
for u in $UNRENDERED; do
  known=no
  for s in $CARRIER_SOURCES $EXCLUDED_SOURCES; do [ "$s" = "$u" ] && known=yes; done
  if [ "$known" = no ]; then
    bad "$u is declared unrendered but is on neither source list" \
      "a stale or misspelled entry excuses a render nobody is checking"
  elif tracked "$RENDER_PREFIX$u"; then
    bad "$u is declared unrendered, but $RENDER_PREFIX$u is tracked" \
      "the skill is installed now: drop it from UNRENDERED so its render joins the roster"
  else
    ok "$u has no render, as declared"
  fi
done

# The comparison has teeth: one changed byte must read as drift, mutated in
# the shell so no command's failure can hand it a pass.
if [ "${reference}x" = "$reference" ]; then
  bad "a one-byte change did not read as drift, so the parity check above proves nothing"
else
  ok "a one-byte change reads as drift"
fi

# --- 2. the roster is closed ---
for f in $TRACKED; do
  case "$f" in
  */tests/bash32-portability.test.sh) ;;
  *) continue ;;
  esac
  listed=no
  for c in $CARRIERS $EXCLUDED; do [ "$c" = "$f" ] && listed=yes; done
  if [ "$listed" = yes ]; then
    ok "$f is on the roster"
  else
    bad "$f is a bash32-portability suite this file has never heard of" \
      "add it to CARRIER_SOURCES, or to EXCLUDED_SOURCES with the reason it asserts something else"
  fi
done

for f in $EXCLUDED; do
  status=0
  grep -qxF -- "$BEGIN" "$f" || status=$?
  if [ ! -f "$f" ]; then
    bad "$f is listed as excluded but does not exist"
  elif [ "$status" -gt 1 ]; then
    bad "$f could not be read (grep exited $status), so its exclusion is unproven"
  elif [ "$status" -eq 0 ]; then
    bad "$f took the shared bash32 pattern set" \
      "it asserts the opposite contract; the set would forbid the runtime it requires"
  else
    ok "$f stays out of the shared set"
  fi
done

# --- 3. the set's teeth, against the text the suites ship ---
# Running the block is the only way to test the regex the suites actually use
# rather than a retyped copy, so every line is first held to the shape the
# block may have: a single-quoted PATTERN assignment, or a comment.
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
# earlier set was walked past. `local -rA` and `local -r -A` are one
# declaration to Bash, so both are here: neither stands in for the other.
PROBES="$(
  cat <<'PROBES_EOF'
local -A cache
local    -A cache
local -rA cache
local -Ar cache
local -r -A cache
local -r -x -A cache
typeset -A cache
typeset -r -A cache
declare -A cache
declare -gA cache
declare -Ag cache
declare -g COUNT=1
declare -x -g name
declare -n ref=target
local -n ref=target
readonly -A cache
declare -l lowered_attr
declare -u upper_attr
local -al items
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
printf "%s" "$value" |& tee log
printf "%s" "$value"|& tee log
grep -q x file |&tee log
(cat f)|& tee log
run 2>&1|& tee log
printf x\(|& cat
printf x\;|& cat
printf x\[|& cat
cmd |&
cmd &>> log
cmd&>>log
  short) run ;;&
  short) run ;&
case $x in short) run ;;&long) run ;; esac
case $x in short) run ;&long) run ;; esac
initial="${1^}"
lowered="${1,}"
indirect="${!name^}"
indirect_all="${!name^^}"
every="${@^^}"
star="${*,,}"
tenth="${10^}"
pid_initial="${$^}"
bgpid_initial="${!^}"
name_zero="${0^}"
under="${_^}"
PROBES_EOF
)"

# Lines that must NOT be flagged: a set that reds Bash 3.2-legal source is a
# set nobody can keep, and every probe above widens an anchor a line here
# keeps honest. Five are real, out of skills/preflight/scripts/preflight,
# hooks/pre-commit-check.sh and
# skills/reviewer/tests/harness-safe-shell-lint.test.sh. The rest are regex
# shapes that spell an operator without being one, including the escaped
# classes bounding the pipe anchor, and the parameters Bash will not convert.
CONTROLS="$(
  cat <<'CONTROLS_EOF'
local -r frozen=1
local -a items
local -ar items
local -r -i count=0
local -r -- name
declare -i count=0
declare -f helper
declare -p NAME
declare -r -x name
declare -f -p helper
readonly frozen=1
readonly -a items
typeset -r frozen=1
grep -A 3 pattern file
export -n VAR
printf '%s\n' "${items[@]}"
echo "${first}, ${second}"
total=${#files[@]}
fallback=${value:-,}
MKTEMP_CALL_RE='(^[[:space:]]*|[;|&(`{][[:space:]]*)mktemp([^A-Za-z0-9_.-]|$)'
RUNNER_RE="(^[[:space:]]*|[;&|\`(][[:space:]]*)"
KIND_TAIL="([[:space:]\"'\`;&|)]|\$)"
  SEP = ";&|()" "\n" "\r"
alternation='([a-z]|&)'
escaped_class='[\(|&]'
escaped_class2='[\;&|)]'
escaped_class3='[\[;&]'
escaped_class4='[a\(|&]'
escaped_group='\(|&\)'
awk_redirect_re=/([[:space:]]>>?|[0-9]>|&>)/
first || second &
first; second &
echo "${1}, ${2}"
echo "${*}"
echo "${!ref}"
keys="${!arr[@]}"
names="${!prefix*}"
flags="${-}"
code="${?}"
count="${#}"
CONTROLS_EOF
)"

# scan MODE PATTERN LINES — the lines PATTERN misses, or the ones it hits.
# Returns 2 when grep could not run: an invalid ERE prints nothing and exits
# 2, and reading that emptiness as clean is how a proof comes to pass while
# proving nothing.
scan() {
  local out="" status=0
  case "$1" in
  miss) out="$(printf '%s\n' "$3" | grep -vE -- "$2")" || status=$? ;;
  hit) out="$(printf '%s\n' "$3" | grep -E -- "$2")" || status=$? ;;
  esac
  [ "$status" -le 1 ] || return 2
  printf '%s' "$out"
}

status=0
uncaught="$(scan miss "$PATTERN" "$PROBES")" || status=$?
false_positives=""
[ "$status" -ne 0 ] || false_positives="$(scan hit "$PATTERN" "$CONTROLS")" || status=$?
if [ "$status" -ne 0 ]; then
  bad "the proof could not run: grep rejected the block's own pattern" \
    "an invalid ERE prints nothing, and no check may read that as clean"
  verdict
  exit
fi
if [ -n "$uncaught" ]; then
  bad "the set misses constructs it must flag" "$(printf '%s\n' "$uncaught" | head -20)"
else
  ok "every probed Bash 4 construct is flagged"
fi
if [ -n "$false_positives" ]; then
  bad "the set flags Bash 3.2-legal source" "$(printf '%s\n' "$false_positives" | head -20)"
else
  ok "no Bash 3.2-legal control line is flagged"
fi

# Both checks above read the pattern rather than passing on their own shape: a
# set narrowed to one alternative must miss probes, and one widened to match
# anything must flag controls. Without this pair a `.` would look perfect.
degenerate() { # MODE PATTERN LINES LABEL
  local status=0 out=""
  out="$(scan "$1" "$2" "$3")" || status=$?
  if [ "$status" -ne 0 ]; then
    bad "the control for '$4' could not run (grep exited nonzero)"
  elif [ -z "$out" ]; then
    bad "$4: it does not, so the check it guards proves nothing"
  else
    ok "$4"
  fi
}
degenerate miss mapfile "$PROBES" "a narrowed set misses probes"
degenerate hit . "$CONTROLS" "a set matching anything flags controls"

verdict
