#!/usr/bin/env bash
# lane-mail send to a lane whose record's host kind declares channel=session,
# a Claude cloud session: a directive goes through `claude -p --cloud SESSION
# --output-format json` under the record's account with the text on stdin, an
# {ok: true} answer is delivery, an error naming an archived session refuses as
# session-archived and any other as session-send-failed, and --re and --halt
# refuse. A session record of another repository is lane-foreign, and a send
# naming a fleet state that holds no record for the lane refuses rather than
# fall back to the mailbox. A local mailbox record keeps its mailbox. A hosted
# mailbox record requires --root MAIL_ROOT --host and uses its recorded host.
# The kind's line is the real lane-host's; `claude` and the provider are stubs.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
unset ORCH_LANE_HOST ORCH_STATE_DIR

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
LANE_MAIL="$REPO_ROOT/skills/orch/scripts/lane-mail"
TMP_ROOT="$(mktemp -d)" || { echo "lane-mail-session: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "lane-mail-session: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "lane-mail-session: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
# shellcheck source=lib/growth-state.sh
source "$REPO_ROOT/skills/orch/tests/lib/growth-state.sh"
# shellcheck source=lib/assertions.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/assertions.sh"

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

# The overseer's checkout, with the fleet state a launch recorded: CC-1 a
# claude-cloud lane, CC-2 a lane on this host, CC-3 a claude-cloud lane of
# another repository's checkout, SSH-1 a hosted mailbox lane. OTHER_STATE is
# a fleet that holds CC-2 alone.
CHECKOUT="$TMP_ROOT/checkout"
mkdir -p "$CHECKOUT/tmp" "$CHECKOUT/wt/CC-1"
git -C "$CHECKOUT" init -q
FOREIGN="$TMP_ROOT/foreign"
mkdir -p "$FOREIGN"
git -C "$FOREIGN" init -q
STATE="$TMP_ROOT/state"
OTHER_STATE="$TMP_ROOT/other-state"
mkdir -p "$STATE" "$OTHER_STATE"
jq -n --arg account "$TMP_ROOT/.eclaude" --arg root "$CHECKOUT" --arg foreign "$FOREIGN" \
  --arg host "$HOST_PROVIDER" --arg host_root "$HOST_ROOT" '{issue_id: "oversee", lanes: [
  {item: "CC-1", harness: "claude", host: "claude-cloud", kind: "claude-cloud", account: $account,
   session_id: "session_01CLOUD", mail_root: ($root + "/wt/CC-1"), window: null, status: "running"},
  {item: "CC-2", harness: "claude", host: null, kind: "local", account: $account,
   mail_root: $root, window: "stub:CC-2", status: "running"},
  {item: "CC-3", harness: "claude", host: "claude-cloud", kind: "claude-cloud", account: $account,
   session_id: "session_03CLOUD", mail_root: $foreign, window: null, status: "running"},
  {item: "SSH-1", harness: "claude", host: $host, kind: "ssh", account: $account,
   mail_root: $host_root, window: null, status: "running"}]}' > "$STATE/workflow-state-oversee.json"
jq '.lanes |= map(select(.item == "CC-2"))' "$STATE/workflow-state-oversee.json" > "$OTHER_STATE/workflow-state-oversee.json"
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
DIRECTIVE=(send --item CC-1 --directive --file "$TMP_ROOT/directive" --state-dir "$STATE")

echo "=== a directive reaches a session lane through the Claude CLI ==="
lm -- "${DIRECTIVE[@]}"
assert_eq "rc=$RC out=$OUT" "rc=0 out=lane-mail: sent item=CC-1 channel=session session=session_01CLOUD" \
  "an ok answer is delivery, receipted with the session"
assert_eq "$(paste -sd'|' "$TMP_ROOT/claude.log")" \
  "argv=-p --cloud session_01CLOUD --output-format json|config=$TMP_ROOT/.eclaude|stdin=Rebase on main, then push." \
  "the directive is queued into the record's session under its account, the text on stdin"
