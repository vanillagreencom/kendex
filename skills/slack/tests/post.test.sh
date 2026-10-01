#!/usr/bin/env bash
# `slack post`: a message to the bound channel or --channel sent as
# standard Markdown, the owner mention, a thread reply, an edit, a file with
# its comment, and the refusals for a secret value in the text or the file,
# a text past Slack's Markdown cap, an unreadable file and flag misuse. The
# controls plant one mutant per rule: the text check gone, so a token posts;
# the file check gone, so a token uploads; the body sent as `text`, which
# Slack renders as mrkdwn; the length check gone, so a text past the cap
# reaches Slack, which refuses it.
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
assert_eq "$RC=$ERR1" "2=slack: secret-value=text" "text matching the secret-value pattern is refused"
printf 'ghp_%s\n' "abcdefghijklmnopqrstuvwxyz0123456789" > "$SK_TMP/leak.md"
sk_run -- post --root "$ROOT" --text 'clean' --file "$SK_TMP/leak.md"
assert_eq "$RC=$ERR1" "2=slack: secret-value=file=$SK_TMP/leak.md" "a file matching the pattern is refused by path"
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

sk_mutant file-bytes secret.py 'check\(data, what\)\n    return data' 'check(b"", what)\n    return data'
sk_run -- post --root "$ROOT" --text 'clean' --file "$SK_TMP/leak.md"
assert_eq "$RC=$(sk_state '[.uploads[] | select(. | contains("ghp_"))] | length')" "0=1" "control: the file check gone, the token uploads"
sk_bin_reset

sk_summary
