for repo in "$TMP_ROOT" "$TMP_ROOT/storage"; do mkdir -p "$repo" && git -C "$repo" init -q && git -C "$repo" -c user.name=Test -c user.email=test@example.com -c core.hooksPath=/dev/null commit -q --allow-empty -m "$repo" || return 1; done
REVIEW_FIXTURE_HEAD="$(git -C "$TMP_ROOT" rev-parse HEAD)" || return 1
review_fixture_stamp() { jq --arg head "$REVIEW_FIXTURE_HEAD" '. + {head:$head,dirty_paths:[]}' "$1" > "$1.stamp" && mv -- "$1.stamp" "$1"; }

# touch_epoch EPOCH PATH — set PATH's mtime to EPOCH seconds.
#
# `touch -d @EPOCH` is GNU; BSD touch reads -d as an ISO-8601 stamp and
# refuses the @ form ("out of range or illegal time specification"). Both take
# a zoned ISO stamp through -d, so the epoch is rendered to one, in UTC, and
# the trailing Z is what keeps the mtime exact on either — `-t` would be read
# in the machine's local zone and shift the mtime by its UTC offset. GNU date
# prints the stamp from `-d @EPOCH`, BSD date from `-r EPOCH`; the same two-arm
# ladder as scripts/lib/date-ladder.sh, which these suites do not source.
touch_epoch() {
  local epoch="$1" path="$2" stamp
  stamp="$(date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -r "$epoch" +%Y-%m-%dT%H:%M:%SZ)" || return 1
  touch -d "$stamp" "$path"
}