assert_eq "mailbox=$([[ -e "$CHECKOUT/wt/CC-1/tmp/lane-mail/CC-1/to-lane.jsonl" || -e "$CHECKOUT/tmp/lane-mail/CC-1/to-lane.jsonl" ]] && echo yes || echo no)" \
  "mailbox=no" "nothing lands in a mailbox for a session lane"

echo "=== what a session send cannot deliver refuses, reaching no session ==="
ARCHIVED='{"ok":false,"error":"Session session_01CLOUD is archived"}'
MISSING='{"ok":false,"error":"Session not found"}'
# LABEL|ENV|ITEM|OPTION|STATE|first stderr line|called, the send a --file and
# the named --state-dir beside the option.
for row in \
  "a halt refuses||CC-1|--halt|$STATE|lane-mail: channel-session=--halt|no" \
  "an answer refuses||CC-1|--re 1700000000-1-abc|$STATE|lane-mail: channel-session=--re|no" \
  "an archived session refuses|STUB_CLAUDE_OUT=$ARCHIVED|CC-1|--directive|$STATE|lane-mail: session-archived=session_01CLOUD|yes" \
  "a session not found is no archived one|STUB_CLAUDE_OUT=$MISSING|CC-1|--directive|$STATE|lane-mail: session-send-failed=session_01CLOUD|yes" \
  "a session lane of another repository is foreign||CC-3|--directive|$STATE|lane-mail: lane-foreign=$FOREIGN|no" \
  "a state holding no record for the lane refuses||CC-1|--directive|$OTHER_STATE|lane-mail: lane-unrecorded=CC-1|no"; do
  IFS='|' read -r label env item opt state want call <<<"$row"
  envs=()
  [[ -z "$env" ]] || envs=("$env")
  read -r -a opts <<<"$opt"
  lm ${envs[@]+"${envs[@]}"} -- send --item "$item" "${opts[@]}" --file "$TMP_ROOT/directive" --state-dir "$state"
  assert_eq "rc=$RC err=$ERR called=$(called)" "rc=2 err=$want called=$call" "$label"
done

