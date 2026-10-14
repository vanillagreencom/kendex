#!/usr/bin/env bash
# `slack listen` under SLACK_JARVIS_SESSION_FILE: while the file is fresh a notice
# and an ask are held, an owner message still lands and its reply posts once
# in that message's thread,
# the hold is journaled once and `--status` shows held-by=jarvis. Once the
# file is stale the resume posts the answer to an ask the channel shows open,
# and notices and open asks past the Jarvis session's seen line count; an ask
# at or below it is skipped with no post and no mention. Its journal records
# that count, the skipped ids and asks whose posts landed.
# A dead token on an ask still records every read notice id.
# A restart or a missing seen file cannot replay a skipped or posted id.
# A missing, unreadable or invalid count skips nothing; a count past the
# snapshot clamps. An absent Jarvis session file or an empty setting posts as before,
# SLACK_JARVIS_SESSION_MAX_AGE bounds the hold, and a file whose age cannot be read
# refuses the post step alone. Compaction keeps a standing hold and the resumes inside the
# horizon. Changed root settings update the presence pair on the next poll
# without a restart; unchanged files run no settings reader. A refused read
# retains the hold and fails only that root. A renamed presence file keeps the
# replaced one holding until the new one is fresh or the replaced one stale.
# The controls plant one mutant per rule.
set -uo pipefail
. "$(dirname "$0")/lib/harness.sh"

sk_fake_start
echo "=== slack listen: the Jarvis session hold ==="

JARVIS_SESSION="$SK_TMP/jarvis-session-live"
HOLD="SLACK_JARVIS_SESSION_FILE=$JARVIS_SESSION"
aged() { sk_age_file "$JARVIS_SESSION" "$1"; } # SECONDS
fresh() { touch -- "$JARVIS_SESSION" && aged 10; }
stale() { aged 600; } # the default SLACK_JARVIS_SESSION_MAX_AGE: the hold ends as this runs
count() { sk_state "[(.messages.${1} // [])[] | select(.text | contains(\"$2\"))] | length"; } # CHANNEL TEXT
holds() { jq -r 'select(.t == "hold" or .t == "resume") | .t' "$(sk_journal "$1")" | tr '\n' ' '; } # ROOT
ask() { # ROOT NAME TEXT [ASK FORM ARGS]
  local root="$1" name="$2" text="$3"
  shift 3
  [ "$#" -gt 0 ] || set -- --recommend a
  sk_lm "$root" ask --item overseer --to owner --file "$(sk_text "$name" "$text")" --options a,b "$@" | sed 's/^id=//'
}
notice() { sk_lm "$1" notice --item overseer --to owner --file "$(sk_text "$2" "$3")" >/dev/null; } # ROOT NAME TEXT
last_id() { tail -n 1 "$(sk_box "$1")/to-overseer.jsonl" | jq -r .id; } # ROOT — the newest envelope's id
old_resumes() { jq -s '[.[] | select(.t == "resume" and (.at | fromdateiso8601) < now - 31536000)] | length' "$(sk_journal "$1")"; } # ROOT — resumes ending over a year ago
row() { sk_run -- listen --status --root "$1"; LINE="$(printf '%s' "$OUT" | sed -n '1p')"; } # ROOT
refuse_next_post() { sk_ctl /_test/fault '{"method": "chat.postMessage", "error": "not_in_channel", "times": 1}' >/dev/null; }
# A status timestamp acknowledges a completed poll. The parent suite bounds
# this wait even if the relay or the settings reader stops making progress.
polled_after() { # ROOT LAST_POLL [RESUMED]
  local tries=0 value
  while [ "$tries" -lt 100 ]; do
    value="$(jq -r --argjson after "$2" --argjson resumed "${3:-false}" \
      '.last_poll > $after and ($resumed == false or (.last_poll_ok and .held_by == ""))' "$1/tmp/slack/status.json" 2>/dev/null)"
    [ "$value" != true ] || return 0
    tries=$((tries + 1)); sleep 0.1
  done
  bad "running relay did not complete its next poll" "$1"
  return 1
}
polls() { # ROOT: two completed polls, the first of which may predate a change
  local n after
  for n in 1 2; do
    after="$(jq -r .last_poll "$1/tmp/slack/status.json")"
    polled_after "$1" "$after" || exit 1
  done
}

# The Jarvis read uses the installed mailbox command. The control removes
# only its write, so the same read succeeds but a resume posts both read items.
while read -r name logical control; do
  R="$(sk_new_root "jarvis-read-$name")"
  sk_bind "$R"
  sk_poll "$R" "$HOLD"
  fresh
  notice "$R" "read-notice-$name" "Read notice in $name."
  READ_NOTICE="$(last_id "$R")"
  READ_ASK="$(ask "$R" "read-ask-$name" "Read ask in $name?")"
  if [ "$name" = gapped ]; then
    python3 - "$(sk_box "$R")/to-overseer.jsonl" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
rows = path.read_text().splitlines(keepends=True)
path.write_text(rows[0] + "interrupted\n" + rows[1])
path.with_name(path.name + ".numbering").write_text(json.dumps(
    {"dropped": 2, "first": json.loads(rows[0])["id"], "lines": [1, 3, 5]}) + "\n")
PY
    [ "$?" -eq 0 ] || exit 1
  fi
  if [ "$control" = yes ]; then
    rm -- "$R/.agents/skills/mailbox/scripts"
    cp -R "$SK_ROOT/skills/mailbox/scripts" "$R/.agents/skills/mailbox/scripts"
    python3 - "$R/.agents/skills/mailbox/scripts/lane-mail" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
