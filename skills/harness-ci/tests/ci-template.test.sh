#!/usr/bin/env bash
# templates/ci.yml is the workflow every repository copies for its aggregate
# `CI` context, so what it runs is evaluated rather than trusted:
# the step that republishes the action's lane verdicts is run, the job
# outputs and conditions are read out of the file and evaluated per event
# and per action answer, and the aggregate step's arguments are handed to
# the real aggregate-needs. Which lane a diff reaches is the action's,
# proved by tools/tests/change-class-action.test.sh in the kendex
# repository; this suite proves the template forwards each lane's own
# verdict and spells no class of its own.
#
# Surfaces:
#   1. the names: one job named CI, the classifier named `Classify the diff`,
#      both gated events under `on:`, and CI needing every other job.
#   2. the job set: per event and action answer, which lanes run. A lane
#      stands down where `lanes` or its own verdict is false, an absent
#      verdict leaves `lanes` deciding, both events read the answers the
#      same way, a dead classifier
#      runs every lane, the declaration is read from the default branch's
#      checkout and never the judged one, and no line of the template reads
#      the change class.
#   3. the aggregate: the waiver and the `--skippable` and `--lane`
#      arguments the template passes, fed to aggregate-needs with the needs
#      the template's own outputs make, accept a skipped lane only where the
#      classifier succeeded and `lanes` or the lane's verdict was false, and
#      CI runs on both events whatever its needs did.
#   4. the copy: every expression closes on its line and every script path
#      it names is one this package ships.
#   5. the steps the classifier can live without: the render-reach, kendex
#      install and mirror steps continue on error and the classify step does
#      not, so a repository whose default branch does not yet carry this
#      package still classifies, with the `render` class out of reach.
# Must-fail arms plant a lane condition without its status function, one
# running only on a true verdict, one without its `lanes` term, CI without
# the waiver, a lane output forwarding the action's `lanes` in place of the
# lane's own verdict, one reading the class, a
# declaration read from the judged checkout, CI without always(), a
# template without merge_group, a render-reach step that fails the job, and
# an evaluator that refuses every expression.
set -euo pipefail
# shellcheck source=lib/sandbox.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/sandbox.sh"
# shellcheck source=lib/workflow.sh
. "$TEST_DIR/lib/workflow.sh"

TEMPLATE="${CI_TEMPLATE_UNDER_TEST:-$TEST_DIR/../templates/ci.yml}"
AGGREGATE_NEEDS="$TEST_DIR/../scripts/aggregate-needs"
[ -f "$TEMPLATE" ] || { echo "missing $TEMPLATE" >&2; exit 1; }

# A key's value in the changes job's step with id ID, `${{ }}` stripped.
step_key() { # TEMPLATE ID KEY
  awk -v id="$2" -v key="$3" '
    /^  changes:/ { in_job = 1; next }
    in_job && /^  [A-Za-z0-9_-]+:/ { in_job = 0 }
    in_job && /^      - / { in_step = ($0 == "      - id: " id) }
    in_job && in_step && index($0, key ": ") > 0 && $0 ~ ("^ +" key ": ") {
      sub("^ +" key ": ", ""); sub(/^\$\{\{ /, ""); sub(/ \}\}$/, ""); print; exit
    }
  ' "$1"
}

