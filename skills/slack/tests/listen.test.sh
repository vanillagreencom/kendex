#!/usr/bin/env bash
# `slack listen`: owner text to the mailbox and the mailbox to Slack, through
# the real lane-mail and a fake Slack API paged two messages at a time. The
# rows: a directive with its delivery id, an ask posted with the mention and
# answered repeatedly in its thread until the asker closes, a chat answer
# and a deadline default shown in the thread, a notice threaded on its ref, a
# notice on an owner's reply threaded under that reply's parent, a report
# uploaded and its thread bound from the share, a non-owner and an empty
# message answered once and not routed, an owner's files saved and named in
# the envelope, an HTML file saved, a long name cut to 200 characters, a
# refused download, Slack's sign-in page in place of a PNG and of an HTML
# file, a file with no download url and a
# body cut short under its Content-Length or inside a chunk each named by file
# id, a whole chunked body with no Content-Length saved, a directive's eyes
# mark swapped for a check once the cursor passes it, a refused mark printed
# without failing the poll and made on the next, a stop after the delivery
# or after its mark landed marked and swapped after the restart, a refused
# swap completed on the next poll, each
# Slack answer a swap counts as settled, a receipts read lane-mail refuses
# printed without failing the poll, each form of Slack's escapes and tokens
# read back as typed, catch-up over pages, the crash between the mailbox
# append and the journal mark, the second relay refused by the lock, two roots
# bound to one channel refused at start, reconnect catch-up leaving a thread
# past SLACK_THREAD_DAYS unread, owner broadcasts routed and non-owner
# broadcasts refused, a secret value refused, a 429 honoured, a
# post Slack refuses failing the poll and made again, a post whose response
# was lost journaled unknown, a refused history read failing the poll, asks
# and notices sent as markdown_text, an ask's deadline as Slack's date token,
# a notice and an ask past its cap sent as text, a first
# start reading Slack from the binding moment and posting nothing from the
# mailbox's past but open asks, daily compaction retaining aged posts in live
# threads and removing inactive ones, aged unposted envelopes skipped,
# a journal reset re-posting open asks alone,
# owners re-resolved from the setting, a report whose file matches the pattern
# or is gone refused, and a notice under an owner message past the horizon
# posted once across compaction. The controls at the end plant one mutant per
# rule: the delivery id dropped, the ask thread no longer resolved, the lock
# no longer exclusive, two roots on one channel accepted, the thread-age
# horizon removed, the owner gate open, the no-text gate open, the files
# unread, the sign-in check gone, the file name kept whole, the files
# directory mode unset, the file's size unread, the name uncut, the length
# unchecked, a missing length read as zero, http.client's own error uncaught
# in the download, the seen mark gone, the cursor unread, a refused mark
# raised, each settled Slack answer unsettled, a refused receipts read raised,
# the markup unread, &amp; unescaped first, the outbound text and the report
# bytes unchecked, the body sent as text, the text fallback gone, the
# deadline as its raw stamp, the post failure swallowed, the envelope horizon removed,
# live-thread post retention removed, the start horizon removed, the history
# seed at zero, and a refused connection read as a lost response.
set -uo pipefail
. "$(dirname "$0")/lib/harness.sh"

sk_fake_start --page 2
echo "=== slack listen ==="

directives() { # ROOT — every directive's key and text; none before the first delivery
  [ -f "$(sk_box "$1")/to-lane.jsonl" ] || return 0
  jq -r 'select(.kind == "directive") | [.delivery_id, .text] | join(" ")' "$(sk_box "$1")/to-lane.jsonl"
}
answers() { jq -r 'select(.kind == "answer") | [.re, .by, .delivery_id, .text] | join(" ")' "$(sk_box "$1")/to-lane.jsonl"; }
posts() { sk_state ".messages.${1}[] | select(.user == \"UBOT\") | [(.thread_ts // \"top\"), .text] | join(\" | \")"; }

# --- refusals before any poll -------------------------------------------------
BARE="$(sk_new_root bare)"
sk_poll "$BARE"
assert_eq "$RC=$ERR1" "2=slack: root-unbound=$BARE" "a root with no binding is refused"
mkdir -p "$SK_TMP/noorch" && git -C "$SK_TMP/noorch" init -q
sk_poll "$SK_TMP/noorch"
assert_eq "$RC=$ERR1" "2=slack: orch-missing=$SK_TMP/noorch" "a root with no lane-mail is refused"
sk_run -- listen --once
assert_eq "$RC=${ERR1%%=*}" "2=slack: usage" "listen with no --root is a usage refusal"

# --- owner text is a directive keyed channel:ts --------------------------------
ROOT="$(sk_new_root alpha)"
sk_bind "$ROOT"
TS1="$(sk_inject C001 U001 'Ship it today.')"
sk_poll "$ROOT"
assert_eq "$RC=$OUT" "0=slack: listening=1 poll_seconds=1
slack: delivered=ts=$TS1 id=$(jq -r --arg d "C001:$TS1" 'select(.delivery_id == $d) | .id' "$(sk_box "$ROOT")/to-lane.jsonl") path=catch-up" "a poll prints the listening and delivery lines and exits 0"
assert_eq "$(directives "$ROOT")" "C001:$TS1 Ship it today." "an owner's top-level message lands as a directive keyed channel:ts"
assert_eq "$(jq -r 'select(.t == "in") | [.kind, .ts, .thread] | join(" ")' "$(sk_journal "$ROOT")")" \
  "directive $TS1 $TS1" "the journal records the delivery by identifiers"
sk_poll "$ROOT"
assert_eq "$(directives "$ROOT" | wc -l | tr -d ' ')" "1" "a second poll delivers nothing twice"

# --- an ask: every reply answers, until the asker closes ---------------------
sk_lm "$ROOT" ask --item overseer --to owner --file "$(sk_text q 'Cut the scanner?')" --options cut,keep --recommend cut --wait 30 >"$SK_TMP/ask.out"
ASK="$(sed 's/^id=//' "$SK_TMP/ask.out")"
sk_poll "$ROOT"
ASK_TS="$(sk_state '.messages.C001[] | select(.text | startswith("<@U001> <@U002> Question")) | .ts')"
assert_has "$(sk_state ".messages.C001[] | select(.ts == \"$ASK_TS\") | .text")" \
  "Question from overseer:

Cut the scanner?

Options: cut, keep. Recommended: cut. It stands at " "the ask is posted with every owner mentioned, its options, recommendation and deadline, a blank line between its paragraphs"
assert_eq "$(sk_state ".messages.C001[] | select(.ts == \"$ASK_TS\") | .body_arg")" "markdown_text" "the ask is sent as markdown_text"
DEADLINE="$(jq -r "select(.id == \"$ASK\") | .deadline" "$(sk_box "$ROOT")/to-overseer.jsonl")"
DEADLINE_EPOCH="$(python3 -c 'import calendar, sys, time; print(calendar.timegm(time.strptime(sys.argv[1], "%Y-%m-%dT%H:%M:%SZ")))' "$DEADLINE")"
assert_has "$(sk_state ".messages.C001[] | select(.ts == \"$ASK_TS\") | .text")" \
  "It stands at <!date^$DEADLINE_EPOCH^{date_short_pretty} at {time}|$DEADLINE> unless you reply in this thread." \
  "the deadline is Slack's date token, shown in the owner's own time zone, the stamp its fallback"
