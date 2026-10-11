#!/usr/bin/env bash
# `slack post`: a message to the bound channel or --channel sent as
# standard Markdown, the owner mention and its drop under a fresh
# SLACK_JARVIS_SESSION_FILE, a thread reply, an edit, a file with
# its comment, and the refusals for a secret value in the text or the file,
# a text past Slack's Markdown cap, an unreadable file and flag misuse. The
# controls plant one mutant per rule: the text check gone, so a token posts;
# the file check gone, so a token uploads; the body sent as `text`, which
# Slack renders as mrkdwn; the length check gone, so a text past the cap
# reaches Slack, which refuses it; the hold check gone, a held post mentions.
set -uo pipefail
. "$(dirname "$0")/lib/harness.sh"

sk_fake_start
echo "=== slack post ==="

ROOT="$(sk_new_root alpha)"
sk_bind "$ROOT"
last() { sk_state ".messages.$1[-1] | [(.thread_ts // \"top\"), .user, .text] | join(\" | \")"; } # CHANNEL
arg_of() { sk_state ".messages.$1[] | select(.ts == \"$2\") | .body_arg"; } # CHANNEL TS — the argument the body came in
LONG="$(python3 -c 'print("x" * 12001, end="")')"

sk_run -- post --root "$ROOT" --text 'Lane 3 stalled.'
TS="${OUT#slack: posted=}"; TS="${TS%% *}"
assert_eq "$RC=$OUT" "0=slack: posted=$TS channel=C001" "a post prints the ts it landed as"
assert_eq "$(last C001)" "top | UBOT | Lane 3 stalled." "the text lands top-level in the bound channel"
assert_eq "$(arg_of C001 "$TS")" "markdown_text" "the text is sent as markdown_text, which Slack renders as standard Markdown"

sk_run -- post --root "$ROOT" --text 'Alert.' --channel C777 --mention
assert_eq "$RC=$(last C777)" "0=top | UBOT | <@U001> <@U002> Alert." "--channel posts elsewhere and --mention prefixes every owner"

# held_post NAME AGE: --mention under a Jarvis session file touched AGE seconds ago.
# Prints the post and the count of mention-held lines, the key the overseer reads.
JARVIS_SESSION="$SK_TMP/jarvis-session-live"
held_post() {
  touch -- "$JARVIS_SESSION"; sk_age_file "$JARVIS_SESSION" "$2"
  sk_run "SLACK_JARVIS_SESSION_FILE=$JARVIS_SESSION" -- post --root "$ROOT" --text "Alert $1." --channel C779 --mention
  printf '%s=%s=%s' "$RC" "$(last C779)" "$(printf '%s\n' "$ERR" | grep -c '^slack: mention-held=')"
}
assert_eq "$(held_post held 10)" "0=top | UBOT | Alert held.=1" "--mention under a fresh Jarvis session file posts with no mention and says mention-held"
assert_eq "$(held_post stale 900)" "0=top | UBOT | <@U001> <@U002> Alert stale.=0" "--mention under a stale file keeps the mention"
touch -- "$JARVIS_SESSION"
sk_run "SLACK_JARVIS_SESSION_FILE=$JARVIS_SESSION" -- post --root "$ROOT" --text 'Plain held.' --channel C779
assert_eq "$RC=$(last C779)=$ERR" "0=top | UBOT | Plain held.=" "a post without --mention is unchanged under a fresh file"

# A completed one-shot relay leaves no OS hold, even with a fresh health record.
sk_poll "$ROOT" "SLACK_JARVIS_SESSION_FILE=$JARVIS_SESSION"
sk_age_file "$JARVIS_SESSION" 900
sk_run "SLACK_JARVIS_SESSION_FILE=$JARVIS_SESSION" -- post --root "$ROOT" --text 'Recorded hold.' --channel C779 --mention
assert_eq "$RC=$(last C779)=$(printf '%s\n' "$ERR" | grep -c '^slack: mention-held=')" "0=top | UBOT | <@U001> <@U002> Recorded hold.=0" \
  "a stopped relay's health record cannot retain a hold"
assert_eq "$(held_post between-polls 10)" "0=top | UBOT | Alert between-polls.=1" \
  "a fresh presence file suppresses mentions before the relay updates its unheld record"

