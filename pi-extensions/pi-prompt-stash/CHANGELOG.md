# Changelog

## Consumer-impacting changes

### 3.0.3

- The stash popup no longer rescans every draft on each frame or keystroke: each draft's search text, preview and line count are computed once, and search results are reused until the query or the drafts change. The list shows no more rows than fit in the popup at its `popupMaxHeight`, whatever `listRows` says, so the key hints stay visible and the selected draft stays on screen.
- A stash holds at most 500 prompts and 8,388,608 bytes of store file. A stash past either limit is refused with a `prompt_stash_refused=item-limit` or `prompt_stash_refused=byte-limit` error and the editor text is kept. A store file already over the byte limit is not loaded; the stash and the popup report `prompt_stash_refused=store-too-large` with its path.
- Store reads and writes no longer block Pi. They run one at a time, so two quick stashes both land. Text typed while a stash is being written stays in the editor. A delete in the popup keeps any draft stashed while the popup was open.

### 3.0.2

- Settings reads come from memory. A read is answered for one second without touching disk, then the settings files are read again. A change made in the extension manager, or a new session, applies at once; a hand edit to `settings.json` applies within one second. Before, every read went to disk.

### 3.0.1

- Prompt stash notices start with a stable item-count field.

### 3.0.0

- **Breaking**: stash stores are no longer moved from the older locations `~/.pi/agent/kendex/prompt-stash/sessions/<id>/` and `<project>/.pi/<store file>` at session start or when the popup opens. Drafts still sitting in those locations stay there and `/prompt-stash` no longer shows them; move them into the per-session directory by hand to keep them.
- `PI_CODING_AGENT_DIR` is used only when it names a root-anchored path — a drive or UNC share on Windows, a leading `/` on POSIX. Anything else uses `~/.pi/agent`.

### 2.0.0

- **Breaking**: the settings namespace is renamed from `vstack` to `kendex`, with no compatibility fallback. Configuration previously read from `vstack.extensionManager.config["@vanillagreen/pi-prompt-stash"]` in `.pi/settings.json` is now read from `kendex.extensionManager.config["@vanillagreen/pi-prompt-stash"]`; settings still stored under the old key are ignored and this package silently falls back to its defaults until the key is renamed. The `package.json` block that declares these settings is renamed from `"vstack"` to `"kendex"` to match.
- **Breaking**: cross-extension interop symbols move from the `vstack.*` to the `kendex.*` `Symbol.for` registry (`kendex.pi.modal-lock`, `kendex.pi.project-trust`, `kendex.prompt-stash.installed`). Symbol identity is the interop contract, so a package on the old namespace cannot see one on the new namespace — upgrade every installed `@vanillagreen` Pi extension together rather than one at a time.
- Project-root detection recognizes `.kendex-lock.json` instead of `.vstack-lock.json`.
- Repository, homepage, issue-tracker, and README asset URLs now point at `vanillagreencom/kendex`.

### 1.1.1

- Baseline: changelog introduced at this version. Consumer-impacting changes — behavior deltas, new/renamed/removed exports, settings and config changes, protocol/audit-shape changes — are recorded here from this version forward.
