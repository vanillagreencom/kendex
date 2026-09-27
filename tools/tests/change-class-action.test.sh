#!/usr/bin/env bash
# `.github/actions/change-class/classify` is the one reader of a change class
# every workflow gates on, and the one decision it makes is `lanes`, from the
# two verdicts it reads: the class is what the shipped `change-class` printed,
# docs_only is what the shipped `harness-only --mode docs` printed, and the
# path families are a grouping of the path list that same call wrote. Beside
# it, lane_verdicts narrows lanes per lane, by the globs the LANES_FROM
# checkout's declaration gives it. The rows drive it through its CLASSIFIER
# input against a stub scripts root, so each output can be traced to the stub
# line that produced it.
#
# Five surfaces:
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
#      and the classify step's `env:` block maps each declared input to
#      exactly one variable, its name upper-cased with `-` as `_`, each one
#      classify's Environment header lists. A copy carrying a misspelled
#      `lanes` value and one carrying a misspelled `inputs.lanes-from` are
#      the controls. A workflow reads the action, never the script, and
#      GitHub reads an undeclared input as empty, so a broken mapping there
#      publishes an empty `lanes` or `lane_verdicts` with every row above
#      green.
#   5. the lane verdicts: one lane reached, two lanes reached, a lane named
#      on two lines, an unclaimed path outside the docs set and one inside
#      it, a docs path a lane claims, lanes=false, no changed path, and an
#      absent and six malformed declarations, one with a valid lane ahead
#      of the bad line, one whose name starts with `-` and one that is a
#      directory, so it exists but cannot be read, each row
#      asserting the verdict lines and the declaration's state; the judged
#      tree carries a declaration of its own that no row may read, and
#      every run starts in a directory holding files the globs would expand
#      to. One mutant copy per rule must fail the row the rule decides.
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
outside_output=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --paths-output) paths_output="$2"; shift 2 ;;
    --outside-output) outside_output="$2"; shift 2 ;;
    *) shift ;;
  esac
done
: >"$paths_output"
for path in ${STUB_PATHS:-}; do printf '%s\n' "$path" >>"$paths_output"; done
[ -z "${STUB_PATHS_UNREADABLE:-}" ] || chmod 000 "$paths_output"
if [ -n "$outside_output" ] && [ -z "${STUB_NO_OUTSIDE:-}" ]; then
  : >"$outside_output"
  for path in ${STUB_OUTSIDE:-}; do printf '%s\n' "$path" >>"$outside_output"; done
fi
line="${STUB_DOCS_LINE:-docs_only=$STUB_DOCS}"
[ -z "${GITHUB_OUTPUT:-}" ] || printf '%s\n' "$line" >>"$GITHUB_OUTPUT"
printf '%s\n' "$line"
STUB
chmod +x "$STUBS/skills/harness-ci/scripts/change-class" \
  "$STUBS/skills/harness-ci/scripts/harness-only"

OUT="$TMP/github-output"
LOG="$TMP/stub-log"
mkdir -p "$TMP/subject"

# Every run starts in a directory the suite owns, holding a file each of
# `good`'s globs would expand to: a declaration or a glob list split with
# pathname expansion on would read `src/decoy.rs` where the declaration
# says `src/*`, and src/main.rs would reach no lane.
CWD="$TMP/cwd"
mkdir -p "$CWD/src" "$CWD/tmux" "$CWD/tests" "$CWD/docs"
: >"$CWD/src/decoy.rs"
: >"$CWD/tmux/decoy.conf"
: >"$CWD/tests/decoy.rs"
: >"$CWD/docs/decoy.md"

