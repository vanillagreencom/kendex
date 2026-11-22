#!/usr/bin/env bash
# ---
# name: lane-mail-check
# event: Stop
# matcher:
# description: Holds a launched lane's turn end while its overseer's mail stands unread, at a context or account handoff mark, or when the lane reported nothing since its last judged turn end, and judges the fleet overseer's turn end at its own marks; the hooks that require it run it at their own events with an argument. The hook finds its own install, walking up from its directory to the home, the open repository or five levels for `skills/mailbox/scripts/lane-mail` or `.agents/skills/mailbox/scripts/lane-mail`, then the home's shared tree, then the open repository's where this hook is installed in it, and hands the payload to that install's `orch-runtime turn-end`, which makes every decision below; with no reader or no runtime there it reports `reader=unlocatable` or `runtime=unlocatable` and passes. Where that runtime is not built for its sources the hook starts its build through the install's `scripts/setup --detach`, holds a turn end in a checkout with a `tmp/lane-mail` directory under the setup's `runtime-building` line, and once more under `runtime-unbuilt` after a failed build, and passes continued turn ends and every other event with that line on stderr. The install directory names the harness: `.claude/hooks` for Claude Code, `.codex/hooks` for Codex, Pi's `kendex/hooks`, and `.github/hooks` or a directory holding `lane-mail-check.json` for Copilot CLI. Every refusal and notice `orch-runtime turn-end` writes opens `lane-mail-check: <key>=<value>` with its reason and remedy under it. A session is a launched lane where its root (`CLAUDE_PROJECT_DIR`, else the root the launch marker for `LANE_MAIL_ITEM` binds where that root stands, else the directory the call runs in) holds the mailbox `tmp/lane-mail/<item>` for the item `LANE_MAIL_ITEM` names, or the one mailbox named for the branch, and that item's launch marker under the common git directory binds the root; any other session is no lane and passes, unless it is the overseer below. A root a launch marker binds with no `tmp/lane-mail` directory is refused under `mailbox-missing=<path>` with the one `mkdir` command that makes it, which alone passes a tool call. Lane mail is the lead's: a subagent is handed none and acknowledges none. At a lane lead's turn end unread mail holds the turn under `unread=<count>`, one envelope per line, and is acknowledged only once that answer is written; a halt among them names the `lane-mail inbox` read that acknowledges it. `lane-mail-deliver` runs it with `deliver` after a tool call, `lane-mail-start` with `start` on Copilot CLI, and `lane-mail-prompt` with `prompt` on Claude Code, Codex and Copilot CLI, each handing the same lines over as context at exit 0; a Copilot prompt leaves them unread, since Copilot can drop that output, and a payload whose `kendex_ack` is `caller`, the pi-hooks lane mail wake's, is handed the acknowledging command as `kendex_ack` and acknowledges nothing here. A session start and a prompt are never held. `lane-mail-halt` runs it with `halt` before a tool call, where it acknowledges nothing and refuses: every call but that read while an unread halt directive stands, under `halt=<id>`, and a subagent's call without the read; in a launched lane, a harness question tool, Claude Code's `AskUserQuestion` and `EnterPlanMode`, Codex's `request_user_input` and Pi's `question`, under `question-tool=<name>`, naming the `lane-mail ask` and `lane-mail wait` route; and an attached agent launch (Claude Code's `Agent`, Codex's `spawn_agent` or `followup_task`, Pi's `subagent` or `delegate_subagent`, Copilot CLI's `task`, `Task` or `Agent`) by a lane lead or the bound overseer at the context mark, or at the mark less `ORCH_HANDOFF_AGENT_RESERVE_TOKENS` while an attached agent may still be out, as orch `references/skill-rules.md` § Round Closure states. A continued turn (`stop_hook_active`) skips the mail check. A gap the session cannot clear, a failed `git` read, an invalid or ambiguous item or an unreadable launch marker, holds a fresh turn end and is reported and passed on a continued turn, at a tool call, for a row and for the `lane` answer. After its mail a launched lane lead's turn end meets its context mark, then its account mark, under orch `references/skill-rules.md` § Round Closure and `references/oversee-events.md` § Hand off a lane before it runs out: a reached mark, a mark setting out of range and a transcript that cannot be read hold a session's first turn end there, a continued one included, with the handoff instruction in the refusal, and a later turn end of that session without the item's handoff record ends under `handoff-stopped=<key>`, the overseer sent a `lane-stopped=<item>` notice from the lane; a standing record passes the turn end before any mark is read; a reading or an account the judges cannot measure is reported and passed, never read as room. Then the idle judge holds once, under `idle=<item>`, a lead's turn end with no `lane-mail` ask or notice sent and no change to its lane status file since its last judged turn end, the count kept in `sent-count` in its mailbox, and never judges the words in the pane: a newest directive that carries a halt passes it; a turn this judge's own hold continued, or any continued turn on Pi, whose pi-hooks carrier runs no further request after one, sends the overseer a notice from the lane, reported under `idle-notice=<item>`, and ends; and a gap in the reader, the listing or the record ends the turn unjudged. A session with no lane item is the fleet's overseer where the checkout's fleet record binds its tmux server, pane and native session as `controller` (orch `schemas/workflow-state.md` § Controller), which a fleet start or `orch-runtime register --fleet` writes; nothing weaker makes one, any other session meets nothing here, and a session in tmux with no pane named is judged on the pane the record binds to its native session, or told once under `session-unjudged=missing-pane`. Only the overseer is handed the notes in the overseer mailbox, `tmp/lane-mail/overseer` at the main checkout, at its turn end and after its tool calls, at its start on Copilot CLI and at each prompt on Claude Code, Codex and Copilot CLI, and only while no live watch holds the fleet record, as orch `references/peer-mail.md` § Who reads a note states; where that cannot be settled it refuses under `fleet-state=<path>`. Its own standing handoff record passes its turn end. Otherwise its turn end is held under `wake=unarmed` or `wake=unwatched`, naming the command that starts its wake, where nothing can wake it, which is told and passed on a continued turn; records its context reading, or a gap naming why it took none, as `context.json` in the overseer mailbox, and its Stop row there; and meets its marks as orch `references/oversee-events.md` § The overseer's own marks states: a reached context mark holds whatever the succession setting and an account mark only while succession is on, each naming its succession route, and a mark the judge cannot answer is reported under `marks=` and passed. After each of its tool calls its context mark is judged again: a reached mark is handed over as context at each call, any other line once. A managed Jarvis session the record binds meets its context mark alone, with Jarvis's succession as the route. `session-start-row`, `session-end-row` and `stop-failure-row` run it with `row` and the event, which writes the event row of a session with no lane item into the overseer mailbox; a launched lane lead writes Stop and PreToolUse rows to `session-rows.jsonl` in its mailbox; Claude Code, Codex and Copilot CLI also write UserPromptSubmit with the normalized prompt's `digest` when the payload carries `prompt`, and Claude Code writes StopFailure with its `error` word. A held Stop keeps the turn open through PreToolUse; a passed Stop closes it. Only Pi reads the turn end from its transcript. The watch judges local lanes from these rows, with pane dialogs and walls first except on Pi, and Codex's failed-turn pane as an override of a Working row; hosted lanes keep their provider's reading. `critical-path-deny` runs it with `lane`, which prints `lane` for a launched lane and `none` otherwise. `lane-mail-model-switch` hands it Claude Code's `PostModelSwitch`, judged for a launched lane or the bound controller against the model its launch recorded. On Copilot CLI `lane-mail-compact` runs it with `compact` to flag an automatic compaction, which holds the turn end until the handoff record stands, and the context extension runs it with `usage` to record each context reading; how a Copilot turn end reads its context is orch `references/copilot-runtime.md` § Measurement. On Copilot CLI, whose payloads name no agent, lead sessions are recorded under `~/.cache/lane-mail/copilot-leads` at a session start and at a turn end whose transcript sits in its session's directory; a tool call from a session no record names is handed no mail and acknowledges none, and its compaction or context reading is not recorded (orch `references/copilot-runtime.md` § Wake and lane mail). A Copilot turn-end refusal is `{"decision":"block","reason":<text>}` on stdout at exit 0, a tool-call refusal `permissionDecision` `deny` at exit 2, and mail after a tool call a top-level `additionalContext` at exit 0; every other harness takes a refusal as exit 2 with the text on stderr. A Copilot payload that reaches another harness's install passes silently, so the Copilot install is the mailbox's one reader for a Copilot call. Not run on gemini: it has no Stop event. Not run on antigravity: its Stop payload carries no `stop_hook_active`.
# summary: Hands a lane its overseer's unread mail at its turn end, and holds the turn end once when the lane is due to hand its work to a fresh session or has reported nothing since its previous turn end. Holds the fleet overseer's turn end at its own handoff marks and while nothing is set to wake it.
# safety: Runs `git rev-parse --show-toplevel` in the session's directory and walks up from its own directory for its install's mailbox reader, reading nothing else, then runs that install's `orch-runtime turn-end` with the payload on stdin and hands its answer to the harness as it stands. Where the install's runtime is not built for its sources it runs the install's `scripts/setup --detach`, which starts the build in the background and holds this checkout's `tmp/lane-mail` while the build runs. Writes nothing itself.
# timeout: 30
# harnesses: [claude, codex, pi, copilot, opencode, cursor]
# requires: [lane-mail-deliver, lane-mail-halt, lane-mail-prompt, session-start-row, session-end-row, stop-failure-row, critical-path-deny, lane-mail-model-switch]
# requires-skills: [orch, mailbox, agent-runtime]
# ---

