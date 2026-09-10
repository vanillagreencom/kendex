#!/usr/bin/env bash
# The proof for `tools/bash32-parse`.
#
# Two things are proven here and nothing else is: the covered set is the one
# the lane declares, and a file Bash 3.2 refuses at parse time reds — while
# the host shell and tools/bash32-lint both read it as clean, which is why
# this lane exists. Under it, every way the pass can fail to run, each proven
# red, because a pass that did not run must never be read as a clean tree.
#
# The workspace is inside the repository on purpose: a directory the lane is
# handed is read through the tree's own mount, and one outside it is a
# refusal this file also asserts.
set -eu -o pipefail

unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

ROOT="$(git rev-parse --show-toplevel)" || exit 2
cd "$ROOT" || exit 2

PARSE="$ROOT/tools/bash32-parse"
LINT="$ROOT/tools/bash32-lint"

mkdir -p "$ROOT/tmp" || exit 2
W="$(mktemp -d "$ROOT/tmp/bash32-parse.XXXXXX")" || exit 2
OUTSIDE="$(cd "$(mktemp -d)" && pwd -P)" || exit 2
trap 'rm -rf -- "${W:?}" "${OUTSIDE:?}"' EXIT

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

[ -x "$PARSE" ] || {
  bad "tools/bash32-parse is missing or not executable"
  verdict
  exit
}

# run PROGRAM ARG... — `rc=<status> first=<key>=<value>`, the keyed line taken
# from LINE 1 of whichever stream answered. A dependency's words reaching that
# stream ahead of the keyed line is the defect this reads for.
RC=0
OUT=""
run() {
  local prog="$1"
  shift
  RC=0
  ("$prog" "$@" >"$W/stdout" 2>"$W/stderr") || RC=$?
  if [ -s "$W/stderr" ]; then
    FIRST="$(sed -n '1s/^bash32-parse: //p' "$W/stderr")"
  else
    FIRST="$(sed -n '1s/^bash32-parse: //p' "$W/stdout")"
  fi
  FIRST="${FIRST:--}"
  OUT="$(cat "$W/stdout" "$W/stderr")"
}

# --- 1. the covered set is the lane's own declaration --------------------
# Read out of the two programs rather than restated here: the roster comes
# from the lint, and what the lane adds to it comes off its own declaration
# line. A second copy of either list here would go stale against them.
COVERED=""
status=0
COVERED="$("$PARSE" --list)" || status=$?
if [ "$status" -ne 0 ] || [ -z "$COVERED" ]; then
  bad "the lane could not list its covered set (exit $status), so nothing below was planted"
  verdict
  exit
fi
NL='
'
ROSTER=""
ROSTER="$("$LINT" --list)" || ROSTER=""
if [ -z "$ROSTER" ]; then
  bad "the lint could not list its roster, so the covered set is unproven"
else
  missing=""
  for d in $ROSTER; do
    case "$NL$COVERED$NL" in
    *"$NL$d$NL"*) ;;
    *) missing="$missing $d" ;;
    esac
  done
  if [ -z "$missing" ]; then
    ok "every directory the lint scans is in the covered set"
  else
    bad "the covered set misses a directory the lint scans:$missing"
  fi
fi
EXTRA=""
EXTRA="$(sed -n 's#^COVERED_EXTRA="\(.*\)"$#\1#p' "$PARSE")" || EXTRA=""
if [ -z "$EXTRA" ]; then
  bad "the lane declares no directory of its own beyond the lint's roster"
else
  for d in $EXTRA; do
    case "$NL$COVERED$NL" in
    *"$NL$d$NL"*) [ -d "$d" ] &&
      ok "the lane's own covered directory $d is listed and is a directory" ||
      bad "the covered set names $d, which is not a directory" ;;
    *) bad "the lane declares $d as covered, but --list does not print it" ;;
    esac
  done
fi

# --- 2. the tree parses, which is the assertion the lane exists to make ---
run "$PARSE"
if [ "$RC" -eq 0 ]; then
  ok "every covered tree parses under a real Bash 3.2"
else
  bad "the covered set does not parse under Bash 3.2 (exit $RC)" "$OUT"
fi

