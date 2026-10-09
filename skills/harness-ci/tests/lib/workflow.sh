#!/usr/bin/env bash
# Line readers for a GitHub Actions workflow file, shared by the suites that
# ask which of a workflow's jobs run: this package's ci-template suite and
# kendex's own tools/tests/ci-aggregate.test.sh. gh-eval.py beside this
# file evaluates what they read.
#
# Sourced, never run. Each reader takes the workflow path and reads only the
# lines at a job's own indent under `jobs:`, the two-space job keys and the
# four-space keys beneath them, so a key nested deeper is never taken for a
# job's own.

GH_EVAL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gh-eval.py"

# gh-eval.py with its status checked. A refusal prints `gh-eval-refused:` and
# the evaluator's own cause line in place of an answer, so no caller reading
# the output inside a command substitution can take a refusal, or a job list
# a refusal cut short, for the empty answer a stand-down gives.
gh_eval() { # MODE CONTEXT_JSON [EXPR] — stdin passes through
  local out status=0
  out="$(python3 "$GH_EVAL" "$@" 2>&1)" || status=$?
  if [ "$status" -ne 0 ]; then
    printf 'gh-eval-refused:%s %s\n' "$status" "$(awk '/^gh-eval: / { sub(/^gh-eval: /, ""); print; exit }' <<<"$out")"
    printf 'gh-eval-refused:%s\n%s\n' "$status" "$out" >&2
    return 0
  fi
  [ -z "$out" ] || printf '%s\n' "$out"
}

# One `JOB<tab>EXPR` line per job with a job-level `if:`, the `${{ }}`
# stripped.
job_ifs() { # WORKFLOW
  awk '
    /^jobs:/ { in_jobs = 1; next }
    !in_jobs { next }
    /^  [A-Za-z0-9_-]+:/ { job = $1; sub(/:$/, "", job); next }
    /^    if:/ {
      expr = $0
      sub(/^    if:[ ]*/, "", expr)
      if (substr(expr, 1, 3) == "${{") { expr = substr(expr, 4); sub(/}}[ ]*$/, "", expr) }
      print job "\t" expr
    }
  ' "$1"
}

# `JOB<tab>NEED,NEED` for every job, from its one-line `needs:`. A needs list
# spelled over several lines prints `?`, which gh-eval.py refuses as a job it
# was given no result for.
job_needs() { # WORKFLOW
  awk '
    /^jobs:/ { in_jobs = 1; next }
    !in_jobs { next }
    /^  [A-Za-z0-9_-]+:/ { if (job != "") print job "\t" needs; job = $1; sub(/:$/, "", job); needs = ""; next }
    /^    needs:/ {
      needs = $0
      sub(/^    needs:[ ]*/, "", needs); gsub(/[][ ]/, "", needs)
      if (needs == "") needs = "?"
    }
    END { if (job != "") print job "\t" needs }
  ' "$1"
}

# The key of each job whose `name:` is exactly NAME.
jobs_named() { # WORKFLOW NAME
  NAME="$2" awk '
    /^jobs:/ { in_jobs = 1; next }
    !in_jobs { next }
    /^  [A-Za-z0-9_-]+:/ { job = $1; sub(/:$/, "", job); next }
    /^    name: / { name = $0; sub(/^    name: /, "", name); if (name == ENVIRON["NAME"]) print job }
  ' "$1"
}

# The events under the top-level `on:` key, sorted, one per line.
triggers() { # WORKFLOW
  awk '
    /^("on"|on):/ { on = 1; next }
    on && /^[^ ]/ { exit }
    on && /^  [a-z_]+:/ { sub(/:.*/, ""); sub(/^  /, ""); print }
  ' "$1" | LC_ALL=C sort
}

# The entries of JOB's own `permissions:` block, `scope: level` each, sorted
# and blank-separated; the workflow-level block is never read.
job_permissions() { # WORKFLOW JOB
  awk -v job="$2" '
    /^  [A-Za-z0-9_-]+:/ { in_job = ($1 == job ":"); in_perms = 0; next }
    in_job && /^    permissions:/ { in_perms = 1; next }
    in_job && in_perms && /^      [a-z-]+: / { sub(/^ +/, ""); print; next }
    in_perms { in_perms = 0 }
  ' "$1" | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//'
}

