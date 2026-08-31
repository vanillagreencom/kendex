#!/usr/bin/env bash
# The proof for `tools/bash32-lint`.
#
# Nine skills used to carry the scan and a tenth had it inlined; a parity
# suite held those copies byte-identical and proved the set once. There is one
# copy now, so the parity half is gone and this file is the proof half: teeth
# against the fixtures in tools/tests/data, a planted construct in every
# directory the roster resolves to, and a red for each way the lint can fail
# closed.
#
# EVERY CHECK HERE FAILS CLOSED. No result is read out of an empty string:
# git, grep and awk are asked for their status, and a command that could not
# run ends the run instead of scoring a pass. And THE PATTERN BLOCK IS NEVER
# EXECUTED — the quoted literals are lifted out and joined, and the result
# reaches nothing but `grep -E --`.
set -eu -o pipefail
ROOT="$(git rev-parse --show-toplevel)" || exit 2
cd "$ROOT" || exit 2

LINT="$ROOT/tools/bash32-lint"
BEGIN='# --- pattern set: begin ------------------------------------------------'
END='# --- pattern set: end --------------------------------------------------'
Q="'"

TMP="$(mktemp -d)" || exit 2
trap 'rm -rf -- "${TMP:?}"' EXIT

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

[ -x "$LINT" ] || {
  bad "tools/bash32-lint is missing or not executable"
  verdict
  exit
}

# --- 1. the roster resolves, and every entry is a real directory ---------
ROSTER=""
status=0
ROSTER="$("$LINT" --list)" || status=$?
if [ "$status" -ne 0 ] || [ -z "$ROSTER" ]; then
  bad "the lint could not list its roster (exit $status), so nothing below was planted"
  verdict
  exit
fi
roster_count=0
for d in $ROSTER; do
  roster_count=$((roster_count + 1))
  [ -d "$d" ] || bad "the roster names $d, which is not a directory"
done
if [ "$roster_count" -lt 5 ]; then
  bad "the roster resolved to $roster_count directories, too few to be the skill tree"
else
  ok "the roster resolves to $roster_count directories"
fi

# The roster is discovered, so it must actually cover the tree: every
# skills/*/scripts is scanned or named in one of the lint's exception lists.
# Read out of the lint rather than restated here — a second copy of the
# exceptions is the duplication this whole change removes.
NL='
'
declared=""
status=0
declared="$(sed -n 's#^NO_\(SCAN\|SHELL\)="\(.*\)"$#\2#p' "$LINT")" || status=$?
if [ "$status" -ne 0 ] || [ -z "$declared" ]; then
  bad "the lint's exception lists could not be read, so roster coverage is unproven"
