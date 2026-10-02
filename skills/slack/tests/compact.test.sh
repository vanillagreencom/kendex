#!/usr/bin/env bash
# `slack compact`: lines resolved or ignored longer ago than SLACK_THREAD_DAYS,
# an old report's upload, an old read directive's receipt marks, and every
# history position but the last leave the journal; every open ask, every
# young line, an old directive still marked eyes with its delivery, and an
# old directive Slack refused to mark with its delivery stay, the relay reads
# the compacted file as before, marks the unmarked directive eyes and swaps
# both marks once read, and a running relay's lock refuses the verb; an old
# connection line leaves and a young one stays. Seven controls, one per rule:
# a mutant that drops no old line, one that keeps every receipt mark, one
# that keeps no unread directive, one that keeps no unmarked directive, one
# that keeps every history position, one that keeps every connection line,
# and one that takes no lock.
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
YOUNG_AT="$(python3 -c 'import time; print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))')"
# The first start's `start` line, which compaction keeps, then an old ask
# answered long ago, an old ignored non-owner line, an old bound
# notice, an old report's upload and its share, old read receipt marks, an old
# history position, an old disconnect, an open ask and a young connect: only
# the start, the open ask and the young connect stay.
JOURNAL="$(sk_journal "$ROOT")"
mkdir -p "$(dirname "$JOURNAL")"
cat > "$JOURNAL" <<EOF
{"at": "", "ids": [], "t": "start"}
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
{"at": "$OLD_AT", "reason": "connection ended", "t": "disconnect"}
{"at": "$YOUNG_AT", "t": "connect"}
EOF
sk_inject C001 UBOT 'Open ask parent.' '' "\"ts\": \"$OLD_REPLY\", \"bot_id\": \"B01\"" >/dev/null
YOUNG="$(sk_inject C001 U001 'young')"
sk_poll "$ROOT"
assert_eq "$(jq -c .open_asks "$ROOT/tmp/slack/status.json")" '["ASK-OPEN"]' "the matching Slack parent keeps ASK-OPEN open before compaction"
BEFORE="$(wc -l < "$JOURNAL" | tr -d ' ')"
sk_run -- compact --root "$ROOT"
assert_eq "$RC=$OUT" "0=slack: compacted=$ROOT dropped=12" "compact prints the lines it dropped"
assert_eq "$(jq -r '[.t, (.ts // .id // .at)] | join(":")' "$JOURNAL" | tr '\n' ' ')" \
  "start: out:ASK-OPEN connect:$YOUNG_AT in:$YOUNG mark:$YOUNG seen:$YOUNG " \
  "the start, the open ask, the young connect, the young delivery, its mark and the last position stay; the resolved, ignored, uploaded, marked, superseded and old connection lines go"
assert_eq "$((BEFORE - $(wc -l < "$JOURNAL" | tr -d ' ')))" "12" "the file shrank by the lines reported"
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

# A resume keeps its skipped ids as one line, by its own `at`, not the
# hold's start or the master's count. Compaction drops the aged line whole.
RESUMES="$(sk_new_root resumes)"
sk_bind "$RESUMES"
cat > "$(sk_journal "$RESUMES")" <<EOF
{"at": "", "ids": [], "t": "start"}
{"t": "resume", "from_at": "$OLD_AT", "at": "$OLD_AT", "seen": 3, "skipped": ["OLD-SKIP"], "asks": []}
{"t": "resume", "from_at": "$OLD_AT", "at": "$YOUNG_AT", "seen": 4, "skipped": ["YOUNG-SKIP"], "asks": []}
EOF
sk_run -- compact --root "$RESUMES"
assert_eq "$RC=$(jq -cr 'select(.t == "resume") | .skipped' "$(sk_journal "$RESUMES")")" '0=["YOUNG-SKIP"]' \
  "compaction keeps skipped ids with the young resume and drops them with the aged resume"

