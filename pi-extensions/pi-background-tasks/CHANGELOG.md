# Changelog

## Consumer-impacting changes

### 2.1.2

- The dashboard reads only a bounded log tail without blocking Pi, preserves configured character limits for Unicode output, reuses unchanged tails for each task, and reuses command layouts between frames. A notification regex that exceeds its execution deadline is disabled and reported once to the agent, including in headless sessions. Exit notifications mark omitted log output. Notifications, the dashboard and log tools share a limit of four disk reads at once.

### 2.1.1

- Session startup keeps fresh task logs when their working directory exists and its name ends in whitespace. Cleanup previously trimmed the name and could delete these files.

### 2.1.0

- New task logs go into one directory per session in the task directory's `lanes/` folder. A session's log directory is deleted once its working directory is gone (a merged worktree), and any log older than 5 days is deleted, when the next session starts. The prune reads only `lanes/`, and in it only real directories this user owns that the package marked as its own, so other folders in the task directory are never touched. Logs written before 2.1.0 stay where they are and are not deleted by the prune, `clear` or the task bound.
- A task's process handle and in-memory output are released once it has exited and its last log write has finished; `log` and exit wakes read the end of the log file instead. A task whose last log write failed or stalled keeps its in-memory output as the record, and a log that cannot be read shows `[log unreadable: <error>]` instead of empty output. At most 50 finished tasks are kept: past that, the oldest finished task is removed with its log. `clear` now deletes the logs of the tasks it removes. A forked session keeps the logs of tasks it copied from the original session. The task list is released when a session ends; the next session restores it from the saved snapshots.

### 2.0.4

- A task that prints a lot no longer makes Pi write the task log synchronously, save the full task state and redraw the widget for every output chunk. Slow task log writes no longer block Pi; the task waits on its output instead.
- A log write that fails loses its bytes, and a log write that stalls loses the output that arrives past a bounded buffer; the log marks each loss with its byte count. In 2.0.3 and earlier a failed write lost its bytes with no mark, and a stalled write blocked Pi.
- Checks of this session's tasks that outlived a Pi restart or reload no longer block Pi at startup or on their 30-second recheck.
- Startup and reload with a long task history no longer slow down.

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
