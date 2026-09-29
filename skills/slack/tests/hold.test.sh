#!/usr/bin/env bash
# `slack listen` under SLACK_MASTER_FILE: while the file is fresh a notice
# and an ask are held, nothing is posted, an owner message still lands, the
# hold is journaled once and `--status` shows held-by=master; once the file
# is stale the resume posts only the open ask and the answer to an ask the
# channel shows open, journals which asks it posted, and a later notice
# posts; an absent file or an empty setting posts as before; compaction
# keeps the last hold or resume line. The controls plant one mutant per
# rule: the hold check gone, the hold journaled every poll, the resume's
# notice floor gone, the status field dropped, and every hold line kept.
set -uo pipefail
. "$(dirname "$0")/lib/harness.sh"

sk_fake_start
echo "=== slack listen: the master hold ==="

MASTER="$SK_TMP/master-live"
HOLD="SLACK_MASTER_FILE=$MASTER"
fresh() { touch "$MASTER"; }
stale() { touch -t 200001010000 "$MASTER"; }
count() { sk_state "[.messages.${1}[] | select(.text | contains(\"$2\"))] | length"; } # CHANNEL TEXT
holds() { jq -r 'select(.t == "hold" or .t == "resume") | .t' "$(sk_journal "$1")" | tr '\n' ' '; } # ROOT
ask() { sk_lm "$1" ask --item overseer --to owner --file "$(sk_text "$2" "$3")" --options a,b --recommend a | sed 's/^id=//'; } # ROOT NAME TEXT
notice() { sk_lm "$1" notice --item overseer --to owner --file "$(sk_text "$2" "$3")" >/dev/null; } # ROOT NAME TEXT
row() { sk_run -- listen --status --root "$1"; LINE="$(printf '%s' "$OUT" | sed -n '1p')"; } # ROOT

