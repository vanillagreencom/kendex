#!/usr/bin/env bash
# What `.github/workflows/skill-tests.yml` runs is keyed to the change class,
# and the keying is in three places that have to agree: `tools/ci-job-set`
# turns a class into one line per lane and a list of shell shards, each job's
# `if:` and the shard matrix read those lines, and `tools/ci-aggregate` holds the required contexts open over the
# lanes a class stood down. A lane that no condition reads runs on every
# class; a lane a condition reads without a status function stands down on
# exactly the diffs nothing classified; an aggregate that waives a lane the
# class did not authorize turns a silent skip into a green required context.
# Each is a check nobody would see fail, which is why they are here. The
# selection itself is tools/tests/ci-class-job-set.test.sh's; the lane lines
# this suite evaluates the workflow against are tools/tests/lib/ci-job-set-world.sh's.
#
# Three surfaces:
#   1. the names: the lanes the gates read, the lanes the changes job
#      publishes and the lanes ci-job-set selects are one set, compared by
#      name, and each aggregate, on its own, holds every job it needs to the
#      lane or event condition that job's own `if:` reads; and the changes
#      job grants the `actions: read` the action's proof reads with and
#      calls tools/ci-job-set with --event-parity.
#   2. the job set: each gated job's own `if:` and the shard matrix's `os:`
#      and `shard:` expressions, read out of the workflow and EVALUATED
#      against a selection and an event, with GitHub's implicit success() where a
#      condition carries no status function. A merge group runs the class
#      job set its pull request ran, less the two jobs held to the
#      pull-request event. Both events run the macOS legs their
#      queue_macos_shards list names; matching patch proof waives these
#      legs only on the group. The full
#      macOS roster runs on main pushes. The queue's legs expand to that
#      list, or to all three where nothing classified, and CI's lane for
#      them is true exactly where they run. Must-fail arms plant a queue
#      condition and a queue shard key that read no selection, a queue job
#      ignoring the event and a CI lane ignoring the selection.
#      A dead classifier runs every gated job its event runs and the whole
#      Linux shard roster. A pull
#      request's run is cancelled by its next push; no other run is. The `CI` job needs every job that can run on a gated event but the aggregators and
#      runs on both gated events whatever its needs did. Must-fail arms plant
#      a lane condition that reads no selection, one that drops its status
#      function, one that ignores the class on a merge group, a matrix with
#      its arms swapped, one ignoring the event, a shard key reading no
#      selection, a cancel held to no event, a job dropped from CI's needs, CI without always(),
#      a lane dropped from one aggregate alone and an event-held job held to
#      another condition. Every run step of the bot-instructions job is held
#      to the events it runs on: the doc-limits, todo-ban and secrets scans on
#      a pull request alone, the bot-instructions and changelog checks on
#      both; the job checks out the whole history the secrets scan judges
#      each commit against. Arms change a step's event condition, add a run
#      step the table does not hold and plant a shallow checkout.
#   3. the aggregate: a lane the class authorized may skip; one it did not
#      is rejected, and so is a dead classifier, a job named twice and a
#      helper that is not there.
set -euo pipefail

# A suite running from inside a git hook inherits GIT_DIR, GIT_COMMON_DIR,
# GIT_WORK_TREE and GIT_INDEX_FILE, which would resolve ROOT to the hook's
# repository instead of this one.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ci-job-set-world.sh
. "$TEST_DIR/lib/ci-job-set-world.sh"
WORKFLOW="$ROOT/.github/workflows/skill-tests.yml"
# The workflow readers and the expression evaluator are the harness-ci
# package's, which its template suite reads a workflow with too.
# shellcheck source=../../skills/harness-ci/tests/lib/workflow.sh
. "$ROOT/skills/harness-ci/tests/lib/workflow.sh"
[ -f "$GH_EVAL" ] || { echo "missing $GH_EVAL" >&2; exit 1; }
AGGREGATE="$ROOT/tools/ci-aggregate"

# --- 1. The names -----------------------------------------------------------
# Each reader is extracted with an anchored pattern: a name is the whole run
# of name characters after `needs.changes.outputs.`, so a misspelt name is a
# different member of the set, never a substring match of the right one.

OUTPUT_NAME='needs\.changes\.outputs\.[a-z_]+'

# The changes job's token reads this workflow's runs and their records for
# the action's proof; without `actions: read` every proof is refused and the
# merge group runs the lanes its pull request already ran. The reader is the
# harness-ci workflow library's.
check "the changes job grants the proof's read and the checkout's, nothing more" \
  "actions: read contents: read" "$(job_permissions "$WORKFLOW" changes)"
plant "$WORKFLOW" "      actions: read" "" "$TMP/no-actions-read.yml" changes
check "must-fail: a changes job without actions: read is named" "contents: read" \
  "$(job_permissions "$TMP/no-actions-read.yml" changes)"

# The selection's one call per workflow run is where the event-parity check
# runs: tools/ci-job-set derives the other event only when asked, so a
# changes job calling it bare would never refuse a selection that differs by
# event.
job_set_calls() { # WORKFLOW — each tools/ci-job-set call in the changes job
  awk '
    /^  [A-Za-z0-9_-]+:/ { in_job = ($1 == "changes:"); next }
    in_job && /^ +run: tools\/ci-job-set/ { sub(/^ +run: /, ""); print }
  ' "$1"
}
check "the changes job asks tools/ci-job-set for the event-parity check" \
  "tools/ci-job-set --event-parity" "$(job_set_calls "$WORKFLOW")"
plant "$WORKFLOW" "run: tools/ci-job-set --event-parity" "run: tools/ci-job-set" "$TMP/no-parity.yml" changes
check "must-fail: a changes job calling tools/ci-job-set without --event-parity is named" \
  "tools/ci-job-set" "$(job_set_calls "$TMP/no-parity.yml")"

# Only the action's accepted macOS record reaches the coverage selector.
selection_proof_input() { # WORKFLOW — the select step's proof expression
  awk '
    /^  [A-Za-z0-9_-]+:/ { in_job = ($1 == "changes:"); in_select = 0 }
    in_job && /^      - / { in_select = ($0 == "      - id: select") }
    in_select && /^          MACOS_PROOF_RECORD:/ { sub(/^          MACOS_PROOF_RECORD: */, ""); print }
  ' "$1"
}
check "the select step forwards accepted macOS proof" \
  '${{ steps.classify.outputs.macos_proof_record }}' "$(selection_proof_input "$WORKFLOW")"
plant "$WORKFLOW" '          MACOS_PROOF_RECORD: ${{ steps.classify.outputs.macos_proof_record }}' "          MACOS_PROOF_RECORD: ''" "$TMP/empty-macos-proof.yml" changes
check "must-fail: empty macOS proof input breaks forwarding" "''" \
  "$(selection_proof_input "$TMP/empty-macos-proof.yml")"

# A shard matrix key's expression, `os` or `shard`, the `${{ }}` stripped.
matrix_expr() { # WORKFLOW KEY [JOB]
  local raw
  raw="$(awk -v job="${3:-skill-suites-shard}:" -v key="$2:" '
    /^  [A-Za-z0-9_-]+:/ { active = ($1 == job) }
    active && /^        [^[:space:]]/ && $1 == key { sub(/^        [^:]+: /, ""); print }
  ' "$1")"
  case "$raw" in
    '&'*) raw="${raw#* }" ;;
    '*'*) raw="$(sed -n "s/^        $2: &${raw#\*} //p" "$1")" ;;
  esac
  case "$raw" in
    '${{'*) printf '%s' "${raw:4:${#raw}-7}" ;;
    \[*) printf "fromJSON('%s')" "$(printf '%s' "$raw" | sed 's/\([a-z][a-z-]*\)/"\1"/g')" ;;
  esac
}

