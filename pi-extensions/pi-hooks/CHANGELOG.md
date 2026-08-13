# Changelog

## Consumer-impacting changes

### 0.3.0

- New `blockRepoCopy` setting (default on, category Bash): refuses a recursive copy — `cp -r`/`-R`/`-a`, recursive or archive `rsync`, `git clone` of a local path, or a `tar` create-to-extract pipe — when the source carries repository history or a build tree AND the destination resolves under a temp/scratch root (`/tmp`, `/var/tmp`, `$TMPDIR`, `$CLAUDE_CODE_TMPDIR`, a `mktemp -d`, or any path containing `scratchpad`). Temp roots are commonly RAM-backed tmpfs, where such a copy fills the filesystem and every process writing there fails with ENOSPC. Both halves of the predicate are required, so an expensive tree copied elsewhere and an ordinary directory copied into scratch both pass. New exports from `extensions/repo-copy-guard.ts`: `repoCopyRefusal`, `refusalReason`, `isScratch`, `dangerousMarkers`, `classifySegment`. Mirrors `hooks/block-repo-copy.sh` for Pi.

### 0.1.6

- Baseline: changelog introduced at this version. Consumer-impacting changes — behavior deltas, new/renamed/removed exports, settings and config changes, protocol/audit-shape changes — are recorded here from this version forward.
