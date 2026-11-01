#!/usr/bin/env bash
# `.github/actions/change-class/classify` is the one reader of a change class
# every workflow gates on. It calls the installed lane producer with the
# two verdicts it reads: the class is what the shipped `change-class` printed,
# docs_only is what the shipped `harness-only --mode docs` printed, and the
# path families are a grouping of the path list that same call wrote. Beside
# it, lane_verdicts narrows lanes per lane, by the globs the LANES_FROM
# checkout's declaration gives it. The rows drive it through its CLASSIFIER
# input against a stub scripts root, so each output can be traced to the stub
# line that produced it.
#
# Five surfaces, the queue mark and the queue-only stand-down under the
# fifth:
#   1. the outputs: one diff per class, a docs-only diff at `standard` size
#      and a `trivial` one off the docs set, asserting every output line the
#      step writes, and the arguments each wrapped script was called with.
#   2. the must-fail inverses: a copy of classify that prints a class of its
#      own instead of reading the wrapped script's fails the render row, and
#      a copy of the decision lib with one lanes rule planted wrong fails
#      the row the rule decides. Each copy must also run to completion, so a copy that
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
#      classify's Environment header lists. A copy carrying a misspelled
#      `lanes` value is the control. A workflow reads the action, never the
#      script, and
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
#      to. One mutant copy per file that holds rules, classify or a
#      shipped lib it reads, must fail the row its rule decides. Beside them, the queue mark: a lane marked `:queue`
#      its own glob reaches stands down on a pull request where the
#      classifier answered queue_only=true and both the lanes-from
#      checkout and the judged head hold the installed reader of the mark,
#      runs where any of the three is missing, and stands down on no other
#      event, and the
#      classifier's queue_only line reaches the step's outputs. The
#      stand-down: on a pull request whose workflow passed
#      queue-only-default true and whose classifier's per-push line read
#      unset, every lane stands down only where both trees
#      hold the render's change-class that reads HARNESS_CI_PER_PUSH_REASON,
#      and runs with a named cause and one warning where either lacks it or
#      no lanes-from was given.
set -euo pipefail

unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

ROOT="$(git rev-parse --show-toplevel)"
CLASSIFY="$ROOT/.github/actions/change-class/classify"
LANES_LIB="$ROOT/skills/harness-ci/scripts/lib/ci-lanes.sh"
DECISION_LIB="$ROOT/skills/harness-ci/scripts/lib/change-class.sh"
ACTION="$ROOT/.github/actions/change-class/action.yml"

