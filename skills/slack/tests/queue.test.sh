#!/usr/bin/env bash
# bash-runtime: 3.2
# Queue delivery shares the real message handler and lane-mail. The worker
# parses keyed outcomes; the assertions below hold that external contract.
set -euo pipefail
. "$(dirname "$0")/lib/harness.sh"

sk_fake_start
ROOT="$(sk_new_root queue)" || exit 1
sk_bind "$ROOT"

# Process settings select one source; the default still requires its app token.
sk_run SLACK_INBOUND=invalid -- listen --root "$ROOT"
assert_eq "$RC=${ERR1%%=*}" '2=slack: setting-invalid' 'unknown inbound mode is refused'
sk_run -- listen --root "$ROOT"
assert_eq "$RC=$ERR1" '2=slack: setting-missing=SLACK_APP_TOKEN' 'default Socket Mode still requires the app token'
sk_ctl /_test/calls-reset '{}' >/dev/null
sk_poll "$ROOT" SLACK_INBOUND=queue
assert_eq "$RC" 0 'queue once needs no app token'
assert_eq "$(sk_state '[.calls[] | select(. == "apps.connections.open" or . == "conversations.history")] | length')" \
  0 'queue once opens no socket and reads no history'

CONFIG="$SK_TMP/queue-config"
SYSTEMCTL="$(sk_fake_systemctl)" || exit 1
sk_run SLACK_INBOUND=queue -- install --root "$ROOT" --print
assert_eq "$RC" 0 'queue install accepts no app token'
mkdir -p "$CONFIG/systemd/user" || exit 1
printf '%s\n' "$OUT" > "$CONFIG/systemd/user/slack-listen.service"
sk_run SLACK_INBOUND=queue XDG_CONFIG_HOME="$CONFIG" PATH="$SYSTEMCTL:$PATH" -- setup --root "$ROOT"
assert_eq "$RC" 0 'queue setup can restart an installed unit without an app token'

# The bound and dispatch run without wall-clock waits. The timeout keeps its
# queued request, and a retry's mailbox key still belongs to lane-mail.
probe() {
  env -i PATH="$PATH" HOME="$SK_TMP/home" LANG=C PYTHONDONTWRITEBYTECODE=1 \
    SLACK_ORCH_DIR="$SK_ROOT/skills/orch" SLACK_INBOUND=queue \
    SLACK_BOT_TOKEN="$SK_TOKEN" SLACK_OWNERS="$OWNERS" SLACK_API_URL="$SK_URL" \
    python3 "$SK_ROOT/skills/slack/tests/lib/queue_probe.py" "${SK_BIN%/*}/lib" "$1" "$2"
}
TIMEOUT="$(sk_new_root timeout)" || exit 1
sk_bind "$TIMEOUT"
RESULT="$(probe "$TIMEOUT" timeout)" || exit 1
assert_eq "$(jq -r '.key == "delivery-timeout" and .elapsed == 20 and .pending == 1' <<<"$RESULT")" \
  true 'the injected wait expires at its bound and leaves the event queued'

DIRECT="$(sk_new_root direct)" || exit 1
sk_bind "$DIRECT"
RESULT="$(probe "$DIRECT" dispatch)" || exit 1
assert_eq "$(jq -r '.key' <<<"$RESULT")" delivered 'queue dispatch completes through the existing message handler'
assert_eq "$(landed "$DIRECT" "$(sk_channel "$DIRECT"):1794111600.000001" 1)" \
  'Injected queue delivery.' 'queue dispatch writes the real mailbox'

while read -r scenario expected; do
  CASE_ROOT="$(sk_new_root "$scenario")" || exit 1
  sk_bind "$CASE_ROOT"
  RESULT="$(probe "$CASE_ROOT" "$scenario")" || exit 1
  assert_eq "$(jq -r '.key' <<<"$RESULT")" "$expected" "queue outcome: $scenario"
done <<'CASES'
repeat delivery-repeated
not-owner not-owner
no-text no-text
bot event-ignored
edit event-ignored
CASES
assert_eq "$(jq -s 'length' "$(sk_box "$SK_TMP/repeat")/to-lane.jsonl")" 1 'repeat keeps one real mailbox entry'

sk_mutant queue-dispatch inbound.py '    root.on_message\(event, bot_user, path="queue"\)' \
  '    if False: root.on_message(event, bot_user, path="queue")'
CONTROL="$(sk_new_root dispatch-control)" || exit 1
sk_bind "$CONTROL"
RESULT="$(probe "$CONTROL" dispatch)" || exit 1
sk_assert_red "$(jq -r '.key' <<<"$RESULT")" delivered 'control: disabling queue dispatch fails the same delivery assertion'
sk_bin_reset

# One real listener proves CLI wiring, with no app token and no Socket Mode
# connection. These waits observe outcomes and an outbound upload, not elapsed
# time as a substitute for completion.
sk_relay_start "$ROOT" SLACK_INBOUND=queue SLACK_APP_TOKEN=
sk_run -- listen --status --root "$ROOT"
assert_eq "$(field "$OUT" inbound)=$(field "$OUT" state)" 'queue=ok' 'status names the active queue source'

