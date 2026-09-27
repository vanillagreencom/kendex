#!/usr/bin/env bash
# `.github/actions/change-class/classify` is the one reader of a change class
# every workflow gates on, and the one decision it makes is `lanes`, from the
# two verdicts it reads: the class is what the shipped `change-class` printed,
# docs_only is what the shipped `harness-only --mode docs` printed, and the
# path families are a grouping of the path list that same call wrote. The
# rows drive it through its CLASSIFIER input against a stub scripts root, so
# each output can be traced to the stub line that produced it.
#
# Four surfaces:
#   1. the outputs: one diff per class, a docs-only diff at `standard` size
#      and a `trivial` one off the docs set, asserting every output line the
#      step writes, and the arguments each wrapped script was called with.
#   2. the must-fail inverses: a copy of classify that prints a class of its
#      own instead of reading the wrapped script's fails the render row, and
#      one copy per lanes rule with that rule planted wrong fails the row the
#      rule decides. Each copy must also run to completion, so a copy that
#      dies for another reason is never counted as a kill.
#   3. the refusals: one row per cause the header documents, each asserting
#      exit 2 and the `change-class-action: wiring-error: cause=` key, the
#      wrapped classifier's own wiring error and the delimiter guard included,
#      and a refused step writing no lanes output.
#   4. action.yml: its `outputs:` block declares exactly the names classify
#      writes, each forwarding the classify step's output of the same name,
#      with a copy carrying a misspelled `lanes` value as its control. A
#      workflow reads the action, never the script, so a dropped mapping
#      there publishes an empty `lanes` with every row above green.
set -euo pipefail

unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

ROOT="$(git rev-parse --show-toplevel)"
CLASSIFY="$ROOT/.github/actions/change-class/classify"
ACTION="$ROOT/.github/actions/change-class/action.yml"

mkdir -p "$ROOT/tmp"
TMP="$(mktemp -d "$ROOT/tmp/change-class-action.XXXXXX")"
trap 'chmod -R u+rwX "${TMP:?}" 2>/dev/null; rm -rf -- "${TMP:?}"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
check() { # DESC EXPECTED ACTUAL
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi
}

# The stub scripts root. Each stub writes what the shipped script writes, in
# the places it writes it: the verdict line on stdout and appended to
# GITHUB_OUTPUT, and for harness-only the path list to --paths-output. What
# each answers is set per row through STUB_* variables.
STUBS="$TMP/stubs"
mkdir -p "$STUBS/skills/harness-ci/scripts"
cat >"$STUBS/skills/harness-ci/scripts/change-class" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'change-class %s\n' "$*" >>"$STUB_LOG"
[ "${STUB_CLASS_EXIT:-0}" -eq 0 ] || exit "$STUB_CLASS_EXIT"
[ -z "${GITHUB_OUTPUT:-}" ] || printf 'change_class=%s\n' "$STUB_CLASS" >>"$GITHUB_OUTPUT"
printf 'change_class=%s\n' "$STUB_CLASS"
STUB
cat >"$STUBS/skills/harness-ci/scripts/harness-only" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'harness-only %s\n' "$*" >>"$STUB_LOG"
[ "${STUB_PATHS_EXIT:-0}" -eq 0 ] || exit "$STUB_PATHS_EXIT"
paths_output=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --paths-output) paths_output="$2"; shift 2 ;;
    *) shift ;;
  esac
done
: >"$paths_output"
for path in ${STUB_PATHS:-}; do printf '%s\n' "$path" >>"$paths_output"; done
[ -z "${STUB_PATHS_UNREADABLE:-}" ] || chmod 000 "$paths_output"
line="${STUB_DOCS_LINE:-docs_only=$STUB_DOCS}"
[ -z "${GITHUB_OUTPUT:-}" ] || printf '%s\n' "$line" >>"$GITHUB_OUTPUT"
printf '%s\n' "$line"
STUB
chmod +x "$STUBS/skills/harness-ci/scripts/change-class" \
  "$STUBS/skills/harness-ci/scripts/harness-only"

OUT="$TMP/github-output"
LOG="$TMP/stub-log"

# Run a classify script with an explicit environment: the defaults below,
# then each NAME=VALUE argument, the later of two settings winning. Prints
# the exit status; stderr is kept in $TMP/err.
run() { # SCRIPT [NAME=VALUE]...
  local script="$1" status=0
  shift
  : >"$OUT"
  : >"$LOG"
  env -i PATH="$PATH" HOME="$HOME" TMPDIR="$TMP" \
    CLASSIFIER="$STUBS" EVENT=pull_request BASE=b0 HEAD=h1 REPO="$TMP/subject" \
    GITHUB_OUTPUT="$OUT" STUB_LOG="$LOG" STUB_CLASS=standard STUB_DOCS=false \
    "$@" bash "$script" >/dev/null 2>"$TMP/err" || status=$?
  printf '%s' "$status"
}

