#!/usr/bin/env bash
# lane-mail send to a lane by the route its caller names, reading no record:
# a session route (--session --account --root), a Claude cloud session, takes
# a directive through `claude -p --cloud SESSION --output-format json` under
# the route's account with the text on stdin, an {ok: true} answer is
# delivery, an error naming an archived session refuses as session-archived
# and any other as session-send-failed, and --re, --halt and --host refuse. A
# session route of another repository is lane-foreign. A send naming no route
# keeps the local mailbox. A hosted send (--root MAIL_ROOT --host) goes to the
# provider the caller's ORCH_LANE_HOST names, and refuses where it names none
# rather than reach the provider the checkout's settings name.
# The credit is the built runtime's and the provider call the built
# orch-runtime's; `claude` and the provider are stubs, and `curl` the
# runtime's usage fixture.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
# shellcheck source=../../orch/tests/lib/git-env.sh
source "$REPO_ROOT/skills/orch/tests/lib/git-env.sh"
unset ORCH_LANE_HOST ORCH_STATE_DIR

LANE_MAIL="$REPO_ROOT/skills/mailbox/scripts/lane-mail"
TMP_ROOT="$(mktemp -d)" || { echo "lane-mail-session: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "lane-mail-session: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "lane-mail-session: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
# shellcheck source=../../orch/tests/lib/growth-state.sh
source "$REPO_ROOT/skills/orch/tests/lib/growth-state.sh"
# shellcheck source=../../orch/tests/lib/assertions.sh
source "$REPO_ROOT/skills/orch/tests/lib/assertions.sh"

# The claude stub logs its argv, its CLAUDE_CONFIG_DIR and its stdin, and
# prints STUB_CLAUDE_OUT.
BIN="$TMP_ROOT/bin"
HOST_PROVIDER="$REPO_ROOT/skills/orch/tests/fixtures/lane-host"
HOST_ROOT=/srv/lane/SSH-1
HOST_DISK="$TMP_ROOT/host-disk"
OTHER_HOST_PROVIDER="$BIN/other-host"
OTHER_HOST_DISK="$TMP_ROOT/other-host-disk"
mkdir -p "$BIN"
cat > "$OTHER_HOST_PROVIDER" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
export LANE_HOST_STUB_DIR="$LANE_HOST_OTHER_DISK" LANE_HOST_STUB_LOG="$LANE_HOST_OTHER_LOG"
exec "$LANE_HOST_RECORDED_PROVIDER" "$@"
EOF
chmod +x "$OTHER_HOST_PROVIDER"
cat > "$BIN/claude" <<'EOF'
#!/usr/bin/env bash
{ printf 'argv=%s\nconfig=%s\nstdin=' "$*" "${CLAUDE_CONFIG_DIR:-}"; cat; } >> "$STUB_CLAUDE_LOG"
printf '%s\n' "$STUB_CLAUDE_OUT"
EOF
chmod +x "$BIN/claude"

# The overseer's checkout, whose settings name the other provider: a hosted
# send that took the settings' provider would land there. CC-1's root is a
# directory inside the checkout, as a cloud lane's worktree path is; FOREIGN
# is another repository's checkout.
CHECKOUT="$TMP_ROOT/checkout"
mkdir -p "$CHECKOUT/tmp" "$CHECKOUT/wt/CC-1"
git -C "$CHECKOUT" init -q
printf '[env]\nORCH_LANE_HOST = "%s"\n' "$OTHER_HOST_PROVIDER" > "$CHECKOUT/kendex.settings.toml"
FOREIGN="$TMP_ROOT/foreign"
mkdir -p "$FOREIGN"
git -C "$FOREIGN" init -q
printf 'Rebase on main, then push.\n' > "$TMP_ROOT/directive"

RC=0
OUT=""
ERR=""
lm() { # [ENV=VALUE...] -- ARGS...
  local env_args=()
  while [[ "$1" != -- ]]; do env_args+=("$1"); shift; done
  shift
  rm -f -- "$TMP_ROOT/claude.log"
  RC=0
  OUT="$(cd "$CHECKOUT" && env PATH="$BIN:$PATH" STUB_CLAUDE_LOG="$TMP_ROOT/claude.log" \
    LANE_HOST_STUB_LOG="$TMP_ROOT/host.log" LANE_HOST_STUB_DIR="$HOST_DISK" \
    LANE_HOST_OTHER_DISK="$OTHER_HOST_DISK" LANE_HOST_OTHER_LOG="$TMP_ROOT/other-host.log" \
    LANE_HOST_RECORDED_PROVIDER="$HOST_PROVIDER" \
    STUB_CLAUDE_OUT='{"ok":true,"session_id":"session_01CLOUD","url":"https://claude.ai/code/session_01CLOUD"}' \
    ${env_args[@]+"${env_args[@]}"} "${LANE_MAIL_BIN:-$LANE_MAIL}" "$@" 2>"$TMP_ROOT/err")" || RC=$?
  ERR="$(head -n 1 "$TMP_ROOT/err")"
}
called() { [[ -f "$TMP_ROOT/claude.log" ]] && echo yes || echo no; }
ROUTE=(--session session_01CLOUD --account "$TMP_ROOT/.eclaude" --root "$CHECKOUT/wt/CC-1")
DIRECTIVE=(send --item CC-1 --directive --file "$TMP_ROOT/directive" "${ROUTE[@]}")

