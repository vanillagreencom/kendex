# D015: A Copilot CLI session is measured by a kendex extension on its usage events, against the limit Copilot compacts at

[← Decision Index](INDEX.md)

**Date**: 2026-09-28

**Status**: Active

**Research**: KEN-2033; the Copilot CLI context research is attached to that issue

**Decision**: A Copilot CLI lane or overseer is judged by the shared context-handoff rule on readings a kendex Copilot extension, `skills/orch/scripts/copilot-lane-context/extension.mjs`, takes of the session's own `session.usage_info` events and hands to `lane-mail-check usage`. Its capacity is the limit Copilot compacts at, `floor(0.80 × tokenLimit)`, so the handoff lands before the compaction. `open-terminal` refuses a Copilot fleet launch it cannot make run the reader, and admits the account's status-line reader as the fallback only where the operator switched extensions off. A pending marker holds the turn end until the newest reading is recorded, and the `preCompact` hook flags an automatic compaction as the backstop, which the next turn end refuses until the handoff record stands. A relaunch after a handoff resumes no session.

**Why**: Copilot cannot turn automatic compaction off and no hook payload carries a token count; its SDK's usage event is the one documented source of the figures, fired at every model call, and the compaction threshold is the SDK's documented default. Each guard stands where Copilot cannot enforce the rule itself.

**Rejected**: The status-line command as the primary reader: a display command on its own interval. The session file's usage checkpoints: too sparse to judge a turn end on. `preCompact` alone as the mark: a notification at the compaction, so the handoff would always follow one self-compaction.

**Revisit when**: Copilot CLI gains a switch that turns automatic compaction off, a usage field that names the compaction limit, or takes extensions out of the experimental set.
