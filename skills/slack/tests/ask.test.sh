#!/usr/bin/env bash
# An owner ask carrying a draft, through the real relay and lane-mail: the
# posted ask shows the draft's recipient, medium and whole text between the
# question and its options, the text as typed. As standard Markdown the text
# is one fenced block longer than any backtick run in it; past the
# markdown_text cap it is one mrkdwn block with Slack's control characters
# escaped, and a text mrkdwn cannot hold in a block is refused. The question
# keeps its tracker links; the draft is never linked. A reserved ask is posted
# naming no default, and once more in its thread on the first poll past its
# deadline while it stays open and unanswered, never again; one first posted
# past its deadline is its own reminder; one with no thread to post in, its
# post response lost or its thread deleted, is reminded with the whole
# question in a thread a reply in answers. Any other ask is listen.test.sh's. Each rule has its own
# control on a copy of the scripts.
set -uo pipefail
. "$(dirname "$0")/lib/harness.sh"

sk_fake_start
echo "=== slack draft ask ==="

LINK='[KEN-1](https://linear.app/workspace/issue/KEN-1)'
SLACK_LINK='<https://linear.app/workspace/issue/KEN-1|KEN-1>'
PAD="$(python3 -c 'print("y" * 12000, end="")')"
MARKDOWN_DRAFT='Hello,

