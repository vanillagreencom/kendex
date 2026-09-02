#!/usr/bin/env bash
# Every issue read keeps completed blocking relations as history while
# identifying only blockers that still prevent dispatch.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../scripts/lib/formatters.sh
source "$SKILL_DIR/scripts/lib/formatters.sh"
expected_inverse_query="$(tr -d '[:space:]' <<<"$ISSUE_BLOCKED_BY_FIELDS")"
inverse_has_type="false"
[[ "$ISSUE_BLOCKED_BY_FIELDS" == *'state { name type }'* ]] && inverse_has_type="true"
assert_tmpdir TMP_ROOT

mkdir -p "$TMP_ROOT/.agents/skills" "$TMP_ROOT/bin" "$TMP_ROOT/.cache/linear"
cp -R "$SKILL_DIR" "$TMP_ROOT/.agents/skills/linear"
git -C "$TMP_ROOT" init -q -b main

# This root's own cache is the subject, so it replaces the assert lib's default
# sandbox — still scratch, so the exit verdict's containment check holds.
export LINEAR_CACHE_ROOT="$TMP_ROOT"

main='{"id":"issue-1","identifier":"KEN-1","title":"dependent","description":"","state":{"name":"Todo","type":"unstarted"},"assignee":null,"project":{"id":"project-1","name":"Project"},"projectMilestone":null,"cycle":null,"parent":null,"team":{"name":"Kendex"},"labels":{"nodes":[]},"priority":0,"estimate":null,"sortOrder":0,"url":"","createdAt":"","updatedAt":"","archivedAt":null,"trashed":false,"children":{"nodes":[]},"relations":{"nodes":[]},"inverseRelations":{"nodes":[{"id":"rel-open","type":"blocks","issue":{"id":"issue-2","identifier":"KEN-2","title":"open","state":{"name":"Working","type":"started"}}},{"id":"rel-done","type":"blocks","issue":{"id":"issue-3","identifier":"KEN-3","title":"done","state":{"name":"Shipped","type":"completed"}}},{"id":"rel-canceled","type":"blocks","issue":{"id":"issue-4","identifier":"KEN-4","title":"canceled","state":{"name":"Abandoned","type":"canceled"}}}]}}'
child="$(jq -cn --argjson base "$main" '$base | .id = "issue-6" | .identifier = "KEN-6" | .title = "child" | .parent = {identifier: "KEN-1"}')"
terminal_only="$(jq -cn --argjson base "$main" '$base | .id = "issue-5" | .identifier = "KEN-5" | .title = "ready" | .state = {name: "Backlog", type: "backlog"} | .inverseRelations.nodes |= map(select(.issue.state.type != "started"))')"
research="$(jq -cn --argjson base "$main" '$base | .id = "issue-7" | .identifier = "KEN-7" | .title = "research" | .state = {name: "In Progress", type: "started"} | .labels.nodes = [{name: "research"}] | .inverseRelations.nodes = [] | .relations.nodes = [{id: "out-open", type: "blocks", relatedIssue: {id: "issue-2", identifier: "KEN-2", title: "open", state: {name: "Working", type: "started"}}}, {id: "out-done", type: "blocks", relatedIssue: {id: "issue-3", identifier: "KEN-3", title: "done", state: {name: "Shipped", type: "completed"}}}, {id: "out-canceled", type: "blocks", relatedIssue: {id: "issue-4", identifier: "KEN-4", title: "canceled", state: {name: "Abandoned", type: "canceled"}}}]')"
bundle="$(jq -cn --argjson base "$main" --argjson child "$child" '$base | .children.nodes = [$child]')"
cache_issues="$(jq -cn --argjson main "$main" --argjson ready "$terminal_only" --argjson research "$research" --argjson child "$child" '[$main, $ready, $research, $child]')"
printf '%s\n' "$cache_issues" >"$TMP_ROOT/.cache/linear/issues.json"
printf '%s\n' '[{"id":"project-1","name":"Project","state":"started","priority":1,"progress":0,"labels":{"nodes":[]},"relations":{"nodes":[]},"inverseRelations":{"nodes":[]}}]' >"$TMP_ROOT/.cache/linear/projects.json"
printf '%s\n' '[]' >"$TMP_ROOT/.cache/linear/cycles.json"
printf '{"synced_at":"%s"}\n' "$(date -Iseconds)" >"$TMP_ROOT/.cache/linear/meta.json"

