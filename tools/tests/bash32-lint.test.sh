#!/usr/bin/env bash
# The proof for `tools/bash32-lint`.
#
# This is the proof for the single shared scanner: fixtures in tools/tests/data,
# a planted construct in every directory the roster resolves to, and a red for
# each way the lint can fail closed.
#
# EVERY CHECK HERE FAILS CLOSED. No result is read out of an empty string:
# git, grep and the lint itself are asked for their status, and a command that
# could not run ends the run instead of scoring a pass. The resolved roster
# and the pattern set are both ASKED OF THE LINT — `--list` and `--pattern` —
# rather than restated here, so what is judged below is what the program runs.
# The roster's hand-named entries have no such question to ask, so they are
# read out of the roster line; that is still reading the lint rather than
# keeping a second copy of the list here.
set -eu -o pipefail

# A suite running from inside a git hook inherits GIT_DIR, GIT_COMMON_DIR,
# GIT_WORK_TREE and GIT_INDEX_FILE, which would resolve the no-repository
# row's fixture to the real repository.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

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
# skills/*/scripts and skills/*/tests is scanned or named in one of the
# lint's exception lists.
# Read out of the lint rather than restated here — a second copy of the
# exceptions is the duplication this whole change removes. -E, because `\|`
# alternation inside `\(...\)` is a GNU BRE extension: BSD sed reads it as a
# literal bar, matches nothing, and leaves the roster coverage unproven.
NL='
'
declared=""
status=0
declared="$(sed -nE 's#^NO_(SCAN|SHELL)="(.*)"$#\2#p' "$LINT" | tr ' ' '\n')" || status=$?
if [ "$status" -ne 0 ] || [ -z "$declared" ]; then
  bad "the lint's exception lists could not be read, so roster coverage is unproven"
else
  ok "the lint declares its exceptions: $(printf '%s' "$declared" | tr '\n' ' ')"
  for d in skills/*/scripts skills/*/tests; do
    case "$NL$ROSTER$NL$declared$NL" in
    *"$NL$d$NL"*) continue ;;
    esac
    bad "$d is neither scanned nor declared as an exception"
  done
fi

# The glob entries above answer for themselves: a skills/ directory that
# left the roster fails the loop. A hand-named entry does not, so it is
# read out of the roster line and looked for in what --list prints —
# dropping one from the line reds here. Read, never restated: a second copy
# of the roster is the staleness this file exists to catch.
named=""
status=0
named="$(sed -n 's#^  set -- \(.*\)$#\1#p' "$LINT" | tr ' ' '\n' | grep -v '[*]')" || status=$?
if [ "$status" -ne 0 ] || [ -z "$named" ]; then
  bad "no hand-named roster entry could be read from the lint, so none is proven listed"
else
  for d in $named; do
    case "$NL$ROSTER$NL" in
    *"$NL$d$NL"*) ok "the hand-named roster entry $d is in what --list prints" ;;
    *) bad "the roster line names $d, but --list does not print it" ;;
    esac
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

