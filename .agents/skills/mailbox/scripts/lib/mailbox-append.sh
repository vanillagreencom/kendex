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
mailbox_legacy_notice() { # ID
  printf 'lane-mail: legacy-close=%s\nLegacy closing answer retained; supported through kendex 1.4.\n' "$1" >&2
}

mailbox_warn_legacy() { # FILE
  local ids id
  ids="$(jq -r -R "$MAILBOX_CLASS_JQ"' (fromjson? // empty) | objects
    | select(mailbox_legacy_close) | .id' <"$1")" || return 2
  [ -n "$ids" ] || return 0
  while IFS= read -r id; do
    mailbox_legacy_notice "$id"
  done <<<"$ids"
}

# The mailbox owns the ask. Tracker writes are advisory: a failed write must
# leave that ask available on its existing chat route.

owner_tracker_settings() { # MAILBOX SCRIPT DIRECTORY [ASK TO CLOSE]
  local root configured=0 recorded_label=""
  OWNER_TRACKER_SETTINGS_CAUSE=settings-unreadable
  OWNER_TRACKER_EMAIL=""
  OWNER_TRACKER_LABEL=""
  # shellcheck source=kendex-env.sh
  # shellcheck source=common-root.sh
  if . "$1/lib/kendex-env.sh" && . "$1/lib/common-root.sh" &&
     root="$(mailbox_common_root .)" && kendex_load_project_env "$root"; then
    OWNER_TRACKER_SETTINGS_CAUSE=settings-unset
    OWNER_TRACKER_EMAIL="${ORCH_OWNER_EMAIL:-${KENDEX_USER_EMAIL:-}}"
    OWNER_TRACKER_LABEL="${ORCH_OWNER_ASK_LABEL:-}"
    [[ -z "$OWNER_TRACKER_LABEL" || -z "$OWNER_TRACKER_EMAIL" ]] || configured=1
  fi
  [[ "$configured" -eq 1 ]] || OWNER_TRACKER_LABEL=""
  # Saved evidence enables close without settings. Keep the configured
  # label unchanged: it is the fallback for other, older asks only.
  if [[ -n "${2:-}" ]]; then
    recorded_label="$(jq -r 'select(.tracker_posted == true) | .tracker_label // empty' <<<"$2")" || return 1
    if [[ -n "$recorded_label" ]]; then
      return 0
    fi
  fi
  [[ "$configured" -eq 1 ]]
}

owner_tracker_unwritten() { # ISSUE CAUSE [ERROR FILE]
  local evidence=""
  if [[ -n "${3:-}" ]]; then
    if evidence="$(mktemp "$BOX/tracker-error.XXXXXX")" && cat -- "$3" >"$evidence"; then
      printf 'lane-mail: tracker-unwritten issue=%s cause=%s error-file=%s\n' "$1" "$2" "$evidence" >&2
      return 0
    fi
    printf 'lane-mail: tracker-error-unretained issue=%s cause=write\n' "$1" >&2
  fi
  printf 'lane-mail: tracker-unwritten issue=%s cause=%s\n' "$1" "$2" >&2
}

# Both mailbox readers fold posting evidence before selecting asks or cursors.
OWNER_TRACKER_JQ="$MAILBOX_TIME_JQ"'def owner_tracker_public:
  select(.kind != "tracker-posted" and .kind != "tracker-failed");
def owner_tracker_record($outcomes):
  if .kind == "ask" and .to == "owner" and .issue != null then
    . as $ask | ([$outcomes[] | select(.re == $ask.id and .issue == $ask.issue)] | last) as $record
    | .tracker_posted = ($record.kind == "tracker-posted")
    | if $record != null then del(.tracker_pending) else . end
    | if $record.tracker_label != null then .tracker_label = $record.tracker_label else . end
  else . end;
def owner_tracker_release_at:
  (.at | at_epoch) + 300;
def owner_tracker_snapshot($now):
  select(.tracker_pending != true or owner_tracker_release_at <= $now) | del(.tracker_pending);
def owner_tracker_label($configured):
  .tracker_label // (if $configured != "" then $configured else error("owner-tracker-label-unavailable") end);
def owner_tracker_open_labels($configured):
  map(select(.tracker_posted == true) | owner_tracker_label($configured)) | unique;'