echo "=== every session send records its result and the account's credit ==="
# A scripts tree whose lane-mail is a copy, OLD replaced by NEW where given,
# and whose lanes is a stub: it logs ORCH_LANE_DIRS and its argv, prints
# STUB_LANES_OUT and exits STUB_LANES_RC. Its workflow-state exits
# STUB_STATE_UPDATE_RC on an update where that is set. Its path lands in
# LANE_MAIL_BIN.
credit_scripts() { # NAME [OLD NEW]
  local dir
  dir="$(mutant_scripts "$1" lane-mail)" || exit 1
  [[ $# -lt 3 ]] || mutate_file "$dir/lane-mail" "$2" "$3"
  rm -- "${dir:?}/lanes" "${dir:?}/workflow-state"
  cat > "$dir/lanes" <<'EOF'
#!/usr/bin/env bash
printf 'dirs=%s argv=%s\n' "${ORCH_LANE_DIRS:-}" "$*" >> "$STUB_LANES_LOG"
printf '%s\n' "${STUB_LANES_OUT:-[]}"
exit "${STUB_LANES_RC:-0}"
EOF
  cat > "$dir/workflow-state" <<EOF
#!/usr/bin/env bash
[[ -z "\${STUB_STATE_UPDATE_RC:-}" || " \$* " != *" update "* ]] || exit "\$STUB_STATE_UPDATE_RC"
exec "$REPO_ROOT/skills/orch/scripts/workflow-state" "\$@"
EOF
  chmod +x "$dir/lanes" "$dir/workflow-state"
  LANE_MAIL_BIN="$dir/lane-mail"
}
ACCOUNT="$TMP_ROOT/.eclaude"
listing() { # CREDITS-JSON — one lanes list --json record for the account
  jq -cn --arg dir "$ACCOUNT" --argjson c "$1" '[{config_dir: "/other", credits: {remaining_dollars: 99, locked_reason: null}}, {config_dir: $dir, credits: $c}]'
}
# The send's record: the type of its at, its result, its credit, and whether
# its text carries the CLI's words.
send_record() { # CLI-WORDS
  jq -c --arg cli "$1" '.lanes[] | select(.item == "CC-1") | .directive_send
    | if . == null then null else [(.at | type), .result, .credit, (.text | contains($cli))] end' "$STATE/workflow-state-oversee.json"
}
clear_send() {
  jq '.lanes |= map(del(.directive_send))' "$STATE/workflow-state-oversee.json" > "$STATE/next.json"
  mv -- "$STATE/next.json" "$STATE/workflow-state-oversee.json"
}
credit_scripts credit
OPEN_CREDIT='{"remaining_dollars":12.5,"locked_reason":null}'
LOCKED_CREDIT='{"remaining_dollars":0,"locked_reason":"spend_limit"}'
# LABEL|claude answer|lanes listing|lanes exit|send exit|CLI words|recorded result|recorded credit
for row in \
  "a delivered send|{\"ok\":true}|$(listing "$OPEN_CREDIT")|0|0||sent|$OPEN_CREDIT" \
  "an archived session|$ARCHIVED|$(listing "$LOCKED_CREDIT")|0|2|is archived|archived|$LOCKED_CREDIT" \
  "a failed send and a failed credit read|$MISSING|[]|1|2|Session not found|failed|\"unread\"" \
  "a listing with no credit body|{\"ok\":true}|$(listing null)|0|0||sent|\"unread\""; do
  IFS='|' read -r label answer lanes lanes_rc want_rc cli result credit <<<"$row"
  clear_send
  rm -f -- "${TMP_ROOT:?}/lanes.log"
  lm STUB_CLAUDE_OUT="$answer" STUB_LANES_OUT="$lanes" STUB_LANES_RC="$lanes_rc" STUB_LANES_LOG="$TMP_ROOT/lanes.log" -- "${DIRECTIVE[@]}"
  assert_eq "rc=$RC record=$(send_record "$cli")" "rc=$want_rc record=[\"number\",\"$result\",$credit,true]" \
    "$label: the lane record holds the send's result, its words and the credit reading"
  assert_eq "$(cat "$TMP_ROOT/lanes.log")" "dirs=$ACCOUNT argv=list --harness claude --local --json" \
    "$label: the credit is read for the record's account alone"
done
# A record write that fails leaves the send's own outcome standing.
clear_send
lm STUB_STATE_UPDATE_RC=1 STUB_LANES_OUT="$(listing "$OPEN_CREDIT")" STUB_LANES_LOG="$TMP_ROOT/lanes.log" -- "${DIRECTIVE[@]}"
assert_eq "rc=$RC out=$OUT err=$ERR" \
  "rc=0 out=lane-mail: sent item=CC-1 channel=session session=session_01CLOUD err=lane-mail: send-unrecorded=CC-1" \
  "a record that cannot be written is noted and the delivery stands"
clear_send
# shellcheck disable=SC2016  # the script's own text, never expanded here.
credit_scripts credit-unrecorded '  lm_send_record "$answer" "$cause"
' ''
lm STUB_CLAUDE_OUT="$ARCHIVED" STUB_LANES_OUT="$(listing "$LOCKED_CREDIT")" STUB_LANES_LOG="$TMP_ROOT/lanes.log" -- "${DIRECTIVE[@]}"
assert_eq "record=$(send_record "is archived")" "record=null" \
  "control: a send that records nothing fails the record rows"
unset LANE_MAIL_BIN

echo "=== a lane on a mailbox kind keeps its mailbox ==="
lm ORCH_LANE_HOST="$OTHER_HOST_PROVIDER" -- send --item CC-2 --directive --file "$TMP_ROOT/directive" --state-dir "$STATE"
assert_eq "rc=$RC called=$(called) lines=$(wc -l < "$CHECKOUT/tmp/lane-mail/CC-2/to-lane.jsonl" | tr -d ' ')" "rc=0 called=no lines=1" \
  "a local lane's directive is appended to its mailbox"

echo "=== a hosted send uses the recorded destination ==="
# An overseer's answer, directive and halt all reach lm_send_channel. The
# record and the provider's files=verb declaration come from hosted launch.
# open-terminal --host can select a different provider from the sender's.
# LABEL|caller provider|root|host flag|send option|exit|refusal key
for row in \
  "an answer without --host refuses|||0|--re 1700000000-1-abc|2|host-root-required" \
  "a directive without --host refuses|||0|--directive|2|host-root-required" \
  "a halt without --host refuses|||0|--halt|2|host-root-required" \
  "a matching provider delivers|$HOST_PROVIDER|$HOST_ROOT|1|--directive|0|" \
  "a different provider delivers on the recorded host|$OTHER_HOST_PROVIDER|$HOST_ROOT|1|--re 1700000000-1-abc|0|" \
  "a local provider default delivers on the recorded host|local|$HOST_ROOT|1|--halt|0|" \
  "an unset provider delivers on the recorded host||$HOST_ROOT|1|--directive|0|" \
  "a different root refuses|$OTHER_HOST_PROVIDER|/srv/other/SSH-1|1|--directive|2|host-root-mismatch"; do
  IFS='|' read -r label provider root hosted opt want_rc key <<<"$row"
  rm -rf -- "$HOST_DISK" "$OTHER_HOST_DISK" "$CHECKOUT/tmp/lane-mail/SSH-1"
  rm -f -- "$TMP_ROOT/host.log" "$TMP_ROOT/other-host.log"
  read -r -a opts <<<"$opt"
  envs=() destination=()
  [[ -z "$provider" ]] || envs=(ORCH_LANE_HOST="$provider")
  [[ -z "$root" ]] || destination=(--root "$root")
  [[ "$hosted" -eq 0 ]] || destination+=(--host)
  lm ${envs[@]+"${envs[@]}"} -- send --item SSH-1 "${opts[@]}" --file "$TMP_ROOT/directive" \
    --state-dir "$STATE" ${destination[@]+"${destination[@]}"}
  assert_eq "$RC" "$want_rc" "$label"
  if [[ "$want_rc" -eq 0 ]]; then
    assert_eq "${OUT%% item=*}" 'lane-mail: sent' "$label: receipt follows delivery"
    delivered="$(jq -r '[.text, .kind, (.halt // false), (.re // "")] | @tsv' \
      "$HOST_DISK$HOST_ROOT/tmp/lane-mail/SSH-1/to-lane.jsonl" 2>/dev/null)" || delivered=absent
    kind=directive halt=false re=""
    case "$opt" in --re*) kind=answer re=1700000000-1-abc ;; --halt) halt=true ;; esac
    expected="$(printf '%s\t%s\t%s\t%s' 'Rebase on main, then push.' "$kind" "$halt" "$re")"
    assert_eq "$delivered" "$expected" "$label: envelope reaches the recorded mailbox"
  else
    assert_eq "out=$OUT key=${ERR%%=*}" "out= key=lane-mail: $key" "$label: no sent receipt"
    assert_eq "remote=$([[ -e "$HOST_DISK" || -e "$TMP_ROOT/host.log" ]] && echo yes || echo no)" \
      "remote=no" "$label: no mailbox read or append"
  fi
  assert_eq "misdelivered=$([[ -e "$CHECKOUT/tmp/lane-mail/SSH-1" || -e "$OTHER_HOST_DISK" || -e "$TMP_ROOT/other-host.log" ]] && echo yes || echo no)" \
    "misdelivered=no" "$label: the local mailbox and other provider stay unused"
