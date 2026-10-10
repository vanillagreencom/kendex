#!/usr/bin/env bash
# Real outbound edges and launcher sibling discovery with stub trackers.
# Removing either outbound call must change what the fake Slack API receives.
set -uo pipefail
. "$(dirname "$0")/lib/harness.sh"
sk_tracker_fixture
sk_fake_start
ROOT="$(sk_tracker_root linear '' '')"
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

# The notice log consumes this key. A failed workspace read never holds a post.
printf '1\n' > "$ROOT/linear.exit"
sk_run -- post --root "$ROOT" --text 'Failed KEN-1'
assert_eq "$RC=$(sk_state ".messages.${CH}[-1].text")" '0=Failed KEN-1' 'failed Linear read still posts unlinked'
assert_has "$ERR" "slack: tracker-links-unavailable=$ROOT" 'failed Linear read prints its keyed notice on stderr'
assert_eq "$RC=${OUT%%=*}=$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" '0=slack: posted=1' 'a failed tracker read keeps the posted receipt alone on stdout'
sk_lm "$ROOT" notice --item overseer --to owner --file "$(sk_text failed-notice 'Failed notice KEN-1')" >/dev/null
sk_lm "$ROOT" notice --item overseer --to owner --file "$(sk_text failed-again 'Failed again KEN-1')" >/dev/null
sk_poll "$ROOT"
assert_eq "$RC=$(sk_state ".messages.${CH}[-1].text")=$(printf '%s\n' "$ERR" | grep -c '^slack: tracker-links-unavailable=')" '0=Failed again KEN-1=1' 'failed relay read still posts both notices and warns once on stderr'
rm "$ROOT/linear.exit"
# A missing optional skill is the same non-blocking discovery failure.
mv "$SK_LINEAR_STUB/scripts/linear.sh" "$SK_LINEAR_STUB/scripts/moved.sh"
sk_run -- post --root "$ROOT" --text 'Missing KEN-1'
assert_eq "$RC=$(sk_state ".messages.${CH}[-1].text")" '0=Missing KEN-1' 'missing Linear skill still posts unlinked'
assert_has "$ERR" "slack: tracker-links-unavailable=$ROOT" 'missing Linear skill prints its keyed notice on stderr'
mv "$SK_LINEAR_STUB/scripts/moved.sh" "$SK_LINEAR_STUB/scripts/linear.sh"

GH="$(sk_tracker_root github '' org/repo)"
sk_run -- post --root "$GH" --channel C777 --text '#2 org/other#3 KEN-1'
assert_eq "$RC=$(sk_state '.messages.C777[-1].text')" "0=[#2](https://github.com/org/repo/pull/2) [org/other#3](https://github.com/org/other/pull/3) $LINK" 'post with no team links workspace ids and sending repository PRs'
git -C "$GH" -c user.name=Fixture -c user.email=fixture@example.test commit --allow-empty --no-gpg-sign -qm fixture || exit 1
COMMIT="$(git -C "$GH" rev-parse HEAD)" || exit 1
SHORT="${COMMIT:0:7}"
sk_run -- post --root "$GH" --channel C777 --text "repo#2 $SHORT unknown#3"
assert_eq "$RC=$(sk_state '.messages.C777[-1].text')" "0=[repo#2](https://github.com/org/repo/pull/2) [$SHORT](https://github.com/org/repo/commit/$COMMIT) unknown#3" 'post delivers PR and commit links with unresolved text'
assert_eq "$(printf '%s\n' "$ERR" | grep -c '^slack: reference-link-unavailable=unknown#3 ')" '1' 'post reports the unresolved reference on stderr'

