# Changelog

## Consumer-impacting changes

### 3.0.2

- A long run of spaces after `git push` in a prompt no longer delays its submission. The check for `git push ... --force` now scans the prompt once; before, it took about a second on a prompt with 32,768 spaces.

### 3.0.1

- Settings reads come from memory. A read is answered for one second without touching disk, then the settings files are read again. A change made in the extension manager, or a new session, applies at once; a hand edit to `settings.json` applies within one second. Before, every read went to disk.

### 3.0.0

- **Breaking**: the settings keys `enabled` and `defaultMode` are no longer read. The mode comes from `mode` alone, and a configuration without `mode` is off. A configuration that relied on `enabled: true` without `mode` had caveman active at 2.0.0 and gets an off session here, with no notice; set `mode` to keep it on. `/caveman debug` no longer lists the removed keys.
- A session state entry written before the `override` shape is no longer restored; the session starts from the configured mode.
- `PI_CODING_AGENT_DIR` is used only when it names a root-anchored path — a drive or UNC share on Windows, a leading `/` on POSIX. Anything else uses `~/.pi/agent`.

### 2.0.0

- **Breaking**: the settings namespace is renamed from `vstack` to `kendex`, with no compatibility fallback. Configuration previously read from `vstack.extensionManager.config["@vanillagreen/pi-caveman"]` in `.pi/settings.json` is now read from `kendex.extensionManager.config["@vanillagreen/pi-caveman"]`; settings still stored under the old key are ignored and this package silently falls back to its defaults until the key is renamed. The `package.json` block that declares these settings is renamed from `"vstack"` to `"kendex"` to match.
- **Breaking**: cross-extension interop symbols move from the `vstack.*` to the `kendex.*` `Symbol.for` registry (`kendex.pi-caveman.installed`, `kendex.pi.caveman`, `kendex.pi.project-trust`). Symbol identity is the interop contract, so a package on the old namespace cannot see one on the new namespace — upgrade every installed `@vanillagreen` Pi extension together rather than one at a time.
- Project-root detection recognizes `.kendex-lock.json` instead of `.vstack-lock.json`.
- Repository, homepage, issue-tracker, and README asset URLs now point at `vanillagreencom/kendex`.

### 1.2.4

- Baseline: changelog introduced at this version. Consumer-impacting changes — behavior deltas, new/renamed/removed exports, settings and config changes, protocol/audit-shape changes — are recorded here from this version forward.
