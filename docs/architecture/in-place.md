# The thing kendex writes is the thing it reads

Read before changing project resolution, the worktree guard or in-place packages.

## The approach

Two places break the usual split between a source and a render. A linked git worktree that carries its own manifest is its own project: a bare `kendex refresh`, `apply` or `check` typed there targets that worktree, and one that carries none belongs to the main checkout. A package whose source is its files in place, the source `manifest::INPLACE_SOURCE_NAME` names, has no render: kendex holds the harness links, the project-instructions block in its `SKILL.md` and the record, and nothing else of the tree.

## Why

A worktree is where a lane works, and a write that lands in the main checkout from a worktree, or the other way round, is a write nobody asked for. An in-place package is the person's own tree; a record that owned it would turn every edit into a stale row, a hold or a take-over of their files.

## Rules

- Do resolve the project a bare verb writes from the working directory through `project_root_from` in `crates/core/src/discover.rs`: a worktree is its own project only where its manifest file exists there.
- Do ask that one predicate everywhere: `hooks/block-worktree-refresh.sh` spells its markers in Bash and refuses a write whose target is another checkout, and `remedy_target` in `crates/core/src/drift/report.rs` resolves the same answer for the check report.
- Do refuse a project-scope `refresh`, `apply` or `updates --apply` from a marked lane worktree unless the caller passes `--lane-refresh`; `crates/core/src/lane.rs` reads the marker the orch skill's `lane-marker` writes.
- Do decide once whether a tree is the source, where the artifact is built in `crates/core/src/engine/desired_skill.rs`; a copy delivered elsewhere from an in-place declaration is a render like any other.
- Do take `--project-path PATH` as the explicit form for writing another project from anywhere.
- Never let a record own an in-place source tree: no edit hold, take-over or removal reaches it, and `refresh`, `check` and `verify` compare the links, the block and the entry point alone.
- Never let a rendered guard require a flag the installed CLI lacks: before a refusal names `--project-path`, the hook asks `kendex refresh --help` once and reads whether the flag is listed.

## The canonical example

`hooks/block-worktree-refresh.sh` with its suite `hooks/tests/block-worktree-refresh.test.sh`: each refused and admitted command is one row, and the Bash markers mirror `discover.rs`. A change to project resolution changes both and runs that suite.

## Revisit when

A harness reads a project from somewhere other than the working directory's checkout, so the predicate cannot answer from the directory alone.

## Not governed

What a lane may write in its worktree beyond kendex's own verbs: the orch skill. How a render is compared with its source: [generated-paths.md](generated-paths.md).
