#!/usr/bin/env bash
# tools/harness-smoke's refusals, which are everything it decides before it
# installs anything: the arguments it takes, the commands it needs, and the
# repository it places its scratch under. The rows past that point drive eight
# harnesses and a model turn each and are not run here.
#
# Every refusal is read as `rc=<status> first=<key>=<value>` — LINE 1 of the
# run's output with its `harness-smoke: ` prefix off, `-` when line 1 is
# something else — so a row pins the clause its own branch emits rather than
# the exit status ten branches share, and anything a dependency wrote ahead
# of the keyed line reds the row.
#
# A row is `label|argv|cwd|path|rc|first`:
#   argv   the arguments as written, `-` for none
#   cwd    `repo` this checkout, `scratch` a directory outside every repository
#   path   `real` this PATH, `empty` a PATH holding nothing, `stubs` a PATH
#          holding kendex, jq and node that answer and a git that refuses
#   rc     the exit status
#   first  `<key>=<value>`, the value written as `SCRATCH` for the scratch
#          directory or as itself
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$TEST_DIR/../.." && pwd)"
SMOKE="$REPO/tools/harness-smoke"
TMP="$(mktemp -d)" || { echo "harness-smoke.test: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP:?}"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

SCRATCH="$TMP/scratch"
mkdir -p "$SCRATCH" "$TMP/empty-bin" "$TMP/stub-bin"
# The scratch rows stand on this: inside a repository the toplevel resolves and
# the no-repository row would prove nothing.
if inrepo="$(cd "$SCRATCH" && git rev-parse --show-toplevel 2>/dev/null)"; then
  bad "precondition: the scratch directory sits in a repository ($inrepo)"
  printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
  exit 1
fi
ok "precondition: the scratch directory is outside every repository"

# /bin/sh, not `env bash`: the rows below hand the script a PATH of their own,
# and a stub whose interpreter is looked up on that PATH could not start.
for stub in kendex jq node; do
  printf '#!/bin/sh\nexit 0\n' >"$TMP/stub-bin/$stub"
  chmod +x "$TMP/stub-bin/$stub"
done
# A git that refuses is what leaves the toplevel unresolved with every other
# command answering, so the row reaches the repository branch and not the
# missing-command one above it.
printf '#!/bin/sh\nexit 128\n' >"$TMP/stub-bin/git"
chmod +x "$TMP/stub-bin/git"

value_of() { # TOKEN — a row's value token as the string it names
  case "$1" in
    SCRATCH) printf '%s' "$SCRATCH" ;;
    *) printf '%s' "$1" ;;
  esac
}

run() { # ARGV CWD PATH-KIND — `rc=<status> first=<key>=<value>`
  local rc=0 dir="" path="" said=""
  case "$2" in
    repo) dir="$REPO" ;;
    *) dir="$SCRATCH" ;;
  esac
  case "$3" in
    empty) path="$TMP/empty-bin" ;;
    stubs) path="$TMP/stub-bin" ;;
    *) path="$PATH" ;;
  esac
  local -a argv=()
  if [ "$1" != - ]; then
    local a
    for a in $1; do argv+=("$a"); done
  fi
  # Run through this shell by its own path rather than through the shebang:
  # a row's PATH need not carry an interpreter, and what it does carry is the
  # row's assertion.
  (cd "$dir" && PATH="$path" "$BASH" "$SMOKE" ${argv[@]+"${argv[@]}"} >"$TMP/out" 2>&1) || rc=$?
  # LINE 1, not the first line matching the prefix: the keyed line has to be
  # the first thing the run says, and a dependency reaching the stream ahead
  # of it is the defect this reads for.
  said="$(sed -n '1s/^harness-smoke: //p' "$TMP/out")"
  printf 'rc=%s first=%s' "$rc" "${said:--}"
}

