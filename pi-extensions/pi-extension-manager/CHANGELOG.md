# Changelog

## Consumer-impacting changes

### 3.0.5

- Package updates and uninstalls no longer freeze the terminal. They run under a progress window where Escape cancels them, and stop after 10 minutes. Cancelling, the deadline or ending the session stops npm or kendex and every process it started, including the npm kendex runs; the failure notice says when a process could not be reached.
- npm directory lookups stop after 15 seconds, and ending the session stops one still running. Ending the session also stops the package instruction script a toggle or uninstall runs, and Escape stops the one an uninstall runs. The script that puts back instructions after a failed uninstall is the exception: it runs to its own 10-second deadline. Ending the session, quitting Pi included, waits up to 18 seconds: up to 4 for stopped commands to end, then that script's 10 seconds and up to 4 more to stop it at its deadline.
- Package command and instruction script failures add two notice keys beside `-exit` and `-launch`: `-timeout` for a command stopped at its deadline and `-cancelled` for one cancelled.
- An npm uninstall that fails or is cancelled puts back the package's APPEND_SYSTEM.md instructions it removed before running npm, unless the package is disabled; its notice says when they could not be restored.
- An instruction script that exits 0 after printing an `append-system:` notice, such as one that cannot write a read-only APPEND_SYSTEM.md, now fails the toggle or uninstall with the `append-system-notice` key, before any setting changes or npm runs.
- A package's broken reason also names each npm directory lookup that failed, after the not-found text.
- On Windows, npm, node and kendex run only from PATH, or from the path an `npmCommand` setting names, never from the open project; a command not found there fails with the directories searched. A quoted PATH directory is searched without its quotes, and a relative PATH entry is skipped. npm's `.cmd` entrypoint receives arguments holding spaces, `&` or `%` intact.

### 3.0.4

- npm version requests have a total deadline, a response byte limit and error handling. Closing the package popup or ending the session cancels its pending version requests.
- Failed instruction scripts keep package-toggle and orphan-uninstall settings unchanged. Package commands retain synchronous execution; a hung update, removal or npm directory lookup can still freeze the terminal.
- Pi package actions and extension lists keep user and project installations separate. Moving a project retains its disabled module state and the next enable removes its saved exclusion. Stored toggles from earlier versions remain readable with a migration warning through 3.0.x.
- Command completion reuses installed package labels. Popup searches reuse package children and scoped settings instead of rebuilding them on each redraw.

### 3.0.3

- Built-in extension selectors (`builtin:<name>` and `-builtin:<name>`) no longer appear as extension-setting rows. Manage built-ins through `pi config`; configured extension paths remain listed.

### 3.0.2

- The manager's glyph style lookup comes from memory. A lookup is answered for one second without touching disk, then the settings files are read again. A change made in the extension manager, or a new session, applies at once; a hand edit to a settings file applies within one second. Before, every lookup read the settings files. The manager's other settings reads still read and parse the settings files on each call.

### 3.0.1

- Manager notices, failures and command results now open with a `key=value` line naming the package, command or setting involved, followed by the explanation. This covers the enable and disable notices, the update-available notice, the npm and kendex install, update and uninstall results, the invalid `npmCommand` warning, and the self-disable refusal.
- The README's description of what the manager cannot do on OMP is rewritten to state each limit directly.

### 3.0.0

