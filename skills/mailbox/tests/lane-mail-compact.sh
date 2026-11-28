#!/usr/bin/env bash
# Retention, stable logical numbering, and a writer waiting on the compacted inode.
# Inputs: skills/jarvis/scripts/**
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd -P)" || exit 1
# shellcheck source=../../orch/tests/lib/git-env.sh
source "$ROOT/skills/orch/tests/lib/git-env.sh"
# shellcheck source=../../orch/tests/lib/assertions.sh
source "$ROOT/skills/orch/tests/lib/assertions.sh"
TMP_ROOT="$(mktemp -d)" || { echo 'lane-mail-compact: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo 'lane-mail-compact: scratch=not-a-directory' >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo 'lane-mail-compact: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
rc=0
python3 "$ROOT/skills/mailbox/tests/lib/lane-mail-compact.py" "$ROOT" "$TMP_ROOT" || rc=$?
assert_eq "$rc" 0 'mailbox compaction contract and must-fail controls'
# An open replacement's exchange through compaction, against a stateful tracker.
REPLACE_FACTS="$(python3 "$ROOT/skills/mailbox/tests/lib/owner-replace.py" compact \
  "$ROOT/skills/mailbox" "$TMP_ROOT" "$BASH")"
assert_eq "$(jq -c 'with_entries(select(.key | startswith("error:")))' <<<"$REPLACE_FACTS")" '{}' \
  'the compaction replacement case runs to its observation'
assert_eq "$(jq '.replacement_retained' <<<"$REPLACE_FACTS")" true \
  "an open replacement keeps its predecessor's exchange and delivery rows, and an answer is delivered once"
assert_eq "$(jq '.aged_out_unrepeated' <<<"$REPLACE_FACTS")" true \
  'an unrelated closed ask on the item ages out, and its answer is not delivered again'

HOME_BOX="$TMP_ROOT/delegate"
ORIGIN="$TMP_ROOT/origin"
for fixture in "$HOME_BOX" "$ORIGIN"; do
  git init -q "$fixture"
  git -C "$fixture" config gc.auto 0
  git -C "$fixture" config maintenance.auto false
  mkdir -p "$fixture/tmp"
  printf '{"controller":{"server":"7000","pane":"%%0"}}\n' >"$fixture/tmp/workflow-state-oversee.json"
done
mail() { ( cd -- "$1" && shift && "$ROOT/skills/mailbox/scripts/lane-mail" "$@" --item overseer ); }
printf 'Which release can ship?\n' >"$TMP_ROOT/question"
printf 'Only the first.\n' >"$TMP_ROOT/reply"
ASK="$(mail "$ORIGIN" ask --to owner --options first,both --reserved --file "$TMP_ROOT/question")"
ASK="${ASK#id=}"
# A delegated exchange from before the hold. The installed commands still
# need to retain and deliver a reply already bound to it.
jq -cn --arg id "$ASK" '{id:($id+"-owner-presentation"), kind:"owner-presentation", re:$id,
  at:"2000-01-01T00:00:00Z", text:"", presenter:"jarvis-retention", reserved:true}' \
  >>"$ORIGIN/tmp/lane-mail/overseer/to-overseer.jsonl"
BOX="$HOME_BOX/tmp/lane-mail/overseer"
mkdir -p "$BOX"
mail "$ORIGIN" pending --to owner |
  jq -c --arg root "$ORIGIN" '{id:"jarvis-retention", kind:"notice", from:"overseer", to:"owner",
    at:"2000-01-01T00:00:00Z", text:"Please review.", presentation:{presenter:"jarvis-retention",
    route:{destination:"local",root:$root,ask:.id},question:{text,options,deadline,reserved}}}' >"$BOX/to-overseer.jsonl"
printf '{"ts":"1.000001","author":"bot","envelope":"jarvis-retention","excerpt":"Which release can ship?"}\n' >"$TMP_ROOT/parent"
mail "$HOME_BOX" send --directive --delivery-id C123:1.000002 --thread-ts 1.000001 \
  --parent "$TMP_ROOT/parent" --file "$TMP_ROOT/reply" >/dev/null
for file in "$BOX/to-overseer.jsonl" "$BOX/to-lane.jsonl"; do
  jq -c '.at="2000-01-01T00:00:00Z"' "$file" >"$TMP_ROOT/aged"
  mv -- "$TMP_ROOT/aged" "$file"
done
printf '1\n' >"$BOX/to-lane.cursor"
mail "$HOME_BOX" compact >/dev/null
assert_eq "$(mail "$HOME_BOX" events | jq -cs '
  [any(.[]; .kind == "notice" and .id == "jarvis-retention"),
   any(.[]; .kind == "directive" and .delivery_id == "C123:1.000002")]')" \
  '[true,true]' 'compaction retains a read reply and its binding while delivery is pending'
(cd -- "$HOME_BOX" && env -i HOME="$HOME_BOX" PATH="$PATH" XDG_CONFIG_HOME="$TMP_ROOT/config" XDG_DATA_HOME="$TMP_ROOT/data" \
  XDG_STATE_HOME="$TMP_ROOT/state" XDG_CACHE_HOME="$TMP_ROOT/cache" "$BASH" "$ROOT/skills/jarvis/scripts/jarvis-session" \
  owner-asks deliver --home "$HOME_BOX") >/dev/null
assert_eq "$(mail "$ORIGIN" events | jq -cs --arg id "$ASK" '
  [.[] | select(.kind == "answer" and .re == $id) | [.sender,.delivery_id,.text]]')" \
  '[["owner","C123:1.000002","Only the first."]]' 'the retained reply reaches the originating mailbox through the installed command'

printf '\npass: %s   fail: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
