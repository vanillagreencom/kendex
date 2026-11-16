#!/usr/bin/env bash
# bash-runtime: 4
# Description writes propagate through Linear's syncedWith GitHub links.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
assert_tmpdir TMP_ROOT
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)"
mkdir -p "$TMP_ROOT/.agents/skills" "$TMP_ROOT/bin"
cp -R "$SKILL_DIR" "$TMP_ROOT/.agents/skills/linear"
git -C "$TMP_ROOT" init -q -b main
git -C "$TMP_ROOT" config gc.auto 0
git -C "$TMP_ROOT" config maintenance.auto false
cat >"$TMP_ROOT/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
config=$(cat)
payload=$(sed -n 's/^data = //p' <<<"$config" | jq -r)
query=$(jq -r '.query' <<<"$payload")
printf '%s\n' "$payload" >>"${CURL_PAYLOAD_LOG:?}"
issue=$(jq -cn --arg id "$(jq -r '.variables.id // "PROJ-1"' <<<"$payload")" --arg mode "$SYNC_MODE" '
  {id: $id, identifier: $id, title: "Reporter title", description: "Reporter body",
   team: {id: "team-id", key: "PROJ", name: "Project"},
   state: {name: "Todo", type: "unstarted"}, labels: {nodes: [], pageInfo: {hasNextPage: false}},
   relations: {nodes: [], pageInfo: {hasNextPage: false}},
   inverseRelations: {nodes: [], pageInfo: {hasNextPage: false}},
   syncedWith: (if $mode == "synced" and $id != "PROJ-0" then
     [{metadata: {owner: "Reporter", repo: "Project", number: 42}}]
     elif $mode == "other" then [{metadata: {}}]
     elif $mode == "null" then null else [] end)}
  | if $mode == "absent" then del(.syncedWith) else . end')
case "$query" in
  *'issueUpdate(id:'*) result=$(jq -cn --argjson issue "$issue" '{issueUpdate: {success: true, issue: $issue}}') ;;
  *'issue(id:'*) result=$(jq -cn --argjson issue "$issue" '{issue: $issue}') ;;
  *) printf '%s' '{"errors":[{"message":"unexpected operation"}]}___HTTP_CODE___200'; exit 0 ;;
esac
jq -cn --argjson data "$result" '{data: $data}'
printf '___HTTP_CODE___200'
CURL
chmod +x "$TMP_ROOT/bin/curl"
printf 'Replacement body' >"$TMP_ROOT/body.md"
LINEAR="$TMP_ROOT/.agents/skills/linear/scripts/linear.sh"
# One input contract: omitted/empty/replaced descriptions, sync and override.
while IFS='|' read -r name action mode form override expected; do
  [[ -z "${SYNC_DESCRIPTION_CASE:-}" || "$SYNC_DESCRIPTION_CASE" == "$name" ]] || continue
  args=(issues "$action")
  if [[ "$action" == bulk-update ]]; then args+=(PROJ-0 PROJ-1); else args+=(PROJ-1); fi
  case "$form" in
    inline) args+=(--description 'Replacement body') ;;
    equals) args+=(--description='Replacement body') ;;
    empty) args+=(--description=) ;;
    file) args+=(--description-file "$TMP_ROOT/body.md") ;;
    file-equals) args+=(--description-file="$TMP_ROOT/body.md") ;;
    fields)
      args+=(--title renamed --remove-parent)
      [[ "$action" != update ]] || args+=(--clear-labels)
      ;;
  esac
  [[ "$override" != yes ]] || args+=(--synced-description)
  log="$TMP_ROOT/requests"
  : >"$log"
  rc=0
  (cd "$TMP_ROOT" && env -i HOME="$TMP_ROOT" XDG_CONFIG_HOME="$TMP_ROOT/config" \
    XDG_DATA_HOME="$TMP_ROOT/data" XDG_STATE_HOME="$TMP_ROOT/state" XDG_CACHE_HOME="$TMP_ROOT/cache" \
    PATH="$TMP_ROOT/bin:$PATH" LINEAR_API_KEY_OVERRIDE=test-token LINEAR_TEAM= LINEAR_REQUIRE_REACH= \
    CURL_PAYLOAD_LOG="$log" SYNC_MODE="$mode" "$BASH" "$LINEAR" "${args[@]}") \
    >"$TMP_ROOT/out" 2>"$TMP_ROOT/err" || rc=$?
  if [[ "$expected" == refuse ]]; then
    assert_ne "$name refuses" "$rc" 0
    # This keyed line is the command's machine-readable refusal contract.
    assert_file_contains "$name names link and override" "$TMP_ROOT/err" \
      'linear: refused=synced-description issue=PROJ-1 github=reporter/project#42 override=--synced-description'
    assert "$name writes nothing" jq -se 'all(.[]; (.query | test("^\\s*mutation") | not))' "$log"
  else
    assert_eq "$name succeeds" "$rc" 0
    count=1
    [[ "$action" != bulk-update ]] || count=2
    case "$form" in
      fields) rule='has("description") | not' ;;
      empty) rule='has("description") and .description == ""' ;;
      *) rule='.description == "Replacement body"' ;;
    esac
    assert "$name sends requested fields" jq -se \
      '[.[] | select(.query | contains("issueUpdate")) | .variables.input] | length == '"$count"' and all(.[]; '"$rule"')' "$log"
  fi
done <<'ROWS'
inline-refuse|update|synced|inline|no|refuse
equals-refuse|update|synced|equals|no|refuse
empty-refuse|update|synced|empty|no|refuse
file-refuse|update|synced|file|no|refuse
file-equals-refuse|update|synced|file-equals|no|refuse
bulk-refuse|bulk-update|synced|inline|no|refuse
bulk-equals-refuse|bulk-update|synced|equals|no|refuse
flagged|update|synced|inline|yes|pass
flagged-file|update|synced|file|yes|pass
flagged-bulk|bulk-update|synced|inline|yes|pass
unsynced|update|none|inline|no|pass
unsynced-bulk|bulk-update|none|inline|no|pass
null-sync|update|null|inline|no|pass
null-sync-bulk|bulk-update|null|inline|no|pass
absent-sync|update|absent|inline|no|pass
absent-sync-bulk|bulk-update|absent|inline|no|pass
other-sync|update|other|inline|no|pass
fields|update|synced|fields|no|pass
bulk-fields|bulk-update|synced|fields|no|pass
ROWS