# `LANE:JOB` for every job whose own condition reads a lane.
gate_pairs() { # WORKFLOW
  job_ifs "$1" | while IFS="$(printf '\t')" read -r job expr; do
    printf '%s\n' "$expr" | grep -oE "$OUTPUT_NAME" |
      sed "s/^needs\\.changes\\.outputs\\.//; s/\$/:$job/" || true
  done | LC_ALL=C sort -u
}

# Every lane a gate reads: the job conditions and the platform matrix.
lanes_read() { # WORKFLOW
  { gate_pairs "$1" | sed 's/:.*//'
    { matrix_expr "$1" os; matrix_expr "$1" shard; } | grep -oE "$OUTPUT_NAME" | sed 's/^needs\.changes\.outputs\.//' || true
  } | LC_ALL=C sort -u
}

# `NAME SOURCE` for every changes-job output the select step publishes.
published_map() { # WORKFLOW
  awk '
    /^  changes:/ { in_job = 1; next }
    in_job && /^  [A-Za-z0-9_-]+:/ { in_job = 0 }
    in_job && /^    outputs:/ { in_outputs = 1; next }
    in_outputs && !/^      / { in_outputs = 0 }
    in_outputs && match($0, /^      [a-z_]+: \$\{\{ steps\.select\.outputs\.[a-z_]+ \}\}$/) {
      name = $1; sub(/:$/, "", name)
      source = $0; sub(/.*steps\.select\.outputs\./, "", source); sub(/ .*/, "", source)
      print name " " source
    }
  ' "$1"
}

# `AGGREGATE<tab>JOB<tab>EXPR` for every `--lane "$VAR:JOB"` an aggregate
# passes, VAR resolved through that same job's `VAR: ${{ EXPR }}` entry, and
# EXPR empty where it resolves to none. AGGREGATE, when named, keeps that
# job's lanes alone.
aggregate_lanes() { # WORKFLOW [AGGREGATE]
  AGG="${2:-}" awk '
    /^  [A-Za-z0-9_-]+:/ { agg = $1; sub(/:$/, "", agg); split("", var) }
    match($0, /^          [A-Z_]+: \$\{\{ .* \}\}$/) {
      name = $1; sub(/:$/, "", name)
      expr = $0; sub(/^[^{]*\{\{ /, "", expr); sub(/ \}\}$/, "", expr)
      var[name] = expr
    }
    match($0, /--lane "\$[A-Z_]+:[a-z0-9-]+"/) {
      pair = substr($0, RSTART + 9, RLENGTH - 10)
      name = pair; sub(/:.*/, "", name)
      job = pair; sub(/^[^:]*:/, "", job)
      if (ENVIRON["AGG"] == "" || agg == ENVIRON["AGG"]) print agg "\t" job "\t" ((name in var) ? var[name] : "")
    }
  ' "$1" | LC_ALL=C sort -u
}
PUBLISHED_LANE='needs\.changes\.outputs\.[a-z_]+'
# `LANE:JOB` for each lane held to a published selection, and `?:JOB` for one
# whose selection resolves to nothing, which matches no lane.
aggregate_pairs() { # WORKFLOW [AGGREGATE]
  aggregate_lanes "$@" | while IFS=$'\t' read -r agg job expr; do
    if [ -z "$expr" ]; then printf '?:%s\n' "$job"; continue; fi
    printf '%s\n' "$expr" | grep -oE "$OUTPUT_NAME" |
      sed "s/^needs\\.changes\\.outputs\\.//; s/\$/:$job/" || true
  done | LC_ALL=C sort -u
}
# `JOB<tab>EXPR` for each lane held to anything but a published selection:
# the event conditions a job is held to.
aggregate_events() { # WORKFLOW [AGGREGATE]
  aggregate_lanes "$@" | LANE="$PUBLISHED_LANE" awk -F '\t' '$3 != "" && $3 !~ ENVIRON["LANE"] { print $2 "\t" $3 }' |
    LC_ALL=C sort -u
}
# `missing=` and `extra=` of ACTUAL against EXPECTED, each a line-per-member set.
set_gap() { # EXPECTED ACTUAL
  printf 'missing=%s extra=%s' \
    "$(comm -23 <(printf '%s\n' "$1" | grep . | LC_ALL=C sort) <(printf '%s\n' "$2" | grep . | LC_ALL=C sort) | tr '\n' ' ' | sed 's/ $//')" \
    "$(comm -13 <(printf '%s\n' "$1" | grep . | LC_ALL=C sort) <(printf '%s\n' "$2" | grep . | LC_ALL=C sort) | tr '\n' ' ' | sed 's/ $//')"
}
CI_JOB="$(jobs_named "$WORKFLOW" CI)"
aggregators() { # WORKFLOW — every job whose script calls tools/ci-aggregate
  awk '
    /^jobs:/ { in_jobs = 1; next }
    !in_jobs { next }
    /^  [A-Za-z0-9_-]+:/ { job = $1; sub(/:$/, "", job); next }
    /^ +tools\/ci-aggregate --/ { print job }
  ' "$1" | LC_ALL=C sort -u
}

PUBLISHED_BY_SCRIPT="$(selection standard false 'crates/core/src/lib.rs' |
  tr ' ' '\n' | sed 's/=.*//' | LC_ALL=C sort)"
[ "$(printf '%s\n' "$PUBLISHED_BY_SCRIPT" | grep -c .)" -gt 0 ] ||
  { echo "ci-job-set published no lane, so the extractor is broken" >&2; exit 1; }
check "the changes job publishes exactly the lanes ci-job-set selects" \
  "$PUBLISHED_BY_SCRIPT" "$(published_map "$WORKFLOW" | awk '{ print $1 }' | LC_ALL=C sort)"
check "each published lane is the select step's line of the same name" "" \
  "$(published_map "$WORKFLOW" | awk '$1 != $2')"
check "the gates read exactly the lanes ci-job-set selects" \
  "$PUBLISHED_BY_SCRIPT" "$(lanes_read "$WORKFLOW")"
GATE_PAIRS="$(gate_pairs "$WORKFLOW")"
[ "$(printf '%s\n' "$GATE_PAIRS" | grep -c .)" -gt 0 ] ||
  { echo "no gated job read out of $WORKFLOW, so the extractor is broken" >&2; exit 1; }

# Each aggregate, on its own, holds every gated job it needs to the lane that
# job's own condition reads, and every job it needs whose condition stands it
# down on a gated event to that condition, spelled as the job spells it. The
# aggregates repeat each other's lanes, so a comparison over their union
# would hide one aggregate's omission behind another's copy. A needed job
# with no lane is event-held where its own condition evaluates false on
# pull_request or merge_group; a condition the evaluator refuses prints its
# refusal into the gap.
aggregate_gap() { # WORKFLOW AGGREGATE — `lanes: missing= extra= events: missing= extra=`
  local wf="$1" agg="$2" needs job expr pr group held=""
  needs="$(job_needs "$wf" | awk -F '\t' -v j="$agg" '$1 == j { print $2 }' | tr ',' '\n' | grep .)" || needs=""
  gate_pairs "$wf" >"$TMP/gap-gates"
  job_ifs "$wf" >"$TMP/gap-ifs"
  while IFS= read -r job; do
    grep -q ":$job\$" "$TMP/gap-gates" && continue
    expr="$(awk -F '\t' -v j="$job" '$1 == j { print $2 }' "$TMP/gap-ifs")"
    [ -n "$expr" ] || continue
    pr="$(gh_eval value '{"github":{"event_name":"pull_request"}}' "$expr")"
    group="$(gh_eval value '{"github":{"event_name":"merge_group"}}' "$expr")"
    case "$pr $group" in
      "true true") ;;
      "true false" | "false true" | "false false") held="$held$(printf '%s\t%s' "$job" "$expr")
" ;;
      *) held="$held$(printf '%s\t%s' "$job" "refused: $pr $group")
