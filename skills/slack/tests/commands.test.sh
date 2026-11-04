#!/usr/bin/env bash
# The optional slash commands and Home tab on the relay's Socket Mode
# connection, against the fake and the real lane-mail. The rows: /lanes and
# /asks replying ephemerally with their configured command's output and
# writing no mailbox, output that is not UTF-8 replied with its bad byte
# replaced, a payload's text reaching no argument or stdin of the
# command, a non-owner and an owner a stale root binding still names refused
# with nothing run, an unknown command answered, /report landing one directive
# in the configured root and none in another, a resent payload landing
# nothing more and a distinct trigger_id a second directive, the overseer's
# notice answering a /report posted in the channel, also once as a new
# message while a Jarvis session hold stands, a payload with no
# trigger_id and a root with no recorded overseer each answered unavailable
# with nothing written, a second fixture whose destination is the other root,
# SLACK_REPORT_ROOT outside the relay's roots or relative refused at start,
# off commands answered as off, a failed, unstartable or secret-matching
# command replying without its output, a timed-out command's stderr, what it
# printed before the bound and on TERM, reaching the relay's stderr, the Home tab published for an owner on
# app_home_opened and not for anyone else or another tab, a failed or
# secret-matching Home command published as its cause in place of an earlier
# view, and Home off, by an empty setting or Slack's not_enabled, printed once
# while the relay keeps routing. The controls: the owner gate read from the
# roots' bindings, the destination taken from the first root, a delivery id
# that changes on a resend, the answer to a /report skipped or routed as a
# notice a hold keeps back, a timed-out command's stderr after TERM dropped,
# the Home command's output sent unchecked, an unstartable command raised out of the
# worker, and Slack's not_enabled raised out of the worker. One worker answers
# envelopes in order, so a row that expects nothing waits for a later reply
# instead of a fixed time.
set -uo pipefail
. "$(dirname "$0")/lib/harness.sh"

sk_fake_start
echo "=== slack listen: slash commands and the Home tab ==="

NOT_OWNER_REPLY="ephemeral|Only the relay's owners run its commands; nothing ran."
REPORT_TEXT="The owner typed /report in Slack: send a progress report now."

# awaited CMD... — CMD's output once it is non-empty, 200 tenths of a second
# at most, and empty at once when the background relay has exited
awaited() {
  local tries=0 out
  while [ "$tries" -lt 200 ]; do
    out="$("$@")"
    if [ -n "$out" ]; then printf '%s' "$out"; return 0; fi
    if [ -n "${SK_BG_PIDS:-}" ] && ! kill -0 "$SK_BG_PIDS" 2>/dev/null; then return 0; fi
    tries=$((tries + 1))
    sleep 0.1
  done
  return 0
}
connection() { sk_run -- listen --status --root "$1"; field "$OUT" connection; } # ROOT
# relay ROOT [--root ROOT]... [VAR=VALUE]... — sk_relay_start, then a stop of
# the suite unless the relay holds its connection.
relay() {
  sk_relay_start "$@"
  [ "$(connection "$1")" = connected ] || { printf 'relay on %s did not connect\n' "$1" >&2; exit 1; }
}
# slash COMMAND USER [TRIGGER] [TEXT] — one slash command envelope; prints its
# response number. TRIGGER defaults to a fresh id; an empty one sends none.
slash() {
  local trigger="${3-T$RANDOM$RANDOM}"
  sk_ctl /_test/command "$(jq -cn --arg c "$1" --arg u "$2" --arg t "$trigger" --arg x "${4:-}" \
    '{command: $c, user_id: $u, channel_id: "C777", text: $x} + (if $t == "" then {} else {trigger_id: $t} end)')" \
    | jq -r .response
}
# reply N — `response_type|text` of the first reply to response N, awaited
reply() { awaited sk_state ".responses[\"$1\"][0] // empty | \"\(.response_type)|\(.text)\""; }
replies() { sk_state ".responses[\"$1\"] | length"; } # N
home_open() { sk_ctl /_test/home "$(jq -cn --arg u "$1" --arg t "${2:-home}" '{user: $u, tab: $t}')" >/dev/null; } # USER [TAB]
views() { sk_state '.views | length'; }
last_view() { sk_state '.views[-1] | "\(.user_id)|\([.view.blocks[].text.text] | join(""))"'; } # `user|text` of the last view published
# posts CHANNEL TEXT — top-level posts in CHANNEL carrying TEXT, or nothing while there are none
posts() { sk_state "[.messages.${1}[] | select((.thread_ts // .ts) == .ts and (.text | contains(\"$2\")))] | length | select(. > 0)"; }
# directives ROOT [KEY] — directives in ROOT's to-lane box, those keyed KEY when given
directives() {
  local file
  file="$(sk_box "$1")/to-lane.jsonl"
  [ -f "$file" ] || { echo 0; return 0; }
  jq -s --arg d "${2:-}" '[.[] | select(.kind == "directive" and ($d == "" or .delivery_id == $d))] | length' "$file"
}
directive_id() { jq -r --arg d "$2" 'select(.delivery_id == $d) | .id' "$(sk_box "$1")/to-lane.jsonl"; } # ROOT KEY

