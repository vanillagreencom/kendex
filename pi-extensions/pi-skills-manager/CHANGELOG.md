# Changelog

## Consumer-impacting changes

### 2.0.4

- Deleting a skill no longer holds Pi until every file is removed: Pi keeps drawing while the files go, though on Node a skill of thousands of files can still pause it briefly. The manager shows that the deletion is running and takes no input until it ends, then reports the deletion; a deletion that fails, or a skill list that fails to reload after one, is reported as an error and the manager takes input again. The skill preview lays out its content once per width instead of on every frame, and search matches against text built once when the list loads, so scrolling a long skill and typing a search stay responsive with a large catalog.

### 2.0.3

- The skill list is no longer loaded when a session starts, with or without a UI. `/skill` loads it when it opens and releases it when it closes. The list no longer keeps skill bodies in memory: it reads each skill's file for its metadata only, and the manager reads a skill's body from its file when it shows that skill. A listed skill whose file can no longer be read shows the read error in its preview and does not open in the editor, where before the editor opened on the body cached at load.

### 2.0.2

- Settings reads come from memory. A read is answered for one second without touching disk, then the settings files are read again. A change made in the extension manager, or a new session, applies at once; a hand edit to `settings.json` applies within one second. Before, every read went to disk.

### 2.0.1

- `PI_CODING_AGENT_DIR` is used only when it names a root-anchored path — a drive or UNC share on Windows, a leading `/` on POSIX. Anything else uses `~/.pi/agent`.

### 2.0.0

- **Breaking**: the settings namespace is renamed from `vstack` to `kendex`, with no compatibility fallback. Configuration previously read from `vstack.extensionManager.config["@vanillagreen/pi-skills-manager"]` in `.pi/settings.json` is now read from `kendex.extensionManager.config["@vanillagreen/pi-skills-manager"]`; settings still stored under the old key are ignored and this package silently falls back to its defaults until the key is renamed. The `package.json` block that declares these settings is renamed from `"vstack"` to `"kendex"` to match.
- **Breaking**: cross-extension interop symbols move from the `vstack.*` to the `kendex.*` `Symbol.for` registry (`kendex.pi-skills-manager.hide-startup-skills`, `kendex.pi-skills-manager.installed`, `kendex.pi-skills-manager.startup-patch`, `kendex.pi.modal-lock`, `kendex.pi.project-trust`). Symbol identity is the interop contract, so a package on the old namespace cannot see one on the new namespace — upgrade every installed `@vanillagreen` Pi extension together rather than one at a time.
- Project-root detection recognizes `.kendex-lock.json` instead of `.vstack-lock.json`.
- Repository, homepage, issue-tracker, and README asset URLs now point at `vanillagreencom/kendex`.

### 1.1.4

- Baseline: changelog introduced at this version. Consumer-impacting changes — behavior deltas, new/renamed/removed exports, settings and config changes, protocol/audit-shape changes — are recorded here from this version forward.