# The same post crosses every OS lock state. The child owns the real lock;
# pipe acknowledgements order acquire and release, and wait confirms exit.
lock_posts() {
  env -i PATH="$PATH" HOME="$SK_TMP/home" LANG=C PYTHONDONTWRITEBYTECODE=1 \
    GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" \
    SLACK_BOT_TOKEN="$SK_TOKEN" SLACK_OWNERS="$OWNERS" SLACK_API_URL="$SK_URL" \
    python3 - "${SK_BIN%/*}/lib" "$SK_BIN" "$ROOT" <<'PY'
import json, os, subprocess, sys, urllib.request
lib, binary, root = sys.argv[1:]
child_code = '''import pathlib, sys
sys.path.insert(0, sys.argv[1])
from store import JARVIS_LOCK, RelayLock
lock = RelayLock(pathlib.Path(sys.argv[2]), JARVIS_LOCK)
for command in sys.stdin:
    if command.strip() == "acquire":
        if lock.handle is None: lock.acquire()
    else: lock.release()
    print("done", flush=True)
'''
child = subprocess.Popen([sys.executable, "-B", "-c", child_code, lib, root],
                         stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
rows = []
def command(value):
    child.stdin.write(value + "\n")
    child.stdin.flush()
    assert child.stdout.readline() == "done\n"
def post():
    result = subprocess.run([binary, "post", "--root", root, "--channel", "C780",
                             "--text", "Lock state.", "--mention"], capture_output=True, text=True, timeout=10)
    assert result.returncode == 0, result.stderr
    state = json.load(urllib.request.urlopen(os.environ["SLACK_API_URL"] + "/_test/state"))
    rows.append([state["messages"]["C780"][-1]["text"].startswith("<@"),
                 sum(line.startswith("slack: mention-held=") for line in result.stderr.splitlines())])
try:
    post()
    command("acquire"); post()
    command("release"); post()
    command("acquire"); post()
    child.kill(); child.wait(timeout=10); post()
    print(json.dumps(rows, separators=(",", ":")))
finally:
    if child.poll() is None:
        child.kill(); child.wait(timeout=10)
PY
}
while read -r name control; do
  case "$control" in
    probe) sk_mutant hold-probe store.py '                    return True\n                raise Refusal\("lock-failed"' '                    return False\n                raise Refusal("lock-failed"' ;;
    file) sk_mutant hold-file store.py '        return False\n$' '        return self.path.exists()\n' ;;
    release) sk_mutant hold-release store.py '        if self.handle is not None:' '        if False and self.handle is not None:' ;;
  esac
  LOCK_ROW="$(lock_posts)"; LOCK_RC=$?
  if [ "$control" = real ]; then
    assert_eq "$LOCK_RC=$LOCK_ROW" '0=[[true,0],[false,1],[true,0],[false,1],[true,0]]' \
      "$name: explicit posts follow acquire, release, reacquire and process exit"
  else
    sk_assert_red "$LOCK_RC=$LOCK_ROW" '0=[[true,0],[false,1],[true,0],[false,1],[true,0]]' \
      "$name: the same post state table fails without OS ownership or release"
  fi
  sk_bin_reset
done <<'ROWS'
lock-states real
probe-control probe
file-control file
release-control release
ROWS

LOCK_FILE="$ROOT/tmp/slack/jarvis-session.lock"
mv "$LOCK_FILE" "$SK_TMP/hold-lock.saved"
mkdir "$LOCK_FILE"
BEFORE="$(sk_state '.messages.C780 | length')"
sk_run -- post --root "$ROOT" --text 'Unreadable lock.' --channel C780 --mention
assert_eq "$RC=${ERR1%%=*}=$(sk_state '.messages.C780 | length')" "2=slack: lock-failed=$BEFORE" \
  "a lock read failure refuses the post before Slack receives a mention"
rmdir "$LOCK_FILE"
mv "$SK_TMP/hold-lock.saved" "$LOCK_FILE"

sk_run -- post --root "$ROOT" --text 'In the thread.' --thread "$TS"
assert_eq "$RC=$(last C001)" "0=$TS | UBOT | In the thread." "--thread replies under the message"
assert_eq "$(sk_state '.messages.C001[-1].reply_broadcast')" "false" "a plain thread post does not broadcast"

sk_run -- post --root "$ROOT" --text 'Lane 3 recovered.' --update "$TS"
assert_eq "$RC=$OUT" "0=slack: updated=$TS channel=C001" "--update edits the message at that ts"
assert_eq "$(sk_state ".messages.C001[] | select(.ts == \"$TS\") | [.text, .body_arg] | join(\" \")")" "Lane 3 recovered. markdown_text" \
  "the edit replaces the text, sent as markdown_text"

printf 'line one\nline two\n' > "$SK_TMP/report.md"
sk_run -- post --root "$ROOT" --text 'The report.' --file "$SK_TMP/report.md"
assert_eq "$RC=$OUT" "0=slack: uploaded=F001 channel=C001" "--file prints the file id"
assert_eq "$(sk_state '.uploads.F001')" "line one
line two" "the file's bytes are uploaded"
assert_eq "$(last C001)" "top | UBOT | The report." "the share carries the text as its comment"

# --- refusals, one row per rule -----------------------------------------------

BEFORE="$(sk_state '.messages.C001 | length')"
sk_run -- post --root "$ROOT" --text 'key xoxb-0123456789-abcdefghij'
assert_eq "$RC=$(sed -n '/^slack: secret-value=/p' <<<"$ERR")" "2=slack: secret-value=text" "text matching the secret-value pattern is refused"
printf 'ghp_%s\n' "abcdefghijklmnopqrstuvwxyz0123456789" > "$SK_TMP/leak.md"
sk_run -- post --root "$ROOT" --text 'clean' --file "$SK_TMP/leak.md"
assert_eq "$RC=$(sed -n '/^slack: secret-value=/p' <<<"$ERR")" "2=slack: secret-value=file=$SK_TMP/leak.md" "a file matching the pattern is refused by path"
assert_eq "$(sk_state '.messages.C001 | length')=$(sk_state '.uploads | length')" "$BEFORE=1" "nothing matching is posted or uploaded"
sk_run -- post --root "$ROOT" --text "$LONG"
assert_eq "$RC=$ERR1" "2=slack: text-too-long=text chars=12001 limit=12000" "a text past the markdown_text cap is refused with its length"
sk_run -- post --root "$ROOT" --text "$LONG" --update "$TS"
assert_eq "$RC=$ERR1" "2=slack: text-too-long=text chars=12001 limit=12000" "an edit past the cap is refused the same way"
assert_eq "$(sk_state '.messages.C001 | length')=$(sk_state ".messages.C001[] | select(.ts == \"$TS\") | .text")" \
  "$BEFORE=Lane 3 recovered." "nothing past the cap is posted or edited"
sk_run -- post --root "$ROOT" --text "${LONG%x}" --channel C778
assert_eq "$RC=$(sk_state '.messages.C778[-1].text | length')" "0=12000" "a text at the cap posts whole"
UPLOADS="$(sk_state '.uploads | length')"
sk_run -- post --root "$ROOT" --text "$LONG" --file "$SK_TMP/report.md"
assert_eq "$RC=${OUT%%=*}=$(sk_state '.uploads | length')" "0=slack: uploaded=$((UPLOADS + 1))" \
  "a text past the cap beside a file uploads as its comment, the cap being markdown_text's alone"
sk_run -- post --root "$ROOT" --text 'x' --file "$SK_TMP/absent.md"
assert_eq "$RC=$ERR1" "2=slack: file-unreadable=$SK_TMP/absent.md" "an unreadable file is refused by path"
sk_run -- post --root "$ROOT"
assert_eq "$RC=${ERR1%%=*}" "2=slack: usage" "post without text or file is a usage refusal"
sk_run -- post --root "$ROOT" --text x --file "$SK_TMP/report.md" --update "$TS"
assert_eq "$RC=${ERR1%%=*}" "2=slack: usage" "--update with --file is a usage refusal"
BARE="$(sk_new_root bare)"
sk_run -- post --root "$BARE" --text x
assert_eq "$RC=$ERR1" "2=slack: root-unbound=$BARE" "an unbound root with no --channel is refused"
sk_run -- post --root "$BARE" --text 'no binding needed' --channel C777
assert_eq "$RC=$(last C777)" "0=top | UBOT | no binding needed" "--channel needs no binding"

# --- controls, one per check ------------------------------------------------------
sk_mutant thread-only verbs.py '\*\*\{body_arg: body\}, thread_ts=thread\)' '**{body_arg: body}, thread_ts=thread, reply_broadcast=True)'
sk_run -- post --root "$ROOT" --text 'In the thread.' --thread "$TS"
assert_eq "$(sk_state '.messages.C001[-1].reply_broadcast')" "true" "control: broadcasting a thread post breaks the thread-only assertion"
sk_bin_reset
sk_mutant secret verbs.py 'secret_check\(body\.encode\(\), "text"\)' 'secret_check(b"", "text")'
sk_run -- post --root "$ROOT" --text 'key xoxb-0123456789-abcdefghij'
assert_eq "$RC" "0" "control: the text check gone, the token posts"
sk_bin_reset

sk_mutant body-arg verbs.py 'channel=channel, \*\*\{body_arg: body\}, thread_ts=thread' 'channel=channel, text=body, thread_ts=thread'
sk_run -- post --root "$ROOT" --text 'Lane 4 stalled.'
MTS="${OUT#slack: posted=}"; MTS="${MTS%% *}"
assert_eq "$RC=$(arg_of C001 "$MTS")" "0=text" "control: the body sent as text, Slack renders mrkdwn"
sk_bin_reset

sk_mutant length verbs.py 'markdown_checked\(body, "text"\)' 'markdown_checked("", "text")'
sk_run -- post --root "$ROOT" --text "$LONG"
assert_eq "$ERR1" "slack: slack-api-failed=chat.postMessage error=msg_blocks_too_long" \
  "control: the length check gone, a text past the cap reaches Slack, which refuses it"
sk_bin_reset

sk_mutant mention-hold verbs.py 'if jarvis_session_held\(' 'if False and jarvis_session_held('
sk_assert_red "$(held_post control 10)" "0=top | UBOT | Alert control.=1" "control: the hold check gone, a held post mentions the owners"
sk_bin_reset

sk_mutant file-bytes secret.py 'check\(data, what\)\n    return data' 'check(b"", what)\n    return data'
sk_run -- post --root "$ROOT" --text 'clean' --file "$SK_TMP/leak.md"
assert_eq "$RC=$(sk_state '[.uploads[] | select(. | contains("ghp_"))] | length')" "0=1" "control: the file check gone, the token uploads"
sk_bin_reset

sk_summary
