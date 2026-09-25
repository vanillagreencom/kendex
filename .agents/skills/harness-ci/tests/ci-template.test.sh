#!/usr/bin/env bash
# templates/ci.yml is the workflow every repository copies for its one
# required `CI` context, so what it runs is evaluated rather than trusted:
# the job conditions are read out of the file and evaluated per event and
# class, and the aggregate step's waiver is handed to the real
# aggregate-needs.
#
# Surfaces:
#   1. the names: one job named CI, the classifier named `Classify the diff`,
#      both gated events under `on:`, and CI needing every other job.
#   2. the job set: per event and class, which lanes run. A `render` or
#      `trivial` merge group runs none, every other class runs them all, a
#      merge group runs what its pull request ran, and a dead classifier runs
#      every lane.
#   3. the aggregate: the waiver the template computes, fed to
#      aggregate-needs, accepts a skipped lane only on the classes that stood
#      the lanes down, and CI runs on both events whatever its needs did.
#   4. the copy: every expression closes on its line and every script path
#      it names is one this package ships.
# Must-fail arms plant a lane condition without its status function, a
# `lanes` output that forgets a class, CI without always(), and a template
# without merge_group.
set -euo pipefail
# shellcheck source=lib/sandbox.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/sandbox.sh"
# shellcheck source=lib/workflow.sh
. "$TEST_DIR/lib/workflow.sh"

TEMPLATE="${CI_TEMPLATE_UNDER_TEST:-$TEST_DIR/../templates/ci.yml}"
GH_EVAL="$TEST_DIR/lib/gh-eval.py"
AGGREGATE_NEEDS="$TEST_DIR/../scripts/aggregate-needs"
[ -f "$TEMPLATE" ] || { echo "missing $TEMPLATE" >&2; exit 1; }

CLASSES="render trivial micro small standard"

