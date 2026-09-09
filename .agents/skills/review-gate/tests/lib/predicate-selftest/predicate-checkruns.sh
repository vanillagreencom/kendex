# shellcheck shell=bash
# Check-run ids order each publisher's analysis rounds. The Actions publisher
# is removed before validating ids; a missing app stays in the sequence.
# name|verdict|exit|runs JSON|requires skip marker
first_skip="$(list_items "$ACTIVE_SKIPS")" || exit 1
first_skip="${first_skip%%$'\n'*}"
clean='{"id":1,"name":"mech-ctx","conclusion":"success","app":{"slug":"trusted-reviewer-app"},"output":{"title":null,"summary":"analysis complete"}}'
rows="$(cat <<EOF
trusted app|approved|0|[$clean]|
Actions app|awaiting|0|[{"id":1,"name":"mech-ctx","conclusion":"success","app":{"slug":"github-actions"},"output":{"summary":"analysis complete"}}]|
missing app|awaiting|0|[{"id":1,"name":"mech-ctx","conclusion":"success","output":{"title":null,"summary":"analysis complete"}}]|
newer running masks success|awaiting|0|[{"id":2,"name":"mech-ctx","conclusion":null,"status":"in_progress","app":{"slug":"trusted-reviewer-app"},"output":{"title":null,"summary":null}},$clean]|
newer skipped masks success|awaiting|0|[{"id":2,"name":"mech-ctx","conclusion":"success","app":{"slug":"trusted-reviewer-app"},"output":{"title":null,"summary":null}},$clean]|yes
newer success over failure|approved|0|[{"id":2,"name":"mech-ctx","conclusion":"success","app":{"slug":"trusted-reviewer-app"},"output":{"title":null,"summary":"analysis complete"}},{"id":1,"name":"mech-ctx","conclusion":"failure","app":{"slug":"trusted-reviewer-app"},"output":{"title":null,"summary":"findings posted"}}]|
Actions cannot mask success|approved|0|[{"id":2,"name":"mech-ctx","conclusion":null,"status":"queued","app":{"slug":"github-actions"},"output":{"title":null,"summary":null}},$clean]|
missing retained id||2|[{"name":"mech-ctx","conclusion":null,"status":"in_progress","app":{"slug":"trusted-reviewer-app"},"output":{"title":null,"summary":null}},$clean]|
string retained id||2|[{"id":"2","name":"mech-ctx","conclusion":null,"status":"in_progress","app":{"slug":"trusted-reviewer-app"},"output":{"title":null,"summary":null}},$clean]|
Actions id validation skipped|approved|0|[{"name":"mech-ctx","conclusion":null,"status":"queued","app":{"slug":"github-actions"},"output":{"title":null,"summary":null}},$clean]|
newest missing app masks success|awaiting|0|[{"id":2,"name":"mech-ctx","conclusion":"success","output":{"title":null,"summary":"analysis complete"}},$clean]|
oldest row listed first|approved|0|[{"id":1,"name":"mech-ctx","conclusion":"failure","app":{"slug":"trusted-reviewer-app"},"output":{"title":null,"summary":"findings posted"}},{"id":2,"name":"mech-ctx","conclusion":"success","app":{"slug":"trusted-reviewer-app"},"output":{"title":null,"summary":"analysis complete"}}]|
EOF
)" || exit 1
while IFS='|' read -r name want exit_code runs requires_skip; do
  if [ "$requires_skip" = yes ] && [ -z "$first_skip" ]; then continue; fi
  if [ "$requires_skip" = yes ]; then
    runs="$(jq -c --arg skip "Review $first_skip. 0 files reviewed." '.[0].output.summary=$skip' <<<"$runs")" || exit 1
  fi
  reset
  CFG_CONTEXTS=mech-ctx
  printf '{"check_runs":%s}\n' "$runs" >"$fixtures/checkruns.json"
  run "$name" "$want" "$exit_code"
done <<<"$rows"
