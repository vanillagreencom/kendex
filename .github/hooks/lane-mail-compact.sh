#!/usr/bin/env bash
# ---
# name: lane-mail-compact
# event: PreCompact
# matcher:
# description: Flags a Copilot lane's or overseer's automatic compaction, so its next turn end holds it until it writes its handoff record, the backstop for a turn that crossed into the compaction before its context reading reached a turn end. A Copilot session is handed off before its compaction by its context reading: the orch `copilot-lane-context` Copilot extension hands the lane-mail-check hook the tokens in context from each `session.usage_info` event, that hook records them against the limit Copilot compacts at, and the session's agentStop judges that record under the shared context rule. Copilot CLI names no switch that turns its automatic compaction off, and a turn can cross that limit before a reading past the mark reaches its turn end; its `preCompact` event with `trigger` `auto` fires as the compaction starts in the background and is notification only, so it can neither hold, delay nor inject context. The judgement is the lane-mail-check hook's, run from beside this one with the argument `compact`: from the lead of a launched lane, or the fleet's overseer, named as lane-mail-check names them, its session one that hook recorded as a Copilot lead, it writes `compaction.json` naming the session in that session's mailbox directory, and the session's next turn end refuses under `compacted=auto` until the handoff record stands, the overseer's whatever its succession setting. A manual compaction, a subagent's, and a session that is no lane or overseer flag nothing; an automatic compaction of a session no lead record names is reported on stderr at exit 0 under `lane-mail-check: session-unrecorded=<id>`. A gap is refused at exit 2 on stderr, which Copilot shows the operator as a warning while the compaction goes on: the judge's `lane-mail-check: compaction-unrecorded=<path>`, and a lane-mail-check missing from beside this hook, opening `lane-mail-compact: judge=<path>`. Not run on claude: a fleet lane there runs with its automatic compaction off and its turn end reads its context from its transcript. Not run on codex: a fleet lane there runs with its automatic compaction off and its turn end reads its context from its rollout. Not run on pi: a fleet lane there runs with compaction off in its settings file and its turn end reads the window its Stop payload carries. Not run on gemini: the lane-mail-check hook it runs is not installed there, having no Stop event. Not run on antigravity: the lane-mail-check hook it runs is not installed there, its Stop payload carrying no `stop_hook_active`. Not run on opencode: it runs no hooks, and a compaction taken as an instruction records nothing. Not run on cursor: kendex delivers a hook there only as advisory rule prose, and a compaction taken as an instruction records nothing.
# summary: Marks a Copilot lane or overseer for handoff when Copilot starts compacting it automatically before its context reading could hand it off, so its next turn end holds it until it hands the work to a fresh session.
# safety: Runs only the lane-mail-check hook installed in its own directory, whose safety line covers what it reads and the `compaction.json` it writes. A judge that is not there is reported on stderr, never run from elsewhere.
# timeout: 30
# harnesses: [copilot]
# requires: [lane-mail-check, lane-mail-start]
# ---

set -euo pipefail

# The judge is the lane-mail-check hook installed beside this one: the one
# writer of a session's context records. Copilot's preCompact takes no answer
# and shows a non-zero exit to the operator as a warning, so a judge that is
# not there is reported to the operator at exit 2 while the compaction goes on.
JUDGE=""
if HOOK_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P); then
  JUDGE="$HOOK_DIR/lane-mail-check.sh"
fi
if [ -z "$JUDGE" ] || [ ! -f "$JUDGE" ]; then
  printf 'lane-mail-compact: judge=%s\n%s\n' "${JUDGE:-unlocatable}" \
    "for the operator: the lane-mail-check hook this one runs is not installed beside it, so Copilot's automatic compaction of this session, the backstop handoff mark, is not flagged and no turn end will hold for it. Install lane-mail-check in the same Copilot hook scope, and tell the session to write its handoff record and end, or end it and relaunch the item" >&2
  exit 2
fi
exec "$BASH" "$JUDGE" compact
