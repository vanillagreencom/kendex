#!/usr/bin/env bash
# What `.github/workflows/skill-tests.yml` runs comes from one table,
# LANES in `tools/ci-job-set`: every route writes the `jobs` list it derives
# there, every gated job's `if:` reads its own id in that list, and
# `tools/ci-aggregate` holds CI's needs to the same rows. A job whose
# condition reads anything else runs or stands down against the table; an
# aggregate that waives a job the list named turns a silent skip into a
# green required context. The selection itself is the ci-class-job-set
# suites'; the selections this suite evaluates the workflow against are
# tools/tests/lib/ci-job-set-world.sh's.
#
# Three surfaces:
#   1. the calls: the changes job calls tools/ci-job-set for its fallback
#      and with --event-parity and --runtime-publish, and its installer
#      command runs the trusted checkout's installer with rolling-main and
#      CLI-only flags.
#   2. the job set: every job that needs the classifier is a LANES row and
#      runs exactly where the list names it, on every event; the changes
#      job's own `jobs` output expression, evaluated; each event's whole
#      run over real selections, the dead classifier's fallback among them;
#      the matrices' `os:` and `shard:` expressions; every run step of the
#      bot-instructions job; the secrets scan finding a credential one
#      pull-request commit added and a later one removed, which the group's
#      squash commit no longer holds; and the `CI` job running on a pull
#      request and a merge group whatever its needs did.
#   3. the aggregate: over the real published list, a job the list left out
#      may skip and one it named may not; a held job missing from CI's needs,
#      a list that is not one, a dead classifier and a helper that is not
#      there are each refused.
# Inputs: .github/workflows/skill-tests.yml tools/ci-aggregate tools/ci-job-set tools/lib/* tools/rust-reads skills/* .agents/skills/* crates/* Cargo.toml Cargo.lock clippy.toml .cargo/*
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

step_field() { # WORKFLOW JOB ID_OR_NAME FIELD: an env expression, step/checkout input or run body
  awk -v job="$2:" -v id="$3" -v field="$4" '
    /^  [A-Za-z0-9_-]+:/ { in_job = ($1 == job); in_step = 0; in_run = 0 }
    in_job && id == "" && $0 ~ "^      " field ": " {
      sub(/^      [A-Z_]+: \$\{\{ /, ""); sub(/ \}\}$/, ""); print
    }
    /^      - / { in_step = (in_job && ($0 == "      - id: " id || $0 == "      - name: " id)); in_run = 0 }
    !in_step { next }
    field ~ /^[A-Z_]+$/ && $0 ~ "^          " field ": " {
      sub(/^          [A-Z_]+: \$\{\{ /, ""); sub(/ \}\}$/, ""); print
    }
    field == "working-directory" && /^        working-directory: / {
      sub(/^        working-directory: /, ""); print
    }
    (field == "ref" || field == "path" || field == "fetch-depth") && $1 == field ":" {
      sub(/^          [^:]+: /, ""); print
    }
    field == "run" && /^        run: / {
      sub(/^        run: /, "")
      if ($0 ~ /^\|-?$/) { in_run = 1; next }
      print; next
    }
    field == "run" && in_run && /^          / { sub(/^          /, ""); print; next }
    !/^          / { in_run = 0 }
  ' "$1"
}

# Cargo's warning policy runs the workflow step bodies. Compiler errors and
# denied lints still block; GitHub reads the ::warning annotation for fmt.
mkdir -p "$TMP/cargo-policy/bin"
cat >"$TMP/cargo-policy/bin/cargo" <<'CARGO'
#!/bin/sh
case "$1:$CARGO_CASE" in
  clippy:error) echo 'error: cannot compile' >&2; exit 1 ;;
  clippy:warning)
    echo 'warning: unused variable' >&2
    case " $* " in *' -D warnings '*) exit 1 ;; esac ;;
  fmt:formatting) echo 'Diff in src/lib.rs:'; exit 1 ;;
esac
CARGO
chmod +x "$TMP/cargo-policy/bin/cargo"
while IFS='|' read -r label workflow step input expected annotation; do
  body="$(step_field "$workflow" cargo-lint "$step" run)" || exit 1
  [ -n "$body" ] || { echo 'cargo step has no run body' >&2; exit 1; }
  printf '%s\n' "$body" >"$TMP/cargo-policy/step.sh"
  rc=0
  env -i "PATH=$TMP/cargo-policy/bin:$PATH" "CARGO_CASE=$input" \
    "$BASH" --noprofile --norc -e -o pipefail "$TMP/cargo-policy/step.sh" >"$TMP/cargo-policy/output" 2>&1 || rc=$?
  check "$label: status" "$expected" "$rc"
  warned=no
  if grep -q '^::warning ' "$TMP/cargo-policy/output"; then warned=yes; fi
  check "$label: GitHub warning annotation" "$annotation" "$warned"
done <<ROWS
clippy warnings pass|$WORKFLOW|cargo clippy|warning|0|no
compiler errors block|$WORKFLOW|cargo clippy|error|1|no
formatting warns|$WORKFLOW|cargo fmt|formatting|0|yes
ROWS

# --- 1. The calls -----------------------------------------------------------
# The fallback is written before anything can fail. The selection's one call per workflow run is where the event-parity check
# runs and the merge group reads the runtime builds it owes: tools/ci-job-set
# does each only when asked, so a changes job calling it bare would never
# refuse a selection that differs by event, and its merge group would
# publish no runtime build.
job_set_calls() { # WORKFLOW — each tools/ci-job-set call in the changes job
  awk '
    /^  [A-Za-z0-9_-]+:/ { in_job = ($1 == "changes:"); next }
    in_job && /^ +run: tools\/ci-job-set/ { sub(/^ +run: /, ""); print }
  ' "$1"
}
check "the changes job asks tools/ci-job-set for the event-parity check and the runtime publication" \
  "tools/ci-job-set --fallback
tools/ci-job-set --event-parity --runtime-publish" "$(job_set_calls "$WORKFLOW")"

# The workflow supplies the flags; these fixtures only record the call.
# Match the real installer's file mode so direct execution fails here too.
INSTALL_WORLD="$TMP/installer"
mkdir -p "$INSTALL_WORLD/classifier"
for origin in subject trusted; do
  install_dir="$INSTALL_WORLD"
  [ "$origin" != trusted ] || install_dir="$INSTALL_WORLD/classifier"
  printf '#!/bin/sh\nprintf "source=%%s\\n" "%s" >> "$RECORD"\nprintf "arg=%%s\\n" "$@" >> "$RECORD"\n' \
    "$origin" >"$install_dir/install.sh"
  chmod 644 "$install_dir/install.sh"
done
INSTALL_EXPECTED='arg=--cli-only
arg=--git
source=trusted'
while IFS='|' read -r row workflow verdict; do
  body="$(step_field "$workflow" changes kendex run)" || exit 1
  [ -n "$body" ] || { echo "installer step has no run body" >&2; exit 1; }
  printf '%s\n' "$body" >"$INSTALL_WORLD/step.sh"
  : >"$INSTALL_WORLD/record"
  rc=0
  (cd "$INSTALL_WORLD" && env -i "PATH=$PATH" "RECORD=$INSTALL_WORLD/record" \
    "$BASH" --noprofile --norc -e -o pipefail step.sh >out 2>&1) || rc=$?
  check "$row invokes the installer" 0 "$rc"
  [ -s "$INSTALL_WORLD/record" ] || { bad "$row recorded no installer call"; continue; }
  actual="$(LC_ALL=C sort "$INSTALL_WORLD/record")" || exit 1
  matched=no
  [ "$actual" != "$INSTALL_EXPECTED" ] || matched=yes
  check "$row selects the trusted rolling-main CLI installer" "$verdict" "$matched"