source = path.read_text()
pattern = 'python3 "$SCRIPT_DIR/lib/lane-mail-store.py" cursor-put "$BOX/to-overseer.seen" "$COUNT"'
assert source.count(pattern) == 1
changed = source.replace(pattern, ': cursor-put "$BOX/to-overseer.seen" "$COUNT"')
assert changed != source
path.write_text(changed)
PY
    [ "$?" -eq 0 ] || exit 1
  fi
  sk_poll "$R" "$HOLD"
  [ "$RC" -eq 0 ] || exit 1
  READ_OUT="$(cd "$R" && .agents/skills/mailbox/scripts/lane-mail events --item overseer --box to-overseer --mark-read)" || exit 1
  assert_eq "$(field "${READ_OUT%%$'\n'*}" count)" "$logical" "$name: Jarvis receives the logical snapshot count"
  assert_eq "$(jq -rs 'map(.id) | join(",")' <<<"${READ_OUT#*$'\n'}")" "$READ_NOTICE,$READ_ASK" "$name: Jarvis receives both read envelopes"
  MARKER=absent
  [ ! -f "$(sk_box "$R")/to-overseer.seen" ] || MARKER="$(cat "$(sk_box "$R")/to-overseer.seen")"
  if [ "$control" = yes ]; then
    sk_assert_red "$MARKER" "$logical" "$name: removing the writer fails the same marker assertion"
    assert_eq "$MARKER" absent "$name: the read still succeeds without writing a marker"
  else
    assert_eq "$MARKER" "$logical" "$name: the real Jarvis read writes its logical count"
  fi
  notice "$R" "unread-notice-$name" "Unread notice in $name."
  stale
  sk_poll "$R" "$HOLD"
  CH_R="$(sk_channel "$R")"
  RESUME_ROW="$RC=$(count "$CH_R" "Read notice in $name.")=$(count "$CH_R" "Read ask in $name?")=$(jq -r 'select(.t == "resume") | .skipped | join(",")' "$(sk_journal "$R")")"
  if [ "$control" = yes ]; then
    sk_assert_red "$RESUME_ROW" "0=0=0=$READ_NOTICE,$READ_ASK" "$name: removing the writer fails the same resume assertion"
    assert_eq "$RESUME_ROW" '0=1=1=' "$name: without the writer the resume skips nothing"
  else
    assert_eq "$RESUME_ROW" "0=0=0=$READ_NOTICE,$READ_ASK" "$name: resume skips the notices and asks Jarvis read"
  fi
  assert_eq "$(count "$CH_R" "Unread notice in $name.")" 1 "$name: a notice after the read still posts"
done <<'ROWS'
plain 2 no
gapped 5 no
writer-control 2 yes
ROWS

ROOT="$(sk_new_root alpha)"
sk_bind "$ROOT"
CH="$(sk_channel "$ROOT")"
sk_poll "$ROOT" "$HOLD"
ASK0="$(ask "$ROOT" q0 'Posted before the hold?')"
sk_poll "$ROOT" "$HOLD"
assert_eq "$RC=$(count "$CH" 'Posted before the hold?')" "0=1" "with no Jarvis session file the ask posts"
ASK0_TS="$(sk_state ".messages.${CH}[] | select(.text | contains(\"Posted before the hold?\")) | .ts")"
notice "$ROOT" n0 'Refused before the hold.'
sk_age_envelope "$ROOT" "$(last_id "$ROOT")" 20
refuse_next_post
sk_poll "$ROOT" "$HOLD"
assert_eq "$RC=$(count "$CH" 'Refused before the hold.')" "1=0" "a notice Slack refuses before the hold stays pending"

# --- a fresh file holds a notice and an ask; owner text still lands ----------
fresh
notice "$ROOT" n1 'Held notice.'
READ_LINES="$(wc -l < "$(sk_box "$ROOT")/to-overseer.jsonl")"
ASK1="$(ask "$ROOT" q1 'Held and open?')"
ASK2="$(ask "$ROOT" q2 'Held and answered?')"
sk_lm "$ROOT" resolve --item overseer --id "$ASK2" --text "$(sk_text a2 'a')" >/dev/null
sk_lm "$ROOT" resolve --item overseer --id "$ASK0" --text "$(sk_text a0 'b, from the Jarvis session')" >/dev/null
TS1="$(sk_inject "$CH" U001 'Still heard.')"
sk_poll "$ROOT" "$HOLD"
assert_eq "$RC=$(count "$CH" 'Held notice.')=$(count "$CH" 'Held and open?')=$(count "$CH" 'Answered in the chat')=$(count "$CH" 'Refused before the hold.')" \
  "0=0=0=0=0" "a fresh Jarvis session file holds the notice, the ask, the answer and the pending notice"
assert_eq "$(jq -r 'select(.kind == "directive") | .delivery_id' "$(sk_box "$ROOT")/to-lane.jsonl")" "$CH:$TS1" \
  "an owner message in the channel still lands while held"
DIRECTIVE="$(jq -r 'select(.kind == "directive") | .id' "$(sk_box "$ROOT")/to-lane.jsonl")"
sk_lm "$ROOT" notice --item overseer --to owner --ref "$DIRECTIVE" --file "$(sk_text reply 'Reply while held.')" >/dev/null
REPLY="$(last_id "$ROOT")"
notice "$ROOT" unrelated 'Unrelated while held.'
sk_poll "$ROOT" "$HOLD"
assert_eq "$RC=$(count "$CH" 'Reply while held.')=$(sk_state ".messages.${CH}[] | select(.text | contains(\"Reply while held.\")) | .thread_ts")" \
  "0=1=$TS1" "a reply to the delivered directive posts once in the owner's thread while held"
assert_eq "$(count "$CH" 'Unrelated while held.')" "0" "an unrelated notice in the same poll stays held"
assert_eq "$(jq -r --arg id "$REPLY" 'select(.t == "out" and .id == $id and .state == "resolved") | .thread' "$(sk_journal "$ROOT")")" \
  "$TS1" "the reply's out line carries its posted thread"
sk_poll "$ROOT" "$HOLD"
assert_eq "$(count "$CH" 'Reply while held.')" "1" "a held poll after restart does not repeat the reply"
assert_eq "$(holds "$ROOT")" "hold " "the hold is journaled once"
row "$ROOT"
assert_has "$LINE" " held-by=jarvis" "the status row shows the hold"

# --- a stale file resumes: asks and answers survive a Jarvis session read ---------
sk_jarvis_read "$ROOT" "$READ_LINES"
stale
notice "$ROOT" n5 'After the stale file.'
sk_poll "$ROOT" "$HOLD"
assert_eq "$RC=$(count "$CH" 'Held and open?')=$(count "$CH" 'Held notice.')=$(count "$CH" 'Held and answered?')" "0=1=0=0" \
  "the resume posts the open ask and neither the held notice nor the answered ask"
assert_eq "$(count "$CH" 'Refused before the hold.')=$(count "$CH" 'After the stale file.')" "0=1" \
  "the resume skips a notice the Jarvis session read before the hold and posts the later one"
assert_has "$(sk_state ".messages.${CH}[] | select(.thread_ts == \"$ASK0_TS\") | .text")" "Answered in the chat: b, from the Jarvis session" \
  "an ask the channel shows open gets its held answer, so its thread closes"
assert_eq "$(holds "$ROOT")=$(jq -r 'select(.t == "resume") | .asks | join(",")' "$(sk_journal "$ROOT")")" "hold resume =$ASK1" \
  "the resume is journaled with the ask it posted"
assert_eq "$(count "$CH" 'Reply while held.')" "1" "the resume does not post the held reply again"
row "$ROOT"
assert_lacks "$LINE" "held-by=" "the status row drops the hold"
notice "$ROOT" n2 'After the resume.'
sk_poll "$ROOT" "$HOLD"
assert_eq "$(count "$CH" 'After the resume.')=$(count "$CH" 'Held notice.')=$(count "$CH" 'Refused before the hold.')" "1=0=0" \
  "a notice after the resume posts; neither read notice replays after a restart"

# --- removal resumes against the same seen count ---------------------------------
fresh
notice "$ROOT" n6 'Held until removed.'
sk_jarvis_read "$ROOT" "$(wc -l < "$(sk_box "$ROOT")/to-overseer.jsonl")"
sk_poll "$ROOT" "$HOLD"
rm -f -- "$JARVIS_SESSION"
notice "$ROOT" n7 'After the removal.'
sk_poll "$ROOT" "$HOLD"
assert_eq "$RC=$(count "$CH" 'Held until removed.')=$(count "$CH" 'After the removal.')" "0=0=1" \
  "a removed file resumes: the read notice never posts, one past the count does"

# --- an absent file or an empty setting posts as before ---------------------------
notice "$ROOT" n3 'No file.'
sk_poll "$ROOT" "$HOLD"
assert_eq "$RC=$(count "$CH" 'No file.')=$(holds "$ROOT")" "0=1=hold resume hold resume " "an absent Jarvis session file holds nothing"
fresh
notice "$ROOT" n4 'No setting.'
sk_poll "$ROOT"
assert_eq "$RC=$(count "$CH" 'No setting.')=$(holds "$ROOT")" "0=1=hold resume hold resume " "an empty setting holds nothing"

# --- SLACK_JARVIS_SESSION_MAX_AGE bounds the hold -------------------------------------------
aged 900
notice "$ROOT" n9 'Under the age bound.'
sk_poll "$ROOT" "$HOLD" SLACK_JARVIS_SESSION_MAX_AGE=3600
assert_eq "$RC=$(count "$CH" 'Under the age bound.')" "0=0" "a file touched 900 s ago holds under SLACK_JARVIS_SESSION_MAX_AGE=3600"
sk_poll "$ROOT" "$HOLD"
assert_eq "$RC=$(count "$CH" 'Under the age bound.')" "0=1" "the same file is stale under the default 600, and the notice posts"

# --- a Jarvis session file whose age cannot be read refuses the post step alone -------------
printf 'x\n' > "$SK_TMP/plain-file"
UNREADABLE="SLACK_JARVIS_SESSION_FILE=$SK_TMP/plain-file/child"
TS2="$(sk_inject "$CH" U001 'Heard past the refusal.')"
notice "$ROOT" n10 'Behind an unreadable file.'
sk_poll "$ROOT" "$UNREADABLE"
assert_eq "$RC=${ERR1%% (*}" "1=slack: jarvis-session-file-unreadable=$SK_TMP/plain-file/child" "an unreadable Jarvis session file is refused by path"
assert_has "$(jq -r 'select(.kind == "directive") | .delivery_id' "$(sk_box "$ROOT")/to-lane.jsonl")" "$CH:$TS2" \
  "an owner message still lands past the refusal"
assert_eq "$(count "$CH" 'Behind an unreadable file.')" "0" "no envelope posts past the refusal"
sk_poll "$ROOT"

# --- compaction keeps a standing hold and the resumes inside the horizon ------------
fresh
sk_poll "$ROOT" "$HOLD"
sk_run -- compact --root "$ROOT"
assert_eq "$RC=$(holds "$ROOT")" "0=resume resume resume hold " "compaction drops each closed hold line and keeps the standing one"
stale
sk_poll "$ROOT" "$HOLD"
sk_age_resume "$ROOT" 2000-01-01T00:00:00Z
assert_eq "$(old_resumes "$ROOT")" "1" "the fixture has one resume past the horizon"
sk_run -- compact --root "$ROOT"
assert_eq "$RC=$(holds "$ROOT")" "0=resume resume resume " "compaction drops a resume whose end is past the horizon"

# --- notices before the first held poll use line numbers, never hold times ---------
# count state, effective seen, backlog posts, fourth posts, skipped ids count.
while read -r value seen backlog fourth skipped; do
  R="$(sk_new_root "seen-$value")"
  fresh
  sk_unposted "$R" "$JARVIS_SESSION"
  IDS="$(jq -sc 'map(.id)' "$(sk_box "$R")/to-overseer.jsonl")"
  case "$value" in
    missing) ;;
    unreadable) mkdir "$(sk_box "$R")/to-overseer.seen" ;;
    ancient) sk_jarvis_read "$R" 3 ;;
    gapped|past-gap)
      # A killed writer can leave filtered physical lines; the Jarvis session's
      # cursor still counts them, including one after the last envelope.
      python3 - "$(sk_box "$R")/to-overseer.jsonl" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