# One description format serves the ask, its close and the watch's existing read.
# The Linear file reader trims trailing newlines. Use --description and keep
# a sentinel during shell capture so the existing body retains those bytes.
OWNER_ACTION_JQ='def owner_action_body:
  sub("^\\*\\*[^*\\r\\n]+, what you do:\\*\\*[^\\r\\n]*(\\r?\\n\\r?\\n)?"; "");
def owner_action_line($name; $action):
  "**" + ($name | [splits("\\s+") | select(length > 0)] | first)
  + ", what you do:** " + $action + "\n\n" + owner_action_body;'

owner_tracker_labels() { # ITEM JSON ADD|REMOVE [CLOSING LABEL] [REMAINING POSTED ASKS]
  jq -r --arg label "${3:-$OWNER_TRACKER_LABEL}" --arg configured "$OWNER_TRACKER_LABEL" \
    --arg action "$2" --argjson remaining "${4:-[]}" "$OWNER_TRACKER_JQ"'
    .labels | if $action == "ADD" then . + [$label] | unique
      else ($remaining | owner_tracker_open_labels($configured)) as $kept
        | map(select(. != $label)) + $kept | unique end | join(",")' <<<"$1"
}

owner_tracker_ask() { # TRACKER ENVELOPE WORK DIRECTORY
  local tracker="$1" envelope="$2" work="$3" issue labels current owner description comment_id cancel_error
  OWNER_TRACKER_POSTED=0
  OWNER_TRACKER_CAUSE=prepare
  issue="$(jq -r '.issue' <<<"$envelope")" || return 1
  owner="$("$tracker" users list --max --format=safe 2>"$work/tracker.err" | jq -ce --arg email "$OWNER_TRACKER_EMAIL" '
    [.[] | select((.email | ascii_downcase) == ($email | ascii_downcase))]
    | if length == 1 then .[0] | select(.id != "" and (.name | test("\\S"))) else empty end')" || {
    OWNER_TRACKER_CAUSE=owner-read; owner_tracker_unwritten "$issue" "$OWNER_TRACKER_CAUSE"; return 0;
  }
  "$tracker" issues update "$issue" --assignee "$(jq -r '.id' <<<"$owner")" >"$work/tracker.out" 2>"$work/tracker.err" || {
    OWNER_TRACKER_CAUSE=assign; owner_tracker_unwritten "$issue" "$OWNER_TRACKER_CAUSE"; return 0;
  }
  current="$("$tracker" issues get "$issue" --format=safe 2>"$work/tracker.err")" || {
    OWNER_TRACKER_CAUSE=labels-read; owner_tracker_unwritten "$issue" "$OWNER_TRACKER_CAUSE"; return 0;
  }
  labels="$(owner_tracker_labels "$current" ADD)" || return 1
  description="$(jq -r --argjson owner "$owner" --argjson ask "$envelope" "$OWNER_ACTION_JQ"'
    (.description // "") | owner_action_line($owner.name; $ask.do) + "."' <<<"$current")" || return 1
  description="${description%.}"
  # A failed comment must leave the description untouched.
  jq -r '.text, "", ("Options: " + (.options | join(", "))),
    (if .reserved == true then "No default. This action waits for your approval. Due " + .deadline
      else "Recommendation: " + .recommend + ". At " + .deadline + " it stands unless you answer." end),
    (if .draft then "Draft: " + (.draft | tojson) else empty end),
    ("ask=" + .id),
    "Reply with one comment: ok, yes or done to approve; anything else is a change request."' \
    <<<"$envelope" >"$work/tracker-comment" || return 1
  "$tracker" comments create "$issue" --body-file "$work/tracker-comment" >"$work/tracker.out" 2>"$work/tracker.err" || {
    OWNER_TRACKER_CAUSE=comment; owner_tracker_unwritten "$issue" "$OWNER_TRACKER_CAUSE"; return 0;
  }
  # The Linear comments interface returns this identity for cancellation.
  comment_id="$(jq -er '.data.comment.id | strings | select(length > 0)' "$work/tracker.out" 2>"$work/tracker.err")" || {
    OWNER_TRACKER_CAUSE=comment-id; owner_tracker_unwritten "$issue" "$OWNER_TRACKER_CAUSE"; return 0;
  }
  "$tracker" issues update "$issue" --labels "$labels" --description "$description" >"$work/tracker.out" 2>"$work/tracker.err" || {
    OWNER_TRACKER_CAUSE=label
    owner_tracker_unwritten "$issue" "$OWNER_TRACKER_CAUSE" "$work/tracker.err"
    # Unposted asks use chat. Do not leave a question whose replies are ignored.
    cancel_error="$work/tracker-cancel.err"
    if "$tracker" comments delete "$comment_id" >"$work/tracker-cancel.out" 2>"$work/tracker-cancel.err"; then
      if jq -e '.success == true' "$work/tracker-cancel.out" >/dev/null 2>"$work/tracker-cancel.err"; then return 0; fi
      cancel_error="$work/tracker-cancel.out"
    fi
    owner_tracker_unwritten "$issue" comment-cancel "$cancel_error"
    return 0
  }
  OWNER_TRACKER_POSTED=1
}

