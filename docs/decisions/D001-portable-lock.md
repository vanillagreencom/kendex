# D001: Portable install record

[← Decision Index](INDEX.md)

**Date**: 2026-09-19

**Status**: Active

**Research**: KEN-1584

**Decision**: `.kendex-lock.json` is committed with the renders it records and reads as its own in every clone. Nothing in it names the checkout that wrote it: every position is relative to the root, a path source is recorded as its declaration, and the root itself is not written. What only one machine knows, the delivery an install used, when it was made and the root it was written under, is the machine half at `.cache/kendex/lock-local.json`, ignored by git. A field goes in the committed half when its value is the same in every clone at the same commit.

**Why**: A lock written per machine left every fresh clone, second machine and linked worktree with renders and no record, so every package read as files kendex never wrote and a stale install ran for days under a clean drift notice.

**Rejected**: Keeping the lock per machine and settling every clone with `--record-existing`: the settle needs consent on every clone and reports nothing about staleness. Recording a path source by the directory it resolved to: an absolute path names the writing machine, and every other clone reads its installs as rebound.

**Revisit when**: A person respelling a path declaration is common enough that the rebind refusal needs a remedy of its own.