event_file() {
  sk_ctl /_test/state | jq --arg c "$(sk_channel "$ROOT")" --arg ts "$1" \
    '.messages[$c][] | select(.ts == $ts) | . + {channel:$c}' > "$SK_TMP/event.json"
}
TS="$(sk_inject "$(sk_channel "$ROOT")" U001 'Worker fixture.')" || exit 1
event_file "$TS" || exit 1
sk_run SLACK_INBOUND=queue -- deliver --root "$ROOT" < "$SK_TMP/event.json"
assert_eq "$RC" 0 'deliver receives a real listener outcome'
assert_eq "$(field "$OUT" path)" queue 'the worker result identifies the queue path'
assert_eq "$(landed "$ROOT" "$(sk_channel "$ROOT"):$TS" 1)" 'Worker fixture.' 'deliver lands one fixture through real lane-mail'
sk_run SLACK_INBOUND=queue -- deliver --root "$ROOT" < "$SK_TMP/event.json"
assert_eq "$RC=${ERR1%%=*}" '2=slack: delivery-repeated' 'a second deliver returns delivery-repeated'
assert_eq "$(jq -s --arg d "$(sk_channel "$ROOT"):$TS" '[.[] | select(.delivery_id==$d)] | length' "$(sk_box "$ROOT")/to-lane.jsonl")" \
  1 'repeated CLI delivery keeps one mailbox entry'

for scenario in not-owner no-text; do
  USER_ID=U001 TEXT='Refuse this author.'
  if [ "$scenario" = not-owner ]; then USER_ID=U404; else TEXT=''; fi
  TS="$(sk_inject "$(sk_channel "$ROOT")" "$USER_ID" "$TEXT")" || exit 1
  event_file "$TS" || exit 1
  sk_run SLACK_INBOUND=queue -- deliver --root "$ROOT" < "$SK_TMP/event.json"
  assert_eq "$RC=${ERR1%%=*}" "2=slack: $scenario" "CLI refusal: $scenario"
  assert_eq "$(printf '%s\n' "$ERR" | wc -l | tr -d ' ')" 1 'worker refusals contain one keyed line'
done

mkdir -p "$ROOT/tmp/progress-reports" || exit 1
REPORT="$ROOT/tmp/progress-reports/queue-report.md"
printf 'Queue report.\n' > "$REPORT"
COMMENT="$(sk_text upload 'Queue file binding.')" || exit 1
sk_lm "$ROOT" notice --item overseer --to owner --attach "$REPORT" --file "$COMMENT" > "$SK_TMP/notice.out" || exit 1
NOTICE="$(field "$(cat "$SK_TMP/notice.out")" id)"
share() {
  sk_state ".messages[\"$(sk_channel "$ROOT")\"][] | select(.bot_id and .files) | .ts"
}
TRIES=0 SHARE=''
while [ -z "$SHARE" ] && [ "$TRIES" -lt 100 ]; do
  SHARE="$(share)" || exit 1
  [ -n "$SHARE" ] || sleep 0.1
  TRIES=$((TRIES + 1))
done
[ -n "$SHARE" ] || { printf 'queue upload did not appear\n' >&2; exit 1; }
event_file "$SHARE" || exit 1
sk_run SLACK_INBOUND=queue -- deliver --root "$ROOT" < "$SK_TMP/event.json"
assert_eq "$RC=$(field "$OUT" id)" "0=$NOTICE" 'a bot upload event completes the original notice binding'
assert_eq "$(jq -r --arg id "$NOTICE" 'select(.t=="bound" and .id==$id) | .ts' "$(sk_journal "$ROOT")")" \
  "$SHARE" 'the queue file binding is journaled under its Slack thread'
assert_eq "$(sk_state '[.calls[] | select(. == "apps.connections.open" or . == "conversations.history")] | length')" \
  0 'the running queue listener makes no socket or history call'
sk_relay_stop
sk_run SLACK_INBOUND=queue -- deliver --root "$ROOT" < "$SK_TMP/event.json"
assert_eq "$RC=${ERR1%%=*}" '2=slack: relay-absent' 'deliver refuses a stopped listener even with its old status and lock file'

for input in '{}' '{"type":"event_callback","event":{"type":"message"}}' '{"type":"message","channel":"C001","ts":"NaN"}' 'not json'; do
  sk_run SLACK_INBOUND=queue -- deliver --root "$ROOT" <<< "$input"
  assert_eq "$RC=${ERR1%%=*}" '2=slack: event-invalid' 'malformed or outer callback input is refused'
done

sk_relay_start "$ROOT"
sk_run -- deliver --root "$ROOT" < "$SK_TMP/event.json"
assert_eq "$RC=${ERR1%%=*}" '2=slack: inbound-mode' 'deliver refuses a live Socket Mode listener'
sk_relay_stop

sk_summary
