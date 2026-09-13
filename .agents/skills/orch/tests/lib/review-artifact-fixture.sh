git -C "$TMP_ROOT" init -q
git -C "$TMP_ROOT" -c user.name=Test -c user.email=test@example.com -c core.hooksPath=/dev/null commit -q --allow-empty -m fixture
REVIEW_FIXTURE_HEAD="$(git -C "$TMP_ROOT" rev-parse HEAD)" || return 1
review_fixture_stamp() {
  local file="$1" json
  if ! jq empty "$file" 2>/dev/null; then return 0; fi
  json="$(jq --arg head "$REVIEW_FIXTURE_HEAD" '. + {head:$head,dirty_paths:[]}' "$file")" || return 1
  printf '%s\n' "$json" > "$file"
}
