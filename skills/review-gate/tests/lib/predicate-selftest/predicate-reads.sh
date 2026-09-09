# shellcheck shell=bash
# Sourced by review-predicate-selftest.sh with its neutral fixture world.
# Guards the whole suite: if this ever says `approved`, some evidence source
# has become unconditionally true and every case below is meaningless.
reset
run "no evidence at all" awaiting
# The changelog's one claim about this status is that it names the head.
cases=$((cases + 1))
case "$LAST_LINE" in "verdict=awaiting detail=no review evidence at $HEAD yet") echo "ok    the awaiting detail names the head sha (awaiting)" ;;
  *) echo "FAIL  the awaiting detail drops the head sha: $LAST_LINE" >&2; failures=$((failures + 1)) ;; esac

# The shim emits stderr on failure, as gh does. The stable read diagnostic
# must precede that detail and the caller's more specific refusal.
while IFS='|' read -r endpoint request; do
  reset
  CFG_CONTEXTS=mech-ctx; CFG_THREADS=enforce
  if [ "$endpoint" = graphql ]; then status_ctx mech-ctx success 'analysis complete'; fi
  export GH_SHIM_FAIL="$endpoint"
  run "$endpoint read failure" "" 2
  printf -v quoted '%q' "1:$request"
  if [ "${LAST_ERROR%%$'\n'*}" != "review-gate-error=predicate-api-read value=$quoted" ]; then
    rg_message error selftest-api-diagnostic "$endpoint" "API failure did not start with its stable diagnostic." >&2
    failures=$((failures + 1))
  fi
done <<EOF
reviews|repos/owner/repo/pulls/1/reviews?per_page=100
statuses|repos/owner/repo/commits/$HEAD/statuses?per_page=100
checkruns|repos/owner/repo/commits/$HEAD/check-runs?check_name=mech-ctx&per_page=100
graphql|graphql
EOF