# --- 3. teeth ------------------------------------------------------------
# The planted defect is the one from the failure this lane answers: a `case`
# inside a command substitution whose patterns carry no leading `(`. Bash 5
# parses it and Bash 3.2 refuses it, so both are asserted below — the row is
# no proof of the interpreter otherwise.
PLANT_DIR=""
plant() { # plant refuse|pass LABEL LINE... — a fresh directory, then the file
  local want="$1" label="$2"
  shift 2
  PLANT_DIR="$W/plant-$((PASS + FAIL))"
  mkdir -p "$PLANT_DIR" || {
    bad "$label" "the directory could not be staged"
    return
  }
  printf '#!/usr/bin/env bash\n:\n' >"$PLANT_DIR/clean.sh"
  printf '%s\n' '#!/usr/bin/env bash' "$@" >"$PLANT_DIR/planted.sh"
  run "$PARSE" "$PLANT_DIR"
  if [ "$want" = refuse ] && [ "$RC" -eq 1 ] && [ "$FIRST" = "syntax=1" ] &&
    [ "${OUT#*planted.sh}" != "$OUT" ]; then
    ok "$label"
  elif [ "$want" = pass ] && [ "$RC" -eq 0 ]; then
    ok "$label"
  else
    bad "$label" "rc=$RC first=$FIRST out=$(printf '%s' "$OUT" | tr '\n' ';')"
  fi
}

plant refuse "an unbalanced case pattern inside a command substitution reds the lane" \
  'verdicts=$(for v in a b; do' \
  '  case "$v" in' \
  '    a) echo one ;;' \
  '    b) echo two ;;' \
  '  esac' \
  'done)' \
  'printf "%s\n" "$verdicts"'
CASE_DIR="$PLANT_DIR"
plant pass "the same case with balanced patterns passes" \
  'verdicts=$(for v in a b; do' \
  '  case "$v" in' \
  '    (a) echo one ;;' \
  '    (b) echo two ;;' \
  '  esac' \
  'done)' \
  'printf "%s\n" "$verdicts"'

# The two readers that miss it, asserted on the very file the row above
# reddened: the host shell parses it, and the lint's text scan calls the
# directory clean. Without both, the red above could be any syntax error.
if [ -z "$CASE_DIR" ] || [ ! -f "$CASE_DIR/planted.sh" ]; then
  bad "the planted case file was not kept, so neither reader below was asked about it"
else
  if bash -n -- "$CASE_DIR/planted.sh" 2>/dev/null; then
    ok "the shell running this suite parses the planted file, so the red came from another one"
  elif [ "${BASH_VERSION%%.*}" = 3 ]; then
    ok "the shell running this suite is Bash ${BASH_VERSION}, which is the one the lane runs"
  else
    bad "Bash $BASH_VERSION refused the planted file, so it is not the Bash 3.2-only shape"
  fi
  status=0
  "$LINT" "$CASE_DIR" >/dev/null 2>&1 || status=$?
  if [ "$status" -eq 0 ]; then
    ok "the lint's text scan reads the planted file as clean, which is why this lane exists"
  else
    bad "the lint reddened the planted file (exit $status), so this row proves nothing about the parse pass"
  fi
fi

# --- 4. the fail-closed paths, each proven red ---------------------------
# A row is `label|mutation|argv|exit|first`:
#   mutation  a copy of the lane with one or two of its declaration lines
#             replaced, staged under the row's own directory beside a copy of
#             the lint the copy resolves as its sibling:
#             `bash5`   the host candidate answers Bash 5, and the runtime
#                       name is one no machine has — a host with neither
#             `runtime` the host candidate answers Bash 5, and `docker` on
#                       PATH is a stub that cannot deliver the image
#             `lint`    the file list comes back empty
#             `silent`  the pass under 3.2 answers nothing at all
#             `short`   the pass reports reading fewer files than it was given
#             `-`       the shipped lane, unmodified
#   argv      `world` a staged directory holding one clean shell file;
#             `outside` a directory outside this repository; `empty` a
#             directory holding nothing; `file` a path that is a file rather
#             than a directory
#   exit      the exit status
#   first     LINE 1 of the stream the run answered on, as `<key>=<value>`
#             with the `bash32-parse: ` prefix off. Every row here exits 2,
#             so the key is what tells one refusal from another.
stage_stub() { # stage_stub DIR NAME VERSION BODY — a fake interpreter
  mkdir -p "$1" || return 1
  {
    printf '%s\n' '#!/bin/sh'
    printf 'if [ "$1" = -c ]; then printf %%s %s; exit 0; fi\n' "'$3'"
    printf '%s\n' "$4"
  } >"$1/$2" || return 1
  chmod +x "$1/$2"
}

