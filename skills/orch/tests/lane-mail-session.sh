#!/usr/bin/env bash
# lane-mail send to a lane whose record's host kind declares channel=session,
# a Claude cloud session: a directive goes through `claude -p --cloud SESSION
# --output-format json` under the record's account with the text on stdin, an
# {ok: true} answer is delivery and {ok: false} an archived session, and --re
# and --halt refuse. A record on a mailbox kind keeps the mailbox. The kind's
# line is the real lane-host's; `claude` is a stub.
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
mkdir -p "$BIN"
cat > "$BIN/claude" <<'EOF'
#!/usr/bin/env bash
{ printf 'argv=%s\nconfig=%s\nstdin=' "$*" "${CLAUDE_CONFIG_DIR:-}"; cat; } >> "$STUB_CLAUDE_LOG"
printf '%s\n' "$STUB_CLAUDE_OUT"
EOF
chmod +x "$BIN/claude"

# The overseer's checkout, with the fleet state a launch recorded: CC-1 a
# claude-cloud lane, CC-2 a lane on this host.
CHECKOUT="$TMP_ROOT/checkout"
mkdir -p "$CHECKOUT/tmp"
git -C "$CHECKOUT" init -q
STATE="$TMP_ROOT/state"
mkdir -p "$STATE"
jq -n --arg account "$TMP_ROOT/.eclaude" --arg root "$CHECKOUT" '{issue_id: "oversee", lanes: [
  {item: "CC-1", harness: "claude", host: "claude-cloud", kind: "claude-cloud", account: $account,
   session_id: "session_01CLOUD", mail_root: ($root + "/wt/CC-1"), window: null, status: "running"},
  {item: "CC-2", harness: "claude", host: null, kind: "local", account: $account,
   mail_root: $root, window: "stub:CC-2", status: "running"}]}' > "$STATE/workflow-state-oversee.json"
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

echo "=== a session lane takes no answer, no halt and no archived session ==="
# ROW: label|ENV|ARGS|expected first stderr line
for row in \
  "a halt refuses||--halt|lane-mail: channel-session=--halt" \
  "an answer refuses||--re 1700000000-1-abc|lane-mail: channel-session=--re" \
  "an archived session refuses|STUB_CLAUDE_OUT={\"ok\":false}|--directive|lane-mail: session-archived=session_01CLOUD"; do
  IFS='|' read -r label env opt want <<<"$row"
  envs=()
  [[ -z "$env" ]] || envs=("$env")
  read -r -a opts <<<"$opt"
  lm ${envs[@]+"${envs[@]}"} -- send --item CC-1 "${opts[@]}" --file "$TMP_ROOT/directive" --state-dir "$STATE"
  assert_eq "rc=$RC err=$ERR" "rc=2 err=$want" "$label"
done
assert_eq "called=$(lm -- send --item CC-1 --halt --file "$TMP_ROOT/directive" --state-dir "$STATE"; called)" "called=no" \
  "a refused halt never reaches the session"

echo "=== a lane on a mailbox kind keeps its mailbox ==="
lm -- send --item CC-2 --directive --file "$TMP_ROOT/directive" --state-dir "$STATE"
assert_eq "rc=$RC called=$(called) lines=$(wc -l < "$CHECKOUT/tmp/lane-mail/CC-2/to-lane.jsonl" | tr -d ' ')" "rc=0 called=no lines=1" \
  "a local lane's directive is appended to its mailbox"

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
mutant session-archived 'elif .ok == false then "archived"' 'elif .ok == false then "sent"'
lm STUB_CLAUDE_OUT='{"ok":false}' -- "${DIRECTIVE[@]}"
assert_eq "rc=$RC" "rc=0" "control: an ok false read as delivered"
unset LANE_MAIL_BIN

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
