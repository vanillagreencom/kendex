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
# Every run copies the script under test beside a stub `proof`, whose
# answer the STUB_* variables set, since classify calls the proof beside
# itself; one row runs the tracked pair to see the real proof answer.
#
# Six surfaces, the queue mark under the fifth:
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
#   4. action.yml: each name classify writes is either declared under
#      `outputs:`, forwarding the classify step's output of the same name,
#      or read by the action's own later steps alone, and the classify
#      step's `env:` block maps each declared input to
#      exactly one variable, its name upper-cased with `-` as `_`, each one
#      classify's Environment header lists. Copies carrying a misspelled
#      `lanes` value, an upload step reading no record_dir and a misspelled
#      `inputs.lanes-from` are the controls. A workflow reads the action, never the script, and
#      GitHub reads an undeclared input as empty, so a broken mapping there
#      publishes an empty `lanes` or `lane_verdicts` with every row above
#      green.
#   5. the lane verdicts: one lane reached, two lanes reached, a lane named
#      on two lines, an unclaimed path outside the docs set and one inside
#      it, a docs path a lane claims, lanes=false, no changed path, and an
#      absent and seven malformed declarations, one with a valid lane ahead
#      of the bad line, one whose name starts with `-`, one that is the
#      event-uniform mark with no name and one that is a
#      directory, so it exists but cannot be read, each row
#      asserting the verdict lines and the declaration's state; the judged
#      tree carries a declaration of its own that no row may read, and
#      every run starts in a directory holding files the globs would expand
#      to. One mutant copy per rule must fail the row the rule decides, the
#      copy of classify or of the shipped lanes lib it reads, whichever
#      holds the rule. Beside them, the queue mark: a lane marked `:queue`
#      its own glob reaches stands down on a pull request where the
#      classifier answered queue_only=true and both the lanes-from
#      checkout and the judged head hold the installed reader of the mark,
#      runs where any of the three is missing, and stands down on no other
#      event; a merge group runs the
#      event-uniform queue lane whatever the proof says, and the
#      classifier's queue_only line reaches the step's outputs.
#   6. the proof: what a proof's record stands down, with and without a
#      declaration, per what it covers, a declared lane only where the
#      declaration marks it event-uniform; the record this run writes for the
#      next, its covers line per case, and record_dir naming it on the two
#      events a later run reads and empty on every other; the record's file
#      name bound to the member proof unzips and to the directory the
#      action uploads, and the artifact's name to the one proof looks up;
#      and one mutant copy per rule.
set -euo pipefail

unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

ROOT="$(git rev-parse --show-toplevel)"
CLASSIFY="$ROOT/.github/actions/change-class/classify"
LANES_LIB="$ROOT/skills/harness-ci/scripts/lib/ci-lanes.sh"
ACTION="$ROOT/.github/actions/change-class/action.yml"

