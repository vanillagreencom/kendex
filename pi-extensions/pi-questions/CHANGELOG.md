# Changelog

## Consumer-impacting changes

### 1.6.0

- RPC fallback: in `ctx.mode === "rpc"` hosts (Paseo, pi-web, VS Code bridges), or when `ctx.ui.custom()` resolves `undefined` without completing the request, the questionnaire now walks questions sequentially through native `ctx.ui.select()`/`ctx.ui.input()` dialogs instead of the custom TUI. Multi-select falls back to a comma-separated numbers input with a free-text custom answer. The `question` tool's `QuestionResult` shape is unchanged in both modes.
- When neither the custom TUI nor native select/input dialogs are available, the `question` tool now returns a clear cancelled-with-error result instead of hanging or refusing generically.
- New module `extensions/rpc-fallback.ts` (exports `isRpcMode`, `rpcDialogUI`, `presentQuestion`, `runRpcQuestionnaire`); headless non-RPC contexts still leave requests pending for bridge/API replies.

### 1.5.0

- Baseline: changelog introduced at this version. Consumer-impacting changes — behavior deltas, new/renamed/removed exports, settings and config changes, protocol/audit-shape changes — are recorded here from this version forward.