sk_poll "$ROOT"
assert_eq "$(sk_state '[.messages.C001[] | select(.text | startswith("<@U001>"))] | length')" "1" "the ask is posted once"
R1="$(sk_inject C001 U002 'keep' "$ASK_TS")"
sk_poll "$ROOT"
assert_eq "$(answers "$ROOT")" "$ASK text C001:$R1 keep" "the first reply lands as an answer with its delivery id"
R2="$(sk_inject C001 U001 'and keep the tests' "$ASK_TS")"
sk_poll "$ROOT"
assert_eq "$(answers "$ROOT")" "$ASK text C001:$R1 keep
$ASK text C001:$R2 and keep the tests" "both replies land once as answers to the ask"
assert_eq "$(sk_reactions C001 "$R1") $(sk_reactions C001 "$R2")" "eyes eyes" "both answers get eyes"
assert_eq "$(sk_lm "$ROOT" pending --item overseer --to owner | jq -r '.id')" "$ASK" "an answered ask stays pending"
assert_eq "$(sk_state "[.messages.C001[] | select(.user == \"UBOT\" and .thread_ts == \"$ASK_TS\")] | length")" "0" "the relay posts no text in the ask's thread"
sk_poll "$ROOT"
assert_eq "$(answers "$ROOT" | wc -l | tr -d ' ')" "2" "a replay lands no extra answer"
sk_lm "$ROOT" resolve --item overseer --id "$ASK" >/dev/null
assert_eq "$(sk_lm "$ROOT" pending --item overseer --to owner)" "" "explicit resolve drops the answered ask"
sk_poll "$ROOT"
assert_eq "$(jq -c '.open_asks' "$ROOT/tmp/slack/status.json")" "[]" "explicit close leaves no open ask in relay status"
sk_poll "$ROOT"
assert_eq "$(jq -s --arg id "$ASK" '[.[] | select(.t == "resolved" and .id == $id)] | length' "$(sk_journal "$ROOT")")" "1" "restart consumes the close once"

# --- a chat answer and a deadline default appear in the thread ------------------
sk_lm "$ROOT" ask --item overseer --to owner --file "$(sk_text q2 'Merge now?')" --options yes,no --recommend no >"$SK_TMP/ask2.out"
ASK2="$(sed 's/^id=//' "$SK_TMP/ask2.out")"
sk_poll "$ROOT"
ASK2_TS="$(sk_state '.messages.C001[] | select(.text | contains("Merge now?")) | .ts')"
sk_lm "$ROOT" resolve --item overseer --id "$ASK2" --text "$(sk_text a2 'yes, after lunch')" >/dev/null
sk_poll "$ROOT"
assert_has "$(posts C001)" "$ASK2_TS | Answered in the chat: yes, after lunch" "an answer typed in the chat is shown in the ask's thread"
sk_lm "$ROOT" ask --item overseer --to owner --file "$(sk_text q3 'Rotate the key?')" --options yes,no --recommend yes >"$SK_TMP/ask3.out"
ASK3="$(sed 's/^id=//' "$SK_TMP/ask3.out")"
sk_poll "$ROOT"
ASK3_TS="$(sk_state '.messages.C001[] | select(.text | contains("Rotate the key?")) | .ts')"
sk_lm "$ROOT" resolve --item overseer --id "$ASK3" --default >/dev/null
sk_poll "$ROOT"
assert_has "$(posts C001)" "$ASK3_TS | No answer by the deadline: yes stands." "a default resolution is shown in the thread"
R3="$(sk_inject C001 U001 'too late' "$ASK3_TS")"
sk_poll "$ROOT"
assert_has "$(directives "$ROOT")" "C001:$R3 too late" "a reply after the default is a directive"
assert_eq "$(sk_lm "$ROOT" pending --item overseer --to owner | wc -l | tr -d ' ')" "0" "no ask is left open"

# --- a notice threads on its ref -----------------------------------------------
D1="$(jq -r 'select(.kind == "directive") | .id' "$(sk_box "$ROOT")/to-lane.jsonl" | sed -n '1p')"
sk_lm "$ROOT" notice --item overseer --to owner --ref "$D1" --file "$(sk_text n1 'Shipping.')" >/dev/null
sk_lm "$ROOT" notice --item overseer --to owner --file "$(sk_text n2 'Round done.')" >/dev/null
sk_poll "$ROOT"
assert_has "$(posts C001)" "$TS1 | Shipping." "a notice answering an owner note lands in that note's thread"
assert_has "$(posts C001)" "top | Round done." "a notice with no ref lands top-level"
assert_eq "$(sk_state '.messages.C001[] | select(.text == "Round done.") | .body_arg')" "markdown_text" "a notice is sent as markdown_text"
R0="$(sk_inject C001 U001 'and the docs' "$TS1")"
sk_poll "$ROOT"
D0="$(jq -r "select(.delivery_id == \"C001:$R0\") | .id" "$(sk_box "$ROOT")/to-lane.jsonl")"
sk_lm "$ROOT" notice --item overseer --to owner --ref "$D0" --file "$(sk_text n0 'Docs too.')" >/dev/null
sk_poll "$ROOT"
assert_has "$(posts C001)" "$TS1 | Docs too." "a notice answering an owner's reply in a thread lands in that thread"

# --- a report: uploaded with the notice as its comment, thread bound from the share
mkdir -p "$ROOT/tmp/progress-reports"
printf '# Progress\n\nAll green.\n' > "$ROOT/tmp/progress-reports/09-27-01-00.md"
sk_lm "$ROOT" notice --item overseer --to owner --attach "$ROOT/tmp/progress-reports/09-27-01-00.md" --file "$(sk_text n3 'Report: all green.')" >/dev/null
sk_poll "$ROOT"
assert_eq "$(sk_state '.uploads.F001')" "# Progress

All green." "the report file is uploaded whole"
SHARE_TS="$(sk_state '.messages.C001[] | select(.files != null) | .ts')"
assert_eq "$(sk_state ".messages.C001[] | select(.ts == \"$SHARE_TS\") | [.text, .files[0].id, .files[0].title] | join(\" \")")" \
  "Report: all green. F001 09-27-01-00.md" "the share carries the notice text as its comment"
sk_poll "$ROOT"
assert_eq "$(jq -r 'select(.t == "bound") | [.file, .ts] | join(" ")' "$(sk_journal "$ROOT")")" "F001 $SHARE_TS" \
  "the next poll binds the report's thread from the share message"
R4="$(sk_inject C001 U001 'good report' "$SHARE_TS")"
sk_poll "$ROOT"
assert_has "$(directives "$ROOT")" "C001:$R4 good report" "a reply under the report is a directive"

# --- a non-owner and an empty message: one reply each, nothing routed -------------
N1="$(sk_inject C001 U999 'let me in')"
F1="$(sk_inject C001 U001 '')"
sk_poll "$ROOT"
sk_poll "$ROOT"
assert_has "$(posts C001)" "$N1 | Only the channel's owners steer this session; this message is not routed." "a non-owner gets one reply"
assert_has "$(posts C001)" "$F1 | Only text and files are routed; this message has neither." "a message with no text and no file gets one reply"
assert_eq "$(sk_state '[.messages.C001[] | select(.text | startswith("Only"))] | length')" "2" "each is answered once"
assert_lacks "$(directives "$ROOT")" "$N1" "the non-owner's message is not routed"
assert_lacks "$(directives "$ROOT")" "$F1" "the empty message is not routed"
B1="$(sk_inject C001 U001 'broadcast' "$TS1" '"subtype": "thread_broadcast"')"
sk_event "$ROOT" C001 "$B1"
assert_eq "$(jq -s --arg d "C001:$B1" --arg ts "$TS1" '[.[] | select(.delivery_id == $d) | {text, thread_ts, parent_ts: .parent.ts}] == [{text:"broadcast", thread_ts:$ts, parent_ts:$ts}]' "$(sk_box "$ROOT")/to-lane.jsonl")" \
  "true" "an owner thread broadcast routes once with its thread pointer"
B2="$(sk_inject C001 U999 'non-owner broadcast' "$TS1" '"subtype": "thread_broadcast"')"
sk_event "$ROOT" C001 "$B2"
assert_eq "$(jq -s --arg d "C001:$B2" '[.[] | select(.delivery_id == $d)] | length' "$(sk_box "$ROOT")/to-lane.jsonl")|$(sk_state '.messages.C001[-1].text')" \
  "0|Only the channel's owners steer this session; this message is not routed." "a non-owner thread broadcast receives NOT_OWNER and no directive"

# --- an owner's files: saved under tmp/slack/files, each named in the envelope -------
text_of() { jq -r --arg d "$2" 'select(.delivery_id == $d) | .text' "$(sk_box "$1")/to-lane.jsonl"; } # ROOT DELIVERY_ID
FILES_DIR="$ROOT/tmp/slack/files"
FM1="$(sk_inject C001 U001 'get this error, why' '' "\"files\": [$(sk_file F901 'shots/shot one.png' image/png 'png bytes one'), $(sk_file F902 err.log text/plain 'log line two')]")"
sk_poll "$ROOT"
assert_eq "$RC=$(text_of "$ROOT" "C001:$FM1")" "0=get this error, why
$FILES_DIR/F901-shots_shot_one.png
$FILES_DIR/F902-err.log" "an owner's message lands with the saved path of each file, one line each, the name made one path component"
assert_eq "$(cat "$FILES_DIR/F901-shots_shot_one.png")|$(cat "$FILES_DIR/F902-err.log")" "png bytes one|log line two" \
  "each saved file holds the bytes Slack served"
assert_eq "$(sk_mode "$FILES_DIR") $(sk_mode "$FILES_DIR/F901-shots_shot_one.png")" "700 600" "the directory is 700 and each file 600"
sk_ctl /_test/fault '{"method": "download", "status": 403}' >/dev/null
sk_ctl /_test/fault '{"method": "download", "signin": true, "times": 2}' >/dev/null
FM2="$(sk_inject C001 U001 'and this one' '' "\"files\": [$(sk_file F903 a.png image/png 'x')]")"
FM3="$(sk_inject C001 U001 '' '' "\"files\": [$(sk_file F904 b.png image/png 'y')]")"
FM4="$(sk_inject C001 U001 '' '' '"files": [{"id": "F777"}]')"
FM9="$(sk_inject C001 U001 '' '' "\"files\": [$(sk_file F910 own.html text/html '<p>own</p>')]")"
sk_poll "$ROOT"
assert_eq "$RC=$(text_of "$ROOT" "C001:$FM2")" "0=and this one
file F903 not fetched: HTTP 403" "a refused download lands the message with the file id and the HTTP status"
assert_eq "$(text_of "$ROOT" "C001:$FM3")" "file F904 not fetched: HTTP 200 sign-in page, the app needs files:read" \
  "Slack's sign-in page in place of a file names files:read, and a file with no text lands"
assert_eq "$(text_of "$ROOT" "C001:$FM4")" "file F777 not fetched: no download url" "a file Slack sends with no download url lands as its id"
assert_eq "$(text_of "$ROOT" "C001:$FM9")" "file F910 not fetched: HTTP 200 sign-in page, the app needs files:read" \
  "the sign-in page in place of an HTML file is refused by its size, not its type"
FM5="$(sk_inject C001 U001 '' '' "\"files\": [$(sk_file F905 page.html text/html '<p>owner page</p>')]")"
FM6="$(sk_inject C001 U001 '' '' "\"files\": [$(sk_file F906 "$(python3 -c 'print("n" * 300 + ".txt")')" text/plain 'long')]")"
sk_poll "$ROOT"
assert_eq "$(text_of "$ROOT" "C001:$FM5")|$(cat "$FILES_DIR/F905-page.html")" "$FILES_DIR/F905-page.html|<p>owner page</p>" \
  "an HTML file the owner sent is saved, not read as the sign-in page"
LONG_SAVED="$(text_of "$ROOT" "C001:$FM6")"
LONG_BASE="${LONG_SAVED##*/}"
assert_eq "${LONG_SAVED%/*}|${#LONG_BASE}|${LONG_BASE:0:8}|$(cat "$LONG_SAVED")" "$FILES_DIR|200|F906-nnn|long" \
  "a name past the file-name limit is cut to 200 characters, the file id first"
sk_ctl /_test/fault '{"method": "download", "cut": "length"}' >/dev/null
sk_ctl /_test/fault '{"method": "download", "cut": "chunked"}' >/dev/null
FM7="$(sk_inject C001 U001 'cut short' '' "\"files\": [$(sk_file F907 g.png image/png 'cut bytes one'), $(sk_file F908 h.png image/png 'cut bytes two')]")"
sk_poll "$ROOT"
FM7_TEXT="$(text_of "$ROOT" "C001:$FM7")"
assert_eq "$RC=$(sed -n '1,2p' <<<"$FM7_TEXT")" "0=cut short
file F907 not fetched: truncated 6 of 13 bytes" "a body short of its Content-Length is not saved, and its line counts the bytes"
assert_has "$(sed -n '3p' <<<"$FM7_TEXT")" "file F908 not fetched: download (IncompleteRead(" \
  "a chunked body cut short is not saved, and the relay goes on"
sk_ctl /_test/fault '{"method": "download", "chunked": true}' >/dev/null
FM8="$(sk_inject C001 U001 '' '' "\"files\": [$(sk_file F909 k.png image/png 'chunked bytes')]")"
sk_poll "$ROOT"
assert_eq "$RC=$(text_of "$ROOT" "C001:$FM8")|$(cat "$FILES_DIR/F909-k.png")" "0=$FILES_DIR/F909-k.png|chunked bytes" \
  "a whole chunked body with no Content-Length is saved with the bytes Slack served"
assert_eq "$(ls -A "$FILES_DIR" | sed 's/^F906-n*$/F906-long/' | tr '\n' ' ')" "F901-shots_shot_one.png F902-err.log F905-page.html F906-long F909-k.png " \
  "a download that failed or was cut leaves no file behind"

# --- catch-up over pages -------------------------------------------------------------
for n in 1 2 3 4 5; do sk_inject C001 U001 "note $n" >/dev/null; done
sk_poll "$ROOT"
assert_eq "$(directives "$ROOT" | sed -n 's/^C001:[0-9.]* \(note [0-9]\)$/\1/p' | tr '\n' ',')" "note 1,note 2,note 3,note 4,note 5," \
  "five messages over three pages land once each, in order"

