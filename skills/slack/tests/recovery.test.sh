#!/usr/bin/env bash
# The relay's post and catch-up recovery through a fake Slack and real lane-mail.
# Controls mutate disposable runtimes and run the same behavioral assertions.
set -uo pipefail
. "$(dirname "$0")/lib/harness.sh"

sk_fake_start --page 2
echo '=== slack recovery ==='

# Slack can accept a post, then cut either a fixed-length or chunked response.
# The in-flight journal also prevents repetition when the API catch is removed;
# that control must still fail the successful-poll and unknown-outcome assertion.
for cut in length chunked control; do
  ROOT="$(sk_new_root "cut-$cut")"
  sk_bind "$ROOT"
  CH="$(sk_channel "$ROOT")"
  sk_poll "$ROOT"
  sk_lm "$ROOT" notice --item overseer --to owner --file "$(sk_text "$cut" "Cut $cut.")" >/dev/null
  ID="$(jq -r .id "$(sk_box "$ROOT")/to-overseer.jsonl")"
  if [ "$cut" = control ]; then
    sk_mutant response-catch api.py 'except \(OSError, http.client.HTTPException\) as err:' 'except OSError as err:'
  fi
  HOW="$cut"
  [ "$cut" != control ] || HOW=length
  sk_ctl /_test/fault "{\"method\":\"chat.postMessage\",\"cut\":\"$HOW\"}" >/dev/null
  sk_recovery "$ROOT" poll
  STATES="$(jq -sr --arg id "$ID" '[.[] | select(.t == "out" and .id == $id) | .state] | join(",")' "$(sk_journal "$ROOT")")"
  GOT="$(printf '%s\n' "$OUT" | tail -n 1 | jq -r .error)|$STATES"
  if [ "$cut" = control ]; then
    sk_assert_red "$GOT" '|inflight,unknown' 'control: the API catch is required to settle a truncated response'
  else
    assert_eq "$GOT" '|inflight,unknown' "$cut: a truncated response settles unknown without failing the poll"
    assert_has "$ERR1" 'slack: slack-response-lost=chat.postMessage' "$cut: the response-phase HTTPException has the lost-response key"
  fi
  sk_bin_reset
  sk_poll "$ROOT"
  assert_eq "$(asks "$CH" "Cut $cut.")|$(jq -c .unknown "$ROOT/tmp/slack/status.json")" "1|[\"$ID\"]" "$cut: restart reports unknown and does not post again"
done

# A failed pre-send append sends nothing. The next run can still post it.
ROOT="$(sk_new_root disk-full)"
sk_bind "$ROOT"
CH="$(sk_channel "$ROOT")"
sk_poll "$ROOT"
sk_lm "$ROOT" notice --item overseer --to owner --file "$(sk_text disk 'Disk full.')" >/dev/null
sk_recovery "$ROOT" append-fail
assert_eq "$(printf '%s\n' "$OUT" | tail -n 1 | jq -r .error)|$(asks "$CH" 'Disk full.')" 'OSError|0' 'a failed in-flight append sends nothing'
sk_poll "$ROOT"
assert_eq "$RC|$(asks "$CH" 'Disk full.')" '0|1' 'a later poll can post after storage recovers'

# Stop the real process after the real API accepts, before _send returns.
# Moving the in-flight append after the post leaves no record before this stop.
for mode in normal control replay-control; do
  ROOT="$(sk_new_root "kill-$mode")"
  sk_bind "$ROOT"
  CH="$(sk_channel "$ROOT")"
  sk_poll "$ROOT"
  sk_lm "$ROOT" notice --item overseer --to owner --file "$(sk_text "kill-$mode" "Kill $mode.")" >/dev/null
  ID="$(jq -r .id "$(sk_box "$ROOT")/to-overseer.jsonl")"
  if [ "$mode" = control ]; then
    sk_mutant post-first relay.py '        self._out\(envelope, kind, "inflight"\)\n        try:\n            if data is not None:\n                return self.api.upload\(Path\(attach\).name, data, self.channel, text, thread_ts\)\n            return str\(self.api.post\("chat.postMessage", channel=self.channel, thread_ts=thread_ts,\n                                     \*\*\{body_arg: text\}\)\["ts"\]\)' '        try:\n            if data is not None:\n                return self.api.upload(Path(attach).name, data, self.channel, text, thread_ts)\n            ts = str(self.api.post("chat.postMessage", channel=self.channel, thread_ts=thread_ts,\n                                     **{body_arg: text})["ts"])\n            self._out(envelope, kind, "inflight")\n            return ts'
  fi
  sk_recovery "$ROOT" kill
  assert_eq "$RC|$(asks "$CH" "Kill $mode.")" '9|1' "$mode: Slack accepts before the process stops"
  sk_bin_reset
  if [ "$mode" = replay-control ]; then
    sk_mutant inflight-replay store.py 'state in \("inflight", "unknown"\)' 'state in ("unknown",)'
  fi
  sk_poll "$ROOT"
  GOT="$RC|$(asks "$CH" "Kill $mode.")|$(jq -c .unknown "$ROOT/tmp/slack/status.json")"
  if [ "$mode" = normal ]; then
    assert_eq "$GOT" "0|1|[\"$ID\"]" 'restart replays a lone in-flight line as unknown and posts nothing'
  else
    sk_assert_red "$GOT" "0|1|[\"$ID\"]" "$mode: the crash recovery assertion fails with the journal rule removed"
    if [ "$mode" = control ]; then
      assert_eq "$(asks "$CH" "Kill $mode.")" '2' 'control: a post before its in-flight append posts twice across the stop'
    fi
  fi
  sk_bin_reset
