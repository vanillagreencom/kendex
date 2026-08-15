# Changelog

## Consumer-impacting changes

### 0.4.0

- New `sessionDriftCheck` setting (default on, category Session): on `session_start` (every reason except `reload`) runs `vstack check --quiet` in the session cwd and, when it exits 1, appends the drift report to the agent's context as a `vstack-drift` custom message (`triggerTurn: false`); exit 2+ appends a "vstack check could not run" line with the diagnostic; exit 0 and a missing `vstack` binary are silent. Companion settings `sessionDriftAvailable` (default on; off passes `--no-available`) and `driftCheckTimeoutMs` (default 30000). New module `extensions/drift-check.ts` exporting `runDriftCheck`, `driftCheckArgs`, `driftMessage`, and types `DriftCheckResult`, `DriftCheckOptions`. `extensions/cargo.ts` gains `runCommandAsync(command, args, cwd, timeoutMs)`; `runCargoAsync` now delegates to it. Mirrors `hooks/session-drift-check.sh` for Pi.

### 0.3.0

- New `blockRepoCopy` setting (default on, category Bash): refuses a recursive copy — `cp -r`/`-R`/`-a`, recursive or archive `rsync`, `git clone` of a local path, or a `tar` create-to-extract pipe — when the source carries repository history or a build tree AND the destination resolves under a temp/scratch root (`/tmp`, `/var/tmp`, `$TMPDIR`, `$CLAUDE_CODE_TMPDIR`, a `mktemp -d`, or any path containing `scratchpad`). Temp roots are commonly RAM-backed tmpfs, where such a copy fills the filesystem and every process writing there fails with ENOSPC. Both halves of the predicate are required, so an expensive tree copied elsewhere and an ordinary directory copied into scratch both pass. New exports from `extensions/repo-copy-guard.ts`: `repoCopyRefusal`, `refusalReason`, `isScratch`, `dangerousMarkers`, `classifySegment`. Mirrors `hooks/block-repo-copy.sh` for Pi.

### 0.1.6

- Baseline: changelog introduced at this version. Consumer-impacting changes — behavior deltas, new/renamed/removed exports, settings and config changes, protocol/audit-shape changes — are recorded here from this version forward.