mkdir -p "$ROOT/tmp"
TMP="$(mktemp -d)" || { echo "suite: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP && ! -L $TMP ]] || { echo "suite: scratch=not-a-directory" >&2; exit 1; }
TMP="$(cd -- "$TMP" && pwd -P)" || { echo "suite: scratch=resolve-failed" >&2; exit 1; }
trap 'chmod -R u+rwX "${TMP:?}" 2>/dev/null; rm -rf -- "${TMP:?}"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
check() { # DESC EXPECTED ACTUAL
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi
}
# A table loop that read no rows asserted nothing. sandbox.sh's copy cannot be
# sourced: it resets PASS and FAIL, makes its own sandbox and replaces the EXIT
# trap.
require_rows() { # TABLE COUNT
  [ "$2" -gt 0 ] || { echo "the $1 table executed no rows" >&2; exit 1; }
}
status=0
(require_rows probe 0) 2>/dev/null || status=$?
check "a table that executed no rows fails the floor" 1 "$status"
status=0
(require_rows probe 1) || status=$?
check "a table that executed a row passes the floor" 0 "$status"

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
[ -z "${GITHUB_OUTPUT:-}" ] ||
  printf 'change_class=%s\nqueue_only=%s\n' "$STUB_CLASS" "${STUB_QUEUE:-false}" >>"$GITHUB_OUTPUT"
[ -z "${STUB_OUTPUT_UNREADABLE:-}" ] || chmod 200 "$GITHUB_OUTPUT"
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
# The lane declaration's reader is the shipped one, read from the stubs root
# as classify reads it from the classifier root. A root without it is the
# lanes-reader refusal's.
mkdir -p "$STUBS/skills/harness-ci/scripts/lib"
cp "$LANES_LIB" "$STUBS/skills/harness-ci/scripts/lib/ci-lanes.sh"
mkdir -p "$TMP/no-lanes-lib"
cp -R "$STUBS/skills" "$TMP/no-lanes-lib/skills"
rm -- "${TMP:?}/no-lanes-lib/skills/harness-ci/scripts/lib/ci-lanes.sh"
# The proof stub answers what STUB_REUSE, STUB_RUN, STUB_TREE and
# STUB_WORKFLOW say, with STUB_REASON in place of the reason each answer
# carries, and where it reuses, writes STUB_RECORD as the record in the work
# directory it was given, as the real one does.
STUB_PROOF="$TMP/stub-proof"
cat >"$STUB_PROOF" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'proof %s\n' "$*" >>"$STUB_LOG"
[ "${STUB_PROOF_EXIT:-0}" -eq 0 ] || exit "$STUB_PROOF_EXIT"
record=""
if [ "${STUB_REUSE:-false}" = true ]; then
  record="$1/record"
  printf '%s\n' "${STUB_RECORD:-}" >"$record"
fi
reason=ineligible-event
[ "${STUB_REUSE:-false}" != true ] || reason=exact-proof
printf 'tree=%s\nworkflow=%s\nreuse=%s\nreason=%s\ndetail=stub\nrun=%s\nrecord=%s\n' \
  "${STUB_TREE:-}" "${STUB_WORKFLOW-.github/workflows/ci.yml}" "${STUB_REUSE:-false}" \
  "${STUB_REASON:-$reason}" "${STUB_RUN:-}" "$record"
[ -z "${STUB_KIND:-}" ] || printf 'kind=%s\npatch_id=%s\n' "$STUB_KIND" "${STUB_PATCH:-}"
STUB
chmod +x "$STUB_PROOF"

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
# lines, marking it event-uniform on the first alone, marks `tmux` too and
# leaves `docs-build` unmarked, and carries a comment that would claim src/*
# for tmux if it were read as globs. The judged tree carries one of its own,
# which reaches every path: a row that reads it publishes `lane_evil`.
declare_lanes() { # NAME CONTENT
  mkdir -p "$TMP/decl/$1/.github"
  printf '%s' "$2" >"$TMP/decl/$1/.github/ci-lanes.conf"
}
declare_lanes good '# Lanes and the paths each reads.
check:event-uniform src/* Cargo.toml
tmux:event-uniform tmux/*   # not src/*
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
declare_lanes bad-mark-only ':event-uniform src/*
'
# `queued` marks `bench` on its first line alone, so its second line's glob
# defers too, and `nightly` carries both marks, the queue mark last. Its
# root holds the installed render's reader of the mark, which a deferral
# needs in the lanes-from checkout and at the judged head alike;
# `queued-no-reader` is the same declaration in a root without it.
QUEUED='check:event-uniform src/*
bench:queue benches/*
bench Cargo.lock
nightly:event-uniform:queue nightly/*
'
declare_lanes queued "$QUEUED"
declare_lanes queued-no-reader "$QUEUED"
mkdir -p "$TMP/decl/queued/.agents/skills/harness-ci/scripts/lib"
cp "$LANES_LIB" "$TMP/decl/queued/.agents/skills/harness-ci/scripts/lib/ci-lanes.sh"
mkdir -p "$TMP/decl/absent" "$TMP/decl/unreadable/.github/ci-lanes.conf" \
  "$TMP/subject/.github"
printf 'evil *\n' >"$TMP/subject/.github/ci-lanes.conf"
# The judged tree's two heads: JUDGED_READER carries the reader of the mark,
# JUDGED_NO_READER is its child that deletes it. Its worktree holds neither,
# since classify reads the head commit, not the worktree.
subject_git() { git -C "$TMP/subject" -c user.name=suite -c user.email=suite@example.invalid "$@"; }
subject_git init -q
subject_git config gc.auto 0
subject_git config maintenance.auto false
mkdir -p "$TMP/subject/.agents/skills/harness-ci/scripts/lib"
cp "$LANES_LIB" "$TMP/subject/.agents/skills/harness-ci/scripts/lib/ci-lanes.sh"
subject_git add .agents
subject_git commit -qm reader
JUDGED_READER="$(subject_git rev-parse HEAD)"
subject_git rm -rq .agents
subject_git commit -qm no-reader
JUDGED_NO_READER="$(subject_git rev-parse HEAD)"

# Run a classify script with an explicit environment: the defaults below,
# then each NAME=VALUE argument, the later of two settings winning. The
# script is copied beside the proof stub first, unless it is run in place
# with `run_in_place`. Prints the exit status; stderr is kept in $TMP/err.
RUN_DIR="$TMP/run"
mkdir -p "$RUN_DIR"
cp "$STUB_PROOF" "$RUN_DIR/proof"
# ROW_CLASSIFIER, when set, is the scripts root a run reads in place of the
# stubs root: plant sets it to a root holding a planted lanes lib.
ROW_CLASSIFIER=""
run_in_place() { # SCRIPT [NAME=VALUE]...
  local script="$1" status=0
  shift
  [ ! -e "$OUT" ] || chmod u+rw "$OUT"
  : >"$OUT"
  : >"$LOG"
  (cd "$CWD" && env -i PATH="$PATH" HOME="$HOME" TMPDIR="$TMP" \
    CLASSIFIER="${ROW_CLASSIFIER:-$STUBS}" EVENT=pull_request BASE=b0 HEAD=h1 REPO="$TMP/subject" \
    GITHUB_OUTPUT="$OUT" STUB_LOG="$LOG" STUB_CLASS=standard STUB_DOCS=false \
    "$@" bash "$script" >"$TMP/stdout" 2>"$TMP/err") || status=$?
  printf '%s' "$status"
}
run() { # SCRIPT [NAME=VALUE]...
  local script="$1"
  shift
  cp "$script" "$RUN_DIR/classify"
  run_in_place "$RUN_DIR/classify" "$@"
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
# The proof lines a run with the stub's default answer writes.
NO_PROOF="proof_reuse=false proof_reason=ineligible-event proof_run= proof_tree= proof_record="
class_rows() {
  cat <<ROWS
render|render|false|.agents/skills/orch/SKILL.md .claude/skills/orch/SKILL.md|change_class=render queue_only=false docs_only=false changed_skills= changed_crates= changed_workflows= changed_paths=.agents/skills/orch/SKILL.md,.claude/skills/orch/SKILL.md $NO_PROOF lanes=false lanes_cause=render lane_verdicts= record_dir=
trivial|trivial|true|docs/guide.md|change_class=trivial queue_only=false docs_only=true changed_skills= changed_crates= changed_workflows= changed_paths=docs/guide.md $NO_PROOF lanes=false lanes_cause=trivial lane_verdicts= record_dir=
trivial-allowlisted|trivial|false|runtime/notes.txt|change_class=trivial queue_only=false docs_only=false changed_skills= changed_crates= changed_workflows= changed_paths=runtime/notes.txt $NO_PROOF lanes=false lanes_cause=trivial lane_verdicts= record_dir=
micro|micro|false|skills/orch/SKILL.md .agents/skills/orch/SKILL.md|change_class=micro queue_only=false docs_only=false changed_skills=orch changed_crates= changed_workflows= changed_paths=skills/orch/SKILL.md,.agents/skills/orch/SKILL.md $NO_PROOF lanes=true lanes_cause=micro lane_verdicts= record_dir=
small|small|false|crates/cli/src/main.rs crates/core/src/lib.rs|change_class=small queue_only=false docs_only=false changed_skills= changed_crates=cli core changed_workflows= changed_paths=crates/cli/src/main.rs,crates/core/src/lib.rs $NO_PROOF lanes=true lanes_cause=small lane_verdicts= record_dir=
standard|standard|false|.github/workflows/ci.yml skills/github/SKILL.md crates/app/src/lib.rs|change_class=standard queue_only=false docs_only=false changed_skills=github changed_crates=app changed_workflows=ci.yml changed_paths=.github/workflows/ci.yml,skills/github/SKILL.md,crates/app/src/lib.rs $NO_PROOF lanes=true lanes_cause=standard lane_verdicts= record_dir=
docs-only-standard|standard|true|docs/guide.md changelog.d/fixed/x.md README.md|change_class=standard queue_only=false docs_only=true changed_skills= changed_crates= changed_workflows= changed_paths=docs/guide.md,changelog.d/fixed/x.md,README.md $NO_PROOF lanes=false lanes_cause=docs-only lane_verdicts= record_dir=
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
require_rows class "$rows"
check "the step says why the lanes answered as they did" \
  "lanes: lanes=false cause=docs-only" "$(grep '^lanes: ' "$TMP/err")"

# The wrapped scripts see the step's inputs as flags, and the path list comes
# from the docs-mode call alone: a harness-mode read here would be a second
# reader of the same diff.
run "$CLASSIFY" STUB_CLASS=micro STUB_PATHS=skills/orch/SKILL.md >/dev/null
check "each wrapped script is called once, with the step's inputs, and the proof with the work directory" \
  "change-class --event pull_request --head h1 --repo $TMP/subject --base b0
harness-only --mode docs --event pull_request --head h1 --repo $TMP/subject --base b0 --paths-output PATHS
proof WORK" \
  "$(sed 's/--paths-output [^ ]*$/--paths-output PATHS/; s/^proof .*/proof WORK/' "$LOG")"
# The proof classify calls is the one beside it: the tracked pair, run in
# place with no GITHUB_SHA, answers the real proof's own refusal.
run_in_place "$CLASSIFY" >/dev/null
check "the tracked classify calls the tracked proof beside it" "proof_reason=no-github-sha" \
  "$(grep '^proof_reason=' "$OUT")"
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

# A rule planted wrong in a copy of TARGET, `classify` or `lib`, every other
# line kept: a classify copy at $mutant, or a lanes lib copy in a stubs root
# of its own, which ROW_CLASSIFIER then names for the runs after it. Sets
# PLANTED to the classify to run. Called outside a substitution, so the
# root it names reaches the runs.
MUTANT_STUBS="$TMP/mutant-stubs"
PLANTED=""
plant() { # TARGET NEEDLE REPLACEMENT
  local file copy
  case "$1" in
    classify) file="$CLASSIFY" copy="$mutant" ROW_CLASSIFIER="" ;;
    lib)
      file="$LANES_LIB" copy="$MUTANT_STUBS/skills/harness-ci/scripts/lib/ci-lanes.sh"
      rm -rf -- "${MUTANT_STUBS:?}"
      cp -R "$STUBS" "$MUTANT_STUBS"
      ROW_CLASSIFIER="$MUTANT_STUBS" ;;
    *) echo "no mutant target $1" >&2; exit 1 ;;
  esac
  [ "$(grep -cF -- "$2" "$file")" -eq 1 ] ||
    { echo "the rule '$2' is no longer one line in $file" >&2; exit 1; }
  NEEDLE="$2" REPLACEMENT="$3" awk '
    { i = index($0, ENVIRON["NEEDLE"]) }
    i > 0 { $0 = substr($0, 1, i - 1) ENVIRON["REPLACEMENT"] substr($0, i + length(ENVIRON["NEEDLE"])) }
    { print }
  ' "$file" >"$copy"
  ! cmp -s "$file" "$copy" || { echo "the mutant for '$2' changed nothing" >&2; exit 1; }
  PLANTED="$CLASSIFY"
  [ "$1" = lib ] || PLANTED="$mutant"
}

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
require_rows "lanes mutant" "$mutants"