# --- the crash between the mailbox append and the journal mark -----------------------
crash_gap() { # ROOT — the mark of the last delivery lost, the owner writes, the relay restarts
  local root="$1" m1 m2 channel
  channel="$(sk_channel "$1")"
  m1="$(sk_inject "$channel" U001 'before the crash')"
  sk_poll "$root"
  grep -v "\"ts\": \"$m1\"" "$(sk_journal "$root")" > "$SK_TMP/journal.cut"
  cp "$SK_TMP/journal.cut" "$(sk_journal "$root")"
  m2="$(sk_inject "$channel" U001 'during the gap')"
  sk_poll "$root"
  GAP_COUNT="$(directives "$root" | grep -cE "before the crash|during the gap")"
  GAP_ID_BEFORE="$(jq -r 'select(.kind == "directive" and .text == "before the crash") | .id' "$(sk_box "$root")/to-lane.jsonl")"
  GAP_ID_JOURNAL="$(jq -r "select(.t == \"in\" and .ts == \"$m1\") | .id" "$(sk_journal "$root")")"
}
crash_gap "$ROOT"
assert_eq "$GAP_COUNT" "2" "each note arrives once across the crash"
assert_eq "$GAP_ID_JOURNAL" "$GAP_ID_BEFORE" "the replayed delivery is journaled under the envelope that landed first"

# --- a second relay on the same checkout is refused ------------------------------------
sk_relay_start "$ROOT"
sk_poll "$ROOT"
assert_eq "$RC=${ERR1%% pid=*}" "2=slack: relay-running=$ROOT" "a second relay on the checkout is refused by the lock"
sk_relay_stop

# --- reconnect catch-up does not re-read a thread past SLACK_THREAD_DAYS ---------------
GAMMA="$(sk_new_root gamma)"
sk_bind "$GAMMA"
OLD_TS="$(python3 -c 'import time; print("%.6f" % (time.time() - 8 * 86400))')"
sk_rebind_at "$GAMMA" "$(python3 -c 'import time; print("%.6f" % (time.time() - 9 * 86400))')"
OLD="$(sk_inject C002 U001 'an old topic' '' "\"ts\": \"$OLD_TS\"")"
sk_inject C002 U001 'reply under the old one' "$OLD" >/dev/null
YOUNG="$(sk_inject C002 U001 'a young topic')"
sk_poll "$GAMMA"
assert_eq "$(directives "$GAMMA" | wc -l | tr -d ' ')" "2" \
  "both topics land as directives, and the reply under the thread past SLACK_THREAD_DAYS, read in the same history, is not routed"
YR="$(sk_inject C002 U001 'reply under the young one' "$YOUNG")"
sk_poll "$GAMMA"
assert_eq "$(directives "$GAMMA" | sed -n '3p')" "C002:$YR reply under the young one" "the history read routes the reply under the young thread"
assert_eq "$(directives "$GAMMA" | wc -l | tr -d ' ')" "3" "the reply under the old thread stays unrouted"

# --- a secret value is refused, journaled, never posted --------------------------------
sk_lm "$GAMMA" notice --item overseer --to owner --file "$(sk_text s1 'token xoxb-0123456789-abcdefghij')" >/dev/null
sk_poll "$GAMMA"
SECRET_ID="$(jq -r 'select(.kind == "notice") | .id' "$(sk_box "$GAMMA")/to-overseer.jsonl")"
assert_eq "$RC=$(sed -n '/^slack: secret-value=/p' <<<"$ERR")" "0=slack: secret-value=id=$SECRET_ID" "a notice matching the secret-value pattern is refused by id"
assert_eq "$(sk_state '[.messages.C002[] | select(.text | contains("xoxb"))] | length')" "0" "nothing matching the pattern is posted"
assert_eq "$(jq -r "select(.t == \"out\" and .id == \"$SECRET_ID\") | .state" "$(sk_journal "$GAMMA")")" "refused" "the refusal is journaled"
refused_line() { jq -r "select(.t == \"out\" and .id == \"$2\" and .state != \"inflight\") | [.state, .reason] | join(\" \")" "$(sk_journal "$1")"; } # ROOT ID
notice_id() { jq -r "select(.text == \"$2\") | .id" "$(sk_box "$1")/to-overseer.jsonl"; } # ROOT TEXT
mkdir -p "$GAMMA/tmp/progress-reports"
LEAK="$GAMMA/tmp/progress-reports/leak.md"
printf 'ghp_%s\n' "abcdefghijklmnopqrstuvwxyz0123456789" > "$LEAK"
sk_lm "$GAMMA" notice --item overseer --to owner --attach "$LEAK" --file "$(sk_text s3 'Clean report.')" >/dev/null
sk_poll "$GAMMA"
LEAK_ID="$(notice_id "$GAMMA" 'Clean report.')"
assert_eq "$RC=$(sed -n '/^slack: secret-value=/p' <<<"$ERR")" "0=slack: secret-value=id=$LEAK_ID file=$LEAK" "a report whose file matches the pattern is refused by id and file"
assert_eq "$(refused_line "$GAMMA" "$LEAK_ID")" "refused secret-value" "the file's refusal is journaled"
assert_eq "$(sk_state '[.uploads[] | select(contains("ghp_"))] | length')" "0" "nothing matching the pattern is uploaded"
GONE="$GAMMA/tmp/progress-reports/gone.md"
printf '# Gone\n' > "$GONE"
sk_lm "$GAMMA" notice --item overseer --to owner --attach "$GONE" --file "$(sk_text s4 'Missing report.')" >/dev/null
rm -f -- "${GONE:?}"
sk_poll "$GAMMA"
assert_eq "$RC=$ERR1" "0=slack: file-unreadable=$GONE" "a report whose file is gone is refused"
assert_eq "$(refused_line "$GAMMA" "$(notice_id "$GAMMA" 'Missing report.')")" "refused file-unreadable" "the unreadable file is journaled refused"
LONG="$(python3 -c 'print("x" * 12001)')"
sk_lm "$GAMMA" notice --item overseer --to owner --file "$(sk_text s5 "$LONG")" >/dev/null
sk_poll "$GAMMA"
LONG_ID="$(notice_id "$GAMMA" "$LONG")"
assert_eq "$RC=$(refused_line "$GAMMA" "$LONG_ID")=$(sk_state '[.messages.C002[] | select(.text | startswith("xxxx")) | .body_arg] | join(" ")')" \
  "0=resolved =text" "a notice past the markdown_text cap lands whole as text, Slack's mrkdwn, and is not journaled refused"
sk_lm "$GAMMA" ask --item overseer --to owner --file "$(sk_text s7 "q$LONG")" --options a,b --recommend a >"$SK_TMP/ask-long.out"
LONG_ASK="$(sed 's/^id=//' "$SK_TMP/ask-long.out")"
sk_poll "$GAMMA"
assert_eq "$RC=$(jq -r "select(.t == \"out\" and .id == \"$LONG_ASK\" and .state != \"inflight\") | .state" "$(sk_journal "$GAMMA")")=$(sk_state '[.messages.C002[] | select(.text | contains("qxxxx")) | [.body_arg, (.text | contains("xxxx\n\nOptions: a, b. Recommended: a.") | tostring)] | join(" ")] | join(",")')" \
  "0=open=text true" "an ask past the cap lands as text with its options tail and stands open"
LONG_REPORT="$GAMMA/tmp/progress-reports/long.md"
printf '# Long\n' > "$LONG_REPORT"
UPLOADS="$(sk_state '.uploads | length')"
sk_lm "$GAMMA" notice --item overseer --to owner --attach "$LONG_REPORT" --file "$(sk_text s6 "y$LONG")" >/dev/null
sk_poll "$GAMMA"
LONG_FILE_ID="$(notice_id "$GAMMA" "y$LONG")"
assert_eq "$RC=$(jq -r "select(.t == \"out\" and .id == \"$LONG_FILE_ID\" and .state != \"inflight\") | .state" "$(sk_journal "$GAMMA")")=$(sk_state '.uploads | length')" \
  "0=file=$((UPLOADS + 1))" "a notice past the cap beside a report uploads with it as the comment, the cap being markdown_text's alone"

# --- a 429 is honoured by Retry-After -------------------------------------------------------
history_calls() { sk_state '[.calls[] | select(. == "conversations.history")] | length'; }
sk_ctl /_test/calls-reset >/dev/null
sk_ctl /_test/fault '{"method": "conversations.history", "status": 429, "retry_after": 0, "times": 1}' >/dev/null
L1="$(sk_inject C002 U001 'after the limit')"
sk_poll "$GAMMA"
LIMITED_RC="$RC" LIMITED_CALLS="$(history_calls)"
sk_ctl /_test/calls-reset >/dev/null
sk_poll "$GAMMA"
assert_eq "$LIMITED_RC=$LIMITED_CALLS" "0=$(($(history_calls) + 1))" "a 429 is retried after Retry-After: one history call more than the same read unrefused"
assert_eq "$(directives "$GAMMA" | sed -n '4p')" "C002:$L1 after the limit" "the message behind the 429 lands"

# --- owners re-resolved from the setting before delivery -----------------------------------
sk_poll "$GAMMA" SLACK_OWNERS="$OWNER"
assert_eq "$(jq -r '[(.owners | join(",")), (.owner_ids | keys | join(","))] | join(" ")' "$GAMMA/tmp/slack/binding.json")" \
  "$OWNER $OWNER" "a changed SLACK_OWNERS rewrites the binding's owners and ids"
X1="$(sk_inject C002 U002 'still me?')"
sk_poll "$GAMMA" SLACK_OWNERS="$OWNER"
assert_has "$(posts C002)" "$X1 | Only the channel's owners steer this session" "a removed owner loses routing at that poll"

# --- a post Slack refuses fails the poll and is made again on the next -----------------------
sk_lm "$GAMMA" ask --item overseer --to owner --file "$(sk_text q5 'Refused once?')" --options a,b --recommend a >"$SK_TMP/ask5.out"
ASK5="$(sed 's/^id=//' "$SK_TMP/ask5.out")"
sk_ctl /_test/fault '{"method": "chat.postMessage", "error": "not_in_channel", "times": 1}' >/dev/null
sk_poll "$GAMMA"
assert_eq "$RC=$ERR1" "1=slack: slack-api-failed=chat.postMessage error=not_in_channel id=$ASK5 root=$GAMMA" \
  "a post Slack refuses fails the poll, naming the error and the envelope"
assert_eq "$(jq -r '.last_poll_ok' "$GAMMA/tmp/slack/status.json")" "false" "the status record reads the poll as failed"
sk_run -- listen --status --root "$GAMMA"
assert_has "$(printf '%s' "$OUT" | sed -n '1p')" " state=failing " "the doctor row reads failing"
assert_has "$(printf '%s' "$OUT" | sed -n '1p')" " fix=slack-api-failed=chat.postMessage error=not_in_channel id=$ASK5" \
  "the row's fix names the Slack error and the envelope"
