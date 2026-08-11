# Changelog

## Consumer-impacting changes

### 1.6.0

- RPC fallback: in `ctx.mode === "rpc"` hosts (Paseo, pi-web, VS Code bridges), or when `ctx.ui.custom()` resolves `undefined` without completing the request, the questionnaire now walks questions sequentially through native `ctx.ui.select()`/`ctx.ui.input()` dialogs instead of the custom TUI. Multi-select falls back to a comma-separated numbers input with a free-text custom answer; the option list (including the free-text fallback row) is always shown in full. The `question` tool's `QuestionResult` shape is unchanged in both modes.
- Empty-selection parity with the TUI: multi-question (or any-multi-select) requests add a "Skip (no selection)" row to single-select dialogs and accept empty multi-select input, matching the TUI confirm tab's ability to submit an unanswered tab; single-question single-select offers no skip, as in the TUI.
- Blank custom answers and out-of-range option numbers re-prompt with an error note instead of submitting an empty or silently-trimmed answer; persistent invalid input cancels after a bounded number of attempts. The dialog walker stops silently when the request is completed elsewhere (bridge reply/rejection/shutdown) mid-walk.
- When neither the custom TUI nor native select/input dialogs are available, the `question` tool now returns a clear cancelled-with-error result instead of hanging or refusing generically.
- Completing a question request now verifies request identity, not just id membership: a stale completer can no longer close a newer request that reused the same id.
- New module `extensions/rpc-fallback.ts` (exports `isRpcMode`, `rpcDialogUI`, `noDialogRouteError`, `presentQuestion`, `runRpcQuestionnaire`, `formatOptionRows`, `parseMultiSelection`); headless non-RPC contexts still leave requests pending for bridge/API replies.

### 1.5.0

- Baseline: changelog introduced at this version. Consumer-impacting changes — behavior deltas, new/renamed/removed exports, settings and config changes, protocol/audit-shape changes — are recorded here from this version forward.
