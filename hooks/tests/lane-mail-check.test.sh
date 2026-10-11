#!/usr/bin/env bash
# lane-mail-check: a Stop hook that blocks a lane's turn end while its overseer
# mailbox holds unread lines, and through the lane-mail-deliver and
# lane-mail-halt hooks beside it hands them over after a tool call and refuses
# one while a halt stands. Every case builds a lane repository under
# TMP_ROOT, writes to its mailbox with the real `lane-mail`, and asserts the
# hook's exit status and the keyed first line of stderr. Copilot's rows are
# lane-mail-check-copilot.test.sh, over the same lib/lane-mail-world.sh.
# HOOK_UNDER_TEST overrides the script the must-fail controls at the end run
# against.
set -euo pipefail

# shellcheck source=lib/lane-mail-world.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/lane-mail-world.sh"

echo "=== lane-mail-check ==="

new_lane plain ken-1
stop
expect 2 "lane-mail-check: mailbox-missing=$LANE/tmp/lane-mail" \
  "a root its launch marker binds with no mailbox directory is refused, never passed"
unmark_lanes
stop
expect 0 - "a repository with no launch marker and no mailbox directory passes silently"
mkdir -p "$LANE/tmp/lane-mail/KEN-2"
stop
expect 0 - "a mailbox naming another item is not this branch's lane and passes silently"
git -C "$LANE" checkout -q --detach
stop
expect 0 - "a detached HEAD names no lane and passes silently"
# GIT_CEILING_DIRECTORIES stops discovery at TMP_ROOT, so this directory reads
# as no repository however the suite's own temp root was placed — a runner
# whose TMPDIR sits inside a checkout would otherwise resolve that checkout.
LANE="$TMP_ROOT/norepo"
CEILING=(GIT_CEILING_DIRECTORIES="$TMP_ROOT")
mkdir -p "$LANE"
stop "${CEILING[@]}"
expect 0 - "a directory git reports no repository for holds no mailbox and passes silently"
mkdir -p "$LANE/tmp/lane-mail/KEN-1"
stop "${CEILING[@]}"
expect 2 "lane-mail-check: git=-C $LANE rev-parse --show-toplevel --git-common-dir" \
  "a mailbox git can report no repository for is refused, never passed"

new_lane empty ken-3
mkdir -p "$LANE/tmp/lane-mail/KEN-3"
REPORT_ITEM=KEN-3
stop
expect 0 "$GAP" "a mailbox with no to-lane.jsonl ends the turn with only the account gap reported"
: > "$LANE/tmp/lane-mail/KEN-3/to-lane.jsonl"
stop
expect 0 "$GAP" "an empty mailbox ends the turn with only the account gap reported"

new_lane unread ken-4
send KEN-4 'Hold the PR until the owner answers.'
REPORT_ITEM=KEN-4
stop
expect 2 "lane-mail-check: unread=1" "unread mail refuses with the count on the first line"
assert_eq "$(cause_below)" "present" "the messages stand under the keyed line"
assert_eq "$(grep -c 'Hold the PR until the owner answers.' "$ERR_FILE")" "1" \
  "the refusal carries the message the overseer sent"
assert_eq "$(cat "$TMP_ROOT/stdout")" "" "the hook writes nothing to stdout"
stop
expect 0 "$GAP" "a second stop passes: the reader advanced the cursor past what it handed over"

send KEN-4 'And rebase first.'
send KEN-4 'Then re-arm auto-merge.'
stop
expect 2 "lane-mail-check: unread=2" "two new messages refuse once, naming both"

# Killed right after its Nth reader call, as a harness kills a hook at its
# budget, the hook has shown the directive or left it unread, never consumed it
# unseen. KILLED is shown, kept (the next stop reports it) or lost.
killed_stop() { # NAME ITEM N [HOOK]
  local calls="$TMP_ROOT/$1.calls"
  new_lane "$1" "$(printf '%s' "$2" | tr 'A-Z' 'a-z')"
  [ -z "${4:-}" ] || install_hook "$4" "$LANE/.claude/hooks/lane-mail-check.sh"
  send "$2" 'Survive the budget.'
  rm -f "$LANE/.claude/skills/orch"
  mkdir -p "$LANE/.claude/skills/orch/scripts"
  printf '#!/usr/bin/env bash\nrc=0\n"%s" "$@" || rc=$?\nn=$(( $(cat "%s" 2>/dev/null || echo 0) + 1 ))\necho "$n" > "%s"\n[ "$n" -ne %s ] || kill -9 "$PPID"\nexit "$rc"\n' \
    "$LANE_MAIL" "$calls" "$calls" "$3" > "$LANE/.claude/skills/orch/scripts/lane-mail"
  chmod +x "$LANE/.claude/skills/orch/scripts/lane-mail"
  plant_siblings "$LANE/.claude/skills/orch/scripts"
  KILLED=lost
  stop
  if grep -q '^lane-mail-check: unread=1$' "$ERR_FILE"; then
    KILLED=shown
  else
    stop
    [ "$(first_line)" != 'lane-mail-check: unread=1' ] || KILLED=kept
  fi
}
for row in 1:kept 2:shown; do
  killed_stop "killed${row%%:*}" "KEN-1$((6 + ${row%%:*}))" "${row%%:*}"
  assert_eq "$KILLED" "${row#*:}" "a hook killed after reader call ${row%%:*} loses no directive"
done

# A launch makes a lane: a mailbox a repository carries with no launch marker,
# or with one bound to another root, is no lane.
unlaunched() { # NAME ITEM MARKER-CONTENT [HOOK] — empty content removes the marker
  new_lane "$1" "$(printf '%s' "$2" | tr 'A-Z' 'a-z')"
  [ -z "${4:-}" ] || install_hook "$4" "$LANE/.claude/hooks/lane-mail-check.sh"
  send "$2" 'Pose as a lane.'
  local marker
  marker="$LANE/.git/lane-mail/$(printf '%s' "$2" | tr 'A-Z' 'a-z')"
  rm -f "$marker"
  [ -z "$3" ] || printf '%s\n' "$3" > "$marker"
  stop
}
unlaunched unmarked KEN-20 ""
expect 0 - "a mailbox with no launch marker is no lane and passes silently"
unlaunched rebound KEN-21 "$TMP_ROOT/another-root"
expect 0 - "a launch marker bound to another root is no lane and passes silently"

# Anything present at to-lane.jsonl in a launched lane reaches the reader,
# whose component rule refuses it: never passed as a mailbox with no file.
for row in dir:ken-23 link:ken-24; do
  new_lane "unsafe_${row%%:*}" "${row#*:}"
  box="$LANE/tmp/lane-mail/$(printf '%s' "${row#*:}" | tr 'a-z' 'A-Z')"
  mkdir -p "$box"
  case "${row%%:*}" in
    dir) mkdir "$box/to-lane.jsonl" ;;
    link) ln -s "$TMP_ROOT/nowhere" "$box/to-lane.jsonl" ;;
  esac
  stop
  assert_eq "RC=$RC first=$(first_line) cause=$(grep -c "^lane-mail: mailbox-unsafe=$box/to-lane.jsonl\$" "$ERR_FILE")" \
    "RC=2 first=lane-mail-check: inbox=2 cause=1" "a ${row%%:*} at to-lane.jsonl in a launched lane is refused, never passed"
done

# A marker present but not a plain file is refused, never read as no lane.
new_lane marker_dir ken-25
send KEN-25 'Behind a marker that is a directory.'
rm -f "$LANE/.git/lane-mail/ken-25"
mkdir "$LANE/.git/lane-mail/ken-25"
stop
expect 2 "lane-mail-check: marker=$LANE/.git/lane-mail/ken-25" "a marker path that is a directory is refused, never read as no lane"

new_lane named ken-6
mark_lane OTHER-1
send OTHER-1 'Brief-named mailbox.'
stop
expect 0 - "a mailbox the branch does not name is not read without LANE_MAIL_ITEM"
stop LANE_MAIL_ITEM=OTHER-1
expect 2 "lane-mail-check: unread=1" "LANE_MAIL_ITEM selects the lane's mailbox whatever the branch is"
stop LANE_MAIL_ITEM=../escape
expect 2 "lane-mail-check: item=invalid" "an item outside its alphabet is refused rather than resolved to a path"

if [ "${CASE_SENSITIVE:?}" -eq 1 ]; then
  new_lane ambiguous ken-7
  mkdir -p "$LANE/tmp/lane-mail/KEN-7" "$LANE/tmp/lane-mail/ken-7"
  stop
  expect 2 "lane-mail-check: item=ambiguous" "two mailboxes lowercasing to one branch decide nothing and are refused"
else
  printf '  skip  two mailboxes lowercasing to one branch: this filesystem is case-insensitive, so the second name is the first mailbox\n'
fi

new_lane noreader ken-8
send KEN-8 'unreachable'
rm -f "$LANE/.claude/skills/orch" "$LANE/.agents/skills/orch/scripts"
stop
expect 2 "lane-mail-check: reader=$LANE/.agents/skills/orch/scripts/lane-mail" \
  "a mailbox with no reader beside it is refused, never passed"

# The repository supplies a reader and the hook is installed nowhere near it.
# The hook's own install is the only place a reader may come from; otherwise a
# repository hands this hook a command to run at every turn end.
new_lane planted ken-12
send KEN-12 'run me'
MARKER="$TMP_ROOT/planted-ran"
plant_reader "$MARKER"
install_hook "$HOOK" "$TMP_ROOT/elsewhere/hooks/lane-mail-check.sh"
stop
expect 2 "lane-mail-check: reader-outside=$LANE/.agents/skills/orch/scripts/lane-mail" \
  "a reader the open repository supplies is refused where the hook is installed outside it"
assert_eq "$([ -e "$MARKER" ] && echo ran || echo not-run)" "not-run" "the repository's own script never runs"

if [ "${CAN_DENY_READS:?}" -eq 1 ]; then
  new_lane unreadable ken-9
  send KEN-9 'sealed'
  chmod 000 "$LANE/tmp/lane-mail/KEN-9/to-lane.jsonl"
  stop
  chmod 644 "$LANE/tmp/lane-mail/KEN-9/to-lane.jsonl"
  expect 2 "lane-mail-check: inbox=2" "a mailbox that cannot be read is refused with the reader's status"
  assert_eq "$(grep -c '^lane-mail: file-unreadable=' "$ERR_FILE")" "1" \
    "the reader's own keyed line is replayed under the hook's"
else
  printf '  skip  a mailbox that cannot be read: running as root, which reads a mode-000 file\n'
  printf '  skip  the reader keyed line under the hook s: running as root, which reads a mode-000 file\n'
fi

new_lane payload ken-10
send KEN-10 'x'
run_payload 'not json'
expect 2 "lane-mail-check: payload=invalid-json" "a payload that is not JSON is refused rather than skipped"
REPORT_ITEM=KEN-10
run_payload '{"stop_hook_active":true}'
expect 0 "$GAP" "the turn the harness already continued is not blocked again"


# A refusal the lane cannot clear repeats at every turn end for as long as its
# cause stands. The turn the harness already continued skips the mailbox check
# whole and reports what it could not settle instead of refusing it again, so
# the session can end. Three causes, each refused once and then reported.
new_lane continued_reader ken-61
send KEN-61 'unreachable'
rm -f "$LANE/.claude/skills/orch" "$LANE/.agents/skills/orch/scripts"
NO_READER="$LANE/.agents/skills/orch/scripts/lane-mail"
stop
expect 2 "lane-mail-check: reader=$NO_READER" "a fresh turn refuses a mailbox it has no reader for"
stop_active
expect 0 "lane-mail-check: handoff-skipped=$NO_READER" \
  "the continued turn reports the same missing install and ends"

new_lane continued_item ken-62
mkdir -p "$LANE/tmp/lane-mail/KEN-62"
stop LANE_MAIL_ITEM='bad item!'
expect 2 "lane-mail-check: item=invalid" "a fresh turn refuses an item outside its alphabet"
stop_active LANE_MAIL_ITEM='bad item!'
expect 0 "lane-mail-check: item=invalid" "the continued turn reports the invalid item and ends"

if [ "${CASE_SENSITIVE:?}" -eq 1 ]; then
  new_lane continued_ambiguous ken-63
  mkdir -p "$LANE/tmp/lane-mail/KEN-63" "$LANE/tmp/lane-mail/ken-63"
  stop
  expect 2 "lane-mail-check: item=ambiguous" "a fresh turn refuses a branch two mailboxes lowercase to"
  stop_active
  expect 0 "lane-mail-check: item=ambiguous" "the continued turn reports the ambiguity and ends"
else
  printf '  skip  a continued turn after an ambiguous item: this filesystem is case-insensitive\n'
fi

# A global install: the hook under a fake home, the orch skill in that home's
# shared tree, the open repository elsewhere. Claude is two deep, Pi four.
global_home() { # NAME — a fake home with the shared reader in it
  GLOBAL_HOME="$TMP_ROOT/$1"
  mkdir -p "$GLOBAL_HOME/.agents/skills/orch"
  ln -s -f -n "$REPO_ROOT/skills/orch/scripts" "$GLOBAL_HOME/.agents/skills/orch/scripts"
}

for hookdir in .claude/hooks .pi/agent/kendex/hooks; do
  new_lane "global-${hookdir%%/*}" ken-14
  send KEN-14 'Reached the global install.'
  rm -f "$LANE/.claude/skills/orch" "$LANE/.agents/skills/orch/scripts"
  global_home "home-${hookdir%%/*}"
  install_hook "$HOOK" "$GLOBAL_HOME/$hookdir/lane-mail-check.sh"
  stop "HOME=$GLOBAL_HOME"
  expect 2 "lane-mail-check: unread=1" "a global install under $hookdir reads its own shared skill tree"
done

# A harness root outside the home directory, which CODEX_HOME and
# PI_CODING_AGENT_DIR make: the walk climbs ancestors kendex installed nothing
# under, and the home's own shared tree is what still holds the reader.
new_lane relocated ken-16
send KEN-16 'Reached the relocated root.'
rm -f "$LANE/.claude/skills/orch" "$LANE/.agents/skills/orch/scripts"
global_home home-relocated
install_hook "$HOOK" "$TMP_ROOT/opt/codex/hooks/lane-mail-check.sh"
stop "HOME=$GLOBAL_HOME"
expect 2 "lane-mail-check: unread=1" \
  "a harness root outside the home reads the home's own shared tree"

# The refusal removed and nothing else: the hook still reads the mailbox and
# advances the cursor, so a control that deleted the read instead would prove
# the assertion runs rather than that the block does.
# Sets MUTANT_PATH rather than printing it: the assertion below writes to the
# same stdout a substitution would capture.
MUTANT_PATH=""

# --- the handoff marks ---------------------------------------------------
#
# A lane hands itself off at the context mark and at its account's wall, so no
# overseer has to read a pane for it. Every row here is a turn end on a lane
# with an empty mailbox, which is the path the marks are judged on.

# A lane whose mailbox holds nothing, so each row below judges the marks alone.
# The mailbox directory is what `write_lane_marker` makes at launch beside the
# marker, so a lane nobody has messaged still carries the name the hook
# resolves the marks by; open-terminal-lane-pick.sh asserts the launcher makes it.
# The lane reports a step before each turn end, so the idle judge after the
# marks passes it; the idle rows clear REPORT_ITEM.
new_handoff_lane() { # NAME ITEM
  new_lane "$1" "$(printf '%s' "$2" | tr 'A-Z' 'a-z')"
  mkdir -p "$LANE/tmp/lane-mail/$2"
  (cd "$LANE" && "$REPO_ROOT/skills/orch/scripts/workflow-state" init "$2" >/dev/null)
  REPORT_ITEM="$2"
}

# The record's fields, the durable recovery state a relaunch reads. One list:
# the refusal's template is checked against it and the record below is built
# from it, so a field leaving either side reddens. `written_at` is not among
# them: `workflow-state set` stamps the record's time from its own clock, so a
# lane cannot hand it one that names a moment the clock has not reached.
HANDOFF_FIELDS='merged,remaining,branch,worktree,open_pr,traps'

# The keys of the JSON template the refusal told the lane to write, in order.
template_fields() {
  sed -n "s/.*handoff '\\({.*}\\)'.*/\\1/p" "$ERR_FILE" |
    grep -o '"[a-z_]*":' | tr -d '":' | tr '\n' ',' | sed 's/,$//'
}

# The record the lane writes at the safe point, and the field a relaunch sets
# on it once the item is resumed. Nothing reads the values, only the shape.
# STATE_DIR is the `--state-dir` the lane's orch commands pass, where they pass
# one.
record_handoff() { # ITEM [RESUMED_AT] [STATE_DIR]
  local value
  value="$(printf '%s' "$HANDOFF_FIELDS" | tr ',' '\n' | jq -Rn --arg r "${2:-}" \
    '([inputs | {key: ., value: "x"}] | from_entries)
     | if $r == "" then . else .resumed_at = $r end')"
  (cd "$LANE" && "$REPO_ROOT/skills/orch/scripts/workflow-state" ${3:+--state-dir "$3"} set "$1" handoff "$value" >/dev/null)
}

TRANSCRIPT="$TMP_ROOT/transcript.jsonl"

new_handoff_lane handoff_context KEN-50
write_transcript "$TRANSCRIPT" 399999
stop_at "$TRANSCRIPT" false
expect 0 "$GAP" "a lane under the context mark ends its turn"
write_transcript "$TRANSCRIPT" 500000
stop_at "$TRANSCRIPT" false
expect 2 "lane-mail-check: context=500000" "a lane at the context mark is refused with the figure it reached"
assert_eq "$(grep -cF -- " set KEN-50 handoff " "$ERR_FILE")" "1" \
  "the refusal names the one command that writes the record"
assert_eq "$(template_fields)" "$HANDOFF_FIELDS" \
  "the record template it names carries every field a relaunch reads"
assert_eq "$(template_fields | tr ',' '\n' | grep -cx written_at || true)" "0" \
  "and asks the lane for no written_at, which the set stamps"
assert_eq "$(grep -cF -- "lane-mail notice --item KEN-50 --file" "$ERR_FILE")" "1" \
  "the refusal names the handoff notice beside it"
stop_at "$TRANSCRIPT" true
expect 2 "lane-mail-check: context=500000" \
  "the refusal repeats on the continued turn, where the mailbox check does not"
record_handoff KEN-50
stop_at "$TRANSCRIPT" false
expect 0 - "a lane whose handoff record stands ends its turn past the mark"
stop_at "$TMP_ROOT/absent.jsonl" false
expect 0 - "the record is judged before every read the marks rest on, so no failed read traps a lane that recorded one"
record_handoff KEN-50 2026-09-18T09:00:00Z
stop_at "$TRANSCRIPT" false
expect 2 "lane-mail-check: context=500000" \
  "a record a relaunch resumed belongs to an earlier life and does not clear the mark"

# A lane in a worktree whose orch commands all pass `--state-dir <worktree>/tmp`,
# as a launch forbidding writes to the main checkout makes it, past the context
# mark with no record yet. The hook runs from the main clone, as a hosted Pi
# lane's does, so only the root its launch marker binds names the worktree.
# HOOK, where named, is the copy it runs.
worktree_handoff_lane() { # NAME ITEM [HOOK]
  new_worktree_lane "$1" "$(printf '%s' "$2" | tr 'A-Z' 'a-z')"
  [ -z "${3:-}" ] || install_hook "$3" "$LANE/.claude/hooks/lane-mail-check.sh"
  mkdir -p "$LANE/tmp/lane-mail/$2"
  (cd "$LANE" && "$REPO_ROOT/skills/orch/scripts/workflow-state" --state-dir "$LANE/tmp" init "$2" >/dev/null)
  REPORT_ITEM="$2"
  CALL_DIR="$MAIN"
  write_transcript "$TRANSCRIPT" 500000
}
worktree_set_named() { # ITEM — the set line naming the worktree tmp, and any init line
  printf 'set=%s init=%s' "$(grep -cF -- " --state-dir $LANE/tmp set $1 handoff " "$ERR_FILE")" \
    "$(grep -cF -- " init $1" "$ERR_FILE")"
}

worktree_handoff_lane handoff_worktree_state KEN-441
stop_at "$TRANSCRIPT" false LANE_MAIL_ITEM=KEN-441
assert_eq "RC=$RC first=$(first_line) $(worktree_set_named KEN-441)" \
  "RC=2 first=lane-mail-check: context=500000 set=1 init=0" \
  "a worktree lane with its record in neither place is refused, told to write it in its worktree's tmp with no init"
record_handoff KEN-441 "" "$LANE/tmp"
stop_at "$TRANSCRIPT" false LANE_MAIL_ITEM=KEN-441
assert_eq "RC=$RC first=$(first_line) main=$([ -e "$MAIN/tmp/workflow-state-KEN-441.json" ] && echo record || echo none)" \
  "RC=0 first=- main=none" \
  "a handoff record in the worktree's tmp, with none in the main clone, ends the turn past the mark"
# A killed write in the worktree's tmp is reported with that file named, not
# read as the none the main clone answers.
worktree_handoff_lane handoff_worktree_unreadable KEN-443
printf '{"handoff":' > "$LANE/tmp/workflow-state-KEN-443.json"
stop_at "$TRANSCRIPT" false LANE_MAIL_ITEM=KEN-443
assert_eq "RC=$RC first=$(first_line)" \
  "RC=0 first=lane-mail-check: handoff-unreadable=$LANE/tmp/workflow-state-KEN-443.json" \
  "a worktree state file the verb could not read is reported under its own key, naming that file"
CALL_DIR=""

# The figure is the LAST usage line, so a compaction that reset the window
# reads as the reset it is, and the window the tail read opens on can end
# mid-line without changing the answer.
new_handoff_lane handoff_last_line KEN-71
write_transcript "$TRANSCRIPT" 600000
append_transcript "$TRANSCRIPT" 1000
stop_at "$TRANSCRIPT" false
expect 0 "$GAP" "a transcript whose first usage line is past the mark and whose last is under it ends the turn"
write_transcript "$TRANSCRIPT" 1000
append_transcript "$TRANSCRIPT" 600000
printf '{"type":"assistant","message":{"usa' >> "$TRANSCRIPT"
stop_at "$TRANSCRIPT" false
expect 2 "lane-mail-check: context=600000" \
  "the last complete usage line is the figure, and the fragment the harness is still writing is skipped"
# The payload's three fields are joined on TAB, so a path holding a space is
# one field and not two.
SPACED="$TMP_ROOT/a transcript.jsonl"
write_transcript "$SPACED" 600000
stop_at "$SPACED" false
expect 2 "lane-mail-check: context=600000" "a transcript path holding a space is read, never truncated at it"

# Each real install selects its adapter and records the reading. The table
# covers both independent limits, unknown capacity and equality. Output tokens
# make the percentage rows cross their mark; omitting them leaves room.
#
#   HOOK DIR|SPELLING|TOKENS|PAYLOAD WINDOW|FIRST LINE|RECORDED
ADAPTER_ROWS='.claude/hooks|claude|399999||GAP|claude 399999 1000000
.claude/hooks|claude|400000||context=400000|claude 400000 1000000
.claude/hooks|claude|500000||context=500000|claude 500000 1000000
.claude/hooks|sonnet|399999||window-unread=claude-sonnet-4-6|claude 399999 null
.claude/hooks|sonnet|400000||context=400000|claude 400000 null
.codex/hooks|codex|232560||GAP|codex 232560 258400
.codex/hooks|codex|232561||context=232561|codex 232561 258400
.pi/kendex/hooks|pi|180000|200000|GAP|pi 180000 200000
.pi/kendex/hooks|pi|180001|200000|context=180001|pi 180001 200000
.pi/kendex/hooks|pi|399999||window-unread=pi-claude/m|pi 399999 null
.pi/kendex/hooks|pi|400000||context=400000|pi 400000 null'
new_handoff_lane handoff_adapters KEN-90
while IFS='|' read -r ROW_DIR ROW_SPELLING ROW_TOKENS ROW_WINDOW ROW_FIRST ROW_RECORDED; do
  install_hook "$HOOK" "$LANE/$ROW_DIR/lane-mail-check.sh"
  usage_line "$ROW_SPELLING" "$ROW_TOKENS" > "$TRANSCRIPT"
  rm -f -- "${LANE:?}/tmp/lane-mail/KEN-90/context.json"
  CONTEXT_PCT_ENV='' run_payload "$(jq -nc --arg p "$TRANSCRIPT" --arg w "$ROW_WINDOW" \
    '{session_id:"s1",stop_hook_active:false,transcript_path:$p}
     + (if $w == "" then {} else {context_window: ($w | tonumber)} end)')"
  case "$ROW_FIRST" in
    GAP) ROW_WANT="RC=0 first=$GAP" ;;
    context=*) ROW_WANT="RC=2 first=lane-mail-check: $ROW_FIRST" ;;
    *) ROW_WANT="RC=0 first=lane-mail-check: $ROW_FIRST" ;;
  esac
  assert_eq "RC=$RC first=$(first_line) recorded=$(jq -r '"\(.harness) \(.tokens) \(.window)"' \
      "$LANE/tmp/lane-mail/KEN-90/context.json" 2>/dev/null)" \
    "$ROW_WANT recorded=$ROW_RECORDED" \
    "$ROW_SPELLING under $ROW_DIR at $ROW_TOKENS tokens of window ${ROW_WINDOW:-its adapter reads}: $ROW_FIRST, recorded for the report"
done <<<"$ADAPTER_ROWS"
# An unreadable configuration cannot erase the independent cap. The hook
# exposes the cause beside the retained reading instead of calling it room.
install_hook "$HOOK" "$LANE/.pi/kendex/hooks/lane-mail-check.sh"
printf 'not-json\n' > "$OFFLINE_HOME/.pi/agent/settings.json"
usage_line pi 400000 > "$TRANSCRIPT"
run_payload "$(jq -nc --arg p "$TRANSCRIPT" \
  '{session_id:"s1",stop_hook_active:false,transcript_path:$p,context_window:200000}')"
assert_eq "$RC|$(first_line)|$(grep -c '^lane-mail-check: context=400000$' "$ERR_FILE")|$(jq -c '[.tokens,.window]' "$LANE/tmp/lane-mail/KEN-90/context.json")" \
  '2|lane-mail-check: compaction-unread=pi|1|[400000,null]' \
  'a broken Pi configuration retains the cap reading and reports the settings failure'
printf '%s\n' '{"compaction":{"enabled":false}}' > "$OFFLINE_HOME/.pi/agent/settings.json"
install_hook "$HOOK" "$LANE/.claude/hooks/lane-mail-check.sh"

# A usage object the adapter does not read. The figure IS there and unread, which
# is not the documented gap a payload naming no transcript leaves, so it gets
# its own key rather than the silence that gap takes. The turn still ends: no
# handoff record the lane writes would teach this install a harness's field
# names, so holding it would be a refusal nothing the lane does could clear.
new_handoff_lane handoff_unread_usage KEN-91
usage_line unread 900000 > "$TRANSCRIPT"
stop_at "$TRANSCRIPT" false
assert_eq "RC=$RC first=$(first_line) judged=$(grep -c 'context=' "$ERR_FILE")" \
  "RC=0 first=lane-mail-check: usage-unread=$TRANSCRIPT judged=0" \
  "a usage object neither spelling reads is keyed, never summed to a figure the mark is judged on"
