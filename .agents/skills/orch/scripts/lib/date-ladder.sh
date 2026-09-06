# shellcheck shell=bash
# `date` in an explicit zone, in both directions, over the two implementations
# a repository checkout runs on. GNU and BSD spell every conversion here
# differently, and the fallback is the whole point of the file.
#
# Shared by the reset parser and oversee-watch's --since filter.

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
  local bsd_stamp="$stamp" bsd_fmt="$fmt"
  # BSD `date -j -f` takes every field its format does not name from the
  # CURRENT time, so a format without %S resolves to this minute's seconds
  # instead of to :00 — a clock read seconds late, and a different answer on
  # every run. GNU `date -d` zeroes them. The seconds are named outright for
  # the BSD arm rather than left to the clock.
  case "$bsd_fmt" in
    *%S*) ;;
    *)
      bsd_stamp="$bsd_stamp:00"
      bsd_fmt="$bsd_fmt:%S"
      ;;
  esac
  tz_date "$zone" -d "$stamp" +%s 2>/dev/null \
    || tz_date "$zone" -j -f "$bsd_fmt" "$bsd_stamp" +%s 2>/dev/null
}

# The other direction on the same ladder: GNU spells an epoch input `-d @`,
# BSD `-r`.
from_epoch() {
  local epoch="$1" fmt="$2" zone="${3-UTC}"
  tz_date "$zone" -d "@$epoch" +"$fmt" 2>/dev/null \
    || tz_date "$zone" -r "$epoch" +"$fmt" 2>/dev/null
}