# --- 3. The refusals --------------------------------------------------------

# CAUSE|ASSIGNMENTS (blank-separated NAME=VALUE)
# A mode-000 file is still readable by root, so the one row that forces a
# read failure that way cannot fail under root and is skipped there, saying so.
refusal_rows=0
while IFS='|' read -r cause assignments; do
  refusal_rows=$((refusal_rows + 1))
  case "$assignments" in
    *STUB_PATHS_UNREADABLE=* | *STUB_OUTPUT_UNREADABLE=*)
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
queue-only-unreadable path=$OUT|STUB_OUTPUT_UNREADABLE=1
path-reader-failed status=2|STUB_PATHS_EXIT=2 STUB_PATHS=a
docs-verdict-unreadable docs-line=harness_only=true|STUB_DOCS_LINE=harness_only=true STUB_PATHS=a
class-without-paths class=micro|STUB_CLASS=micro STUB_PATHS=
family-read-failed prefix=skills|STUB_PATHS=skills/orch/SKILL.md STUB_PATHS_UNREADABLE=1
delimiter-collides path=__change_class_changed_paths_end__|STUB_PATHS=__change_class_changed_paths_end__
lanes-from-unreadable root=$TMP/nowhere|LANES_FROM=$TMP/nowhere
lanes-from-judged-tree root=$TMP/subject|LANES_FROM=$TMP/subject
repo-unreadable repo=$TMP/nowhere|LANES_FROM=$TMP/decl/good REPO=$TMP/nowhere
outside-list-unreadable status=2|LANES_FROM=$TMP/decl/good STUB_PATHS=Makefile STUB_NO_OUTSIDE=1
lanes-reader-unreadable root=$TMP/no-lanes-lib|LANES_FROM=$TMP/decl/good CLASSIFIER=$TMP/no-lanes-lib
proof-failed status=2|STUB_PROOF_EXIT=2
proof-unreadable lines=tree= workflow=.github/workflows/ci.yml reuse=maybe reason=ineligible-event detail=stub run= record=|STUB_REUSE=maybe
ROWS
require_rows refusal "$refusal_rows"

# A classify with no proof beside it is a broken action, refused before
# either wrapped script runs.
mkdir -p "$TMP/no-proof"
cp "$CLASSIFY" "$TMP/no-proof/classify"
status="$(run_in_place "$TMP/no-proof/classify")"
check "refusal proof-missing: exit" "2" "$status"
check "refusal proof-missing: key" "proof-missing path=$TMP/no-proof/proof" "$(refusal)"

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

# --- 4. action.yml forwards or reads every output classify writes ----------

# The names one classify run writes, heredoc-delimited values skipped. The
# standard row reaches every writer, lanes last.
run "$CLASSIFY" STUB_CLASS=standard STUB_PATHS=skills/orch/SKILL.md MACOS_PATCH_PROOF=true >/dev/null
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
# The classify outputs the action's own steps under `runs:` read, sorted.
steps_read() { # ACTION_YML
  awk '/^runs:/ { on = 1 } on' "$1" | grep -oE 'steps\.classify\.outputs\.[a-z_]+' |
    sed 's/.*\.//' | LC_ALL=C sort -u
}
case " $(steps_read "$ACTION" | tr '\n' ' ') " in
  *" record_dir "*) ;;
  *) echo "the step reader found no record_dir read in $ACTION, so it is broken" >&2; exit 1 ;;
esac
# Each declared entry that forwards no written name under its own, and each
# written name neither declared nor read by a step; empty where all hold.
forwarding() { # ACTION_YML
  local names
  names="$( { declared "$1" | cut -d' ' -f1; steps_read "$1"; } | LC_ALL=C sort -u)"
  comm -13 <(printf '%s\n' "$forwarded") <(declared "$1") | sed 's/^/declared-unforwarded: /'
  comm -23 <(printf '%s\n' "$written") <(printf '%s\n' "$names") | sed 's/^/written-unread: /'
}
check "each output classify writes is forwarded by name or read by the action's own steps" \
  "" "$(forwarding "$ACTION")"

needle='value: ${{ steps.classify.outputs.lanes }}'
[ "$(grep -cF -- "$needle" "$ACTION")" -eq 1 ] ||
  { echo "the lanes mapping is no longer one line in $ACTION" >&2; exit 1; }
NEEDLE="$needle" awk '
  { i = index($0, ENVIRON["NEEDLE"]) }
  i > 0 { $0 = substr($0, 1, i - 1) "value: ${{ steps.classify.outputs.lane }}" substr($0, i + length(ENVIRON["NEEDLE"])) }
  { print }
' "$ACTION" >"$TMP/action.yml"
! cmp -s "$ACTION" "$TMP/action.yml" || { echo "the action.yml mutant changed nothing" >&2; exit 1; }
check "must-fail: an action.yml whose lanes value is misspelled fails the forwarding row" \
  'declared-unforwarded: lanes ${{ steps.classify.outputs.lane }}' "$(forwarding "$TMP/action.yml")"
[ "$(grep -c 'steps\.classify\.outputs\.record_dir' "$ACTION")" -ge 2 ] ||
  { echo "the upload step no longer reads record_dir on two lines of $ACTION" >&2; exit 1; }
sed 's/steps\.classify\.outputs\.record_dir/steps.classify.outputs.record_path/' "$ACTION" >"$TMP/action.yml"
check "must-fail: an action.yml whose upload step reads no record_dir fails the forwarding row" \
  'written-unread: record_dir' "$(forwarding "$TMP/action.yml")"

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

# The one env line no input carries: the job token, which GitHub writes.
TOKEN_LINE='GH_TOKEN: ${{ github.token }}'
mapped="$(input_mappings "$ACTION")"
case "$mapped" in
  *'LANES_FROM: ${{ inputs.lanes-from }}'*) ;;
  *) echo "the inputs reader found no lanes-from input in $ACTION, so it is broken: $mapped" >&2; exit 1 ;;
esac
check "action.yml maps each input to exactly one classify env line of its own name, the token beside them" \
  "$mapped" "$(classify_env "$ACTION" | grep -vxF -- "$TOKEN_LINE")"
check "the token reaches classify from the github context, never an input" "1" \
  "$(classify_env "$ACTION" | grep -cxF -- "$TOKEN_LINE")"

# The names classify's header lists under `Environment, from the action's
# inputs`: the runner's own variables, GITHUB_OUTPUT among them, sit under
# the second Environment header and no input carries them.
header_env="$(awk '
  /^# Environment, from the action/ { on = 1; next }
  on && /^# Environment, from the runner/ { exit }
  on && /^#   [A-Z][A-Z_]* / { print $2 }
' "$CLASSIFY" | LC_ALL=C sort)" ||
  { echo "the Environment header reader failed on $CLASSIFY" >&2; exit 1; }