done <<ROWS
workflow|$WORKFLOW|yes
ROWS

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

# Each shell leg's skip list: a push's macOS leg reads the suites its group
# proved on macOS, every other leg the one list, and none where the changes
# job did not succeed. The leg env's expression, evaluated.
SKIPS_EXPR="$(sed -n 's/^      SKIPPED_SUITES: \${{ \(.*\) }}$/\1/p' "$WORKFLOW")"
[ -n "$SKIPS_EXPR" ] || { echo "no SKIPPED_SUITES expression read out of $WORKFLOW" >&2; exit 1; }
# OS|RESULT|MACOS LIST|EXPECTED
while IFS='|' read -r os result macos expected; do
  check "a $os leg's skips with the changes job at $result and macOS list '$macos'" "$expected" \
    "$(gh_eval value "$(jq -cn --arg os "$os" --arg r "$result" --arg m "$macos" '
      {matrix: {os: $os}, needs: {changes: {result: $r, outputs: ({skipped_suites: "[\"l\"]"}
        + (if $m == "" then {} else {skipped_suites_macos: $m} end))}}}')" "$SKIPS_EXPR")"
done <<'ROWS'
ubuntu-latest|success|["m"]|"[\"l\"]"
macos-latest|success|["m"]|"[\"m\"]"
macos-latest|success|[]|"[]"
macos-latest|success||"[\"l\"]"
macos-latest|failure|["m"]|"[]"
ROWS

# A push whose proof read fails runs its whole rosters.
mkdir -p "$TMP/gh-down"
printf '#!/bin/sh\nexit 1\n' >"$TMP/gh-down/gh"
chmod +x "$TMP/gh-down/gh"
PUSH_HEAD="$(git -C "$ROOT" rev-parse HEAD)"

# --- 2. The job set ---------------------------------------------------------
# gh-eval.py's header names the expression forms it covers and refuses the
# rest. The changes job's outputs are its own expressions, evaluated over the
# steps context_json models; the fallback each event writes first is the
# real script's.
MAP="$TMP/published-map"
published_map "$WORKFLOW" >"$MAP"
grep -q '^jobs	' "$MAP" || { echo "no jobs output read out of the changes job" >&2; exit 1; }
fallback_of() { # EVENT — the `jobs=` word the changes job's fallback step writes
  : >"$TMP/fallback"
  EVENT="$1" GITHUB_OUTPUT="$TMP/fallback" "$JOB_SET" --fallback 2>/dev/null ||
    { echo "ci-job-set refused the $1 fallback" >&2; exit 1; }
  cat "$TMP/fallback"
}
FALLBACK_GROUP="$(fallback_of merge_group)"
FALLBACK_PUSH="$(fallback_of push)"
FALLBACK_NIGHT="$(fallback_of schedule)"
FALLBACK_DISPATCH="$(fallback_of workflow_dispatch)"
ctx() { # EVENT RESULT SELECTION — what a job condition reads
  local fallback
  case "$1" in
    merge_group | pull_request) fallback=$FALLBACK_GROUP ;;
    push) fallback=$FALLBACK_PUSH ;;
    schedule) fallback=$FALLBACK_NIGHT ;;
    workflow_dispatch) fallback=$FALLBACK_DISPATCH ;;
    *) echo "no fallback for $1" >&2; exit 1 ;;
  esac
  context_json "$1" "$2" "$3" "$MAP" refs/heads/main "$fallback"
}

# --- 2.1. Every gated job reads its own row --------------------------------
# Every job but the classifier and CI is a LANES row. A job that needs the
# changes job runs exactly where the `jobs` list names it, on every event,
# and a job that starts before the classifier runs on each event its row
# runs on, a pull request aside. Each condition is evaluated
# with its own id listed alone, with every other row listed, with an empty
# list and with no list, so a condition that reads anything but its own id
# disagrees with one of them.
LANE_ROWS="$("$JOB_SET" --lanes)"
lane_cell() { # JOB COLUMN — that LANES cell, empty where no row names the job
  printf '%s\n' "$LANE_ROWS" | awk -F '|' -v job="$1" -v col="$2" '$1 == job { print $col }'
}
GATED="$(job_needs "$WORKFLOW" | awk -F '\t' -v ci="$CI_JOB" '$1 != ci && ("," $2 ",") ~ /,changes,/ { print $1 }')"
grep -qx ui-tests <<<"$GATED" || { echo "ui-tests read as no gated job, so the needs reader is broken" >&2; exit 1; }
check "every job but the classifier and CI is a LANES row, and every row such a job" "missing= extra=" \
  "$(set_gap "$(printf '%s\n' "$LANE_ROWS" | cut -d '|' -f 1)" \
    "$(job_needs "$WORKFLOW" | cut -f 1 | grep -vxF -e changes -e "$CI_JOB")")"
job_ifs "$WORKFLOW" >"$TMP/job-ifs"
job_needs "$WORKFLOW" >"$TMP/job-needs"
gated_lines() { # the `JOB<tab>NEEDS<tab>EXPR` lines of the gated jobs
  local job
  while IFS= read -r job; do
    printf '%s\t%s\t%s\n' "$job" "$(awk -F '\t' -v j="$job" '$1 == j { print $2 }' "$TMP/job-needs")" \
      "$(awk -F '\t' -v j="$job" '$1 == j { print $2 }' "$TMP/job-ifs")"
  done <<<"$GATED"
}
reads_own_row() { # WORKFLOW_IF_LINES — `missing=` and `extra=` jobs over every variant
  local lines="$1" event job others want got gap=""
  for event in merge_group push schedule workflow_dispatch pull_request; do
    while IFS= read -r job; do
      others="$(printf '%s\n' "$GATED" | grep -vxF -- "$job" | jq -Rnc '[inputs]')"
      got="$(gh_eval jobs "$(jq -cn --arg e "$event" --arg j "[\"$job\"]" \
        '{github: {event_name: $e}, needs: {changes: {result: "success", outputs: {jobs: $j}}}}')" <<<"$lines")"
      [ "$got" = "$job" ] || gap="$gap $event:$job:alone=[$got]"
      got="$(gh_eval jobs "$(jq -cn --arg e "$event" --arg j "$others" \
        '{github: {event_name: $e}, needs: {changes: {result: "success", outputs: {jobs: $j}}}}')" <<<"$lines" | grep -xF -- "$job" || true)"
      [ -z "$got" ] || gap="$gap $event:$job:others"
    done <<<"$GATED"
    for want in '{"jobs":"[]"}' '{}'; do
      got="$(gh_eval jobs "$(jq -cn --arg e "$event" --argjson o "$want" \
        '{github: {event_name: $e}, needs: {changes: {result: "success", outputs: $o}}}')" <<<"$lines" | tr '\n' ' ')"
      [ -z "$got" ] || gap="$gap $event:$want=[$got]"
    done
  done
  printf '%s' "${gap# }"
}
check "each gated job runs exactly where the jobs list names it" "" "$(reads_own_row "$(gated_lines)")"
EARLY="$(printf '%s\n' "$LANE_ROWS" | cut -d '|' -f 1 | grep -vxF -f <(printf '%s\n' "$GATED"))" ||
  { echo "every LANES job needs the classifier, so the needs reader is broken" >&2; exit 1; }