done

echo "=== controls ==="
# mutant OLD NEW — a copy of the scripts with lane-mail's one rule removed.
mutant() {
  local dir
  dir="$(mutant_scripts "$1" lane-mail)" || exit 1
  mutate_file "$dir/lane-mail" "$2" "$3"
  LANE_MAIL_BIN="$dir/lane-mail"
}
mutant session-mailbox '    session) ;;' '    session) return 0 ;;'
lm -- "${DIRECTIVE[@]}"
assert_eq "called=$(called)" "called=no" "control: a session lane served through the mailbox never reaches the session"
# shellcheck disable=SC2016  # the script's own text, never expanded here.
mutant session-halt '[ "$HALT" -eq 0 ] || refuse channel-session --halt' 'true'
lm -- send --item CC-1 --halt --file "$TMP_ROOT/directive" --state-dir "$STATE"
assert_eq "rc=$RC" "rc=0" "control: a halt accepted reaches the session"
# shellcheck disable=SC2016
mutant session-re '[ -z "$MSGID" ] || refuse channel-session --re' 'true'
lm -- send --item CC-1 --re 1700000000-1-abc --file "$TMP_ROOT/directive" --state-dir "$STATE"
assert_eq "rc=$RC" "rc=0" "control: an answer accepted reaches the session"
mutant session-ok 'if .ok == true then "sent"' 'if .ok != null then "sent"'
lm STUB_CLAUDE_OUT="$ARCHIVED" -- "${DIRECTIVE[@]}"
assert_eq "rc=$RC" "rc=0" "control: an ok false read as delivered"
mutant session-archived 'elif (.error // "" | tostring | test("archived"; "i")) then "archived"' 'elif .ok == false then "archived"'
lm STUB_CLAUDE_OUT="$MISSING" -- "${DIRECTIVE[@]}"
assert_eq "err=$ERR" "err=lane-mail: session-archived=session_01CLOUD" "control: every ok false read as archived fails the not-found row"
# shellcheck disable=SC2016
mutant session-foreign '  lm_root_own "$root"' '  :'
lm -- send --item CC-3 --directive --file "$TMP_ROOT/directive" --state-dir "$STATE"
assert_eq "called=$(called)" "called=yes" "control: without the root check another repository's session is reached"
# shellcheck disable=SC2016
mutant session-unrecorded '[ -z "$STATE_DIR" ] || refuse lane-unrecorded' 'true || refuse lane-unrecorded'
printf 'Rebase again.\n' > "$TMP_ROOT/directive-2"
lm -- send --item CC-1 --directive --file "$TMP_ROOT/directive-2" --state-dir "$OTHER_STATE"
assert_eq "rc=$RC called=$(called)" "rc=0 called=no" "control: without the record check the send falls back to a mailbox"
# shellcheck disable=SC2016
mutant hosted-mailbox 'if [ "$files" != local ]; then' 'if false && [ "$files" != local ]; then'
lm -- send --item SSH-1 --directive --file "$TMP_ROOT/directive" --state-dir "$STATE"
assert_eq "rc=$RC lines=$(wc -l < "$CHECKOUT/tmp/lane-mail/SSH-1/to-lane.jsonl" | tr -d ' ')" \
  "rc=0 lines=1" "control: without the host check a send reports delivery to the local mailbox"
