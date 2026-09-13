#!/usr/bin/env bash
# A neutral committed repository for review artifact fixtures.
review_fixture_init() {
  git -C "$1" init -q
  git -C "$1" -c user.name=Test -c user.email=test@example.com -c core.hooksPath=/dev/null commit -q --allow-empty -m fixture
  REVIEW_FIXTURE_HEAD="$(git -C "$1" rev-parse HEAD)" || return 1
}

# Supply the starting snapshot without changing malformed JSON fixtures.
review_fixture_stamp() {
  local file="$1" json
  if ! jq empty "$file" 2>/dev/null; then return 0; fi
  json="$(jq --arg head "$REVIEW_FIXTURE_HEAD" '. + {head:$head,dirty_paths:[]}' "$file")" || return 1
  printf '%s\n' "$json" > "$file"
}