assert_eq "$(grep -c 'none of the field names' "$ERR_FILE")" "1" \
  "and the key carries the English that says why the figure went unread"
assert_eq "$(grep -cx "$GAP" "$ERR_FILE")" "1" \
  "and the account mark beside it is judged as it is on any other turn end"

new_handoff_lane handoff_setting KEN-51
write_transcript "$TRANSCRIPT" 500000
stop_at "$TRANSCRIPT" false ORCH_HANDOFF_CONTEXT_PCT=90
expect 2 "lane-mail-check: context=500000" "a raised percentage keeps the independent absolute cap"
CONTEXT_PCT_ENV='' stop_at "$TRANSCRIPT" false
expect 2 "lane-mail-check: context=500000" "the package default keeps the independent absolute cap"
# orch-env falls back to its default only on a NON-numeric value, so a value
# in a shape no comparison can take reaches the hook and is named here.
for VALUE in 050 101 0; do
  stop_at "$TRANSCRIPT" false "ORCH_HANDOFF_CONTEXT_PCT=$VALUE"
  assert_eq "RC=$RC first=$(first_line) named=$(grep -cF -- " set KEN-51 handoff " "$ERR_FILE")" \
    "RC=2 first=lane-mail-check: setting-range=ORCH_HANDOFF_CONTEXT_PCT=$VALUE named=1" \
    "a context mark of $VALUE, outside whole percents 1 to 100, names the value, and the record clears it"
done

new_handoff_lane handoff_subagent KEN-52
write_transcript "$TRANSCRIPT" 800000
run_payload "$(jq -nc --arg p "$TRANSCRIPT" \
  '{session_id:"s1",stop_hook_active:false,agent_id:"a1",transcript_path:$p}')"
expect 0 - "a subagent runs its own window and is judged on neither mark"

new_handoff_lane handoff_no_transcript KEN-53
stop
expect 0 "$GAP" "a payload naming no transcript leaves the context unread and passes"
stop_at "$TMP_ROOT/absent.jsonl" false
assert_eq "RC=$RC first=$(first_line) named=$(grep -cF -- " set KEN-53 handoff " "$ERR_FILE")" \
  "RC=2 first=lane-mail-check: transcript=unreadable named=1" \
  "a transcript the payload names and nothing can read is refused, with the record that clears it"

# The settings loader sources .env.local as shell, and every orch script this
# hook runs loads it. A file a person has broken therefore stops the state read
# first, with a status the verb never gives, so the gap is reported with the
# loader's own words and the turn ends rather than the lane being held on a
# fault no handoff record clears. The key says the script is THERE and did not
# answer, never that it is missing: the repair is a settings line, and an
# operator sent to reinstall an installed skill never finds it.
new_handoff_lane handoff_setting_unreadable KEN-78
printf 'this is ( not shell\n' > "$LANE/.env.local"
write_transcript "$TRANSCRIPT" 600000
stop_at "$TRANSCRIPT" false
assert_eq "RC=$RC first=$(first_line) cause=$(grep -c 'syntax error' "$ERR_FILE") said=$(grep -c 'is there but did not answer' "$ERR_FILE")" \
  "RC=0 first=lane-mail-check: handoff-unanswered=$LANE/.claude/skills/orch/scripts/workflow-state cause=1 said=1" \
  "a settings file that will not load is reported with the loader's words and the turn ends"
assert_eq "$(grep -c 'is not there' "$ERR_FILE")" "0" \
  "and is never reported as an install that is not there"

# The verb's own status 2: a state file it cannot read. Its header and --help
# publish 2 as attributable, so it is told apart from an install that does not
# carry the verb at all — the repair for one is a state file, for the other an
# install — and the reader's own words, which name the file, stand under it.
# Driven against the real verb, on the file shape a killed write leaves: a
# truncated document, which is the shape jq reports WITHOUT naming the file it
# came from. So the key carries the path the `path` verb answers rather than
# resting on the reader's words, and this row is what holds it to that.
new_handoff_lane handoff_unreadable_state KEN-86
STATE_FILE="$(cd "$LANE" && "$REPO_ROOT/skills/orch/scripts/workflow-state" path KEN-86)"
printf '{"handoff":' > "$STATE_FILE"
write_transcript "$TRANSCRIPT" 600000
stop_at "$TRANSCRIPT" false
assert_eq "RC=$RC first=$(first_line) cause=$(grep -c 'jq: parse error' "$ERR_FILE")" \
  "RC=0 first=lane-mail-check: handoff-unreadable=$STATE_FILE cause=1" \
  "a state file the verb could not read is reported under its own key, naming the file"
assert_eq "$(grep -F 'jq: parse error' "$ERR_FILE" | grep -cF "$STATE_FILE")" "0" \
  "and the reader's own words name no file for this shape, which is why the key carries it"

# A sibling the marks need that is there and answers non-zero: the record still
# clears it, so it is refused with the setting named and its words under it.
new_handoff_lane handoff_setting_broken KEN-85
plant_install orch-env
printf '#!/bin/sh\nprintf "orch-env: broken\\n" >&2\nexit 1\n' \
  > "$LANE/.claude/skills/orch/scripts/orch-env"
chmod +x "$LANE/.claude/skills/orch/scripts/orch-env"
write_transcript "$TRANSCRIPT" 600000
stop_at "$TRANSCRIPT" false
assert_eq "RC=$RC first=$(first_line) cause=$(grep -cx 'orch-env: broken' "$ERR_FILE") named=$(grep -cF -- " set KEN-85 handoff " "$ERR_FILE")" \
  "RC=2 first=lane-mail-check: setting=ORCH_HANDOFF_CONTEXT_PCT cause=1 named=1" \
  "a mark whose setting could not be read is refused with the reader's words and the record that clears it"

# The read is bounded to the last TRANSCRIPT_WINDOW bytes, and falls back to
# the whole file where that window carries no usage line — a session whose
# recent megabyte is all tool results. Both halves need a transcript larger
# than the window, so the copy shortens the window instead of the fixture
# growing to a megabyte.
variant short-window -e 's@^TRANSCRIPT_WINDOW=1048576$@TRANSCRIPT_WINDOW=512@'
WINDOW_HOOK="$VARIANT_PATH"
# filler PATH BYTES — lines the usage read skips, so a row can put a usage line
# on either side of the window.
filler() { # PATH BYTES
  jq -nc --arg p "$(head -c "$2" /dev/zero | tr '\0' 'x')" '{type:"user",text:$p}' >> "$1"
}

new_handoff_lane handoff_window KEN-83
install_hook "$WINDOW_HOOK" "$LANE/.claude/hooks/lane-mail-check.sh"
write_transcript "$TRANSCRIPT" 600000
filler "$TRANSCRIPT" 2000
stop_at "$TRANSCRIPT" false
expect 2 "lane-mail-check: context=600000" \
  "a usage line before the window is found by the read of the whole file behind it"
assert_eq "$(grep -c 'usage-unread' "$ERR_FILE")" "0" \
  "and a window holding no usage line resolves through that read, never under the unread-usage key"
write_transcript "$TRANSCRIPT" 1000
filler "$TRANSCRIPT" 2000
append_transcript "$TRANSCRIPT" 600000
stop_at "$TRANSCRIPT" false
expect 2 "lane-mail-check: context=600000" \
  "a usage line inside the window is found without reading the whole file"

# The account mark, measured through the credential the lane runs on. The
# standard home is shared with the orch suites, so both accounts are staged
# HERE rather than there: neutralclaude AT the default mark this hook judges, and
# eclaude one point above it. claude has 80 and is room.
#
# The pair is what pins the number. The refusal key carries the account's
# measured headroom and not the threshold, so the neutralclaude row alone is green
# for any mark at or above it; eclaude ends its turn at this default and is
# refused by the one it replaced, so a mark that drifts back reddens here.
source "$REPO_ROOT/skills/orch/tests/lib/lanes-fixture.sh"
standard_home handoff-accounts
claude_usage 5 97 12 Opus > "$FIXTURE_DIR/.neutralclaude.json"
claude_usage 5 96 12 Opus > "$FIXTURE_DIR/.eclaude.json"
FETCHER="$TMP_ROOT/handoff-fetch"
make_fetcher "$FETCHER"
account_env() { # LANE-DIR-NAME
  printf '%s\n' "LANES_HOME=$H" "ORCH_LANES_FETCH_CMD=$FETCHER" "FIXTURE_DIR=$FIXTURE_DIR" \
    "CLAUDE_CONFIG_DIR=$H/$1"
}

# Claude Code names the model in its usage line; the usage API scopes Fable
# separately from the shared session and weekly windows.
make_lane "$H" fableclaude 3600
claude_usage 0 65 100 Fable > "$FIXTURE_DIR/.fableclaude.json"
make_lane "$H" weekclaude 3600
claude_usage 0 100 100 Fable > "$FIXTURE_DIR/.weekclaude.json"
# MODEL|ACCOUNT|RC|FIRST LINE
CLAUDE_ACCOUNT_ROWS='claude-opus-5-5|.fableclaude|0|-
claude-fable-5-1|.fableclaude|2|lane-mail-check: headroom=0
claude-opus-5-5|.weekclaude|2|lane-mail-check: headroom=0
|.fableclaude|2|lane-mail-check: headroom=0'
new_handoff_lane handoff_claude_model KEN-54
while IFS='|' read -r model account status first; do
  if [ -n "$model" ]; then
    usage_line claude 1000 | jq -c --arg m "$model" '.message.model = $m' > "$TRANSCRIPT"
  else
    printf '%s\n' '{"type":"user","message":{"role":"user","content":"Start"}}' > "$TRANSCRIPT"
  fi
  # shellcheck disable=SC2046
  stop_at "$TRANSCRIPT" false $(account_env "$account")
  expect "$status" "$first" "Claude model [$model] reads $account through its own windows"
done <<< "$CLAUDE_ACCOUNT_ROWS"

# Keep --model in the copy while removing its assignment. The Opus row then
# fails: a full Fable window forces a handoff on a model with room.
wake_mutant claude-model-unassigned \
  '    PICK_MODEL=(--model "$(lane_context_mark_model claude "$MODEL")")' \
  '    : # PICK_MODEL=(--model "$(lane_context_mark_model claude "$MODEL")")'
new_handoff_lane control_claude_model KEN-54
install_hook "$MUTANT_PATH" "$LANE/.claude/hooks/lane-mail-check.sh"
write_transcript "$TRANSCRIPT" 1000
# shellcheck disable=SC2046
stop_at "$TRANSCRIPT" false $(account_env .fableclaude)
expect 2 "lane-mail-check: headroom=0" "control: the unassigned model reads the full Fable window"
control_status=0
(
  FAIL=0
  expect 0 - "Claude model [claude-opus-5-5] reads .fableclaude through its own windows"
  [ "$FAIL" -eq 0 ]
) > "$TMP_ROOT/claude-model.control.log" || control_status=$?
assert_eq "$control_status" 1 "control: without the model assignment the Opus row turns red"

new_handoff_lane handoff_headroom KEN-54
write_transcript "$TRANSCRIPT" 1000
# shellcheck disable=SC2046
stop_at "$TRANSCRIPT" false $(account_env .claude)
expect 0 - "a lane on an account with room ends its turn"
# shellcheck disable=SC2046
stop_at "$TRANSCRIPT" false $(account_env .neutralclaude)
expect 2 "lane-mail-check: headroom=3" "a lane at its account's handoff mark is refused with the headroom left"
assert_eq "$(grep -cF -- " set KEN-54 handoff " "$ERR_FILE")" "1" \
  "the account refusal carries the same instruction as the context refusal"
# shellcheck disable=SC2046
stop_at "$TRANSCRIPT" false $(account_env .neutralclaude) ORCH_HANDOFF_HEADROOM_PCT=1
expect 0 - "a mark the setting lowers leaves the same account with room"
# shellcheck disable=SC2046
stop_at "$TRANSCRIPT" false $(account_env .eclaude)
expect 0 - "an account one point above the mark ends its turn, which the mark this default replaced would refuse"
# The mark reads the account's wall, never the projection a launch is judged
# on: the lane's own claim is among the ones charged, so a projection would
# send every lane on a busy account to hand off with room left. sclaude reads
# 80 percent headroom on its 5-hour window, the one the whole default burn is
# charged against; its four live claims at 30 an hour each project -40.
make_lane "$H" sclaude 3600
claude_usage 20 10 5 Opus > "$FIXTURE_DIR/.sclaude.json"
HANDOFF_CLAIMS="$TMP_ROOT/handoff-claims"
mkdir -p "$HANDOFF_CLAIMS/claims"
for pane in 1 2 3 4; do
  printf '%s\t%%%s\t%s\tken-%s\t2026-09-28T00:00:00Z\t\n' "$$" "$pane" "$H/.sclaude" "$pane" \
    > "$HANDOFF_CLAIMS/claims/$pane.claim"
done
# shellcheck disable=SC2046
stop_at "$TRANSCRIPT" false $(account_env .sclaude) "OVERSEE_WATCH_STATE_DIR=$HANDOFF_CLAIMS" ORCH_LANE_BURN_PCT_PER_HOUR=30
expect 0 - "a lane on an account with room ends its turn though the lanes on it project past the mark"
record_handoff KEN-54
# shellcheck disable=SC2046
stop_at "$TRANSCRIPT" false $(account_env .neutralclaude)
expect 0 - "a lane whose handoff record stands ends its turn at its account's mark"

# An account nothing could measure is a gap the lane cannot act on: it is
# reported and the turn ends, never refused, so a setup with no usage endpoint
# is not stopped by a mark it can never reach.
new_handoff_lane handoff_unmeasured KEN-55
write_transcript "$TRANSCRIPT" 1000
# shellcheck disable=SC2046
stop_at "$TRANSCRIPT" false $(account_env .openclaude)
expect 0 "lane-mail-check: account=unmeasured" \
  "an account with an inventory entry and no usable credential is reported, never read as room"

# `lanes pick --lane` keeps a status-only contract where `handoff-standing`
# could not, and one reservation is what makes that safe: every status with an
# arm of its own is one no death before the verb can produce. `lanes` loads the
# same `.env.local` through the same loader, and a file bash cannot parse kills
# it with 1 or 2 — the two rows below — while the arms that refuse a lane, name
# its harness and report an abandoned read take 3, 4 and 124. An arm that
# starts acting on 1 or 2 reds here.
new_handoff_lane handoff_lanes_reserved KEN-92
write_transcript "$TRANSCRIPT" 1000
for status in 1 2; do
  plant_install lanes
  printf '#!/bin/sh\nprintf "lanes: died at %%s\\n" "%s" >&2\nexit %s\n' "$status" "$status" \
    > "$LANE/.claude/skills/orch/scripts/lanes"
  chmod +x "$LANE/.claude/skills/orch/scripts/lanes"
  stop_at "$TRANSCRIPT" false
  assert_eq "RC=$RC first=$(first_line) cause=$(grep -cx "lanes: died at $status" "$ERR_FILE")" \
    "RC=0 first=lane-mail-check: account=unmeasured cause=1" \
    "a lanes exiting $status leaves the account unmeasured with its own words, never refusing on a status its verb never gives"
done

# A Pi lane spends the account its model's provider bills, named in its
# session file: a pi-claude model the Claude seat CLAUDE_CONFIG_DIR names,
# judged there on that model, and a github-copilot model the Copilot pool on
# Pi's own root, as ORCH_LANE_COPILOT_POOL states it. Any other provider is
# left unjudged, never read as room, and the turn ends. The context mark is
# judged there as everywhere.
#
#   PROVIDER|ACCOUNT DIR|POOL READING|RC|FIRST LINE
PI_ACCOUNT_ROWS='pi-claude|.claude||0|-
pi-claude|.neutralclaude||2|lane-mail-check: headroom=3
github-copilot|.neutralclaude|97/100|2|lane-mail-check: headroom=3
github-copilot|.neutralclaude|50/100|0|-
openai|.claude||0|lane-mail-check: account=unmeasured'
new_handoff_lane handoff_pi_account KEN-79
install_hook "$HOOK" "$LANE/.pi/kendex/hooks/lane-mail-check.sh"
PI_ROOT="$TMP_ROOT/pi-account-root"
mkdir -p "$PI_ROOT"
printf '%s\n' '{"compaction":{"enabled":false}}' > "$PI_ROOT/settings.json"
# A Pi turn end: its session file on PROVIDER, and the window its Stop payload
# names.
stop_pi() { # PROVIDER TOKENS [ENV=VAL...]
  local provider="$1" tokens="$2"
  shift 2
  usage_line pi "$tokens" | jq -c --arg p "$provider" '.message.provider = $p' > "$TRANSCRIPT"
  run_payload "$(jq -nc --arg p "$TRANSCRIPT" \
    '{session_id:"s1",stop_hook_active:false,transcript_path:$p,context_window:1000000}')" \
    "PI_CODING_AGENT_DIR=$PI_ROOT" "$@"
}
while IFS='|' read -r PI_PROVIDER PI_DIR PI_POOL PI_RC PI_FIRST; do
  # shellcheck disable=SC2046
  stop_pi "$PI_PROVIDER" 1000 $(account_env "$PI_DIR") "ORCH_LANE_COPILOT_POOL=${PI_POOL:+$PI_ROOT=$PI_POOL}"
  expect "$PI_RC" "$PI_FIRST" "a Pi lane on $PI_PROVIDER with ${PI_POOL:-the seat $PI_DIR}: $PI_FIRST"
done <<<"$PI_ACCOUNT_ROWS"
# A provider nothing measures is answered by the rule alone, and a turn end
# whose transcript names no model has read no provider, so the account is left
# unjudged for want of a reading: `lanes` is never asked in either. Both run on
# an install whose `lanes` touches LANES_ASKED, every other script the real
# one, so a call is seen whatever it prints; the reader walk from
# .pi/kendex/hooks finds .pi/kendex/skills before the lane's .agents copy, and
# the install is removed after, so the rows below run on the real scripts.
PI_INSTALL="$LANE/.pi/kendex/skills/orch/scripts"
LANES_ASKED="$TMP_ROOT/pi-lanes-asked"
mkdir -p "$PI_INSTALL"
ln -s -f -n "$REPO_ROOT/skills/orch/scripts/lane-mail" "$PI_INSTALL/lane-mail"
plant_siblings "$PI_INSTALL" lanes
printf '#!/bin/sh\ntouch %s\nexit 1\n' "$LANES_ASKED" > "$PI_INSTALL/lanes"
chmod +x "$PI_INSTALL/lanes"
asked() { [ -e "$LANES_ASKED" ] && echo 1 || echo 0; }
# shellcheck disable=SC2046
stop_pi openai 1000 $(account_env .claude)
assert_eq "RC=$RC first=$(first_line) asked=$(asked)" \
  "RC=0 first=lane-mail-check: account=unmeasured asked=0" \
  "a Pi lane on a provider nothing measures is unmeasured by the rule, lanes never asked"
rm -f "$LANES_ASKED"
# shellcheck disable=SC2046
run_payload '{"session_id":"s1","stop_hook_active":false}' "PI_CODING_AGENT_DIR=$PI_ROOT" $(account_env .neutralclaude)
assert_eq "RC=$RC first=$(first_line) asked=$(asked)" \
  "RC=0 first=lane-mail-check: account=unmeasured asked=0" \
  "a Pi lane whose model no reading named is unmeasured for that reason, never blamed on a provider"
rm -rf -- "${LANE:?}/.pi/kendex/skills"
# shellcheck disable=SC2046
stop_pi pi-claude 600000 $(account_env .claude)
expect 2 "lane-mail-check: context=600000" "and the context mark is judged on a Pi lane as everywhere"
# The control drops the Pi arm, which reads every Pi account as one lanes
# keeps no inventory for, so a Pi lane on a spent seat ends its turn.
variant no-pi-account -e '/^    pi) pi_account || return 0 ;;$/d'
install_hook "$VARIANT_PATH" "$LANE/.pi/kendex/hooks/lane-mail-check.sh"
# shellcheck disable=SC2046
stop_pi pi-claude 1000 $(account_env .neutralclaude)
assert_eq "RC=$RC first=$(first_line)" "RC=0 first=lane-mail-check: account=unlisted" \
  "control: with no Pi arm a Pi lane on a spent Claude seat ends its turn unjudged"
install_hook "$HOOK" "$LANE/.pi/kendex/hooks/lane-mail-check.sh"

# An install directory naming no harness has no account to read at all: the
# gap is reported, naming the directory, and the turn ends.
install_hook "$HOOK" "$LANE/.opencode/hooks/lane-mail-check.sh"
stop
assert_eq "RC=$RC first=$(first_line) named=$(grep -cF -- "$LANE/.opencode/hooks is no harness" "$ERR_FILE")" \
  "RC=0 first=lane-mail-check: account=unlisted named=1" \
  "a harness this install does not name leaves the account unjudged, named, and the turn ends"

# A setting out of range dies inside `lanes` as invalid-percent, whose exit the
# hook cannot tell from an unmeasurable account, so the bound is judged here.
new_handoff_lane handoff_setting_range KEN-70
write_transcript "$TRANSCRIPT" 1000
# shellcheck disable=SC2046
stop_at "$TRANSCRIPT" false $(account_env .claude) ORCH_HANDOFF_HEADROOM_PCT=101
assert_eq "RC=$RC first=$(first_line) named=$(grep -cF -- " set KEN-70 handoff " "$ERR_FILE")" \
  "RC=2 first=lane-mail-check: setting-range=ORCH_HANDOFF_HEADROOM_PCT=101 named=1" \
  "a headroom setting out of range names the setting and its value, never the account"

# The read waits on a credentials lock and two network calls, and on a cache
# miss on the host-wide usage refresh lock and a 429 retry's sleep and third
# call, which together outlast this hook's budget, and a hook the harness kills
# at its budget writes no line at all. The copy shortens the ceiling so the row
# need not wait for it.
if command -v timeout >/dev/null 2>&1; then
  variant short-ceiling -e 's@^ACCOUNT_CEILING=20$@ACCOUNT_CEILING=1@'
  standard_home handoff-ceiling
  SLOW_FETCH="$TMP_ROOT/slow-fetch"
  printf '#!/bin/sh\nsleep 30\n' > "$SLOW_FETCH"
  chmod +x "$SLOW_FETCH"
  new_handoff_lane handoff_ceiling KEN-69
  install_hook "$VARIANT_PATH" "$LANE/.claude/hooks/lane-mail-check.sh"
  write_transcript "$TRANSCRIPT" 1000
  stop_at "$TRANSCRIPT" false "LANES_HOME=$H" "ORCH_LANES_FETCH_CMD=$SLOW_FETCH" \
    "FIXTURE_DIR=$FIXTURE_DIR" "CLAUDE_CONFIG_DIR=$H/.claude"
  expect 0 "lane-mail-check: account=timeout" \
    "an account read that passes the ceiling is reported as a gap and the turn ends"

  # What the ceiling leaves behind. `lanes` takes the credentials mutex inside
  # a command substitution, which the ceiling reaps along with the shell that
  # called it. Without a release the mutex outlives the hook and every later
  # renewal on that account waits out its whole timeout. The stub is the real
  # lock library taking the real mutex, on a PATH with no flock, which is the
  # platform that has one. The assertion reads the settled state rather than
  # the instant the hook returns, through lib/lanes-fixture.sh's
  # `settled_mutex`, sourced above.
  LOCK_BIN="$TMP_ROOT/lock-bin"
  mkdir -p "$LOCK_BIN"
  for tool in mkdir sleep rmdir cat rm; do
    ln -s -f -n "$(command -v "$tool")" "$LOCK_BIN/$tool"
  done
  LANE_LOCK="$TMP_ROOT/held-lane/.lanes-refresh.lock"
  mkdir -p "$TMP_ROOT/held-lane"
  new_handoff_lane handoff_mutex KEN-84
  install_hook "$VARIANT_PATH" "$LANE/.claude/hooks/lane-mail-check.sh"
  plant_install lanes
  # The nesting is the real one: `lanes` measures a lane in a command
  # substitution, the renewal inside it takes the mutex in another, and it
  # blocks there on its token POST, a third. Which of those the holder waits in
  # decides whether bash reaches its trap, so a stub that blocked in a bare
  # foreground command would measure a shape `lanes` never has.
  printf '#!/usr/bin/env bash\nset -uo pipefail\n. "%s/lib/file-lock.sh"\nrefresh() {\n  PATH="%s"\n  exec 9>"%s"\n  orch_take_lock 9 "%s" 30 || exit 1\n  post=$(sleep 30)\n  printf %%s "$post"\n}\nmeasure() {\n  local out\n  out=$(refresh) || return 1\n  printf %%s "$out"\n}\nrecord=$(measure)\n' \
    "$REPO_ROOT/skills/orch/scripts" "$LOCK_BIN" "$LANE_LOCK" "$LANE_LOCK" \
    > "$LANE/.claude/skills/orch/scripts/lanes"
  chmod +x "$LANE/.claude/skills/orch/scripts/lanes"
  write_transcript "$TRANSCRIPT" 1000
  stop_at "$TRANSCRIPT" false "LANES_HOME=$H" "ORCH_LANES_FETCH_CMD=$FETCHER" \
    "FIXTURE_DIR=$FIXTURE_DIR" "CLAUDE_CONFIG_DIR=$H/.claude"
  assert_eq "RC=$RC first=$(first_line) mutex=$(settled_mutex "$LANE_LOCK.d")" \
    "RC=0 first=lane-mail-check: account=timeout mutex=released" \
    "the ceiling leaves no credentials mutex behind for the next renewal to wait on"

  standard_home handoff-accounts
  claude_usage 5 97 12 Opus > "$FIXTURE_DIR/.neutralclaude.json"
  claude_usage 5 96 12 Opus > "$FIXTURE_DIR/.eclaude.json"
else
  printf '  skip  an account read past the ceiling: this host has no timeout to bound it with\n'
fi

# The record is judged before the scripts only the marks need, so a lane that
# has already recorded its handoff is not held by a partial install.
new_handoff_lane handoff_partial KEN-65
plant_install lanes
record_handoff KEN-65
write_transcript "$TRANSCRIPT" 600000
stop_at "$TRANSCRIPT" false
expect 0 - "a standing record ends the turn although lanes is missing from the install"

# The same install with no record: the script the marks need is named, and so
# is the record that ends the refusal.
new_handoff_lane handoff_script KEN-67
plant_install lanes
write_transcript "$TRANSCRIPT" 1000
stop_at "$TRANSCRIPT" false
assert_eq "RC=$RC first=$(first_line) named=$(grep -cF -- " set KEN-67 handoff " "$ERR_FILE")" \
  "RC=2 first=lane-mail-check: script=$LANE/.claude/skills/orch/scripts/lanes named=1" \
  "a script the marks need and the install has not got is refused, with the record that clears it"