ROOT="$(sk_new_root alpha)"
sk_bind "$ROOT"
CH="$(sk_channel "$ROOT")"
sk_poll "$ROOT" "$HOLD"
ASK0="$(ask "$ROOT" q0 'Posted before the hold?')"
sk_poll "$ROOT" "$HOLD"
assert_eq "$RC=$(count "$CH" 'Posted before the hold?')" "0=1" "with no master file the ask posts"
ASK0_TS="$(sk_state ".messages.${CH}[] | select(.text | contains(\"Posted before the hold?\")) | .ts")"

# --- a fresh file holds a notice and an ask; owner text still lands ----------
fresh
notice "$ROOT" n1 'Held notice.'
ASK1="$(ask "$ROOT" q1 'Held and open?')"
ASK2="$(ask "$ROOT" q2 'Held and answered?')"
sk_lm "$ROOT" resolve --item overseer --id "$ASK2" --text "$(sk_text a2 'a')" >/dev/null
sk_lm "$ROOT" resolve --item overseer --id "$ASK0" --text "$(sk_text a0 'b, from the master')" >/dev/null
TS1="$(sk_inject "$CH" U001 'Still heard.')"
sk_poll "$ROOT" "$HOLD"
assert_eq "$RC=$(count "$CH" 'Held notice.')=$(count "$CH" 'Held and open?')=$(count "$CH" 'Answered in the chat')" "0=0=0=0" \
  "a fresh master file holds the notice, the ask and the answer"
assert_eq "$(jq -r 'select(.kind == "directive") | .delivery_id' "$(sk_box "$ROOT")/to-lane.jsonl")" "$CH:$TS1" \
  "an owner message in the channel still lands while held"
sk_poll "$ROOT" "$HOLD"
assert_eq "$(holds "$ROOT")" "hold " "the hold is journaled once"
row "$ROOT"
assert_has "$LINE" " held-by=master" "the status row shows the hold"

# --- a stale file resumes with the open ask alone ------------------------------
stale
sk_poll "$ROOT" "$HOLD"
assert_eq "$RC=$(count "$CH" 'Held and open?')=$(count "$CH" 'Held notice.')=$(count "$CH" 'Held and answered?')" "0=1=0=0" \
  "the resume posts the open ask and neither the held notice nor the answered ask"
assert_has "$(sk_state ".messages.${CH}[] | select(.thread_ts == \"$ASK0_TS\") | .text")" "Answered in the chat: b, from the master" \
  "an ask the channel shows open gets its held answer, so its thread closes"
assert_eq "$(holds "$ROOT")=$(jq -r 'select(.t == "resume") | .asks | join(",")' "$(sk_journal "$ROOT")")" "hold resume =$ASK1" \
  "the resume is journaled with the ask it posted"
row "$ROOT"
assert_lacks "$LINE" "held-by=" "the status row drops the hold"
notice "$ROOT" n2 'After the resume.'
sk_poll "$ROOT" "$HOLD"
assert_eq "$(count "$CH" 'After the resume.')=$(count "$CH" 'Held notice.')" "1=0" "a notice after the resume posts; the held one never does"

# --- an absent file or an empty setting posts as before ---------------------------
rm -f -- "$MASTER"
notice "$ROOT" n3 'No file.'
sk_poll "$ROOT" "$HOLD"
assert_eq "$RC=$(count "$CH" 'No file.')=$(holds "$ROOT")" "0=1=hold resume " "an absent master file holds nothing"
fresh
notice "$ROOT" n4 'No setting.'
sk_poll "$ROOT"
assert_eq "$RC=$(count "$CH" 'No setting.')=$(holds "$ROOT")" "0=1=hold resume " "an empty setting holds nothing"

# --- compaction keeps the last hold or resume line ---------------------------------
sk_poll "$ROOT" "$HOLD"
sk_run -- compact --root "$ROOT"
assert_eq "$RC=$(holds "$ROOT")" "0=hold " "compaction keeps only the last hold line"

# --- controls, one mutant per rule --------------------------------------------------
# held ROOT — a bound root with a notice written under a fresh file and polled.
held() {
  sk_bind "$1"
  sk_poll "$1" "$HOLD"
  fresh
  notice "$1" "n-$(basename "$1")" "Held in $(basename "$1")."
  sk_poll "$1" "$HOLD"
}

sk_mutant hold relay.py 'if self\.master_live\(\):' 'if False:'
BETA="$(sk_new_root beta)"
held "$BETA"
assert_eq "$(count "$(sk_channel "$BETA")" 'Held in beta.')" "1" "control: the hold check gone, a notice posts under a fresh file"
sk_bin_reset

sk_mutant once relay.py 'if not self\.state\.held:\n                self\.journal' 'if True:\n                self.journal'
GAMMA="$(sk_new_root gamma)"
held "$GAMMA"
assert_eq "$(holds "$GAMMA")" "hold hold " "control: the transition rule gone, every held poll journals a hold"
sk_bin_reset

sk_mutant floor relay.py 'route = "skip" if before\(state\.resume_at, state\.resume_ids, at, env_id\) else "notice"' 'route = "notice"'
DELTA="$(sk_new_root delta)"
held "$DELTA"
stale
sk_poll "$DELTA" "$HOLD"
assert_eq "$(count "$(sk_channel "$DELTA")" 'Held in delta.')" "1" "control: the resume floor gone, a held notice posts"
sk_bin_reset

sk_mutant status verbs.py 'if record\.get\("held_by"\) else ""' 'if False else ""'
fresh
sk_poll "$ROOT" "$HOLD"
row "$ROOT"
assert_lacks "$LINE" "held-by=" "control: the status field dropped, a standing hold is not shown"
sk_bin_reset

sk_mutant compact store.py 'drop = index != last_hold' 'drop = False'
stale
sk_poll "$ROOT" "$HOLD"
sk_run -- compact --root "$ROOT"
assert_eq "$(holds "$ROOT")" "hold resume " "control: every hold line kept, compaction leaves the earlier one"
sk_bin_reset

sk_summary