CMD="$SK_TMP/cmd"
mkdir -p "$CMD"
cat > "$CMD/status" <<EOF
#!/usr/bin/env bash
printf 'ran\n' >> "$CMD/status.runs"
printf 'status-fixture argc=%s stdin=%s\n' "\$#" "\$(wc -c | tr -d ' ')"
printf 'stderr-fixture\n' >&2
EOF
printf '#!/usr/bin/env bash\nprintf "asks-fixture\\n"\n' > "$CMD/asks"
printf '#!/usr/bin/env bash\nprintf "leaked-output\\n"\nexit 3\n' > "$CMD/fail"
printf '#!/usr/bin/env bash\nprintf "token xo%%sb-%%s\\n" x 123456789012\n' > "$CMD/secret"
printf '#!/usr/bin/env bash\nprintf "*Fleet* home-fixture\\n<https://example.test/pr/1|PR 1>\\n"\n' > "$CMD/home"
printf '#!/usr/bin/env bash\nprintf "caf\\351 status\\n"\n' > "$CMD/latin1"
# hang: a stderr line, then a wait past the command bound that TERM ends
# after one more stderr line.
cat > "$CMD/hang" <<'EOF'
#!/usr/bin/env bash
trap 'printf "hang-on-term\n" >&2; exit 0' TERM
printf 'hang-before\n' >&2
sleep 60 &
wait
EOF
# home-seq: the Home fixture on its first run, then output and exit 4, then a secret.
cat > "$CMD/home-seq" <<EOF
#!/usr/bin/env bash
n=\$((\$(cat "$CMD/home-seq.n" 2>/dev/null || echo 0) + 1))
echo "\$n" > "$CMD/home-seq.n"
case "\$n" in
  1) exec "$CMD/home" ;;
  2) printf 'home-fixture-stale\n'; exit 4 ;;
  *) exec "$CMD/secret" ;;