case "$header_env" in
  *LANES_FROM*) ;;
  *) echo "the Environment header reader found no LANES_FROM in $CLASSIFY, so it is broken: $header_env" >&2; exit 1 ;;
esac
check "classify's env names are the ones its Environment header lists" \
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
bad-mark-only|bad-mark-only|standard|false|src/main.rs|src/main.rs|lane_verdicts= state=malformed cause=bad-name line=1 name=:event-uniform
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
require_rows lane "$rows"

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
# NEEDLE@REPLACEMENT@ROW@TARGET, split on `@` because a rule spells the
# shell's `&&`; TARGET is the file holding the rule, as plant takes it.
mutants=0
while IFS='@' read -r needle replacement row target; do
  mutants=$((mutants + 1))
  plant "$target" "$needle" "$replacement"
  check "must-fail: '$needle' planted as '$replacement' fails the $row row" \
    no "$(lane_row_holds "$PLANTED" "$row")"
done <<'ROWS'
declaration="$lanes_root/.github/ci-lanes.conf"@declaration="$judged_root/.github/ci-lanes.conf"@one-lane@classify
    line="${line%%#*}"@    line="$line"@one-lane@lib
[!abcdefghijklmnopqrstuvwxyz0123456789]* | *[!abcdefghijklmnopqrstuvwxyz0123456789_-]*)@never-a-lane-name)@bad-name@lib
{ declaration_note="cause=no-globs line=$number lane=$name"; return 1; }@:@no-globs@lib
[ "$lane_count" -gt 0 ] || { declaration_note="cause=no-lanes"; return 1; }@:@no-lanes@lib
          lane_hits[$index]="cause=claimed path=$path glob=$LANE_GLOB_HIT"@          lane_hits[$index]=""@two-lanes@classify
    if [ "$claimed" = false ] && [ -z "$every" ] && outside_docs "$path"; then@    if false; then@unclaimed@classify
 && outside_docs "$path"; then@ && true; then@unclaimed-docs@classify
    every="cause=no-changed-paths"@    every=""@no-paths@classify
    lane_state="malformed" lane_count=0@    lane_state="malformed"@bad-after-good@classify
[!abcdefghijklmnopqrstuvwxyz0123456789]* | *[!@*[!@bad-leading@lib
      '' | [!@      [!@bad-mark-only@lib
    set -f@    :@one-lane@lib
  set -f; for glob in@  for glob in@one-lane@lib
    lane_values[$index]=false lane_causes[$index]="cause=lanes-false lanes_cause=$lanes_cause"@    lane_values[$index]=true lane_causes[$index]="cause=lanes-false lanes_cause=$lanes_cause"@docs-only@classify
    lane_values[$index]=false lane_causes[$index]="cause=unreached"@    lane_values[$index]=true lane_causes[$index]="cause=unreached"@one-lane@classify
{ declaration_note="cause=unreadable"; return 1; }@:@unreadable@lib
ROWS
ROW_CLASSIFIER=""
require_rows "lane mutant" "$mutants"

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

# --- 5b. The queue mark ------------------------------------------------------

# A lane marked `:queue` that one of its own globs reaches stands down on a
# pull request alone, and there only where the classifier answered
# queue_only=true and both the declaration's root and the judged head hold
# the reader of the mark; every other event runs it as an unmarked lane, and
# a queue lane only an unclaimed path reached runs on the pull request too.
# ROW|EVENT|DECLARATION|JUDGED HEAD (reader or no-reader)|QUEUE_ONLY|
# PATHS (each outside the docs set)|EXPECTED: the lane_verdicts value and
# the lanes the step's `lane:` lines name queue-deferred.
queue_rows() {
  cat <<'ROWS'
pr-deferred|pull_request|queued|reader|true|benches/b.rs src/main.rs|lane_verdicts=lane_check=true,lane_bench=false,lane_nightly=false deferred=bench
pr-second-line|pull_request|queued|reader|true|Cargo.lock|lane_verdicts=lane_check=false,lane_bench=false,lane_nightly=false deferred=bench
pr-both-marks|pull_request|queued|reader|true|nightly/run.sh|lane_verdicts=lane_check=false,lane_bench=false,lane_nightly=false deferred=nightly
pr-unclaimed|pull_request|queued|reader|true|Makefile|lane_verdicts=lane_check=true,lane_bench=true,lane_nightly=true deferred=
pr-unclaimed-and-claimed|pull_request|queued|reader|true|Makefile benches/b.rs|lane_verdicts=lane_check=true,lane_bench=false,lane_nightly=true deferred=bench
pr-unconfirmed|pull_request|queued|reader|false|benches/b.rs src/main.rs|lane_verdicts=lane_check=true,lane_bench=true,lane_nightly=false deferred=
pr-reader-absent|pull_request|queued-no-reader|reader|true|benches/b.rs src/main.rs|lane_verdicts=lane_check=true,lane_bench=true,lane_nightly=false deferred=
pr-judged-reader-absent|pull_request|queued|no-reader|true|benches/b.rs src/main.rs|lane_verdicts=lane_check=true,lane_bench=true,lane_nightly=false deferred=
merge-group|merge_group|queued|reader|true|benches/b.rs src/main.rs|lane_verdicts=lane_check=true,lane_bench=true,lane_nightly=false deferred=
push|push|queued|reader|true|benches/b.rs|lane_verdicts=lane_check=false,lane_bench=true,lane_nightly=false deferred=
ROWS
}
# The one read of a queue row's columns, into the Q_* globals.
queue_row() { # ROW
  local line
  line="$(queue_rows | grep -m1 "^$1|")" || { echo "no queue row named $1" >&2; exit 1; }
  IFS='|' read -r _ Q_EVENT Q_DECL Q_JUDGED Q_QUEUE Q_PATHS Q_EXPECTED <<<"$line"
  case "$Q_JUDGED" in
    reader) Q_HEAD="$JUDGED_READER" ;;
    no-reader) Q_HEAD="$JUDGED_NO_READER" ;;
    *) echo "queue row $1 names no judged head: $Q_JUDGED" >&2; exit 1 ;;
  esac
}
queue_answer() { # SCRIPT ROW — the row's answer, or `crashed`
  queue_row "$2"
  if [ "$(run "$1" EVENT="$Q_EVENT" HEAD="$Q_HEAD" LANES_FROM="$TMP/decl/$Q_DECL" STUB_QUEUE="$Q_QUEUE" \
    STUB_PATHS="$Q_PATHS" STUB_OUTSIDE="$Q_PATHS")" != 0 ]; then
    echo crashed
    return 0
  fi
  printf '%s deferred=%s\n' "$(outputs | tr ' ' '\n' | grep '^lane_verdicts=')" \
    "$(sed -n 's/^lane: name=\([^ ]*\) verdict=false cause=queue-deferred .*/\1/p' "$TMP/err" | tr '\n' ' ' | sed 's/ $//')"
}
rows=0
while IFS= read -r row; do
  rows=$((rows + 1))
  queue_row "$row"
  check "queue row $row" "$Q_EXPECTED" "$(queue_answer "$CLASSIFY" "$row")"
done < <(queue_rows | cut -d'|' -f1)
require_rows queue "$rows"
# The lane: line's cause, per row that reaches each branch of the deferral,
# and the one annotation a missing reader raises on the step's stdout.
for row in pr-deferred pr-unconfirmed pr-reader-absent pr-judged-reader-absent; do
  case "$row" in
    pr-deferred) want="lane: name=bench verdict=false cause=queue-deferred path=benches/b.rs glob=benches/*" ;;
    pr-unconfirmed) want="lane: name=bench verdict=true cause=queue-unconfirmed queue_only=false path=benches/b.rs glob=benches/*" ;;
    pr-reader-absent) want="lane: name=bench verdict=true cause=queue-reader-absent tree=lanes-from path=benches/b.rs glob=benches/*" ;;
    pr-judged-reader-absent) want="lane: name=bench verdict=true cause=queue-reader-absent tree=judged path=benches/b.rs glob=benches/*" ;;
  esac
  check "the $row row's lane line names its cause, path and glob" "$want" \
    "$(queue_answer "$CLASSIFY" "$row" >/dev/null; grep '^lane: name=bench ' "$TMP/err")"
  case "$row" in
    pr-reader-absent) want='::warning title=queue lane not deferred::tree=lanes-from ' ;;
    pr-judged-reader-absent) want='::warning title=queue lane not deferred::tree=judged ' ;;
    *) want='' ;;
  esac
  check "the $row row's annotation" "$want" \
    "$(sed -n 's/^\(::warning title=[^:]*::tree=[^ ]* \).*/\1/p' "$TMP/stdout")"
