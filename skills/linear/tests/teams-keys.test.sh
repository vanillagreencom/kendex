#!/usr/bin/env bash
# `teams keys` supplies the workspace and every team key to Slack with one
# read. The existing list still returns an array. Controls live in controls/.
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
cat > "$TMP_ROOT/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
config="$(cat)"
payload="$(sed -n 's/^data = //p' <<<"$config" | jq -r)"
query="$(jq -r .query <<<"$payload")"
printf '%s\n' "$payload" >> "$CALLS"
if [ "$FAIL_READ" = 1 ]; then
  printf '%s' '{"errors":[{"message":"Read failed"}]}___HTTP_CODE___200'
elif [[ "$query" == *organization* ]]; then
  if [[ "$query" == *urlKey* && "$query" == *'nodes { key }'* ]]; then
    printf '%s' '{"data":{"organization":{"urlKey":"workspace","teams":{"nodes":[{"key":"HT"},{"key":"HTIO"},{"key":"KEN"}]}}}}___HTTP_CODE___200'
  else
    printf '%s' '{"data":{"organization":{}}}___HTTP_CODE___200'
  fi
else
  printf '%s' '{"data":{"teams":{"nodes":[{"id":"team","name":"Team","key":"KEN","description":"","members":{"nodes":[]},"createdAt":""}]}}}___HTTP_CODE___200'
fi
SH
chmod +x "$TMP_ROOT/bin/curl"
LINEAR="$TMP_ROOT/project/.agents/skills/linear/scripts/linear.sh"
run() {
  local fail="$1"
  shift
  RC=0
  OUT="$(cd "$TMP_ROOT/project" && env -i PATH="$TMP_ROOT/bin:$PATH" HOME="$TMP_ROOT" LANG=C \
    LINEAR_CACHE_ROOT="$ASSERT_CACHE_ROOT" LINEAR_API_KEY_OVERRIDE=test-key \
    LINEAR_CLIENT_ID='' LINEAR_CLIENT_SECRET='' CALLS="$TMP_ROOT/calls" FAIL_READ="$fail" \
    bash "$LINEAR" "$@" 2>"$TMP_ROOT/err")" || RC=$?
}
run 0 teams keys
assert_eq 'team keys read succeeds' "$RC" 0
assert_jq 'team keys supplies the workspace and complete key array' "$OUT" '. == {urlKey:"workspace",keys:["HT","HTIO","KEN"]}'
assert_eq 'team keys uses one API read' "$(wc -l < "$TMP_ROOT/calls" | tr -d ' ')" 1
run 0 teams list
assert_jq 'teams list retains its array shape' "$OUT" 'type == "array" and .[0].key == "KEN"'
run 1 teams keys
assert_ne 'a failed team keys read returns nonzero' "$RC" 0
