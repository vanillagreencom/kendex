# Changelog

## Consumer-impacting changes

### Unreleased

- The extension uses `PI_CODING_AGENT_DIR` only when root-anchored — a drive or UNC share on Windows, a leading `/` on POSIX. Anything else uses `~/.pi/agent`. The install helper is unchanged.

### 2.0.0

- **Breaking**: the settings namespace is renamed from `vstack` to `kendex`, with no compatibility fallback. Configuration previously read from `vstack.extensionManager.config["@vanillagreen/pi-questions"]` in `.pi/settings.json` is now read from `kendex.extensionManager.config["@vanillagreen/pi-questions"]`; settings still stored under the old key are ignored and this package silently falls back to its defaults until the key is renamed. The `package.json` block that declares these settings is renamed from `"vstack"` to `"kendex"` to match.
- **Breaking**: cross-extension interop symbols move from the `vstack.*` to the `kendex.*` `Symbol.for` registry (`kendex.pi-qol.notification-service`, `kendex.pi-questions.installed`, `kendex.pi-questions.service`, `kendex.pi.activity`, `kendex.pi.modal-lock`, `kendex.pi.project-trust`). Symbol identity is the interop contract, so a package on the old namespace cannot see one on the new namespace — upgrade every installed `@vanillagreen` Pi extension together rather than one at a time.
- Project-root detection recognizes `.kendex-lock.json` instead of `.vstack-lock.json`.
- Repository, homepage, issue-tracker, and README asset URLs now point at `vanillagreencom/kendex`.

### 1.6.0

- RPC fallback: in `ctx.mode === "rpc"` hosts (Paseo, pi-web, VS Code bridges), or when `ctx.ui.custom()` resolves `undefined` without completing the request, the questionnaire now walks questions sequentially through native `ctx.ui.select()`/`ctx.ui.input()` dialogs instead of the custom TUI. Multi-select falls back to a comma-separated numbers input with a free-text custom answer; the option list (including the free-text fallback row) is always shown in full. The `question` tool's `QuestionResult` shape is unchanged in both modes.
- Empty-selection parity with the TUI: multi-question (or any-multi-select) requests add a "Skip (no selection)" row to single-select dialogs and accept empty multi-select input, matching the TUI confirm tab's ability to submit an unanswered tab; single-question single-select offers no skip, as in the TUI.
- Blank custom answers and out-of-range option numbers re-prompt with an error note instead of submitting an empty or silently-trimmed answer; persistent invalid input cancels after a bounded number of attempts. The dialog walker stops silently when the request is completed elsewhere (bridge reply/rejection/shutdown) mid-walk.
- When neither the custom TUI nor native select/input dialogs are available, the `question` tool now returns a clear cancelled-with-error result instead of hanging or refusing generically.
- Completing a question request now verifies request identity, not just id membership: a stale completer can no longer close a newer request that reused the same id.
- New module `extensions/rpc-fallback.ts` (exports `isRpcMode`, `rpcDialogUI`, `noDialogRouteError`, `presentQuestion`, `runRpcQuestionnaire`, `formatOptionRows`, `parseMultiSelection`); headless non-RPC contexts still leave requests pending for bridge/API replies.

### 1.5.0

- Baseline: changelog introduced at this version. Consumer-impacting changes — behavior deltas, new/renamed/removed exports, settings and config changes, protocol/audit-shape changes — are recorded here from this version forward.
