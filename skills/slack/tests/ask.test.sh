#!/usr/bin/env bash
# An owner ask carrying a draft, through the real relay and lane-mail: the
# posted ask shows the draft's recipient, medium and whole text between the
# question and its options, the text as typed. As standard Markdown the text
# is one fenced block longer than any backtick run in it; past the
# markdown_text cap it is one mrkdwn block with Slack's control characters
# escaped, and a text mrkdwn cannot hold in a block is refused. The question
# keeps its tracker links; the draft is never linked. A reserved ask is posted
# naming no default, and once more in its thread on the first poll past its
# deadline while it stays open, never again; one first posted past its
# deadline is its own reminder. Any other ask is listen.test.sh's. Each rule
# has its own control on a copy of the scripts.
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
# polled once more. Sets ROOT, ASK, ASK_TS and POSTED, the ask's text.
reserved_ask() {
  ROOT="$(sk_tracker_root "$1" Team '')"
  sk_bind "$ROOT"
  ASK="$(sk_lm "$ROOT" ask --item overseer --to owner --file "$(sk_text "$1" 'Cut the 2.0.0 release?')" --options cut,hold --reserved --wait "$2")"
  ASK="${ASK#id=}"
  sk_poll "$ROOT"
  ASK_TS="$(sk_state ".messages.$(sk_channel "$ROOT")[] | select(.text | contains(\"Cut the 2.0.0 release?\")) | .ts")"
  POSTED="$(sk_state ".messages.$(sk_channel "$ROOT")[] | select(.ts == \"$ASK_TS\") | .text")"
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
# The relay's posts in the ask's thread that mention the owner past the deadline.
reminders() { sk_state "[.messages.$(sk_channel "$ROOT")[] | select(.thread_ts == \"$ASK_TS\" and (.text | startswith(\"<@\") and contains(\"Past its deadline\")))] | length"; }

reserved_ask reserved 30
assert_has "$POSTED" "Options: cut, hold. This decision is yours alone and has no default; reply in this thread by <!date^" \
  "a reserved ask posts its options and no default"
assert_eq "$(reminders)" "0" "before its deadline the reserved ask is posted once"
past_deadline
assert_eq "$(reminders)" "1" "past its deadline the open reserved ask is posted once more in its thread, and never again"

reserved_ask reserved-closed 30
sk_lm "$ROOT" resolve --item overseer --id "$ASK" --text "$(sk_text closed 'hold')" >/dev/null
past_deadline
assert_eq "$(reminders)" "0" "a reserved ask the owner answered is not posted again past its deadline"

reserved_ask reserved-late 0
assert_eq "$(reminders)" "0" "a reserved ask first posted past its deadline is its own reminder"

sk_mutant reserved-tail relay.py 'if envelope.get\("reserved"\) is True:' 'if False:'
reserved_ask control-tail 30
assert_lacks "$POSTED" "has no default" "control: without the reserved tail the ask reads as one with a default"

sk_mutant reserved-early relay.py '\n\s+and at_epoch\(str\(envelope\["deadline"\]\)\) <= self\.clock\(\)\):' '):'
reserved_ask control-early 30
sk_assert_red "$(reminders)" "0" "control: without the deadline rule the reminder posts before the deadline"

sk_mutant reserved-again relay.py '\n\s+and overdue_id\(env_id\) not in state\.carried' ''
reserved_ask control-again 30
past_deadline
sk_assert_red "$(reminders)" "1" "control: without the journal rule the reminder posts on every poll"

sk_mutant reserved-closed relay.py 'state\.carried and env_id not in closed' 'state.carried'
reserved_ask control-closed 30
sk_lm "$ROOT" resolve --item overseer --id "$ASK" --text "$(sk_text control-closed-a 'hold')" >/dev/null
past_deadline
sk_assert_red "$(reminders)" "0" "control: without the closed rule an answered reserved ask is posted again"

sk_mutant reserved-late relay.py 'if envelope\.get\("reserved"\) is True and at_epoch' 'if False and at_epoch'
reserved_ask control-late 0
sk_assert_red "$(reminders)" "0" "control: without the first-post rule a late reserved ask is posted twice"
sk_bin_reset

sk_summary
