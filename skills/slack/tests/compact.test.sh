#!/usr/bin/env bash
# `slack compact`: lines resolved or ignored longer ago than SLACK_THREAD_DAYS,
# an old report's upload and superseded deliveries leave the journal.
# Required generation deliveries and their receipts stay for later live
# replies. Unread deliveries also stay without generation metadata, as
# older journals wrote them. Controls isolate that unread retention from
# generation retention, and exercise receipts, positions, connections,
# uncertain posts and the relay lock.
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
  "start: out:ASK-OPEN connect:$YOUNG_AT in:$YOUNG mark:$YOUNG parent:$OLD_REPLY seen:$YOUNG " \
  "the start, the open ask, the young connect, the young delivery, its mark, the parent the open ask's thread read recorded and the last position stay; the resolved, ignored, uploaded, marked, superseded and old connection lines go"
assert_eq "$((BEFORE - $(wc -l < "$JOURNAL" | tr -d ' ')))" "12" "the file shrank by the lines reported"
NEXT="$(sk_inject C001 U001 'after compaction')"
sk_poll "$ROOT"
assert_eq "$RC=$(jq -r 'select(.t == "in") | .ts' "$JOURNAL" | tr '\n' ' ')" "0=$YOUNG $NEXT " \
  "the relay reads the compacted journal and goes on from its last position"
# A read root keeps its generation mark for a later live reply. One marked eyes
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
assert_eq "$RC=$(receipts "$GAMMA")" "0=in:$READ_OLD:directive mark:$READ_OLD:eyes mark:$READ_OLD:white_check_mark in:$UNREAD_OLD:directive mark:$UNREAD_OLD:eyes in:$UNMARKED_OLD:directive " \
  "the read root keeps its generation delivery and receipts; the unread and unmarked directives also keep their deliveries"
sk_poll "$GAMMA"
assert_eq "$RC $(sk_reactions "$GAMMA_CH" "$UNMARKED_OLD")" "0 eyes" "the next poll marks the kept unmarked directive"
sk_lm "$GAMMA" inbox --item overseer >/dev/null
sk_poll "$GAMMA"
assert_eq "$RC $(sk_reactions "$GAMMA_CH" "$UNREAD_OLD") $(sk_reactions "$GAMMA_CH" "$UNMARKED_OLD")" "0 white_check_mark white_check_mark" \
  "both kept directives swap to a check once the overseer reads them"
READ_REPLY="$(sk_inject "$GAMMA_CH" U001 'Old topic reply.' "$READ_OLD" "\"ts\":\"$(python3 -c 'import time; print("%.6f" % (time.time() - 9 * 86400 + 180))')\"")"
sk_event "$GAMMA" "$GAMMA_CH" "$READ_REPLY"
assert_eq "$RC=$(jq -c --arg d "$GAMMA_CH:$READ_REPLY" 'select(.delivery_id == $d) | .parent.thread' "$(sk_box "$GAMMA")/to-lane.jsonl")" \
  "0=$(jq -nc --arg ts "$READ_REPLY" '[{ts:$ts,author:"owner",text:"Old topic reply."}]')" \
  "a live old-thread reply excludes the root already delivered before compaction"
sk_lm "$GAMMA" inbox --item overseer >/dev/null || exit 1
sk_poll "$GAMMA"
assert_eq "$RC=$(sk_reactions "$GAMMA_CH" "$READ_REPLY")" '0=white_check_mark' "the later old reply is read before its delivery supersedes the root mark"
# The saved scan position has expired together with the cached parent.
printf '{"t":"thread","ts":"%s","seen":"%s"}\n' "$READ_OLD" "$READ_REPLY" >> "$(sk_journal "$GAMMA")"
sk_run -- compact --root "$GAMMA"
assert_eq "$RC=$(jq -sr --arg ts "$READ_OLD" '[.[] | select((.t == "in" or .t == "mark") and .ts == $ts)] | length' "$(sk_journal "$GAMMA")")" \
  '0=0' "the later delivered reply lets compaction remove the superseded root delivery and receipts"
assert_eq "$(jq -sr '[.[] | select(.t == "parent" or .t == "thread")] | length' "$(sk_journal "$GAMMA")")" \
  0 "expired parent caches and saved thread scans still leave the journal"
assert_eq "$(jq -sr --arg ts "$READ_REPLY" '[.[] | select(.t == "mark" and .ts == $ts) | .name] | index("white_check_mark") != null' "$(sk_journal "$GAMMA")")" \
  true "the latest generation delivery keeps its read receipt after ordinary history prunes"
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
# hold's start or the Jarvis session's count. Compaction drops the aged line whole.
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