while IFS= read -r job; do
  # EVENT:COLUMN, the LANES cell each event reads.
  for pair in merge_group:3 push:4 schedule:5 workflow_dispatch:6 pull_request:3; do
    event="${pair%:*}"
    runs=false
    [ "$(lane_cell "$job" "${pair#*:}")" = - ] || [ "$event" = pull_request ] || runs=true
    check "$job, which starts before the classifier, runs on $event: $runs" "$runs" \
      "$(gh_eval value "$(jq -cn --arg e "$event" '{github: {event_name: $e}}')" \
        "$(awk -F '\t' -v j="$job" '$1 == j { print $2 }' "$TMP/job-ifs")")"
  done
done <<<"$EARLY"

# --- 2.2. The jobs output --------------------------------------------------
# The selection where the select step succeeded, the fallback step's list
# where it failed after writing one or never ran, and nothing where neither
# wrote, which GitHub leaves unset. STEPS|EXPECTED
JOBS_EXPR="$(awk -F '\t' '$1 == "jobs" { print $2 }' "$MAP")"
while IFS='|' read -r row steps expected; do
  check "the jobs output where $row" "$expected" \
    "$(gh_eval value "{\"steps\":$steps}" "$JOBS_EXPR")"
done <<'ROWS'
the select step succeeded|{"select":{"outcome":"success","outputs":{"jobs":"[\"a\"]"}},"fallback":{"outcome":"success","outputs":{"jobs":"[\"b\"]"}}}|"[\"a\"]"
the select step wrote and failed|{"select":{"outcome":"failure","outputs":{"jobs":"[\"a\"]"}},"fallback":{"outcome":"success","outputs":{"jobs":"[\"b\"]"}}}|"[\"b\"]"
the select step never ran|{"select":{"outcome":"skipped","outputs":{}},"fallback":{"outcome":"success","outputs":{"jobs":"[\"b\"]"}}}|"[\"b\"]"
neither step wrote|{"select":{"outcome":"failure","outputs":{}},"fallback":{"outcome":"failure","outputs":{}}}|null
ROWS

# --- 2.3. What each event runs ---------------------------------------------
# Every job of the workflow, gated or not, per event, over real selections:
# the script's selection, the changes job's own output expression and each
# job's own condition together. Other needs start skipped so the evaluator
# can resolve the conditions; a job with no `if:` uses GitHub's implicit
# success().
event_jobs() { # WORKFLOW EVENT RESULT SELECTION — every job that runs, sorted and spaced
  local wf="$1" c job needs expr
  c="$(ctx "$2" "$3" "$4" | jq -c --arg jobs "$(job_needs "$wf" | cut -f1)" '
    .needs = (($jobs | split("\n") | map(select(length > 0) | {key: ., value: {result: "skipped"}}) | from_entries) + .needs)')"
  job_ifs "$wf" >"$TMP/event-ifs"
  job_needs "$wf" | while IFS=$'\t' read -r job needs; do
    expr="$(awk -F '\t' -v j="$job" '$1 == j { print $2 }' "$TMP/event-ifs")"
    printf '%s\t%s\t%s\n' "$job" "$needs" "${expr:-success()}"
  done | gh_eval jobs "$c" | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//'
}
group_selection() { SELECT_JOBS=true SELECT_EVENT=merge_group selection "$@"; }
# Each selection reads the whole checkout on one core, so they are made side
# by side, each into a file of its own, before any row reads one.
prefetch() { # NAME COMMAND...
  local name="$1"
  shift
  (ROW_TAG=".$name" "$@" >"$TMP/sel-$name") &
  PREFETCH_PIDS="$PREFETCH_PIDS $!"
}
fetched() { # NAME — the selection prefetch wrote
  cat "$TMP/sel-$1"
}
push_selection() {
  # The unread proof prints its ::warning annotation ahead of the selection.
  PATH="$TMP/gh-down:$PATH" GITHUB_REPOSITORY=owner/repo GITHUB_SHA="$PUSH_HEAD" PUSH_BEFORE="$PUSH_HEAD" \
    PUSH_AFTER="$PUSH_HEAD" SELECT_JOBS=true SELECT_EVENT=push selection '' '' '' | sed -n '$p'
}
night_selection() {
  PATH="$TMP/gh-down:$PATH" GITHUB_REPOSITORY=owner/repo GITHUB_SHA="$PUSH_HEAD" SELECT_JOBS=true \
    SELECT_EVENT=schedule selection '' '' ''
}
cargo_group_selection() { SELECT_CARGO_MATRIX=true group_selection "$@"; }
PREFETCH_PIDS=""
prefetch readme group_selection trivial true README.md
prefetch run_md group_selection trivial true commands/run.md
prefetch agent_rs group_selection trivial true crates/core/src/render/agent.rs
prefetch one_skill cargo_group_selection micro false 'skills/orch/SKILL.md
.agents/skills/orch/SKILL.md'
prefetch standard_code cargo_group_selection standard false crates/core/src/lib.rs
prefetch orch_script group_selection micro false skills/orch/scripts/orch-runtime
prefetch jarvis_change group_selection micro false skills/jarvis/scripts/task
prefetch lane_source selection standard false .github/workflows/skill-tests.yml
prefetch push_unread push_selection
prefetch night_unread night_selection
for pid in $PREFETCH_PIDS; do
  wait "$pid" || { echo "a prefetched selection failed" >&2; exit 1; }
done
readme="$(fetched readme)"
one_skill="$(fetched one_skill)"
standard_code="$(fetched standard_code)"
orch_script="$(fetched orch_script)"
jarvis_change="$(fetched jarvis_change)"
push_unread="$(fetched push_unread)"
night_unread="$(fetched night_unread)"
MAIN_JOBS="cargo-check-windows cargo-linux cargo-macos cargo-tests-windows catalog changes skill-suites-macos-queue skill-suites-shard smoke"
# A night runs every job a selection can leave out, and its fault report; a
# manual dispatch runs the same jobs without the report.
DISPATCH_JOBS="cargo-check-windows cargo-lint cargo-linux cargo-macos cargo-tests-windows catalog changes skill-suites-macos skill-suites-shard smoke ui-tests"
NIGHT_JOBS="cargo-check-windows cargo-lint cargo-linux cargo-macos cargo-tests-windows catalog changes night-faults skill-suites-macos skill-suites-shard smoke ui-tests"
# EVENT|RESULT|SELECTION|EXPECTED. A pull request runs `CI` alone, whatever
# its diff; a dead classifier runs its event's whole job set.
event_rows=0
while IFS='|' read -r event result sel expected; do
  event_rows=$((event_rows + 1))
  check "every job on $event at $result under '$sel'" "$expected" "$(event_jobs "$WORKFLOW" "$event" "$result" "$sel")"
done <<ROWS
pull_request|skipped||ci
merge_group|success|$readme|bot-instructions cargo-linux changes ci markdown preflight
merge_group|success|$one_skill|bot-instructions cargo-linux catalog changes ci markdown preflight skill-suites-shard
merge_group|success|$standard_code|bot-instructions cargo-check-windows cargo-lint cargo-linux cargo-macos cargo-tests-windows catalog changes ci markdown preflight skill-suites-macos-queue skill-suites-shard smoke
push|success|$push_unread|$MAIN_JOBS
push|failure||$MAIN_JOBS
schedule|success|$night_unread|$NIGHT_JOBS
schedule|failure||$NIGHT_JOBS
workflow_dispatch|success||$DISPATCH_JOBS
ROWS
[ "$event_rows" -ge 9 ] || { echo "the event table read $event_rows rows" >&2; exit 1; }
# A dead classifier's merge group runs exactly CI's needs, besides CI: a
# merge-group job CI does not hold, or a need no merge group runs, is a gap.
check "a dead classifier's merge group runs every job CI needs, and only those" "missing= extra=" \
  "$(set_gap "$(job_needs "$WORKFLOW" | awk -F '\t' -v j="$CI_JOB" '$1 == j { print $2 }' | tr ',' '\n')" \
    "$(event_jobs "$WORKFLOW" merge_group failure '' | tr ' ' '\n' | grep -vxF -- "$CI_JOB")")"

# --- 2.4. The matrices -----------------------------------------------------
legs() { # WORKFLOW SELECTION [RESULT] [EVENT] [KEY] [JOB] — what a matrix key expands to, `os` by default
  local wf="$1" sel="$2" result="${3:-success}" event="${4:-merge_group}" expr
  expr="$(matrix_expr "$wf" "${5:-os}" "${6:-skill-suites-shard}")"
  [ -n "$expr" ] || { printf 'no-matrix-expression'; return 0; }
  gh_eval value "$(ctx "$event" "$result" "$sel")" "$expr"
}
# Required skill suites use Linux alone.
check "the shell matrix uses Linux alone" '["ubuntu-latest"]' "$(legs "$WORKFLOW" "$one_skill")"
# The shard key expands to the published list, and to the whole roster where
# nothing was published; that literal is the roster ci-job-set selects from,
# in its order.
check "the shard matrix expands the selected shards" \
  "$(sed -n 's/.* shards=\([^ ]*\).*/\1/p' <<<"$orch_script")" \
  "$(legs "$WORKFLOW" "$orch_script" success merge_group shard)"
check "the shard matrix expands ci-job-set's roster, in order, when nothing classified" \
  "$(fetched lane_source | sed -n 's/.* shards=\([^ ]*\).*/\1/p')" \
  "$(legs "$WORKFLOW" '' failure merge_group shard)"
# The queue's macOS legs expand the published list, and the macOS-capable
# roster where the changes job failed. EVENT|RESULT|SELECTION|LEGS
while IFS='|' read -r event result sel expected; do
  check "the queue's macOS legs expand $expected on $event at $result" "$expected" \
    "$(legs "$WORKFLOW" "$sel" "$result" "$event" shard skill-suites-macos-queue)"
done <<ROWS
merge_group|success|$orch_script|$(sed -n 's/.* queue_macos_shards=\([^ ]*\).*/\1/p' <<<"$orch_script")
merge_group|failure||$QUEUE_ALL
push|success|$push_unread|$QUEUE_ALL
push|failure||$QUEUE_ALL
ROWS
# A night uses a fixed full matrix on macOS.
check "the nightly macOS matrix uses macOS alone" '["macos-latest"]' \
  "$(gh_eval value '{}' "$(matrix_expr "$WORKFLOW" os skill-suites-macos)")"
check "a night runs the fixed full shard roster" "$ROSTER" \
  "$(legs "$WORKFLOW" "$night_unread" success schedule shard skill-suites-macos)"
# A night and a manual dispatch publish no shard list, so their Linux legs
# run the whole roster.
for event in schedule workflow_dispatch; do
  check "the Linux shard matrix runs the whole roster on $event" \
    "$(fetched lane_source | sed -n 's/.* shards=\([^ ]*\).*/\1/p')" \
    "$(legs "$WORKFLOW" "$([ "$event" = schedule ] && printf '%s' "$night_unread")" success "$event" shard)"
done
# The fault report waits for every other job a night runs, so it reads
# each one's result.
check "the night's fault report needs every other job a night runs" "missing= extra=" \
  "$(set_gap "$(sed -n 's/^jobs=//p' <<<"$FALLBACK_NIGHT" | jq -r '.[] | select(. != "night-faults")'; echo changes)" \
    "$(job_needs "$WORKFLOW" | awk -F '\t' '$1 == "night-faults" { print $2 }' | tr ',' '\n')")"

# The document byte ceilings run in the job a `render` or `trivial` diff
# runs, and in no other, so every class that runs any gated job runs that
# scan in its merge group, as the step table below holds. Each `run:` line is read with the job it sits in.
job_of_run() { # WORKFLOW COMMAND — the jobs whose `run:` line names it, sorted and spaced
  COMMAND="$2" awk '
    /^jobs:/ { in_jobs = 1; next }
    !in_jobs { next }
    /^  [A-Za-z0-9_-]+:/ { job = $1; sub(/:$/, "", job); next }
    /^ +run: / && index($0, ENVIRON["COMMAND"]) > 0 { print job }
  ' "$1" | LC_ALL=C sort -u | tr '\n' ' ' | sed 's/ $//'
}
DOC_LIMITS_JOB="$(job_of_run "$WORKFLOW" skills/doc-limits/scripts/doc-limits)"
check "doc-limits runs in one job" bot-instructions "$DOC_LIMITS_JOB"
case " $(event_jobs "$WORKFLOW" merge_group success "$readme") " in
  *" $DOC_LIMITS_JOB "*) ok "a trivial diff's merge group runs the doc-limits job" ;;
  *) bad "a trivial diff's merge group runs the doc-limits job" ;;
