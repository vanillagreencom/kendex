# shellcheck shell=bash
# `date` in an explicit zone, in both directions, over the two implementations
# a repository checkout runs on. GNU and BSD spell every conversion here
# differently, and the fallback is the whole point of the file.
#
# Sourced, never run. It has a caller outside the reset parser — the `--since`
# floor `oversee-watch` parses — so it is a peer of usage-reset.sh rather than
# a part of it: a date shim named for one feature would be a lie to the other
# caller, and having usage-reset.sh reach back into oversee-watch for three
# names would be the seam this repository's size ratchet calls a failed one.

# `date` under an explicit zone. An empty ZONE leaves TZ alone, which is the
# runner's own zone — the zone a harness banner naming none was drawn in, since
# it was drawn on this host.
tz_date() {
  local zone="$1"
  shift
  if [[ -n "$zone" ]]; then TZ="$zone" date "$@"; else date "$@"; fi
}

# A timestamp → epoch, GNU date first, then BSD/macOS. FMT is the BSD arm's
# input format, which GNU does not need, and ZONE the zone the stamp is written
# in. Both default to the ISO8601 UTC form, which is what every caller but the
# reset-banner parser hands it; UTC is load-bearing there, so a `--since` floor
# is not shifted by the runner's local zone.
to_epoch() {
  local stamp="$1" fmt="${2:-%Y-%m-%dT%H:%M:%SZ}" zone="${3-UTC}"
  tz_date "$zone" -d "$stamp" +%s 2>/dev/null \
    || tz_date "$zone" -j -f "$fmt" "$stamp" +%s 2>/dev/null
}

# The other direction on the same ladder: GNU spells an epoch input `-d @`,
# BSD `-r`.
from_epoch() {
  local epoch="$1" fmt="$2" zone="${3-UTC}"
  tz_date "$zone" -d "@$epoch" +"$fmt" 2>/dev/null \
    || tz_date "$zone" -r "$epoch" +"$fmt" 2>/dev/null
}