# The one command that records a handoff, missing: a refusal naming it could
# never be cleared, so the gap is reported and the turn ends.
new_handoff_lane handoff_no_state KEN-72
plant_install workflow-state
write_transcript "$TRANSCRIPT" 600000
stop_at "$TRANSCRIPT" false
expect 0 "lane-mail-check: handoff-skipped=$LANE/.claude/skills/orch/scripts/workflow-state" \
  "an install with no workflow-state leaves the marks unjudged rather than trapping the lane"

# Hooks and skills refresh on their own schedules, and the reader walk climbs
# from this hook's install to the home's shared tree, so the orch scripts the
# marks run can be older than the hook. The verb answers 0 for a record and 3
# for none; every other status is an install that does not carry it, reported
# with its own words and passed. Read as "no record" instead, a lane that has
# already written one would be refused at every turn end for ever.
old_dispatcher() { # — the unknown-command arm of a workflow-state without the verb
  plant_install workflow-state
  printf '#!/bin/sh\ncase "$1" in\n  handoff-standing) printf "workflow-state: unknown-command arg1=%%s\\n" "$1" >&2; exit 1 ;;\nesac\nexit 0\n' \
    > "$LANE/.claude/skills/orch/scripts/workflow-state"
  chmod +x "$LANE/.claude/skills/orch/scripts/workflow-state"
}

new_handoff_lane handoff_old_state KEN-80
old_dispatcher
UNANSWERED="lane-mail-check: handoff-unanswered=$LANE/.claude/skills/orch/scripts/workflow-state"
write_transcript "$TRANSCRIPT" 600000
stop_at "$TRANSCRIPT" false
assert_eq "RC=$RC first=$(first_line) cause=$(grep -c 'workflow-state: unknown-command' "$ERR_FILE") said=$(grep -c 'is there but did not answer' "$ERR_FILE")" \
  "RC=0 first=$UNANSWERED cause=1 said=1" \
  "an install that does not carry the verb is reported with its own words and the turn ends"
record_handoff KEN-80
old_dispatcher
stop_at "$TRANSCRIPT" false
expect 0 "$UNANSWERED" "a lane that has written its record is never refused by that install either"

# The same shape one library down: `lane_context_caller_cfg` is this branch's
# addition, and an orch library without it is readable and sources without
# error, so the call would leave the hook on bash's 127 with no keyed line.
# The library is THERE, so it takes the unanswered key rather than the one
# that tells an operator to install what is installed.
new_handoff_lane handoff_old_library KEN-81
plant_install lib
mkdir -p "$LANE/.claude/skills/orch/scripts/lib"
# Every library but the one this case holes, and that one is written as a file
# of its own rather than over a link: a redirect through a symlink truncates
# the link's target, which here would be the catalog's own copy.
for name in "$REPO_ROOT/skills/orch/scripts/lib"/*.sh; do
  [ "${name##*/}" != lane-context.sh ] || continue
  ln -s -f -n "$name" "$LANE/.claude/skills/orch/scripts/lib/${name##*/}"
done
printf '# shellcheck shell=bash\n: "an orch library older than the account rule"\n' \
  > "$LANE/.claude/skills/orch/scripts/lib/lane-context.sh"
write_transcript "$TRANSCRIPT" 1000
stop_at "$TRANSCRIPT" false
assert_eq "RC=$RC first=$(first_line) said=$(grep -c 'is there but did not answer' "$ERR_FILE")" \
  "RC=0 first=lane-mail-check: handoff-unanswered=$LANE/.claude/skills/orch/scripts/lib/lane-context.sh said=1" \
  "an orch library without the account rule is reported and the turn ends, never left on 127"

# This hook's own directory gone while the turn ends, which a refresh that
# replaces the hooks directory does: no install can be looked for at all, so
# the gap takes the value no path can fill. The stub removes the directory on
# the `--git-common-dir` read that resolves the lane's root, the one call of
# its kind a run makes, and well ahead of the reader on a lane whose mailbox
# holds nothing; bash goes on reading this hook from the handle it already has.
new_handoff_lane handoff_unlocatable KEN-91
GIT_SHIM="$TMP_ROOT/git-shim"
mkdir -p "$GIT_SHIM"
printf '#!/usr/bin/env bash\ncase " $* " in *" --git-common-dir "*)\n  rm -f -- "%s/lane-mail-check.sh"\n  rmdir -- "%s" 2>/dev/null || :\n  ;;\nesac\nexec %s "$@"\n' \
  "$LANE/.claude/hooks" "$LANE/.claude/hooks" "$(command -v git)" > "$GIT_SHIM/git"
chmod +x "$GIT_SHIM/git"
write_transcript "$TRANSCRIPT" 1000
stop_at "$TRANSCRIPT" false "PATH=$GIT_SHIM:$PATH"
assert_eq "RC=$RC first=$(first_line) named=$(grep -c 'could not be resolved' "$ERR_FILE")" \
  "RC=0 first=lane-mail-check: handoff-skipped=unlocatable named=1" \
  "a hook whose own directory went away reports the gap under the value no path can fill"
assert_eq "$(grep -c 'No such file or directory' "$ERR_FILE")" "1" \
  "and cd's own words are replayed UNDER the keyed line, never ahead of it"

# The same library absent rather than stale. It takes the key whose text says
# the file is not there and names installing the orch skill, because the repair
# the unanswered key names, a settings line, would send the operator to
# .env.local for a file nothing put on disk. Its install shape is the one a
# refresh older than the library leaves: a lib directory carrying every sibling
# and not this one.
new_handoff_lane handoff_absent_library KEN-90
plant_install lib
mkdir -p "$LANE/.claude/skills/orch/scripts/lib"
for name in "$REPO_ROOT/skills/orch/scripts/lib"/*.sh; do
  [ "${name##*/}" != lane-context.sh ] || continue
  ln -s -f -n "$name" "$LANE/.claude/skills/orch/scripts/lib/${name##*/}"
done
write_transcript "$TRANSCRIPT" 1000
stop_at "$TRANSCRIPT" false
assert_eq "RC=$RC first=$(first_line) absent=$(grep -c 'is not there' "$ERR_FILE") stale=$(grep -c 'is there but did not answer' "$ERR_FILE")" \
  "RC=0 first=lane-mail-check: handoff-skipped=$LANE/.claude/skills/orch/scripts/lib/lane-context.sh absent=1 stale=0" \
  "a library the install has not got is reported as absent, never as one that would not answer"

# A library bash cannot parse. Its syntax errors are written as bash reads the
# file, so an unredirected source would put them AHEAD of the keyed line, which
# is the one thing this hook's output contract forbids.
new_handoff_lane handoff_broken_library KEN-87
plant_install lib
mkdir -p "$LANE/.claude/skills/orch/scripts/lib"
for name in "$REPO_ROOT/skills/orch/scripts/lib"/*.sh; do
  [ "${name##*/}" != lane-context.sh ] || continue
  ln -s -f -n "$name" "$LANE/.claude/skills/orch/scripts/lib/${name##*/}"
done
printf '# shellcheck shell=bash\nthis is ( not shell\n' \
  > "$LANE/.claude/skills/orch/scripts/lib/lane-context.sh"
write_transcript "$TRANSCRIPT" 1000
stop_at "$TRANSCRIPT" false
assert_eq "RC=$RC first=$(first_line) cause=$(grep -c 'syntax error' "$ERR_FILE")" \
  "RC=0 first=lane-mail-check: handoff-unanswered=$LANE/.claude/skills/orch/scripts/lib/lane-context.sh cause=1" \
  "a library bash cannot parse is reported with its words UNDER the keyed line, never above it"

# The same library present and unreadable. The source is the one probe that
# answers, so it is run rather than guarded by a readability test: failing it
# writes bash's own permission error to the file the arm replays, where a test
# ahead of it would leave that cause empty under a line that promises one.
if [ "${CAN_DENY_READS:?}" -eq 1 ]; then
  chmod 000 "$LANE/.claude/skills/orch/scripts/lib/lane-context.sh"
  stop_at "$TRANSCRIPT" false
  chmod 644 "$LANE/.claude/skills/orch/scripts/lib/lane-context.sh"
  assert_eq "RC=$RC first=$(first_line) cause=$(grep -ci 'permission denied' "$ERR_FILE")" \
    "RC=0 first=lane-mail-check: handoff-unanswered=$LANE/.claude/skills/orch/scripts/lib/lane-context.sh cause=1" \
    "a library that cannot be read is reported with bash's own words, never with an empty cause"
else
  printf '  skip  a library that cannot be read: running as root, which reads a mode-000 file\n'
fi

# The account mark can fire on a lane's first turn end, before any workflow has
# run init, and `set` refuses a state file that is not there. The refusal has
# to carry the init that makes one, so the lane can act on it and nothing else.
new_lane handoff_uninit ken-66
mkdir -p "$LANE/tmp/lane-mail/KEN-66"
write_transcript "$TRANSCRIPT" 600000
stop_at "$TRANSCRIPT" false
expect 2 "lane-mail-check: context=600000" "a lane with no state file is refused at the mark"
INIT_CMD="$(grep -F -- " init KEN-66" "$ERR_FILE")"
assert_eq "$([ -n "$INIT_CMD" ] && echo named || echo absent)" "named" \
  "the refusal names the init that set needs"
(cd "$LANE" && eval "$INIT_CMD" > /dev/null)
stop_at "$TRANSCRIPT" false
assert_eq "RC=$RC first=$(first_line) init=$(grep -cF -- " init KEN-66" "$ERR_FILE")" \
  "RC=2 first=lane-mail-check: context=600000 init=0" \
  "the init it named makes the state, and the next refusal drops that line"
record_handoff KEN-66
stop_at "$TRANSCRIPT" false
expect 0 - "the set it named then clears the mark"

# The same refusal on a lane with no branch to name: LANE_MAIL_ITEM selects the
# item and HEAD is detached, so the init line carries no --branch and must
# still be a command the lane can run.
new_lane handoff_detached ken-82
mkdir -p "$LANE/tmp/lane-mail/KEN-82"
mark_lane KEN-82
git -C "$LANE" checkout -q --detach
write_transcript "$TRANSCRIPT" 600000
stop_at "$TRANSCRIPT" false LANE_MAIL_ITEM=KEN-82
expect 2 "lane-mail-check: context=600000" "a detached lane the brief named is refused at the mark"
INIT_CMD="$(grep -F -- " init KEN-82" "$ERR_FILE")"
assert_eq "$([ -n "$INIT_CMD" ] && echo named || echo absent) branch=$(grep -cF -- '--branch' "$ERR_FILE")" \
  "named branch=0" "the refusal names an init with no branch where HEAD names none"
(cd "$LANE" && eval "$INIT_CMD" > /dev/null)
record_handoff KEN-82
stop_at "$TRANSCRIPT" false LANE_MAIL_ITEM=KEN-82
expect 0 - "and the init it named is a command that runs, so the record clears the mark"

# The third route into the marks: a mailbox written and read, so the reader
# reports a count with nothing unread under it.
new_handoff_lane handoff_read KEN-64
send KEN-64 'Rebase first.'
write_transcript "$TRANSCRIPT" 600000
stop_at "$TRANSCRIPT" false
expect 2 "lane-mail-check: unread=1" "the directive refuses the turn end before any mark is judged"
stop_at "$TRANSCRIPT" false
expect 2 "lane-mail-check: context=600000" \
  "a lane whose mailbox has been read is judged on the marks at its next turn end"

# --- a Pi lane's turn rows ------------------------------------------------
# A Pi lane is judged from what Pi emits, never its pane: its turn ends and the
# first tool call after each, as rows this hook writes in the lane's mailbox
# directory (orch lib/session-rows.sh § A Pi lane's own rows). The reader of
# those rows is tested in orch's lane-state suite; these rows pin the writer.

# A Pi lane with the orch install where the Pi hook's walk to its reader looks.
new_pi_lane() { # NAME ITEM [HOOK]
  new_handoff_lane "$1" "$2"
  mkdir -p "$LANE/.pi/skills"
  ln -s "$LANE/.claude/skills/orch" "$LANE/.pi/skills/orch"
  install_hook "${3:-$HOOK}" "$LANE/.pi/kendex/hooks/lane-mail-check.sh"
  PI_ROWS="$LANE/tmp/lane-mail/$2/session-rows.jsonl"
}
# Each row as event:stop_reason:message, space-joined; `-` for no file.
pi_rows() {
  [ -e "$PI_ROWS" ] || { echo -; return 0; }
  jq -r '"\(.event):\(.stop_reason // ""):\(.message // "")"' "$PI_ROWS" | paste -sd' ' -
}
PI_TURN="$TMP_ROOT/pi-turn.jsonl"
pi_tool() { # [EXTRA_FIELDS_JSON]
  local extra="${1:-}"
  [ -n "$extra" ] || extra='{}'
  ARM_ARGS=(halt)
  run_payload "$(jq -nc --argjson extra "$extra" '{tool_name:"bash",tool_input:{command:"ls"}} + $extra')"
  ARM_ARGS=()
}
pi_stop() { # [EXTRA_FIELDS_JSON]
  local extra="${1:-}"
  [ -n "$extra" ] || extra='{}'
  run_payload "$(jq -nc --arg p "$PI_TURN" --argjson extra "$extra" \
    '{session_id:"s1",stop_hook_active:false,transcript_path:$p,context_window:200000} + $extra')"
}

new_pi_lane pi_rows KEN-95
usage_line pi 1000 > "$PI_TURN"
pi_tool
pi_tool
pi_stop
assert_eq "RC=$RC rows=$(pi_rows)" "RC=0 rows=PreToolUse:: Stop:stop:" \
  "a Pi lane writes one PreToolUse row for its turn's tool calls and a Stop row at its end"
jq -nc '{type:"message",message:{role:"assistant",model:"m",stopReason:"error",
  errorMessage:"429 You have hit your usage limit for this period"}}' >> "$PI_TURN"
pi_stop
assert_eq "rows=$(pi_rows)" \
  "rows=PreToolUse:: Stop:stop: Stop:error:429 You have hit your usage limit for this period" \
  "a turn that ended on an error carries Pi's own message, which is what a reader judges a wall from"
pi_tool
assert_eq "last=$(pi_rows | awk '{ print $NF }')" "last=PreToolUse::" \
  "the first tool call after a turn end opens the next turn"
PI_ROWS_BEFORE="$(pi_rows)"
pi_stop '{"agent_type":"worker"}'
pi_tool '{"agent_type":"worker"}'
assert_eq "rows=$(pi_rows)" "rows=$PI_ROWS_BEFORE" "a subagent's tool call and turn end write no row of the lead's"
install_hook "$HOOK" "$LANE/.claude/hooks/lane-mail-check.sh"
rm -f -- "${PI_ROWS:?}"
stop_at "$PI_TURN" false
assert_eq "rows=$(pi_rows)" "rows=-" "a Claude Code lane writes no row: its pane is what its readers judge"
# A Pi lane launched on a pool account runs under PI_CODING_AGENT_DIR, and its
# hook sits in that root's kendex/hooks: it is Pi's install all the same.
new_handoff_lane pi_pool_rows KEN-97
PI_POOL="$LANE/.pool/acct"
mkdir -p "$PI_POOL"
ln -s "$LANE/.claude/skills/orch" "$PI_POOL/skills"
install_hook "$HOOK" "$PI_POOL/kendex/hooks/lane-mail-check.sh"
PI_ROWS="$LANE/tmp/lane-mail/KEN-97/session-rows.jsonl"
ARM_ARGS=(halt)
run_payload '{"tool_name":"bash","tool_input":{"command":"ls"}}' "PI_CODING_AGENT_DIR=$PI_POOL"
ARM_ARGS=()
run_payload "$(jq -nc --arg p "$PI_TURN" '{session_id:"s1",stop_hook_active:false,transcript_path:$p,context_window:200000}')" \
  "PI_CODING_AGENT_DIR=$PI_POOL"
assert_eq "rows=$(pi_rows)" "rows=PreToolUse:: Stop:error:429 You have hit your usage limit for this period" \
  "a Pi lane whose hook sits under the PI_CODING_AGENT_DIR root writes its rows"
# An install naming no harness writes no row, and a launched lane's turn end
# there says so under harness-unlisted rather than leaving its Pi reader
# unjudged in silence.
new_handoff_lane pi_unnamed_rows KEN-98
mkdir -p "$LANE/.other"
ln -s "$LANE/.claude/skills/orch" "$LANE/.other/skills"
install_hook "$HOOK" "$LANE/.other/hooks/lane-mail-check.sh"
PI_ROWS="$LANE/tmp/lane-mail/KEN-98/session-rows.jsonl"
ARM_ARGS=(halt)
run_payload '{"tool_name":"bash","tool_input":{"command":"ls"}}'
ARM_ARGS=()
assert_eq "RC=$RC said=$(grep -c '^lane-mail-check: harness-unlisted=' "$ERR_FILE" || true)" "RC=0 said=0" \
  "a tool call on an install naming no harness writes nothing and says nothing"
pi_stop
assert_eq "said=$(grep -c "^lane-mail-check: harness-unlisted=$LANE/.other/hooks\$" "$ERR_FILE" || true) rows=$(pi_rows)" "said=1 rows=-" \
  "a launched lane's turn end on an install naming no harness reports harness-unlisted and writes no row"

# --- the idle judge at a turn end -----------------------------------------
# A launched lane lead that ends its turn with nothing sent through lane mail
# since its last judged turn end, no handoff recorded and no halt standing,
# told nobody it stopped: the overseer reads the mailbox, never the pane. The
# turn end is refused once with the continuation that reads the lane's mail,
# and the hold recorded; ending idle again on the turn that recorded hold
# continued is reported to the overseer as a lane notice, never refused a
# second time. Every fact is lane mail's: the transcript rows below give the
# judge a lane's words and it reads none of them.

# The lane's record of its sent count, and the notices its outbound file
# holds, the first line of each, one per line.
sent_record() { # ITEM
  cat -- "$LANE/tmp/lane-mail/$1/sent-count" 2>/dev/null || echo none
}
notices() { # ITEM
  [ -f "$LANE/tmp/lane-mail/$1/to-overseer.jsonl" ] || { echo none; return 0; }
  jq -r 'select(.kind == "notice") | .text | split("\n") | first' "$LANE/tmp/lane-mail/$1/to-overseer.jsonl"
}
# The lane reads its mail, as the continuation tells it to: a plain inbox read,
# which acknowledges a halt among the lines.
read_mail() { # ITEM
  (cd "$LANE" && "$LANE_MAIL" inbox --item "$1" --root "$LANE" >/dev/null)
}
printf 'Which base?\n' > "$TMP_ROOT/ask.txt"

new_handoff_lane idle_turn KEN-65
REPORT_ITEM=""
stop
assert_eq "RC=$RC keys=$(hook_keys) record=$(sent_record KEN-65)" \
  "RC=2 keys=account=unlisted;idle=KEN-65 record=0 held" \
  "a lane that ends its turn having sent nothing through lane mail is held once, after the marks, and the hold recorded"
printf -v INBOX_ROUTE 'inbox --item %q --root %q' KEN-65 "$LANE"
printf -v ASK_ROUTE 'ask --item %q --root %q --file [PATH]' KEN-65 "$LANE"
printf -v NOTICE_ROUTE 'notice --item %q --root %q --file [PATH]' KEN-65 "$LANE"
assert_eq "$(grep -cF -- "$INBOX_ROUTE" "$ERR_FILE") $(grep -cF -- "$ASK_ROUTE" "$ERR_FILE") $(grep -cF -- "$NOTICE_ROUTE" "$ERR_FILE")" \
  "1 1 1" "the refusal continues the lane with its inbox read beside the ask and notice routes, rooted at the lane"
stop_active
assert_eq "RC=$RC keys=$(hook_keys) notices=$(notices KEN-65) record=$(sent_record KEN-65)" \
  "RC=0 keys=account=unlisted;idle-notice=KEN-65 notices=lane-mail-check: lane-idle=KEN-65 record=1" \
  "the continued turn ending idle again is reported to the overseer once, never held twice, and the record counts the notice"
stop
assert_eq "RC=$RC keys=$(hook_keys) record=$(sent_record KEN-65)" "RC=2 keys=account=unlisted;idle=KEN-65 record=1 held" \
  "the hook's own notice is no send of the lane's: the next turn ending idle is held again"
report KEN-65
stop
assert_eq "RC=$RC keys=$(hook_keys) record=$(sent_record KEN-65)" "RC=0 keys=account=unlisted record=2" \
  "a turn in which the lane sent a notice ends, and the record moves to its count"
stop
assert_eq "RC=$RC keys=$(hook_keys)" "RC=2 keys=account=unlisted;idle=KEN-65" \
  "the send is counted once: the turn after it ending idle is held"
(cd "$LANE" && "$LANE_MAIL" ask --item KEN-65 --root "$LANE" --file "$TMP_ROOT/ask.txt" >/dev/null)
stop
expect 0 "$GAP" "a turn in which the lane sent an ask ends"
# A record larger than the count is a mailbox replaced under it: the count
# moved, and the record starts again from it.
printf '9\n' > "$LANE/tmp/lane-mail/KEN-65/sent-count"
stop
assert_eq "RC=$RC record=$(sent_record KEN-65)" "RC=0 record=3" \
  "a record above the count is a replaced mailbox: the turn ends and the record takes the count"

# The continued turn is judged by who held it. A lane held here that then
# sends a notice, as one waiting on a dispatched agent does, ends the
# continued turn with no notice from the hook. A turn another stop hook
# continued after the lane reported is held as a fresh one, and only the turn
# that hold continued is reported.
new_handoff_lane idle_wait KEN-76
REPORT_ITEM=""
stop
report KEN-76
stop_active
assert_eq "RC=$RC keys=$(hook_keys) notices=$(notices KEN-76 | paste -sd'|' -) record=$(sent_record KEN-76)" \
  "RC=0 keys=account=unlisted notices=step $REPORTS done record=1" \
  "a held lane whose continuation sends a notice ends its turn, and the hook sends none"
new_handoff_lane idle_other_hook KEN-77
REPORT_ITEM=""
report KEN-77
stop
stop_active
assert_eq "RC=$RC keys=$(hook_keys) notices=$(notices KEN-77 | paste -sd'|' -) record=$(sent_record KEN-77)" \
  "RC=2 keys=account=unlisted;idle=KEN-77 notices=step $REPORTS done record=1 held" \
  "a turn another stop hook continued after the lane reported is held, and no notice is sent"
stop_active
assert_eq "RC=$RC keys=$(hook_keys) record=$(sent_record KEN-77)" \
  "RC=0 keys=account=unlisted;idle-notice=KEN-77 record=2" \
  "the turn this judge's own hold continued is the one reported"

# What the overseer sends is no send of the lane's, and a halt it sent is the
# one standing reason for a lane to sit idle, until a later directive lifts it.
new_handoff_lane idle_halt KEN-66
REPORT_ITEM=""
send KEN-66 'Rebase onto main.' >/dev/null
read_mail KEN-66
stop
assert_eq "RC=$RC keys=$(hook_keys)" "RC=2 keys=account=unlisted;idle=KEN-66" \
  "a directive the overseer sent and the lane read is no send of the lane's"
send KEN-66 'Stop here.' --halt >/dev/null
read_mail KEN-66
stop
expect 0 "$GAP" "a lane whose newest directive is a halt sits idle unheld"
assert_eq "record=$(sent_record KEN-66)" "record=0" "and the hold the turn end before it recorded is cleared"
send KEN-66 'Carry on.' >/dev/null
read_mail KEN-66
stop
assert_eq "RC=$RC keys=$(hook_keys)" "RC=2 keys=account=unlisted;idle=KEN-66" \
  "a directive after the halt lifts it, and the lane ending idle is held again"

# The facts that settle the turn before the judge reaches it: a handoff
# record, a subagent's turn end, and a lane no launch marker binds.
new_handoff_lane idle_handoff KEN-67
REPORT_ITEM=""
record_handoff KEN-67
stop
expect 0 - "a lane whose handoff record stands is not judged idle"
new_handoff_lane idle_subagent KEN-68
REPORT_ITEM=""
run_payload '{"session_id":"s1","stop_hook_active":false,"agent_type":"worker"}'
expect 0 - "a subagent's turn end is not judged idle"
new_handoff_lane idle_unmarked KEN-69
REPORT_ITEM=""
unmark_lanes
stop
expect 0 - "a mailbox no launch marker binds is no lane, and is not judged idle"

# The judge on every harness's install: the Codex and Pi copies hold a lane
# that sent nothing as the Claude Code copy does.
for row in codex:.codex/hooks:KEN-70 pi:.pi/kendex/hooks:KEN-71; do
  IFS=: read -r IDLE_HARNESS IDLE_DIR IDLE_ITEM <<<"$row"
  new_handoff_lane "idle_$IDLE_HARNESS" "$IDLE_ITEM"
  REPORT_ITEM=""
  mkdir -p "$LANE/${IDLE_DIR%/hooks}/skills"
  ln -s "$LANE/.claude/skills/orch" "$LANE/${IDLE_DIR%/hooks}/skills/orch"
  install_hook "$HOOK" "$LANE/$IDLE_DIR/lane-mail-check.sh"
  stop
  assert_eq "RC=$RC idle=$(grep -c "^lane-mail-check: idle=$IDLE_ITEM\$" "$ERR_FILE" || true)" "RC=2 idle=1" \
    "a $IDLE_HARNESS lane that sent nothing is held"
  stop_active
  assert_eq "RC=$RC notice=$(grep -c "^lane-mail-check: idle-notice=$IDLE_ITEM\$" "$ERR_FILE" || true)" "RC=0 notice=1" \
    "and on the turn its harness continued, reported to the overseer"
done
# The pi-hooks carrier runs no further request after a continued turn, so a
# hold there reaches nobody: a Pi turn another stop hook continued is reported
# in its place. A fresh lane has no identical idle notice in the minute window.
new_pi_lane idle_pi_other_hook "$IDLE_ITEM"
REPORT_ITEM=""
report "$IDLE_ITEM"
stop
stop_active
assert_eq "RC=$RC notice=$(grep -c "^lane-mail-check: idle-notice=$IDLE_ITEM\$" "$ERR_FILE" || true) record=$(sent_record "$IDLE_ITEM")" \
  "RC=0 notice=1 record=2" \
  "a Pi turn another stop hook continued ends with the notice, never a hold nobody runs"

# The lane's words are in the transcript the payload names, and the judge
# reads none of them. Each row writes the harness's own transcript spelling
# whose final assistant text is WORDS, after SENDS notices this turn: a
# statement from a lane that sent nothing is held as the transcript-free row
# is, and a question from a lane that sent a notice passes.
while IFS=: read -r WORDS_HARNESS WORDS_DIR WORDS_ITEM WORDS_SENDS WORDS_RC WORDS_KEY WORDS; do
  new_handoff_lane "words_$WORDS_ITEM" "$WORDS_ITEM"
  REPORT_ITEM=""
  mkdir -p "$LANE/${WORDS_DIR%/hooks}/skills"
  [ -e "$LANE/${WORDS_DIR%/hooks}/skills/orch" ] || ln -s "$LANE/.claude/skills/orch" "$LANE/${WORDS_DIR%/hooks}/skills/orch"
  install_hook "$HOOK" "$LANE/$WORDS_DIR/lane-mail-check.sh"
  usage_line "$WORDS_HARNESS" 1000 | jq -c --arg w "$WORDS" '.message.content = [{type: "text", text: $w}]' \
    > "$TMP_ROOT/words.jsonl"
  [ "$WORDS_SENDS" -eq 0 ] || report "$WORDS_ITEM"
  run_payload "$(jq -nc --arg p "$TMP_ROOT/words.jsonl" \
    '{session_id:"s1",stop_hook_active:false,transcript_path:$p,context_window:200000}')"
  assert_eq "RC=$RC idle=$(grep -c "^lane-mail-check: idle=$WORDS_ITEM\$" "$ERR_FILE" || true)" "RC=$WORDS_RC idle=$WORDS_KEY" \
    "a $WORDS_HARNESS lane that sent $WORDS_SENDS notices and wrote '$WORDS' is judged on its sends alone"
