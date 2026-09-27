#!/usr/bin/env bash
# `slack post`: a message to the bound channel or --channel, the owner
# mention, a thread reply, an edit, a file with its comment, and the refusals
# for a secret value in the text or the file, an unreadable file and flag
# misuse. The control plants a mutant whose text check is gone, so a token
# posts.
set -uo pipefail
. "$(dirname "$0")/lib/harness.sh"

sk_fake_start
echo "=== slack post ==="

ROOT="$(sk_new_root alpha)"
sk_bind "$ROOT"
last() { sk_state ".messages.$1[-1] | [(.thread_ts // \"top\"), .user, .text] | join(\" | \")"; } # CHANNEL

sk_run -- post --root "$ROOT" --text 'Lane 3 stalled.'
TS="${OUT#slack: posted=}"; TS="${TS%% *}"
assert_eq "$RC=$OUT" "0=slack: posted=$TS channel=C001" "a post prints the ts it landed as"
assert_eq "$(last C001)" "top | UBOT | Lane 3 stalled." "the text lands top-level in the bound channel"

sk_run -- post --root "$ROOT" --text 'Alert.' --channel C777 --mention
assert_eq "$RC=$(last C777)" "0=top | UBOT | <@U001> <@U002> Alert." "--channel posts elsewhere and --mention prefixes every owner"

sk_run -- post --root "$ROOT" --text 'In the thread.' --thread "$TS"
assert_eq "$RC=$(last C001)" "0=$TS | UBOT | In the thread." "--thread replies under the message"

sk_run -- post --root "$ROOT" --text 'Lane 3 recovered.' --update "$TS"
assert_eq "$RC=$OUT" "0=slack: updated=$TS channel=C001" "--update edits the message at that ts"
assert_eq "$(sk_state ".messages.C001[] | select(.ts == \"$TS\") | .text")" "Lane 3 recovered." "the edit replaces the text"

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
sk_mutant secret verbs.py 'secret_check\(body\.encode\(\), "text"\)' 'secret_check(b"", "text")'
sk_run -- post --root "$ROOT" --text 'key xoxb-0123456789-abcdefghij'
assert_eq "$RC" "0" "control: the text check gone, the token posts"
sk_bin_reset

sk_mutant file-bytes secret.py 'check\(data, what\)\n    return data' 'check(b"", what)\n    return data'
sk_run -- post --root "$ROOT" --text 'clean' --file "$SK_TMP/leak.md"
assert_eq "$RC=$(sk_state '[.uploads[] | select(. | contains("ghp_"))] | length')" "0=1" "control: the file check gone, the token uploads"
sk_bin_reset

sk_summary
