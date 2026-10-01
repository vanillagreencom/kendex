#!/usr/bin/env bash
# Real outbound edges and launcher sibling discovery with stub trackers.
# Removing either outbound call must change what the fake Slack API receives.
set -uo pipefail
. "$(dirname "$0")/lib/harness.sh"
sk_tracker_fixture
sk_fake_start
ROOT="$(sk_tracker_root linear Team '')"
sk_bind "$ROOT"
sk_poll "$ROOT"
CH="$(sk_channel "$ROOT")"
LINK='[KEN-1](https://linear.app/workspace/issue/KEN-1)'
SLACK_LINK='<https://linear.app/workspace/issue/KEN-1|KEN-1>'

sk_lm "$ROOT" notice --item overseer --to owner --file "$(sk_text notice 'Notice KEN-1')" >/dev/null
sk_poll "$ROOT"
assert_eq "$RC=$(sk_state ".messages.${CH}[-1].text")" "0=Notice $LINK" 'a notice links at the relay edge'
sk_lm "$ROOT" ask --item overseer --to owner --file "$(sk_text ask 'Ask KEN-1?')" --options yes,no --recommend no > "$SK_TMP/ask.out"
ASK="$(sed 's/^id=//' "$SK_TMP/ask.out")"
sk_poll "$ROOT"
assert_has "$(sk_state ".messages.${CH}[-1].text")" "Ask $LINK?" 'an ask links at the relay edge'
sk_lm "$ROOT" resolve --item overseer --id "$ASK" --text "$(sk_text answer 'Answer KEN-1')" >/dev/null
sk_poll "$ROOT"
assert_eq "$RC=$(sk_state ".messages.${CH}[-1].text")" "0=Answered in the chat: Answer $LINK" 'an answer links at the relay edge'
printf 'report body\n' > "$SK_TMP/report.md"
mkdir -p "$ROOT/tmp/progress-reports"
cp "$SK_TMP/report.md" "$ROOT/tmp/progress-reports/report.md"
sk_lm "$ROOT" notice --item overseer --to owner --file "$(sk_text report 'Report KEN-1')" --attach "$ROOT/tmp/progress-reports/report.md" >/dev/null
assert_eq "$?" '0' 'a report notice succeeds before reading its comment'
sk_poll "$ROOT"
assert_eq "$RC=$(sk_state ".messages.${CH}[-1].text")" "0=Report $SLACK_LINK" 'a report comment links as mrkdwn'

sk_run -- post --root "$ROOT" --text 'Post KEN-1'
TS="$(sk_state ".messages.${CH}[-1].ts")"
assert_eq "$RC=$(sk_state ".messages.${CH}[-1].text")" "0=Post $LINK" 'slack post links at its edge'
sk_run -- post --root "$ROOT" --text 'Update KEN-1' --update "$TS"
assert_eq "$RC=$(sk_state ".messages.${CH}[] | select(.ts == \"$TS\") | .text")" "0=Update $LINK" 'slack update links at its edge'
sk_run -- post --root "$ROOT" --text 'File KEN-1' --file "$SK_TMP/report.md"
assert_eq "$RC=$(sk_state ".messages.${CH}[-1].text")" "0=File $SLACK_LINK" 'slack file comment links as mrkdwn'