# The step's outputs as `name=value` lines in the order written, a
# heredoc-delimited value joined with commas.
outputs() {
  awk '
    collecting && $0 == delim { print name "=" value; collecting = 0; next }
    collecting { value = (value == "" ? $0 : value "," $0); next }
    /^[a-z_]+<</ {
      name = $0; sub(/<<.*/, "", name)
      delim = $0; sub(/^[^<]*<</, "", delim)
      value = ""; collecting = 1; next
    }
    { print }
  ' "$OUT" | tr '\n' ' ' | sed 's/ $//'
}

refusal() { # the first refusal line's cause, or nothing
  sed -n 's/^change-class-action: wiring-error: cause=//p' "$TMP/err" | head -1
}

# --- 1. The outputs, one diff per class --------------------------------------

# ROW|CLASS|DOCS|PATHS (blank-separated)|EXPECTED OUTPUTS
# The trivial-allowlisted row is a `trivial` class on a path outside the docs
# set, which change-class answers under a HARNESS_CI_TRIVIAL_PATHS allowlist.
class_rows() {
  cat <<'ROWS'
render|render|false|.agents/skills/orch/SKILL.md .claude/skills/orch/SKILL.md|change_class=render docs_only=false changed_skills= changed_crates= changed_workflows= changed_paths=.agents/skills/orch/SKILL.md,.claude/skills/orch/SKILL.md lanes=false lanes_cause=render
trivial|trivial|true|docs/guide.md|change_class=trivial docs_only=true changed_skills= changed_crates= changed_workflows= changed_paths=docs/guide.md lanes=false lanes_cause=trivial
trivial-allowlisted|trivial|false|runtime/notes.txt|change_class=trivial docs_only=false changed_skills= changed_crates= changed_workflows= changed_paths=runtime/notes.txt lanes=false lanes_cause=trivial
micro|micro|false|skills/orch/SKILL.md .agents/skills/orch/SKILL.md|change_class=micro docs_only=false changed_skills=orch changed_crates= changed_workflows= changed_paths=skills/orch/SKILL.md,.agents/skills/orch/SKILL.md lanes=true lanes_cause=micro
small|small|false|crates/cli/src/main.rs crates/core/src/lib.rs|change_class=small docs_only=false changed_skills= changed_crates=cli core changed_workflows= changed_paths=crates/cli/src/main.rs,crates/core/src/lib.rs lanes=true lanes_cause=small
standard|standard|false|.github/workflows/ci.yml skills/github/SKILL.md crates/app/src/lib.rs|change_class=standard docs_only=false changed_skills=github changed_crates=app changed_workflows=ci.yml changed_paths=.github/workflows/ci.yml,skills/github/SKILL.md,crates/app/src/lib.rs lanes=true lanes_cause=standard
docs-only-standard|standard|true|docs/guide.md changelog.d/fixed/x.md README.md|change_class=standard docs_only=true changed_skills= changed_crates= changed_workflows= changed_paths=docs/guide.md,changelog.d/fixed/x.md,README.md lanes=false lanes_cause=docs-only
ROWS
}

# Whether ROW's outputs from SCRIPT are the ones the table expects:
# `crashed` where SCRIPT did not run to completion, so a mutant that dies for
# an unrelated reason is told apart from one whose outputs the row refuses.
row_holds() { # SCRIPT ROW — prints yes, no or crashed
  local line name class docs paths expected
  line="$(class_rows | grep -m1 "^$2|")" ||
    { echo "no class row named $2" >&2; exit 1; }
  IFS='|' read -r name class docs paths expected <<<"$line"
  if [ "$(run "$1" STUB_CLASS="$class" STUB_DOCS="$docs" STUB_PATHS="$paths")" != 0 ]; then
    echo crashed
  elif [ "$(outputs)" = "$expected" ]; then
    echo yes
  else
    echo no
  fi
}

rows=0
while IFS='|' read -r name class docs paths expected; do
  rows=$((rows + 1))
  status="$(run "$CLASSIFY" STUB_CLASS="$class" STUB_DOCS="$docs" STUB_PATHS="$paths")"
  check "$name: classify exits 0" "0" "$status"
  check "$name: every output line" "$expected" "$(outputs)"
done < <(class_rows)
[ "$rows" -eq 7 ] || { echo "the class table read $rows rows" >&2; exit 1; }
check "the step says why the lanes answered as they did" \
  "lanes: lanes=false cause=docs-only" "$(grep '^lanes: ' "$TMP/err")"

