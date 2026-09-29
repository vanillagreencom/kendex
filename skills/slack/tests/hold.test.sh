#!/usr/bin/env bash
# `slack listen` under SLACK_MASTER_FILE: while the file is fresh a notice
# and an ask are held, no envelope is posted, an owner message still lands,
# the hold is journaled once and `--status` shows held-by=master. Once the
# file is stale the resume posts the open ask, the answer to an ask the
# channel shows open, a notice Slack refused before the hold and one written
# after the file went stale, never a held notice, and journals which asks
# landed, never one Slack refused; a removed file ends the hold at the last poll that found it
# fresh. A notice written before the touch posts on the resume though the
# relay first saw the hold a poll later or failed to read the channel in
# between. An absent file or an empty setting posts as before,
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
# The master's touch, ten seconds back: an envelope written after it, or one
# of those aged five seconds, lands in a later second; one aged twenty before.
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

# --- a stale file resumes: open asks and notices from outside the hold -----------
sleep 1 # the held envelopes' `at` second passes, so the hold's end lands in a later one
stale
notice "$ROOT" n5 'After the stale file.'
sk_poll "$ROOT" "$HOLD"
assert_eq "$RC=$(count "$CH" 'Held and open?')=$(count "$CH" 'Held notice.')=$(count "$CH" 'Held and answered?')" "0=1=0=0" \
  "the resume posts the open ask and neither the held notice nor the answered ask"
assert_eq "$(count "$CH" 'Refused before the hold.')=$(count "$CH" 'After the stale file.')" "1=1" \
  "the resume posts the notice refused before the hold and the one written after the file went stale"
assert_has "$(sk_state ".messages.${CH}[] | select(.thread_ts == \"$ASK0_TS\") | .text")" "Answered in the chat: b, from the master" \
  "an ask the channel shows open gets its held answer, so its thread closes"
assert_eq "$(holds "$ROOT")=$(jq -r 'select(.t == "resume") | .asks | join(",")' "$(sk_journal "$ROOT")")" "hold resume =$ASK1" \
  "the resume is journaled with the ask it posted"
row "$ROOT"
assert_lacks "$LINE" "held-by=" "the status row drops the hold"
notice "$ROOT" n2 'After the resume.'
sk_poll "$ROOT" "$HOLD"
assert_eq "$(count "$CH" 'After the resume.')=$(count "$CH" 'Held notice.')=$(count "$CH" 'Refused before the hold.')" "1=0=1" \
  "a notice after the resume posts; the held one never does and the refused one posted once"

# --- a removed file ends the hold at the last poll that found it fresh -------------
fresh
notice "$ROOT" n6 'Held until removed.'
sleep 1 # that envelope's `at` second passes before the poll that last finds the file fresh
sk_poll "$ROOT" "$HOLD"
rm -f -- "$MASTER"
notice "$ROOT" n7 'After the removal.'
sk_poll "$ROOT" "$HOLD"
assert_eq "$RC=$(count "$CH" 'Held until removed.')=$(count "$CH" 'After the removal.')" "0=0=1" \
  "a removed file resumes: the held notice never posts, one written after the removal does"

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
aged 1000000000
sk_poll "$ROOT" "$HOLD"
assert_eq "$(old_resumes "$ROOT")" "1" "a file touched long ago ends its hold then"
sk_run -- compact --root "$ROOT"
assert_eq "$RC=$(holds "$ROOT")" "0=resume resume resume " "compaction drops a resume whose end is past the horizon"

# --- a notice written before the touch posts, whatever the relay's polls missed ------
# before_touch ROOT [fault] — a notice posted, then one written before the
# touch, the channel read refused once between them when asked, the hold
# first seen on the poll after the touch, then a stale file.
before_touch() {
  local name
  name="$(basename "$1")"
  sk_bind "$1"
  sk_poll "$1" "$HOLD"
  notice "$1" "a-$name" "Posted in $name."
  sk_age_envelope "$1" "$(last_id "$1")" 30
  sk_poll "$1" "$HOLD"
  notice "$1" "b-$name" "Before the touch in $name."
  sk_age_envelope "$1" "$(last_id "$1")" 20
  if [ "${2:-}" = fault ]; then
    sk_ctl /_test/fault '{"method": "conversations.history", "error": "ratelimited", "times": 1}' >/dev/null
    sk_poll "$1" "$HOLD"
    assert_eq "$RC=$(count "$(sk_channel "$1")" "Before the touch in $name.")" "1=0" "the refused channel read fails the poll before anything posts"
  fi
  fresh
  sk_poll "$1" "$HOLD"
  stale
  sk_poll "$1" "$HOLD"
}
NU="$(sk_new_root nu)"
before_touch "$NU"
assert_eq "$(count "$(sk_channel "$NU")" 'Before the touch in nu.')" "1" "a notice written before the touch posts though the hold was first seen a poll later"
XI="$(sk_new_root xi)"
before_touch "$XI" fault
assert_eq "$(count "$(sk_channel "$XI")" 'Before the touch in xi.')" "1" "a notice written before the touch posts though the channel read failed in between"

