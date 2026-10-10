#!/usr/bin/env bash
# `slack listen` under SLACK_MASTER_FILE: while the file is fresh a notice
# and an ask are held, an owner message still lands and its reply posts once
# in that message's thread,
# the hold is journaled once and `--status` shows held-by=master. Once the
# file is stale the resume posts the open ask, the answer to an ask the
# channel shows open and notices past the master's seen line count. Its
# journal records that count, the skipped ids and asks whose posts landed.
# A dead token on an earlier ask still records every later read notice id.
# A restart or a missing seen file cannot replay a skipped or posted id.
# A missing, unreadable or invalid count skips nothing; a count past the
# snapshot clamps. An absent master file or an empty setting posts as before,
# SLACK_MASTER_MAX_AGE bounds the hold, and a file whose age cannot be read
# refuses the post step alone. Compaction keeps a standing hold and the resumes inside the
# horizon. Changed root settings update the presence pair on the next poll
# without a restart; unchanged files run no settings reader. A refused read
# retains the hold and fails only that root. The controls plant one mutant per rule.
set -uo pipefail
. "$(dirname "$0")/lib/harness.sh"

sk_fake_start
echo "=== slack listen: the master hold ==="

MASTER="$SK_TMP/master-live"
HOLD="SLACK_MASTER_FILE=$MASTER"
aged() { sk_age_file "$MASTER" "$1"; } # SECONDS
fresh() { touch -- "$MASTER" && aged 10; }
stale() { aged 600; } # the default SLACK_MASTER_MAX_AGE: the hold ends as this runs
count() { sk_state "[(.messages.${1} // [])[] | select(.text | contains(\"$2\"))] | length"; } # CHANNEL TEXT
holds() { jq -r 'select(.t == "hold" or .t == "resume") | .t' "$(sk_journal "$1")" | tr '\n' ' '; } # ROOT
ask() { sk_lm "$1" ask --item overseer --to owner --file "$(sk_text "$2" "$3")" --options a,b --recommend a | sed 's/^id=//'; } # ROOT NAME TEXT
notice() { sk_lm "$1" notice --item overseer --to owner --file "$(sk_text "$2" "$3")" >/dev/null; } # ROOT NAME TEXT
last_id() { tail -n 1 "$(sk_box "$1")/to-overseer.jsonl" | jq -r .id; } # ROOT — the newest envelope's id
old_resumes() { jq -s '[.[] | select(.t == "resume" and (.at | fromdateiso8601) < now - 31536000)] | length' "$(sk_journal "$1")"; } # ROOT — resumes ending over a year ago
row() { sk_run -- listen --status --root "$1"; LINE="$(printf '%s' "$OUT" | sed -n '1p')"; } # ROOT
refuse_next_post() { sk_ctl /_test/fault '{"method": "chat.postMessage", "error": "not_in_channel", "times": 1}' >/dev/null; }

