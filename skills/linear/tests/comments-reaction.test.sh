#!/usr/bin/env bash
# bash-runtime: 4
# Surface: comments reaction, used by the owner-answer watch and ask close.
# Inputs: scripts/linear.sh, scripts/commands/comments.sh, scripts/lib/*.sh,
# tests/lib/assert.sh. The curl fixture keeps every request offline.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
assert_tmpdir TMP_ROOT
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
mkdir -p "$TMP_ROOT/project/.agents/skills" "$TMP_ROOT/bin"
cp -R "$SKILL_DIR" "$TMP_ROOT/project/.agents/skills/linear"
git -C "$TMP_ROOT/project" init -q
git -C "$TMP_ROOT/project" config gc.auto 0
git -C "$TMP_ROOT/project" config maintenance.auto false
cat >"$TMP_ROOT/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
config=$(cat)
payload=$(sed -n 's/^data = //p' <<<"$config" | jq -r)
query=$(jq -r .query <<<"$payload")
printf '%s\n' "$payload" >>"$CALLS"
case "$query" in
  *'reactionCreate(input:'*) operation=reactionCreate ;;
  *'reactionDelete(id:'*) operation=reactionDelete ;;
  *'comment(id:'*)
    if [[ "$ROW" == lookup-error ]]; then
      printf '%s' '{"errors":[{"message":"fixture lookup failure"}]}___HTTP_CODE___200'
    else
      jq -cnj --arg row "$ROW" '{data:{viewer:{id:"actor"},comment:{reactions:
        ([{id:"others-eyes",emoji:"eyes",user:{id:"other"}},
         {id:"own-check",emoji:"white_check_mark",user:{id:"actor"}}]
        + (if $row == "absent" then [] else [{id:"own-eyes",emoji:"eyes",user:{id:"actor"}}] end))}}}'
      printf '%s' '___HTTP_CODE___200'
    fi
    exit 0 ;;
  *) exit 1 ;;
esac
if [[ "$ROW" == api-error ]]; then
  printf '%s' '{"errors":[{"message":"fixture mutation failure"}]}'
else
  jq -cnj --arg op "$operation" --arg row "$ROW" '{data:{($op):{success:($row != "rejected")}}}'
fi
printf '%s' '___HTTP_CODE___200'
SH
chmod +x "$TMP_ROOT/bin/curl"
LINEAR="$TMP_ROOT/project/.agents/skills/linear/scripts/linear.sh"
run_reaction() {
  local row="$1"
  shift
  : >"$TMP_ROOT/calls"
  RC=0
  OUT=$(cd "$TMP_ROOT/project" && env -i PATH="$TMP_ROOT/bin:$PATH" HOME="$TMP_ROOT" LANG=C \
    LINEAR_APP_TOKEN=fixture-token ROW="$row" CALLS="$TMP_ROOT/calls" \
    "$BASH" "$LINEAR" comments reaction "$@" 2>"$TMP_ROOT/err") || RC=$?
}
# Both existing callers use emoji names and no team setting. The remove route
# must preserve reactions from other actors and the actor's other emoji.
while IFS='|' read -r row remove want_rc want_calls; do
  args=(owner-comment eyes)
  [[ "$remove" != remove ]] || args+=(--remove)
  run_reaction "$row" "${args[@]}"
  assert_eq "$row $remove status" "$RC" "$want_rc"
  assert_eq "$row $remove request count" "$(wc -l <"$TMP_ROOT/calls" | tr -d ' ')" "$want_calls"
  if [[ "$want_rc" == 0 ]]; then assert_jq "$row $remove succeeds" "$OUT" '.success == true'; fi
  if [[ "$remove" == add ]]; then
    assert_jq "$row add sends comment and emoji" "$(cat "$TMP_ROOT/calls")" \
      '.variables == {input:{commentId:"owner-comment",emoji:"eyes"}}'
  elif [[ "$row" == present || "$row" == rejected || "$row" == api-error ]]; then
    assert_jq "$row remove deletes only own matching reaction" "$(jq -cs '[.[] | select(.query | contains("reactionDelete"))]' "$TMP_ROOT/calls")" \
      'length == 1 and .[0].variables == {id:"own-eyes"}'
  fi
done <<'ROWS'
present|add|0|1
rejected|add|1|1
api-error|add|1|1
present|remove|0|2
absent|remove|0|1
lookup-error|remove|1|1
rejected|remove|1|2
api-error|remove|1|2
ROWS
while IFS='|' read -r comment emoji flag; do
  args=("$comment" "$emoji")
  [[ -z "$flag" ]] || args+=("$flag")
  run_reaction invalid "${args[@]}"
  assert_ne 'invalid arguments refuse' "$RC" 0
  assert_eq 'invalid arguments send no request' "$(cat "$TMP_ROOT/calls")" ''
done <<'ROWS'
|eyes|
owner-comment||
owner-comment|eyes|--unknown
ROWS
