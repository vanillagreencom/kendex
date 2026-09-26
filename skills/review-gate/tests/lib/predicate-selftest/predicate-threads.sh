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
a waiver resolution answered by its resolver since is theirs, not a waiver|1|true|terminal|[{"isResolved":true,"resolvedBy":{"login":"vanillagreen-fleet-lanes[bot]"},"comments":{"pageInfo":{"hasNextPage":false},"nodes":[{"body":"Issue KEN-1 does not exist","author":{"login":"copilot-pull-request-reviewer","__typename":"Bot"}},{"body":"Resolved by the merge route: change class trivial at 1111111111111111111111111111111111111111, review evidence none under REVIEW_GATE_CLASS_POLICY","author":{"login":"vanillagreen-fleet-lanes","__typename":"Bot"}},{"body":"Fixed in abc1234","author":{"login":"vanillagreen-fleet-lanes","__typename":"Bot"}}]}}]||approved|0
a waiver thread someone else resolved again is theirs, not a waiver|1|true|terminal|[{"isResolved":true,"resolvedBy":{"login":"bmethod"},"comments":{"pageInfo":{"hasNextPage":false},"nodes":[{"body":"Issue KEN-1 does not exist","author":{"login":"copilot-pull-request-reviewer","__typename":"Bot"}},{"body":"Resolved by the merge route: change class trivial at 1111111111111111111111111111111111111111, review evidence none under REVIEW_GATE_CLASS_POLICY","author":{"login":"vanillagreen-fleet-lanes","__typename":"Bot"}}]}}]||approved|0
CASES