assert_eq "$(jq -r "select(.t == \"out\" and .id == \"$ASK5\") | .state" "$(sk_journal "$GAMMA")" | wc -l | tr -d ' ')" "2" \
  "the refused post records its in-flight and retry lines"
sk_poll "$GAMMA"
assert_eq "$RC=$(asks C002 'Refused once?')" "0=1" "the next poll posts the ask and exits 0"

# --- a post the network refused is made again; a lost response is journaled unknown ----------
sk_lm "$GAMMA" ask --item overseer --to owner --file "$(sk_text q6 'Refused connection?')" --options a,b --recommend a >"$SK_TMP/ask6.out"
ASK6="$(sed 's/^id=//' "$SK_TMP/ask6.out")"
sk_ctl /_test/fault '{"method": "chat.postMessage", "refuse": true, "times": 1}' >/dev/null
sk_poll "$GAMMA"
assert_eq "$RC=${ERR1%% *}" "1=slack:" "a refused connection fails the poll"
# The reserved non-listening port can time out on macOS. The transport key,
# envelope and root are the contract, not the operating system's error text.
assert_eq "${ERR1%% (*}|${ERR1##*)}" "slack: slack-unreachable=chat.postMessage| id=$ASK6 root=$GAMMA" \
  "the unsent request has the unreachable key, naming the envelope and root"
assert_eq "$(jq -r "select(.t == \"out\" and .id == \"$ASK6\") | .state" "$(sk_journal "$GAMMA")" | wc -l | tr -d ' ')" "2" \
  "a request Slack never received records its in-flight and retry lines"
sk_poll "$GAMMA"
assert_eq "$RC=$(asks C002 'Refused connection?')" "0=1" "the next poll posts the ask"
sk_lm "$GAMMA" ask --item overseer --to owner --file "$(sk_text q7 'Lost response?')" --options a,b --recommend a >"$SK_TMP/ask7.out"
ASK7="$(sed 's/^id=//' "$SK_TMP/ask7.out")"
sk_ctl /_test/fault '{"method": "chat.postMessage", "drop": true, "times": 1}' >/dev/null
sk_poll "$GAMMA"
assert_eq "$RC=${ERR1%%=*}" "0=slack: slack-response-lost" "a dropped response is reported and the poll goes on"
assert_eq "$(jq -r "select(.t == \"out\" and .id == \"$ASK7\" and .state != \"inflight\") | .state" "$(sk_journal "$GAMMA")")" "unknown" "the lost response is journaled unknown"
sk_poll "$GAMMA"
assert_eq "$(asks C002 'Lost response?')" "0" "an unknown post is never repeated"
sk_run -- listen --status --root "$GAMMA"
assert_has "$(printf '%s' "$OUT" | sed -n '1p')" " oldest_unknown=$ASK7 " "the doctor row names the oldest unknown post"

# --- a refused history read fails the poll ---------------------------------------------------------
sk_ctl /_test/fault '{"method": "conversations.history", "error": "channel_not_found", "times": 1}' >/dev/null
sk_poll "$GAMMA"
assert_eq "$RC=$ERR1=$(jq -r '.last_poll_ok' "$GAMMA/tmp/slack/status.json")" \
  "1=slack: slack-api-failed=conversations.history error=channel_not_found root=$GAMMA=false" "a refused history read fails the poll and its record"
sk_poll "$GAMMA"
assert_eq "$RC=$(jq -r '.last_poll_ok' "$GAMMA/tmp/slack/status.json")" "0=true" "the next poll succeeds"

# --- a first start: Slack from the binding moment, the mailbox from its newest envelope -----------
for n in 1 2 3; do sk_inject C777 U001 "history $n" >/dev/null; done
PRE_PARENT="$(sk_inject C777 U001 'An adopted topic.')"
PRE_REPLY="$(sk_inject C777 U001 'A reply before binding.' "$PRE_PARENT")"
DELTA="$(sk_new_root delta)"
sk_lm "$DELTA" notice --item overseer --to owner --file "$(sk_text n5 'Old notice.')" >/dev/null
mkdir -p "$DELTA/tmp/progress-reports"
printf '# Old report\n' > "$DELTA/tmp/progress-reports/old.md"
sk_lm "$DELTA" notice --item overseer --to owner --attach "$DELTA/tmp/progress-reports/old.md" --file "$(sk_text n6 'Old report.')" >/dev/null
sk_lm "$DELTA" ask --item overseer --to owner --file "$(sk_text q8 'Still open?')" --options a,b --recommend a >/dev/null
sk_run -- setup --root "$DELTA" --take C777
assert_eq "$RC" 0 "a channel with history is adopted"
sk_poll "$DELTA"
assert_eq "$(asks C777 'Old notice.')=$(asks C777 'Old report.')=$(asks C777 'Still open?')" "0=0=1" \
  "the mailbox's past notices and report are not posted; its open ask is"
assert_eq "$(jq -r 'select(.t == "start") | .at' "$(sk_journal "$DELTA")" | wc -l | tr -d ' ')" "1" "the start is journaled"
H4="$(sk_inject C777 U001 'history 4')"
sk_lm "$DELTA" notice --item overseer --to owner --file "$(sk_text n7 'New notice.')" >/dev/null
sk_poll "$DELTA"
assert_eq "$(directives "$DELTA" | tail -n 1)" "C777:$H4 history 4" "the next message is routed"
assert_eq "$(asks C777 'New notice.')" "1" "a notice written after the start is posted"

# --- an external parent missed during disconnect is discovered by catch-up ------
for mode in production control; do
  DISCOVERY="$(sk_new_root "discovery-$mode")"
  sk_bind "$DISCOVERY"
  DISCOVERY_CH="$(sk_channel "$DISCOVERY")"
  sk_poll "$DISCOVERY"
  sk_run -- post --root "$DISCOVERY" --text 'An external topic.'
  assert_eq "$RC" 0 "$mode: slack post creates the external parent"
  DISCOVERY_PARENT="$(sk_state ".messages.${DISCOVERY_CH}[-1].ts")"
  DISCOVERY_REPLY="$(sk_inject "$DISCOVERY_CH" U001 'Missed while disconnected.' "$DISCOVERY_PARENT")"
  if [ "$mode" = control ]; then
    sk_mutant discovery relay.py 'if thread_ts not in self\.state\.threads:' 'if thread_ts not in self.state.threads and False:'
  fi
  sk_poll "$DISCOVERY"
  if [ -f "$(sk_box "$DISCOVERY")/to-lane.jsonl" ]; then
    DISCOVERED="$(jq -s --arg d "$DISCOVERY_CH:$DISCOVERY_REPLY" --arg ts "$DISCOVERY_PARENT" \
      '[.[] | select(.delivery_id == $d and .text == "Missed while disconnected." and .thread_ts == $ts and .parent == {ts:$ts,author:"bot",excerpt:"An external topic."})] | length' "$(sk_box "$DISCOVERY")/to-lane.jsonl")"
  else
    DISCOVERED=0
  fi
  if [ "$mode" = control ]; then
    sk_assert_red "$RC=$DISCOVERED" '0=1' 'control: disabled external-parent discovery breaks reply delivery'
  else
    assert_eq "$RC=$DISCOVERED" '0=1' 'catch-up discovers an unknown external parent and carries the reply pointer'
  fi
  sk_bin_reset
done

# --- a notice under an owner message past the horizon posts once across compaction --------------------
# A fresh notice keeps the old message's thread live through compaction.
OLD_NOTE="$(jq -r 'select(.kind == "directive" and .text == "an old topic") | .id' "$(sk_box "$GAMMA")/to-lane.jsonl")"
sk_lm "$GAMMA" notice --item overseer --to owner --ref "$OLD_NOTE" --file "$(sk_text n11 'Late ruling.')" >/dev/null
sk_poll "$GAMMA"
sk_run -- compact --root "$GAMMA"
sk_poll "$GAMMA"
assert_eq "$RC=$(asks C002 'Late ruling.')" "0=1" "a notice under an owner message past the horizon posts once across compaction"
assert_has "$(posts C002)" "$OLD | Late ruling." "it lands in that message's thread"

# Bind these roots after gamma, whose cases use the fake API's C002 channel.
# Closures first observed after the posting horizon still update state.
# Legacy rows model the retained pre-1.3 resolve producer.
while read -r mode close; do
  LATE="$(sk_new_root "late-$mode-$close")"
  sk_bind "$LATE"
  sk_lm "$LATE" ask --item overseer --to owner --file "$(sk_text late 'Late close?')" --options a,b --recommend a >"$SK_TMP/late.out"
  LATE_ASK="$(sed 's/^id=//' "$SK_TMP/late.out")"
  sk_poll "$LATE"
  LATE_CH="$(sk_channel "$LATE")"
  LATE_TS="$(sk_state ".messages.${LATE_CH}[-1].ts")"
  assert_eq "$(jq -c .open_asks "$LATE/tmp/slack/status.json")" "[\"$LATE_ASK\"]" "$mode/$close: the posted ask is open before closure"
  args=(--item overseer --id "$LATE_ASK")
  case "$close" in
    text) args+=(--text "$(sk_text late-answer b)") ;;
    default) args+=(--default) ;;
  esac
  sk_lm "$LATE" resolve "${args[@]}" >/dev/null
  if [ "$mode" = legacy ]; then
    jq -c 'select(.kind != "resolution") | del(.closes)' "$(sk_box "$LATE")/to-lane.jsonl" >"$SK_TMP/legacy-close.jsonl"
    cp "$SK_TMP/legacy-close.jsonl" "$(sk_box "$LATE")/to-lane.jsonl"
  fi
  LATE_CLOSE="$(jq -r 'select(.kind == "resolution" or .kind == "answer") | .id' "$(sk_box "$LATE")/to-lane.jsonl" | tail -n 1)"
  sk_age_envelope "$LATE" "$LATE_CLOSE" 172800
  sk_poll "$LATE" SLACK_THREAD_DAYS=1
  assert_eq "$(jq -c .open_asks "$LATE/tmp/slack/status.json")" "[]" "$mode/$close: late first observation closes relay state"
  sk_poll "$LATE" SLACK_THREAD_DAYS=1
  sk_run SLACK_THREAD_DAYS=1 -- compact --root "$LATE"
  sk_poll "$LATE" SLACK_THREAD_DAYS=1
  assert_eq "$(jq -s --arg source "$LATE_CLOSE" '[.[] | select(.t == "resolved" and .source == $source)] | length' "$(sk_journal "$LATE")")" "1" "$mode/$close: restart and compaction retain closure consumption"
  LATE_REPLY="$(sk_inject "$LATE_CH" U001 'after close' "$LATE_TS")"
  sk_poll "$LATE" SLACK_THREAD_DAYS=1
  assert_has "$(directives "$LATE")" "$LATE_CH:$LATE_REPLY after close" "$mode/$close: the retained close routes a later reply as a directive"