done <<'ROWS'
claude:.claude/hooks:KEN-86:0:2:1:All done.
pi:.pi/kendex/hooks:KEN-87:0:2:1:All done.
claude:.claude/hooks:KEN-88:1:0:0:Should I merge it?
pi:.pi/kendex/hooks:KEN-89:1:0:0:Should I merge it?
ROWS

# A listing or a record the judge cannot read is reported and the turn ends:
# nothing a lane does at its turn end repairs its mailbox. An outbound file
# that is a directory is one the reader refuses as unsafe.
new_handoff_lane idle_events_failed KEN-72
REPORT_ITEM=""
mkdir -p "$LANE/tmp/lane-mail/KEN-72/to-overseer.jsonl"
stop
assert_eq "RC=$RC keys=$(hook_keys)" "RC=0 keys=account=unlisted;events=2" \
  "an events listing the reader refuses is reported under its exit status and the turn ends"
for BAD_RECORD in 'many' '0 maybe' '0 held 1'; do
  new_handoff_lane idle_record_bad KEN-73
  REPORT_ITEM=""
  printf '%s\n' "$BAD_RECORD" > "$LANE/tmp/lane-mail/KEN-73/sent-count"
  stop
  assert_eq "RC=$RC keys=$(hook_keys) record=$(sent_record KEN-73)" \
    "RC=0 keys=account=unlisted;idle-record=$LANE/tmp/lane-mail/KEN-73/sent-count record=0" \
    "a record reading '$BAD_RECORD' is reported, rewritten with the count, and the turn ends"
  stop
  assert_eq "RC=$RC keys=$(hook_keys)" "RC=2 keys=account=unlisted;idle=KEN-73" \
    "and the rewritten record judges the next turn end"
  rm -rf -- "${LANE:?}"
done
new_handoff_lane idle_record_dir KEN-74
REPORT_ITEM=""
mkdir -p "$LANE/tmp/lane-mail/KEN-74/sent-count"
stop
assert_eq "RC=$RC keys=$(hook_keys)" \
  "RC=0 keys=account=unlisted;idle-record=$LANE/tmp/lane-mail/KEN-74/sent-count;idle-unrecorded=$LANE/tmp/lane-mail/KEN-74/sent-count" \
  "a record that is a directory is reported as unreadable and as unwritable, and the turn ends"
# A hold the record cannot take is not made: one with no record would be made
# again on every turn it continued. A mailbox directory the hook cannot write
# in leaves a readable record unwritable, except to root, which ignores the
# mode.
if [ "${CAN_DENY_READS:?}" -eq 1 ]; then
  new_handoff_lane idle_hold_unrecorded KEN-78
  REPORT_ITEM=""
  printf '0\n' > "$LANE/tmp/lane-mail/KEN-78/sent-count"
  chmod 555 "$LANE/tmp/lane-mail/KEN-78"
  stop
  chmod 755 "$LANE/tmp/lane-mail/KEN-78"
  assert_eq "RC=$RC idle=$(grep -c '^lane-mail-check: idle=' "$ERR_FILE" || true) unrecorded=$(grep -c "^lane-mail-check: idle-hold-unrecorded=$LANE/tmp/lane-mail/KEN-78/sent-count\$" "$ERR_FILE" || true)" \
    "RC=0 idle=0 unrecorded=1" \
    "a hold the record cannot take is reported under idle-hold-unrecorded and not made"
  # The notice sent and not counted: the next turn end reads it as a send.
  # This case's reader seals the mailbox once the notice is in it.
  new_handoff_lane idle_notice_unrecorded KEN-76
  REPORT_ITEM=""
  stop
  wrap_reader "$(printf '[ "${1:-}" != notice ] || { %q "$@" && chmod 555 %q; exit; }' "$LANE_MAIL" "$LANE/tmp/lane-mail/KEN-76")"
  stop_active
  chmod 755 "$LANE/tmp/lane-mail/KEN-76"
  assert_eq "RC=$RC keys=$(hook_keys) record=$(sent_record KEN-76)" \
    "RC=0 keys=account=unlisted;idle-notice-unrecorded=$LANE/tmp/lane-mail/KEN-76/sent-count;idle-notice=KEN-76 record=0 held" \
    "a notice the record cannot count is reported under idle-notice-unrecorded"
else
  printf '  skip  a hold the record cannot take: running as root, which writes in a mode-555 directory\n'
  printf '  skip  a notice the record cannot count: running as root, which writes in a mode-555 directory\n'
fi
# A listing jq cannot read is reported and the turn ends. This case's reader
# prints a line that is no JSON for its `events` verb and runs every other one.
new_handoff_lane idle_events_envelope KEN-79
REPORT_ITEM=""
NOT_JSON='[ "${1:-}" != events ] || { echo "planted: not json"; exit 0; }'
wrap_reader "$NOT_JSON"
stop
assert_eq "RC=$RC keys=$(hook_keys) record=$(sent_record KEN-79)" \
  "RC=0 keys=account=unlisted;events=envelope record=none" \
  "an events listing whose envelopes jq cannot read is reported under events=envelope and the turn ends"
# A notice that cannot be sent is reported and passed too: the lane has had
# its one continuation, and refusing again is the loop. This case's reader
# refuses its `notice` verb and runs every other one.
new_handoff_lane idle_notice_unsent KEN-75
REPORT_ITEM=""
wrap_reader '[ "${1:-}" != notice ] || { echo "planted: notice refused" >&2; exit 3; }'
stop
stop_active
assert_eq "RC=$RC keys=$(hook_keys) record=$(sent_record KEN-75)" \
  "RC=0 keys=account=unlisted;idle-notice-unsent=3 record=0 held" \
  "a notice the reader refuses is reported under its exit status, the record untouched, and the turn ends"
assert_eq "$(grep -c '^planted: notice refused$' "$ERR_FILE")" "1" "with the reader's own words under it"

# No hook reads a lane's words: the question rule that read the final
# assistant text and the turn's opening stamp out of the transcript is gone
# from the hook and from every render of it, and no jq program in them selects
# a transcript's text blocks. RENDERS names the copies this repository tracks;
# a must-fail control below plants the text read back into a copy.
text_reads() { # FILE...
  grep -c -E 'asks_the_person|transcript_turn_start|transcript_final_line|select\(\.type == "text"\)' "$@" |
    awk -F: '{ n += $NF } END { print n + 0 }'
}
RENDERS=("$HOOK" "$REPO_ROOT/.claude/hooks/lane-mail-check.sh" "$REPO_ROOT/.codex/hooks/lane-mail-check.sh" \
  "$REPO_ROOT/.pi/kendex/hooks/lane-mail-check.sh")
assert_eq "$(text_reads "${RENDERS[@]}")" "0" "no copy of the hook reads a lane's message text"

# --- the overseer's own turn end ------------------------------------------
# The fleet's overseer is no lane: it carries no launch marker, no claim and no
# item of its own, so every rule above passed it in silence and it rode past
# 500 thousand tokens with the fleet unattended. It meets two marks of its own
# here, and this hook judges neither: `oversee-succeed --check-marks` decides
# where they sit and what this session's pane and account say, and the rows
# below are about which of its answers refuses a turn end and which ends one.
# The judge, the overseer session and the answers it gives are
# lib/lane-mail-world.sh's; the tool-call judgement is
# lane-mail-check-overseer-tool.test.sh's.

# A turn end from a harness whose payload names no session, which is what sends
# this hook to the pane key.
stop_unnamed() { # [ENV=VAL...]
  run_payload "$(jq -nc --arg p "$TRANSCRIPT" \
    '{stop_hook_active:false,transcript_path:$p}')" "$@"
}

overseer_transcript
# The two commands an overseer's refusal names, counted in the stderr it wrote:
# the succession is handed the reading this turn end took, as the judge was.
overseer_route() { grep -cF -- "/oversee-succeed --context $OVERSEER_CONTEXT -- [THE PERMISSION" "$ERR_FILE"; }
overseer_record_named() { grep -cF -- " set oversee handoff " "$ERR_FILE"; }

new_overseer overseer_context
judge_says "$BELOW_MARK_LINE"
# shellcheck disable=SC2046
stop_at "$TRANSCRIPT" false $(overseer_env)
expect 0 - "an overseer the judgement puts under both marks ends its turn"
assert_eq "$(judge_argv)" "--check-marks --context $OVERSEER_CONTEXT" \
  "and the hook asked for the judgement on the reading this turn end took, and nothing else, opening no window" "$ERR_FILE"
judge_says "$CONTEXT_MARK_LINE"
# shellcheck disable=SC2046
stop_at "$TRANSCRIPT" false $(overseer_env)
expect 2 "lane-mail-check: context=612000" \
  "an overseer the judgement puts at the context mark is refused with the figure it read"
assert_eq "route=$(overseer_route) record=$(overseer_record_named)" "route=1 record=1" \
  "the refusal names the succession as the route, with the record that clears a succession that refuses"
# shellcheck disable=SC2046
stop_at "$TRANSCRIPT" true $(overseer_env)
expect 2 "lane-mail-check: context=612000" \
  "and repeats on the continued turn, as a lane's does"
record_overseer_handoff
# shellcheck disable=SC2046
stop_at "$TRANSCRIPT" false $(overseer_env)
assert_eq "RC=$RC first=$(first_line) judged=$(judge_calls)" "RC=0 first=- judged=3" \
  "an overseer whose own handoff record stands ends its turn, and the judgement is not even asked"
# The fleet item is one item, shared by every overseer of the fleet in turn. A
# record the session before this one wrote and exited on answers for nobody
# here: the replacement a refused succession leaves the operator to start by
# hand would otherwise ride past both its marks in silence for its whole life,
# in the predecessor's own pane.
record_overseer_handoff other-session
# shellcheck disable=SC2046
stop_at "$TRANSCRIPT" false $(overseer_env)
expect 2 "lane-mail-check: context=612000" \
  "a record another session wrote holds nobody, so this overseer meets the mark"
assert_eq "record=$(overseer_record_named) named=$(grep -cF -- '"session_id":"s1"' "$ERR_FILE")" \
  "record=1 named=1" "and the record it is told to write names this session"
assert_eq "$(grep -cF -- "\"pane_key\":\"$OVERSEER_SERVER $OVERSEER_PANE\"" "$ERR_FILE")" "1" \
  "with the pane key beside it, for a harness that names no session" "$ERR_FILE"

# Where the payload names no session the pane key answers, which tells a
# successor in ANOTHER pane from the writer and is all that is available there.
new_overseer overseer_unnamed_session
judge_says "$CONTEXT_MARK_LINE"
record_overseer_handoff "" "$OVERSEER_SERVER $OVERSEER_PANE"
# shellcheck disable=SC2046
stop_unnamed $(overseer_env)
expect 0 - "a record carrying this session's own pane key ends the turn of a payload with no id"
record_overseer_handoff "" "$OVERSEER_SERVER %4"
# shellcheck disable=SC2046
stop_unnamed $(overseer_env)
# A payload naming no session also binds the transcript to nobody, so the read
# is reported as unbound ahead of the mark, the judge is handed the install's
# harness and no reading, and the mark it refuses on is the planted judge's own.
assert_eq "RC=$RC first=$(first_line) mark=$(grep -c '^lane-mail-check: context=612000$' "$ERR_FILE") argv=$(judge_argv | tail -n 1) reason=$(grep -c 'binding-missing' "$ERR_FILE")" \
  "RC=2 first=lane-mail-check: transcript-unowned=$TRANSCRIPT mark=1 argv=--check-marks --harness claude reason=1" \
  "and one carrying another pane's key holds nobody: the unbound transcript is reported once, the judge handed the harness and no reading, and its mark refused" "$ERR_FILE"

# The account mark is the judge's own, on the judge's own setting: this hook
# reads neither, so the figure and the mark it names come off that one line.
new_overseer overseer_headroom
judge_says "$HEADROOM_MARK_LINE"
# shellcheck disable=SC2046
stop_at "$TRANSCRIPT" false $(overseer_env)
expect 2 "lane-mail-check: headroom=4" \
  "an overseer the judgement puts at its account mark is refused with the headroom it read"
assert_eq "named=$(grep -cF -- 'the ORCH_OVERSEER_HEADROOM_PCT mark of 10' "$ERR_FILE") route=$(overseer_route)" \
  "named=1 route=1" "and the refusal names the judge's own setting and the succession"

# A reading whose window the adapter could not name is handed on with that
# window empty, to the judge and to the succession the refusal names alike, so
# the judge reports the context unmeasured rather than judging a stored figure.
new_overseer overseer_window_unread
usage_line sonnet 999999 > "$TRANSCRIPT"
judge_says "$HEADROOM_MARK_LINE"
# shellcheck disable=SC2046
stop_at "$TRANSCRIPT" false $(overseer_env)
assert_eq "argv=$(judge_argv | tail -n 1) route=$(grep -cF -- "/oversee-succeed --context 999999: -- [THE PERMISSION" "$ERR_FILE")" \
  "argv=--check-marks --context 999999: route=1" \
  "an overseer reading with no window hands its judge and its succession the tokens and no window" "$ERR_FILE"
variant no-context-arg -e 's|^    ${JUDGE_ARGS\[@\]+"${JUDGE_ARGS\[@\]}"} 2>|    2>|'
install_hook "$VARIANT_PATH" "$LANE/.claude/hooks/lane-mail-check.sh"
write_transcript "$TRANSCRIPT" 600000
# shellcheck disable=SC2046
stop_at "$TRANSCRIPT" false $(overseer_env)
assert_eq "$(judge_argv | tail -n 1)" "--check-marks" \
  "control: a hook that withholds the reading hands its judge no context"
install_hook "$HOOK" "$LANE/.claude/hooks/lane-mail-check.sh"

# --- the reading is bound to the current session's own transcript ----------
# The overseer reads context only off the native file the payload's session
# owns under the launch home the fleet record names. A file that is not this
# session's leaves the context unmeasured, reported once, while the account
# triggers still decide; a session restarted in the pane reads its own new
# file by binding to the id the payload carries, never a predecessor's.
owned_payload() { # SESSION TRANSCRIPT [ENV=VAL...]
  local session="$1" path="$2"
  shift 2
  run_payload "$(jq -nc --arg s "$session" --arg p "$path" \
    '{session_id:$s,stop_hook_active:false,transcript_path:$p}')" "$@"
}
new_overseer overseer_binding
# The restarted session's own file, owned under the recorded home; the
# predecessor's s1 file still sits beside it at 600000 tokens.
S2_TRANSCRIPT="$OVERSEER_HOME_DIR/projects/repo/s2.jsonl"
write_transcript "$S2_TRANSCRIPT" 700000
judge_says "$HEADROOM_MARK_LINE"
# shellcheck disable=SC2046
owned_payload s2 "$S2_TRANSCRIPT" $(overseer_env)
assert_eq "argv=$(judge_argv | tail -n 1) unowned=$(grep -c '^lane-mail-check: transcript-unowned' "$ERR_FILE")" \
  "argv=--check-marks --context 700000:1000000 unowned=0" \
  "a session restarted in the pane reads its own new transcript, bound by its id" "$ERR_FILE"
# The same restarted session pointed at the predecessor's s1 file reads
# nobody's context: the id does not name that file, so it is unmeasured and
# only the account triggers decide.
# shellcheck disable=SC2046
owned_payload s2 "$TRANSCRIPT" $(overseer_env)
assert_eq "RC=$RC first=$(first_line) argv=$(judge_argv | tail -n 1) headroom=$(grep -c '^lane-mail-check: headroom=4' "$ERR_FILE")" \
  "RC=2 first=lane-mail-check: transcript-unowned=$TRANSCRIPT argv=--check-marks --harness claude headroom=1" \
  "a predecessor's transcript is not this session's, so its context is unmeasured and the account mark decides" "$ERR_FILE"
# A record naming this pane and no launch home, one `oversee register` wrote
# for a session with no account, is healed from the session's own
# environment: the home the harness variable carries is written into the
# record and binds the transcript on this very turn end. A session whose
# environment names another home than the one its transcript sits under
# still binds nothing: the heal names the environment's home, the gate reads
# the file as another home's, context is unmeasured and the account triggers
# decide, the judge handed the harness this install names.
new_overseer overseer_no_home
startless_record "{\"server_start\":$OVERSEER_SERVER_START}"
judge_says "$HEADROOM_MARK_LINE"
# shellcheck disable=SC2046
stop_at "$TRANSCRIPT" false $(overseer_env) "CLAUDE_CONFIG_DIR=$OVERSEER_HOME_DIR"
assert_eq "RC=$RC first=$(first_line) argv=$(judge_argv | tail -n 1) home=$(recorded_field home) harness=$(recorded_field harness)" \
  "RC=2 first=lane-mail-check: headroom=4 argv=--check-marks --context $OVERSEER_CONTEXT home=$OVERSEER_HOME_DIR harness=claude" \
  "a record naming no launch home is healed from the session's own home, which binds the transcript on the same turn end" "$ERR_FILE"
new_overseer overseer_other_home
startless_record "{\"server_start\":$OVERSEER_SERVER_START}"
judge_says "$HEADROOM_MARK_LINE"
# shellcheck disable=SC2046
stop_at "$TRANSCRIPT" false $(overseer_env)
assert_eq "RC=$RC first=$(first_line) argv=$(judge_argv | tail -n 1) reason=$(grep -c 'home-mismatch' "$ERR_FILE") home=$(recorded_field home)" \
  "RC=2 first=lane-mail-check: transcript-unowned=$TRANSCRIPT argv=--check-marks --harness claude reason=1 home=$OFFLINE_HOME/.claude" \
  "a session whose own home is not the one its transcript sits under binds nothing, so the account mark decides" "$ERR_FILE"
# That turn end still writes the overseer's context record, with no figure and
# the gate's reason as its gap, so the record advances at every turn end and
# oversee-watch can report why it carries no reading.
gap_record() { jq -r '"\(.tokens) \(.gap) \(.pane_key)"' "$LANE/tmp/lane-mail/overseer/context.json" 2>/dev/null || echo none; }
assert_eq "$(gap_record)" "null home-mismatch $OVERSEER_SERVER $OVERSEER_PANE" \
  "and the context record is written with no reading, the gate's reason as its gap and this pane's key" "$ERR_FILE"
variant no-gap-record -e '/^  \[ -z "\$READ_GAP" \] || overseer_gap_record "\$READ_GAP"$/d'
install_hook "$VARIANT_PATH" "$LANE/.claude/hooks/lane-mail-check.sh"
rm -f -- "${LANE:?}/tmp/lane-mail/overseer/context.json"
# shellcheck disable=SC2046
stop_at "$TRANSCRIPT" false $(overseer_env)
assert_eq "$(gap_record)" "none" \
  "control: a hook that writes no gap record leaves an unowned turn end recording nothing"
install_hook "$HOOK" "$LANE/.claude/hooks/lane-mail-check.sh"

# The record that lost its launch identity: it names this pane on this server
# and carries no server start, no home and no harness, the shape a writer from
# before starts were recorded left and a watch start then kept. It names the
# session in its pane (lib/overseer-launch.sh § ol_unstarted), which is judged
# on its marks and heals the record, so the session is never left judged on
# nothing while it runs into its window. The judge is the real
# oversee-succeed, which answers the reading this turn end hands it with
# `mark-reached kind=context` before it discovers anything else.
lost_identity() { # NAME [HOOK] [STUB]: STUB is a state_stub mode
  new_overseer "$1"
  install_hook "${2:-$HOOK}" "$LANE/.claude/hooks/lane-mail-check.sh"
  rm -f -- "$LANE/.claude/skills/orch/scripts/oversee-succeed"
  ln -s "$REPO_ROOT/skills/orch/scripts/oversee-succeed" "$LANE/.claude/skills/orch/scripts/oversee-succeed"
  startless_record
  [ -z "${3:-}" ] || state_stub "$3"
  # shellcheck disable=SC2046
  stop_at "$TRANSCRIPT" false $(overseer_env) "CLAUDE_CONFIG_DIR=$OVERSEER_HOME_DIR"
  LOST="RC=$RC first=$(first_line) record=$(jq -r '"\(.tokens) \(.gap)"' "$LANE/tmp/lane-mail/overseer/context.json" 2>/dev/null || echo none) start=$(recorded_field server_start) home=$(recorded_field home) harness=$(recorded_field harness)"
}
lost_identity overseer_lost_identity
assert_eq "$LOST" \
  "RC=2 first=lane-mail-check: context=${OVERSEER_CONTEXT%%:*} record=${OVERSEER_CONTEXT%%:*} null start=$OVERSEER_SERVER_START home=$OVERSEER_HOME_DIR harness=claude" \
  "a record naming this pane with no start, home or harness still names this session: the reading is recorded, the context mark is refused, and the record is healed" "$ERR_FILE"
# The start test that reads a record carrying no start as another session's:
# the session is judged on nothing, and nothing is healed.
variant startless-unnamed \
  -e 's/^    elif ol_unstarted(.*/    else "other" end),/'
lost_identity control_lost_identity_start "$VARIANT_PATH"
assert_eq "$LOST" "RC=0 first=- record=none start=none home=none harness=none" \
  "control: a hook that reads a record carrying no start as another session's judges the lost overseer on nothing"
# The heal skipped: the record names no home, the transcript binds to nothing
# and the context mark is left to nothing.
variant no-heal -e 's/^  \[ "\$NEED_HEAL" -eq 1 \] || return 0$/  return 0/'
lost_identity control_lost_identity_heal "$VARIANT_PATH"
assert_eq "$LOST" "RC=0 first=lane-mail-check: transcript-unowned=$TRANSCRIPT record=null home-unnamed start=none home=none harness=none" \
  "control: a hook that heals nothing leaves the lost overseer's transcript unbound and its context mark judged by nothing"
# A heal whose write fails still binds this run to the home the session's own
# environment names: the failure is reported under its own key, the reading is
# taken and the context mark judged, and the record waits for the next run.
lost_identity overseer_lost_unhealed "$HOOK" update-fails
assert_eq "$LOST unhealed=$(grep -c "^lane-mail-check: record-unhealed=$OVERSEER_SERVER $OVERSEER_PANE\$" "$ERR_FILE") mark=$(grep -c "^lane-mail-check: context=${OVERSEER_CONTEXT%%:*}\$" "$ERR_FILE")" \
  "RC=2 first=lane-mail-check: record-unhealed=$OVERSEER_SERVER $OVERSEER_PANE record=${OVERSEER_CONTEXT%%:*} null start=none home=none harness=none unhealed=1 mark=1" \
  "a heal whose write fails is reported, and the run still binds the transcript to the session's own home and judges the mark" "$ERR_FILE"
# The home dropped with the failed write: the transcript binds to nothing.
variant unhealed-unbound -e 's/^    message record-unhealed "\$CALLER_KEY" "\$(cat -- "\$WORK_DIR\/heal.err")"$/&\n    HEAL_HOME=""/'
lost_identity control_lost_unhealed "$VARIANT_PATH" update-fails
assert_eq "${LOST#* record=}" "null home-unnamed start=none home=none harness=none" \
  "control: a hook that drops the home with a failed heal leaves the transcript unbound and the mark judged by nothing"
# A Pi install states no transcript shape, so its overseer binds nothing and
# reads the payload's own window as a Pi lane does; nothing is reported.
new_overseer overseer_pi
# The Pi hook's walk to its reader stops at the lane root, so the planted
# judge is offered where that walk looks, as the codex block below does.
mkdir -p "$LANE/.pi/skills"
ln -s "$LANE/.claude/skills/orch" "$LANE/.pi/skills/orch"
install_hook "$HOOK" "$LANE/.pi/kendex/hooks/lane-mail-check.sh"
PI_TRANSCRIPT="$TMP_ROOT/pi-overseer.jsonl"
usage_line pi 180000 > "$PI_TRANSCRIPT"
judge_says "$HEADROOM_MARK_LINE"
# shellcheck disable=SC2046
run_payload "$(jq -nc --arg p "$PI_TRANSCRIPT" \
  '{session_id:"s1",stop_hook_active:false,transcript_path:$p,context_window:200000}')" $(overseer_env)
assert_eq "argv=$(judge_argv | tail -n 1) unowned=$(grep -c '^lane-mail-check: transcript-unowned' "$ERR_FILE")" \
  "argv=--check-marks --context 180000:200000 unowned=0" \
  "a Pi overseer reads the payload's own window, bound to no transcript shape" "$ERR_FILE"
install_hook "$HOOK" "$LANE/.claude/hooks/lane-mail-check.sh"
# A payload naming no transcript has nothing to bind: the read leaves the
# context unread in silence and the judge is handed the account triggers
# alone, with no `transcript-unowned` line for an empty path.
new_overseer overseer_no_transcript
judge_says "$HEADROOM_MARK_LINE"
# shellcheck disable=SC2046
stop $(overseer_env)
assert_eq "argv=$(judge_argv | tail -n 1) unowned=$(grep -c '^lane-mail-check: transcript-unowned' "$ERR_FILE")" \
  "argv=--check-marks unowned=0" \
  "an overseer payload naming no transcript is read as unread, not reported unowned" "$ERR_FILE"
assert_eq "$(gap_record)" "null transcript-unnamed $OVERSEER_SERVER $OVERSEER_PANE" \
  "and its context record is written with the gap transcript-unnamed" "$ERR_FILE"
# Every other overseer turn end that takes no reading writes the record too,
# with the reader's word for why, and a usage object the adapter does not read
# is reported under its own key as a lane's is: one row per word.
overseer_gap_word() { # NAME TRANSCRIPT_LINE|- [INSTALL_DIR]
  local cop_transcript="$TMP_ROOT/session-state/s1/events.jsonl"
  new_overseer "$1"
  printf '%s\n' "$2" > "$TRANSCRIPT"
  if [ -n "${3:-}" ]; then
    mkdir -p "$LANE/$3"
    ln -s "$LANE/.claude/skills/orch" "$LANE/$3/skills"
    install_hook "$HOOK" "$LANE/$3/hooks/lane-mail-check.sh"
  fi
  judge_says "$HEADROOM_MARK_LINE"
  if [ "${3:-}" = .github ]; then
    # Copilot's own agentStop, the lead's: its transcript sits in the
    # directory named for the session, so the judge records the lead under
    # the world's Copilot home.
    # A TRANSCRIPT_LINE of `-` is an agentStop naming no transcript at all.
    mkdir -p "${cop_transcript%/*}"
    printf '%s\n' "$2" > "$cop_transcript"
    [ "$2" != - ] || cop_transcript=""
    # shellcheck disable=SC2046
    run_payload "$(jq -nc --arg p "$cop_transcript" \
      '{sessionId:"s1", timestamp:1, cwd:"/w", stopReason:"end_turn", stop_hook_active:false}
        + (if $p == "" then {} else {transcriptPath:$p} end)')" \
      "HOME=$COP_HOME" $(overseer_env)
  elif [ "$2" = - ]; then
    # A TRANSCRIPT_LINE of `-` is a Stop naming no transcript at all.
    # shellcheck disable=SC2046
    stop $(overseer_env)
  else
    # shellcheck disable=SC2046
    stop_at "$TRANSCRIPT" false $(overseer_env)
  fi
  printf 'record=%s unread=%s unlisted=%s unrecorded=%s' "$(gap_record)" \
    "$(grep -cFx -- "lane-mail-check: usage-unread=$TRANSCRIPT" "$ERR_FILE")" \
    "$(grep -c '^lane-mail-check: harness-unlisted=' "$ERR_FILE")" \
    "$(grep -c '^lane-mail-check: reading-unrecorded=' "$ERR_FILE")"
}
assert_eq "$(overseer_gap_word overseer_usage_absent '{"type":"user"}')" \
  "record=null usage-absent $OVERSEER_SERVER $OVERSEER_PANE unread=0 unlisted=0 unrecorded=0" \
  "an overseer transcript holding no usage line writes the gap usage-absent" "$ERR_FILE"
assert_eq "$(overseer_gap_word overseer_usage_unread "$(usage_line unread 900000)")" \
  "record=null usage-unread $OVERSEER_SERVER $OVERSEER_PANE unread=1 unlisted=0 unrecorded=0" \
  "a usage object the adapter does not read writes the gap usage-unread and is reported under its own key" "$ERR_FILE"
# An install naming no harness reports that under harness-unlisted and writes
# no gap: its context is never read, so a gap would stand at every turn end
# for the session's life. The harness is decided before the payload's
# transcript, so a Stop naming none writes no gap either, and says nothing:
# there is no transcript to go unread. A Copilot install's turn end reads the
# reading its usage arm records first and writes no gap over it; with none
# standing it reads the statusLine session record, so it writes a gap like
# any read harness: the transcript gate's reason where the payload names a
# transcript under another home, and `session-record`, beside
# reading-unrecorded, where no record answers.
while IFS='|' read -r name install line expected what; do
  assert_eq "$(overseer_gap_word "$name" "$line" "$install")" "$expected" \
    "$what" "$ERR_FILE"
done <<INSTALLS
overseer_unlisted_other|.other|$(usage_line claude 600000)|record=none unread=0 unlisted=1 unrecorded=0|an install naming no harness reports harness-unlisted and writes no gap record
overseer_unlisted_untranscribed|.other|-|record=none unread=0 unlisted=0 unrecorded=0|a Stop naming no transcript in an install naming no harness writes no gap record
overseer_copilot_unowned|.github|$(usage_line claude 600000)|record=null home-mismatch $OVERSEER_SERVER $OVERSEER_PANE unread=0 unlisted=0 unrecorded=0|a Copilot install writes the transcript gate's gap
overseer_copilot_unrecorded|.github|-|record=null session-record $OVERSEER_SERVER $OVERSEER_PANE unread=0 unlisted=0 unrecorded=1|a Copilot agentStop with no extension reading and no statusLine record answering writes the gap session-record and reports reading-unrecorded
INSTALLS
variant unlisted-late -e '/^  if \[ -z "\$HARNESS" \]; then$/,/^  fi$/d'
HOOK_SAVED="$HOOK"
HOOK="$VARIANT_PATH"
assert_eq "$(overseer_gap_word control_unlisted_late - .other)" \
  "record=null transcript-unnamed $OVERSEER_SERVER $OVERSEER_PANE unread=0 unlisted=0 unrecorded=0" \
  "control: a hook that decides the harness after the transcript names a gap for an unnamed harness at every turn end"
HOOK="$HOOK_SAVED"
variant no-session-record-gap -e '/^      READ_GAP=session-record$/d'
HOOK_SAVED="$HOOK"
HOOK="$VARIANT_PATH"
assert_eq "$(overseer_gap_word control_session_record_gap - .github)" \
  "record=none unread=0 unlisted=0 unrecorded=1" \
  "control: a Copilot arm that names no gap leaves an unanswered session record unrecorded"
HOOK="$HOOK_SAVED"
variant no-overseer-unread -e 's/^    \[ "\$READ_GAP" != usage-unread \] || message usage-unread "\$TRANSCRIPT"$/    :/'
HOOK_SAVED="$HOOK"
HOOK="$VARIANT_PATH"
assert_eq "$(overseer_gap_word control_overseer_unread "$(usage_line unread 900000)")" \
  "record=null usage-unread $OVERSEER_SERVER $OVERSEER_PANE unread=0 unlisted=0 unrecorded=0" \
  "control: an overseer arm that drops the usage-unread report leaves the unread figure silent on stderr"
HOOK="$HOOK_SAVED"
write_transcript "$TRANSCRIPT" "${OVERSEER_CONTEXT%%:*}"
# A gap record that cannot be written is reported under its own key, which
# says no reading was taken, and the record keeps its earlier entry.
FAIL_MV_BIN="$TMP_ROOT/fail-mv-bin"; mkdir -p "$FAIL_MV_BIN"
cat > "$FAIL_MV_BIN/mv" <<FAILMV
#!/usr/bin/env bash
case "\${!#}" in
  */context.json) printf '%s\n' 'fixture context write failed' >&2; exit 1 ;;