# The lane declarations, one checkout root each. `good` names `check` on two
# lines and carries a comment that would claim src/* for tmux if it were read
# as globs. The judged tree carries one of its own, which reaches every path:
# a row that reads it publishes `lane_evil`.
declare_lanes() { # NAME CONTENT
  mkdir -p "$TMP/decl/$1/.github"
  printf '%s' "$2" >"$TMP/decl/$1/.github/ci-lanes.conf"
}
declare_lanes good '# Lanes and the paths each reads.
check src/* Cargo.toml
tmux tmux/*   # not src/*
check tests/*

docs-build docs/*
'
declare_lanes bad-name '# a lane
Check src/*
'
declare_lanes no-globs 'check
'
declare_lanes no-lanes '# nothing declared
'
declare_lanes bad-after-good 'check src/*
Bad x
'
declare_lanes bad-leading 'check src/*
-check tests/*
'
mkdir -p "$TMP/decl/absent" "$TMP/decl/unreadable/.github/ci-lanes.conf" \
  "$TMP/subject/.github"
printf 'evil *\n' >"$TMP/subject/.github/ci-lanes.conf"

# Run a classify script with an explicit environment: the defaults below,
# then each NAME=VALUE argument, the later of two settings winning. Prints
# the exit status; stderr is kept in $TMP/err.
run() { # SCRIPT [NAME=VALUE]...
  local script="$1" status=0
  shift
  : >"$OUT"
  : >"$LOG"
  (cd "$CWD" && env -i PATH="$PATH" HOME="$HOME" TMPDIR="$TMP" \
    CLASSIFIER="$STUBS" EVENT=pull_request BASE=b0 HEAD=h1 REPO="$TMP/subject" \
    GITHUB_OUTPUT="$OUT" STUB_LOG="$LOG" STUB_CLASS=standard STUB_DOCS=false \
    "$@" bash "$script" >"$TMP/stdout" 2>"$TMP/err") || status=$?
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
render|render|false|.agents/skills/orch/SKILL.md .claude/skills/orch/SKILL.md|change_class=render docs_only=false changed_skills= changed_crates= changed_workflows= changed_paths=.agents/skills/orch/SKILL.md,.claude/skills/orch/SKILL.md lanes=false lanes_cause=render lane_verdicts=
trivial|trivial|true|docs/guide.md|change_class=trivial docs_only=true changed_skills= changed_crates= changed_workflows= changed_paths=docs/guide.md lanes=false lanes_cause=trivial lane_verdicts=
trivial-allowlisted|trivial|false|runtime/notes.txt|change_class=trivial docs_only=false changed_skills= changed_crates= changed_workflows= changed_paths=runtime/notes.txt lanes=false lanes_cause=trivial lane_verdicts=
micro|micro|false|skills/orch/SKILL.md .agents/skills/orch/SKILL.md|change_class=micro docs_only=false changed_skills=orch changed_crates= changed_workflows= changed_paths=skills/orch/SKILL.md,.agents/skills/orch/SKILL.md lanes=true lanes_cause=micro lane_verdicts=
small|small|false|crates/cli/src/main.rs crates/core/src/lib.rs|change_class=small docs_only=false changed_skills= changed_crates=cli core changed_workflows= changed_paths=crates/cli/src/main.rs,crates/core/src/lib.rs lanes=true lanes_cause=small lane_verdicts=
standard|standard|false|.github/workflows/ci.yml skills/github/SKILL.md crates/app/src/lib.rs|change_class=standard docs_only=false changed_skills=github changed_crates=app changed_workflows=ci.yml changed_paths=.github/workflows/ci.yml,skills/github/SKILL.md,crates/app/src/lib.rs lanes=true lanes_cause=standard lane_verdicts=
docs-only-standard|standard|true|docs/guide.md changelog.d/fixed/x.md README.md|change_class=standard docs_only=true changed_skills= changed_crates= changed_workflows= changed_paths=docs/guide.md,changelog.d/fixed/x.md,README.md lanes=false lanes_cause=docs-only lane_verdicts=
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
run "$CLASSIFY" STUB_CLASS=micro STUB_PATHS=skills/orch/SKILL.md \
  LANES_FROM="$TMP/decl/good" >/dev/null
check "a declared lane asks harness-only for the paths outside the docs set" \
  "harness-only --mode docs --event pull_request --head h1 --repo $TMP/subject --base b0 --paths-output PATHS --outside-output OUTSIDE" \
  "$(sed -n 's/--paths-output [^ ]* --outside-output [^ ]*$/--paths-output PATHS --outside-output OUTSIDE/; s/^harness-only /harness-only /p' "$LOG")"
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
lanes-from-unreadable root=$TMP/nowhere|LANES_FROM=$TMP/nowhere
lanes-from-judged-tree root=$TMP/subject|LANES_FROM=$TMP/subject
repo-unreadable repo=$TMP/nowhere|LANES_FROM=$TMP/decl/good REPO=$TMP/nowhere
outside-list-unreadable status=2|LANES_FROM=$TMP/decl/good STUB_PATHS=Makefile STUB_NO_OUTSIDE=1
ROWS
[ "$refusal_rows" -eq 16 ] ||
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
run "$CLASSIFY" LANES_FROM="$TMP/decl/good" STUB_PATHS=Makefile STUB_NO_OUTSIDE=1 >/dev/null
check "a refused lane read writes no lanes or lane_verdicts output" "" \
  "$(grep '^lane' "$OUT" || true)"

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

# The inputs, the other way: `NAME: ${{ inputs.<input> }}` per entry of
# ACTION_YML's `inputs:` block, NAME upper-cased with `-` as `_`, sorted.
input_mappings() { # ACTION_YML
  awk '
    /^inputs:/ { on = 1; next }
    on && /^[^ ]/ { exit }
    on && /^  [a-z][a-z-]*:$/ {
      input = $1; sub(/:$/, "", input)
      name = toupper(input); gsub(/-/, "_", name)
      print name ": ${{ inputs." input " }}"
    }
  ' "$1" | LC_ALL=C sort
}

# The classify step's `env:` lines of ACTION_YML, indentation stripped, sorted.
classify_env() { # ACTION_YML
  awk '
    /^    - id: classify$/ { step = 1; next }
    step && /^    - / { exit }
    step && /^      env:$/ { env = 1; next }
    env && /^        [A-Z_]+: / { sub(/^ +/, ""); print; next }
    env { env = 0 }
  ' "$1" | LC_ALL=C sort
}

mapped="$(input_mappings "$ACTION")"
case "$mapped" in
  *'LANES_FROM: ${{ inputs.lanes-from }}'*) ;;
  *) echo "the inputs reader found no lanes-from input in $ACTION, so it is broken: $mapped" >&2; exit 1 ;;
esac
check "action.yml maps each input to exactly one classify env line of its own name" \
  "$mapped" "$(classify_env "$ACTION")"

# The names classify's header lists under `Environment`, but GITHUB_OUTPUT,
# which the runner sets and no input carries.
header_env="$(awk '
  /^# Environment/ { on = 1; next }
  on && /^# Outputs/ { exit }
  on && /^#   [A-Z][A-Z_]* / { print $2 }
' "$CLASSIFY" | grep -vx GITHUB_OUTPUT | LC_ALL=C sort)" ||
  { echo "the Environment header reader failed on $CLASSIFY" >&2; exit 1; }
case "$header_env" in
  *LANES_FROM*) ;;
  *) echo "the Environment header reader found no LANES_FROM in $CLASSIFY, so it is broken: $header_env" >&2; exit 1 ;;
esac
check "classify's env names are the ones its Environment header lists, GITHUB_OUTPUT aside" \
  "$header_env" "$(classify_env "$ACTION" | sed 's/:.*//')"