" ;;
    esac
  done <<<"$needs"
  printf 'lanes: %s events: %s' \
    "$(set_gap "$(printf '%s\n' "$needs" | while IFS= read -r job; do grep ":$job\$" "$TMP/gap-gates" || true; done)" \
      "$(aggregate_pairs "$wf" "$agg")")" \
    "$(set_gap "$held" "$(aggregate_events "$wf" "$agg")" | tr '\t' '=')"
}
AGGREGATE_ROWS=0
for agg in $(aggregators "$WORKFLOW"); do
  AGGREGATE_ROWS=$((AGGREGATE_ROWS + 1))
  check "$agg holds each job it needs to the selection its own condition reads" \
    "lanes: missing= extra= events: missing= extra=" "$(aggregate_gap "$WORKFLOW" "$agg")"
done
[ "$AGGREGATE_ROWS" -ge 4 ] || { echo "the aggregate table read $AGGREGATE_ROWS rows" >&2; exit 1; }
# The event-held set, derived above, holds the two diff checks CI names.
EVENT_HELD="$(aggregate_events "$WORKFLOW" | cut -f1 | LC_ALL=C sort -u | tr '\n' ' ' | sed 's/ $//')"
check "the aggregates hold the two diff checks to an event" "markdown preflight" "$EVENT_HELD"

# --- 2. The job set ---------------------------------------------------------
# gh-eval.py's header names the expression forms it covers and refuses the
# rest.

# The context a gated job's condition reads: the event, and the changes job's
# result with the outputs its published map names out of a selection, or none
# where it did not succeed.
context_json() { # EVENT RESULT SELECTION MAP_FILE
  local outputs='{}'
  if [ "$2" = success ]; then
    outputs="$(printf '%s\n' $3 | jq -Rn --rawfile map "$4" '
      ([inputs | select(length > 0) | split("=") | {key: .[0], value: .[1]}] | from_entries) as $chosen
      | [$map | split("\n")[] | select(length > 0) | split(" ")
         | select($chosen[.[1]] != null) | {key: .[0], value: $chosen[.[1]]}] | from_entries')" ||
      { echo "could not build the outputs of '$3'" >&2; exit 1; }
  fi
  jq -cn --arg event "$1" --arg result "$2" --argjson outputs "$outputs" \
    '{github: {event_name: $event}, needs: {changes: {result: $result, outputs: $outputs}}}'
}

# The jobs a class or an event stands down or runs: every job whose own
# condition reads a lane, and every job an aggregate holds, since a job an
# aggregate holds whose condition reads nothing runs on every class.
gated_jobs() { # WORKFLOW
  { gate_pairs "$1" | sed 's/^[^:]*://'; aggregate_lanes "$1" | cut -f2; } | LC_ALL=C sort -u
}

running() { # WORKFLOW SELECTION [RESULT] [EVENT] — the gated jobs that run, sorted and spaced
  local wf="$1" sel="$2" result="${3:-success}" event="${4:-pull_request}" map="$TMP/published-map" job expr
  published_map "$wf" >"$map"
  gated_jobs "$wf" >"$TMP/gated"
  job_needs "$wf" >"$TMP/needs"
  job_ifs "$wf" | while IFS="$(printf '\t')" read -r job expr; do
    grep -qxF -- "$job" "$TMP/gated" &&
      printf '%s\t%s\t%s\n' "$job" "$(awk -F '\t' -v j="$job" '$1 == j { print $2 }' "$TMP/needs")" "$expr"
  done >"$TMP/gated-ifs" || true
  gh_eval jobs "$(context_json "$event" "$result" "$sel" "$map")" <"$TMP/gated-ifs" |
    LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//'
}

legs() { # WORKFLOW SELECTION [RESULT] [EVENT] [KEY] — what a matrix key expands to, `os` by default
  local wf="$1" sel="$2" result="${3:-success}" event="${4:-pull_request}" map="$TMP/published-map" expr
  published_map "$wf" >"$map"
  expr="$(matrix_expr "$wf" "${5:-os}")"
  [ -n "$expr" ] || { printf 'no-matrix-expression'; return 0; }
  gh_eval value "$(context_json "$event" "$result" "$sel" "$map")" "$expr"
}

# The selected portability job on pull requests and merge groups.
MACOS_QUEUE_JOB=skill-suites-macos-queue
EVERY_GATED="bot-instructions cargo-check-windows cargo-lint cargo-linux cargo-macos cargo-tests-windows markdown preflight $MACOS_QUEUE_JOB skill-suites-shard ui-tests"
# A pull request runs every gated lane.
EVERY_PR_LANE="bot-instructions cargo-check-windows cargo-lint cargo-linux cargo-macos cargo-tests-windows markdown preflight $MACOS_QUEUE_JOB skill-suites-shard ui-tests"
# What a merge group runs of it: every lane, without the two pull-request diff
# checks.
EVERY_GROUP_LANE="bot-instructions cargo-check-windows cargo-lint cargo-linux cargo-macos cargo-tests-windows $MACOS_QUEUE_JOB skill-suites-shard ui-tests"
check "the gated set is read out of the workflow" "$EVERY_GATED" \
  "$(gated_jobs "$WORKFLOW" | tr '\n' ' ' | sed 's/ $//')"

one_skill="$(selection micro false 'skills/orch/SKILL.md
.agents/skills/orch/SKILL.md')"
# A standard diff of product code, the full battery a pull request of that
# class runs.
standard_code="$(selection standard false 'crates/core/src/lib.rs')"
# EVENT|SELECTION|EXPECTED JOBS. A merge group runs the class job set its pull
# request ran, the two pull-request diff checks aside: a `render` group runs
# the one verify job and a standard group every lane its class selects. A
# group whose queue_macos_shards list names a shard also runs that job, a
# proof standing the rest down included.
job_rows=0
while IFS='|' read -r event sel expected; do
  job_rows=$((job_rows + 1))
  check "jobs on $event under '$sel'" "$expected" "$(running "$WORKFLOW" "$sel" success "$event")"
done <<ROWS
pull_request|$VERIFY_ROW|bot-instructions markdown preflight
merge_group|$VERIFY_ROW|bot-instructions
pull_request|$ALL_ON|$EVERY_PR_LANE
merge_group|$ALL_ON|$EVERY_GROUP_LANE
pull_request|$one_skill|bot-instructions cargo-linux markdown preflight skill-suites-shard
merge_group|$one_skill|bot-instructions cargo-linux skill-suites-shard
pull_request|$CODE_ROW|bot-instructions cargo-linux cargo-macos cargo-tests-windows markdown preflight
merge_group|$CODE_ROW|bot-instructions cargo-linux cargo-macos cargo-tests-windows
pull_request|$ORCH_CODE_ROW|bot-instructions cargo-linux cargo-macos cargo-tests-windows markdown preflight $MACOS_QUEUE_JOB skill-suites-shard
merge_group|$ORCH_CODE_ROW|bot-instructions cargo-linux cargo-macos cargo-tests-windows $MACOS_QUEUE_JOB skill-suites-shard
pull_request|$standard_code|bot-instructions cargo-check-windows cargo-lint cargo-linux cargo-macos cargo-tests-windows markdown preflight $MACOS_QUEUE_JOB skill-suites-shard
merge_group|$standard_code|bot-instructions cargo-check-windows cargo-lint cargo-linux cargo-macos cargo-tests-windows $MACOS_QUEUE_JOB skill-suites-shard
merge_group|$ORCH_PROOF_ROW|bot-instructions cargo-linux cargo-macos cargo-tests-windows $MACOS_QUEUE_JOB skill-suites-shard
merge_group|$SOURCE_PROOF_ROW|bot-instructions cargo-linux cargo-macos cargo-tests-windows $MACOS_QUEUE_JOB skill-suites-shard
merge_group|$PATCH_PROOF_ROW|bot-instructions cargo-linux cargo-tests-windows skill-suites-shard
ROWS
[ "$job_rows" -ge 14 ] || { echo "the job table read $job_rows rows" >&2; exit 1; }