esac
exec "$(command -v mv)" "\$@"
FAILMV
chmod +x "$FAIL_MV_BIN/mv"
gap_unwritten() {
  new_overseer "$1"
  (cd "$LANE" && "$REPO_ROOT/skills/orch/scripts/workflow-state" set oversee overseer \
    "$(jq -nc --arg s "$OVERSEER_SERVER" --arg p "$OVERSEER_PANE" --argjson start "$OVERSEER_SERVER_START" \
      '{server:$s,server_start:$start,pane:$p,window:"@7"}')" >/dev/null)
  judge_says "$HEADROOM_MARK_LINE"
  # shellcheck disable=SC2046
  stop_at "$TRANSCRIPT" false $(overseer_env) "PATH=$FAIL_MV_BIN:$TMUX_BIN:$PATH"
  printf 'key=%s cause=%s record=%s' \
    "$(grep -cFx -- "lane-mail-check: context-gap-unrecorded=$LANE/tmp/lane-mail/overseer/context.json" "$ERR_FILE")" \
    "$(grep -cFx 'fixture context write failed' "$ERR_FILE")" "$(gap_record)"
}
assert_eq "$(gap_unwritten overseer_gap_unwritten)" "key=1 cause=1 record=none" \
  "a gap record that cannot be written is reported under its own key with the cause below it" "$ERR_FILE"
variant gap-key-shared -e 's/^    message context-gap-unrecorded /    message context-unrecorded /'
HOOK_SAVED="$HOOK"
HOOK="$VARIANT_PATH"
assert_eq "$(gap_unwritten control_gap_unwritten)" "key=0 cause=1 record=none" \
  "control: a gap write failure reported under the reading's key says a reading was taken"
HOOK="$HOOK_SAVED"
# Control: with the ownership gate gone the predecessor's foreign file is read
# and its reading handed to the judge, the very thing the gate prevents.
new_overseer overseer_binding_control
variant read-any-transcript -e 's/^  if overseer_transcript_owned; then$/  if true; then/'
install_hook "$VARIANT_PATH" "$LANE/.claude/hooks/lane-mail-check.sh"
judge_says "$HEADROOM_MARK_LINE"
# shellcheck disable=SC2046
owned_payload s2 "$TRANSCRIPT" $(overseer_env)
assert_eq "argv=$(judge_argv | tail -n 1)" "argv=--check-marks --context 600000:1000000" \
  "control: without the ownership gate a session reads a transcript it does not own"
install_hook "$HOOK" "$LANE/.claude/hooks/lane-mail-check.sh"

for mark_row in \
  "rate|$RATE_MARK_LINE|30|ORCH_OVERSEER_WALL_MINUTES" \
  "qualifying|$QUALIFYING_MARK_LINE|1|ORCH_OVERSEER_SUCCESSOR_ACCOUNTS"; do
  IFS='|' read -r mark_kind mark_line mark_value mark_setting <<<"$mark_row"
  new_overseer "overseer_$mark_kind"
  judge_says "$mark_line"
  # shellcheck disable=SC2046
  stop_at "$TRANSCRIPT" false $(overseer_env)
  expect 2 "lane-mail-check: $mark_kind=$mark_value" \
    "an overseer at its $mark_kind mark is refused with the value it read"
  assert_eq "setting=$(grep -cF -- "$mark_setting" "$ERR_FILE") route=$(overseer_route)" \
    "setting=1 route=1" "and the refusal names the setting and succession route"
done
# The qualifying mark fires where this session's own account was not measured
# above the trigger, so its refusal carries the headroom the judgement read and
# an unread account does not pass for a fleet down to one.
assert_eq "$(grep -cF -- "reads headroom=unreadable" "$ERR_FILE")" "1" \
  "the qualifying refusal carries the headroom the judgement read for this session"

# What the marks cannot judge is reported and passed, never refused: an
# overseer whose marks nothing could measure must still end a turn, exactly as
# a lane whose account nothing measured does.
new_overseer overseer_gaps
judge_says "oversee-succeed: mark-unmeasured kind=headroom reason=headroom-unreadable succession=on"
# shellcheck disable=SC2046
stop_at "$TRANSCRIPT" false $(overseer_env)
expect 0 "lane-mail-check: marks=unmeasured" \
  "a reading the judgement could not take is reported and the turn ends"
assert_eq "$(grep -cF -- "reason=headroom-unreadable" "$ERR_FILE")" "1" \
  "with the judge's own line under it, naming the figure that was missing"
printf '3\n' > "$JUDGE_DIR/rc"
printf 'oversee-succeed: pane-unreadable pane=%s\n' "$OVERSEER_PANE" > "$JUDGE_DIR/err"
# shellcheck disable=SC2046
stop_at "$TRANSCRIPT" false $(overseer_env)
assert_eq "RC=$RC first=$(first_line) cause=$(grep -c 'oversee-succeed: pane-unreadable' "$ERR_FILE")" \
  "RC=0 first=lane-mail-check: marks=unjudged cause=1" \
  "a judgement that did not answer is reported with its own words and the turn ends"
rm -f -- "${JUDGE_DIR:?}/rc" "${JUDGE_DIR:?}/err"
judge_says "oversee-succeed: mark-reached kind=context mark=500000 succession=on"
# shellcheck disable=SC2046
stop_at "$TRANSCRIPT" false $(overseer_env)
expect 0 "lane-mail-check: marks=unjudged" \
  "a reached mark naming no figure is an answer this hook cannot act on, and the turn ends"

# The judgement reads every account the fleet can launch on, which can outlast
# this hook's budget; a hook killed at its budget writes no line at all.
if command -v timeout >/dev/null 2>&1; then
  variant short-real-judge -e 's@^ACCOUNT_CEILING=20$@ACCOUNT_CEILING=3@'
  new_overseer overseer_fast_context
  install_hook "$VARIANT_PATH" "$LANE/.claude/hooks/lane-mail-check.sh"
  rm -f -- "$LANE/.claude/skills/orch/scripts/oversee-succeed" \
    "$LANE/.claude/skills/orch/scripts/lanes"
  ln -s "$REPO_ROOT/skills/orch/scripts/oversee-succeed" \
    "$LANE/.claude/skills/orch/scripts/oversee-succeed"
  cat > "$LANE/.claude/skills/orch/scripts/lanes" <<'SLOWCAPACITY'
#!/bin/sh
case " $* " in
  *" --lane "*)
    printf '%s\n' '{"wall":20,"alias":"claude","binding_resets_at":"2026-09-24T00:00:00Z","usage_rate_state":"not-increasing","projected_wall_minutes":null}'
    ;;
  *) sleep 120 ;;
esac
SLOWCAPACITY
  chmod +x "$LANE/.claude/skills/orch/scripts/lanes"
  REAL_TMUX_BIN="$TMP_ROOT/real-tmux-bin"; mkdir -p "$REAL_TMUX_BIN"
  # The caller pane is $TMUX_PANE, read through overseer-host-tmux inspect:
  # the listing, window, server, capture and liveness reads, the pane pid
  # unprobed while the command is no bare shell, and the server's start the
  # record is bound by, TMUX_SERVER_START.
  cat > "$REAL_TMUX_BIN/tmux" <<'REALTMUX'
#!/bin/sh
case " $* " in
  *" list-panes "*) printf '%s\n' "$TMUX_PANE" ;;
  *" capture-pane "*) ;;
  *"#{pane_pid} #{pane_current_command}"*) printf '9000 %s\n' "${FIXTURE_TMUX_COMMAND:-claude}" ;;
  *"#{pid} #{start_time}"*) printf '%s %s\n' "$FIXTURE_TMUX_SERVER" "$TMUX_SERVER_START" ;;
  *"#{pid}"*) printf '%s\n' "$FIXTURE_TMUX_SERVER" ;;
  *"#{window_id}"*) printf '%s\n' '@7' ;;
  *"#{pane_current_path}"*) printf '%s\n' "$FIXTURE_TMUX_PATH" ;;
  *"#{pane_current_command}"*) printf '%s\n' "${FIXTURE_TMUX_COMMAND:-claude}" ;;
  *) exit 1 ;;
esac
REALTMUX
  chmod +x "$REAL_TMUX_BIN/tmux"
  # The real judge handles a node pane before slow capacity or a stored identity.
  # The record names no harness, and the turn end heals it with this install's,
  # so the context-after-identity judge meets no harness-unnamed refusal; it
  # still reads the account before the due reading and answers nothing the
  # hook can act on.
  mkdir -p "$LANE/.codex/skills"
  ln -s "$LANE/.claude/skills/orch" "$LANE/.codex/skills/orch"
  install_hook "$VARIANT_PATH" "$LANE/.codex/hooks/lane-mail-check.sh"
  # This block runs the codex hook, so the ownership gate holds the payload's
  # transcript to a codex rollout under the recorded codex launch home. The
  # session s1 owns this file under CODEX_OVERSEER_HOME by the shape
  # lib/adapters/codex.sh names, and the record carries that home.
  CODEX_OVERSEER_HOME="$TMP_ROOT/codex-overseer-home"
  CODEX_TRANSCRIPT="$CODEX_OVERSEER_HOME/sessions/2026/09/27/rollout-2026-09-27T00-00-00-s1.jsonl"
  mkdir -p "$(dirname "$CODEX_TRANSCRIPT")"
  record_overseer "$OVERSEER_PANE" "$OVERSEER_SERVER" "$CODEX_OVERSEER_HOME"
  usage_line codex 400000 > "$CODEX_TRANSCRIPT"
  REAL_SUCCEED="$LANE/.claude/skills/orch/scripts/oversee-succeed"
  EARLY_RESULT='if [[ "$MODE" == check && "$CONTEXT_STATE" == due ]]; then'
  assert_eq "$(grep -cF -- "$EARLY_RESULT" "$REAL_SUCCEED")" 1 'the context-order control finds its result once'
  HOOK="$REAL_SUCCEED" variant context-after-identity \
    -e 's/if \[\[ "$MODE" == check \&\& "$CONTEXT_STATE" == due \]\]; then/if [[ "$MODE" == check \&\& "$CONTEXT_STATE" == due \&\& 0 == 1 ]]; then/'
  REAL_MV="$(command -v mv)"
  cat > "$REAL_TMUX_BIN/mv" <<'FAILWRITE'
#!/usr/bin/env bash
case "$FIXTURE_WRITE:${!#}" in
  failed:*/context.json) printf '%s\n' 'fixture context write failed' >&2; exit 1 ;;
esac
exec "$FIXTURE_REAL_MV" "$@"
FAILWRITE
  chmod +x "$REAL_TMUX_BIN/mv"
  while IFS='|' read -r writer judge expected; do
    rm -f -- "${REAL_SUCCEED:?}" "${LANE:?}/tmp/lane-mail/overseer/context.json"
    cp "$judge" "$REAL_SUCCEED"
    chmod +x "$REAL_SUCCEED"
    # shellcheck disable=SC2046
    stop_at "$CODEX_TRANSCRIPT" false $(overseer_env) "PATH=$REAL_TMUX_BIN:$PATH" \
      "FIXTURE_TMUX_SERVER=$OVERSEER_SERVER" "FIXTURE_TMUX_PATH=$LANE" \
      FIXTURE_TMUX_COMMAND=node "FIXTURE_REAL_MV=$REAL_MV" "FIXTURE_WRITE=$writer" ORCH_OVERSEER_SUCCESSOR_ACCOUNTS=1
    record=none
    [[ ! -f "$LANE/tmp/lane-mail/overseer/context.json" ]] || \
      record="$(jq -r '"\(.tokens) \(.window) \(.pane_key)"' "$LANE/tmp/lane-mail/overseer/context.json")"
    assert_eq "$RC|$(grep -E '^lane-mail-check: (context=[0-9]+|marks=unjudged)$' "$ERR_FILE")|$(grep -c '^fixture context write failed$' "$ERR_FILE")|$(grep -c '^oversee-succeed: harness-unnamed ' "$ERR_FILE")|$(grep -cFx "lane-mail-check: context-unrecorded=$LANE/tmp/lane-mail/overseer/context.json" "$ERR_FILE")|$record" \
      "$expected" "actual marks: writer=$writer judge=${judge##*/} preserves the live due reading"
  done <<ROWS
kept|$REPO_ROOT/skills/orch/scripts/oversee-succeed|2|lane-mail-check: context=400000|0|0|0|400000 258400 $OVERSEER_SERVER $OVERSEER_PANE
failed|$REPO_ROOT/skills/orch/scripts/oversee-succeed|2|lane-mail-check: context=400000|1|0|1|none
failed|$VARIANT_PATH|0|lane-mail-check: marks=unjudged|1|0|1|none
ROWS
  write_transcript "$TRANSCRIPT" 600000

  variant short-judge -e 's@^ACCOUNT_CEILING=20$@ACCOUNT_CEILING=1@'
  new_overseer overseer_ceiling
  install_hook "$VARIANT_PATH" "$LANE/.claude/hooks/lane-mail-check.sh"
  judge_says "$CONTEXT_MARK_LINE"
  touch "$JUDGE_DIR/hang"
  # shellcheck disable=SC2046
  stop_at "$TRANSCRIPT" false $(overseer_env)
  expect 0 "lane-mail-check: marks=timeout" \
    "a judgement that passes the ceiling is reported as a gap and the turn ends"
  rm -f -- "${JUDGE_DIR:?}/hang"
else
  printf '  skip  a judgement past the ceiling: this host has no timeout to bound it with\n'
fi

# What is NOT an overseer. Each row is the same session, the judgement standing
# at a reached mark, with one leg of the identification missing, and each must
# end its turn in silence without the judgement being asked at all: a test that
# took every session with no lane for the overseer would hold an ordinary
# session's turn end on marks nobody set for it.
new_overseer overseer_identity
judge_says "$CONTEXT_MARK_LINE"
# shellcheck disable=SC2046
stop_at "$TRANSCRIPT" false $(overseer_env "%3")
assert_eq "RC=$RC first=$(first_line) judged=$(judge_calls)" "RC=0 first=- judged=0" \
  "a pane the fleet state does not name is no overseer and is judged on nothing"
record_overseer "$OVERSEER_PANE" 7001
# shellcheck disable=SC2046
stop_at "$TRANSCRIPT" false $(overseer_env)
expect 0 - "the same pane id on another tmux server is another session, not this overseer"
record_overseer "$OVERSEER_PANE" "$OVERSEER_SERVER"
stop_at "$TRANSCRIPT" false "PATH=$TMUX_BIN:$PATH"
expect 0 - "a session outside tmux has no pane to be the overseer's"
(cd "$LANE" && "$REPO_ROOT/skills/orch/scripts/workflow-state" init oversee >/dev/null)
# shellcheck disable=SC2046
stop_at "$TRANSCRIPT" false $(overseer_env)
assert_eq "RC=$RC first=$(first_line) judged=$(judge_calls)" "RC=0 first=- judged=0" \
  "a fleet state recording no overseer names nobody, so nobody is judged"

# The overseer the fleet record lost: the record names another pane, while the
# overseer's context record names this one, which only its own turn ends
# write. Its turn end is judged on no mark, reports the gap under its own key
# with the recorded pane key under it, and still writes the context record,
# with no figure and the gap `pane-unrecorded`, turn after turn. A session in
# a third pane the context record does not name is an ordinary one and writes
# nothing over it.
new_overseer overseer_unrecorded
judge_says "$HEADROOM_MARK_LINE"
# shellcheck disable=SC2046
stop_at "$TRANSCRIPT" false $(overseer_env)
record_overseer %4 "$OVERSEER_SERVER"
unrecorded_rows() { # CALLER_PANE
  # shellcheck disable=SC2046
  stop_at "$TRANSCRIPT" false $(overseer_env "$1")
  printf 'RC=%s first=%s recorded=%s judged=%s record=%s' "$RC" "$(first_line)" \
    "$(grep -cFx -- "$OVERSEER_SERVER %4" "$ERR_FILE")" "$(judge_calls)" "$(gap_record)"
}
assert_eq "$(unrecorded_rows "$OVERSEER_PANE")" \
  "RC=0 first=lane-mail-check: pane-unrecorded=$OVERSEER_SERVER $OVERSEER_PANE recorded=1 judged=1 record=null pane-unrecorded $OVERSEER_SERVER $OVERSEER_PANE" \
  "a session whose own reading the context record holds, and the fleet record no longer names, reports it and writes the gap" "$ERR_FILE"
assert_eq "$(unrecorded_rows "$OVERSEER_PANE")" \
  "RC=0 first=lane-mail-check: pane-unrecorded=$OVERSEER_SERVER $OVERSEER_PANE recorded=1 judged=1 record=null pane-unrecorded $OVERSEER_SERVER $OVERSEER_PANE" \
  "and does so again at its next turn end, over its own gap record" "$ERR_FILE"
assert_eq "$(unrecorded_rows %3)" \
  "RC=0 first=- recorded=0 judged=1 record=null pane-unrecorded $OVERSEER_SERVER $OVERSEER_PANE" \
  "a session in a pane neither record names is ordinary and writes nothing over the overseer's record" "$ERR_FILE"
variant any-pane-unrecorded -e '/^  \[ "\$LANE_CTX_PANE_KEY" = "\$CALLER_KEY" \] || return 0$/d'
install_hook "$VARIANT_PATH" "$LANE/.claude/hooks/lane-mail-check.sh"
assert_eq "$(unrecorded_rows %3)" \
  "RC=0 first=lane-mail-check: pane-unrecorded=$OVERSEER_SERVER %3 recorded=1 judged=1 record=null pane-unrecorded $OVERSEER_SERVER %3" \
  "control: without the pane test an ordinary session overwrites the overseer's record"
variant no-unrecorded -e 's/^      overseer_unrecorded$/      :/'
install_hook "$VARIANT_PATH" "$LANE/.claude/hooks/lane-mail-check.sh"
record_overseer "$OVERSEER_PANE" "$OVERSEER_SERVER"
# shellcheck disable=SC2046
stop_at "$TRANSCRIPT" false $(overseer_env)
record_overseer %4 "$OVERSEER_SERVER"
assert_eq "$(unrecorded_rows "$OVERSEER_PANE")" \
  "RC=0 first=- recorded=0 judged=2 record=600000 null $OVERSEER_SERVER $OVERSEER_PANE" \
  "control: a hook that skips the lost overseer leaves its record standing, stale and silent"
install_hook "$HOOK" "$LANE/.claude/hooks/lane-mail-check.sh"
# A fleet state that cannot be read names no pane at all: the session whose
# reading the context record holds is not taken for the overseer the record
# lost, and its record stands as it was.
state_unread() { # NAME
  new_overseer "$1"
  judge_says "$HEADROOM_MARK_LINE"
  # shellcheck disable=SC2046
  stop_at "$TRANSCRIPT" false $(overseer_env)
  plant_install workflow-state
  printf '#!/bin/sh\ncase "$1" in\n  path) echo "%s/tmp/workflow-state-oversee.json" ;;\n  *) echo "workflow-state: lock-failed lock-file=x" >&2; exit 3 ;;\nesac\n' "$LANE" \
    > "$LANE/.claude/skills/orch/scripts/workflow-state"
  chmod +x "$LANE/.claude/skills/orch/scripts/workflow-state"
  # shellcheck disable=SC2046
  stop_at "$TRANSCRIPT" false $(overseer_env)
  printf 'RC=%s first=%s record=%s' "$RC" "$(first_line)" "$(gap_record)"
}
assert_eq "$(state_unread overseer_state_unread)" "RC=0 first=- record=600000 null $OVERSEER_SERVER $OVERSEER_PANE" \
  "a fleet state that cannot be read writes no pane-unrecorded gap over the overseer's reading" "$ERR_FILE"
variant ungated-unrecorded -e '/^  \[ "\$OVERSEER_UNRECORDED" -eq 1 \] || return 0$/d'
HOOK_SAVED="$HOOK"
HOOK="$VARIANT_PATH"
# The path's first read of CALLER_KEY, unset by the failed read, stops the
# hook on both shells; bash 3.2 then exits with its EXIT trap's 0, bash 5 with
# 1, so the error line is the witness and the status is not.
assert_eq "$(state_unread control_state_unread >/dev/null; grep -c ': CALLER_KEY: unbound variable$' "$ERR_FILE")" "1" \
  "control: without the unrecorded gate a fleet state that cannot be read reaches the lost-overseer path" "$ERR_FILE"
HOOK="$HOOK_SAVED"

# The mailbox rules are untouched: an overseer's checkout carries the fleet's
# own mailbox directory, and its branch names no mailbox in it.
new_overseer overseer_mailbox
mkdir -p "$LANE/tmp/lane-mail/overseer"
judge_says "$CONTEXT_MARK_LINE"
# shellcheck disable=SC2046
stop_at "$TRANSCRIPT" false $(overseer_env)
expect 2 "lane-mail-check: context=612000" \
  "the fleet mailbox in the overseer's own checkout names no lane, and the marks are judged"

# Succession off passes an account mark, which the watch judges and reports
# every pass. The context mark is judged by this hook alone, so it is refused
# whatever the setting, with the handoff record as the route once the
# succession refuses as off. The setting is read off the judgement's own line
# and nowhere else, so a spelling this hook would take for `on` and that
# script refuses cannot exist.
new_overseer overseer_succession_off
judge_says "$OFF_HEADROOM_LINE"
# shellcheck disable=SC2046
stop_at "$TRANSCRIPT" false $(overseer_env)
assert_eq "RC=$RC first=$(first_line)" "RC=0 first=-" \
  "an account crossing whose line says the succession is off ends the turn"
judge_says "$OFF_MARK_LINE"
# shellcheck disable=SC2046
stop_at "$TRANSCRIPT" false $(overseer_env)
assert_eq "RC=$RC first=$(first_line) record=$(overseer_record_named)" \
  "RC=2 first=lane-mail-check: context=612000 record=1" \
  "a context crossing is refused with the succession off, naming the record that ends it"
