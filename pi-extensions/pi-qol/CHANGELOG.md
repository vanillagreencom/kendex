# Changelog

## Consumer-impacting changes

### 2.3.0

- A session without a UI (`pi -p`, headless lanes) no longer loads the session-search index at startup.
- The session-search index is released after `sessionSearch.cacheTtlSeconds`, whose default is now 300 seconds instead of 0 (0 still keeps the index until the session ends). A search after the index was released opens the overlay at once, shows that it is loading, and fills in when the index has loaded again. The index keeps at most 32,768 characters of message text per session and 8,388,608 characters in total, newest session first; a session past that total is searched by name, path and first prompt only.
- A session-search resume or fork that waits in the editor as `/search:resume-pending` keeps only the latest one, and it is dropped when the session ends. Before, every earlier one stayed in memory.
- Parsed session prompts are kept for at most 64 sessions and finished thinking times for at most 256 blocks. Thinking labels are released at the end of each agent run, and notification cooldown entries once their cooldown has passed and all of them when the session ends.

### 2.2.1

- Turn-end notifications no longer freeze Pi when tmux is slow. Each tmux call now stops after 1 second and runs in the background. Each notification reads Pi's tmux pane, window and session in one call, so the window mark follows a pane that `break-pane` or `join-pane` moved. A terminal that does not accept output, such as a tmux client behind a dropped SSH link, is skipped at once, so later notifications still arrive. The window mark and the tmux message no longer wait for terminal writes, and a mark cleared by your input while its notification is still in flight is not set.
- Long tool output no longer costs an extra scan on every screen redraw. The queued-message status alignment now checks a text block again only when its text changes. It is installed when an interactive session starts and removed when the session ends.
- Settings reads come from memory. A read is answered for one second without touching disk, then the settings files are read again. A change made in the extension manager, or a new session, applies at once; a hand edit to `settings.json` applies within one second. Before, every read went to disk.

### 2.2.0

- Show a provider label before the model by default, using readable names such as `Copilot / GPT 6 Astra`. Disable it with `statusline.showProvider`.
- Move the working spinner before the project name when the QOL statusline is enabled. Static mode remains available; retry and compaction messages follow the indicator into the statusline. Requires Pi 0.86.0 or newer.

### 2.1.1

- The budget guard and the idle compaction trigger honour Pi's own `compaction.enabled`: while it is `false`, neither starts a compaction, so that one key turns off every automatic compaction in Pi. Before this, the budget guard still compacted at 85 percent of the window with Pi's compaction off. `/qol` now shows a `Budget guard` line, and both it and `Idle compaction` read "disabled by Pi compaction.enabled=false" when that key is the reason. With the key `true` or absent, both behave as before. A manual `/compact` is unaffected.

### 2.1.0

- The statusline can name the Claude login the session authenticated as, read from the Claude bridge's published `kendex.pi.claude-bridge.billing-identity.v1` surface. The bridge owns the judgement of what counts as a confirmed login, so the row shows an email only where the SDK confirmed one: nothing appears before the session's first turn, and nothing appears when the request used an API key or a third-party backend such as Bedrock or Vertex. The segment appears only while the active model uses the Claude bridge. The new `statusline.showAccount` setting turns the segment off; it defaults to on.

### 2.0.1

- Pi 0.85.1 parity: the shared summarizer rejects a summary whose generation stopped at the token cap, with the error "Summary generation hit the token cap and the summary is incomplete", as Pi's own compaction and branch-summary generators do. An incomplete summary no longer becomes the continuation checkpoint.
- `PI_CODING_AGENT_DIR` is used only when it names a root-anchored path — a drive or UNC share on Windows, a leading `/` on POSIX. Anything else uses `~/.pi/agent`.

### 2.0.0

- **Breaking**: the settings namespace is renamed from `vstack` to `kendex`, with no compatibility fallback. Configuration previously read from `vstack.extensionManager.config["@vanillagreen/pi-qol"]` in `.pi/settings.json` is now read from `kendex.extensionManager.config["@vanillagreen/pi-qol"]`; settings still stored under the old key are ignored and this package silently falls back to its defaults until the key is renamed. The `package.json` block that declares these settings is renamed from `"vstack"` to `"kendex"` to match.
- **Breaking**: cross-extension interop symbols move from the `vstack.*` to the `kendex.*` `Symbol.for` registry (`kendex.pi-agents-tmux.statusline`, `kendex.pi-qol.installed`, `kendex.pi-qol.notification-service`, `kendex.pi-qol.pending-queue.theme-patch`, `kendex.pi-qol.session-search.pending-context`, `kendex.pi-qol.status-text-alignment-patch`, `kendex.pi-qol.thinking-timer.patch`, `kendex.pi-qol.thinking-timer.store`, `kendex.pi-questions.service`, `kendex.pi.caveman`, `kendex.pi.extension-manager.open-quick-settings`, `kendex.pi.modal-lock`, `kendex.pi.project-trust`). Symbol identity is the interop contract, so a package on the old namespace cannot see one on the new namespace — upgrade every installed `@vanillagreen` Pi extension together rather than one at a time.
- Project-root detection recognizes `.kendex-lock.json` instead of `.vstack-lock.json`.
- Repository, homepage, issue-tracker, and README asset URLs now point at `vanillagreencom/kendex`.

### 1.8.0

- Pi 0.84.0 parity: session auto-rename now forwards `null` provider headers unchanged. `ModelRegistry.getApiKeyAndHeaders()` returns `ProviderHeaders` (`Record<string, string | null>`) where `null` is a header-deletion marker pi-ai acts on; `headerRecord()` dropped those entries, silently re-sending headers Pi asked to remove. `headerRecord()` is now exported and preserves `null` while still dropping empty and non-string values.

### 1.7.5

- Long-session budget guard now gives Pi's built-in post-response compaction first chance, avoiding duplicate `Already compacted` failures.
- Successful compaction suppresses repeat attempts at the same threshold until usage falls below the guard or advances to a new threshold; unrelated failures still surface and retry normally.
- Minimum supported Pi version is now 0.80.4 for long-session budget guard support.
- Active budget-guard compaction now finishes before terminal settlement or one-shot pane shutdown can overtake it. Delayed activity from a replaced session is ignored instead of changing the current session's guard state.

### 1.7.4

- Baseline: changelog introduced at this version. Consumer-impacting changes — behavior deltas, new/renamed/removed exports, settings and config changes, protocol/audit-shape changes — are recorded here from this version forward.