# The detector fixture is not an authenticated credential. Its commit suffix
# must stay intact so both callers refuse the original secret-pattern match.
sk_bind "$GH"
sk_poll "$GH"
GH_CH="$(sk_channel "$GH")"
for mode in original control; do
  if [ "$mode" = control ]; then
    sk_mutant pre-expansion markup.py '    preserve = secret_pattern\(\)\.search\([^\n]+\) is not None' '    preserve = False'
  fi
  for edge in post notice; do
    BEFORE="$(sk_state ".messages.$GH_CH | length")"
    case "$edge" in
      post)
        sk_run -- post --root "$GH" --text "xoxb-$COMMIT"
        GOT="$RC=$(sed -n '/^slack: secret-value=/p' <<<"$ERR")=$(sk_state ".messages.$GH_CH | length")"
        WANT="2=slack: secret-value=text=$BEFORE"
        ;;
      notice)
        sk_lm "$GH" notice --item overseer --to owner --file "$(sk_text "commit-secret-$mode" "$mode xoxb-$COMMIT")" > "$SK_TMP/notice.out"
        ID="$(field "$(cat "$SK_TMP/notice.out")" id)"
        sk_poll "$GH"
        STATE="$(jq -r --arg id "$ID" 'select(.t == "out" and .id == $id and .state != "inflight") | [.state, (.reason // "")] | join(" ")' "$(sk_journal "$GH")")"
        GOT="$RC=$(sed -n '/^slack: secret-value=/p' <<<"$ERR")=$STATE=$(sk_state ".messages.$GH_CH | length")"
        WANT="0=slack: secret-value=id=$ID=refused secret-value=$BEFORE"
        ;;
    esac
    if [ "$mode" = original ]; then
      assert_eq "$GOT" "$WANT" "$edge refuses a matching value before commit expansion"
    else
      sk_assert_red "$GOT" "$WANT" "control: $edge refusal fails when expansion hides the match"
    fi
  done
done
sk_bin_reset

NONE="$(sk_tracker_root none '' '')"
printf '1\n' > "$NONE/linear.exit"
sk_run -- post --root "$NONE" --channel C777 --text 'KEN-1 #2'
assert_eq "$RC=$(sk_state '.messages.C777[-1].text')" '0=KEN-1 #2' 'post with no workspace credentials remains unchanged'
assert_has "$ERR" "slack: tracker-links-unavailable=$NONE" 'post with no workspace credentials prints its keyed notice on stderr'

# Restoring the former team gate breaks both outbound edges in an empty-team root.
sk_mutant team-gate markup.py '(            script = Path\(os.environ\["SLACK_LINEAR_DIR"\]\))' '            team = self._read(root, [str(Path(os.environ["SLACK_ORCH_DIR"]) / "scripts/orch-env"), "LINEAR_TEAM", ""])\n            if not team:\n                self.cache[root] = (now, None)\n                return None\n\1'
sk_run -- post --root "$ROOT" --text 'Team control KEN-1'
sk_assert_red "$RC=$(sk_state ".messages.${CH}[-1].text")" "0=Team control $LINK" 'control: the former team gate breaks post links'
sk_lm "$ROOT" notice --item overseer --to owner --file "$(sk_text team-control 'Team control notice KEN-1')" >/dev/null
sk_poll "$ROOT"
sk_assert_red "$RC=$(sk_state ".messages.${CH}[-1].text")" "0=Team control notice $LINK" 'control: the former team gate breaks relay links'
sk_bin_reset
sk_mutant no-notice markup.py '                notice\("tracker-links-unavailable", f"\{root\} cause=\{err\}", file=sys.stderr\)' '                pass'
printf '1\n' > "$ROOT/linear.exit"
sk_lm "$ROOT" notice --item overseer --to owner --file "$(sk_text warning-control-a 'Warning control A KEN-1')" >/dev/null
sk_lm "$ROOT" notice --item overseer --to owner --file "$(sk_text warning-control-b 'Warning control B KEN-1')" >/dev/null
sk_poll "$ROOT"
sk_assert_red "$RC=$(sk_state ".messages.${CH}[-1].text")=$(printf '%s\n' "$ERR" | grep -c '^slack: tracker-links-unavailable=')" '0=Warning control B KEN-1=1' 'control: dropping the notice breaks failure reporting across two sends'
sk_bin_reset
sk_mutant warning-stdout markup.py '(notice\("tracker-links-unavailable", f"\{root\} cause=\{err\}", file=)sys.stderr' '\1sys.stdout'
sk_run -- post --root "$ROOT" --text 'Receipt control KEN-1'
sk_assert_red "$RC=${OUT%%=*}=$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" '0=slack: posted=1' 'control: a tracker warning on stdout breaks the posted receipt'
sk_assert_red "$(printf '%s\n' "$ERR" | grep -c '^slack: tracker-links-unavailable=')" '1' 'control: a tracker warning on stdout loses the stderr notice'
sk_bin_reset
rm "$ROOT/linear.exit"

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