# The same property over every selection the table names: what a merge group
# runs is what its pull request ran less the event-held jobs, plus the
# queue's macOS legs where the selection's queue_macos_shards list is not
# empty.
group_jobs_of() { # SELECTION JOBS — JOBS, spaced, less every event-held one, plus the queue job SELECTION names
  local job out=""
  for job in $2; do
    case " $EVENT_HELD " in *" $job "*) ;; *) out="$out $job" ;; esac
  done
  case " $1 " in *" queue_macos_shards=[] "*) ;; *) out="$out $MACOS_QUEUE_JOB" ;; esac
  printf '%s\n' $out | LC_ALL=C sort -u | tr '\n' ' ' | sed 's/ $//'
}
for sel in "$VERIFY_ROW" "$ALL_ON" "$one_skill" "$CODE_ROW" "$ORCH_CODE_ROW" "$UI_ROW" "$PROSE_ROW" "$standard_code"; do
  check "a merge group runs its pull request's class job set under '$sel'" \
    "$(group_jobs_of "$sel" "$(running "$WORKFLOW" "$sel" success pull_request)")" \
    "$(running "$WORKFLOW" "$sel" success merge_group)"
done

# A classifier that died published nothing. Every gated job runs, which is
# what each condition's status function and result term are for.
check "a dead classifier runs every pull-request lane" "$EVERY_PR_LANE" \
  "$(running "$WORKFLOW" "$ALL_OFF" failure pull_request)"
check "a dead classifier runs every merge-group lane" "$EVERY_GROUP_LANE" \
  "$(running "$WORKFLOW" "$ALL_OFF" failure merge_group)"

# EVENT|RESULT|SELECTION|LEGS. Required skill suites use Linux alone.
leg_rows=0
while IFS='|' read -r event result sel expected; do
  leg_rows=$((leg_rows + 1))
  check "the matrix expands $expected on $event at $result under '$sel'" "$expected" \
    "$(legs "$WORKFLOW" "$sel" "$result" "$event")"
done <<ROWS
pull_request|success|$ALL_ON|["ubuntu-latest"]
merge_group|success|$ALL_ON|["ubuntu-latest"]
pull_request|success|$ORCH_CODE_ROW|["ubuntu-latest"]
merge_group|success|$ORCH_CODE_ROW|["ubuntu-latest"]
merge_group|success|$ORCH_PROOF_ROW|["ubuntu-latest"]
pull_request|success|$one_skill|["ubuntu-latest"]
merge_group|success|$one_skill|["ubuntu-latest"]
pull_request|failure|$ALL_OFF|["ubuntu-latest"]
merge_group|failure|$ALL_OFF|["ubuntu-latest"]
ROWS
[ "$leg_rows" -ge 9 ] || { echo "the leg table read $leg_rows rows" >&2; exit 1; }

# The push job reads the skipped classifier's fallback through its shard
# alias. These are source and expression checks, not a hosted execution.
macos_condition() { # WORKFLOW
  job_ifs "$1" | awk -F '\t' '$1 == "skill-suites-macos" { print $2 }'
}
while IFS='|' read -r event result expected; do
  check "macOS skill suites run=$expected on $event with classification $result" "$expected" \
    "$(gh_eval value "$(context_json "$event" "$result" "$ALL_OFF" "$TMP/published-map")" "$(macos_condition "$WORKFLOW")")"
done <<'ROWS'
pull_request|success|false
pull_request|failure|false
merge_group|success|false
merge_group|failure|false
push|skipped|true
ROWS
check "the main-push macOS matrix uses macOS alone" '["macos-latest"]' \
  "$(gh_eval value '{}' "$(matrix_expr "$WORKFLOW" os skill-suites-macos)")"
check "main pushes run the full shard roster through the alias" "$ROSTER" \
  "$(gh_eval value "$(context_json push skipped "$ALL_OFF" "$TMP/published-map")" "$(matrix_expr "$WORKFLOW" shard skill-suites-macos)")"
plant "$WORKFLOW" "github.event_name == 'push'" "github.event_name != 'push'" "$TMP/wf-macos-pr.yml" skill-suites-macos
check "must-fail: macOS skill suites moved onto a PR run there" true \
  "$(gh_eval value "$(context_json pull_request success "$ALL_OFF" "$TMP/published-map")" "$(macos_condition "$TMP/wf-macos-pr.yml")")"

# The queue's macOS legs: the job's condition, then its shard key evaluated,
# as GitHub expands the matrix; `none` where the condition stands the job
# down. CI's lane for the job is read beside it, and is true exactly where
# the job runs.
queue_legs() { # WORKFLOW EVENT RESULT SELECTION — the expanded shards, or none
  local wf="$1" ctx cond expr value
  ctx="$(context_json "$2" "$3" "$4" "$TMP/published-map")"
  cond="$(job_ifs "$wf" | awk -F '\t' -v j="$MACOS_QUEUE_JOB" '$1 == j { print $2 }')"
  [ -n "$cond" ] || { printf 'no-condition'; return 0; }
  value="$(gh_eval value "$ctx" "$cond")"
  case "$value" in
    true) ;;
    false) printf 'none'; return 0 ;;
    *) printf '%s' "$value"; return 0 ;;
  esac
  expr="$(matrix_expr "$wf" shard "$MACOS_QUEUE_JOB")"
  [ -n "$expr" ] || { printf 'no-matrix-expression'; return 0; }
  gh_eval value "$ctx" "$expr"
}
queue_lane() { # WORKFLOW EVENT RESULT SELECTION — CI's selection for the queue job
  local expr
  expr="$(aggregate_lanes "$1" "$CI_JOB" | awk -F '\t' -v j="$MACOS_QUEUE_JOB" '$2 == j { print $3 }')"
  [ -n "$expr" ] || { printf 'no-lane'; return 0; }
  gh_eval value "$(context_json "$2" "$3" "$4" "$TMP/published-map")" "$expr"
}
# A merge group touching the script the orch-terminal shard races.
open_terminal="$(SELECT_EVENT=merge_group selection micro false skills/orch/scripts/open-terminal)"
only_succeed="$(measured linux false true false '["orch-oversee-succeed"]' '["orch-oversee-succeed"]')"
# EVENT|RESULT|SELECTION|LEGS. VERIFY_ROW, PROSE_ROW and one_skill name no leg.
queue_rows=0
while IFS='|' read -r event result sel expected; do
  queue_rows=$((queue_rows + 1))
  check "the queue's macOS legs expand $expected on $event at $result under '$sel'" "$expected" \
    "$(queue_legs "$WORKFLOW" "$event" "$result" "$sel")"
  lane=false
  [ "$expected" = none ] || lane=true
  check "CI's queue lane is $lane on $event at $result under '$sel'" "$lane" \
    "$(queue_lane "$WORKFLOW" "$event" "$result" "$sel")"
done <<ROWS
merge_group|success|$open_terminal|$QUEUE_ALL
merge_group|success|$ORCH_PROOF_ROW|$QUEUE_ALL
merge_group|success|$SOURCE_PROOF_ROW|$QUEUE_ALL
merge_group|success|$PATCH_PROOF_ROW|none
merge_group|success|$ORCH_CODE_ROW|["orch-terminal","orch-oversee-succeed"]
merge_group|success|$only_succeed|["orch-oversee-succeed"]
merge_group|success|$one_skill|none
merge_group|success|$VERIFY_ROW|none
merge_group|success|$PROSE_ROW|none
merge_group|failure|$ALL_OFF|$QUEUE_ALL
pull_request|success|$ALL_ON|$QUEUE_ALL
pull_request|success|$open_terminal|$QUEUE_ALL
pull_request|failure|$ALL_OFF|$QUEUE_ALL
push|skipped|$ALL_OFF|none
ROWS
[ "$queue_rows" -ge 13 ] || { echo "the queue table read $queue_rows rows" >&2; exit 1; }