# shellcheck disable=SC2016
mutant hosted-provider 'export ORCH_LANE_HOST="$host"' ': # export ORCH_LANE_HOST="$host"'
lm ORCH_LANE_HOST="$OTHER_HOST_PROVIDER" -- send --item SSH-1 --directive --file "$TMP_ROOT/directive" \
  --state-dir "$STATE" --root "$HOST_ROOT" --host
assert_eq "rc=$RC lines=$(wc -l < "$OTHER_HOST_DISK$HOST_ROOT/tmp/lane-mail/SSH-1/to-lane.jsonl" | tr -d ' ')" \
  "rc=0 lines=1" "control: without provider binding a sent receipt names delivery on the other host"
# shellcheck disable=SC2016
mutant hosted-root '[ "$ROOT" = "$root" ] || refuse host-root-mismatch "$ROOT" "mail_root=$root"' \
  'true || [ "$ROOT" = "$root" ] || refuse host-root-mismatch "$ROOT" "mail_root=$root"'
lm -- send --item SSH-1 --directive --file "$TMP_ROOT/directive" \
  --state-dir "$STATE" --root /srv/other/SSH-1 --host
assert_eq "rc=$RC lines=$(wc -l < "$HOST_DISK/srv/other/SSH-1/tmp/lane-mail/SSH-1/to-lane.jsonl" | tr -d ' ')" \
  "rc=0 lines=1" "control: without the root check a sent receipt names delivery to the other mailbox"
unset LANE_MAIL_BIN

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