# Evaluate each expression in a workflow-level concurrency value with the
# same evaluator as job conditions, retaining the text between expressions.
concurrency_value() { # WORKFLOW KEY CONTEXT_JSON
  local raw ctx="$3" out="" expr value
  raw="$(awk -v key="$2" '
    /^concurrency:/ { on = 1; next }
    on && /^[^ ]/ { exit }
    on && $1 == key ":" { sub(/^ *[a-z-]+: */, ""); print }
  ' "$1")"
  [ -n "$raw" ] || { printf 'no-concurrency-%s' "$2"; return 0; }
  while [ -n "$raw" ]; do
    case "$raw" in
      *'${{'*)
        out="$out${raw%%'${{'*}"
        raw="${raw#*'${{'}"
        expr="${raw%%'}}'*}"
        raw="${raw#*'}}'}"
        value="$(gh_eval value "$ctx" "$expr" | jq -er 'if . == null then "" else tostring end')" || return 1
        out="$out$value"
        ;;
      *) out="$out$raw"; raw="" ;;
    esac
  done
  printf '%s' "$out"
}

# Whether the job named CI runs on EVENT with every job it needs at RESULT:
# `yes`, `no`, or the refusal gh_eval printed.
ci_runs() { # WORKFLOW EVENT RESULT
  local wf="$1" ci needs expr ctx out
  ci="$(jobs_named "$wf" CI)"
  needs="$(job_needs "$wf" | awk -F '\t' -v j="$ci" '$1 == j { print $2 }')"
  expr="$(job_ifs "$wf" | awk -F '\t' -v j="$ci" '$1 == j { print $2 }')"
  ctx="$(jq -cn --arg event "$2" --arg result "$3" --arg needs "$needs" \
    '{github: {event_name: $event}, needs: ($needs | split(",") | map({key: ., value: {result: $result}}) | from_entries)}')"
  out="$(printf '%s\t%s\t%s\n' "$ci" "$needs" "$expr" | gh_eval jobs "$ctx")"
  case "$out" in
    "$ci") echo yes ;;
    "") echo no ;;
    *) printf '%s' "$out" ;;
  esac
}

# A copy of SRC with FROM replaced by TO, where FROM occurs once in the file,
# or once inside the job JOB when one is named; any other count, or an edit
# that changes nothing, stops the calling suite. MATCH=line requires the
# entire line, so a job condition cannot match a nested step condition.
plant() { # SRC FROM TO OUT [JOB] [MATCH=substring|line]
  local src="$1" from="$2" to="$3" out="$4" job="${5:-}" match="${6:-substring}"
  case "$match" in
    substring|line) ;;
    *) echo "plant: unknown match mode: $match" >&2; exit 1 ;;
  esac
  FROM="$from" TO="$to" JOB="$job" MATCH="$match" awk '
    /^  [A-Za-z0-9_-]+:/ { k = $1; sub(/:$/, "", k) }
    {
      i = (ENVIRON["JOB"] == "" || k == ENVIRON["JOB"]) &&
          (ENVIRON["MATCH"] != "line" || $0 == ENVIRON["FROM"]) ? index($0, ENVIRON["FROM"]) : 0
    }
    i > 0 { n++; $0 = substr($0, 1, i - 1) ENVIRON["TO"] substr($0, i + length(ENVIRON["FROM"])) }
    { print }
    END {
      if (n != 1) {
        printf "plant: the planted text occurs %d times in job [%s]: %s\n", n + 0, ENVIRON["JOB"], ENVIRON["FROM"] > "/dev/stderr"
        exit 1
      }
    }
  ' "$src" >"$out" || exit 1
  ! cmp -s "$src" "$out" || { echo "plant: the planted edit changed nothing: $from" >&2; exit 1; }
}
