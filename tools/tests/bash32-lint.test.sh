#!/usr/bin/env bash
# The proof for `tools/bash32-lint`.
#
# A copy of the scan used to sit in each skill that wanted one, with a further
# one inlined in a github suite; a parity suite held those copies
# byte-identical and proved the set once. There is one copy now, so the parity
# half is gone and this file is the proof half: teeth against the fixtures in
# tools/tests/data, a planted construct in every directory the roster resolves
# to, and a red for each way the lint can fail closed.
#
# EVERY CHECK HERE FAILS CLOSED. No result is read out of an empty string:
# git, grep and the lint itself are asked for their status, and a command that
# could not run ends the run instead of scoring a pass. The roster and the
# pattern set are both ASKED OF THE LINT — `--list` and `--pattern` — rather
# than restated here or parsed back out of its source, so what is judged below
# is what the program runs.
set -eu -o pipefail
ROOT="$(git rev-parse --show-toplevel)" || exit 2
cd "$ROOT" || exit 2

LINT="$ROOT/tools/bash32-lint"

# A physical path, and a ceiling on it: § 4 needs a directory that is in no
# git repository, and TMPDIR can sit inside a checkout — this repository's own
# guidance puts scratch under tmp/. The ceiling stops git's upward search at
# $TMP, so a fixture BELOW $TMP is outside every repository; § 4 asserts that
# it worked rather than assuming it.
TMP="$(cd "$(mktemp -d)" && pwd -P)" || exit 2
trap 'rm -rf -- "${TMP:?}"' EXIT
export GIT_CEILING_DIRECTORIES="$TMP"

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
  # A second probe one level down. Half the roster's shell lives in a
  # scripts/lib or scripts/commands, so a discovery that stopped at the top
  # level would still red on the probe above while reading none of it.
  mkdir -p "$work/dir/nested" || bad "could not stage a nested directory under $d"
  printf '#!/usr/bin/env bash\nlocal -A planted_cache\n' >"$work/dir/nested/planted-nested.sh"
  status=0
  out="$("$LINT" "$work/dir" 2>&1)" || status=$?
  if [ "$status" -eq 1 ] && [ "${out#*planted-probe.sh}" != "$out" ]; then
    ok "a planted Bash 4 construct reds $d"
  else
    bad "a planted Bash 4 construct did NOT red $d (exit $status)" "$out"
  fi
  if [ "${out#*nested/planted-nested.sh}" != "$out" ]; then
    ok "the scan of $d reaches a nested directory"
  else
    bad "the scan of $d never read nested/planted-nested.sh (exit $status)" "$out"
  fi
  planted=$((planted + 1))
done
[ "$planted" -eq "$roster_count" ] ||
  bad "planted into $planted of $roster_count roster directories"

# A violation the lint cannot name is a report nobody can act on. The filename
# used to be interpolated into a sed PROGRAM, so a `|` in it closed the s
# command's delimiter and a `\1` read as a backreference; sed died either way
# and every hit for that file was discarded under a header that still printed.
# Asserted on the exact reported line — file, line number, matched text —
# because a check on the exit code alone passes against that prefixer: the run
# reds regardless, on a trailing newline rather than on a report.
mkdir -p "$TMP/odd-name" || bad "could not stage the odd-name directory"
odd="$TMP/odd-name/a|b\\1.sh"
printf '#!/usr/bin/env bash\n:\n' >"$TMP/odd-name/clean.sh"
printf '#!/usr/bin/env bash\nlocal -A cache\n' >"$odd"
if [ ! -f "$odd" ]; then
  bad "the odd-name fixture was not staged, so nothing here is proven"
else
  status=0
  out="$("$LINT" "$TMP/odd-name" 2>&1)" || status=$?
  if [ "$status" -ne 1 ]; then
    bad "a construct in a file whose name holds | and \\ exited $status, not 1" "$out"
  elif grep -Fqx -- "$odd:2:local -A cache" <<<"$out"; then
    ok "a violation names its file and matched text whatever the filename holds"
  else
    bad "the violation output names neither $odd nor its matched text" "$out"
  fi
fi

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

# The roster's exception entries are repository-relative, so they have to be
# read from the toplevel and not from wherever the caller stands. Invoked with
# a relative DIR from a subdirectory, the run must scan that DIR and say clean
# rather than die on an exception it failed to find beneath the caller's cwd.
status=0
out="$(cd "$ROOT/skills/orch" && "$LINT" scripts 2>&1)" || status=$?
if [ "$status" -eq 0 ]; then
  ok "a relative DIR argument from a subdirectory scans clean"
else
  bad "a relative DIR from a subdirectory exited $status, not 0" "$out"
fi

# An exception is a directory, not a string, so it must hold under every
# spelling of that directory: relative to the toplevel, and absolute. The two
# diverging is an exception that excuses a run named one way and scans the
# same tree named the other.
noscan_dir=""
noscan_dir="$(sed -n 's#^NO_SCAN="\(.*\)"$#\1#p' "$LINT" | head -n 1)" || noscan_dir=""
if [ -z "$noscan_dir" ] || [ ! -d "$ROOT/$noscan_dir" ]; then
  bad "the lint declares no NO_SCAN directory these spellings could exercise"
else
  for spelling in "$noscan_dir" "$ROOT/$noscan_dir"; do
    status=0
    out="$(cd "$ROOT" && "$LINT" "$spelling" 2>&1)" || status=$?
    if [ "$status" -eq 2 ]; then
      ok "the NO_SCAN exception holds when its directory is named as $spelling"
    else
      bad "naming the exception as $spelling exited $status, not 2" "$out"
    fi
  done