esac

# Every step runs on the merge group, the one run that judges a change: a
# pull request runs no lane. Every run step of the job is held here: a step is known by its `id:`, or
# its `name:` where it has none, and its own `if:` is read and evaluated per
# event; a step with none runs wherever its job runs.
DOC_LIMITS=skills/doc-limits/scripts/doc-limits
STEP_JOB=bot-instructions
DOC_STEP='doc-limits (document byte ceilings)'
SECRETS_STEP='secrets (credential scan of the change)'
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
STEP_ROWS="merge_group|$DOC_STEP|yes
merge_group|$SECRETS_STEP|yes
merge_group|bot-instructions-check|yes
merge_group|decision-ids|yes
merge_group|changelog-entries|yes"
while IFS='|' read -r event step runs; do
  if step_row_ok "$WORKFLOW" "$event" "$step" "$runs"; then
    ok "$step runs on $event: $runs"
  else
    bad "$step runs on $event: $runs (got '$GOT')"
  fi
done <<<"$STEP_ROWS"
check "the step table holds every run step of $STEP_JOB" "missing= extra=" "$(step_coverage_gap "$WORKFLOW")"

# Once selected, macOS and Windows cargo jobs test on groups, selected
# nights and dispatches. A selected main cargo job compiles for its cache.
# JOB|EVENT|RUNS
while IFS='|' read -r job event runs; do
  check "the $job test step runs on $event: $runs" "$runs" "$(STEP_JOB="$job" step_runs "$WORKFLOW" test "$event")"
done <<'ROWS'
cargo-linux|merge_group|yes
cargo-linux|push|no
cargo-linux|schedule|no
cargo-macos|merge_group|yes
cargo-macos|push|no
cargo-macos|schedule|yes
cargo-macos|workflow_dispatch|yes
cargo-tests-windows|merge_group|yes
cargo-tests-windows|push|no
cargo-tests-windows|schedule|yes
cargo-tests-windows|workflow_dispatch|yes
ROWS