judge_says "$HEADROOM_MARK_LINE"
# shellcheck disable=SC2046
stop_at "$TRANSCRIPT" false $(overseer_env) ORCH_OVERSEER_SUCCESSION=off
expect 2 "lane-mail-check: headroom=4" \
  "and the setting in the environment decides nothing here: the line does"

# The command the overseer's route names has to be in the install, or the
# refusal sends it to one it has not got.
new_overseer overseer_script
plant_install oversee-succeed
# shellcheck disable=SC2046
stop_at "$TRANSCRIPT" false $(overseer_env)
assert_eq "RC=$RC first=$(first_line) record=$(overseer_record_named)" \
  "RC=2 first=lane-mail-check: script=$LANE/.claude/skills/orch/scripts/oversee-succeed record=1" \
  "an install with no oversee-succeed is refused, with the record that still clears it"

# A subagent of the overseer runs its own window on its own turn, as a lane's
# does.
new_overseer overseer_subagent
judge_says "$CONTEXT_MARK_LINE"
run_payload "$(jq -nc --arg p "$TRANSCRIPT" \
  '{session_id:"s1",stop_hook_active:false,agent_id:"a1",transcript_path:$p}')" \
  $(overseer_env)
assert_eq "RC=$RC first=$(first_line) judged=$(judge_calls)" "RC=0 first=- judged=0" \
  "a subagent of the overseer is judged on neither mark"

# The qualifying refusal's headroom field: its parse gone, the refusal reads
# the account as unmeasured whatever the judgement said.
mutant no-headroom -e '/^      headroom=\*) MARK_HEADROOM=\${field#headroom=} ;;$/d'
new_overseer control_headroom
install_hook "$MUTANT_PATH" "$LANE/.claude/hooks/lane-mail-check.sh"
judge_says "${QUALIFYING_MARK_LINE% headroom=*} headroom=40"
# shellcheck disable=SC2046
stop_at "$TRANSCRIPT" false $(overseer_env)
assert_eq "RC=$RC read=$(grep -cF -- "reads headroom=40" "$ERR_FILE")" "RC=2 read=0" \
  "control: without the headroom parse the qualifying refusal drops the figure the judgement read"

mutant no-block -e 's@^  refuse unread "\$COUNT"$@  acknowledge; exit 0@'
BLOCK_MUTANT="$MUTANT_PATH"
new_lane control ken-11
send KEN-11 'Block me.'
install_hook "$BLOCK_MUTANT" "$LANE/.claude/hooks/lane-mail-check.sh"
stop
expect 0 - "control: without its refusal the hook lets the turn end with the message unread"

mutant unbound -e 's@^  \[ "\$BOUND" != "\$ROOT" \] || LAUNCHED=yes$@  LAUNCHED=yes@'
unlaunched control_unmarked KEN-22 "" "$MUTANT_PATH"
expect 2 "lane-mail-check: unread=1" "control: without the marker rule a committed mailbox poses as a lane"

# The acknowledgement moved ahead of the refusal, both still made: killed
# between them, the hook has consumed a directive it never showed.
mutant ack-first -e 's@^  ACK_LINES=\$LINES$@  ACK_LINES=$LINES; acknowledge; ACK_LINES=""@'
killed_stop control_killed KEN-19 2 "$MUTANT_PATH"
assert_eq "$KILLED" "lost" "control: acknowledged before its refusal, a killed hook consumes the directive unseen"

# The containment rule's control: its refusal arm replaced by the assignment
# it guards, so the repository's script runs and leaves its marker.
mutant no-containment -e 's@^        return 2$@        READER="$ROOT/.agents/skills/orch/scripts/lane-mail"@'
OPEN_MUTANT="$MUTANT_PATH"
new_lane control_open ken-13
send KEN-13 'run me'
OPEN_MARKER="$TMP_ROOT/open-ran"
plant_reader "$OPEN_MARKER"
install_hook "$OPEN_MUTANT" "$TMP_ROOT/open-elsewhere/hooks/lane-mail-check.sh"
stop
assert_eq "$([ -e "$OPEN_MARKER" ] && echo ran || echo not-run)" "ran" \
  "control: without the containment rule the repository's own script runs"

# The shared tree is one rule offered at two sites, the walk and the home, so
# the mutant removes both; either site alone still answers the other's world.
mutant no-shared-tree \
  -e 's@ "\$AT/.agents/skills/orch/scripts/lane-mail"; do$@; do@' \
  -e 's@^    \[ ! -x "\$CANDIDATE" \] || READER="\$CANDIDATE"$@    :@'
SHARED_MUTANT="$MUTANT_PATH"
new_lane control_shared ken-15
send KEN-15 'Reached the global install.'
rm -f "$LANE/.claude/skills/orch" "$LANE/.agents/skills/orch/scripts"
global_home home-control
install_hook "$SHARED_MUTANT" "$GLOBAL_HOME/.claude/hooks/lane-mail-check.sh"
stop "HOME=$GLOBAL_HOME"
expect 2 "lane-mail-check: reader-outside=$LANE/.agents/skills/orch/scripts/lane-mail" \
  "control: without the shared tree the global install finds no reader"
install_hook "$SHARED_MUTANT" "$TMP_ROOT/opt-control/codex/hooks/lane-mail-check.sh"
stop "HOME=$GLOBAL_HOME"
expect 2 "lane-mail-check: reader-outside=$LANE/.agents/skills/orch/scripts/lane-mail" \
  "control: without it a relocated harness root finds none either"

# The tool a call names, Bash unless a case names the harness question tool;
# the payload names the command the lane is about to run.
TOOL_NAME=Bash
tool() { # ARM [COMMAND] [FIELD] — FIELD, agent_id or agent_type, marks a subagent's call
  local judge="$CASE_HOOK"
  CASE_HOOK="$LANE/.claude/hooks/lane-mail-$1.sh"
  run_payload "$(jq -nc --arg n "$TOOL_NAME" --arg c "${2:-git status}" --arg f "${3:-}" \
    '{tool_name: $n, tool_input: {command: $c}} + (if $f == "" then {} else {($f): "dev-1"} end)')"
  CASE_HOOK="$judge"
}

# An install with no orch skill beside the hook and nothing in the mailbox:
# there is nothing to hand over and nothing to record a handoff with either, so
# every arm ends rather than holding a lane it cannot help.
new_lane noreader_empty ken-60
mkdir -p "$LANE/tmp/lane-mail/KEN-60"
install_arms
rm -f "$LANE/.claude/skills/orch" "$LANE/.agents/skills/orch/scripts"
EMPTY_READER="$LANE/.agents/skills/orch/scripts/lane-mail"
stop
expect 0 "lane-mail-check: handoff-skipped=$EMPTY_READER" \
  "a launched lane with an empty mailbox and no reader ends its turn, reporting the gap"
tool deliver
assert_eq "RC=$RC context=$(context_line) stderr=$(first_line)" "RC=0 context=- stderr=-" \
  "the same lane's finished tool call carries nothing and says nothing"
tool halt
expect 0 - "the same lane's next tool call runs"

# A reader the open repository supplies, on a lane with an empty mailbox: the
# marks cannot be judged with a script this hook is not installed beside, and
# that gap has its own key. Sent to install a skill, an operator whose skill is
# installed inside the repository would look for a fault that is not there.
new_lane outside_empty ken-64
mkdir -p "$LANE/tmp/lane-mail/KEN-64"
OUTSIDE_READER="$LANE/.agents/skills/orch/scripts/lane-mail"
plant_reader "$TMP_ROOT/outside-empty-ran"
install_hook "$HOOK" "$TMP_ROOT/outside-empty/hooks/lane-mail-check.sh"
stop
assert_eq "RC=$RC first=$(first_line) ran=$([ -e "$TMP_ROOT/outside-empty-ran" ] && echo ran || echo not-run)" \
  "RC=0 first=lane-mail-check: handoff-outside=$OUTSIDE_READER ran=not-run" \
  "a reader only the open repository supplies leaves the marks unjudged under its own key, unrun"

new_lane arms ken-30
install_arms
send KEN-30 'Rebase first.'
tool halt
expect 0 - "an unread directive that is no halt passes the tool call"
tool deliver
assert_eq "RC=$RC context=$(context_line) stderr=$(first_line)" \
  "RC=0 context=PostToolUse lane-mail-check: unread=1 stderr=-" \
  "a directive reaches a working lane in the context its next tool call's hook output carries"
assert_eq "$(jq -r '.hookSpecificOutput.additionalContext' "$TMP_ROOT/stdout" | grep -cF 'Rebase first.')" "1" \
  "that context carries the directive itself"
tool deliver
assert_eq "RC=$RC context=$(context_line)" "RC=0 context=-" "a finished tool call with nothing unread carries nothing"

send KEN-30 'Stop pushing.' --halt
HALT_ID=$(jq -r 'select(.halt == true) | .id' "$LANE/tmp/lane-mail/KEN-30/to-lane.jsonl")
printf -v READ_HALT '%q inbox --item %q --root %q' "$LANE/.claude/skills/orch/scripts/lane-mail" KEN-30 "$LANE"
tool halt
expect 2 "lane-mail-check: halt=$HALT_ID" "an unread halt refuses the next tool call"
assert_eq "directive=$(grep -cF 'Stop pushing.' "$ERR_FILE") command=$(grep -cxF -- "$READ_HALT" "$ERR_FILE")" \
  "directive=1 command=1" "the halt refusal carries the directive and the one command that reads it"
tool deliver
tool halt
expect 2 "lane-mail-check: halt=$HALT_ID" "a deliver run leaves the halt standing"
stop
tool halt
expect 2 "lane-mail-check: halt=$HALT_ID" "a stop run leaves the halt standing"
tool halt "$READ_HALT"
expect 0 - "the one command that reads the halt passes while it stands"
"$LANE_MAIL" inbox --item KEN-30 --root "$LANE" >/dev/null
tool halt
expect 0 - "a halt read by the inbox passes"

# A mailbox refusal carries no handoff instruction and pays for none. The
# instruction is built at its own site, so nothing below the reader resolves
# runs `workflow-state` to decide whether the item has a state file yet.
new_lane halt_no_state ken-88
mkdir -p "$LANE/tmp/lane-mail/KEN-88"
install_arms
plant_install workflow-state
STATE_LOG="$TMP_ROOT/halt-state-calls"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> %s\nexit 3\n' "$STATE_LOG" \
  > "$LANE/.claude/skills/orch/scripts/workflow-state"
chmod +x "$LANE/.claude/skills/orch/scripts/workflow-state"
send KEN-88 'Stop here.' --halt
HALT_88=$(jq -r 'select(.halt == true) | .id' "$LANE/tmp/lane-mail/KEN-88/to-lane.jsonl")
tool halt
assert_eq "RC=$RC first=$(first_line) state=$([ -s "$STATE_LOG" ] && echo ran || echo none)" \
  "RC=2 first=lane-mail-check: halt=$HALT_88 state=none" \
  "a halt refusal runs no workflow-state: it carries no instruction to build"

# A lane asks its overseer only through lane mail: the harness question tool
# opens a dialog on a pane the overseer never reads. The halt arm refuses it
# in a launched lane by the name the payload carries, one row per harness's
# spelling, and names the route; a halt already standing is refused first.
new_lane question_tool ken-40
mkdir -p "$LANE/tmp/lane-mail/KEN-40"
install_arms
for TOOL_NAME in AskUserQuestion EnterPlanMode request_user_input question; do
  tool halt
  expect 2 "lane-mail-check: question-tool=$TOOL_NAME" "the $TOOL_NAME tool is refused in a launched lane"
done
TOOL_NAME=AskUserQuestion
tool halt
printf -v ASK_ROUTE 'ask --item %q --root %q --file [PATH]' KEN-40 "$LANE"
printf -v WAIT_ROUTE 'wait --item %q --root %q --id [MSGID]' KEN-40 "$LANE"
assert_eq "$(grep -cF -- "$ASK_ROUTE" "$ERR_FILE") $(grep -cF -- "$WAIT_ROUTE" "$ERR_FILE")" "1 1" \
  "the refusal names the ask send and the wait on its id, each rooted at the lane, once each"
tool halt 'git status' agent_id
expect 2 "lane-mail-check: question-tool=AskUserQuestion" "a subagent's question tool call is refused too"
assert_eq "$(grep -c -- 'ask --item' "$ERR_FILE")" "0" \
  "and is shown no command: lane mail is the lead's, so it reports the question up"
TOOL_NAME=Bash
tool halt
expect 0 - "any other tool passes the same lane"
# Unread mail that holds no halt is the mailbox check's pass, not the call's:
# the question tool is still judged behind it, for the lead and a subagent
# alike, and the line stays unread for the deliver arm to hand over.
send KEN-40 'Rebase onto main.'
TOOL_NAME=AskUserQuestion
tool halt
expect 2 "lane-mail-check: question-tool=AskUserQuestion" \
  "a directive unread in the mailbox does not pass the lead's question tool call"
tool halt 'git status' agent_id
expect 2 "lane-mail-check: question-tool=AskUserQuestion" "nor a subagent's"
TOOL_NAME=Bash
tool halt
expect 0 - "a Bash call on that lane still passes"
tool deliver
assert_eq "RC=$RC context=$(context_line)" "RC=0 context=PostToolUse lane-mail-check: unread=1" \
  "and leaves the directive unread for the deliver arm"
send KEN-40 'Stop.' --halt
TOOL_NAME=AskUserQuestion
tool halt
expect 2 "lane-mail-check: halt=$(jq -r 'select(.halt == true) | .id' "$LANE/tmp/lane-mail/KEN-40/to-lane.jsonl")" \
  "an unread halt is refused ahead of the question tool"

# The marker rule decides lane-ness here as for the mailbox: a committed
# mailbox and status file with no launch marker pose as no lane, and a
# session that is no lane keeps its question tool.
new_lane question_unmarked ken-41
mkdir -p "$LANE/tmp/lane-mail/KEN-41"
: > "$LANE/tmp/lane-status-KEN-41.md"
install_arms
unmark_lanes
tool halt
expect 0 - "a committed mailbox and status file with no launch marker keep the question tool"
new_lane question_plain ken-42
install_arms
unmark_lanes
tool halt
expect 0 - "a session that is no lane keeps its question tool"
TOOL_NAME=Bash