[Reset password](https://example.invalid) before KEN-123 ships: run ```make```.'
MARKDOWN_WANT="Send this email for $LINK?

Draft to release-list@example.com by email:

\`\`\`\`
$MARKDOWN_DRAFT
\`\`\`\`

Options: approve, deny. Recommended: deny."
MRKDWN_DRAFT="Hello <https://example.invalid|Reset> & KEN-123 \`x\`
$PAD"
MRKDWN_WANT="Send this email for $SLACK_LINK?

Draft to release-list@example.com by email:

\`\`\`
Hello &lt;https://example.invalid|Reset&gt; &amp; KEN-123 \`x\`
$PAD
\`\`\`

Options: approve, deny. Recommended: deny."
FENCED_DRAFT="run \`\`\`make\`\`\`
$PAD"

# draft_ask NAME DRAFT_TEXT — one draft ask posted from a fresh root. Sets ASK
# to its id, POSTED to its body argument and its text between the owner
# mention's header line and the deadline sentence, `<arg>|<text>`, and JOURNALED to its settled journal
# state and reason.
draft_ask() {
  local root draft
  root="$(sk_tracker_root "$1" Team '')"
  sk_bind "$root"
  draft="$(jq -cn --arg text "$2" '{recipient: "release-list@example.com", medium: "email", text: $text, text_hash: "sha256:0f"}')"
  ASK="$(sk_lm "$root" ask --item overseer --to owner --file "$(sk_text "$1" 'Send this email for KEN-1?')" --options approve,deny --recommend deny)"
  ASK="${ASK#id=}"
  sk_event_filter "$root" "if .kind == \"ask\" then .draft = $draft else . end"
  sk_poll "$root"
  POSTED="$(sk_state ".messages.$(sk_channel "$root")[] | select(.text | contains(\"Send this email for\")) | .body_arg + \"|\" + (.text | sub(\"^[^\\n]* Question from overseer:\\n\\n\"; \"\") | sub(\" It stands at [^\\n]* unless you reply in this thread[.]$\"; \"\"))")"
  JOURNALED="$(jq -r "select(.t == \"out\" and .id == \"$ASK\" and .state != \"inflight\") | [.state, .reason // empty] | join(\" \")" "$(sk_journal "$root")")"
}

draft_ask markdown "$MARKDOWN_DRAFT"
assert_eq "$POSTED" "markdown_text|$MARKDOWN_WANT" "under the cap the draft sits in a fence longer than its backtick run, unlinked, between the linked question and the options"

draft_ask mrkdwn "$MRKDWN_DRAFT"
assert_eq "$POSTED" "text|$MRKDWN_WANT" "past the cap the draft sits in one mrkdwn block, its control characters escaped and unlinked"

draft_ask fenced "$FENCED_DRAFT"
assert_eq "$RC=$ERR1" "0=slack: text-not-literal=id=$ASK draft chars=${#FENCED_DRAFT}" "a draft mrkdwn cannot hold in a block is refused by id"
assert_eq "$JOURNALED|$POSTED" "refused text-not-literal|" "the refused draft ask is journaled refused and nothing posts"

sk_mutant draft-block relay.py 'if draft:' 'if draft and False:'
draft_ask control-block "$MARKDOWN_DRAFT"
assert_has "$POSTED" "Send this email for $LINK?" "control probe: the ask still posts"
assert_lacks "$POSTED" "Draft to release-list@example.com by email:" "control: the draft block dropped, the ask shows no draft"

sk_mutant fence markup.py 'fence = "`" \* max\(3, longest \+ 1\)' 'fence = ""'
draft_ask control-fence "$MARKDOWN_DRAFT"
sk_assert_red "$POSTED" "markdown_text|$MARKDOWN_WANT" "control: a draft outside a fence fails the literal assertion"

sk_mutant fence-length markup.py 'max\(3, longest \+ 1\)' '3'
draft_ask control-fence-length "$MARKDOWN_DRAFT"
sk_assert_red "$POSTED" "markdown_text|$MARKDOWN_WANT" "control: a fence its backtick run closes fails the literal assertion"

sk_mutant escape markup.py '\{escape\(self\.text\)\}' '{self.text}'
draft_ask control-escape "$MRKDWN_DRAFT"
sk_assert_red "$POSTED" "text|$MRKDWN_WANT" "control: an unescaped mrkdwn draft fails the literal assertion"

sk_mutant not-literal markup.py 'if "```" in self\.text:' 'if "```" in self.text and False:'
draft_ask control-not-literal "$FENCED_DRAFT"
sk_assert_red "$JOURNALED" "refused text-not-literal" "control: a draft posted past its backtick run fails the refusal assertion"
sk_bin_reset

# The tracker carries the detail. Slack posts one line: the owner mention and
# question frame, the first question line, the issue identifier, which
# outbound markup expands into its link, and the deadline.
tracker_ask() { # NAME FAILURE
  local root scripts phase="${2:-}" at deadline ask_rc=0 notice
  root="$(sk_tracker_root "$1" Team '')"
  sk_bind "$root"
  scripts="$root/.agents/skills/mailbox/scripts"
  rm -- "${scripts:?}"
  cp -R "${SK_LANE_MAIL%/*}" "$scripts"
  mkdir -p "$root/.agents/skills/linear/scripts"
  cat >"$root/.agents/skills/linear/scripts/linear.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "${TRACKER_FAILURE:-}:$1:$2:${4:-}" in
  assign:issues:update:--assignee|labels-read:issues:get:*|label:issues:update:--labels|comment:comments:create:*) exit 1 ;;
esac
case "$1:$2" in
  users:list) echo '[{"id":"87654321-4321-4321-4321-cba987654321","name":"Riley Other","email":"other@example.test"},{"id":"12345678-1234-1234-1234-123456789abc","name":"Maya Owner","email":"owner@example.com","display_name":"maya"}]' ;;
  teams:keys) echo '{"urlKey":"workspace","keys":["KEN"]}' ;;
  issues:get) echo '{"labels":["skills"]}' ;;
  issues:update) echo '{}' ;;
  comments:create) echo '{"success":true,"data":{"success":true,"comment":{"id":"question-id"}}}' ;;
  *) exit 1 ;;