# Each line below serves one of two needs only shell meets: the harness runs
# this file by path, so finding the install it belongs to is the file's own
# work; and until that install's runtime is built, nothing else can answer.
# Every decision of the turn end is `orch-runtime turn-end`'s.
set -euo pipefail

# The harness's spelling of this directory names the harness to the verb.
dir=${BASH_SOURCE[0]%/*}
root=$(git -C "${CLAUDE_PROJECT_DIR:-$PWD}" rev-parse --show-toplevel 2>/dev/null) || root=""
home=$(cd -- "${HOME:-/}" 2>/dev/null && pwd -P) || home=""
hook=$(cd -- "$dir" 2>/dev/null && pwd -P) || hook=""

# The mailbox reader of this hook's own install: up from here to the home,
# the open repository or five levels; then the home's shared tree, for a
# harness root kept outside the home; then the open repository's, only where
# this hook is installed in it.
reader=""
at=$hook
levels=0
while [ -n "$at" ] && [ "$levels" -lt 5 ] && [ "$at" != "$root" ] && [ "$at" != / ]; do
  for candidate in "$at/skills/mailbox/scripts/lane-mail" "$at/.agents/skills/mailbox/scripts/lane-mail"; do
    if [ -z "$reader" ] && [ -x "$candidate" ]; then reader=$candidate; fi
  done
  if [ -n "$reader" ] || [ "$at" = "$home" ]; then break; fi
  at=${at%/*}
  [ -n "$at" ] || at=/
  levels=$((levels + 1))
done
if [ -z "$reader" ] && [ -n "$home" ] && [ "$home" != "$root" ] &&
  [ -x "$home/.agents/skills/mailbox/scripts/lane-mail" ]; then
  reader=$home/.agents/skills/mailbox/scripts/lane-mail
fi
if [ -z "$reader" ] && [ -n "$root" ] && [ -x "$root/.agents/skills/mailbox/scripts/lane-mail" ]; then
  case "$hook" in "$root"/*) reader=$root/.agents/skills/mailbox/scripts/lane-mail ;; esac
fi
if [ -z "$reader" ]; then
  printf 'lane-mail-check: reader=unlocatable hook=%s\n' "$dir" >&2
  exit 0
fi
export LANE_MAIL_CLI=$reader
scripts=${reader%/mailbox/scripts/lane-mail}/orch/scripts
# A launcher this install lacks is reported and passed on every arm, as a
# missing reader is: the shell's 127 for it would refuse every tool call on
# Copilot and Pi, which refuse a call on any nonzero status.
[ -x "$scripts/orch-runtime" ] ||
  { printf 'lane-mail-check: runtime=unlocatable path=%s\n' "$scripts/orch-runtime" >&2; exit 0; }

# stdout passes straight through; stderr is held so that the wrapper's own
# line for an unbuilt runtime never stands ahead of the answer given here.
rc=0
exec 3>&1
err=$("$scripts/orch-runtime" turn-end --hook-dir "$dir" "$@" 2>&1 1>&3 3>&-) || rc=$?
exec 3>&-
if [ "$rc" -ne 69 ]; then
  [ -z "$err" ] || printf '%s\n' "$err" >&2
  exit "$rc"
fi

# The runtime is not built for these sources: start its build, holding this
# checkout's mailbox directory, and say the build's own lines.
src=0
line=$("$scripts/setup" --detach ${root:+--hold "$root/tmp/lane-mail"} 2>&1) || src=$?
line=${line//agent-runtime-setup: /lane-mail-check: }
line=${line//orch-runtime-setup: /lane-mail-check: }
if [ "$src" -eq 3 ] && [ "$#" -eq 0 ]; then
  printf '%s\n' "$line" >&2
  # The launcher exits before reading the payload when its runtime is absent.
  if jq -es 'length == 1 and .[0].stop_hook_active == true' >/dev/null 2>&1; then exit 0; fi
  case "$dir" in
    */.claude/hooks | */.codex/hooks | */.pi/kendex/hooks | */.pi/agent/kendex/hooks) copilot=0 ;;
    */.github/hooks) copilot=1 ;;
    *) if [ -f "$dir/lane-mail-check.json" ]; then copilot=1; else copilot=0; fi ;;
  esac
  if [ "$copilot" -eq 0 ]; then exit 2; fi
  nl=$'\n'
  reason=${line//\\/\\\\}
  reason=${reason//\"/\\\"}
  reason=${reason//$nl/\\n}
  printf '{"decision":"block","reason":"%s"}\n' "$reason"
  exit 0
fi
[ -z "$line" ] || printf '%s\n' "$line" >&2
exit 0
