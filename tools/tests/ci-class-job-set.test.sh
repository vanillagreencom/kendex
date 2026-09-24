#!/usr/bin/env bash
# What `.github/workflows/skill-tests.yml` runs is keyed to the change class,
# and the keying is in three places that have to agree: `tools/ci-job-set`
# turns a class into one line per lane, each job's `if:` reads one of those
# lines, and `tools/ci-aggregate` holds the required contexts open over the
# lanes a class stood down. A lane that no condition reads runs on every
# class; a lane a condition reads without a status function stands down on
# exactly the diffs nothing classified; an aggregate that waives a lane the
# class did not authorize turns a silent skip into a green required context.
# Each is a check nobody would see fail, which is why they are here.
#
# Four surfaces:
#   1. the selection — one row per class, asserting the whole lane line.
#      render and trivial select nothing, standard selects everything, and
#      micro and small select by what their paths can reach. The refusals
#      beside them: a class the table does not name, and a measured class
#      arriving with no changed path.
#   2. the job set — the jobs the workflow runs under each class, derived by
#      reading each job's own `if:` out of the workflow rather than from a
#      list here. Two must-fail arms plant the pre-patch shape: a lane
#      condition that reads no selection, and a matrix that narrows to no
#      platform.
#   3. the status functions — every condition reading a selection also reads
#      `needs.changes.result`, so a dead classifier runs the lane instead of
#      standing it down.
#   4. the aggregate — a lane the class authorized may skip; one it did not
#      is rejected, and so is a dead classifier.
set -euo pipefail

# A suite running from inside a git hook inherits GIT_DIR, GIT_COMMON_DIR,
# GIT_WORK_TREE and GIT_INDEX_FILE, which would resolve ROOT to the hook's
# repository instead of this one.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

ROOT="$(git rev-parse --show-toplevel)"
WORKFLOW="${WORKFLOW_UNDER_TEST:-$ROOT/.github/workflows/skill-tests.yml}"
JOB_SET="$ROOT/tools/ci-job-set"
AGGREGATE="$ROOT/tools/ci-aggregate"

mkdir -p "$ROOT/tmp"
TMP="$(mktemp -d "$ROOT/tmp/ci-class-job-set.XXXXXX")"
trap 'rm -rf -- "${TMP:?}"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
check() { # DESC EXPECTED ACTUAL
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi
}

# --- 1. The selection -------------------------------------------------------

# The lane names come out of the script under test, so a lane added there
# without a row below reaches the job-set section as an unread name.
LANES="$(sed -n 's/^LANES="\(.*\)"$/\1/p' "$JOB_SET" | tr ' ' '\n' | grep -c .)"
[ "$LANES" -gt 0 ] || { echo "no LANES line read from $JOB_SET" >&2; exit 1; }

selection() { # CLASS PATHS — the lane lines, blank-separated, or the refusal key
  local class="$1" paths="$2" out="$TMP/selection" status=0
  : >"$out"
  CHANGE_CLASS="$class" CHANGED_PATHS="$paths" GITHUB_OUTPUT="$out" \
    "$JOB_SET" 2>"$TMP/selection-err" || status=$?
  if [ "$status" -ne 0 ]; then
    printf 'exit=%s %s' "$status" \
      "$(sed -n 's/^ci-job-set: cause=//p' "$TMP/selection-err" | head -1)"
    return 0
  fi
  tr '\n' ' ' <"$out" | sed 's/ $//'
}

ALL_OFF="shell_shards=false macos_legs=false ui=false bot_instructions=false cargo_linux=false cargo_macos=false cargo_lint=false cargo_windows=false"
ALL_ON="shell_shards=true macos_legs=true ui=true bot_instructions=true cargo_linux=true cargo_macos=true cargo_lint=true cargo_windows=true"

# A `render` diff is generated files the classifier re-rendered to prove it.
check "render selects no gated lane" "$ALL_OFF" \
  "$(selection render '.agents/skills/orch/SKILL.md
.claude/skills/orch/SKILL.md')"
# A `trivial` diff is inside the docs path set and its line ceiling.
check "trivial selects no gated lane" "$ALL_OFF" \
  "$(selection trivial 'docs/architecture/overview.md')"
check "standard selects every gated lane" "$ALL_ON" \
  "$(selection standard 'crates/core/src/lib.rs')"
# One skill's prose: the shell suites read it, no shell or crate behaves
# differently on macOS because of it, and the Linux cargo lane lints the
# catalog it renders into.
check "micro over one skill's prose runs the shell suites, the catalog lint and nothing else" \
  "shell_shards=true macos_legs=false ui=false bot_instructions=true cargo_linux=true cargo_macos=false cargo_lint=false cargo_windows=false" \
  "$(selection micro 'skills/orch/SKILL.md