path.write_text("interrupted\n" + path.read_text() + "interrupted\n")
PY
      if [ "$value" = gapped ]; then sk_jarvis_read "$R" 3; else sk_jarvis_read "$R" 99; fi ;;
    *) sk_jarvis_read "$R" "$value" ;;
  esac
  notice "$R" "fourth-$value" "Fourth in seen-$value."
  if [ "$value" = ancient ]; then aged 1000000000; else stale; fi
  sk_poll "$R" "$HOLD"
  assert_eq "$RC=$(count "$(sk_channel "$R")" "Backlog in seen-$value.")=$(count "$(sk_channel "$R")" "Fourth in seen-$value.")=$(jq -r 'select(.t == "resume") | "\(.seen)=\(.skipped | length)"' "$(sk_journal "$R")")" \
    "0=$backlog=$fourth=$seen=$skipped" "resume count $value skips only read notices and journals the clamped count"
  if [ "$value" = 3 ]; then
    assert_eq "$(jq -c 'select(.t == "resume") | .skipped' "$(sk_journal "$R")")" "$IDS" "the resume names every skipped backlog id"
    rm -- "$(sk_box "$R")/to-overseer.seen"
  fi
  sk_run -- compact --root "$R"
  sk_poll "$R" "$HOLD"
  assert_eq "$(count "$(sk_channel "$R")" "Backlog in seen-$value.")=$(count "$(sk_channel "$R")" "Fourth in seen-$value.")" \
    "$backlog=$fourth" "count $value: compaction and restart repeat neither skipped nor out ids"
done <<'ROWS'
3 3 0 1 3
missing none 3 1 0
unreadable none 3 1 0
invalid none 3 1 0
-1 none 3 1 0
0 0 3 1 0
99 4 0 0 4
ancient 3 0 1 3
gapped 3 1 1 2
past-gap 6 0 0 4
ROWS

# --- a refusal on an ask preserves later read notice ids ---------------------------
# refused_resume ROOT [ERROR] : a read notice, then a held ask and an unread
# notice past the seen count; Slack refuses the ask once. Prints the ask id and
# sets REFUSED_READ.
refused_resume() {
  local id
  sk_bind "$1"
  sk_poll "$1" "$HOLD"
  fresh
  notice "$1" "read-$(basename "$1")" "Read before the ask in $(basename "$1")."
  REFUSED_READ="$(last_id "$1")"
  sk_jarvis_read "$1" "$(wc -l < "$(sk_box "$1")/to-overseer.jsonl")"
  id="$(ask "$1" "r-$(basename "$1")" "Refused on resume in $(basename "$1")?")"
  notice "$1" "unread-$(basename "$1")" "Unread after the ask in $(basename "$1")."
  sk_poll "$1" "$HOLD"
  stale
  sk_ctl /_test/fault "$(jq -cn --arg error "${2:-not_in_channel}" '{method: "chat.postMessage", error: $error, times: 1}')" >/dev/null
  sk_poll "$1" "$HOLD"
  printf '%s' "$id"
}
resumed_asks() { jq -r 'select(.t == "resume") | .asks | join(",")' "$(sk_journal "$1")"; } # ROOT
# Error, refusal key, exit status, unread notice posts before restart. A token refusal
# stops the posting loop; not_in_channel leaves the later posts running.
while read -r error key status unread; do
  R="$(sk_new_root "refused-$error")"
  refused_resume "$R" "$error" >/dev/null
  CH_R="$(sk_channel "$R")"
  assert_has "$ERR1" "slack: $key=" "$error: the ask refusal reports its key"
  assert_eq "$(jq -c .unknown "$R/tmp/slack/status.json")" '[]' "$error: an explicit rejection clears the in-flight unknown before restart"
  assert_eq "$RC=$(count "$CH_R" "Refused on resume in refused-$error?")=$(resumed_asks "$R")=$(jq -r 'select(.t == "resume") | "\(.seen)=\(.skipped | join(","))"' "$(sk_journal "$R")")=$(count "$CH_R" "Read before the ask in refused-$error.")=$(count "$CH_R" "Unread after the ask in refused-$error.")=$(holds "$R")" \
    "$status=0==1=$REFUSED_READ=0=$unread=hold resume " "$error: the failed ask is omitted and every read notice id survives the refusal"
  rm -- "$(sk_box "$R")/to-overseer.seen"
  sk_poll "$R" "$HOLD"
  assert_eq "$RC=$(count "$CH_R" "Refused on resume in refused-$error?")=$(count "$CH_R" "Read before the ask in refused-$error.")=$(count "$CH_R" "Unread after the ask in refused-$error.")=$(holds "$R")" \
    "0=1=0=1=hold resume " "$error: restart posts the pending ask and unread notice but never the read notice"
done <<'ROWS'
not_in_channel slack-api-failed 1 1
invalid_auth slack-auth-failed 2 0
token_revoked slack-auth-failed 2 0
ROWS

# --- a resume skips an ask the Jarvis session read and mentions the owners on a later one ---
# The control posts every open ask whatever its line, the rule before asks were read.
while read -r name control reserved expires; do
  R="$(sk_new_root "ask-seen-$name")"
  sk_bind "$R"
  sk_poll "$R" "$HOLD"
  fresh
  if [ "$reserved" = yes ]; then
    READ_ASK="$(ask "$R" "read-$name" "Read by the session in $name?" --reserved --wait 30)"
  else
    READ_ASK="$(ask "$R" "read-$name" "Read by the session in $name?")"
  fi
  sk_jarvis_read "$R" "$(wc -l < "$(sk_box "$R")/to-overseer.jsonl")"
  if [ "$expires" = closed ]; then
    sk_lm "$R" resolve --item overseer --id "$READ_ASK" --default >/dev/null || exit 1
  fi
  if [ "$reserved" = yes ]; then
    UNREAD_ASK="$(ask "$R" "unread-$name" "Unread by the session in $name?" --reserved --wait 30)"
  else
    UNREAD_ASK="$(ask "$R" "unread-$name" "Unread by the session in $name?")"
  fi
  sk_poll "$R" "$HOLD"
  stale
  case "$control" in
    every-ask) sk_mutant every-ask relay.py 'kind in \("notice", "ask"\) and' 'kind == "notice" and' ;;
    overdue) sk_mutant skipped-overdue relay.py '\n\s+and \(env_id in state\.by_envelope or env_id in state\.unknown\)' '' ;;
  esac
  if [ "$expires" = before ]; then
    jq -c --arg id "$READ_ASK" 'if .id == $id then .deadline = "2000-01-01T00:00:00Z" else . end' "$(sk_box "$R")/to-overseer.jsonl" > "$SK_TMP/expired.jsonl"
    mv "$SK_TMP/expired.jsonl" "$(sk_box "$R")/to-overseer.jsonl"
  fi
  sk_poll "$R" "$HOLD"
  CH_R="$(sk_channel "$R")"
  READ_ROW="$RC=$(count "$CH_R" "Read by the session in $name?")=$(jq -r 'select(.t == "resume") | .skipped | join(",")' "$(sk_journal "$R")")"
  if [ "$control" = every-ask ]; then
    sk_assert_red "$READ_ROW" "0=0=$READ_ASK" "$name: posting every open ask fails the read-ask row"
    sk_bin_reset
    continue
  fi
  assert_eq "$READ_ROW" "0=0=$READ_ASK" "$name: an ask at or below the seen count is journaled skipped and never posted"
  assert_eq "$(count "$CH_R" "Unread by the session in $name?")=$(resumed_asks "$R")" "1=$UNREAD_ASK" \
    "$name: an ask past the seen count posts and is journaled landed"
  assert_eq "$(sk_state ".messages.${CH_R}[] | select(.text | contains(\"Unread by the session in $name?\")) | .text | startswith(\"<@U001> <@U002> \")")" \
    "true" "$name: the ask past the count carries the owners' mention"
  if [ "$reserved" = yes ]; then
    # Poll with the same relay state, then replay after compaction. The mailbox's
    # deadline is fixture input, so expiry needs no elapsed-time wait.
    jq -c --arg read "$READ_ASK" --arg unread "$UNREAD_ASK" 'if .id == $read or .id == $unread then .deadline = "2000-01-01T00:00:00Z" else . end' "$(sk_box "$R")/to-overseer.jsonl" > "$SK_TMP/expired.jsonl"
    mv "$SK_TMP/expired.jsonl" "$(sk_box "$R")/to-overseer.jsonl"
    sk_relay_start "$R" "$HOLD"
    polled_after "$R" 0 || exit 1
    polls "$R"
    sk_relay_stop
    RESERVED_ROW="$(count "$CH_R" "Read by the session in $name?")=$(sk_state "[.messages.${CH_R}[] | select(.thread_ts != null and (.text | startswith(\"<@U001> <@U002> \")))] | length")"
    case "$control" in
      overdue) sk_assert_red "$RESERVED_ROW" "0=1" "$name: carried seen asks must not become overdue mentions" ;;
      *) assert_eq "$RESERVED_ROW" "0=1" "$name: later polls remind only the posted unread reserved ask" ;;
    esac
    sk_run -- compact --root "$R"
    sk_poll "$R" "$HOLD"
    case "$control" in
      overdue) sk_assert_red "$(count "$CH_R" "Read by the session in $name?")" 0 "$name: replay must keep a seen reserved ask out of overdue mentions" ;;
      *) assert_eq "$(count "$CH_R" "Read by the session in $name?")=$(sk_state "[.messages.${CH_R}[] | select(.thread_ts != null and (.text | startswith(\"<@U001> <@U002> \")))] | length")" "0=1" "$name: compaction and replay preserve suppression and the single unread reminder" ;;
    esac
  fi
  sk_bin_reset
done <<'ROWS'
real real no after
closed real no closed
every-ask-control every-ask no after
reserved-expired real yes before
reserved-later real yes after
reserved-overdue-control overdue yes after
ROWS

# --- root-local settings through the real launcher and one two-root poll ----------
# The installed unit runs in the first root. The control replaces the caller
# snapshot with the loaded process environment, recreating the launch-root leak.
while read -r name first control a_posts a_held; do
  A="$(sk_new_root "pair-$name-a")"
  B="$(sk_new_root "pair-$name-b")"
  sk_bind "$A"
  sk_bind "$B"
  FILE="$B/tmp/jarvis-session-live"
  touch -- "$FILE"
  sk_age_file "$FILE" 10
  printf '[env]\nSLACK_JARVIS_SESSION_FILE = "%s"\nSLACK_JARVIS_SESSION_MAX_AGE = "600"\n' "$FILE" > "$B/kendex.settings.toml"
  if [ "$first" = A ]; then FIRST="$A"; SECOND="$B"; else FIRST="$B"; SECOND="$A"; fi
  SK_RUN_FROM="$FIRST"
  sk_run -- listen --once --root "$FIRST" --root "$SECOND"
  assert_eq "$RC" "0" "$name: both roots seed in one process"
  notice "$A" "pair-$name-a" "Pair notice $name A."
  notice "$B" "pair-$name-b" "Pair notice $name B."
  case "$control" in
    leak) sk_mutant process-presence settings.py 'env=CALLER_ENV' 'env=dict(os.environ)' ;;
    launch) sk_mutant caller-snapshot ../slack 'export _KENDEX_SLACK_CALLER_ENV="\$_slack_caller_env"' 'export _KENDEX_SLACK_CALLER_ENV="$(python3 -c '\''import json, os; print(json.dumps(dict(os.environ)))'\'')"' ;;
  esac
  sk_run -- listen --once --root "$FIRST" --root "$SECOND"
  assert_eq "$RC=$(count "$(sk_channel "$A")" "Pair notice $name A.")=$(count "$(sk_channel "$B")" "Pair notice $name B.")" \
    "0=$a_posts=0" "$name: only roots with a fresh configured file hold (control must hold A)"
  sk_run -- listen --status --root "$A" --root "$B"
  assert_has "$OUT" "slack-relay=$B state=ok" "$name: B has its own status row"
  assert_has "$OUT" "held-by=jarvis" "$name: status reports the Jarvis session hold"
  assert_eq "$(jq -r 'if .held_by == "" then "none" else .held_by end' "$A/tmp/slack/status.json")=$(jq -r .held_by "$B/tmp/slack/status.json")" \
    "$a_held=jarvis" "$name: the hold belongs to B only, unless the control leaks"
  sk_bin_reset
  sk_age_file "$FILE" 900
  sk_run -- listen --once --root "$FIRST" --root "$SECOND"
  assert_eq "$RC=$(count "$(sk_channel "$A")" "Pair notice $name A.")=$(count "$(sk_channel "$B")" "Pair notice $name B.")" \
    "0=1=1" "$name: stale B posts on the next poll and A never repeats"
  SK_RUN_FROM=""