# Use the real changed-path output, expanded by the workflow itself, for
# the Linux Cargo argv. Full selection and a missing output both run the
# whole fallback crate.
linux_commands() { # WORKFLOW RESULT SELECTION CRATE
  local wf="$1" ctx matrix cell expr body step crate targets field value
  ctx="$(ctx merge_group "$2" "$3")" || return 1
  expr="$(matrix_expr "$wf" matrix cargo-linux)" || return 1
  matrix="$(gh_eval value "$ctx" "$expr")" || return 1
  cell="$(jq -ce --arg crate "$4" '
    if has("include") then .include[]
    else .crate[] | {crate: .} end | select(.crate == $crate)
  ' <<<"$matrix")" || return 1
  ctx="$(jq -c --argjson matrix "$cell" '.matrix = $matrix' <<<"$ctx")" || return 1
  for field in CRATE CARGO_TEST_TARGETS; do
    expr="$(step_field "$wf" cargo-linux '' "$field")" || return 1
    value="$(gh_eval value "$ctx" "$expr" | jq -er 'select(type == "string")')" || return 1
    case "$field" in CRATE) crate=$value ;; CARGO_TEST_TARGETS) targets=$value ;; esac
  done
  for step in compile test; do
    body="$(step_field "$wf" cargo-linux "$step" run)" || return 1
    [ -n "$body" ] || return 1
    (env -i "PATH=$PATH" "CRATE=$crate" "CARGO_TEST_TARGETS=$targets" "$BASH" --noprofile --norc -e -c '
      cargo() { printf "cargo"; printf "|%s" "$@"; printf "\n"; }
      eval "$1"
    ' _ "$body") || return 1
  done
}
linux_args="|--test|catalog_render_lint|--test|integration"
check "Linux compile and test receive the selected CLI targets" \
  "cargo|test|-p|kendex-cli|--locked|--no-run$linux_args
cargo|test|-p|kendex-cli|--locked|--no-fail-fast$linux_args" \
  "$(linux_commands "$WORKFLOW" success "$one_skill" kendex-cli)"
case " $standard_code " in
  *" cargo_linux_matrix=null "*) ;;
  *) echo 'workspace build selection did not emit a null Cargo matrix' >&2; exit 1 ;;
esac
while IFS='|' read -r result selected; do
  check "Linux compile and test retain the whole crate on $result" \
    "cargo|test|-p|kendex-cli|--locked|--no-run
cargo|test|-p|kendex-cli|--locked|--no-fail-fast" \
    "$(linux_commands "$WORKFLOW" "$result" "$selected" kendex-cli)"
done <<ROWS
success|$standard_code
failure|
ROWS

# The orch-state Linux leg stages the runtime builds the changes job owes
# on a merge group, so a key is published before main moves, and on a push
# for one still owed; never on a pull request or a night, and never where
# nothing is owed. EVENT|PUBLISH|RUNS
publish_if="$(job_steps "$WORKFLOW" skill-suites-shard | awk -F '\t' '$1 == "runtime-publish" { print $2 }')"
[ -n "$publish_if" ] && [ "$publish_if" != none ] ||
  { echo "skill-suites-shard has no runtime-publish step condition: '$publish_if'" >&2; exit 1; }
while IFS='|' read -r event publish runs; do
  check "the runtime-publish step runs on $event with runtime_publish $publish: $runs" "$runs" \
    "$(gh_eval value "$(jq -cn --arg e "$event" --arg p "$publish" '{github: {event_name: $e},
      matrix: {shard: "orch-state"}, runner: {os: "Linux"},
      needs: {changes: {result: "success", outputs: {runtime_publish: $p}}}}')" "$publish_if")"
done <<'ROWS'
merge_group|[{"name":"orch-runtime","key":"k"}]|true
push|[{"name":"orch-runtime","key":"k"}]|true
pull_request|[{"name":"orch-runtime","key":"k"}]|false
schedule|[{"name":"orch-runtime","key":"k"}]|false
merge_group|[]|false
ROWS

# The secrets scan in the content-scan job judges each group and pull
# request commit against its own parents, which only the whole history
# (depth 0) holds.
checkout_depth() { # WORKFLOW JOB — the candidate checkout's depth, or none
  local depth
  depth="$(step_field "$1" "$2" candidate-checkout fetch-depth)" || return 1
  printf '%s' "${depth:-none}"
}
SCAN_JOB="$(job_of_run "$WORKFLOW" "$DOC_LIMITS")"
check "the content-scan job checks out the whole history, every commit's parents" "0" \
  "$(checkout_depth "$WORKFLOW" "$SCAN_JOB")"

# The pull-request producer can replace its guard scripts and exclusions.
# Use the template suite's neutral credential fixture with this source
# workflow's actual checkout inputs and scan body. No candidate script may
# run first: it shares the runner directory with the scanner executable.
# The pull request adds the credential in one commit and removes it in the
# next; the queue's squash commit, the group, holds neither, so only the
# scan of the pull request's own commits can find it.
check "the credential scan runs before candidate scripts" "$SECRETS_STEP" \
  "$(job_steps "$WORKFLOW" "$SCAN_JOB" | awk -F '\t' '$3 == "yes" { print $1; exit }')"
CREDENTIAL_REPO="$TMP/credential-source"
mkdir -p "$CREDENTIAL_REPO/skills/commit-guards"
git -C "$CREDENTIAL_REPO" init -q -b main
git -C "$CREDENTIAL_REPO" config user.email credential-fixture@example.invalid
git -C "$CREDENTIAL_REPO" config user.name credential-fixture
git -C "$CREDENTIAL_REPO" config gc.auto 0
git -C "$CREDENTIAL_REPO" config maintenance.auto false
cp -R "$ROOT/skills/commit-guards/scripts" "$CREDENTIAL_REPO/skills/commit-guards/"
git -C "$CREDENTIAL_REPO" add -A
git -C "$CREDENTIAL_REPO" commit -qm base
git -C "$CREDENTIAL_REPO" checkout -qb candidate
for script in install-gitleaks secrets; do
  printf '#!/usr/bin/env bash\nprintf ran >"$RUNNER_TEMP/candidate-code-ran"\nexit 0\n' \
    >"$CREDENTIAL_REPO/skills/commit-guards/scripts/$script"
done
printf '%s\n' "AKIA""Z7Q3R5T2V4X6Y7W2" >"$CREDENTIAL_REPO/cred.txt"
mkdir -p "$CREDENTIAL_REPO/tools"
printf '*\tthe candidate excludes every path\n' >"$CREDENTIAL_REPO/tools/secrets-excludes"
git -C "$CREDENTIAL_REPO" add -A
git -C "$CREDENTIAL_REPO" commit -qm 'candidate guard fixture'
git -C "$CREDENTIAL_REPO" rm -q cred.txt
git -C "$CREDENTIAL_REPO" commit -qm 'candidate drops the credential'
git -C "$CREDENTIAL_REPO" update-ref refs/pull/7/head candidate
git -C "$CREDENTIAL_REPO" checkout -qb group main
git -C "$CREDENTIAL_REPO" merge -q --squash candidate
git -C "$CREDENTIAL_REPO" commit -qm 'the queue squash of pull request 7'
[ -z "$(git -C "$CREDENTIAL_REPO" ls-tree -r --name-only group -- cred.txt)" ] ||
  { echo 'the group commit holds the credential the pull request removed' >&2; exit 1; }