# An older journal's answer has no generation metadata. Its unread delivery
# and eyes mark stay; a read answer can leave with its marks.
ANSWER_UNREAD="$(python3 -c 'import time; print("%.6f" % (time.time() - 9 * 86400 + 30))')"
ANSWER_READ="$(python3 -c 'import time; print("%.6f" % (time.time() - 9 * 86400 + 45))')"
ANSWERS="$(sk_new_root answers)"
sk_bind "$ANSWERS"
cat > "$(sk_journal "$ANSWERS")" <<EOF
{"at": "", "ids": [], "t": "start"}
{"at": "$OLD_AT", "channel": "C001", "id": "ASK-DONE", "kind": "ask", "state": "open", "t": "out", "thread": "$OLD_TS"}
{"channel": "C001", "id": "ANS-UNREAD", "kind": "answer", "t": "in", "thread": "$OLD_TS", "ts": "$ANSWER_UNREAD"}
{"channel": "C001", "id": "ANS-READ", "kind": "answer", "t": "in", "thread": "$OLD_TS", "ts": "$ANSWER_READ"}
{"id": "ASK-DONE", "t": "resolved"}
{"name": "eyes", "t": "mark", "ts": "$ANSWER_UNREAD"}
{"name": "eyes", "t": "mark", "ts": "$ANSWER_READ"}
{"name": "white_check_mark", "t": "mark", "ts": "$ANSWER_READ"}
EOF
cp "$(sk_journal "$ANSWERS")" "$SK_TMP/answers.jsonl"
sk_run -- compact --root "$ANSWERS"
assert_eq "$RC=$(receipts "$ANSWERS")" "0=in:$ANSWER_UNREAD:answer mark:$ANSWER_UNREAD:eyes " \
  "the unread legacy answer keeps its delivery and eyes mark; the read legacy answer and receipts expire"

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

sk_mutant marks store.py 'elif kind == "mark" and old:\n            drop = not \(pending or retained\)' 'elif kind == "mark" and old:\n            drop = False'
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

# Older journal deliveries have no generation. Removing that fixture field
# isolates unread retention from the independent generation-retention rule.
while read -r mark mode; do
  LEGACY="$(sk_new_root "legacy-$mark-$mode")"
  sk_bind "$LEGACY"
  sk_rebind_at "$LEGACY" "$(python3 -c 'import time; print("%.6f" % (time.time() - 10 * 86400))')"
  LEGACY_CH="$(sk_channel "$LEGACY")"
  LEGACY_TS="$(sk_inject "$LEGACY_CH" U001 'An unread legacy directive.' '' "\"ts\":\"$OLD_UNMARKED_LOST\"")"
  if [ "$mark" = unmarked ]; then
    sk_ctl /_test/fault '{"method":"reactions.add","error":"missing_scope"}' >/dev/null
  fi
  sk_poll "$LEGACY"
  WANT_MARK=eyes
  [ "$mark" != unmarked ] || WANT_MARK=""
  assert_eq "$RC=$(sk_reactions "$LEGACY_CH" "$LEGACY_TS")" "0=$WANT_MARK" "$mark/$mode: the real delivery reaches its intended receipt state"
  jq -c --arg ts "$LEGACY_TS" 'if .t == "in" and .ts == $ts then del(.generation) else . end' "$(sk_journal "$LEGACY")" > "$SK_TMP/legacy-journal" || exit 1
  mv -- "$SK_TMP/legacy-journal" "$(sk_journal "$LEGACY")" || exit 1
  if [ "$mode" = control ]; then
    case "$mark" in
      eyes) sk_mutant pending store.py 'pending = kind in \("in", "mark"\) and' 'pending = False and' ;;
      unmarked) sk_mutant unmarked store.py 'state\.marks\.get\(str\(line\["ts"\]\)\) != READ' 'state.marks.get(str(line["ts"]), READ) != READ' ;;
    esac
  fi
  sk_run -- compact --root "$LEGACY"
  GOT="$RC=$(receipts "$LEGACY")"
  WANT="0=in:$LEGACY_TS:directive "
  [ "$mark" != eyes ] || WANT="${WANT}mark:$LEGACY_TS:eyes "
  if [ "$mode" = production ]; then
    assert_eq "$GOT" "$WANT" "$mark: unread legacy delivery and its existing receipt survive compaction"
  else
    sk_assert_red "$GOT" "$WANT" "$mark: disabling only the intended unread guard fails the same retention assertion"
  fi
  sk_bin_reset
  sk_poll "$LEGACY"
  sk_lm "$LEGACY" inbox --item overseer >/dev/null || exit 1
  sk_poll "$LEGACY"
  GOT="$RC=$(sk_reactions "$LEGACY_CH" "$LEGACY_TS")"
  if [ "$mode" = production ]; then
    assert_eq "$GOT" '0=white_check_mark' "$mark: the retained legacy directive gets its read receipt after the real inbox consumes it"
  else
    sk_assert_red "$GOT" '0=white_check_mark' "$mark: losing the legacy delivery prevents the later read receipt"
  fi
done <<'ROWS'
eyes production
eyes control
unmarked production
unmarked control
ROWS

sk_mutant answers store.py 'str\(line\["ts"\]\) in state\.delivered' 'str(line["ts"]) in state.delivered and line.get("kind") != "answer"'
cp "$SK_TMP/answers.jsonl" "$(sk_journal "$ANSWERS")"
sk_run -- compact --root "$ANSWERS"
sk_assert_red "$RC=$(receipts "$ANSWERS")" "0=in:$ANSWER_UNREAD:answer mark:$ANSWER_UNREAD:eyes " \
  "control: the unread rule kept to directives, an old eyes answer loses its delivery"
sk_bin_reset

sk_summary