# The classify step's outputs, as the context every changes-job expression
# reads: the action answered LANES, VERDICTS (comma-joined lane_<name>=
# lines, empty where no declaration was read) and CLASS. The template's
# `lanes` step is run on them, and what it wrote to its output file is its
# step outputs. The class rides along so a template that reads it, as a
# planted one does, is evaluated on it.
changes_context() { # TEMPLATE LANES VERDICTS CLASS
  local classify env_expr run_line value out
  classify="$(jq -cn --arg l "$2" --arg v "$(printf '%s' "$3" | tr ',' '\n')" --arg c "$4" \
    '{lanes: $l, lane_verdicts: $v, change_class: $c}')"
  env_expr="$(step_key "$1" lanes LANE_VERDICTS)"
  run_line="$(step_key "$1" lanes run)"
  [ -n "$env_expr" ] && [ -n "$run_line" ] ||
    { echo "no lanes step read out of $1, so the step reader is broken" >&2; exit 1; }
  value="$(gh_eval value "$(jq -cn --argjson o "$classify" '{steps: {classify: {outputs: $o}}}')" "$env_expr")"
  value="$(jq -er 'if type == "string" then . else "" end' <<<"$value")" ||
    { echo "the LANE_VERDICTS expression did not evaluate: $value" >&2; exit 1; }
  out="$SANDBOX/lanes-step-output"
  : >"$out"
  env -i PATH="$PATH" LANE_VERDICTS="$value" GITHUB_OUTPUT="$out" bash -ec "$run_line" ||
    { echo "the lanes step failed" >&2; exit 1; }
  jq -cRn --argjson o "$classify" '
    [inputs | select(length > 0) | capture("^(?<key>[^=]+)=(?<value>.*)$")] | from_entries |
    {steps: {classify: {outputs: $o}, lanes: {outputs: .}}}' <"$out"
}