# A condition reading no selection runs the legs on a group of prose alone.
plant "$WORKFLOW" "|| needs.changes.outputs.queue_macos_shards != '[]')" "|| true)" \
  "$TMP/wf-queue-unselected.yml" "$MACOS_QUEUE_JOB"
check "must-fail: a queue condition reading no selection runs on a prose group" "[]" \
  "$(queue_legs "$TMP/wf-queue-unselected.yml" merge_group success "$one_skill")"
# A shard key reading no selection runs every queue shard.
plant "$WORKFLOW" "fromJSON(needs.changes.result != 'success' &&" "fromJSON(true &&" \
  "$TMP/wf-queue-all.yml" "$MACOS_QUEUE_JOB"
check "must-fail: a queue shard key reading no selection runs an unselected queue shard" \
  "$QUEUE_ALL" "$(queue_legs "$TMP/wf-queue-all.yml" merge_group success "$only_succeed")"
# Removing PR portability leaves no successful proof for the group.
plant "$WORKFLOW" "github.event_name != 'push'" "github.event_name == 'merge_group'" \
  "$TMP/wf-queue-no-pr.yml" "$MACOS_QUEUE_JOB"
check "must-fail: portability restricted to groups omits the PR proof" "none" \
  "$(queue_legs "$TMP/wf-queue-no-pr.yml" pull_request success "$open_terminal")"

# The shard key expands to the published list, and to the whole roster where
# nothing was published; that literal is the roster ci-job-set selects from,
# in its order, which the ALL_ON row's list is.
check "the shard matrix expands the selected shards" "[$ORCH,\"guards-scans\",\"rest\"]" \
  "$(legs "$WORKFLOW" "$ORCH_CODE_ROW" success merge_group shard)"
check "the shard matrix expands ci-job-set's roster, in order, when nothing classified" \
  "$(selection standard false .github/workflows/skill-tests.yml | sed -n 's/.* shards=\([^ ]*\).*/\1/p')" \
  "$(legs "$WORKFLOW" "$ALL_OFF" failure pull_request shard)"

# The document byte ceilings and the work-marker scan run in the job a
# `render` or `trivial` diff runs, and in no other, so every class that runs
# any gated job runs both scans on a pull request; on a merge group their
# steps stand down, as the step table below holds. Each `run:` line is read
# with the job it sits in. The job a `render` diff runs is read off a merge
# group, where no job held to the pull-request event runs beside it.
job_of_run() { # WORKFLOW COMMAND — the jobs whose `run:` line names it, sorted and spaced
  COMMAND="$2" awk '
    /^jobs:/ { in_jobs = 1; next }
    !in_jobs { next }
    /^  [A-Za-z0-9_-]+:/ { job = $1; sub(/:$/, "", job); next }
    /^ +run: / && index($0, ENVIRON["COMMAND"]) > 0 { print job }
  ' "$1" | LC_ALL=C sort -u | tr '\n' ' ' | sed 's/ $//'
}
VERIFY_JOBS="$(running "$WORKFLOW" "$VERIFY_ROW" success merge_group)"
[ -n "$VERIFY_JOBS" ] || { echo "the verify row runs no job, so the extractor is broken" >&2; exit 1; }
for scan in skills/doc-limits/scripts/doc-limits skills/commit-guards/scripts/todo-ban; do
  check "$scan runs in the verify job alone" "$VERIFY_JOBS" "$(job_of_run "$WORKFLOW" "$scan")"
done

# The scans run on a pull request alone: a byte ceiling is a context budget,
# a work marker is hygiene and the secrets scan reads the pull request's own
# commits, which the pull request answers for, and none ejects a merge group.
# The bot-instructions check and the changelog check stay on both events.
# Every run step of the job is held here: a step is known by its `id:`, or
# its `name:` where it has none, and its own `if:` is read and evaluated per
# event; a step with none runs wherever its job runs.
DOC_LIMITS=skills/doc-limits/scripts/doc-limits
STEP_JOB=bot-instructions
DOC_STEP='doc-limits (document byte ceilings)'
TODO_STEP='todo-ban (index-wide work-marker scan)'
SECRETS_STEP='secrets (credential scan of the pull request diff)'
# `KEY<tab>IF<tab>RUN` per step of JOB: KEY its id, else its name, else `?`;
# IF its condition (`${{ }}` stripped, or none); RUN yes where it has `run:`.
job_steps() { # WORKFLOW JOB
  JOB="$2" awk '
    function flush() {
      if (open) printf "%s\t%s\t%s\n", (id != "" ? id : (name != "" ? name : "?")), (cond == "" ? "none" : cond), (run ? "yes" : "no")
      open = 0; id = ""; name = ""; cond = ""; run = 0
    }
    /^  [A-Za-z0-9_-]+:/ { flush(); job = $1; sub(/:$/, "", job); next }
    job != ENVIRON["JOB"] { next }
    /^      - / { flush(); open = 1; line = $0; sub(/^      - /, "        ", line); $0 = line }
    !open { next }
    /^        id: / { id = $0; sub(/^        id: */, "", id) }
    /^        name: / { name = $0; sub(/^        name: */, "", name) }
    /^        if: / {
      cond = $0; sub(/^        if: */, "", cond)
      if (substr(cond, 1, 3) == "${{") { cond = substr(cond, 4); sub(/}}[ ]*$/, "", cond) }
    }
    /^        run:/ { run = 1 }
    END { flush() }
  ' "$1"
}
step_runs() { # WORKFLOW KEY EVENT — yes, no, no-step, or the evaluator's refusal
  local expr out
  expr="$(job_steps "$1" "$STEP_JOB" | KEY="$2" awk -F '\t' '$1 == ENVIRON["KEY"] { print $2; exit }')"
  [ -n "$expr" ] || { printf 'no-step'; return 0; }
  [ "$expr" != none ] || { printf 'yes'; return 0; }
  out="$(gh_eval value "$(jq -cn --arg e "$3" '{github: {event_name: $e}}')" "$expr")"
  case "$out" in
    true) printf 'yes' ;;
    false) printf 'no' ;;
    *) printf '%s' "$out" ;;
  esac
}
step_row_ok() { # WORKFLOW EVENT KEY RUNS — sets GOT
  GOT="$(step_runs "$1" "$3" "$2")"
  [ "$GOT" = "$4" ]
}
# `missing=` the job's run steps the table holds to no event, `extra=` the
# table's steps the job does not run.
step_coverage_gap() { # WORKFLOW
  set_gap "$(job_steps "$1" "$STEP_JOB" | awk -F '\t' '$3 == "yes" { print $1 }' | LC_ALL=C sort -u)" \
    "$(printf '%s\n' "$STEP_ROWS" | awk -F '|' 'NF { print $2 }' | LC_ALL=C sort -u)"
}
# EVENT|STEP|RUNS
STEP_ROWS="pull_request|$DOC_STEP|yes
merge_group|$DOC_STEP|no
pull_request|$TODO_STEP|yes
merge_group|$TODO_STEP|no
pull_request|$SECRETS_STEP|yes
merge_group|$SECRETS_STEP|no
pull_request|bot-instructions-check|yes
merge_group|bot-instructions-check|yes
pull_request|changelog-entries|yes
merge_group|changelog-entries|yes"
while IFS='|' read -r event step runs; do
  if step_row_ok "$WORKFLOW" "$event" "$step" "$runs"; then
    ok "$step runs on $event: $runs"
  else
    bad "$step runs on $event: $runs (got '$GOT')"
  fi
done <<<"$STEP_ROWS"
check "the step table holds every run step of $STEP_JOB" "missing= extra=" "$(step_coverage_gap "$WORKFLOW")"

# Main keeps the macOS test execution that supplies ongoing platform evidence.
check "macOS Cargo test runs on main" "yes" "$(STEP_JOB=cargo-macos step_runs "$WORKFLOW" test push)"
plant "$WORKFLOW" "      - name: test" "      - name: test
        if: github.event_name != 'push'" "$TMP/wf-macos-no-main-test.yml" cargo-macos
