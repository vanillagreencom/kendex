#!/usr/bin/env bash
# `slack compact`: lines resolved or ignored longer ago than SLACK_THREAD_DAYS,
# an old report's upload, an old read directive's receipt marks, and every
# history position but the last leave the journal; every open ask, every
# young line, an old directive still marked eyes with its delivery, and an
# old directive Slack refused to mark with its delivery stay, the relay reads
# the compacted file as before, marks the unmarked directive eyes and swaps
# both marks once read, and a running relay's lock refuses the verb. Six
# controls, one per rule: a mutant that drops no old line, one that keeps
# every receipt mark, one that keeps no unread directive, one that keeps no
# unmarked directive, one that keeps every history position, and one that
# takes no lock.
set -uo pipefail
. "$(dirname "$0")/lib/harness.sh"

sk_fake_start
echo "=== slack compact ==="

ROOT="$(sk_new_root alpha)"
sk_bind "$ROOT"
OLD_TS="$(python3 -c 'import time; print("%.6f" % (time.time() - 9 * 86400))')"
OLD_REPLY="$(python3 -c 'import time; print("%.6f" % (time.time() - 9 * 86400 + 60))')"
OLD_SHARE="$(python3 -c 'import time; print("%.6f" % (time.time() - 9 * 86400 + 120))')"
OLD_UNMARKED="$(python3 -c 'import time; print("%.6f" % (time.time() - 9 * 86400 + 90))')"
OLD_UNMARKED_LOST="$(python3 -c 'import time; print("%.6f" % (time.time() - 9 * 86400 + 150))')"
OLD_AT="$(python3 -c 'import time; print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - 9 * 86400)))')"
# An old ask answered long ago, an old ignored non-owner line, an old bound
# notice, an old report's upload and its share, old read receipt marks, an old
# history position, and an open ask: only the open ask stays.
JOURNAL="$(sk_journal "$ROOT")"
mkdir -p "$(dirname "$JOURNAL")"
cat > "$JOURNAL" <<EOF
{"at": "$OLD_AT", "channel": "C001", "id": "ASK-OLD", "kind": "ask", "state": "open", "t": "out", "thread": "$OLD_TS"}
{"channel": "C001", "id": "ANS-OLD", "kind": "answer", "t": "in", "thread": "$OLD_TS", "ts": "$OLD_REPLY"}
{"id": "ASK-OLD", "t": "resolved"}
{"seen": "$OLD_REPLY", "t": "thread", "ts": "$OLD_TS"}
{"channel": "C001", "kind": "ignored", "reason": "not-owner", "t": "in", "ts": "$OLD_REPLY"}
{"at": "$OLD_AT", "channel": "C001", "id": "NOTE-OLD", "kind": "notice", "state": "resolved", "t": "out", "thread": "$OLD_TS"}
{"at": "$OLD_AT", "channel": "C001", "file": "F-OLD", "id": "REPORT-OLD", "kind": "notice", "state": "file", "t": "out"}
{"file": "F-OLD", "id": "REPORT-OLD", "t": "bound", "ts": "$OLD_SHARE"}
{"at": "$OLD_AT", "channel": "C001", "id": "ASK-OPEN", "kind": "ask", "state": "open", "t": "out", "thread": "$OLD_REPLY"}
{"name": "eyes", "t": "mark", "ts": "$OLD_REPLY"}
{"name": "white_check_mark", "t": "mark", "ts": "$OLD_REPLY"}
{"t": "seen", "ts": "$OLD_REPLY"}
EOF
YOUNG="$(sk_inject C001 U001 'young')"
sk_poll "$ROOT"
BEFORE="$(wc -l < "$JOURNAL" | tr -d ' ')"
sk_run -- compact --root "$ROOT"
assert_eq "$RC=$OUT" "0=slack: compacted=$ROOT dropped=11" "compact prints the lines it dropped"
assert_eq "$(jq -r '[.t, (.ts // .id)] | join(":")' "$JOURNAL" | tr '\n' ' ')" \
  "out:ASK-OPEN in:$YOUNG seen:$YOUNG mark:$YOUNG " \
  "the open ask, the young delivery, its mark and the last position stay; the resolved, ignored, uploaded, marked and superseded old lines go"