# --- a held ask Slack refuses on the resume is not journaled as posted --------------
# refused_resume ROOT — a bound root holding an open ask, the resume's post of
# it refused once; prints the ask's id.
refused_resume() {
  local id
  sk_bind "$1"
  sk_poll "$1" "$HOLD"
  fresh
  id="$(ask "$1" "r-$(basename "$1")" "Refused on resume in $(basename "$1")?")"
  sk_poll "$1" "$HOLD"
  stale
  refuse_next_post
  sk_poll "$1" "$HOLD"
  printf '%s' "$id"
}
resumed_asks() { jq -r 'select(.t == "resume") | .asks | join(",")' "$(sk_journal "$1")"; } # ROOT
OMICRON="$(sk_new_root omicron)"
refused_resume "$OMICRON" >/dev/null
assert_eq "$RC=$(count "$(sk_channel "$OMICRON")" 'Refused on resume in omicron?')=$(resumed_asks "$OMICRON")" "1=0=" \
  "a held ask Slack refuses on the resume is not named by the resume line"
sk_poll "$OMICRON" "$HOLD"
assert_eq "$RC=$(count "$(sk_channel "$OMICRON")" 'Refused on resume in omicron?')=$(holds "$OMICRON")" "0=1=hold resume " \
  "the next poll posts the refused ask and journals no second resume"

# --- controls, one mutant per rule --------------------------------------------------
# held ROOT — a bound root with a notice written under a fresh file and polled.
# A control that needs that notice inside the hold moves it five seconds
# back, into a second before the hold's end.
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

sk_mutant window relay.py 'route = "skip" if any\(within\(w, at\) for w in holds\) else "notice"' 'route = "notice"'
DELTA="$(sk_new_root delta)"
held "$DELTA"
sk_age_envelope "$DELTA" "$(last_id "$DELTA")" 5
stale
sk_poll "$DELTA" "$HOLD"
assert_eq "$(count "$(sk_channel "$DELTA")" 'Held in delta.')" "1" "control: the hold window gone, a held notice posts"
sk_bin_reset

# The pending notice is moved twenty seconds back, before the hold's start
# and in a second before the hold's end.
sk_mutant from relay.py 'return at_epoch\(window\.from_at\) < at < ' 'return at < '
EPSILON="$(sk_new_root epsilon)"
sk_bind "$EPSILON"
sk_poll "$EPSILON" "$HOLD"
notice "$EPSILON" ne 'Refused in epsilon.'
sk_age_envelope "$EPSILON" "$(last_id "$EPSILON")" 20
refuse_next_post
sk_poll "$EPSILON" "$HOLD"
fresh
sk_poll "$EPSILON" "$HOLD"
stale
sk_poll "$EPSILON" "$HOLD"
assert_eq "$(count "$(sk_channel "$EPSILON")" 'Refused in epsilon.')" "0" "control: the hold's start gone, a notice refused before it is dropped"
sk_bin_reset

HOLD_LINE='self\.journal\.append\(t="hold", at=format_at\(touched\)\)'
sk_mutant posted relay.py "$HOLD_LINE" 'self.journal.append(t="hold", at=newest(self.mail.events())[0])'
ZETA="$(sk_new_root zeta)"
held "$ZETA"
sk_age_envelope "$ZETA" "$(last_id "$ZETA")" 5
stale
sk_poll "$ZETA" "$HOLD"
assert_eq "$(count "$(sk_channel "$ZETA")" 'Held in zeta.')" "1" "control: the start taken from the mailbox at the hold's first poll, a notice written after the touch posts"
sk_bin_reset

sk_mutant history relay.py "$HOLD_LINE" 'self.journal.append(t="hold", at=newest([e for e in self.mail.events() if str(e["id"]) in self.state.carried])[0])'
LAMBDA="$(sk_new_root lambda)"
before_touch "$LAMBDA"
assert_eq "$(count "$(sk_channel "$LAMBDA")" 'Before the touch in lambda.')" "0" "control: the start taken from the relay's posts, a notice before the touch seen a poll later is dropped"
MU="$(sk_new_root mu)"
before_touch "$MU" fault
assert_eq "$(count "$(sk_channel "$MU")" 'Before the touch in mu.')" "0" "control: the start taken from the relay's posts, a notice before a refused read and the touch is dropped"
sk_bin_reset

sk_mutant stale relay.py 'at = format_at\(touched \+ self\.settings\.master_max_age\)' 'at = format_at(self.clock() + self.settings.master_max_age)'
ETA="$(sk_new_root eta)"
held "$ETA"
stale
notice "$ETA" ne2 'After stale in eta.'
sk_poll "$ETA" "$HOLD"
assert_eq "$(count "$(sk_channel "$ETA")" 'After stale in eta.')" "0" "control: the stale file's end taken from the poll, not the touch, a notice after it is held"
sk_bin_reset

sk_mutant landed relay.py 'if self\.post_ask\(envelope\) and landed' 'if (self.post_ask(envelope) or True) and landed'
PI="$(sk_new_root pi)"
PI_ASK="$(refused_resume "$PI")"
assert_eq "$(resumed_asks "$PI")" "$PI_ASK" "control: every routed ask journaled, the resume names one Slack refused"
sk_bin_reset

sk_mutant seen relay.py 'elif self\.master_seen is not None:' 'elif False:'
THETA="$(sk_new_root theta)"
held "$THETA"
sk_age_envelope "$THETA" "$(last_id "$THETA")" 5
rm -f -- "$MASTER"
sk_poll "$THETA" "$HOLD"
assert_eq "$(count "$(sk_channel "$THETA")" 'Held in theta.')" "1" "control: the last fresh poll gone, a held notice posts after the removal"
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
aged 1000000000
sk_poll "$ROOT" "$HOLD"
sk_run -- compact --root "$ROOT"
assert_eq "$(old_resumes "$ROOT")" "1" "control: every resume kept, compaction leaves one past the horizon"
sk_bin_reset

sk_summary
