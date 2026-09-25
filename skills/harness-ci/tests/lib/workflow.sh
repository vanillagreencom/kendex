#!/usr/bin/env bash
# Line readers for a GitHub Actions workflow file, shared by the suites that
# ask which of a workflow's jobs run: this package's ci-template suite and
# kendex's own tools/tests/ci-class-job-set.test.sh. gh-eval.py beside this
# file evaluates what they read.
#
# Sourced, never run. Each reader takes the workflow path and reads only the
# lines at a job's own indent under `jobs:`, the two-space job keys and the
# four-space keys beneath them, so a key nested deeper is never taken for a
# job's own.

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
