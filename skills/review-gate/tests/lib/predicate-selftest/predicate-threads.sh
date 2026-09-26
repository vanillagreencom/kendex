# shellcheck shell=bash
# A complete advancing walk sums resolved state. The final page of an
# over-budget fixture is resolved, so removing the budget would approve it.
# A resolved thread whose merge-route waiver still stands counts as open: this
# world's class policy is inactive, which reaches the thread term the way a
# class sent for review does, and a none class never reaches it.
# name|page count|last resolved|initial cursor|first nodes JSON|empty read|verdict|exit
while IFS='|' read -r name pages resolved cursor nodes empty want expected_exit; do
  reset
  CFG_CONTEXTS=mech-ctx; CFG_THREADS=enforce
  CFG_API_ATTEMPTS=1; CFG_API_DELAY=0
  status_ctx mech-ctx success 'analysis complete'
  next=false
  if [ "$pages" -gt 1 ] || [ "$cursor" != terminal ]; then next=true; fi
  if [ "$cursor" = terminal ] || [ "$cursor" = missing ]; then
    jq -n --argjson next "$next" --argjson nodes "$nodes" \
      '{data:{repository:{pullRequest:{reviewThreads:{pageInfo:{hasNextPage:$next},nodes:$nodes}}}}}' >"$fixtures/graphql.json"
  else
    jq -n --argjson next "$next" --arg cursor "$cursor" --argjson nodes "$nodes" \
      '{data:{repository:{pullRequest:{reviewThreads:{pageInfo:{hasNextPage:$next,endCursor:$cursor},nodes:$nodes}}}}}' >"$fixtures/graphql.json"
  fi
  i=2
  while [ "$i" -le "$pages" ]; do
    next=true; page_resolved=true
    if [ "$i" = "$pages" ]; then next=false; page_resolved="$resolved"; fi
    jq -n --arg cursor "C$((i + 1))" --argjson next "$next" --argjson resolved "$page_resolved" \
      '{data:{repository:{pullRequest:{reviewThreads:{pageInfo:{hasNextPage:$next,endCursor:$cursor},nodes:[{isResolved:$resolved}]}}}}}' \
      >"$fixtures/graphql.cursor-C$i.json"
    i=$((i + 1))
  done
  [ "$empty" != yes ] || export GH_SHIM_EMPTY=graphql
  run "$name" "$want" "$expected_exit"