ROOT="$(sk_new_root alpha)"
sk_bind "$ROOT"
CH="$(sk_channel "$ROOT")"
sk_poll "$ROOT" "$HOLD"
ASK0="$(ask "$ROOT" q0 'Posted before the hold?')"
sk_poll "$ROOT" "$HOLD"
assert_eq "$RC=$(count "$CH" 'Posted before the hold?')" "0=1" "with no master file the ask posts"
ASK0_TS="$(sk_state ".messages.${CH}[] | select(.text | contains(\"Posted before the hold?\")) | .ts")"
notice "$ROOT" n0 'Refused before the hold.'
sk_age_envelope "$ROOT" "$(last_id "$ROOT")" 20
refuse_next_post
sk_poll "$ROOT" "$HOLD"
assert_eq "$RC=$(count "$CH" 'Refused before the hold.')" "1=0" "a notice Slack refuses before the hold stays pending"

# --- a fresh file holds a notice and an ask; owner text still lands ----------
fresh
notice "$ROOT" n1 'Held notice.'
ASK1="$(ask "$ROOT" q1 'Held and open?')"
ASK2="$(ask "$ROOT" q2 'Held and answered?')"
sk_lm "$ROOT" resolve --item overseer --id "$ASK2" --text "$(sk_text a2 'a')" >/dev/null
sk_lm "$ROOT" resolve --item overseer --id "$ASK0" --text "$(sk_text a0 'b, from the master')" >/dev/null
TS1="$(sk_inject "$CH" U001 'Still heard.')"
sk_poll "$ROOT" "$HOLD"
assert_eq "$RC=$(count "$CH" 'Held notice.')=$(count "$CH" 'Held and open?')=$(count "$CH" 'Answered in the chat')=$(count "$CH" 'Refused before the hold.')" \
  "0=0=0=0=0" "a fresh master file holds the notice, the ask, the answer and the pending notice"
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
assert_has "$LINE" " held-by=master" "the status row shows the hold"

# --- a stale file resumes: asks and answers survive a master read ----------------
sk_master_read "$ROOT" "$(wc -l < "$(sk_box "$ROOT")/to-overseer.jsonl")"
stale
notice "$ROOT" n5 'After the stale file.'
sk_poll "$ROOT" "$HOLD"
assert_eq "$RC=$(count "$CH" 'Held and open?')=$(count "$CH" 'Held notice.')=$(count "$CH" 'Held and answered?')" "0=1=0=0" \
  "the resume posts the open ask and neither the held notice nor the answered ask"
assert_eq "$(count "$CH" 'Refused before the hold.')=$(count "$CH" 'After the stale file.')" "0=1" \
  "the resume skips a notice the master read before the hold and posts the later one"
assert_has "$(sk_state ".messages.${CH}[] | select(.thread_ts == \"$ASK0_TS\") | .text")" "Answered in the chat: b, from the master" \
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
sk_master_read "$ROOT" "$(wc -l < "$(sk_box "$ROOT")/to-overseer.jsonl")"
sk_poll "$ROOT" "$HOLD"
rm -f -- "$MASTER"
notice "$ROOT" n7 'After the removal.'
sk_poll "$ROOT" "$HOLD"
assert_eq "$RC=$(count "$CH" 'Held until removed.')=$(count "$CH" 'After the removal.')" "0=0=1" \
  "a removed file resumes: the read notice never posts, one past the count does"

# --- an absent file or an empty setting posts as before ---------------------------
notice "$ROOT" n3 'No file.'
sk_poll "$ROOT" "$HOLD"
assert_eq "$RC=$(count "$CH" 'No file.')=$(holds "$ROOT")" "0=1=hold resume hold resume " "an absent master file holds nothing"
fresh
notice "$ROOT" n4 'No setting.'
sk_poll "$ROOT"
assert_eq "$RC=$(count "$CH" 'No setting.')=$(holds "$ROOT")" "0=1=hold resume hold resume " "an empty setting holds nothing"

# --- SLACK_MASTER_MAX_AGE bounds the hold -------------------------------------------
aged 900
notice "$ROOT" n9 'Under the age bound.'
sk_poll "$ROOT" "$HOLD" SLACK_MASTER_MAX_AGE=3600
assert_eq "$RC=$(count "$CH" 'Under the age bound.')" "0=0" "a file touched 900 s ago holds under SLACK_MASTER_MAX_AGE=3600"
sk_poll "$ROOT" "$HOLD"
assert_eq "$RC=$(count "$CH" 'Under the age bound.')" "0=1" "the same file is stale under the default 600, and the notice posts"

# --- a master file whose age cannot be read refuses the post step alone -------------
printf 'x\n' > "$SK_TMP/plain-file"
UNREADABLE="SLACK_MASTER_FILE=$SK_TMP/plain-file/child"
TS2="$(sk_inject "$CH" U001 'Heard past the refusal.')"
notice "$ROOT" n10 'Behind an unreadable file.'
sk_poll "$ROOT" "$UNREADABLE"
assert_eq "$RC=${ERR1%% (*}" "1=slack: master-file-unreadable=$SK_TMP/plain-file/child" "an unreadable master file is refused by path"
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
  sk_unposted "$R" "$MASTER"
  IDS="$(jq -sc 'map(.id)' "$(sk_box "$R")/to-overseer.jsonl")"
  case "$value" in
    missing) ;;
    unreadable) mkdir "$(sk_box "$R")/to-overseer.seen" ;;
    ancient) sk_master_read "$R" 3 ;;
    gapped|past-gap)
      # A killed writer can leave filtered physical lines; the master's
      # cursor still counts them, including one after the last envelope.
      python3 - "$(sk_box "$R")/to-overseer.jsonl" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