done <<'ROWS'
A-first A real 1 none
B-first B real 1 none
B-first-control B leak 0 jarvis
B-first-launcher-control B launch 0 jarvis
ROWS

# Both files have the same age, but each root has its own freshness bound.
A="$(sk_new_root ages-a)"
B="$(sk_new_root ages-b)"
for R in "$A" "$B"; do sk_bind "$R"; done
printf '[env]\nSLACK_JARVIS_SESSION_FILE = "%s"\nSLACK_JARVIS_SESSION_MAX_AGE = "3600"\n' "$JARVIS_SESSION" > "$A/kendex.settings.toml"
printf '[env]\nSLACK_JARVIS_SESSION_FILE = "%s"\nSLACK_JARVIS_SESSION_MAX_AGE = "600"\n' "$JARVIS_SESSION" > "$B/kendex.settings.toml"
fresh
SK_RUN_FROM="$A"
sk_run -- listen --once --root "$A" --root "$B"
notice "$A" ages-a 'Age notice A.'
notice "$B" ages-b 'Age notice B.'
aged 900
sk_run -- listen --once --root "$A" --root "$B"
assert_eq "$RC=$(count "$(sk_channel "$A")" 'Age notice A.')=$(count "$(sk_channel "$B")" 'Age notice B.')" \
  "0=0=1" "different root age bounds hold A while B posts"
aged 4000
sk_run -- listen --once --root "$A" --root "$B"
assert_eq "$RC=$(count "$(sk_channel "$A")" 'Age notice A.')=$(count "$(sk_channel "$B")" 'Age notice B.')" \
  "0=1=1" "A resumes at its own bound and B never repeats"
SK_RUN_FROM=""

# The real settings reader resolves aliases per root. Both roots read the
# same retired pair in one process, so each fallback warning appears once.
while read -r name source new_file new_age held warnings control; do
  R="$(sk_new_root "alias-$name")"; S="$(sk_new_root "alias-peer-$name")"
  sk_bind "$R"; sk_bind "$S"
  fresh; aged 900
  for ROOT_ALIAS in "$R" "$S"; do
    case "$source" in
      private) SETTINGS_FILE="$ROOT_ALIAS/.env.local" ;;
      *) SETTINGS_FILE="$ROOT_ALIAS/kendex.settings.toml"; printf '[env]\n' > "$SETTINGS_FILE" ;;
    esac
    printf 'SLACK_MASTER_FILE="%s"\nSLACK_MASTER_MAX_AGE="3600"\n' "$JARVIS_SESSION" >> "$SETTINGS_FILE"
    case "$new_file" in
      absent) ;;
      empty) printf 'SLACK_JARVIS_SESSION_FILE=""\n' >> "$SETTINGS_FILE" ;;
      fresh) printf 'SLACK_JARVIS_SESSION_FILE="%s"\n' "$JARVIS_SESSION" >> "$SETTINGS_FILE" ;;
    esac
    case "$new_age" in
      absent) ;;
      empty) printf 'SLACK_JARVIS_SESSION_MAX_AGE=""\n' >> "$SETTINGS_FILE" ;;
      *) printf 'SLACK_JARVIS_SESSION_MAX_AGE="%s"\n' "$new_age" >> "$SETTINGS_FILE" ;;
    esac
  done
  sk_run -- listen --once --root "$R" --root "$S"
  notice "$R" "alias-$name" "Alias notice $name."
  case "$control" in
    alias) sk_mutant no-alias settings.py 'if name not in values and old in values:' 'if False:' ;;
    precedence) sk_mutant old-wins settings.py 'if name not in values and old in values:' 'if old in values:' ;;
    warning) sk_mutant repeated-warning settings.py 'if old not in RENAMED_SETTINGS:' 'if True:' ;;
    status) sk_mutant retired-status settings.py 'JARVIS_SESSION = "jarvis"' 'JARVIS_SESSION = "retired"' ;;
  esac
  sk_run -- listen --once --root "$R" --root "$S"
  POSTS="$(count "$(sk_channel "$R")" "Alias notice $name.")"
  HELD="$(jq -r .held_by "$R/tmp/slack/status.json")"
  WARNINGS="$(printf '%s\n' "$ERR" | grep -c '^setting-renamed old=')"
  EXPECTED_HELD=""; [ "$held" != 1 ] || EXPECTED_HELD=jarvis
  case "$control" in
    alias|precedence|status) sk_assert_red "$RC=$POSTS=$HELD" "0=$((1 - held))=$EXPECTED_HELD" "$name: the hold contract rejects the mutant" ;;
    *) assert_eq "$RC=$POSTS=$HELD" "0=$((1 - held))=$EXPECTED_HELD" "$name: the selected keys set the hold" ;;
  esac
  case "$control" in
    warning) sk_assert_red "$WARNINGS" "$warnings" "$name: the warning contract rejects the mutant" ;;
    alias|precedence) ;;
    *) assert_eq "$WARNINGS" "$warnings" "$name: each fallback warns once across both roots" ;;
  esac
  if [ "$control" = real ] && [ "$warnings" = 2 ]; then
    assert_eq "$ERR" 'setting-renamed old=SLACK_MASTER_FILE new=SLACK_JARVIS_SESSION_FILE
setting-renamed old=SLACK_MASTER_MAX_AGE new=SLACK_JARVIS_SESSION_MAX_AGE' "$name: diagnostics name each replacement key"
  fi
  sk_bin_reset
done <<'ROWS'
legacy toml absent absent 1 2 real
private-legacy private absent absent 1 2 real
new-file toml empty absent 0 1 real
new-age toml fresh 600 0 0 real
new-empty-age toml fresh empty 0 0 real
alias-control toml absent absent 1 2 alias
precedence-control toml empty absent 0 1 precedence
warning-control toml absent absent 1 2 warning
status-control toml absent absent 1 2 status
ROWS

