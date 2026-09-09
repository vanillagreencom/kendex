# shellcheck shell=bash
# Sourced by review-predicate-selftest.sh with its neutral fixture world.
# Thread-term configurability: REVIEW_GATE_THREADS=off never
# emits threads-open AND skips the GraphQL read entirely — proven by making
# the endpoint fail, which must not matter when the read is skipped.
reset
CFG_CONTEXTS="mech-ctx"; CFG_THREADS="off"
status_ctx "mech-ctx" success "analysis complete"
threads false >"$fixtures/graphql.json"
run "threads=off: unresolved thread does not close the gate" approved

reset
CFG_CONTEXTS="mech-ctx"; CFG_THREADS="off"
status_ctx "mech-ctx" success "analysis complete"
export GH_SHIM_FAIL=graphql
run "threads=off: the reviewThreads read is skipped entirely (failing endpoint cannot matter)" approved
unset GH_SHIM_FAIL
cases=$((cases + 1))
# Fail-closed on the instrument itself: a missing/empty url log proves
# nothing about the read being skipped; the run above made
# other API reads, so the log must exist and be non-empty.
if [ ! -s "$fixtures/.urls.log" ]; then
  echo "FAIL  threads=off url log missing or empty - cannot prove the read was skipped" >&2
  failures=$((failures + 1))
elif grep -q '^graphql$' "$fixtures/.urls.log"; then
  echo "FAIL  threads=off issued a reviewThreads read anyway" >&2
  failures=$((failures + 1))
else
  echo "ok    threads=off issues no reviewThreads read (url log)"
fi

reset
CFG_CONTEXTS="mech-ctx"; CFG_THREADS="enforce"
status_ctx "mech-ctx" success "analysis complete"
threads false >"$fixtures/graphql.json"
run "threads=enforce (the default): unresolved thread still fails closed" threads-open

reset
CFG_THREADS="sometimes"
run "unknown REVIEW_GATE_THREADS value is a config error" "" 2
