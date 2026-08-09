#!/usr/bin/env bash
# VST-126: `issues update <ID> --attach <PATH>`. Image embeds append to the
# description being written — and, when the update carries no
# --description/--description-file, to the issue's EXISTING description
# (append, never wipe). Non-image files become Linear attachments via
# attachmentCreate after the update; `--attach` alone is a valid update that
# skips the issueUpdate mutation entirely. Partial failures after a
# successful write name the issue and exit non-zero.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PROJECT="$TMP_ROOT/project"
mkdir -p "$PROJECT/.agents/skills" "$PROJECT/bin"
git -C "$PROJECT" init -q -b main
cp -R "$SKILL_DIR" "$PROJECT/.agents/skills/linear"

LINEAR="$PROJECT/.agents/skills/linear/scripts/linear.sh"
CURL_LOG="$TMP_ROOT/curl-payloads.jsonl"
ERR_FILE="$TMP_ROOT/stderr.txt"

ISSUE_JSON='{"id":"issue-uuid-9","identifier":"TEAM-9","title":"t","description":"Existing text.","state":{"name":"Todo","type":"unstarted"},"assignee":null,"project":null,"projectMilestone":null,"cycle":null,"parent":null,"team":{"name":"Configured"},"labels":{"nodes":[]},"priority":3,"estimate":null,"sortOrder":1.0,"url":"https://linear.app/x/issue/TEAM-9","createdAt":"2026-08-08T00:00:00Z","updatedAt":"2026-08-08T00:00:00Z","archivedAt":null,"trashed":null,"relations":{"nodes":[]},"inverseRelations":{"nodes":[]}}'

cat >"$PROJECT/bin/curl" <<SH
#!/usr/bin/env bash
ISSUE_JSON='$ISSUE_JSON'
SH
cat >>"$PROJECT/bin/curl" <<'SH'
has_config=0
for a in "$@"; do [ "$a" = "-K" ] && has_config=1; done
if [ "$has_config" = "0" ]; then
  printf '404'
  exit 0
fi
config="$(cat)"

if grep -q '^upload-file = ' <<<"$config"; then
  url="$(sed -n 's/^url = //p' <<<"$config" | jq -r)"
  file="$(sed -n 's/^upload-file = //p' <<<"$config" | jq -r)"
  headers="$(sed -n 's/^header = //p' <<<"$config" | jq -s .)"
  jq -cn --arg url "$url" --arg file "$file" --argjson headers "$headers" \
    '{put: {url: $url, file: $file, headers: $headers}}' >>"${CURL_LOG:?}"
  printf '200'
  exit 0
fi

payload="$(sed -n 's/^data = //p' <<<"$config" | jq -r)"
printf '%s\n' "$payload" >>"${CURL_LOG:?}"
query="$(jq -r '.query' <<<"$payload")"

case "$query" in
*"fileUpload("*)
  filename="$(jq -r '.variables.filename' <<<"$payload")"
  printf '%s' "{\"data\":{\"fileUpload\":{\"success\":true,\"uploadFile\":{\"uploadUrl\":\"https://uploads.linear.app/put/$filename\",\"assetUrl\":\"https://uploads.linear.app/asset/$filename\",\"headers\":[{\"key\":\"x-linear-upload\",\"value\":\"signed-$filename\"}]}}}}___HTTP_CODE___200"
  ;;
*"attachmentCreate("*)
  title="$(jq -r '.variables.input.title' <<<"$payload")"
  if [ "$title" = "boom.pdf" ]; then
    printf '%s' '{"data":{"attachmentCreate":{"success":false,"attachment":null}}}___HTTP_CODE___200'
  else
    printf '%s' '{"data":{"attachmentCreate":{"success":true,"attachment":{"id":"att-uuid","url":"u","title":"t"}}}}___HTTP_CODE___200'
  fi
  ;;
*"issueUpdate("*)
  printf '%s' "{\"data\":{\"issueUpdate\":{\"success\":true,\"issue\":$ISSUE_JSON}}}___HTTP_CODE___200"
  ;;
*"issue(id:"*)
  printf '%s' "{\"data\":{\"issue\":$ISSUE_JSON}}___HTTP_CODE___200"
  ;;
*"teams(filter:"*)
  printf '%s' '{"data":{"teams":{"nodes":[{"id":"team-uuid"}]}}}___HTTP_CODE___200'
  ;;
*)
  printf '%s' '{"data":{}}___HTTP_CODE___200'
  ;;
esac
SH
chmod +x "$PROJECT/bin/curl"

