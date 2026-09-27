#!/usr/bin/env bash
# `slack listen`: owner text to the mailbox and the mailbox to Slack, through
# the real lane-mail and a fake Slack API paged two messages at a time. The
# rows: a directive with its delivery id, an ask posted with the mention and
# answered once in its thread, the second reply as a directive, a chat answer
# and a deadline default shown in the thread, a notice threaded on its ref,
# a report uploaded and its thread bound from the share, a non-owner and a
# file alone answered once and not routed, catch-up over pages, the crash
# between the mailbox append and the journal mark, the second relay refused
# by the lock, a reply under a thread past SLACK_THREAD_DAYS left unrouted,
# a secret value refused, a 429 honoured, and owners re-resolved from the
# setting. The controls at the end plant four mutants, one per rule: the
# delivery id dropped, the ask thread no longer resolved, the lock no longer
# exclusive, the thread-age horizon removed.
set -uo pipefail
. "$(dirname "$0")/lib/harness.sh"

sk_fake_start --page 2
echo "=== slack listen ==="

directives() { jq -r 'select(.kind == "directive") | [.delivery_id, .text] | join(" ")' "$(sk_box "$1")/to-lane.jsonl"; }
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
assert_eq "$RC=$OUT" "0=slack: listening=1 poll_seconds=1" "a poll prints the listening line and exits 0"
assert_eq "$(directives "$ROOT")" "C001:$TS1 Ship it today." "an owner's top-level message lands as a directive keyed channel:ts"
assert_eq "$(jq -r 'select(.t == "in") | [.kind, .ts, .thread] | join(" ")' "$(sk_journal "$ROOT")")" \
  "directive $TS1 $TS1" "the journal records the delivery by identifiers"
sk_poll "$ROOT"
assert_eq "$(directives "$ROOT" | wc -l | tr -d ' ')" "1" "a second poll delivers nothing twice"

# --- an ask: posted with the mention, answered once, then a directive ---------
sk_lm "$ROOT" ask --item overseer --to owner --file "$(sk_text q 'Cut the scanner?')" --options cut,keep --recommend cut --wait 30 >"$SK_TMP/ask.out"
ASK="$(sed 's/^id=//' "$SK_TMP/ask.out")"
sk_poll "$ROOT"
ASK_TS="$(sk_state '.messages.C001[] | select(.text | startswith("<@U001> <@U002> Question")) | .ts')"
assert_has "$(sk_state ".messages.C001[] | select(.ts == \"$ASK_TS\") | .text")" \
  "Cut the scanner?
Options: cut, keep. Recommended: cut. It stands at " "the ask is posted with every owner mentioned, its options, recommendation and deadline"
sk_poll "$ROOT"
assert_eq "$(sk_state '[.messages.C001[] | select(.text | startswith("<@U001>"))] | length')" "1" "the ask is posted once"
R1="$(sk_inject C001 U002 'keep' "$ASK_TS")"
sk_poll "$ROOT"
assert_eq "$(answers "$ROOT")" "$ASK text C001:$R1 keep" "the first reply in the thread resolves the ask with the delivery id"
assert_has "$(posts C001)" "$ASK_TS | Recorded as your answer." "the relay confirms the answer in the thread"
R2="$(sk_inject C001 U001 'and keep the tests' "$ASK_TS")"
sk_polls "$ROOT" 10
assert_has "$(directives "$ROOT")" "C001:$R2 and keep the tests" "a second reply is delivered as a directive within ten polls"
assert_has "$(posts C001)" "$ASK_TS | This question was already answered; delivered as a directive instead." \
  "the second reply is told the question was answered"
assert_eq "$(answers "$ROOT" | wc -l | tr -d ' ')" "1" "one answer stands"

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
sk_polls "$ROOT" 10
assert_has "$(directives "$ROOT")" "C001:$R3 too late" "a reply after the default is a directive"
assert_eq "$(sk_lm "$ROOT" pending --item overseer --to owner | wc -l | tr -d ' ')" "0" "no ask is left open"