# A violation report must preserve a filename that contains sed metacharacters.
# Assert the exact reported line — file, line number, matched text —
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
# A row is `label|world|cwd|argv|exit`:
#   world  words for build, each staged fresh under the row's own directory
#          W: `empty` a directory holding nothing; `nonshell` one holding
#          only a JSON file; `populated` one holding a clean shell file;
#          `syntax` one holding a shell file that does not parse;
#          `unreadable-dir` a clean file beside a subdirectory nobody can
#          read; `unreadable-file` a clean file beside an extensionless
#          entry point nobody can read; `unenterable` a directory nobody can
#          enter; `grep-stub` a grep on PATH that answers the shebang probe
#          and refuses the scan; `unless-root` the row's outcome is
#          `skipped-as-root` under uid 0, which reads and enters every
#          directory whatever its mode; `lint:stale` a copy of the lint
#          whose NO_SHELL names a directory that is gone; `lint:grew` a copy
#          of the lint whose NO_SHELL names W/noshell, a copy of the real
#          NO_SHELL directory that grew a shell file; `lint:sealed` a copy
#          of the lint whose NO_SHELL names W/sealed, a directory nobody can
#          enter; `-` for nothing staged
#   cwd    where the lint runs: `root` the toplevel, `world` W, any other
#          value a path under the toplevel
#   argv   the lint's arguments as written: `W/<path>` a path under W,
#          `NO_SCAN` and `NO_SHELL` the lint's own entries as it declares
#          them, `ROOT/NO_SCAN` the NO_SCAN directory spelled absolute, any
#          other word itself; `-` for none
#   exit   the exit status
#
# The exception entries are repository-relative, so a relative DIR from a
# subdirectory proves they are read from the toplevel and not beneath the
# caller's cwd, and the two NO_SCAN spellings prove an exception is a
# directory rather than a string. The price of that is the no-repository
# row: with nothing to resolve the toplevel from, the exceptions cannot be
# judged and the run ends. A directory holding only non-shell files beside
# a populated one is the per-directory guard, which the roster-wide "nothing
# was read" guard would otherwise carry, and a run naming only a NO_SHELL
# directory is that roster-wide guard; an empty directory ends the run
# before either, on the empty listing it cannot classify. A failed grep is
# proven by a stub that refuses the scan
# rather than by an unreadable file, which root would read; the discovery
# and resolution halves have no such stub and skip under root instead.

# Read out of the lint, never restated. A run that could not read them ends
# here: a row handed an empty entry would be refused as "not a directory"
# and score the 2 it expects.
NOSCAN=""
NOSCAN="$(sed -n 's#^NO_SCAN="\(.*\)"$#\1#p' "$LINT")" || NOSCAN=""
NOSCAN="${NOSCAN%% *}"
NOSHELL=""
NOSHELL="$(sed -n 's#^NO_SHELL="\(.*\)"$#\1#p' "$LINT")" || NOSHELL=""
NOSHELL="${NOSHELL%% *}"
if [ -z "$NOSCAN" ] || [ ! -d "$ROOT/$NOSCAN" ] || [ -z "$NOSHELL" ] || [ ! -d "$ROOT/$NOSHELL" ]; then
  bad "precondition: the lint declares no NO_SCAN and NO_SHELL directory the rows could exercise"
  verdict
  exit
fi
ok "precondition: the exceptions name directories: NO_SCAN $NOSCAN, NO_SHELL $NOSHELL"

# Every row's directory sits below the ceiling set at the top of this file,
# so it is outside every repository. Asserted rather than assumed: under a
# TMPDIR inside a checkout the no-repository row would resolve a toplevel,
# scan clean, and report that the fail-closed path held.
WORLDS="$TMP/worlds"
mkdir -p "$WORLDS" || {
  bad "precondition: the fixture root could not be staged"
  verdict
  exit
}
if inroot="$(cd "$WORLDS" && git rev-parse --show-toplevel 2>/dev/null)"; then
  bad "precondition: the fixture root sits in a git repository ($inroot), so nothing here is proven"
  verdict
  exit
fi
ok "precondition: the fixture root is outside every repository"

W=""
W_LINT="$LINT"
W_PATH="$PATH"
W_SKIP=no
row_n=0

# mutate_lint LINE — a copy of the lint with its NO_SHELL line replaced by
# LINE, asserted to have landed exactly once: an edit that landed nowhere
# would run the unmodified lint and prove nothing.
mutate_lint() {
  local landed=0
  sed "s|^NO_SHELL=.*|$1|" "$LINT" >"$W/lint" || return 1
  chmod +x "$W/lint" || return 1
  landed="$(grep -Fxc -- "$1" "$W/lint")" || return 1
  [ "$landed" -eq 1 ] || return 1
  W_LINT="$W/lint"
}

