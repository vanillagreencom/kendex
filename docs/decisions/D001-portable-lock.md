# D001: Portable install record

[← Decision Index](INDEX.md)

**Date**: 2026-09-19

**Status**: Active

**Research**: —

**Applies to**: `crates/core/src/lock/`, `crates/core/src/engine/posture.rs`, `crates/core/src/engine/generated_paths.rs`

## Summary

`.kendex-lock.json` is committed with the renders it records and reads as its own in every clone. Nothing in it names the checkout that wrote it: every position and every provenance under the project is spelled as a remainder of the root, and the root itself is not written. What only one machine knows — the delivery an install used, when it was made, the root it was written under — is the machine half of the record at `.cache/kendex/lock-local.json`, which the managed ignore block keeps out of git. The lock format is version 11; a version 10 record is refused by name and the way out is a fresh install, with `--record-existing` where the renders on disk are current.

## Context

The renders under `.agents/`, `.claude/`, `.codex/` and `.pi/` are committed, but the lock that says what they are was gitignored and written per machine. A fresh clone, a second machine and a linked worktree therefore started with renders and no record, and every package read as files kendex never wrote: `kendex check` reported them as blocked, never as stale, and an overseer ran an unmanaged copy nine fixes behind for four days with a clean drift notice.

## Pattern

The committed half holds what every clone shares and the machine half holds what one machine did. The split is by whether a value is a fact about the installation or about the checkout:

| Field | Where | Why |
|-------|-------|-----|
| name, kind, harness, source, sourceHash, sourceCommit, renderedHash, enabled, upstreamSkills, registration, reasons | committed | facts about the installation, identical in every clone |
| emitted.paths | committed, as remainders of the root, slashed | positions are names joined onto the root (invariant 17), so the remainder is the whole fact |
| sourceRepo, sources.repo, bundles.sourceRepo | committed; a path under the root as `.` or `./<remainder>` | derived from the committed manifest's declaration, so committing it leaks nothing the manifest does not; keeps the durable-provenance rule (invariant 4) and the update holds working in every clone |
| method, installedAt | machine half | what this apply on this disk did |
| root | machine half | the one question still needing it, whether a reconnected folder is the one a project left, is a question about this machine |

Reading rejoins each remainder onto the root reading it and refuses a position that is no remainder (absolute, empty, `.` or `..`), so a lock can claim nothing outside the project holding it; writing refuses the same claim before spelling it. A machine half for a key the committed record no longer names is dropped, and an entry with no machine half reads the manifest's answer for its delivery and takes a fresh timestamp on the next apply.

## Decision Criteria

A field goes in the committed half when its value is the same in every clone of the project at the same commit. A field whose value differs per machine, or that a clone cannot use, goes in the machine half. A field that would be the same everywhere but is spelled with a machine path is respelled, never moved.

## Alternatives Considered

- **Keep the lock per machine and settle every clone with `--record-existing`**: the state this decision ends; the settle needs consent on every clone and reports nothing about staleness.
- **Move `sourceRepo` to the machine half, as the request listed it**: rejected. Provenance is derived from the committed manifest, so committing it leaks no more than the manifest does, and without it a clone cannot refuse a rebind (invariant 4) or hold sibling packages at their recorded commits during a targeted update. Only a source declared by a path outside the project writes an absolute path, and the declaration already carries that path.
- **Keep absolute positions with the writing root and rebase on read** (the version 10 shape): rejected. Every machine writes its own root and paths, so a committed record would change on every apply on every machine.
- **Keep the machine half under `.kendex-local/`**: rejected. That directory is the project's local source, which git carries; `.cache/` is already per-machine and ignored.

## Impact

The commit offer and the render inventory list the lock beside `.kendex-generated.json`, so a refresh commits the record with the render diff. The managed ignore block drops the lock, and a consumer's own rule that still ignores it is reported with what a clone loses. `WORKTREE_COPIES` no longer copies the lock into a worktree. A linked worktree whose `.cache` is a link to the main checkout's shares the machine half; the shared values are the delivery and the timestamp, which agree across worktrees of one branch, and the root, which then names the last checkout that applied.

## Revisit When

- `kendex check` claims a matching unmanaged copy into the lock on its own (KEN-1585), which retires `--record-existing` as the migration path.
- A source declared by a path outside the project is common enough that its absolute provenance churns the committed record between machines; then provenance outside the root needs a portable spelling of its own.