done
# Both trees without the reader: each deferred lane names both, under one
# annotation.
run "$CLASSIFY" HEAD="$JUDGED_NO_READER" LANES_FROM="$TMP/decl/queued-no-reader" STUB_QUEUE=true \
  STUB_PATHS="benches/b.rs nightly/run.sh" STUB_OUTSIDE="benches/b.rs nightly/run.sh" >/dev/null
check "both trees without the reader name both on a lane line and warn once" \
  "lane: name=bench verdict=true cause=queue-reader-absent tree=lanes-from,judged path=benches/b.rs glob=benches/* 1" \
  "$(grep '^lane: name=bench ' "$TMP/err") $(grep -c '^::warning title=queue lane not deferred::' "$TMP/stdout")"
check "the step forwards the classifier's queue_only line as it wrote it" "queue_only=true" \
  "$(run "$CLASSIFY" STUB_QUEUE=true STUB_PATHS=src/main.rs >/dev/null; grep '^queue_only=' "$OUT")"

# The merge group after a pull request that deferred `nightly`: that run's
# record says nightly did not run, so the proof stands down `check`, which
# it ran, and never `nightly`, though `queued` marks both event-uniform.
mg_after_deferral() { # SCRIPT — the merge group's lanes and lane_verdicts
  run "$1" EVENT=merge_group LANES_FROM="$TMP/decl/queued" STUB_QUEUE=true \
    STUB_PATHS="nightly/run.sh src/main.rs" STUB_OUTSIDE="nightly/run.sh src/main.rs" \
    STUB_REUSE=true STUB_RUN=42 STUB_TREE=t1 \
    STUB_RECORD="$(printf 'covers=lanes\nlane_check=true\nlane_bench=false\nlane_nightly=false')" >/dev/null
  outputs | tr ' ' '\n' | grep -E '^(lanes|lane_verdicts)=' | tr '\n' ' ' | sed 's/ $//'
}
MG_AFTER_DEFERRAL="lanes=true lane_verdicts=lane_check=false,lane_bench=false,lane_nightly=true"
check "a merge group runs the event-uniform lane its pull request deferred, whatever the proof" \
  "$MG_AFTER_DEFERRAL" "$(mg_after_deferral "$CLASSIFY")"
plant classify \
  'if [ "${proven[$index]}" = true ] && [ "${lane_uniform[$index]}" = true ]; then' \
  'if { [ "${proven[$index]}" = true ] || [ "${lane_queue[$index]}" = true ]; } && [ "${lane_uniform[$index]}" = true ]; then'
answer="$(mg_after_deferral "$PLANTED")"
if [ "$answer" = "$MG_AFTER_DEFERRAL" ]; then
  bad "must-fail: a proof that stands a queue lane down unrecorded still runs the deferred lane"
else
  ok "must-fail: a proof that stands a queue lane down unrecorded stands the deferred lane down"
fi

# One copy per queue rule, the rule planted wrong and every other line kept.
# NEEDLE@REPLACEMENT@ROW@TARGET, as the lane table above. queue_mutant says
# what a planted copy does to its row: crashed, survives or fails.
queue_mutant() { # TARGET NEEDLE REPLACEMENT ROW
  local answer
  plant "$1" "$2" "$3"
  answer="$(queue_answer "$PLANTED" "$4")"
  queue_row "$4"
  case "$answer" in
    crashed) echo crashed ;;
    "$Q_EXPECTED") echo survives ;;
    *) echo fails ;;
  esac
}
mutants=0
while IFS='@' read -r needle replacement row target; do
  mutants=$((mutants + 1))
  case "$(queue_mutant "$target" "$needle" "$replacement" "$row")" in
    crashed) bad "must-fail: '$needle' planted as '$replacement' crashed the $row row" ;;
    survives) bad "must-fail: '$needle' planted as '$replacement' still answers the $row row" ;;
    fails) ok "must-fail: '$needle' planted as '$replacement' fails the $row row" ;;
    *) bad "must-fail: '$needle' planted as '$replacement' gave no verdict on the $row row" ;;
  esac
done <<'ROWS'
  elif [ "$EVENT" = pull_request ] && [ "${lane_queue[$index]}" = true ] && [ -n "${lane_hits[$index]}" ]; then@  elif false; then@pr-deferred@classify
[ "$EVENT" = pull_request ] && [ "${lane_queue[$index]}"@true && [ "${lane_queue[$index]}"@merge-group@classify
 && [ -n "${lane_hits[$index]}" ]; then@; then@pr-unclaimed@classify
  [ -f "$lanes_root/$queue_reader" ] || missing="lanes-from"@  true || missing="lanes-from"@pr-reader-absent@classify
  [ "$(git -C "$REPO" cat-file -t "$HEAD:$queue_reader" 2>/dev/null)" = blob ] ||@  true ||@pr-judged-reader-absent@classify
    elif [ "$queue_only" != true ]; then@    elif false; then@pr-unconfirmed@classify
*:queue) queue=true name=@*:queue) queue=false name=@pr-deferred@lib
    [ "$queue" = false ] || lane_queue[$index]=true@    lane_queue[$index]="$queue"@pr-second-line@lib
    while :; do@    for _ in once; do@pr-both-marks@lib
ROWS
ROW_CLASSIFIER=""
require_rows "queue mutant" "$mutants"
# The loop's own control: a copy that keeps the rule's behaviour must read as
# still answering its row, or the loop reports kills it never saw.
check "a behaviour-preserving queue mutant reads as still answering its row" survives \
  "$(queue_mutant classify '    elif [ "$queue_only" != true ]; then' \
    '    elif [ "$queue_only" != "true" ]; then' pr-unconfirmed)"

# Patch proof has a separate output and never changes tree lane verdicts.
status="$(run "$CLASSIFY" EVENT=merge_group MACOS_PATCH_PROOF=true STUB_REUSE=true STUB_KIND=macos-patch STUB_PATCH=p1 STUB_RUN=42 STUB_RECORD='covers=all')"
check "patch proof classify exit" "0" "$status"
check "patch proof keeps integrated lanes" "true false p1" "$(sed -n 's/^lanes=//p' "$OUT") $(sed -n 's/^proof_reuse=//p' "$OUT") $(sed -n 's/^patch_id=//p' "$OUT")"
check "patch proof publishes macOS record separately" "macos_proof_record=covers=all" "$(outputs | tr ' ' '\n' | grep '^macos_proof_record=')"
needle='  proof_reuse=false'
[ "$(grep -cF -- "$needle" "$CLASSIFY")" -eq 1 ] || exit 1
sed '/^  proof_reuse=false$/d; /^  proof_record=""$/d' "$CLASSIFY" >"$TMP/patch-leak-classify"
! cmp -s "$CLASSIFY" "$TMP/patch-leak-classify" || exit 1
status="$(run "$TMP/patch-leak-classify" EVENT=merge_group MACOS_PATCH_PROOF=true STUB_REUSE=true STUB_KIND=macos-patch STUB_PATCH=p1 STUB_RECORD='covers=all')"
[ "$status" = 0 ] && [ "$(sed -n 's/^lanes=//p' "$OUT")" = false ] && ok "must-fail: patch proof leaks into tree proof" || bad "must-fail: patch proof leak control"