esac
STUB
  chmod +x "$root/.agents/skills/linear/scripts/linear.sh"
  ASK="$(cd "$root" && env ORCH_OWNER_EMAIL=owner@example.com ORCH_OWNER_ASK_LABEL=owner-gated LINEAR_TEAM=KEN \
    TRACKER_FAILURE="$phase" "$scripts/lane-mail" ask --item overseer --to owner \
    --issue KEN-1 --do 'Approve the action. Your reply closes this ask.' --file "$(sk_text "$1" 'Approve action?
Details on the item.')" --options approve,hold --recommend approve --wait 60 2>"$root/tracker.err")" || ask_rc=$?
  assert_eq "$ask_rc" 0 "$1 creates the owner ask"
  case "$ASK" in
    id=?*) ok "$1 returns its owner ask id" ;;
    *) bad "$1 returns its owner ask id" "$ASK"; TRACKER_POST=""; FALLBACK_FACTS=false; return ;;
  esac
  ASK="${ASK#id=}"
  if [ -n "$phase" ]; then
    notice="$(sed -n '1p' "$root/tracker.err")"
    assert_eq "$(field "$notice" issue)|$(field "$notice" cause)" "KEN-1|$phase" \
      "$1 reaches its selected tracker failure"
  fi
  local posted=false
  [ -n "$phase" ] || posted=true
  assert_eq "$(jq -s --arg id "$ASK" 'any(.[]; .kind == "tracker-posted" and .re == $id)' \
    "$(sk_box "$root")/to-overseer.jsonl")" "$posted" "$1 records the intended tracker posting result"
  at="$(jq -r 'select(.kind == "ask") | .deadline' "$(sk_box "$root")/to-overseer.jsonl")"
  deadline="$(jq -rn --arg at "$at" '$at | fromdateiso8601')"
  sk_poll "$root"
  TRACKER_POST="$(sk_state ".messages.$(sk_channel "$root")[] | select(.text | contains(\"Approve action?\")) | .text")"
  # The one line still names the owner, frames the decision and gives its deadline.
  TRACKER_LINE="<@U001> <@U002> Question from overseer: Approve action? $LINK It stands at <!date^$deadline^{date_short_pretty} at {time}|$at> unless you reply in this thread."
  # Slack's API post must carry the supplied question, choices and the date
  # token for the ask's deadline, rather than a guessed wall-clock value.
  FALLBACK_FACTS="$(jq -cn --arg text "$TRACKER_POST" --arg deadline "$deadline" \
    '$text | contains("Details on the item.") and contains("approve, hold") and contains($deadline)')"
}
tracker_ask tracker-line
assert_eq "$TRACKER_POST" "$TRACKER_LINE" \
  'tracker ask posts the owner mention, the question frame, its first line, issue link and deadline'
sk_mutant tracker-line relay.py 'if envelope.get\("tracker_posted"\) is True:' 'if False:'
tracker_ask tracker-line-control
sk_assert_red "$TRACKER_POST" "$TRACKER_LINE" \
  'control: posting the whole ask fails the tracker line assertion'
sk_bin_reset
for failure in assign labels-read label comment; do
  tracker_ask "tracker-fallback-$failure" "$failure"
  assert_eq "$FALLBACK_FACTS" true "$failure keeps the question, options and deadline in the Slack API post"
done
sk_mutant tracker-confirmation relay.py 'if envelope.get\("tracker_posted"\) is True:' 'if envelope.get("issue"):'
tracker_ask tracker-fallback-control comment
sk_assert_red "$FALLBACK_FACTS" true \
  'control: issue presence fails the full chat fallback assertion'
sk_bin_reset