mkdir -p "$ROOT/tmp"
TMP="$(mktemp -d "$ROOT/tmp/action-suite.XXXXXX")" || { echo "suite: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP && ! -L $TMP ]] || { echo "suite: scratch=not-a-directory" >&2; exit 1; }
TMP="$(cd -- "$TMP" && pwd -P)" || { echo "suite: scratch=resolve-failed" >&2; exit 1; }
CONTROL_ROOT="$(mktemp -d)" || { echo "suite: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $CONTROL_ROOT && ! -L $CONTROL_ROOT ]] || { echo "suite: scratch=not-a-directory" >&2; exit 1; }
CONTROL_ROOT="$(cd -- "$CONTROL_ROOT" && pwd -P)" || { echo "suite: scratch=resolve-failed" >&2; exit 1; }
trap 'chmod -R u+rwX "${TMP:?}" 2>/dev/null; rm -rf -- "${TMP:?}" "${CONTROL_ROOT:?}"' EXIT

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
printf 'base-rev: %s\nhead-rev: %s\n' "$STUB_BASE_REV" "$STUB_HEAD_REV" >&2
[ "${STUB_CLASS_EXIT:-0}" -eq 0 ] || exit "$STUB_CLASS_EXIT"
output="${GITHUB_OUTPUT:-}"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output) output="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ -z "$output" ] || printf 'change_class=%s\n' "$STUB_CLASS" >>"$output"
if [ "${STUB_QUEUE_ABSENT:-false}" != true ]; then
  printf 'queue-only: queue_only=%s cause=%s\n' "${STUB_QUEUE:-false}" "${STUB_QUEUE_CAUSE:-stub}" >&2
  [ -z "${STUB_PER_PUSH:-}" ] || printf 'per-push: state=%s\n' "$STUB_PER_PUSH" >&2
  [ -z "$output" ] || printf 'queue_only=%s\n' "${STUB_QUEUE:-false}" >>"$output"
fi
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
cp "$DECISION_LIB" "$STUBS/skills/harness-ci/scripts/lib/change-class.sh"
mkdir -p "$TMP/no-lanes-lib"
cp -R "$STUBS/skills" "$TMP/no-lanes-lib/skills"
rm -- "${TMP:?}/no-lanes-lib/skills/harness-ci/scripts/lib/ci-lanes.sh"
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
# The stand-down's reader is the render's change-class that reads the
# per-push opt-back. JUDGED_STANDDOWN carries it; JUDGED_OLD_RENDER carries
# a change-class from before the opt-back. The `standdown` and
# `standdown-old` declaration roots hold the same two renders.
STANDDOWN_READER=.agents/skills/harness-ci/scripts/change-class
mkdir -p "$TMP/subject/$(dirname "$STANDDOWN_READER")"
printf '#!/usr/bin/env bash\n# an older render\n' >"$TMP/subject/$STANDDOWN_READER"
subject_git add .agents
subject_git commit -qm old-render
JUDGED_OLD_RENDER="$(subject_git rev-parse HEAD)"
printf '#!/usr/bin/env bash\n: "${HARNESS_CI_PER_PUSH_REASON:-}"\n' >"$TMP/subject/$STANDDOWN_READER"
subject_git add .agents
subject_git commit -qm standdown-render
JUDGED_STANDDOWN="$(subject_git rev-parse HEAD)"
for decl in standdown standdown-old; do
  declare_lanes "$decl" '# Lanes and the paths each reads.
check:event-uniform src/* Cargo.toml
mac:nightly macos/*
'
  mkdir -p "$TMP/decl/$decl/$(dirname "$STANDDOWN_READER")"
done
cp "$TMP/subject/$STANDDOWN_READER" "$TMP/decl/standdown/$STANDDOWN_READER"
printf '#!/usr/bin/env bash\n# an older render\n' >"$TMP/decl/standdown-old/$STANDDOWN_READER"

# Run a classify script with an explicit environment: the defaults below,
# then each NAME=VALUE argument, the later of two settings winning. The
# script is copied into a run directory first, unless it is run in place
# with `run_in_place`. Prints the exit status; stderr is kept in $TMP/err.
RUN_DIR="$TMP/run"
mkdir -p "$RUN_DIR"
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
    STUB_BASE_REV="$JUDGED_READER" STUB_HEAD_REV="$JUDGED_NO_READER" \
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
class_rows() {
  cat <<ROWS
render|render|false|.agents/skills/orch/SKILL.md .claude/skills/orch/SKILL.md|change_class=render queue_only=false docs_only=false changed_skills= changed_crates= changed_workflows= changed_paths=.agents/skills/orch/SKILL.md,.claude/skills/orch/SKILL.md lanes=false lanes_cause=render lane_verdicts=
trivial|trivial|true|docs/guide.md|change_class=trivial queue_only=false docs_only=true changed_skills= changed_crates= changed_workflows= changed_paths=docs/guide.md lanes=false lanes_cause=trivial lane_verdicts=
trivial-allowlisted|trivial|false|runtime/notes.txt|change_class=trivial queue_only=false docs_only=false changed_skills= changed_crates= changed_workflows= changed_paths=runtime/notes.txt lanes=false lanes_cause=trivial lane_verdicts=
micro|micro|false|skills/orch/SKILL.md .agents/skills/orch/SKILL.md|change_class=micro queue_only=false docs_only=false changed_skills=orch changed_crates= changed_workflows= changed_paths=skills/orch/SKILL.md,.agents/skills/orch/SKILL.md lanes=true lanes_cause=micro lane_verdicts=
small|small|false|crates/cli/src/main.rs crates/core/src/lib.rs|change_class=small queue_only=false docs_only=false changed_skills= changed_crates=cli core changed_workflows= changed_paths=crates/cli/src/main.rs,crates/core/src/lib.rs lanes=true lanes_cause=small lane_verdicts=
standard|standard|false|.github/workflows/ci.yml skills/github/SKILL.md crates/app/src/lib.rs|change_class=standard queue_only=false docs_only=false changed_skills=github changed_crates=app changed_workflows=ci.yml changed_paths=.github/workflows/ci.yml,skills/github/SKILL.md,crates/app/src/lib.rs lanes=true lanes_cause=standard lane_verdicts=
docs-only-standard|standard|true|docs/guide.md changelog.d/fixed/x.md README.md|change_class=standard queue_only=false docs_only=true changed_skills= changed_crates= changed_workflows= changed_paths=docs/guide.md,changelog.d/fixed/x.md,README.md lanes=false lanes_cause=docs-only lane_verdicts=
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
check "each wrapped script is called once, with the step's inputs" \
  "change-class --event pull_request --head h1 --repo $TMP/subject --base b0 --output /dev/null
harness-only --mode docs --event pull_request --head h1 --repo $TMP/subject --base b0 --paths-output PATHS" \
  "$(sed 's/--paths-output [^ ]*$/--paths-output PATHS/' "$LOG")"
run "$CLASSIFY" STUB_CLASS=micro STUB_PATHS=skills/orch/SKILL.md \
  LANES_FROM="$TMP/decl/good" >/dev/null
check "a declared lane asks harness-only for the paths outside the docs set" \
  "harness-only --mode docs --event pull_request --head h1 --repo $TMP/subject --base b0 --paths-output PATHS --outside-output OUTSIDE" \
  "$(sed -n 's/--paths-output [^ ]* --outside-output [^ ]*$/--paths-output PATHS --outside-output OUTSIDE/; s/^harness-only /harness-only /p' "$LOG")"
run "$CLASSIFY" STUB_CLASS=standard BASE= >/dev/null
check "an empty base is not passed as a flag" \
  "change-class --event pull_request --head h1 --repo $TMP/subject --output /dev/null" \
  "$(sed -n 's/^change-class /change-class /p' "$LOG")"

# --- 2. Must-fail: a classify that decides the class itself ------------------
# The copy keeps every line but the one that reads the wrapped script, and
# prints `standard` there instead. The render row, whose stub says render,
# must see the difference.
mutant="$CONTROL_ROOT/classify"
needle='"$SCRIPTS/change-class" "${args[@]}" --output /dev/null'
[ "$(grep -cF -- "$needle" "$CLASSIFY")" -eq 1 ] ||
  { echo "the change-class call is no longer one line in $CLASSIFY" >&2; exit 1; }
NEEDLE="$needle" awk '
  { i = index($0, ENVIRON["NEEDLE"]) }
  i > 0 {
    $0 = substr($0, 1, i - 1) "printf '"'"'change_class=standard\\n'"'"'" substr($0, i + length(ENVIRON["NEEDLE"]))
  }
  { print }
' "$CLASSIFY" >"$mutant"
! cmp -s "$CLASSIFY" "$mutant" || { echo "the mutant changed nothing" >&2; exit 1; }
status="$(run "$mutant" STUB_CLASS=render STUB_PATHS=.agents/skills/orch/SKILL.md)"
check "must-fail: a classify that decides its own class changes the render row" \
  '0 change_class=standard' "$status $(sed -n '/^change_class=/p' "$OUT")"

# A rule planted wrong in a copy of TARGET, `classify` or `lib`, every other
# line kept: a classify copy at $mutant, or a lanes lib copy in a stubs root
# of its own, which ROW_CLASSIFIER then names for the runs after it. Sets
# PLANTED to the classify to run. Called outside a substitution, so the
# root it names reaches the runs.
MUTANT_STUBS="$CONTROL_ROOT/mutant-stubs"
PLANTED=""
plant() { # TARGET NEEDLE REPLACEMENT
  local file copy
  case "$1" in
    classify)
      if [ "$(grep -cF -- "$2" "$CLASSIFY")" -eq 0 ]; then
        file="$DECISION_LIB" copy="$MUTANT_STUBS/skills/harness-ci/scripts/lib/change-class.sh"
        rm -rf -- "${MUTANT_STUBS:?}"
        cp -R "$STUBS" "$MUTANT_STUBS"
        ROW_CLASSIFIER="$MUTANT_STUBS"
      else
        file="$CLASSIFY" copy="$mutant" ROW_CLASSIFIER=""
      fi ;;
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
  [ "$file" != "$CLASSIFY" ] || PLANTED="$mutant"
}

# A lanes rule planted wrong, every other line kept. The copy must run to
# completion and fail the row the rule decides.
# NEEDLE@REPLACEMENT@ROW THE RULE DECIDES, split on `@` because a rule spells
# the shell's `||`.
mutants=0
while IFS='@' read -r needle replacement row; do
  mutants=$((mutants + 1))
  plant classify "$needle" "$replacement"
  check "must-fail: '$needle' planted as '$replacement' fails the $row row" \
    no "$(row_holds "$PLANTED" "$row")"
done <<'ROWS'
[ "$class" = render ] || @@render
ROWS
require_rows "lanes mutant" "$mutants"
ROW_CLASSIFIER=""

# The action can update before its separately checked-out default branch.
# A classifier without the shared producer grants no lane skip.
LEGACY_STUBS="$TMP/legacy-stubs"
cp -R "$STUBS" "$LEGACY_STUBS"
printf '#!/usr/bin/env bash\nset -euo pipefail\n' \
  >"$LEGACY_STUBS/skills/harness-ci/scripts/lib/change-class.sh"
status="$(run "$CLASSIFY" CLASSIFIER="$LEGACY_STUBS" STUB_CLASS=render STUB_PATHS=.agents/skills/orch/SKILL.md)"
check 'an older classifier runs every lane' \
  '0 lanes=true lanes_cause=lane-producer-unavailable lane_verdicts=' \
  "$status $(outputs | tr ' ' '\n' | grep -E '^(lanes|lanes_cause|lane_verdicts)=' | tr '\n' ' ' | sed 's/ $//')"

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
  actual="$(refusal)"
  check "refusal $cause: key" "$cause" "$actual"
  check "refusal $cause: no outputs" "" "$(cat "$OUT")"
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
lanes-reader-unreadable root=$TMP/no-lanes-lib|LANES_FROM=$TMP/decl/good CLASSIFIER=$TMP/no-lanes-lib
invalid-input input=queue-only-default value=yes|QUEUE_ONLY_DEFAULT=yes
ROWS
require_rows refusal "$refusal_rows"

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
# The classify outputs the action's own steps under `runs:` read, sorted.
steps_read() { # ACTION_YML
  awk '/^runs:/ { on = 1 } on' "$1" | grep -oE 'steps\.classify\.outputs\.[a-z_]+' |
    sed 's/.*\.//' | LC_ALL=C sort -u
}
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

# A lane rule planted wrong, every other line kept. The copy must run to
# completion and fail the row the rule decides.
# NEEDLE@REPLACEMENT@ROW@TARGET, split on `@` because a rule spells the
# shell's `&&`; TARGET is the file holding the rule, as plant takes it.
mutants=0
while IFS='@' read -r needle replacement row target; do
  mutants=$((mutants + 1))
  plant "$target" "$needle" "$replacement"
  check "must-fail: '$needle' planted as '$replacement' fails the $row row" \
    no "$(lane_row_holds "$PLANTED" "$row")"
done <<'ROWS'
    line="${line%%#*}"@    line="$line"@one-lane@lib
ROWS
ROW_CLASSIFIER=""
require_rows "lane mutant" "$mutants"

# --- 5b. Declaration changes ------------------------------------------------

declare_lanes added-glob 'check:event-uniform src/* Cargo.toml tests/*
tmux:event-uniform tmux/* fixtures/*
docs-build docs/*
'
declare_lanes reordered 'docs-build docs/*
tmux:event-uniform tmux/* tmux/*
check tests/* Cargo.toml src/*
check:event-uniform src/*
'
declare_lanes removed-glob 'check:event-uniform src/* Cargo.toml tests/*
tmux:event-uniform fixtures/*
docs-build docs/*
'
declare_lanes added-lane 'check:event-uniform src/* Cargo.toml tests/*
tmux:event-uniform tmux/*
docs-build docs/*
extra src/*
'
declare_lanes removed-lane 'check:event-uniform src/* Cargo.toml tests/*
docs-build docs/*
'
declare_lanes renamed-lane 'check:event-uniform src/* Cargo.toml tests/*
terminal:event-uniform tmux/*
docs-build docs/*
'
declare_lanes queue-added 'check:event-uniform src/* Cargo.toml tests/*
tmux:event-uniform:queue tmux/*
docs-build docs/*
'
declare_lanes queue-glob-added 'check:event-uniform src/* Cargo.toml tests/*
tmux:event-uniform:queue tmux/* fixtures/*
docs-build docs/*
'
declare_lanes nightly-added 'check:event-uniform src/* Cargo.toml tests/*
tmux:nightly tmux/*
docs-build docs/*
'
declare_lanes nightly-glob-added 'check:event-uniform src/* Cargo.toml tests/*
tmux:nightly tmux/* fixtures/*
docs-build docs/*
'
declare_lanes uniform-only 'check src/* Cargo.toml tests/*
tmux tmux/*
docs-build docs/*
'

# GitHub supplies HEAD as a commit. Its declaration must be read there,
# even where the checkout holds another declaration or a merge tree.
DELTA_REPO="$TMP/delta-repo"
mkdir -p "$DELTA_REPO/.github"
mkdir -p "$DELTA_REPO/.agents/skills/harness-ci/scripts/lib" "$TMP/decl/queue-added/.agents/skills/harness-ci/scripts/lib"
cp "$LANES_LIB" "$DELTA_REPO/.agents/skills/harness-ci/scripts/lib/ci-lanes.sh"
cp "$LANES_LIB" "$TMP/decl/queue-added/.agents/skills/harness-ci/scripts/lib/ci-lanes.sh"
delta_git() { git -C "$DELTA_REPO" -c user.name=suite -c user.email=suite@example.invalid "$@"; }
delta_git init -q
delta_git config gc.auto 0
delta_git config maintenance.auto false
for decl in good added-glob reordered removed-glob added-lane removed-lane renamed-lane queue-added queue-glob-added nightly-added nightly-glob-added uniform-only bad-name unreadable absent; do
  [ ! -e "$DELTA_REPO/.github/ci-lanes.conf" ] || rm -r -- "$DELTA_REPO/.github/ci-lanes.conf"
  case "$decl" in
    absent) ;;
    unreadable)
      mkdir "$DELTA_REPO/.github/ci-lanes.conf"
      : >"$DELTA_REPO/.github/ci-lanes.conf/member" ;;
    *) cp "$TMP/decl/$decl/.github/ci-lanes.conf" "$DELTA_REPO/.github/ci-lanes.conf" ;;
  esac
  delta_git add -A
  delta_git commit --allow-empty -qm "$decl"
  delta_git rev-parse HEAD >"$TMP/decl/$decl/head"
done

# NAME|BASE DECLARATION|HEAD DECLARATION|CHANGED PATHS|EXPECTED VERDICTS
# All these paths are outside the docs set. The action's workflow and
# aggregate consume lane_verdicts; expected values are independent of globs.
delta_rows() {
  cat <<'ROWS'
added-glob|good|added-glob|.github/ci-lanes.conf|lane_verdicts=lane_check=false,lane_tmux=true,lane_docs-build=false
removed-glob|added-glob|good|.github/ci-lanes.conf|lane_verdicts=lane_check=false,lane_tmux=true,lane_docs-build=false
reordered-claims|good|reordered|.github/ci-lanes.conf|lane_verdicts=lane_check=false,lane_tmux=false,lane_docs-build=false
uniform-only|good|uniform-only|.github/ci-lanes.conf|lane_verdicts=lane_check=false,lane_tmux=false,lane_docs-build=false
added-lane|good|added-lane|.github/ci-lanes.conf|lane_verdicts=lane_check=false,lane_tmux=false,lane_docs-build=false,lane_extra=true
removed-lane|good|removed-lane|.github/ci-lanes.conf|lane_verdicts=lane_check=false,lane_tmux=true,lane_docs-build=false
renamed-lane|good|renamed-lane|.github/ci-lanes.conf|lane_verdicts=lane_check=false,lane_tmux=true,lane_docs-build=false,lane_terminal=true
nightly-added|good|nightly-added|.github/ci-lanes.conf|lane_verdicts=lane_check=false,lane_tmux=true,lane_docs-build=false
nightly-glob-changed|nightly-added|nightly-glob-added|.github/ci-lanes.conf|lane_verdicts=lane_check=false,lane_tmux=true,lane_docs-build=false
queue-added|good|queue-added|.github/ci-lanes.conf|lane_verdicts=lane_check=false,lane_tmux=true,lane_docs-build=false
queue-removed|queue-added|good|.github/ci-lanes.conf|lane_verdicts=lane_check=false,lane_tmux=true,lane_docs-build=false
queue-glob-only|queue-added|queue-glob-added|.github/ci-lanes.conf|lane_verdicts=lane_check=false,lane_tmux=true,lane_docs-build=false
queue-claim-after-declaration|queue-added|queue-glob-added|.github/ci-lanes.conf tmux/tmux.conf|lane_verdicts=lane_check=false,lane_tmux=false,lane_docs-build=false
queue-claim-before-declaration|queue-added|queue-glob-added|tmux/tmux.conf .github/ci-lanes.conf|lane_verdicts=lane_check=false,lane_tmux=false,lane_docs-build=false
mixed-delete-claim-first|queue-added|absent|tmux/tmux.conf .github/ci-lanes.conf|lane_verdicts=lane_check=true,lane_tmux=true,lane_docs-build=true
malformed-head|queue-added|bad-name|.github/ci-lanes.conf tmux/tmux.conf|lane_verdicts=lane_check=true,lane_tmux=true,lane_docs-build=true
missing-head|queue-added|absent|.github/ci-lanes.conf tmux/tmux.conf|lane_verdicts=lane_check=true,lane_tmux=true,lane_docs-build=true
unreadable-head|queue-added|unreadable|.github/ci-lanes.conf tmux/tmux.conf|lane_verdicts=lane_check=true,lane_tmux=true,lane_docs-build=true
unreadable-revision|queue-added|invalid|tmux/tmux.conf .github/ci-lanes.conf|lane_verdicts=lane_check=true,lane_tmux=true,lane_docs-build=true
malformed-base|bad-name|good|.github/ci-lanes.conf|lane_verdicts=
missing-base|absent|good|.github/ci-lanes.conf|lane_verdicts=
unreadable-base|unreadable|good|.github/ci-lanes.conf|lane_verdicts=
branch-only-claim|good|added-glob|.github/ci-lanes.conf fixtures/new.rs|lane_verdicts=lane_check=true,lane_tmux=true,lane_docs-build=true
retained-base-claim|good|removed-glob|.github/ci-lanes.conf tmux/tmux.conf|lane_verdicts=lane_check=false,lane_tmux=true,lane_docs-build=false
existing-base-claim|good|added-glob|.github/ci-lanes.conf src/new.rs|lane_verdicts=lane_check=true,lane_tmux=true,lane_docs-build=false
path-before-declaration|good|added-glob|src/new.rs .github/ci-lanes.conf|lane_verdicts=lane_check=true,lane_tmux=true,lane_docs-build=false
ROWS
}
delta_answer() { # SCRIPT ROW
  local line name decl head_decl paths expected head
  line="$(delta_rows | grep "^$2|")" || { echo "no declaration row named $2" >&2; exit 1; }
  IFS='|' read -r name decl head_decl paths expected <<<"$line"
  head=invalid
  [ "$head_decl" = invalid ] || head="$(cat "$TMP/decl/$head_decl/head")"
  if [ "$(run "$1" REPO="$DELTA_REPO" HEAD="$head" LANES_FROM="$TMP/decl/$decl" \
    STUB_QUEUE=true STUB_PATHS="$paths" STUB_OUTSIDE="$paths")" != 0 ]; then
    echo crashed
    return 0
  fi
  outputs | tr ' ' '\n' | grep '^lane_verdicts='
}
rows=0
while IFS='|' read -r name decl head_decl paths expected; do
  rows=$((rows + 1))
  check "declaration row $name" "$expected" "$(delta_answer "$CLASSIFY" "$name")"
done < <(delta_rows)
require_rows declaration "$rows"

# Bypassing this one path's comparison restores the previous selector.
# The regression then observes all lanes instead of the changed lane alone.
plant classify '    if [ "$path" = .github/ci-lanes.conf ]; then' '    if false; then'
check "must-fail: the previous selector runs every lane for one added glob" \
  'lane_verdicts=lane_check=true,lane_tmux=true,lane_docs-build=true' "$(delta_answer "$PLANTED" added-glob)"
mutants=0
while IFS='@' read -r needle replacement row; do
  mutants=$((mutants + 1))
  plant classify "$needle" "$replacement"
  expected="$(delta_rows | grep "^$row|" | cut -d'|' -f5)"
  answer="$(delta_answer "$PLANTED" "$row")"
  if [ "$answer" != crashed ] && [ "$answer" != "$expected" ]; then
    ok "must-fail: declaration rule rejects $row"
  else
    bad "must-fail: declaration rule survived or crashed for $row"
  fi
done <<'ROWS'
[ "${claims[$other]}" != "$claim" ]@[ "${claims[$other]}" = "$claim" ]@added-glob
[ "${queues[$other]}" != "${lane_queue[$index]}" ]@false@queue-added
 || [ "${nightlies[$other]}" != "${lane_nightly[$index]}" ]; then@; then@nightly-added
    elif [ "${lane_changed[$index]}" = true ]; then@    elif false; then@nightly-glob-changed
[ "$found" = true ] || printf@[ "$found" = false ] || printf@removed-lane
        declaration_comparison=unreadable@        declaration_comparison=not-needed@malformed-head
  elif [ "$declaration_comparison" = unreadable ]; then@  elif false; then@missing-head
            lane_count=$((lane_count + 1))@            :@added-lane
 && [ -n "$hit" ]; then@; then@queue-removed
          lane_changed[$index]=true@          lane_hits[$index]="" lane_changed[$index]=true@queue-claim-before-declaration
        [ -n "${lane_hits[$index]}" ] ||@        [ "${lane_changed[$index]}" = true ] ||@queue-claim-after-declaration
          lane_changed[$index]=true@          lane_changed[$index]=false@added-glob
      if ci_lanes_claims "$index" "$path"; then@      if ci_lanes_claims "$index" "$path" || { [ "$path" = fixtures/new.rs ] && [ "$index" -eq 1 ]; }; then@branch-only-claim
ROWS
require_rows "declaration mutant" "$mutants"

# --- 5c. The queue mark ------------------------------------------------------

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
rows=0
while IFS='|' read -r name queue absent expected; do
  rows=$((rows + 1))
  status="$(run "$CLASSIFY" STUB_QUEUE="$queue" STUB_QUEUE_ABSENT="$absent" STUB_PATHS=src/main.rs)"
  check "$name: queue metadata handoff exits 0" 0 "$status"
  check "$name: the step forwards the documented queue record" "$expected" \
    "$(sed -n '/^queue_only=/p' "$OUT")"
done <<'ROWS'
queue required|true|false|queue_only=true
queue not required|false|false|queue_only=false
classifier predates queue metadata|false|true|
ROWS
require_rows queue-metadata "$rows"

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
  elif [ "$EVENT" = pull_request ] && [ "${lane_queue[$index]}" = true ] && [ -n "$hit" ]; then@  elif false; then@pr-deferred@classify
[ "$EVENT" = pull_request ] && [ "${lane_queue[$index]}"@true && [ "${lane_queue[$index]}"@merge-group@classify
 && [ -n "$hit" ]; then@; then@pr-unclaimed@classify
  if [ ! -f "$lanes_root/$1" ] ||@  if false ||@pr-reader-absent@classify
  if ! git -C "$REPO" cat-file blob "$HEAD:$1" >"${work:?}/judged-reader" 2>/dev/null ||@  if false ||@pr-judged-reader-absent@classify
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

# --- 5d. The queue-only stand-down and the nightly run ----------------------

# On pull_request and push, every lane stands down only where the workflow
# passed queue-only-default true, the classifier's per-push line reads
# unset, the repository's default mode, and the lanes-from checkout and the
# judged head both hold the render's change-class reading
# HARNESS_CI_PER_PUSH_REASON. A workflow that passes no input, a per-push
# line reading set or unread, and an absent queue record run the lanes.
# Either tree without the reader
# runs them and names the tree on one warning; no lanes-from runs them and
# names that gap instead. The schedule and workflow_dispatch runs run every
# lane. A `:nightly` lane runs off the full run only on its own glob, a
# declaration change or a diff whose paths were not read, whatever path no
# lane claims. Which queue-only cause the classifier names decides nothing
# here: the stub names none, and lanes-output.test.sh holds the real
# classifier's queue-path change to the stand-down.
# ROW|EVENT|DECLARATION (`none`: no lanes-from)|JUDGED HEAD|DEFAULT INPUT|
# QUEUE ONLY (`absent` prints no queue-only line)|PER PUSH (`absent` prints
# no per-push line)|PATHS|EXPECTED: lanes, lanes_cause, lane_verdicts and
# the first word of the stand-down warning.
standdown_rows() {
  cat <<'ROWS'
pr-stood-down|pull_request|standdown|standdown|true|true|unset|src/main.rs|lanes=false lanes_cause=queue-only lane_verdicts=lane_check=false,lane_mac=false warn=
push-stood-down|push|standdown|standdown|true|true|unset|src/main.rs|lanes=false lanes_cause=queue-only lane_verdicts=lane_check=false,lane_mac=false warn=
merge-group|merge_group|standdown|standdown|true|true|unset|src/main.rs|lanes=true lanes_cause=standard lane_verdicts=lane_check=true,lane_mac=false warn=
pr-copied-template|pull_request|standdown|standdown||true|unset|src/main.rs|lanes=true lanes_cause=standard lane_verdicts=lane_check=true,lane_mac=false warn=
pr-opted-back|pull_request|standdown|standdown|true|false|set|src/main.rs|lanes=true lanes_cause=standard lane_verdicts=lane_check=true,lane_mac=false warn=
pr-opted-back-queue-only|pull_request|standdown|standdown|true|true|set|src/main.rs|lanes=true lanes_cause=standard lane_verdicts=lane_check=true,lane_mac=false warn=
pr-settings-unread|pull_request|standdown|standdown|true|true|unread|src/main.rs|lanes=true lanes_cause=standard lane_verdicts=lane_check=true,lane_mac=false warn=
pr-queue-only-absent|pull_request|standdown|standdown|true|absent|absent|src/main.rs|lanes=true lanes_cause=standard lane_verdicts=lane_check=true,lane_mac=false warn=
pr-lanes-from-unset|pull_request|none|standdown|true|true|unset|src/main.rs|lanes=true lanes_cause=queue-only-lanes-from-unset lane_verdicts= warn=lanes-from=unset
lanes-from-old-render|pull_request|standdown-old|standdown|true|true|unset|src/main.rs|lanes=true lanes_cause=queue-only-reader-absent lane_verdicts=lane_check=true,lane_mac=false warn=lanes-from
lanes-from-no-render|pull_request|good|standdown|true|true|unset|src/main.rs|lanes=true lanes_cause=queue-only-reader-absent lane_verdicts=lane_check=true,lane_tmux=false,lane_docs-build=false warn=lanes-from
judged-old-render|pull_request|standdown|old|true|true|unset|src/main.rs|lanes=true lanes_cause=queue-only-reader-absent lane_verdicts=lane_check=true,lane_mac=false warn=judged
judged-no-render|pull_request|standdown|no-reader|true|true|unset|src/main.rs|lanes=true lanes_cause=queue-only-reader-absent lane_verdicts=lane_check=true,lane_mac=false warn=judged
both-old-render|pull_request|standdown-old|old|true|true|unset|src/main.rs|lanes=true lanes_cause=queue-only-reader-absent lane_verdicts=lane_check=true,lane_mac=false warn=lanes-from,judged
schedule|schedule|standdown|standdown|true|true|unset|src/main.rs|lanes=true lanes_cause=full-run lane_verdicts=lane_check=true,lane_mac=true warn=
dispatch|workflow_dispatch|standdown|standdown|true|true|unset||lanes=true lanes_cause=full-run lane_verdicts=lane_check=true,lane_mac=true warn=
nightly-unclaimed|merge_group|standdown|standdown|true|true|unset|Makefile|lanes=true lanes_cause=standard lane_verdicts=lane_check=true,lane_mac=false warn=
nightly-no-paths|merge_group|standdown|standdown|true|true|unset||lanes=true lanes_cause=standard lane_verdicts=lane_check=true,lane_mac=true warn=
nightly-claimed|merge_group|standdown|standdown|true|true|unset|macos/run.sh|lanes=true lanes_cause=standard lane_verdicts=lane_check=false,lane_mac=true warn=
ROWS
}
standdown_answer() { # SCRIPT ROW — the row's answer, or `crashed`
  local line event decl judged default queue per_push paths head lanes_from="" absent=false
  line="$(standdown_rows | grep -m1 "^$2|")" || { echo "no stand-down row named $2" >&2; exit 1; }
  IFS='|' read -r _ event decl judged default queue per_push paths _ <<<"$line"
  case "$judged" in
    standdown) head="$JUDGED_STANDDOWN" ;;
    old) head="$JUDGED_OLD_RENDER" ;;
    no-reader) head="$JUDGED_NO_READER" ;;
    *) echo "stand-down row $2 names no judged head: $judged" >&2; exit 1 ;;
  esac
  [ "$decl" = none ] || lanes_from="$TMP/decl/$decl"
  case "$queue" in
    absent) queue=false absent=true ;;
  esac
  [ "$per_push" != absent ] || per_push=""
  if [ "$(run "$1" EVENT="$event" HEAD="$head" LANES_FROM="$lanes_from" QUEUE_ONLY_DEFAULT="$default" \
    STUB_QUEUE="$queue" STUB_QUEUE_ABSENT="$absent" STUB_PER_PUSH="$per_push" \
    STUB_PATHS="$paths" STUB_OUTSIDE="$paths")" != 0 ]; then
    echo crashed
    return 0
  fi
  printf '%s warn=%s\n' \
    "$(outputs | tr ' ' '\n' | grep -E '^(lanes|lanes_cause|lane_verdicts)=' | tr '\n' ' ' | sed 's/ $//')" \
    "$(sed -n 's/^::warning title=lanes not stood down::\([^ ]*\) .*/\1/p' "$TMP/stdout" | tr '\n' ' ' | sed 's/ $//')"
}
rows=0
while IFS='|' read -r name _ _ _ _ _ _ _ expected; do
  rows=$((rows + 1))
  check "stand-down row $name" "$expected" "$(standdown_answer "$CLASSIFY" "$name")"