# The wrapped scripts see the step's inputs as flags, and the path list comes
# from the docs-mode call alone: a harness-mode read here would be a second
# reader of the same diff.
run "$CLASSIFY" STUB_CLASS=micro STUB_PATHS=skills/orch/SKILL.md >/dev/null
check "each wrapped script is called once, with the step's inputs" \
  "change-class --event pull_request --head h1 --repo $TMP/subject --base b0
harness-only --mode docs --event pull_request --head h1 --repo $TMP/subject --base b0 --paths-output PATHS" \
  "$(sed 's/--paths-output [^ ]*$/--paths-output PATHS/' "$LOG")"
run "$CLASSIFY" STUB_CLASS=standard BASE= >/dev/null
check "an empty base is not passed as a flag" \
  "change-class --event pull_request --head h1 --repo $TMP/subject" \
  "$(sed -n 's/^change-class /change-class /p' "$LOG")"

# --- 2. Must-fail: a classify that decides the class itself ------------------
# The copy keeps every line but the one that reads the wrapped script, and
# prints `standard` there instead. The render row, whose stub says render,
# must see the difference.
mutant="$TMP/mutant/classify"
mkdir -p "$TMP/mutant"
needle='"$("$SCRIPTS/change-class" "${args[@]}")"'
[ "$(grep -cF -- "$needle" "$CLASSIFY")" -eq 1 ] ||
  { echo "the change-class call is no longer one line in $CLASSIFY" >&2; exit 1; }
NEEDLE="$needle" awk '
  { i = index($0, ENVIRON["NEEDLE"]) }
  i > 0 {
    $0 = substr($0, 1, i - 1) "\"$(printf '"'"'change_class=standard\\n'"'"' | tee -a \"$GITHUB_OUTPUT\")\"" substr($0, i + length(ENVIRON["NEEDLE"]))
  }
  { print }
' "$CLASSIFY" >"$mutant"
! cmp -s "$CLASSIFY" "$mutant" || { echo "the mutant changed nothing" >&2; exit 1; }
check "must-fail: a classify that decides its own class fails the render row" \
  no "$(row_holds "$mutant" render)"

# One copy per lanes rule, the rule planted wrong and every other line kept.
# Each copy must run to completion and fail the row its rule decides.
# NEEDLE@REPLACEMENT@ROW THE RULE DECIDES, split on `@` because a rule spells
# the shell's `||`.
mutants=0
while IFS='@' read -r needle replacement row; do
  mutants=$((mutants + 1))
  [ "$(grep -cF -- "$needle" "$CLASSIFY")" -eq 1 ] ||
    { echo "the lanes rule '$needle' is no longer one line in $CLASSIFY" >&2; exit 1; }
  NEEDLE="$needle" REPLACEMENT="$replacement" awk '
    { i = index($0, ENVIRON["NEEDLE"]) }
    i > 0 { $0 = substr($0, 1, i - 1) ENVIRON["REPLACEMENT"] substr($0, i + length(ENVIRON["NEEDLE"])) }
    { print }
  ' "$CLASSIFY" >"$mutant"
  ! cmp -s "$CLASSIFY" "$mutant" || { echo "the mutant for '$needle' changed nothing" >&2; exit 1; }
  check "must-fail: '$needle' planted as '$replacement' fails the $row row" \
    no "$(row_holds "$mutant" "$row")"
done <<'ROWS'
[ "$class" = render ] || @@render
 || [ "$class" = trivial ]; then@; then@trivial-allowlisted
elif [ "$docs" = docs_only=true ]; then@elif false; then@docs-only-standard
  lanes=true lanes_cause="$class"@  lanes=false lanes_cause="$class"@standard
ROWS
[ "$mutants" -eq 4 ] || { echo "the lanes mutant table read $mutants rows" >&2; exit 1; }

# --- 3. The refusals --------------------------------------------------------

# CAUSE|ASSIGNMENTS (blank-separated NAME=VALUE)
# A mode-000 file is still readable by root, so the one row that forces a
# read failure that way cannot fail under root and is skipped there, saying so.
refusal_rows=0
while IFS='|' read -r cause assignments; do
  refusal_rows=$((refusal_rows + 1))
  case "$assignments" in
    *STUB_PATHS_UNREADABLE=*)
      if [ "$(id -u)" -eq 0 ]; then
        printf '  skip  refusal %s: root reads a mode-000 file\n' "$cause"
        continue
      fi ;;
  esac
  # shellcheck disable=SC2086 # the assignments are blank-separated words
  status="$(run "$CLASSIFY" $assignments)"
  check "refusal $cause: exit" "2" "$status"
  check "refusal $cause: key" "$cause" "$(refusal)"