done <<'CASES'
missing advancing cursor|1|true|missing|[]||threads-open|0
resolved follow-up page|2|true|C2|[{"isResolved":true},{"isResolved":true}]||approved|0
unresolved follow-up page|2|false|C2|[{"isResolved":true},{"isResolved":true}]||threads-open|0
walk past page budget|21|true|C2|[{"isResolved":true}]||threads-open|0
walk at page budget|20|true|C2|[{"isResolved":true}]||approved|0
unreadable cursor fixture|1|true|bad/value|[{"isResolved":true}]|||2
zero-byte thread read|1|true|terminal|[]|yes||2
null resolved state|1|true|terminal|[{"isResolved":null},{"isResolved":true}]||threads-open|0
a waiver resolution the merge route made still stands, lapsed where review is due|1|true|terminal|[{"isResolved":true,"resolvedBy":{"login":"vanillagreen-fleet-lanes[bot]"},"comments":{"pageInfo":{"hasNextPage":false},"nodes":[{"body":"Issue KEN-1 does not exist","author":{"login":"copilot-pull-request-reviewer","__typename":"Bot"}},{"body":"Resolved by the merge route: change class trivial at 1111111111111111111111111111111111111111, review evidence none under REVIEW_GATE_CLASS_POLICY","author":{"login":"vanillagreen-fleet-lanes","__typename":"Bot"}}]}}]||threads-open|0
a second waiver resolution by the same resolver still stands, lapsed where review is due|1|true|terminal|[{"isResolved":true,"resolvedBy":{"login":"vanillagreen-fleet-lanes[bot]"},"comments":{"pageInfo":{"hasNextPage":false},"nodes":[{"body":"Issue KEN-1 does not exist","author":{"login":"copilot-pull-request-reviewer","__typename":"Bot"}},{"body":"Resolved by the merge route: change class trivial at 1111111111111111111111111111111111111111, review evidence none under REVIEW_GATE_CLASS_POLICY","author":{"login":"vanillagreen-fleet-lanes","__typename":"Bot"}},{"body":"Resolved by the merge route: change class trivial at 3333333333333333333333333333333333333333, review evidence none under REVIEW_GATE_CLASS_POLICY","author":{"login":"vanillagreen-fleet-lanes","__typename":"Bot"}}]}}]||threads-open|0
a waiver resolution answered by its resolver since is theirs, not a waiver|1|true|terminal|[{"isResolved":true,"resolvedBy":{"login":"vanillagreen-fleet-lanes[bot]"},"comments":{"pageInfo":{"hasNextPage":false},"nodes":[{"body":"Issue KEN-1 does not exist","author":{"login":"copilot-pull-request-reviewer","__typename":"Bot"}},{"body":"Resolved by the merge route: change class trivial at 1111111111111111111111111111111111111111, review evidence none under REVIEW_GATE_CLASS_POLICY","author":{"login":"vanillagreen-fleet-lanes","__typename":"Bot"}},{"body":"Fixed in abc1234","author":{"login":"vanillagreen-fleet-lanes","__typename":"Bot"}}]}}]||approved|0
a waiver thread someone else resolved again is theirs, not a waiver|1|true|terminal|[{"isResolved":true,"resolvedBy":{"login":"bmethod"},"comments":{"pageInfo":{"hasNextPage":false},"nodes":[{"body":"Issue KEN-1 does not exist","author":{"login":"copilot-pull-request-reviewer","__typename":"Bot"}},{"body":"Resolved by the merge route: change class trivial at 1111111111111111111111111111111111111111, review evidence none under REVIEW_GATE_CLASS_POLICY","author":{"login":"vanillagreen-fleet-lanes","__typename":"Bot"}}]}}]||approved|0
CASES

# The waiver rule is a file beside the predicate. A copy of the scripts tree
# without it refuses with no verdict and names that file, rather than read a
# lapsed waiver as a resolved thread or fail later on an unrelated read.
reset
CFG_CONTEXTS=mech-ctx; CFG_THREADS=enforce
status_ctx mech-ctx success 'analysis complete'
no_rule="$work/no-waiver-rule"
mkdir -p "$no_rule/lib"
cp "$here/review-predicate.sh" "$no_rule/"
cp "$here/lib/settings.sh" "$here/lib/diagnostics.sh" "$no_rule/lib/"
if [ -e "$no_rule/lib/waiver.sh" ]; then
  echo "FAIL  the no-rule copy of the scripts tree still holds lib/waiver.sh" >&2
  failures=$((failures + 1))
else
  shipped_predicate="$predicate"
  predicate="$no_rule/review-predicate.sh"
  run "a predicate without its waiver rule refuses" "" 2
  predicate="$shipped_predicate"
  printf -v quoted '%q' "$no_rule/lib/waiver.sh"
  expected="review-gate-error=predicate-waiver-load value=$quoted"
  if [ "${LAST_ERROR%%$'\n'*}" != "$expected" ]; then
    echo "FAIL  a predicate without its waiver rule emitted ${LAST_ERROR%%$'\n'*}, wanted $expected" >&2
    failures=$((failures + 1))
  fi
  # The refusal is where the run stops: a second error record means it read
  # on without the rule and failed somewhere else too.
  error_records="$(printf '%s\n' "$LAST_ERROR" | grep -c '^review-gate-error=')"
  if [ "$error_records" != 1 ]; then
    echo "FAIL  a predicate without its waiver rule emitted $error_records error records, wanted 1" >&2
    failures=$((failures + 1))
  fi
fi