path.write_text("interrupted\n" + path.read_text() + "interrupted\n")
PY
      if [ "$value" = gapped ]; then sk_master_read "$R" 3; else sk_master_read "$R" 99; fi ;;
    *) sk_master_read "$R" "$value" ;;
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
# refused_resume ROOT [ERROR] : a held ask before a read notice and an unread
# notice; Slack refuses the ask once. Prints the ask id and sets REFUSED_READ.
refused_resume() {
  local id
  sk_bind "$1"
  sk_poll "$1" "$HOLD"
  fresh
  id="$(ask "$1" "r-$(basename "$1")" "Refused on resume in $(basename "$1")?")"
  notice "$1" "read-$(basename "$1")" "Read after the ask in $(basename "$1")."
  REFUSED_READ="$(last_id "$1")"
  sk_master_read "$1" "$(wc -l < "$(sk_box "$1")/to-overseer.jsonl")"
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
  assert_eq "$RC=$(count "$CH_R" "Refused on resume in refused-$error?")=$(resumed_asks "$R")=$(jq -r 'select(.t == "resume") | "\(.seen)=\(.skipped | join(","))"' "$(sk_journal "$R")")=$(count "$CH_R" "Read after the ask in refused-$error.")=$(count "$CH_R" "Unread after the ask in refused-$error.")=$(holds "$R")" \
    "$status=0==2=$REFUSED_READ=0=$unread=hold resume " "$error: the failed ask is omitted and every read notice id survives the refusal"
  rm -- "$(sk_box "$R")/to-overseer.seen"
  sk_poll "$R" "$HOLD"
  assert_eq "$RC=$(count "$CH_R" "Refused on resume in refused-$error?")=$(count "$CH_R" "Read after the ask in refused-$error.")=$(count "$CH_R" "Unread after the ask in refused-$error.")=$(holds "$R")" \
    "0=1=0=1=hold resume " "$error: restart posts the pending ask and unread notice but never the read notice"
done <<'ROWS'
not_in_channel slack-api-failed 1 1
invalid_auth slack-auth-failed 2 0
token_revoked slack-auth-failed 2 0
ROWS

# --- root-local settings through the real launcher and one two-root poll ----------
# The installed unit runs in the first root. The control replaces the caller
# snapshot with the loaded process environment, recreating the launch-root leak.
while read -r name first control a_posts a_held; do
  A="$(sk_new_root "pair-$name-a")"
  B="$(sk_new_root "pair-$name-b")"
  sk_bind "$A"
  sk_bind "$B"
  FILE="$B/tmp/master-live"
  touch -- "$FILE"
  sk_age_file "$FILE" 10
  printf '[env]\nSLACK_MASTER_FILE = "%s"\nSLACK_MASTER_MAX_AGE = "600"\n' "$FILE" > "$B/kendex.settings.toml"
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
  assert_has "$OUT" "held-by=master" "$name: status reports the master hold"
  assert_eq "$(jq -r 'if .held_by == "" then "none" else .held_by end' "$A/tmp/slack/status.json")=$(jq -r .held_by "$B/tmp/slack/status.json")" \
    "$a_held=master" "$name: the hold belongs to B only, unless the control leaks"
  sk_bin_reset
  sk_age_file "$FILE" 900
  sk_run -- listen --once --root "$FIRST" --root "$SECOND"
  assert_eq "$RC=$(count "$(sk_channel "$A")" "Pair notice $name A.")=$(count "$(sk_channel "$B")" "Pair notice $name B.")" \
    "0=1=1" "$name: stale B posts on the next poll and A never repeats"
  SK_RUN_FROM=""
done <<'ROWS'
A-first A real 1 none
B-first B real 1 none
B-first-control B leak 0 master
B-first-launcher-control B launch 0 master
ROWS

# Both files have the same age, but each root has its own freshness bound.
A="$(sk_new_root ages-a)"
B="$(sk_new_root ages-b)"
for R in "$A" "$B"; do sk_bind "$R"; done
printf '[env]\nSLACK_MASTER_FILE = "%s"\nSLACK_MASTER_MAX_AGE = "3600"\n' "$MASTER" > "$A/kendex.settings.toml"
printf '[env]\nSLACK_MASTER_FILE = "%s"\nSLACK_MASTER_MAX_AGE = "600"\n' "$MASTER" > "$B/kendex.settings.toml"
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
    relative) FILE="tmp/master-live"; touch -- "$R/$FILE"; sk_age_file "$R/$FILE" 900 ;;
    tilde) FILE="~/master-live"; touch -- "$SK_TMP/home/master-live"; sk_age_file "$SK_TMP/home/master-live" 900 ;;
    absent) FILE="" ;;
    *) FILE="$MASTER"; fresh; aged 900 ;;
  esac
  printf '[env]\nSLACK_BOT_TOKEN = "wrong-root-token"\nSLACK_OWNERS = "wrong@example.test"\nSLACK_API_URL = "http://invalid.test"\n' > "$R/kendex.settings.toml"
  case "$source" in
    local|private|named) printf 'SLACK_MASTER_FILE = "%s"\nSLACK_MASTER_MAX_AGE = "600"\n' "$FILE" >> "$R/kendex.settings.toml" ;;
  esac
  case "$source" in
    local) printf '[env]\nSLACK_MASTER_MAX_AGE = "%s"\n' "$age" > "$R/.kendex/settings.toml" ;;
    private) printf '[env]\nSLACK_MASTER_MAX_AGE = "600"\n' > "$R/.kendex/settings.toml"; printf 'SLACK_MASTER_MAX_AGE=%s\n' "$age" > "$R/.env.local" ;;
    named) printf 'SLACK_MASTER_MAX_AGE=%s\n' "$age" > "$R/private.env"; printf 'KENDEX_ENV_FILE = "private.env"\n' >> "$R/kendex.settings.toml" ;;
    private-only) printf 'SLACK_MASTER_FILE=%s\nSLACK_MASTER_MAX_AGE=%s\n' "$FILE" "$age" > "$R/.env.local" ;;
    named-only) printf 'SLACK_MASTER_FILE=%s\nSLACK_MASTER_MAX_AGE=%s\n' "$FILE" "$age" > "$R/private.env"; printf 'KENDEX_ENV_FILE = "private.env"\n' >> "$R/kendex.settings.toml" ;;
    private-age) printf 'SLACK_MASTER_MAX_AGE=%s\n' "$age" > "$R/.env.local" ;;
    named-age) printf 'SLACK_MASTER_MAX_AGE=%s\n' "$age" > "$R/private.env"; printf 'KENDEX_ENV_FILE = "private.env"\n' >> "$R/kendex.settings.toml" ;;
  esac
  case "$control" in
    export) sk_mutant presence-export settings.py 'export (SLACK_MASTER_FILE="\$\{SLACK_MASTER_FILE-\}" SLACK_MASTER_MAX_AGE="\$\{SLACK_MASTER_MAX_AGE-\}")' '\1' ;;
  esac
  notice "$R" "settings-$name" "Settings notice $name."
  case "$caller" in
    age) sk_poll "$R" SLACK_MASTER_MAX_AGE=600 ;;
    file) sk_poll "$R" "SLACK_MASTER_FILE=$SK_TMP/no-master" ;;
    empty) sk_poll "$R" SLACK_MASTER_FILE= ;;
    configured-file) sk_poll "$R" "SLACK_MASTER_FILE=$FILE" ;;
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
printf '[env]\nSLACK_MASTER_MAX_AGE = "invalid"\n' > "$R/kendex.settings.toml"
sk_run -- listen --once --root "$A" --root "$R"
assert_eq "$RC=$ERR1" "2=slack: setting-invalid=SLACK_MASTER_MAX_AGE=invalid root=$R" \
  "invalid root age refuses at start and names that root even without a file"