echo "=== a directive reaches a session route through the Claude CLI ==="
session_delivered() {
  lm -- "${DIRECTIVE[@]}"
  assert_eq "rc=$RC out=$OUT" "rc=0 out=lane-mail: sent item=CC-1 channel=session session=session_01CLOUD" \
    "a session root inside its checkout delivers and receipts the directive"
  if [[ -f "$TMP_ROOT/claude.log" ]]; then
    assert_eq "$(paste -sd'|' "$TMP_ROOT/claude.log")" \
      "argv=-p --cloud session_01CLOUD --output-format json|config=$TMP_ROOT/.eclaude|stdin=Rebase on main, then push." \
      "the directive is queued into the route's session under its account, the text on stdin"
  else
    assert_eq "$(called)" yes "the session CLI receives the directive"
  fi
  assert_eq "mailbox=$([[ -e "$CHECKOUT/wt/CC-1/tmp/lane-mail/CC-1/to-lane.jsonl" || -e "$CHECKOUT/tmp/lane-mail/CC-1/to-lane.jsonl" ]] && echo yes || echo no)" \
    "mailbox=no" "nothing lands in a mailbox for a session lane"
}
session_delivered

echo "=== what a session send cannot deliver refuses, reaching no session ==="
ARCHIVED='{"ok":false,"error":"Session session_01CLOUD is archived"}'
MISSING='{"ok":false,"error":"Session not found"}'
# LABEL|ENV|OPTIONS|first stderr line|called, each a session send of the
# directive file.
for row in \
  "a halt refuses||--halt ${ROUTE[*]}|lane-mail: channel-session=--halt|no" \
  "an answer refuses||--re 1700000000-1-abc ${ROUTE[*]}|lane-mail: channel-session=--re|no" \
  "a hosted session route refuses||--directive ${ROUTE[*]} --host|lane-mail: option-conflict=--session,--host|no" \
  "an archived session refuses|STUB_CLAUDE_OUT=$ARCHIVED|--directive ${ROUTE[*]}|lane-mail: session-archived=session_01CLOUD|yes" \
  "a session not found is no archived one|STUB_CLAUDE_OUT=$MISSING|--directive ${ROUTE[*]}|lane-mail: session-send-failed=session_01CLOUD|yes" \
  "a session route of another repository is foreign||--directive --session session_03CLOUD --account $TMP_ROOT/.eclaude --root $FOREIGN|lane-mail: lane-foreign=$FOREIGN|no"; do
  IFS='|' read -r label env opt want call <<<"$row"
  envs=()
  [[ -z "$env" ]] || envs=("$env")
  read -r -a opts <<<"$opt"
  lm ${envs[@]+"${envs[@]}"} -- send --item CC-1 "${opts[@]}" --file "$TMP_ROOT/directive"
  assert_eq "rc=$RC err=$ERR called=$(called)" "rc=2 err=$want called=$call" "$label"
done
# A lane record with no account carries an empty field into the route.
lm -- send --item CC-1 --directive --file "$TMP_ROOT/directive" --session session_01CLOUD --account '' --root "$CHECKOUT/wt/CC-1"
assert_eq "rc=$RC err=$ERR called=$(called)" "rc=2 err=lane-mail: session-unrecorded=CC-1 called=no" \
  "a session route naming no account refuses"

