#!/usr/bin/env bash
# `issues create --attach <PATH>` uploads local files through
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
  name="$(jq -r '.variables.name // empty' <<<"$payload")"
  if [ "$name" = "agent:ghost" ]; then
    printf '%s' '{"data":{"issueLabels":{"nodes":[]}}}___HTTP_CODE___200'
  else
    printf '%s' '{"data":{"issueLabels":{"nodes":[{"id":"label-uuid"}]}}}___HTTP_CODE___200'
  fi
  ;;
*"issueCreate(input:"*)
  title_in="$(jq -r '.variables.input.title // empty' <<<"$payload")"
  if [ "$title_in" = "REJECT-CREATE" ]; then
    printf '%s' '{"data":{"issueCreate":{"success":false,"issue":null}}}___HTTP_CODE___200'
    exit 0
  fi
  printf '%s' '{"data":{"issueCreate":{"success":true,"issue":{"id":"issue-uuid","identifier":"TEAM-1","title":"t","description":"","state":{"name":"Todo","type":"unstarted"},"assignee":null,"project":null,"projectMilestone":null,"cycle":null,"parent":null,"team":{"name":"Configured"},"labels":{"nodes":[]},"priority":3,"estimate":null,"sortOrder":1.0,"url":"https://linear.app/x/issue/TEAM-1","createdAt":"2026-08-08T00:00:00Z","updatedAt":"2026-08-08T00:00:00Z","archivedAt":null,"trashed":null,"relations":{"nodes":[]},"inverseRelations":{"nodes":[]}}}}}___HTTP_CODE___200'
  ;;
*)
  printf '%s' '{"data":{}}___HTTP_CODE___200'
  ;;
esac
SH
chmod +x "$PROJECT/bin/curl"

printf '[env]\nLINEAR_TEAM = "Configured"\n' >"$PROJECT/kendex.settings.toml"

printf 'PNGDATA' >"$TMP_ROOT/shot.png" # 7 bytes, image/png
printf '%%PDF-1.4' >"$TMP_ROOT/notes.pdf"
printf 'x' >"$TMP_ROOT/boom.pdf"
printf 'x' >"$TMP_ROOT/put-fail.png"
printf 'Body from file.' >"$TMP_ROOT/desc.md"

OUT=""
ERR=""
RC=0

# assert_log DESC FILTER — FILTER must select a true value over the logged
# curl payloads, read as a stream.
assert_log() {
  assert "$1" jq -s -e "$2" "$CURL_LOG"
}

assert_not_log() {
  assert_not "$1" jq -s -e "$2" "$CURL_LOG"
}

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

echo "=== image attach: fileUpload -> PUT with returned headers -> embed in description ==="

run_linear issues create --title "With image" --attach "$TMP_ROOT/shot.png"
assert_eq "an image attach create exits zero" "$RC" 0

assert_log "fileUpload carries the contentType, filename and size read from the file" \
  'any(.[]; (.query? // "" | contains("fileUpload"))
    and .variables.contentType == "image/png"
    and .variables.filename == "shot.png"
    and .variables.size == 7)'

assert_log "the PUT carries the returned headers plus Content-Type" \
  'any(.[]; .put?.url == "https://uploads.linear.app/put/shot.png"
    and (.put.headers | index("x-linear-upload: signed-shot.png"))
    and (.put.headers | index("x-amz-acl: private"))
    and (.put.headers | index("Content-Type: image/png")))'

# The PUT must precede the create — bytes exist before anything references them.
assert_log "the PUT happens before issueCreate" \
  '([to_entries[] | select(.value | has("put")) | .key] | first)
    < ([to_entries[] | select(.value.query? // "" | contains("issueCreate")) | .key] | first)'

assert_log "the image embed lands in the created description" \
  'any(.[]; (.query? // "" | contains("issueCreate"))
    and .variables.input.description == "![shot.png](https://uploads.linear.app/asset/shot.png)")'

assert_not_log "an image attach embeds rather than calling attachmentCreate" \
  'any(.[]; .query? // "" | contains("attachmentCreate"))'

echo "=== non-image attach: attachmentCreate with the created issue id ==="

run_linear issues create --title "With pdf" --attach "$TMP_ROOT/notes.pdf"
assert_eq "a pdf attach create exits zero" "$RC" 0

assert_log "fileUpload carries application/pdf" \
  'any(.[]; (.query? // "" | contains("fileUpload"))
    and .variables.contentType == "application/pdf")'

assert_log "attachmentCreate carries the created issue id and asset url" \
  'any(.[]; (.query? // "" | contains("attachmentCreate"))
    and .variables.input.issueId == "issue-uuid"
    and .variables.input.url == "https://uploads.linear.app/asset/notes.pdf"
    and .variables.input.title == "notes.pdf")'

