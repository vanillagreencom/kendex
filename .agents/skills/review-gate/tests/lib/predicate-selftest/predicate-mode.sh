# shellcheck shell=bash
# Sourced by review-predicate-selftest.sh with its neutral fixture world.
# REVIEW_GATE_MODE (the one-switch gate disable, owner-controlled):
# "off" answers approved before ANY evidence read — the urls.log pin proves
# zero API traffic, so a disabled gate can never leak reads or block on a
# broken API. The detail is an attestation ("disabled by settings"), never
# a review claim. An unknown value is exit 2: a typo cannot disable a gate.
reset
CFG_GATE_MODE="off"
run "mode off: approved without evaluating anything" approved
# The detail is the attestation CONTRACT, not decoration: statuses converged
# from this verdict must say the gate is disabled, never imply a review
# happened — pin the exact line the case above emitted.
cases=$((cases + 1))
if [ "$LAST_LINE" = "verdict=approved detail=review gate disabled by settings (REVIEW_GATE_MODE=off)" ]; then
  echo "ok    mode off: the attestation detail is exact (statuses never imply a review)"
else
  echo "FAIL  mode off attestation detail drifted: '$LAST_LINE'" >&2
  failures=$((failures + 1))
fi
if [ -f "$fixtures/.urls.log" ] && [ -s "$fixtures/.urls.log" ]; then
  echo "FAIL  mode off must make ZERO API reads (urls.log: $(tr '\n' ' ' <"$fixtures/.urls.log"))" >&2
  failures=$((failures + 1))
else
  echo "ok    mode off makes zero API reads (urls.log empty)"
fi
cases=$((cases + 1))

reset
CFG_GATE_MODE="off"
reviews_set "$(review "objector" CHANGES_REQUESTED "2026-01-02T00:00:00Z")"
threads false >"$fixtures/graphql.json"
run "mode off: even standing objections and open threads are not read" approved

reset
CFG_GATE_MODE="offf"
run "mode: an unknown value is a loud config error, never a disabled gate" "" 2
