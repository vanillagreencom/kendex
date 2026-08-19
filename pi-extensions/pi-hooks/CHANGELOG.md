# Changelog

## Consumer-impacting changes

### 0.4.0

- New `sessionDriftCheck` setting (default on, category Session). On
  `session_start` with reason `startup`, `new` or `fork`, runs
  `vstack check --quiet` in the session cwd without awaiting it, and appends
  the drift report to the agent's context when it exits 1.
- Every other outcome is stated rather than silent: exit 2+, a missing `vstack`
  binary, an inaccessible cwd and an unexpected throw each append their own
  line, so no failure of the check reads as a clean install. Exit 0 is silent.
- Companion settings `sessionDriftAvailable` (default on) and
  `driftCheckTimeoutMs` (default 30000).
- New module `extensions/drift-check.ts`: `runDriftCheck`, `driftCheckArgs`,
  `driftMessage`, `driftErrorMessage`, `deliverDrift`, and types
  `DriftCheckResult`, `DriftCheckOptions`.
- New module `extensions/process.ts`: `runCommandAsync` and `CommandResult`.
  `extensions/cargo.ts`'s `runCargoAsync` delegates to it, and `CargoResult` is
  now an alias of `CommandResult`.
- Mirrors `hooks/session-drift-check.sh` for Pi.

### 0.3.0

- New `blockRepoCopy` setting (default on, category Bash): refuses a recursive
  copy — `cp -r`/`-R`/`-a`, recursive `rsync`, `git clone` of a local path, or
  a `tar` create-to-extract pipe — when the source carries repository history
  AND the destination resolves under a temp or scratch root. Such roots are
  commonly tmpfs, where the copy fills the filesystem and every process writing
  there fails with ENOSPC.
- Both halves of the predicate are required, so a large tree copied elsewhere
  and an ordinary directory copied into scratch both pass.
- New exports from `extensions/repo-copy-guard.ts`: `repoCopyRefusal`,
  `refusalReason`, `isScratch`, `dangerousMarkers`, `classifySegment`.
- Mirrors `hooks/block-repo-copy.sh` for Pi.

### 0.1.6

- Baseline: changelog introduced at this version. Consumer-impacting changes
  are recorded here from this version forward.