done < <(standdown_rows)
require_rows standdown "$rows"

# One copy per stand-down rule, the rule planted wrong and every other line
# kept, as the queue mutants above.
mutants=0
while IFS='@' read -r needle replacement row target; do
  mutants=$((mutants + 1))
  plant "$target" "$needle" "$replacement"
  expected="$(standdown_rows | grep -m1 "^$row|" | cut -d'|' -f9)"
  answer="$(standdown_answer "$PLANTED" "$row")"
  if [ "$answer" != crashed ] && [ "$answer" != "$expected" ]; then
    ok "must-fail: '$needle' planted as '$replacement' fails the $row row"
  else
    bad "must-fail: '$needle' planted as '$replacement' survived or crashed the $row row"
  fi
done <<'ROWS'
        if [ -z "$standdown_missing" ]; then@        if true; then@lanes-from-old-render@classify
[ "$queue_default" = true ] && @@pr-copied-template@classify
 && [ "$per_push" = unset ]; then@; then@pr-opted-back-queue-only@classify
 && [ "$per_push" = unset ]; then@ && [ "$per_push" != set ]; then@pr-settings-unread@classify
      if [ -z "$lanes_from" ]; then@      if false; then@pr-lanes-from-unset@classify
  '' | false) queue_default=false ;;@  '' | false) queue_default=true ;;@pr-copied-template@classify