cat >"$TMP_ROOT/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
config="$(cat)"
payload="$(sed -n 's/^data = //p' <<<"$config" | jq -r)"
query="$(jq -r '.query' <<<"$payload")"
compact="$(tr -d '[:space:]' <<<"$query")"
printf '%s\n' "$compact" >>"$QUERY_LOG"

count_literal() {
  local remaining="$1" needle="$2" count=0
  while [[ "$remaining" == *"$needle"* ]]; do
    remaining="${remaining#*"$needle"}"
    count=$((count + 1))
  done
  printf '%s\n' "$count"
}

case "$query" in
*"ListIssues"*|*"BulkGetIssues"*)
  response="$(jq -cn --argjson issue "$FIXTURE_MAIN" '{data:{issues:{nodes:[$issue],pageInfo:{hasNextPage:false,endCursor:null}}}}')"
  ;;
*"GetIssueWithBundle"*|*"GetChildrenRecursive"*)
  response="$(jq -cn --argjson issue "$FIXTURE_BUNDLE" '{data:{issue:$issue}}')"
  ;;
*"GetRelations"*|*"GetIssue"*|*"issue(id:"*)
  response="$(jq -cn --argjson issue "$FIXTURE_MAIN" '{data:{issue:$issue}}')"
  ;;
*)
  response='{"errors":[{"message":"unexpected query"}]}'
  ;;
esac

inverse_count="$(count_literal "$compact" 'inverseRelations{')"
shared_count="$(count_literal "$compact" "$EXPECTED_INVERSE_QUERY")"
if [[ "$INVERSE_HAS_TYPE" != "true" || "$inverse_count" != "$shared_count" ]]; then
  response="$(jq 'walk(if type == "object" and has("inverseRelations") then .inverseRelations.nodes |= map(del(.issue.state.type)) else . end)' <<<"$response")"
fi
printf '%s___HTTP_CODE___200' "$response"
SH
chmod +x "$TMP_ROOT/bin/curl"

LINEAR="$TMP_ROOT/.agents/skills/linear/scripts/linear.sh"
run_live() {
  (cd "$TMP_ROOT" && PATH="$TMP_ROOT/bin:$PATH" LINEAR_API_KEY_OVERRIDE=test-token \
    QUERY_LOG="$TMP_ROOT/query.log" FIXTURE_MAIN="$main" FIXTURE_BUNDLE="$bundle" \
    EXPECTED_INVERSE_QUERY="$expected_inverse_query" INVERSE_HAS_TYPE="$inverse_has_type" bash "$LINEAR" "$@")
}
run_cache() {
  (cd "$TMP_ROOT" && bash "$LINEAR" "$@")
}
assert_issue() {
  assert_jq "$1" "$2" "$3 | .blocked_by == [\"KEN-2\", \"KEN-3\", \"KEN-4\"] and .blocked_by_open == [\"KEN-2\"]"
}

assert_issue "live get safe filters by state type" "$(run_live issues get KEN-1 --format=safe)" '.'
assert_issue "live get compact filters by state type" "$(run_live issues get KEN-1 --format=compact)" '.'
assert_issue "live list safe filters by state type" "$(run_live issues list --format=safe)" '.[0]'
assert_issue "live list compact filters by state type" "$(run_live issues list --format=compact)" '.[0]'
assert_jq "live relation analysis filters by state type" "$(run_live issues list --with-relations --format=raw)" \
  '.blocked[0].blocked_by == ["KEN-2"]'
assert_issue "live bulk-get filters by state type" "$(run_live issues bulk-get KEN-1 --format=safe)" '.[0]'

live_bundle="$(run_live issues get KEN-1 --with-bundle --format=safe)"
assert_issue "live bundle root filters by state type" "$live_bundle" '.'
assert_issue "live bundle child filters by state type" "$live_bundle" '.children[0]'
live_bundle_compact="$(run_live issues get KEN-1 --with-bundle --format=compact)"
assert_issue "live compact bundle root filters by state type" "$live_bundle_compact" '.'
assert_issue "live compact bundle child filters by state type" "$live_bundle_compact" '.children[0]'
assert_issue "live recursive children filter by state type" "$(run_live issues children KEN-1 --recursive --format=safe)" '.[0]'