run_table() { # TITLE ROWS
  local title="$1" rows="$2" label argv cwd path want first got row field
  local before=$((PASS + FAIL))
  printf '=== %s ===\n' "$title"
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    IFS='|' read -r label argv cwd path want first <<<"$row"
    for field in "$label" "$argv" "$cwd" "$path" "$want" "$first"; do
      [ -n "$field" ] || {
        printf 'a row with an empty field asserts nothing: %s\n' "$row" >&2
        exit 1
      }
    done
    got="$(run "$argv" "$cwd" "$path")"
    if [ "$got" = "rc=$want first=${first%%=*}=$(value_of "${first#*=}")" ]; then
      ok "$label"
    else
      bad "$label" "want rc=$want first=${first%%=*}=$(value_of "${first#*=}"), got $got"
    fi
  done <<EOF
$rows
EOF
  [ "$((PASS + FAIL))" -gt "$before" ] || {
    printf 'no row was asserted\n' >&2
    exit 2
  }
}

run_table "what harness-smoke refuses before it installs anything" "\
an argument it does not take is refused|--bogus|repo|real|2|argument=--bogus
--only with no value is refused|--only|repo|real|2|argument=--only
--dir with no value is refused|--dir|repo|real|2|argument=--dir
a harness it does not install into is refused|--only nope|repo|real|2|unknown-harness=nope
a harness it does install into is not refused for its name|--only claude --bogus|repo|real|2|argument=--bogus
a command it needs and cannot find is refused by name|--keep|repo|empty|2|missing-tool=kendex
no repository around the run is refused, naming where it stood|-|scratch|stubs|2|not-in-repo=SCRATCH"

# The two tallies are counts, and a count only means something once rows have
# been decided. A stubbed harness decides them without a model turn: one that
# exits 0 saying nothing fails every row it is asked, and one that cannot run
# leaves every row unanswerable. The count each verdict carries is compared
# with the rows the run actually printed, so a tally that went back to a
# boolean reports 1 against ten rows and reds.
echo "=== the failed and unanswerable counts are the number of rows ==="
ROWS_REPO="$TMP/rows-repo"
ROWS_BIN="$TMP/rows-bin"
ROWS_CFG="$TMP/rows-cfg"
mkdir -p "$ROWS_REPO" "$ROWS_BIN" "$ROWS_CFG"
printf '#!/bin/sh\nexit 0\n' >"$ROWS_BIN/kendex"
chmod +x "$ROWS_BIN/kendex"
git -C "$ROWS_REPO" init -q
git -C "$ROWS_REPO" config user.email harness-smoke@kendex.invalid
git -C "$ROWS_REPO" config user.name harness-smoke

# The aligned row lines only: the markdown table under them repeats every row,
# and counting both would double every tally.
row_count() { # FILE RESULT — rows the run reported with that result
  awk -v want="$2" '/^\|/ { next } $3 == want { n++ } END { print n + 0 }' "$1"
}

rows_case() { # LABEL HARNESS-EXIT RESULT KEY WANT-STATUS
  local label="$1" h out rc=0
  for h in claude codex; do
    printf '#!/bin/sh\nexit %s\n' "$2" >"$ROWS_BIN/$h"
    chmod +x "$ROWS_BIN/$h"
  done
  rm -rf -- "${TMP:?}/rows-dir"
  mkdir -p "$TMP/rows-dir"
  out="$TMP/rows-out"
  (cd "$ROWS_REPO" && PATH="$ROWS_BIN:$PATH" CLAUDE_CONFIG_DIR="$ROWS_CFG" \
    "$BASH" "$SMOKE" --only claude,codex --dir "$TMP/rows-dir" >"$out" 2>&1) || rc=$?
  local seen keyed
  seen="$(row_count "$out" "$3")"
  keyed="$(sed -n "s/^harness-smoke: $4=//p" "$out")"
  if [ "$rc" = "$5" ] && [ "$seen" -ge 2 ] && [ "$keyed" = "$seen" ]; then
    ok "$label ($4=$keyed over $seen row(s), exit $rc)"
  else
    bad "$label" "rc=$rc want=$5 rows=$seen keyed=${keyed:--}"
  fi
}

rows_case "a harness that answers nothing fails every row it is asked" 0 fail failed 1
rows_case "a harness that cannot run leaves every row unanswerable" 3 unanswerable unanswerable 3

# The keyed line being first is half the claim; the cause the dependency gave
# has to survive under it.
echo "=== a dependency's own words are replayed under the keyed line ==="
cause_out="$( (cd "$SCRATCH" && PATH="$TMP/stub-bin" "$BASH" "$SMOKE" 2>&1) )" || true
if [ "$(printf '%s\n' "$cause_out" | sed -n 1p)" = "harness-smoke: not-in-repo=$SCRATCH" ]; then
  ok "the keyed line is line 1 when git has failed"
else
  bad "the keyed line is line 1 when git has failed" "$(printf '%s' "$cause_out" | tr '\n' ';')"
fi

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