per_push="$(sed -n 's/^per-push: state=//p'@per_push="$(sed -n 's/^per-push: state=x//p'@pr-stood-down@classify
    pull_request | push)@    pull_request | push | merge_group)@merge-group@classify
render_reader_missing "$per_push_reader" HARNESS_CI_PER_PUSH_REASON)@render_reader_missing "$per_push_reader")@judged-old-render@classify
if [ "$EVENT" = schedule ] || [ "$EVENT" = workflow_dispatch ]; then@if [ "$EVENT" = schedule ]; then@dispatch@classify
  if [ "$lanes_cause" = full-run ]; then@  if false; then@schedule@classify
  elif [ "${lane_nightly[$index]}" = true ]; then@  elif false; then@nightly-unclaimed@classify
      lane_values[$index]=false lane_causes[$index]="cause=nightly-unreached"@      lane_values[$index]=true lane_causes[$index]="cause=nightly-unreached"@nightly-unclaimed@classify
  elif [ "$no_changed_paths" = true ]; then@  elif [ "$no_changed_paths" = true ] && [ "${lane_nightly[$index]}" != true ]; then@nightly-no-paths@classify
*:nightly) nightly=true name=@*:nightly) nightly=false name=@nightly-unclaimed@lib
ROWS
ROW_CLASSIFIER=""
require_rows "stand-down mutant" "$mutants"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
