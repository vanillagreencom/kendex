#!/usr/bin/env bash
# Surface: owner ask tracker writer and outcome projection.
# Inputs: skills/mailbox/scripts/**, skills/linear/scripts/**, skills/slack/scripts/**, skills/orch/references/secret-value.ere,
# skills/mailbox/tests/lib/owner-tracker.py,
# skills/mailbox/tests/lib/owner-tracker-close.py,
# skills/mailbox/tests/lib/owner-tracker-replace.py,
# skills/orch/tests/lib/assertions.sh, skills/orch/tests/lib/growth-state.sh.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
export PYTHONDONTWRITEBYTECODE=1
ROOT="$(cd -- "${BASH_SOURCE[0]%/*}/../../.." && pwd -P)"
# shellcheck source=../../orch/tests/lib/assertions.sh
. "$ROOT/skills/orch/tests/lib/assertions.sh"
# shellcheck source=../../orch/tests/lib/growth-state.sh
. "$ROOT/skills/orch/tests/lib/growth-state.sh"
TMP_ROOT="$(mktemp -d)" || { echo 'owner-tracker: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo 'owner-tracker: scratch=not-a-directory' >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo 'owner-tracker: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
run_rows() { # SOURCE
  python3 - "$ROOT/skills/mailbox/tests/lib/owner-tracker.py" "$1" "$TMP_ROOT" "$BASH" <<'PY'
import subprocess
import sys
import os
import signal
child = subprocess.Popen([sys.executable, *sys.argv[1:]], start_new_session=True)
try:
    child.wait(timeout=60)
except subprocess.TimeoutExpired:
    os.killpg(child.pid, signal.SIGKILL)
    child.wait()
    raise
sys.exit(child.returncode)
PY
}
FACTS="$(run_rows "${MAILBOX_UNDER_TEST:-$ROOT/skills/mailbox}")"
assert_eq "$(jq '.pending' <<<"$FACTS")" true 'tracker calls start after a marked immutable ask'
assert_eq "$(jq '.terminal' <<<"$FACTS")" true 'each tracker result appends its terminal outcome'
assert_eq "$(jq '.projection' <<<"$FACTS")" true 'readers fold terminal outcomes without replay or private events'
assert_eq "$(jq '.outcome' <<<"$FACTS")" true 'the folded ask names its failure cause or posted comment'
assert_eq "$(jq '.delivery' <<<"$FACTS")" true 'the real relay holds pending asks then posts the selected form once'
assert_eq "$(jq '.bound' <<<"$FACTS")" true 'a missing outcome releases at the fixed bound and preserves later delivery'
CLOSE_FACTS="$(python3 "$ROOT/skills/mailbox/tests/lib/owner-tracker-close.py" \
  "${MAILBOX_UNDER_TEST:-$ROOT/skills/mailbox}" "$TMP_ROOT" "$BASH")"
assert_eq "$(jq '.unposted' <<<"$CLOSE_FACTS")" true 'failed tracker writes preserve description and labels'
assert_eq "$(jq '.notice' <<<"$CLOSE_FACTS")" true 'failed tracker writes retain their failure notice'
assert_eq "$(jq '.posted' <<<"$CLOSE_FACTS")" true 'a confirmed tracker post projects as posted'
assert_eq "$(jq '.close_untracked' <<<"$CLOSE_FACTS")" true 'a close calls no tracker'
assert_eq "$(jq '.retained_error' <<<"$CLOSE_FACTS")" true 'a refused label retains tracker error bytes after close'
assert_eq "$(jq '.comments' <<<"$CLOSE_FACTS")" true 'only successful tracker posts leave a question comment'
assert_eq "$(jq '.rollback_owned' <<<"$CLOSE_FACTS")" true 'failed comments restore the exact description the ask replaced'
assert_eq "$(jq '.rollback_unowned' <<<"$CLOSE_FACTS")" true 'rollback preserves a later description and reports lost ownership'
assert_eq "$(jq '.rollback_notice' <<<"$CLOSE_FACTS")" true 'failed rollback reports its cause and retains the comment error'
assert_eq "$(jq '.comment_refused' <<<"$CLOSE_FACTS")" true 'refused comment acknowledgements stay unposted and retain the response'
assert_eq "$(jq '.rollback_labels' <<<"$CLOSE_FACTS")" true 'rollback removes only the added owner label from fresh labels'
assert_eq "$(jq '.comment_form' <<<"$CLOSE_FACTS")" true 'the question comment mentions the owner and carries no ask id'
assert_eq "$(jq '.mention' <<<"$CLOSE_FACTS")" true 'a saved comment without the owner mention refuses by its key and records no post'
assert_eq "$(jq '.comment_delete' <<<"$CLOSE_FACTS")" true 'a refused comment delete reports its key and retains the answer'
REPLACE_FACTS="$(python3 "$ROOT/skills/mailbox/tests/lib/owner-tracker-replace.py" \
  "${MAILBOX_UNDER_TEST:-$ROOT/skills/mailbox}" "$TMP_ROOT" "$BASH")"
# One row per replace-flow contract. The rule for each owner comment: the
# question it belongs to among every question this mailbox posted on the
# item, open or closed, and that question's ask, open, replaced by an open
# ask, or neither and reported to the overseer once.
while IFS='|' read -r fact contract; do
  [[ -n "$fact" ]] || continue
  assert_eq "$(jq --arg fact "$fact" '.[$fact]' <<<"$REPLACE_FACTS")" true "$contract"
done <<'ROWS'
same_item_replaces|an item ask on the item strikes the earlier question under a link to it, closes that ask as resolve does and keeps the item
chat_replaces|a chat ask replacing a posted item ask strikes its question with no link and closes it
other_item_replaces|an item ask on another item with --replaces strikes the earlier question under a link to its own and closes that ask
other_item_kept|an open ask on another item, named by no --replaces, stays open and unedited
uncommented_replaced|an ask with no question comment is replaced and closed, and a replacing chain carries the earlier entries on
unposted_replaces_nothing|an item ask whose question fails to post leaves every earlier ask open and unedited and has no comment
posted_after_unposted|the next posted re-ask after an unposted one replaces both and takes a reply under the first question
refused_appends_nothing|a refused --replaces or an unconfigured item ask appends nothing and leaves the named ask open
reask_after_close|an item ask after the item's question closed posts its own comment and replaces nothing
unmarked_still_closes|a replaced question whose comment is missing prints replace-unmarked and its ask still closes
refused_close_kept|a refused close prints replace-unclosed with its key and leaves the ask open, struck and replaced
read_before_replace|a comment delivered while its ask was open is not delivered again after a re-ask replaces that ask
replaced_window|a comment on the item after a replaced question reaches the replacing ask under the item header
replaced_reply|a reply under a replaced question reaches the replacing ask under the reply header
open_question_plain|a comment after the open question, or a reply under it, reaches that ask with no header
closed_replacer_reported|once the replacing ask closes, comments on either item and replies under either question are reported unmatched
item_chain|a chain of re-asks on one item delivers each window to the last ask naming its own question
unposted_third|an unposted third ask leaves the second taking its comments plain and replies under the first under the header
mixed_chain|a chat ask replacing an item re-ask takes both windows, each naming its own question
closed_question_reported|a comment after a closed question that nothing replaced is reported unmatched
closed_window_reported|after a re-ask on a closed question, a comment before the new question is reported and one after it is the new ask's
closed_reply_after_later_question|a reply under a closed unreplaced question is reported unmatched while a later question is open
closed_chain_reported|replies under the questions of a closed chain are reported unmatched, not delivered to a later ask
off_item_window|a comment on the item after a question an ask off the item replaced reaches that ask under the item header
off_item_reply|a reply under a question an ask off the item replaced reaches that ask under the reply header
own_item_plain|an ask on another item takes that item's comments plain and a comment from before its question is not judged
third_bounds_window|a later question on the item bounds the replaced window and takes its own comments plain
closed_later_question|after the later question closes, comments after it and replies under it are reported unmatched
closed_between|a comment between a closed question and an open one is reported, and one after the open question is its ask's
both_open|with two open asks posted on one item each comment reaches the ask of the question it belongs to
refused_close_later|once an ask left open by a refused close closes, its question's comments reach the ask that replaced it
before_first_question|a comment from before the item's oldest question is neither delivered nor reported
reply_under_comment|a reply under an owner comment goes where that comment goes
report_unsent_retried|a report the mailbox refuses prints report-unsent, keeps the read and lands on the next pass
compacted_kept|compaction keeps an item's closed questions and their records while an open ask replaces one there
compacted_reask|once an item's records leave, a later question there judges only the comments after it
missing_item|an item Linear holds no issue for counts as holding no comments, named once on stderr, and the pass reads
ROWS
# The item write's settings are judged before the append: each unset key
# refuses an item ask by name and leaves the mailbox and the tracker as they
# were, while an ask without --issue still lands in chat.
SETTINGS_CASE="$TMP_ROOT/settings"
mkdir -p "$SETTINGS_CASE/.agents/skills/mailbox" "$SETTINGS_CASE/.agents/skills/linear/scripts"
cp -R "${MAILBOX_UNDER_TEST:-$ROOT/skills/mailbox}/scripts" "$SETTINGS_CASE/.agents/skills/mailbox/scripts"
git init -q "$SETTINGS_CASE"
git -C "$SETTINGS_CASE" config gc.auto 0
git -C "$SETTINGS_CASE" config maintenance.auto false
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s/tracker-calls"\nexit 1\n' "$SETTINGS_CASE" \
  >"$SETTINGS_CASE/.agents/skills/linear/scripts/linear.sh"
chmod +x "$SETTINGS_CASE/.agents/skills/linear/scripts/linear.sh"
printf 'Approve the change?\n' >"$SETTINGS_CASE/question"
SETTINGS_BOX="$SETTINGS_CASE/tmp/lane-mail/overseer/to-overseer.jsonl"
settings_ask() { # ENV_ASSIGNMENT... -- LANE_MAIL_ARG...
  local assignments=()
  while [[ "$1" != -- ]]; do assignments+=("$1"); shift; done
  shift
  (cd "$SETTINGS_CASE" && env -i PATH="$PATH" HOME="$SETTINGS_CASE" TMPDIR="$SETTINGS_CASE" \
    ${assignments[@]+"${assignments[@]}"} "$BASH" "$SETTINGS_CASE/.agents/skills/mailbox/scripts/lane-mail" ask \
    --item overseer --to owner --options approve,hold --recommend approve --effect none --wait 5 \
    --file "$SETTINGS_CASE/question" "$@")
}
chat_rc=0
settings_ask -- >"$SETTINGS_CASE/chat.out" 2>"$SETTINGS_CASE/chat.err" || chat_rc=$?
assert_eq "$chat_rc|$(jq -s 'map(select(.kind == "ask")) | length' "$SETTINGS_BOX" 2>/dev/null)" '0|1' \
  'an ask without --issue lands in chat with the tracker settings unset'
while IFS='|' read -r row assignment unset; do
  [[ -n "$row" ]] || continue
  before="$(cksum <"$SETTINGS_BOX")"
  ask_rc=0
  settings_ask ${assignment:+"$assignment"} -- --issue KEN-7 --do 'Approve change' \
    >"$SETTINGS_CASE/$row.out" 2>"$SETTINGS_CASE/$row.err" || ask_rc=$?
  assert_eq "$ask_rc|$(sed -n 1p "$SETTINGS_CASE/$row.err")|$(cat "$SETTINGS_CASE/$row.out")" \
    "2|lane-mail: item-ask-unconfigured issue=KEN-7 cause=settings-unset unset=$unset|" \
    "an item ask with $row unset refuses by the key it lacks"
  assert_eq "$(cksum <"$SETTINGS_BOX")|$([[ -e "$SETTINGS_CASE/tracker-calls" ]] && echo called)" "$before|" \
    "an item ask with $row unset leaves the mailbox and the tracker untouched"
done <<'ROWS'
label|ORCH_OWNER_EMAIL=owner@example.test|ORCH_OWNER_ASK_LABEL
owner account|ORCH_OWNER_ASK_LABEL=owner-gated|ORCH_OWNER_EMAIL
both||ORCH_OWNER_ASK_LABEL,ORCH_OWNER_EMAIL
ROWS
# The item is judged before the append too: owner-answers reads it back
# through `comments bulk-list`, which takes an upper-case identifier alone.
while IFS='|' read -r row issue; do
  [[ -n "$row" ]] || continue
  before="$(cksum <"$SETTINGS_BOX")"
  ask_rc=0
  settings_ask ORCH_OWNER_EMAIL=owner@example.test ORCH_OWNER_ASK_LABEL=owner-gated -- \
    --issue "$issue" --do 'Approve change' >"$SETTINGS_CASE/$row.out" 2>"$SETTINGS_CASE/$row.err" || ask_rc=$?
  assert_eq "$ask_rc|$(sed -n 1p "$SETTINGS_CASE/$row.err")|$(cat "$SETTINGS_CASE/$row.out")" \
    "2|lane-mail: issue-invalid=$issue|" "an item ask naming its item by $row refuses issue-invalid"
  assert_eq "$(cksum <"$SETTINGS_BOX")|$([[ -e "$SETTINGS_CASE/tracker-calls" ]] && echo called)" "$before|" \
    "an item ask naming its item by $row leaves the mailbox and the tracker untouched"
done <<'ROWS'
uuid|4029001b-0b88-4e0d-b5a8-3af25993f856
lower-case identifier|ken-7
ROWS
if [[ -z "${MAILBOX_UNDER_TEST:-}" ]]; then
  for rule in pending failed bound private-failed cause comment-id mention attribution mention-check close-untracked retained-error rollback-owner comment-refused rollback-label settings; do
    mkdir -p "$TMP_ROOT/control-$rule"
    cp -R "$ROOT/skills/mailbox/scripts" "$TMP_ROOT/control-$rule/scripts"
    if [[ "$rule" == pending ]]; then
      mutate_file "$TMP_ROOT/control-$rule/scripts/lane-mail" '.tracker_pending = true' '.tracker_pending = false'
      assertion='the real relay holds pending asks then posts the selected form once'
    elif [[ "$rule" == failed ]]; then
      mutate_file "$TMP_ROOT/control-$rule/scripts/lane-mail" 'lm_append_local "$TO_OVERSEER" "$POSTED_LINE"' \
        'if [ "$OWNER_TRACKER_POSTED" -eq 1 ]; then lm_append_local "$TO_OVERSEER" "$POSTED_LINE"; fi'
      assertion='the real relay holds pending asks then posts the selected form once'
    elif [[ "$rule" == bound ]]; then
      mutate_file "$TMP_ROOT/control-$rule/scripts/lib/lane-mail-store.py" \
        'and (release_at is None or time.time() < release_at)' \
        'and (release_at is None or True or time.time() < release_at)'
      assertion='a missing outcome releases at the fixed bound and preserves later delivery'
    elif [[ "$rule" == private-failed ]]; then
      mutate_file "$TMP_ROOT/control-$rule/scripts/lib/mailbox-append.sh" \
        '.kind == "tracker-posted" or .kind == "tracker-failed" or' \
        '.kind == "tracker-posted" or'
      assertion='readers fold terminal outcomes without replay or private events'
    elif [[ "$rule" == cause ]]; then
      mutate_file "$TMP_ROOT/control-$rule/scripts/lib/mailbox-append.sh" \
        '.tracker_cause = $record.cause' '.'
      assertion='the folded ask names its failure cause or posted comment'
    elif [[ "$rule" == comment-id ]]; then
      mutate_file "$TMP_ROOT/control-$rule/scripts/lib/mailbox-append.sh" \
        'OWNER_TRACKER_COMMENT="$comment_id"' ':'
      assertion='the folded ask names its failure cause or posted comment'
    elif [[ "$rule" == mention ]]; then
      mutate_file "$TMP_ROOT/control-$rule/scripts/lib/mailbox-append.sh" \
        '"https://linear.app/" + ($workspace | @uri) + "/profiles/" + ($owner.display_name | @uri), "",' ''
      assertion='the question comment mentions the owner and carries no ask id'
    elif [[ "$rule" == attribution ]]; then
      mutate_file "$TMP_ROOT/control-$rule/scripts/lib/mailbox-append.sh" ' --no-attribution --body-file' ' --body-file'
      assertion='the question comment mentions the owner and carries no ask id'
    elif [[ "$rule" == mention-check ]]; then
      mutate_file "$TMP_ROOT/control-$rule/scripts/lib/mailbox-append.sh" \
        'owner_tracker_mentioned "$tracker" "$comment_id"' 'true "$tracker" "$comment_id"'
      assertion='a saved comment without the owner mention refuses by its key and records no post'
    elif [[ "$rule" == close-untracked ]]; then
      mutate_file "$TMP_ROOT/control-$rule/scripts/lane-mail" \
        'lm_resolved "$MSGID" "$BY" "$CLOSE_ID"' \
        'lm_resolved "$MSGID" "$BY" "$CLOSE_ID"; "$SCRIPT_DIR/../../linear/scripts/linear.sh" issues update KEN-7 --clear-labels >/dev/null 2>&1 || :'
      assertion='a close calls no tracker'
    elif [[ "$rule" == retained-error ]]; then
      mutate_file "$TMP_ROOT/control-$rule/scripts/lib/mailbox-append.sh" \
        'owner_tracker_unwritten "$issue" "$OWNER_TRACKER_CAUSE" "$work/tracker.err"' \
        'owner_tracker_unwritten "$issue" "$OWNER_TRACKER_CAUSE"'
      assertion='a refused label retains tracker error bytes after close'
    elif [[ "$rule" == rollback-owner ]]; then
      mutate_file "$TMP_ROOT/control-$rule/scripts/lib/mailbox-append.sh" \
        '[[ "$owns_description" == true ]] || {' '[[ "$owns_description" == true ]] || true || {'
      assertion='rollback preserves a later description and reports lost ownership'
    elif [[ "$rule" == comment-refused ]]; then
      mutate_file "$TMP_ROOT/control-$rule/scripts/lib/mailbox-append.sh" \
        "select(.success == true) | .data.comment.id" "select(true) | .data.comment.id"
      assertion='refused comment acknowledgements stay unposted and retain the response'
    elif [[ "$rule" == settings ]]; then
      mutate_file "$TMP_ROOT/control-$rule/scripts/lane-mail" \
        'refuse item-ask-unconfigured "$ISSUE"' ':'
      assertion='an item ask with label unset refuses by the key it lacks'
    else
      mutate_file "$TMP_ROOT/control-$rule/scripts/lib/mailbox-append.sh" \
        'if [[ "$added_label" == true ]]; then' 'if false && [[ "$added_label" == true ]]; then'
      assertion='rollback removes only the added owner label from fresh labels'
    fi
    control_rc=0
    MAILBOX_UNDER_TEST="$TMP_ROOT/control-$rule" "$BASH" "$ROOT/skills/mailbox/tests/owner-tracker.sh" \
      >"$TMP_ROOT/control-$rule.log" 2>&1 || control_rc=$?
    assert_eq "$control_rc" 1 "control: removing $rule makes the writer suite fail"
    assert_file_contains "$TMP_ROOT/control-$rule.log" "FAIL  $assertion" "control: $rule reaches its contract assertion"
  done
fi
printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