assert_eq "$((BEFORE - $(wc -l < "$JOURNAL" | tr -d ' ')))" "11" "the file shrank by the lines reported"
NEXT="$(sk_inject C001 U001 'after compaction')"
sk_poll "$ROOT"
assert_eq "$RC=$(jq -r 'select(.t == "in") | .ts' "$JOURNAL" | tr '\n' ' ')" "0=$YOUNG $NEXT " \
  "the relay reads the compacted journal and goes on from its last position"
# A directive read long ago leaves with its marks; one still marked eyes
# keeps its delivery and its mark whatever its age, and swaps once read; one
# whose eyes mark Slack refused keeps its delivery, is marked on the next
# poll, and swaps once read.
GAMMA="$(sk_new_root gamma)"
sk_bind "$GAMMA"
sk_rebind_at "$GAMMA" "$(python3 -c 'import time; print("%.6f" % (time.time() - 10 * 86400))')"
GAMMA_CH="$(sk_channel "$GAMMA")"
READ_OLD="$(sk_inject "$GAMMA_CH" U001 'read long ago' '' "\"ts\": \"$OLD_TS\"")"
sk_poll "$GAMMA"
sk_lm "$GAMMA" inbox --item overseer >/dev/null
sk_poll "$GAMMA"
UNREAD_OLD="$(sk_inject "$GAMMA_CH" U001 'still unread' '' "\"ts\": \"$OLD_REPLY\"")"
sk_poll "$GAMMA"
UNMARKED_OLD="$(sk_inject "$GAMMA_CH" U001 'never marked' '' "\"ts\": \"$OLD_UNMARKED\"")"
sk_ctl /_test/fault '{"method": "reactions.add", "error": "missing_scope"}' >/dev/null
sk_poll "$GAMMA"
receipts() { jq -r 'select(.t == "in" or .t == "mark") | [.t, .ts, (.name // .kind)] | join(":")' "$(sk_journal "$1")" | tr '\n' ' '; } # ROOT
assert_eq "$RC $(sk_reactions "$GAMMA_CH" "$READ_OLD") $(sk_reactions "$GAMMA_CH" "$UNREAD_OLD") [$(sk_reactions "$GAMMA_CH" "$UNMARKED_OLD")]" \
  "0 white_check_mark eyes []" "one old directive is read, one is not, and Slack refused the third its mark"
sk_run -- compact --root "$GAMMA"
assert_eq "$RC=$(receipts "$GAMMA")" "0=in:$UNREAD_OLD:directive mark:$UNREAD_OLD:eyes in:$UNMARKED_OLD:directive " \
  "the old unread directive keeps its delivery and its eyes mark, the old unmarked one its delivery; the old read one keeps neither"
sk_poll "$GAMMA"
assert_eq "$RC $(sk_reactions "$GAMMA_CH" "$UNMARKED_OLD")" "0 eyes" "the next poll marks the kept unmarked directive"
sk_lm "$GAMMA" inbox --item overseer >/dev/null
sk_poll "$GAMMA"
assert_eq "$RC $(sk_reactions "$GAMMA_CH" "$UNREAD_OLD") $(sk_reactions "$GAMMA_CH" "$UNMARKED_OLD")" "0 white_check_mark white_check_mark" \
  "both kept directives swap to a check once the overseer reads them"
sk_run SLACK_THREAD_DAYS=0 -- compact --root "$ROOT"
assert_eq "$RC=$ERR1" "2=slack: setting-invalid=SLACK_THREAD_DAYS=0" "a thread-days value under 1 is refused"
sk_run -- compact --root "$SK_TMP/nowhere"
assert_eq "$RC=$ERR1" "2=slack: root-unreadable=$SK_TMP/nowhere" "a root that is no directory is refused"
BETA="$(sk_new_root beta)"
sk_bind "$BETA"
sk_relay_start "$BETA"
HELD="$(cat "$(sk_journal "$BETA")")"
sk_run -- compact --root "$BETA"
assert_eq "$RC=${ERR1%% pid=*}" "2=slack: relay-running=$BETA" "compact beside a running relay is refused by its lock"
assert_eq "$(cat "$(sk_journal "$BETA")")" "$HELD" "the refused compact leaves the relay's journal as it was"
sk_relay_stop

