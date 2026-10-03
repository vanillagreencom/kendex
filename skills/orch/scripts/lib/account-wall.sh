# shellcheck shell=bash
#
# The weekly wall a harness banner stated for an account, kept until the reset
# the banner names. `lanes` judges an account on its usage reading, and a Claude
# account has read room in `lanes list` and `lanes pick` while its harness
# showed a weekly-limit banner on the first turn. This record is the fallback
# for a wall the usage endpoint does not report: while it stands, the account's
# weekly window reads 100 whatever the endpoint said, and once its reset has
# passed the account reads its measured value again.
#
# oversee-watch writes it on every pass that finds a claimed lane walled, the
# pass that raises `usage-limit` and each later one, so a wall reported before
# the record existed, or whose write failed, is recorded on the next pass. Only
# the harness's own report is recorded: the banner Claude Code draws in a pane
# (ACCOUNT_WALL_DRAWN), or the error a Pi lane's turn ended on, which its
# session row carries. `lanes` reads it in emit_lane, so `list` and both `pick`
# forms judge one record. It lives in `walls/` beside the claim store
# lane_claims_dir names, one file per account named by a checksum of the
# config dir in lane_claims_canon's spelling, holding `{config_dir, resets_at}`
# with the reset in epoch seconds.
#
# Sourced, never run. lib/lane-claims.sh must be sourced first.

account_wall_dir() { # ROOT
  local claims
  claims="$(lane_claims_dir "$1")" || return 1
  printf '%s/walls\n' "${claims%/*}"
}

# The record for CONFIG_DIR: its path in ACCOUNT_WALL_FILE and in
# ACCOUNT_WALL_CANON the spelling the record names the account by. Globals,
# so the caller runs this in its own shell.
ACCOUNT_WALL_FILE="" ACCOUNT_WALL_CANON=""
account_wall_file() { # ROOT CONFIG_DIR
  local dir sum
  dir="$(account_wall_dir "$1")" || return 1
  ACCOUNT_WALL_CANON="$(lane_claims_canon "$2")" || return 1
  sum="$(printf '%s' "$ACCOUNT_WALL_CANON" | cksum)" || return 1
  ACCOUNT_WALL_FILE="$dir/${sum%% *}.json"
}

# What opens the line Claude Code draws a usage-limit message on: its
# MessageResponse prefix, two spaces, `⎿`, a space and U+00A0, measured in
# Claude Code 2.1.288, which renders its rate-limit message inside that
# component. The lane's own words never open a line with it: its prose starts
# `⏺ ` or an indent, and the first line of a tool result takes `  ⎿  ` with two
# plain spaces. So a banner the lane quotes, the case oversee-events.md §
# usage-limit has the overseer confirm, records no wall.
ACCOUNT_WALL_DRAWN=$'  \xe2\x8e\xbf \xc2\xa0'

# Records the wall BANNER states for CONFIG_DIR until RESET, an epoch, where a
# line of the banner is the harness's own weekly-limit message and RESET is
# after NOW. CHANNEL says where BANNER was read: empty for a pane, where only a
# line opening with ACCOUNT_WALL_DRAWN is the harness's own, or `row` for a Pi
# lane's session row, whose error message is the harness's own report and
# never drawn, so the weekly phrase anywhere in it is the wall. Nothing else
# is written: a lane with no claim names no account, a quoted banner is no wall
# of that account, a banner whose reset the grammar could not read names no
# time to keep the wall until, and a reset already behind NOW is a wall that
# has lifted. Returns 1, after a keyed line on stderr, when the record could
# not be written or CHANNEL is neither.
account_wall_record() { # ROOT CONFIG_DIR RESET NOW BANNER [CHANNEL]
  local file="" line own=""
  [[ -z "${6:-}" || "$6" == row ]] || {
    printf 'account-wall: channel-invalid value=%s\n' "$6" >&2
    return 1
  }
  [[ -n "$2" && "$3" =~ ^[0-9]+$ && "$3" -gt "$4" ]] || return 0
  while IFS= read -r line; do
    if [[ -n "${6:-}" ]]; then
      [[ "$line" != *You*"ve hit your weekly limit"* ]] || own=1
    else
      [[ "$line" != "$ACCOUNT_WALL_DRAWN"You*"ve hit your weekly limit"* ]] || own=1
    fi
  done <<<"$5"
  [[ -n "$own" ]] || return 0
  # Renamed into place only once complete, so `lanes` never reads half a record.
  if account_wall_file "$1" "$2" && file="$ACCOUNT_WALL_FILE" && mkdir -p -- "${file%/*}" \
    && jq -nc --arg d "$ACCOUNT_WALL_CANON" --argjson r "$3" \
      '{config_dir: $d, resets_at: $r}' >"$file.$$.tmp" \
    && mv -f -- "$file.$$.tmp" "$file"; then
    return 0
  fi
  [[ -z "$file" ]] || rm -f -- "${file:?}.$$.tmp"
  printf 'account-wall: record-unwritten config_dir=%s\n' "$2" >&2
  printf '%s\n' "account-wall: the weekly wall this banner states could not be recorded; the next pass tries again, and until then lanes reads this account on its usage reading alone" >&2
  return 1
}

# BUCKETS, a parsed usage reading for CONFIG_DIR, with its weekly window at 100
# and resetting at the recorded reset while that reset is ahead of the clock.
# With no record, a record naming another account (a checksum collision), or
# a reset already passed, the reading comes back unchanged. A record jq cannot
# read fails, after a keyed line on stderr: a wall nobody can read is no
# evidence the account has room.
account_wall_buckets() { # ROOT CONFIG_DIR BUCKETS
  local dir file
  dir="$(account_wall_dir "$1")" || return 1
  [[ -d "$dir" ]] || { printf '%s\n' "$3"; return 0; }
  account_wall_file "$1" "$2" || return 1
  file="$ACCOUNT_WALL_FILE"
  [[ -e "$file" ]] || { printf '%s\n' "$3"; return 0; }
  if jq -c --slurpfile w "$file" --arg d "$ACCOUNT_WALL_CANON" '
    $w[0] as $wall
    | if $wall.config_dir != $d or $wall.resets_at <= now then .
      else . + {weekly_pct: 100,
                resets: ((.resets // {}) + {weekly: ($wall.resets_at | floor | todate)})}
      end' <<<"$3" 2>/dev/null; then
    return 0
  fi
  printf 'account-wall: record-unreadable path=%s\n' "$file" >&2
  printf '%s\n' "account-wall: the wall record for this account could not be read, so the account reads unmeasured" >&2
  return 1
}