check "must-fail: skipping main omits macOS Cargo tests" "no" "$(STEP_JOB=cargo-macos step_runs "$TMP/wf-macos-no-main-test.yml" test push)"

# A step with its event condition changed fails its merge group row: a scan
# with the condition taken off, the shape that ejected merge groups over a
# budget, runs there again, and the changelog check held to pull requests
# would let a merge group past the package version rule.
PR_ONLY="        if: always() && github.event_name == 'pull_request'"
ALWAYS="        if: always()"
while IFS='|' read -r step from to; do
  STEP="$step" FROM="$from" TO="$to" awk '
    /^      - / { in_step = 0 }
    /^      - / || /^        / {
      key = $0; sub(/^      - /, "        ", key)
      if (key == "        id: " ENVIRON["STEP"] || key == "        name: " ENVIRON["STEP"]) in_step = 1
    }
    in_step && $0 == ENVIRON["FROM"] { $0 = ENVIRON["TO"]; n++ }
    { print }
    END { if (n != 1) exit 2 }
  ' "$WORKFLOW" >"$TMP/wf-step-event.yml" ||
    { echo "the event condition of '$step' could not be changed in a copy" >&2; exit 1; }
  want="$(printf '%s\n' "$STEP_ROWS" | STEP="$step" awk -F '|' '$1 == "merge_group" && $2 == ENVIRON["STEP"] { print $3 }')"
  [ -n "$want" ] || { echo "the step table has no merge group row for '$step'" >&2; exit 1; }
  if step_row_ok "$TMP/wf-step-event.yml" merge_group "$step" "$want"; then
    bad "must-fail: $step with its event condition changed fails its merge group row (got '$GOT')"
  else
    ok "must-fail: $step with its event condition changed fails its merge group row"
  fi
done <<ROWS
$DOC_STEP|$PR_ONLY|$ALWAYS
$TODO_STEP|$PR_ONLY|$ALWAYS
changelog-entries|$ALWAYS|$PR_ONLY
ROWS

# A run step added to the job with no rows is named.
awk '
  { print }
  $0 == "        run: skills/commit-guards/scripts/changelog-entries --base \"$BASE\"" {
    print "      - name: planted"
    print "        run: true"
    n++
  }
  END { if (n != 1) exit 2 }
' "$WORKFLOW" >"$TMP/wf-step-unlisted.yml" ||
  { echo "a step could not be added to $STEP_JOB in a copy" >&2; exit 1; }
check "must-fail: a run step the table does not hold is named" "missing=planted extra=" \
  "$(step_coverage_gap "$TMP/wf-step-unlisted.yml")"

# The secrets scan in the content-scan job judges each pull request commit
# against its own parents, which only the whole history (depth 0) holds.
checkout_depth() { # WORKFLOW JOB — fetch-depth of the job's actions/checkout step, or none
  local depth
  depth="$(awk -v job="$2" '
    /^  [A-Za-z0-9_-]+:/ { in_job = ($1 == job ":"); next }
    in_job && /^      - / { in_co = ($0 ~ /uses: actions\/checkout@/) }
    in_job && in_co && /^          fetch-depth: / { print $2 }
  ' "$1")"
  printf '%s' "${depth:-none}"
}
SCAN_JOB="$(job_of_run "$WORKFLOW" "$DOC_LIMITS")"
check "the content-scan job checks out the whole history, every commit's parents" "0" \
  "$(checkout_depth "$WORKFLOW" "$SCAN_JOB")"

plant "$WORKFLOW" "          fetch-depth: 0" "" "$TMP/wf-shallow.yml" "$SCAN_JOB"
check "must-fail: a content-scan checkout without fetch-depth 0 is named" "none" \
  "$(checkout_depth "$TMP/wf-shallow.yml" "$SCAN_JOB")"

# --- 2a. The one context ---------------------------------------------------
# `CI` is the aggregate context the organization standard has every repository
# report, checked by review-gate's standard-ci-context row.
# Every job reports into it but the aggregators, which run tools/ci-aggregate
# as it does; it runs on both gated events whatever its needs did, and the
# classifier it reads runs on both.

ci_needs_gap() { # WORKFLOW — `missing=` and `extra=` against jobs that can run on gated events
  local wf="$1" ci job expr main_only=""
  ci="$(jobs_named "$wf" CI)"
  while IFS=$'\t' read -r job expr; do
    case "$expr" in *needs.*) continue ;; esac
    if [ "$(gh_eval value '{"github":{"event_name":"pull_request"}}' "$expr")" = false ] &&
       [ "$(gh_eval value '{"github":{"event_name":"merge_group"}}' "$expr")" = false ]; then
      main_only="$main_only$job\n"
    fi
  done < <(job_ifs "$wf")
  set_gap "$(job_needs "$wf" | cut -f1 | LC_ALL=C sort | comm -23 - <({ aggregators "$wf"; printf '%b' "$main_only"; } | LC_ALL=C sort -u))" \
    "$(job_needs "$wf" | awk -F '\t' -v j="$ci" '$1 == j { print $2 }' | tr ',' '\n')"
}
check "one job is named CI" "ci" "$(jobs_named "$WORKFLOW" CI | tr '\n' ' ' | sed 's/ $//')"
AGGREGATORS="$(aggregators "$WORKFLOW" | tr '\n' ' ' | sed 's/ $//')"
check "the aggregators are read out of the workflow" "cargo-tests cargo-tests-macos ci skill-suites" "$AGGREGATORS"
check "CI needs every gated-event job but the aggregators" "missing= extra=" "$(ci_needs_gap "$WORKFLOW")"
plant "$WORKFLOW" "needs: [changes, skill-suites-shard, ui-tests, bot-instructions]" \
  "needs: [changes, skill-suites-shard, skill-suites-macos, ui-tests, bot-instructions]" "$TMP/wf-required-macos.yml" skill-suites
check "must-fail: required skill suites can name a macOS push dependency" skill-suites-macos \
  "$(job_needs "$TMP/wf-required-macos.yml" | awk -F '\t' '$1 == "skill-suites" { print $2 }' | tr ',' '\n' | grep -x skill-suites-macos)"
check "required contexts have no macOS skill-suite dependency" '' \
  "$(job_needs "$WORKFLOW" | awk -F '\t' '$1 == "ci" || $1 == "skill-suites" { print $2 }' | tr ',' '\n' | grep -x skill-suites-macos || true)"
# EVENT|RESULT|RUNS
ci_rows=0
while IFS='|' read -r event result runs; do
  ci_rows=$((ci_rows + 1))
  check "CI runs on $event with its needs at $result: $runs" "$runs" "$(ci_runs "$WORKFLOW" "$event" "$result")"
done <<ROWS
pull_request|success|yes
pull_request|failure|yes
merge_group|failure|yes
merge_group|skipped|yes
push|success|no
ROWS
[ "$ci_rows" -ge 5 ] || { echo "the CI table read $ci_rows rows" >&2; exit 1; }
# The classifier every lane and CI read runs on both gated events.
check "the workflow runs on both gated events" "merge_group pull_request push" \
  "$(triggers "$WORKFLOW" | tr '\n' ' ' | sed 's/ $//')"
changes_if="$(job_ifs "$WORKFLOW" | awk -F '\t' '$1 == "changes" { print $2 }')"
for event in pull_request merge_group; do
  check "the changes job classifies on $event" "true" \
    "$(gh_eval value "$(jq -cn --arg e "$event" '{github: {event_name: $e}}')" "$changes_if")"
done

