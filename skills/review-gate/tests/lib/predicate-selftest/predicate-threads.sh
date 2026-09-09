# shellcheck shell=bash
# A complete advancing walk sums resolved state. The final page of an
# over-budget fixture is resolved, so removing the budget would approve it.
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
CASES
