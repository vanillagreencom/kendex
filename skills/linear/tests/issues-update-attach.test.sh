#!/usr/bin/env bash
# bash-runtime: 4
# `issues update <ID> --attach <PATH>`. Image embeds append to the
# description being written — and, when the update carries no
# --description/--description-file, to the issue's EXISTING description
# (append, never wipe). Non-image files become Linear attachments via
# attachmentCreate after the update; `--attach` alone is a valid update that
# skips the issueUpdate mutation entirely. Partial failures after a
# successful write name the issue and exit non-zero. Retained non-image
# records survive upload/binding failures and resume without reupload.

set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
assert_tmpdir TMP_ROOT

PROJECT="$TMP_ROOT/project"
mkdir -p "$PROJECT/.agents/skills" "$PROJECT/bin"
git -C "$PROJECT" init -q -b main
git -C "$PROJECT" config gc.auto 0
git -C "$PROJECT" config maintenance.auto false
cp -R "$SKILL_DIR" "$PROJECT/.agents/skills/linear"

LINEAR="$PROJECT/.agents/skills/linear/scripts/linear.sh"
CURL_LOG="$TMP_ROOT/curl-payloads.jsonl"
ERR_FILE="$TMP_ROOT/stderr.txt"

ISSUE_JSON='{"id":"issue-uuid-9","identifier":"TEAM-9","title":"t","description":"Existing text.","state":{"name":"Todo","type":"unstarted"},"assignee":null,"project":null,"projectMilestone":null,"cycle":null,"parent":null,"team":{"key":"TEAM","name":"Configured"},"labels":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]},"priority":3,"estimate":null,"sortOrder":1.0,"url":"https://linear.app/x/issue/TEAM-9","createdAt":"2026-08-08T00:00:00Z","updatedAt":"2026-08-08T00:00:00Z","archivedAt":null,"trashed":null,"relations":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]},"inverseRelations":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}'

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
  if [[ -n "${FAIL_PUT_FILE:-}" && "${file##*/}" == "$FAIL_PUT_FILE" ]]; then
    printf '403'
    exit 0
  fi
  printf '%s' "${PUT_HTTP:-200}"
  exit "${PUT_EXIT:-0}"
fi

payload="$(sed -n 's/^data = //p' <<<"$config" | jq -r)"
printf '%s\n' "$payload" >>"${CURL_LOG:?}"
query="$(jq -r '.query' <<<"$payload")"

case "$query" in
*"fileUpload("*)
  filename="$(jq -r '.variables.filename' <<<"$payload")"
  if [[ "$filename" == "${FAIL_UPLOAD_FILE:-}" ]]; then
    printf '%s' '{"errors":[{"message":"fixture-upload-denied"}]}___HTTP_CODE___200'
    exit 0
  fi
  printf '%s' "{\"data\":{\"fileUpload\":{\"success\":true,\"uploadFile\":{\"uploadUrl\":\"https://uploads.linear.app/put/$filename\",\"assetUrl\":\"https://uploads.linear.app/asset/$filename\",\"headers\":[{\"key\":\"x-linear-upload\",\"value\":\"signed-$filename\"}]}}}}___HTTP_CODE___200"
  ;;
*"attachmentCreate("*)
  title="$(jq -r '.variables.input.title' <<<"$payload")"
  if [ "$title" = "boom.pdf" ]; then
    printf '%s' '{"errors":[{"message":"fixture-bind-denied"}]}___HTTP_CODE___200'
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
  issue="$(jq -r '.variables.id' <<<"$payload")"
  if [[ -n "${REWRITE_RETAINED_FILE:-}" ]]; then
    printf '[]' >"$REWRITE_RETAINED_FILE"
  fi
  case "$issue" in
    TEAM-404|00000000-0000-0000-0000-000000000404)
      printf '%s' '{"data":{"issue":null}}___HTTP_CODE___200' ;;
    *)
      printf '%s' "{\"data\":{\"issue\":$ISSUE_JSON}}___HTTP_CODE___200" ;;
  esac
  ;;