esac
EOF
chmod +x "$CMD"/*
runs() {
  if [ ! -e "$CMD/status.runs" ]; then echo 0; return 0; fi
  wc -l < "$CMD/status.runs" | tr -d ' '
}

ALPHA="$(sk_new_root alpha)"
BETA="$(sk_new_root beta)"
GAMMA="$(sk_new_root gamma)"
sk_bind "$ALPHA"
sk_bind "$BETA"
sk_bind "$GAMMA"
# gamma records no overseer: lane-mail refuses an owner send there before appending.
rm -- "$GAMMA/tmp/workflow-state-oversee.json"
# alpha's binding still maps an owner to an id SLACK_OWNERS no longer resolves to.
jq '.owner_ids["brad@example.test"] = "U009"' "$ALPHA/tmp/slack/binding.json" > "$SK_TMP/stale.json"
cp "$SK_TMP/stale.json" "$ALPHA/tmp/slack/binding.json"
ALPHA_CH="$(sk_channel "$ALPHA")"

CONFIGURED=("SLACK_STATUS_COMMAND=$CMD/status" "SLACK_ASKS_COMMAND=$CMD/asks" "SLACK_HOME_COMMAND=$CMD/home")

# Both status names share the current owner gate. Keep this scenario usable
# by the dispatch and repeated-warning controls below.
status_commands() {
  local name user before after number response text alpha_before beta_before alpha_after beta_after
  STATUS_RESULT=""
  # Errexit is off; required evidence must keep the reader's failure status.
  alpha_before="$(directives "$ALPHA")" || return $?
  beta_before="$(directives "$BETA")" || return $?
  relay "$ALPHA" --root "$BETA" "${CONFIGURED[@]}"
  for name in /lanes /status; do
    for user in U001 U999 U009 U001; do
      before="$(runs)" || return $?
      number="$(slash "$name" "$user" "" "; touch $SK_TMP/pwned")"
      reply "$number" >/dev/null
      response="$(sk_state ".responses[\"$number\"][0].response_type")"
      text="$(sk_state ".responses[\"$number\"][0].text")"
      # Configured stdout is the product result; refusal wording is not.
      [ "$user" = U001 ] || text="withheld"
      after="$(runs)" || return $?
      STATUS_RESULT="$STATUS_RESULT$name:$user:$response:$((after - before)):$text;"
    done
  done
  alpha_after="$(directives "$ALPHA")" || return $?
  beta_after="$(directives "$BETA")" || return $?
  STATUS_RESULT="$STATUS_RESULT$((alpha_after - alpha_before))|$((beta_after - beta_before))|$([ -e "$SK_TMP/pwned" ] && echo ran || echo none)"
  STATUS_WARNINGS="$(sed -n 's/^slack: command-renamed=\([^ ]*\) fix=\([^ ]*\) remove-in=\([^ ]*\)$/\1|\2|\3/p' "$SK_TMP/relay.err")"
  sk_relay_stop
}
STATUS_EXPECTED=""
for name in /lanes /status; do
  STATUS_EXPECTED="$STATUS_EXPECTED$name:U001:ephemeral:1:status-fixture argc=0 stdin=0;"
  STATUS_EXPECTED="$STATUS_EXPECTED$name:U999:ephemeral:0:withheld;$name:U009:ephemeral:0:withheld;"
  STATUS_EXPECTED="$STATUS_EXPECTED$name:U001:ephemeral:1:status-fixture argc=0 stdin=0;"
done
STATUS_EXPECTED="${STATUS_EXPECTED}0|0|none"
status_commands || exit $?
assert_eq "$STATUS_RESULT" "$STATUS_EXPECTED" "both status names return configured output only to current owners, without payload execution or mailbox writes"
assert_eq "$STATUS_WARNINGS" "/status|/lanes|2.0.0" "the retired command warns once with its replacement and removal version"
# --- settings refused at start -------------------------------------------------
sk_run "SLACK_REPORT_ROOT=$GAMMA" -- listen --root "$ALPHA" --root "$BETA" --once
assert_eq "$RC=$ERR1" "2=slack: setting-invalid=SLACK_REPORT_ROOT=$GAMMA fix=name a checkout this relay's --root serves" \
  "a SLACK_REPORT_ROOT outside the relay's roots refuses its start"
sk_run "SLACK_REPORT_ROOT=gamma" -- listen --root "$GAMMA" --once
assert_eq "$RC=$ERR1" "2=slack: setting-invalid=SLACK_REPORT_ROOT=gamma" "a relative SLACK_REPORT_ROOT is refused"

# --- configured commands, the owner gate and /report to alpha ----------------------
# stale_gate: /lanes from the id alpha's stale binding names; prints its reply.
stale_gate() { reply "$(slash /lanes U009)"; }
# Each scenario below starts and stops its own relay in this shell, so the
# stop reaches it, and leaves its answer in RESULT.
# second_report: /report with beta as the destination over alpha and beta;
# alpha's and beta's directive counts for its key.
second_report() {
  local key
  relay "$ALPHA" --root "$BETA" "SLACK_REPORT_ROOT=$BETA"
  key="T-beta-$RANDOM"
  reply "$(slash /report U001 "$key")" >/dev/null
  RESULT="$(directives "$ALPHA" "command:$key")|$(directives "$BETA" "command:$key")"
  sk_relay_stop
}
# report_trip: one /report sent twice with one trigger_id to alpha, then the
# overseer's notice answering its first directive and a later notice; the
# count of directives whose key starts with the trigger_id's and the
# answer's top-level posts in alpha's channel once the later notice posted.
report_trip() {
  local key answer keyed
  relay "$ALPHA" "SLACK_REPORT_ROOT=$ALPHA"
  key="T-resend-$RANDOM"
  answer="Progress report $key."
  reply "$(slash /report U001 "$key")" >/dev/null
  reply "$(slash /report U001 "$key")" >/dev/null
  keyed="$(jq -r --arg d "command:$key" 'select(.kind == "directive" and (.delivery_id | startswith($d))) | .id' \
    "$(sk_box "$ALPHA")/to-lane.jsonl")"
  sk_lm "$ALPHA" notice --item overseer --to owner --ref "$(printf '%s\n' "$keyed" | sed -n 1p)" \
    --file "$(sk_text report-answer "$answer")" >/dev/null
  sk_lm "$ALPHA" notice --item overseer --to owner --file "$(sk_text report-later "After $key.")" >/dev/null
  awaited posts "$ALPHA_CH" "After $key." >/dev/null
  RESULT="$(printf '%s\n' "$keyed" | grep -c .)|$(posts "$ALPHA_CH" "$answer")"
  sk_relay_stop
}
# held_report: /report to alpha while the Jarvis session presence file is
# fresh, then an unrelated owner notice and a notice whose --ref names the
# directive (oversee-report's own report notice carries none); the hold as status shows it once the answer posted, the
# answer's top-level posts and the unrelated notice's posts.
held_report() {
  local key answer
  touch -- "$SK_TMP/jarvis-session-live"
  relay "$ALPHA" "SLACK_REPORT_ROOT=$ALPHA" "SLACK_JARVIS_SESSION_FILE=$SK_TMP/jarvis-session-live"
  key="T-held-$RANDOM"
  answer="Held progress report $key."
  reply "$(slash /report U001 "$key")" >/dev/null
  sk_lm "$ALPHA" notice --item overseer --to owner --file "$(sk_text held-unrelated "Unrelated $key.")" >/dev/null
  sk_lm "$ALPHA" notice --item overseer --to owner --ref "$(directive_id "$ALPHA" "command:$key")" \
    --file "$(sk_text held-answer "$answer")" >/dev/null
  awaited posts "$ALPHA_CH" "$answer" >/dev/null
  RESULT="$(jq -r .held_by "$ALPHA/tmp/slack/status.json")|$(posts "$ALPHA_CH" "$answer")|$(posts "$ALPHA_CH" "Unrelated $key.")"
  sk_relay_stop
}

relay "$ALPHA" --root "$BETA" "SLACK_REPORT_ROOT=$ALPHA" "${CONFIGURED[@]}"
reply "$(slash /lanes U001)" >/dev/null
assert_has "$(cat "$SK_TMP/relay.err")" "stderr-fixture" "the command's stderr goes to the relay's stderr"
assert_eq "$(reply "$(slash /asks U002)")" "ephemeral|asks-fixture" "/asks replies with its command's output"
assert_eq "$(directives "$ALPHA")|$(directives "$BETA")" "0|0" "/lanes and /asks write no mailbox"
assert_eq "$(reply "$(slash /deploy U001)")" "ephemeral|/deploy is not a command this relay answers." "an unknown command is answered"

REPORT_REPLY="$(reply "$(slash /report U001 T-alpha-1)")"
REPORT_ID="$(directive_id "$ALPHA" command:T-alpha-1)"
assert_eq "$REPORT_REPLY" "ephemeral|Report requested from the overseer at $ALPHA (id=$REPORT_ID)." \
  "/report's reply names the checkout reached and the directive"
assert_eq "$(directives "$ALPHA" command:T-alpha-1)|$(directives "$BETA")|$(jq -r 'select(.delivery_id == "command:T-alpha-1") | .text' "$(sk_box "$ALPHA")/to-lane.jsonl")" \
  "1|0|$REPORT_TEXT" "/report lands one directive, keyed by its trigger_id, in the configured root alone"
assert_eq "$(reply "$(slash /report U001 T-alpha-1)")|$(directives "$ALPHA")" "$REPORT_REPLY|1" \
  "a resent /report lands nothing more and names the directive that landed"
reply "$(slash /report U002 T-alpha-2)" >/dev/null
assert_eq "$(directives "$ALPHA" command:T-alpha-2)|$(directives "$ALPHA")" "1|2" "a distinct trigger_id is a second directive"
assert_eq "$(reply "$(slash /report U001 "")")|$(directives "$ALPHA")" \
  "ephemeral|/report carried no usable trigger_id; nothing was sent.|2" "a /report with no trigger_id writes nothing"

home_open U001
home_open U999
home_open U001 messages
reply "$(slash /asks U001)" >/dev/null
assert_eq "$(views)|$(sk_state '.views[0] | "\(.user_id)|\(.view.type)|\(.view.blocks[0].type)|\(.view.blocks[0].text.text)"')" \
  "1|U001|home|section|*Fleet* home-fixture
<https://example.test/pr/1|PR 1>" "the Home tab is published for the owner who opened it, and for no one else or another tab"
assert_eq "$(replies 1)" "1" "a command is answered once"
sk_relay_stop

# --- a second fixture: the destination is the setting's root ------------------------
second_report
assert_eq "$RESULT" "0|1" "with beta configured, /report lands in beta and not in alpha"

# --- the overseer's answer to /report -------------------------------------------------
report_trip
assert_eq "$RESULT" "1|1" "a resent /report lands one directive, and the overseer's notice answering it posts once in the channel"
held_report
assert_eq "$RESULT" "jarvis|1|" "while a Jarvis session hold stands, a notice naming the /report directive posts once as a new message and an unrelated notice stays held"

# --- unavailable destination, off commands and Home off -------------------------------
relay "$GAMMA" "SLACK_REPORT_ROOT=$GAMMA" "SLACK_ASKS_COMMAND=$CMD/secret"
assert_eq "$(reply "$(slash /report U001 T-gamma-1)")|$(directives "$GAMMA")" \
  "ephemeral|No overseer is recorded at $GAMMA; nothing was sent.|0" "a root with no recorded overseer is answered unavailable and nothing is written"
assert_eq "$(reply "$(slash /lanes U001)")" "ephemeral|/lanes is not enabled on this relay; SLACK_STATUS_COMMAND turns it on." \
  "an off command says so"
home_open U001
home_open U001
assert_eq "$(reply "$(slash /asks U001)")" "ephemeral|/asks failed (secret-value); its output is not shown." \
  "output matching the secret-value pattern is withheld, and the relay goes on after Home off"
assert_eq "$(grep -c '^slack: home-not-enabled=setting$' "$SK_TMP/relay.err")|$(views)" "1|1" \
  "an empty SLACK_HOME_COMMAND prints home-not-enabled once and publishes nothing"
sk_relay_stop

# --- a failed command, and Slack's not_enabled ----------------------------------------
# home_refused: Slack refuses one views.publish not_enabled; the count of
# home-not-enabled lines, the views published by a second owner's open, and
# the text of an owner message sent after, which the worker reaches only once
# both opens are handled. The relay keeps running for the rows after it.
home_refused() {
  local ts before text
  relay "$ALPHA" "SLACK_HOME_COMMAND=$CMD/home" "SLACK_STATUS_COMMAND=$CMD/fail"
  sk_ctl /_test/fault '{"method": "views.publish", "error": "not_enabled"}' >/dev/null
  before="$(views)"
  home_open U001
  home_open U002
  ts="$(sk_inject "$ALPHA_CH" U002 "After Home off $RANDOM.")"
  text="$(landed "$ALPHA" "$ALPHA_CH:$ts" 50 | cut -c1-14)"
  RESULT="$(grep -c '^slack: home-not-enabled=slack$' "$SK_TMP/relay.err")|$(($(views) - before))|$text"
}
home_refused
assert_eq "$RESULT" "1|0|After Home off" "Slack's not_enabled prints home-not-enabled once, a later open publishes nothing, and the relay still routes messages"
FAILED="$(reply "$(slash /lanes U001)")"
assert_eq "$FAILED" "ephemeral|/lanes failed (exit-3); its output is not shown." "a failed command's reply names the cause"
assert_lacks "$FAILED" "leaked-output" "a failed command's reply carries none of its output"
assert_has "$(cat "$SK_TMP/relay.err")" "slack: command-failed=SLACK_STATUS_COMMAND cause=exit-3" "the failure is one keyed line on stderr"
sk_relay_stop

# --- withheld output: a bad byte, a failed or secret Home command, a missing command ---
# withheld: over beta, /lanes whose command prints a byte that is not
# UTF-8, three owner Home opens of home-seq, each followed, once a later
# reply shows the worker handled it, by the views this relay has published
# and the last one, and last /asks naming a missing command, whose failure a
# mutant can turn into a relay stop.
withheld() {
  local i before
  rm -f -- "${CMD:?}/home-seq.n"
  relay "$BETA" "SLACK_HOME_COMMAND=$CMD/home-seq" "SLACK_STATUS_COMMAND=$CMD/latin1" "SLACK_ASKS_COMMAND=$CMD/missing"
  BAD_BYTE="$(reply "$(slash /lanes U001)")"
  before="$(views)"
  VIEWS=()
  for i in 1 2 3; do
    home_open U001
    reply "$(slash /deploy U001)" >/dev/null
    VIEWS+=("$(($(views) - before))|$(last_view)")
  done
  MISSING="$(reply "$(slash /asks U001)")"
  sk_relay_stop
}
HOME_SECRET="3|U001|SLACK_HOME_COMMAND failed (secret-value); its output is not shown."
MISSING_REPLY="ephemeral|/asks failed (start); its output is not shown."
withheld
assert_eq "$BAD_BYTE" "ephemeral|caf"$'\xef\xbf\xbd'" status" "output that is not UTF-8 is replied with the bad byte replaced, and the relay goes on"
assert_eq "${VIEWS[0]}" "1|U001|*Fleet* home-fixture
<https://example.test/pr/1|PR 1>" "a Home command's output is the view"
assert_eq "${VIEWS[1]}" "2|U001|SLACK_HOME_COMMAND failed (exit-4); its output is not shown." \
  "a failed Home command after a published view publishes its cause and none of its output"
assert_eq "${VIEWS[2]}" "$HOME_SECRET" "a secret-matching Home command's output is withheld and the view names the refusal"
assert_has "$(cat "$SK_TMP/relay.err")" "slack: secret-value=command=SLACK_HOME_COMMAND" "the Home refusal is one keyed line on stderr"
assert_eq "$MISSING" "$MISSING_REPLY" "a command line that cannot start replies with the cause"

# --- a timed-out command ------------------------------------------------------------
# timed_out: /lanes whose command outlasts the bound; its reply, and how many
# of the relay's stderr lines carry each of the command's two stderr lines and
# the timeout's keyed line.
timed_out() {
  relay "$ALPHA" "SLACK_STATUS_COMMAND=$CMD/hang"
  RESULT="$(reply "$(slash /lanes U001)")"
  RESULT="$RESULT|$(grep -c '^hang-before$' "$SK_TMP/relay.err")|$(grep -c '^hang-on-term$' "$SK_TMP/relay.err")"
  RESULT="$RESULT|$(grep -c '^slack: command-failed=SLACK_STATUS_COMMAND cause=timeout$' "$SK_TMP/relay.err")"
  sk_relay_stop
}
TIMED_OUT="ephemeral|/lanes failed (timeout); its output is not shown.|1|1|1"
timed_out
assert_eq "$RESULT" "$TIMED_OUT" "a timed-out command replies timeout, and its stderr before the bound and on TERM reaches the relay's stderr"

# The real threaded reader/worker invokes this target for slash AND Home.
# Its first operation observes its own score; parent scoring must not change.
cat > "$CMD/score" <<'PY'
#!/usr/bin/env python3
import pathlib, sys
score = pathlib.Path('/proc/self/oom_score_adj').read_text().strip() if sys.platform.startswith('linux') else 'not-linux'
print('score=' + score)
PY
chmod +x "$CMD/score"
score_run() {
  relay "$ALPHA" "SLACK_STATUS_COMMAND=$CMD/score" "SLACK_HOME_COMMAND=$CMD/score"
  SCORE_PARENT_BEFORE="$(python3 - "$SK_BG_PIDS" <<'PY'
import pathlib,sys
p = pathlib.Path('/proc') / sys.argv[1] / 'oom_score_adj'
print(p.read_text().strip() if p.exists() else 'not-linux')
PY
)"
  SCORE_SLASH="$(reply "$(slash /lanes U001)")"
  home_open U001
  reply "$(slash /deploy U001)" >/dev/null
  SCORE_HOME="$(last_view)"
  SCORE_PARENT_AFTER="$(python3 - "$SK_BG_PIDS" <<'PY'
import pathlib,sys
p = pathlib.Path('/proc') / sys.argv[1] / 'oom_score_adj'
print(p.read_text().strip() if p.exists() else 'not-linux')
PY
)"
  sk_relay_stop
}
SCORE_WANT=not-linux
[ ! -e /proc/self/oom_score_adj ] || SCORE_WANT=1000
score_run
assert_eq "$SCORE_SLASH|$SCORE_HOME" "ephemeral|score=$SCORE_WANT|U001|score=$SCORE_WANT" 'slash and Home targets observe child scoring before exec'
assert_eq "$SCORE_PARENT_BEFORE" "$SCORE_PARENT_AFTER" 'the threaded relay never changes its own score'
if [ "$SCORE_WANT" = 1000 ]; then
  sk_mutant score-999 mailbox.py 'command_score = 1000' 'command_score = 999'
  score_run
  assert_eq "$SCORE_SLASH|$SCORE_HOME" 'ephemeral|score=999|U001|score=999' 'score control really executes both targets with 999, including consistent readback'
  sk_assert_red "$SCORE_SLASH|$SCORE_HOME" 'ephemeral|score=1000|U001|score=1000' 'control: the same independent child score assertion rejects 999'
  sk_bin_reset
fi

cat > "$CMD/output" <<'PY'
#!/usr/bin/env python3
import os, pathlib, sys
mode = pathlib.Path(__file__).with_name('output.mode').read_text().strip()
C = 52096
token = b'xo' + b'xb-' + b'123456789012'
if mode == 'split-secret':
    os.write(1,b'x' * 4093 + b' ' + token[:2])
    os.write(1,token[2:])
elif mode == 'boundary-secret':
    os.write(1,b'prefix-sentinel' + b'x' * (C-18) + b' ' + token)
elif mode == 'discard-secret':
    os.write(1,b'prefix-sentinel' + b'x' * C + b' ' + token)
elif mode in ('oversize','nonzero'):
    os.write(1,b'prefix-sentinel' + b'x' * C)
    if mode == 'nonzero': sys.exit(3)
elif mode == 'stderr':
    os.write(2,b'local-only' + b'e' * C)
    print('safe-answer')
elif mode == 'kill':
    import signal
    os.kill(os.getpid(),signal.SIGKILL)
else:
    print('safe-answer')
PY
chmod +x "$CMD/output"
# One shared boundary owns slash/Home secrecy and disclosure. Discarded
# secrets are never claimed checked: even benign oversized success refuses.
output_rows() {
  local mode cause text
  relay "$ALPHA" "SLACK_STATUS_COMMAND=$CMD/output" "SLACK_HOME_COMMAND=$CMD/output"
  while read -r mode cause; do
    printf '%s\n' "$mode" > "$CMD/output.mode"
    text="$(reply "$(slash /lanes U001)")"
    home_open U001
    reply "$(slash /deploy U001)" >/dev/null
    text="$text|$(last_view)"
    if [ "$cause" = success ]; then
      assert_has "$text" safe-answer "$mode: complete safe stdout reaches slash and Home"
    else
      assert_has "$text" "($cause)" "$mode: the shared result owner keeps the observed cause"
      assert_lacks "$text" prefix-sentinel "$mode: no retained prefix reaches slash or Home"
    fi
    case "$mode" in
      oversize|boundary-secret|discard-secret|nonzero|stderr)
        assert_has "$text" 'output cut at 52096 bytes' "$mode: the visible result discloses the capture cut" ;;
    esac
    assert_lacks "$text" local-only "$mode: stderr is never delivered to Slack"
    if [ "$mode" = kill ]; then
      assert_lacks "$text" OOM 'SIGKILL has no invented OOM attribution'
      assert_lacks "$text" 'memory limit' 'SIGKILL has no invented configured-limit attribution'
    fi
  done <<'ROWS'
clean success
split-secret secret-value
boundary-secret secret-check-incomplete
discard-secret secret-check-incomplete
oversize secret-check-incomplete
stderr success
nonzero exit-3
kill exit--9
clean success
ROWS
  sk_relay_stop
}
output_rows
assert_has "$(cat "$SK_TMP/relay.err")" local-only 'retained command stderr keeps its local destination'
# Real I/O failure and a missing Linux interface are distinct. These copies
# alter only the interface path, never add a production fault-injection API.
if [ "$SCORE_WANT" = 1000 ]; then
  for score_path in "$SK_TMP/absent-score" /dev/full /dev/null /dev/full/not-directory; do
    sk_mutant score-path mailbox.py '/proc/self/oom_score_adj' "$score_path"
    : > "$CMD/status.runs"
    relay "$ALPHA" "SLACK_STATUS_COMMAND=$CMD/status"
    SCORE_RESULT="$(reply "$(slash /lanes U001)")"
    assert_has "$(reply "$(slash /deploy U001)")" '/deploy' 'the worker keeps answering after a scoring result'
    sk_relay_stop
    if [ "$score_path" = "$SK_TMP/absent-score" ]; then
      assert_eq "$(runs)" 1 'absent scoring interface keeps command support'
      assert_has "$(cat "$SK_TMP/relay.err")" 'command-score-unavailable=' 'absence is disclosed, never reported applied'
    else
      assert_eq "$(runs)" 0 'a real scoring I/O failure never executes the target'
      assert_has "$SCORE_RESULT" '(start)' 'a real scoring failure is a command start failure'
      assert_has "$(cat "$SK_TMP/relay.err")" 'errno=' 'scoring failures retain their operation and errno'
    fi
    sk_bin_reset
  done
  sk_mutant score-error-fallback mailbox.py '/proc/self/oom_score_adj' '/dev/full/not-directory'
  python3 - "${SK_BIN%/*}/lib/mailbox.py" <<'PY'
import pathlib,sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
assert s.count('if error.errno != errno.ENOENT:') == 1
p.write_text(s.replace('if error.errno != errno.ENOENT:', 'if False:'))
PY
  : > "$CMD/status.runs"
  relay "$ALPHA" "SLACK_STATUS_COMMAND=$CMD/status"
  reply "$(slash /lanes U001)" >/dev/null
  sk_relay_stop
  assert_eq "$(runs)" 1 'score-error control actually starts the target'
  sk_assert_red "$(runs)" 0 'control: treating a real score error as absence fails the same no-target assertion'
  sk_bin_reset
fi
sk_mutant not-linux mailbox.py 'sys.platform.startswith\("linux"\)' 'False'
relay "$ALPHA" "SLACK_STATUS_COMMAND=$CMD/status"
assert_has "$(reply "$(slash /lanes U001)")" status-fixture 'non-Linux scoring skip preserves command support'
sk_relay_stop
sk_bin_reset

# --- controls ----------------------------------------------------------------------
# Inject a dependency failure at each count observation. Forward every other
# read to the real tool so this exercises runs() and the existing mailbox reader.
while read -r observation reader fail_at; do
  READ_CALLS="$SK_TMP/count-$observation"
  printf '0\n' > "$READ_CALLS" || exit $?
  read_rc=0
  (
    failed_read() {
      local calls
      read -r calls < "$READ_CALLS" || return $?
      calls=$((calls + 1))
      printf '%s\n' "$calls" > "$READ_CALLS" || return $?
      [ "$calls" -ne "$fail_at" ] || return 7
      command "$@"
    }
    case "$reader" in
      mailbox) jq() {
        if [ "$1" = -s ]; then failed_read jq "$@"; else command jq "$@"; fi
      } ;;
      runs) wc() { failed_read wc "$@"; } ;;
    esac
    result=0
    status_commands || result=$?
    sk_relay_stop
    exit "$result"
  ) > "$SK_TMP/$observation.out" 2> "$SK_TMP/$observation.err" || read_rc=$?
  assert_eq "$read_rc" 7 "$observation: failed required count evidence preserves its dependency status"
done <<'ROWS'
alpha-before mailbox 1
beta-before mailbox 2
alpha-after mailbox 3
beta-after mailbox 4
run-before runs 1
run-after runs 2
ROWS
sk_mutant status-dispatch relay.py 'COMMANDS\["/status"\] = COMMANDS\["/lanes"\]' 'COMMANDS["/status"] = COMMANDS.pop("/lanes")'
status_commands || exit $?
sk_assert_red "$STATUS_RESULT" "$STATUS_EXPECTED" "control: the previous dispatch without /lanes fails the configured status scenario"
sk_mutant status-warning relay.py 'name == "/status" and not self.status_renamed' 'name == "/status"'
status_commands || exit $?
sk_assert_red "$STATUS_WARNINGS" "/status|/lanes|2.0.0" "control: repeated retired-command warnings fail the one-warning contract"
sk_mutant owner-gate relay.py 'self\.owner_set = set\(resolve_owner_ids\(self\.api, self\.settings\.owners\)\.values\(\)\)' \
  'self.owner_set = set().union(*(set(r.binding.owner_ids.values()) for r in self.roots))'
relay "$ALPHA" "${CONFIGURED[@]}"
sk_assert_red "$(stale_gate)" "$NOT_OWNER_REPLY" "control: an owner gate read from the roots' bindings admits the stale id"
sk_relay_stop
sk_mutant fixed-root relay.py 'LaneMail\(root\)\.directive' 'LaneMail(self.paths[0]).directive'
second_report
sk_assert_red "$RESULT" "0|1" "control: a destination taken from the first root lands in alpha"
sk_mutant resend relay.py 'f"\{COMMAND_KEY\}\{trigger\}"' 'f"{COMMAND_KEY}{trigger}:{time.time()}"'
report_trip
sk_assert_red "$RESULT" "1|1" "control: a delivery id that changes on a resend lands twice"
sk_mutant report-skip relay.py 'reference\.get\("thread_ts"\) or delivery_id\.startswith\(COMMAND_KEY\)' 'reference.get("thread_ts")'
report_trip
sk_assert_red "$RESULT" "1|1" "control: the notice answering a /report, skipped as another medium's reply, posts nothing"
sk_mutant report-notice relay.py 'elif reply:\n                route = "reply"' 'elif reply:\n                route = "notice" if delivery_id.startswith(COMMAND_KEY) else "reply"'
held_report
sk_assert_red "$RESULT" "jarvis|1|" "control: a notice naming the /report directive, routed as a notice, stays held"
sk_mutant term-stderr mailbox.py 'capture\[kind\]\.add\(chunk\)' 'capture[kind].add(chunk) if not timed_out else None'
timed_out
sk_assert_red "$RESULT" "$TIMED_OUT" "control: the stderr read after TERM dropped, the relay's stderr lacks the command's TERM line"
sk_mutant home-unchecked relay.py 'secret_check\(out\.encode\(\), f"command=\{setting\}", complete=not result.stdout_cut\)' 'None'
withheld
sk_assert_red "${VIEWS[2]}" "$HOME_SECRET" "control: a Home command's output sent unchecked publishes the secret"
sk_mutant incomplete-check secret.py 'if not complete:' 'if False:'
printf '%s\n' oversize > "$CMD/output.mode"
relay "$ALPHA" "SLACK_STATUS_COMMAND=$CMD/output" "SLACK_HOME_COMMAND=$CMD/output"
CUT_CONTROL="$(reply "$(slash /lanes U001)")"
home_open U001
reply "$(slash /deploy U001)" >/dev/null
CUT_CONTROL="$CUT_CONTROL|$(last_view)"
sk_relay_stop
CONTROL_FAIL="$SK_FAIL"
CONTROL_RC=0
CONTROL_OUT="$(assert_lacks "$CUT_CONTROL" prefix-sentinel 'oversize: no retained prefix reaches slash or Home'; [ "$SK_FAIL" = "$CONTROL_FAIL" ])" || CONTROL_RC=$?
assert_eq "$CONTROL_RC" 1 'control: skipping incomplete checking fails the same withheld-prefix assertion'
sk_mutant start-raise relay.py '        except CommandSetupError as exc:[\s\S]*?        finally:' '        finally:'
withheld
sk_assert_red "$MISSING" "$MISSING_REPLY" "control: a command that cannot start, raised out of the worker, stops the relay"
sk_mutant home-raise relay.py 'self\.home_disabled\("slack"\)\n                return' 'self.home_disabled("slack")\n                raise'
home_refused
sk_assert_red "$RESULT" "1|0|After Home off" "control: not_enabled raised out of the worker stops the relay"
sk_relay_stop
sk_bin_reset

sk_summary