# -q is the shebang probe in is_shell; the stub answers it from the real
# grep so discovery still works. Everything else is the scan, and it could
# not run.
stage_grep_stub() {
  mkdir "$W/bin" || return 1
  cat >"$W/bin/grep" <<'STUB' || return 1
#!/bin/sh
for a in "$@"; do
  case "$a" in
  -q*) exec /usr/bin/env -i PATH=/usr/bin:/bin grep "$@" ;;
  esac
done
exit 2
STUB
  chmod +x "$W/bin/grep" || return 1
  W_PATH="$W/bin:$PATH"
}

word() { # word WORD — stage one world word under W
  case "$1" in
  empty) mkdir "$W/empty" ;;
  nonshell)
    mkdir "$W/nonshell" &&
      printf '{"a":1}\n' >"$W/nonshell/fixture.json"
    ;;
  populated)
    mkdir "$W/populated" &&
      printf '#!/usr/bin/env bash\n:\n' >"$W/populated/real.sh"
    ;;
  syntax)
    mkdir "$W/syntax" &&
      printf '#!/usr/bin/env bash\nif [ 1 -eq 1 ]; then\n' >"$W/syntax/broken.sh"
    ;;
  unreadable-dir)
    mkdir -p "$W/unreadable-dir/sub" &&
      printf '#!/usr/bin/env bash\n:\n' >"$W/unreadable-dir/a.sh" &&
      printf '#!/usr/bin/env bash\nlocal -A cache\n' >"$W/unreadable-dir/sub/bad.sh" &&
      chmod 000 "$W/unreadable-dir/sub"
    ;;
  unreadable-file)
    # Extensionless entry points are classified by their shebang, so an
    # unreadable one would answer "not shell" and leave the scan short.
    mkdir "$W/unreadable-file" &&
      printf '#!/usr/bin/env bash\n:\n' >"$W/unreadable-file/real.sh" &&
      printf '#!/usr/bin/env bash\nlocal -A cache\n' >"$W/unreadable-file/entrypoint" &&
      chmod 000 "$W/unreadable-file/entrypoint"
    ;;
  unenterable)
    mkdir "$W/unenterable" &&
      chmod 000 "$W/unenterable"
    ;;
  grep-stub) stage_grep_stub ;;
  unless-root) W_SKIP=yes ;;
  lint:stale) mutate_lint 'NO_SHELL="skills/gone/scripts"' ;;
  lint:grew)
    cp -R "$ROOT/$NOSHELL" "$W/noshell" &&
      printf '#!/usr/bin/env bash\n:\n' >"$W/noshell/now-shell.sh" &&
      mutate_lint "NO_SHELL=\"$W/noshell\""
    ;;
  lint:sealed)
    mkdir "$W/sealed" &&
      chmod 000 "$W/sealed" &&
      mutate_lint "NO_SHELL=\"$W/sealed\""
    ;;
  -) ;;
  *)
    printf 'unknown world word: %s\n' "$1" >&2
    exit 2
    ;;
  esac
}

build() { # build WORD... — a fresh directory W, then each word staged in it
  local w
  row_n=$((row_n + 1))
  W="$WORLDS/$row_n"
  W_LINT="$LINT"
  W_PATH="$PATH"
  W_SKIP=no
  mkdir "$W" || return 1
  for w in "$@"; do
    word "$w" || return 1
  done
}

