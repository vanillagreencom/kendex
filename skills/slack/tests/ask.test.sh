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

sk_tracker_fixture
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