# --- 2a'. Superseded runs ---------------------------------------------------
# A push to a pull request cancels the run its previous head started; a merge
# group or a push to main never shares a group with another run, so nothing
# cancels or queues it behind one. Each `${{ }}` of the workflow's
# concurrency values is evaluated and spliced back into its text.
concurrency_value() { # WORKFLOW KEY EVENT — the key's value on a run of that event
  local raw ctx out="" expr
  raw="$(awk -v key="$2" '
    /^concurrency:/ { on = 1; next }
    on && /^[^ ]/ { exit }
    on && $1 == key ":" { sub(/^ *[a-z-]+: */, ""); print }
  ' "$1")"
  [ -n "$raw" ] || { printf 'no-concurrency-%s' "$2"; return 0; }
  ctx="$(jq -cn --arg e "$3" '{github: {event_name: $e, run_id: 7}}
    | if $e == "pull_request" then .github.event = {pull_request: {number: 42}} else . end')"
  while [ -n "$raw" ]; do
    case "$raw" in
      *'${{'*)
        out="$out${raw%%'${{'*}"
        raw="${raw#*'${{'}"
        expr="${raw%%'}}'*}"
        raw="${raw#*'}}'}"
        out="$out$(gh_eval value "$ctx" "$expr" | tr -d '"')"
        ;;
      *) out="$out$raw"; raw="" ;;
    esac
  done
  printf '%s' "$out"
}
# EVENT|GROUP|CANCEL
concurrency_rows=0
while IFS='|' read -r event group cancel; do
  concurrency_rows=$((concurrency_rows + 1))
  check "a $event run's concurrency group and cancel" "$group $cancel" \
    "$(concurrency_value "$WORKFLOW" group "$event") $(concurrency_value "$WORKFLOW" cancel-in-progress "$event")"
done <<'ROWS'
pull_request|skill-tests-pull_request-42|true
merge_group|skill-tests-merge_group-7|false
push|skill-tests-push-7|false
ROWS
[ "$concurrency_rows" -ge 3 ] || { echo "the concurrency table read $concurrency_rows rows" >&2; exit 1; }
plant "$WORKFLOW" "cancel-in-progress: \${{ github.event_name == 'pull_request' }}" "cancel-in-progress: true" \
  "$TMP/wf-cancel-all.yml"
check "must-fail: a cancel held to no event cancels a merge group run" "true" \
  "$(concurrency_value "$TMP/wf-cancel-all.yml" cancel-in-progress merge_group)"

# --- 2b. Must-fail controls -------------------------------------------------

# The pre-patch shape of the macOS cargo lane: gated on the event alone. It
# runs on the one-skill row, which is the full battery the narrowing exists
# to avoid.
plant "$WORKFLOW" "!cancelled() && (github.event_name == 'push' || needs.changes.result != 'success' || needs.changes.outputs.cargo_macos == 'true')" \
  "!cancelled()" "$TMP/wf-ungated.yml"
case " $(running "$TMP/wf-ungated.yml" "$one_skill") " in
  *" cargo-macos "*) ok "must-fail: a lane condition reading no selection runs on the one-skill row" ;;
  *) bad "must-fail: an ungated macOS cargo lane still reads as gated" ;;
esac

# A condition without its status function keeps GitHub's implicit success()
# and stands its lane down on exactly the run nothing classified.
plant "$WORKFLOW" "!cancelled() && github.event_name != 'push' && (needs.changes.result != 'success' || needs.changes.outputs.ui == 'true')" \
  "github.event_name != 'push' && (needs.changes.result != 'success' || needs.changes.outputs.ui == 'true')" \
  "$TMP/wf-no-status.yml"
case " $(running "$TMP/wf-no-status.yml" "$ALL_OFF" failure) " in
  *" ui-tests "*) bad "must-fail: a condition with no status function still runs under a dead classifier" ;;
  *) ok "must-fail: a condition with no status function stands down under a dead classifier" ;;
esac


# The shard key reading no selection expands the whole roster on a diff that
# selected one package.
plant "$WORKFLOW" "|| needs.changes.outputs.shards)" "|| '$ROSTER')" "$TMP/wf-shards-unread.yml"
check "must-fail: a shard key reading no selection expands the whole roster" \
  "$ROSTER" "$(legs "$TMP/wf-shards-unread.yml" "$ORCH_CODE_ROW" success merge_group shard)"

# The doc-limits step moved, not deleted, into the shell shards: the scan
# still runs, but not on the classes that run no shard.
awk '
  /^  [A-Za-z0-9_-]+:/ { job = $1; sub(/:$/, "", job) }
  job == "bot-instructions" && $0 == "      - name: doc-limits (document byte ceilings)" {
    skip = 1; moved++; next
  }
  skip && /^        / { next }
  { skip = 0; print }
  job == "skill-suites-shard" && $0 ~ /^    steps:/ {
    print "      - name: doc-limits (document byte ceilings)"
    print "        run: skills/doc-limits/scripts/doc-limits"
    inserted++
  }
  END { if (moved != 1 || inserted != 1) exit 2 }
' "$WORKFLOW" >"$TMP/wf-moved-scan.yml" ||
  { echo "the doc-limits step could not be moved in a copy" >&2; exit 1; }
check "must-fail: a doc-limits step moved to the shell shards is reported there" \
  "skill-suites-shard" \
  "$(job_of_run "$TMP/wf-moved-scan.yml" skills/doc-limits/scripts/doc-limits)"

# A lane that ignores the class on a merge group runs in a render group,
# which is the full battery the queue pass exists to avoid.
plant "$WORKFLOW" "github.event_name == 'push' || needs.changes.result != 'success' || needs.changes.outputs.cargo_linux == 'true'" \
  "github.event_name == 'push' || github.event_name == 'merge_group' || needs.changes.result != 'success' || needs.changes.outputs.cargo_linux == 'true'" \
  "$TMP/wf-group-ungated.yml"
check "must-fail: a lane ignoring the class on merge groups runs in a render group" \
  "bot-instructions cargo-linux" "$(running "$TMP/wf-group-ungated.yml" "$VERIFY_ROW" success merge_group)"

# A job CI does not need reports into no required context.
plant "$WORKFLOW" "needs: [changes, bot-instructions, skill-suites-shard," "needs: [changes, skill-suites-shard," "$TMP/wf-ci-short.yml"
check "must-fail: a job dropped from CI's needs is named" "missing=bot-instructions extra=" \
  "$(ci_needs_gap "$TMP/wf-ci-short.yml")"

# A lane dropped from one aggregate alone, while another aggregate still
# passes it, is named on that aggregate: CI, and a per-repository aggregator.
# AGGREGATE|LANE LINE|GAP
while IFS='|' read -r agg line gap; do
  plant "$WORKFLOW" "$line" '' "$TMP/wf-lane-$agg.yml" "$agg"
  check "must-fail: a lane dropped from $agg alone is named" "$gap" "$(aggregate_gap "$TMP/wf-lane-$agg.yml" "$agg")"
done <<'ROWS'
ci|--lane "$UI:ui-tests"|lanes: missing=ui:ui-tests extra= events: missing= extra=
cargo-tests|--lane "$CARGO_LINT:cargo-lint"|lanes: missing=cargo_lint:cargo-lint extra= events: missing= extra=
ROWS

# Without always(), GitHub's implicit success() skips CI on a failed need, and
# a skipped required context satisfies the ruleset.
plant "$WORKFLOW" "    if: always() && github.event_name != 'push'" "    if: github.event_name != 'push'" \
  "$TMP/wf-ci-no-always.yml" "$CI_JOB"
check "must-fail: CI without always() does not run on a failed need" "no" \
  "$(ci_runs "$TMP/wf-ci-no-always.yml" merge_group failure)"

# An event-held job held to another condition than its own.
plant "$WORKFLOW" "PULL_REQUEST: \${{ github.event_name == 'pull_request' }}" "PULL_REQUEST: \${{ github.event_name != 'push' }}" \
  "$TMP/wf-event-drift.yml"
