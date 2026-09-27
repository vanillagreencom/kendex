#!/usr/bin/env bash
# `slack compact`: lines resolved or ignored longer ago than SLACK_THREAD_DAYS
# and every history position but the last leave the journal; every open ask
# and every young line stay, and the relay reads the compacted file as
# before. Two controls, one per rule: a mutant that drops no old line, and
# one that keeps every history position.
set -uo pipefail
. "$(dirname "$0")/lib/harness.sh"

sk_fake_start
echo "=== slack compact ==="

ROOT="$(sk_new_root alpha)"
sk_bind "$ROOT"
OLD_TS="$(python3 -c 'import time; print("%.6f" % (time.time() - 9 * 86400))')"
OLD_REPLY="$(python3 -c 'import time; print("%.6f" % (time.time() - 9 * 86400 + 60))')"
# An old ask answered long ago, an old ignored non-owner line, an old bound
# notice, an old history position, and an open ask: only the open ask stays.
JOURNAL="$(sk_journal "$ROOT")"
mkdir -p "$(dirname "$JOURNAL")"
cat > "$JOURNAL" <<EOF
{"channel": "C001", "id": "ASK-OLD", "kind": "ask", "state": "open", "t": "out", "thread": "$OLD_TS"}
{"channel": "C001", "id": "ANS-OLD", "kind": "answer", "t": "in", "thread": "$OLD_TS", "ts": "$OLD_REPLY"}
{"id": "ASK-OLD", "t": "resolved"}
{"seen": "$OLD_REPLY", "t": "thread", "ts": "$OLD_TS"}
{"channel": "C001", "kind": "ignored", "reason": "not-owner", "t": "in", "ts": "$OLD_REPLY"}
{"channel": "C001", "id": "NOTE-OLD", "kind": "notice", "state": "resolved", "t": "out", "thread": "$OLD_TS"}
{"channel": "C001", "id": "ASK-OPEN", "kind": "ask", "state": "open", "t": "out", "thread": "$OLD_REPLY"}
{"t": "seen", "ts": "$OLD_REPLY"}
EOF
YOUNG="$(sk_inject C001 U001 'young')"
sk_poll "$ROOT"
BEFORE="$(wc -l < "$JOURNAL" | tr -d ' ')"
sk_run -- compact --root "$ROOT"
assert_eq "$RC=$OUT" "0=slack: compacted=$ROOT dropped=7" "compact prints the lines it dropped"
assert_eq "$(jq -r '[.t, (.ts // .id)] | join(":")' "$JOURNAL" | tr '\n' ' ')" \
  "out:ASK-OPEN in:$YOUNG seen:$YOUNG " \
  "the open ask, the young delivery and the last position stay; the resolved, ignored and superseded old lines go"
assert_eq "$((BEFORE - $(wc -l < "$JOURNAL" | tr -d ' ')))" "7" "the file shrank by the lines reported"
NEXT="$(sk_inject C001 U001 'after compaction')"
sk_poll "$ROOT"
assert_eq "$RC=$(jq -r 'select(.t == "in") | .ts' "$JOURNAL" | tr '\n' ' ')" "0=$YOUNG $NEXT " \
  "the relay reads the compacted journal and goes on from its last position"
sk_run SLACK_THREAD_DAYS=0 -- compact --root "$ROOT"
assert_eq "$RC=$ERR1" "2=slack: setting-invalid=SLACK_THREAD_DAYS=0" "a thread-days value under 1 is refused"
sk_run -- compact --root "$SK_TMP/nowhere"
assert_eq "$RC=$ERR1" "2=slack: root-unreadable=$SK_TMP/nowhere" "a root that is no directory is refused"

# --- controls, one per rule -------------------------------------------------------
sk_mutant keep store.py 'if drop:\n            dropped \+= 1' 'if False:\n            dropped += 1'
cat >> "$JOURNAL" <<EOF
{"channel": "C001", "kind": "ignored", "reason": "not-owner", "t": "in", "ts": "$OLD_TS"}
EOF
sk_run -- compact --root "$ROOT"
assert_eq "$RC=$OUT" "0=slack: compacted=$ROOT dropped=0" "control: the drop rule gone, an old ignored line stays"
sk_bin_reset

sk_mutant positions store.py 'drop = index != last_seen' 'drop = False'
cat >> "$JOURNAL" <<EOF
{"t": "seen", "ts": "$NEXT"}
EOF
sk_run -- compact --root "$ROOT"
assert_eq "$RC=$(jq -r 'select(.t == "seen") | .ts' "$JOURNAL" | wc -l | tr -d ' ')" "0=3" \
  "control: the position rule gone, every history position stays"
sk_bin_reset

sk_summary