echo "=== every session send prints its result and the account's credit ==="
# mutant NAME OLD NEW — a copy of the scripts with lane-mail's OLD replaced
# by NEW, its path in LANE_MAIL_BIN.
mutant() {
  local dir
  dir="$(mutant_scripts "$1" lane-mail)" || exit 1
  # The credit is read through agent-runtime's entry beside the mailbox.
  [[ -e "$dir/../../agent-runtime" ]] || ln -s "$REPO_ROOT/skills/agent-runtime" "$dir/../../agent-runtime"
  mutate_file "$dir/lane-mail" "$2" "$3"
  LANE_MAIL_BIN="$dir/lane-mail"
}
# The credit is the built runtime's roster reading the route's account: its
# usage endpoint is the runtime's measured `curl` fixture, answering from
# USAGE_FIXTURE_DIR by the token the account's credentials hold, and logging
# each request there. The caller's own AGENT_RUNTIME_ACCOUNT_DIRS names another account,
# whose token has no answer, so a read not narrowed to the route's account
# shows in that log.
ACCOUNT="$TMP_ROOT/.eclaude"
OTHER_ACCOUNT="$TMP_ROOT/.oclaude"
USAGE="$TMP_ROOT/usage"
mkdir -p "$ACCOUNT" "$OTHER_ACCOUNT" "$USAGE" "$TMP_ROOT/claims"
ln -s "$REPO_ROOT/skills/agent-runtime/tests/rust/fixtures/usage-curl/curl" "$BIN/curl"
EXPIRES=$((($(date +%s) + 3600) * 1000))
for token in eclaude oclaude; do
  jq -cn --arg token "token-$token" --argjson expires "$EXPIRES" \
    '{claudeAiOauth: {accessToken: $token, refreshToken: "refresh", expiresAt: $expires, subscriptionType: "max"}}'
done > "$TMP_ROOT/credentials.jsonl"
sed -n 1p "$TMP_ROOT/credentials.jsonl" > "$ACCOUNT/.credentials.json"
sed -n 2p "$TMP_ROOT/credentials.jsonl" > "$OTHER_ACCOUNT/.credentials.json"
# usage_answer CREDIT — the account's usage body with CREDIT as its extra
# usage, `none` for a body with no credit, `unread` for no answer at all.
usage_answer() {
  rm -f -- "$USAGE/token-eclaude.usage.json" "$USAGE/curl.log"
  [[ "$1" != unread ]] || return 0
  jq -n --arg credit "$1" '{seven_day: {utilization: 10, resets_at: "2099-08-01T06:00:00Z"}}
    + if $credit == "none" then {} else {iguana_necktie: ({limit_dollars: 50, used_dollars: 20,
        resets_at: "2099-08-01T06:00:00Z"} + ($credit | fromjson))} end' > "$USAGE/token-eclaude.usage.json"
}
CREDIT_ENV=(AGENT_RUNTIME_ACCOUNT_DIRS="$OTHER_ACCOUNT" USAGE_FIXTURE_DIR="$USAGE" OVERSEE_WATCH_STATE_DIR="$TMP_ROOT/claims"
  AGENT_RUNTIME_ACCOUNT_STATE_DIR="$TMP_ROOT/claims" AGENT_RUNTIME_USAGE_TTL=0 AGENT_RUNTIME_USAGE_MAX_AGE=0)
# The send's receipt, the keyed line it prints on stderr whatever its
# outcome for orch's `send` verb: its result, its credit, and whether its
# text carries the CLI's words; `none` where no line was printed.
receipt() { # CLI-WORDS
  local record
  record="$(sed -n 's/^lane-mail: directive-send item=CC-1 record=//p' "$TMP_ROOT/err")"
  [[ -n "$record" ]] || { printf 'none'; return 0; }
  jq -c --arg cli "$1" '[.result, .credit, (.text | contains($cli))]' <<<"$record"
}
OPEN_CREDIT='{"remaining_dollars":12.5,"locked_reason":null}'
LOCKED_CREDIT='{"remaining_dollars":0,"locked_reason":"spend_limit"}'
# LABEL|claude answer|usage answer|send exit|CLI words|result|credit
for row in \
  "a delivered send|{\"ok\":true}|$OPEN_CREDIT|0||sent|$OPEN_CREDIT" \
  "an archived session|$ARCHIVED|$LOCKED_CREDIT|2|is archived|archived|$LOCKED_CREDIT" \
  "a failed send and a failed credit read|$MISSING|unread|2|Session not found|failed|\"unread\"" \
  "a usage answer with no credit body|{\"ok\":true}|none|0||sent|\"unread\""; do
  IFS='|' read -r label answer usage want_rc cli result credit <<<"$row"
  usage_answer "$usage"
  lm STUB_CLAUDE_OUT="$answer" "${CREDIT_ENV[@]}" -- "${DIRECTIVE[@]}"
  assert_eq "rc=$RC receipt=$(receipt "$cli")" \
    "rc=$want_rc receipt=[\"$result\",$credit,true]" \
    "$label: the receipt holds the send's result, its words and the credit reading"
  assert_eq "$(sort -u "$USAGE/curl.log")" "usage token-eclaude" \
    "$label: the credit is read for the route's account alone"
