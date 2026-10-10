# shellcheck shell=bash
# The rules a mailbox obeys wherever the file sits: the lane's own disk through
# `lane-mail`, a provider's host through `lane-host append`, and the fixture
# that models a provider. One owner for each, because a drift in where a line
# ends glues two envelopes together or hands over half of one, and a drift in
# the lock loses a line whenever two writers meet.
#
# Sourced, never executed, after lib/file-lock.sh, whose orch_take_lock and
# orch_release_lock this uses; oversee-watch sources it for the envelope class
# alone, which takes no lock. Bash 3.2-safe, like its callers.

# Whether FILE ends on a complete line: 0 when its last byte is a newline and
# when it is empty, 1 when a writer left a fragment there, 2 when it could not
# be read. Both sides of a mailbox ask this, the writer before it appends and
# the reader before it hands lines over, and a one-sided answer is how the two
# come apart: the writer glues two envelopes together, or the reader emits a
# partial line or drops a whole one.
mailbox_line_complete() { # FILE
  local last
  [ -s "$1" ] || return 0
  # `&&`, not `;`: a substitution reports its last command, so `tail; printf x`
  # reports the printf, and a read that failed would answer as a fragment.
  # The `printf x` guard stays, because the substitution strips the very
  # newline this compares against.
  last="$(tail -c 1 -- "$1" && printf x)" || return 2
  [ "$last" != "$(printf '\nx')" ] || return 0
  return 1
}

# A writer killed inside its write leaves a line with no newline of its own.
# Closing it makes it a line the reader counts and does not parse, so the
# envelope that follows lands whole instead of being glued to it and both lost.
# The caller holds the lock on FILE; the append here is its own open, which the
# kernel places at the end exactly as the caller's descriptor would.
mailbox_terminate() { # FILE
  local complete=0
  mailbox_line_complete "$1" || complete=$?
  [ "$complete" -ne 0 ] || return 0
  [ "$complete" -eq 1 ] || return 1
  printf '\n' >>"$1" || return 1
}

# The `at` stamp as epoch seconds, null where it does not parse: the one
# parse every reader of a stamp shares, prefixed to its jq program.
MAILBOX_TIME_JQ='def at_epoch: try (strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) catch null;'

# The destination's most recent whole-envelope repeat within a minute. Both
# lane-mail and lane-host append call this under the destination's own lock.
# Deadline offsets stay equal on a retry even when its timestamp advances.
# The envelope crosses a file, not argv: a message can exceed one argument's
# kernel limit. Raw provider appends that are not envelopes remain raw bytes.
mailbox_duplicate_id() { # FILE ENVELOPE_FILE
  jq -r -R --rawfile sent "$2" "$MAILBOX_TIME_JQ"'
    def content:
      if has("deadline") then
        (.deadline | at_epoch) as $deadline | (.at | at_epoch) as $stamp
        | if $deadline != null and $stamp != null then
            .deadline = ($deadline - $stamp)
          else . end
      else . end | del(.id, .at);
    ($sent | fromjson? // empty | objects) as $candidate
    | ($candidate.at | at_epoch) as $now
    | ($candidate | content) as $want
    | (fromjson? // empty) | objects
    | select(content == $want)
    | (.at | at_epoch) as $at
    | select($now != null and $at != null and ($now - $at) >= 0 and ($now - $at) <= 60)
    | .id | strings' <"$1" |
    awk '{ last = $0 } END { if (NR > 0) print last }'
}

# Add stdin's bytes to FILE under a lock on FILE itself, which every writer of
# it on that disk opens. A lock anywhere else is one writer's own: two writers
# holding separate locks both read the file and the second write loses the
# first one's line. FILE is created when it is not there, under whatever umask
# the caller set, and an unterminated last line is closed first.
#
# GUARD, where given, is a function run as `GUARD FILE` under the lock after
# the terminator and before the append: a check-and-append that is one
# operation, so a line whose right to land depends on what the file already
# holds, a delivery id or an ask's one resolution, is judged against the file
# it joins and never against a copy another writer has moved on from. The
# guard returns 1 for an expected refusal, 2 for a read failure, and 3 for a
# write failure. Its diagnostics stay on stderr.
#
# ENVELOPE_FILE, where given, names the candidate bytes on stdin. The minute
# repeat check runs under this same lock and prints `duplicate id=FIRST` on
# stderr when it refuses. Delivery-id and resolution callers use GUARD alone.
#
# Exit 3 when the lock could not be taken within WAIT_SECONDS, 2 when a write
# failed, 4 when the guard refused, 5 when its read failed. These need different repairs, a writer
# holding the mailbox, a disk or permission failure, a line already there, so
# every caller turns the number into its own word before anyone reads it:
# lane-mail into lock-failed, write-failed and the guard's key, the provider
# and the fixture into lock-timeout and write-failed.
mailbox_append_locked() { # FILE WAIT_SECONDS [GUARD [ENVELOPE_FILE]]: bytes on stdin
  local duplicate="" guard_rc=0
  exec 9>>"$1" || return 2
  if ! orch_take_lock 9 "$1" "$2"; then
    exec 9>&-
    return 3
  fi
  if ! mailbox_terminate "$1"; then
    exec 9>&-
    orch_release_lock
    return 2
  fi
  if [ -n "${4:-}" ]; then
    if ! duplicate="$(mailbox_duplicate_id "$1" "$4")"; then
      exec 9>&-
      orch_release_lock
      return 2
    fi
    if [ -n "$duplicate" ]; then
      printf 'duplicate id=%s\n' "$duplicate" >&2
      exec 9>&-
      orch_release_lock
      return 4
    fi
  fi
  if [ -n "${3:-}" ]; then
    "$3" "$1" || guard_rc=$?
  fi
  if [ "$guard_rc" -ne 0 ]; then
    exec 9>&-
    orch_release_lock
    case "$guard_rc" in
      1) return 4 ;;
      3) return 2 ;;
      *) return 5 ;;
    esac
  fi
  if ! cat >&9; then
    exec 9>&-
    orch_release_lock
    return 2
  fi
  exec 9>&-
  orch_release_lock
}

