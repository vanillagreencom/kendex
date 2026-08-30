#!/usr/bin/env bash
# The bash32 pattern set is carried, verbatim, by every suite in this repo
# that scans shell source for Bash 4 syntax. The copies are the design: skills
# install independently, so a judge inside one skill is absent from every
# install that skips it. This suite makes copies safe. It holds every copy
# byte-identical, proves the set's teeth once against the text a real suite
# ships, and pins the roster over both trees, because a render is where a
# hand edit looks least wrong.
#
# EVERY CHECK BELOW FAILS CLOSED. A proof that cannot fail is worse than no
# proof, because ten files rest on this one. So no result is read out of an
# empty string: git, grep and awk are asked for their status, and a command
# that could not run ends the run instead of scoring a pass. And THE BLOCK IS
# NEVER EXECUTED. It is content this suite judges, so it is parsed: the
# quoted literals are lifted out and joined, and the pattern reaches nothing
# but `grep -E --`. There is no eval here and no shell a block could reach.
set -uf -o pipefail
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

# One exception naming no source hides a typo; one whose skill is now
# installed leaves a render unchecked.
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
# Over markers first, then over filenames. The tenth carrier was an inline
# scan inside bot_review_status.sh, found by reading rather than by a
# failure, so closing over the filename alone would miss the next one.
case "$BEGIN" in
*[\\^\$.\[\]\|\(\)\*\+\?\{\}]*)
  bad "the marker carries a regex metacharacter, so the tree-wide scan cannot pin it"
  verdict
  exit
  ;;
esac
marker_files=""
status=0
marker_files="$(git grep -I --name-only -E -e "^$BEGIN\$")" || status=$?
if [ "$status" -gt 1 ]; then
  bad "the marker scan could not run (git grep exited $status)"
  verdict
  exit
fi
for f in $marker_files; do
  listed=no
  for c in $CARRIERS; do [ "$c" = "$f" ] && listed=yes; done
  if [ "$listed" = yes ]; then
    ok "$f carries the marker and is a listed carrier"
  else
    bad "$f carries the shared block but is on no list" \
      "add it to CARRIER_SOURCES, whatever the file is named"
  fi
done

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
# The pattern is built out of the block, not run from it. A single-quote ends
# at the next one, so the literal between them is exactly the bytes in it and
# a line carrying a second quote is not an assignment — which is what an
# `eval` of a shape-checked line would have run. The first assignment opens
# the chain, the rest append, anything else is refused.
QUOTERUN="a block line closes its quote and keeps going, so it is not an assignment"
PATTERN=""
built=none
while IFS= read -r line; do
  case "$line" in
  '#'* | '') continue ;;
  esac
  if [ "$built" = none ]; then
    prefix="PATTERN=$Q"
  else
    prefix="PATTERN=\"\$PATTERN\"$Q"
  fi
  case "$line" in
  "$prefix"*"$Q")
    body="${line#"$prefix"}"
    body="${body%"$Q"}"
    case "$body" in *"$Q"*) bad "$QUOTERUN" "$line"; built=refused; break ;; esac
    PATTERN="$PATTERN$body"
    built=yes
    ;;
  *)
    bad "the block holds a line that is not an assignment expected here" "$line"
    built=refused
    break
    ;;
  esac
done <<EOF
$reference
EOF
if [ "$built" != yes ] || [ -z "$PATTERN" ]; then
  bad "no pattern could be built from the block, so nothing below was proven"
  verdict
  exit
fi
ok "the block parses as a PATTERN chain and was never executed"


# The proof's two fixtures, read as data and never sourced. tools/tests/data
# holds them a line per case: probes are Bash 4 constructs the set must flag,
# each a must-fail probe that reds a real suite when dropped into a scanned
# tree; controls are Bash 3.2-legal source it must leave alone, including the
# bracket expressions and separator strings in this repo that an unanchored
# operator pattern used to match. An unreadable or empty fixture ends the run
# rather than proving nothing over no cases — and it is read here rather than
# inside a helper, because a `bad` raised in a command substitution is stdout,
# not a failure, and would land in the variable it was refusing to fill.
PROBES=""
CONTROLS=""
UNCATCHABLE=""
OVERFLAGGED=""
fixture_status=0
PROBES="$(cat tools/tests/data/bash32-probes.txt)" || fixture_status=$?
CONTROLS="$(cat tools/tests/data/bash32-controls.txt)" || fixture_status=$?
UNCATCHABLE="$(cat tools/tests/data/bash32-uncatchable.txt)" || fixture_status=$?
OVERFLAGGED="$(cat tools/tests/data/bash32-overflagged.txt)" || fixture_status=$?
if [ "$fixture_status" -ne 0 ] || [ -z "$PROBES" ] || [ -z "$CONTROLS" ] ||
  [ -z "$UNCATCHABLE" ] || [ -z "$OVERFLAGGED" ]; then
  bad "a fixture under tools/tests/data is missing or empty, so the proof has no cases"
  verdict
  exit
fi


# scan MODE PATTERN LINES — the lines PATTERN misses, or the ones it hits. 2
# when grep could not run: an invalid ERE prints nothing and exits 2, and
# reading that emptiness as clean is a proof that passes while proving nothing.
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

