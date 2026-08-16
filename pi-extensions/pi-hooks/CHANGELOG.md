# Changelog

## Consumer-impacting changes

### 0.4.0

- New `sessionDriftCheck` setting (default on, category Session): on `session_start` with reason `startup`, `new`, or `fork` (never `resume` or `reload`) runs `vstack check --quiet` in the session cwd without awaiting it (startup is never blocked) and, when it exits 1, appends the drift report to the agent's context as a `vstack-drift` custom message (`triggerTurn: false`); exit 2+ appends a "vstack check could not run" line with the diagnostic; a missing `vstack` binary appends one "vstack drift check skipped: vstack is not on PATH" line; exit 0 is silent. Companion settings `sessionDriftAvailable` (default on; off passes `--no-available`) and `driftCheckTimeoutMs` (default 30000). A session cwd that is missing or cannot be entered appends its own "vstack check could not run: project directory <dir> is not accessible; drift status unknown" line instead of being reported as a missing binary. New module `extensions/drift-check.ts` exporting `runDriftCheck`, `driftCheckArgs`, `driftMessage`, and types `DriftCheckResult` (variants `clean`, `drift`, `failed`, `unavailable`, `unusable-cwd`), `DriftCheckOptions`. New module `extensions/process.ts` exporting `runCommandAsync(command, args, cwd, timeoutMs)` and `CommandResult`; `extensions/cargo.ts`'s `runCargoAsync` delegates to it and `CargoResult` is now an alias of `CommandResult`. Mirrors `hooks/session-drift-check.sh` for Pi. The check itself never touches the project's git and never waits on the network; a vstack source cache under `~/.vstack/cache` older than its TTL is refreshed by a detached background process.

### 0.3.0

- New `blockRepoCopy` setting (default on, category Bash): refuses a recursive copy — `cp -r`/`-R`/`-a`, recursive or archive `rsync`, `git clone` of a local path, or a `tar` create-to-extract pipe — when the source carries repository history or a build tree AND the destination resolves under a temp/scratch root (`/tmp`, `/var/tmp`, `$TMPDIR`, `$CLAUDE_CODE_TMPDIR`, a `mktemp -d`, or any path containing `scratchpad`). Temp roots are commonly RAM-backed tmpfs, where such a copy fills the filesystem and every process writing there fails with ENOSPC. Both halves of the predicate are required, so an expensive tree copied elsewhere and an ordinary directory copied into scratch both pass. New exports from `extensions/repo-copy-guard.ts`: `repoCopyRefusal`, `refusalReason`, `isScratch`, `dangerousMarkers`, `classifySegment`. Mirrors `hooks/block-repo-copy.sh` for Pi.

### 0.1.6

- Baseline: changelog introduced at this version. Consumer-impacting changes — behavior deltas, new/renamed/removed exports, settings and config changes, protocol/audit-shape changes — are recorded here from this version forward.