# Each source is loaded by kendex_load_project_env. Tokens and owners in a
# served root must not replace the process settings from the launch checkout.
# Private files permit bare assignments. The export control keeps their shell
# values but prevents the Python child from receiving them.
while read -r name source file age caller control posts; do
  R="$(sk_new_root "settings-$name")"
  sk_bind "$R"
  sk_poll "$R"
  mkdir -p "$R/.kendex"
  case "$file" in
    relative) FILE="tmp/jarvis-session-live"; touch -- "$R/$FILE"; sk_age_file "$R/$FILE" 900 ;;
    tilde) FILE="~/jarvis-session-live"; touch -- "$SK_TMP/home/jarvis-session-live"; sk_age_file "$SK_TMP/home/jarvis-session-live" 900 ;;
    absent) FILE="" ;;
    *) FILE="$JARVIS_SESSION"; fresh; aged 900 ;;
  esac
  printf '[env]\nSLACK_BOT_TOKEN = "wrong-root-token"\nSLACK_OWNERS = "wrong@example.test"\nSLACK_API_URL = "http://invalid.test"\n' > "$R/kendex.settings.toml"
  case "$source" in
    local|private|named) printf 'SLACK_JARVIS_SESSION_FILE = "%s"\nSLACK_JARVIS_SESSION_MAX_AGE = "600"\n' "$FILE" >> "$R/kendex.settings.toml" ;;
  esac
  case "$source" in
    local) printf '[env]\nSLACK_JARVIS_SESSION_MAX_AGE = "%s"\n' "$age" > "$R/.kendex/settings.toml" ;;
    private) printf '[env]\nSLACK_JARVIS_SESSION_MAX_AGE = "600"\n' > "$R/.kendex/settings.toml"; printf 'SLACK_JARVIS_SESSION_MAX_AGE=%s\n' "$age" > "$R/.env.local" ;;
    named) printf 'SLACK_JARVIS_SESSION_MAX_AGE=%s\n' "$age" > "$R/private.env"; printf 'KENDEX_ENV_FILE = "private.env"\n' >> "$R/kendex.settings.toml" ;;
    private-only) printf 'SLACK_JARVIS_SESSION_FILE=%s\nSLACK_JARVIS_SESSION_MAX_AGE=%s\n' "$FILE" "$age" > "$R/.env.local" ;;
    named-only) printf 'SLACK_JARVIS_SESSION_FILE=%s\nSLACK_JARVIS_SESSION_MAX_AGE=%s\n' "$FILE" "$age" > "$R/private.env"; printf 'KENDEX_ENV_FILE = "private.env"\n' >> "$R/kendex.settings.toml" ;;
    private-age) printf 'SLACK_JARVIS_SESSION_MAX_AGE=%s\n' "$age" > "$R/.env.local" ;;
    named-age) printf 'SLACK_JARVIS_SESSION_MAX_AGE=%s\n' "$age" > "$R/private.env"; printf 'KENDEX_ENV_FILE = "private.env"\n' >> "$R/kendex.settings.toml" ;;
  esac
  case "$control" in
    export) sk_mutant presence-export settings.py 'export "\$@"' ':' ;;
  esac
  notice "$R" "settings-$name" "Settings notice $name."
  case "$caller" in
    age) sk_poll "$R" SLACK_JARVIS_SESSION_MAX_AGE=600 ;;
    file) sk_poll "$R" "SLACK_JARVIS_SESSION_FILE=$SK_TMP/no-jarvis-session" ;;
    empty) sk_poll "$R" SLACK_JARVIS_SESSION_FILE= ;;
    configured-file) sk_poll "$R" "SLACK_JARVIS_SESSION_FILE=$FILE" ;;
    *) sk_poll "$R" ;;
  esac
  assert_eq "$RC=$(count "$(sk_channel "$R")" "Settings notice $name.")" "0=$posts" \
    "$name: root settings and caller precedence apply only to presence"
  sk_bin_reset
done <<'ROWS'
relative local relative 3600 none real 0
tilde private tilde 3600 none real 0
named named absolute 3600 none real 0
caller-age private absolute 3600 age real 1
caller-file local absolute 3600 file real 1
caller-empty private absolute 3600 empty real 1
root-empty local absent 3600 none real 1
private-only private-only absolute 3600 none real 0
named-only named-only absolute 3600 none real 0
private-age private-age absolute 3600 configured-file real 0
named-age named-age absolute 3600 configured-file real 0
private-caller-age private-only absolute 3600 age real 1
private-caller-file private-only absolute 3600 file real 1
private-caller-empty private-only absolute 3600 empty real 1
private-export-control private-only absolute 3600 none export 1
private-age-export-control private-age absolute 3600 configured-file export 1
ROWS

R="$(sk_new_root invalid-age)"
sk_bind "$R"
S="$(sk_new_root startup-settings-peer)"
sk_bind "$S"
sk_poll "$S"
printf '[env]\nSLACK_JARVIS_SESSION_MAX_AGE = "invalid"\n' > "$R/kendex.settings.toml"
notice "$S" startup-invalid-age 'Healthy after invalid startup age.'
sk_run -- listen --once --root "$S" --root "$R"
assert_eq "$RC=$(count "$(sk_channel "$S")" 'Healthy after invalid startup age.')" "1=1" \
  "an invalid root age skips that root while the healthy root posts"
assert_has "$ERR1" "slack: setting-invalid=SLACK_JARVIS_SESSION_MAX_AGE=invalid root=$R" \
  "the invalid age diagnostic names the refused root even without a file"
printf '[env]\nSLACK_JARVIS_SESSION_FILE = []\n' > "$R/kendex.settings.toml"
notice "$S" startup-unreadable-setting 'Healthy after unreadable startup setting.'
sk_run -- listen --once --root "$S" --root "$R"
assert_eq "$RC=$(count "$(sk_channel "$S")" 'Healthy after unreadable startup setting.')" "1=1" \
  "an unreadable root setting skips that root while the healthy root posts"
assert_has "$ERR1" "slack: setting-invalid=root=$R settings-reader=" "the root settings failure names its root and reader"

# --- changed files update a running relay, without restarting it -------------------
# An installed package update re-executes the relay with its original caller
# environment. Retired keys keep their hold and warnings across that re-exec.
while read -r name control; do
  R="$(sk_new_root "reload-alias-$name")"
  sk_bind "$R"
  fresh; aged 900
  printf '[env]\nSLACK_MASTER_FILE="%s"\nSLACK_MASTER_MAX_AGE="3600"\n' "$JARVIS_SESSION" > "$R/kendex.settings.toml"
  case "$control" in
    warning) sk_mutant reload-warnings relay.py 'json.dumps\(sorted\(RENAMED_SETTINGS\)\)' 'json.dumps([])' ;;
    *) sk_copy reload-alias ;;
  esac
  sk_relay_start "$R"
  PID="$(jq -r .pid "$R/tmp/slack/status.json")"
  BEFORE_CODE="$(jq -r .code "$R/tmp/slack/status.json")"
  notice "$R" "reload-alias-$name" "Held across update $name."
  AFTER="$(jq -r .last_poll "$R/tmp/slack/status.json")"
  polled_after "$R" "$AFTER" || exit 1
  printf '\n' >> "${SK_BIN%/*}/lib/relay.py"
  TRIES=0
  while [ "$(jq -r .code "$R/tmp/slack/status.json")" = "$BEFORE_CODE" ] && [ "$TRIES" -lt 100 ]; do
    TRIES=$((TRIES + 1)); sleep 0.1
  done
  assert_lacks "$(jq -r .code "$R/tmp/slack/status.json")" "$BEFORE_CODE" "$name: the package update completes its reload"
  assert_eq "$(jq -r '.pid,.held_by' "$R/tmp/slack/status.json" | tr '\n' '=')$(count "$(sk_channel "$R")" "Held across update $name.")" \
    "$PID=jarvis=0" "$name: the same process keeps its old-key hold after reload"
  sk_relay_stop
  WARNINGS="$(grep -c '^setting-renamed old=' "$SK_TMP/relay.err")"
  case "$control" in
    warning) sk_assert_red "$WARNINGS" 2 "$name: repeated warnings after reload fail the process limit" ;;
    *) assert_eq "$WARNINGS" 2 "$name: reload issues no repeated fallback warnings" ;;
  esac
  sk_bin_reset
done <<'ROWS'
legacy real
warning-control warning
ROWS

live_setting() { # ROOT SOURCE AGE
  case "$2" in
    toml) printf '[env]\nSLACK_JARVIS_SESSION_FILE = "%s"\nSLACK_JARVIS_SESSION_MAX_AGE = "%s"\n' "$JARVIS_SESSION" "$3" > "$1/kendex.settings.toml" ;;
    local) mkdir -p "$1/.kendex"; printf '[env]\nSLACK_JARVIS_SESSION_FILE = "%s"\nSLACK_JARVIS_SESSION_MAX_AGE = "%s"\n' "$JARVIS_SESSION" "$3" > "$1/.kendex/settings.toml" ;;
    private) printf 'SLACK_JARVIS_SESSION_FILE=%s\nSLACK_JARVIS_SESSION_MAX_AGE=%s\n' "$JARVIS_SESSION" "$3" > "$1/.env.local" ;;
    named) printf '[env]\nKENDEX_ENV_FILE = "private.env"\n' > "$1/kendex.settings.toml"; printf 'SLACK_JARVIS_SESSION_FILE=%s\nSLACK_JARVIS_SESSION_MAX_AGE=%s\n' "$JARVIS_SESSION" "$3" > "$1/private.env" ;;
  esac
}
while read -r name source caller control; do
  R="$(sk_new_root "live-$name")"; S="$(sk_new_root "peer-$name")"
  sk_bind "$R"; sk_bind "$S"
  CHANNEL="$(sk_channel "$R")"; PEER_CHANNEL="$(sk_channel "$S")"
  if [ "$control" = mutant ]; then
    sk_mutant no-poll-presence relay.py 'presence = load_presence\(self.path\)' 'presence = self.presence'
  fi
  if [ "$control:$caller" = real:none ]; then
    sk_copy "resume-$name"
    # Pause the real refused poll before it records its completion time.
    # Removal then precedes that old reading's status write on every run.
    python3 - "${SK_BIN%/*}/lib/relay.py" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