- Detect native oh-my-pi npm/link plugins, including disabled installations, through host-resolved configuration and plugin roots. Open `/kendex:extensions` or `/kendex:extensions:settings` on OMP 18.1.11 or later; Pi keeps `/extensions`. Native package toggles update plugin lock records. OMP updates, uninstall, individual module toggles, project suppression edits and other extensions' settings remain unsupported. Manager settings preserve existing YAML filenames and unknown fields, and malformed settings refuse writes.
- Keep native user/project entrypoints separate in search, filters and inspectors, and show settings only for the active manager installation. Trusted OMP project edits can create project settings without changing global values.
- **Breaking**: manager enable display, edits, resets and recovery use the global setting even for a project-installed manager. Project enable flags are ignored, so a project that disabled the manager through a project-scoped `enabled` has it follow the global value after this update; other manager settings retain project layering.
- `PI_CODING_AGENT_DIR` is used only when it names a root-anchored path — a drive or UNC share on Windows, a leading `/` on POSIX. Anything else uses `~/.pi/agent`.
- `APPEND_SYSTEM.md` blocks are written by each package's own vendored `scripts/append-system.mjs`, run by the manager under a 10-second bound, instead of by manager code. A package that declares `pi.appendSystem` but ships no script gets no block on enable. On npm uninstall the block is stripped before npm removes the package tree; the former global-directory cleanup backstop after uninstall is gone.
- `@oh-my-pi/pi-coding-agent` and `@oh-my-pi/pi-utils` (`>=18.1.11`) are optional peer dependencies.

### 2.0.0

- **Breaking**: the settings namespace is renamed from `vstack` to `kendex`, with no compatibility fallback. Configuration previously read from `vstack.extensionManager.config["@vanillagreen/pi-extension-manager"]` in `.pi/settings.json` is now read from `kendex.extensionManager.config["@vanillagreen/pi-extension-manager"]`; settings still stored under the old key are ignored and this package silently falls back to its defaults until the key is renamed. The `package.json` block that declares these settings is renamed from `"vstack"` to `"kendex"` to match.
- **Breaking**: cross-extension interop symbols move from the `vstack.*` to the `kendex.*` `Symbol.for` registry (`kendex.pi-extension-manager.installed`, `kendex.pi.extension-config-resolver`, `kendex.pi.extension-manager.open-quick-settings`, `kendex.pi.modal-lock`, `kendex.pi.project-trust`). Symbol identity is the interop contract, so a package on the old namespace cannot see one on the new namespace — upgrade every installed `@vanillagreen` Pi extension together rather than one at a time.
- Project-root detection recognizes `.kendex-lock.json` instead of `.vstack-lock.json`.
- Repository, homepage, issue-tracker, and README asset URLs now point at `vanillagreencom/kendex`.

### 1.4.0

- The settings editor shows the value an extension actually resolves when that value comes from a config file the manager does not own. A row backed by such a file names the file under the setting; editing the row writes Pi settings, which override the file; `delete` reports the file instead of resetting, because the value is not stored in Pi settings. Manager config still outranks an extension's own files, so the external lookup runs only when neither manager scope holds the key.
- New integration point: an extension that reads settings from channels beyond manager config registers an `ExternalConfigResolver` under `Symbol.for("kendex.pi.extension-config-resolver")`, keyed by package name. A missing, malformed, or throwing resolver is treated as "nothing external is set" — the modal never fails to render because of one. Resolutions are cached per `(extension, key)` per inventory, so the popup's per-keystroke re-read does not repeat filesystem work; the inventory is rebuilt on each open, so external-file edits still surface.
- For repos vendoring this extension's source: `extensions/manager/types.ts` adds `EXTERNAL_CONFIG_RESOLVER_SYMBOL`, `ExternalConfigResolution`, `ExternalConfigResolver`, and `ExternalConfigResolverRegistry`; `ConfigValue.scope` widens to `Scope | "default" | "external"` and gains an optional `source` display path; `Inventory` gains a required `cwd`. These are internal modules, not a package API — the manifest declares no `main`, `exports`, or `types`, Pi loads the extension through `pi.extensions`, and nothing outside this package imports them — so the required `cwd` and the widened union break no consumer and the bump stays minor. A vendored copy carrying local edits to these modules needs those three shapes updated.

### 1.3.2

- Baseline: changelog introduced at this version. Consumer-impacting changes — behavior deltas, new/renamed/removed exports, settings and config changes, protocol/audit-shape changes — are recorded here from this version forward.