done

# Slack's exhausted rate limit is an explicit refusal, not an uncertain post.
for mode in normal control; do
  ROOT="$(sk_new_root "rate-$mode")"
  sk_bind "$ROOT"
  CH="$(sk_channel "$ROOT")"
  sk_poll "$ROOT"
  sk_lm "$ROOT" notice --item overseer --to owner --file "$(sk_text "rate-$mode" "Rate $mode.")" >/dev/null
  if [ "$mode" = control ]; then
    sk_mutant retry-line relay.py '        self._out\(envelope, kind, "retry", reason=err.key\)' '        None if True else self._out(envelope, kind, "retry", reason=err.key)'
  fi
  sk_ctl /_test/fault '{"method":"chat.postMessage","status":429,"times":4,"retry_after":0}' >/dev/null
  sk_poll "$ROOT"
  assert_eq "$RC|$(asks "$CH" "Rate $mode.")" '1|0' "$mode: exhausted 429 retries fail the poll without a post"
  sk_bin_reset
  sk_poll "$ROOT"
  GOT="$RC|$(asks "$CH" "Rate $mode.")|$(jq -c .unknown "$ROOT/tmp/slack/status.json")"
  if [ "$mode" = normal ]; then
    assert_eq "$GOT" '0|1|[]' 'an explicit retry line leaves the rate-limited envelope postable on restart'
  else
    sk_assert_red "$GOT" '0|1|[]' 'control: removing the retry line breaks later delivery'
  fi
done

