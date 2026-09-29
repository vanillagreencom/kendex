# D015: A Copilot CLI session is measured by a kendex extension on its usage events, against the limit Copilot compacts at

[← Decision Index](INDEX.md)

**Date**: 2026-09-28

**Status**: Active

**Research**: KEN-2033, the attached `copilot-cli-context-research.md`; the Copilot CLI 1.0.88 and 1.0.89 extension probe the orchestrator ran for the owner's correction

**Context**: A fleet session hands off at 400000 tokens, or once its context passes `ORCH_HANDOFF_CONTEXT_PCT` (at most 90) of its effective capacity, the limit before automatic compaction (`lane_context_handoff_due` in `skills/orch/scripts/lib/lane-context.sh`). Claude Code, Codex and Pi turn compaction off, and their turn-end hook reads the tokens from the transcript. Copilot CLI names no setting, flag or variable that turns its automatic compaction off, and no hook payload carries a token count. Its `preCompact` hook is notification only: it cannot block or delay the compaction, and cannot inject context. The Copilot SDK a CLI extension joins the session through streams the figures: `session.usage_info` carries `currentTokens` and `tokenLimit`, the prompt token limit, at every model call and right after each compaction, with no `agentId` for the root agent. A user extension is `$COPILOT_HOME/extensions/<name>/extension.mjs`; extensions are an experimental feature, loaded only where `enabledFeatureFlags.EXTENSIONS` is true in `$COPILOT_HOME/settings.json`, and an explicit false there wins over `--experimental`. Measured, the CLI starts compacting at the first reading at or past 0.80 of `tokenLimit`, the SDK's documented `InfiniteSessionConfig.backgroundCompactionThreshold` default (copilot-sdk `types.d.ts`, `@default 0.80`). It emits `session.compaction_start` before the `session.usage_info` of the same tokens.

**Decision**: A Copilot CLI lane or overseer is judged by the shared rule, unchanged, on the readings a kendex Copilot extension takes of its own usage events. Its capacity is the limit Copilot compacts at, so the handoff lands before that compaction, at about 72 percent of the token limit at the default mark. No threshold is Copilot's alone.

1. **Reader.** The orch skill ships the extension as `skills/orch/scripts/copilot-lane-context/extension.mjs`. It does `joinSession({})` from `@github/copilot-sdk/extension` and `session.on('session.usage_info', ...)`, and ignores an event that carries `agentId`. For each root reading it runs `lane-mail-check.sh usage` from the Copilot hook scope the session loads (`<git root>/.github/hooks`, else `${COPILOT_HOME:-$HOME/.copilot}/hooks`), with `{session_id, cwd, current_tokens, token_limit}` on stdin. At most one run is in flight, bounded at 30 seconds, and a reading that lands during a run replaces the one queued. A gap is written once per distinct keyed line to the session timeline with `session.log` at level warning; a missing hook scope is a gap only for a session that can be a fleet session, one naming `LANE_MAIL_ITEM`, running in a tmux pane or working in a checkout with a `tmp/lane-mail` mailbox root, since the extension runs for every session on the home. For a launched lane's lead or the fleet overseer, named by the gate every arm of that hook asks, the usage arm records the session's `context.json`:
   - `tokens` is `current_tokens`.
   - `window`, the capacity, is `floor(0.80 x token_limit)`, and `capacity_source` names Copilot's documented background compaction default.
