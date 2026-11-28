#!/usr/bin/env bash
# Surface: owner ask tracker writer and outcome projection.
# Inputs: skills/mailbox/scripts/**, skills/linear/scripts/**, skills/slack/scripts/**, skills/orch/references/secret-value.ere,
# skills/mailbox/tests/lib/owner-tracker.py,
# skills/mailbox/tests/lib/owner-tracker-close.py,
# skills/mailbox/tests/lib/owner-replace.py,
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
MAILBOX_SOURCE="${MAILBOX_UNDER_TEST:-$ROOT/skills/mailbox}"

tracker_rows() {
  local FACTS
  FACTS="$(python3 - "$ROOT/skills/mailbox/tests/lib/owner-tracker.py" "$MAILBOX_SOURCE" "$TMP_ROOT" "$BASH" <<'PY'
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
)"
  assert_eq "$(jq '.pending' <<<"$FACTS")" true 'tracker calls start after a marked immutable ask'
  assert_eq "$(jq '.terminal' <<<"$FACTS")" true 'each tracker result appends its terminal outcome'
  assert_eq "$(jq '.projection' <<<"$FACTS")" true 'readers fold terminal outcomes without replay or private events'
  assert_eq "$(jq '.outcome' <<<"$FACTS")" true 'the folded ask names its failure cause or posted comment'
  assert_eq "$(jq '.delivery' <<<"$FACTS")" true 'the real relay holds pending asks then posts the selected form once'
  assert_eq "$(jq '.bound' <<<"$FACTS")" true 'a missing outcome releases at the fixed bound and preserves later delivery'
}

close_rows() {
  local CLOSE_FACTS
  CLOSE_FACTS="$(python3 "$ROOT/skills/mailbox/tests/lib/owner-tracker-close.py" \
    "$MAILBOX_SOURCE" "$TMP_ROOT" "$BASH")"
  assert_eq "$(jq '.unposted' <<<"$CLOSE_FACTS")" true 'failed tracker writes preserve description and labels'
  assert_eq "$(jq '.notice' <<<"$CLOSE_FACTS")" true 'failed tracker writes retain their failure notice'
  assert_eq "$(jq '.posted' <<<"$CLOSE_FACTS")" true 'a confirmed tracker post projects as posted'
  assert_eq "$(jq '.close_untracked' <<<"$CLOSE_FACTS")" true 'a close writes nothing to the tracker and reads only its comments'
  assert_eq "$(jq '.retained_error' <<<"$CLOSE_FACTS")" true 'a refused label retains tracker error bytes after close'
  assert_eq "$(jq '.comments' <<<"$CLOSE_FACTS")" true 'only successful tracker posts leave a question comment'
  assert_eq "$(jq '.rollback_owned' <<<"$CLOSE_FACTS")" true 'failed comments restore the exact description the ask replaced'
  assert_eq "$(jq '.rollback_unowned' <<<"$CLOSE_FACTS")" true 'rollback preserves a later description and reports lost ownership'
  assert_eq "$(jq '.rollback_notice' <<<"$CLOSE_FACTS")" true 'failed rollback reports its cause and retains the comment error'
  assert_eq "$(jq '.comment_refused' <<<"$CLOSE_FACTS")" true 'refused comment acknowledgements stay unposted and retain the response'
  assert_eq "$(jq '.rollback_labels' <<<"$CLOSE_FACTS")" true 'rollback takes the owner label off fresh labels and keeps the rest'
  assert_eq "$(jq '.rollback_pair' <<<"$CLOSE_FACTS")" true 'a failed ask post leaves neither the owner label nor the owner assignee'
  assert_eq "$(jq '.comment_form' <<<"$CLOSE_FACTS")" true 'the question comment mentions the owner and carries no ask id'
  assert_eq "$(jq '.mention' <<<"$CLOSE_FACTS")" true 'a saved comment without the owner mention refuses by its key and records no post'
  assert_eq "$(jq '.comment_delete' <<<"$CLOSE_FACTS")" true 'a refused comment delete reports its key and retains the answer'
  assert_eq "$(jq '.survivor_removed' <<<"$CLOSE_FACTS")" true 'a later close recovers a failed reserved question before clearing the owner pair'
}