# The class of an envelope in the overseer's own to-lane.jsonl, as a jq
# definition a caller puts ahead of its filter, so the writer that checks a
# reply's --ref and the watch that reports the line judge one rule: a
# `close` is a resolution or a legacy closing answer; `resolution` is an owner answer
# carrying `by`; a `peer` line names another repository's overseer in `from`;
# an `owner-note` names owner or no sender; and a `stray` is an owner answer
# missing the `by` field every owner-answer writer supplies.
# shellcheck disable=SC2034  # read by the scripts that source this.
# Compatibility floor: kendex 1.3 mailboxes; remove legacy reads no earlier
# than 1.5, after the release-standard minor-release warning period.
MAILBOX_CLASS_JQ='def mailbox_legacy_close:
  .kind == "answer" and (.by == "text" or .by == "default") and (has("closes") | not);
def overseer_mail_class:
  if .kind == "resolution" or mailbox_legacy_close then "close"
  elif .kind == "answer" and (.by | type) == "string" then "resolution"
  elif ((.from // "") | . != "" and . != "owner") then "peer"
  elif .kind == "answer" then "stray"
  else "owner-note" end;'

# The pre-1.3 resolve producer wrote an answer without a closes field.
mailbox_warn_legacy() { # FILE
  local ids id
  ids="$(jq -r -R "$MAILBOX_CLASS_JQ"' (fromjson? // empty) | objects
    | select(mailbox_legacy_close) | .id' <"$1")" || return 2
  [ -n "$ids" ] || return 0
  while IFS= read -r id; do
    printf 'lane-mail: legacy-close=%s\nLegacy closing answer retained; supported through kendex 1.4.\n' "$id" >&2
  done <<<"$ids"
}

# The mailbox owns the ask. Tracker writes are advisory: a failed write must
# leave that ask available on its existing chat route.

owner_tracker_settings() { # ORCH SCRIPT DIRECTORY
  OWNER_TRACKER_EMAIL="$("$1/orch-env" ORCH_OWNER_EMAIL "")" || return 1
  if [[ -z "$OWNER_TRACKER_EMAIL" ]]; then
    OWNER_TRACKER_EMAIL="$("$1/orch-env" KENDEX_USER_EMAIL "")" || return 1
  fi
  OWNER_TRACKER_LABEL="$("$1/orch-env" ORCH_OWNER_ASK_LABEL "")" || return 1
  OWNER_TRACKER_TEAM="$("$1/orch-env" LINEAR_TEAM "")" || return 1
  [[ -n "$OWNER_TRACKER_LABEL" && -n "$OWNER_TRACKER_TEAM" && -n "$OWNER_TRACKER_EMAIL" ]]
}

owner_tracker_unwritten() { # ISSUE CAUSE
  printf 'lane-mail: tracker-unwritten issue=%s cause=%s\n' "$1" "$2" >&2
}

owner_tracker_labels() { # TRACKER ISSUE ADD|REMOVE
  local current
  current="$("$1" issues get "$2" --format=safe)" || return 1
  jq -r --arg label "$OWNER_TRACKER_LABEL" --arg action "$3" '
    .labels | if $action == "ADD" then . + [$label] | unique
      else map(select(. != $label)) end | join(",")' <<<"$current"
}

owner_tracker_ask() { # TRACKER ENVELOPE WORK DIRECTORY
  local tracker="$1" envelope="$2" work="$3" issue labels
  OWNER_TRACKER_POSTED=0
  issue="$(jq -r '.issue' <<<"$envelope")" || return 1
  "$tracker" issues update "$issue" --assignee "$OWNER_TRACKER_EMAIL" >"$work/tracker.out" 2>"$work/tracker.err" || {
    owner_tracker_unwritten "$issue" assign; return 0;
  }
  labels="$(owner_tracker_labels "$tracker" "$issue" ADD 2>"$work/tracker.err")" || {
    owner_tracker_unwritten "$issue" labels-read; return 0;
  }
  "$tracker" issues update "$issue" --labels "$labels" >"$work/tracker.out" 2>"$work/tracker.err" || {
    owner_tracker_unwritten "$issue" label; return 0;
  }
  jq -r '.text, "", ("Options: " + (.options | join(", "))),
    (if .reserved == true then "No default. This action waits for your approval. Due " + .deadline
      else "Recommendation: " + .recommend + ". At " + .deadline + " it stands unless you answer." end),
    (if .draft then "Draft: " + (.draft | tojson) else empty end),
    ("ask=" + .id),
    "Reply with one comment: ok, yes or done to approve; anything else is a change request."' \
    <<<"$envelope" >"$work/tracker-comment" || return 1
  "$tracker" comments create "$issue" --body-file "$work/tracker-comment" >"$work/tracker.out" 2>"$work/tracker.err" || {
    owner_tracker_unwritten "$issue" comment; return 0;
  }
  OWNER_TRACKER_POSTED=1
}

owner_tracker_close() { # TRACKER ASK CLOSE_ID WORK DIRECTORY
  local tracker="$1" ask="$2" close="$3" work="$4" issue labels ask_id
  issue="$(jq -r '.issue // empty' <<<"$ask")" || return 1
  [[ -n "$issue" ]] || return 0
  # The close guard supplies the ruling from the owner's last answer or the
  # default. Read that record, rather than computing another ruling here.
  ask_id="$(jq -r '.id' <<<"$ask")" || return 1
  jq -rs --arg id "$close" --arg ask "$ask_id" '
    ([.[] | select(.kind == "answer" and .re == $ask)] | last | .text // "") as $ruling
    | .[] | select(.id == $id) | "ask=" + .re + " closed (" + .by + "): " + $ruling' \
    "$TO_LANE" >"$work/tracker-comment" || return 1
  "$tracker" comments create "$issue" --body-file "$work/tracker-comment" >"$work/tracker.out" 2>"$work/tracker.err" || {
    owner_tracker_unwritten "$issue" close-comment; return 0;
  }
  labels="$(owner_tracker_labels "$tracker" "$issue" REMOVE 2>"$work/tracker.err")" || {
    owner_tracker_unwritten "$issue" labels-read; return 0;
  }
  local label_args=(--clear-labels)
  [[ -z "$labels" ]] || label_args=(--labels "$labels")
  "$tracker" issues update "$issue" "${label_args[@]}" --clear-assignee >"$work/tracker.out" 2>"$work/tracker.err" ||
    owner_tracker_unwritten "$issue" close-update
}