# --- controls, one per rule -------------------------------------------------------
sk_mutant keep store.py 'if drop:\n            dropped \+= 1' 'if False:\n            dropped += 1'
cat >> "$JOURNAL" <<EOF
{"channel": "C001", "kind": "ignored", "reason": "not-owner", "t": "in", "ts": "$OLD_TS"}
EOF
sk_run -- compact --root "$ROOT"
assert_eq "$RC=$OUT" "0=slack: compacted=$ROOT dropped=0" "control: the drop rule gone, an old ignored line stays"
sk_bin_reset

sk_relay_start "$BETA"
sk_mutant lock verbs.py 'lock\.acquire\(\)' 'lock.path'
sk_run -- compact --root "$BETA"
assert_eq "$RC=${OUT%% dropped=*}" "0=slack: compacted=$BETA" "control: the lock gone, compact rewrites the journal beside the relay"
sk_bin_reset
sk_relay_stop

sk_mutant positions store.py 'drop = index != last_seen' 'drop = False'
cat >> "$JOURNAL" <<EOF
{"t": "seen", "ts": "$NEXT"}
EOF
sk_run -- compact --root "$ROOT"
assert_eq "$RC=$(jq -r 'select(.t == "seen") | .ts' "$JOURNAL" | wc -l | tr -d ' ')" "0=3" \
  "control: the position rule gone, every history position stays"
sk_bin_reset

sk_mutant marks store.py 'elif kind == "mark" and old:\n            drop = not pending' 'elif kind == "mark" and old:\n            drop = False'
cat >> "$JOURNAL" <<EOF
{"name": "white_check_mark", "t": "mark", "ts": "$OLD_TS"}
EOF
sk_run -- compact --root "$ROOT"
assert_eq "$RC=$(jq -r 'select(.t == "mark") | .ts' "$JOURNAL" | tr '\n' ' ')" "0=$YOUNG $NEXT $OLD_TS " "control: the mark rule gone, an old receipt mark stays"
sk_bin_reset

sk_mutant pending store.py 'pending = kind in \("in", "mark"\) and' 'pending = False and'
UNREAD_LOST="$(sk_inject "$GAMMA_CH" U001 'unread and lost' '' "\"ts\": \"$OLD_SHARE\"")"
sk_run -- listen --root "$GAMMA" --once
sk_run -- compact --root "$GAMMA"
sk_bin_reset
sk_lm "$GAMMA" inbox --item overseer >/dev/null
sk_poll "$GAMMA"
assert_eq "$(receipts "$GAMMA" | grep -c "$UNREAD_LOST")|$(sk_reactions "$GAMMA_CH" "$UNREAD_LOST")" "0|eyes" \
  "control: the unread rule gone, an old eyes directive loses its lines and never swaps"

sk_mutant unmarked store.py 'state\.marks\.get\(str\(line\["ts"\]\)\) != READ' 'state.marks.get(str(line["ts"]), READ) != READ'
UNMARKED_LOST="$(sk_inject "$GAMMA_CH" U001 'unmarked and lost' '' "\"ts\": \"$OLD_UNMARKED_LOST\"")"
sk_ctl /_test/fault '{"method": "reactions.add", "error": "missing_scope"}' >/dev/null
sk_run -- listen --root "$GAMMA" --once
sk_run -- compact --root "$GAMMA"
sk_bin_reset
sk_poll "$GAMMA"
assert_eq "$(receipts "$GAMMA" | grep -c "$UNMARKED_LOST")|$(sk_reactions "$GAMMA_CH" "$UNMARKED_LOST")" "0|" \
  "control: the unmarked rule gone, an old directive Slack refused to mark loses its line and is never marked"

sk_summary
