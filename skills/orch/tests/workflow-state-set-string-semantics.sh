#!/usr/bin/env bash
# `workflow-state set` stores a value that is not JSON as the raw string: it
# never parses a JSON string literal, so a pre-quoted value keeps its quote
# characters. Pinned here: a `{`/`[` prefix, exactly null/true/false, or an
# all-digit value splices as JSON; every other value — including one that
# starts with a double quote — is stored verbatim via `jq --arg`. `append`
# shares the `{`/`[` hybrid; `update` is always a jq expression.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

WS="$REPO_ROOT/skills/orch/scripts/workflow-state"

# shellcheck source=lib/assertions.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/assertions.sh"

echo "=== workflow-state set raw-string semantics ==="

# --- Part 1: set / update / append value semantics -------------------------

sd="$TMP_ROOT/state"
"$WS" --state-dir "$sd" init issue-705 \
  --worktree "$REPO_ROOT" --branch issue-705 >/dev/null
sf="$sd/workflow-state-issue-705.json"

# Test 1: a bare string stores a clean JSON string.
"$WS" --state-dir "$sd" set issue-705 pr_review.mode review
assert_eq "$(jq -c '.pr_review.mode' "$sf")" '"review"' \
  "bare-string set stores a clean JSON string"

# Test 2 (pinned raw semantics): a pre-quoted value stores the quote
# characters literally — set never parses JSON string literals.
"$WS" --state-dir "$sd" set issue-705 pr_review.mode '"review"'
assert_eq "$(jq -c '.pr_review.mode' "$sf")" '"\"review\""' \
  "pre-quoted set stores literal quote characters (raw-string semantics)"

# Test 3: JSON-looking values splice as JSON; `off` is none of them.
"$WS" --state-dir "$sd" set issue-705 pr_review_baseline '{"last_threads":["PRRT_t"]}'
assert_eq "$(jq -r '.pr_review_baseline | type' "$sf")" "object" \
  "set splices a {…} value as a JSON object"
"$WS" --state-dir "$sd" set issue-705 review_agents '["a"]'
assert_eq "$(jq -c '.review_agents' "$sf")" '["a"]' \
  "set splices a […] value as a JSON array"
"$WS" --state-dir "$sd" set issue-705 skip_qa true
assert_eq "$(jq -c '.skip_qa' "$sf")" "true" \
  "set splices true as a JSON boolean"
"$WS" --state-dir "$sd" set issue-705 pre_delegate_sha null
assert_eq "$(jq -r '.pre_delegate_sha | type' "$sf")" "null" \
  "set splices null as JSON null"
"$WS" --state-dir "$sd" set issue-705 cycles 7
assert_eq "$(jq -c '.cycles' "$sf")" "7" \
  "set splices an all-digit value as a JSON number"
"$WS" --state-dir "$sd" set issue-705 pr_review.mode off
assert_eq "$(jq -c '.pr_review.mode' "$sf")" '"off"' \
  "set stores off as the clean string it looks like"

# Test 4: update is a jq expression — string literals need their JSON quotes.
"$WS" --state-dir "$sd" update issue-705 '.pr_review.mode = "off"'
assert_eq "$(jq -c '.pr_review.mode' "$sf")" '"off"' \
  "update applies jq-expression (JSON) semantics"

# Test 5: append shares the hybrid — bare strings verbatim, {/[ as JSON.
"$WS" --state-dir "$sd" append issue-705 json_paths plain.json
"$WS" --state-dir "$sd" append issue-705 json_paths '"quoted.json"'
"$WS" --state-dir "$sd" append issue-705 fixed_items '{"description":"x"}'
assert_eq "$(jq -c '.json_paths' "$sf")" '["plain.json","\"quoted.json\""]' \
  "append stores bare strings clean and pre-quoted strings verbatim"
assert_eq "$(jq -r '.fixed_items[0] | type' "$sf")" "object" \
  "append splices a {…} value as a JSON object"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