CREDENTIAL_BASE="$(git -C "$CREDENTIAL_REPO" rev-parse main)"
if ! GITLEAKS_BIN="$(command -v gitleaks)"; then
  "$ROOT/skills/commit-guards/scripts/install-gitleaks" "$TMP/gitleaks"
  GITLEAKS_BIN="$TMP/gitleaks/gitleaks"
fi

QUEUE_REF="refs/heads/gh-readonly-queue/main/pr-7-$CREDENTIAL_BASE"
scan_env() { # WORKFLOW KEY CONTEXT_JSON — the scan step's env value at that context
  local expr
  expr="$(step_field "$1" "$SCAN_JOB" "$SECRETS_STEP" "$2")" || return 1
  [ -n "$expr" ] || { echo "credential scan has no $2 expression" >&2; return 1; }
  gh_eval value "$3" "$expr" | jq -r '. // ""'
}
credential_row=0
while IFS='|' read -r row wf head_ref expected; do
  credential_row=$((credential_row + 1))
  root="$TMP/credential-$credential_row"
  mkdir -p "$root/runner/gitleaks"
  cp "$GITLEAKS_BIN" "$root/runner/gitleaks/gitleaks"
  for checkout in candidate-checkout 'the credential guards, from the default branch'; do
    path="$(step_field "$wf" "$SCAN_JOB" "$checkout" path)" || exit 1
    ref="$(step_field "$wf" "$SCAN_JOB" "$checkout" ref)" || exit 1
    depth="$(step_field "$wf" "$SCAN_JOB" "$checkout" fetch-depth)" || exit 1
    [ -n "$path" ] || { echo 'credential checkout has no path' >&2; exit 1; }
    case "$ref" in
      '') branch=group ;;
      '${{ github.event.repository.default_branch }}') branch=main ;;
      *) echo 'credential checkout has an unsupported ref' >&2; exit 1 ;;
    esac
    if [ "$depth" = 0 ]; then
      git clone -q --no-hardlinks --branch "$branch" "$CREDENTIAL_REPO" "$root/$path"
    else
      git clone -q --depth "${depth:-1}" --branch "$branch" "file://$CREDENTIAL_REPO" "$root/$path"
    fi
  done
  work="$(step_field "$wf" "$SCAN_JOB" "$SECRETS_STEP" working-directory)" || exit 1
  body="$(step_field "$wf" "$SCAN_JOB" "$SECRETS_STEP" run)" || exit 1
  [ -n "$body" ] || { echo 'credential scan has no run body' >&2; exit 1; }
  # The step's refs, evaluated for a merge group whose base is main.
  context="$(jq -cn --arg sha "$CREDENTIAL_BASE" --arg head "$head_ref" \
    '{github: {event_name: "merge_group", event: {merge_group: {base_sha: $sha, base_ref: "refs/heads/main", head_ref: $head}}}}')"
  scan_BASE="$(scan_env "$wf" BASE "$context")" || exit 1
  scan_BASE_REF="$(scan_env "$wf" BASE_REF "$context")" || exit 1
  scan_HEAD_REF="$(scan_env "$wf" HEAD_REF "$context")" || exit 1
  status=0
  (cd -- "$root/${work:-.}" && env -i PATH="$PATH" HOME="$root" BASE="$scan_BASE" \
    BASE_REF="$scan_BASE_REF" HEAD_REF="$scan_HEAD_REF" \
    KENDEX_REAL_HOME=1 CI=true GITHUB_ACTIONS=true GITHUB_WORKSPACE="$root" RUNNER_TEMP="$root/runner" \
    "$BASH" --noprofile --norc -e -o pipefail -c "$body") >"$root/out" 2>&1 || status=$?
  finding=no
  if grep -qx 'secrets: secret=cred.txt:1:aws-access-token' "$root/out"; then finding=yes; fi
  candidate=no
  [ ! -e "$root/runner/candidate-code-ran" ] || candidate=yes
  check "$row: scan exit, credential finding, and candidate execution" \
    "$expected" "$status:$finding:$candidate"
  if [ "$expected" != "$status:$finding:$candidate" ]; then
    printf 'ci-aggregate-test: credential-row=%s status=%s\n' "$row" "$status" >&2
    tail -n 40 "$root/out" >&2
  fi
done <<ROWS
trusted|$WORKFLOW|$QUEUE_REF|1:yes:no
a queue ref naming no pull request|$WORKFLOW|refs/heads/gh-readonly-queue/main/head|2:no:no
ROWS

# Execute the decision step read from the workflow, not a second invocation
# written by the test. The create-decision workflow can allocate D035 on two
# branches before either lands. Here the remote's release branch advances
# after the candidate clones; main stays behind, so a hard-coded default
# branch or a stale clone cannot answer for the event's actual base.
decision_fixture_index() { # REPO [D035_FILENAME]
  mkdir -p "$1/docs/decisions"
  {
    printf '%s\n' '| Date | ID | Research | Decision | Rationale | Revisit When | Status | Link |' \
      '|------|----|----------|----------|-----------|--------------|--------|------|' \
      '| 2026-01-10 | D034 | P-1 | Existing | Reason | Never | Active | [Full](D034-first.md) |'
    [ -z "${2:-}" ] || printf '| 2026-01-11 | D035 | P-2 | Added | Reason | Never | Active | [Full](%s) |\n' "$2"
  } >"$1/docs/decisions/INDEX.md"
  printf '# D034: Existing\n' >"$1/docs/decisions/D034-first.md"
  [ -z "${2:-}" ] || printf '# D035: Added\n' >"$1/docs/decisions/$2"
}
decision_fixture_commit() { # REPO
  git -C "$1" add docs/decisions
  git -C "$1" -c core.hooksPath=/dev/null -c commit.gpgsign=false \
    -c user.email=ci-test@example.invalid -c user.name=ci-test commit -q -m fixture
}
decision_ci_row_ok() { # WORKFLOW EVENT KIND STATUS ERROR_KEY — sets DECISION_GOT
  local wf="$1" event="$2" kind="$3" want="$4" key="$5" dir context expr base_ref body work_dir rc=0 out seed
  DECISION_GOT=fixture-failed
  dir="$(mktemp -d "$TMP/decision-ci.XXXXXX")" || return 1
  git init -q -b main "$dir/up" || return 1
  decision_fixture_index "$dir/up" || return 1
  decision_fixture_commit "$dir/up" || return 1
  seed="$(git -C "$dir/up" rev-parse HEAD)" || return 1
  git -C "$dir/up" checkout -q -b release || return 1
  git clone -q --branch release "$dir/up" "$dir/work" || return 1
  decision_fixture_index "$dir/up" D035-main.md || return 1
  decision_fixture_commit "$dir/up" || return 1
  case "$kind" in
    collision|unavailable|empty-base)
      decision_fixture_index "$dir/work" D035-lane.md || return 1
      decision_fixture_commit "$dir/work" || return 1
      ;;
    inherited|renamed)
      git -C "$dir/work" pull -q --ff-only || return 1
      if [ "$kind" = renamed ]; then
        git -C "$dir/work" mv docs/decisions/D035-main.md docs/decisions/D035-renamed.md || return 1
        decision_fixture_index "$dir/work" D035-renamed.md || return 1
        decision_fixture_commit "$dir/work" || return 1
      fi
      ;;
    *) echo "decision fixture: unknown kind=$kind" >&2; return 1 ;;
  esac
  if [ "$kind" = unavailable ]; then
    git -C "$dir/work" remote set-url origin "$dir/absent" || return 1
  fi
  context="$(jq -cn --arg event "$event" --arg seed "$seed" --arg kind "$kind" '
    {github: {event_name: $event, event:
      (if $kind == "empty-base" then {}
       elif $event == "pull_request" then {pull_request: {base: {ref: "release", sha: $seed}}}
       else {merge_group: {base_ref: "refs/heads/release", base_sha: $seed}} end)}}')" || return 1
  expr="$(step_field "$wf" bot-instructions decision-ids BASE_REF)" || return 1
  [ -n "$expr" ] || { DECISION_GOT=missing-base-expression; return 1; }
  base_ref="$(gh_eval value "$context" "$expr" | jq -r '. // ""')" || return 1
  body="$(step_field "$wf" bot-instructions decision-ids run)" || return 1
  [ -n "$body" ] || { DECISION_GOT=missing-run-body; return 1; }
  work_dir="$(step_field "$wf" bot-instructions decision-ids working-directory)" || return 1
  printf '%s\n' "$body" >"$dir/step.sh" || return 1
  mkdir -p "$dir/work/skills/decider" || return 1
  cp -R "$ROOT/skills/decider/scripts" "$dir/work/skills/decider/" || return 1
  mv "$dir/work" "$dir/candidate" || return 1
  out="$(cd "$dir/$work_dir" && env -i "PATH=$PATH" "HOME=$HOME" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 DECISIONS_DIR=docs/decisions \
    "BASE_REF=$base_ref" "$BASH" --noprofile --norc -e -o pipefail "$dir/step.sh" 2>&1)" || rc=$?
  DECISION_GOT="exit=$rc out=$out"
  [ "$rc" -eq "$want" ] || return 1
  if [ -n "$key" ]; then
    [[ "$out" == *"$key"* ]] || return 1
  else
    [[ "$out" != *"error="* ]] || return 1
  fi
}
for event in merge_group; do
  while IFS='|' read -r kind status key; do
    if decision_ci_row_ok "$WORKFLOW" "$event" "$kind" "$status" "$key"; then
      ok "decision CI: $event $kind"
    else
      bad "decision CI: $event $kind ($DECISION_GOT)"
    fi
  done <<'ROWS'