check "must-fail: an event-held job held to another condition is named" \
  "lanes: missing= extra= events: missing=markdown=github.event_name == 'pull_request' preflight=github.event_name == 'pull_request' extra=markdown=github.event_name != 'push' preflight=github.event_name != 'push'" \
  "$(aggregate_gap "$TMP/wf-event-drift.yml" "$CI_JOB")"

# --- 3. The aggregate -------------------------------------------------------

RESULTS='{"changes":{"result":"success"},"skill-suites-shard":{"result":"success"},"ui-tests":{"result":"skipped"},"bot-instructions":{"result":"success"}}'
aggregate() { # AGGREGATE_SCRIPT LANE... — the exit status, and the refusal key when there is one
  local script="$1" status=0
  shift
  "$script" --results "$RESULTS" --classifier changes "$@" \
    >"$TMP/aggregate-out" 2>"$TMP/aggregate-err" || status=$?
  printf '%s' "$status"
  sed -n 's/^ci-aggregate: cause=/ /p' "$TMP/aggregate-err" | head -1
}

# The workflow combines the shard and runner selections for each required
# shell aggregate. Keep both output names in the control: name coverage
# alone cannot detect an expression that authorizes every skipped shell job.
saved_results="$RESULTS"
RESULTS='{"changes":{"result":"success"},"skill-suites-shard":{"result":"skipped"}}'
for agg in skill-suites "$CI_JOB"; do
  expr="$(aggregate_lanes "$WORKFLOW" "$agg" | awk -F '\t' '$2 == "skill-suites-shard" { print $3 }')"
  while IFS='|' read -r row event sel expected_value expected_status; do
    value="$(gh_eval value "$(context_json "$event" success "$sel" "$TMP/published-map")" "$expr")"
    check "$agg shell selection on $row" "$expected_value" "$value"
    check "$agg skipped shell result on $row" "$expected_status" \
      "$(aggregate "$AGGREGATE" --lane "$value:skill-suites-shard")"
  done <<ROWS
selected-linux|pull_request|$one_skill|true|1
tree-proof-integration|merge_group|$ORCH_PROOF_ROW|true|1
patch-proof-integration|merge_group|$PATCH_PROOF_ROW|true|1
tree-proof-full-integration|merge_group|$SOURCE_PROOF_ROW|true|1
ROWS
  plant "$WORKFLOW" "SHELL_SHARDS: \${{ $expr }}" "SHELL_SHARDS: \${{ $expr && false }}" \
    "$TMP/wf-shell-false-$agg.yml" "$agg"
  false_expr="$(aggregate_lanes "$TMP/wf-shell-false-$agg.yml" "$agg" | awk -F '\t' '$2 == "skill-suites-shard" { print $3 }')"
  value="$(gh_eval value "$(context_json pull_request success "$one_skill" "$TMP/published-map")" "$false_expr")"
  check "must-fail: $agg with selection behavior removed authorizes skipped Linux" "0" \
    "$(aggregate "$AGGREGATE" --lane "$value:skill-suites-shard")"
done
RESULTS="$saved_results"

# The queue's macOS legs report into CI: a failed or cancelled leg fails it,
# and so does a selected job that skipped; a job the selection or the event
# stood down may skip. The selection is CI's own lane expression evaluated.
queue_expr="$(aggregate_lanes "$WORKFLOW" "$CI_JOB" | awk -F '\t' -v j="$MACOS_QUEUE_JOB" '$2 == j { print $3 }')"
[ -n "$queue_expr" ] || bad "no queue lane read out of $CI_JOB, so the lane reader is broken"
queue_aggregate() { # EXPR EVENT SELECTION RESULT — the lane value and the aggregate's status
  local value
  value="$(gh_eval value "$(context_json "$2" success "$3" "$TMP/published-map")" "$1")"
  RESULTS="$(jq -cn --arg job "$MACOS_QUEUE_JOB" --arg r "$4" '{changes: {result: "success"}} + {($job): {result: $r}}')"
  printf '%s %s' "$value" "$(aggregate "$AGGREGATE" --lane "$value:$MACOS_QUEUE_JOB")"
}
# ROW|EVENT|SELECTION|RESULT|LANE AND STATUS
while IFS='|' read -r row event sel result expected; do
  check "$CI_JOB queue macOS legs on $row" "$expected" \
    "$(queue_aggregate "$queue_expr" "$event" "$sel" "$result")"
done <<ROWS
selected-failed|merge_group|$open_terminal|failure|true 1
selected-cancelled|merge_group|$open_terminal|cancelled|true 1
selected-skipped|merge_group|$open_terminal|skipped|true 1
selected-passed|merge_group|$open_terminal|success|true 0
unselected-docs|merge_group|$VERIFY_ROW|skipped|false 0
pull-request|pull_request|$open_terminal|skipped|true 1
patch-proven|merge_group|$PATCH_PROOF_ROW|skipped|false 0
ROWS
plant "$WORKFLOW" "MACOS_QUEUE: \${{ $queue_expr }}" "MACOS_QUEUE: \${{ $queue_expr && false }}" \
  "$TMP/wf-queue-lane-false.yml" "$CI_JOB"
false_expr="$(aggregate_lanes "$TMP/wf-queue-lane-false.yml" "$CI_JOB" | awk -F '\t' -v j="$MACOS_QUEUE_JOB" '$2 == j { print $3 }')"
check "must-fail: a CI lane ignoring the selection lets a selected queue job skip" "false 0" \
  "$(queue_aggregate "$false_expr" merge_group "$open_terminal" skipped)"

check "a lane the class stood down may skip" "0" \
  "$(aggregate "$AGGREGATE" --lane 'true:skill-suites-shard' --lane 'false:ui-tests' \
    --lane 'true:bot-instructions')"
check "a lane the class selected may not skip" "1" \
  "$(aggregate "$AGGREGATE" --lane 'true:skill-suites-shard' --lane 'true:ui-tests' \
    --lane 'true:bot-instructions')"
# One lane stood down turns the waiver on; the skipped lane beside it is one
# the class selected, so the waiver must not reach it.
check "a waiver for one lane authorizes no skip of another" "1" \
  "$(aggregate "$AGGREGATE" --lane 'true:skill-suites-shard' --lane 'true:ui-tests' \
    --lane 'false:bot-instructions')"
# The second selection for one job is refused before either becomes a waiver,
# whichever of the two comes last.
check "a job named twice is refused, the selected one first" \
  "2 duplicate-lane job=ui-tests" \
  "$(aggregate "$AGGREGATE" --lane 'true:ui-tests' --lane 'false:ui-tests')"
check "a job named twice is refused, the stood-down one first" \
  "2 duplicate-lane job=ui-tests" \
  "$(aggregate "$AGGREGATE" --lane 'false:ui-tests' --lane 'true:ui-tests')"

# A copy of the script parked where the harness-ci scripts are not, and one
# beside a scripts directory that holds no helper. Exit 1 is the helper's
# rejection of a lane, so neither may answer it.
mkdir -p "$TMP/no-dir/tools" "$TMP/no-helper/tools" "$TMP/no-helper/skills/harness-ci/scripts"
cp "$AGGREGATE" "$TMP/no-dir/tools/ci-aggregate"
cp "$AGGREGATE" "$TMP/no-helper/tools/ci-aggregate"
case "$(aggregate "$TMP/no-dir/tools/ci-aggregate" --lane 'false:ui-tests')" in
  "2 helper-unreadable dir="*) ok "a missing helper directory is a refusal, not a rejected lane" ;;
  *) bad "a missing helper directory is a refusal, not a rejected lane ($(cat "$TMP/aggregate-err"))" ;;
esac
case "$(aggregate "$TMP/no-helper/tools/ci-aggregate" --lane 'false:ui-tests')" in
  "2 helper-missing path="*) ok "a missing helper is a refusal, not a rejected lane" ;;
  *) bad "a missing helper is a refusal, not a rejected lane ($(cat "$TMP/aggregate-err"))" ;;
esac

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