# --- 6. The proof -------------------------------------------------------------

# What a proof stands down. Every row reuses run 42 on tree t1 and reads the
# `good` declaration where DECL says so. The covered and gated rows hand the
# same record covering `check`, which `good` marks event-uniform, and
# `docs-build`, which it does not: the proof stands the first down and never
# the second.
# ROW|DECL|CLASS|DOCS|PATHS|OUTSIDE|RECORD (lines joined with commas)|EXPECTED
proof_rows() {
  cat <<'ROWS'
all-no-decl|-|standard|false|src/main.rs|src/main.rs|covers=all|lanes=false lanes_cause=proof-reused lane_verdicts=
lanes-no-decl|-|standard|false|src/main.rs|src/main.rs|covers=lanes,lane_check=true|lanes=true lanes_cause=standard lane_verdicts=
none-no-decl|-|standard|false|src/main.rs|src/main.rs|covers=none|lanes=true lanes_cause=standard lane_verdicts=
no-covers-no-decl|-|standard|false|src/main.rs|src/main.rs|tree=t1|lanes=true lanes_cause=standard lane_verdicts=
all-decl|good|standard|false|src/main.rs|src/main.rs|covers=all|lanes=false lanes_cause=proof-reused lane_verdicts=lane_check=false,lane_tmux=false,lane_docs-build=false
lanes-decl-covered|good|small|false|src/main.rs|src/main.rs|covers=lanes,lane_check=true,lane_docs-build=true|lanes=false lanes_cause=proof-reused lane_verdicts=lane_check=false,lane_tmux=false,lane_docs-build=false
lanes-decl-gated|good|standard|false|src/main.rs docs/guide.md|src/main.rs|covers=lanes,lane_check=true,lane_docs-build=true|lanes=true lanes_cause=standard lane_verdicts=lane_check=false,lane_tmux=false,lane_docs-build=true
lanes-decl-partial|good|standard|false|src/main.rs tmux/tmux.conf|src/main.rs tmux/tmux.conf|covers=lanes,lane_check=true,lane_tmux=false|lanes=true lanes_cause=standard lane_verdicts=lane_check=false,lane_tmux=true,lane_docs-build=false
lanes-decl-unnamed|good|standard|false|src/main.rs|src/main.rs|covers=lanes,lane_tmux=true|lanes=true lanes_cause=standard lane_verdicts=lane_check=true,lane_tmux=false,lane_docs-build=false
every-decl|good|standard|false|Makefile|Makefile|covers=lanes,lane_check=true,lane_tmux=true|lanes=true lanes_cause=standard lane_verdicts=lane_check=false,lane_tmux=false,lane_docs-build=true
docs-only-decl|good|standard|true|docs/guide.md||covers=all|lanes=false lanes_cause=docs-only lane_verdicts=lane_check=false,lane_tmux=false,lane_docs-build=false
render-no-decl|-|render|false|.agents/skills/orch/SKILL.md|.agents/skills/orch/SKILL.md|covers=all|lanes=false lanes_cause=render lane_verdicts=
ROWS
}
proof_answer() { # SCRIPT ROW — the lanes outputs, or `crashed`
  local line name decl class docs paths outside record expected lanes_from=""
  line="$(proof_rows | grep -m1 "^$2|")" || { echo "no proof row named $2" >&2; exit 1; }
  IFS='|' read -r name decl class docs paths outside record expected <<<"$line"
  [ "$decl" = - ] || lanes_from="$TMP/decl/$decl"
  if [ "$(run "$1" LANES_FROM="$lanes_from" STUB_CLASS="$class" STUB_DOCS="$docs" \
    STUB_PATHS="$paths" STUB_OUTSIDE="$outside" STUB_REUSE=true STUB_RUN=42 STUB_TREE=t1 \
    STUB_RECORD="$(printf '%s' "$record" | tr ',' '\n')")" != 0 ]; then
    echo crashed
    return 0
  fi
  outputs | tr ' ' '\n' | grep -E '^(lanes|lanes_cause|lane_verdicts)=' | tr '\n' ' ' | sed 's/ $//'
}
rows=0
while IFS='|' read -r name decl class docs paths outside record expected; do
  rows=$((rows + 1))
  check "proof row $name" "$expected" "$(proof_answer "$CLASSIFY" "$name")"
done < <(proof_rows)
require_rows proof "$rows"
check "a proof's stand-down names the run on the lane's line" \
  "lane: name=check verdict=false cause=proof-reused run=42" \
  "$(proof_answer "$CLASSIFY" lanes-decl-partial >/dev/null; grep '^lane: name=check ' "$TMP/err")"
check "the proof outputs carry the run, the tree and the record" \
  "proof_reuse=true proof_reason=exact-proof proof_run=42 proof_tree=t1 proof_record=covers=lanes,lane_check=true,lane_tmux=false" \
  "$(outputs | tr ' ' '\n' | grep '^proof_' | tr '\n' ' ' | sed 's/ $//')"
check "the step says what the proof answered" "proof: reuse=true reason=exact-proof run=42 stub" \
  "$(grep '^proof: reuse=' "$TMP/err")"
check "a proof held back from an unmarked lane names the run on the lane's line" \
  "lane: name=docs-build verdict=true cause=claimed path=docs/guide.md glob=docs/* proof-held=not-event-uniform run=42" \
  "$(proof_answer "$CLASSIFY" lanes-decl-gated >/dev/null; grep '^lane: name=docs-build ' "$TMP/err")"
check "a proof held back from an unmarked lane is counted apart from an uncovered one" \
  "proof: applied=1 of the lanes the diff runs, 1 held as not event-uniform, 0 uncovered" \
  "$(grep '^proof: applied=' "$TMP/err")"

