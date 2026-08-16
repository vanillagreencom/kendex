# Changelog

## Consumer-impacting changes

### 0.4.0

- New `sessionDriftCheck` setting (default on, category Session): on `session_start` with reason `startup`, `new`, or `fork` (never `resume` or `reload`) runs `vstack check --quiet` in the session cwd without awaiting it (startup is never blocked) and, when it exits 1, appends the drift report to the agent's context as a `vstack-drift` custom message (`triggerTurn: false`); exit 2+ appends a "vstack check could not run" line with the diagnostic; a missing `vstack` binary appends one "vstack drift check skipped: vstack is not on PATH" line; exit 0 is silent. Companion settings `sessionDriftAvailable` (default on; off passes `--no-available`) and `driftCheckTimeoutMs` (default 30000). New module `extensions/drift-check.ts` exporting `runDriftCheck`, `driftCheckArgs`, `driftMessage`, and types `DriftCheckResult`, `DriftCheckOptions`. New module `extensions/process.ts` exporting `runCommandAsync(command, args, cwd, timeoutMs)` and `CommandResult`; `extensions/cargo.ts`'s `runCargoAsync` delegates to it and `CargoResult` is now an alias of `CommandResult`. Mirrors `hooks/session-drift-check.sh` for Pi. The check itself never touches the project's git; vstack may fetch its own source caches under `~/.vstack/cache` at most once per TTL.

### 0.1.6

- Baseline: changelog introduced at this version. Consumer-impacting changes — behavior deltas, new/renamed/removed exports, settings and config changes, protocol/audit-shape changes — are recorded here from this version forward.
