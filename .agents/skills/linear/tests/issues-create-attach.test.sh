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
  if [ "${FAKE_ASSET_DOWNLOAD:-0}" = "fail" ]; then
    printf '500'
    exit 0
  fi
  if [ "${FAKE_ASSET_DOWNLOAD:-0}" = "1" ]; then
    out="" headers=""
    while (($#)); do
      case "$1" in
      -o) out="$2"; shift 2 ;;
      -D) headers="$2"; shift 2 ;;
      *) shift ;;
      esac
    done
    printf 'research findings\n' >"$out"
    printf 'HTTP/2 200\n' >"$headers"
    printf '200'
    exit 0
  fi
  # background attachment-cache download — out of scope until the sync case
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
*"SyncIssueAttachments"*)
  printf '%s' '{"data":{"attachments":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"url":"https://uploads.linear.app/asset/findings.md","title":"docs/research/TEAM-1/findings.md","issue":{"identifier":"TEAM-1"}}]}}}___HTTP_CODE___200'
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
printf '%%PDF-1.4' >"$TMP_ROOT/second.pdf"
printf 'x' >"$TMP_ROOT/boom.pdf"
printf 'x' >"$TMP_ROOT/put-fail.png"
printf 'Body from file.' >"$TMP_ROOT/desc.md"
mkdir -p "$PROJECT/docs/research/TEAM-1"
printf 'Research notes.' >"$PROJECT/docs/research/TEAM-1/findings.md"

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

run_linear issues create --title "With cited research" \
  --attach "$PROJECT/docs/research/TEAM-1/findings.md"
assert_eq "a repo artifact attachment exits zero" "$RC" 0
assert_log "a repo artifact uses its full repo-relative path as title" \
  'any(.[]; (.query? // "" | contains("attachmentCreate"))
    and .variables.input.title == "docs/research/TEAM-1/findings.md")'

assert_log "a non-image attach injects no description" \
  'any(.[]; (.query? // "" | contains("issueCreate"))
    and (.variables.input | has("description") | not))'

echo "=== the create response carries the attachment records for verification ==="

run_linear issues create --title "Verify one" --attach "$TMP_ROOT/notes.pdf"
assert_eq "a single non-image attach create exits zero" "$RC" 0
assert_jq "a successful create reports the created issue and one requested attachment" \
  "$OUT" '.success == true and .identifier == "TEAM-1"
    and .url == "https://linear.app/x/issue/TEAM-1" and .attachments_requested == 1'
assert_jq "a successful create returns the uploaded asset URL and attachment title" \
  "$OUT" '.attachments == [{url: "https://uploads.linear.app/asset/notes.pdf", repo_path: "notes.pdf"}]'
assert_eq "an attach create keeps the pretty JSON shape every create response has" \
  "$OUT" "$(jq . <<<"$OUT")"

run_linear issues create --title "Verify two" \
  --attach "$TMP_ROOT/notes.pdf" --attach "$TMP_ROOT/second.pdf"
assert_eq "a two-file attach create exits zero" "$RC" 0
assert_jq "two non-image attachments are counted and listed in request order" \
  "$OUT" '.attachments_requested == 2 and .attachments == [
    {url: "https://uploads.linear.app/asset/notes.pdf", repo_path: "notes.pdf"},
    {url: "https://uploads.linear.app/asset/second.pdf", repo_path: "second.pdf"}]'

run_linear issues create --title "Verify mixed" \
  --attach "$TMP_ROOT/shot.png" --attach "$TMP_ROOT/notes.pdf"
assert_eq "a mixed image and file create exits zero" "$RC" 0
assert_log "the image of a mixed create still embeds in the description" \
  'any(.[]; (.query? // "" | contains("issueCreate"))
    and .variables.input.description == "![shot.png](https://uploads.linear.app/asset/shot.png)")'
assert_jq "a mixed create reports only the non-image record" \
  "$OUT" '.attachments_requested == 1
    and .attachments == [{url: "https://uploads.linear.app/asset/notes.pdf", repo_path: "notes.pdf"}]'

run_linear issues create --title "No attach"
assert_eq "a create with no attachments exits zero" "$RC" 0
assert_jq "a create with no attachments keeps the plain normalized response" \
  "$OUT" 'has("attachments_requested") == false and has("attachments") == false
    and .success == true and .identifier == "TEAM-1"'

run_linear issues create --title "Ids format" --format ids --attach "$TMP_ROOT/notes.pdf"
assert_eq "a --format=ids create with an attachment exits zero" "$RC" 0
assert_eq "--format=ids prints only the created identifier" "$OUT" "TEAM-1"

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
assert_jq "a partial failure claims no attachment record" \
  "$OUT" '.attachments_requested == 1 and .attachments == []'

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

echo "=== sync downloads issue attachment objects and keeps their repo paths ==="