2. **Install.** `open-terminal` refuses a Copilot fleet launch unless it can make the lane's Copilot home run the reader. It copies the extension to `<home>/extensions/kendex-lane-context/extension.mjs`, rewriting it only where the content differs. It sets `enabledFeatureFlags.EXTENSIONS` true in `<home>/settings.json`, writing a linked file through to its target. An `EXTENSIONS` false is the operator's choice and is never overridden: the launch refuses as `unsupported-for-oversee harness=copilot reason=no-context-reader detail=disabled`, and as `detail=unreadable` or `detail=unwritable` where the file cannot be read or written. It refuses the item as `reason=no-context-hooks` where no hook scope the lane loads holds `lane-mail-check` and `lane-mail-compact`, judged once the item's worktree stands and before the harness starts in it: the project scope is that worktree's `.github/hooks`, made from the item's base or, on a relaunch, kept as it stands, never the caller's checkout, so project-scope hooks count only once committed on that base; the global scope is `<home>/hooks`.
3. **Judge.** The `agentStop` turn-end hook reads the session's own record and judges it through `lane_context_handoff_due`, as for Claude. The overseer's turn end hands the reading to `oversee-succeed --check-marks --context TOKENS:WINDOW`. With no record of the session, the context is reported unmeasured under `reading-unrecorded` and never read as room; `lanes context` reads the row `unrecorded`. A reading the usage arm could not write removes the session's earlier record with it, so a turn end past the mark never judges an older figure as room.
4. **Backstop.** A turn can cross the limit before a reading past the mark reaches a turn end, and Copilot emits the compaction's start before the reading that crossed. The `lane-mail-compact` hook runs at `preCompact` with `trigger` `auto` and flags the session in `compaction.json` beside the reading. The next turn end refuses under `compacted=auto` until the handoff record stands. An overseer's turn end refuses whatever its succession setting, as it does at the context mark. A gap in the flag's write exits 2, which Copilot shows the operator as a warning while the compaction goes on.
5. **Relaunch.** A local relaunch of a Copilot item whose handoff record stands resumes no session, by the retirement rule every harness's relaunch follows (KEN-1936, `session-retired`): the session that handed off still carries the reading past its mark, and the fresh brief resumes from the record.

Copilot honours an `agentStop` block 8 times in a row and then ends the turn unheld. A refusal the lane does not act on therefore ends that turn, and the refusal returns at the session's next turn end.

**Rationale**:

- The reader uses Copilot's own SDK event for the purpose, with the session's figures as Copilot counts them. It parses no screen text and no session file.
- The shared rule stays the one judge. The only Copilot-specific input is the capacity, and the record names where it came from.
- The extension runs in the session's own working directory and environment, so the lane is named by the same gate its turn end uses.
- Each guard stands where Copilot cannot enforce the rule itself: the launch gate because Copilot loads no extension and no hook the home does not name, and the backstop because `preCompact` cannot hold the compaction.

## Alternatives Considered

- **The statusLine command**: the owner's fallback, used only where the extension route is unavailable. It is available.
- **`events.jsonl` `session.usage_checkpoint`**: too sparse to judge a turn end on. The session file records usage at checkpoints, not after each model call.
- **A Copilot SDK runner as the harness** (`infiniteSessions: { enabled: false }`): a second launch surface without the CLI's hooks and session files.
- **`preCompact` alone as the mark**: a notification at the compaction, so the handoff always comes after one self-compaction. It is kept as the backstop.

**Revisit When**: Copilot CLI gains a switch that turns automatic compaction off, a usage field that names the compaction limit, or takes extensions out of the experimental set.

**Verification**: `skills/orch/tests/copilot-lane-context.sh`, `hooks/tests/lane-mail-usage.test.sh`, `hooks/tests/lane-mail-compact.test.sh`, `skills/orch/tests/open-terminal-copilot-context.sh`, `skills/orch/tests/open-terminal-copilot.sh`, `skills/orch/tests/lane_context_adapters.sh`, `skills/orch/tests/lanes_context.sh`

**References**: [D008](D008-copilot-agent-model.md); copilot-sdk `extension.d.ts` (`joinSession`), `session.d.ts` (`on`, `log`), `generated/session-events.d.ts` (`UsageInfoEvent`), `types.d.ts` (`backgroundCompactionThreshold`); Copilot hooks reference, https://docs.github.com/en/copilot/reference/hooks-reference
