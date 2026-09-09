# shellcheck shell=bash
# Literal binding syntax is exercised through the same table for forced and
# configured reviewers. These rows cover opt-out, authorship and a changed floor.
comment_battery "mech-bot[bot]" "Analysis (clean) for commit:" 7
while IFS='|' read -r name reviewers author floor length want; do
  reset
  CFG_REVIEWERS="$reviewers"
  [ "$floor" = ACTIVE ] || CFG_FLOOR="$floor"
  comment "$author" "Reviewed commit: \`$(printf '%.*s' "$length" "$HEAD")\`" >"$fixtures/comments.json"
  run "$name" "$want"
done <<EOF
comment source disabled||some-bot[bot]|ACTIVE|7|awaiting
different comment author|mech-bot[bot]:Reviewed commit:|other-bot[bot]|ACTIVE|7|awaiting
configured author cannot self-approve|$AUTHOR:Reviewed commit:|$AUTHOR|ACTIVE|7|awaiting
below configured floor|mech-bot[bot]:Reviewed commit:|mech-bot[bot]|10|7|awaiting
at configured floor|mech-bot[bot]:Reviewed commit:|mech-bot[bot]|10|10|approved
EOF