# --- a notice threads on its ref -----------------------------------------------
D1="$(jq -r 'select(.kind == "directive") | .id' "$(sk_box "$ROOT")/to-lane.jsonl" | sed -n '1p')"
sk_lm "$ROOT" notice --item overseer --to owner --ref "$D1" --file "$(sk_text n1 'Shipping.')" >/dev/null
sk_lm "$ROOT" notice --item overseer --to owner --file "$(sk_text n2 'Round done.')" >/dev/null
sk_poll "$ROOT"
assert_has "$(posts C001)" "$TS1 | Shipping." "a notice answering an owner note lands in that note's thread"
assert_has "$(posts C001)" "top | Round done." "a notice with no ref lands top-level"

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
sk_polls "$ROOT" 10
assert_has "$(directives "$ROOT")" "C001:$R4 good report" "a reply under the report is a directive"

# --- a non-owner and a file alone: one reply each, nothing routed ------------------
N1="$(sk_inject C001 U999 'let me in')"
F1="$(sk_inject C001 U001 '' '' '"files": [{"id": "F777"}]')"
sk_poll "$ROOT"
sk_poll "$ROOT"
assert_has "$(posts C001)" "$N1 | Only the channel's owners steer this session; this message is not routed." "a non-owner gets one reply"
assert_has "$(posts C001)" "$F1 | Only text is routed; a file alone is not." "a file alone gets one reply"
assert_eq "$(sk_state '[.messages.C001[] | select(.text | startswith("Only"))] | length')" "2" "each is answered once"
assert_lacks "$(directives "$ROOT")" "$N1" "the non-owner's message is not routed"
assert_lacks "$(directives "$ROOT")" "$F1" "the file alone is not routed"
B1="$(sk_inject C001 U001 'broadcast' "$ASK_TS" '"subtype": "thread_broadcast"')"
sk_poll "$ROOT"
assert_lacks "$(directives "$ROOT")" "$B1" "a thread broadcast is ignored"

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

# --- a reply under a thread older than SLACK_THREAD_DAYS is not routed ----------------
GAMMA="$(sk_new_root gamma)"
sk_bind "$GAMMA"
OLD_TS="$(python3 -c 'import time; print("%.6f" % (time.time() - 8 * 86400))')"
OLD="$(sk_inject C002 U001 'an old topic' '' "\"ts\": \"$OLD_TS\"")"
YOUNG="$(sk_inject C002 U001 'a young topic')"
sk_poll "$GAMMA"
assert_eq "$(directives "$GAMMA" | wc -l | tr -d ' ')" "2" "both topics land as directives"
sk_inject C002 U001 'reply under the old one' "$OLD" >/dev/null
YR="$(sk_inject C002 U001 'reply under the young one' "$YOUNG")"
for n in 2 3 4 5 6 7 8 9; do sk_poll "$GAMMA"; done
assert_eq "$(directives "$GAMMA" | wc -l | tr -d ' ')" "2" "before the tenth poll no bound thread is re-read"
sk_poll "$GAMMA"
assert_eq "$(directives "$GAMMA" | sed -n '3p')" "C002:$YR reply under the young one" "the tenth poll routes the reply under the young thread"
assert_eq "$(directives "$GAMMA" | wc -l | tr -d ' ')" "3" "the reply under the thread past SLACK_THREAD_DAYS is not routed"

# --- a secret value is refused, journaled, never posted --------------------------------
sk_lm "$GAMMA" notice --item overseer --to owner --file "$(sk_text s1 'token xoxb-0123456789-abcdefghij')" >/dev/null
sk_poll "$GAMMA"
SECRET_ID="$(jq -r 'select(.kind == "notice") | .id' "$(sk_box "$GAMMA")/to-overseer.jsonl")"
assert_eq "$RC=$ERR1" "0=slack: secret-value=id=$SECRET_ID" "a notice matching the secret-value pattern is refused by id"
assert_eq "$(sk_state '[.messages.C002[] | select(.text | contains("xoxb"))] | length')" "0" "nothing matching the pattern is posted"
assert_eq "$(jq -r "select(.t == \"out\" and .id == \"$SECRET_ID\") | .state" "$(sk_journal "$GAMMA")")" "refused" "the refusal is journaled"