# Lane mail is the lead's: a subagent's call, marked by either field a harness
# sends, neither takes it nor clears a halt.
for row in agent_id:KEN-36 agent_type:KEN-37; do
  field=${row%%:*} item=${row#*:}
  new_lane "sub_$field" "$(printf '%s' "$item" | tr 'A-Z' 'a-z')"
  install_arms
  send "$item" 'Rebase again.'
  tool deliver "git status" "$field"
  tool deliver
  assert_eq "RC=$RC context=$(context_line)" "RC=0 context=PostToolUse lane-mail-check: unread=1" \
    "a subagent's call marked by $field leaves the directive unread for the lead's next call"
  send "$item" 'Stop again.' --halt
  SUB_HALT=$(jq -r 'select(.halt == true) | .id' "$LANE/tmp/lane-mail/$item/to-lane.jsonl")
  printf -v SUB_READ '%q inbox --item %q --root %q' "$LANE/.claude/skills/orch/scripts/lane-mail" "$item" "$LANE"
  tool halt "$SUB_READ" "$field"
  expect 2 "lane-mail-check: halt=$SUB_HALT" \
    "a subagent's call marked by $field carrying the acknowledging command is refused while a halt stands"
  tool halt
  expect 2 "lane-mail-check: halt=$SUB_HALT" "the halt still stands for the lead after the $field refusal"
done

ARM_ARGS=(bogus)
stop
ARM_ARGS=()
expect 2 "lane-mail-check: arm=bogus" "an arm the judge does not know is refused"
rm -f "$LANE/.claude/hooks/lane-mail-check.sh"
for name in deliver halt; do
  tool "$name"
  expect 2 "lane-mail-$name: judge=$LANE/.claude/hooks/lane-mail-check.sh" \
    "the $name hook with no judge beside it refuses, never passes"
done

# The judges read the lane's own mailbox whatever checkout a call is made
# from: a lane runs its post-merge steps from the main clone, which has no
# mailbox of its own. Claude Code names the directory the session started in;
# a harness that names none reaches the lane through the launch marker for the
# item its brief set. With neither the call's own checkout answers, and the
# main clone is no lane.
new_worktree_lane from_main ken-95
install_arms
send KEN-95 'Hold the merge.' --halt
HALT_95=$(jq -r 'select(.halt == true) | .id' "$LANE/tmp/lane-mail/KEN-95/to-lane.jsonl")
CALL_DIR="$MAIN"
# Each row: the variable the harness sets, the status, the keyed line, and
# what names the lane. `NO_LANE=` sets nothing the hook reads.
for row in "CLAUDE_PROJECT_DIR=$LANE|2|lane-mail-check: halt=$HALT_95|the directory the harness started in" \
  "LANE_MAIL_ITEM=KEN-95|2|lane-mail-check: halt=$HALT_95|the launch marker for the brief's item" \
  "NO_LANE=|0|-|nothing, so the main clone answers and is no lane"; do
  CALL_ENV=("${row%%|*}")
  rest=${row#*|}
  want_rc=${rest%%|*}
  rest=${rest#*|}
  tool halt
  expect "$want_rc" "${rest%%|*}" "a halt judge run from the main clone reads the lane through ${rest#*|}"
done
CALL_ENV=("CLAUDE_PROJECT_DIR=$LANE")
tool halt
ACK_95=$(sed -n 3p "$ERR_FILE")
printf -v READ_95 '%q inbox --item %q --root %q' "$LANE/.claude/skills/orch/scripts/lane-mail" KEN-95 "$LANE"
assert_eq "$ACK_95" "$READ_95" "the halt refusal names the lane's root in the command that reads it"
(cd "$MAIN" && env -u CLAUDE_PROJECT_DIR bash -c "$ACK_95" >/dev/null)
tool halt
expect 0 - "that command run from the main clone reads the halt, and the next call passes"
# The question route from the main clone: the one cwd that is not the lane's
# root, so the route's root is the lane's and never the call's own directory.
TOOL_NAME=AskUserQuestion
tool halt
expect 2 "lane-mail-check: question-tool=AskUserQuestion" "a question tool call from the main clone is refused"
printf -v ASK_ROUTE 'ask --item %q --root %q --file [PATH]' KEN-95 "$LANE"
printf -v WAIT_ROUTE 'wait --item %q --root %q --id [MSGID]' KEN-95 "$LANE"
assert_eq "$(grep -cF -- "$ASK_ROUTE" "$ERR_FILE") $(grep -cF -- "$WAIT_ROUTE" "$ERR_FILE")" "1 1" \
  "its refusal roots the ask send and the wait at the lane, not at the main clone the call is made from"
TOOL_NAME=Bash
send KEN-95 'Rebase first.'
tool deliver
assert_eq "RC=$RC context=$(context_line)" "RC=0 context=PostToolUse lane-mail-check: unread=1" \
  "a deliver judge run from the main clone hands the lane its directive"
tool deliver
assert_eq "RC=$RC context=$(context_line)" "RC=0 context=-" \
  "and acknowledges it in the lane's own mailbox, so the next call carries nothing"
send KEN-95 'Then re-arm.'
stop
expect 2 "lane-mail-check: unread=1" "a turn end from the main clone refuses on the lane's unread directive"
report KEN-95
stop
expect 0 "$GAP" "and acknowledges it in the lane's own mailbox, so the next turn end passes"
CALL_DIR=""
CALL_ENV=()

# A root its launch marker binds with no mailbox directory: every arm refuses
# the lead, naming the marker, and the one command that restores the directory
# passes; a subagent is refused before its call. Other lanes' markers beside it
# are never read.
new_lane marked_no_mailbox ken-96
install_arms
MARKER_96="$LANE/.git/lane-mail/ken-96"
printf '%s\n' "$TMP_ROOT/another-lane" > "$LANE/.git/lane-mail/ken-196"
mkdir "$LANE/.git/lane-mail/ken-296"
printf -v MKDIR_96 'mkdir -p -- %q' "$LANE/tmp/lane-mail"
tool halt
expect 2 "lane-mail-check: mailbox-missing=$LANE/tmp/lane-mail" \
  "a marked root with no mailbox directory refuses the next tool call"
assert_eq "marker=$(grep -cF -- "$MARKER_96" "$ERR_FILE") command=$(grep -cxF -- "$MKDIR_96" "$ERR_FILE")" \
  "marker=1 command=1" "the refusal names the marker and the one command that restores the mailbox"
tool deliver
expect 2 "lane-mail-check: mailbox-missing=$LANE/tmp/lane-mail" \
  "a finished tool call on the same lane is refused too"
tool halt "$MKDIR_96" agent_id
assert_eq "RC=$RC first=$(first_line) command=$(grep -cxF -- "$MKDIR_96" "$ERR_FILE")" \
  "RC=2 first=lane-mail-check: mailbox-missing=$LANE/tmp/lane-mail command=0" \
  "a subagent's call carrying that command is refused and is never shown it"
stop_active
expect 2 "lane-mail-check: mailbox-missing=$LANE/tmp/lane-mail" \
  "the continued turn is refused too: the lane clears it with one command"
tool halt "$MKDIR_96"
expect 0 - "the lead's call running that command passes"
(cd "$LANE" && bash -c "$MKDIR_96")
tool halt
expect 0 - "once the directory stands the next call passes"
unmark_lanes
rmdir "$LANE/tmp/lane-mail"
tool halt
expect 0 - "a root with neither a launch marker nor a mailbox directory passes a tool call silently"

# The directory the harness started in dropped: the judge asks the call's cwd.
mutant no-project-dir -e 's@^LANE_DIR=\${CLAUDE_PROJECT_DIR:-\$PWD}$@LANE_DIR=$PWD@'
new_worktree_lane control_from_main ken-97
install_arms "$MUTANT_PATH"
send KEN-97 'Hold the merge.' --halt
CALL_DIR="$MAIN"
CALL_ENV=("CLAUDE_PROJECT_DIR=$LANE")
tool halt
expect 0 - "control: without the harness's directory a halt judge run from the main clone passes the call"
# The root dropped from the reader's peek: the reader roots itself at the call's
# cwd and reads the main clone.
mutant peek-no-root -e 's@inbox --item "\$MAILBOX_ITEM" --root "\$ROOT" --peek@inbox --item "$MAILBOX_ITEM" --peek@'
install_arms "$MUTANT_PATH"
tool halt
expect 0 - "control: without the root the reader's peek from the main clone finds nothing and passes the call"
# The marker read dropped: LANE_MAIL_ITEM no longer reaches the lane's root.
mutant no-marker-root -e 's@|| ROOT="\$BOUND"$@|| :@'
install_arms "$MUTANT_PATH"
CALL_ENV=("LANE_MAIL_ITEM=KEN-97")
tool halt
expect 0 - "control: without the marker read a harness naming no directory passes the call"
# The read command written without the root: run from the main clone, it
# reads the main clone and the halt stands.
mutant ack-no-root -e 's@'"'"'%q inbox --item %q --root %q'"'"' "\$READER" "\$MAILBOX_ITEM" "\$ROOT"@'"'"'%q inbox --item %q'"'"' "$READER" "$MAILBOX_ITEM"@'
install_arms "$MUTANT_PATH"
CALL_ENV=("CLAUDE_PROJECT_DIR=$LANE")
tool halt
(cd "$MAIN" && env -u CLAUDE_PROJECT_DIR bash -c "$(sed -n 3p "$ERR_FILE")" >/dev/null 2>&1) || :
tool halt
expect 2 "lane-mail-check: halt=$(jq -r 'select(.halt == true) | .id' "$LANE/tmp/lane-mail/KEN-97/to-lane.jsonl")" \
  "control: without the root in it the command run from the main clone leaves the halt standing"
# The root dropped from the turn end's acknowledgement alone: a turn end from
# the main clone moves the main clone's cursor, and the directive repeats.
mutant stop-ack-no-root -e 's@^  "\$READER" inbox --item "\$MAILBOX_ITEM" --root "\$ROOT" --ack@  "$READER" inbox --item "$MAILBOX_ITEM" --ack@'
new_worktree_lane control_stop_ack ken-94
install_arms "$MUTANT_PATH"
send KEN-94 'Rebase first.'
CALL_DIR="$MAIN"
CALL_ENV=("CLAUDE_PROJECT_DIR=$LANE")
stop
stop
expect 2 "lane-mail-check: unread=1" \
  "control: without the root in its acknowledgement a turn end from the main clone repeats the directive"
CALL_DIR=""
CALL_ENV=()

# The refusal replaced by a pass, and the command's pass removed.
mutant no-mailbox-missing -e 's@^      refuse mailbox-missing "\$MAIL_ROOT"$@      exit 0@'
new_lane control_no_mailbox ken-98
install_arms "$MUTANT_PATH"
tool halt
expect 0 - "control: without its refusal a marked root with no mailbox passes the call"
mutant no-mailbox-pass -e 's@^      \[ "\$CALLER" = subagent \] || ! call_runs "\$MAILBOX_COMMAND" || exit 0$@      :@'
install_arms "$MUTANT_PATH"
printf -v MKDIR_98 'mkdir -p -- %q' "$LANE/tmp/lane-mail"
tool halt "$MKDIR_98"
expect 2 "lane-mail-check: mailbox-missing=$LANE/tmp/lane-mail" \
  "control: without its pass the one command that restores the mailbox is refused"
# The subagent gate on that pass removed: a subagent's call runs the command.
mutant mailbox-pass-subagent -e 's@^      \[ "\$CALLER" = subagent \] || ! call_runs@      ! call_runs@'
install_arms "$MUTANT_PATH"
tool halt "$MKDIR_98" agent_id
expect 0 - "control: without the subagent gate a subagent's call carrying that command passes"

# A condition the lane cannot clear without a tool call: before a tool call
# it is reported and the call runs, where a fresh turn end refuses it.
new_lane halt_workdir ken-36
install_arms
ARM_ARGS=(halt)
run_payload '{"tool_name":"Bash","tool_input":{"command":"git status"}}' "TMPDIR=$TMP_ROOT/absent"
ARM_ARGS=()
expect 0 "lane-mail-check: workdir=$TMP_ROOT/absent" \
  "a work directory the halt arm cannot make is reported and the tool call runs"
stop "TMPDIR=$TMP_ROOT/absent"
expect 2 "lane-mail-check: workdir=$TMP_ROOT/absent" \
  "control: the same condition refuses a fresh turn end"

# The halt refusal replaced by a pass, its judgement still made.
mutant no-halt -e 's@^    refuse halt "\$HALT_ID"$@    exit 0@'
new_lane control_halt ken-31
install_arms "$MUTANT_PATH"
send KEN-31 'Stop.' --halt
tool halt
expect 0 - "control: without its halt refusal the hook passes a tool call with a halt pending"

# Each arm's subagent check removed alone: a subagent's call is judged as the lead's.
mutant lead-deliver -e 's@^if \[ -n "\$CONTEXT_EVENT" \] && \[ "\$CALLER" = subagent \]; then$@if false; then@'
new_lane control_sub_deliver ken-34
install_arms "$MUTANT_PATH"
send KEN-34 'For the lead.'
tool deliver "git status" agent_id
assert_eq "RC=$RC context=$(context_line)" "RC=0 context=PostToolUse lane-mail-check: unread=1" \
  "control: without the deliver check a subagent's call is handed the lead's directive"
mutant lead-halt -e 's@^      lead | unknown) ! call_runs "\$ACK_COMMAND" || exit 0 ;;$@      *) ! call_runs "$ACK_COMMAND" || exit 0 ;;@'
new_lane control_sub_halt ken-35
install_arms "$MUTANT_PATH"
send KEN-35 'Halt the lead.' --halt
printf -v SUB_READ '%q inbox --item %q --root %q' "$LANE/.claude/skills/orch/scripts/lane-mail" KEN-35 "$LANE"
tool halt "$SUB_READ" agent_id
expect 0 - "control: without the halt check a subagent's call carrying the acknowledging command passes"

# The agent_type read dropped, agent_id still read: a subagent the pi-hooks
# carrier marks is judged as the lead.
wake_mutant no-agent-type \
  '   (if .hook_event_name == "SubagentStop" or str(.agent_id) + str(.agent_type) != "" then "subagent" else "lead" end),' \
  '   (if .hook_event_name == "SubagentStop" or str(.agent_id) != "" then "subagent" else "lead" end),'
new_lane control_sub_type ken-38
install_arms "$MUTANT_PATH"
send KEN-38 'For the lead.'
tool deliver "git status" agent_type
tool deliver
assert_eq "RC=$RC context=$(context_line)" "RC=0 context=-" \
  "control: without the agent_type read a subagent's call consumes the lead's directive"
send KEN-38 'Halt the lead.' --halt
printf -v SUB_READ '%q inbox --item %q --root %q' "$LANE/.claude/skills/orch/scripts/lane-mail" KEN-38 "$LANE"
tool halt "$SUB_READ" agent_type
expect 0 - "control: without the agent_type read a subagent's call carrying the acknowledging command passes"

# The deliver context written without its envelopes, the keyed line kept.
mutant no-envelopes -e 's@^    NOTICE=\$(message unread "\$COUNT" 2>&1)$@    NOTICE=$(UNREAD= message unread "$COUNT" 2>\&1)@'
new_lane control_envelopes ken-39
install_arms "$MUTANT_PATH"
send KEN-39 'Rebase first.'
tool deliver
assert_eq "context=$(context_line) carried=$(jq -r '.hookSpecificOutput.additionalContext' "$TMP_ROOT/stdout" | grep -cF 'Rebase first.')" \
  "context=PostToolUse lane-mail-check: unread=1 carried=0" \
  "control: without its envelopes the deliver context keeps its key and loses the directive"

# The halt refusal written without the acknowledging command.
mutant no-ack-command -e 's@"\$ACK_COMMAND" "\$HALT_TEXT"@"" "$HALT_TEXT"@'
new_lane control_ack_command ken-41
install_arms "$MUTANT_PATH"
send KEN-41 'Stop pushing.' --halt
printf -v ACK_READ '%q inbox --item %q --root %q' "$LANE/.claude/skills/orch/scripts/lane-mail" KEN-41 "$LANE"
tool halt
assert_eq "key=$(first_line | cut -d= -f1) command=$(grep -cxF -- "$ACK_READ" "$ERR_FILE")" \
  "key=lane-mail-check: halt command=0" \
  "control: without the command the halt refusal keeps its key and loses the one read that clears it"

# The reader's acknowledgement clamp removed: a deliver run consumes the halt it showed.
CLAMPLESS="$TMP_ROOT/clampless"
mkdir -p "$CLAMPLESS"
mkdir -p "$CLAMPLESS/lib"
plant_siblings "$CLAMPLESS" lib
for CLAMP_LIB in "$REPO_ROOT/skills/orch/scripts/lib"/*; do
  [ "${CLAMP_LIB##*/}" = lane-mail-store.py ] || ln -s "$CLAMP_LIB" "$CLAMPLESS/lib/"
done
ln -s "$LANE_MAIL" "$CLAMPLESS/lane-mail"
MUTANT_SOURCE="$REPO_ROOT/skills/orch/scripts/lib/lane-mail-store.py" mutant no-clamp \
  -e 's@\[\$bound, \$halt\] | min else \$bound@\$bound else \$bound@'
mv "$MUTANT_PATH" "$CLAMPLESS/lib/lane-mail-store.py"
new_lane control_clamp ken-32
install_arms
ln -s -f -n "$CLAMPLESS" "$LANE/.agents/skills/orch/scripts"
send KEN-32 'Stop.' --halt
tool deliver
tool halt
expect 0 - "control: without the acknowledgement clamp a deliver run consumes the halt"

# The missing-judge refusal's exit removed, its message still written.
MUTANT_SOURCE="$TEST_DIR/../lane-mail-halt.sh" mutant no-judge-exit -e 's@^  exit 2$@  :@'
new_lane control_judge ken-33
install_arms
install_hook "$MUTANT_PATH" "$LANE/.claude/hooks/lane-mail-halt.sh"
rm -f "$LANE/.claude/hooks/lane-mail-check.sh"
tool halt
assert_eq "$([ "$RC" -eq 2 ] && echo refused || echo passed)" "passed" \
  "control: without its exit the halt hook with no judge beside it does not refuse"

# Each handoff mark's refusal replaced by a pass, its judgement still made.
mutant no-context-mark -e 's@^    0) \[ "\$DUE" != due \] || refuse_handoff context "\$TOKENS" ;;$@    0) : ;;@'
new_handoff_lane control_context KEN-56
install_hook "$MUTANT_PATH" "$LANE/.claude/hooks/lane-mail-check.sh"
write_transcript "$TRANSCRIPT" 600000
stop_at "$TRANSCRIPT" false
expect 0 "$GAP" "control: without its context refusal a lane past the mark ends its turn"

mutant no-headroom-mark -e 's@^      refuse_handoff headroom "\$HEADROOM"$@      :@'
new_handoff_lane control_headroom KEN-57
install_hook "$MUTANT_PATH" "$LANE/.claude/hooks/lane-mail-check.sh"
write_transcript "$TRANSCRIPT" 1000
# shellcheck disable=SC2046
stop_at "$TRANSCRIPT" false $(account_env .neutralclaude)
expect 0 - "control: without its account refusal a lane at its account's mark ends its turn"

# The verb's own status 2 folded back in with the statuses it cannot attribute:
# an unreadable state file then reads as an install that does not carry the
# verb, and the operator is sent to refresh an install that is current while
# the state file that actually stopped the read is never named.
mutant fold-unreadable \
  -e 's@^    "$HANDOFF_VERDICT=unreadable") HANDOFF_STATE=unreadable ;;$@    "$HANDOFF_VERDICT=unreadable") HANDOFF_STATE=unanswered ;;@'
new_handoff_lane control_unreadable KEN-89
install_hook "$MUTANT_PATH" "$LANE/.claude/hooks/lane-mail-check.sh"
CONTROL_STATE="$(cd "$LANE" && "$REPO_ROOT/skills/orch/scripts/workflow-state" path KEN-89)"
printf '{"handoff":' > "$CONTROL_STATE"
write_transcript "$TRANSCRIPT" 600000
stop_at "$TRANSCRIPT" false
expect 0 "lane-mail-check: handoff-unanswered=$LANE/.claude/skills/orch/scripts/workflow-state" \
  "control: folded in, an unreadable state file reads as an install that lacks the verb"
assert_eq "$(grep -c "$CONTROL_STATE" "$ERR_FILE")" "0" \
  "control: and the file that actually stopped the read is never named"

# The library probe moved out of this shell and into a child of it. Bash 3.2
# kills the shell on a source it cannot parse even as the condition of an `if`,
# where bash 5 takes the non-zero status and carries on, and this hook's EXIT
# teardown then succeeds and lends the dead run its own 0: the turn passes with
# the account mark unjudged and not one line on stderr, which is the one answer
# the marks forbid. What the masking costs depends on the interpreter the
# shebang picks, so the control runs only under the one that dies.
mutant in-process-probe \
  -e 's@^  if ! "\$BASH" -euo pipefail -c .* 2>"\$WORK_DIR/lib.err"; then$@  if ! { . "$SCRIPTS/lib/lane-context.sh" \&\& declare -F lane_context_caller_cfg >/dev/null; } 2>"$WORK_DIR/lib.err"; then@'
new_handoff_lane control_probe KEN-93
install_hook "$MUTANT_PATH" "$LANE/.claude/hooks/lane-mail-check.sh"
plant_install lib
mkdir -p "$LANE/.claude/skills/orch/scripts/lib"
for name in "$REPO_ROOT/skills/orch/scripts/lib"/*.sh; do
  [ "${name##*/}" != lane-context.sh ] || continue
  ln -s -f -n "$name" "$LANE/.claude/skills/orch/scripts/lib/${name##*/}"
done
printf '# shellcheck shell=bash\nthis is ( not shell\n' \
  > "$LANE/.claude/skills/orch/scripts/lib/lane-context.sh"
write_transcript "$TRANSCRIPT" 1000
if [ "$HOOK_BASH_MAJOR" -lt 4 ]; then
  stop_at "$TRANSCRIPT" false
  expect 0 - \
    "control: probed in-process, a library this shell cannot parse kills the hook and its teardown passes the turn in silence"
else
  printf '  skip  control: probed in-process, the masking needs a shell that dies on a sourced parse error; this one is bash %s\n' \
    "$HOOK_BASH_MAJOR"
fi

# The record test answering yes whatever the state holds: the mark then clears
# itself and no lane ever writes one.
mutant record-always \
  -e 's@^    "$HANDOFF_VERDICT=none") HANDOFF_STATE=none; return 0 ;;$@    "$HANDOFF_VERDICT=none") HANDOFF_STATE=stands; return 0 ;;@'
new_handoff_lane control_record KEN-58
install_hook "$MUTANT_PATH" "$LANE/.claude/hooks/lane-mail-check.sh"
write_transcript "$TRANSCRIPT" 600000
stop_at "$TRANSCRIPT" false
expect 0 - "control: with the record test inverted a lane past the mark with no record ends its turn"

# The continued turn routed back to a plain pass: a lane that declined the
# first refusal then ends the session with nothing recorded.
mutant active-passes -e 's@^handoff_check$@[ "$CONTINUED" = true ] || handoff_check@'
new_handoff_lane control_active KEN-59
install_hook "$MUTANT_PATH" "$LANE/.claude/hooks/lane-mail-check.sh"
write_transcript "$TRANSCRIPT" 600000
stop_at "$TRANSCRIPT" true
expect 0 - "control: with the continued turn routed past the marks a lane ends past the mark"

# A read mailbox routed to a plain pass rather than on to the marks: the lane
# that has already been messaged is then the one never judged.
mutant read-passes -e 's@^  \[ -n "\$UNREAD" \] || return 0$@  [ -n "$UNREAD" ] || exit 0@'
new_handoff_lane control_read KEN-73
install_hook "$MUTANT_PATH" "$LANE/.claude/hooks/lane-mail-check.sh"
send KEN-73 'Rebase first.'
stop
write_transcript "$TRANSCRIPT" 600000
stop_at "$TRANSCRIPT" false
expect 0 - "control: with a read mailbox routed past the marks a lane ends past the mark"

# The continued turn refusing every resolution failure again: the session then
# never ends, which is the loop stop_hook_active exists to end.
mutant active-refuses -e 's@^  if \[ "\$REPORTED" = true \]; then$@  if false; then@'
new_lane control_stall ken-75
mkdir -p "$LANE/tmp/lane-mail/KEN-75"
install_hook "$MUTANT_PATH" "$LANE/.claude/hooks/lane-mail-check.sh"
stop_active LANE_MAIL_ITEM='bad item!'
expect 2 "lane-mail-check: item=invalid" \
  "control: without the continued turn's report the same refusal is made again"

# The gap left unreported: an account nothing measured then reads as room.
mutant silent-gap -e 's@^    \*) message account unmeasured .*$@    *) : ;;@'
new_handoff_lane control_gap KEN-76
install_hook "$MUTANT_PATH" "$LANE/.claude/hooks/lane-mail-check.sh"
write_transcript "$TRANSCRIPT" 1000
# shellcheck disable=SC2046
stop_at "$TRANSCRIPT" false $(account_env .openclaude)
expect 0 - "control: without its report an account nothing measured passes silently"

# An unattributable status read as "no record stands": the lane that wrote its
# record is then refused at every turn end by an install that never saw it.
mutant record-on-any -e 's@^    \*) HANDOFF_STATE=unanswered ;;$@    *) HANDOFF_STATE=none ;;@'
new_handoff_lane control_old_state KEN-77
install_hook "$MUTANT_PATH" "$LANE/.claude/hooks/lane-mail-check.sh"
old_dispatcher
record_handoff KEN-77
write_transcript "$TRANSCRIPT" 600000
stop_at "$TRANSCRIPT" false
expect 2 "lane-mail-check: context=600000" \
  "control: read as no record, an older install refuses a lane that has already handed off"

# The whole-file fallback dropped: a session whose recent window is all tool
# results reads as no context at all and runs to its wall.
MUTANT_SOURCE="$WINDOW_HOOK" mutant no-window-fallback \
  -e 's@^    if \[ -z "\$READING" \] && ! READING=\$(lane_context_reading .*); then$@    if false; then@'
new_handoff_lane control_window KEN-78
install_hook "$MUTANT_PATH" "$LANE/.claude/hooks/lane-mail-check.sh"
write_transcript "$TRANSCRIPT" 600000
filler "$TRANSCRIPT" 2000
stop_at "$TRANSCRIPT" false
expect 0 "$GAP" \
  "control: without the fallback a usage line before the window reads as no context at all"

# The record's time put back in the template: the lane is asked for it again,
# and the row above that says it is not goes red.
mutant asks-written-at -e 's@{"merged":@{"written_at":"[NOW]","merged":@'
new_handoff_lane control_written_at KEN-94
install_hook "$MUTANT_PATH" "$LANE/.claude/hooks/lane-mail-check.sh"
write_transcript "$TRANSCRIPT" 600000
stop_at "$TRANSCRIPT" false
assert_eq "$(template_fields | tr ',' '\n' | grep -cx written_at || true)" "1" \
  "control: with written_at back in the template the lane is asked for the record's time"

# Control: a gate that asks the library about an empty path reports it as an
# unbound transcript and withholds the context argument for nothing.
mutant owned-empty-path -e '/^overseer_transcript_owned() {$/,/^}$/{/^  \[ -n "\$TRANSCRIPT" \] || return 0$/d;}'
new_overseer control_owned_empty_path
install_hook "$MUTANT_PATH" "$LANE/.claude/hooks/lane-mail-check.sh"
judge_says "$HEADROOM_MARK_LINE"
# shellcheck disable=SC2046
stop $(overseer_env)
assert_eq "argv=$(judge_argv | tail -n 1) unowned=$(grep -c '^lane-mail-check: transcript-unowned' "$ERR_FILE")" \
  "argv=--check-marks --harness claude unowned=1" \
  "control: without its empty-path test the gate reports a payload naming no transcript as unowned"
# Control: a gate that reports the library's harness-unlisted answer holds a Pi
# overseer, whose install states no transcript shape, to a binding it cannot make.
mutant owned-unlisted-reported -e 's/^    0 | 3) return 0 ;;$/    0) return 0 ;;/'
new_overseer control_owned_unlisted
mkdir -p "$LANE/.pi/skills"
ln -s "$LANE/.claude/skills/orch" "$LANE/.pi/skills/orch"
install_hook "$MUTANT_PATH" "$LANE/.pi/kendex/hooks/lane-mail-check.sh"
judge_says "$HEADROOM_MARK_LINE"
# shellcheck disable=SC2046
run_payload "$(jq -nc --arg p "$PI_TRANSCRIPT" \
  '{session_id:"s1",stop_hook_active:false,transcript_path:$p,context_window:200000}')" $(overseer_env)
assert_eq "unowned=$(grep -c '^lane-mail-check: transcript-unowned' "$ERR_FILE")" "unowned=1" \
  "control: a gate reporting the harness-unlisted answer holds a Pi overseer to a transcript shape"

# The overseer identification's control: the pane comparison removed, so any
# session with no lane is taken for the overseer. An ordinary session in a
# fleet checkout is then held at its own turn end on marks nobody set for it.
mutant any-session-overseer -e '/^   (if ol_names(/s@\$pane)@(.pane // ""))@'
new_overseer control_any_session
install_hook "$MUTANT_PATH" "$LANE/.claude/hooks/lane-mail-check.sh"
judge_says "$CONTEXT_MARK_LINE"
# shellcheck disable=SC2046
stop_at "$TRANSCRIPT" false $(overseer_env "%3")
expect 2 "lane-mail-check: context=612000" \
  "control: without the pane comparison a session the fleet state never named is held"

# The succession field's controls, one per rule it enforces: the arm that
# passes an account mark removed, and the context exception removed.
mutant overseer-succession -e 's@^  \[ "\$SUCCESSION" != off \] || \[ "\$MARK_KIND" = context \] || return 0$@  :@'
new_overseer control_succession_off
install_hook "$MUTANT_PATH" "$LANE/.claude/hooks/lane-mail-check.sh"
judge_says "$OFF_HEADROOM_LINE"
# shellcheck disable=SC2046
stop_at "$TRANSCRIPT" false $(overseer_env)
expect 2 "lane-mail-check: headroom=4" \
  "control: without the field read an account mark is refused with its route turned off"
mutant overseer-succession-context -e 's@ || \[ "\$MARK_KIND" = context \] || return 0$@ || return 0@'
new_overseer control_succession_context
install_hook "$MUTANT_PATH" "$LANE/.claude/hooks/lane-mail-check.sh"
judge_says "$OFF_MARK_LINE"
# shellcheck disable=SC2046
stop_at "$TRANSCRIPT" false $(overseer_env)
assert_eq "RC=$RC first=$(first_line)" "RC=0 first=-" \
  "control: without the context exception a context crossing under succession off is told nothing"

# The fleet record's own control: the writer comparison removed, so a record
# any session left on the shared item answers for this one and its turn end is
# passed with both marks unjudged, for the life of the session.
mutant overseer-record-owner -e 's@^      if \[ "\$ROLE" != overseer \] || handoff_is_mine; then$@      if true; then@'
new_overseer control_record_owner
install_hook "$MUTANT_PATH" "$LANE/.claude/hooks/lane-mail-check.sh"
judge_says "$CONTEXT_MARK_LINE"
record_overseer_handoff other-session
# shellcheck disable=SC2046
stop_at "$TRANSCRIPT" false $(overseer_env)
assert_eq "RC=$RC first=$(first_line)" "RC=0 first=-" \
  "control: without the writer comparison another session's record passes this one past its mark"

# The judged line's own control: the three-field guard removed, so a keyed line
# missing a figure refuses anyway and names nothing the judgement read.
mutant overseer-fields \
  -e 's@^  if \[ -z "\$MARK_KIND" \] || \[ -z "\$MARK_VALUE" \] || \[ -z "\$MARK" \]; then$@  if false; then@'
new_overseer control_overseer_fields
install_hook "$MUTANT_PATH" "$LANE/.claude/hooks/lane-mail-check.sh"
judge_says "oversee-succeed: mark-reached kind=context mark=500000 succession=on"
# shellcheck disable=SC2046
stop_at "$TRANSCRIPT" false $(overseer_env)
expect 2 "lane-mail-check: context=" \
  "control: without the three-field guard a line naming no figure refuses on one"

# The silence a session that is neither a lane nor the recorded overseer keeps.
# Two arms hold it, one where the install cannot be resolved and one where that
# install has no workflow-state, and the candidate flag is what both read.
# Without them a plain repository carrying a rendered orch tree, opened from a
# harness whose own install has no orch skill, writes a keyed line at every
# turn end of every session in the checkout.
new_lane control_not_a_lane main
unmark_lanes
rm -f -- "${LANE:?}/.claude/skills/orch" "${LANE:?}/.agents/skills/orch/scripts"
SILENT_READER="$LANE/.agents/skills/orch/scripts/lane-mail"
# shellcheck disable=SC2046
stop $(overseer_env "%3")
expect 0 - "a session that is no lane and no overseer says nothing about an install it has not got"
mutant unresolved-speaks -e 's@^    \[ "\$NO_LANE_ITEM" -eq 0 \] || return 1$@    :@'
install_hook "$MUTANT_PATH" "$LANE/.claude/hooks/lane-mail-check.sh"
# shellcheck disable=SC2046
stop $(overseer_env "%3")
expect 0 "lane-mail-check: handoff-skipped=$SILENT_READER" \
  "control: without the candidate arms that session reports a gap at every turn end"

# The question tool's refusal replaced by a pass, its judgement still made: a
# lane then opens the dialog its overseer never sees.
mutant no-question-tool -e 's@^  refuse question-tool "\$TOOL"$@  return 0@'
new_lane control_question_tool ken-43
mkdir -p "$LANE/tmp/lane-mail/KEN-43"
install_arms "$MUTANT_PATH"
TOOL_NAME=AskUserQuestion
tool halt
expect 0 - "control: without its refusal a lane's question tool call passes"

# The mailbox check's pass on unread mail with no halt turned back into an
# exit: a directive in the mailbox then lets the question tool through.
mutant question-behind-mail -e 's@^    \[ -n "\$HALT" \] || return 0$@    [ -n "$HALT" ] || exit 0@'
new_lane control_question_mail ken-45
mkdir -p "$LANE/tmp/lane-mail/KEN-45"
install_arms "$MUTANT_PATH"
send KEN-45 'Rebase onto main.'
TOOL_NAME=AskUserQuestion
tool halt
expect 0 - "control: with the mailbox check exiting on unread mail, a directive lets the question tool through"

# The launch gate dropped from that check alone: a committed mailbox then
# poses as a lane and an ordinary session loses its question tool.
mutant question-unlaunched -e '/^question_tool_check() {/,/^}/ s@^  lane_launched || return 0$@  :@'
new_lane control_question_unmarked ken-44
mkdir -p "$LANE/tmp/lane-mail/KEN-44"
install_arms "$MUTANT_PATH"
unmark_lanes
tool halt
expect 2 "lane-mail-check: question-tool=AskUserQuestion" \
  "control: without the marker rule a committed mailbox loses its question tool"
TOOL_NAME=Bash

# The idle refusal replaced by a pass: a lane that sent nothing then stops
# unseen.
mutant no-idle-refusal -e 's@^  refuse idle "\$ITEM"$@  return 0@'
new_handoff_lane control_idle_refusal KEN-80
REPORT_ITEM=""
install_hook "$MUTANT_PATH" "$LANE/.claude/hooks/lane-mail-check.sh"
stop
expect 0 "$GAP" "control: without its refusal a lane that sent nothing ends its turn"

# The count ignored: a lane that reported this turn is held all the same.
mutant idle-ignores-sent -e 's@^  if \[ "\$SENT" != "\$RECORDED" \]; then$@  if false; then@'
new_handoff_lane control_idle_sent KEN-81
REPORT_ITEM=""
install_hook "$MUTANT_PATH" "$LANE/.claude/hooks/lane-mail-check.sh"
report KEN-81
stop
assert_eq "RC=$RC keys=$(hook_keys)" "RC=2 keys=account=unlisted;idle=KEN-81" \
  "control: without the count a lane that sent a notice this turn is held"

# The box filter dropped: the overseer's directive in the lane's inbound file
# counts as the lane's own send.
mutant idle-any-box -e 's@select(\.box == "to-overseer" and (\.kind == "ask" or \.kind == "notice"))@select(.kind == "ask" or .kind == "notice" or .kind == "directive")@'
new_handoff_lane control_idle_box KEN-82
REPORT_ITEM=""
install_hook "$MUTANT_PATH" "$LANE/.claude/hooks/lane-mail-check.sh"
send KEN-82 'Rebase onto main.' >/dev/null
read_mail KEN-82
stop
expect 0 "$GAP" "control: without the box filter a directive the overseer sent passes a lane that sent nothing"

# The halt fact dropped: a halted lane is held and told to continue.
mutant idle-ignores-halt -e 's@^  if \[ "\$HALTED" = true \]; then$@  if false; then@'
new_handoff_lane control_idle_halt KEN-83
REPORT_ITEM=""
install_hook "$MUTANT_PATH" "$LANE/.claude/hooks/lane-mail-check.sh"
send KEN-83 'Stop here.' --halt >/dev/null
read_mail KEN-83
stop
assert_eq "RC=$RC keys=$(hook_keys)" "RC=2 keys=account=unlisted;idle=KEN-83" \
  "control: without the halt fact a halted lane is held"

# The continued-turn arm dropped: the refusal repeats, which is the loop.
mutant idle-refused-twice -e 's@^  if \[ "\$CONTINUED" = true \] && {@  if false \&\& {@'
new_handoff_lane control_idle_twice KEN-84
REPORT_ITEM=""
install_hook "$MUTANT_PATH" "$LANE/.claude/hooks/lane-mail-check.sh"
stop
stop_active
assert_eq "RC=$RC keys=$(hook_keys)" "RC=2 keys=account=unlisted;idle=KEN-84" \
  "control: without the continued-turn arm a lane is held twice in a row"

# The notice left out of the record: the hook's own notice then passes the
# lane's next idle turn as a send of its own.
mutant idle-notice-uncounted -e '/^  record_sent idle-notice-unrecorded "\$((SENT + 1))" || :$/d'
new_handoff_lane control_idle_notice KEN-85
REPORT_ITEM=""
install_hook "$MUTANT_PATH" "$LANE/.claude/hooks/lane-mail-check.sh"
stop
stop_active
stop
expect 0 "$GAP" "control: with the notice uncounted the lane's next idle turn passes"

# The text read planted back into a copy of the hook: the inventory row counts
# it, so that row reads what it claims to.
mutant text-read -e 's@^idle_check() {$@idle_check() { : jq -r '"'"'select(.type == "text")'"'"';@'
assert_eq "$(text_reads "$MUTANT_PATH")" "1" "control: a copy that reads the transcript's text is counted"

# A words-reading judge under a spelling the inventory row does not know:
# it passes a turn whose final assistant text is no question. The transcript
# rows hold the lane that wrote a statement and sent nothing.
WORDS_READ='idle_check() { [ -n "$TRANSCRIPT" ] \&\& tail -n 1 -- "$TRANSCRIPT" | jq -r ".message.content[]?.text" | grep -q "?$" || return 0;'
mutant words-read -e "s@^idle_check() {\$@$WORDS_READ@"
new_handoff_lane control_words_read KEN-90
REPORT_ITEM=""
install_hook "$MUTANT_PATH" "$LANE/.claude/hooks/lane-mail-check.sh"
usage_line claude 1000 | jq -c '.message.content = [{type: "text", text: "All done."}]' > "$TMP_ROOT/words.jsonl"
run_payload "$(jq -nc --arg p "$TMP_ROOT/words.jsonl" \
  '{session_id:"s1",stop_hook_active:false,transcript_path:$p,context_window:200000}')"
assert_eq "RC=$RC idle=$(grep -c '^lane-mail-check: idle=' "$ERR_FILE" || true)" "RC=0 idle=0" \
  "control: a judge that reads the lane's words passes a statement from a lane that sent nothing"

# The envelope failure passed in silence: a listing jq cannot read ends the
# turn with nothing said.
mutant idle-envelope-silent -e 's@ || { message events envelope "\$FACTS"; return 0; }$@ || return 0@'
new_handoff_lane control_idle_envelope KEN-98
REPORT_ITEM=""
install_hook "$MUTANT_PATH" "$LANE/.claude/hooks/lane-mail-check.sh"
wrap_reader "$NOT_JSON"
stop
assert_eq "RC=$RC keys=$(hook_keys)" "RC=0 keys=account=unlisted" \
  "control: without its report a listing jq cannot read ends the turn unsaid"

# The recorded hold ignored: every continued turn is reported, so a turn
# another stop hook continued after the lane reported sends the notice.
mutant idle-hold-ignored -e 's@{ \[ -n "\$HOLD" \] || \[ "\$HARNESS" = pi \]; }@true@'
new_handoff_lane control_idle_hold KEN-91
REPORT_ITEM=""
install_hook "$MUTANT_PATH" "$LANE/.claude/hooks/lane-mail-check.sh"
report KEN-91
stop
stop_active
assert_eq "RC=$RC keys=$(hook_keys)" "RC=0 keys=account=unlisted;idle-notice=KEN-91" \
  "control: without the recorded hold a turn another stop hook continued is reported, never held"

# The hold made and not recorded: the turn it continued is held again.
mutant idle-hold-unrecorded -e 's@^  record_sent idle-hold-unrecorded "\$SENT" held || return 0$@  record_sent idle-hold-unrecorded "$SENT" || return 0@'
new_handoff_lane control_idle_unrecorded KEN-92
REPORT_ITEM=""
install_hook "$MUTANT_PATH" "$LANE/.claude/hooks/lane-mail-check.sh"
stop
stop_active
assert_eq "RC=$RC keys=$(hook_keys)" "RC=2 keys=account=unlisted;idle=KEN-92" \
  "control: without the hold in the record the turn it continued is held again"

# A hold the record could not take made all the same: the lane is held with
# nothing to bound the next continued turn.
mutant idle-hold-unguarded -e 's@^  record_sent idle-hold-unrecorded "\$SENT" held || return 0$@  record_sent idle-hold-unrecorded "$SENT" held || :@'
if [ "${CAN_DENY_READS:?}" -eq 1 ]; then
  new_handoff_lane control_idle_unguarded KEN-93
  REPORT_ITEM=""
  install_hook "$MUTANT_PATH" "$LANE/.claude/hooks/lane-mail-check.sh"
  printf '0\n' > "$LANE/tmp/lane-mail/KEN-93/sent-count"
  chmod 555 "$LANE/tmp/lane-mail/KEN-93"
  stop
  chmod 755 "$LANE/tmp/lane-mail/KEN-93"
  assert_eq "RC=$RC idle=$(grep -c '^lane-mail-check: idle=' "$ERR_FILE" || true)" "RC=2 idle=1" \
    "control: without the guard a hold the record cannot take is made"
else
  printf '  skip  control: a hold the record cannot take made unguarded: running as root, which writes in a mode-555 directory\n'
fi

# The Pi arm dropped: a Pi turn another stop hook continued is held, and the
# carrier runs nothing for that hold.
mutant idle-pi-held -e 's@ || \[ "\$HARNESS" = pi \]; }@; }@'
new_pi_lane control_idle_pi KEN-94 "$MUTANT_PATH"
REPORT_ITEM=""
report KEN-94
stop
stop_active
assert_eq "RC=$RC idle=$(grep -c '^lane-mail-check: idle=KEN-94$' "$ERR_FILE" || true)" "RC=2 idle=1" \
  "control: without the Pi arm a Pi turn another stop hook continued is held"

# The halt's clear dropped: the hold the turn end before the halt recorded
# stands.
mutant idle-halt-keeps-hold -e 's@^    \[ -z "\$HOLD" \] || record_sent idle-unrecorded "\$SENT" || :$@    :@'
new_handoff_lane control_idle_halt_hold KEN-96
REPORT_ITEM=""
install_hook "$MUTANT_PATH" "$LANE/.claude/hooks/lane-mail-check.sh"
stop
send KEN-96 'Stop here.' --halt >/dev/null
read_mail KEN-96
stop
assert_eq "record=$(sent_record KEN-96)" "record=0 held" "control: without the clear a halted turn end keeps the hold"

# --- the checkout's overseer mailbox --------------------------------------
# `lane-mail peer send --repo` writes the overseer mailbox of another
# repository's main checkout, and that mailbox has one reader: the session the
# checkout's fleet record names by tmux server and pane. A live watch reads it
# itself; with none, the hooks hand the notes to that session and to no other
# session in the checkout, so one the owner opened there for other work, in
# another pane or outside tmux, reads nothing.

# The session the record names: new_overseer's pane with the arms installed
# and a judge that finds no mark reached, so its turn end speaks only for the
# mailbox. SESSION_ENV is its own environment, OTHER_ENV a second session's in
# another pane of the same tmux server.
named_session() { # NAME [JUDGE]
  new_overseer "$1"
  install_arms "${2:-$HOOK}"
  judge_says "$BELOW_MARK_LINE"
}
# shellcheck disable=SC2207
SESSION_ENV=($(overseer_env))
# shellcheck disable=SC2207
OTHER_ENV=($(overseer_env %3))
# A session that is no lane in a checkout with no fleet record at all.
new_plain_session() { # NAME
  new_lane "$1" main
  unmark_lanes
  install_arms
}

named_session peer_named
peer_send 'Your pin bump broke our build.'
stop "${SESSION_ENV[@]}"
expect 2 "lane-mail-check: unread=1" "a peer note reaches the session the fleet record names at its turn end"
assert_eq "$(grep -c 'Your pin bump broke our build.' "$ERR_FILE")" "1" "the refusal carries the note"
stop "${SESSION_ENV[@]}"
expect 0 - "a second turn end passes: the reader advanced the overseer mailbox cursor past what it handed over"
peer_send 'And the changelog names the wrong version.'
CALL_ENV=("${SESSION_ENV[@]}")
tool halt
expect 0 - "a note in the overseer mailbox refuses no tool call: nothing halts a session on that mailbox"
tool deliver
assert_eq "RC=$RC context=$(context_line)" "RC=0 context=PostToolUse lane-mail-check: unread=1" \
  "a peer note reaches the named session in the context its next tool call's hook output carries"
assert_eq "$(jq -r '.hookSpecificOutput.additionalContext' "$TMP_ROOT/stdout" | grep -cF 'wrong version')" "1" \
  "that context carries the note itself"
peer_send 'Reply when the fix lands.'
run_payload '{"session_id":"s1","stop_hook_active":false,"agent_id":"dev-1"}'
expect 0 - "a subagent's turn end in the named session is handed nothing from the overseer mailbox"
CALL_ENV=()
assert_eq "$(overseer_unread 'Reply when the fix lands.')" "1" "and leaves the note unread for the lead's own turn end"

# A second session in the checkout, in another pane of the same tmux server,
# and one outside tmux: neither is handed the note at a turn end or after a
# tool call, and it stays unread until the named session's turn end takes it.
named_session peer_other
peer_send 'For the overseer alone.'
stop "${OTHER_ENV[@]}"
expect 0 - "a session in another pane of the checkout is handed nothing at its turn end"
CALL_ENV=("${OTHER_ENV[@]}")
tool deliver
CALL_ENV=()
assert_eq "RC=$RC context=$(context_line)" "RC=0 context=-" "nor after its tool call"
stop
expect 0 - "a session outside tmux is handed nothing at its turn end"
tool deliver
assert_eq "RC=$RC context=$(context_line)" "RC=0 context=-" "nor after its tool call"
assert_eq "$(overseer_unread 'For the overseer alone.')" "1" "the note stays unread"
stop "${SESSION_ENV[@]}"
expect 2 "lane-mail-check: unread=1" "and reaches the named session at its turn end"
stop "${SESSION_ENV[@]}"
expect 0 - "which is handed it once"

# The record is read at the checkout's root, never in the call's own
# directory: a Claude Code call made from another checkout, one holding no
# fleet state, still names the session the root's record names.
named_session peer_call_elsewhere
peer_send 'Named at the root.'
CALL_DIR="$PEER_SENDER"
CALL_ENV=("CLAUDE_PROJECT_DIR=$LANE")
stop "${SESSION_ENV[@]}"
CALL_DIR=""
CALL_ENV=()
expect 2 "lane-mail-check: unread=1" \
  "a turn end called from another checkout reads the record at the root CLAUDE_PROJECT_DIR names"

# The record binds its pair to the start of the tmux server it was written on,
# since a server a tmux restart starts may be handed the recorded pid and
# numbers its panes from %0 again. One naming this server's start names the
# session in its pane; one naming an earlier start names a server that is
# gone, and the session a later server put in the same pane id is handed
# nothing; one carrying no start names the session in its pane, which heals
# it; one whose server start tmux cannot read establishes nothing.
EARLIER_START=$((OVERSEER_SERVER_START - 3600))
bound_session() { # NAME START [JUDGE]
  named_session "$1" "${3:-$HOOK}"
  record_overseer "$OVERSEER_PANE" "$OVERSEER_SERVER" "" "$2"
}
bound_session peer_bound "$OVERSEER_SERVER_START"
peer_send 'Bound to its server.'
stop "${SESSION_ENV[@]}"
expect 2 "lane-mail-check: unread=1" "a record bound to this server's start names the session in its pane"
bound_session peer_reused "$EARLIER_START"
peer_send 'Sent to the gone server.'
stop "${SESSION_ENV[@]}"
expect 0 - "a session in the recorded pane id on a server started after the record is handed nothing at its turn end"
CALL_ENV=("${SESSION_ENV[@]}")
tool deliver
CALL_ENV=()
assert_eq "RC=$RC context=$(context_line)" "RC=0 context=-" "nor after its tool call"
assert_eq "$(overseer_unread 'Sent to the gone server.')" "1" "and the note stays unread"
bound_session peer_startless none
peer_send 'Sent to no start.'
stop "${SESSION_ENV[@]}"
expect 2 "lane-mail-check: unread=1" "a record carrying no start names the session in its pane"
bound_session peer_start_unread none
peer_send 'Start unread.'
stop "${SESSION_ENV[@]}" TMUX_SERVER_START=
expect 0 - "a session whose server start tmux cannot read is handed nothing"
assert_eq "$(overseer_unread 'Start unread.')" "1" "and the note stays unread"

# A checkout with no fleet record names no reader: no session there is handed
# a note, inside tmux or out.
new_plain_session peer_unnamed
(cd "$LANE" && "$REPO_ROOT/skills/orch/scripts/workflow-state" init oversee >/dev/null)
record_overseer "$OVERSEER_PANE" "$OVERSEER_SERVER"
peer_send 'Nobody named.'
(cd "$LANE" && "$REPO_ROOT/skills/orch/scripts/workflow-state" init oversee >/dev/null)
stop "${SESSION_ENV[@]}"
expect 0 - "a checkout whose fleet state names no pane hands a session nothing"
stop
expect 0 - "nor a session outside tmux"
assert_eq "$(overseer_unread 'Nobody named.')" "1" "and the note stays unread"

# A live watch reads this mailbox, so the named session leaves every line for
# it. The watch is a process whose command line names oversee-watch, recorded
# where a repeat watch records itself: beside the fleet state
# `workflow-state path oversee` prints.
FAKE_WATCH=""
start_watch() {
  local state
  state="$(cd "$LANE" && "$REPO_ROOT/skills/orch/scripts/workflow-state" path oversee)"
  mkdir -p "${state%/*}"
  env -i "PATH=$PATH" bash -c 'exec -a oversee-watch sleep 600' &
  FAKE_WATCH=$!
  printf 'pid=%s\nstate=%s\npane=none\norigin=hand\ncwd=%s\n' "$FAKE_WATCH" "$state" "$LANE" > "${state%/*}/oversee-watch.pid"
  start_follow
}
stop_watch() {
  kill "$FAKE_WATCH" 2>/dev/null || :
  wait "$FAKE_WATCH" 2>/dev/null || :
  stop_wake_processes
}
# Every orch library but the watch record's, linked one by one, since the
# reader sources its own from the install's directory.
hole_watch_library() {
  local name
  rm -f -- "${LANE:?}/.claude/skills/orch/scripts/lib"
  mkdir -p "$LANE/.claude/skills/orch/scripts/lib"
  for name in "$REPO_ROOT/skills/orch/scripts/lib"/*; do
    [ "${name##*/}" != watch-pid.sh ] || continue
    ln -s -f -n "$name" "$LANE/.claude/skills/orch/scripts/lib/${name##*/}"
  done
}