MW=""
MPATH=""
MUTANT=""
mutate() { # mutate WORD — stage the row's world and the lane copy it runs
  MW="$W/row-$((PASS + FAIL))"
  MPATH="$PATH"
  MUTANT="$PARSE"
  mkdir -p "$MW/world" "$MW/empty" "$MW/bin" "$MW/tools" || return 1
  printf '#!/usr/bin/env bash\n:\n' >"$MW/world/real.sh" || return 1
  [ "$1" = - ] && return 0
  cp "$LINT" "$MW/tools/bash32-lint" || return 1
  MUTANT="$MW/tools/bash32-parse"
  local candidates="CANDIDATES=\"$MW/bin/five\"" runtime='RUNTIME_CMD="docker"' lint=""
  case "$1" in
  bash5)
    stage_stub "$MW/bin" five '5.0.0(1)-release' 'exit 0' || return 1
    runtime='RUNTIME_CMD="bash32-parse-no-such-runtime"'
    ;;
  runtime)
    stage_stub "$MW/bin" five '5.0.0(1)-release' 'exit 0' || return 1
    stage_stub "$MW/bin" docker '' 'echo "no such image" >&2; exit 125' || return 1
    MPATH="$MW/bin:$PATH"
    ;;
  lint)
    candidates=""
    printf '%s\n' '#!/bin/sh' 'exit 0' >"$MW/bin/emptylint" || return 1
    chmod +x "$MW/bin/emptylint" || return 1
    lint="LINT=\"$MW/bin/emptylint\""
    ;;
  silent)
    stage_stub "$MW/bin" five '3.2.57(1)-release' 'exit 0' || return 1
    ;;
  short)
    stage_stub "$MW/bin" five '3.2.57(1)-release' \
      'printf "bash32-parse: parsed=0\nbash32-parse: failed=0\n"; exit 0' || return 1
    ;;
  *)
    printf 'unknown mutation word: %s\n' "$1" >&2
    exit 2
    ;;
  esac
  # Each replacement is asserted to have landed: an edit that matched nothing
  # would run the shipped lane and score the row it was meant to force.
  local expr="" line=""
  for line in "$candidates" "$runtime" "$lint"; do
    [ -n "$line" ] || continue
    expr="$expr -e s|^${line%%=*}=.*|$line|"
  done
  # shellcheck disable=SC2086 # each -e and its expression is one word
  sed $expr "$PARSE" >"$MUTANT" || return 1
  chmod +x "$MUTANT" || return 1
  for line in "$candidates" "$runtime" "$lint"; do
    [ -n "$line" ] || continue
    [ "$(grep -Fxc -- "$line" "$MUTANT")" -eq 1 ] || return 1
  done
}

row_argv() { # row_argv TOKEN
  case "$1" in
  world) printf '%s' "$MW/world" ;;
  outside) printf '%s' "$OUTSIDE" ;;
  empty) printf '%s' "$MW/empty" ;;
  file) printf '%s' "$MW/world/real.sh" ;;
  *) printf '%s' "$1" ;;
  esac
}

rows="\
a directory outside the repository is refused rather than reached|-|outside|2|outside-repo=outside
a path that is not a directory ends the run|-|file|2|unresolvable=file
a file list that could not be built is not read as a clean tree|-|empty|2|listing=2
a host with no Bash 3.2 and no container runtime refuses|bash5|world|2|no-bash32=absent
a container runtime that cannot deliver the image refuses|runtime|world|2|no-bash32=docker
an empty file list is not read as a clean tree|lint|world|2|no-files=0
a pass that answers nothing reaches no verdict|silent|world|2|no-verdict=0
a pass that read fewer files than it was given reaches no verdict|short|world|2|short=0"

asserted=0
while IFS='|' read -r label mutation argv want first; do
  [ -n "$label" ] || continue
  if ! mutate "$mutation"; then
    bad "$label" "the row's world could not be staged"
    continue
  fi
  RC=0
  (PATH="$MPATH" "$MUTANT" "$(row_argv "$argv")" >"$W/stdout" 2>"$W/stderr") ||
    RC=$?
  if [ -s "$W/stderr" ]; then
    FIRST="$(sed -n '1s/^bash32-parse: //p' "$W/stderr")"
  else
    FIRST="$(sed -n '1s/^bash32-parse: //p' "$W/stdout")"
  fi
  want_val="$(row_argv "${first#*=}")"
  asserted=$((asserted + 1))
  if [ "$RC" = "$want" ] && [ "$FIRST" = "${first%%=*}=$want_val" ]; then
    ok "$label"
  else
    bad "$label (want rc=$want first=${first%%=*}=$want_val, got rc=$RC first=${FIRST:--})" \
      "$(tr '\n' ';' <"$W/stderr")"
  fi
done <<EOF
$rows
EOF
[ "$asserted" -gt 0 ] || {
  printf 'no fail-closed row was asserted\n' >&2
  exit 2
}

verdict
