#!/usr/bin/env bash
# VST-126: `comments create <ID> --attach <PATH>`. Files upload through
# Linear's fileUpload flow and are referenced from the comment body: images
# embed as ![name](assetUrl), other files append a [name](assetUrl) markdown
# link (comments have no attachmentCreate surface). --attach composes with
# --body/--body-file, permits a body-less comment, and a missing/unreadable
# path refuses before any API call.

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

printf '[env]\nLINEAR_TEAM = "Configured"\n' >"$PROJECT/vstack.settings.toml"

printf 'PNGDATA' >"$TMP_ROOT/shot.png"
printf '%%PDF-1.4' >"$TMP_ROOT/notes.pdf"
printf 'Body from file.' >"$TMP_ROOT/body.md"

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

echo "=== image attach embeds into the comment body after --body text ==="

run_linear comments create TEAM-1 --body "Note" --attach "$TMP_ROOT/shot.png"
[[ "$RC" -eq 0 ]] || fail "image attach comment exited $RC: $ERR"
jq -s -e 'any(.[]; (.query? // "" | contains("fileUpload"))
    and .variables.contentType == "image/png"
    and .variables.size == 7)' "$CURL_LOG" >/dev/null ||
  fail "fileUpload not called with contentType/size from the file"
jq -s -e 'any(.[]; .put?.url == "https://uploads.linear.app/put/shot.png"
    and (.put.headers | index("x-linear-upload: signed-shot.png"))
    and (.put.headers | index("Content-Type: image/png")))' "$CURL_LOG" >/dev/null ||
  fail "PUT did not carry the returned headers plus Content-Type"
jq -s -e 'any(.[]; (.query? // "" | contains("commentCreate"))
    and .variables.input.body == "Note\n\n![shot.png](https://uploads.linear.app/asset/shot.png)\n")' \
  "$CURL_LOG" >/dev/null || fail "image embed missing from comment body"

echo "=== non-image attach appends a markdown link, never attachmentCreate ==="

run_linear comments create TEAM-1 --body "Report" --attach "$TMP_ROOT/notes.pdf"
[[ "$RC" -eq 0 ]] || fail "pdf attach comment exited $RC: $ERR"
jq -s -e 'any(.[]; (.query? // "" | contains("commentCreate"))
    and .variables.input.body == "Report\n\n[notes.pdf](https://uploads.linear.app/asset/notes.pdf)\n")' \
  "$CURL_LOG" >/dev/null || fail "markdown link missing from comment body"
if jq -s -e 'any(.[]; .query? // "" | contains("attachmentCreate"))' "$CURL_LOG" >/dev/null; then
  fail "comments must never call attachmentCreate"
fi

echo "=== --attach alone is a valid comment (body is the embed) ==="

run_linear comments create TEAM-1 --attach "$TMP_ROOT/shot.png"
[[ "$RC" -eq 0 ]] || fail "attach-only comment exited $RC: $ERR"
jq -s -e 'any(.[]; (.query? // "" | contains("commentCreate"))
    and .variables.input.body == "![shot.png](https://uploads.linear.app/asset/shot.png)\n")' \
  "$CURL_LOG" >/dev/null || fail "attach-only body is not the bare embed"

echo "=== --attach composes with --body-file ==="

run_linear comments create TEAM-1 --body-file "$TMP_ROOT/body.md" --attach "$TMP_ROOT/notes.pdf"
[[ "$RC" -eq 0 ]] || fail "body-file + attach comment exited $RC: $ERR"
jq -s -e 'any(.[]; (.query? // "" | contains("commentCreate"))
    and .variables.input.body == "Body from file.\n\n[notes.pdf](https://uploads.linear.app/asset/notes.pdf)\n")' \
  "$CURL_LOG" >/dev/null || fail "link did not append to --body-file content"

echo "=== missing file refuses before any API call ==="

run_linear comments create TEAM-1 --attach "$TMP_ROOT/nope.png"
[[ "$RC" -ne 0 ]] || fail "missing --attach path exited 0: $OUT"
grep -q "not readable" <<<"$ERR" || fail "missing-path refusal lacks 'not readable': $ERR"
[[ "$(api_calls)" == "0" ]] || fail "missing --attach path attempted $(api_calls) API call(s)"

echo "=== no body and no attach still refuses ==="

run_linear comments create TEAM-1
[[ "$RC" -ne 0 ]] || fail "body-less, attach-less comment exited 0: $OUT"
grep -q -- "--attach" <<<"$ERR" || fail "refusal does not mention --attach as an option: $ERR"

echo "all pass"