export CACHE_PROJECT_ROOT="$PROJECT" LINEAR_API_KEY=test-token
export FAKE_ASSET_DOWNLOAD=1 CURL_LOG
export PATH="$PROJECT/bin:$PATH"
source "$SKILL_DIR/scripts/lib/attachments.sh"
mkdir -p "$PROJECT/.cache/linear"
attach_ensure_dir
printf '[{"identifier":"TEAM-1","description":""}]' >"$PROJECT/.cache/linear/issues.json"
printf '{}' >"$ATTACH_MANIFEST"
GRAPHQL_MODE=objects
graphql_query() {
  case "$GRAPHQL_MODE" in
  objects)
    printf '%s' '{"attachments":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"url":"https://uploads.linear.app/asset/findings.md","title":"docs/research/TEAM-1/findings.md","issue":{"identifier":"TEAM-1"}},{"url":"https://uploads.linear.app/asset/other.md","title":"docs/research/OTHER/findings.md","issue":{"identifier":"OTHER"}}]}}'
    ;;
  empty)
    printf '%s' '{"attachments":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}'
    ;;
  large)
    local page
    read -r page <"$LARGE_COUNTER"
    page=$((page + 1))
    printf '%s\n' "$page" >"$LARGE_COUNTER"
    sed -n "${page}p" "$LARGE_PAGES_FILE"
    ;;
  esac
}
resolve_linear_api_key() { return 0; }

count=$(attach_sync --quiet)
assert_eq "an issue attachment object downloads without a description link" "$count" 1
assert "an issue attachment keeps its exact repo path in cache" \
  jq -e '[.[] | select(.source == "TEAM-1" and .filename == "findings.md" and
    .repo_path == "docs/research/TEAM-1/findings.md" and (.local_path | endswith("_findings.md")))] | length == 1' \
  "$ATTACH_MANIFEST"
cached=$(attach_get_for_issue TEAM-1)
assert_eq "the issue lookup returns its downloaded attachment" \
  "$(jq -r '.[0].repo_path' <<<"$cached")" 'docs/research/TEAM-1/findings.md'
assert_eq "an unrelated issue attachment stays outside this cache" \
  "$(jq 'length' "$ATTACH_MANIFEST")" 1
cached_path=$(jq -r '.[0].local_path' <<<"$cached")
assert_eq "re-uploading a cached file retains its source repo path" \
  "$(attach_issue_title "$cached_path")" 'docs/research/TEAM-1/findings.md'

# A markdown URL may have been downloaded before the attachment object was
# fetched. The object must still supply the cited path on the next sync.
jq 'to_entries | map({key, value: (.value | del(.repo_path) | .context = "description")}) | from_entries' \
  "$ATTACH_MANIFEST" >"$ATTACH_MANIFEST.tmp"
mv "$ATTACH_MANIFEST.tmp" "$ATTACH_MANIFEST"
count=$(attach_sync --quiet)
assert_eq "a previously downloaded URL needs no second download" "$count" 0
assert_eq "an existing download gains the attachment repo path" \
  "$(jq -r '.[].repo_path' "$ATTACH_MANIFEST")" 'docs/research/TEAM-1/findings.md'

LINKED_ROOT="$TMP_ROOT/linked-worktree"
mkdir -p "$LINKED_ROOT"
ln -s "$PROJECT/.cache" "$LINKED_ROOT/.cache"
CACHE_PROJECT_ROOT="$LINKED_ROOT"
source "$SKILL_DIR/scripts/lib/attachments.sh"
printf '{}' >"$ATTACH_MANIFEST"
count=$(attach_sync --quiet)
assert_eq "the shared cache downloads through the linked worktree path" "$count" 1
cached_path=$(jq -r '.[].local_path' "$ATTACH_MANIFEST")
export LINEAR_CACHE_ROOT="$LINKED_ROOT"
run_linear issues create --title "Reattach cached research" --attach "$cached_path"
assert_eq "a cached file reattachment exits zero" "$RC" 0
assert_log "a linked worktree cached file retains its repo path on reattachment" \
  'any(.[]; (.query? // "" | contains("attachmentCreate"))
    and .variables.input.title == "docs/research/TEAM-1/findings.md")'

printf '{"synced_at":"2026-08-08T00:00:00Z"}' >"$PROJECT/.cache/linear/meta.json"
printf '{}' >"$ATTACH_MANIFEST"
run_linear cache attachments fetch TEAM-1
assert_eq "a per-issue attachment fetch succeeds when the file downloads" "$RC" 0
assert_jq "a per-issue attachment fetch reports its download" "$OUT" \
  '.downloaded == 1 and .total_urls == 1'

printf '{}' >"$ATTACH_MANIFEST"
rm -f -- "$cached_path"
export FAKE_ASSET_DOWNLOAD=fail
failed_rc=0
failed_out=$(attach_sync --quiet 2>"$ERR_FILE") || failed_rc=$?
assert_ne "a failed attachment sync exits nonzero" "$failed_rc" 0
assert_file_contains "a failed attachment sync reports its failure count" \
  "$ERR_FILE" 'download_failed=1'
assert_eq "a failed attachment sync prints no success count" "$failed_out" ''