printf '[env]\nSLACK_MASTER_FILE = []\n' > "$R/kendex.settings.toml"
sk_run -- listen --once --root "$A" --root "$R"
assert_eq "$RC" "2" "an unreadable root setting refuses startup instead of disabling its hold"
assert_has "$ERR1" "slack: setting-invalid=root=$R settings-reader=" "the root settings failure names its root and reader"

# --- changed files update a running relay, without restarting it -------------------
# A status timestamp is the poll acknowledgement. Wait for a later completed
# poll of both roots, bounded by the parent suite's timeout.
polled_after() { # ROOT LAST_POLL
  local tries=0 value
  while [ "$tries" -lt 100 ]; do
    value="$(jq -r --argjson after "$2" '.last_poll > $after' "$1/tmp/slack/status.json" 2>/dev/null)"
    [ "$value" != true ] || return 0
    tries=$((tries + 1)); sleep 0.1
  done
  bad "running relay did not complete its next poll" "$1"
  return 1
}
live_setting() { # ROOT SOURCE AGE
  case "$2" in
    toml) printf '[env]\nSLACK_MASTER_FILE = "%s"\nSLACK_MASTER_MAX_AGE = "%s"\n' "$MASTER" "$3" > "$1/kendex.settings.toml" ;;
    local) mkdir -p "$1/.kendex"; printf '[env]\nSLACK_MASTER_FILE = "%s"\nSLACK_MASTER_MAX_AGE = "%s"\n' "$MASTER" "$3" > "$1/.kendex/settings.toml" ;;
    private) printf 'SLACK_MASTER_FILE=%s\nSLACK_MASTER_MAX_AGE=%s\n' "$MASTER" "$3" > "$1/.env.local" ;;
    named) printf '[env]\nKENDEX_ENV_FILE = "private.env"\n' > "$1/kendex.settings.toml"; printf 'SLACK_MASTER_FILE=%s\nSLACK_MASTER_MAX_AGE=%s\n' "$MASTER" "$3" > "$1/private.env" ;;
  esac
}
while read -r name source caller control; do
  R="$(sk_new_root "live-$name")"; S="$(sk_new_root "peer-$name")"
  sk_bind "$R"; sk_bind "$S"
  CHANNEL="$(sk_channel "$R")"; PEER_CHANNEL="$(sk_channel "$S")"
  if [ "$control" = mutant ]; then
    sk_mutant no-poll-presence relay.py 'presence = load_presence\(self.path\)' 'presence = self.presence'
  fi
  case "$caller" in
    empty) sk_relay_start "$R" --root "$S" SLACK_MASTER_FILE= ;;
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
      sk_assert_red "$(field "$LINE" held-by)=$(count "$CHANNEL" "Changed hold $name.")" "master=0" \
        "control: dropping the per-poll read fails the running hold assertion" ;;
    *)
      assert_eq "$(field "$LINE" state)=$(field "$LINE" held-by)=$(count "$CHANNEL" "Changed hold $name.")" "ok=master=0" \
        "$name: the changed setting holds on the next completed poll"
      live_setting "$R" "$source" invalid
      notice "$R" "live-$name-invalid" "Invalid hold $name."
      AFTER="$(jq -r .last_poll "$R/tmp/slack/status.json")"
      polled_after "$R" "$AFTER" || exit 1
      row "$R"
      assert_eq "$(field "$LINE" state)=$(field "$LINE" held-by)=$(count "$CHANNEL" "Invalid hold $name.")" "failing=master=0" \
        "$name: a refused reading retains the hold and posts nothing"
      assert_has "$(jq -r .last_error "$R/tmp/slack/status.json")" "setting-invalid=SLACK_MASTER_MAX_AGE=invalid root=$R" \
        "$name: the refused reading names its root"
      row "$S"; assert_eq "$(field "$LINE" state)" ok "$name: a refused reading leaves its peer ok"
      case "$source" in
        toml) rm -- "$R/kendex.settings.toml" ;;
        local) rm -- "$R/.kendex/settings.toml" ;;
        private) printf 'SLACK_MASTER_FILE=\n' > "$R/.env.local" ;;
        named) printf 'SLACK_MASTER_FILE=\n' > "$R/private.env" ;;
      esac
      AFTER="$(jq -r .last_poll "$R/tmp/slack/status.json")"
      polled_after "$R" "$AFTER" || exit 1
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