# The changes job's outputs, as a JSON object, for a classify step that
# answered LANES, VERDICTS and CLASS. Returns 1 where any piece could not be
# evaluated, a refusing evaluator included.
job_outputs() { # TEMPLATE LANES VERDICTS CLASS
  local ctx name expr value outputs='{}'
  ctx="$(changes_context "$@")" || return 1
  while IFS="$(printf '\t')" read -r name expr; do
    value="$(gh_eval value "$ctx" "$expr")"
    outputs="$(jq -cn --argjson o "$outputs" --arg n "$name" --argjson v "$value" \
      '$o + {($n): (if $v == null then "" else ($v | tostring) end)}' 2>/dev/null)" || return 1
  done < <(awk '
    /^  changes:/ { in_job = 1; next }
    in_job && /^  [A-Za-z0-9_-]+:/ { in_job = 0 }
    in_job && /^    outputs:/ { in_outputs = 1; next }
    in_outputs && !/^      / { in_outputs = 0 }
    in_outputs && /^      [A-Za-z0-9_-]+: \$\{\{ .* \}\}$/ {
      name = $1; sub(/:$/, "", name)
      expr = $0; sub(/^[^{]*\$\{\{ /, "", expr); sub(/ \}\}$/, "", expr)
      print name "\t" expr
    }
  ' "$1")
  printf '%s' "$outputs"
}

# The lanes: every job reading the changes job but CI.
lane_jobs() { # TEMPLATE
  local ci
  ci="$(jobs_named "$1" CI)"
  job_needs "$1" | awk -F '\t' -v ci="$ci" '$1 != ci && $2 ~ /(^|,)changes(,|$)/ { print $1 }' | LC_ALL=C sort
}

# The lanes that run on EVENT for a classifier at RESULT whose action
# answered LANES and VERDICTS on a CLASS diff.
running() { # TEMPLATE EVENT RESULT LANES VERDICTS CLASS — sorted and spaced, or `none`
  local wf="$1" outputs='{}' job ran
  if [ "$3" = success ]; then
    outputs="$(job_outputs "$wf" "$4" "$5" "$6")" ||
      { printf 'job-outputs-refused'; return 0; }
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

# EVENT|ACTION'S LANES|LANE VERDICTS|CLASS|LANES THAT RUN
# The standard rows at lanes=false are a docs-only diff past the trivial
# ceiling, the answer a template reading the class would get wrong; the
# lanes=true row with a false verdict is a diff that reaches no path the
# lane reads, the answer a template reading `lanes` alone would get wrong.
# An empty verdict list is a declaration the action did not read, where
# `lanes` alone decides. Each
# pull_request row has a merge_group twin with the same answer, so both
# events read the verdicts the same way.
job_rows=0
while IFS='|' read -r event lanes verdicts class expected; do
  job_rows=$((job_rows + 1))
  assert_eq "lanes on $event for a $class diff the action answered lanes=$lanes verdicts=$verdicts" "$expected" \
    "$(running "$TEMPLATE" "$event" success "$lanes" "$verdicts" "$class")"
done <<'ROWS'
merge_group|false|lane_test=false|render|none
merge_group|false|lane_test=false|standard|none
merge_group|true|lane_test=false|standard|none
merge_group|true|lane_test=true|micro|test
merge_group|true||standard|test
merge_group|false||standard|none
pull_request|false||standard|none
pull_request|false|lane_test=false|standard|none
pull_request|true|lane_test=false|standard|none
pull_request|true|lane_test=true|standard|test
pull_request|true||standard|test
ROWS
require_rows job "$job_rows"
assert_eq "the job rows name every lane the template runs" "test" "$LANES"
for event in pull_request merge_group; do
  assert_eq "a dead classifier runs every lane on $event" "$LANES" "$(running "$TEMPLATE" "$event" failure "" "" "")"
done

# The declaration is the default branch's: lanes-from names the checkout
# whose ref is the default branch, and never the tree the action judges.
declaration_source() { # TEMPLATE — the checkout lanes-from names, and what it holds
  local from default_path judged
  from="$(step_key "$1" classify lanes-from)"
  judged="$(step_key "$1" classify repo)"
  default_path="$(awk '
    /^  changes:/ { in_job = 1; next }
    in_job && /^  [A-Za-z0-9_-]+:/ { in_job = 0 }
    in_job && /^      - / { ref = 0 }
    in_job && $0 == "          ref: ${{ github.event.repository.default_branch }}" { ref = 1 }
    in_job && ref && /^          path: / { sub(/^          path: /, ""); print; exit }
  ' "$1")"
  if [ -z "$from" ] || [ -z "$default_path" ]; then
    printf 'unread from=%s default=%s' "$from" "$default_path"
  elif [ "$from" = "$judged" ]; then
    printf 'judged'
  elif [ "$from" = "$default_path" ]; then
    printf 'default-branch'
  else
    printf 'other=%s' "$from"
  fi
}
assert_eq "the lane declaration is read from the default branch's checkout" "default-branch" \
  "$(declaration_source "$TEMPLATE")"

# The lanes rule is the action's. A template line reading the class would be
# a second spelling of it, in every repository's copy.
class_reads() { # TEMPLATE — the non-comment lines reading a change class
  grep -vE '^[[:space:]]*#' "$1" | grep -F 'change_class' || true
}
assert_eq "no line of the template reads the change class" "" "$(class_reads "$TEMPLATE")"

# --- 3. The aggregate -------------------------------------------------------

# The aggregate step's arguments after its RESULTS, one per line, read out
# of the step as the shell would split them, "$WAIVER" still unexpanded.
aggregate_args() { # TEMPLATE
  awk '/aggregate-needs$/ { on = 1; next } on && !/^          / { exit } on { print }' "$1" |
    tr ' ' '\n' | grep -v '^$' | grep -vxF -- '--results' | grep -vxF -- '"$RESULTS"' || true
}
ARGS="$(aggregate_args "$TEMPLATE")"
[ -n "$ARGS" ] || { echo "no aggregate-needs arguments read out of $TEMPLATE" >&2; exit 1; }
assert_eq "every lane is one its own verdict may stand down" "$LANES" \
  "$(printf '%s\n' "$ARGS" | sed -n 's/^\([a-z0-9_-]*\)=\1$/\1/p' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"
assert_eq "every lane is one the waiver may stand down" "$LANES" \
  "$(printf '%s\n' "$ARGS" | awk 'prev == "--skippable" { print } { prev = $0 }' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"

# The exit status of TEMPLATE's aggregate step for a classifier at RESULT
# whose action answered LANES and VERDICTS, every lane at LANE_RESULT: the
# needs the template's own outputs make, its WAIVER evaluated on them, and
# its arguments handed to the real aggregate-needs.
aggregate_exit() { # TEMPLATE RESULT LANES VERDICTS LANE_RESULT
  local wf="$1" outputs='{}' waiver_expr waiver results status=0 arg
  if [ "$2" = success ]; then
    outputs="$(job_outputs "$1" "$3" "$4" standard)" ||
      { printf 'job-outputs-refused'; return 0; }
  fi
  waiver_expr="$(sed -n 's/^          WAIVER: \${{ \(.*\) }}$/\1/p' "$1")"
  waiver=""
  [ -z "$waiver_expr" ] ||
    waiver="$(gh_eval value "$(jq -cn --argjson o "$outputs" '{needs: {changes: {outputs: $o}}}')" "$waiver_expr")"
  results="$(jq -cn --arg c "$2" --argjson o "$outputs" --arg r "$5" --arg lanes "$LANES" \
    '{changes: {result: $c, outputs: $o}} + ($lanes | split(" ") | map({key: ., value: {result: $r}}) | from_entries)')"
  set --
  while IFS= read -r arg; do
    [ "$arg" != '"$WAIVER"' ] || arg="$waiver"
    set -- "$@" "$arg"
  done <<<"$(aggregate_args "$wf")"
  "$AGGREGATE_NEEDS" --results "$results" "$@" >/dev/null 2>&1 || status=$?
  printf '%s' "$status"
}

# CLASSIFIER RESULT|ACTION'S LANES|LANE VERDICTS|LANE RESULT|EXIT
# A classifier that did not succeed publishes no outputs. The lanes=false
# row with no verdict is a docs-only diff before the default branch carries
# a declaration, which the waiver alone stands down.
aggregate_rows=0
while IFS='|' read -r classifier lanes verdicts lane_result expected; do
  aggregate_rows=$((aggregate_rows + 1))
  assert_eq "CI with its classifier at $classifier answering lanes=$lanes verdicts=$verdicts and its lanes $lane_result exits $expected" \
    "$expected" "$(aggregate_exit "$TEMPLATE" "$classifier" "$lanes" "$verdicts" "$lane_result")"
done <<'ROWS'
success|true|lane_test=false|skipped|0
success|true|lane_test=true|skipped|1
success|true|lane_test=true|success|0
success|true||skipped|1
success|true||success|0
success|false||skipped|0
success|false|lane_test=false|skipped|0
success|true|lane_test=false|failure|1
failure|||skipped|1
failure|||success|1
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

# --- 4a. The permission the proof reads with ------------------------------
# The action reads the workflow's earlier runs and their records with the job
# token, so the changes job grants `actions: read`; a template without it
# gets one refusal per run and no reuse.
assert_eq "the changes job grants the proof's read and the checkout's, nothing more" \
  "actions: read contents: read" "$(job_permissions "$TEMPLATE" changes)"
awk '$0 == "      actions: read" { n++; next } { print } END { if (n != 1) exit 2 }' \
  "$TEMPLATE" >"$SANDBOX/no-actions-read.yml" ||
  { echo "actions: read could not be dropped from a copy" >&2; exit 1; }
assert_eq "must-fail: a changes job without actions: read is named" "contents: read" \
  "$(job_permissions "$SANDBOX/no-actions-read.yml" changes)"

# The template's lanes run wherever lanes is true and do the same work on
# every event, which is the one thing that lets a run reading no declaration
# record covers=all for the run after it; a template without the input
# records covers=none and nothing reuses.
assert_eq "the classify step says every lane runs wherever lanes is true" "true" \
  "$(step_key "$TEMPLATE" classify covers-all-lanes)"
plant "$TEMPLATE" "covers-all-lanes: true" "covers-all-lanes: false" "$SANDBOX/no-covers-all.yml"
assert_eq "must-fail: a template not saying so is named" "false" \
  "$(step_key "$SANDBOX/no-covers-all.yml" classify covers-all-lanes)"

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
  "$(running "$SANDBOX/no-status.yml" merge_group failure "" "" "")"

# A lane that runs only on a true verdict stands down where no declaration
# was read, and CI then refuses the skip it cannot authorize.
plant "$TEMPLATE" "needs.changes.outputs.lane_test != 'false'" "needs.changes.outputs.lane_test == 'true'" "$SANDBOX/true-only.yml"
assert_eq "must-fail: a lane running only on a true verdict stands down with no declaration read" "none" \
  "$(running "$SANDBOX/true-only.yml" pull_request success true "" standard)"

# A lane that drops its `lanes` term runs on a docs-only diff wherever the
# default branch carries no declaration, and CI without the waiver refuses
# the skip that diff earns.
plant "$TEMPLATE" "needs.changes.outputs.lanes != 'false' && " "" "$SANDBOX/no-lanes-term.yml"
assert_eq "must-fail: a lane without its lanes term runs on a docs-only diff with no declaration read" "test" \
  "$(running "$SANDBOX/no-lanes-term.yml" pull_request success false "" standard)"
plant "$TEMPLATE" "--skippable test --lane test=test" "--lane test=test" "$SANDBOX/no-waiver.yml"
assert_eq "must-fail: CI without the waiver refuses a docs-only skip with no declaration read" "1" \
  "$(aggregate_exit "$SANDBOX/no-waiver.yml" success false "" skipped)"

# A lane output forwarding the action's one `lanes` runs the lane on a diff
# that reaches no path it reads.
plant "$TEMPLATE" "lane_test: \${{ steps.lanes.outputs.lane_test }}" \
  "lane_test: \${{ steps.classify.outputs.lanes }}" "$SANDBOX/global-lanes.yml"
assert_eq "must-fail: a lane output forwarding lanes runs the lane its own verdict stood down" "test" \
  "$(running "$SANDBOX/global-lanes.yml" merge_group success true lane_test=false standard)"

# A lane output that spells a class rule reads the class.
plant "$TEMPLATE" "lane_test: \${{ steps.lanes.outputs.lane_test }}" \
  "lane_test: \${{ steps.classify.outputs.change_class != 'render' && steps.classify.outputs.change_class != 'trivial' }}" \
  "$SANDBOX/class-rule.yml"
assert_eq "must-fail: a lane output spelling the class rule reads the class" "1" \
  "$(class_reads "$SANDBOX/class-rule.yml" | wc -l | tr -d ' ')"

# A declaration read from the judged checkout is one the pull request writes.
plant "$TEMPLATE" "lanes-from: classifier" "lanes-from: subject" "$SANDBOX/judged-lanes.yml"
assert_eq "must-fail: a declaration read from the judged checkout is named" "judged" \
  "$(declaration_source "$SANDBOX/judged-lanes.yml")"

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
refused_lanes="$(running "$TEMPLATE" merge_group failure "" "" "" 2>/dev/null)"
refused_ci="$(ci_runs "$TEMPLATE" merge_group failure 2>/dev/null)"
refused_outputs="$(running "$TEMPLATE" merge_group success true lane_test=false standard 2>/dev/null)"
GH_EVAL="$real_eval"
assert_eq "must-fail: a refusing evaluator is no stand-down" "gh-eval-refused:2 cause=planted-refusal" "$refused_lanes"
assert_eq "must-fail: a refusing evaluator is no CI that stays down" "gh-eval-refused:2 cause=planted-refusal" "$refused_ci"
assert_eq "must-fail: a refusing evaluator is no verdict a lane reads" "job-outputs-refused" "$refused_outputs"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