run_linear cache attachments fetch TEAM-1
assert_ne "a failed per-issue attachment fetch exits nonzero" "$RC" 0
assert_contains "a failed per-issue attachment fetch reports its failure count" \
  "$ERR" 'download_failed=1'
run_linear cache attachments fetch
assert_ne "a failed all-issue attachment fetch exits nonzero" "$RC" 0
assert_contains "a failed all-issue attachment fetch reports its failure count" \
  "$ERR" 'download_failed=1'

sync_rc=0
meta_before=$(cat "$PROJECT/.cache/linear/meta.json")
(
  cd "$PROJECT"
  source "$SKILL_DIR/scripts/commands/sync.sh"
  sync_issues() { printf '%s' '[{"id":"issue-uuid","identifier":"TEAM-1","title":"Research","description":"","trashed":false,"archivedAt":null}]'; }
  sync_comments() { printf '%s' '[]'; }
  write_comments() { :; }
  sync_projects() { printf '%s' '[]'; }
  sync_cycles() { printf '%s' '[]'; }
  sync_initiatives() { printf '%s' '[]'; }
  sync_labels() { printf '%s' '[]'; }
  graphql_query() { printf '%s' '{"attachments":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"url":"https://uploads.linear.app/asset/findings.md","title":"docs/research/TEAM-1/findings.md","issue":{"identifier":"TEAM-1"}}]}}'; }
  main --full
) >"$TMP_ROOT/sync-out" 2>"$ERR_FILE" || sync_rc=$?
assert_ne "a failed project sync exits nonzero" "$sync_rc" 0
assert_eq "a failed project sync leaves the cache timestamp unchanged" \
  "$(cat "$PROJECT/.cache/linear/meta.json")" "$meta_before"
export FAKE_ASSET_DOWNLOAD=1

GRAPHQL_MODE=empty
printf '{}' >"$ATTACH_MANIFEST"
count=$(attach_sync --quiet)
assert_eq "a consumer with no attachments keeps an empty cache" "$count" 0
assert_eq "an empty attachment pull records no issue attachment" \
  "$(jq 'length' "$ATTACH_MANIFEST")" 0

LARGE_PAGES_FILE="$TMP_ROOT/large-attachment-pages.jsonl"
LARGE_COUNTER="$TMP_ROOT/large-attachment-page"
jq -n '[range(0; 30) | {identifier: ("TEAM-" + tostring), description: ""}]' \
  >"$PROJECT/.cache/linear/issues.json"
jq -cn '
  [range(0; 1500) as $n | {url: ("https://uploads.linear.app/asset/research-" + ($n | tostring) + ".md"),
    title: ("docs/research/TEAM-" + (($n / 50 | floor) | tostring) + "/research-" + ($n | tostring) + ".md"),
    issue: {identifier: ("TEAM-" + (($n / 50 | floor) | tostring))}}] as $items
  | range(0; 6) as $page
  | {attachments: {pageInfo: {hasNextPage: ($page < 5), endCursor: ("p" + ($page | tostring))},
      nodes: $items[($page * 250):(($page + 1) * 250)]}}
' >"$LARGE_PAGES_FILE"
GRAPHQL_MODE=large
printf '0\n' >"$LARGE_COUNTER"
large_rc=0
large_urls=$(attach_issue_object_urls 2>"$ERR_FILE") || large_rc=$?
assert_eq "a large attachment page series extracts all objects" "$large_rc" 0
assert_eq "the large attachment query keeps every page" \
  "$(jq 'length' <<<"$large_urls")" 1500

printf '0\n' >"$LARGE_COUNTER"
large_rc=0
large_urls=$(attach_extract_all_urls 2>"$ERR_FILE") || large_rc=$?
assert_eq "a large attachment set merges with cached text" "$large_rc" 0
assert_eq "the large attachment merge keeps every issue object" \
  "$(jq 'length' <<<"$large_urls")" 1500

GRAPHQL_MODE=empty
angle_issue_url='https://uploads.linear.app/asset/angle-issue.md'
angle_comment_url='https://uploads.linear.app/asset/angle-comment.md'
assert_eq "an angle markdown URL excludes its closing bracket" \
  "$(attach_extract_urls "(<$angle_issue_url>)")" "$angle_issue_url"
mkdir -p "$PROJECT/.cache/linear/comments"
jq -n --arg url "$angle_issue_url" \
  '[{identifier: "TEAM-1", description: ("(<" + $url + ">)")}]' \
  >"$PROJECT/.cache/linear/issues.json"
jq -n --arg url "$angle_comment_url" \
  '[{body: ("(<" + $url + ">)")}]' \
  >"$PROJECT/.cache/linear/comments/TEAM-1.json"
angle_urls=$(attach_extract_all_urls)
assert_eq "an angle markdown issue URL excludes its closing bracket" \
  "$(jq -r '[.[] | select(.context == "description") | .url] | first' <<<"$angle_urls")" "$angle_issue_url"
assert_eq "an angle markdown comment URL excludes its closing bracket" \
  "$(jq -r '[.[] | select(.context == "comment") | .url] | first' <<<"$angle_urls")" "$angle_comment_url"