done <<'ROWS'
current explicit
current default
legacy text
legacy default
ROWS

# --- daily compaction: envelope age and thread activity are separate ------------------
# Each old owner root is read, so an unread receipt cannot keep it alive.
# The controls use the same cases: bypass the age gate on an unposted notice,
# or drop an aged post despite recent activity in its thread.
# CASE AGE POSTED RECENT_REPLY MUTANT OUTCOMES ROOT_LINES POSTS
while read -r name age posted active mutant want_out want_root want_posts; do
  RET="$(sk_new_root "retention-$name")"
  sk_bind "$RET"
  RET_CH="$(sk_channel "$RET")"
  sk_poll "$RET"
  RET_TS="$(sk_inject "$RET_CH" U001 'Old retention topic.' '' "\"ts\": \"$OLD_TS\"")"
  sk_event "$RET" "$RET_CH" "$RET_TS"
  RET_ID="$(jq -r --arg d "$RET_CH:$RET_TS" 'select(.delivery_id == $d) | .id' "$(sk_box "$RET")/to-lane.jsonl")"
  sk_lm "$RET" inbox --item overseer >/dev/null
  sk_poll "$RET"
  sk_lm "$RET" notice --item overseer --to owner --ref "$RET_ID" --file "$(sk_text "retention-$name" 'Retention ruling.')" >/dev/null
  NOTE_ID="$(notice_id "$RET" 'Retention ruling.')"
  if [ "$posted" = 1 ]; then sk_poll "$RET"; fi
  if [ "$age" = old ]; then
    sk_age_envelope "$RET" "$NOTE_ID" $((8 * 86400))
    NOTE_AT="$(jq -r --arg id "$NOTE_ID" 'select(.id == $id) | .at' "$(sk_box "$RET")/to-overseer.jsonl")"
    jq -c --arg id "$NOTE_ID" --arg at "$NOTE_AT" 'if .t == "out" and .id == $id then .at = $at else . end' "$(sk_journal "$RET")" > "$SK_TMP/aged.jsonl" \
      && cp "$SK_TMP/aged.jsonl" "$(sk_journal "$RET")"
  fi
  if [ "$active" = 1 ]; then
    RET_REPLY="$(sk_inject "$RET_CH" U001 'Continue the retention topic.' "$RET_TS")"
    sk_event "$RET" "$RET_CH" "$RET_REPLY"
    sk_lm "$RET" inbox --item overseer >/dev/null
    sk_poll "$RET"
  fi
  case "$mutant" in
    none) ;;
    horizon) sk_mutant envelope-horizon relay.py 'elif at < horizon:' 'elif at < horizon and False:' ;;
    retain) sk_mutant out-retention store.py 'drop = str\(line\["thread"\]\) not in live' 'drop = True' ;;
    *) printf 'unknown retention mutant: %s\n' "$mutant" >&2; exit 1 ;;
  esac
  jq '.compacted_day = "2000-01-01"' "$RET/tmp/slack/status.json" > "$SK_TMP/day.json" && cp "$SK_TMP/day.json" "$RET/tmp/slack/status.json"
  sk_poll "$RET"
  assert_eq "$RC=$(jq -s --arg id "$NOTE_ID" '[.[] | select(.t == "out" and .id == $id and .state != "inflight")] | length' "$(sk_journal "$RET")")=$(jq -s --arg id "$RET_ID" '[.[] | select(.t == "in" and .id == $id)] | length' "$(sk_journal "$RET")")=$(asks "$RET_CH" 'Retention ruling.')" \
    "0=$want_out=$want_root=$want_posts" "daily compaction: $name (post record, owner root, Slack posts)"
  if [ "$name" = aged-post-inactive-thread ]; then
    assert_eq "$(jq -s --arg id "$NOTE_ID" '[.[] | select(.t == "out" and .id == $id and .state == "inflight")] | length' "$(sk_journal "$RET")")" 0 'daily compaction drops the aged inactive post pre-send record with its outcome'
  fi
  sk_bin_reset
done <<'ROWS'
young-post-old-root young 1 0 none 1 1 1
aged-post-live-thread old 1 1 none 1 1 1
aged-post-inactive-thread old 1 0 none 0 0 1
aged-unposted-envelope old 0 0 none 0 0 0
control-envelope-horizon old 0 0 horizon 1 0 1
control-live-thread-retention old 1 1 retain 0 1 1
ROWS

# --- a journal reset re-posts open asks alone ----------------------------------------------------------
mv "$(sk_journal "$DELTA")" "$SK_TMP/delta-journal.aside"
sk_poll "$DELTA"
assert_eq "$RC=$(asks C777 'New notice.')=$(asks C777 'Old notice.')" "0=1=0" "after the journal is moved aside no notice is posted again"
assert_eq "$(asks C777 'Still open?')" "2" "the open ask is posted once more, so its thread is bound again"
assert_eq "$(directives "$DELTA" | wc -l | tr -d ' ')" "1" "the re-read channel lands nothing twice"

# --- two roots bound to one channel are refused at start ---------------------------------------
# Two checkouts with one directory name get one default channel name, so
# the second setup finds and binds the first one's channel.
PAIR_A="$(sk_new_root pair-a/omega)"
PAIR_B="$(sk_new_root pair-b/omega)"
sk_bind "$PAIR_A"
sk_bind "$PAIR_B"
PAIR_CH="$(sk_channel "$PAIR_A")"
sk_run -- listen --root "$PAIR_A" --root "$PAIR_B" --once
assert_eq "$RC=$ERR1" "2=slack: channel-shared=$PAIR_CH roots=$PAIR_A,$PAIR_B fix=run \`slack setup --name NAME\` in one of them" \
  "two roots on one channel are refused, naming both and the channel"
assert_eq "$([ -e "$(sk_journal "$PAIR_A")" ] || [ -e "$(sk_journal "$PAIR_B")" ] && echo polled || echo untouched)" "untouched" \
  "the refusal comes before any poll"

# --- receipt marks: eyes once a directive lands, a check once the overseer reads it ---
IOTA="$(sk_new_root iota)"
sk_bind "$IOTA"
IOTA_CH="$(sk_channel "$IOTA")"
M1="$(sk_inject "$IOTA_CH" U001 'first note')"
M2="$(sk_inject "$IOTA_CH" U001 'second note')"
sk_poll "$IOTA"
assert_eq "$RC $(sk_reactions "$IOTA_CH" "$M1") $(sk_reactions "$IOTA_CH" "$M2")" "0 eyes eyes" "each directive's message is marked eyes in the poll that lands it"
sk_lm "$IOTA" inbox --item overseer --ack 1 >/dev/null
sk_poll "$IOTA"
assert_eq "$(sk_reactions "$IOTA_CH" "$M1") $(sk_reactions "$IOTA_CH" "$M2")" "white_check_mark eyes" \
  "the directive the cursor passed swaps eyes for a check; the unread one keeps eyes"
sk_lm "$IOTA" inbox --item overseer >/dev/null
sk_poll "$IOTA"
assert_eq "$(sk_reactions "$IOTA_CH" "$M2")" "white_check_mark" "an inbox read swaps the rest"
sk_ctl /_test/fault '{"method": "reactions.add", "error": "missing_scope"}' >/dev/null
M3="$(sk_inject "$IOTA_CH" U001 'third note')"
M3_NEXT="$(sk_inject "$IOTA_CH" U001 'after third note')"
sk_ctl /_test/calls-reset >/dev/null
sk_poll "$IOTA"
assert_eq "$RC=$ERR1" "0=slack: slack-api-failed=reactions.add error=missing_scope" "a mark Slack refuses is printed and fails no poll"
assert_eq "$(text_of "$IOTA" "$IOTA_CH:$M3")|$(sk_reactions "$IOTA_CH" "$M3")|$(jq -r "select(.t == \"mark\" and .ts == \"$M3\") | .name" "$(sk_journal "$IOTA")")" \
  "third note||" "the directive lands unmarked and no mark is journaled"
assert_eq "$(sk_reactions "$IOTA_CH" "$M3_NEXT")|$(sk_state '[.calls[] | select(. == "reactions.add")] | length')" "eyes|2" "each new delivery attempts eyes once, even after a refusal"
sk_ctl /_test/calls-reset >/dev/null
sk_ctl /_test/fault '{"method": "reactions.add", "error": "missing_scope"}' >/dev/null
sk_poll "$IOTA"
assert_eq "$(sk_reactions "$IOTA_CH" "$M3")|$(sk_state '[.calls[] | select(. == "reactions.add")] | length')" "|1" "a previously refused delivery gets one retry in a later poll"
sk_poll "$IOTA"
assert_eq "$RC $(sk_reactions "$IOTA_CH" "$M3")" "0 eyes" "the next poll makes the mark Slack refused"
sk_lm "$IOTA" inbox --item overseer >/dev/null
M4="$(sk_inject "$IOTA_CH" U001 'fourth note')"
sk_poll "$IOTA"
sk_lm "$IOTA" inbox --item overseer >/dev/null
sk_ctl /_test/fault '{"method": "reactions.add", "error": "internal_error"}' >/dev/null
sk_poll "$IOTA"
assert_eq "$RC $(sk_reactions "$IOTA_CH" "$M4")" "0 " "a swap whose check Slack refused leaves the message unmarked for that poll"
sk_poll "$IOTA"
assert_eq "$(sk_reactions "$IOTA_CH" "$M4")" "white_check_mark" "the next poll completes the swap"
assert_eq "$(sk_state "[.messages.${IOTA_CH}[] | select(.user == \"UBOT\")] | length")" "0" "no mark posts a message"
sk_ctl /_test/calls-reset >/dev/null
sk_poll "$IOTA"
assert_eq "$(sk_state '[.calls[] | select(startswith("reactions."))] | length')" "0" "a completed swap is not made again"
settle_rows() { # SLACK ERROR<TAB>THE REACTIONS METHODS THAT ANSWER IT, one line per MARK_SETTLED member
  printf '%s\t%s\n' \
    no_reaction reactions.remove \
    already_reacted reactions.add \
    message_not_found 'reactions.remove reactions.add'
}
swap_due() { # ROOT CHANNEL TEXT — a directive landed and read, its swap due on the next poll; prints its ts
  local ts
  ts="$(sk_inject "$2" U001 "$3")"
  sk_poll "$1"
  sk_lm "$1" inbox --item overseer >/dev/null
  printf '%s' "$ts"
}
mark_of() { jq -r --arg ts "$2" 'select(.t == "mark" and .ts == $ts) | .name' "$(sk_journal "$1")" | tail -n 1; } # ROOT TS — its last journaled mark
while IFS=$'\t' read -r error methods <&3; do
  MS="$(swap_due "$IOTA" "$IOTA_CH" "settle $error")"
  for method in $methods; do sk_ctl /_test/fault "{\"method\": \"$method\", \"error\": \"$error\"}" >/dev/null; done
  sk_poll "$IOTA"
  assert_eq "$RC=$ERR|$(mark_of "$IOTA" "$MS")" "0=|white_check_mark" "a swap Slack answers $error on is settled: no line, the check journaled"
  sk_ctl /_test/calls-reset >/dev/null
  sk_poll "$IOTA"
  assert_eq "$(sk_state '[.calls[] | select(startswith("reactions."))] | length')" "0" "a swap settled by $error is not made again"
done 3<<<"$(settle_rows)"
stop_rows() { # NAME<TAB>THE LINE A STOP FOLLOWS OR REPLACES<TAB>ITS REPLACEMENT<TAB>REACTIONS AT THE STOP, one line per point
  printf '%s\t%s\t%s\t%s\n' \
    after-in 'self\.journal\.append\(t="in", channel=self\.channel, ts=ts, kind="directive", id=envelope, thread=thread_ts\)' '\g<0>; os._exit(9)' '' \
    after-react 'self\.journal\.append\(t="mark", ts=ts, name=SEEN\)' 'os._exit(9)' eyes
}
while IFS=$'\t' read -r stop pattern repl before <&3; do
  sk_mutant "stop-$stop" relay.py "$pattern" "$repl"
  MX="$(sk_inject "$IOTA_CH" U001 "stopped $stop")"
  sk_poll "$IOTA"
  STOPPED="$RC|$(sk_reactions "$IOTA_CH" "$MX")|$(mark_of "$IOTA" "$MX")"
  sk_bin_reset
  sk_poll "$IOTA"
  RESTARTED="$RC|$(sk_reactions "$IOTA_CH" "$MX")|$(mark_of "$IOTA" "$MX")"
  sk_lm "$IOTA" inbox --item overseer >/dev/null
  sk_poll "$IOTA"
  assert_eq "$STOPPED/$(text_of "$IOTA" "$IOTA_CH:$MX")/$RESTARTED/$(sk_reactions "$IOTA_CH" "$MX")" \
    "9|$before|/stopped $stop/0|eyes|eyes/white_check_mark" "a stop $stop: the directive landed, the restart marks it, the read swaps it"
done 3<<<"$(stop_rows)"

# --- a receipts read lane-mail refuses: printed, the mark waits, the poll goes on -------
MU="$(sk_new_root mu)"
rm -- "${MU:?}/.agents/skills/orch/scripts"
mkdir -p "$MU/.agents/skills/orch/scripts"
cat > "$MU/.agents/skills/orch/scripts/lane-mail" <<EOF
#!/usr/bin/env bash
if [ -e "$MU/tmp/drain-refused" ]; then
  case " \$* " in *" --receipts "*) echo 'lane-mail: drain-refused' >&2; exit 2 ;; esac
