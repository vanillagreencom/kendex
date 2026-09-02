# shellcheck shell=bash
# Reading a harness usage-limit banner's reset clause. What shape a reset
# clause comes in, and what instant it names given the moment the banner was
# seen. Pure string-to-string: nothing here reads a pane, a tmux window, an
# event or the watch state, and `die` is its only import from the script that
# sources it.
#
# Sourced, never run. lib/date-ladder.sh must be sourced first. Beyond it the
# file imports one name, `die`, and takes the banner lines to read as an
# argument rather than reaching for the predicate that found them.

# The reset clause the same banner line states. Three tails, tried in this
# order. Every arm states its evidence at one of three GRADES, and an arm that
# can state none does not exist: MEASURED in a shipped binary, RECORDED in this
# repository as the CLI's own copy, or ACCEPTED on the grammar of the sibling
# parser this repository already has for the question,
# pi-extensions/pi-agents-tmux/extensions/subagent/rate-limit-reset.ts. Naming
# a source is not a grade; a hand-written assertion string and a captured pane
# are not the same evidence.
#   dated    `resets Sep 6, 4pm`, `resets Oct 7, 2027, 11:32am` — MEASURED in
#            Claude Code 2.1.258, whose `Td()` formats through `Intl` in en-US
#            past 24 hours out, lowercases the meridiem and drops the space
#            before it, and prints the year only when it is not the current
#            one. Codex 0.152.1 draws the same tail with an ordinal day and no
#            comma before the clock (`Try again at Sep 6th, 2026 4:30 PM`):
#            MEASURED as ` Try again at `, `%b %-d`, the `stndrdth` ordinal
#            table and `, %Y %-I:%M %p` at adjacent offsets in its binary.
#            Both are covered, and both triggers come from these two readings.
#   weekday  `resets Thursday 4am` — RECORDED, at
#            pi-extensions/pi-claude-bridge/tests/unit-usage-limit.mjs, as the
#            CLI's official limit copy, and reaching a pane through a result
#            payload's `errors` array rather than as a banner the TUI draws.
#            NOT measured: 2.1.258 cannot print it, since every reset clause
#            routes through `Td()` and neither of its option objects carries a
#            `weekday` key.
#   clock    `resets 9:50am (America/Los_Angeles)` — MEASURED, same formatter
#            inside 24 hours, with the IANA zone in parentheses when the banner
#            asks for one. The meridiem is optional so `resets 21:00` reads
#            too, and that is ACCEPTED only: `Td()` prints a clock only with
#            `hour12` set, on both its branches, and omits the clock entirely
#            otherwise, while the `timeFormat` setting reaches the
#            message-timestamp and UI-clock formatters and never `Td()`.
# A clock inside a fall-back hour names two instants in its zone. A dayless
# tail resolves them by the same rule as any other candidate, the first after
# the sighting; a dated tail, having no sighting to order them against, takes
# the later.
# Deliberately outside: a duration (Claude's `resets in 5m` for a fast-mode
# cooldown), a weekday with no clock, and a bare number carrying neither
# minutes nor a meridiem. Each leaves the event without a time rather than
# with a guessed one.
USAGE_RESET_LEAD='([Rr]esets|[Tt]ry again at)[[:space:]]+'
USAGE_RESET_CLOCK='([0-9]{1,2})(:([0-9]{2}))?(:[0-9]{2})?[[:space:]]?([AaPp][Mm])?'
USAGE_RESET_DATED_RE="${USAGE_RESET_LEAD}([A-Z][a-z][a-z])[a-z]*[[:space:]]+([0-9]{1,2})[a-z]*,[[:space:]]+(([0-9]{4}),?[[:space:]]+)?${USAGE_RESET_CLOCK}"
USAGE_RESET_WEEKDAY_RE="${USAGE_RESET_LEAD}([A-Z][a-z]+day)[[:space:]]+${USAGE_RESET_CLOCK}"
USAGE_RESET_CLOCK_RE="${USAGE_RESET_LEAD}${USAGE_RESET_CLOCK}"
USAGE_RESET_ANY_RE="${USAGE_RESET_DATED_RE}|${USAGE_RESET_WEEKDAY_RE}|${USAGE_RESET_CLOCK_RE}"
# The zone the banner names, an IANA name of one or more components: the
# helper behind the banner is Intl.DateTimeFormat().resolvedOptions().timeZone,
# which returns `UTC` for a process whose TZ is UTC, so demanding a slash reads
# a correct zone as none at all. Trusted only once the host resolves it: TZ
# falls back to UTC for a name it does not know, silently and with a zero
# status, so an unchecked one turns a standing wall into a lifted one on a
# whole offset.
USAGE_RESET_ZONE_RE='\(([A-Za-z]+(/[A-Za-z0-9_+-]+)*)\)'
ZONEINFO_DIR="${TZDIR:-/usr/share/zoneinfo}"
# Month and weekday names are matched here rather than through `date`, whose
# `%b`/`%a` follow LC_TIME while its parser reads English only: a host with a
# non-English LC_TIME would round-trip every label into nothing. Every format
# this file hands `date` is numeric for the same reason.
USAGE_RESET_MONTHS='Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec'
USAGE_RESET_WEEKDAYS='Monday Tuesday Wednesday Thursday Friday Saturday Sunday'

