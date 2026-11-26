#!/usr/bin/env bash
# bash-runtime: 4
# Tests for comments react: the comment and emoji reach Linear's reactionCreate,
# and only an answer Linear confirms exits zero.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
assert_tmpdir TMP_ROOT

mkdir -p "$TMP_ROOT/.agents/skills" "$TMP_ROOT/bin"
cp -R "$SKILL_DIR" "$TMP_ROOT/.agents/skills/linear"

# Answers in the shape of Linear's schema: Mutation.reactionCreate returns a
# ReactionPayload {success, reaction {id, emoji}}, and a refused mutation an
# errors list.
cat >"$TMP_ROOT/bin/curl" <<'SH'
#!/usr/bin/env bash
config="$(cat)"
printf '%s\n' "$config" > "${CURL_CONFIG_CAPTURE:?}"
cat -- "${CURL_ANSWER:?}"
printf '___HTTP_CODE___200'
SH
chmod +x "$TMP_ROOT/bin/curl"

export CURL_CONFIG_CAPTURE="$TMP_ROOT/curl-config.txt" CURL_ANSWER="$TMP_ROOT/answer.json"
comment=00000000-0000-4000-8000-000000000001
while IFS='|' read -r name answer want_rc; do
  [[ -n "$name" ]] || continue
  printf '%s' "$answer" >"$CURL_ANSWER"
  rm -f -- "${CURL_CONFIG_CAPTURE:?}"
  rc=0
  out="$(PATH="$TMP_ROOT/bin:$PATH" LINEAR_API_KEY_OVERRIDE=test-token LINEAR_RETRY_BASE_DELAY=0 \
    bash "$TMP_ROOT/.agents/skills/linear/scripts/linear.sh" comments react "$comment" --emoji eyes 2>"$TMP_ROOT/err")" || rc=$?
  assert_eq "comments react $name exit" "$rc" "$want_rc"
  payload="$(sed -n 's/^data = //p' "$CURL_CONFIG_CAPTURE" | jq -r)"
  assert_jq "comments react $name sends the comment and emoji to reactionCreate" "$payload" \
    "(.query | test(\"reactionCreate\\\\(input: \\\\\$input\\\\)\")) and .variables.input == {commentId: \"$comment\", emoji: \"eyes\"}"
  if [[ "$want_rc" -eq 0 ]]; then
    assert_jq "comments react $name prints Linear's reaction" "$out" '.success == true and .data.reaction.emoji == "eyes"'
  fi
done <<ROWS
created|{"data":{"reactionCreate":{"success":true,"reaction":{"id":"00000000-0000-4000-8000-000000000002","emoji":"eyes"}}}}|0
unsuccessful|{"data":{"reactionCreate":{"success":false,"reaction":{"id":"00000000-0000-4000-8000-000000000002","emoji":"eyes"}}}}|1
refused|{"errors":[{"message":"Entity not found: Comment","extensions":{"type":"invalid input"}}]}|1
ROWS
