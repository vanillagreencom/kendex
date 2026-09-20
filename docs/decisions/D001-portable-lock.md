# D001: Portable install record

[← Decision Index](INDEX.md)

**Date**: 2026-09-19

**Status**: Active

**Research**: KEN-1584

**Applies to**: `crates/core/src/lock/`, `crates/core/src/hash.rs`, `crates/core/src/engine/`, `crates/core/src/pi_ext/`, `skills/worktree/scripts/`

## Summary

`.kendex-lock.json` is committed with the renders it records and reads as its own in every clone. Nothing in it names the checkout that wrote it: every position is spelled as a remainder of the root, a path source's provenance is its declaration in a dot-marked spelling rather than the directory it resolved to, and the root itself is not written. What only one machine knows — the delivery an install used, when it was made, the root it was written under — is the machine half of the record at `.cache/kendex/lock-local.json`, which the managed ignore block keeps out of git and which holds one row per checkout that wrote through it. The lock format is version 11; a version 10 record is refused by name and the way out is a fresh install, with `--record-existing` where the renders on disk are current.

## Context

The renders under `.agents/`, `.claude/`, `.codex/` and `.pi/` are committed, but the lock that says what they are was gitignored and written per machine. A fresh clone, a second machine and a linked worktree therefore started with renders and no record, and every package read as files kendex never wrote: `kendex check` reported them as blocked, never as stale, and an overseer ran an unmanaged copy nine fixes behind for four days with a clean drift notice.

A linked worktree now carries the committed record of its own branch, and its `.cache` is a link to the main checkout's under the worktree convention this repository ships (`WORKTREE_SYMLINKS`), so the main checkout and every linked worktree write one machine-half file. Each keeps its own row in it.

A standalone clone carries the committed record in its checkout. Worktree setup treats configured copies as a no-op when the checkout is both the source and destination.

## Pattern

The committed half holds what every clone shares and the machine half holds what one machine did. The split is by whether a value is a fact about the installation or about the checkout:

| Field | Where | Why |
|-------|-------|-----|
| name, kind, harness, source, sourceHash, sourceCommit, renderedHash, enabled, upstreamSkills, registration, reasons | committed | facts about the installation, identical in every clone |
| emitted | committed; `kind` and `name` as they are, `paths` as remainders of the root, slashed | positions are names joined onto the root (invariant 17), so the remainder is the whole fact |
| sourceRepo, sources.repo, bundles.sourceRepo | committed; a path source as its declaration in the spelling `source::declared_path_identity` gives it, which `source::path_root` reads through the same reader: `.` for the declaring root, `./catalog` under it, `../catalog` and an absolute declaration as typed | the declaration is the one spelling of a path source every clone shares, and the committed manifest already carries it, so committing it discloses nothing new; the directory it resolves to differs per machine, and recorded instead every clone read its own installs as rebound; the dot mark keeps every path identity out of the namespace `owner/repo`, a URL, `local` and `in-place` live in, so `path = "owner/repo"` records `./owner/repo` and the rebind refusal (invariant 4) and the reserved-name exemptions never match a path against one of those; keeps the durable-provenance rule and the update holds working in every clone. One identity within the declaring scope only: two scopes declaring `catalog` record one string for two directories, so a surface spanning scopes (marketplace rows, the library's provenance rows) keys on `source::machine_identity`, the directory the identity resolves to from its scope, never on this |
| method, installedAt | machine half | what this apply on this disk did |
| root | machine half, one row per root that wrote through the file | the one question still needing it, whether a reconnected folder is the one a project left, is a question about this machine; the relocate refusal for a folder holding a third project's record stands on this half alone and reads every root the file names, so a worktree's row beside a checkout's does not make the checkout's renamed folder a third project's, and a folder whose cache was cleared reads as holding no record, which the ordinary confirmation allows |

`sourceHash` identifies source content under the source path's Git policy. `renderedHash` identifies final artifact bytes under the destination path's Git policy. The values can differ for a copied package from an untracked source. A clean text checkout uses Git's LF identity in both CRLF and LF clones. A kendex-owned destination follows its policy whether or not Git reports the file as changed, so kendex's own uncommitted render keeps the identity it was recorded with. An untracked source edit, a Git-visible edit at a source or unowned path, and binary content keep exact byte identity. Apply and recovery preconditions always bind to exact disk bytes.

Reading rejoins each remainder onto the root reading it and refuses a position that is no remainder (absolute, empty, `.` or `..`), so a lock can claim nothing outside the project holding it; writing refuses the same claim before spelling it. The machine half is reached through whatever `.cache` resolves to and is deliberately not held to the project root: a save replaces this root's row and keeps every other, and a read takes this root's row. An apply resolves that machine path before it takes its writer lock, so linked roots use one lock for the shared file. It holds that lock from the journal snapshot through the successful clear or rollback. A machine record for a key the committed record no longer names is dropped. An entry with no machine half is re-recorded by the next apply with the manifest's delivery and a fresh timestamp; a fork, which reads an installation back through the place its delivery wrote each skill, refuses until that apply rather than guess. A machine half this build cannot read, from another build writing the shared file or from an interrupted write, reads as absent for the same reason: it carries nothing an install needs, and the next save writes this root's row whole.

## Decision Criteria

A field goes in the committed half when its value is the same in every clone of the project at the same commit. A field whose value differs per machine, or that a clone cannot use, goes in the machine half. A field that would be the same everywhere but is spelled with a machine path is respelled, never moved. A respelling that serves as an identity has one reader (`source::declared_path_identity`, which `source::path_root` shares), lives in a namespace no other identity can enter, and is compared across scopes only through the directory it resolves to on this machine.

## Alternatives Considered

- **Keep the lock per machine and settle every clone with `--record-existing`**: the state this decision ends; the settle needs consent on every clone and reports nothing about staleness.
- **Move `sourceRepo` to the machine half, as the request listed it**: rejected. Without it a clone cannot refuse a rebind (invariant 4) or hold sibling packages at their recorded commits during a targeted update. Recorded as the declaration, it carries exactly what the committed manifest carries.
- **Record a path source by the directory it resolved to, respelled as a remainder where it sits under the root**: rejected. A declaration outside the root (`../catalog`, the sibling-checkout shape `kendex source add` accepts) resolves to an absolute path naming the writing machine and its account, which the manifest does not hold, and every other clone resolves the same declaration elsewhere and reads its installs as rebound.
- **Keep absolute positions with the writing root and rebase on read** (the version 10 shape): rejected. Every machine writes its own root and paths, so a committed record would change on every apply on every machine.
- **Keep the machine half under `.kendex-local/`**: rejected. That directory is the project's local source, which git carries; `.cache/` is already per-machine and ignored.

## Impact

The commit offer and the render inventory list the lock beside `.kendex-generated.json`, so a refresh commits the record with the render diff. A clone that carries renders and no record, and the clone every earlier build left, is settled by `kendex check`: it plans the scope once, records each render that matches its source at the commit the source resolved, and reports each one that differs as stale with the file count and `kendex apply --replace-unmanaged` as the fix, so `--record-existing` is the explicit spelling of the same claim for a record moved aside by hand. The managed ignore block drops the lock, and a consumer's own rule that still ignores it is reported with what a clone loses; `--record-existing` refreshes the block in the same run as the record, so the record it writes is never left ignored. A stale `WORKTREE_COPIES` entry cannot replace the lock because worktree setup leaves every Git-owned copy path to Git. A linked worktree whose `.cache` is a link to the main checkout's shares the machine-half file; each checkout keeps its own row in it, and the file names every checkout that applied through it. A fork in a fresh clone waits for one apply to record the delivery it reads back through.

After `worktree push` rebases a branch, it persists the SHA map and clears the pending rewrite before it restores configured worktree paths. A setup failure still stops the push. The successful rewrite keeps its map for the caller and for the next recovery step.

## Revisit When

- A person respelling a path declaration (`catalog` to `./catalog/` is one identity; `../catalog` to `/home/me/catalog` is not) is common enough that the rebind refusal it produces needs a remedy of its own.
- The relocate refusal for a folder holding a third project's record has to survive a cleared cache; then the writing root, or a project identity, goes into the committed half.