# Count calls through the real Relay start and poll owners. A stub returns
# an unconfigured presence pair; no parser or API behavior is under test here.
R="$(sk_new_root presence-count)"; S="$(sk_new_root presence-count-peer)"
sk_bind "$R"; sk_bind "$S"
OUT="$(env -i PATH="$PATH" HOME="$SK_TMP/home" LANG=C PYTHONDONTWRITEBYTECODE=1 \
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
    (roots[0] / "kendex.settings.toml").write_text('[env]\nSLACK_MASTER_FILE = "master"\n')
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

sk_mutant hold relay.py 'if touched is not None and now - touched < self\.presence\.master_max_age:' 'if False:'
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
sk_unposted "$DELTA" "$MASTER"
sk_master_read "$DELTA" 3
stale
sk_poll "$DELTA" "$HOLD"
assert_eq "$(count "$(sk_channel "$DELTA")" 'Backlog in delta.')" "3" "control: the seen rule gone, all three pre-hold notices replay"
sk_bin_reset

EPSILON="$(sk_new_root epsilon)"
fresh
sk_unposted "$EPSILON" "$MASTER"
sk_master_read "$EPSILON" 3
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
assert_eq "$(count "$(sk_channel "$THETA")" 'Read after the ask in theta.')" "1" \
  "control: the unrecorded read notice replays after the token refusal and restart"
