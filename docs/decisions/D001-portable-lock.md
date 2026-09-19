# D001: Portable install record

[← Decision Index](INDEX.md)

**Date**: 2026-09-19

**Status**: Active

**Research**: —

**Applies to**: `crates/core/src/lock/`, `crates/core/src/engine/posture.rs`, `crates/core/src/engine/generated_paths.rs`

## Summary

`.kendex-lock.json` is committed with the renders it records and reads as its own in every clone. Nothing in it names the checkout that wrote it: every position is spelled as a remainder of the root, a path source's provenance is its declaration rather than the directory it resolved to, and the root itself is not written. What only one machine knows — the delivery an install used, when it was made, the root it was written under — is the machine half of the record at `.cache/kendex/lock-local.json`, which the managed ignore block keeps out of git. The lock format is version 11; a version 10 record is refused by name and the way out is a fresh install, with `--record-existing` where the renders on disk are current.

## Context

The renders under `.agents/`, `.claude/`, `.codex/` and `.pi/` are committed, but the lock that says what they are was gitignored and written per machine. A fresh clone, a second machine and a linked worktree therefore started with renders and no record, and every package read as files kendex never wrote: `kendex check` reported them as blocked, never as stale, and an overseer ran an unmanaged copy nine fixes behind for four days with a clean drift notice.

## Pattern

The committed half holds what every clone shares and the machine half holds what one machine did. The split is by whether a value is a fact about the installation or about the checkout:

| Field | Where | Why |
|-------|-------|-----|
| name, kind, harness, source, sourceHash, sourceCommit, renderedHash, enabled, upstreamSkills, registration, reasons | committed | facts about the installation, identical in every clone |
| emitted | committed; `kind` and `name` as they are, `paths` as remainders of the root, slashed | positions are names joined onto the root (invariant 17), so the remainder is the whole fact |
| sourceRepo, sources.repo, bundles.sourceRepo | committed; a path source as its declaration, read the way `source::path_root` reads it (`.` for the declaring root, `../catalog` as typed, an absolute declaration as typed) | the declaration is the one spelling of a path source every clone shares, and the committed manifest already carries it, so committing it discloses nothing new; the directory it resolves to differs per machine, and recorded instead every clone read its own installs as rebound; keeps the durable-provenance rule (invariant 4) and the update holds working in every clone |
| method, installedAt | machine half | what this apply on this disk did |
| root | machine half | the one question still needing it, whether a reconnected folder is the one a project left, is a question about this machine; the relocate refusal for a folder holding a third project's record stands on this half alone, and a folder whose cache was cleared reads as holding no record, which the ordinary confirmation allows |

Reading rejoins each remainder onto the root reading it and refuses a position that is no remainder (absolute, empty, `.` or `..`), so a lock can claim nothing outside the project holding it; writing refuses the same claim before spelling it. A machine half for a key the committed record no longer names is dropped, and an entry with no machine half reads the manifest's answer for its delivery and takes a fresh timestamp on the next apply. A machine half this build cannot read, from another build sharing the cache or from an interrupted write, reads as absent for the same reason: it carries nothing an install needs, and the next save writes it whole.

## Decision Criteria

A field goes in the committed half when its value is the same in every clone of the project at the same commit. A field whose value differs per machine, or that a clone cannot use, goes in the machine half. A field that would be the same everywhere but is spelled with a machine path is respelled, never moved.

## Alternatives Considered

- **Keep the lock per machine and settle every clone with `--record-existing`**: the state this decision ends; the settle needs consent on every clone and reports nothing about staleness.
- **Move `sourceRepo` to the machine half, as the request listed it**: rejected. Without it a clone cannot refuse a rebind (invariant 4) or hold sibling packages at their recorded commits during a targeted update. Recorded as the declaration, it carries exactly what the committed manifest carries.
- **Record a path source by the directory it resolved to, respelled as a remainder where it sits under the root**: rejected. A declaration outside the root (`../catalog`, the sibling-checkout shape `kendex source add` accepts) resolves to an absolute path naming the writing machine and its account, which the manifest does not hold, and every other clone resolves the same declaration elsewhere and reads its installs as rebound.
- **Keep absolute positions with the writing root and rebase on read** (the version 10 shape): rejected. Every machine writes its own root and paths, so a committed record would change on every apply on every machine.
- **Keep the machine half under `.kendex-local/`**: rejected. That directory is the project's local source, which git carries; `.cache/` is already per-machine and ignored.

## Impact

The commit offer and the render inventory list the lock beside `.kendex-generated.json`, so a refresh commits the record with the render diff. The managed ignore block drops the lock, and a consumer's own rule that still ignores it is reported with what a clone loses. `WORKTREE_COPIES` no longer copies the lock into a worktree. A linked worktree whose `.cache` is a link to the main checkout's shares the machine half; the shared values are the delivery and the timestamp, which agree across worktrees of one branch, and the root, which then names the last checkout that applied.

## Revisit When

- `kendex check` claims a matching unmanaged copy into the lock on its own (KEN-1585), which retires `--record-existing` as the migration path.
- A person respelling a path declaration (`catalog` to `./catalog/` is one identity; `../catalog` to `/home/me/catalog` is not) is common enough that the rebind refusal it produces needs a remedy of its own.
- The relocate refusal for a folder holding a third project's record has to survive a cleared cache; then the writing root, or a project identity, goes into the committed half.