# Replay the real journal after its completed posts age out. A lone pre-send
# line is still uncertain; a later outcome, including retry, settles it.
for mode in production settled-control unknown-control; do
  SETTLED="$(sk_new_root "settled-$mode")"
  sk_bind "$SETTLED"
  SETTLED_CH="$(sk_channel "$SETTLED")"
  SETTLED_JOURNAL="$(sk_journal "$SETTLED")"
  printf '%s\n' '{"t":"start","at":"","ids":[]}' >"$SETTLED_JOURNAL"
  while read -r id kind outcome; do
    printf '{"t":"out","channel":"%s","id":"%s","kind":"%s","state":"inflight","at":"%s"}\n' "$SETTLED_CH" "$id" "$kind" "$OLD_AT" >>"$SETTLED_JOURNAL"
    case "$outcome" in
      lone) ;;
      file) printf '{"t":"out","channel":"%s","id":"%s","kind":"%s","state":"file","at":"%s","file":"F-SETTLED"}\n' "$SETTLED_CH" "$id" "$kind" "$OLD_AT" >>"$SETTLED_JOURNAL" ;;
      retry|unknown) printf '{"t":"out","channel":"%s","id":"%s","kind":"%s","state":"%s","at":"%s","reason":"slack-rate-limited"}\n' "$SETTLED_CH" "$id" "$kind" "$outcome" "$OLD_AT" >>"$SETTLED_JOURNAL" ;;
      open|resolved)
        printf '{"t":"out","channel":"%s","id":"%s","kind":"%s","state":"%s","at":"%s","thread":"%s"}\n' "$SETTLED_CH" "$id" "$kind" "$outcome" "$OLD_AT" "$OLD_TS" >>"$SETTLED_JOURNAL"
        [ "$outcome" != open ] || printf '{"t":"resolved","id":"%s"}\n' "$id" >>"$SETTLED_JOURNAL"
        ;;
      *) printf 'unknown compaction outcome: %s\n' "$outcome" >&2; exit 1 ;;
    esac
  done <<'ROWS'
NOTICE notice resolved
ANSWER answer resolved
REPORT notice file
ASK ask open
RETRY notice retry
UNKNOWN notice unknown
UNSETTLED notice lone
ROWS
  case "$mode" in
    production) ;;
    settled-control) sk_mutant settled-inflight store.py 'drop = str\(line\["id"\]\) not in state.unknown' 'drop = False' ;;
    unknown-control) sk_mutant unknown-inflight store.py 'drop = str\(line\["id"\]\) not in state.unknown' 'drop = True' ;;
  esac
  sk_run -- compact --root "$SETTLED"
  assert_eq "$RC" 0 "$mode: the post journal compacts"
  sk_recovery "$SETTLED" journal
  GOT="$(printf '%s\n' "$OUT" | tail -n 1 | jq -cr '[.error,.unknown]')"
  if [ "$mode" = production ]; then
    assert_eq "$GOT" '["",["UNKNOWN","UNSETTLED"]]' 'compaction replay keeps uncertain posts without resurrecting a notice, answer, report, closed ask or retry'
    assert_eq "$(jq -s '[.[] | select(.t == "out" and (.id == "NOTICE" or .id == "ANSWER" or .id == "REPORT" or .id == "ASK"))] | length' "$SETTLED_JOURNAL")" 0 'aged completed posts leave no pre-send or outcome record'
  else
    sk_assert_red "$GOT" '["",["UNKNOWN","UNSETTLED"]]' "$mode: the same compaction replay assertion fails on the planted retention defect"
  fi
  sk_bin_reset
done

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

sk_mutant connection store.py 'elif kind in CONNECTION_KINDS:\n            drop = aged' 'elif kind in CONNECTION_KINDS:\n            drop = False'
cat >> "$JOURNAL" <<EOF
{"at": "$OLD_AT", "t": "reconnect"}
EOF
sk_run -- compact --root "$ROOT"
assert_eq "$RC=$(jq -r 'select(.t == "reconnect") | .at' "$JOURNAL")" "0=$OLD_AT" "control: the connection rule gone, an old reconnect line stays"
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