# The record this run leaves, on the two events a later run reads.
# ROW|EVENT|DECL|CLASS|DOCS|PATHS|OUTSIDE|REUSE|RECORD|ENV|EXPECTED (the
# file's lines joined with commas, or `absent`). ENV is blank-separated
# NAME=VALUE words. The pr-all row is the template's case, a workflow that
# runs every lane on lanes=true; pr-selecting is kendex's own, a workflow
# selecting its jobs itself, which sets no covers-all-lanes. pr-decl-gated
# runs `docs-build`, which `good` leaves unmarked, and records it covered:
# the record says what passed, and the run reading it judges the mark.
RUNNER="$TMP/runner"
mkdir -p "$RUNNER"
RECORD_DIR="${RUNNER:?}/change-class-record"
COVERS_ALL=COVERS_ALL_LANES=true
record_rows() {
  cat <<ROWS
pr-all|pull_request|-|standard|false|src/main.rs|src/main.rs|false||$COVERS_ALL|tree=t1,workflow=.github/workflows/ci.yml,event=pull_request,change_class=standard,docs_only=false,covers=all,changed_path=src/main.rs
pr-selecting|pull_request|-|standard|false|src/main.rs|src/main.rs|false|||tree=t1,workflow=.github/workflows/ci.yml,event=pull_request,change_class=standard,docs_only=false,covers=none,changed_path=src/main.rs
pr-none|pull_request|-|standard|true|docs/guide.md||false||$COVERS_ALL|tree=t1,workflow=.github/workflows/ci.yml,event=pull_request,change_class=standard,docs_only=true,covers=none,changed_path=docs/guide.md
pr-absent-decl|pull_request|absent|small|false|src/main.rs|src/main.rs|false||$COVERS_ALL|tree=t1,workflow=.github/workflows/ci.yml,event=pull_request,change_class=small,docs_only=false,covers=all,changed_path=src/main.rs
mg-reused-all|merge_group|-|standard|false|src/main.rs|src/main.rs|true|covers=all||tree=t1,workflow=.github/workflows/ci.yml,event=merge_group,change_class=standard,docs_only=false,covers=all,changed_path=src/main.rs
pr-carried|pull_request|-|standard|true|docs/guide.md||true|covers=lanes,lane_check=true||tree=t1,workflow=.github/workflows/ci.yml,event=pull_request,change_class=standard,docs_only=true,covers=lanes,lane_check=true,changed_path=docs/guide.md
pr-decl|pull_request|good|standard|false|src/main.rs tmux/tmux.conf|src/main.rs tmux/tmux.conf|true|covers=lanes,lane_check=true,lane_tmux=false||tree=t1,workflow=.github/workflows/ci.yml,event=pull_request,change_class=standard,docs_only=false,covers=lanes,lane_check=true,lane_tmux=true,lane_docs-build=false,changed_path=src/main.rs,changed_path=tmux/tmux.conf
pr-decl-no-proof|pull_request|good|standard|false|src/main.rs|src/main.rs|false||$COVERS_ALL|tree=t1,workflow=.github/workflows/ci.yml,event=pull_request,change_class=standard,docs_only=false,covers=lanes,lane_check=true,lane_tmux=false,lane_docs-build=false,changed_path=src/main.rs
pr-decl-gated|pull_request|good|standard|false|src/main.rs docs/guide.md|src/main.rs|false||$COVERS_ALL|tree=t1,workflow=.github/workflows/ci.yml,event=pull_request,change_class=standard,docs_only=false,covers=lanes,lane_check=true,lane_tmux=false,lane_docs-build=true,changed_path=src/main.rs,changed_path=docs/guide.md
mg-decl-all|merge_group|good|standard|false|src/main.rs|src/main.rs|true|covers=all||tree=t1,workflow=.github/workflows/ci.yml,event=merge_group,change_class=standard,docs_only=false,covers=lanes,lane_check=true,lane_tmux=true,lane_docs-build=true,changed_path=src/main.rs
pr-queue-deferred|pull_request|queued|standard|false|benches/b.rs src/main.rs|benches/b.rs src/main.rs|false||$COVERS_ALL STUB_QUEUE=true HEAD=$JUDGED_READER|tree=t1,workflow=.github/workflows/ci.yml,event=pull_request,change_class=standard,docs_only=false,covers=lanes,lane_check=true,lane_bench=false,lane_nightly=false,changed_path=benches/b.rs,changed_path=src/main.rs
push|push|-|standard|false|src/main.rs|src/main.rs|false||$COVERS_ALL|absent
ROWS
}
# The record's lines as record_dir names them: `absent` where record_dir is
# empty and nothing was written, `stray` where a record sits there all the
# same, what the directory holds where it is not the one file `record`, or
# `crashed`.
record_answer() { # SCRIPT ROW
  local line name event decl class docs paths outside reuse record env expected lanes_from="" dir
  line="$(record_rows | grep -m1 "^$2|")" || { echo "no record row named $2" >&2; exit 1; }
  IFS='|' read -r name event decl class docs paths outside reuse record env expected <<<"$line"
  [ "$decl" = - ] || lanes_from="$TMP/decl/$decl"
  rm -rf -- "${RUNNER:?}/change-class-record"
  # shellcheck disable=SC2086 # ENV is blank-separated NAME=VALUE words
  if [ "$(run "$1" EVENT="$event" LANES_FROM="$lanes_from" STUB_CLASS="$class" STUB_DOCS="$docs" \
    STUB_PATHS="$paths" STUB_OUTSIDE="$outside" STUB_REUSE="$reuse" STUB_RUN=42 STUB_TREE=t1 \
    STUB_RECORD="$(printf '%s' "$record" | tr ',' '\n')" RUNNER_TEMP="$RUNNER" $env)" != 0 ]; then
    echo crashed
    return 0
  fi
  dir="$(sed -n 's/^record_dir=//p' "$OUT")"
  if [ -z "$dir" ]; then
    [ -e "$RECORD_DIR" ] && echo stray || echo absent
  elif [ "$dir" != "$RECORD_DIR" ] || [ "$(ls -A "$dir")" != record ]; then
    echo "record_dir=$dir holds $(ls -A "$dir" | tr '\n' ' ')"
  else
    tr '\n' ',' <"$dir/record" | sed 's/,$//'
  fi
}
rows=0
while IFS='|' read -r name event decl class docs paths outside reuse record env expected; do
  rows=$((rows + 1))
  check "record row $name" "$expected" "$(record_answer "$CLASSIFY" "$name")"
done < <(record_rows)
require_rows record "$rows"
check "the step names the record it wrote" "record: path=$RECORD_DIR/record tree=t1 covers=all" \
  "$(record_answer "$CLASSIFY" pr-all >/dev/null; grep '^record: ' "$TMP/err")"
check "a push says why it leaves no record" "record: skipped cause=unrecorded-event event=push" \
  "$(record_answer "$CLASSIFY" push >/dev/null; grep '^record: ' "$TMP/err")"

# CAUSE|ASSIGNMENTS: a pull request whose tree, workflow or runner directory
# did not read leaves no record, writes record_dir empty and says which.
skip_answer() { # SCRIPT ASSIGNMENTS
  rm -rf -- "${RUNNER:?}/change-class-record"
  # shellcheck disable=SC2086 # the assignments are blank-separated words
  run "$1" STUB_PATHS=src/main.rs $2 >/dev/null
  printf '%s %s %s' "$(grep '^record: ' "$TMP/err")" "$(grep '^record_dir=' "$OUT")" \
    "$([ -e "$RECORD_DIR" ] && echo present || echo absent)"
}
while IFS='|' read -r cause assignments; do
  check "no $cause, no record" "record: skipped cause=$cause record_dir= absent" \
    "$(skip_answer "$CLASSIFY" "$assignments")"
done <<ROWS
tree-unreadable|RUNNER_TEMP=$RUNNER
workflow-unreadable|STUB_TREE=t1 STUB_WORKFLOW= RUNNER_TEMP=$RUNNER
no-runner-temp|STUB_TREE=t1
ROWS
needle='    elif [ -z "$proof_workflow" ]; then'
[ "$(grep -cxF -- "$needle" "$CLASSIFY")" -eq 1 ] ||
  { echo "the workflow skip is no longer one line in $CLASSIFY" >&2; exit 1; }
awk -v needle="$needle" '$0 == needle { print "    elif false; then"; next } { print }' "$CLASSIFY" >"$mutant"
case "$(skip_answer "$mutant" "STUB_TREE=t1 STUB_WORKFLOW= RUNNER_TEMP=$RUNNER")" in
  *"record_dir=$RECORD_DIR present") ok "must-fail: a classify recording an unread workflow writes the record" ;;
  *) bad "must-fail: a classify recording an unread workflow writes the record" ;;
esac

status="$(run "$CLASSIFY" MACOS_PATCH_PROOF=true STUB_KIND=tree STUB_PATCH=p1 STUB_TREE=t1 RUNNER_TEMP="$RUNNER")"
check "PR patch record writer exit" "0" "$status"
check "PR record carries patch identity and macOS opt-in" "patch_id=p1
macos_patch=true" "$(grep -E '^(patch_id|macos_patch)=' "$RECORD_DIR/record")"

