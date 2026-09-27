#!/usr/bin/env bash
# templates/ci.yml is the workflow every repository copies for its one
# required `CI` context, so what it runs is evaluated rather than trusted:
# the job conditions are read out of the file and evaluated per event and
# per `lanes` answer from the change-class action, and the aggregate step's
# waiver is handed to the real aggregate-needs. Which diffs answer
# lanes=false is the action's, proved by tools/tests/change-class-action.test.sh
# in the kendex repository; this suite proves the template forwards that
# answer and spells no class of its own.
#
# Surfaces:
#   1. the names: one job named CI, the classifier named `Classify the diff`,
#      both gated events under `on:`, and CI needing every other job.
#   2. the job set: per event and action answer, which lanes run. lanes=false
#      runs none, lanes=true runs them all, both events read `lanes` the
#      same way, a dead classifier runs every lane, and no line of the
#      template reads the change class.
#   3. the aggregate: the waiver the template computes, fed to
#      aggregate-needs, accepts a skipped lane only where the classifier
#      succeeded and answered lanes=false, and CI runs on both events
#      whatever its needs did.
#   4. the copy: every expression closes on its line and every script path
#      it names is one this package ships.
#   5. the steps the classifier can live without: the render-reach, kendex
#      install and mirror steps continue on error and the classify step does
#      not, so a repository whose default branch does not yet carry this
#      package still classifies, with the `render` class out of reach.
# Must-fail arms plant a lane condition without its status function, a
# `lanes` output that spells a class rule in place of forwarding the
# action's, CI without always(), a template without merge_group, a
# render-reach step that fails the job, and an evaluator that refuses every
# expression.
set -euo pipefail
# shellcheck source=lib/sandbox.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/sandbox.sh"
# shellcheck source=lib/workflow.sh
. "$TEST_DIR/lib/workflow.sh"

TEMPLATE="${CI_TEMPLATE_UNDER_TEST:-$TEST_DIR/../templates/ci.yml}"
AGGREGATE_NEEDS="$TEST_DIR/../scripts/aggregate-needs"
[ -f "$TEMPLATE" ] || { echo "missing $TEMPLATE" >&2; exit 1; }

# The value an expression in the changes job's `outputs:` evaluates to, for
# a classify step that answered LANES on a CLASS diff. The class rides along
# so a template that reads it, as a planted one does, is evaluated on it.
output_value() { # TEMPLATE OUTPUT LANES CLASS
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
  gh_eval value "$(jq -cn --arg l "$3" --arg c "$4" '{steps: {classify: {outputs: {lanes: $l, change_class: $c}}}}')" "$expr" | tr -d '"'
}

# The lanes: every job reading the changes job but CI.
lane_jobs() { # TEMPLATE
  local ci
  ci="$(jobs_named "$1" CI)"
  job_needs "$1" | awk -F '\t' -v ci="$ci" '$1 != ci && $2 ~ /(^|,)changes(,|$)/ { print $1 }' | LC_ALL=C sort
}