# A new ask that replaces an open one, each row judged on its own tracker.
replacement_rows() {
  local REPLACE_FACTS fact contract
  REPLACE_FACTS="$(python3 "$ROOT/skills/mailbox/tests/lib/owner-replace.py" ask \
    "$MAILBOX_SOURCE" "$TMP_ROOT" "$BASH")"
  assert_eq "$(jq -c 'with_entries(select(.key | startswith("error:")))' <<<"$REPLACE_FACTS")" '{}' \
    'every replacement case runs to its observation'
  while IFS='|' read -r fact contract; do
    [[ -n "$fact" ]] || continue
    assert_eq "$(jq --arg fact "$fact" '.[$fact]' <<<"$REPLACE_FACTS")" true "$contract"
  done <<'ROWS'
same_item_replaces|a re-ask on the item strikes the earlier question under a link to the new one and closes its ask as resolve does, the item keeping its label and assignee
spellings_replaced|an earlier ask kept under the item's lower-case ref, its UUID or a former identifier is replaced through the tracker identity
refused_before_post|a replaced question with no acting identity or another author refuses the ask before anything is appended or posted
incomplete_retried|an edit that fails after the post leaves the earlier ask open and incomplete until a pass retries the same comment and closes it, the replacing ask open or closed since
absent_closes|a replaced question comment the tracker holds no longer closes its ask with no edit
no_team_replaces|a re-ask where Linear has no team marks the earlier comment replaced and closes its ask
explicit_replaces|--replaces closes a chat-only ask or an ask on another item, and an item ask leaves another item's open ask alone
ROWS
}

# The item write's settings are judged before the append: each unset key
# refuses an item ask by name and leaves the mailbox and the tracker as they
# were, while an ask without --issue still lands in chat.
settings_ask() { # CASE ENV_ASSIGNMENT... -- LANE_MAIL_ARG...
  local SETTINGS_CASE="$1"
  shift
  local assignments=()
  while [[ "$1" != -- ]]; do assignments+=("$1"); shift; done
  shift
  (cd "$SETTINGS_CASE" && env -i PATH="$PATH" HOME="$SETTINGS_CASE" TMPDIR="$SETTINGS_CASE" \
    ${assignments[@]+"${assignments[@]}"} "$BASH" "$SETTINGS_CASE/.agents/skills/mailbox/scripts/lane-mail" ask \
    --item overseer --to owner --options approve,hold --recommend approve --effect none --wait 5 \
    --file "$SETTINGS_CASE/question" "$@")
}

settings_rows() {
  local SETTINGS_CASE SETTINGS_BOX chat_rc ask_rc row assignment unset before
  SETTINGS_CASE="$TMP_ROOT/settings"
  mkdir -p "$SETTINGS_CASE/.agents/skills/mailbox" "$SETTINGS_CASE/.agents/skills/linear/scripts"
  cp -R "$MAILBOX_SOURCE/scripts" "$SETTINGS_CASE/.agents/skills/mailbox/scripts"
  git init -q "$SETTINGS_CASE"
  git -C "$SETTINGS_CASE" config gc.auto 0
  git -C "$SETTINGS_CASE" config maintenance.auto false
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s/tracker-calls"\nexit 1\n' "$SETTINGS_CASE" \
    >"$SETTINGS_CASE/.agents/skills/linear/scripts/linear.sh"
  chmod +x "$SETTINGS_CASE/.agents/skills/linear/scripts/linear.sh"
  printf 'Approve the change?\n' >"$SETTINGS_CASE/question"
  SETTINGS_BOX="$SETTINGS_CASE/tmp/lane-mail/overseer/to-overseer.jsonl"
  chat_rc=0
  settings_ask "$SETTINGS_CASE" -- >"$SETTINGS_CASE/chat.out" 2>"$SETTINGS_CASE/chat.err" || chat_rc=$?
  assert_eq "$chat_rc|$(jq -s 'map(select(.kind == "ask")) | length' "$SETTINGS_BOX" 2>/dev/null)" '0|1' \
    'an ask without --issue lands in chat with the tracker settings unset'
  while IFS='|' read -r row assignment unset; do
    [[ -n "$row" ]] || continue
    before="$(cksum <"$SETTINGS_BOX")"
    ask_rc=0
    settings_ask "$SETTINGS_CASE" ${assignment:+"$assignment"} -- --issue KEN-7 --do 'Approve change' \
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
}

# Controls select one phase and run in their own process so assertion failures
# and fixture errors keep the suite's usual exit behavior.
case "${1:-all}" in
  all)
    tracker_rows
    close_rows
    replacement_rows
    settings_rows
    ;;
  tracker) tracker_rows ;;
  close) close_rows ;;
  settings) settings_rows ;;
  *) printf 'owner-tracker: unknown phase %s\n' "$1" >&2; exit 2 ;;
esac