printf '[env]\nLINEAR_TEAM = "Configured"\n' >"$PROJECT/vstack.settings.toml"

printf 'PNGDATA' >"$TMP_ROOT/shot.png"
printf '%%PDF-1.4' >"$TMP_ROOT/notes.pdf"
printf 'x' >"$TMP_ROOT/boom.pdf"

OUT=""
ERR=""
RC=0

fail() {
  echo "FAIL $*"
  [[ -s "$CURL_LOG" ]] && echo "--- curl payloads ---" && cat "$CURL_LOG"
  exit 1
}

run_linear() {
  : >"$CURL_LOG"
  set +e
  OUT="$(cd "$PROJECT" && env -u LINEAR_TEAM -u LINEAR_AGENT_LABELS \
    PATH="$PROJECT/bin:$PATH" \
    LINEAR_API_KEY=test-token \
    CURL_LOG="$CURL_LOG" \
    bash "$LINEAR" "$@" </dev/null 2>"$ERR_FILE")"
  RC=$?
  set -e
  ERR="$(cat "$ERR_FILE")"
}

api_calls() {
  wc -l <"$CURL_LOG" | tr -d ' '
}

echo "=== image attach with no --description appends to the EXISTING description ==="

run_linear issues update TEAM-9 --attach "$TMP_ROOT/shot.png"
[[ "$RC" -eq 0 ]] || fail "image attach update exited $RC: $ERR"
jq -s -e 'any(.[]; (.query? // "" | contains("issueUpdate"))
    and .variables.id == "TEAM-9"
    and .variables.input.description == "Existing text.\n\n![shot.png](https://uploads.linear.app/asset/shot.png)")' \
  "$CURL_LOG" >/dev/null || fail "embed did not append to the existing description"

echo "=== image attach with --description appends to the NEW description ==="

run_linear issues update TEAM-9 --description "New body" --attach "$TMP_ROOT/shot.png"
[[ "$RC" -eq 0 ]] || fail "image attach + --description update exited $RC: $ERR"
jq -s -e 'any(.[]; (.query? // "" | contains("issueUpdate"))
    and .variables.input.description == "New body\n\n![shot.png](https://uploads.linear.app/asset/shot.png)")' \
  "$CURL_LOG" >/dev/null || fail "embed did not append to the new description"

echo "=== non-image --attach alone is a valid update: attachmentCreate only ==="

run_linear issues update TEAM-9 --attach "$TMP_ROOT/notes.pdf"
[[ "$RC" -eq 0 ]] || fail "attach-only update exited $RC: $ERR"
if jq -s -e 'any(.[]; .query? // "" | contains("issueUpdate"))' "$CURL_LOG" >/dev/null; then
  fail "attach-only update must not run issueUpdate"
fi
jq -s -e 'any(.[]; (.query? // "" | contains("attachmentCreate"))
    and .variables.input.issueId == "issue-uuid-9"
    and .variables.input.url == "https://uploads.linear.app/asset/notes.pdf"
    and .variables.input.title == "notes.pdf")' "$CURL_LOG" >/dev/null ||
  fail "attachmentCreate not called with the issue uuid and asset url"
jq -e '.success == true and .identifier == "TEAM-9"' <<<"$OUT" >/dev/null ||
  fail "attach-only update output lacks success/identifier: $OUT"

echo "=== attachmentCreate failure after a successful update: names issue, non-zero ==="

run_linear issues update TEAM-9 --title "New title" --attach "$TMP_ROOT/boom.pdf"
[[ "$RC" -ne 0 ]] || fail "failed attachmentCreate exited 0: $OUT"
jq -s -e 'any(.[]; .query? // "" | contains("issueUpdate"))' "$CURL_LOG" >/dev/null ||
  fail "issueUpdate did not run before the attachment failure"
grep -q "TEAM-9" <<<"$ERR" || fail "partial failure does not name the issue: $ERR"
grep -q '"partial":true' <<<"$ERR" || fail "partial failure lacks partial: true: $ERR"
grep -q "TEAM-9" <<<"$OUT" || fail "update summary missing from stdout: $OUT"

echo "=== missing file refuses before any API call ==="

run_linear issues update TEAM-9 --attach "$TMP_ROOT/nope.png"
[[ "$RC" -ne 0 ]] || fail "missing --attach path exited 0: $OUT"
grep -q "not readable" <<<"$ERR" || fail "missing-path refusal lacks 'not readable': $ERR"
[[ "$(api_calls)" == "0" ]] || fail "missing --attach path attempted $(api_calls) API call(s)"

echo "all pass"