# A deleted open ask cannot block a healthy thread or same-poll outbound mail.
# lane-mail emits default/text answers and notices that reference the ask.
for mode in normal control target-control; do
while read -r answer; do
  ROOT="$(sk_new_root "missing-$mode-$answer")"
  sk_bind "$ROOT"
  CH="$(sk_channel "$ROOT")"
  sk_poll "$ROOT"
  sk_lm "$ROOT" ask --item overseer --to owner --file "$(sk_text "ask-$mode" 'Deleted ask?')" --options yes,no --recommend no --wait 30 >"$SK_TMP/ask.out"
  ID="$(sed 's/^id=//' "$SK_TMP/ask.out")"
  sk_poll "$ROOT"
  ASK_TS="$(sk_state ".messages.${CH}[-1].ts")"
  sk_ctl /_test/delete "{\"channel\":\"$CH\",\"ts\":\"$ASK_TS\"}" >/dev/null
  GOOD="$(sk_inject "$CH" U001 'Healthy parent.')"
  REPLY="$(sk_inject "$CH" U001 'Healthy reply.' "$GOOD")"
  sk_lm "$ROOT" notice --item overseer --to owner --ref "$ID" --file "$(sk_text "missing-$mode" "Outbound $mode.")" >/dev/null
  if [ "$mode" = control ]; then
    sk_mutant thread-refusal relay.py '        notice\("thread-read-failed",' '        raise err\n        notice("thread-read-failed",'
  elif [ "$mode" = target-control ]; then
    sk_mutant missing-target store.py 'return None if self.threads\[thread_ts\].missing else thread_ts' 'return thread_ts if self.threads[thread_ts].missing else thread_ts'
  fi
  sk_recovery "$ROOT" poll
  GOT="$(printf '%s\n' "$OUT" | tail -n 1 | jq -r .caught_up)|$(asks "$CH" "Outbound $mode.")"
  if [ "$mode" != control ]; then
    assert_eq "$GOT" 'true|1' "$mode/$answer: a deleted open ask leaves catch-up complete and outbound posts on the same poll"
    assert_has "$OUT" "slack: thread-read-failed=ts=$ASK_TS id=$ID reason=slack-api-failed" 'the per-thread failure line names its thread and envelope'
    assert_eq "$(jq -s --arg id "$ID" '[.[] | select(.t == "resolved" and .id == $id and .reason == "thread_not_found")] | length' "$(sk_journal "$ROOT")")|$(sk_lm "$ROOT" pending --item overseer --to owner | jq -r .id)" "1|$ID" 'only the journal thread closes; the mailbox ask stays open'
    assert_eq "$(jq -s --arg d "$CH:$REPLY" '[.[] | select(.delivery_id == $d)] | length' "$(sk_box "$ROOT")/to-lane.jsonl")" '1' 'another thread reply still lands'
    sk_ctl /_test/calls-reset >/dev/null
    sk_poll "$ROOT"
    assert_lacks "$OUT" "ts=$ASK_TS" 'restart skips the deleted ask thread'
    assert_eq "$(jq -s --arg id "$ID" '[.[] | select(.t == "resolved" and .id == $id)] | length' "$(sk_journal "$ROOT")")" '1' 'restart does not close the missing thread again'
    case "$answer" in
      default) sk_lm "$ROOT" resolve --item overseer --id "$ID" --default >/dev/null || exit 1 ;;
      text) sk_lm "$ROOT" resolve --item overseer --id "$ID" --text "$(sk_text missing-answer 'yes, in chat')" >/dev/null || exit 1 ;;
    esac
    sk_poll "$ROOT"
    GOT="$RC|$(sk_state "[.messages.${CH}[] | select(.bot_id != null) | (.thread_ts // \"\")] | @json")"
    if [ "$mode" = normal ]; then
      assert_eq "$GOT" '0|["",""]' "$answer: the referenced notice and later answer both post to the channel, never to the deleted ask"
      LAST_TS="$(sk_state ".messages.${CH}[-1].ts")"
      assert_eq "$(jq -sr '[.[] | select(.t == "out" and .kind == "answer" and .state == "resolved")][-1].thread' "$(sk_journal "$ROOT")")" "$LAST_TS" "$answer: the answer outcome records its new channel parent"
      sk_poll "$ROOT"
      assert_eq "$(sk_state "[.messages.${CH}[] | select(.bot_id != null)] | length")|$(sk_lm "$ROOT" pending --item overseer --to owner | wc -l | tr -d ' ')" '2|0' "$answer: restart repeats neither post and mailbox resolution closes the ask"
    else
      sk_assert_red "$GOT" '0|["",""]' "$answer: allowing missing outbound targets breaks the actual notice and answer destinations"
    fi
  else
    sk_assert_red "$GOT" 'true|1' 'control: re-raising the per-thread refusal breaks same-poll outbound'
  fi
  sk_bin_reset
done <<'ROWS'
default
text
ROWS
done

# A temporary conversations.replies refusal leaves catch-up due on the same
# RootRelay, and outbound mail still posts on the first poll. The newer thread
# is read first, so both faults leave it to that poll; the next poll reads the
# refused one. The rate control re-raises every refusal out of the poll's
# catch-up, as a slack-rate-limited one must not be.
for mode in normal control; do
while read -r parent fault want; do
  ROOT="$(sk_new_root "read-$mode-$parent-$fault")"
  sk_bind "$ROOT"
  CH="$(sk_channel "$ROOT")"
  sk_poll "$ROOT"
  if [ "$parent" = known ]; then
    sk_lm "$ROOT" notice --item overseer --to owner --file "$(sk_text retry-parent 'Retry parent.')" >/dev/null
    sk_poll "$ROOT"
  else
    sk_run -- post --root "$ROOT" --text 'Retry parent.'
  fi
  PARENT="$(sk_state ".messages.${CH}[-1].ts")"
  REPLY="$(sk_inject "$CH" U001 'Reply after read recovery.' "$PARENT")"
  GOOD="$(sk_inject "$CH" U001 'Unaffected parent.')"
  GOOD_REPLY="$(sk_inject "$CH" U001 'Unaffected reply.' "$GOOD")"
  sk_lm "$ROOT" notice --item overseer --to owner --file "$(sk_text retry-outbound 'Read retry outbound.')" >/dev/null
  NOTE="$(jq -r 'select(.text == "Read retry outbound.") | .id' "$(sk_box "$ROOT")/to-overseer.jsonl")"
  case "$fault" in
    rate) sk_ctl /_test/fault "{\"method\":\"conversations.replies\",\"ts\":\"$PARENT\",\"status\":429,\"retry_after\":0}" >/dev/null ;;
    cut) sk_ctl /_test/fault "{\"method\":\"conversations.replies\",\"ts\":\"$PARENT\",\"cut\":\"chunked\"}" >/dev/null ;;
  esac
  if [ "$mode" = control ]; then
    case "$fault" in
      rate) sk_mutant rate-poll relay.py 'if err\.key != "slack-rate-limited":\n                    raise' 'if True:\n                    raise' ;;
      cut) sk_mutant thread-retry relay.py '        return missing' '        return True' ;;
    esac
  fi
  sk_recovery "$ROOT" catchup-retry
  GOT="$(printf '%s\n' "$OUT" | tail -n 1 | jq -cr --arg reply "$REPLY" --arg good "$GOOD_REPLY" --arg note "$NOTE" '[.error,.polls[0].caught_up,(.polls[0].delivered | index($good) != null),(.polls[0].carried | index($note) != null),(.polls[1].delivered | index($reply) != null),(.polls[1].delivered | index($good) != null),.polls[1].caught_up]')"
  if [ "$mode" = normal ]; then
    assert_eq "$GOT" "$want" "$parent/$fault: same-instance catch-up retries the refused read while the first poll posts outbound mail"
    assert_eq "$(jq -s --arg d "$CH:$REPLY" '[.[] | select(.delivery_id == $d)] | length' "$(sk_box "$ROOT")/to-lane.jsonl")|$(asks "$CH" 'Read retry outbound.')" '1|1' "$parent/$fault: read recovery delivers the reply and outbound notice once"
  else
    sk_assert_red "$GOT" "$want" "$parent/$fault: completing a refused catch-up, or failing the poll on a rate limit, breaks same-instance recovery"
  fi
  sk_bin_reset