fi
exec "$SK_LANE_MAIL" "\$@"
EOF
chmod +x "$MU/.agents/skills/orch/scripts/lane-mail"
sk_bind "$MU"
MU_CH="$(sk_channel "$MU")"
MU1="$(swap_due "$MU" "$MU_CH" 'read me')"
touch "$MU/tmp/drain-refused"
sk_lm "$MU" notice --item overseer --to owner --file "$(sk_text n20 'Still posting.')" >/dev/null
sk_poll "$MU"
assert_eq "$RC=$ERR1" "0=slack: lane-mail-failed=lane-mail: drain-refused" "a receipts read lane-mail refuses is printed and fails no poll"
assert_eq "$(asks "$MU_CH" 'Still posting.')|$(sk_reactions "$MU_CH" "$MU1")" "1|eyes" "the notice still posts and the mark waits"
rm -- "${MU:?}/tmp/drain-refused"
sk_poll "$MU"
assert_eq "$(sk_reactions "$MU_CH" "$MU1")" "white_check_mark" "the next poll makes the swap"

# --- text as the owner typed it: Slack's escapes and tokens read back, one row per form ---
markup_rows() { # SENT<TAB>DELIVERED, one line per form
  printf '%s\t%s\n' \
    'a &amp; b &lt;c&gt;' 'a & b <c>' \
    'see <https://example.test/a?x=1&amp;y=2|the docs>' 'see the docs (https://example.test/a?x=1&y=2)' \
    'open <https://example.test/b>' 'open https://example.test/b' \
    'ask <@U002> first' 'ask @ann first' \
    'ask <@U404> too' 'ask @U404 too' \
    'ask <@U002|annie> now' 'ask @annie now' \
    '<!here> ship it :rocket:' '@here ship it :rocket:' \
    '<!channel> stop' '@channel stop' \
    '<!subteam^S1|@team> look' '@team look' \
    '<!subteam^S1> look' '@subteam look' \
    'due <!date^1392734382^{date}|Feb 18, 2014> then' 'due Feb 18, 2014 then' \
    'in <#C123|general>' 'in #general' \
    'in <#C123>' 'in #C123' \
    'in <#C124|>' 'in #C124' \
    'typed &amp;lt; as is' 'typed &lt; as is'
}
LAMBDA="$(sk_new_root lambda)"
sk_bind "$LAMBDA"
LAMBDA_CH="$(sk_channel "$LAMBDA")"
MARKUP_TS=()
while IFS=$'\t' read -r sent _; do MARKUP_TS+=("$(sk_inject "$LAMBDA_CH" U001 "$sent")"); done <<<"$(markup_rows)"
sk_poll "$LAMBDA"
assert_eq "$RC=$ERR1" "0=slack: slack-api-failed=users.info error=user_not_found" "a mention Slack will not name is printed and fails no poll"
n=0
while IFS=$'\t' read -r sent want; do
  assert_eq "$(text_of "$LAMBDA" "$LAMBDA_CH:${MARKUP_TS[$n]}")" "$want" "Slack's text [$sent] lands as [$want]"
  n=$((n + 1))
done <<<"$(markup_rows)"

# --- controls, one mutant per rule ------------------------------------------------------------
sk_mutant delivery mailbox.py '"--delivery-id", delivery_id, "--file"' '"--delivery-id", delivery_id + "." + str(os.getpid()), "--file"'
DELTA="$(sk_new_root delta)"
sk_bind "$DELTA"
crash_gap "$DELTA"
assert_eq "$GAP_COUNT" "3" "control: the delivery id dropped, the replayed note lands twice"
sk_bin_reset

sk_mutant resolve relay.py 'outcome, answer_id = self.mail.answer\(thread.envelope, text, delivery\)' 'outcome, answer_id = self.mail.answer(thread.envelope, text, delivery)\n            self.mail._run("resolve", "--item", "overseer", "--id", thread.envelope)'
EPS="$(sk_new_root eps)"
sk_bind "$EPS"
sk_lm "$EPS" ask --item overseer --to owner --file "$(sk_text q4 'Which?')" --options a,b --recommend a >/dev/null
sk_poll "$EPS"
EPS_CH="$(sk_channel "$EPS")"
ASK4_TS="$(sk_state ".messages.${EPS_CH}[] | select(.text | contains(\"Which?\")) | .ts")"
sk_inject "$EPS_CH" U001 'b' "$ASK4_TS" >/dev/null
sk_poll "$EPS"
sk_inject "$EPS_CH" U001 'and another answer' "$ASK4_TS" >/dev/null
sk_poll "$EPS"
CONTROL_FAIL="$SK_FAIL"
CONTROL_RC=0
CONTROL_OUT="$(
  assert_eq "$(answers "$EPS" | wc -l | tr -d ' ')" "2" "control probe: both replies remain answers"
  [ "$SK_FAIL" = "$CONTROL_FAIL" ]
)" || CONTROL_RC=$?
assert_eq "$CONTROL_RC" "1" "control: restoring close on the first reply turns the two-answer assertion red"
sk_bin_reset

# Keep the resolution route and envelope, but suppress its journal append.
sk_mutant closure-journal relay.py 'self\.journal\.append\(t="resolved", id=str\(envelope\["re"\]\), source=str\(envelope\["id"\]\)\)' 'None if True else self.journal.append(t="resolved", id=str(envelope["re"]), source=str(envelope["id"]))'
CLOSE_ROOT="$(sk_new_root closure-journal)"
sk_bind "$CLOSE_ROOT"
sk_lm "$CLOSE_ROOT" ask --item overseer --to owner --file "$(sk_text closure 'Close?')" --options a,b --recommend a >"$SK_TMP/close.out"
CLOSE_ASK="$(sed 's/^id=//' "$SK_TMP/close.out")"
sk_poll "$CLOSE_ROOT"
sk_lm "$CLOSE_ROOT" resolve --item overseer --id "$CLOSE_ASK" >/dev/null
sk_poll "$CLOSE_ROOT"
CONTROL_FAIL="$SK_FAIL"
CONTROL_RC=0
CONTROL_OUT="$(
  assert_eq "$(jq -c '.open_asks' "$CLOSE_ROOT/tmp/slack/status.json")" "[]" "explicit close leaves no open ask in relay status"
  [ "$SK_FAIL" = "$CONTROL_FAIL" ]
)" || CONTROL_RC=$?
assert_eq "$CONTROL_RC" "1" "control: disabling closure journaling turns relay status red"
sk_bin_reset

sk_mutant closure-replay store.py 'self\.resolutions\.add\(str\(line\["source"\]\)\)' 'self.resolutions.update([])'
sk_poll "$CLOSE_ROOT"
sk_poll "$CLOSE_ROOT"
CONTROL_FAIL="$SK_FAIL"
CONTROL_RC=0
CONTROL_OUT="$(
  assert_eq "$(jq -s --arg id "$CLOSE_ASK" '[.[] | select(.t == "resolved" and .id == $id)] | length' "$(sk_journal "$CLOSE_ROOT")")" "1" "restart consumes the close once"
  [ "$SK_FAIL" = "$CONTROL_FAIL" ]
)" || CONTROL_RC=$?
assert_eq "$CONTROL_RC" "1" "control: losing source replay repeats the closure record"
sk_bin_reset

sk_mutant late-closure relay.py 'if thread_ts in state\.threads and env_id not in state\.resolutions:' 'if thread_ts in state.threads and env_id not in state.resolutions and at_epoch(str(envelope["at"])) >= self.settings.horizon(self.clock()):'
LATE_CONTROL="$(sk_new_root late-control)"
sk_bind "$LATE_CONTROL"
sk_lm "$LATE_CONTROL" ask --item overseer --to owner --file "$(sk_text late-control 'Delayed?')" --options a,b --recommend a >"$SK_TMP/late-control.out"
LATE_CONTROL_ASK="$(sed 's/^id=//' "$SK_TMP/late-control.out")"
sk_poll "$LATE_CONTROL"
sk_lm "$LATE_CONTROL" resolve --item overseer --id "$LATE_CONTROL_ASK" >/dev/null
LATE_CONTROL_CLOSE="$(jq -r .id "$(sk_box "$LATE_CONTROL")/to-lane.jsonl")"
sk_age_envelope "$LATE_CONTROL" "$LATE_CONTROL_CLOSE" 172800
sk_poll "$LATE_CONTROL" SLACK_THREAD_DAYS=1
CONTROL_FAIL="$SK_FAIL"
CONTROL_RC=0
CONTROL_OUT="$(
  assert_eq "$(jq -c .open_asks "$LATE_CONTROL/tmp/slack/status.json")" "[]" "late first observation closes relay state"
  [ "$SK_FAIL" = "$CONTROL_FAIL" ]
)" || CONTROL_RC=$?
assert_eq "$CONTROL_RC" "1" "control: applying post age to closure leaves relay state open"
sk_bin_reset