named_session peer_watched
start_watch
peer_send 'For the fleet.'
stop "${SESSION_ENV[@]}"
expect 0 - "a checkout whose fleet state a live watch holds hands the named session nothing at its turn end"
CALL_ENV=("${SESSION_ENV[@]}")
tool deliver
CALL_ENV=()
assert_eq "RC=$RC context=$(context_line)" "RC=0 context=-" "nor after its tool call"
assert_eq "$(overseer_unread 'For the fleet.')" "1" "and the note stays unread for the watch"
stop_watch
stop "${SESSION_ENV[@]}"
expect 2 "lane-mail-check: unread=1" "a watch record whose pid has exited holds nothing, and the named session is handed the note"

# A lane reads its own mailbox and never the overseer's beside it.
new_lane peer_lane ken-71
install_arms
(cd "$LANE" && "$REPO_ROOT/skills/orch/scripts/workflow-state" init oversee >/dev/null)
record_overseer "$OVERSEER_PANE" "$OVERSEER_SERVER"
send KEN-71 'Rebase onto main.'
peer_send 'Not for the lane.'
stop
expect 2 "lane-mail-check: unread=1" "a launched lane in a checkout holding a peer note is refused on its own mailbox alone"
assert_eq "own=$(grep -cF 'Rebase onto main.' "$ERR_FILE") peer=$(grep -cF 'Not for the lane.' "$ERR_FILE")" "own=1 peer=0" \
  "the refusal carries the lane's directive and not the peer's note"
assert_eq "$(overseer_unread 'Not for the lane.')" "1" "which stays unread in the overseer mailbox"

# A session whose install has no orch skill cannot be established as the one
# the record names, so a peer note standing there refuses it nothing.
named_session peer_noreader
peer_send 'No reader here.'
rm -rf -- "${LANE:?}/.claude/skills/orch" "${LANE:?}/.agents/skills/orch/scripts"
stop "${SESSION_ENV[@]}"
expect 0 - "a session with a peer note standing and no reader beside the hook is handed and refused nothing"

# Whether a live watch holds the fleet state is the install's answer for the
# named session: the state's path from its workflow-state, and liveness from
# its watch record library. One it cannot give leaves the mailbox neither read
# nor passed as read.
named_session peer_state_broken
peer_send 'Unjudged.'
watch_stub
stop "${SESSION_ENV[@]}"
expect 2 "lane-mail-check: fleet-state=$LANE/.claude/skills/orch/scripts/lib/watch-pid.sh" \
  "a watch-library read that cannot answer refuses the named session, never reads or passes the mailbox"
assert_eq "$(grep -c '^watch-pid: record=unreadable' "$ERR_FILE")" "1" "the script's own keyed line is replayed under the hook's"
assert_eq "$(overseer_unread 'Unjudged.')" "1" "and the note stays unread"
# The same broken read would refuse any arm that reached it: the halt arm, a
# subagent's turn end and a session the record does not name never do.
CALL_ENV=("${SESSION_ENV[@]}")
tool halt
expect 0 - "the halt arm never judges the overseer mailbox"
run_payload '{"session_id":"s1","stop_hook_active":false,"agent_id":"dev-1"}'
expect 0 - "nor does a subagent's turn end"
CALL_ENV=()
stop "${OTHER_ENV[@]}"
expect 0 - "nor a session the fleet record does not name"

named_session peer_no_mailbox
watch_stub
stop "${SESSION_ENV[@]}"
assert_eq "RC=$RC fleet-state=$(grep -c '^lane-mail-check: fleet-state=' "$ERR_FILE" || :)" "RC=0 fleet-state=0" \
  "the named session with no overseer mailbox never judges mail protection, independent of the wake probe"

named_session peer_library_absent
peer_send 'No library.'
state_stub delegate
hole_watch_library
stop "${SESSION_ENV[@]}"
expect 2 "lane-mail-check: fleet-state=$LANE/.claude/skills/orch/scripts/lib/watch-pid.sh" \
  "an install with the reader and no watch record library refuses the named session on the missing library"
assert_eq "$(overseer_unread 'No library.')" "1" "and the note stays unread"

mutant no-overseer-arm -e 's@^    MAILBOX_ITEM=overseer$@    return 0@'
named_session control_peer_named "$MUTANT_PATH"
peer_send 'Never read.'
stop "${SESSION_ENV[@]}"
expect 0 - "control: without the overseer mailbox arm a peer note never reaches the named session"

# With the record test gone, every lead session in a checkout no live watch
# holds is handed the mailbox, a second session in another pane among them.
mutant any-lead-reads -e '/^mail_check() {/,/^}/ { /^    overseer_identified || return 0$/d; }'
named_session control_peer_other "$MUTANT_PATH"
peer_send 'Taken by another pane.'
stop "${OTHER_ENV[@]}"
expect 2 "lane-mail-check: unread=1" \
  "control: without the record test a session in another pane is handed the named session's note"

# With the start test gone the pair alone names the session: a later server
# handed the recorded pid and pane id is handed the gone server's note.
mutant pair-only -e '/^   (if ol_names(/s@\$start;@(.server_start | tostring);@'
bound_session control_peer_reused "$EARLIER_START" "$MUTANT_PATH"
peer_send 'Taken by a later server.'
stop "${SESSION_ENV[@]}"
expect 2 "lane-mail-check: unread=1" \
  "control: without the start test a later server's session in the recorded pane id is handed the note"
# With an unread start read on, a startless record names a session whose
# server nothing could read.
mutant start-unread-names -e '/^      start=\$(tmux_server_start /s@)$@ || :)@'
bound_session control_peer_start_unread none "$MUTANT_PATH"
peer_send 'Unread start taken.'
stop "${SESSION_ENV[@]}" TMUX_SERVER_START=
assert_eq "RC=$RC unread=$(overseer_unread 'Unread start taken.')" "RC=2 unread=0" \
  "control: a hook that reads past an unread start hands that session the note"

mutant record-at-call-dir -e '/^overseer_identify() {/,/^}/ s@cd -- "\$ROOT" 2>/dev/null && @@'
named_session control_peer_call_elsewhere "$MUTANT_PATH"
peer_send 'Named at the call dir.'
CALL_DIR="$PEER_SENDER"
CALL_ENV=("CLAUDE_PROJECT_DIR=$LANE")
stop "${SESSION_ENV[@]}"
CALL_DIR=""
CALL_ENV=()
expect 0 - "control: a record read in the call's own directory names no session for the root's mailbox"

mutant peer-halt-reads -e '/^    \[ "\$ARM" != halt \] || return 0$/d'
named_session control_peer_halt "$MUTANT_PATH"
peer_send 'Halt arm.'
watch_stub
CALL_ENV=("${SESSION_ENV[@]}")
tool halt
# shellcheck disable=SC2034 # run_payload in lib/lane-mail-world.sh reads it
CALL_ENV=()
expect 2 "lane-mail-check: fleet-state=$LANE/.claude/skills/orch/scripts/lib/watch-pid.sh" \
  "control: without the halt exclusion the halt arm judges the overseer mailbox"

mutant peer-subagent-reads -e '/^    \[ "\$CALLER" != subagent \] || return 0$/d'
named_session control_peer_subagent "$MUTANT_PATH"
peer_send 'Subagent.'
watch_stub
run_payload '{"session_id":"s1","stop_hook_active":false,"agent_id":"dev-1"}' "${SESSION_ENV[@]}"
expect 2 "lane-mail-check: fleet-state=$LANE/.claude/skills/orch/scripts/lib/watch-pid.sh" \
  "control: without the lead-only rule a subagent's turn end judges the overseer mailbox"

mutant peer-no-file-test -e '/^    \[ -e "\$MAIL_ROOT\/overseer\/to-lane.jsonl" \] || \[ -L "\$MAIL_ROOT\/overseer\/to-lane.jsonl" \] || return 0$/d'
named_session control_peer_nofile "$MUTANT_PATH"
watch_stub
stop "${SESSION_ENV[@]}"
expect 2 "lane-mail-check: fleet-state=$LANE/.claude/skills/orch/scripts/lib/watch-pid.sh" \
  "control: without the file test the named session with no overseer mailbox judges the fleet state"

mutant peer-reader-refuses -e 's@^    resolve_reader || return 0$@    resolve_reader || refuse "$FAIL_KEY" "$FAIL_VALUE" "$FAIL_CAUSE"@'
named_session control_peer_noreader "$MUTANT_PATH"
peer_send 'No reader.'
rm -rf -- "${LANE:?}/.claude/skills/orch" "${LANE:?}/.agents/skills/orch/scripts"
stop "${OTHER_ENV[@]}"
expect 2 "lane-mail-check: reader=$LANE/.agents/skills/orch/scripts/lane-mail" \
  "control: refusing where no reader resolves holds every session in the checkout on mail none of them reads"

mutant peer-path-passes -e 's@^    refuse fleet-state "\$SCRIPTS/workflow-state" @    return 0 # @' -e 's/input_filename/""/'
named_session control_peer_state "$MUTANT_PATH"
peer_send 'Path unread.'
state_stub path-fails
stop "${SESSION_ENV[@]}"
assert_eq "RC=$RC unread=$(overseer_unread 'Path unread.')" "RC=0 unread=1" \
  "control: without the path refusal a failed state read passes mail protection and leaves the note unread"

mutant peer-library-passes -e 's@^    \*) refuse fleet-state "\$SCRIPTS/lib/watch-pid.sh" .*$@    *) return 1 ;;@'
named_session control_peer_library "$MUTANT_PATH"
peer_send 'Library unread.'
state_stub delegate
hole_watch_library
stop "${SESSION_ENV[@]}"
expect 2 "lane-mail-check: unread=1" "control: without the library refusal a library that answers nothing reads as no live watch"

mutant peer-ignores-watch -e '/^watch_live() {/,/^}/ s@^    0) return 0 ;;$@    0) return 1 ;;@'
named_session control_peer_watched "$MUTANT_PATH"
start_watch
peer_send 'Taken from the watch.'
stop "${SESSION_ENV[@]}"
stop_watch
expect 2 "lane-mail-check: unread=1" "control: without the live-watch rule the named session takes the watch's mail"

mutant peer-idle-stands-down -e '/^watch_live() {/,/^}/ s@^    1) return 1 ;;$@    1) return 0 ;;@'
named_session control_peer_idle "$MUTANT_PATH"
peer_send 'Nobody watching.'
stop "${SESSION_ENV[@]}"
expect 0 - "control: without the no-watch rule a checkout with no live watch leaves the note unread"

mutant lane-reads-overseer -e 's@^    MAILBOX_ITEM="\$ITEM"$@    MAILBOX_ITEM=overseer@'
new_lane control_peer_lane ken-72
install_hook "$MUTANT_PATH" "$LANE/.claude/hooks/lane-mail-check.sh"
(cd "$LANE" && "$REPO_ROOT/skills/orch/scripts/workflow-state" init oversee >/dev/null)
record_overseer "$OVERSEER_PANE" "$OVERSEER_SERVER"
send KEN-72 'Own directive.'
peer_send 'Peer note.'
stop
assert_eq "RC=$RC peer=$(grep -cF 'Peer note.' "$ERR_FILE")" "RC=2 peer=1" \
  "control: without the own-mailbox rule a lane is handed the peer's note"

# The deliver arm's acknowledgement removed: the same lines are handed over
# at every finished call of the lead's.
mutant deliver-no-ack -e '/^    acknowledge$/d'
new_lane control_deliver_ack ken-222
install_arms "$MUTANT_PATH"
send KEN-222 'Rebase first.'
tool deliver
tool deliver
assert_eq "RC=$RC context=$(context_line)" "RC=0 context=PostToolUse lane-mail-check: unread=1" \
  "control: without its acknowledgement the deliver arm hands the same lines over again"
# A Pi lane's turn rows: with the call gone the lane emits nothing, so every reader reads it
# unjudged.
mutant no-lane-row -e '/^lane_row$/d'
new_pi_lane control_pi_rows KEN-96 "$MUTANT_PATH"
pi_tool
pi_stop
assert_eq "rows=$(pi_rows)" "rows=-" "control: without the lane row call a Pi lane writes no row"
# Without the moved root a pool account's Pi install writes no row: the FLT-400
# silence the moved root closes.
mutant no-moved-pi-root -e 's@^  \[ -z "\$PI_HOOK_DIR" \] || \[ "\$PI_HOOK_DIR" != "\$THIS_HOOK_DIR" \] || HARNESS=pi$@  :@'
new_handoff_lane control_pi_pool KEN-99
PI_POOL="$LANE/.pool/acct"
mkdir -p "$PI_POOL"
ln -s "$LANE/.claude/skills/orch" "$PI_POOL/skills"
install_hook "$MUTANT_PATH" "$PI_POOL/kendex/hooks/lane-mail-check.sh"
PI_ROWS="$LANE/tmp/lane-mail/KEN-99/session-rows.jsonl"
pi_stop '{}'
run_payload "$(jq -nc --arg p "$PI_TURN" '{session_id:"s1",stop_hook_active:false,transcript_path:$p,context_window:200000}')" \
  "PI_CODING_AGENT_DIR=$PI_POOL"
assert_eq "rows=$(pi_rows)" "rows=-" "control: without the moved root a pool account's Pi install writes no row"

# The read naming no worktree: a lane whose record stands in its worktree's tmp
# is refused at every turn end.
mutant no-worktree-read -e 's@^  \[ "\$ROLE" = overseer \] || \[ "\$LAUNCHED" != yes \] || set -- --worktree "\$ROOT"$@  :@'
worktree_handoff_lane control_worktree_state KEN-442 "$MUTANT_PATH"
record_handoff KEN-442 "" "$LANE/tmp"
stop_at "$TRANSCRIPT" false LANE_MAIL_ITEM=KEN-442
expect 2 "lane-mail-check: context=500000" \
  "control: without the worktree read a record in the worktree's tmp leaves the refusal standing"
# The instruction naming no directory: the set line points at the main clone.
mutant no-state-dir -e 's@^  \[ -z "\$HANDOFF_FILE" \] || printf -v STATE_ARGS@  : || printf -v STATE_ARGS@'
worktree_handoff_lane control_worktree_set KEN-444 "$MUTANT_PATH"
stop_at "$TRANSCRIPT" false LANE_MAIL_ITEM=KEN-444
assert_eq "RC=$RC $(worktree_set_named KEN-444)" "RC=2 set=0 init=0" \
  "control: without the directory the read found, the set line does not name the worktree's tmp"
CALL_DIR=""

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