collision|1|error=id-collision id=D035
inherited|0|
renamed|0|
unavailable|1|error=base-unverified
empty-base|1|error=base-unverified
ROWS
done

# --- 2a. The one context ---------------------------------------------------
# `CI` is the aggregate context the organization standard has every repository
# report, checked by review-gate's standard-ci-context row.
# Every other merge-group job reports into it; it runs on a pull request and
# a merge group whatever its needs did. The changes job selects group and
# main work and decides whether a scheduled head needs testing.
check "one job is named CI" "ci" "$(jobs_named "$WORKFLOW" CI | tr '\n' ' ' | sed 's/ $//')"
AGGREGATORS="$(aggregators "$WORKFLOW" | tr '\n' ' ' | sed 's/ $//')"
check "CI is the only aggregate read out of the workflow" "ci" "$AGGREGATORS"
# EVENT|RESULT|RUNS
ci_rows=0
while IFS='|' read -r event result runs; do
  ci_rows=$((ci_rows + 1))
  check "CI runs on $event with its needs at $result: $runs" "$runs" "$(ci_runs "$WORKFLOW" "$event" "$result")"
done <<ROWS
pull_request|success|yes
pull_request|skipped|yes
pull_request|failure|yes
merge_group|failure|yes
merge_group|skipped|yes
push|success|no
schedule|skipped|no
workflow_dispatch|skipped|no
ROWS
[ "$ci_rows" -ge 8 ] || { echo "the CI table read $ci_rows rows" >&2; exit 1; }
# On a pull request every need is skipped and the classifier never ran, so
# CI passes by running no aggregate; on a merge group the aggregate runs.
# EVENT|STEP|RUNS
while IFS='|' read -r event step runs; do
  check "CI's '$step' step runs on $event: $runs" "$runs" "$(STEP_JOB="$CI_JOB" step_runs "$WORKFLOW" "$step" "$event")"
done <<'ROWS'
pull_request|every needed job succeeded|no
merge_group|every needed job succeeded|yes
pull_request|a pull request runs no lane|yes
merge_group|a pull request runs no lane|no
ROWS
# The workflow's events; the changes job every lane and CI read runs on the
# merge group, the main push and the schedule for their proof routes, and
# the dispatch for its fallback alone.
check "the workflow runs on its five events" "merge_group pull_request push schedule workflow_dispatch" \
  "$(triggers "$WORKFLOW" | tr '\n' ' ' | sed 's/ $//')"
changes_if="$(job_ifs "$WORKFLOW" | awk -F '\t' '$1 == "changes" { print $2 }')"
while IFS='|' read -r event classifies; do
  check "the changes job runs on $event: $classifies" "$classifies" \
    "$(gh_eval value "$(jq -cn --arg e "$event" '{github: {event_name: $e, ref: "refs/heads/main"}}')" "$changes_if")"
done <<'ROWS'
merge_group|true
pull_request|false
push|true
schedule|true
workflow_dispatch|true
ROWS

# --- 2a'. Superseded runs ---------------------------------------------------
# No run cancels another. A pull request, a merge group or a nightly run never
# shares a group with another run, so nothing cancels it, replaces it pending
# or queues it behind one; every push to main shares the ref's group
# and cancels nothing, so a newer push waits and replaces only the pending
# run. Each `${{ }}` of the workflow's concurrency values is evaluated and
# spliced back into its text.
# EVENT|GROUP|CANCEL
concurrency_rows=0
while IFS='|' read -r event group cancel; do
  concurrency_rows=$((concurrency_rows + 1))
  concurrency_ctx="$(jq -cn --arg e "$event" '{github: {workflow: "fixture-ci", event_name: $e, run_id: 7, ref: "refs/heads/main"}}
    | if $e == "pull_request" then .github.event = {pull_request: {number: 42}} else . end')"
  check "a $event run's concurrency group and cancel" "$group $cancel" \
    "$(concurrency_value "$WORKFLOW" group "$concurrency_ctx") $(concurrency_value "$WORKFLOW" cancel-in-progress "$concurrency_ctx")"
done <<'ROWS'
pull_request|fixture-ci-pull_request-7|false
merge_group|fixture-ci-merge_group-7|false
push|fixture-ci-push-refs/heads/main|false
schedule|fixture-ci-schedule-7|false
ROWS
[ "$concurrency_rows" -ge 4 ] || { echo "the concurrency table read $concurrency_rows rows" >&2; exit 1; }