echo "=== slack referenced ask ==="
# A linked ask stays separate from the directive, so its reply answers the ask.
referenced_ask() {
  ROOT="$(sk_tracker_root "$1" Team '')"
  sk_bind "$ROOT"
  CH="$(sk_channel "$ROOT")"
  sk_poll "$ROOT"
  REF_TS="$(sk_inject "$CH" U001 'Earlier conversation.')"
  sk_poll "$ROOT"
  REF="$(jq -r 'select(.kind == "directive") | .id' "$(sk_box "$ROOT")/to-lane.jsonl")"
  ASK="$(sk_lm "$ROOT" ask --item overseer --to owner --ref "$REF" --file "$(sk_text "$1" 'Approve referenced action?')" --options approve,hold --recommend hold)"
  ASK="${ASK#id=}"
  if [ -n "${2:-}" ]; then
    if [ -n "${3:-}" ]; then
      sk_lm "$ROOT" ask --item overseer --to owner --ref "$REF" --file "$(sk_text "$1-other" 'Other referenced action?')" --options approve,hold --recommend hold >/dev/null
    fi
    sk_lm "$ROOT" ask --item overseer --to owner --file "$(sk_text "$1-later" 'Later question?')" --options approve,hold --recommend hold >/dev/null
    sk_lm "$ROOT" notice --item overseer --to owner --file "$(sk_text "$1-notice" 'Later notice.')" >/dev/null
    sk_ctl /_test/fault "$2" >/dev/null
    if [ -n "${3:-}" ]; then sk_ctl /_test/fault "$3" >/dev/null; fi
  fi
  sk_poll "$ROOT"
  ASK_TS="$(sk_state "[.messages.${CH}[] | select(.text | contains(\"Approve referenced action?\")) | .ts][0] // \"\"")"
  POSTED="$(sk_state "[.messages.${CH}[] | select(.ts == \"$ASK_TS\") | .text][0] // \"\"")"
  REF_LINK="https://workspace.slack.test/archives/$CH/p${REF_TS/./}"
}
referenced_ask referenced
assert_eq "$RC" 0 'the fake Slack server supports the permalink request'
assert_has "$POSTED" "$REF_LINK" 'the ask carries the referenced Slack conversation permalink'
assert_eq "$(sk_state "[.messages.${CH}[] | select(.ts == \"$ASK_TS\") | .thread_ts // \"top-level\"][0]")" \
  top-level 'the ask starts its own thread'
sk_inject "$CH" U001 approve "$ASK_TS" >/dev/null
sk_poll "$ROOT"
assert_eq "$(jq -cs --arg id "$ASK" '[.[] | select(.kind == "answer" and .re == $id) | .text]' "$(sk_box "$ROOT")/to-lane.jsonl")" \
  '["approve"]' 'an owner reply in the ask thread answers the ask'

# Slack can refuse a read or post, lose its response, or reject the token.
# A lost post can have landed; a lost read cannot have posted the ask.
while IFS='|' read -r name fault second poll_rc delivered state retried; do
  referenced_ask "referenced-$name" "$fault" "$second"
  assert_eq "$RC|$ASK_TS" "$poll_rc|" "$name leaves the failed ask unposted and reports its poll result"
  assert_eq "$(asks "$CH" 'Later question?')|$(asks "$CH" 'Later notice.')" "$delivered|$delivered" \
    "$name gives later asks and notices the per-message refusal behavior"
  assert_eq "$(jq -sr --arg id "$ASK" '[.[] | select(.t == "out" and .id == $id)] | last | .state // "none"' "$(sk_journal "$ROOT")")" \
    "$state" "$name records whether this ask can retry"
  if [ "$poll_rc" -eq 1 ]; then
    assert_eq "$(field "$ERR1" id)" "$ASK" "$name reports the first failed envelope"
  fi
  sk_poll "$ROOT"
  assert_eq "$RC" 0 "$name succeeds on the next poll"
  assert_eq "$(asks "$CH" 'Approve referenced action?')" "$retried" "$name retries only an ask whose post remains pending"
  assert_eq "$(asks "$CH" 'Later question?')|$(asks "$CH" 'Later notice.')" '1|1' \
    "$name delivers each later ask and notice once across polls"
  if [ "$retried" -eq 1 ]; then
    assert_has "$(sk_state ".messages.${CH}[] | select(.text | contains(\"Approve referenced action?\")) | .text")" \
      "$REF_LINK" "$name retains the referenced conversation link on retry"
  fi
done <<'ROWS'
post-api|{"method":"chat.postMessage","error":"internal_error"}||1|1|retry|1
post-lost|{"method":"chat.postMessage","drop":true}||0|1|unknown|0
post-auth|{"method":"chat.postMessage","error":"invalid_auth"}||2|0|retry|1
read-lost|{"method":"chat.getPermalink","drop":true}||1|1|retry|1
read-api|{"method":"chat.getPermalink","error":"message_not_found"}||1|1|retry|1
read-auth|{"method":"chat.getPermalink","error":"invalid_auth"}||2|0|retry|1
read-first|{"method":"chat.getPermalink","drop":true}|{"method":"chat.getPermalink","error":"message_not_found"}|1|1|retry|1
ROWS

sk_mutant ref-link relay.py '            pieces \+= \[f"\\n\\n\[Referenced conversation\]\(\{permalink\}\)"\]' '            pieces += []'
referenced_ask referenced-control
sk_assert_red "$(jq -cn --arg text "$POSTED" --arg link "$REF_LINK" '$text | contains($link)')" true \
  'control: dropping the link fails the referenced conversation assertion'
sk_bin_reset

sk_mutant ref-refusal relay.py 'self\.post_refused\(err, envelope, "ask", read=True\)' 'raise err'
referenced_ask referenced-refusal-control '{"method":"chat.getPermalink","drop":true}'
sk_assert_red "$(asks "$CH" 'Later question?')|$(asks "$CH" 'Later notice.')" '1|1' \
  'control: propagating the read refusal blocks later asks and notices in the same poll'
sk_bin_reset

echo "=== slack reserved ask ==="
# reserved_ask NAME WAIT — a reserved ask posted from a fresh root, then
# polled once more. Sets ROOT, CH, ASK, ASK_TS (empty when nothing posted)
# and POSTED, the ask's text. A post fault armed before it hits its post.
reserved_ask() {
  ROOT="$(sk_tracker_root "$1" Team '')"
  sk_bind "$ROOT"
  CH="$(sk_channel "$ROOT")"
  ASK="$(sk_lm "$ROOT" ask --item overseer --to owner --file "$(sk_text "$1" 'Cut the 2.0.0 release?')" --options cut,hold --reserved --wait "$2")"
  ASK="${ASK#id=}"
  [ -z "${3:-}" ] || sk_ctl /_test/fault "$3" >/dev/null
  sk_poll "$ROOT"
  ASK_TS="$(sk_state "[.messages.${CH}[] | select(.text | contains(\"Cut the 2.0.0 release?\")) | .ts][0] // \"\"")"
  POSTED="$(sk_state "[.messages.${CH}[] | select(.ts == \"$ASK_TS\") | .text][0] // \"\"")"
  sk_poll "$ROOT"
}
# past_deadline: the ask's deadline moved into the past in the fixture's own
# mailbox, then two polls, each a fresh relay reading the journal.
past_deadline() {
  local box
  box="$(sk_box "$ROOT")"
  jq -c --arg id "$ASK" 'if .id == $id then .deadline = "2000-01-01T00:00:00Z" else . end' "$box/to-overseer.jsonl" > "$SK_TMP/box.jsonl"
  mv "$SK_TMP/box.jsonl" "$box/to-overseer.jsonl"
  sk_poll "$ROOT"
  sk_poll "$ROOT"
}
# reminders: the relay's posts in the ask's thread that open with the owner mention.
reminders() { sk_state "[.messages.${CH}[] | select(.user == \"UBOT\" and .thread_ts == \"$ASK_TS\" and (.text | startswith(\"<@\")))] | length"; }
# reminder_ts: the thread the journal records for the ask's one reminder.
reminder_ts() { jq -r --arg id "$ASK:overdue" 'select(.t == "out" and .id == $id and .state == "resolved") | .thread' "$(sk_journal "$ROOT")"; }
# reminder_options: whether the reminder's own post shows the ask's options.
reminder_options() { sk_state "[.messages.${CH}[] | select(.ts == \"$(reminder_ts)\") | .text | contains(\"Options: cut, hold.\")][0] // false"; }
# answers_to_ask: the owner answers the mailbox holds for the ask.
answers_to_ask() { jq -s --arg id "$ASK" '[.[] | select(.kind == "answer" and .re == $id)] | length' "$(sk_box "$ROOT")/to-lane.jsonl" 2>/dev/null || echo 0; }
# reply_to_reminder: an owner reply in the reminder's thread, then a poll.
reply_to_reminder() { sk_inject "$CH" U001 'hold' "$(reminder_ts)" >/dev/null; sk_poll "$ROOT"; }

reserved_ask reserved 30
assert_has "$POSTED" "No default: " "a reserved ask posts naming no default"
assert_eq "$(reminders)" "0" "before its deadline the reserved ask is posted once"
past_deadline
assert_eq "$(reminders)" "1" "past its deadline the open reserved ask is posted once more in its thread, and never again"

reserved_ask reserved-closed 30
sk_lm "$ROOT" resolve --item overseer --id "$ASK" >/dev/null
past_deadline
assert_eq "$(reminders)" "0" "a reserved ask the overseer closed with no answer is not posted again past its deadline"

reserved_ask reserved-answered 30
sk_inject "$CH" U001 'hold' "$ASK_TS" >/dev/null
sk_poll "$ROOT"
past_deadline
assert_eq "$(answers_to_ask)|$(reminders)" "1|0" "a reserved ask the owner answered in its thread, still open, is not posted again past its deadline"

reserved_ask reserved-late 0
assert_eq "$([ -n "$ASK_TS" ] && echo posted)|$(reminders)" "posted|0" "a reserved ask first posted past its deadline is posted once, its own reminder"

reserved_ask reserved-lost 30 '{"method": "chat.postMessage", "drop": true, "times": 1}'
past_deadline
reply_to_reminder
assert_eq "$([ -n "$(reminder_ts)" ] && echo reminded)|$(reminder_options)|$(answers_to_ask)" "reminded|true|1" \
  "a reserved ask whose post response was lost is reminded with its options in a thread of its own, and a reply there answers the ask"

reserved_ask reserved-deleted 30
sk_ctl /_test/delete "{\"channel\":\"$CH\",\"ts\":\"$ASK_TS\"}" >/dev/null
sk_poll "$ROOT"
past_deadline
reply_to_reminder
assert_eq "$([ "$(reminder_ts)" != "$ASK_TS" ] && echo moved)|$(reminder_options)|$(answers_to_ask)" "moved|true|1" \
  "a reserved ask whose thread Slack deleted is reminded with its options in a new thread, and a reply there answers the ask"

sk_mutant reserved-tail relay.py 'if envelope.get\("reserved"\) is True:' 'if False:'
reserved_ask control-tail 30
sk_assert_red "$(grep -c 'No default: ' <<<"$POSTED")" "1" "control: without the reserved tail the ask names no missing default"

sk_mutant reserved-early relay.py '\n\s+and at_epoch\(str\(envelope\["deadline"\]\)\) <= self\.clock\(\)\):' '):'
reserved_ask control-early 30
sk_assert_red "$(reminders)" "0" "control: without the deadline rule the reminder posts before the deadline"

sk_mutant reserved-again relay.py ' and overdue_id\(env_id\) not in state\.carried' ''
reserved_ask control-again 30
past_deadline
sk_assert_red "$(reminders)" "1" "control: without the journal rule the reminder posts on every poll"

sk_mutant reserved-closed relay.py 'state\.carried and env_id not in closed' 'state.carried'
reserved_ask control-closed 30
sk_lm "$ROOT" resolve --item overseer --id "$ASK" >/dev/null
past_deadline
sk_assert_red "$(reminders)" "0" "control: without the closed rule a closed reserved ask is posted again"

sk_mutant reserved-answered relay.py 'and env_id not in answered and' 'and'
reserved_ask control-answered 30
sk_inject "$CH" U001 'hold' "$ASK_TS" >/dev/null
sk_poll "$ROOT"
past_deadline
sk_assert_red "$(answers_to_ask)|$(reminders)" "1|0" "control: without the answered rule an answered reserved ask is posted again"

sk_mutant reserved-late relay.py 'if envelope\.get\("reserved"\) is True and at_epoch' 'if False and at_epoch'
reserved_ask control-late 0
sk_assert_red "$([ -n "$ASK_TS" ] && echo posted)|$(reminders)" "posted|0" "control: without the first-post rule a late reserved ask is posted twice"

sk_mutant reserved-unposted relay.py 'ts = self\._send\(envelope, "ask", pieces, None\)' 'ts = "1.000001"'
reserved_ask control-unposted 0
sk_assert_red "$([ -n "$ASK_TS" ] && echo posted)|$(reminders)" "posted|0" "control: an ask journaled open but never sent fails the posted assertion"

sk_mutant reserved-rebind relay.py 'self\._out\(envelope, "ask", "open", thread=landed,' 'None and self._out(envelope, "ask", "open", thread=landed,'
reserved_ask control-rebind 30 '{"method": "chat.postMessage", "drop": true, "times": 1}'
past_deadline
reply_to_reminder
sk_assert_red "$([ -n "$(reminder_ts)" ] && echo reminded)|$(answers_to_ask)" "reminded|1" \
  "control: without the rebind a reply to the reminder of a lost ask is no answer"

sk_mutant reserved-short relay.py 'if thread_ts is not None\n' 'if True\n'
reserved_ask control-short 30 '{"method": "chat.postMessage", "drop": true, "times": 1}'
past_deadline
sk_assert_red "$([ -n "$(reminder_ts)" ] && echo reminded)|$(reminder_options)" "reminded|true" \
  "control: a replacement reminder built from the question text alone shows no options"
sk_bin_reset

sk_summary
