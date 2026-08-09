#!/usr/bin/env bash
# VST-126: `issues create --attach <PATH>` uploads local files through
# Linear's fileUpload flow (mutation -> PUT to uploadUrl with EXACTLY the
# returned headers) and references them from the created issue: images embed
# as ![name](assetUrl) in the description, other files become Linear
# attachments via attachmentCreate after the create.
#
# Fail-loud contract under test: a missing/unreadable path refuses before
# any API call; a PUT failure refuses before the issue exists; an
# attachmentCreate failure AFTER the create reports the created identifier
# with partial: true and exits non-zero.

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

# The fake curl mirrors the script's two transports: GraphQL POSTs and the
# storage PUT both arrive as curl-config-on-stdin (-K -); the attachment
# cache's background asset download uses direct args (no -K) and is not
# under test here.
cat >"$PROJECT/bin/curl" <<'SH'
#!/usr/bin/env bash
has_config=0
for a in "$@"; do [ "$a" = "-K" ] && has_config=1; done
if [ "$has_config" = "0" ]; then
  # background attachment-cache download — out of scope, never logged
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
  case "$file" in
  *put-fail*) printf '500' ;;
  *) printf '200' ;;
  esac
  exit 0
fi

payload="$(sed -n 's/^data = //p' <<<"$config" | jq -r)"
printf '%s\n' "$payload" >>"${CURL_LOG:?}"
query="$(jq -r '.query' <<<"$payload")"

case "$query" in
*"fileUpload("*)
  filename="$(jq -r '.variables.filename' <<<"$payload")"
  printf '%s' "{\"data\":{\"fileUpload\":{\"success\":true,\"uploadFile\":{\"uploadUrl\":\"https://uploads.linear.app/put/$filename\",\"assetUrl\":\"https://uploads.linear.app/asset/$filename\",\"headers\":[{\"key\":\"x-linear-upload\",\"value\":\"signed-$filename\"},{\"key\":\"x-amz-acl\",\"value\":\"private\"}]}}}}___HTTP_CODE___200"
  ;;
*"attachmentCreate("*)
  title="$(jq -r '.variables.input.title' <<<"$payload")"
  if [ "$title" = "boom.pdf" ]; then
    printf '%s' '{"data":{"attachmentCreate":{"success":false,"attachment":null}}}___HTTP_CODE___200'
  else
    printf '%s' '{"data":{"attachmentCreate":{"success":true,"attachment":{"id":"att-uuid","url":"u","title":"t"}}}}___HTTP_CODE___200'
  fi
  ;;
*"teams(filter:"*)
  printf '%s' '{"data":{"teams":{"nodes":[{"id":"team-uuid"}]}}}___HTTP_CODE___200'
  ;;
*"issueLabels(filter:"*)
  printf '%s' '{"data":{"issueLabels":{"nodes":[{"id":"label-uuid"}]}}}___HTTP_CODE___200'
  ;;
*"issueCreate(input:"*)
  printf '%s' '{"data":{"issueCreate":{"success":true,"issue":{"id":"issue-uuid","identifier":"TEAM-1","title":"t","description":"","state":{"name":"Todo","type":"unstarted"},"assignee":null,"project":null,"projectMilestone":null,"cycle":null,"parent":null,"team":{"name":"Configured"},"labels":{"nodes":[]},"priority":3,"estimate":null,"sortOrder":1.0,"url":"https://linear.app/x/issue/TEAM-1","createdAt":"2026-08-08T00:00:00Z","updatedAt":"2026-08-08T00:00:00Z","archivedAt":null,"trashed":null,"relations":{"nodes":[]},"inverseRelations":{"nodes":[]}}}}}___HTTP_CODE___200'
  ;;
*)
  printf '%s' '{"data":{}}___HTTP_CODE___200'
  ;;
esac
SH
chmod +x "$PROJECT/bin/curl"

printf '[env]\nLINEAR_TEAM = "Configured"\n' >"$PROJECT/vstack.settings.toml"

printf 'PNGDATA' >"$TMP_ROOT/shot.png" # 7 bytes, image/png
printf '%%PDF-1.4' >"$TMP_ROOT/notes.pdf"
printf 'x' >"$TMP_ROOT/boom.pdf"
printf 'x' >"$TMP_ROOT/put-fail.png"
printf 'Body from file.' >"$TMP_ROOT/desc.md"

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

echo "=== image attach: fileUpload -> PUT with returned headers -> embed in description ==="

run_linear issues create --title "With image" --attach "$TMP_ROOT/shot.png"
[[ "$RC" -eq 0 ]] || fail "image attach create exited $RC: $ERR"

jq -s -e 'any(.[]; (.query? // "" | contains("fileUpload"))
    and .variables.contentType == "image/png"
    and .variables.filename == "shot.png"
    and .variables.size == 7)' "$CURL_LOG" >/dev/null ||
  fail "fileUpload not called with contentType/filename/size from the file"

jq -s -e 'any(.[]; .put?.url == "https://uploads.linear.app/put/shot.png"
    and (.put.headers | index("x-linear-upload: signed-shot.png"))
    and (.put.headers | index("x-amz-acl: private"))
    and (.put.headers | index("Content-Type: image/png")))' "$CURL_LOG" >/dev/null ||
  fail "PUT did not carry the returned headers plus Content-Type"