# --- 3. The aggregate -------------------------------------------------------
# CI's real step: the jobs output the changes job publishes, and RESULTS
# holding every job CI needs.
HELD="$(printf '%s\n' "$LANE_ROWS" | awk -F '|' '$3 != "-" { print $1 }')"
results_of() { # [JOB=RESULT...] — changes and every held job succeeded, but as named
  local pair json
  json="$(printf '%s\n' changes $HELD | jq -Rnc '[inputs | select(length > 0) | {key: ., value: {result: "success"}}] | from_entries')"
  for pair in "$@"; do
    json="$(jq -c --arg job "${pair%%=*}" --arg r "${pair#*=}" \
      'if $r == "missing" then del(.[$job]) else .[$job] = {result: $r} end' <<<"$json")"
  done
  printf '%s' "$json"
}
RESULTS="$(results_of)"
aggregate() { # AGGREGATE_SCRIPT JOBS — the exit status, and the refusal key when there is one
  local status=0
  "$1" --results "$RESULTS" --classifier changes --jobs "$2" \
    >"$TMP/aggregate-out" 2>"$TMP/aggregate-err" || status=$?
  printf '%s' "$status"
  sed -n 's/^ci-aggregate: cause=/ /p' "$TMP/aggregate-err" | head -1
}
published_jobs() { # EVENT RESULT SELECTION — the changes job's jobs output
  ctx "$1" "$2" "$3" | jq -r '.needs.changes.outputs.jobs // ""'
}

# CI's own needs hold every LANES job it judges.
RESULTS="$(job_needs "$WORKFLOW" | awk -F '\t' -v j="$CI_JOB" '$1 == j { print $2 }' | tr ',' '\n' |
  jq -Rnc '[inputs | select(length > 0) | {key: ., value: {result: "success"}}] | from_entries')"
check "CI's needs hold every job the table holds" 0 \
  "$(aggregate "$AGGREGATE" "$(printf '%s\n' "$HELD" | jq -Rnc '[inputs]')")"

# A job the selection left out may skip, one it named may not, and a dead
# classifier's fallback list holds every one: README skips catalog and
# smoke; catalog content, compiled renderer inputs and a dead classifier do
# not. JOB|RESULT|PATH|STATUS
while IFS='|' read -r job result path expected; do
  sel=""
  case "$result:$path" in
    success:README.md) sel="$readme" ;;
    success:commands/run.md) sel="$(fetched run_md)" ;;
    success:crates/core/src/render/agent.rs) sel="$(fetched agent_rs)" ;;
  esac
  RESULTS="$(results_of "changes=$result" "$job=skipped")"
  check "$job skipped beside a $result classifier over $path" "$expected" \
    "$(aggregate "$AGGREGATE" "$(published_jobs merge_group "$result" "$sel")")"
done <<'ROWS'
catalog|success|README.md|0
catalog|success|commands/run.md|1
catalog|success|crates/core/src/render/agent.rs|1
catalog|failure|README.md|1
smoke|success|README.md|0
smoke|success|commands/run.md|0
smoke|success|crates/core/src/render/agent.rs|1
ROWS

# The shell shards and the queue's macOS legs: a selected job's failed,
# cancelled, skipped or missing result fails CI, and a passing one or an
# unselected skip does not. A job missing from the needs fails CI whether
# or not it was selected, since its result is unread. ROW|SELECTION|JOB|RESULT|STATUS
while IFS='|' read -r row sel job result expected; do
  RESULTS="$(results_of "$job=$result")"
  check "$CI_JOB over $job at $result on $row" "$expected" \
    "$(aggregate "$AGGREGATE" "$(published_jobs merge_group success "$sel")")"
done <<ROWS
one-skill|$one_skill|skill-suites-shard|skipped|1
one-skill|$one_skill|skill-suites-shard|failure|1
one-skill|$one_skill|skill-suites-shard|cancelled|1
one-skill|$one_skill|skill-suites-shard|missing|1
one-skill|$one_skill|skill-suites-shard|success|0
orch-script|$orch_script|skill-suites-shard|skipped|1
jarvis|$jarvis_change|skill-suites-shard|skipped|1
readme|$readme|skill-suites-shard|skipped|0
readme|$readme|skill-suites-shard|missing|1
orch-script|$orch_script|skill-suites-macos-queue|failure|1
orch-script|$orch_script|skill-suites-macos-queue|cancelled|1
orch-script|$orch_script|skill-suites-macos-queue|skipped|1
orch-script|$orch_script|skill-suites-macos-queue|success|0
readme|$readme|skill-suites-macos-queue|skipped|0
readme|$readme|preflight|skipped|1
ROWS
RESULTS="$(results_of skill-suites-macos-queue=missing)"
aggregate "$AGGREGATE" "$(published_jobs merge_group success "$readme")" >/dev/null
check "a held job missing from the needs is named" 1 \
  "$(grep -c '^ci-aggregate: needed-result=absent job=skill-suites-macos-queue$' "$TMP/aggregate-err" || true)"

# The list itself. A waiver for one job reaches no other, and a list that is
# not one is refused before it can authorize a skip.
LISTED="$HELD"
RESULTS="$(results_of ui-tests=skipped)"
check "a job the list leaves out may skip" 0 \
  "$(aggregate "$AGGREGATE" "$(grep -vx ui-tests <<<"$LISTED" | jq -Rnc '[inputs]')")"
check "a job the list names may not skip" 1 "$(aggregate "$AGGREGATE" '["ui-tests"]')"
RESULTS="$(results_of ui-tests=skipped bot-instructions=skipped)"
check "one job left out authorizes no skip of a listed one" 1 \
  "$(aggregate "$AGGREGATE" '["ui-tests"]')"
# A job whose merge-group cell is `on` runs on every merge group, so no list
# authorizes its skip.
RESULTS="$(results_of preflight=skipped)"
check "a list that leaves out an always-run job authorizes no skip of it" 1 \
  "$(aggregate "$AGGREGATE" "$(grep -vx preflight <<<"$LISTED" | jq -Rnc '[inputs]')")"
# shellcheck disable=SC2046 # one JOB=RESULT word per lane
RESULTS="$(results_of $(printf '%s\n' "$LANE_ROWS" | awk -F '|' '$3 != "-" && $3 != "on" { print $1 "=skipped" }'))"
check "an empty list authorizes every selected lane's skip" 0 "$(aggregate "$AGGREGATE" '[]')"
check "a list that is no JSON list of names is refused" "2 jobs-unreadable value={}" \
  "$(aggregate "$AGGREGATE" '{}')"

# A copy of the script parked where the harness-ci scripts are not, and one
# beside a scripts directory that holds no helper. Exit 1 is the helper's
# rejection of a lane, so neither may answer it.
mkdir -p "$TMP/no-dir/tools" "$TMP/no-helper/tools" "$TMP/no-helper/skills/harness-ci/scripts"
cp "$AGGREGATE" "$TMP/no-dir/tools/ci-aggregate"
cp "$AGGREGATE" "$TMP/no-helper/tools/ci-aggregate"
case "$(aggregate "$TMP/no-dir/tools/ci-aggregate" '[]')" in
  "2 helper-unreadable dir="*) ok "a missing helper directory is a refusal, not a rejected lane" ;;
  *) bad "a missing helper directory is a refusal, not a rejected lane ($(cat "$TMP/aggregate-err"))" ;;
esac
case "$(aggregate "$TMP/no-helper/tools/ci-aggregate" '[]')" in
  "2 helper-missing path="*) ok "a missing helper is a refusal, not a rejected lane" ;;
  *) bad "a missing helper is a refusal, not a rejected lane ($(cat "$TMP/aggregate-err"))" ;;
esac

# A changes job that published nothing, its runner lost, authorizes no skip,
# and the helper names the classifier.
RESULTS="$(results_of changes=failure ui-tests=skipped)"
check "an unpublished list authorizes no skip" 1 "$(aggregate "$AGGREGATE" '')"
check "and the rejection names the classifier, not a parse failure" 1 \
  "$(grep -c 'aggregate-needs: rejected classifier=changes waiver=false' "$TMP/aggregate-err")"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