*"teams(filter:"*)
  printf '%s' '{"data":{"teams":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"team-uuid","key":"TEAM","name":"Team"}]}}}___HTTP_CODE___200'
  ;;
*)
  printf '%s' '{"data":{}}___HTTP_CODE___200'
  ;;
esac
SH
chmod +x "$PROJECT/bin/curl"

printf '[env]\nLINEAR_TEAM = "TEAM"\n' >"$PROJECT/kendex.settings.toml"

printf 'PNGDATA' >"$TMP_ROOT/shot.png"
printf '%%PDF-1.4' >"$TMP_ROOT/notes.pdf"
printf 'x' >"$TMP_ROOT/boom.pdf"
printf 'later' >"$TMP_ROOT/later.pdf"
printf 'last' >"$TMP_ROOT/last.pdf"

OUT=""
ERR=""
RC=0

run_linear() {
  : >"$CURL_LOG"
  RC=0
  OUT="$(cd "$PROJECT" && env -u LINEAR_TEAM -u LINEAR_AGENT_LABELS \
    PATH="$PROJECT/bin:$PATH" \
    LINEAR_API_KEY=test-token \
    PUT_HTTP="${PUT_HTTP:-200}" PUT_EXIT="${PUT_EXIT:-0}" \
    FAIL_UPLOAD_FILE="${FAIL_UPLOAD_FILE:-}" FAIL_PUT_FILE="${FAIL_PUT_FILE:-}" \
    REWRITE_RETAINED_FILE="${REWRITE_RETAINED_FILE:-}" \
    CURL_LOG="$CURL_LOG" \
    "$BASH" "$LINEAR" "$@" </dev/null 2>"$ERR_FILE")" || RC=$?
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

# The existing storage PUT producer can fail before HTTP or after a response.
while IFS='|' read -r name PUT_HTTP PUT_EXIT expected_http; do
  run_linear issues update TEAM-9 --attach "$TMP_ROOT/notes.pdf"
  assert_ne "$name: PUT failure fails the caller" "$RC" 0
  assert_jq "$name: empty reusable queue on first PUT failure" "$OUT" \
    '.success == false and .partial == false and .pending_attachments == [] and (.remaining_files | length) == 1'
  assert_jq "$name: safe PUT diagnostic" "$(jq -sc 'map(select(has("curl_exit")))' <<<"$ERR")" \
    "length == 1 and .[0].http_code == \"$expected_http\" and .[0].curl_exit == $PUT_EXIT"
  assert_not_log "$name: no attachment record after failed PUT" \
    'any(.[]; .query? // "" | contains("attachmentCreate"))'
  assert_not_contains "$name: signed URL stays private" "$OUT$ERR" 'https://uploads.linear.app/put/notes.pdf'
  assert_not_contains "$name: signed header stays private" "$OUT$ERR" 'signed-notes.pdf'
done <<'CASES'
connection|000|7|000
local-read|000|26|000
http-rejected|403|0|403
response-then-failure|200|26|000
CASES
unset PUT_HTTP PUT_EXIT

mkdir -p "$PROJECT/docs/research/TEAM-9"
printf 'Research notes.' >"$PROJECT/docs/research/TEAM-9/findings.md"
run_linear issues update TEAM-9 --attach "$PROJECT/docs/research/TEAM-9/findings.md"
assert_eq "a cited artifact attach-only update exits zero" "$RC" 0
assert_jq "an attach-only update returns the new asset URL and repo path" \
  "$OUT" '.attachments == [{url: "https://uploads.linear.app/asset/findings.md", repo_path: "docs/research/TEAM-9/findings.md"}]'

while IFS='|' read -r name title; do
  field_args=()
  [ -z "$title" ] || field_args=(--title "$title")
  run_linear issues update TEAM-9 "${field_args[@]}" --attach "$PROJECT/docs/research/TEAM-9/findings.md" \
    --attach "$TMP_ROOT/shot.png" --attach "$TMP_ROOT/notes.pdf"
  assert_eq "$name: succeeds" "$RC" 0
  assert_jq "$name: returns actual non-image receipts in request order" "$OUT" \
    '.success == true and .identifier == "TEAM-9" and .data != null and .attachments_requested == 2
      and .attachments == [{url: "https://uploads.linear.app/asset/findings.md", repo_path: "docs/research/TEAM-9/findings.md"},
        {url: "https://uploads.linear.app/asset/notes.pdf", repo_path: "notes.pdf"}]'
  assert_log "$name: preserves the image embed and uploads each file once" \
    '([.[] | select(.query? // "" | contains("fileUpload("))] | length) == 3
      and ([.[] | select(.put? != null)] | length) == 3
      and ([.[] | select(.query? // "" | contains("attachmentCreate("))] | length) == 2
      and any(.[]; (.query? // "" | contains("issueUpdate("))
        and .variables.input.description == "Existing text.\n\n![shot.png](https://uploads.linear.app/asset/shot.png)")'
done <<'CASES'
mixed attach-only|
mixed with title|New title
CASES

run_linear issues update TEAM-9 --title "New title"
assert_eq "an ordinary field update succeeds" "$RC" 0
assert_jq "an ordinary field update retains its mutation summary without receipts" "$OUT" \
  '.success == true and .identifier == "TEAM-9" and .data != null
    and (has("attachments_requested") | not) and (has("attachments") | not)'
assert_log "an ordinary field update sends its title without uploads" \
  'any(.[]; (.query? // "" | contains("issueUpdate(")) and .variables.input.title == "New title")
    and all(.[]; ((.query? // "" | contains("fileUpload(")) | not) and .put? == null)'

echo "=== attachmentCreate failure after a successful update: names issue, non-zero ==="

while IFS='|' read -r name title format; do
  field_args=()
  [ -z "$title" ] || field_args+=(--title "$title")
  [ -z "$format" ] || field_args+=(--format "$format")
  run_linear issues update TEAM-9 "${field_args[@]}" --attach "$TMP_ROOT/notes.pdf" --attach "$TMP_ROOT/boom.pdf"
  assert_eq "$name: preserves binding failure status" "$RC" 1
  assert_jq "$name: attempted pairs remain retryable without success receipts" "$OUT" \
    '.success == false and .partial == true and .identifier == "TEAM-9" and .attachments_requested == 2
      and .attachments == [] and .pending_attachments == [
        {url:"https://uploads.linear.app/asset/notes.pdf",repo_path:"notes.pdf"},
        {url:"https://uploads.linear.app/asset/boom.pdf",repo_path:"boom.pdf"}]'
  # The original API error is a caller-consumed cause, not CLI prose.
  assert_jq "$name: preserves the API failure cause" "$(jq -sc 'map(select(.error? == "fixture-bind-denied"))' <<<"$ERR")" 'length == 1'
done <<'CASES'
bind attach-only||
bind field update|New title|
bind formatted update|New title|ids
CASES

for action in update create; do
  FAIL_UPLOAD_FILE=later.pdf
  if [[ "$action" == update ]]; then action_args=(TEAM-9); else action_args=(--title fixture --description $'Fixture.\nReached by: fixture'); fi
  run_linear issues "$action" "${action_args[@]}" --attach "$TMP_ROOT/notes.pdf" \
    --attach "$TMP_ROOT/later.pdf" --attach "$TMP_ROOT/last.pdf"
  unset FAIL_UPLOAD_FILE
  assert_eq "$action: shared upload failure remains failed" "$RC" 1
  assert_jq "$action: shared upload owner publishes reusable pairs" "$OUT" \
    '.success == false and .pending_attachments == [{url:"https://uploads.linear.app/asset/notes.pdf",repo_path:"notes.pdf"}]
      and (.remaining_files | length) == 2'
done

echo "=== later upload failures retain completed pairs and exact upload suffix ==="

for failure in graphql put; do
  FAIL_UPLOAD_FILE="" FAIL_PUT_FILE=""
  if [[ "$failure" == graphql ]]; then FAIL_UPLOAD_FILE=later.pdf; else FAIL_PUT_FILE=later.pdf; fi
  run_linear issues update TEAM-9 --attach "$TMP_ROOT/notes.pdf" --attach "$TMP_ROOT/shot.png" \
    --attach "$TMP_ROOT/later.pdf" --attach "$TMP_ROOT/last.pdf"
  assert_eq "$failure: preserves upload failure status" "$RC" 1
  assert_jq "$failure: completed non-image survives the failed batch" "$OUT" \
    '.success == false and .partial == true and .pending_attachments == [
      {url:"https://uploads.linear.app/asset/notes.pdf",repo_path:"notes.pdf"}]'
  suffix=$(jq -c --arg failed "$TMP_ROOT/later.pdf" --arg last "$TMP_ROOT/last.pdf" \
    '.failed_path == $failed and .remaining_files == [$failed,$last]' <<<"$OUT")
  assert_eq "$failure: exact failed and unattempted upload suffix" "$suffix" true
  assert_not_log "$failure: failed batch writes no embeds or bindings and skips last upload" \
    'any(.[]; (.query? // "" | test("issueUpdate\\(|attachmentCreate\\(")) or .variables.filename? == "last.pdf")'
  if [[ "$failure" == graphql ]]; then
    assert_jq "$failure: preserves upload API cause" "$(jq -sc 'map(select(.error? == "fixture-upload-denied"))' <<<"$ERR")" 'length == 1'
  else
    assert_jq "$failure: preserves PUT cause" "$(jq -sc 'map(select(has("curl_exit")))' <<<"$ERR")" \
      'length == 1 and .[0].http_code == "403" and .[0].curl_exit == 0'
  fi
  assert_not_contains "$failure: pending output excludes private upload URLs" "$OUT$ERR" 'https://uploads.linear.app/put/'
  assert_not_contains "$failure: pending output excludes private headers" "$OUT$ERR" 'signed-'
done
unset FAIL_UPLOAD_FILE FAIL_PUT_FILE

RETAINED="$TMP_ROOT/retained.json"
printf '%s' '[{"url":"https://uploads.linear.app/opaque/path%20part","repo_path":"missing/original %.md  "}]' >"$RETAINED"
REWRITE_RETAINED_FILE="$RETAINED"
run_linear issues update TEAM-9 --attach-uploaded "$RETAINED"
unset REWRITE_RETAINED_FILE
assert_eq "resume succeeds after its input is captured" "$RC" 0
assert_log "resume binds exact captured strings without any upload or field mutation" \
  'any(.[]; (.query? // "" | contains("attachmentCreate(")) and .variables.input.issueId == "issue-uuid-9"
    and .variables.input.url == "https://uploads.linear.app/opaque/path%20part" and .variables.input.title == "missing/original %.md  ")
    and all(.[]; (.query? // "" | test("fileUpload\\(|issueUpdate\\(") | not) and .put? == null)'
assert_jq "resume returns confirmed pairs in the existing receipt contract" "$OUT" \
  '.success == true and .attachments_requested == 1 and .attachments == [
    {url:"https://uploads.linear.app/opaque/path%20part",repo_path:"missing/original %.md  "}]'

jq '.attachments' <<<"$OUT" >"$RETAINED"
FAIL_UPLOAD_FILE=later.pdf
run_linear issues update TEAM-9 --attach-uploaded="$RETAINED" --attach "$TMP_ROOT/notes.pdf" \
  --attach "$TMP_ROOT/later.pdf" --attach "$TMP_ROOT/last.pdf"
unset FAIL_UPLOAD_FILE
assert_eq "combined resume upload failure remains failed" "$RC" 1
assert_jq "combined resume re-emits retained and newly completed pairs" "$OUT" \
  '.pending_attachments == [{url:"https://uploads.linear.app/opaque/path%20part",repo_path:"missing/original %.md  "},
    {url:"https://uploads.linear.app/asset/notes.pdf",repo_path:"notes.pdf"}]'
jq '.pending_attachments' <<<"$OUT" >"$RETAINED"
run_linear issues update TEAM-9 --attach-uploaded "$RETAINED" --attach "$TMP_ROOT/later.pdf" --attach "$TMP_ROOT/last.pdf"
assert_eq "combined resume succeeds" "$RC" 0
assert_log "combined resume uploads only remaining files" \
  '([.[] | select(.query? // "" | contains("fileUpload(")) | .variables.filename] == ["later.pdf","last.pdf"])
    and ([.[] | select(.put? != null)] | length) == 2
    and ([.[] | select(.query? // "" | contains("attachmentCreate("))] | length) == 4'
assert_jq "combined resume confirms the complete ordered binding queue" "$OUT" \
  '.success == true and .attachments_requested == 4 and (.attachments | map(.repo_path)) == ["missing/original %.md  ","notes.pdf","later.pdf","last.pdf"]'

while IFS='|' read -r name input; do
  printf '%s' "$input" >"$RETAINED"
  run_linear issues update TEAM-9 --attach-uploaded "$RETAINED"
  assert_eq "$name: invalid retained input refuses" "$RC" 1
  assert_eq "$name: invalid retained input sends no API request" "$(api_calls)" 0
  assert_eq "$name: invalid retained input prints no success" "$OUT" ''
  assert_jq "$name: retained input has a typed refusal" "$ERR" '.code == "ATTACH_UPLOADED_INVALID"'
done <<'CASES'
invalid JSON|[
multiple values|[] []
empty array|[]
non-array|{}
missing path|[{"url":"https://uploads.linear.app/a"}]
missing URL|[{"repo_path":"a"}]
empty path|[{"url":"https://uploads.linear.app/a","repo_path":""}]
wrong type|[{"url":"https://uploads.linear.app/a","repo_path":1}]
private endpoint|[{"uploadUrl":"https://uploads.linear.app/a","headers":[],"repo_path":"a"}]
private headers|[{"url":"https://uploads.linear.app/a","headers":[],"repo_path":"a"}]
other host|[{"url":"https://uploads.linear.app.evil/a","repo_path":"a"}]
empty URL path|[{"url":"https://uploads.linear.app/","repo_path":"a"}]
signed query|[{"url":"https://uploads.linear.app/a?signature=private","repo_path":"a"}]
fragment|[{"url":"https://uploads.linear.app/a#part","repo_path":"a"}]
tab path|[{"url":"https://uploads.linear.app/a","repo_path":"a\tb"}]
newline URL|[{"url":"https://uploads.linear.app/a\nb","repo_path":"a"}]
NUL path|[{"url":"https://uploads.linear.app/a","repo_path":"a\u0000b"}]
valid then invalid|[{"url":"https://uploads.linear.app/a","repo_path":"a"},{"url":"https://uploads.linear.app/b"}]
CASES
run_linear issues update TEAM-9 --attach-uploaded "$TMP_ROOT/missing.json"
assert_eq "unreadable retained file sends no API request" "$(api_calls)" 0
assert_jq "unreadable retained file has a typed refusal" "$ERR" '.code == "ATTACH_UPLOADED_INVALID"'

printf '%s' '[{"url":"https://uploads.linear.app/retained","repo_path":"boom.pdf"}]' >"$RETAINED"
run_linear issues update TEAM-9 --attach-uploaded "$RETAINED"
assert_eq "resumed binding failure remains failed" "$RC" 1
assert_jq "resumed binding failure retains retryable pair" "$OUT" \
  '.success == false and .attachments == [] and .pending_attachments == [{url:"https://uploads.linear.app/retained",repo_path:"boom.pdf"}]'
assert_not_log "resumed binding failure never reuploads" \
  'any(.[]; (.query? // "" | contains("fileUpload(")) or .put? != null)'

echo "=== missing file refuses before any API call ==="

run_linear issues update TEAM-9 --attach "$TMP_ROOT/nope.png"
assert_ne "a missing --attach path fails" "$RC" 0
assert_eq "a missing --attach path attempts no API call" "$(api_calls)" "0"

echo "=== issueUpdate payload rejection: nothing attached, non-zero ==="

run_linear issues update TEAM-9 --title "REJECT-UPDATE" --attach "$TMP_ROOT/notes.pdf"
assert_ne "a rejected issueUpdate fails" "$RC" 0
assert_not_log "attachmentCreate is never reached after a rejected update" \
  'any(.[]; .query? // "" | contains("attachmentCreate"))'

echo "=== --labels with --clear-labels is refused BEFORE the upload ==="

# The combination can only ever be refused, so refusing it after the upload
# would strand the asset in Linear storage — the same class the pre-upload
# label resolution already guards against.
run_linear issues update TEAM-9 --labels bug --clear-labels --attach "$TMP_ROOT/notes.pdf"
assert_ne "--labels with --clear-labels is refused" "$RC" 0
assert_not_log "the refused update uploaded nothing" \
  'any(.[]; (.query? // "" | contains("fileUpload")) or (.put? != null))'

echo "=== bulk-update forwards --attach to each issue ==="

run_linear issues bulk-update TEAM-9 --attach "$TMP_ROOT/shot.png"
assert_eq "bulk-update --attach exits zero" "$RC" 0
assert_log "bulk-update --attach uploads the file" \
  'any(.[]; .query? // "" | contains("fileUpload"))'

echo "=== attachment destination lookup without a configured team ==="

printf '[env]\n' >"$PROJECT/kendex.settings.toml"
# Linear returns a null issue for a missing destination. Both attachment types
# must wait for the live reader, including when bulk-update calls update.
while IFS='|' read -r name action issue file expected; do
  run_linear issues "$action" "$issue" --attach "$TMP_ROOT/$file"
  if [[ "$expected" == valid ]]; then
    assert_eq "$name: attachment succeeds" "$RC" 0
    assert_log "$name: live lookup precedes upload" \
      'length == 4 and (.[0].query | contains("query GetIssue("))
        and (.[1].query | contains("fileUpload(")) and .[2].put != null
        and (.[3].query | contains("issueUpdate(") or contains("attachmentCreate("))'
  else
    assert_ne "$name: missing issue refuses the attachment" "$RC" 0
    assert_log "$name: lookup is the only request, with no upload or mutation" \
      'length == 1 and (.[0].query | contains("query GetIssue("))'
  fi
done <<'CASES'
valid update image|update|TEAM-9|shot.png|valid
valid update file|update|TEAM-9|notes.pdf|valid
valid bulk image|bulk-update|TEAM-9|shot.png|valid
valid bulk file|bulk-update|TEAM-9|notes.pdf|valid
missing update identifier|update|TEAM-404|notes.pdf|missing
missing update UUID|update|00000000-0000-0000-0000-000000000404|shot.png|missing
missing bulk identifier|bulk-update|TEAM-404|notes.pdf|missing
missing bulk UUID|bulk-update|00000000-0000-0000-0000-000000000404|shot.png|missing
CASES

for issue in TEAM-404 00000000-0000-0000-0000-000000000404; do
  run_linear issues update "$issue" --attach-uploaded "$RETAINED"
  assert_eq "$issue: retained binding requires a live destination" "$RC" 1
  assert_log "$issue: retained lookup refusal sends no mutation or upload" \
    'length == 1 and (.[0].query | contains("query GetIssue("))'
done