else
  ok "the lint declares its exceptions: $(printf '%s' "$declared" | tr '\n' ' ')"
  for d in skills/*/scripts; do
    case "$NL$ROSTER$NL$declared$NL" in
    *"$NL$d$NL"*) continue ;;
    esac
    bad "$d is neither scanned nor declared as an exception"
  done
fi

# --- 2. the tree is clean, which is the assertion the lint exists to make -
status=0
out="$("$LINT" 2>&1)" || status=$?
if [ "$status" -eq 0 ]; then
  ok "no Bash 4+ construct in any shipped shell file"
else
  bad "the shipped tree does not scan clean (exit $status)" "$out"
fi

# --- 3. teeth: a planted construct reds EVERY roster directory ----------
# Copied rather than mutated in place: the assertion is about the directory
# the roster names, and the tree under test stays untouched.
planted=0
for d in $ROSTER; do
  work="$TMP/plant/$planted"
  mkdir -p "$work" || continue
  cp -R "$d" "$work/dir" || {
    bad "could not stage a copy of $d"
    continue
  }
  printf '#!/usr/bin/env bash\nlocal -A planted_cache\n' >"$work/dir/planted-probe.sh"
  status=0
  out="$("$LINT" "$work/dir" 2>&1)" || status=$?
  if [ "$status" -eq 1 ] && [ "${out#*planted-probe.sh}" != "$out" ]; then
    ok "a planted Bash 4 construct reds $d"
  else
    bad "a planted Bash 4 construct did NOT red $d (exit $status)" "$out"
  fi
  planted=$((planted + 1))
done
[ "$planted" -eq "$roster_count" ] ||
  bad "planted into $planted of $roster_count roster directories"

# --- 4. the lint's fail-closed paths, each proven red -------------------
expect_die() { # expect_die LABEL DIR
  local status=0 out=""
  out="$("$LINT" "$2" 2>&1)" || status=$?
  if [ "$status" -eq 2 ]; then
    ok "$1"
  else
    bad "$1 — exited $status, not 2" "$out"
  fi
}

mkdir -p "$TMP/empty"
expect_die "a directory holding no shell file is a scan that read nothing" "$TMP/empty"

mkdir -p "$TMP/nonshell"
printf '{"a":1}\n' >"$TMP/nonshell/fixture.json"
expect_die "a directory holding only non-shell files reads nothing either" "$TMP/nonshell"

# And an empty directory does not get carried by a populated one beside it.
# Without this the two cases above pass on the roster-wide "nothing was read"
# guard alone, and dropping the per-directory one costs nothing.
mkdir -p "$TMP/populated"
printf '#!/usr/bin/env bash\n:\n' >"$TMP/populated/real.sh"
status=0
out="$("$LINT" "$TMP/populated" "$TMP/empty" 2>&1)" || status=$?
if [ "$status" -eq 2 ]; then
  ok "an empty directory beside a populated one still ends the run"
else
  bad "an empty directory beside a populated one exited $status, not 2" "$out"
fi

# A construct this set does not name still has to be syntax.
mkdir -p "$TMP/syntax"
printf '#!/usr/bin/env bash\nif [ 1 -eq 1 ]; then\n' >"$TMP/syntax/broken.sh"
status=0
out="$("$LINT" "$TMP/syntax" 2>&1)" || status=$?
if [ "$status" -eq 1 ]; then
  ok "a shell file that does not parse reds the lint"
else
  bad "an unparsable shell file exited $status, not 1" "$out"
fi

# grep's status is part of the answer: 0 found, 1 none, anything else a scan
# that did not run. Proven by making the scan itself fail — a stub grep that
# answers the shebang probe and refuses the scan — rather than by an
# unreadable file, which root would read.
mkdir -p "$TMP/gbin"
cat >"$TMP/gbin/grep" <<'STUB'
#!/bin/sh
# -q is the shebang probe in is_shell; answer it from the real grep so
# discovery still works. Everything else is the scan, and it could not run.
for a in "$@"; do
  case "$a" in
  -q*) exec /usr/bin/env -i PATH=/usr/bin:/bin grep "$@" ;;
  esac
done
exit 2
STUB
chmod +x "$TMP/gbin/grep"
status=0
out="$(PATH="$TMP/gbin:$PATH" "$LINT" "$TMP/populated" 2>&1)" || status=$?
if [ "$status" -eq 2 ]; then
  ok "a scan that could not run is not read as a clean tree"
else
  bad "a failed grep exited $status, not 2" "$out"
fi

status=0
out="$("$LINT" "$TMP/no-such-directory" 2>&1)" || status=$?
if [ "$status" -eq 2 ]; then
  ok "a path that is not a directory ends the run"
else
  bad "a missing directory exited $status, not 2" "$out"
fi

# A stale exception excuses a directory nobody is checking, so the lint
# refuses to start on one. Proven against a copy with the entry rewritten.
mutant="$TMP/mutant-lint"
sed 's|^NO_SHELL=.*|NO_SHELL="skills/gone/scripts"|' "$LINT" >"$mutant" &&
  chmod +x "$mutant" || bad "could not stage the stale-exception mutant"
if [ -x "$mutant" ]; then
  grep -q 'skills/gone/scripts' "$mutant" || bad "the stale-exception mutation did not land"
  status=0
  out="$(cd "$ROOT" && "$mutant" 2>&1)" || status=$?
  if [ "$status" -eq 2 ]; then
    ok "an exception naming a directory that is gone ends the run"
  else
    bad "a stale exception exited $status, not 2" "$out"
  fi
fi

# And the other direction: a NO_SHELL directory that grows a shell file must
# stop being excused rather than staying silently unscanned.
noshell_dir=""
noshell_dir="$(sed -n 's#^NO_SHELL="\(.*\)"$#\1#p' "$LINT" | head -n 1)" || noshell_dir=""
if [ -n "$noshell_dir" ] && [ -d "$noshell_dir" ]; then
  ok "the NO_SHELL exception names $noshell_dir"
  probe_lint="$TMP/probe-noshell"
  probe_dir="$TMP/noshell-copy"
  cp -R "$noshell_dir" "$probe_dir" &&
    printf '#!/usr/bin/env bash\n:\n' >"$probe_dir/now-shell.sh" &&
    sed "s|^NO_SHELL=.*|NO_SHELL=\"$probe_dir\"|" "$LINT" >"$probe_lint" &&
    chmod +x "$probe_lint" || bad "could not stage the grew-a-shell-file probe"
  if [ -x "$probe_lint" ]; then
    status=0
    out="$("$probe_lint" "$probe_dir" 2>&1)" || status=$?
    if [ "$status" -eq 2 ]; then
      ok "a NO_SHELL directory that grew a shell file ends the run"
    else
      bad "a NO_SHELL directory with a shell file exited $status, not 2" "$out"
    fi
  fi
else
  bad "the lint declares no NO_SHELL directory this check could exercise"
fi

# --- 5. the pattern set, against the text the lint ships ----------------
# Built out of the block, not run from it. A single quote ends at the next
# one, so the literal between them is exactly the bytes in it and a line
# carrying a second quote is not an assignment — which is what an `eval` of a
# shape-checked line would have run.
extract() {
  awk -v begin="$BEGIN" -v end="$END" '
    $0 == begin { if (opened) malformed = 1; opened++; inside = 1; next }
    $0 == end   { if (!inside) malformed = 1; inside = 0; closed++; next }
    inside      { print }
    END { if (malformed || opened != 1 || closed != 1 || inside) exit 1 }
  ' "$1"
}
block=""
status=0
block="$(extract "$LINT")" || status=$?
if [ "$status" -ne 0 ]; then
  bad "the pattern block could not be read out of the lint (awk exited $status)"
  verdict
  exit
fi
ok "the lint holds one well-formed pattern block"

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
    case "$body" in
    *"$Q"*)
      bad "a block line closes its quote and keeps going, so it is not an assignment" "$line"
      built=refused
      break
      ;;
    esac
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
$block
EOF
if [ "$built" != yes ] || [ -z "$PATTERN" ]; then
  bad "no pattern could be built from the block, so nothing below was proven"
  verdict
  exit
fi
ok "the block parses as a PATTERN chain and was never executed"

# After the end marker the guard is a WHITELIST: a line may extend the set in
# the documented append form or READ the variable, and a line that names
# PATTERN any other way is refused, whatever the spelling. It was a blocklist
# once and came up short five times — `export PATTERN=`, `PATTERN[0]=`,
# `declare PATTERN=`, `readonly PATTERN=`, `printf -v PATTERN` all walked
# past it. What every assignment shares is that it NAMES the variable.
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
  ' "$1"
}
named=""
status=0
named="$(names_pattern "$LINT")" || status=$?
if [ "$status" -ne 0 ]; then
  bad "the lines after the marker could not be read (awk exited $status)"
elif [ -n "$named" ]; then
  bad "the lint names PATTERN after the end marker outside a read" \
    "$(printf '%s\n' "$named" | head -5)"
else
  ok "nothing after the end marker names PATTERN outside a read"
fi

# The gap this guard has, checked so the sentence above cannot go stale. An
# assignment that never spells the name is invisible to a text rule, and bash
# really does perform it. Reaching that means running the shell, not reading
# it; if it ever starts being caught, this reds and the claim gets rewritten.
gapfile="$TMP/gap"
printf '%s\nv=PATT; v="${v}ERN"; declare "$v=mapfile"\n' "$END" >"$gapfile"
status=0
caught="$(names_pattern "$gapfile")" || status=$?
if [ "$status" -ne 0 ]; then
  bad "the indirection check could not run (awk exited $status)"
elif [ -n "$caught" ]; then
  bad "the guard now catches an assignment that never spells PATTERN" \
    "rewrite the stated gap beside it; it is no longer a gap"
else
  ok "an assignment that never spells PATTERN is still outside this guard"
fi

# --- 6. the fixtures, one file per direction ----------------------------
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

# The stated limits are a list, and these two keep it from going stale: the
# lint names shapes a scan cannot decide in both directions, and each must
# still behave as it says. Closing one is a contract change and reds here
# until that list is rewritten to match.
status=0
now_caught="$(scan hit "$PATTERN" "$UNCATCHABLE")" || status=$?
if [ "$status" -ne 0 ]; then
  bad "the stated-limit scan could not run (grep exited nonzero)"
elif [ -n "$now_caught" ]; then
  bad "the set now flags a construct the lint says it misses" \
    "$(printf '%s\n' "$now_caught" | head -10)"
else
  ok "every shape the lint calls a miss is still unflagged"
fi
status=0
now_clean="$(scan miss "$PATTERN" "$OVERFLAGGED")" || status=$?
if [ "$status" -ne 0 ]; then
  bad "the over-flag scan could not run (grep exited nonzero)"
elif [ -n "$now_clean" ]; then
  bad "the set no longer flags source the lint says it over-flags" \
    "$(printf '%s\n' "$now_clean" | head -10)"
else
  ok "every line the lint calls an accepted over-flag is still flagged"
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

# --- 7. the extracted pattern is the one the lint runs ------------------
# Sections 5 and 6 judge text lifted out of the file. This closes the gap
# between that text and the program: one probe line the extracted set flags,
# planted as a file, must red the lint itself.
probe_line="$(printf '%s\n' "$PROBES" | head -n 1)"
mkdir -p "$TMP/derived"
printf '#!/usr/bin/env bash\n%s\n' "$probe_line" >"$TMP/derived/probe.sh"
status=0
out="$("$LINT" "$TMP/derived" 2>&1)" || status=$?
if [ "$status" -eq 1 ]; then
  ok "the first fixture probe reds the lint as run, not only as read"
else
  bad "the lint did not red on a fixture probe (exit $status)" "$out"
fi

verdict