.agents/skills/orch/SKILL.md')"
# One crate: no shell suite reads it, and every cargo lane does.
check "small over one crate runs the cargo lanes and no shell suite" \
  "shell_shards=false macos_legs=true ui=false bot_instructions=true cargo_linux=true cargo_macos=true cargo_lint=true cargo_windows=true" \
  "$(selection small 'crates/cli/src/main.rs')"

check "a class the table does not name is refused, not absorbed" \
  "exit=2 unknown-class class=enormous" "$(selection enormous 'skills/orch/SKILL.md')"
check "a measured class with no changed path is refused" \
  "exit=2 class-without-paths class=micro" "$(selection micro '')"

# --- 2. The job set ---------------------------------------------------------
# Each job's gate is read out of the workflow: the lane its own job-level
# `if:` names, or none. An aggregate names a lane in its `env:` and is
# ungated, so only a line at the job's own indent is read.

job_lanes() { # WORKFLOW — one `JOB<tab>LANE|-` line per job
  awk '
    /^jobs:/ { in_jobs = 1; next }
    !in_jobs { next }
    /^  [A-Za-z0-9_-]+:/ {
      if (job != "") print job "\t" lane
      job = $1; sub(/:$/, "", job); lane = "-"; next
    }
    /^    if:/ {
      if (match($0, /needs\.changes\.outputs\.[a-z_]+/)) {
        lane = substr($0, RSTART + 22, RLENGTH - 22)
      }
      next
    }
    END { if (job != "") print job "\t" lane }
  ' "$1"
}

running() { # WORKFLOW SELECTION — the gated jobs that run, sorted and spaced
  local wf="$1" sel="$2" job lane out=""
  while IFS="$(printf '\t')" read -r job lane; do
    [ "$lane" != "-" ] || continue
    case " $sel " in
      *" $lane=true "*) out="$out$job
" ;;
    esac
  done < <(job_lanes "$wf")
  printf '%s' "$out" | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//'
}

# A lane is read at a job's own `if:` or, for the platform legs, in the
# matrix expression that drops them; those two lines are the whole gate
# surface, and a lane in neither runs on every class.
lanes_read() { # WORKFLOW
  grep -E "^    if:|os: \\$\{\{ fromJSON\(" "$1" |
    grep -oE 'needs\.changes\.outputs\.[a-z_]+' |
    sed 's/^needs\.changes\.outputs\.//' | LC_ALL=C sort -u
}

check "every lane the selection publishes is read by a gate" \
  "$LANES" "$(lanes_read "$WORKFLOW" | grep -c .)"

check "render runs no gated job" "" \
  "$(running "$WORKFLOW" "$(selection render '.agents/skills/orch/SKILL.md')")"
check "trivial runs no gated job" "" \
  "$(running "$WORKFLOW" "$(selection trivial 'docs/architecture/overview.md')")"
check "standard runs every gated job" \
  "bot-instructions cargo-check-windows cargo-lint cargo-linux cargo-macos cargo-tests-windows skill-suites-shard ui-tests" \
  "$(running "$WORKFLOW" "$(selection standard 'crates/core/src/lib.rs')")"
one_skill="$(selection micro 'skills/orch/SKILL.md
.agents/skills/orch/SKILL.md')"
check "micro over one skill runs the shell shards and the Linux cargo lane" \
  "bot-instructions cargo-linux skill-suites-shard" \
  "$(running "$WORKFLOW" "$one_skill")"
check "small over one crate runs the cargo lanes and not the shell shards" \
  "bot-instructions cargo-check-windows cargo-lint cargo-linux cargo-macos cargo-tests-windows" \
  "$(running "$WORKFLOW" "$(selection small 'crates/cli/src/main.rs')")"

# --- 2b. Must-fail: a lane condition that reads no selection -----------------
# The pre-patch shape of the macOS cargo lane: gated on the event alone. It
# then runs on the one-skill row, which is the full matrix the narrowing
# exists to avoid.
wf_ungated="$TMP/wf-lane-ungated.yml"
before="$(grep -cF "needs.changes.outputs.cargo_macos == 'true'" "$WORKFLOW")"
[ "$before" -eq 1 ] || { echo "the cargo_macos condition is no longer one line" >&2; exit 1; }
sed "s%!cancelled() && (github.event_name == 'push' || needs.changes.result != 'success' || needs.changes.outputs.cargo_macos == 'true')%!cancelled()%" \
  "$WORKFLOW" >"$wf_ungated"