done <<ROWS
classifier-unreadable root=$TMP/nowhere|CLASSIFIER=$TMP/nowhere
missing-event|EVENT=
missing-head|HEAD=
missing-repo|REPO=
missing-output-file|GITHUB_OUTPUT=
classifier-failed status=2|STUB_CLASS_EXIT=2
verdict-unreadable class-line=change_class=enormous|STUB_CLASS=enormous
path-reader-failed status=2|STUB_PATHS_EXIT=2 STUB_PATHS=a
docs-verdict-unreadable docs-line=harness_only=true|STUB_DOCS_LINE=harness_only=true STUB_PATHS=a
class-without-paths class=micro|STUB_CLASS=micro STUB_PATHS=
family-read-failed prefix=skills|STUB_PATHS=skills/orch/SKILL.md STUB_PATHS_UNREADABLE=1
delimiter-collides path=__change_class_changed_paths_end__|STUB_PATHS=__change_class_changed_paths_end__
ROWS
[ "$refusal_rows" -eq 12 ] ||
  { echo "the refusal table read $refusal_rows rows" >&2; exit 1; }

# mktemp's failure is planted as a mktemp first on PATH that exits 1. A
# TMPDIR naming no directory fails GNU mktemp but not the macOS runner's BSD
# mktemp, which still creates the directory, and a PATH is not a word the
# table's NAME=VALUE list can carry intact.
mkdir -p "$TMP/no-mktemp"
printf '#!/bin/sh\nexit 1\n' >"$TMP/no-mktemp/mktemp"
chmod +x "$TMP/no-mktemp/mktemp"
status="$(run "$CLASSIFY" PATH="$TMP/no-mktemp:$PATH")"
check "refusal mktemp-failed: exit" "2" "$status"
check "refusal mktemp-failed: key" "mktemp-failed" "$(refusal)"

# A refusal carries no verdict to a caller: nothing after the refused step
# reaches the output file.
run "$CLASSIFY" STUB_PATHS=__change_class_changed_paths_end__ >/dev/null
check "a refused delimiter writes no changed_paths output" "" \
  "$(grep '^changed_paths' "$OUT" || true)"
check "a refused step writes no lanes output" "" \
  "$(grep '^lanes' "$OUT" || true)"

# --- 4. action.yml forwards every output classify writes -------------------

# The names one classify run writes, heredoc-delimited values skipped. The
# standard row reaches every writer, lanes last.
run "$CLASSIFY" STUB_CLASS=standard STUB_PATHS=skills/orch/SKILL.md >/dev/null
written="$(awk '
  collecting { if ($0 == delim) collecting = 0; next }
  /^[a-z_]+<</ { delim = $0; sub(/^[^<]*<</, "", delim); sub(/<<.*/, ""); print; collecting = 1; next }
  /^[a-z_]+=/ { sub(/=.*/, ""); print }
' "$OUT" | LC_ALL=C sort)"
case "$written" in
  *change_class*lanes*) ;;
  *) echo "classify wrote no change_class or lanes output, so the name reader is broken: $written" >&2; exit 1 ;;
esac
forwarded="$(printf '%s\n' "$written" | awk '{ printf "%s ${{ steps.classify.outputs.%s }}\n", $1, $1 }')"

# NAME VALUE per entry of ACTION_YML's `outputs:` block, sorted.
declared() { # ACTION_YML
  awk '
    /^outputs:/ { on = 1; next }
    on && /^[^ ]/ { exit }
    on && /^  [a-z_]+:$/ { name = $1; sub(/:$/, "", name); next }
    on && /^    value: / { value = $0; sub(/^    value: /, "", value); print name " " value }
  ' "$1" | LC_ALL=C sort
}
check "action.yml declares exactly the outputs classify writes, each forwarded by name" \
  "$forwarded" "$(declared "$ACTION")"

needle='value: ${{ steps.classify.outputs.lanes }}'
[ "$(grep -cF -- "$needle" "$ACTION")" -eq 1 ] ||
  { echo "the lanes mapping is no longer one line in $ACTION" >&2; exit 1; }
NEEDLE="$needle" awk '
  { i = index($0, ENVIRON["NEEDLE"]) }
  i > 0 { $0 = substr($0, 1, i - 1) "value: ${{ steps.classify.outputs.lane }}" substr($0, i + length(ENVIRON["NEEDLE"])) }
  { print }
' "$ACTION" >"$TMP/action.yml"
! cmp -s "$ACTION" "$TMP/action.yml" || { echo "the action.yml mutant changed nothing" >&2; exit 1; }
if [ "$forwarded" != "$(declared "$TMP/action.yml")" ]; then
  ok "must-fail: an action.yml whose lanes value is misspelled fails the forwarding row"
else
  bad "must-fail: an action.yml whose lanes value is misspelled fails the forwarding row"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