if [[ $# -eq 0 && -z "${MAILBOX_UNDER_TEST:-}" ]]; then
  for rule in pending failed bound private-failed cause comment-id mention attribution mention-check close-untracked retained-error rollback-owner comment-refused settings; do
    mkdir -p "$TMP_ROOT/control-$rule"
    cp -R "$ROOT/skills/mailbox/scripts" "$TMP_ROOT/control-$rule/scripts"
    if [[ "$rule" == pending ]]; then
      phase=tracker
      mutate_file "$TMP_ROOT/control-$rule/scripts/lane-mail" '.tracker_pending = true' '.tracker_pending = false'
      assertion='the real relay holds pending asks then posts the selected form once'
    elif [[ "$rule" == failed ]]; then
      phase=tracker
      mutate_file "$TMP_ROOT/control-$rule/scripts/lane-mail" 'lm_append_local "$TO_OVERSEER" "$POSTED_LINE"' \
        'if [ "$OWNER_TRACKER_POSTED" -eq 1 ]; then lm_append_local "$TO_OVERSEER" "$POSTED_LINE"; fi'
      assertion='the real relay holds pending asks then posts the selected form once'
    elif [[ "$rule" == bound ]]; then
      phase=tracker
      mutate_file "$TMP_ROOT/control-$rule/scripts/lib/lane-mail-store.py" \
        'and (release_at is None or time.time() < release_at)' \
        'and (release_at is None or True or time.time() < release_at)'
      assertion='a missing outcome releases at the fixed bound and preserves later delivery'
    elif [[ "$rule" == private-failed ]]; then
      phase=tracker
      mutate_file "$TMP_ROOT/control-$rule/scripts/lib/mailbox-append.sh" \
        '.kind == "tracker-posted" or .kind == "tracker-failed" or' \
        '.kind == "tracker-posted" or'
      assertion='readers fold terminal outcomes without replay or private events'
    elif [[ "$rule" == cause ]]; then
      phase=tracker
      mutate_file "$TMP_ROOT/control-$rule/scripts/lib/mailbox-append.sh" \
        '.tracker_cause = $record.cause' '.'
      assertion='the folded ask names its failure cause or posted comment'
    elif [[ "$rule" == comment-id ]]; then
      phase=tracker
      mutate_file "$TMP_ROOT/control-$rule/scripts/lib/mailbox-append.sh" \
        'OWNER_TRACKER_COMMENT="$comment_id"' ':'
      assertion='the folded ask names its failure cause or posted comment'
    elif [[ "$rule" == mention ]]; then
      phase=close
      mutate_file "$TMP_ROOT/control-$rule/scripts/lib/mailbox-append.sh" \
        '"https://linear.app/" + ($workspace | @uri) + "/profiles/" + ($owner.display_name | @uri), "",' ''
      assertion='the question comment mentions the owner and carries no ask id'
    elif [[ "$rule" == attribution ]]; then
      phase=close
      mutate_file "$TMP_ROOT/control-$rule/scripts/lib/mailbox-append.sh" ' --no-attribution --body-file' ' --body-file'
      assertion='the question comment mentions the owner and carries no ask id'
    elif [[ "$rule" == mention-check ]]; then
      phase=close
      mutate_file "$TMP_ROOT/control-$rule/scripts/lib/mailbox-append.sh" \
        'owner_tracker_mentioned "$tracker" "$comment_id"' 'true "$tracker" "$comment_id"'
      assertion='a saved comment without the owner mention refuses by its key and records no post'
    elif [[ "$rule" == close-untracked ]]; then
      phase=close
      mutate_file "$TMP_ROOT/control-$rule/scripts/lane-mail" \
        'lm_resolved "$MSGID" "$BY" "$CLOSE_ID"' \
        'lm_resolved "$MSGID" "$BY" "$CLOSE_ID"; "$SCRIPT_DIR/../../linear/scripts/linear.sh" issues update KEN-7 --clear-labels >/dev/null 2>&1 || :'
      assertion='a close writes nothing to the tracker and reads only its comments'
    elif [[ "$rule" == retained-error ]]; then
      phase=close
      mutate_file "$TMP_ROOT/control-$rule/scripts/lib/mailbox-append.sh" \
        'owner_tracker_unwritten "$issue" "$OWNER_TRACKER_CAUSE" "$work/tracker.err"' \
        'owner_tracker_unwritten "$issue" "$OWNER_TRACKER_CAUSE"'
      assertion='a refused label retains tracker error bytes after close'
    elif [[ "$rule" == rollback-owner ]]; then
      phase=close
      mutate_file "$TMP_ROOT/control-$rule/scripts/lib/mailbox-append.sh" \
        'elif [[ "$owns_description" != true ]]; then' 'elif false; then'
      assertion='rollback preserves a later description and reports lost ownership'
    elif [[ "$rule" == comment-refused ]]; then
      phase=close
      mutate_file "$TMP_ROOT/control-$rule/scripts/lib/mailbox-append.sh" \
        "select(.success == true) | .data.comment.id" "select(true) | .data.comment.id"
      assertion='refused comment acknowledgements stay unposted and retain the response'
    else
      phase=settings
      mutate_file "$TMP_ROOT/control-$rule/scripts/lane-mail" \
        'refuse item-ask-unconfigured "$ISSUE"' ':'
      assertion='an item ask with label unset refuses by the key it lacks'
    fi
    control_rc=0
    MAILBOX_UNDER_TEST="$TMP_ROOT/control-$rule" "$BASH" "$ROOT/skills/mailbox/tests/owner-tracker.sh" "$phase" \
      >"$TMP_ROOT/control-$rule.log" 2>&1 || control_rc=$?
    assert_eq "$control_rc" 1 "control: removing $rule makes the writer suite fail"
    assert_file_contains "$TMP_ROOT/control-$rule.log" "FAIL  $assertion" "control: $rule reaches its contract assertion"
  done
fi
printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
