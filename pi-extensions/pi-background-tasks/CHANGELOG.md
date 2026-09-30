# Changelog

## Consumer-impacting changes

### 2.0.4

- A chunk of task output no longer costs a synchronous log write, a widget render and a full state save. Output is written to the task log in batches every 250 ms. The widget refreshes at most every 200 ms. Task state is saved at most once per second while output streams. The saved state file is compact JSON.
- A task log whose writes fall more than 4 MiB behind the task's output drops output until its next write, and records a line with the number of dropped bytes where the gap is. A failed log write records the same kind of line, with the write error, at the start of the next write.
- Process and systemd unit checks (`ps`, `systemctl`) run in the background with a 1-second timeout, at most 4 at a time. On Linux the process check reads `/proc` in the background. A check that times out, is killed, or fails to start for a reason other than a missing command no longer marks a live task as exited: the task stays running and is checked again on the next pass. On a host without `ps`, a restored task counts as exited when its process ID no longer exists. The user systemd manager check stops after its first answer until the extension loads again, for example after `/reload`. When that check times out while a task starts, later task starts with the same settings do not use `systemd-run` and do not ask again; the background check keeps asking.
- Session start and reload read the saved task history first and then check each restored running task once, so a long history no longer slows startup.
- Session shutdown waits at most 2 seconds for pending task log writes.

### 2.0.3

- Settings reads come from memory. A read is answered for one second without touching disk, then the settings files are read again. A change made in the extension manager, or a new session, applies at once; a hand edit to `settings.json` applies within one second. Before, every read went to disk.

### 2.0.2

- The npm install and uninstall helper reports each refusal as an `append-system: <key>=<value>` line followed by the explanation.
- An appendSystem source file that cannot be read is reported and skipped instead of throwing, so the npm install still completes.

### 2.0.1

- Finished tasks disappear from the inline widget after `widgetFinishedRetentionSeconds` without waiting for another task event. Long retention periods use bounded timer waits, and hiding the widget or ending the session clears the timer.
- The extension uses `PI_CODING_AGENT_DIR` only when root-anchored — a drive or UNC share on Windows, a leading `/` on POSIX. Anything else uses `~/.pi/agent`. The install helper is unchanged.

### 2.0.0

- **Breaking**: the settings namespace is renamed from `vstack` to `kendex`, with no compatibility fallback. Configuration previously read from `vstack.extensionManager.config["@vanillagreen/pi-background-tasks"]` in `.pi/settings.json` is now read from `kendex.extensionManager.config["@vanillagreen/pi-background-tasks"]`; settings still stored under the old key are ignored and this package silently falls back to its defaults until the key is renamed. The `package.json` block that declares these settings is renamed from `"vstack"` to `"kendex"` to match.
- **Breaking**: cross-extension interop symbols move from the `vstack.*` to the `kendex.*` `Symbol.for` registry (`kendex.background-tasks.installed`, `kendex.pi.activity`, `kendex.pi.mini-dashboard-stack`, `kendex.pi.modal-lock`, `kendex.pi.project-trust`). Symbol identity is the interop contract, so a package on the old namespace cannot see one on the new namespace — upgrade every installed `@vanillagreen` Pi extension together rather than one at a time.
- Project-root detection recognizes `.kendex-lock.json` instead of `.vstack-lock.json`.
- Repository, homepage, issue-tracker, and README asset URLs now point at `vanillagreencom/kendex`.

### 1.6.3

- Documentation only, no runtime change. This version ships what landed on main after 1.6.2 was published: the packaged README trimmed to the consumer contract — what the extension does, its tools, settings, and setup — with contributor-facing internals moved to the unpublished `DEVELOPMENT.md` (#1473). Published so the npm and pi.dev gallery pages carry the current copy; `extensions/` and `scripts/` are byte-identical to 1.6.2.

### 1.6.2

- Baseline: changelog introduced at this version. Consumer-impacting changes — behavior deltas, new/renamed/removed exports, settings and config changes, protocol/audit-shape changes — are recorded here from this version forward.