sk_mutant lock store.py 'fcntl\.LOCK_EX \| fcntl\.LOCK_NB' 'fcntl.LOCK_SH | fcntl.LOCK_NB'
sk_relay_start "$EPS"
sk_poll "$EPS"
assert_eq "$RC" "0" "control: the lock no longer exclusive, a second relay runs"
sk_relay_stop
sk_bin_reset

sk_mutant shared relay.py 'if other != root\.path:' 'if other != root.path and False:'
sk_run -- listen --root "$PAIR_A" --root "$PAIR_B" --once
assert_eq "$RC" "0" "control: the one-channel rule gone, both roots poll one channel"
sk_bin_reset

sk_mutant horizon relay.py 'return not thread.missing and \(thread.open or max\(float\(thread.ts\), thread.active\) >= self.settings.horizon\(self.clock\(\)\)\)' 'return True'
ZETA="$(sk_new_root zeta)"
sk_bind "$ZETA"
sk_rebind_at "$ZETA" "$(python3 -c 'import time; print("%.6f" % (time.time() - 9 * 86400))')"
ZETA_CH="$(sk_channel "$ZETA")"
OLD2="$(sk_inject "$ZETA_CH" U001 'old' '' "\"ts\": \"$OLD_TS\"")"
sk_inject "$ZETA_CH" U001 'late reply' "$OLD2" >/dev/null
sk_poll "$ZETA"
assert_eq "$(directives "$ZETA" | wc -l | tr -d ' ')" "2" "control: the horizon removed, the reply under the old thread is routed"
sk_bin_reset

sk_mutant owner relay.py 'if user not in self\.binding\.owner_ids\.values\(\):' 'if user not in self.binding.owner_ids.values() and False:'
N2="$(sk_inject C001 U999 'not an owner' "$TS1" '"subtype": "thread_broadcast"')"
sk_event "$ROOT" C001 "$N2"
assert_eq "$(jq -s --arg d "C001:$N2" --arg ts "$TS1" '[.[] | select(.delivery_id == $d) | {text, thread_ts, parent_ts: .parent.ts}] == [{text:"not an owner", thread_ts:$ts, parent_ts:$ts}]' "$(sk_box "$ROOT")/to-lane.jsonl")" \
  "true" "control: the owner gate open, a non-owner thread broadcast is routed"
sk_bin_reset

sk_mutant notext relay.py 'if not lines:' 'if not lines and False:'
F2="$(sk_inject "$ZETA_CH" U001 '')"
sk_poll "$ZETA"
assert_lacks "$(posts "$ZETA_CH")" "$F2 | Only text and files are routed" "control: the no-text gate open, an empty message gets no reply"
sk_bin_reset

ZETA_FILES="$ZETA/tmp/slack/files"
sk_mutant files-dropped relay.py 'lines = \(\[text\] if text else \[\]\) \+ self\.fetch_files\(message\)' 'lines = [text] if text else []'
FC1="$(sk_inject "$ZETA_CH" U001 'see file' '' "\"files\": [$(sk_file F911 c.png image/png 'c')]")"
sk_poll "$ZETA"
assert_eq "$(text_of "$ZETA" "$ZETA_CH:$FC1")" "see file" "control: the files unread, the envelope names no file"
sk_bin_reset

sk_mutant signin api.py 'if resp\.headers\.get_content_type\(\) == "text/html" and copied != size:' 'if False:'
sk_ctl /_test/fault '{"method": "download", "signin": true}' >/dev/null
FC2="$(sk_inject "$ZETA_CH" U001 '' '' "\"files\": [$(sk_file F912 d.png image/png 'd')]")"
sk_poll "$ZETA"
assert_eq "$(text_of "$ZETA" "$ZETA_CH:$FC2")" "$ZETA_FILES/F912-d.png" "control: the sign-in check gone, the sign-in page is saved as the file"
sk_bin_reset

sk_mutant name store.py 're\.sub\(r"\[\^A-Za-z0-9\._-\]", "_", f"\{file_id\}-\{name\}"\)' 'f"{file_id}-{name}"'
FC3="$(sk_inject "$ZETA_CH" U001 '' '' "\"files\": [$(sk_file F913 'shots/e.png' image/png 'e')]")"
sk_poll "$ZETA"
assert_has "$(text_of "$ZETA" "$ZETA_CH:$FC3")" "file F913 not fetched: " "control: the name kept whole, a slash in it leaves the file unsaved"
sk_bin_reset

sk_mutant file-mode store.py 'os\.chmod\(directory, 0o700\)' 'os.chmod(directory, 0o755)'
sk_inject "$ZETA_CH" U001 '' '' "\"files\": [$(sk_file F914 f.png image/png 'f')]" >/dev/null
sk_poll "$ZETA"
assert_eq "$(sk_mode "$ZETA_FILES")" "755" "control: the directory mode unset, the files directory is readable by others"
sk_bin_reset

sk_mutant html-size relay.py 'size = given if isinstance\(given, int\) else None' 'size = None'
FC4="$(sk_inject "$ZETA_CH" U001 '' '' "\"files\": [$(sk_file F915 page.html text/html '<p>page</p>')]")"
sk_poll "$ZETA"
assert_eq "$(text_of "$ZETA" "$ZETA_CH:$FC4")" "file F915 not fetched: HTTP 200 sign-in page, the app needs files:read" \
  "control: the file's size unread, an HTML file is refused as the sign-in page"
sk_bin_reset

sk_mutant name-cut store.py '\[:NAME_CHARS\]' ''
FC5="$(sk_inject "$ZETA_CH" U001 '' '' "\"files\": [$(sk_file F916 "$(python3 -c 'print("n" * 300)')" text/plain 'long')]")"
sk_poll "$ZETA"
assert_has "$(text_of "$ZETA" "$ZETA_CH:$FC5")" "file F916 not fetched: " "control: the name uncut, a long name leaves the file unsaved"
sk_bin_reset

sk_mutant length api.py 'if declared is not None and declared\.strip\(\)\.isdigit\(\) and copied != int\(declared\):' 'if False:'
sk_ctl /_test/fault '{"method": "download", "cut": "length"}' >/dev/null
FC6="$(sk_inject "$ZETA_CH" U001 '' '' "\"files\": [$(sk_file F917 i.png image/png 'cut bytes')]")"
sk_poll "$ZETA"
assert_eq "$(text_of "$ZETA" "$ZETA_CH:$FC6")|$(cat "$ZETA_FILES/F917-i.png")" "$ZETA_FILES/F917-i.png|cut " \
  "control: the length unchecked, a body cut short is saved as the file"
sk_bin_reset

sk_mutant no-length api.py 'declared = resp\.headers\.get\("Content-Length"\)' 'declared = resp.headers.get("Content-Length", "0")'
sk_ctl /_test/fault '{"method": "download", "chunked": true}' >/dev/null
FC8="$(sk_inject "$ZETA_CH" U001 '' '' "\"files\": [$(sk_file F919 l.png image/png 'chunked bytes')]")"
sk_poll "$ZETA"
assert_eq "$(text_of "$ZETA" "$ZETA_CH:$FC8")" "file F919 not fetched: truncated 13 of 0 bytes" \
  "control: a missing Content-Length read as zero, a whole chunked body is refused"
sk_bin_reset

sk_mutant http-exception api.py 'except http\.client\.HTTPException as err:' 'except LookupError as err:'
sk_file F918 j.png image/png 'cut bytes' >/dev/null
sk_ctl /_test/fault '{"method": "download", "cut": "chunked"}' >/dev/null
sk_recovery "$ZETA" download "$SK_URL/_files/F918"
sk_assert_red "$(printf '%s\n' "$OUT" | tail -n 1 | jq -r .error)" 'file-not-fetched' 'control: omitting the download catch breaks its file-not-fetched key'
sk_bin_reset

sk_mutant mark-seen relay.py 'if self\.react\("reactions\.add", ts, SEEN\):' 'if False and self.react("reactions.add", ts, SEEN):'
MC1="$(sk_inject "$ZETA_CH" U001 'mark me')"
sk_poll "$ZETA"
assert_eq "$(sk_reactions "$ZETA_CH" "$MC1")" "" "control: the seen mark gone, a delivered directive carries no reaction"
sk_bin_reset

for retry in poll delivery; do
  case "$retry" in
    poll) sk_mutant same-poll relay.py '(        if not self.caught_up:\n            self.catch_up\(bot_user\)\n)' '\1        self.mark_seen(self.state.delivered)\n' ;;
    delivery) sk_mutant delivery-sweep relay.py '(        notice\("delivered", f"ts=\{ts\} id=\{envelope\} path=\{path\}"\)\n)        self.mark_seen\(\[ts\]\)' '\1        self.mark_seen(self.state.delivered)' ;;
  esac
  RETRY_ROOT="$(sk_new_root "retry-$retry")"
  sk_bind "$RETRY_ROOT"
  RETRY_CH="$(sk_channel "$RETRY_ROOT")"
  RETRY_TS="$(sk_inject "$RETRY_CH" U001 'Refuse first mark')"
  sk_inject "$RETRY_CH" U001 'Mark next delivery' >/dev/null
  sk_ctl /_test/fault '{"method": "reactions.add", "error": "missing_scope"}' >/dev/null
  sk_poll "$RETRY_ROOT"
  sk_assert_red "$(sk_reactions "$RETRY_CH" "$RETRY_TS")" '' "control: $retry retry marks a newly refused delivery in the same poll"
  sk_bin_reset
done

sk_mutant mark-cursor relay.py 'if self\.state\.delivered\.get\(ts\) not in read:' 'if False:'
MC2="$(sk_inject "$ZETA_CH" U001 'unread')"
sk_poll "$ZETA"
assert_eq "$(sk_reactions "$ZETA_CH" "$MC2")" "white_check_mark" "control: the cursor unread, an unread directive is marked read"
sk_bin_reset

sk_mutant mark-fatal relay.py 'print_refusal\(err\)\n                return False' 'raise err'
sk_ctl /_test/fault '{"method": "reactions.add", "error": "missing_scope"}' >/dev/null
sk_inject "$ZETA_CH" U001 'scope missing' >/dev/null
sk_poll "$ZETA"
assert_eq "$RC" "1" "control: a refused mark raised, the poll fails"
sk_bin_reset