live_relations="$(run_live issues list-relations KEN-1 --format=safe)"
assert_jq "live relations keep history and filter open blockers" "$live_relations" \
  '[.blocked_by[].id] == ["KEN-2", "KEN-3", "KEN-4"] and [.blocked_by_open[].id] == ["KEN-2"]'

assert_issue "cache get safe filters by state type" "$(run_cache cache issues get KEN-1 --format=safe)" '.'
assert_issue "cache get compact filters by state type" "$(run_cache cache issues get KEN-1 --format=compact)" '.'
assert_issue "cache list safe filters by state type" "$(run_cache cache issues list --all-projects --max --format=safe)" '.[0]'
assert_issue "cache list compact filters by state type" "$(run_cache cache issues list --all-projects --max --format=compact)" '.[0]'
assert_issue "cache bulk-get filters by state type" "$(run_cache cache issues bulk-get KEN-1 --format=safe)" '.[0]'

cache_bundle="$(run_cache cache issues get KEN-1 --with-bundle --format=safe)"
assert_issue "cache bundle root filters by state type" "$cache_bundle" '.'
assert_issue "cache bundle child filters by state type" "$cache_bundle" '.children[0]'
cache_bundle_compact="$(run_cache cache issues get KEN-1 --with-bundle --format=compact)"
assert_issue "cache compact bundle root filters by state type" "$cache_bundle_compact" '.'
assert_issue "cache compact bundle child filters by state type" "$cache_bundle_compact" '.children[0]'
assert_issue "cache recursive children filter by state type" "$(run_cache cache issues children KEN-1 --recursive --format=safe)" '.[0]'

cache_relations="$(run_cache cache issues list-relations KEN-1)"
assert_jq "cache relations keep history and filter open blockers" "$cache_relations" \
  '[.blocked_by[].id] == ["KEN-2", "KEN-3", "KEN-4"] and [.blocked_by_open[].id] == ["KEN-2"]'

session="$(run_cache session-status)"
assert_jq "session status routes open blockers to blocked" "$session" \
  '([.issues.blocked[] | select(.id == "KEN-1")][0]) | .blocked_by == ["KEN-2", "KEN-3", "KEN-4"] and .blocked_by_open == ["KEN-2"]'
assert_jq "session status routes terminal-only history to backlog" "$session" \
  '([.issues.backlog[] | select(.id == "KEN-5")][0]) | .blocked_by == ["KEN-3", "KEN-4"] and .blocked_by_open == []'
assert_jq "session research blocks include only open targets" "$session" \
  '([.issues.research_ready[] | select(.id == "KEN-7")][0]).blocks == ["KEN-2"]'

assert_contains "production inverse projection requests state type" \
  "$ISSUE_BLOCKED_BY_FIELDS" 'state { name type }'
assert_file_contains "live queries use the production inverse projection" \
  "$TMP_ROOT/query.log" "$expected_inverse_query"

projection_sources=""
if ! projection_sources="$(grep -R -l -F 'inverseRelations' "$SKILL_DIR/scripts")"; then
  projection_sources=""
fi
projection_count=0
projection_sites=""
expected_projection_count="$(tr -d '[:space:]' <<<"$ISSUE_BLOCKED_BY_FIELDS" | awk '
  { text = text $0 }
  END { while (match(text, /inverseRelations\{nodes\{[^{}]*issue\{/)) { count++; text = substr(text, RSTART + RLENGTH) } print count + 0 }
')"
while IFS= read -r source; do
  [[ -n "$source" ]] || continue
  source_count="$(tr -d '[:space:]' <"$source" | awk '
    { text = text $0 }
    END { while (match(text, /inverseRelations\{nodes\{[^{}]*issue\{/)) { count++; text = substr(text, RSTART + RLENGTH) } print count + 0 }
  ')"
  if (( source_count > 0 )); then
    projection_count=$((projection_count + source_count))
    projection_sites+="${projection_sites:+$'\n'}$source"
  fi
done <<<"$projection_sources"
assert_eq "production inverse relation definition has one nodes opening" "$expected_projection_count" 1
assert_eq "production GraphQL has one inverse relation projection owner" "$projection_count" "$expected_projection_count"
assert_contains "the inverse relation projection owner is the formatter library" \
  "$projection_sites" "scripts/lib/formatters.sh"