arg_of() { # arg_of TOKEN — a row's argv token as the argument it names
  case "$1" in
  W/*) printf '%s/%s' "$W" "${1#W/}" ;;
  NO_SCAN) printf '%s' "$NOSCAN" ;;
  NO_SHELL) printf '%s' "$NOSHELL" ;;
  ROOT/NO_SCAN) printf '%s/%s' "$ROOT" "$NOSCAN" ;;
  *) printf '%s' "$1" ;;
  esac
}

run() { # run CWD ARGV — `rc=<status>`, or `rc=skipped-as-root`
  local rc=0 dir="" a=""
  local -a argv=()
  if [ "$W_SKIP" = yes ] && [ "$(id -u)" -eq 0 ]; then
    printf 'rc=skipped-as-root'
    return
  fi
  case "$1" in
  root) dir="$ROOT" ;;
  world) dir="$W" ;;
  *) dir="$ROOT/$1" ;;
  esac
  if [ "$2" != - ]; then
    for a in $2; do
      argv+=("$(arg_of "$a")")
    done
  fi
  (cd "$dir" && PATH="$W_PATH" "$W_LINT" ${argv[@]+"${argv[@]}"} >"$W/stdout" 2>"$W/stderr") || rc=$?
  # The modes an unreadable world set come off, so the EXIT trap can remove it.
  chmod -R u+rwX "$W"
  printf 'rc=%s' "$rc"
}

run_table() { # run_table TITLE ROWS
  local title="$1" rows="$2" label world cwd argv want got row field before=$((PASS + FAIL))
  printf '=== %s ===\n' "$title"
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    IFS='|' read -r label world cwd argv want <<<"$row"
    for field in "$label" "$world" "$cwd" "$argv" "$want"; do
      [ -n "$field" ] || {
        printf 'a row with an empty field asserts nothing: %s\n' "$row" >&2
        exit 1
      }
    done
    # shellcheck disable=SC2086
    if ! build $world; then
      bad "$label" "the world could not be staged: $world"
      continue
    fi
    got="$(run "$cwd" "$argv")"
    # A rendering aid for writing rows; the run is refused after the loop.
    if [ "${TOOLS_TABLE_PROBE:-}" = 1 ]; then
      printf '%s => %s\n' "$label" "$got"
      continue
    fi
    if [ "$got" = "rc=skipped-as-root" ]; then
      printf '  skip  %s (%s)\n' "$label" "$got"
    elif [ "$got" = "rc=$want" ]; then
      ok "$label"
    else
      bad "$label (want rc=$want, got $got)" "$(tr '\n' ';' <"$W/stderr")"
    fi
  done <<EOF
$rows
EOF
  [ "$((PASS + FAIL))" -gt "$before" ] || {
    printf 'no row was asserted (a probe run renders rows instead)\n' >&2
    exit 2
  }
}

run_table "the fail-closed paths" "\
a directory holding no shell file is a scan that read nothing|empty|root|W/empty|2
a directory holding only non-shell files reads nothing either|nonshell|root|W/nonshell|2
a relative DIR argument from a subdirectory scans clean|-|skills/orch|scripts|0
the NO_SCAN exception holds when its directory is named relative to the toplevel|-|root|NO_SCAN|2
the NO_SCAN exception holds when its directory is named absolute|-|root|ROOT/NO_SCAN|2
a run with no repository around it ends rather than scanning|populated|world|populated|2
an empty directory beside a populated one still ends the run|populated empty|root|W/populated W/empty|2
a directory holding only non-shell files beside a populated one still ends the run|populated nonshell|root|W/populated W/nonshell|2
a run naming only a NO_SHELL directory read nothing|-|root|NO_SHELL|2
a shell file that does not parse reds the lint|syntax|root|W/syntax|1
a scan that could not run is not read as a clean tree|populated grep-stub|root|W/populated|2
a file list that could not be built is not read as a clean tree|unreadable-dir unless-root|root|W/unreadable-dir|2
a file that could not be classified ends the run rather than being dropped|unreadable-file unless-root|root|W/unreadable-file|2
a path that is not a directory ends the run|-|root|W/no-such-directory|2
a directory that cannot be entered ends the run|unenterable unless-root|root|W/unenterable|2
an exception naming a directory that is gone ends the run|lint:stale|root|-|2
a NO_SHELL directory that grew a shell file ends the run|lint:grew|root|W/noshell|2
an exception naming a directory that cannot be entered ends the run|populated lint:sealed unless-root|root|W/populated|2"

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