# The value an expression in the changes job's `outputs:` evaluates to, for
# a classify step that printed CLASS.
output_value() { # TEMPLATE OUTPUT CLASS
  local expr
  expr="$(awk -v out="$2" '
    /^  changes:/ { in_job = 1; next }
    in_job && /^  [A-Za-z0-9_-]+:/ { in_job = 0 }
    in_job && /^    outputs:/ { in_outputs = 1; next }
    in_outputs && !/^      / { in_outputs = 0 }
    in_outputs && index($0, "      " out ": ${{ ") == 1 {
      sub(/^[^{]*\$\{\{ /, ""); sub(/ \}\}$/, ""); print
    }
  ' "$1")"
  [ -n "$expr" ] || { printf 'no-output=%s' "$2"; return 0; }
  python3 "$GH_EVAL" value \
    "$(jq -cn --arg c "$3" '{steps: {classify: {outputs: {change_class: $c}}}}')" "$expr" | tr -d '"'
}

# The lanes: every job reading the changes job but CI.
lane_jobs() { # TEMPLATE
  local ci
  ci="$(jobs_named "$1" CI)"
  job_needs "$1" | awk -F '\t' -v ci="$ci" '$1 != ci && $2 ~ /(^|,)changes(,|$)/ { print $1 }' | LC_ALL=C sort
}

# The lanes that run on EVENT for a classifier at RESULT that printed CLASS.
running() { # TEMPLATE EVENT RESULT CLASS — sorted and spaced, or `none`
  local wf="$1" outputs='{}' job ran
  if [ "$3" = success ]; then
    outputs="$(jq -cn --arg c "$4" --arg l "$(output_value "$wf" lanes "$4")" '{change_class: $c, lanes: $l}')"
  fi
  lane_jobs "$wf" >"$SANDBOX/lanes"
  ran="$(job_needs "$wf" | while IFS="$(printf '\t')" read -r job needs; do
    grep -qxF -- "$job" "$SANDBOX/lanes" || continue
    printf '%s\t%s\t%s\n' "$job" "$needs" "$(job_ifs "$wf" | awk -F '\t' -v j="$job" '$1 == j { print $2 }')"
  done | python3 "$GH_EVAL" jobs \
    "$(jq -cn --arg e "$2" --arg r "$3" --argjson o "$outputs" '{github: {event_name: $e}, needs: {changes: {result: $r, outputs: $o}}}')" |
    LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"
  printf '%s' "${ran:-none}"
}

# Whether CI runs on EVENT with every job it needs at RESULT.
ci_runs() { # TEMPLATE EVENT RESULT — yes or no
  local wf="$1" ci needs expr ctx
  ci="$(jobs_named "$wf" CI)"
  needs="$(job_needs "$wf" | awk -F '\t' -v j="$ci" '$1 == j { print $2 }')"
  expr="$(job_ifs "$wf" | awk -F '\t' -v j="$ci" '$1 == j { print $2 }')"
  ctx="$(jq -cn --arg e "$2" --arg r "$3" --arg n "$needs" \
    '{github: {event_name: $e}, needs: ($n | split(",") | map({key: ., value: {result: $r}}) | from_entries)}')"
  if [ -n "$(printf '%s\t%s\t%s\n' "$ci" "$needs" "$expr" | python3 "$GH_EVAL" jobs "$ctx")" ]; then
    echo yes
  else
    echo no
  fi
}

# A copy of the template with FROM replaced once by TO, or the suite stops.
plant() { # FROM TO OUT
  [ "$(grep -cF -- "$1" "$TEMPLATE")" -eq 1 ] ||
    { echo "the planted text is no longer one line: $1" >&2; exit 1; }
  FROM="$1" TO="$2" awk '
    { i = index($0, ENVIRON["FROM"]) }
    i > 0 { $0 = substr($0, 1, i - 1) ENVIRON["TO"] substr($0, i + length(ENVIRON["FROM"])) }
    { print }
  ' "$TEMPLATE" >"$3"
  ! cmp -s "$TEMPLATE" "$3" || { echo "the planted edit changed nothing: $1" >&2; exit 1; }
}

# --- 1. The names -----------------------------------------------------------

CI_JOB="$(jobs_named "$TEMPLATE" CI | tr '\n' ' ' | sed 's/ $//')"
assert_eq "one job is named CI" "ci" "$CI_JOB"
assert_eq "the classifier is named as every repository names it" "changes" \
  "$(jobs_named "$TEMPLATE" 'Classify the diff' | tr '\n' ' ' | sed 's/ $//')"
assert_eq "the template runs on both gated events and no other" "merge_group pull_request" \
  "$(triggers "$TEMPLATE" | tr '\n' ' ' | sed 's/ $//')"
LANES="$(lane_jobs "$TEMPLATE" | tr '\n' ' ' | sed 's/ $//')"
[ -n "$LANES" ] || { echo "no lane read out of $TEMPLATE, so the extractor is broken" >&2; exit 1; }
assert_eq "CI needs every other job" \
  "$(job_needs "$TEMPLATE" | cut -f1 | grep -vxF "$CI_JOB" | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')" \
  "$(job_needs "$TEMPLATE" | awk -F '\t' -v j="$CI_JOB" '$1 == j { print $2 }' | tr ',' '\n' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"

# --- 2. The job set ---------------------------------------------------------

# EVENT|CLASS|LANES THAT RUN
job_rows=0
while IFS='|' read -r event class expected; do
  job_rows=$((job_rows + 1))
  assert_eq "lanes on $event for a $class diff" "$expected" "$(running "$TEMPLATE" "$event" success "$class")"
done <<ROWS
merge_group|render|none
merge_group|trivial|none
merge_group|standard|$LANES
merge_group|small|$LANES
merge_group|micro|$LANES
pull_request|render|none
pull_request|standard|$LANES
ROWS
require_rows job "$job_rows"
for class in $CLASSES; do
  assert_eq "a $class merge group runs its pull request's lanes" \
    "$(running "$TEMPLATE" pull_request success "$class")" "$(running "$TEMPLATE" merge_group success "$class")"
done
for event in pull_request merge_group; do
  assert_eq "a dead classifier runs every lane on $event" "$LANES" "$(running "$TEMPLATE" "$event" failure "")"
done

# --- 3. The aggregate -------------------------------------------------------

# The waiver CI computes from the classifier's `lanes` output, read out of
# its aggregate step.
waiver_expr="$(sed -n 's/^          WAIVER: \${{ \(.*\) }}$/\1/p' "$TEMPLATE")"
[ -n "$waiver_expr" ] || { echo "no WAIVER read out of $TEMPLATE" >&2; exit 1; }
skippable="$(awk '/aggregate-needs$/ { on = 1 } on { print } on && !/^          / { exit }' "$TEMPLATE" |
  grep -oE -- '--skippable [a-z0-9-]+' | sed 's/--skippable //' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"
assert_eq "every lane is one the waiver may stand down" "$LANES" "$skippable"

# CLASS|LANE RESULT|EXIT
aggregate_rows=0
while IFS='|' read -r class lane_result expected; do
  aggregate_rows=$((aggregate_rows + 1))
  waiver="$(python3 "$GH_EVAL" value \
    "$(jq -cn --arg l "$(output_value "$TEMPLATE" lanes "$class")" '{needs: {changes: {outputs: {lanes: $l}}}}')" \
    "$waiver_expr")"
  results="$(jq -cn --arg r "$lane_result" --arg lanes "$LANES" \
    '{changes: {result: "success"}} + ($lanes | split(" ") | map({key: ., value: {result: $r}}) | from_entries)')"
  set -- $(printf '%s\n' $LANES | sed 's/^/--skippable /')
  status=0
  "$AGGREGATE_NEEDS" --results "$results" --classifier changes --waiver "$waiver" "$@" \
    >/dev/null 2>&1 || status=$?
  assert_eq "CI on a $class diff with its lanes $lane_result exits $expected" "$expected" "$status"
done <<ROWS
render|skipped|0
trivial|skipped|0
micro|skipped|1
standard|skipped|1
standard|success|0
render|failure|1
ROWS
require_rows aggregate "$aggregate_rows"

# EVENT|RESULT|RUNS
ci_rows=0
while IFS='|' read -r event result runs; do
  ci_rows=$((ci_rows + 1))
  assert_eq "CI runs on $event with its needs at $result: $runs" "$runs" "$(ci_runs "$TEMPLATE" "$event" "$result")"
done <<ROWS
pull_request|success|yes
pull_request|failure|yes
merge_group|failure|yes
merge_group|skipped|yes
ROWS
require_rows ci "$ci_rows"

# --- 4. The copy ------------------------------------------------------------

assert_eq "every workflow expression closes on its own line" "" \
  "$(grep -F '${{' "$TEMPLATE" | grep -vF '}}' || true)"
# A comment may cite the package's docs; every path a step runs is a script
# this package ships.
assert_eq "the template's steps name the shipped script paths" \
  ".agents/skills/harness-ci/scripts/aggregate-needs
.agents/skills/harness-ci/scripts/harness-only" \
  "$(grep -vE '^[[:space:]]*#' "$TEMPLATE" | grep -oE '\.agents/skills/[A-Za-z0-9_/.-]+' | LC_ALL=C sort -u)"
assert_eq "those paths are scripts this package ships" "yes yes" \
  "$([ -x "$AGGREGATE_NEEDS" ] && echo yes || echo no) $([ -x "$TEST_DIR/../scripts/harness-only" ] && echo yes || echo no)"

# --- Must-fail controls -----------------------------------------------------

# Without its status function a lane keeps GitHub's implicit success() and
# stands down on exactly the run nothing classified.
plant "if: \${{ !cancelled() && (needs.changes.result" "if: \${{ (needs.changes.result" "$SANDBOX/no-status.yml"
assert_eq "must-fail: a lane without its status function stands down under a dead classifier" "none" \
  "$(running "$SANDBOX/no-status.yml" merge_group failure "")"

# A `lanes` output that forgets `trivial` runs every lane on a trivial group.
plant " && steps.classify.outputs.change_class != 'trivial'" "" "$SANDBOX/no-trivial.yml"
assert_eq "must-fail: a lanes output without trivial runs the lanes on a trivial group" "$LANES" \
  "$(running "$SANDBOX/no-trivial.yml" merge_group success trivial)"

# Without always(), a failed need skips CI, and a skipped required context
# satisfies the ruleset.
plant "    if: always()" "    if: github.event_name != ''" "$SANDBOX/no-always.yml"
assert_eq "must-fail: CI without always() does not run on a failed need" "no" \
  "$(ci_runs "$SANDBOX/no-always.yml" merge_group failure)"

# A template without merge_group never reports CI on a queue sha.
awk '$0 == "  merge_group:" { n++; next } { print } END { if (n != 1) exit 2 }' "$TEMPLATE" >"$SANDBOX/no-group.yml" ||
  { echo "merge_group could not be dropped from a copy" >&2; exit 1; }
assert_eq "must-fail: a template without merge_group is named" "pull_request" \
  "$(triggers "$SANDBOX/no-group.yml" | tr '\n' ' ' | sed 's/ $//')"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
