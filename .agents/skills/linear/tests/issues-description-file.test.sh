#!/usr/bin/env bash
# Tests for issues create/update --description-file parsing without the real API.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
assert_tmpdir TMP_ROOT

mkdir -p "$TMP_ROOT/.agents/skills" "$TMP_ROOT/bin"
cp -R "$SKILL_DIR" "$TMP_ROOT/.agents/skills/linear"
# Isolate CACHE_DIR resolution (git rev-parse --show-toplevel) to this
# throwaway root — without this, cache writes land in the real project's
# `.cache/linear`.
git -C "$TMP_ROOT" init -q -b main

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
create_rc=0
create_out="$(cd "$TMP_ROOT" && PATH="$TMP_ROOT/bin:$PATH" LINEAR_API_KEY_OVERRIDE=test-token LINEAR_TEAM=TestTeam CURL_PAYLOAD_LOG="$create_log" \
  bash "$LINEAR" issues create --title "New task" --team Claude --description-file "$desc_file" 2>&1)" || create_rc=$?
assert_eq "issues create --description-file exits zero" "$create_rc" 0

assert_jq "issues create --description-file reports the created issue" \
  "$create_out" '.success == true and .identifier == "PROJ-1"'
assert "the issueCreate payload carries the markdown description verbatim" \
  jq -s -e '
    any(.[];
      (.query | contains("issueCreate"))
      and (.variables.input.description | contains("## Plan"))
      and (.variables.input.description | contains("`foo_bar()`"))
      and (.variables.input.description | contains("\"quoted\""))
      and (.variables.input.description | contains("- item one")))
  ' "$create_log"

# --- update with --description-file --------------------------------------------
update_log="$TMP_ROOT/update-payloads.jsonl"
: >"$update_log"
update_rc=0
update_out="$(cd "$TMP_ROOT" && PATH="$TMP_ROOT/bin:$PATH" LINEAR_API_KEY_OVERRIDE=test-token LINEAR_TEAM=TestTeam CURL_PAYLOAD_LOG="$update_log" \
  bash "$LINEAR" issues update PROJ-1 --description-file "$desc_file" 2>&1)" || update_rc=$?
assert_eq "issues update --description-file exits zero" "$update_rc" 0

assert_jq "issues update --description-file reports success" "$update_out" '.success == true'
assert "the issueUpdate payload carries the markdown description verbatim" \
  jq -s -e '
    any(.[];
      (.query | contains("issueUpdate"))
      and (.variables.input.description | contains("## Plan"))
      and (.variables.input.description | contains("`foo_bar()`"))
      and (.variables.input.description | contains("\"quoted\"")))
  ' "$update_log"

# --- helper: a command must fail with an expected stderr substring --------------
assert_fails() {
  local label="$1" expected="$2"
  shift 2
  local err_file="$TMP_ROOT/err.txt" rc=0
  (cd "$TMP_ROOT" && PATH="$TMP_ROOT/bin:$PATH" LINEAR_API_KEY_OVERRIDE=test-token LINEAR_TEAM=TestTeam \
    bash "$LINEAR" "$@") >"$TMP_ROOT/out.txt" 2>"$err_file" || rc=$?

  assert_ne "$label: exits nonzero" "$rc" 0
  assert_file_contains "$label" "$err_file" "$expected"
}

# --- mutual exclusivity (create + update) --------------------------------------
assert_fails "create refuses --description with --description-file" "mutually exclusive" \
  issues create --title "New task" --team Claude --description inline --description-file "$desc_file"
assert_fails "update refuses --description with --description-file" "mutually exclusive" \
  issues update PROJ-1 --description inline --description-file "$desc_file"

# --- unreadable / missing path errors (create + update) ------------------------
assert_fails "create refuses an unreadable --description-file" "not readable" \
  issues create --title "New task" --team Claude --description-file "$TMP_ROOT/does-not-exist.md"
assert_fails "update refuses an unreadable --description-file" "not readable" \
  issues update PROJ-1 --description-file "$TMP_ROOT/does-not-exist.md"