done
# The receipt is a stderr line; stdout keeps the `sent` receipt alone.
assert_eq "stdout=$(grep -c '^lane-mail: directive-send' <<<"$OUT") err=$(sed -n '$p' "$TMP_ROOT/err" | cut -d' ' -f1-3)" 'stdout=0 err=lane-mail: directive-send item=CC-1' 'the record is on stderr, after the refusal where there is one, never on stdout'
# shellcheck disable=SC2016  # the script's own text, never expanded here.
mutant credit-unrecorded '  lm_send_record "$answer" "$cause"
' ''
usage_answer "$LOCKED_CREDIT"
lm STUB_CLAUDE_OUT="$ARCHIVED" "${CREDIT_ENV[@]}" -- "${DIRECTIVE[@]}"
assert_eq "receipt=$(receipt "is archived")" "receipt=none" \
  "control: a send that prints no receipt fails the receipt rows"
# shellcheck disable=SC2016
mutant credit-any-account 'AGENT_RUNTIME_ACCOUNT_DIRS="$account" "$AGENT_RUNTIME_SCRIPTS/agent-runtime"' '"$AGENT_RUNTIME_SCRIPTS/agent-runtime"'
usage_answer "$OPEN_CREDIT"
lm "${CREDIT_ENV[@]}" -- "${DIRECTIVE[@]}"
assert_eq "receipt=$(receipt "") log=$(sort -u "$USAGE/curl.log" | paste -sd, -)" \
  'receipt=["sent","unread",true] log=usage token-oclaude' \
  "control: a read not narrowed to the route's account reads the caller's accounts"
unset LANE_MAIL_BIN

echo "=== a send naming no route keeps the local mailbox ==="
lm ORCH_LANE_HOST="$OTHER_HOST_PROVIDER" -- send --item CC-2 --directive --file "$TMP_ROOT/directive"
assert_eq "rc=$RC called=$(called) lines=$(wc -l < "$CHECKOUT/tmp/lane-mail/CC-2/to-lane.jsonl" | tr -d ' ')" "rc=0 called=no lines=1" \
  "a local lane's directive is appended to its mailbox"

echo "=== a hosted send goes to the provider its caller names ==="
# LABEL|caller provider|send option|exit|refusal key
for row in \
  "a named provider takes a directive|$HOST_PROVIDER|--directive|0|" \
  "a named provider takes an answer|$HOST_PROVIDER|--re 1700000000-1-abc|0|" \
  "a named provider takes a halt|$HOST_PROVIDER|--halt|0|" \
  "a hosted send that names no host refuses||--directive|2|host-route-missing"; do
  IFS='|' read -r label provider opt want_rc key <<<"$row"
  rm -rf -- "$HOST_DISK" "$OTHER_HOST_DISK" "$CHECKOUT/tmp/lane-mail/SSH-1"
  rm -f -- "$TMP_ROOT/host.log" "$TMP_ROOT/other-host.log"
  read -r -a opts <<<"$opt"
  envs=()
  [[ -z "$provider" ]] || envs=(ORCH_LANE_HOST="$provider")
  lm ${envs[@]+"${envs[@]}"} -- send --item SSH-1 "${opts[@]}" --file "$TMP_ROOT/directive" --root "$HOST_ROOT" --host
  assert_eq "$RC" "$want_rc" "$label"
  if [[ "$want_rc" -eq 0 ]]; then
    assert_eq "${OUT%% item=*}" 'lane-mail: sent' "$label: receipt follows delivery"
    delivered="$(jq -r '[.text, .kind, (.halt // false), (.re // "")] | @tsv' \
      "$HOST_DISK$HOST_ROOT/tmp/lane-mail/SSH-1/to-lane.jsonl" 2>/dev/null)" || delivered=absent
    kind=directive halt=false re=""
    case "$opt" in --re*) kind=answer re=1700000000-1-abc ;; --halt) halt=true ;; esac
    expected="$(printf '%s\t%s\t%s\t%s' 'Rebase on main, then push.' "$kind" "$halt" "$re")"
    assert_eq "$delivered" "$expected" "$label: envelope reaches the named host's mailbox"
  else
    assert_eq "out=$OUT key=${ERR%%=*}" "out= key=lane-mail: $key" "$label: no sent receipt"
    assert_eq "remote=$([[ -e "$HOST_DISK" || -e "$TMP_ROOT/host.log" ]] && echo yes || echo no)" \
      "remote=no" "$label: no mailbox read or append"
  fi
  assert_eq "misdelivered=$([[ -e "$CHECKOUT/tmp/lane-mail/SSH-1" || -e "$OTHER_HOST_DISK" || -e "$TMP_ROOT/other-host.log" ]] && echo yes || echo no)" \
    "misdelivered=no" "$label: the local mailbox and the settings' provider stay unused"
