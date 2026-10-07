#!/usr/bin/env bash
# A related relation is one record Linear shows on both issues; every read of
# the issue on the target side lists it, from inverseRelations.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../scripts/lib/formatters.sh
source "$SKILL_DIR/scripts/lib/formatters.sh"
assert_tmpdir TMP_ROOT
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

mkdir -p "$TMP_ROOT/.agents/skills" "$TMP_ROOT/bin"
cp -R "$SKILL_DIR" "$TMP_ROOT/.agents/skills/linear"
git -C "$TMP_ROOT" init -q -b main
git -C "$TMP_ROOT" config gc.auto 0
git -C "$TMP_ROOT" config maintenance.auto false

# KEN-1 created the related relation to KEN-2; KEN-3 created the one to KEN-1,
# so KEN-1 sees it only under inverseRelations. The inverse blocks relation
# from KEN-4 and the inverse duplicate from KEN-5 are not related ones.
page='"pageInfo":{"hasNextPage":false,"endCursor":null}'
main='{"id":"issue-1","identifier":"KEN-1","title":"target","description":"","state":{"name":"Todo","type":"unstarted"},"assignee":null,"project":null,"projectMilestone":null,"cycle":null,"parent":null,"team":{"name":"Kendex"},"labels":{'"$page"',"nodes":[]},"priority":0,"estimate":null,"sortOrder":0,"url":"","createdAt":"","updatedAt":"","archivedAt":null,"trashed":false,"children":{'"$page"',"nodes":[]},"relations":{'"$page"',"nodes":[{"id":"rel-out","type":"related","relatedIssue":{"id":"issue-2","identifier":"KEN-2","title":"outgoing","state":{"name":"Todo","type":"unstarted"}}}]},"inverseRelations":{'"$page"',"nodes":[{"id":"rel-in","type":"related","issue":{"id":"issue-3","identifier":"KEN-3","title":"incoming","state":{"name":"Working","type":"started"}}},{"id":"rel-blk","type":"blocks","issue":{"id":"issue-4","identifier":"KEN-4","title":"blocker","state":{"name":"Todo","type":"unstarted"}}},{"id":"rel-dup","type":"duplicate","issue":{"id":"issue-5","identifier":"KEN-5","title":"copy","state":{"name":"Todo","type":"unstarted"}}}]}}'
bundle="$(jq -cn --argjson base "$main" '$base | .children.nodes = []')"

cat >"$TMP_ROOT/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
config="$(cat)"
payload="$(sed -n 's/^data = //p' <<<"$config" | jq -r)"
query="$(jq -r '.query' <<<"$payload")"
compact="$(tr -d '[:space:]' <<<"$query")"
printf '%s\n' "$compact" >>"$QUERY_LOG"

case "$query" in
*"ListIssues"*|*"IssueRefs"*)
  response="$(jq -cn --argjson issue "$FIXTURE_MAIN" '{data:{issues:{nodes:[$issue],pageInfo:{hasNextPage:false,endCursor:null}}}}')"
  ;;
*"GetIssueWithBundle"*)
  response="$(jq -cn --argjson issue "$FIXTURE_BUNDLE" '{data:{issue:$issue}}')"
  ;;
*"GetRelations"*|*"GetIssue"*|*"issue(id:"*)
  response="$(jq -cn --argjson issue "$FIXTURE_MAIN" '{data:{issue:$issue}}')"
  ;;
*)
  response='{"errors":[{"message":"unexpected query"}]}'
  ;;
esac

# Linear answers only what the query asks for: a read that does not request
# the inverse side's type and issue identifier gets no inverse related row.
if [[ "$compact" != *'inverseRelations{'*'nodes{idtypeissue{ididentifier'* ]]; then
  response="$(jq 'walk(if type == "object" and has("inverseRelations") then del(.inverseRelations) else . end)' <<<"$response")"
fi
printf '%s___HTTP_CODE___200' "$response"
SH
chmod +x "$TMP_ROOT/bin/curl"

LINEAR="$TMP_ROOT/.agents/skills/linear/scripts/linear.sh"
run_live() {
  (cd "$TMP_ROOT" && PATH="$TMP_ROOT/bin:$PATH" LINEAR_API_KEY_OVERRIDE=test-token \
    QUERY_LOG="$TMP_ROOT/query.log" FIXTURE_MAIN="$main" FIXTURE_BUNDLE="$bundle" \
    bash "$LINEAR" "$@")
}
assert_related() {
  assert_jq "$1" "$2" "$3 | .related == [\"KEN-2\", \"KEN-3\"]"
}

assert_related "get safe lists the inverse related issue" "$(run_live issues get KEN-1 --format=safe)" '.'
assert_related "get with bundle lists the inverse related issue" \
  "$(run_live issues get KEN-1 --with-bundle --format=safe)" '.'
assert_related "bulk-get lists the inverse related issue" "$(run_live issues bulk-get KEN-1 --format=safe)" '.[0]'
assert_related "list lists the inverse related issue" "$(run_live issues list --format=safe)" '.[0]'

relations="$(run_live issues list-relations KEN-1 --format=safe)"
assert_jq "list-relations lists the inverse related row" "$relations" \
  '.related == [
    {relation_id: "rel-out", id: "KEN-2", title: "outgoing", state: "Todo"},
    {relation_id: "rel-in", id: "KEN-3", title: "incoming", state: "Working"}
  ]'
assert_jq "list-relations keeps an inverse duplicate out of duplicates" "$relations" '.duplicates == []'

# A relation both sides carry, as a self-relation would, is listed once.
both="$(jq -cn --argjson issue "$main" '{issue: ($issue | .inverseRelations.nodes += [{id: "rel-out", type: "related", issue: {identifier: "KEN-2", title: "outgoing", state: {name: "Todo"}}}])}')"
assert_jq "a relation on both sides is listed once" "$(format_issue_single "$both")" '.related == ["KEN-2", "KEN-3"]'
