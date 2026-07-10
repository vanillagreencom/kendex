#!/usr/bin/env bash
# Regression test for issues create/update --description-file parsing without the real API.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

mkdir -p "$TMP_ROOT/.agents/skills" "$TMP_ROOT/bin"
cp -R "$SKILL_DIR" "$TMP_ROOT/.agents/skills/linear"

# Mocked curl: routes by GraphQL operation, logs each request payload for assertions.
cat >"$TMP_ROOT/bin/curl" <<'SH'
#!/usr/bin/env bash
config="$(cat)"
payload="$(sed -n 's/^data = //p' <<<"$config" | jq -r)"
query="$(jq -r '.query' <<<"$payload")"
variables="$(jq -c '.variables' <<<"$payload")"
printf '%s\n' "$payload" >> "${CURL_PAYLOAD_LOG:?}"

issue_json='{"id":"issue-uuid","identifier":"PROJ-1","title":"t","description":"d","state":{"name":"Todo","type":"unstarted"},"assignee":null,"project":null,"projectMilestone":null,"cycle":null,"parent":null,"team":{"name":"Claude"},"labels":{"nodes":[]},"priority":3,"estimate":null,"sortOrder":1.0,"url":"https://linear.app/test/issue/PROJ-1","createdAt":"2026-07-03T00:00:00Z","updatedAt":"2026-07-03T00:00:00Z","archivedAt":null,"trashed":null,"relations":{"nodes":[]},"inverseRelations":{"nodes":[]}}'

case "$query" in
*"teams(filter:"*)
  printf '%s' '{"data":{"teams":{"nodes":[{"id":"team-uuid"}]}}}___HTTP_CODE___200'
  ;;
*"issueCreate(input:"*)
  printf '%s' "{\"data\":{\"issueCreate\":{\"success\":true,\"issue\":$issue_json}}}___HTTP_CODE___200"
  ;;
*"issueUpdate(id:"*)
  printf '%s' "{\"data\":{\"issueUpdate\":{\"success\":true,\"issue\":$issue_json}}}___HTTP_CODE___200"
  ;;
*"issue(id:"*)
  printf '%s' '{"data":{"issue":{"identifier":"PROJ-1","team":{"name":"Claude"}}}}___HTTP_CODE___200'
  ;;
*)
  printf '%s' '{"errors":[{"message":"unexpected query"}]}___HTTP_CODE___200'
  ;;
esac
SH
chmod +x "$TMP_ROOT/bin/curl"

LINEAR="$TMP_ROOT/.agents/skills/linear/scripts/linear.sh"

# Multiline markdown with backticks and quotes that must survive verbatim.
desc_file="$TMP_ROOT/description.md"
cat >"$desc_file" <<'MD'
## Plan

Use `foo_bar()` and preserve "quoted" values exactly.

- item one
- item two
MD

# --- create with --description-file --------------------------------------------
create_log="$TMP_ROOT/create-payloads.jsonl"
: >"$create_log"
create_out="$(PATH="$TMP_ROOT/bin:$PATH" LINEAR_API_KEY=test-token CURL_PAYLOAD_LOG="$create_log" \
  bash "$LINEAR" issues create --title "New task" --team Claude --description-file "$desc_file")"

if ! jq -e '.success == true and .identifier == "PROJ-1"' >/dev/null <<<"$create_out"; then
  echo "FAIL issues create --description-file returned unexpected output: $create_out"
  exit 1
fi

if ! jq -s -e '
  any(.[];
    (.query | contains("issueCreate"))
    and (.variables.input.description | contains("## Plan"))
    and (.variables.input.description | contains("`foo_bar()`"))
    and (.variables.input.description | contains("\"quoted\""))
    and (.variables.input.description | contains("- item one")))
' "$create_log" >/dev/null; then
  echo "FAIL issueCreate payload did not carry the markdown description verbatim"
  cat "$create_log"
  exit 1
fi

# --- update with --description-file --------------------------------------------
update_log="$TMP_ROOT/update-payloads.jsonl"
: >"$update_log"
update_out="$(PATH="$TMP_ROOT/bin:$PATH" LINEAR_API_KEY=test-token CURL_PAYLOAD_LOG="$update_log" \
  bash "$LINEAR" issues update PROJ-1 --description-file "$desc_file")"

if ! jq -e '.success == true' >/dev/null <<<"$update_out"; then
  echo "FAIL issues update --description-file returned unexpected output: $update_out"
  exit 1
fi

if ! jq -s -e '
  any(.[];
    (.query | contains("issueUpdate"))
    and (.variables.input.description | contains("## Plan"))
    and (.variables.input.description | contains("`foo_bar()`"))
    and (.variables.input.description | contains("\"quoted\"")))
' "$update_log" >/dev/null; then
  echo "FAIL issueUpdate payload did not carry the markdown description verbatim"
  cat "$update_log"
  exit 1
fi

# --- helper: assert a command fails with an expected stderr substring -----------
assert_fails() {
  local expected="$1"; shift
  local err_file="$TMP_ROOT/err.txt"
  local rc
  set +e
  PATH="$TMP_ROOT/bin:$PATH" LINEAR_API_KEY=test-token \
    bash "$LINEAR" "$@" >"$TMP_ROOT/out.txt" 2>"$err_file"
  rc=$?
  set -e
  if [[ "$rc" -eq 0 ]]; then
    echo "FAIL command unexpectedly succeeded: $*"
    cat "$TMP_ROOT/out.txt"
    exit 1
  fi
  if ! grep -q "$expected" "$err_file"; then
    echo "FAIL command '$*' missing expected error '$expected'"
    cat "$err_file"
    exit 1
  fi
}

# --- mutual exclusivity (create + update) --------------------------------------
assert_fails "mutually exclusive" issues create --title "New task" --team Claude \
  --description inline --description-file "$desc_file"
assert_fails "mutually exclusive" issues update PROJ-1 \
  --description inline --description-file "$desc_file"

# --- unreadable / missing path errors (create + update) ------------------------
assert_fails "not readable" issues create --title "New task" --team Claude \
  --description-file "$TMP_ROOT/does-not-exist.md"
assert_fails "not readable" issues update PROJ-1 \
  --description-file "$TMP_ROOT/does-not-exist.md"

echo "all pass"
