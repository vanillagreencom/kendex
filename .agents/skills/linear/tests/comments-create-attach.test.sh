#!/usr/bin/env bash
# VST-126: `comments create <ID> --attach <PATH>`. Files upload through
# Linear's fileUpload flow and are referenced from the comment body: images
# embed as ![name](assetUrl), other files append a [name](assetUrl) markdown
# link (comments have no attachmentCreate surface). --attach composes with
# --body/--body-file, permits a body-less comment, and a missing/unreadable
# path refuses before any API call.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
assert_tmpdir TMP_ROOT

PROJECT="$TMP_ROOT/project"
mkdir -p "$PROJECT/.agents/skills" "$PROJECT/bin"
git -C "$PROJECT" init -q -b main
cp -R "$SKILL_DIR" "$PROJECT/.agents/skills/linear"

LINEAR="$PROJECT/.agents/skills/linear/scripts/linear.sh"
CURL_LOG="$TMP_ROOT/curl-payloads.jsonl"
ERR_FILE="$TMP_ROOT/stderr.txt"

cat >"$PROJECT/bin/curl" <<'SH'
#!/usr/bin/env bash
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
*"commentCreate("*)
  body="$(jq -c '.variables.input.body' <<<"$payload")"
  printf '%s' "{\"data\":{\"commentCreate\":{\"success\":true,\"comment\":{\"id\":\"comment-uuid\",\"body\":$body,\"createdAt\":\"2026-08-08T00:00:00Z\",\"updatedAt\":\"2026-08-08T00:00:00Z\",\"user\":{\"name\":\"tester\"},\"issue\":{\"identifier\":\"TEAM-1\",\"updatedAt\":\"2026-08-08T00:00:00Z\"}}}}}___HTTP_CODE___200"
  ;;
*)
  printf '%s' '{"data":{}}___HTTP_CODE___200'
  ;;
esac
SH
chmod +x "$PROJECT/bin/curl"

printf '[env]\nLINEAR_TEAM = "Configured"\n' >"$PROJECT/kendex.settings.toml"

printf 'PNGDATA' >"$TMP_ROOT/shot.png"
printf '%%PDF-1.4' >"$TMP_ROOT/notes.pdf"
printf 'Body from file.' >"$TMP_ROOT/body.md"

OUT=""
ERR=""
RC=0

run_linear() {
  : >"$CURL_LOG"
  RC=0
  OUT="$(cd "$PROJECT" && env -u LINEAR_TEAM -u LINEAR_AGENT_LABELS \
    PATH="$PROJECT/bin:$PATH" \
    LINEAR_API_KEY=test-token \
    CURL_LOG="$CURL_LOG" \
    bash "$LINEAR" "$@" </dev/null 2>"$ERR_FILE")" || RC=$?
  ERR="$(cat "$ERR_FILE")"
}

api_calls() {
  wc -l <"$CURL_LOG" | tr -d ' '
}

# assert_log DESC FILTER — FILTER must select a true value over the logged
# curl payloads, read as a stream.
assert_log() {
  assert "$1" jq -s -e "$2" "$CURL_LOG"
}

assert_not_log() {
  assert_not "$1" jq -s -e "$2" "$CURL_LOG"
}

echo "=== image attach embeds into the comment body after --body text ==="

run_linear comments create TEAM-1 --body "Note" --attach "$TMP_ROOT/shot.png"
assert_eq "an image attach comment exits zero" "$RC" 0
assert_log "fileUpload carries the contentType and size read from the file" \
  'any(.[]; (.query? // "" | contains("fileUpload"))
    and .variables.contentType == "image/png"
    and .variables.size == 7)'
assert_log "the PUT carries the returned headers plus Content-Type" \
  'any(.[]; .put?.url == "https://uploads.linear.app/put/shot.png"
    and (.put.headers | index("x-linear-upload: signed-shot.png"))
    and (.put.headers | index("Content-Type: image/png")))'
assert_log "the image embed lands in the comment body after the --body text" \
  'any(.[]; (.query? // "" | contains("commentCreate"))
    and .variables.input.body == "Note\n\n![shot.png](https://uploads.linear.app/asset/shot.png)\n")'

echo "=== non-image attach appends a markdown link, never attachmentCreate ==="

run_linear comments create TEAM-1 --body "Report" --attach "$TMP_ROOT/notes.pdf"
assert_eq "a pdf attach comment exits zero" "$RC" 0
assert_log "a non-image attach appends a markdown link to the body" \
  'any(.[]; (.query? // "" | contains("commentCreate"))
    and .variables.input.body == "Report\n\n[notes.pdf](https://uploads.linear.app/asset/notes.pdf)\n")'
assert_not_log "comments never call attachmentCreate" \
  'any(.[]; .query? // "" | contains("attachmentCreate"))'

echo "=== --attach alone is a valid comment (body is the embed) ==="

run_linear comments create TEAM-1 --attach "$TMP_ROOT/shot.png"
assert_eq "an attach-only comment exits zero" "$RC" 0
assert_log "an attach-only comment body is the bare embed" \
  'any(.[]; (.query? // "" | contains("commentCreate"))
    and .variables.input.body == "![shot.png](https://uploads.linear.app/asset/shot.png)\n")'

echo "=== --attach composes with --body-file ==="

run_linear comments create TEAM-1 --body-file "$TMP_ROOT/body.md" --attach "$TMP_ROOT/notes.pdf"
assert_eq "a --body-file plus --attach comment exits zero" "$RC" 0
assert_log "the link appends to the --body-file content" \
  'any(.[]; (.query? // "" | contains("commentCreate"))
    and .variables.input.body == "Body from file.\n\n[notes.pdf](https://uploads.linear.app/asset/notes.pdf)\n")'

echo "=== missing file refuses before any API call ==="

run_linear comments create TEAM-1 --attach "$TMP_ROOT/nope.png"
assert_ne "a missing --attach path refuses" "$RC" 0
assert_contains "the missing-path refusal says the file is not readable" "$ERR" "not readable"
assert_eq "a missing --attach path attempts no API call" "$(api_calls)" "0"

echo "=== no body and no attach still refuses ==="

run_linear comments create TEAM-1
assert_ne "a comment with no body and no attach refuses" "$RC" 0
assert_contains "the refusal names --attach as an option" "$ERR" "--attach"

echo "=== markdown label escaping in comment embeds ==="

printf 'PNG' >"$TMP_ROOT/re]port.png"
run_linear comments create TEAM-1 --body "See:" --attach "$TMP_ROOT/re]port.png"
assert_eq "a bracket-named attach exits zero" "$RC" 0
assert_log "the comment body escapes a bracket in the embed label" \
  'any(.[]; (.query? // "" | contains("commentCreate")) and (.variables.input.body | contains("![re\\]port.png](")))'