needle = '        delivered = max(self.state.delivered, key=float, default="")'
assert text.count(needle) == 1
barrier = '''        arm = self.path / "tmp/resume-arm"
        if not ok and "setting-invalid" in error and arm.exists():
            arm.unlink()
            (self.path / "tmp/resume-entered").touch()
            while not (self.path / "tmp/resume-release").exists():
                time.sleep(0.01)
'''
path.write_text(text.replace(needle, barrier + needle))
PY
    [ "$?" -eq 0 ] || exit 1
  fi
  case "$caller" in
    empty) sk_relay_start "$R" --root "$S" SLACK_JARVIS_SESSION_FILE= ;;
    *) sk_relay_start "$R" --root "$S" ;;
  esac
  polled_after "$S" 0 || exit 1
  PID="$(jq -r .pid "$R/tmp/slack/status.json")"
  row "$R"; assert_lacks "$LINE" held-by= "$name: first root starts without a hold"
  row "$S"; assert_lacks "$LINE" held-by= "$name: second root starts without a hold"
  fresh
  live_setting "$R" "$source" 3600
  notice "$R" "live-$name-held" "Changed hold $name."
  notice "$S" "live-$name-peer" "Peer notice $name."
  AFTER="$(jq -r .last_poll "$R/tmp/slack/status.json")"
  PEER_AFTER="$(jq -r .last_poll "$S/tmp/slack/status.json")"
  polled_after "$R" "$AFTER" || exit 1
  polled_after "$S" "$PEER_AFTER" || exit 1
  row "$R"
  case "$caller:$control" in
    empty:real)
      assert_lacks "$LINE" held-by= "$name: caller's empty export still wins after the file changes"
      assert_eq "$(count "$CHANNEL" "Changed hold $name.")" 1 "$name: caller override permits the notice" ;;
    *:mutant)
      sk_assert_red "$(field "$LINE" held-by)=$(count "$CHANNEL" "Changed hold $name.")" "jarvis=0" \
        "control: dropping the per-poll read fails the running hold assertion" ;;
    *)
      assert_eq "$(field "$LINE" state)=$(field "$LINE" held-by)=$(count "$CHANNEL" "Changed hold $name.")" "ok=jarvis=0" \
        "$name: the changed setting holds on the next completed poll"
      live_setting "$R" "$source" invalid
      notice "$R" "live-$name-invalid" "Invalid hold $name."
      AFTER="$(jq -r .last_poll "$R/tmp/slack/status.json")"
      polled_after "$R" "$AFTER" || exit 1
      row "$R"
      assert_eq "$(field "$LINE" state)=$(field "$LINE" held-by)=$(count "$CHANNEL" "Invalid hold $name.")" "failing=jarvis=0" \
        "$name: a refused reading retains the hold and posts nothing"
      assert_has "$(jq -r .last_error "$R/tmp/slack/status.json")" "setting-invalid=SLACK_JARVIS_SESSION_MAX_AGE=invalid root=$R" \
        "$name: the refused reading names its root"
      row "$S"; assert_eq "$(field "$LINE" state)" ok "$name: a refused reading leaves its peer ok"
      touch "$R/tmp/resume-arm" || exit 1
      TRIES=0
      while [ ! -f "$R/tmp/resume-entered" ] && [ "$TRIES" -lt 100 ]; do
        TRIES=$((TRIES + 1)); sleep 0.1
      done
      [ -f "$R/tmp/resume-entered" ] || { bad "refused poll did not reach the resume barrier" "$R"; exit 1; }
      case "$source" in
        toml) rm -- "$R/kendex.settings.toml" ;;
        local) rm -- "$R/.kendex/settings.toml" ;;
        private) printf 'SLACK_JARVIS_SESSION_FILE=\n' > "$R/.env.local" ;;
        named) printf 'SLACK_JARVIS_SESSION_FILE=\n' > "$R/private.env" ;;
      esac
      AFTER="$(jq -r .last_poll "$R/tmp/slack/status.json")"
      touch "$R/tmp/resume-release" || exit 1
      # A refused poll can finish after removal. Its timestamp does not
      # acknowledge the new setting; wait for a successful, unheld poll.
      polled_after "$R" "$AFTER" true || exit 1
      row "$R"; assert_eq "$(field "$LINE" state)=$(field "$LINE" held-by)" "ok=" "$name: removing or emptying the setting resumes"
      assert_eq "$(count "$CHANNEL" "Changed hold $name.")=$(count "$CHANNEL" "Invalid hold $name.")" "1=1" \
        "$name: resume posts the held notices once"
      AFTER="$(jq -r .last_poll "$R/tmp/slack/status.json")"
      polled_after "$R" "$AFTER" || exit 1
      assert_eq "$(count "$CHANNEL" "Changed hold $name.")" 1 "$name: the resumed notice never repeats" ;;
  esac
  assert_eq "$(count "$PEER_CHANNEL" "Peer notice $name.")" 1 "$name: the other root posts its notice"
  assert_eq "$(jq -r .pid "$R/tmp/slack/status.json")" "$PID" "$name: settings changes keep the running pid"
  assert_lacks "$(cat "$SK_TMP/relay.out" "$SK_TMP/relay.err")" reloading= "$name: settings changes trigger no code reload"
  sk_relay_stop
  sk_bin_reset
done <<'ROWS'
toml toml none real
local local none real
private private none real
named named none real
caller-empty toml empty real
no-read toml none mutant
ROWS

# --- a renamed presence file holds until the new file is fresh -------------------
# The setting moves to a file nothing wrote yet while the old one is fresh: a
# running relay stays held and posts no ask. A fresh new file keeps the hold.
# At the end the new file is stale and the old one is aged OLD_END: stale, so
# both files are; or fresh, so only the drop of the old path once the new one
# was fresh lets the hold end. Each control reds one rule.
while read -r name control old_end; do
  R="$(sk_new_root "rename-$name")"
  sk_bind "$R"
  CHANNEL="$(sk_channel "$R")"
  OLD="$SK_TMP/rename-$name-old"; NEW="$SK_TMP/rename-$name-new"
  touch -- "$OLD"; sk_age_file "$OLD" 10
  printf '[env]\nSLACK_JARVIS_SESSION_FILE = "%s"\n' "$OLD" > "$R/kendex.settings.toml"
  case "$control" in
    new-only) sk_mutant rename-new-only relay.py 'if self\.replaced_session_file and not' 'if False and not' ;;
    keep) sk_mutant rename-keep relay.py 'if self\.replaced_session_file and not presence_fresh\(touched, self\.presence, now\):' 'if self.replaced_session_file:' ;;
    post) sk_mutant rename-post verbs.py 'if jarvis_session_held\(root, presence, time.time\(\)\):' 'if __import__("relay").presence_fresh(__import__("relay").touched_at(presence.jarvis_session_file), presence, time.time()):' ;;
  esac
  sk_relay_start "$R"
  polled_after "$R" 0 || exit 1
  ask "$R" "rename-$name" "Asked across the rename in $name?" >/dev/null
  printf '[env]\nSLACK_JARVIS_SESSION_FILE = "%s"\n' "$NEW" > "$R/kendex.settings.toml"
  polls "$R"
  row "$R"
  RENAMED="$(field "$LINE" held-by)=$(count "$CHANNEL" "Asked across the rename in $name?")"
  case "$control" in
    new-only) sk_assert_red "$RENAMED" "jarvis=0" "control: reading only the new path resumes and posts the ask at the rename" ;;
    *) assert_eq "$RENAMED" "jarvis=0" "$name: the replaced fresh file holds while the new one is absent" ;;
  esac
  if [ "$control" != new-only ]; then
    sk_run -- post --root "$R" --text "Explicit across rename $name." --mention
    POST_ROW="$RC=$(sk_state ".messages.${CHANNEL}[-1].text | startswith(\"<@\")")=$(printf '%s\n' "$ERR" | grep -c '^slack: mention-held=')"
    case "$control" in
      post) sk_assert_red "$POST_ROW" "0=false=1" "$name: reading only the current presence path mentions during a held rename" ;;
      *) assert_eq "$POST_ROW" "0=false=1" "$name: explicit post uses the retained hold and prints one mention-held line" ;;
    esac
  fi
  if [ "$control" != new-only ]; then
    touch -- "$NEW"; sk_age_file "$NEW" 10
    polls "$R"
    row "$R"
    assert_eq "$(field "$LINE" held-by)=$(count "$CHANNEL" "Asked across the rename in $name?")" "jarvis=0" \
      "$name: the new file written fresh keeps the hold"
    sk_run -- post --root "$R" --text "Explicit after takeover $name." --mention
    assert_eq "$RC=$(sk_state ".messages.${CHANNEL}[-1].text | startswith(\"<@\")")=$(printf '%s\n' "$ERR" | grep -c '^slack: mention-held=')" "0=false=1" \
      "$name: explicit post keeps holding after the new file takes ownership"
    sk_age_file "$NEW" 900; sk_age_file "$OLD" "$old_end"
    polls "$R"
    row "$R"
    ENDED="$(field "$LINE" held-by)=$(count "$CHANNEL" "Asked across the rename in $name?")"
    case "$control" in
      keep) sk_assert_red "$ENDED" "=1" "control: keeping the replaced path after the new file was fresh holds past its end" ;;
      *) assert_eq "$ENDED" "=1" "$name: the hold ends with the new file stale and the old one aged $old_end, and the ask posts once" ;;
    esac
    if [ "$control" != keep ]; then
      sk_run -- post --root "$R" --text "Explicit after release $name." --mention
      assert_eq "$RC=$(sk_state ".messages.${CHANNEL}[-1].text | startswith(\"<@U001> <@U002> \")")=$(printf '%s\n' "$ERR" | grep -c '^slack: mention-held=')" "0=true=0" \
        "$name: explicit post restores mentions after the relay releases its hold"
    fi
  fi
  sk_relay_stop
  sk_bin_reset