done

echo "=== controls ==="
mutant session-mailbox '  if [ "$SESSION_GIVEN" -eq 0 ]; then' '  if true; then'
lm -- "${DIRECTIVE[@]}"
assert_eq "called=$(called)" "called=no" "control: a session route served through the mailbox never reaches the session"
# shellcheck disable=SC2016  # the script's own text, never expanded here.
mutant session-halt '[ "$HALT" -eq 0 ] || refuse channel-session --halt' 'true'
lm -- send --item CC-1 --halt --file "$TMP_ROOT/directive" "${ROUTE[@]}"
assert_eq "rc=$RC" "rc=0" "control: a halt accepted reaches the session"
# shellcheck disable=SC2016
mutant session-re '[ -z "$MSGID" ] || refuse channel-session --re' 'true'
lm -- send --item CC-1 --re 1700000000-1-abc --file "$TMP_ROOT/directive" "${ROUTE[@]}"
assert_eq "rc=$RC" "rc=0" "control: an answer accepted reaches the session"
mutant session-ok 'if .ok == true then "sent"' 'if .ok != null then "sent"'
lm STUB_CLAUDE_OUT="$ARCHIVED" -- "${DIRECTIVE[@]}"
assert_eq "rc=$RC" "rc=0" "control: an ok false read as delivered"
mutant session-archived 'elif (.error // "" | tostring | test("archived"; "i")) then "archived"' 'elif .ok == false then "archived"'
lm STUB_CLAUDE_OUT="$MISSING" -- "${DIRECTIVE[@]}"
assert_eq "err=$ERR" "err=lane-mail: session-archived=session_01CLOUD" "control: every ok false read as archived fails the not-found row"
# shellcheck disable=SC2016
mutant session-foreign '  elif [ "$VERB" = send ] || [ "$VERB" = resolve ]; then' '  elif false; then'
lm -- send --item CC-1 --directive --file "$TMP_ROOT/directive" --session session_03CLOUD --account "$TMP_ROOT/.eclaude" --root "$FOREIGN"
assert_eq "called=$(called)" "called=yes" "control: without the root check another repository's session is reached"
# shellcheck disable=SC2016
mutant session-host '[ "$SESSION_GIVEN" -eq 0 ] || [ "$HOST" -eq 0 ] || refuse option-conflict' 'true || refuse option-conflict'
lm -- "${DIRECTIVE[@]}" --host
assert_eq "called=$(called)" "called=yes" "control: a hosted session route accepted reaches the session past every mailbox check"
# shellcheck disable=SC2016
mutant session-checkout '{ [[ "$OPTS_GIVEN" == *"--root$NL"* ]] && [ "$SESSION_GIVEN" -eq 0 ]; }' '[[ "$OPTS_GIVEN" == *"--root$NL"* ]]'
SESSION_ASSERT_RC=0
( FAIL=0; session_delivered; [[ "$FAIL" -eq 0 ]] ) >"$TMP_ROOT/session-root-control.out" || SESSION_ASSERT_RC=$?
assert_eq "$SESSION_ASSERT_RC" 1 "control: requiring a checkout root fails the same session delivery assertions"
# shellcheck disable=SC2016
mutant session-unrecorded '{ [ -n "$account" ] && [ -n "$session" ]; } || refuse session-unrecorded "$ITEM"' 'true'
lm -- send --item CC-1 --directive --file "$TMP_ROOT/directive" --session session_01CLOUD --account '' --root "$CHECKOUT/wt/CC-1"
assert_eq "called=$(called)" "called=yes" "control: without the route check a session send runs with no account"
# shellcheck disable=SC2016
mutant host-route '[ "$HOST" -eq 0 ] || [ -n "${ORCH_LANE_HOST:-}" ] || refuse host-route-missing "$ITEM"' ':'
rm -rf -- "$HOST_DISK" "$OTHER_HOST_DISK"
lm -- send --item SSH-1 --directive --file "$TMP_ROOT/directive" --root "$HOST_ROOT" --host
assert_eq "rc=$RC lines=$(wc -l < "$OTHER_HOST_DISK$HOST_ROOT/tmp/lane-mail/SSH-1/to-lane.jsonl" | tr -d ' ')" \
  "rc=0 lines=1" "control: without the route check a hosted send lands at the settings' provider"
unset LANE_MAIL_BIN

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