needle='LANES_FROM: ${{ inputs.lanes-from }}'
[ "$(grep -cF -- "$needle" "$ACTION")" -eq 1 ] ||
  { echo "the lanes-from mapping is no longer one line in $ACTION" >&2; exit 1; }
NEEDLE="$needle" awk '
  { i = index($0, ENVIRON["NEEDLE"]) }
  i > 0 { $0 = substr($0, 1, i - 1) "LANES_FROM: ${{ inputs.lanes_from }}" substr($0, i + length(ENVIRON["NEEDLE"])) }
  { print }
' "$ACTION" >"$TMP/action.yml"
! cmp -s "$ACTION" "$TMP/action.yml" || { echo "the lanes-from mutant changed nothing" >&2; exit 1; }
if [ "$mapped" != "$(classify_env "$TMP/action.yml")" ]; then
  ok "must-fail: an action.yml whose lanes-from input is misspelled fails the input mapping row"
else
  bad "must-fail: an action.yml whose lanes-from input is misspelled fails the input mapping row"
fi

# --- 5. The lane verdicts ---------------------------------------------------

# ROW|DECLARATION|CLASS|DOCS|PATHS|PATHS OUTSIDE THE DOCS SET|EXPECTED
# EXPECTED is the lane_verdicts value, its lines joined with commas, and the
# declaration's state and cause off the step's `lane-declaration:` line. The
# bad-after-good row is a docs-only diff, where every lane read before the
# malformed line would publish false if it were kept.
lane_rows() {
  cat <<'ROWS'
one-lane|good|standard|false|src/main.rs|src/main.rs|lane_verdicts=lane_check=true,lane_tmux=false,lane_docs-build=false state=read
two-lanes|good|small|false|src/main.rs tmux/tmux.conf|src/main.rs tmux/tmux.conf|lane_verdicts=lane_check=true,lane_tmux=true,lane_docs-build=false state=read
second-line|good|micro|false|tests/cli.rs|tests/cli.rs|lane_verdicts=lane_check=true,lane_tmux=false,lane_docs-build=false state=read
unclaimed|good|standard|false|tmux/tmux.conf Makefile|tmux/tmux.conf Makefile|lane_verdicts=lane_check=true,lane_tmux=true,lane_docs-build=true state=read
unclaimed-docs|good|standard|false|tmux/tmux.conf README.md|tmux/tmux.conf|lane_verdicts=lane_check=false,lane_tmux=true,lane_docs-build=false state=read
claimed-docs|good|standard|false|src/lib.rs docs/guide.md|src/lib.rs|lane_verdicts=lane_check=true,lane_tmux=false,lane_docs-build=true state=read
docs-only|good|standard|true|docs/guide.md||lane_verdicts=lane_check=false,lane_tmux=false,lane_docs-build=false state=read
render|good|render|false|.agents/skills/orch/SKILL.md|.agents/skills/orch/SKILL.md|lane_verdicts=lane_check=false,lane_tmux=false,lane_docs-build=false state=read
no-paths|good|standard|false|||lane_verdicts=lane_check=true,lane_tmux=true,lane_docs-build=true state=read
absent|absent|standard|false|src/main.rs|src/main.rs|lane_verdicts= state=absent
bad-name|bad-name|standard|false|src/main.rs|src/main.rs|lane_verdicts= state=malformed cause=bad-name line=2 name=Check
no-globs|no-globs|standard|false|src/main.rs|src/main.rs|lane_verdicts= state=malformed cause=no-globs line=1 lane=check
no-lanes|no-lanes|standard|false|src/main.rs|src/main.rs|lane_verdicts= state=malformed cause=no-lanes
bad-after-good|bad-after-good|standard|true|docs/guide.md||lane_verdicts= state=malformed cause=bad-name line=2 name=Bad
bad-leading|bad-leading|standard|false|src/main.rs|src/main.rs|lane_verdicts= state=malformed cause=bad-name line=2 name=-check
unreadable|unreadable|standard|false|src/main.rs|src/main.rs|lane_verdicts= state=malformed cause=unreadable
ROWS
}