# The lanes that run on EVENT for a classifier at RESULT whose action
# answered LANES on a CLASS diff.
running() { # TEMPLATE EVENT RESULT LANES CLASS — sorted and spaced, or `none`
  local wf="$1" outputs='{}' job ran
  if [ "$3" = success ]; then
    outputs="$(jq -cn --arg l "$(output_value "$wf" lanes "$4" "$5")" '{lanes: $l}')"
  fi
  lane_jobs "$wf" >"$SANDBOX/lanes"
  ran="$(job_needs "$wf" | while IFS="$(printf '\t')" read -r job needs; do
    grep -qxF -- "$job" "$SANDBOX/lanes" || continue
    printf '%s\t%s\t%s\n' "$job" "$needs" "$(job_ifs "$wf" | awk -F '\t' -v j="$job" '$1 == j { print $2 }')"
  done | gh_eval jobs \
    "$(jq -cn --arg e "$2" --arg r "$3" --argjson o "$outputs" '{github: {event_name: $e}, needs: {changes: {result: $r, outputs: $o}}}')" |
    LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"
  printf '%s' "${ran:-none}"
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

# EVENT|ACTION'S LANES|CLASS|LANES THAT RUN
# The standard rows at lanes=false are a docs-only diff past the trivial
# ceiling, the answer a template reading the class would get wrong. Each
# pull_request row has a merge_group twin with the same answer, so both
# events read `lanes` the same way.
job_rows=0
while IFS='|' read -r event lanes class expected; do
  job_rows=$((job_rows + 1))
  assert_eq "lanes on $event for a $class diff the action answered lanes=$lanes" "$expected" \
    "$(running "$TEMPLATE" "$event" success "$lanes" "$class")"
done <<ROWS
merge_group|false|render|none
merge_group|false|trivial|none
merge_group|false|standard|none
merge_group|true|standard|$LANES
merge_group|true|micro|$LANES
pull_request|false|standard|none
pull_request|true|standard|$LANES
ROWS
require_rows job "$job_rows"
for event in pull_request merge_group; do
  assert_eq "a dead classifier runs every lane on $event" "$LANES" "$(running "$TEMPLATE" "$event" failure "" "")"
done

# The lanes rule is the action's. A template line reading the class would be
# a second spelling of it, in every repository's copy.
class_reads() { # TEMPLATE — the non-comment lines reading a change class
  grep -vE '^[[:space:]]*#' "$1" | grep -F 'change_class' || true
}
assert_eq "no line of the template reads the change class" "" "$(class_reads "$TEMPLATE")"

# --- 3. The aggregate -------------------------------------------------------

# The waiver CI computes from the classifier's `lanes` output, read out of
# its aggregate step.
waiver_expr="$(sed -n 's/^          WAIVER: \${{ \(.*\) }}$/\1/p' "$TEMPLATE")"
[ -n "$waiver_expr" ] || { echo "no WAIVER read out of $TEMPLATE" >&2; exit 1; }
skippable="$(awk '/aggregate-needs$/ { on = 1 } on { print } on && !/^          / { exit }' "$TEMPLATE" |
  grep -oE -- '--skippable [a-z0-9-]+' | sed 's/--skippable //' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"
assert_eq "every lane is one the waiver may stand down" "$LANES" "$skippable"

# CLASSIFIER RESULT|ACTION'S LANES|LANE RESULT|EXIT
# A classifier that did not succeed publishes no outputs, so its lanes value
# is empty.
aggregate_rows=0
while IFS='|' read -r classifier lanes lane_result expected; do
  aggregate_rows=$((aggregate_rows + 1))
  outputs='{}'
  [ "$classifier" != success ] ||
    outputs="$(jq -cn --arg l "$(output_value "$TEMPLATE" lanes "$lanes" standard)" '{lanes: $l}')"
  waiver="$(gh_eval value \
    "$(jq -cn --argjson o "$outputs" '{needs: {changes: {outputs: $o}}}')" \
    "$waiver_expr")"
  results="$(jq -cn --arg c "$classifier" --arg r "$lane_result" --arg lanes "$LANES" \
    '{changes: {result: $c}} + ($lanes | split(" ") | map({key: ., value: {result: $r}}) | from_entries)')"
  set -- $(printf '%s\n' $LANES | sed 's/^/--skippable /')
  status=0
  "$AGGREGATE_NEEDS" --results "$results" --classifier changes --waiver "$waiver" "$@" \
    >/dev/null 2>&1 || status=$?
  assert_eq "CI with its classifier at $classifier answering lanes=$lanes and its lanes $lane_result exits $expected" \
    "$expected" "$status"
done <<ROWS
success|false|skipped|0
success|true|skipped|1
success|true|success|0
success|false|failure|1
failure||skipped|1
failure||success|1
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

# --- 5. The steps the classifier can live without -------------------------

# Whether the changes job's step with id ID carries `continue-on-error: true`.
continues() { # TEMPLATE ID — yes or no
  local hit
  hit="$(awk -v id="$2" '
    /^  changes:/ { in_job = 1; next }
    in_job && /^  [A-Za-z0-9_-]+:/ { in_job = 0 }
    in_job && /^      - / { in_step = ($0 == "      - id: " id) }
    in_job && in_step && $0 == "        continue-on-error: true" { print "yes" }
  ' "$1")"
  printf '%s' "${hit:-no}"
}
# ID|CONTINUES
step_rows=0
while IFS='|' read -r id expected; do
  step_rows=$((step_rows + 1))
  assert_eq "the $id step continues on error: $expected" "$expected" "$(continues "$TEMPLATE" "$id")"
done <<ROWS
render-reach|yes
kendex|yes
mirror|yes
classify|no
ROWS
require_rows step "$step_rows"

# --- Must-fail controls -----------------------------------------------------

# Without its status function a lane keeps GitHub's implicit success() and
# stands down on exactly the run nothing classified.
plant "$TEMPLATE" "if: \${{ !cancelled() && (needs.changes.result" "if: \${{ (needs.changes.result" "$SANDBOX/no-status.yml"
assert_eq "must-fail: a lane without its status function stands down under a dead classifier" "none" \
  "$(running "$SANDBOX/no-status.yml" merge_group failure "" "")"

# A `lanes` output that spells the class rule itself, as the template once
# did, runs every lane on a docs-only diff the action stood down, and reads
# the class.
plant "$TEMPLATE" "lanes: \${{ steps.classify.outputs.lanes }}" \
  "lanes: \${{ steps.classify.outputs.change_class != 'render' && steps.classify.outputs.change_class != 'trivial' }}" \
  "$SANDBOX/class-rule.yml"
assert_eq "must-fail: a lanes output spelling the class rule runs the lanes on a docs-only standard diff" "$LANES" \
  "$(running "$SANDBOX/class-rule.yml" merge_group success false standard)"
assert_eq "must-fail: a lanes output spelling the class rule reads the class" "1" \
  "$(class_reads "$SANDBOX/class-rule.yml" | wc -l | tr -d ' ')"

# Without always(), a failed need skips CI, and a skipped required context
# satisfies the ruleset.
plant "$TEMPLATE" "    if: always()" "    if: github.event_name != ''" "$SANDBOX/no-always.yml"
assert_eq "must-fail: CI without always() does not run on a failed need" "no" \
  "$(ci_runs "$SANDBOX/no-always.yml" merge_group failure)"

# A template without merge_group never reports CI on a queue sha.
awk '$0 == "  merge_group:" { n++; next } { print } END { if (n != 1) exit 2 }' "$TEMPLATE" >"$SANDBOX/no-group.yml" ||
  { echo "merge_group could not be dropped from a copy" >&2; exit 1; }
assert_eq "must-fail: a template without merge_group is named" "pull_request" \
  "$(triggers "$SANDBOX/no-group.yml" | tr '\n' ' ' | sed 's/ $//')"

# render-reach failing the job, as it does where the default branch has no
# harness-only: the classifier dies on the adoption pull request.
awk '$0 == "      - id: render-reach" { print; getline; if ($0 == "        continue-on-error: true") { n++; next } } { print } END { if (n != 1) exit 2 }' \
  "$TEMPLATE" >"$SANDBOX/reach-fails.yml" ||
  { echo "continue-on-error could not be dropped from render-reach in a copy" >&2; exit 1; }
assert_eq "must-fail: a render-reach step that fails the job is named" "no" \
  "$(continues "$SANDBOX/reach-fails.yml" render-reach)"

# An evaluator that refuses every expression answers neither a stand-down nor
# a CI that does not run, the two answers the controls above expect.
printf 'import sys\nsys.stderr.write("gh-eval: cause=planted-refusal\\n")\nsys.exit(2)\n' >"$SANDBOX/refusing-eval.py"
real_eval="$GH_EVAL"
GH_EVAL="$SANDBOX/refusing-eval.py"
refused_lanes="$(running "$TEMPLATE" merge_group failure "" "" 2>/dev/null)"
refused_ci="$(ci_runs "$TEMPLATE" merge_group failure 2>/dev/null)"
GH_EVAL="$real_eval"
assert_eq "must-fail: a refusing evaluator is no stand-down" "gh-eval-refused:2 cause=planted-refusal" "$refused_lanes"
assert_eq "must-fail: a refusing evaluator is no CI that stays down" "gh-eval-refused:2 cause=planted-refusal" "$refused_ci"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
