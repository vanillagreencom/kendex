#!/usr/bin/env bash
# `slack compact`: lines resolved or ignored longer ago than SLACK_THREAD_DAYS,
# an old report's upload, and every history position but the last leave the
# journal; every open ask and every young line stay, the relay reads the
# compacted file as before, and a running relay's lock refuses the verb.
# Three controls, one per rule: a mutant that drops no old line, one that
# keeps every history position, and one that takes no lock.
set -uo pipefail
. "$(dirname "$0")/lib/harness.sh"

sk_fake_start
echo "=== slack compact ==="

ROOT="$(sk_new_root alpha)"
sk_bind "$ROOT"
OLD_TS="$(python3 -c 'import time; print("%.6f" % (time.time() - 9 * 86400))')"
OLD_REPLY="$(python3 -c 'import time; print("%.6f" % (time.time() - 9 * 86400 + 60))')"
OLD_SHARE="$(python3 -c 'import time; print("%.6f" % (time.time() - 9 * 86400 + 120))')"
OLD_AT="$(python3 -c 'import time; print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - 9 * 86400)))')"
# An old ask answered long ago, an old ignored non-owner line, an old bound
# notice, an old report's upload and its share, an old history position,
# and an open ask: only the open ask stays.
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
{"t": "seen", "ts": "$OLD_REPLY"}
EOF
YOUNG="$(sk_inject C001 U001 'young')"
sk_poll "$ROOT"
BEFORE="$(wc -l < "$JOURNAL" | tr -d ' ')"
sk_run -- compact --root "$ROOT"
assert_eq "$RC=$OUT" "0=slack: compacted=$ROOT dropped=9" "compact prints the lines it dropped"
assert_eq "$(jq -r '[.t, (.ts // .id)] | join(":")' "$JOURNAL" | tr '\n' ' ')" \
  "out:ASK-OPEN in:$YOUNG seen:$YOUNG " \
  "the open ask, the young delivery and the last position stay; the resolved, ignored, uploaded and superseded old lines go"
assert_eq "$((BEFORE - $(wc -l < "$JOURNAL" | tr -d ' ')))" "9" "the file shrank by the lines reported"
NEXT="$(sk_inject C001 U001 'after compaction')"
sk_poll "$ROOT"
assert_eq "$RC=$(jq -r 'select(.t == "in") | .ts' "$JOURNAL" | tr '\n' ' ')" "0=$YOUNG $NEXT " \
  "the relay reads the compacted journal and goes on from its last position"
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

sk_summary