owner_tracker_close() { # TRACKER ASK CLOSE_ID WORK DIRECTORY
  local tracker="$1" ask="$2" close="$3" work="$4" issue labels ask_id current description remaining closing_label posted
  # An item reference alone does not grant ownership of its tracker contents.
  posted="$(jq -r '.tracker_posted == true' <<<"$ask")" || return 1
  [[ "$posted" == true ]] || return 0
  issue="$(jq -r '.issue // empty' <<<"$ask")" || return 1
  [[ -n "$issue" ]] || return 0
  closing_label="$(jq -r --arg configured "$OWNER_TRACKER_LABEL" "$OWNER_TRACKER_JQ"'
    owner_tracker_label($configured)' <<<"$ask" 2>"$work/tracker.err")" || {
    owner_tracker_unwritten "$issue" "$OWNER_TRACKER_SETTINGS_CAUSE"; return 0;
  }
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
  current="$("$tracker" issues get "$issue" --format=safe 2>"$work/tracker.err")" || {
    owner_tracker_unwritten "$issue" labels-read; return 0;
  }
  # Distinct owner asks can share an issue. The locked pending reader owns
  # closure and posting evidence; a closed ask cannot clear another open ask.
  "${BASH_SOURCE[0]%/lib/mailbox-append.sh}/lane-mail" pending --item overseer --root "$ROOT" --to owner \
    >"$work/tracker-remaining" 2>"$work/tracker.err" || {
    owner_tracker_unwritten "$issue" asks-read; return 0;
  }
  remaining="$(jq -cs --arg issue "$issue" '[.[] | select(.tracker_posted == true and .issue == $issue)]' \
    "$work/tracker-remaining")" || return 1
  # A remaining legacy ask needs configured evidence. Another ask's saved
  # label cannot identify it, even when that other ask is closing.
  labels="$(owner_tracker_labels "$current" REMOVE "$closing_label" "$remaining" 2>"$work/tracker.err")" || {
    owner_tracker_unwritten "$issue" "$OWNER_TRACKER_SETTINGS_CAUSE"; return 0;
  }
  local owner_args=(--clear-assignee)
  if [[ "$remaining" != '[]' ]]; then
    owner_args=()
  fi
  # Keep a line another ask or a later edit owns, even if its format matches.
  description="$(jq -r --argjson closed "$ask" --argjson asks "$remaining" "$OWNER_ACTION_JQ"'
    .assignee as $name | (.description // "")
    | if ($closed.do // "") != "" then
        ("" | owner_action_line($name; $closed.do)) as $prefix
        | if startswith($prefix) then
            ltrimstr($prefix) as $body | ($asks | last) as $next
            | if ($next.do // "") != "" then ("" | owner_action_line($name; $next.do)) + $body else $body end
          else . end
      else . end
    | . + "."' <<<"$current")" || return 1
  description="${description%.}"
  local label_args=(--clear-labels)
  [[ -z "$labels" ]] || label_args=(--labels "$labels")
  "$tracker" issues update "$issue" "${label_args[@]}" ${owner_args[@]+"${owner_args[@]}"} --description "$description" >"$work/tracker.out" 2>"$work/tracker.err" ||
    owner_tracker_unwritten "$issue" close-update
}