[ "$(grep -cF "needs.changes.outputs.cargo_macos == 'true'" "$wf_ungated")" -eq 0 ] ||
  { echo "the must-fail edit matched nothing, so it plants no defect" >&2; exit 1; }
case " $(running "$wf_ungated" "$one_skill") " in
  *" cargo-macos "*)
    bad "must-fail: an ungated macOS cargo lane still reads as gated" ;;
  *)
    ok "must-fail: a lane condition reading no selection runs on the one-skill row" ;;
esac
check "must-fail: that same workflow has a lane no gate reads" \
  "$((LANES - 1))" "$(lanes_read "$wf_ungated" | grep -c .)"

# --- 3. The status functions ------------------------------------------------
# A condition reading a selection without `needs.changes.result` keeps the
# implicit success() and stands its lane down whenever the classifier died.
missing=""
while IFS= read -r line; do
  case "$line" in
    *'needs.changes.result'*) ;;
    *) missing="$missing$line
" ;;
  esac
done < <(grep -E '^    if:.*needs\.changes\.outputs\.' "$WORKFLOW")
check "every lane condition lifts its selection behind the classifier's result" \
  "" "$missing"
check "every lane condition carries a status function" "" \
  "$(grep -E '^    if:.*needs\.changes\.outputs\.' "$WORKFLOW" | grep -vF '!cancelled()' || true)"

# The macOS legs are dropped from the matrix rather than conditioned inside
# it, because a job-level `if:` cannot reach the `matrix` context.
os_line="$(grep -F 'os: ${{ fromJSON(' "$WORKFLOW")"
check "the platform matrix reads the macos_legs selection" "1" \
  "$(printf '%s\n' "$os_line" | grep -cF 'needs.changes.outputs.macos_legs')"
check "the platform matrix runs both legs when nothing classified" "1" \
  "$(printf '%s\n' "$os_line" | grep -cF "needs.changes.result != 'success'")"

# --- 3b. Must-fail: a platform matrix that cannot widen ----------------------
wf_onearm="$TMP/wf-matrix-fixed.yml"
awk '{
  if (index($0, "os: ${{ fromJSON(") > 0) {
    print "        os: [ubuntu-latest, macos-latest]"
    next
  }
  print
}' "$WORKFLOW" >"$wf_onearm"
[ "$(grep -cF 'os: ${{ fromJSON(' "$wf_onearm")" -eq 0 ] ||
  { echo "the must-fail edit left the matrix expression in place" >&2; exit 1; }
check "must-fail: a matrix that reads no selection is named" "0" \
  "$(grep -F 'os: ${{ fromJSON(' "$wf_onearm" | grep -cF 'needs.changes.outputs.macos_legs' || true)"

# --- 4. The aggregate -------------------------------------------------------

RESULTS='{"changes":{"result":"success"},"skill-suites-shard":{"result":"success"},"ui-tests":{"result":"skipped"},"bot-instructions":{"result":"success"}}'
aggregate_status() { # LANE...
  local status=0
  "$AGGREGATE" --results "$RESULTS" --classifier changes "$@" \
    >"$TMP/aggregate-out" 2>"$TMP/aggregate-err" || status=$?
  printf '%s' "$status"
}

check "a lane the class stood down may skip" "0" \
  "$(aggregate_status --lane 'true:skill-suites-shard' --lane 'false:ui-tests' \
    --lane 'true:bot-instructions')"
check "a lane the class selected may not skip" "1" \
  "$(aggregate_status --lane 'true:skill-suites-shard' --lane 'true:ui-tests' \
    --lane 'true:bot-instructions')"
check "no lane authorized means no skip is accepted" "1" \
  "$(aggregate_status --lane 'true:skill-suites-shard' --lane 'true:ui-tests')"

# A classifier that died publishes no selection, so every lane reads empty.
# That authorizes nothing and the helper names the classifier.
DEAD='{"changes":{"result":"failure"},"ui-tests":{"result":"skipped"}}'
dead_status=0
"$AGGREGATE" --results "$DEAD" --classifier changes --lane ':ui-tests' \
  >/dev/null 2>"$TMP/dead-err" || dead_status=$?
check "a dead classifier authorizes no skip" "1" "$dead_status"
check "and the rejection names the classifier, not a parse failure" "1" \
  "$(grep -c 'aggregate-needs: rejected classifier=changes waiver=false' "$TMP/dead-err")"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