while IFS=$'\t' read -r error methods <&3; do
  sk_mutant "settled-$error" relay.py "(MARK_SETTLED = \\{[^}\\n]*)\"$error\"(, )?" '\1'
  SR="$(sk_new_root "settle-$error")"
  sk_bind "$SR"
  SR_CH="$(sk_channel "$SR")"
  MS="$(swap_due "$SR" "$SR_CH" 'settle me')"
  for method in $methods; do sk_ctl /_test/fault "{\"method\": \"$method\", \"error\": \"$error\"}" >/dev/null; done
  sk_poll "$SR"
  assert_eq "$ERR1|$(mark_of "$SR" "$MS")" "slack: slack-api-failed=${methods%% *} error=$error|eyes" \
    "control: $error no longer settled, the swap is printed as refused and no check is journaled"
  # A refused remove skips add, leaving its queued fault for the next fixture.
  sk_ctl /_test/faults-reset >/dev/null
  sk_bin_reset
done 3<<<"$(settle_rows)"

sk_mutant mark-read-refused relay.py '        try:\n            read = self\.mail\.read_directives\(\)\n        except Refusal as err:\n            print_refusal\(err\)\n            return\n' '        read = self.mail.read_directives()\n'
sk_inject "$MU_CH" U001 'refused read' >/dev/null
touch "$MU/tmp/drain-refused"
sk_lm "$MU" notice --item overseer --to owner --file "$(sk_text n21 'Held back.')" >/dev/null
sk_poll "$MU"
assert_eq "$RC $(asks "$MU_CH" 'Held back.')" "1 0" "control: a refused receipts read raised, the poll fails and the notice waits"
rm -- "${MU:?}/tmp/drain-refused"
sk_bin_reset

sk_mutant markup-skipped relay.py 'text = plain\(\(message\.get\("text"\) or ""\)\.strip\(\), self\.user_name\)' 'text = (message.get("text") or "").strip()'
MK1="$(sk_inject "$ZETA_CH" U001 'a &amp; b')"
sk_poll "$ZETA"
assert_eq "$(text_of "$ZETA" "$ZETA_CH:$MK1")" "a &amp; b" "control: the markup unread, Slack's escape lands as sent"
sk_bin_reset

sk_mutant markup-order markup.py 'return text\.replace\("&lt;", "<"\)\.replace\("&gt;", ">"\)\.replace\("&amp;", "&"\)' 'return text.replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">")'
MK2="$(sk_inject "$ZETA_CH" U001 'typed &amp;lt;')"
sk_poll "$ZETA"
assert_eq "$(text_of "$ZETA" "$ZETA_CH:$MK2")" "typed <" "control: &amp; unescaped first, a typed &lt; lands as <"
sk_bin_reset

sk_mutant text-check relay.py 'secret_check\(text\.encode\(\), f"id=\{env_id\}"\)' 'secret_check(b"", f"id={env_id}")'
sk_lm "$ZETA" notice --item overseer --to owner --file "$(sk_text s2 'leak xoxb-0123456789-abcdefghij')" >/dev/null
sk_poll "$ZETA"
assert_eq "$(asks "$ZETA_CH" 'xoxb-0123456789')" "1" "control: the outbound text unchecked, a token posts"
sk_bin_reset

sk_mutant report-bytes relay.py 'checked_file\(attach, f"id=\{env_id\} file=\{attach\}"\)' 'checked_file(attach, f"id={env_id} file={attach}") if False else Path(attach).read_bytes()'
mkdir -p "$ZETA/tmp/progress-reports"
printf 'ghp_%s\n' "abcdefghijklmnopqrstuvwxyz0123456789" > "$ZETA/tmp/progress-reports/leak.md"
sk_lm "$ZETA" notice --item overseer --to owner --attach "$ZETA/tmp/progress-reports/leak.md" --file "$(sk_text n8 'Leaky report.')" >/dev/null
sk_poll "$ZETA"
assert_eq "$(sk_state '[.uploads[] | select(. | contains("ghp_"))] | length')" "1" "control: the report bytes unchecked, a token uploads"
sk_bin_reset

sk_mutant body-arg markup.py 'return markdown, "markdown_text"' 'return markdown, "text"'
sk_lm "$ZETA" notice --item overseer --to owner --file "$(sk_text n13 'Plain again.')" >/dev/null
sk_poll "$ZETA"
assert_eq "$(sk_state ".messages.${ZETA_CH}[] | select(.text == \"Plain again.\") | .body_arg")" "text" "control: the body sent as text, Slack renders mrkdwn"
sk_bin_reset

sk_mutant length markup.py 'return ""\.join\(_render\(part, mrkdwn=True\) for part in parts\), "text"' 'return "".join(_render(part, mrkdwn=True) for part in parts), "markdown_text"'
sk_lm "$ZETA" notice --item overseer --to owner --file "$(sk_text n14 "$LONG")" >/dev/null
sk_poll "$ZETA"
assert_eq "$RC=${ERR1%% id=*}=$(sk_state "[.messages.${ZETA_CH}[] | select(.text | startswith(\"xxxx\"))] | length")" \
  "1=slack: slack-api-failed=chat.postMessage error=msg_blocks_too_long=0" "control: the text fallback gone, Slack refuses a notice past the cap and it never lands"
sk_bin_reset

sk_mutant deadline relay.py 'It stands at \{local_time\(str\(envelope\[.deadline.\]\)\)\}' 'It stands at {envelope["deadline"]}'
sk_lm "$ZETA" ask --item overseer --to owner --file "$(sk_text q11 'Zulu deadline?')" --options a,b --recommend a >/dev/null
sk_poll "$ZETA"
assert_eq "$(sk_state ".messages.${ZETA_CH}[] | select(.text | contains(\"Zulu deadline?\")) | .text | contains(\"<!date^\")")" "false" \
  "control: the deadline as its raw stamp, the ask posts with no date token"
sk_bin_reset

sk_mutant swallow relay.py 'if self\.post_failed is not None:\n            raise self\.post_failed' 'if self.post_failed is not None:\n            self.post_failed = None'
sk_lm "$ZETA" ask --item overseer --to owner --file "$(sk_text q9 'Swallowed?')" --options a,b --recommend a >/dev/null
sk_ctl /_test/fault '{"method": "chat.postMessage", "error": "not_in_channel", "times": 1}' >/dev/null
sk_poll "$ZETA"
assert_eq "$RC=$(jq -r '.last_poll_ok' "$ZETA/tmp/slack/status.json")" "0=true" "control: the post failure swallowed, a refused post reads as a clean poll"
sk_bin_reset


sk_mutant start relay.py 'elif before\(state\.start_at, state\.start_ids, at, env_id\):' 'elif False:'
ETA="$(sk_new_root eta)"
sk_lm "$ETA" notice --item overseer --to owner --file "$(sk_text n9 'Before the start.')" >/dev/null
sk_bind "$ETA"
sk_poll "$ETA"
assert_eq "$(asks "$(sk_channel "$ETA")" 'Before the start.')" "1" "control: the start horizon removed, a notice from before the start posts"
sk_bin_reset

# One binding owns adoption, repeat setup and delivery progress independently.
while read -r mode want; do
  LIFE="$(sk_new_root "lifetime-$mode")"
  sk_lm "$LIFE" ask --item overseer --to owner --file "$(sk_text lifetime 'Lifetime ask?')" --options yes,no --recommend no >/dev/null
  case "$mode" in seed) sk_mutant seed relay.py 'self\.journal\.append\(t="seen", ts=self\.binding\.bound_at\)' 'self.journal.append(t="seen", ts="0")' ;; floor) sk_mutant floor relay.py 'oldest = max\(thread.seen, self.binding.bound_at, key=float\)' 'oldest = thread.seen' ;; esac
  sk_run -- setup --root "$LIFE" --take C777
  sk_poll "$LIFE"
  LIFE_ASK="$(sk_state '[.messages.C777[] | select(.text | contains("Lifetime ask?"))][-1].ts')"
  QUEUED="$(sk_inject C777 U001 queued "$PRE_PARENT")"
  ANSWER="$(sk_inject C777 U001 yes "$LIFE_ASK")"
  BOUND="$(jq -r .bound_at "$LIFE/tmp/slack/binding.json")"
  if [ "$mode" = repeat ]; then
    sk_mutant repeat verbs.py 'bound_before.bound_at if bound_before else f"\{time.time\(\):.6f\}"' 'f"{time.time():.6f}"'
  fi
  sk_run SLACK_OWNERS="$OWNER" -- setup --root "$LIFE" --take C777
  sk_poll "$LIFE"
  assert_eq "$(jq -sr --arg pre "$PRE_REPLY" --arg root "$PRE_PARENT" --arg q "$QUEUED" --arg a "$ANSWER" '[any(.[]; .delivery_id == ("C777:"+$pre)), any(.[]; .delivery_id == ("C777:"+$root)), any(.[]; .delivery_id == ("C777:"+$q)), any(.[]; .delivery_id == ("C777:"+$a) and .kind == "answer")] | @json' "$(sk_box "$LIFE")/to-lane.jsonl")=$(jq -r --arg bound "$BOUND" '.bound_at == $bound' "$LIFE/tmp/slack/binding.json")" \
    "$want" "$mode: the stable binding excludes prior messages and retains queued directives and answers"
  sk_bin_reset
done <<'ROWS'
production [false,false,true,true]=true
floor [true,false,true,true]=true
seed [false,true,true,true]=true
repeat [false,false,false,false]=false
ROWS


# A one-shot fault must hit this ask, not a prior row's pending retry.
NET="$(sk_new_root network)"
sk_bind "$NET"
sk_poll "$NET"
sk_mutant network api.py 'raise Refusal\("slack-unreachable", ' 'raise Refusal("slack-response-lost", '
sk_lm "$NET" ask --item overseer --to owner --file "$(sk_text q10 'Never sent?')" --options a,b --recommend a >"$SK_TMP/ask10.out"
ASK10="$(sed 's/^id=//' "$SK_TMP/ask10.out")"
sk_ctl /_test/fault '{"method": "chat.postMessage", "refuse": true, "times": 1}' >/dev/null
sk_poll "$NET"
assert_eq "${ERR1%% (*}" "slack: slack-response-lost=chat.postMessage" \
  "control: the network mutant classifies the unsent request as a lost response"
assert_eq "$RC=$(jq -r "select(.t == \"out\" and .id == \"$ASK10\" and .state != \"inflight\") | .state" "$(sk_journal "$NET")")=$(asks "$(sk_channel "$NET")" 'Never sent?')" "0=unknown=0" \
  "control: a refused connection read as a lost response, the unsent ask is journaled unknown"
sk_bin_reset

sk_summary