LONG="$(python3 -c 'print("x " * 5980 + "KEN-1", end="")')"
for edge in post update notice; do
  case "$edge" in
    post) sk_run -- post --root "$ROOT" --text "$LONG" ;;
    update) sk_run -- post --root "$ROOT" --text "$LONG" --update "$TS" ;;
    notice)
      sk_lm "$ROOT" notice --item overseer --to owner --file "$(sk_text long "$LONG")" >/dev/null
      sk_poll "$ROOT"
      ;;
  esac
  if [ "$edge" = update ]; then ROW=".messages.${CH}[] | select(.ts == \"$TS\")"; else ROW=".messages.${CH}[-1]"; fi
  assert_eq "$RC=$(sk_state "$ROW | [.body_arg, (.text | endswith(\"$SLACK_LINK\"))] | join(\" \")")" '0=text true' "$edge selects mrkdwn when links cross the cap"
done

# Metadata read failure never holds a post and emits one keyed notice.
printf '1\n' > "$ROOT/linear.exit"
sk_run -- post --root "$ROOT" --text 'Failed KEN-1'
assert_eq "$RC=$(sk_state ".messages.${CH}[-1].text")" '0=Failed KEN-1' 'failed Linear read still posts unlinked'
assert_has "$OUT" "slack: tracker-links-unavailable=$ROOT" 'failed Linear read prints its keyed notice'
sk_lm "$ROOT" notice --item overseer --to owner --file "$(sk_text failed-notice 'Failed notice KEN-1')" >/dev/null
sk_lm "$ROOT" notice --item overseer --to owner --file "$(sk_text failed-again 'Failed again KEN-1')" >/dev/null
sk_poll "$ROOT"
assert_eq "$RC=$(sk_state ".messages.${CH}[-1].text")=$(printf '%s\n' "$OUT" | grep -c '^slack: tracker-links-unavailable=')" '0=Failed again KEN-1=1' 'failed relay read still posts both notices and notices once'
rm "$ROOT/linear.exit"
# A missing optional skill is the same non-blocking discovery failure.
mv "$SK_LINEAR_STUB/scripts/linear.sh" "$SK_LINEAR_STUB/scripts/moved.sh"
sk_run -- post --root "$ROOT" --text 'Missing KEN-1'
assert_eq "$RC=$(sk_state ".messages.${CH}[-1].text")" '0=Missing KEN-1' 'missing Linear skill still posts unlinked'
assert_has "$OUT" "slack: tracker-links-unavailable=$ROOT" 'missing Linear skill prints its keyed notice'
mv "$SK_LINEAR_STUB/scripts/moved.sh" "$SK_LINEAR_STUB/scripts/linear.sh"

GH="$(sk_tracker_root github '' org/repo)"
sk_run -- post --root "$GH" --channel C777 --text '#2 org/other#3 KEN-1'
assert_eq "$RC=$(sk_state '.messages.C777[-1].text')" '0=[#2](https://github.com/org/repo/issues/2) [org/other#3](https://github.com/org/other/issues/3) KEN-1' 'post selects the GitHub consumer tracker'
NONE="$(sk_tracker_root none '' '')"
sk_run -- post --root "$NONE" --channel C777 --text 'KEN-1 #2'
assert_eq "$RC=$(sk_state '.messages.C777[-1].text')" '0=KEN-1 #2' 'post with no tracker remains unchanged'
assert_lacks "$OUT" 'tracker-links-unavailable=' 'no tracker prints no notice'

# The launcher must not export its own loaded team to every served root.
printf '[env]\nLINEAR_TEAM = "LaunchTeam"\n' > "$SK_TMP/home/kendex.settings.toml"
sk_run -- post --root "$GH" --channel C777 --text '#2'
assert_eq "$RC=$(sk_state '.messages.C777[-1].text')" '0=[#2](https://github.com/org/repo/issues/2)' 'launch checkout team does not replace another root tracker'
sk_mutant launcher ../slack '  unset LINEAR_TEAM' '  export LINEAR_TEAM'
sk_run -- post --root "$GH" --channel C777 --text '#2'
assert_eq "$RC=$(sk_state '.messages.C777[-1].text')" '0=#2' 'control: leaking launch settings selects the wrong tracker'
sk_bin_reset
rm "$SK_TMP/home/kendex.settings.toml"

# A value introduced by linking must reach the secret check, not only the
# author's original words. Linear's workspace slug can contain hyphens.
printf '{"urlKey":"xoxb-0123456789-abcdefghij","keys":["KEN"]}\n' > "$ROOT/linear.json"
BEFORE="$(sk_state ".messages.$CH | length")"
sk_run -- post --root "$ROOT" --text 'KEN-1'
assert_eq "$RC=$ERR1=$(sk_state ".messages.$CH | length")" "2=slack: secret-value=text=$BEFORE" 'post checks secrets after link expansion'
sk_lm "$ROOT" notice --item overseer --to owner --file "$(sk_text link-secret 'KEN-1')" >/dev/null
sk_poll "$ROOT"
assert_eq "$(sk_state ".messages.$CH | length")" "$BEFORE" 'relay checks secrets after link expansion'
printf '{"urlKey":"workspace","keys":["HT","HTIO","KEN"]}\n' > "$ROOT/linear.json"

sk_mutant post verbs.py 'body, body_arg = outbound\(root, body, file_comment=bool\(file\), fallback=False\)' 'body, body_arg = body, "markdown_text"'
sk_run -- post --root "$ROOT" --text 'Post control KEN-1'
assert_eq "$RC=$(sk_state ".messages.${CH}[-1].text")" '0=Post control KEN-1' 'control: removing post linking reaches Slack bare'
sk_bin_reset
sk_mutant relay relay.py 'text, body_arg = outbound\(self.path, text, file_comment=bool\(attach\)\)' 'text, body_arg = text, "markdown_text"'
sk_lm "$ROOT" notice --item overseer --to owner --file "$(sk_text control 'Relay control KEN-1')" >/dev/null
sk_poll "$ROOT"
assert_eq "$RC=$(sk_state ".messages.${CH}[-1].text")" '0=Relay control KEN-1' 'control: removing relay linking reaches Slack bare'
sk_bin_reset
sk_summary
