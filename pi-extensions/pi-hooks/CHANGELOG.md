# Changelog

## Consumer-impacting changes

### 0.6.1

- `blockBareCd` refuses a `cd` with no target. It changes to `$HOME` for every later tool call, the same permanent move as `cd /tmp`, and only the form carrying a path was caught before.

### 0.6.0

- The session-start drift report no longer opens with "kendex check could not run" when kendex ran and answered. Exit 1 (drift, or packages not yet evaluated) is relayed verbatim. Exit 2 means kendex could not check, in part or at all: a report carrying a "could not check" section is relayed under a "kendex check incomplete (exit 2); some drift status unknown:" line, while output opening with kendex's own `Error:` line or a usage `error:` (nothing was checked) keeps the "kendex check could not run (exit 2)" line. Exit 3+, a non-ENOENT spawn error, an inaccessible session directory, or an unexpected throw read as "could not run"; a missing binary (ENOENT) reads as "skipped". `DriftCheckResult` gains the `incomplete` variant.
- **Breaking**: the `sessionDriftAvailable` setting is removed, along with `driftCheckArgs` and `DriftCheckOptions.includeAvailable`. It passed `--no-available`, a flag `kendex check` has never had, so every session start with it off was a usage error.

### 0.5.0

- **Breaking**: the settings namespace is renamed from `vstack` to `kendex`, with no compatibility fallback. Configuration previously read from `vstack.extensionManager.config["@vanillagreen/pi-hooks"]` in `.pi/settings.json` is now read from `kendex.extensionManager.config["@vanillagreen/pi-hooks"]`; settings still stored under the old key are ignored and this package silently falls back to its defaults until the key is renamed. The `package.json` block that declares these settings is renamed from `"vstack"` to `"kendex"` to match.
- **Breaking**: cross-extension interop symbols move from the `vstack.*` to the `kendex.*` `Symbol.for` registry (`kendex.pi-hooks.installed`, `kendex.pi.project-trust`). Symbol identity is the interop contract, so a package on the old namespace cannot see one on the new namespace — upgrade every installed `@vanillagreen` Pi extension together rather than one at a time.
- Project-root detection recognizes `.kendex-lock.json` instead of `.vstack-lock.json`.
- Repository, homepage, issue-tracker, and README asset URLs now point at `vanillagreencom/kendex`.

### 0.4.0

- New `sessionDriftCheck` setting (default on, category Session): on `session_start` with reason `startup`, `new`, or `fork` (never `resume` or `reload`) runs `kendex check --quiet` in the session cwd without awaiting it (startup is never blocked) and, when it exits 1, appends the drift report to the agent's context as a `kendex-drift` custom message (`triggerTurn: false`); exit 2+ appends a "kendex check could not run" line with the diagnostic; a missing `kendex` binary appends one "kendex drift check skipped: kendex is not on PATH" line; exit 0 is silent. Companion settings `sessionDriftAvailable` (default on; off passes `--no-available`) and `driftCheckTimeoutMs` (default 30000). A session cwd that is missing or cannot be entered appends its own "kendex check could not run: project directory <dir> is not accessible; drift status unknown" line instead of being reported as a missing binary. An unexpected throw anywhere in the drift path appends "kendex check could not run: <reason>; drift status unknown" rather than falling silent, so no failure mode of the check reads as a clean install. New module `extensions/drift-check.ts` exporting `runDriftCheck`, `driftCheckArgs`, `driftMessage`, `driftErrorMessage`, `deliverDrift`, and types `DriftCheckResult` (variants `clean`, `drift`, `failed`, `unavailable`, `unusable-cwd`), `DriftCheckOptions`. New module `extensions/process.ts` exporting `runCommandAsync(command, args, cwd, timeoutMs)` and `CommandResult`; `extensions/cargo.ts`'s `runCargoAsync` delegates to it and `CargoResult` is now an alias of `CommandResult`. On timeout `runCommandAsync` signals the child's process group with SIGTERM and escalates to SIGKILL one second later only while the run has not already settled, so a child that exits on SIGTERM is never escalated and no escalation outlives the run. Mirrors `hooks/session-drift-check.sh` for Pi. The check itself never touches the project's git and never waits on the network; a kendex source cache under `~/.kendex/cache` older than its TTL is refreshed by a detached background process.

### 0.3.0

- New `blockRepoCopy` setting (default on, category Bash): refuses a recursive copy — `cp -r`/`-R`/`-a`, recursive or archive `rsync`, `git clone` of a local path, or a `tar` create-to-extract pipe — when the source carries repository history or a build tree AND the destination resolves under a temp/scratch root (`/tmp`, `/var/tmp`, `$TMPDIR`, `$CLAUDE_CODE_TMPDIR`, a `mktemp -d`, or any path containing `scratchpad`). Temp roots are commonly RAM-backed tmpfs, where such a copy fills the filesystem and every process writing there fails with ENOSPC. Both halves of the predicate are required, so an expensive tree copied elsewhere and an ordinary directory copied into scratch both pass. New exports from `extensions/repo-copy-guard.ts`: `repoCopyRefusal`, `refusalReason`, `isScratch`, `dangerousMarkers`, `classifySegment`. Mirrors `hooks/block-repo-copy.sh` for Pi.

### 0.1.6

- Baseline: changelog introduced at this version. Consumer-impacting changes — behavior deltas, new/renamed/removed exports, settings and config changes, protocol/audit-shape changes — are recorded here from this version forward.