done <<'ROWS'
both-stale real 900
dropped real 10
read-new-control new-only 900
keep-control keep 10
post-control post 10
ROWS

# A real 429 retry waits through the API's injectable sleep. Move the clock
# by its Retry-After and post from a separate process inside that wait. The
# same table covers startup, a retained rename, a new hold and process exit.
while read -r name control; do
  R="$(sk_new_root "retry-hold-$name")"; sk_bind "$R"
  OLD="$SK_TMP/retry-$name-old"; NEW="$SK_TMP/retry-$name-new"
  case "$control" in
    startup) sk_mutant hold-startup relay.py '            root.prepare_hold\(\)' '            pass' ;;
    poll) sk_mutant hold-poll relay.py '        self.prepare_hold\(\)' '        pass' ;;
    post) sk_mutant hold-retry-post relay.py 'if RelayLock\(root, JARVIS_LOCK\).held\(\):' 'if False and RelayLock(root, JARVIS_LOCK).held():' ;;
  esac
  OUT="$(env -i PATH="$PATH" HOME="$SK_TMP/home" LANG=C PYTHONDONTWRITEBYTECODE=1 \
    GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" \
    SLACK_BOT_TOKEN="$SK_TOKEN" SLACK_OWNERS="$OWNERS" SLACK_API_URL="$SK_URL" \
    SLACK_ORCH_DIR="$SK_ROOT/skills/orch" SLACK_LINEAR_DIR="$SK_LINEAR_STUB" \
    python3 - "${SK_BIN%/*}/lib" "$SK_BIN" "$R" "$OLD" "$NEW" <<'PY'
import json, os, pathlib, subprocess, sys, time, urllib.request
sys.path.insert(0, sys.argv[1])
from api import Slack
from relay import Relay
from settings import load
from store import JARVIS_LOCK, RelayLock
binary, root, old, new = sys.argv[2], *map(pathlib.Path, sys.argv[3:])
settings = load()
settings.poll_seconds = 1
now = time.time() - 60
phase = "startup"
rows = []
def presence(path, fresh):
    path.touch()
    stamp = now - (10 if fresh else 900)
    os.utime(path, (stamp, stamp))
def setting(path):
    (root / "kendex.settings.toml").write_text('[env]\nSLACK_JARVIS_SESSION_FILE = "' + str(path) + '"\n')
api = Slack(settings.token, settings.api_url)
def fixture(path, **body):
    request = urllib.request.Request(settings.api_url + "/_test/" + path, json.dumps(body).encode())
    return json.load(urllib.request.urlopen(request))
def waiting(seconds):
    global now
    assert seconds == 60, seconds
    now += seconds
    held = RelayLock(root, JARVIS_LOCK).held()
    status = root / "tmp/slack/status.json"
    stale = not status.exists() or time.time() - json.loads(status.read_text())["last_poll"] > 7
    result = subprocess.run([binary, "post", "--root", str(root), "--text", "Retry " + phase, "--mention"],
                            capture_output=True, text=True, timeout=10)
    assert result.returncode == 0, result.stderr
    message = json.load(urllib.request.urlopen(settings.api_url + "/_test/state"))["messages"][channel][-1]
    rows.append([held, stale, message["text"].startswith("<@"),
                 sum(line.startswith("slack: mention-held=") for line in result.stderr.splitlines())])
api.sleep = waiting
channel = json.loads((root / "tmp/slack/binding.json").read_text())["channel"]
presence(old, True); setting(old)
fixture("fault", method="auth.test", status=429, times=1, retry_after=60)
listener = Relay([root], settings, api, clock=lambda: now)
relay = listener.roots[0]
startup_held = RelayLock(root, JARVIS_LOCK).held()
# Leave a real delivered message without its courtesy mark for the next poll.
fixture("message", channel=channel, user="U001", text="Hold retry directive.")
fixture("fault", method="reactions.add", error="not_in_channel", times=1)
now -= 60
assert listener.poll_once()
setting(new)
phase = "rename"
fixture("fault", method="reactions.add", status=429, times=1, retry_after=60)
assert listener.poll_once()
assert relay.state.held and old.exists() and not new.exists()
# Release both files, then a new fresh file must publish before mark_seen waits.
presence(old, False); presence(new, False)
assert listener.poll_once()
assert not RelayLock(root, JARVIS_LOCK).held()
presence(new, True)
relay.state.marks.clear()
phase = "new-hold"
now -= 60
relay.record_status(True, "", listener.code, "disconnected", listener.since, "")
fixture("fault", method="reactions.add", status=429, times=1, retry_after=60)
assert listener.poll_once()
# The final hold survives until this owner exits. Age the current file so the
# The next shell post can only regain mentions through OS release at exit.
presence(new, False)
print("retry-rows=" + json.dumps([startup_held, rows], separators=(",", ":")))
PY
)"; RETRY_RC=$?
  RETRY_ROW="$(printf '%s\n' "$OUT" | sed -n 's/^retry-rows=//p')"
  if [ "$control" = real ]; then
    assert_eq "$RETRY_RC=$RETRY_ROW" '0=[true,[[false,true,false,1],[true,true,false,1],[true,true,false,1]]]' \
      "$name: startup publishes the hold after global authentication; root retries keep it despite stale health"
  else
    sk_assert_red "$RETRY_RC=$RETRY_ROW" '0=[true,[[false,true,false,1],[true,true,false,1],[true,true,false,1]]]' \
      "$name: the same retry state table fails without early publication or shared ownership"
  fi
  sk_run -- post --root "$R" --text "Stopped retry $name." --mention
  CHANNEL="$(sk_channel "$R")"
  assert_eq "$RC=$(sk_state ".messages.${CHANNEL}[-1].text | startswith(\"<@U001> <@U002> \")")=$(printf '%s\n' "$ERR" | grep -c '^slack: mention-held=')" '0=true=0' \
    "$name: process exit releases the lock even when its health record reports held"
  sk_bin_reset
done <<'ROWS'
retry real
startup-control startup
poll-control poll
retry-post-control post
ROWS

# Count calls through the real Relay start and poll owners. A stub returns
# an unconfigured presence pair; no parser or API behavior is under test here.
R="$(sk_new_root presence-count)"; S="$(sk_new_root presence-count-peer)"
sk_bind "$R"; sk_bind "$S"
OUT="$(env -i PATH="$PATH" HOME="$SK_TMP/home" LANG=C PYTHONDONTWRITEBYTECODE=1 \
  GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" \
  python3 - "${SK_BIN%/*}/lib" "$R" "$S" <<'PY'
import collections, pathlib, sys
sys.path.insert(0, sys.argv[1])
import relay
from settings import Presence, Settings
roots = [pathlib.Path(path) for path in sys.argv[2:]]
calls = collections.Counter()
def reader(root):
    calls[root] += 1
    return Presence("", 600)
class API:
    def get(self, method):
        assert method == "auth.test"
        return {"user_id": "UBOT"}
relay.load_presence = reader
listener = relay.Relay(roots, Settings("", "", [], 1, 7, ""), API(), clock=lambda: 0)
try:
    for root in listener.roots:
        root.ready = lambda: None
        root.due = None
        root.mark_seen = lambda delivered: None
        root.mark_read = lambda: None
        root.mail.events = lambda: []
    for _ in range(3):
        for root in listener.roots:
            root.poll("UBOT")
    assert [calls[root] for root in roots] == [1, 1], calls
    (roots[0] / "kendex.settings.toml").write_text('[env]\nSLACK_JARVIS_SESSION_FILE = "jarvis"\n')
    for root in listener.roots:
        root.poll("UBOT")
    assert [calls[root] for root in roots] == [2, 1], calls
    for root in listener.roots:
        root.poll("UBOT")
    assert [calls[root] for root in roots] == [2, 1], calls
    print("reader-count=ok")
