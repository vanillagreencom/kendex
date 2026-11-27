# shellcheck shell=bash
# The rules a mailbox obeys wherever the file sits: the lane's own disk through
# `lane-mail`, a provider's host through `orch-runtime host append`, and the fixture
# that models a provider. One owner for each, because a drift in where a line
# ends glues two envelopes together or hands over half of one, and a drift in
# the lock loses a line whenever two writers meet.
#
# Sourced, never executed, after lib/file-lock.sh, whose orch_take_lock and
# orch_release_lock this uses; the envelope class alone takes no lock. Bash
# 3.2-safe, like its callers.

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

# Whether a newline-terminated mailbox line is damage a reader must stop at:
# neither an envelope (a JSON object) nor a fragment mailbox_terminate closed,
# which carries mailbox_torn_mark at its end. The writer marks with this rule
# and every lane-mail reader refuses with it, so the two cannot come apart on
# which line is a killed writer's and which is damage. The mark opens with
# U+001E, a control character JSON allows nowhere, so a marked line never
# parses, whatever the fragment before it held.
# shellcheck disable=SC2034  # read by the scripts that source this.
MAILBOX_LINE_JQ='def mailbox_torn_mark: "\u001etorn";
def mailbox_line_invalid:
  (endswith(mailbox_torn_mark) | not)
  and (((fromjson? // null) | type) != "object");
'

# A writer killed inside its write leaves a line with no newline of its own.
# Closing it lets the envelope that follows land whole instead of being glued
# to it and both lost. A fragment that is not already a whole envelope is
# closed with mailbox_torn_mark, so readers skip it as a killed writer's line
# rather than refusing it as damage; one that parses is closed as it stands
# and read as the envelope it is. The caller holds the lock on FILE; the
# append here is its own open, which the kernel places at the end exactly as
# the caller's descriptor would.
mailbox_terminate() { # FILE
  local complete=0 mark
  mailbox_line_complete "$1" || complete=$?
  [ "$complete" -ne 0 ] || return 0
  [ "$complete" -eq 1 ] || return 1
  mark="$(tail -n 1 -- "$1" |
    jq -j -R "$MAILBOX_LINE_JQ"'if mailbox_line_invalid then mailbox_torn_mark else "" end')" || return 1
  printf '%s\n' "$mark" >>"$1" || return 1
}

# The `at` stamp as epoch seconds, null where it does not parse: the one
# parse every reader of a stamp shares, prefixed to its jq program.
MAILBOX_TIME_JQ='def at_epoch: try (strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) catch null;'

# The destination's most recent whole-envelope repeat within a minute. Both
# lane-mail and a provider's append verb call this under the destination's own lock.
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
# reply's --ref and the watch that reports the line judge one rule: `data`
# is a data notice, whoever its `from` names, so it is never an owner note; a
# `close` is a resolution; `resolution` is an owner answer carrying `by`, a
# pre-1.3 closing answer with no closes field included; a `peer` line names
# another repository's overseer in `from`; an `owner-note` names owner or no
# sender; and a `stray` is an owner answer missing the `by` field every
# owner-answer writer supplies.
# shellcheck disable=SC2034  # read by the scripts that source this.
MAILBOX_CLASS_JQ='def overseer_mail_class:
  if .kind == "data" then "data"
  elif .kind == "resolution" then "close"
  elif .kind == "answer" and (.by | type) == "string" then "resolution"
  elif ((.from // "") | . != "" and . != "owner") then "peer"
  elif .kind == "answer" then "stray"
  else "owner-note" end;
# Outbound mail records replies after delivery. Exact ids let a reply clear
# its own note without acknowledging earlier notes above the read cursor.
def mailbox_answers:
  reduce (.[] | if .kind == "notice" and .to == "owner" then .ref
                elif .kind == "answer" then .re else empty end
                | strings | select(length > 0)) as $id ({}; .[$id] = true);
'

# The mailbox owns the ask. Tracker writes after the append are advisory: a
# failed write must leave that ask available on its existing chat route. The
# settings the write needs are judged before the append, and an item ask they
# cannot carry is refused there.

# OWNER_TRACKER_UNSET names, comma-separated, each key left unset, the owner
# account as ORCH_OWNER_EMAIL, its documented key, which KENDEX_USER_EMAIL
# stands in for.
owner_tracker_settings() { # MAILBOX SCRIPT DIRECTORY
  local root
  OWNER_TRACKER_SETTINGS_CAUSE=settings-unreadable
  OWNER_TRACKER_EMAIL=""
  OWNER_TRACKER_LABEL=""
  OWNER_TRACKER_UNSET=""
  # shellcheck source=kendex-env.sh
  # shellcheck source=common-root.sh
  if . "$1/lib/kendex-env.sh" && . "$1/lib/common-root.sh" &&
     root="$(mailbox_common_root .)" &&
     kendex_load_project_env "$root" -- ORCH_OWNER_EMAIL KENDEX_USER_EMAIL ORCH_OWNER_ASK_LABEL; then
    OWNER_TRACKER_EMAIL="${ORCH_OWNER_EMAIL:-${KENDEX_USER_EMAIL:-}}"
    OWNER_TRACKER_LABEL="${ORCH_OWNER_ASK_LABEL:-}"
    [[ -n "$OWNER_TRACKER_LABEL" ]] || OWNER_TRACKER_UNSET=ORCH_OWNER_ASK_LABEL
    [[ -n "$OWNER_TRACKER_EMAIL" ]] || OWNER_TRACKER_UNSET="${OWNER_TRACKER_UNSET:+$OWNER_TRACKER_UNSET,}ORCH_OWNER_EMAIL"
    [[ -n "$OWNER_TRACKER_UNSET" ]] || return 0
    OWNER_TRACKER_SETTINGS_CAUSE=settings-unset
  fi
  OWNER_TRACKER_LABEL=""
  return 1
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

# Both mailbox readers fold the private records onto the ask each names before
# selecting asks or cursors: posting evidence, and a reservation, which makes a
# standing owner ask reserved as `--reserved` makes one at ask time, so every
# reader of the folded ask judges the one `reserved` field.
OWNER_TRACKER_JQ="$MAILBOX_TIME_JQ"'def owner_private:
  .kind == "tracker-posted" or .kind == "tracker-failed" or .kind == "reservation" or .kind == "replacement";
def owner_tracker_public:
  select(owner_private | not);
def owner_ask_reserved($private):
  if .kind == "ask" and .to == "owner"
    and (.id as $id | any($private[]; .kind == "reservation" and .re == $id))
  then .reserved = true else . end;
def owner_tracker_record($outcomes):
  if .kind == "ask" and .to == "owner" and .issue != null then
    . as $ask | ([$outcomes[] | select(.re == $ask.id and .issue == $ask.issue)] | last) as $record
    | .tracker_posted = ($record.kind == "tracker-posted")
    | if $record != null then del(.tracker_pending) else . end
    | if $record.tracker_label != null then .tracker_label = $record.tracker_label else . end
    | if $record.tracker_comment != null then .tracker_comment = $record.tracker_comment else . end
    | if $record.tracker_action_line == false then .tracker_action_line = false else . end
    | if $record.kind == "tracker-failed" then .tracker_cause = $record.cause else . end
  else . end
  | if .kind == "ask" and .to == "owner" then
      . as $ask | ([$outcomes[] | select(.kind == "replacement" and .re == $ask.id)] | last) as $replacement
      | if $replacement != null then .replacement = $replacement.outcome else . end
    else . end;
def owner_tracker_release_at:
  (.at | at_epoch) + 300;
def owner_tracker_snapshot($now):
  select(.tracker_pending != true or owner_tracker_release_at <= $now) | del(.tracker_pending);'

# An ask's `replaces` takes effect only where the ask reached the owner: an
# ask with no item, or an item ask whose question posted. The ask's replace
# step and owner-answers both judge an ask by this one rule.
OWNER_REPLACING_JQ='def owner_replacing: .issue == null or .tracker_posted == true;'

# Which question comments of this mailbox still stand open, and for which
# ask: the one rule every reader of a question judges by. The input is the
# open owner asks as `pending` folds them. Each row names a question comment
# and the open ask a reply under it reaches: an open posted ask's own
# question, and each question an open ask that reached the owner replaced,
# the latest such ask where several did, `replaced` naming the ask the
# question was asked for. A question no row names is no longer open: its ask
# closed and no open ask replaced it. An own row's comment is null only on a
# record from before posted asks kept their comment id. `item` is the item
# whose comments hold the question: the identifier and UUID the ask recorded
# as its identity, else the ref it was asked under with no UUID. A replaced
# question's item can be one no open ask is on.
OWNER_QUESTION_JQ="$OWNER_REPLACING_JQ"'
def owner_questions:
  map(select(.kind == "ask" and .to == "owner")) as $asks
  | [$asks[] | select(.tracker_posted == true) | {comment: .tracker_comment, ask: .id, issue, replaced: null,
      item: {ref: (.identity.identifier // .issue), uuid: .identity.uuid}}] as $own
  | $own + ([$asks[] | select(owner_replacing) | . as $by | (.replaces // [])[]
        | select((.tracker_comment | type) == "string")
        | select(.tracker_comment as $comment | all($own[]; .comment != $comment))
        | {comment: .tracker_comment, ask: $by.id, issue: null, replaced: .id,
          item: (if .identity != null then {ref: .identity.identifier, uuid: .identity.uuid} else null end)}]
      | group_by(.comment) | map(last));

# The first question on a reply path in one item. The row count bounds a
# broken parent chain. The mailbox delivery reader also keeps its existing
# earlier-comment rule for intermediate replies.
def owner_question_parent($rows; $questions; $earlier):
  def follow($left):
    . as $row | .parent_id as $parent
    | if $parent == null or $parent == "" or $left == 0 then null
      elif $questions | has($parent) then $parent
      elif $rows[$parent] == null or ($earlier and $rows[$parent].created_at >= $row.created_at) then null
      else $rows[$parent] | follow($left - 1) end;
  follow($rows | length);

# Each fact belongs to this exact question. The replacement writer uses
# the same rule to recognize a mark that landed on a previous attempt.
def owner_question_settled($answered; $closed; $replaced):
  def struck:
    (.body | split("\n")) as $lines
    | ($lines[0] | test("^\\*\\*Replaced\\*\\* by (a newer question|\\[the newer question\\]\\(https?://.+\\))\\. Answer that one only\\.$"))
      and $lines[1] == ""
      and ([$lines[2:][] | select(test("\\S"))] | length > 0 and all(.[]; test("^~~.*\\S.*~~$")));
  $answered or $closed or $replaced or struck;'

# One description format serves the ask and the watch's read and close.
# The Linear file reader trims trailing newlines. Use --description and keep
# a sentinel during shell capture so the existing body retains those bytes.
# The question's comment ID ends the action's own line, so a watch closing
# one ask removes only the line it marked, whatever other mailbox asks on the
# item. The Linear description guard takes one action line before the quoted
# opening, so the mark cannot stand on a line of its own.
OWNER_ACTION_JQ='def owner_action_body:
  sub("^\\*\\*[^*\\r\\n]+, what you do:\\*\\*[^\\r\\n]*(\\r?\\n\\r?\\n)?"; "");
def owner_action_line($name; $action; $question):
  "**" + ($name | [splits("\\s+") | select(length > 0)] | first)
  + ", what you do:** " + $action
  + (if ($question | type) == "string" and $question != "" then " `Owner question: " + $question + "`" else "" end)
  + "\n\n" + owner_action_body;'

# The item as the ask reads it: description, assignee name and
# label names. `linear.sh graphql` refuses a label page left open, which the
# label write needs, since it sends the whole set.
owner_tracker_item() { # TRACKER ISSUE
  local answer
  answer="$("$1" graphql --query 'query OwnerTracker($id: String!) { issue(id: $id) { description assignee { name } labels(first: 250) { pageInfo { hasNextPage } nodes { name } } } }' \
    --variables "$(jq -cn --arg id "$2" '{id: $id}')")" || return 1
  jq -ce '.issue | {description: (.description // ""), assignee: (.assignee.name // ""), labels: [.labels.nodes[].name]}' <<<"$answer"
}

owner_tracker_labels() { # ITEM JSON ADD|REMOVE
  jq -r --arg label "$OWNER_TRACKER_LABEL" --arg action "$2" '
    .labels | if $action == "ADD" then . + [$label] else map(select(. != $label)) end
    | unique | join(",")' <<<"$1"
}

# Whether the saved comment mentions the owner: 0 yes, 1 no, 2 unread. Linear
# keeps a comment's rendered body as ProseMirror JSON in bodyData, a mention of
# a person as a `suggestion_userMentions` node whose attrs.id is that user's id
# (read from a live owner-ask comment, HT-2435 f288ba35).
owner_tracker_mentioned() { # TRACKER COMMENT OWNER_ID
  local answer mentioned
  answer="$("$1" graphql --query 'query OwnerTrackerComment($id: String!) { comment(id: $id) { bodyData } }' \
    --variables "$(jq -cn --arg id "$2" '{id: $id}')")" || return 2
  mentioned="$(jq -r --arg owner "$3" '.comment.bodyData | fromjson
    | any(.. | objects; .type == "suggestion_userMentions" and .attrs.id == $owner)' <<<"$answer")" || return 2
  case "$mentioned" in
    true) return 0 ;;
    false) return 1 ;;
  esac
  return 2
}

owner_tracker_ask() { # TRACKER ENVELOPE WORK DIRECTORY ASKER
  local tracker="$1" envelope="$2" work="$3" asker="$4" issue labels current owner description latest owns_description original_description
  local added_label rollback_labels comment_error comment_id workspace mentioned ask_id comment_issue question comment_file form
  local rollback_args=()
  OWNER_TRACKER_POSTED=0
  OWNER_TRACKER_COMMENT=""
  OWNER_TRACKER_LINED=1
  OWNER_TRACKER_CAUSE=prepare
  issue="$(jq -r '.issue' <<<"$envelope")" || return 1
  ask_id="$(jq -er '.id | strings | select(length > 0)' <<<"$envelope")" || return 1
  comment_issue="$(jq -r '.identity.uuid // .issue' <<<"$envelope")" || return 1
  owner="$("$tracker" users list --max --format=safe 2>"$work/tracker.err" | jq -ce --arg email "$OWNER_TRACKER_EMAIL" '
    [.[] | select((.email | ascii_downcase) == ($email | ascii_downcase))]
    | if length == 1 then .[0] | select(.id != "" and (.name | test("\\S")) and (.display_name // "" | test("\\S")))
      else empty end')" || {
    OWNER_TRACKER_CAUSE=owner-read; owner_tracker_unwritten "$issue" "$OWNER_TRACKER_CAUSE"; return 0;
  }
  # Linear renders a profile URL as a mention and notifies that person. The
  # workspace key comes from the tracker, never from package code.
  workspace="$("$tracker" teams keys 2>"$work/tracker.err" | jq -re '.urlKey | select(type == "string" and test("\\S"))')" || {
    OWNER_TRACKER_CAUSE=workspace-read; owner_tracker_unwritten "$issue" "$OWNER_TRACKER_CAUSE"; return 0;
  }
  # The ID the question comment posts under, which marks the action line.
  question="$("$tracker" comments owner-questions --id "$ask_id" 2>"$work/tracker.err" | jq -er 'strings | select(length > 0)')" || {
    OWNER_TRACKER_CAUSE=question-id; owner_tracker_unwritten "$issue" "$OWNER_TRACKER_CAUSE"; return 0;
  }
  "$tracker" issues update "$issue" --assignee "$(jq -r '.id' <<<"$owner")" >"$work/tracker.out" 2>"$work/tracker.err" || {
    OWNER_TRACKER_CAUSE=assign; owner_tracker_unwritten "$issue" "$OWNER_TRACKER_CAUSE"; return 0;
  }
  current="$(owner_tracker_item "$tracker" "$issue" 2>"$work/tracker.err")" || {
    OWNER_TRACKER_CAUSE=labels-read; owner_tracker_unwritten "$issue" "$OWNER_TRACKER_CAUSE"; return 0;
  }
  labels="$(owner_tracker_labels "$current" ADD)" || return 1
  added_label="$(jq -r --arg label "$OWNER_TRACKER_LABEL" '.labels | index($label) == null' <<<"$current")" || return 1
  description="$(jq -r --argjson owner "$owner" --argjson ask "$envelope" --arg question "$question" "$OWNER_ACTION_JQ"'
    (.description // "") | owner_action_line($owner.name; $ask.do; $question) + "."' <<<"$current")" || return 1
  description="${description%.}"
  # The comment is a message to a person. Ids stay in the mailbox: the watch
  # finds this comment by the id the tracker-posted record keeps. The form
  # for an item that takes no action line carries the action itself, since
  # that line is where the owner otherwise reads it.
  for form in lined unlined; do
    jq -r --arg workspace "$workspace" --argjson owner "$owner" --arg asker "$asker" --arg form "$form" '
    "https://linear.app/" + ($workspace | @uri) + "/profiles/" + ($owner.display_name | @uri), "",
    .text, "", (if $form == "unlined" then "What you do: " + .do, "" else empty end),
    ("Options: " + (.options | join(", "))),
    (if .reserved == true then "No default. This action waits for your approval. Due " + .deadline
      else "Recommendation: " + .recommend + ". At " + .deadline + " it stands unless you answer." end),
    (if .draft then "Draft: " + (.draft | tojson) else empty end),
    "", "Reply to this comment: ok, yes or done to approve; anything else is a change request.",
    "", "Requested by " + $asker' \
      <<<"$envelope" >"$work/tracker-comment-$form" || return 1
  done
  comment_file="$work/tracker-comment-lined"
  # The Linear package refuses, before any write, a description write to an
  # item Linear's GitHub sync links (issues.sh require_unsynced_description),
  # so there the label goes alone and the item carries no action line.
  if ! "$tracker" issues update "$issue" --labels "$labels" --description "$description" >"$work/tracker.out" 2>"$work/tracker.err"; then
    if grep -q '^linear: refused=synced-description ' "$work/tracker.err" &&
       "$tracker" issues update "$issue" --labels "$labels" >"$work/tracker.out" 2>"$work/tracker.err"; then
      OWNER_TRACKER_LINED=0
      comment_file="$work/tracker-comment-unlined"
    else
      OWNER_TRACKER_CAUSE=label; owner_tracker_unwritten "$issue" "$OWNER_TRACKER_CAUSE" "$work/tracker.err"; return 0
    fi
  fi
  OWNER_TRACKER_CAUSE=comment
  comment_error="$work/tracker-comment.err"
  comment_id=""
  # No attribution line, so the comment opens with the owner's mention.
  if "$tracker" comments create "$comment_issue" --owner-question "$ask_id" --no-attribution --body-file "$comment_file" >"$work/tracker.out" 2>"$work/tracker-comment.err"; then
    if comment_id="$(jq -er 'select(.success == true) | .data.comment.id // ""' "$work/tracker.out" 2>"$work/tracker-comment.err")"; then
      # The ask is posted only once the saved comment shows the mention that
      # tells the owner it is there.
      mentioned=0
      owner_tracker_mentioned "$tracker" "$comment_id" "$(jq -r '.id' <<<"$owner")" \
        2>"$work/tracker-mention.err" || mentioned=$?
      case "$mentioned" in
        0) OWNER_TRACKER_POSTED=1; OWNER_TRACKER_COMMENT="$comment_id"; return 0 ;;
        1) OWNER_TRACKER_CAUSE=mention; comment_error="" ;;
        *) OWNER_TRACKER_CAUSE=mention-read; comment_error="$work/tracker-mention.err" ;;
      esac
    else
      comment_id=""
      comment_error="$work/tracker.out"
    fi
  fi
  owner_tracker_unwritten "$issue" "$OWNER_TRACKER_CAUSE" ${comment_error:+"$comment_error"}
  # An unposted ask leaves no question comment: the chat carries it, and no
  # reader follows a reply to a comment the ask does not record.
  # `comments delete` exits 0 on a refused delete too, so its answer is judged
  # as the create's is.
  if [[ -n "$comment_id" ]]; then
    if "$tracker" comments delete "$comment_id" >"$work/tracker-delete.out" 2>"$work/tracker-delete.err"; then
      jq -e '.success == true' "$work/tracker-delete.out" >/dev/null 2>&1 ||
        owner_tracker_unwritten "$issue" comment-delete "$work/tracker-delete.out"
    else
      owner_tracker_unwritten "$issue" comment-delete "$work/tracker-delete.err"
    fi
  fi
  [[ "$OWNER_TRACKER_LINED" -eq 1 || "$added_label" == true ]] || return 0
  latest="$(owner_tracker_item "$tracker" "$issue" 2>"$work/tracker-rollback.err")" || {
    owner_tracker_unwritten "$issue" rollback-read "$work/tracker-rollback.err"; return 0;
  }
  if [[ "$OWNER_TRACKER_LINED" -eq 1 ]]; then
    # Restore only while the fresh read still contains this ask's exact write.
    owns_description="$(jq -r --arg written "$description" '(.description // "") == $written' \
      <<<"$latest" 2>"$work/tracker-rollback.err")" || {
      owner_tracker_unwritten "$issue" rollback-read "$work/tracker-rollback.err"; return 0;
    }
    [[ "$owns_description" == true ]] || {
      owner_tracker_unwritten "$issue" rollback-unowned; return 0;
    }
    original_description="$(jq -r '(.description // "") + "."' <<<"$current")" || return 1
    rollback_args=(--description "${original_description%.}")
  fi
  if [[ "$added_label" == true ]]; then
    rollback_labels="$(owner_tracker_labels "$latest" REMOVE 2>"$work/tracker-rollback.err")" || {
      owner_tracker_unwritten "$issue" rollback-read "$work/tracker-rollback.err"; return 0;
    }
    if [[ -z "$rollback_labels" ]]; then
      rollback_args+=(--clear-labels)
    else
      rollback_args+=(--labels "$rollback_labels")
    fi
  fi
  "$tracker" issues update "$issue" "${rollback_args[@]}" \
    >"$work/tracker-rollback.out" 2>"$work/tracker-rollback.err" ||
    owner_tracker_unwritten "$issue" rollback-update "$work/tracker-rollback.err"
  return 0
}

# The refs among REF... that Linear answered it holds no issue for: the
# `missing` list a refused `issues bulk-get` or `comments bulk-list` closes
# its stderr with (comments --help), whose identifiers are in upper case
# (linear_issue_refs), each printed as the caller gave it. Returns 1 where
# the stderr in ERROR_FILE holds no such list, or one naming a ref not given:
# the read failed some other way, and whether the issue exists is unknown.
owner_tracker_missing() { # ERROR_FILE REF...
  local error="$1"
  shift
  jq -Rrn --args '$ARGS.positional as $refs
    | [inputs | fromjson? | objects | .missing | arrays] | last
    | if . == null or length == 0 or any(.[]; type != "string") then error("unread") else . end
    | . as $missing
    | if all($missing[]; . as $name | any($refs[]; . == $name or ascii_upcase == $name)) then . else error("unread") end
    | $refs[] | select(. as $ref | any($missing[]; . == $ref or . == ($ref | ascii_upcase)))' \
    "$@" <"$error" 2>/dev/null
}

# The tracker identity of each item REF: the current identifier and UUID
# Linear's `issues bulk-get` answers, which reads an identifier in any case, a
# UUID and a moved issue's former identifier as the one issue
# (linear_issue_refs_read). Prints one JSON object keyed by each ref, its value
# {identifier, uuid}, or null where Linear answers it holds no such issue.
# Returns 1 where a read fails any other way, its stderr in WORK/identity.err.
# One read answers the refs; a ref no row names as it was given, a former
# identifier or one in lower case, is then read alone, since the safe rows do
# not say which ref each answers.
owner_tracker_identity() { # TRACKER WORK REF...
  local tracker="$1" work="$2" known='{}' missing ref rows unmatched="" remaining=()
  shift 2
  [[ "$#" -gt 0 ]] || { printf '{}\n'; return 0; }
  if ! rows="$("$tracker" issues bulk-get "$@" --format=safe 2>"$work/identity.err")"; then
    missing="$(owner_tracker_missing "$work/identity.err" "$@")" || return 1
    for ref in "$@"; do
      if grep -Fqx -- "$ref" <<<"$missing"; then
        known="$(jq -c --arg ref "$ref" '.[$ref] = null' <<<"$known")" || return 1
      else
        remaining+=("$ref")
      fi
    done
    rows='[]'
    if [[ "${#remaining[@]}" -gt 0 ]]; then
      rows="$("$tracker" issues bulk-get "${remaining[@]}" --format=safe 2>"$work/identity.err")" || return 1
    fi
  fi
  jq -e 'type == "array" and all(.[]; type == "object" and (.id | type == "string") and (.uuid | type == "string"))' \
    <<<"$rows" >/dev/null 2>"$work/identity.err" || return 1
  known="$(jq -c --argjson rows "$rows" --args '. as $known | reduce ($ARGS.positional[] | select(. as $ref | $known | has($ref) | not)) as $ref
    ($known; ([$rows[] | select(.uuid == $ref or .id == $ref)] | first) as $row
      | if $row == null then . else .[$ref] = {identifier: $row.id, uuid: $row.uuid} end)' "$@" <<<"$known")" || return 1
  unmatched="$(jq -r --args '. as $known | $ARGS.positional[] | select(. as $ref | $known | has($ref) | not)' "$@" <<<"$known")" ||
    return 1
  while IFS= read -r ref; do
    [[ -n "$ref" ]] || continue
    if ! rows="$("$tracker" issues bulk-get "$ref" --format=safe 2>"$work/identity.err")"; then
      owner_tracker_missing "$work/identity.err" "$ref" >/dev/null || return 1
      rows='null'
    fi
    known="$(jq -c --arg ref "$ref" --argjson rows "$rows" '.[$ref] = (if $rows == null then null
      elif ($rows | type == "array" and length == 1 and (.[0].id | type == "string") and (.[0].uuid | type == "string"))
      then {identifier: $rows[0].id, uuid: $rows[0].uuid} else error("rows") end)' <<<"$known" 2>"$work/identity.err")" || return 1
  done <<<"$unmatched"
  printf '%s\n' "$known"
}

# The acting identity a replaced question's mark compares each comment's
# author with. A mark is a `comments update`, which the Linear package refuses
# before any call where no LINEAR_TEAM is configured (its configured-team
# gate, auth-check's writes_enabled). Sets OWNER_REPLACE_ACTOR, or sets
# OWNER_REPLACE_CAUSE and returns 1: team-unset, team-unread where auth-check
# does not say, actor-unread where it names no acting identity.
owner_tracker_replace_actor() { # TRACKER WORK
  local team
  OWNER_REPLACE_ACTOR=""
  OWNER_REPLACE_CAUSE=""
  # auth-check prints its report when its API read fails too, with no actor.
  "$1" auth-check </dev/null >"$2/replace-auth" 2>"$2/replace-auth.err" || :
  team="$(jq -r 'if .writes_enabled == true then "set" elif .writes_enabled == false then "unset" else "unread" end' \
    "$2/replace-auth" 2>/dev/null)" || team=unread
  case "$team" in
    set) ;;
    unset) OWNER_REPLACE_CAUSE=team-unset; return 1 ;;
    *) OWNER_REPLACE_CAUSE=team-unread; return 1 ;;
  esac
  OWNER_REPLACE_ACTOR="$(jq -r '.actor.id // "" | strings' "$2/replace-auth" 2>/dev/null)" || OWNER_REPLACE_ACTOR=""
  [[ -n "$OWNER_REPLACE_ACTOR" ]] || { OWNER_REPLACE_CAUSE=actor-unread; return 1; }
}

# Where a replaced ask's question comment stands, read by its exact id, in
# OWNER_REPLACE_STATE: absent where `comments bulk-get` answers no such
# comment, foreign where an identity other than ACTOR wrote it, marked where
# it already carries the replacement strike, ready otherwise, and unread where
# a read fails. With `mark`, a ready comment is edited: its own lines struck
# through under one line linking NEW_COMMENT, or saying a newer question
# replaced it where the new ask has no comment, so the owner answers that one
# only. The state is then marked, or unmarked where the edit did not land.
# Only a comment ACTOR wrote is edited: after an account change, the earlier
# account's comment is another author's text.
owner_tracker_replaced_comment() { # TRACKER WORK ENTRY_JSON ACTOR check|mark [NEW_COMMENT]
  local tracker="$1" work="$2" entry="$3" actor="$4" mode="$5" new="${6:-}" comment item urls rows row url
  OWNER_REPLACE_STATE=unread
  comment="$(jq -r '.tracker_comment' <<<"$entry")" || return 0
  item="$(jq -r '.identity.uuid // ""' <<<"$entry")" || return 0
  urls="$("$tracker" comments bulk-get "$comment" ${new:+"$new"} 2>"$work/replace.err")" || return 0
  jq -e 'type == "object"' <<<"$urls" >/dev/null 2>&1 || return 0
  if ! jq -e --arg id "$comment" 'has($id)' <<<"$urls" >/dev/null; then
    OWNER_REPLACE_STATE=absent
    return 0
  fi
  [[ -n "$item" ]] || return 0
  rows="$("$tracker" comments list "$item" --format=safe 2>"$work/replace.err")" || return 0
  row="$(jq -ce --arg id "$comment" 'map(select(.id == $id)) | first
    | select(type == "object" and (.body | type == "string") and (.user_id | type == "string"))' <<<"$rows" 2>/dev/null)" ||
    return 0
  if [[ "$(jq -r --arg actor "$actor" '.user_id == $actor' <<<"$row")" != true ]]; then
    OWNER_REPLACE_STATE=foreign
    return 0
  fi
  if jq -e "$OWNER_QUESTION_JQ"' owner_question_settled(false; false; false)' <<<"$row" >/dev/null; then
    OWNER_REPLACE_STATE=marked
    return 0
  fi
  OWNER_REPLACE_STATE=ready
  [[ "$mode" == mark ]] || return 0
  url="$(jq -r --arg id "$new" '.[$id].url // "" | strings' <<<"$urls")" || return 0
  jq -r --arg url "$url" '(.body | gsub("\r"; "") | sub("\n+$"; "") | split("\n")) as $lines
    | ("**Replaced** by " + (if $url == "" then "a newer question" else "[the newer question](" + $url + ")" end)
      + ". Answer that one only."), "",
      ($lines[] | if test("\\S") then "~~" + . + "~~" else . end)' <<<"$row" >"$work/replaced-comment" || return 0
  OWNER_REPLACE_STATE=unmarked
  if "$tracker" comments update "$comment" --body-file "$work/replaced-comment" >"$work/replace.out" 2>"$work/replace.err" &&
     jq -e '.success == true' "$work/replace.out" >/dev/null 2>&1; then
    OWNER_REPLACE_STATE=marked
  fi
}