# One-based index of WORD in LIST, empty when it is absent.
word_index() {
  awk -v want="$2" '{ for (i = 1; i <= NF; i++) if ($i == want) { print i; exit } }' <<<"$1"
}

# The wall the banner LINES name, as a key: the tail that matched, the clock,
# the date or weekday it carries, and the zone. Empty when no line states a
# reset in a shape the grammar reads, or when it names a zone this host cannot
# resolve. Nothing here reads a clock, so a pass can compare the key it sees
# now against the one it stored without the answer moving under it.
usage_reset_key() {
  local line rc=0 hour min meridiem mon day year weekday zone
  line="$(grep -Em1 -- "$USAGE_RESET_ANY_RE" <<<"$1")" || rc=$?
  [[ "$rc" -le 1 ]] \
    || die "could not search a limit banner for its reset clause (grep exited $rc)"
  [[ -n "$line" ]] || return 0
  mon=""; day=""; year=""; weekday=""
  # Longest tail first: a dated clause also matches the bare-clock tail from
  # its own clock onwards, and a weekday one would lose its day.
  if [[ "$line" =~ $USAGE_RESET_DATED_RE ]]; then
    mon="${BASH_REMATCH[2]}"; day="${BASH_REMATCH[3]}"; year="${BASH_REMATCH[5]}"
    hour="${BASH_REMATCH[6]}"; min="${BASH_REMATCH[8]}"; meridiem="${BASH_REMATCH[10]}"
  elif [[ "$line" =~ $USAGE_RESET_WEEKDAY_RE ]]; then
    weekday="${BASH_REMATCH[2]}"
    hour="${BASH_REMATCH[3]}"; min="${BASH_REMATCH[5]}"; meridiem="${BASH_REMATCH[7]}"
  elif [[ "$line" =~ $USAGE_RESET_CLOCK_RE ]]; then
    hour="${BASH_REMATCH[2]}"; min="${BASH_REMATCH[4]}"; meridiem="${BASH_REMATCH[6]}"
  else
    return 0
  fi
  # A run of digits carrying neither minutes nor a meridiem is a number that
  # follows the word, not a clock: `resets 2026-09-03` would otherwise put the
  # `20` of the year on the event as an hour. Every shape above carries one or
  # the other, so nothing attested is lost.
  [[ -n "$min" || -n "$meridiem" ]] || return 0
  # 12-hour to 24-hour; a clock with no meridiem is already a 24-hour one, as
  # it is for the sibling parser. Nothing range-checks the result: every clock
  # is handed to `date` on resolution, which rejects an impossible one, and a
  # rejected candidate leaves the event without a time — the same answer a
  # range check would give, from the one implementation that has to agree with
  # itself.
  hour=$((10#$hour)); min=$((10#${min:-0}))
  case "$meridiem" in
    [Pp]*) [[ "$hour" -eq 12 ]] || hour=$((hour + 12)) ;;
    [Aa]*) [[ "$hour" -ne 12 ]] || hour=0 ;;
  esac
  # Read AFTER every field above: the match overwrites BASH_REMATCH. A zone the
  # host cannot resolve leaves no key at all, so no wall is stamped and no time
  # is computed in the UTC that TZ would silently fall back to.
  zone=""
  if [[ "$line" =~ $USAGE_RESET_ZONE_RE ]]; then
    zone="${BASH_REMATCH[1]}"
    [[ -r "$ZONEINFO_DIR/$zone" ]] || return 0
  fi
  # One field layout for every tail — kind, month, day, year, clock, zone —
  # so one `read` splits any key and an unused column is simply empty.
  if [[ -n "$mon" ]]; then
    mon="$(word_index "$USAGE_RESET_MONTHS" "$mon")"
    [[ -n "$mon" ]] || return 0
    printf 'dated|%s|%s|%s|%02d:%02d|%s\n' "$mon" "$((10#$day))" "$year" "$hour" "$min" "$zone"
  elif [[ -n "$weekday" ]]; then
    weekday="$(word_index "$USAGE_RESET_WEEKDAYS" "$weekday")"
    [[ -n "$weekday" ]] || return 0
    printf 'dow|%s|||%02d:%02d|%s\n' "$weekday" "$hour" "$min" "$zone"
  else
    printf 'clock||||%02d:%02d|%s\n' "$hour" "$min" "$zone"
  fi
}