finally:
    for root in listener.roots:
        root.lock.handle.close()
PY
)"; COUNT_RC=$?
assert_eq "$COUNT_RC=$OUT" "0=reader-count=ok" "unchanged polls run no reader; one changed root reads once more"

# --- controls, one mutant per rule --------------------------------------------------
# The same held reply and unrelated-notice assertions must fail when the
# held branch drops replies or posts every route.
while read -r name replacement; do
  R="$(sk_new_root "reply-control-$name")"
  sk_bind "$R"
  sk_poll "$R"
  fresh
  CHANNEL="$(sk_channel "$R")"
  TS="$(sk_inject "$CHANNEL" U001 "Still heard in $name.")"
  sk_poll "$R" "$HOLD"
  DIRECTIVE="$(jq -r 'select(.kind == "directive") | .id' "$(sk_box "$R")/to-lane.jsonl")"
  sk_lm "$R" notice --item overseer --to owner --ref "$DIRECTIVE" --file "$(sk_text "$name-reply" "Reply in $name.")" >/dev/null
  notice "$R" "$name-unrelated" "Unrelated in $name."
  sk_mutant "$name" relay.py 'self\.post_events\(\[routed for routed in self\.routes\(self\.mail\.events\(\)\) if routed\[1\] == "reply"\]\)' "$replacement"
  sk_poll "$R" "$HOLD"
  case "$name" in
    no-held-reply) sk_assert_red "$RC=$(count "$CHANNEL" "Reply in $name.")=$(sk_state ".messages.${CHANNEL}[] | select(.text | contains(\"Reply in $name.\")) | .thread_ts")" "0=1=$TS" "control: dropping held replies fails the reply row" ;;
    all-held-routes) sk_assert_red "$(count "$CHANNEL" "Unrelated in $name.")" "0" "control: posting every held route fails the unrelated-notice row" ;;
  esac
  sk_bin_reset
done <<'ROWS'
no-held-reply if False: \g<0>
all-held-routes self.post_events([routed for routed in self.routes(self.mail.events()) if True or routed[1] == "reply"])
ROWS

# held ROOT — a bound root with a notice written under a fresh file and polled.

held() {
  sk_bind "$1"
  sk_poll "$1" "$HOLD"
  fresh
  notice "$1" "n-$(basename "$1")" "Held in $(basename "$1")."
  sk_poll "$1" "$HOLD"
}

sk_mutant hold relay.py 'if presence_fresh\(touched, self\.presence, now\):' 'if False:'
BETA="$(sk_new_root beta)"
held "$BETA"
assert_eq "$(count "$(sk_channel "$BETA")" 'Held in beta.')" "1" "control: the hold check gone, a notice posts under a fresh file"
sk_bin_reset

sk_mutant once relay.py 'if not self\.state\.held:\n                self\.journal' 'if True:\n                self.journal'
GAMMA="$(sk_new_root gamma)"
held "$GAMMA"
assert_eq "$(holds "$GAMMA")" "hold hold " "control: the transition rule gone, every held poll journals a hold"
sk_bin_reset

sk_mutant count relay.py 'envelope\["line"\] <= seen' 'False'
DELTA="$(sk_new_root delta)"
fresh
sk_unposted "$DELTA" "$JARVIS_SESSION"
sk_jarvis_read "$DELTA" 3
stale
sk_poll "$DELTA" "$HOLD"
assert_eq "$(count "$(sk_channel "$DELTA")" 'Backlog in delta.')" "3" "control: the seen rule gone, all three pre-hold notices replay"
sk_bin_reset

EPSILON="$(sk_new_root epsilon)"
fresh
sk_unposted "$EPSILON" "$JARVIS_SESSION"
sk_jarvis_read "$EPSILON" 3
stale
sk_poll "$EPSILON" "$HOLD"
sk_mutant replay store.py 'self\.carried\.update\(str\(env_id\) for env_id in line\["skipped"\]\)' 'self.carried.update([])'
rm -- "$(sk_box "$EPSILON")/to-overseer.seen"
sk_poll "$EPSILON" "$HOLD"
assert_eq "$(count "$(sk_channel "$EPSILON")" 'Backlog in epsilon.')" "3" "control: without replay, skipped ids post after restart"
sk_bin_reset

sk_mutant complete-suppression relay.py 'if route == "seen"\]' 'if route == "seen" and False]'
THETA="$(sk_new_root theta)"
refused_resume "$THETA" invalid_auth >/dev/null
assert_eq "$RC=$(jq -r 'select(.t == "resume") | .skipped | length' "$(sk_journal "$THETA")")" "2=0" \
  "control: without snapshot suppression, a dead token leaves no read notice id in the resume"
rm -- "$(sk_box "$THETA")/to-overseer.seen"
sk_poll "$THETA" "$HOLD"
assert_eq "$(count "$(sk_channel "$THETA")" 'Read before the ask in theta.')" "1" \
  "control: the unrecorded read notice replays after the token refusal and restart"
sk_bin_reset

ETA="$(sk_new_root eta)"
fresh
sk_unposted "$ETA" "$JARVIS_SESSION"
sk_jarvis_read "$ETA" 3
aged 1000000000
sk_mutant age-stamp relay.py 'at = format_at\(self.clock\(\)\)' 'at = format_at(self.jarvis_session_touched() + self.presence.jarvis_session_max_age)'
sk_poll "$ETA" "$HOLD"
sk_bin_reset
sk_run -- compact --root "$ETA"
rm -- "$(sk_box "$ETA")/to-overseer.seen"
sk_poll "$ETA" "$HOLD"
assert_eq "$(count "$(sk_channel "$ETA")" 'Backlog in eta.')" "3" "control: an expiry-time stamp lets compaction drop young skipped ids and replay them"

sk_mutant clamp relay.py 'return min\(count, lines\)' 'return count'
ZETA="$(sk_new_root zeta)"
fresh
sk_unposted "$ZETA" "$JARVIS_SESSION"
sk_jarvis_read "$ZETA" 99
stale
sk_poll "$ZETA" "$HOLD"
assert_eq "$(jq -r 'select(.t == "resume") | .seen' "$(sk_journal "$ZETA")")" "99" "control: without clamping, the resume records a count past its snapshot"
sk_bin_reset

sk_mutant landed relay.py 'if self\.post_ask\(envelope\) and landed' 'if (self.post_ask(envelope) or True) and landed'
PI="$(sk_new_root pi)"
PI_ASK="$(refused_resume "$PI")"
assert_eq "$(resumed_asks "$PI")" "$PI_ASK" "control: every routed ask journaled, the resume names one Slack refused"
sk_bin_reset


sk_mutant age settings.py '_positive_int\("SLACK_JARVIS_SESSION_MAX_AGE", DEFAULT_JARVIS_SESSION_MAX_AGE, values, root\)' 'DEFAULT_JARVIS_SESSION_MAX_AGE'
IOTA="$(sk_new_root iota)"
sk_bind "$IOTA"
sk_poll "$IOTA" "$HOLD"
fresh
aged 900
notice "$IOTA" ni 'Aged in iota.'
sk_poll "$IOTA" "$HOLD" SLACK_JARVIS_SESSION_MAX_AGE=3600
assert_eq "$(count "$(sk_channel "$IOTA")" 'Aged in iota.')" "1" "control: the setting unread, a file inside SLACK_JARVIS_SESSION_MAX_AGE holds nothing"
sk_bin_reset

sk_mutant unreadable relay.py 'raise Refusal\("jarvis-session-file-unreadable", f"\{path\} \(\{err\.strerror\}\)"\) from err' 'return None'
KAPPA="$(sk_new_root kappa)"
sk_bind "$KAPPA"
sk_poll "$KAPPA"
notice "$KAPPA" nk 'Unreadable in kappa.'
sk_poll "$KAPPA" "$UNREADABLE"
assert_eq "$RC=$(count "$(sk_channel "$KAPPA")" 'Unreadable in kappa.')" "0=1" "control: the refusal turned to no Jarvis session, a notice posts past an unreadable file"
sk_bin_reset

sk_mutant status verbs.py 'if record\.get\("held_by"\) else ""' 'if False else ""'
fresh
sk_poll "$ROOT" "$HOLD"
row "$ROOT"
assert_lacks "$LINE" "held-by=" "control: the status field dropped, a standing hold is not shown"
sk_bin_reset

sk_mutant compact-hold store.py 'drop = index != last_hold' 'drop = False'
stale
sk_poll "$ROOT" "$HOLD"
sk_run -- compact --root "$ROOT"
assert_has "$(holds "$ROOT")" "hold" "control: every hold line kept, compaction leaves a closed one"
sk_bin_reset

sk_mutant compact-resume store.py 'kind == "resume":\n            drop = aged' 'kind == "resume":\n            drop = False'
fresh
sk_poll "$ROOT" "$HOLD"
stale
sk_poll "$ROOT" "$HOLD"
sk_age_resume "$ROOT" 2000-01-01T00:00:00Z
sk_run -- compact --root "$ROOT"
assert_eq "$(old_resumes "$ROOT")" "1" "control: every resume kept, compaction leaves one past the horizon"
sk_bin_reset

sk_summary