fi

# And the price of reading them from the toplevel, stated: with no repository
# around it the exceptions cannot be judged at all, so the run ends instead of
# scanning a roster nothing checked. The fixture sits BELOW the ceiling set at
# the top of this file, and its being outside a repository is asserted rather
# than assumed — under a TMPDIR inside a checkout it would otherwise resolve a
# toplevel, scan clean, and report that the fail-closed path held.
mkdir -p "$TMP/norepo/populated"
printf '#!/usr/bin/env bash\n:\n' >"$TMP/norepo/populated/real.sh"
if noroot="$(cd "$TMP/norepo" && git rev-parse --show-toplevel 2>/dev/null)"; then
  bad "the no-repository fixture sits in a git repository ($noroot), so nothing here is proven"
else
  status=0
  out="$(cd "$TMP/norepo" && "$LINT" populated 2>&1)" || status=$?
  if [ "$status" -eq 2 ]; then
    ok "a run with no repository around it ends rather than scanning"
  else
    bad "a run outside a repository exited $status, not 2" "$out"
  fi
fi

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

# Discovery is the other half of the same contract: a file list that could not
# be built, and a file that could not be classified, are each a scan that did
# not run. Root reads both regardless, so the pair is skipped there rather
# than scored as a pass.
if [ "$(id -u)" -ne 0 ]; then
  mkdir -p "$TMP/unreadable-dir/sub"
  printf '#!/usr/bin/env bash\n:\n' >"$TMP/unreadable-dir/a.sh"
  printf '#!/usr/bin/env bash\nlocal -A cache\n' >"$TMP/unreadable-dir/sub/bad.sh"
  chmod 000 "$TMP/unreadable-dir/sub"
  status=0
  out="$("$LINT" "$TMP/unreadable-dir" 2>&1)" || status=$?
  chmod 755 "$TMP/unreadable-dir/sub"
  if [ "$status" -eq 2 ]; then
    ok "a file list that could not be built is not read as a clean tree"
  else
    bad "an unreadable subdirectory exited $status, not 2" "$out"
  fi

  # Extensionless entry points are classified by their shebang, so an
  # unreadable one would answer "not shell" and leave the scan silently short.
  mkdir -p "$TMP/unreadable-file"
  printf '#!/usr/bin/env bash\n:\n' >"$TMP/unreadable-file/real.sh"
  printf '#!/usr/bin/env bash\nlocal -A cache\n' >"$TMP/unreadable-file/entrypoint"
  chmod 000 "$TMP/unreadable-file/entrypoint"
  status=0
  out="$("$LINT" "$TMP/unreadable-file" 2>&1)" || status=$?
  chmod 644 "$TMP/unreadable-file/entrypoint"
  if [ "$status" -eq 2 ]; then
    ok "a file that could not be classified ends the run rather than being dropped"
  else
    bad "an unreadable extensionless file exited $status, not 2" "$out"
  fi
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

# --- 5. the pattern set, as the lint itself reports it -------------------
# Asked of the program, not lifted out of its text: `--pattern` prints the
# string the scan greps with, so everything below judges what actually runs
# and the source's section markers carry no contract.
PATTERN=""
status=0
PATTERN="$("$LINT" --pattern)" || status=$?
if [ "$status" -ne 0 ] || [ -z "$PATTERN" ]; then
  bad "the lint could not print its pattern set (exit $status), so nothing below was proven"
  verdict
  exit
fi
ok "the lint prints the pattern set it runs"

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

# --- 7. the bridge: what --pattern reports is what the scan runs ---------
# §§ 5 and 6 judge the string `--pattern` prints, and nothing above ties that
# string to the one the scan greps with. A lint that reported the whole set
# while scanning with a narrower one would pass every check to here, and its
# tree would go on reporting clean with a construct in it — a scan weaker than
# its report is the dangerous direction for a gate to fail in.
#
# So the whole probe set is put through the PROGRAM: one file per probe line,
# one scan over the directory, and each probe must come back in the violations
# output. Matched on the line grep produced rather than on the filename, so a
# `bash -n` failure — which also reds the run — cannot stand in for a hit.
probe_files="$TMP/probe-files"
mkdir -p "$probe_files" || bad "could not stage the probe-file directory"
probe_n=0
while IFS= read -r line; do
  [ -n "$line" ] || continue
  probe_n=$((probe_n + 1))
  printf '%s\n' "$line" >"$probe_files/probe-$probe_n.sh"
done <<EOF
$PROBES
EOF
status=0
out="$("$LINT" "$probe_files" 2>&1)" || status=$?
if [ "$probe_n" -lt 50 ]; then
  bad "$probe_n probe files were staged, too few to be the probe set"
elif [ "$status" -ne 1 ]; then
  bad "the scan over the staged probe set exited $status, not 1" "$out"
else
  unreported=""
  i=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    i=$((i + 1))
    grep -Fqx -- "$probe_files/probe-$i.sh:1:$line" <<<"$out" ||
      unreported="$unreported$line
"
  done <<EOF
$PROBES
EOF
  if [ -n "$unreported" ]; then
    bad "the scan reported no violation for constructs the pattern set names" \
      "$(printf '%s\n' "$unreported" | head -20)"
  else
    ok "all $probe_n probes are flagged by the program, not merely by its report"
  fi
fi

verdict