# The UTC instants a wall clock names on one day in ZONE, ascending. Normally
# one. In a fall-back hour a local clock names TWO, and `date` resolves the
# string to a single fold — the earlier, on GNU — so the second is reachable
# only by asking whether an hour later reads back as the same wall clock. In a
# spring-forward gap the clock names none and `date` shifts it forward; that
# answer is kept, since a banner cannot name a time its own harness could not
# have drawn.
local_instants() {
  local zone="$1" day="$2" stamp="$3" first second
  first="$(to_epoch "$day $stamp" '%Y-%m-%d %H:%M' "$zone")" || return 0
  printf '%s\n' "$first"
  second=$((first + 3600))
  [[ "$(from_epoch "$second" '%Y-%m-%d %H:%M' "$zone")" == "$day $stamp" ]] || return 0
  printf '%s\n' "$second"
}

# KEY resolved to an epoch, empty when `date` rejects the clock it carries.
#
# A dated clause names its own day and resolves outright; SINCE supplies only
# the year a banner omits, which it omits only when that year is the current
# one. Every other clause names a time of day and no day, and is pinned to its
# first occurrence STRICTLY AFTER SINCE — the pass on which this watch first
# saw the banner. The day is then OBSERVED rather than inferred, which is what
# makes a reset behind us a fact rather than the likelier of two readings: a
# banner first seen at 16:00 saying `resets 21:00` is tonight's, and the same
# banner still there tomorrow is still tonight's, spent.
#
# Days are enumerated calendrically off local NOON, never by adding 86400 to an
# epoch: a DST shift moves local midnight, so a day added that way can skip the
# next calendar day altogether or repeat the current one.
usage_reset_epoch() {
  local key="$1" since="$2" kind mon day year stamp zone dow anchor cand d last
  local best best_abs abs years
  IFS='|' read -r kind mon day year stamp zone <<<"$key"
  # A dated clause carries no sighting to order a fall-back hour's two
  # instants against, so it takes the LATER: reporting a wall spent an hour
  # early nudges a lane whose account is still walled, while reporting it an
  # hour late only parks one that is already parked.
  if [[ "$kind" == dated ]]; then
    # The year the banner printed, or the three around the sighting when it
    # printed none: a banner omits its year only when that year is the current
    # one WHERE IT WAS DRAWN, which is not the year of the sighting once a New
    # Year has been crossed, and `resets Jan 2` seen on Dec 28 is next year's.
    # Candidates a year apart make the one nearest the sighting the only
    # reading, unambiguous in a way a bare clock's never was; with the year
    # printed there is one candidate and the choice is a no-op. Written once so
    # the fold rule below cannot hold on one path and not the other.
    if [[ -n "$year" ]]; then
      years="$year"
    else
      year="$(from_epoch "$since" '%Y' "$zone")" || return 0
      years="$((year - 1)) $year $((year + 1))"
    fi
    best=""
    best_abs=0
    for d in $years; do
      cand="$(local_instants "$zone" \
        "$(printf '%s-%02d-%02d' "$d" "$mon" "$day")" "$stamp" | tail -1)"
      [[ -n "$cand" ]] || continue
      abs=$((cand - since))
      [[ "$abs" -ge 0 ]] || abs=$(( -abs ))
      if [[ -z "$best" || "$abs" -lt "$best_abs" ]]; then best="$cand"; best_abs="$abs"; fi
    done
    [[ -z "$best" ]] || printf '%s\n' "$best"
    return 0
  fi
  # A weekday clause may sit a whole week out; a bare clock is today or
  # tomorrow, measured from the pass that first saw it.
  dow=""
  last=1
  if [[ "$kind" == dow ]]; then
    dow="$mon"
    last=7
  fi
  anchor="$(to_epoch "$(from_epoch "$since" '%Y-%m-%d' "$zone") 12:00" '%Y-%m-%d %H:%M' "$zone")" \
    || return 0
  for ((d = 0; d <= last; d++)); do
    if [[ -n "$dow" && "$(from_epoch "$((anchor + d * 86400))" '%u' "$zone")" != "$dow" ]]; then
      continue
    fi
    # The policy is the first occurrence strictly after the sighting, and in a
    # fall-back hour that has to be decided over BOTH instants the clock names:
    # taking whichever fold `date` returned would skip a whole day when the
    # sighting falls between them, and always taking the later one would park a
    # first-fold sighting an hour past its wall.
    while IFS= read -r cand; do
      [[ "$cand" -gt "$since" ]] || continue
      printf '%s\n' "$cand"
      return 0
    done < <(local_instants "$zone" "$(from_epoch "$((anchor + d * 86400))" '%Y-%m-%d' "$zone")" "$stamp")
  done
}