# After the end marker the guard is a WHITELIST. A line may extend the set in
# the documented append form, or READ the variable — every legitimate line in
# every carrier is one of those two — and a line that names PATTERN any other
# way is refused, whatever the spelling.
#
# It was a blocklist and came up short five times: `export PATTERN=`,
# `PATTERN[0]=`, `declare PATTERN=`, `readonly PATTERN=` and `printf -v
# PATTERN` all walked past it. Enumerating the ways a shell can assign a name
# has no more of an end than enumerating the ways it can spell `mapfile`, and
# this repo has made that mistake in both directions today. What every
# assignment shares is that it NAMES the variable, so naming it outside a read
# is what this refuses, including the ones nobody has thought of.
#
# Reads are recognised by stripping them: `$PATTERN` and `${PATTERN}` come out
# of the line, and if the token survives, the line names it for some other
# purpose. A comment mentioning PATTERN after the marker would be refused too;
# none exists, and rewording one is the cost of a guard whose default is no.
#
# This is a static read of the text. The block is still never executed.
# names_pattern — reads a carrier on stdin, prints `N: line` for every line
# after the marker that names PATTERN outside a `$PATTERN` read.
names_pattern() {
  awk -v marker="$END" '
    $0 == marker { after = 1; next }
    !after { next }
    {
      line = $0
      gsub(/\$\{PATTERN\}/, "", line)
      gsub(/\$PATTERN/, "", line)
      if (line ~ /(^|[^A-Za-z0-9_])PATTERN([^A-Za-z0-9_]|$)/) printf "%d: %s\n", NR, $0
    }
  '
}
APPEND_RE='^[0-9]+: PATTERN="\$PATTERN"'"$Q"'[^'"$Q"']*'"$Q"'$'
for f in $CARRIERS; do
  [ -f "$f" ] || continue
  named=""
  named_status=0
  named="$(names_pattern <"$f")" || named_status=$?
  if [ "$named_status" -ne 0 ]; then
    bad "the lines after the marker in $f could not be read (awk exited $named_status)"
    continue
  fi
  offenders=""
  status=0
  if [ -n "$named" ]; then
    offenders="$(printf '%s\n' "$named" | grep -vE "$APPEND_RE")" || status=$?
  fi
  if [ "$status" -gt 1 ]; then
    bad "the post-marker scan over $f could not run (grep exited $status)"
  elif [ -n "$offenders" ]; then
    bad "$f names PATTERN after the marker outside a read or the append form" \
      "$(printf '%s\n' "$offenders" | head -5)
after the block, PATTERN may be read or extended with PATTERN=\"\$PATTERN\"'...' and nothing else"
  else
    ok "$f only extends or reads the set after the marker"
  fi
done

# The gap this guard has, checked so the sentence above cannot go stale. An
# assignment that never spells the name is invisible to a text rule, and bash
# really does perform it — `v=PATT; v="${v}ERN"; declare "$v=mapfile"` leaves
# PATTERN set to mapfile. Reaching that means resolving a variable's value,
# which is running the shell, not reading it. If it ever starts being caught,
# this reds and the claim above gets rewritten to match.
indirect='v=PATT; v="${v}ERN"; declare "$v=mapfile"'
status=0
caught="$(printf '%s\n%s\n' "$END" "$indirect" | names_pattern)" || status=$?
if [ "$status" -ne 0 ]; then
  bad "the indirection check could not run (awk exited $status)"
elif [ -n "$caught" ]; then
  bad "the guard now catches an assignment that never spells PATTERN" \
    "rewrite the stated gap beside it; it is no longer a gap"
else
  ok "an assignment that never spells PATTERN is still outside this guard"
fi

# And a render matches its source WHOLE, not only inside the block. Every
# rendered tests/ and scripts/ file in this repo is byte-identical to its
# source — the renderer injects into SKILL.md, not into code — so holding the
# pair to that costs nothing and catches drift the block comparison cannot.
for f in $CARRIER_SOURCES $EXCLUDED_SOURCES; do
  skip=no
  for u in $UNRENDERED; do [ "$u" = "$f" ] && skip=yes; done
  [ "$skip" = yes ] && continue
  r="$RENDER_PREFIX$f"
  status=0
  cmp -s "$f" "$r" || status=$?
  if [ "$status" -gt 1 ]; then
    bad "$f and $r could not be compared (cmp exited $status)"
  elif [ "$status" -eq 1 ]; then
    bad "$r differs from $f outside the shared block" \
      "$(diff "$f" "$r" | head -10)"
  else
    ok "$r is byte-identical to $f"
  fi
done

# The stated limit is a list, and these two checks keep it from going stale:
# the block names shapes a scan cannot decide in both directions, and each
# must still behave as the block says. Closing one is a contract change and
# reds here until that list is rewritten to match.
status=0
now_caught="$(scan hit "$PATTERN" "$UNCATCHABLE")" || status=$?
if [ "$status" -ne 0 ]; then
  bad "the stated-limit scan could not run (grep exited nonzero)"
elif [ -n "$now_caught" ]; then
  bad "the set now flags a construct the block says it misses" \
    "$(printf '%s\n' "$now_caught" | head -10)
rewrite the block's stated limit, or take the line out of the fixture"
else
  ok "every shape the block calls a miss is still unflagged"
fi
status=0
now_clean="$(scan miss "$PATTERN" "$OVERFLAGGED")" || status=$?
if [ "$status" -ne 0 ]; then
  bad "the over-flag scan could not run (grep exited nonzero)"
elif [ -n "$now_clean" ]; then
  bad "the set no longer flags source the block says it over-flags" \
    "$(printf '%s\n' "$now_clean" | head -10)
an anchor came back, or the line changed: rewrite the block's list to match"
else
  ok "every line the block calls an accepted over-flag is still flagged"
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