done <<'ROWS'
known rate ["",false,true,true,true,true,true]
known cut ["",false,true,true,true,true,true]
unknown rate ["",false,true,true,true,true,true]
unknown cut ["",false,true,true,true,true,true]
ROWS
done

# More threads hold an offline reply than Slack's allowance lets the catch-up
# read in one window. Each window's 429 ends that poll's catch-up with nothing
# slept; a poll inside the Retry-After reads nothing; the next window resumes
# past the threads already read, newest first, until the oldest reply lands
# and the catch-up completes, every reply once. ALLOW 2 puts the 429 on a
# thread read, 3 on a directive thread's parent read. Each control breaks one
# rule: the resume, the order, the hold, the rate limit ending the catch-up,
# and the parent read allowing no retry.
WANT='["",[],0,true,false,true,true]'
while read -r allow control; do
  ROOT="$(sk_new_root "allowance-$allow-$control")"
  sk_bind "$ROOT"
  CH="$(sk_channel "$ROOT")"
  sk_poll "$ROOT"
  TOPICS=()
  for n in 1 2 3 4 5; do TOPICS+=("$(sk_inject "$CH" U001 "Allowance topic $n.")"); done
  sk_poll "$ROOT"
  REPLIES=()
  for n in 1 2 3 4 5; do REPLIES+=("$(sk_inject "$CH" U001 "Offline reply $n." "${TOPICS[$((n - 1))]}")"); done
  case "$control" in
    resume) sk_mutant resume relay.py '\} - due, key=float' '}, key=float' ;;
    order) sk_mutant newest-first relay.py 'key=float, reverse=True\)' 'key=float)' ;;
    hold) sk_mutant hold relay.py 'self\.clock\(\) >= self\.catch_up_at' 'True' ;;
    rate-ends) sk_mutant rate-ends relay.py 'if err\.key in \("slack-auth-failed", "slack-rate-limited"\):' 'if err.key == "slack-auth-failed":' ;;
    parent-retry) sk_mutant parent-retry relay.py 'retries=0 if path == "catch-up" else RETRIES' 'retries=RETRIES' ;;
  esac
  sk_recovery "$ROOT" allowance "$allow"
  GOT="$(printf '%s\n' "$OUT" | tail -n 1 | jq -cr --arg new "${REPLIES[4]}" --arg old "${REPLIES[0]}" '[
    .error,
    [.polls[].slept[]],
    ([.polls | to_entries[] | select(.key % 2 == 1) | .value.replies] | add),
    (.polls[0].delivered | index($new) != null),
    (.polls[0].delivered | index($old) != null),
    (.polls[-1].delivered | index($old) != null),
    .polls[-1].caught_up]')"
  ONCE="$(for r in "${REPLIES[@]}"; do jq -s --arg d "$CH:$r" '[.[] | select(.delivery_id == $d)] | length' "$(sk_box "$ROOT")/to-lane.jsonl"; done | sort -u | tr '\n' ' ')"
  if [ "$control" = none ]; then
    assert_eq "$GOT|$ONCE" "$WANT|1 " "allow $allow: a rate-limited catch-up holds for Retry-After and resumes newest first until every offline reply lands once"
  else
    sk_assert_red "$GOT" "$WANT" "allow $allow: the $control control breaks the resumed catch-up"
  fi
  sk_bin_reset
