#!/usr/bin/env bash
# An owner ask carrying a draft, through the real relay and lane-mail: the
# posted ask shows the draft's recipient, medium and whole text between the
# question and its options, the text as typed. As standard Markdown the text
# is a fenced block longer than any backtick run in it. Oversized literal
# continuation payloads are covered by markup.test.sh. The question
# keeps its tracker links; the draft is never linked. A reserved ask is posted
# naming no default, and once more in its thread on the first poll past its
# deadline while it stays open and unanswered, never again; one first posted
# past its deadline is its own reminder. A question Slack deleted can be
# reminded in a new thread. A lost response leaves the post unconfirmed
# until Slack readback. Any other ask is listen.test.sh's. Each rule has its own
# control on a copy of the scripts.
set -uo pipefail
. "$(dirname "$0")/lib/harness.sh"

sk_fake_start
echo "=== slack draft ask ==="

LINK='**[\[KEN-1\]](https://linear.app/workspace/issue/KEN-1)**'
MARKDOWN_DRAFT='Hello,

[Reset password](https://example.invalid) before KEN-123 ships: run ```make```.'
MARKDOWN_WANT="Send this email for $LINK?

Draft to release-list@example.com by email:

\`\`\`\`
$MARKDOWN_DRAFT
\`\`\`\`

Options: approve, deny. Recommended: deny."
# draft_ask NAME DRAFT_TEXT — one draft ask posted from a fresh root. Sets ASK
# to its id, POSTED to its body argument and its text between the owner
# mention's header line and the deadline sentence, `<arg>|<text>`.
draft_ask() {
  local root draft
  root="$(sk_tracker_root "$1" Team '')"
  sk_bind "$root"
  draft="$(jq -cn --arg text "$2" '{recipient: "release-list@example.com", medium: "email", text: $text, text_hash: "sha256:0f"}')"
  ASK="$(sk_lm "$root" ask --item overseer --to owner --file "$(sk_text "$1" 'Send this email for KEN-1?')" --options approve,deny --recommend deny --effect none)"
  ASK="${ASK#id=}"
  sk_event_filter "$root" "if .kind == \"ask\" then .draft = $draft else . end"
  sk_poll "$root"
  POSTED="$(sk_state ".messages.$(sk_channel "$root")[] | select(.text | contains(\"Send this email for\")) | .body_arg + \"|\" + (.text | sub(\"^[^\\n]* Question from overseer:\\n\\n\"; \"\") | sub(\" It stands at [^\\n]* unless you reply in this thread[.]$\"; \"\"))")"
}

draft_ask markdown "$MARKDOWN_DRAFT"
assert_eq "$POSTED" "markdown_text|$MARKDOWN_WANT" "under the cap the draft sits in a fence longer than its backtick run, unlinked, between the linked question and the options"

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

sk_bin_reset

# Read the deadline lane-mail assigned so the assertion checks Slack's date
# token and fallback without depending on the time the test takes to post.
ask_deadline() { # ROOT ASK_ID
  local at deadline
  at="$(jq -er --arg id "$2" 'select(.kind == "ask" and .id == $id) | .deadline' \
    "$(sk_box "$1")/to-overseer.jsonl")" || return 1
  deadline="$(jq -rn --arg at "$at" '$at | fromdateiso8601')" || return 1
  printf 'It stands at <!date^%s^{date_short_pretty} at {time}|%s> unless you reply in this thread.' "$deadline" "$at"
}

tracker_ask() { # NAME FAILURE
  local root scripts phase="${2:-}" deadline ask_rc=0 notice
  local question='Approve action?
The action updates the release checklist.'
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
  assign:issues:update:--assignee|labels-read:graphql:--query:*|label:issues:update:--labels|comment:comments:create:*) exit 1 ;;
esac
case "$1:$2" in
  users:list) echo '[{"id":"87654321-4321-4321-4321-cba987654321","name":"Riley Other","email":"other@example.test"},{"id":"12345678-1234-1234-1234-123456789abc","name":"Maya Owner","email":"owner@example.com","display_name":"maya"}]' ;;
  teams:keys) echo '{"urlKey":"workspace","keys":["KEN"]}' ;;
  graphql:--query)
    case "$3" in
      'query OwnerTrackerComment('*) echo '{"comment":{"bodyData":"{\"type\":\"doc\",\"content\":[{\"type\":\"suggestion_userMentions\",\"attrs\":{\"id\":\"12345678-1234-1234-1234-123456789abc\"}}]}"}}' ;;
      *) echo '{"issue":{"description":"","assignee":{"name":"Maya Owner"},"labels":{"pageInfo":{"hasNextPage":false},"nodes":[{"name":"skills"}]}}}' ;;
    esac ;;
  issues:update) echo '{}' ;;
  comments:owner-questions) echo '"question-id"' ;;
  comments:create) echo '{"success":true,"data":{"success":true,"comment":{"id":"question-id"}}}' ;;
  issues:bulk-get) echo '[{"id":"KEN-1","uuid":"00000001-0000-4000-8000-000000000001"}]' ;;
  *) exit 1 ;;
esac
STUB
  chmod +x "$root/.agents/skills/linear/scripts/linear.sh"
  ASK="$(cd "$root" && env ORCH_OWNER_EMAIL=owner@example.com ORCH_OWNER_ASK_LABEL=owner-gated LINEAR_TEAM=KEN \
    TRACKER_FAILURE="$phase" "$scripts/lane-mail" ask --item overseer --to owner \
    --issue KEN-1 --do 'Approve the action. Your reply closes this ask.' --file "$(sk_text "$1" "$question")" \
    --options approve,hold --recommend approve --effect none --wait 60 2>"$root/tracker.err")" || ask_rc=$?
  assert_eq "$ask_rc" 0 "$1 creates the owner ask"
  case "$ASK" in
    id=?*) ok "$1 returns its owner ask id" ;;
    *) bad "$1 returns its owner ask id" "$ASK"; return ;;
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
  deadline="$(ask_deadline "$root" "$ASK")" || { bad "$1 records a deadline"; return; }
  sk_poll "$root"
  local actual expected
  actual="$(sk_state ".messages.$(sk_channel "$root")[] | select(.text | contains(\"Approve action?\")) | .text")"
  expected="<@U001> <@U002> Question from overseer:

$question"
  if [ "$posted" = true ]; then
    expected="$expected

$LINK"
  fi
  assert_eq "$actual" "$expected

Options: approve, hold. Recommended: approve. $deadline" \
    "$1 posts the whole question, options, recommendation and deadline"
}
tracker_ask tracker-posted
for failure in assign labels-read label comment; do
  tracker_ask "tracker-fallback-$failure" "$failure"
done

echo "=== slack referenced ask ==="
# A linked ask stays separate from the directive, so its reply answers the ask.
REFERENCED_QUESTION='Approve referenced action?
The action updates the release checklist.'
referenced_ask() {
  ROOT="$(sk_tracker_root "$1" Team '')"
  sk_bind "$ROOT"
  CH="$(sk_channel "$ROOT")"
  sk_poll "$ROOT"
  REF_TS="$(sk_inject "$CH" U001 'Earlier conversation.')"
  sk_poll "$ROOT"
  REF="$(jq -r 'select(.kind == "directive") | .id' "$(sk_box "$ROOT")/to-lane.jsonl")"
  ASK="$(sk_lm "$ROOT" ask --item overseer --to owner --ref "$REF" --file "$(sk_text "$1" "$REFERENCED_QUESTION")" \
    --options approve,hold --recommend hold --effect none --wait 60)"
  ASK="${ASK#id=}"
  if [ -n "${2:-}" ]; then
    if [ -n "${3:-}" ]; then
      sk_lm "$ROOT" ask --item overseer --to owner --ref "$REF" --file "$(sk_text "$1-other" 'Other referenced action?')" --options approve,hold --recommend hold --effect none >/dev/null
    fi
    sk_lm "$ROOT" ask --item overseer --to owner --file "$(sk_text "$1-later" 'Later question?')" --options approve,hold --recommend hold --effect none >/dev/null
    sk_lm "$ROOT" notice --item overseer --to owner --file "$(sk_text "$1-notice" 'Later notice.')" >/dev/null
    sk_ctl /_test/fault "$2" >/dev/null
    if [ -n "${3:-}" ]; then sk_ctl /_test/fault "$3" >/dev/null; fi
  fi
  sk_poll "$ROOT"
  ASK_TS="$(sk_state "[.messages.${CH}[] | select(.text | contains(\"Approve referenced action?\")) | .ts][0] // \"\"")"
  POSTED="$(sk_state "[.messages.${CH}[] | select(.ts == \"$ASK_TS\") | .text][0] // \"\"")"
  REF_LINK="https://workspace.slack.com/archives/$CH/p${REF_TS/./}"
}
referenced_ask referenced
assert_eq "$RC" 0 'the fake Slack server supports the permalink request'
DEADLINE="$(ask_deadline "$ROOT" "$ASK")" || bad 'the itemless ask records a deadline'
assert_eq "$POSTED" "<@U001> <@U002> Question from overseer:

$REFERENCED_QUESTION

Options: approve, hold. Recommended: hold. $DEADLINE

[Referenced conversation]($REF_LINK)" \
  'the itemless ask posts the whole question, options, recommendation, deadline and referenced conversation link'
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
post-api|{"method":"chat.postMessage","error":"invalid_blocks"}||1|1|retry|1
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
age_read_mailbox() {
  local box
  for box in to-lane to-overseer; do
    jq -c '.at="2000-01-01T00:00:00Z"' "$(sk_box "$ROOT")/$box.jsonl" >"$SK_TMP/aged" || return 1
    mv -- "$SK_TMP/aged" "$(sk_box "$ROOT")/$box.jsonl" || return 1
  done
  printf '50\n' >"$(sk_box "$ROOT")/to-lane.cursor"
}

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
assert_eq "$(reminder_ts)|$(asks "$CH" 'Cut the 2.0.0 release?')" "|0" \
  "a reserved ask whose first post is unconfirmed does not start a second thread"

reserved_ask reserved-deleted 30
[ "$RC" -eq 0 ] && [ -n "$ASK_TS" ] || exit 1
# The installed compactor still runs, but its capability answer is temporarily
# unavailable. Keep the existing root's presenter when Slack replaces it.
INSTALLED="$ROOT/.agents/skills/mailbox/scripts"
rm -- "$INSTALLED" && cp -R "${SK_LANE_MAIL%/*}" "$INSTALLED" || exit 1
mkdir -p "$ROOT/.agents/skills/agent-runtime" &&
  ln -s "$SK_ROOT/skills/agent-runtime/scripts" "$ROOT/.agents/skills/agent-runtime/scripts" || exit 1
COMPACTOR="$INSTALLED/lib/lane-mail-store.py"
cp -- "$COMPACTOR" "$SK_TMP/compactor.saved" || exit 1
python3 - "$COMPACTOR" <<'PY' || exit 1
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text()
marker = 'if op == "presentation-retention":'
assert source.count(marker) == 1
path.write_text(source.replace(marker, 'if False:'))
PY
sk_ctl /_test/delete "{\"channel\":\"$CH\",\"ts\":\"$ASK_TS\"}" >/dev/null
sk_poll "$ROOT"
sk_ctl /_test/fault '{"method":"chat.postMessage","accepted":true,"error":"fatal_error"}' >/dev/null
past_deadline
assert_eq "$(sk_lm "$ROOT" pending --item overseer --to owner | jq -r '.presentation.thread_ts')" "$(reminder_ts)" \
  "the recovered replacement is the confirmed approval thread"
sk_lm "$ROOT" resolve --item overseer --id "$ASK" >/dev/null || exit 1
sk_lm "$ROOT" notice --item overseer --to owner --file "$(sk_text unrelated 'An unrelated old notice.')" >/dev/null || exit 1
OVER="$(sk_box "$ROOT")/to-overseer.jsonl"
UNRELATED="$(jq -er 'select(.kind == "notice" and (.text | contains("An unrelated old notice."))) | .id' "$OVER")" || exit 1
age_read_mailbox || exit 1
COMPACTED="$(ORCH_ARCHIVE_ROOT="$SK_TMP/archive" SK_LANE_MAIL="$INSTALLED/lane-mail" sk_lm "$ROOT" compact --item overseer)" || exit 1
assert_has "$COMPACTED" 'compacted item=overseer' "the installed compactor ran successfully"
assert_eq "$(jq -r --arg id "$UNRELATED" 'select(.id == $id) | .id' "$OVER")" "" \
  "compaction removed the unrelated aged notice"

# A refusal from a bound write must leave the event available to retry.
sk_copy bound-answer-refused
WRITER="${SK_BIN%/slack/scripts/slack}/mailbox/scripts/lane-mail"
mv -- "$WRITER" "$WRITER.real" || exit 1
cat >"$WRITER" <<'SH'
#!/usr/bin/env bash
if [ "$1" = send ]; then
  for arg in "$@"; do
    if [ "$arg" = --presenter ]; then
      printf 'lane-mail: write-failed=fixture-cleanup-check\n' >&2
      exit 2
    fi
  done
fi
exec "${BASH_SOURCE[0]}.real" "$@"
SH
chmod +x "$WRITER" || exit 1
LATE="$(sk_inject "$CH" U001 hold "$(reminder_ts)")" || exit 1
sk_poll "$ROOT"
assert_has "$ERR" 'fixture-cleanup-check' "the failed bound write is reported"
assert_eq "$(jq -r --arg ts "$LATE" 'select(.ts == $ts or (.t == "thread" and .seen == $ts)) | .t' "$(sk_journal "$ROOT")")|$(sk_reactions "$CH" "$LATE")" \
  "|" "the failed cleanup period neither routes the reply nor marks the Slack event seen"
sk_bin_reset
cp -- "$SK_TMP/compactor.saved" "$COMPACTOR" || exit 1
sk_poll "$ROOT"
sk_poll "$ROOT"
assert_eq "$([ "$(reminder_ts)" != "$ASK_TS" ] && echo moved)|$(reminder_options)|$(answers_to_ask)" "moved|true|1" \
  "a late reply in the replacement thread answers its closed original ask after current compaction"
assert_eq "$(jq -r --arg d "$CH:$LATE" 'select(.delivery_id == $d) | [.kind,.re,.sender] | join("|")' "$(sk_box "$ROOT")/to-lane.jsonl")" \
  "answer|$ASK|owner" "retry keeps the original delivery identity and never records a directive"

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

sk_mutant reserved-unposted relay.py 'ts = self\._send\(envelope, "ask", pieces, None, presentation=retained\)' 'ts = "1.000001"'
reserved_ask control-unposted 0
sk_assert_red "$([ -n "$ASK_TS" ] && echo posted)|$(reminders)" "posted|0" "control: an ask journaled open but never sent fails the posted assertion"

sk_mutant reserved-rebind relay.py 'self\.bind_presentation\(envelope, \{"ts": landed, "text": excerpt\}, "ask", retained\)' 'None'
reserved_ask control-rebind 30
sk_ctl /_test/delete "{\"channel\":\"$CH\",\"ts\":\"$ASK_TS\"}" >/dev/null
sk_poll "$ROOT"
past_deadline
reply_to_reminder
sk_assert_red "$([ -n "$(reminder_ts)" ] && echo reminded)|$(answers_to_ask)" "reminded|1" \
  "control: without the rebind a reply to the replacement thread is no answer"

sk_mutant reserved-short relay.py 'if thread_ts is not None\n' 'if True\n'
reserved_ask control-short 30
sk_ctl /_test/delete "{\"channel\":\"$CH\",\"ts\":\"$ASK_TS\"}" >/dev/null
sk_poll "$ROOT"
past_deadline
sk_assert_red "$([ -n "$(reminder_ts)" ] && echo reminded)|$(reminder_options)" "reminded|true" \
  "control: a replacement reminder built from the question text alone shows no options"
sk_bin_reset

ROOT="$(sk_new_root pre-presentation-writer)"
sk_bind "$ROOT"
CH="$(sk_channel "$ROOT")"
legacy="$ROOT/.agents/skills/mailbox/scripts"
rm -- "$legacy"
cp -R "${SK_LANE_MAIL%/*}" "$legacy"
# A pre-presentation compactor uses the original age and read rule and cannot
# advertise retained presentations. The installed writer refuses their verbs.
python3 - "$legacy/lib/lane-mail-store.py" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text()
old_plan = ' or awaiting_delivery or bound'
old_entry = 'if op == "presentation-retention":'
assert source.count(old_plan) == source.count(old_entry) == 1
path.write_text(source.replace(old_plan, '').replace(old_entry, 'if False:'))
PY
mv -- "$legacy/lane-mail" "$legacy/lane-mail-current"
cat >"$legacy/lane-mail" <<'SH'
#!/usr/bin/env bash
case "$1" in
  present) printf 'lane-mail: verb-invalid=present\n' >&2; exit 2 ;;
esac
for arg in "$@"; do
  if [ "$arg" = --presenter ]; then printf 'lane-mail: option-unknown=--presenter\n' >&2; exit 2; fi
done
exec "${BASH_SOURCE[0]%/*}/lane-mail-current" "$@"
SH
chmod +x "$legacy/lane-mail"
legacy_mail() { SK_LANE_MAIL="$legacy/lane-mail" sk_lm "$ROOT" "$@" --item overseer; }
ASK="$(legacy_mail ask --to owner --file "$(sk_text legacy 'Question in a legacy checkout?')" \
  --options yes,no --reserved)"
ASK="${ASK#id=}"
sk_poll "$ROOT"
TS="$(sk_state ".messages.${CH}[] | select(.text | contains(\"Question in a legacy checkout?\")) | .ts")"
REPLY="$(sk_inject "$CH" U001 'I will confirm separately.' "$TS")"
sk_poll "$ROOT"
assert_eq "$(asks "$CH" 'Question in a legacy checkout?')|$(jq -r --arg d "$CH:$REPLY" \
  'select(.delivery_id == $d) | [.re,.sender] | join("|")' "$(sk_box "$ROOT")/to-lane.jsonl")" "1|$ASK|owner" \
  "the relay uses the legacy direct post and answer path in an older bound checkout"
BOX="$(sk_box "$ROOT")"
assert_eq "$(jq -c --arg id "$ASK" 'select(.re == $id and (.kind | startswith("owner-present")))' "$BOX/to-overseer.jsonl")" "" \
  "the old compactor's mailbox receives no new presentation records"
legacy_mail resolve --id "$ASK" >/dev/null
age_read_mailbox
ORCH_ARCHIVE_ROOT="$SK_TMP/archive" legacy_mail compact >/dev/null
assert_eq "$(jq -c --arg id "$ASK" 'select(.id == $id)' "$BOX/to-overseer.jsonl")" "" \
  "the older compaction rule ages the closed legacy ask out normally"

sk_summary
