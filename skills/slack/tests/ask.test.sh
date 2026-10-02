#!/usr/bin/env bash
# An owner ask carrying a draft, through the real relay and lane-mail: the
# posted ask shows the draft's recipient, medium and whole text between the
# question and its options, the text as typed. As standard Markdown the text
# is one fenced block longer than any backtick run in it; past the
# markdown_text cap it is one mrkdwn block with Slack's control characters
# escaped, and a text mrkdwn cannot hold in a block is refused. The question
# keeps its tracker links; the draft is never linked. An ask with no draft is
# listen.test.sh's. Each rule has its own control on a copy of the scripts.
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

sk_summary