done <<'ROWS'
2 none
3 none
2 resume
2 order
2 hold
2 rate-ends
3 parent-retry
ROWS

# An acknowledged live reply whose parent is deleted remains in pending_live
# after its first refusal, then is dropped once on poll without blocking posts.
for mode in normal control; do
ROOT="$(sk_new_root "pending-deleted-$mode")"
sk_bind "$ROOT"
CH="$(sk_channel "$ROOT")"
sk_poll "$ROOT"
sk_run -- post --root "$ROOT" --text 'External parent.'
PARENT="$(sk_state ".messages.${CH}[-1].ts")"
REPLY="$(sk_inject "$CH" U001 'Deleted reply.' "$PARENT")"
sk_ctl /_test/state | jq --arg c "$CH" --arg ts "$REPLY" '.messages[$c][] | select(.ts == $ts)' >"$SK_TMP/event.json" || exit 1
sk_ctl /_test/delete "{\"channel\":\"$CH\",\"ts\":\"$PARENT\"}" >/dev/null
sk_lm "$ROOT" notice --item overseer --to owner --file "$(sk_text pending 'Pending outbound.')" >/dev/null
if [ "$mode" = control ]; then
  sk_mutant pending-refusal relay.py 'err.error != "thread_not_found"' 'err.error == "thread_not_found"'
fi
sk_recovery "$ROOT" pending "$SK_TMP/event.json"
GOT="$(printf '%s\n' "$OUT" | tail -n 1 | jq -r '[.error,.pending,.caught_up] | @json')|$(asks "$CH" 'Pending outbound.')"
if [ "$mode" = normal ]; then
  assert_eq "$GOT" '["",0,true]|1' 'a permanently refused live event is dropped and outbound mail posts'
  assert_eq "$(grep -c 'slack: thread-read-failed=' <<<"$OUT")" '1' 'the deleted live parent prints one keyed line across two polls'
else
  sk_assert_red "$GOT" '["",0,true]|1' 'control: retaining a permanently refused live event blocks outbound mail'
fi
sk_bin_reset
done

# A new ref notice makes an old parent eligible even outside history.
for mode in normal age-control discovery-control; do
  ROOT="$(sk_new_root "active-$mode")"
  sk_bind "$ROOT"
  CH="$(sk_channel "$ROOT")"
  sk_poll "$ROOT"
  OLD_TS="$(python3 -c 'import time; print("%.6f" % (time.time() - 9 * 86400))')"
  PARENT="$(sk_inject "$CH" U001 'Old parent.' '' "\"ts\":\"$OLD_TS\"")"
  sk_event "$ROOT" "$CH" "$PARENT"
  REF="$(jq -r --arg d "$CH:$PARENT" 'select(.delivery_id == $d) | .id' "$(sk_box "$ROOT")/to-lane.jsonl")"
  sk_lm "$ROOT" notice --item overseer --to owner --ref "$REF" --file "$(sk_text "active-$mode" 'Recent activity.')" >/dev/null
  sk_poll "$ROOT"
  assert_eq "$(sk_state ".messages.${CH}[] | select(.text == \"Recent activity.\") | .thread_ts")" "$PARENT" "$mode: the notice posts into the old parent by ref"
  REPLY="$(sk_inject "$CH" U001 'Reply while stopped.' "$PARENT")"
  case "$mode" in
    age-control) sk_mutant parent-age relay.py 'max\(float\(thread.ts\), thread.active\)' 'float(thread.ts)' ;;
    discovery-control) sk_mutant replied-only relay.py 'thread.open or thread.ts not in replied or replied\[thread.ts\]' 'thread.open or False or replied.get(thread.ts, 0.0)' ;;
  esac
  sk_poll "$ROOT"
  sk_poll "$ROOT"
  GOT="$(jq -s --arg d "$CH:$REPLY" '[.[] | select(.kind == "directive" and .delivery_id == $d)] | length' "$(sk_box "$ROOT")/to-lane.jsonl")"
  if [ "$mode" = normal ]; then
    assert_eq "$GOT" '1' 'restart reads the recently active old thread and delivers the reply once'
  else
    sk_assert_red "$GOT" '1' "$mode: omitting recent activity or absent-history threads drops the reply"
  fi
  sk_bin_reset
done

sk_summary