sk_bin_reset

ETA="$(sk_new_root eta)"
fresh
sk_unposted "$ETA" "$MASTER"
sk_master_read "$ETA" 3
aged 1000000000
sk_mutant age-stamp relay.py 'at = format_at\(self.clock\(\)\)' 'at = format_at(self.master_touched() + self.presence.master_max_age)'
sk_poll "$ETA" "$HOLD"
sk_bin_reset
sk_run -- compact --root "$ETA"
rm -- "$(sk_box "$ETA")/to-overseer.seen"
sk_poll "$ETA" "$HOLD"
assert_eq "$(count "$(sk_channel "$ETA")" 'Backlog in eta.')" "3" "control: an expiry-time stamp lets compaction drop young skipped ids and replay them"

sk_mutant clamp relay.py 'return min\(count, lines\)' 'return count'
ZETA="$(sk_new_root zeta)"
fresh
sk_unposted "$ZETA" "$MASTER"
sk_master_read "$ZETA" 99
stale
sk_poll "$ZETA" "$HOLD"
assert_eq "$(jq -r 'select(.t == "resume") | .seen' "$(sk_journal "$ZETA")")" "99" "control: without clamping, the resume records a count past its snapshot"
sk_bin_reset

sk_mutant landed relay.py 'if self\.post_ask\(envelope\) and landed' 'if (self.post_ask(envelope) or True) and landed'
PI="$(sk_new_root pi)"
PI_ASK="$(refused_resume "$PI")"
assert_eq "$(resumed_asks "$PI")" "$PI_ASK" "control: every routed ask journaled, the resume names one Slack refused"
sk_bin_reset


sk_mutant age settings.py '_positive_int\("SLACK_MASTER_MAX_AGE", DEFAULT_MASTER_MAX_AGE, values, root\)' 'DEFAULT_MASTER_MAX_AGE'
IOTA="$(sk_new_root iota)"
sk_bind "$IOTA"
sk_poll "$IOTA" "$HOLD"
fresh
aged 900
notice "$IOTA" ni 'Aged in iota.'
sk_poll "$IOTA" "$HOLD" SLACK_MASTER_MAX_AGE=3600
assert_eq "$(count "$(sk_channel "$IOTA")" 'Aged in iota.')" "1" "control: the setting unread, a file inside SLACK_MASTER_MAX_AGE holds nothing"
sk_bin_reset

sk_mutant unreadable relay.py 'raise Refusal\("master-file-unreadable", f"\{path\} \(\{err\.strerror\}\)"\) from err' 'return None'
KAPPA="$(sk_new_root kappa)"
sk_bind "$KAPPA"
sk_poll "$KAPPA"
notice "$KAPPA" nk 'Unreadable in kappa.'
sk_poll "$KAPPA" "$UNREADABLE"
assert_eq "$RC=$(count "$(sk_channel "$KAPPA")" 'Unreadable in kappa.')" "0=1" "control: the refusal turned to no master, a notice posts past an unreadable file"
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