# What one lane row's run of SCRIPT answered, or `crashed` where it did not
# run to completion.
lane_answer() { # SCRIPT ROW
  local line name decl class docs paths outside expected
  line="$(lane_rows | grep -m1 "^$2|")" ||
    { echo "no lane row named $2" >&2; exit 1; }
  IFS='|' read -r name decl class docs paths outside expected <<<"$line"
  if [ "$(run "$1" LANES_FROM="$TMP/decl/$decl" STUB_CLASS="$class" \
    STUB_DOCS="$docs" STUB_PATHS="$paths" STUB_OUTSIDE="$outside")" != 0 ]; then
    echo crashed
    return 0
  fi
  printf '%s %s\n' "$(outputs | tr ' ' '\n' | grep '^lane_verdicts=')" \
    "$(sed -n 's/^lane-declaration: state=\([^ ]*\) path=[^ ]*/state=\1/p' "$TMP/err")"
}

lane_row_holds() { # SCRIPT ROW — prints yes, no or crashed
  local answer expected
  answer="$(lane_answer "$1" "$2")"
  expected="$(lane_rows | grep -m1 "^$2|" | cut -d'|' -f7)"
  if [ "$answer" = crashed ]; then echo crashed
  elif [ "$answer" = "$expected" ]; then echo yes
  else echo no
  fi
}

rows=0
while IFS='|' read -r name decl class docs paths outside expected; do
  rows=$((rows + 1))
  check "lane row $name" "$expected" "$(lane_answer "$CLASSIFY" "$name")"
done < <(lane_rows)
[ "$rows" -eq 16 ] || { echo "the lane table read $rows rows" >&2; exit 1; }

# GitHub reads a `::warning` line off the step's stdout; a declaration the
# step could not use says so there, and one it read says nothing.
for decl in absent bad-name unreadable good; do
  run "$CLASSIFY" LANES_FROM="$TMP/decl/$decl" STUB_PATHS=src/main.rs \
    STUB_OUTSIDE=src/main.rs >/dev/null
  case "$decl" in
    absent) want='::warning title=lane declaration absent::' ;;
    bad-name | unreadable) want='::warning title=lane declaration malformed::' ;;
    good) want='' ;;
  esac
  check "the $decl declaration's warning" "$want" \
    "$(sed -n 's/^\(::warning title=[^:]*::\).*/\1/p' "$TMP/stdout")"