# The PUT must precede the create — bytes exist before anything references them.
jq -s -e '([to_entries[] | select(.value | has("put")) | .key] | first)
    < ([to_entries[] | select(.value.query? // "" | contains("issueCreate")) | .key] | first)' \
  "$CURL_LOG" >/dev/null || fail "PUT did not happen before issueCreate"

jq -s -e 'any(.[]; (.query? // "" | contains("issueCreate"))
    and .variables.input.description == "![shot.png](https://uploads.linear.app/asset/shot.png)")' \
  "$CURL_LOG" >/dev/null || fail "image embed missing from created description"

if jq -s -e 'any(.[]; .query? // "" | contains("attachmentCreate"))' "$CURL_LOG" >/dev/null; then
  fail "image attach must embed, not attachmentCreate"
fi

echo "=== non-image attach: attachmentCreate with the created issue id ==="

run_linear issues create --title "With pdf" --attach "$TMP_ROOT/notes.pdf"
[[ "$RC" -eq 0 ]] || fail "pdf attach create exited $RC: $ERR"

jq -s -e 'any(.[]; (.query? // "" | contains("fileUpload"))
    and .variables.contentType == "application/pdf")' "$CURL_LOG" >/dev/null ||
  fail "fileUpload not called with application/pdf"

jq -s -e 'any(.[]; (.query? // "" | contains("attachmentCreate"))
    and .variables.input.issueId == "issue-uuid"
    and .variables.input.url == "https://uploads.linear.app/asset/notes.pdf"
    and .variables.input.title == "notes.pdf")' "$CURL_LOG" >/dev/null ||
  fail "attachmentCreate not called with the created issue id and asset url"

jq -s -e 'any(.[]; (.query? // "" | contains("issueCreate"))
    and (.variables.input | has("description") | not))' "$CURL_LOG" >/dev/null ||
  fail "non-image attach must not inject a description"

echo "=== --attach composes with --description-file ==="

run_linear issues create --title "Compose" \
  --description-file "$TMP_ROOT/desc.md" --attach "$TMP_ROOT/shot.png"
[[ "$RC" -eq 0 ]] || fail "composed create exited $RC: $ERR"

jq -s -e 'any(.[]; (.query? // "" | contains("issueCreate"))
    and .variables.input.description == "Body from file.\n\n![shot.png](https://uploads.linear.app/asset/shot.png)")' \
  "$CURL_LOG" >/dev/null || fail "embed did not append to --description-file content"

echo "=== missing file refuses before any API call ==="

run_linear issues create --title "Missing" --attach "$TMP_ROOT/nope.png"
[[ "$RC" -ne 0 ]] || fail "missing --attach path exited 0: $OUT"
grep -q "not readable" <<<"$ERR" || fail "missing-path refusal lacks 'not readable': $ERR"
grep -q "nope.png" <<<"$ERR" || fail "missing-path refusal does not name the path: $ERR"
[[ "$(api_calls)" == "0" ]] || fail "missing --attach path attempted $(api_calls) API call(s)"

echo "=== PUT failure refuses before the issue exists ==="

run_linear issues create --title "PutFail" --attach "$TMP_ROOT/put-fail.png"
[[ "$RC" -ne 0 ]] || fail "failed PUT exited 0: $OUT"
grep -q "Upload PUT failed" <<<"$ERR" || fail "failed PUT lacks the PUT error: $ERR"
if jq -s -e 'any(.[]; .query? // "" | contains("issueCreate"))' "$CURL_LOG" >/dev/null; then
  fail "issueCreate was reached despite a failed upload PUT"
fi

echo "=== attachmentCreate failure AFTER create: names the issue, exits non-zero ==="

run_linear issues create --title "Partial" --attach "$TMP_ROOT/boom.pdf"
[[ "$RC" -ne 0 ]] || fail "failed attachmentCreate exited 0: $OUT"
jq -s -e 'any(.[]; .query? // "" | contains("issueCreate"))' "$CURL_LOG" >/dev/null ||
  fail "issue was not created before the attachment failure"
grep -q "TEAM-1" <<<"$ERR" || fail "partial failure does not name the created issue: $ERR"
grep -q '"partial":true' <<<"$ERR" || fail "partial failure lacks partial: true: $ERR"
grep -q "TEAM-1" <<<"$OUT" || fail "created identifier missing from stdout: $OUT"

echo "=== agent-label guard still refuses BEFORE any upload ==="

printf '[env]\nLINEAR_TEAM = "Configured"\nLINEAR_AGENT_LABELS = "agent:generalist"\n' \
  >"$PROJECT/vstack.settings.toml"
run_linear issues create --title "Guarded" --attach "$TMP_ROOT/shot.png"
[[ "$RC" -ne 0 ]] || fail "bare create with --attach passed the routing guard: $OUT"
grep -q "LINEAR_AGENT_LABELS" <<<"$ERR" || fail "guard refusal missing: $ERR"
[[ "$(api_calls)" == "0" ]] || fail "guarded create attempted $(api_calls) API call(s)"

echo "all pass"