assert_log "a non-image attach injects no description" \
  'any(.[]; (.query? // "" | contains("issueCreate"))
    and (.variables.input | has("description") | not))'

echo "=== --attach composes with --description-file ==="

run_linear issues create --title "Compose" \
  --description-file "$TMP_ROOT/desc.md" --attach "$TMP_ROOT/shot.png"
assert_eq "a --description-file plus --attach create exits zero" "$RC" 0

assert_log "the embed appends to the --description-file content" \
  'any(.[]; (.query? // "" | contains("issueCreate"))
    and .variables.input.description == "Body from file.\n\n![shot.png](https://uploads.linear.app/asset/shot.png)")'

echo "=== missing file refuses before any API call ==="

run_linear issues create --title "Missing" --attach "$TMP_ROOT/nope.png"
assert_ne "a missing --attach path fails" "$RC" 0
assert_contains "the missing-path refusal says the file is not readable" "$ERR" "not readable"
assert_contains "the missing-path refusal names the path" "$ERR" "nope.png"
assert_eq "a missing --attach path" "$(api_calls)" "0"

echo "=== PUT failure refuses before the issue exists ==="

run_linear issues create --title "PutFail" --attach "$TMP_ROOT/put-fail.png"
assert_ne "a failed upload PUT fails" "$RC" 0
assert_contains "the failed-PUT error names the PUT" "$ERR" "Upload PUT failed"
assert_not_log "issueCreate is never reached after a failed upload PUT" \
  'any(.[]; .query? // "" | contains("issueCreate"))'

echo "=== attachmentCreate failure AFTER create: names the issue, exits non-zero ==="

run_linear issues create --title "Partial" --attach "$TMP_ROOT/boom.pdf"
assert_ne "a failed attachmentCreate fails" "$RC" 0
assert_log "the issue is created before the attachment failure" \
  'any(.[]; .query? // "" | contains("issueCreate"))'
assert_contains "the partial failure names the created issue" "$ERR" "TEAM-1"
assert_contains "the partial failure is reported as partial" "$ERR" '"partial":true'
assert_contains "the created identifier reaches stdout" "$OUT" "TEAM-1"

echo "=== agent-label guard still refuses BEFORE any upload ==="

printf '[env]\nLINEAR_TEAM = "Configured"\nLINEAR_AGENT_LABELS = "agent:generalist"\n' \
  >"$PROJECT/kendex.settings.toml"
run_linear issues create --title "Guarded" --attach "$TMP_ROOT/shot.png"
assert_ne "a bare create with --attach under the routing guard fails" "$RC" 0
assert_contains "the guard refusal names LINEAR_AGENT_LABELS" "$ERR" "LINEAR_AGENT_LABELS"
assert_eq "a guarded create attempts no API call" "$(api_calls)" "0"

echo "=== markdown label escaping: bracket filename cannot break the embed ==="

printf '[env]\nLINEAR_TEAM = "Configured"\n' >"$PROJECT/kendex.settings.toml"
printf 'PNG' >"$TMP_ROOT/re]port.png"
run_linear issues create --title "Escaped" --attach "$TMP_ROOT/re]port.png"
assert_eq "a bracket-named attach exits zero" "$RC" 0
assert_log "the description embed escapes the bracket in the label" \
  'any(.[]; (.query? // "" | contains("issueCreate")) and (.variables.input.description | contains("![re\\]port.png](")))'

echo "=== issueCreate payload rejection: no attach, non-zero, no created claim ==="

run_linear issues create --title "REJECT-CREATE" --attach "$TMP_ROOT/notes.pdf"
assert_ne "a rejected issueCreate fails" "$RC" 0
assert_contains "the rejection error says so" "$ERR" "rejected"
assert_not_log "attachmentCreate is never reached after a rejected create" \
  'any(.[]; .query? // "" | contains("attachmentCreate"))'

echo "=== declared taxonomy: unresolvable agent label refuses BEFORE uploads ==="

printf '[env]\nLINEAR_TEAM = "Configured"\nLINEAR_AGENT_LABELS = "agent:generalist, agent:ghost"\n' \
  >"$PROJECT/kendex.settings.toml"
run_linear issues create --title "Orphan guard" --labels "agent:ghost" --attach "$TMP_ROOT/shot.png"
assert_ne "an unresolvable agent label with --attach fails" "$RC" 0
assert_not_log "no upload runs before the routed-or-refused check" \
  'any(.[]; .query? // "" | contains("fileUpload"))'

echo "=== bare --attach is a structured usage error, not a set -u abort ==="

printf '[env]\nLINEAR_TEAM = "Configured"\n' >"$PROJECT/kendex.settings.toml"
run_linear issues create --title "Bare" --attach
assert_ne "a bare --attach fails" "$RC" 0
assert_contains "a bare --attach gives a structured usage error" "$ERR" "requires a path"