done

# One copy per lane rule, the rule planted wrong and every other line kept.
# Each must run to completion and fail the row its rule decides.
# NEEDLE@REPLACEMENT@ROW, split on `@` because a rule spells the shell's `&&`.
mutants=0
while IFS='@' read -r needle replacement row; do
  mutants=$((mutants + 1))
  [ "$(grep -cF -- "$needle" "$CLASSIFY")" -eq 1 ] ||
    { echo "the lane rule '$needle' is no longer one line in $CLASSIFY" >&2; exit 1; }
  NEEDLE="$needle" REPLACEMENT="$replacement" awk '
    { i = index($0, ENVIRON["NEEDLE"]) }
    i > 0 { $0 = substr($0, 1, i - 1) ENVIRON["REPLACEMENT"] substr($0, i + length(ENVIRON["NEEDLE"])) }
    { print }
  ' "$CLASSIFY" >"$mutant"
  ! cmp -s "$CLASSIFY" "$mutant" || { echo "the mutant for '$needle' changed nothing" >&2; exit 1; }
  check "must-fail: '$needle' planted as '$replacement' fails the $row row" \
    no "$(lane_row_holds "$mutant" "$row")"
done <<'ROWS'
declaration="$lanes_root/.github/ci-lanes.conf"@declaration="$judged_root/.github/ci-lanes.conf"@one-lane
    line="${line%%#*}"@    line="$line"@one-lane
      [!abcdefghijklmnopqrstuvwxyz0123456789]* | *[!abcdefghijklmnopqrstuvwxyz0123456789_-]*)@      never-a-lane-name)@bad-name
{ declaration_note="cause=no-globs line=$number lane=$name"; return 1; }@:@no-globs
[ "$lane_count" -gt 0 ] || { declaration_note="cause=no-lanes"; return 1; }@:@no-lanes
          lane_hits[$index]="cause=claimed path=$path glob=$LANE_GLOB_HIT"@          lane_hits[$index]=""@two-lanes
    if [ "$claimed" = false ] && [ -z "$every" ] && outside_docs "$path"; then@    if false; then@unclaimed
 && outside_docs "$path"; then@ && true; then@unclaimed-docs
    every="cause=no-changed-paths"@    every=""@no-paths
    lane_state="malformed" lane_count=0@    lane_state="malformed"@bad-after-good
      [!abcdefghijklmnopqrstuvwxyz0123456789]* | *[!@      *[!@bad-leading
    set -f@    :@one-lane
  set -f; for glob in@  for glob in@one-lane
    lane=false lane_cause="cause=lanes-false lanes_cause=$lanes_cause"@    lane=true lane_cause="cause=lanes-false lanes_cause=$lanes_cause"@docs-only
    lane=false lane_cause="cause=unreached"@    lane=true lane_cause="cause=unreached"@one-lane
{ declaration_note="cause=unreadable"; return 1; }@:@unreadable
ROWS
[ "$mutants" -eq 16 ] || { echo "the lane mutant table read $mutants rows" >&2; exit 1; }

# The refusal of a lanes-from naming the judged tree, planted away.
needle='[ "$lanes_root" != "$judged_root" ] ||'
[ "$(grep -cF -- "$needle" "$CLASSIFY")" -eq 1 ] ||
  { echo "the judged-tree refusal is no longer one line in $CLASSIFY" >&2; exit 1; }
NEEDLE="$needle" awk '
  { i = index($0, ENVIRON["NEEDLE"]) }
  i > 0 { $0 = substr($0, 1, i - 1) "true ||" substr($0, i + length(ENVIRON["NEEDLE"])) }
  { print }
' "$CLASSIFY" >"$mutant"
! cmp -s "$CLASSIFY" "$mutant" || { echo "the judged-tree mutant changed nothing" >&2; exit 1; }
status="$(run "$mutant" LANES_FROM="$TMP/subject" STUB_PATHS=src/main.rs STUB_OUTSIDE=src/main.rs)"
check "must-fail: a classify reading lanes from the judged tree is not refused" \
  "0 lane_verdicts=lane_evil=true" "$status $(outputs | tr ' ' '\n' | grep '^lane_verdicts=')"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