# --- a 429 is honoured by Retry-After -------------------------------------------------------
sk_ctl /_test/calls-reset >/dev/null
sk_ctl /_test/fault '{"method": "conversations.history", "status": 429, "retry_after": 0, "times": 1}' >/dev/null
L1="$(sk_inject C002 U001 'after the limit')"
sk_poll "$GAMMA"
assert_eq "$RC=$(sk_state '[.calls[] | select(. == "conversations.history")] | length')" "0=2" "a 429 is retried after Retry-After"
assert_eq "$(directives "$GAMMA" | sed -n '4p')" "C002:$L1 after the limit" "the message behind the 429 lands"

# --- owners re-resolved from the setting before delivery -----------------------------------
sk_poll "$GAMMA" SLACK_OWNERS="$OWNER"
assert_eq "$(jq -r '[(.owners | join(",")), (.owner_ids | keys | join(","))] | join(" ")' "$GAMMA/tmp/slack/binding.json")" \
  "$OWNER $OWNER" "a changed SLACK_OWNERS rewrites the binding's owners and ids"
X1="$(sk_inject C002 U002 'still me?')"
sk_poll "$GAMMA" SLACK_OWNERS="$OWNER"
assert_has "$(posts C002)" "$X1 | Only the channel's owners steer this session" "a removed owner loses routing at that poll"

# --- controls, one mutant per rule ------------------------------------------------------------
sk_mutant delivery mailbox.py '"--delivery-id", delivery_id, "--file"' '"--delivery-id", delivery_id + "." + str(os.getpid()), "--file"'
DELTA="$(sk_new_root delta)"
sk_bind "$DELTA"
crash_gap "$DELTA"
assert_eq "$GAP_COUNT" "3" "control: the delivery id dropped, the replayed note lands twice"
sk_bin_reset

sk_mutant resolve relay.py 'thread\.kind == "ask":' 'thread.kind == "never":'
EPS="$(sk_new_root eps)"
sk_bind "$EPS"
sk_lm "$EPS" ask --item overseer --to owner --file "$(sk_text q4 'Which?')" --options a,b --recommend a >/dev/null
sk_poll "$EPS"
EPS_CH="$(sk_channel "$EPS")"
ASK4_TS="$(sk_state ".messages.${EPS_CH}[] | select(.text | contains(\"Which?\")) | .ts")"
sk_inject "$EPS_CH" U001 'b' "$ASK4_TS" >/dev/null
sk_poll "$EPS"
assert_eq "$(answers "$EPS" | wc -l | tr -d ' ')=$(directives "$EPS" | wc -l | tr -d ' ')" "0=1" \
  "control: the ask thread no longer resolved, the reply lands as a directive"
sk_bin_reset

sk_mutant lock store.py 'fcntl\.LOCK_EX \| fcntl\.LOCK_NB' 'fcntl.LOCK_SH | fcntl.LOCK_NB'
sk_relay_start "$EPS"
sk_poll "$EPS"
assert_eq "$RC" "0" "control: the lock no longer exclusive, a second relay runs"
sk_relay_stop
sk_bin_reset

sk_mutant horizon relay.py 'tenth and float\(thread\.ts\) >= horizon' 'tenth'
ZETA="$(sk_new_root zeta)"
sk_bind "$ZETA"
ZETA_CH="$(sk_channel "$ZETA")"
OLD2="$(sk_inject "$ZETA_CH" U001 'old' '' "\"ts\": \"$OLD_TS\"")"
sk_poll "$ZETA"
sk_inject "$ZETA_CH" U001 'late reply' "$OLD2" >/dev/null
for n in 2 3 4 5 6 7 8 9 10; do sk_poll "$ZETA"; done
assert_eq "$(directives "$ZETA" | wc -l | tr -d ' ')" "2" "control: the horizon removed, the reply under the old thread is routed"
sk_bin_reset

sk_summary