# The record's names, bound at both ends. The one file in record_dir is the
# member proof unzips, and the upload step uploads record_dir itself, so the
# artifact's root is that directory and its member the file's own name; a
# file uploaded on its own lands at the artifact root under its basename.
# The artifact's name is the upload step's prefix before proof_tree, and
# proof looks a record up by its own prefix before the tree.
proof_member() { # PROOF — the member its unzip reads
  sed -n 's/^.*unzip -p "\$WORK\/record\.zip" \([^ ]*\) >.*$/\1/p' "$1"
}
proof_prefix() { # PROOF — the artifact name before the tree
  sed -n 's/^artifact_name="\(.*\)\$tree"$/\1/p' "$1"
}
upload_key() { # ACTION_YML KEY — the upload step's KEY under `with:`
  awk -v key="$2" '
    /^    - / { upload = 0 }
    /^      uses: actions\/upload-artifact@/ { upload = 1 }
    upload && !seen && index($0, "        " key ": ") == 1 { print substr($0, length(key) + 11); seen=1 }
  ' "$1"
}
binding() { # PROOF ACTION_YML — `bound`, or what disagrees
  local member written prefix name
  member="$(proof_member "$1")"
  prefix="$(proof_prefix "$1")"
  [ -n "$member" ] && [ -n "$prefix" ] ||
    { echo "no unzip member or artifact prefix read from $1, so a reader is broken"; return 0; }
  record_answer "$CLASSIFY" pr-all >/dev/null
  written="$(ls -A "$(sed -n 's/^record_dir=//p' "$OUT")")"
  name="$(upload_key "$2" name)"
  if [ "$written" != "$member" ]; then
    echo "classify writes $written, proof reads $member"
  elif [ "$(upload_key "$2" path)" != '${{ steps.classify.outputs.record_dir }}' ]; then
    echo "the upload step uploads $(upload_key "$2" path), not record_dir"
  elif [ "$name" != "$prefix\${{ steps.classify.outputs.proof_tree }}" ]; then
    echo "the upload step names $name, proof looks up $prefix<tree>"
  else
    echo bound
  fi
}
PROOF_SCRIPT="$ROOT/.github/actions/change-class/proof"
check "the record classify writes is the member and artifact proof reads, as the action uploads it" \
  bound "$(binding "$PROOF_SCRIPT" "$ACTION")"
sed 's/unzip -p "$WORK\/record.zip" record >/unzip -p "$WORK\/record.zip" change-class-record >/' \
  "$PROOF_SCRIPT" >"$TMP/proof-member"
! cmp -s "$PROOF_SCRIPT" "$TMP/proof-member" || { echo "the member mutant changed nothing" >&2; exit 1; }
check "must-fail: a proof reading another member breaks the binding" \
  "classify writes record, proof reads change-class-record" "$(binding "$TMP/proof-member" "$ACTION")"
awk '$0 == "        path: ${{ steps.classify.outputs.record_dir }}" && !n { print "        path: ${{ runner.temp }}/change-class-record/record"; n++; next } { print } END { exit n != 1 }' \
  "$ACTION" >"$TMP/action-upload.yml" || { echo "the upload path is no longer one line in $ACTION" >&2; exit 1; }
check "must-fail: an action uploading the record file itself breaks the binding" \
  'the upload step uploads ${{ runner.temp }}/change-class-record/record, not record_dir' \
  "$(binding "$PROOF_SCRIPT" "$TMP/action-upload.yml")"
awk '$0 == "        name: change-class-proof-${{ steps.classify.outputs.proof_tree }}" { print "        name: change-class-record-${{ steps.classify.outputs.proof_tree }}"; n++; next } { print } END { exit n != 1 }' \
  "$ACTION" >"$TMP/action-name.yml" || { echo "the artifact name is no longer one line in $ACTION" >&2; exit 1; }
check "must-fail: an action uploading under another artifact name breaks the binding" \
  'the upload step names change-class-record-${{ steps.classify.outputs.proof_tree }}, proof looks up change-class-proof-<tree>' \
  "$(binding "$PROOF_SCRIPT" "$TMP/action-name.yml")"

# One copy per proof rule, the rule planted wrong and every other line kept.
# NEEDLE@REPLACEMENT@TABLE:ROW@FILE, split on `@` because a rule spells
# `||`; FILE is the file holding the rule, as plant takes it.
mutants=0
while IFS='@' read -r needle replacement target file; do
  mutants=$((mutants + 1))
  plant "$file" "$needle" "$replacement"
  row="${target#*:}"
  case "${target%%:*}" in
    proof) expected="$(proof_rows | grep -m1 "^$row|" | awk -F '|' '{ print $8 }')"; got="$(proof_answer "$PLANTED" "$row")" ;;
    record) expected="$(record_rows | grep -m1 "^$row|" | awk -F '|' '{ print $11 }')"; got="$(record_answer "$PLANTED" "$row")" ;;
  esac
  case "$got" in
    crashed) bad "must-fail: '$needle' planted as '$replacement' crashed the $row row" ;;
    "$expected") bad "must-fail: '$needle' planted as '$replacement' still answers the $row row" ;;
    *) ok "must-fail: '$needle' planted as '$replacement' fails the $row row" ;;
  esac
done <<'ROWS'
  [ "$record_covers" = all ] && return 0@  false && return 0@proof:all-decl@classify
  grep -qxF -- "lane_$1=true" <<<"$record_lanes"@  grep -qF -- "lane_$1=" <<<"$record_lanes"@proof:lanes-decl-partial@classify
    if [ "$uncovered" -eq 0 ] && [ "$held" -eq 0 ] && [ "$stood" -gt 0 ]; then@    if [ "$held" -eq 0 ] && [ "$stood" -gt 0 ]; then@proof:lanes-decl-partial@classify
 && [ "$held" -eq 0 ] && [ "$stood" -gt 0 ]; then@ && [ "$stood" -gt 0 ]; then@proof:lanes-decl-gated@classify
  elif [ "$record_covers" = all ]; then@  elif true; then@proof:lanes-no-decl@classify
if [ "$proof_reuse" = true ] && [ "$lanes" = true ]; then@if [ "$proof_reuse" = true ]; then@proof:render-no-decl@classify
    *) record_covers=none ;;@    *) record_covers=all ;;@proof:no-covers-no-decl@classify
if [ "$lanes" = true ] && [ "$lane_state" != read ] && [ "${COVERS_ALL_LANES:-}" = true ]; then@if false; then@record:pr-all@classify
 && [ "${COVERS_ALL_LANES:-}" = true ]; then@; then@record:pr-selecting@classify
[ "${lane_values[$index]}" != true ] && [ "${proven[$index]}" != true ] ||@[ "${lane_values[$index]}" != true ] ||@record:pr-decl@classify
 || covered=true@ || covered="${lane_uniform[$index]}"@record:pr-decl-gated@classify
elif [ "$lane_state" = read ]; then@elif false; then@record:mg-decl-all@classify
*:event-uniform) uniform=true name=@*:event-uniform) uniform=false name=@proof:lanes-decl-covered@lib
    [ "$uniform" = false ] || lane_uniform[$index]=true@    lane_uniform[$index]="$uniform"@proof:lanes-decl-covered@lib
 && [ "${lane_uniform[$index]}" = true ]; then@; then@proof:lanes-decl-gated@classify
elif [ "$record_covers" = lanes ]; then@elif false; then@record:pr-carried@classify
  pull_request | merge_group)@  pull_request | merge_group | push)@record:push@classify
ROWS
ROW_CLASSIFIER=""
require_rows "proof mutant" "$mutants"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
