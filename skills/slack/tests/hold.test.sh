#!/usr/bin/env bash
# `slack listen` under SLACK_MASTER_FILE: while the file is fresh a notice
# and an ask are held, no envelope is posted, an owner message still lands,
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
# horizon. The controls plant one mutant per rule.
set -uo pipefail
. "$(dirname "$0")/lib/harness.sh"

sk_fake_start
echo "=== slack listen: the master hold ==="

MASTER="$SK_TMP/master-live"
HOLD="SLACK_MASTER_FILE=$MASTER"
aged() { python3 -c 'import os, sys, time; t = time.time() - int(sys.argv[2]); os.utime(sys.argv[1], (t, t))' "$MASTER" "$1"; } # SECONDS
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
sk_poll "$ROOT" "$HOLD"
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

# --- controls, one mutant per rule --------------------------------------------------
# held ROOT — a bound root with a notice written under a fresh file and polled.

held() {
  sk_bind "$1"
  sk_poll "$1" "$HOLD"
  fresh
  notice "$1" "n-$(basename "$1")" "Held in $(basename "$1")."
  sk_poll "$1" "$HOLD"
}

sk_mutant hold relay.py 'if touched is not None and now - touched < self\.settings\.master_max_age:' 'if False:'
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
sk_mutant age-stamp relay.py 'at = format_at\(self.clock\(\)\)' 'at = format_at(self.master_touched() + self.settings.master_max_age)'
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


sk_mutant age settings.py '_positive_int\("SLACK_MASTER_MAX_AGE", DEFAULT_MASTER_MAX_AGE\)' 'DEFAULT_MASTER_MAX_AGE'
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
