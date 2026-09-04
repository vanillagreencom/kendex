#!/usr/bin/env bash
# `issues update <ID> --attach <PATH>`. Image embeds append to the
# description being written — and, when the update carries no
# --description/--description-file, to the issue's EXISTING description
# (append, never wipe). Non-image files become Linear attachments via
# attachmentCreate after the update; `--attach` alone is a valid update that
# skips the issueUpdate mutation entirely. Partial failures after a
# successful write name the issue and exit non-zero.

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
  title_in="$(jq -r '.variables.input.title // empty' <<<"$payload")"
  if [ "$title_in" = "REJECT-UPDATE" ]; then
    printf '%s' '{"data":{"issueUpdate":{"success":false,"issue":null}}}___HTTP_CODE___200'
  else
    printf '%s' "{\"data\":{\"issueUpdate\":{\"success\":true,\"issue\":$ISSUE_JSON}}}___HTTP_CODE___200"
  fi
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

printf '[env]\nLINEAR_TEAM = "Configured"\n' >"$PROJECT/kendex.settings.toml"

printf 'PNGDATA' >"$TMP_ROOT/shot.png"
printf '%%PDF-1.4' >"$TMP_ROOT/notes.pdf"
printf 'x' >"$TMP_ROOT/boom.pdf"

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

echo "=== image attach with no --description appends to the EXISTING description ==="

run_linear issues update TEAM-9 --attach "$TMP_ROOT/shot.png"
assert_eq "an image attach update exits zero" "$RC" 0
assert_log "the embed appends to the existing description" \
  'any(.[]; (.query? // "" | contains("issueUpdate"))
    and .variables.id == "TEAM-9"
    and .variables.input.description == "Existing text.\n\n![shot.png](https://uploads.linear.app/asset/shot.png)")'

echo "=== image attach with --description appends to the NEW description ==="

run_linear issues update TEAM-9 --description "New body" --attach "$TMP_ROOT/shot.png"
assert_eq "an image attach with --description exits zero" "$RC" 0
assert_log "the embed appends to the new description" \
  'any(.[]; (.query? // "" | contains("issueUpdate"))
    and .variables.input.description == "New body\n\n![shot.png](https://uploads.linear.app/asset/shot.png)")'

echo "=== non-image --attach alone is a valid update: attachmentCreate only ==="

run_linear issues update TEAM-9 --attach "$TMP_ROOT/notes.pdf"
assert_eq "an attach-only update exits zero" "$RC" 0
assert_not_log "an attach-only update runs no issueUpdate" \
  'any(.[]; .query? // "" | contains("issueUpdate"))'
assert_log "attachmentCreate carries the issue uuid and asset url" \
  'any(.[]; (.query? // "" | contains("attachmentCreate"))
    and .variables.input.issueId == "issue-uuid-9"
    and .variables.input.url == "https://uploads.linear.app/asset/notes.pdf"
    and .variables.input.title == "notes.pdf")'
assert_jq "an attach-only update reports success and the identifier" \
  "$OUT" '.success == true and .identifier == "TEAM-9"'

echo "=== attachmentCreate failure after a successful update: names issue, non-zero ==="

run_linear issues update TEAM-9 --title "New title" --attach "$TMP_ROOT/boom.pdf"
assert_ne "a failed attachmentCreate fails the update" "$RC" 0
assert_log "issueUpdate runs before the attachment failure" \
  'any(.[]; .query? // "" | contains("issueUpdate"))'
assert_contains "the partial failure names the issue" "$ERR" "TEAM-9"
assert_contains "the partial failure is reported as partial" "$ERR" '"partial":true'
assert_contains "the update summary still reaches stdout" "$OUT" "TEAM-9"

echo "=== missing file refuses before any API call ==="

run_linear issues update TEAM-9 --attach "$TMP_ROOT/nope.png"
assert_ne "a missing --attach path fails" "$RC" 0
assert_contains "the missing-path refusal says the file is not readable" "$ERR" "not readable"
assert_eq "a missing --attach path attempts no API call" "$(api_calls)" "0"

echo "=== issueUpdate payload rejection: nothing attached, non-zero ==="

run_linear issues update TEAM-9 --title "REJECT-UPDATE" --attach "$TMP_ROOT/notes.pdf"
assert_ne "a rejected issueUpdate fails" "$RC" 0
assert_contains "the rejection error says so" "$ERR" "rejected"
assert_not_log "attachmentCreate is never reached after a rejected update" \
  'any(.[]; .query? // "" | contains("attachmentCreate"))'

echo "=== --labels with --clear-labels is refused BEFORE the upload ==="

# The combination can only ever be refused, so refusing it after the upload
# would strand the asset in Linear storage — the same class the pre-upload
# label resolution already guards against.
run_linear issues update TEAM-9 --labels bug --clear-labels --attach "$TMP_ROOT/notes.pdf"
assert_ne "--labels with --clear-labels is refused" "$RC" 0
assert_contains "the conflicting label flags carry a refusal message" "$ERR" "not both"
assert_not_log "the refused update uploaded nothing" \
  'any(.[]; (.query? // "" | contains("fileUpload")) or (.put? != null))'

echo "=== bulk-update forwards --attach to each issue ==="

run_linear issues bulk-update TEAM-9 --attach "$TMP_ROOT/shot.png"
assert_eq "bulk-update --attach exits zero" "$RC" 0
assert_log "bulk-update --attach uploads the file" \
  'any(.[]; .query? // "" | contains("fileUpload"))'
