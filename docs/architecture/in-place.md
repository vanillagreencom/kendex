# The thing kendex writes is the thing it reads

Read before changing project resolution, the worktree guard or in-place packages.

## The approach

Two places break the usual split between a source and a render. Project resolution walks up from the process's working directory to the first project marker. A linked git worktree can therefore resolve a project inside its own checkout or a project above it. A package whose source is its files in place, the source `manifest::INPLACE_SOURCE_NAME` names, has no render: kendex holds the harness links, the project-instructions block in its `SKILL.md` and the record, and nothing else of the tree.

## Why

A worktree is where a lane works, and a write that lands in the main checkout from a worktree, or the other way round, is a write nobody asked for. An in-place package is the person's own tree; a record that owned it would turn every edit into a stale row, a hold or a take-over of their files.

## Rules

- Do resolve the project a bare verb writes from the working directory through `project_root_from` in `crates/core/src/discover.rs`. A marker inside a worktree makes that folder a project without requiring a manifest.
- Do apply the cross-checkout restriction to the command families selected by `writing_scopes` in `crates/cli/src/commands/lane_refresh.rs`. Its `check` compares the actual caller with their resolved writing destinations before bootstrap writes. Global scope and read or preview runs pass. `hooks/block-worktree-refresh.sh` queries only the installed executable on its own PATH with `--worktree-project-write-capability` before an advisory. Only one plain bare kendex call can receive that advisory. Other plain project-writer matches retain baseline refusals, including compound commands, prefixes and executable paths, without a capability query or execution: Claude PreToolUse runs before Bash approval. Global, read and preview inputs retain their existing classification. Quoted titles, messages and heredoc data stay outside the plain scan. The CLI answers before bootstrap with the fixed JSON object `{"worktree_project_write_guard":1}`. An absent capability, failed call or unreadable answer refuses with the executable's update route. This closes the install window for these plain commands because catalog refresh and executable update are independent. The hook neither resolves targets nor reads quoted data as execution. `remedy_target` in `crates/core/src/drift/report.rs` resolves the project for the check report.
- Do refuse a project-scope `refresh`, `apply` or `updates --apply` from a marked lane worktree unless the caller passes `--lane-refresh`; `crates/core/src/lane.rs` reads the marker the orch skill's `lane-marker` writes. The CLI also checks the `KENDEX_LANE_ORIGIN` launch root that orch's `open-terminal` exports inside local and hosted lane shells, so changing directory into main does not hide the invoking lane.
- Do decide once whether a tree is the source, where the artifact is built in `crates/core/src/engine/desired_skill.rs`; a copy delivered elsewhere from an in-place declaration is a render like any other.
- Do take `--project-path PATH` as the explicit project target for the verbs that accept it. A linked caller needs `--lane-refresh` to write another checkout with `refresh`, `apply` or `updates --apply`; that flag overrides both the marked-lane and cross-checkout checks. Other guarded project-writing verbs require a caller in the destination checkout.
- Never let a record own an in-place source tree: no edit hold, take-over or removal reaches it, and `refresh`, `check` and `verify` compare the links, the block and the entry point alone.

## The canonical example

`crates/cli/src/commands/lane_refresh.rs` with its suite `crates/cli/tests/lane_refresh.rs`: parsed commands use the same destination owners as dispatch. A refusal leaves the project and first-run records unchanged. The capability query answers before project checks or bootstrap writes. The hook's separate suite checks capability refusals, supported advisories and silent data.

## Revisit when

A lane starts through a route that does not preserve its launch root.

## Not governed

What a lane may write in its worktree beyond kendex's own verbs: the orch skill. How a render is compared with its source: [engine.md § The generated-file inventory](engine.md#the-generated-file-inventory).
