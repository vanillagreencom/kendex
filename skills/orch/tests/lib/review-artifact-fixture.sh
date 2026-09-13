for repo in "$TMP_ROOT" "$TMP_ROOT/storage"; do mkdir -p "$repo" && git -C "$repo" init -q && git -C "$repo" -c user.name=Test -c user.email=test@example.com -c core.hooksPath=/dev/null commit -q --allow-empty -m "$repo" || return 1; done
REVIEW_FIXTURE_HEAD="$(git -C "$TMP_ROOT" rev-parse HEAD)" || return 1
review_fixture_stamp() { jq --arg head "$REVIEW_FIXTURE_HEAD" '. + {head:$head,dirty_paths:[]}' "$1" > "$1.stamp" && mv -- "$1.stamp" "$1"; }
